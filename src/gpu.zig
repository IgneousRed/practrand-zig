// Optional Metal/Vulkan execution. Separate services own classification/counts
// and optional FPF work while CPU workers continue independent families.
const std = @import("std");
const builtin = @import("builtin");
const Job = @import("worker_pool.zig").Job;
const Service = @import("worker_pool.zig").Service;
const TieBits = @import("classification.zig").TieBits;
// Initial batching heuristic, not a measured performance crossover.
pub const minimum_input_bytes = 64 << 10;
// Measured fold-inclusive crossover; calls retain their original boundaries.
pub const minimum_count_input_bytes = 4 << 20;
const Create = *const fn (usize, [*]u8, usize, [*]u8, usize) callconv(.c) ?*anyopaque;
const Destroy = *const fn (*anyopaque) callconv(.c) void;
const Classify = *const fn (*anyopaque, [*]const u8, usize, [*]const u32, [*]u8, [*]u8, usize) callconv(.c) c_int;
const AddFpfPair = *const fn (*anyopaque, [*]const u8, usize, [*]const u8, u32, [*]u64, [*]u64, [*]u8, usize) callconv(.c) c_int;
const AddFpf = *const fn (*anyopaque, [*]const u8, usize, [*]const u8, u32, [*]u64, [*]u8, usize) callconv(.c) c_int;
const Count = *const fn (*anyopaque, u32, [*]const u8, usize, [*]const u32, [*]const u32, u32, u32, ?[*]const u32, *[*]const u32, [*]u8, usize) callconv(.c) c_int;
const CountPairParameters = extern struct {
    initial: [9]u32,
    warmup: [9]u32,
    dc_initial: u32,
    dc_warmup: u32,
    dc_odd: u32,
    dc_mask: u32,
};
const DispatchPair = *const fn (*anyopaque, [*]const u8, usize, *const CountPairParameters, [*]const u32, *[*]const u32, [*]u8, usize) callconv(.c) c_int;
extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;

