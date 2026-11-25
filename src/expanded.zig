// Expanded battery and classification transform from PractRand 0.96 (CC0).
const std = @import("std");
const b = @import("battery.zig");
const p = @import("permutation.zig");
const Pat5 = @import("pattern.zig").Pat5;
const NearSeq3 = @import("near_seq.zig").NearSeq3;
const pool = @import("worker_pool.zig");
const classification = @import("classification.zig");
const Gpu = @import("gpu.zig").Executor;
const A = std.mem.Allocator;
// OddPhi: every C8 stream starts from this fixed low seed word and a zero high word.
pub const classification_seed: u64 = 0x9e3779b97f4a7c15;
const Family = enum { bcfn, classified, perm64, perm32, weighted64, weighted32, birthday, mod3, brank, tmf, near, dc7, dc7_16, dc7_32, pat, fpf64, fpf32, fpf16, fpf4, gap };
const families = std.enums.values(Family);
pub const family_count = families.len;
// These boundaries affect Pat5 results; preserve PractRand 0.96.
pub const transform_flush_bytes: usize = 4 << 20;
pub const maximum_transform_input_bytes: usize = 16 << 20;
const BCFN = b.BitCount(0);
const DC16 = b.Distribution(6, 1, false);
const DC32 = b.Distribution(5, 2, false);
const DC7 = b.Distribution(9, 0, true);
const DC7_16 = b.Distribution(6, 1, true);
const DC7_32 = b.Distribution(5, 2, true);
const FPF64 = b.FloatingPattern(6);
const FPF32 = b.FloatingPattern(5);
const FPF4 = b.FloatingPattern(2);
const Perm64 = p.Permutation(64, false);
const Perm32 = p.Permutation(32, false);
const Weighted64 = p.Permutation(64, true);
const Weighted32 = p.Permutation(32, true);
const Birthday = b.BirthdayTest(1);
const Mod3 = b.Modulo3(0);
const BRank = b.MatrixRank(18);
const TMF = b.TripleMirror(0);

const Classified = struct {
    random: classification.TieBits,
    buffer: []u8,
    used: usize = 0,
    bcfn: b.BCFN,
    dc8: b.DC6,
    dc16: DC16,
    dc32: DC32,
    fpf: b.FPF,
    gap: b.Gap,
    mod3: b.Mod3,
    tmf: b.TMF,
    const Transform = struct {
        gpu: *Gpu,
        random: *classification.TieBits,
        input: []const u8,
        output: []u8,
        fn run(raw: *anyopaque) !void {
            const transform: *@This() = @ptrCast(@alignCast(raw));
            try transform.gpu.classify(transform.random, transform.input, transform.output);
        }
    };
    fn update(t: *Classified, bytes: []const u8, gpu: ?*Gpu) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = @min(bytes.len - offset, maximum_transform_input_bytes);
            const produced = n / 16;
            const input = bytes[offset..][0..n];
            const output = t.buffer[t.used..][0..produced];
            if (gpu) |device| {
                // The CPU family owns C8 state and child counting. Only this
                // bounded transform borrows it on the GPU service, until joined.
                var transform = Transform{ .gpu = device, .random = &t.random, .input = input, .output = output };
                var request = Gpu.Request.init(.{ .context = &transform, .run = Transform.run });
                device.start(&request);
                try device.wait(&request);
            } else classification.classify(&t.random, input, output);
            t.used += produced;
            t.flush(false);
            offset += n;
        }
    }
    fn flush(t: *Classified, aggressive: bool) void {
        const full = t.used / 1024 * 1024;
        if (full < (if (aggressive) @as(usize, 1024) else transform_flush_bytes)) return;
        const input = t.buffer[0..full];
        t.bcfn.update(input);
        t.dc8.update(input);
        t.dc16.update(input);
        t.dc32.update(input);
        t.fpf.update(input);
        t.gap.update(input);
        t.mod3.update(input);
        t.tmf.update(input);
        std.mem.copyForwards(u8, t.buffer[0 .. t.used - full], t.buffer[full..t.used]);
        t.used -= full;
    }
    fn results(t: Classified, blocks: u64, r: *b.Results) !void {
        if (blocks == 0) return;
        const old = r.prefix;
        r.prefix = try r.formatName("{s}[C8]", .{old});
        defer r.prefix = old;
        try t.bcfn.results(blocks, r);
        try t.dc8.results(blocks, r);
        try t.dc16.results(blocks, r);
        try t.dc32.results(blocks, r);
        try t.fpf.results(blocks, r);
        try t.gap.results(r);
        try t.mod3.results(r);
        try t.tmf.results(blocks, r);
    }
};