pub const Executor = struct {
    pub const Request = Service.Request;
    const Mod3Extension = struct { dispatch: Count, layers: usize };
    allocator: std.mem.Allocator,
    library: std.DynLib,
    context: *anyopaque,
    destroy: Destroy,
    dispatch: Classify,
    count_dispatch: Count,
    pair_dispatch: ?DispatchPair = null,
    extended_mod3: ?Mod3Extension = null,
    fpf_add: ?AddFpf = null,
    fpf_add_pair: ?AddFpfPair = null,
    capacity: usize,
    fpf_capacity: usize,
    supports_counts: bool,
    ties: []u32,
    device_name: [256:0]u8,
    service: Service = .{},
    fpf_service: Service = .{},

    // Initialize in place: the service thread retains this address.
    pub fn init(self: *Executor, allocator: std.mem.Allocator, capacity: usize, library_path: ?[]const u8) !void {
        const explicit = library_path orelse if (getenv("PRACTRAND_GPU_LIBRARY")) |p| std.mem.span(p) else null;
        const path = explicit orelse if (builtin.os.tag == .macos) "@rpath/libpractrand_metal.dylib" else "libpractrand_vulkan.so";
        var library = std.DynLib.open(path) catch fallback: {
            // Prefer Metal on macOS. A Vulkan-only installation is still usable.
            if (explicit == null and builtin.os.tag == .macos) {
                if (std.DynLib.open("@rpath/libpractrand_vulkan.dylib")) |loaded| break :fallback loaded else |_| {}
            }
            std.debug.print("GPU: cannot load {s}; build with -Dmetal=true on macOS or -Dvulkan=true with a Vulkan runtime. PRACTRAND_GPU_LIBRARY can select an explicit library path.\n", .{path});
            return error.GpuLibraryUnavailable;
        };
        errdefer library.close();
        const version = library.lookup(*const fn () callconv(.c) u32, "pr_gpu_api_version") orelse return error.GpuLibraryIncompatible;
        if (version() != 11) return error.GpuLibraryIncompatible;
        const create = library.lookup(Create, "pr_gpu_create") orelse return error.GpuLibraryIncompatible;
        const destroy = library.lookup(Destroy, "pr_gpu_destroy") orelse return error.GpuLibraryIncompatible;
        const dispatch = library.lookup(Classify, "pr_gpu_classify") orelse return error.GpuLibraryIncompatible;
        const count_dispatch = library.lookup(Count, "pr_gpu_count") orelse return error.GpuLibraryIncompatible;
        const count_support = library.lookup(*const fn (*anyopaque) callconv(.c) u32, "pr_gpu_count_supported") orelse return error.GpuLibraryIncompatible;
        var name: [256:0]u8 = @splat(0);
        var message: [512:0]u8 = @splat(0);
        const context = create(capacity, &name, name.len, &message, message.len) orelse {
            std.debug.print("GPU: {s}\n", .{std.mem.sliceTo(&message, 0)});
            return error.GpuInitializationFailed;
        };
        errdefer destroy(context);
        const extended_mod3: ?Mod3Extension = if (library.lookup(Count, "pr_gpu_mod3_count_v1")) |dispatch_mod3| extension: {
            const get_layers = library.lookup(*const fn (*anyopaque) callconv(.c) u32, "pr_gpu_mod3_layers_v1") orelse return error.GpuLibraryIncompatible;
            const layers = get_layers(context);
            // Whole 1 KiB calls retain complete pairs and a whole-u32 packed
            // handoff through nine GPU levels. Older backends keep six.
            if (layers < 6 or layers > 9) return error.GpuLibraryIncompatible;
            break :extension .{ .dispatch = dispatch_mod3, .layers = layers };
        } else null;
        const fpf_capacity = if (library.lookup(*const fn (*anyopaque) callconv(.c) usize, "pr_gpu_fpf_capacity_v1")) |get_capacity| get_capacity(context) else capacity;
        if (fpf_capacity < capacity or fpf_capacity > 128 << 20 or fpf_capacity % 1024 != 0) return error.GpuLibraryIncompatible;
        const ties = try allocator.alloc(u32, capacity / 32);
        errdefer allocator.free(ties);
        self.* = .{ .allocator = allocator, .library = library, .context = context, .destroy = destroy, .dispatch = dispatch, .count_dispatch = count_dispatch, .pair_dispatch = library.lookup(DispatchPair, "pr_gpu_count_pair_v1"), .extended_mod3 = extended_mod3, .fpf_add = library.lookup(AddFpf, "pr_gpu_fpf_add_v1"), .fpf_add_pair = library.lookup(AddFpfPair, "pr_gpu_fpf_add_pair_v1"), .capacity = capacity, .fpf_capacity = fpf_capacity, .supports_counts = count_support(context) != 0, .ties = ties, .device_name = name };
        try self.service.init();
        errdefer self.service.deinit();
        if (self.fpf_add != null) try self.fpf_service.init();
    }
    pub fn deinit(self: *Executor) void {
        if (self.fpf_add != null) self.fpf_service.deinit();
        self.service.deinit();
        self.destroy(self.context);
        self.library.close();
        self.allocator.free(self.ties);
    }
    pub fn start(self: *Executor, request: *Request) void {
        self.service.start(request);
    }
    pub fn wait(self: *Executor, request: *Request) !void {
        try self.service.wait(request);
    }
    // Independent FPF submissions keep CPU family workers available while
    // this owner waits for its GPU lease. The caller joins before reusing state.
    pub fn startFpf(self: *Executor, request: *Request) void {
        self.fpf_service.start(request);
    }
    pub fn waitFpf(self: *Executor, request: *Request) !void {
        try self.fpf_service.wait(request);
    }
    // Called only by the owning service job. Publish RNG progress after dispatch
    // and readback succeed; the output remains private until the caller publishes it.
    pub fn classify(self: *Executor, random: *TieBits, input: []const u8, output: []u8) !void {
        if (builtin.is_test and (input.len % 32 != 0 or input.len / 32 > self.ties.len or output.len != input.len / 16)) @panic("invalid GPU classification batch");
        if (input.len == 0) return;
        var fresh = random.*;
        const ties = self.ties[0 .. input.len / 32];
        // Keep the shader's low-16-bit-per-pair contract while consuming every
        // byte of the shared CPU/GPU tie stream, including cached partial words.
        for (ties) |*tie| tie.* = fresh.take(u16);
        var message: [512:0]u8 = @splat(0);
        if (self.dispatch(self.context, input.ptr, input.len, ties.ptr, output.ptr, &message, message.len) != 0) {
            std.debug.print("GPU: {s}\n", .{std.mem.sliceTo(&message, 0)});
            return error.GpuExecutionFailed;
        }
        random.* = fresh;
    }
    // The FPF service and direct callers use independent FPF state/scratch.
    // Its backend holds the scratch lock through integer merging; no borrowed
    // readback escapes to another request. Classification/counter scratch is separate.
    pub fn addFpf(self: *Executor, bytes: []const u8, tail: *const [8]u8, started: bool, counts: []u64) !void {
        try self.addFpfWith16(bytes, tail, started, counts, null);
    }
    pub fn addFpfWith16(self: *Executor, bytes: []const u8, tail: *const [8]u8, started: bool, counts: []u64, aligned: ?[]u64) !void {
        if (builtin.is_test and (counts.len != 851968 or bytes.len == 0 or bytes.len > self.fpf_capacity or bytes.len % 1024 != 0 or
            (aligned != null and aligned.?.len != counts.len))) @panic("invalid native FPF input");
        var message: [512:0]u8 = @splat(0);
        const status = if (aligned) |other| pair: {
            const add = self.fpf_add_pair orelse return error.GpuFpfUnavailable;
            break :pair add(self.context, bytes.ptr, bytes.len, tail, @intFromBool(started), counts.ptr, other.ptr, &message, message.len);
        } else single: {
            const add = self.fpf_add orelse return error.GpuFpfUnavailable;
            break :single add(self.context, bytes.ptr, bytes.len, tail, @intFromBool(started), counts.ptr, &message, message.len);
        };
        if (status != 0) {
            std.debug.print("GPU FPF: {s}\n", .{std.mem.sliceTo(&message, 0)});
            return error.GpuFpfFailed;
        }
    }
    pub const CountKind = enum(u32) { mod3 = 0, dc7 = 2 };
    pub const CountInput = struct {
        kind: CountKind,
        bytes: []const u8,
        initial: [9]u32 = @splat(0),
        warmup: [9]u32 = @splat(0),
        odd: u32 = 0,
        mask: u32 = 0,
        lookup: []const u32 = &.{},
    };
    // Only the service calls this. The result borrows shared scratch until the
    // next backend call; callers merge it before publishing their service job.
    pub fn count(self: *Executor, input: CountInput) ![]const u32 {
        return self.countWith(input, self.count_dispatch, 6);
    }
    pub fn mod3Layers(self: *const Executor) usize {
        return if (self.extended_mod3) |extension| extension.layers else 6;
    }
    pub fn countMod3(self: *Executor, input: CountInput) ![]const u32 {
        if (builtin.is_test and input.kind != .mod3) @panic("invalid extended Mod3 request");
        if (self.extended_mod3) |extension| return self.countWith(input, extension.dispatch, extension.layers);
        return self.count(input);
    }
    pub fn hasCountPair(self: *const Executor) bool {
        return self.pair_dispatch != null and self.mod3Layers() == 9;
    }
    pub const PairResult = struct { mod3: []const u32, dc7: []const u32 };
    // One service request owns both borrowed output regions until they are merged.
    pub fn countPair(self: *Executor, mod3: CountInput, dc7: CountInput) !PairResult {
        if (builtin.is_test and (!self.hasCountPair() or mod3.kind != .mod3 or dc7.kind != .dc7 or
            mod3.bytes.ptr != dc7.bytes.ptr or mod3.bytes.len != dc7.bytes.len or
            mod3.bytes.len == 0 or mod3.bytes.len % 1024 != 0 or mod3.bytes.len > self.capacity or dc7.lookup.len != 256))
            @panic("invalid paired GPU counter call");
        const parameters = CountPairParameters{ .initial = mod3.initial, .warmup = mod3.warmup, .dc_initial = dc7.initial[0], .dc_warmup = dc7.warmup[0], .dc_odd = dc7.odd, .dc_mask = dc7.mask };
        var message: [512:0]u8 = @splat(0);
        var result: [*]const u32 = undefined;
        if (self.pair_dispatch.?(self.context, mod3.bytes.ptr, mod3.bytes.len, &parameters, dc7.lookup.ptr, &result, &message, message.len) != 0) {
            std.debug.print("GPU paired counter: {s}\n", .{std.mem.sliceTo(&message, 0)});
            return error.GpuCountingFailed;
        }
        const mod3_size = 9 * 19683 + (mod3.bytes.len >> 10);
        return .{ .mod3 = result[0..mod3_size], .dc7 = result[mod3_size..][0 .. 2 * 262144] };
    }
    fn countWith(self: *Executor, input: CountInput, dispatch_counts: Count, layers: usize) ![]const u32 {
        if (builtin.is_test and (input.bytes.len == 0 or input.bytes.len % 1024 != 0 or input.bytes.len > self.capacity)) @panic("invalid bounded GPU counter call");
        var message: [512:0]u8 = @splat(0);
        var result: [*]const u32 = undefined;
        const lookup = if (input.lookup.len == 0) null else input.lookup.ptr;
        if (dispatch_counts(self.context, @backingInt(input.kind), input.bytes.ptr, input.bytes.len, &input.initial, &input.warmup, input.odd, input.mask, lookup, &result, &message, message.len) != 0) {
            std.debug.print("GPU counter: {s}\n", .{std.mem.sliceTo(&message, 0)});
            return error.GpuCountingFailed;
        }
        const size = switch (input.kind) {
            .mod3 => layers * 19683 + (input.bytes.len >> @intCast(layers + 1)),
            .dc7 => 2 * 262144,
        };
        return result[0..size];
    }
};