pub const Battery = struct {
    histograms: []u64,
    blocks: u64 = 0,
    bcfn: BCFN,
    classified: Classified,
    perm64: Perm64,
    perm32: Perm32,
    weighted64: Weighted64,
    weighted32: Weighted32,
    birthday: Birthday,
    mod3: Mod3,
    brank: BRank,
    tmf: TMF,
    near: NearSeq3,
    dc7: DC7,
    dc7_16: DC7_16,
    dc7_32: DC7_32,
    pat: Pat5,
    fpf64: FPF64,
    fpf32: FPF32,
    fpf16: b.FPF,
    fpf4: FPF4,
    gap: b.Gap,
    // The caller owns the run arena and immutable models; deinit releases independent resources.
    pub fn init(a: A, models: []const @import("near_seq.zig").Model) !Battery {
        const storage = try b.allocateHistograms(.{
            .bcfn = BCFN.count_bins,
            .classified_bcfn = b.BCFN.count_bins,
            .classified_dc8 = b.DC6.count_bins,
            .classified_dc16 = DC16.count_bins,
            .classified_dc32 = DC32.count_bins,
            .classified_fpf = b.FPF.count_bins,
            .classified_gap = b.Gap.count_bins,
            .classified_mod3 = b.Mod3.count_bins,
            .classified_tmf = b.TMF.count_bins,
            .perm64 = Perm64.count_bins,
            .perm32 = Perm32.count_bins,
            .weighted64 = Weighted64.count_bins,
            .weighted32 = Weighted32.count_bins,
            .mod3 = Mod3.count_bins,
            .tmf = TMF.count_bins,
            .dc7_even = DC7.count_bins,
            .dc7_odd = DC7.count_bins,
            .dc7_16_even = DC7_16.count_bins,
            .dc7_16_odd = DC7_16.count_bins,
            .dc7_32_even = DC7_32.count_bins,
            .dc7_32_odd = DC7_32.count_bins,
            .pat = Pat5.count_bins,
            .fpf64 = FPF64.count_bins,
            .fpf32 = FPF32.count_bins,
            .fpf16 = b.FPF.count_bins,
            .fpf4 = FPF4.count_bins,
            .gap = b.Gap.count_bins,
        });
        errdefer b.freeHistograms(storage.memory);
        const c = storage.counts;
        const last = try a.alloc(u32, 2 * 65536);
        @memset(last, 0);
        var birthday = Birthday{ .allocator = std.heap.page_allocator, .buffer = try std.ArrayList(u64).initCapacity(std.heap.page_allocator, b.birthday_sample_capacity) };
        errdefer birthday.buffer.deinit(birthday.allocator);
        var brank = try BRank.init(std.heap.page_allocator);
        errdefer brank.allocator.free(brank.matrix);
        return .{
            .histograms = storage.memory,
            .bcfn = .{ .counts = c.bcfn },
            .classified = .{ .random = classification.TieBits.init(classification_seed), .buffer = try a.alloc(u8, transform_flush_bytes + maximum_transform_input_bytes / 16 + 1024), .bcfn = .{ .counts = c.classified_bcfn }, .dc8 = .{ .counts = c.classified_dc8 }, .dc16 = .{ .counts = c.classified_dc16 }, .dc32 = .{ .counts = c.classified_dc32 }, .fpf = .{ .counts = c.classified_fpf }, .gap = .{ .counts = c.classified_gap, .last = last[0..65536] }, .mod3 = .{ .counts = c.classified_mod3 }, .tmf = .{ .counts = c.classified_tmf } },
            .perm64 = .{ .counts = c.perm64 },
            .perm32 = .{ .counts = c.perm32 },
            .weighted64 = .{ .counts = c.weighted64 },
            .weighted32 = .{ .counts = c.weighted32 },
            .birthday = birthday,
            .mod3 = .{ .counts = c.mod3 },
            .brank = brank,
            .tmf = .{ .counts = c.tmf },
            .near = try NearSeq3.init(a, models),
            .dc7 = .{ .counts = c.dc7_even, .odd_counts = c.dc7_odd },
            .dc7_16 = .{ .counts = c.dc7_16_even, .odd_counts = c.dc7_16_odd },
            .dc7_32 = .{ .counts = c.dc7_32_even, .odd_counts = c.dc7_32_odd },
            .pat = .{ .counts = c.pat },
            .fpf64 = .{ .counts = c.fpf64 },
            .fpf32 = .{ .counts = c.fpf32 },
            .fpf16 = .{ .counts = c.fpf16 },
            .fpf4 = .{ .counts = c.fpf4 },
            .gap = .{ .counts = c.gap, .last = last[65536..] },
        };
    }
    pub fn deinit(t: *Battery) void {
        b.freeHistograms(t.histograms);
        t.birthday.buffer.deinit(t.birthday.allocator);
        t.brank.allocator.free(t.brank.matrix);
        t.near.deinit();
    }
    pub fn update(t: *Battery, bytes: []const u8, executor: ?*pool.Pool, gpu: ?*Gpu) !void {
        if (@import("builtin").is_test and (bytes.len == 0 or bytes.len % 1024 != 0)) @panic("battery input must contain complete nonempty blocks");
        const offload = if (bytes.len >= @import("gpu.zig").minimum_input_bytes) gpu else null;
        // FPF offload leaves useful CPU capacity for C8 while keeping the GPU
        // service focused on raw histograms. Older backends retain GPU C8.
        const classify_offload = if (offload) |device| device.fpf_add == null else false;
        var gpu_job: GpuJob = undefined;
        var counters: ?Gpu.Request = null;
        var fpf: ?Gpu.Request = null;
        if (offload) |device| {
            if (bytes.len >= @import("gpu.zig").minimum_count_input_bytes) {
                gpu_job = .{ .battery = t, .bytes = bytes, .gpu = device };
                if (device.supports_counts) {
                    counters = Gpu.Request.init(.{ .context = &gpu_job, .run = GpuJob.count });
                    device.start(&counters.?);
                }
                if (device.fpf_add != null) {
                    fpf = Gpu.Request.init(.{ .context = &gpu_job, .run = GpuJob.addFpf });
                    device.startFpf(&fpf.?);
                }
            }
        }
        var contexts: [families.len]CountJob = undefined;
        var jobs: [families.len]pool.Job = undefined;
        var n: usize = 0;
        for (families) |family| {
            if (fpf != null and (family == .fpf4 or (family == .fpf16 and gpu.?.fpf_add_pair != null))) continue;
            if (counters != null and (family == .mod3 or family == .dc7)) continue;
            contexts[n] = .{ .battery = t, .bytes = bytes, .family = family, .gpu_classify = if (classify_offload and family == .classified) offload else null };
            jobs[n] = .{ .context = &contexts[n], .run = CountJob.run };
            n += 1;
        }
        // Join every executor even when a job set fails. Input and stack job
        // contexts must remain alive until neither executor can reference them.
        const cpu_result: anyerror!void = block: {
            if (executor) |workers| {
                break :block workers.run(jobs[0..n]);
            } else for (jobs[0..n]) |job| job.run(job.context) catch |err| break :block err;
            break :block {};
        };
        const gpu_result: anyerror!void = if (counters) |*request| gpu.?.wait(request) else {};
        const fpf_result: anyerror!void = if (fpf) |*request| gpu.?.waitFpf(request) else {};
        try cpu_result;
        try gpu_result;
        try fpf_result;
        t.blocks += bytes.len / 1024;
    }
    fn updateFamily(t: *Battery, bytes: []const u8, family: Family) !void {
        switch (family) {
            .bcfn => t.bcfn.update(bytes),
            .classified => try t.classified.update(bytes, null),
            .perm64 => t.perm64.update(bytes),
            .perm32 => t.perm32.update(bytes),
            .weighted64 => t.weighted64.update(bytes),
            .weighted32 => t.weighted32.update(bytes),
            .birthday => try t.birthday.update(bytes),
            .mod3 => t.mod3.update(bytes),
            .brank => try t.brank.update(bytes),
            .tmf => t.tmf.update(bytes),
            .near => try t.near.update(bytes),
            .dc7 => t.dc7.update(bytes),
            .dc7_16 => t.dc7_16.update(bytes),
            .dc7_32 => t.dc7_32.update(bytes),
            .pat => t.pat.update(bytes),
            .fpf64 => t.fpf64.update(bytes),
            .fpf32 => t.fpf32.update(bytes),
            .fpf16 => t.fpf16.update(bytes),
            .fpf4 => t.fpf4.update(bytes),
            .gap => t.gap.update(bytes),
        }
    }
    // Preserve upstream's checkpoint flush boundary before deriving any scores.
    pub fn prepareCheckpoint(t: *Battery) void {
        t.classified.flush(true);
    }
    pub fn results(t: *const Battery, r: *b.Results) !void {
        if (t.blocks == 0) return;
        if (@import("builtin").is_test and t.classified.used >= 1024) @panic("classification must be prepared before scoring");
        try t.bcfn.results(t.blocks, r);
        try t.classified.results(t.blocks / 16, r);
        try t.perm64.results(t.blocks, r);
        try t.perm32.results(t.blocks, r);
        try t.weighted64.results(t.blocks, r);
        try t.weighted32.results(t.blocks, r);
        try t.birthday.results(r);
        try t.mod3.results(r);
        try t.brank.results(r);
        try t.tmf.results(t.blocks, r);
        try t.near.results(t.blocks, r);
        try t.dc7.results(t.blocks, r);
        try t.dc7_16.results(t.blocks, r);
        try t.dc7_32.results(t.blocks, r);
        try t.pat.results(t.blocks, r);
        try t.fpf64.results(t.blocks, r);
        try t.fpf32.results(t.blocks, r);
        try t.fpf16.results(t.blocks, r);
        try t.fpf4.results(t.blocks, r);
        try t.gap.results(r);
    }
};
const CountJob = struct {
    battery: *Battery,
    bytes: []const u8,
    family: Family,
    gpu_classify: ?*Gpu = null,
    fn run(raw: *anyopaque) !void {
        const job: *CountJob = @ptrCast(@alignCast(raw));
        const t = job.battery;
        if (job.gpu_classify) |device| return t.classified.update(job.bytes, device);
        return t.updateFamily(job.bytes, job.family);
    }
};

const GpuJob = struct {
    battery: *Battery,
    bytes: []const u8,
    gpu: *Gpu,
    fn count(raw: *anyopaque) !void {
        const job: *const GpuJob = @ptrCast(@alignCast(raw));
        return b.gpuCounters(&job.battery.mod3, &job.battery.dc7, job.bytes, job.gpu);
    }
    fn addFpf(raw: *anyopaque) !void {
        const job: *const GpuJob = @ptrCast(@alignCast(raw));
        const t = job.battery;
        return b.gpuFpfWith16(&t.fpf4, if (job.gpu.fpf_add_pair != null) &t.fpf16 else null, job.bytes, job.gpu);
    }
};
