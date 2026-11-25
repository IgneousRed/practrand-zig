const std = @import("std");
const stream_module = @import("streams.zig");
const report = @import("report.zig");
const s = @import("statistics.zig");
const Gpu = @import("gpu.zig").Executor;
const Service = @import("worker_pool.zig").Service;
const builtin_rngs = @import("builtin_rngs.zig");
const version = "0.2.0";
const input_buffer_bytes = 32 << 20;
const expanded_parallel_input_bytes = 128 << 20;
const maximum_step_blocks = 256 * 1024;
const A = std.mem.Allocator;
comptime {
    const target = @import("builtin");
    if (@sizeOf(usize) != 8 or target.cpu.arch.endian() != .little or
        (target.os.tag != .macos and target.os.tag != .linux))
        @compileError("supported targets are 64-bit little-endian macOS and Linux");
}

extern "c" fn printf([*:0]const u8, ...) c_int;
extern "c" fn write(c_int, [*]const u8, usize) isize;
extern "c" fn read(c_int, [*]u8, usize) isize;
extern "c" fn exit(c_int) noreturn;
extern "c" fn atoi([*:0]const u8) c_int;
fn now() f64 {
    var stamp: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &stamp) != 0) fail("monotonic clock unavailable");
    return s.f(stamp.sec) + s.f(stamp.nsec) * 0.000000001;
}
fn fail(message: []const u8) noreturn {
    _ = write(2, "RNG_test: ", 10);
    _ = write(2, message.ptr, message.len);
    _ = write(2, "\n", 1);
    exit(1);
}
fn eq(a: []const u8, other: []const u8) bool {
    return std.mem.eql(u8, a, other);
}
const Length = union(enum) { blocks: u64, seconds: f64 };
fn length(text: []const u8, target: builtin_rngs.Target) !Length {
    @setFloatMode(.strict);
    if (text.len == 0 or !std.ascii.isDigit(text[0])) return error.InvalidLength;
    var end: usize = 0;
    var value: f64 = 0;
    while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) value = value * 10 + s.f(text[end] - '0');
    if (end < text.len and text[end] == '.') {
        end += 1;
        // Preserve 0.96's digit-by-digit rounding before unit scaling and
        // whole-block truncation, including the boundary behavior in UB051.
        var place: f64 = 0.1;
        while (end < text.len and std.ascii.isDigit(text[end])) : ({
            end += 1;
            place *= 0.1;
        }) value += s.f(text[end] - '0') * place;
    }
    const suffix = text[end..];
    var amount: f64 = undefined;
    if (suffix.len == 1) {
        if (std.mem.indexOfScalar(u8, "smhd", suffix[0])) |unit| {
            const multipliers = [_]f64{ 1, 60, 3600, 86400 };
            const seconds = @max(0.05, value) * multipliers[unit];
            if (!std.math.isFinite(seconds)) return error.InvalidLength;
            return .{ .seconds = seconds };
        }
    }
    if (suffix.len == 0) amount = s.pow(2, value) else {
        if (suffix.len > 2 or (suffix.len == 2 and suffix[1] != 'B')) return error.InvalidLength;
        const unit = std.mem.indexOfScalar(u8, "KMGTP", suffix[0]) orelse return error.InvalidLength;
        amount = value * s.pow(1024, s.f(unit + 1));
    }
    // Each seed or entropy string yields eight bytes. An explicit B suffix
    // always denotes bytes, independently of the selected target.
    if (target != .output and !std.mem.endsWith(u8, suffix, "B")) amount *= 8;
    if (!std.math.isFinite(amount) or amount < 1024 or amount >= s.pow(2, 64)) return error.InvalidLength;
    return .{ .blocks = @as(u64, @intFromFloat(amount)) / 1024 };
}

test "length parsing preserves original decimal rounding and target units" {
    // Original CLI captures: UB051 and .work/departure-audit/length-summary.json.
    try std.testing.expectEqual(Length{ .blocks = 1026 }, try length("1.0029296875M", .output));
    try std.testing.expectEqual(Length{ .blocks = 1027 }, try length("1.00390625M", .output));
    try std.testing.expectEqual(Length{ .blocks = 1027 }, try length("1027K", .output));
    for ([_]builtin_rngs.Target{ .{ .seeding = .{ .bits = 64 } }, .entropy }) |target| {
        try std.testing.expectEqual(Length{ .blocks = 8215 }, try length("1.0029296875M", target));
        try std.testing.expectEqual(Length{ .blocks = 1026 }, try length("1.0029296875MB", target));
        try std.testing.expectEqual(Length{ .blocks = 8 }, try length("10", target));
    }
    try std.testing.expectEqual(Length{ .blocks = 1024 }, try length("1.M", .output));
    try std.testing.expectEqual(Length{ .seconds = 3.0000000000000004 }, try length("0.05m", .output));
    for ([_][]const u8{ "", ".5M", "1..M", "1.2.3M", "1sB" }) |text| try std.testing.expectError(error.InvalidLength, length(text, .output));
}
const Action = enum { minimum, maximum, show };
const Event = struct { at: Length, action: Action };
fn event(events: *std.ArrayList(Event), a: A, at: Length, action: Action) !void {
    for (events.items) |*e| {
        if (std.meta.eql(at, e.at)) {
            e.action = action;
            return;
        }
    }
    try events.append(a, .{ .at = at, .action = action });
}
fn show(streams: *stream_module.Streams, allocator: A, rng: []const u8, seed: []const u8, elapsed: f64, filter: report.Filter, executor: ?*@import("worker_pool.zig").Pool, target: builtin_rngs.Target) !bool {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const results = try streams.checkpoint(a, executor);
    return report.checkpoint(a, results, rng, seed, streams.blocks(), elapsed, filter, switch (target) {
        .output => .bytes,
        .seeding => .seeds,
        .entropy => .entropy_strings,
    });
}
fn usage() void {
    _ = printf("usage: RNG_test RNG_EXPRESSION|stdin[8|16|32|64] [options]\n" ++
        "  Inputs: file[8|16|32|64](PATH), stdin[8|16|32|64], built-in RNGs\n" ++
        "  Input sources can be nested in transforms, e.g. As8(file64(PATH)).\n" ++
        "  -te 0|1                core (default) or expanded battery\n" ++
        "  -tf 0|1|2              none, standard, or extra folding (default 1)\n" ++
        "  -tlmin/-tlmax LENGTH   minimum/maximum test length\n" ++
        "  -tlshow LENGTH         additional checkpoint (repeatable)\n" ++
        "  LENGTH: log2 bytes, KB/MB/GB/TB/PB, or s/m/h/d\n" ++
        "  -a | -e EXPECTED | -p THRESHOLD   report filtering\n" ++
        "  -table_narrow | -table_wide | -table_scoring   report layout (default: narrow)\n" ++
        "  -tlfail | -tlmaxonly   stop on failure (default) or only at limit\n" ++
        "  -seed HEX              128-bit hexadecimal seed (unseedable input: report label)\n" ++
        "  -ttnormal | -ttseed[BITS]   output or seeding test (omitted/0: autodetect)\n" ++
        "  Original walk accepts nonnegative widths as in 0.96; Gray walks: 16..128.\n" ++
        "  -ttep                  entropy pooling test (57-byte entropy strings)\n" ++
        "  --seed-walk original|gray|balanced-gray   default: original\n" ++
        "  Seed/entropy tests: bare lengths/K/M/... count seeds/strings; KB/MB/... count bytes.\n" ++
        "  --full-precision      append round-trip raw, p-value and suspicion values\n" ++
        "  --reference-compatible  PractRand 0.96 results with documented corrections\n" ++
        "  -multithreaded | -singlethreaded   parallel (default) or serial\n" ++
        "  -gpu | --gpu          Metal/Vulkan alongside CPU workers (requires -te 1)\n" ++
        "  --list_recommended_rngs | --list_reference_rngs | --list-rngs\n" ++
        "  -do_metatest | -no_metatest   experimental checkpoint summary (default: off)\n" ++
        "  -no_selftest\n" ++
        "Defaults: core, standard folding, minimum 2 seconds, maximum 32 TiB.\n" ++
        "This is rewrite " ++ version ++ ", implementing a subset of PractRand 0.96.\n");
}
fn listGenerators(command: []const u8) void {
    if (eq(command, "--list-rngs")) {
        for (0..builtin_rngs.pr_rng_factory_count()) |i| {
            const name = builtin_rngs.pr_rng_factory_name(i).?;
            const text = std.mem.span(name);
            const removed = std.mem.startsWith(u8, text, "xsm") or std.mem.startsWith(u8, text, "rarns");
            _ = printf("%s%s\n", name, if (removed) @as([*:0]const u8, " (no longer supported)") else @as([*:0]const u8, ""));
        }
        return;
    }
    const recommended = eq(command, "--list_recommended_rngs");
    var group: c_uint = if (recommended) 0 else 1;
    const end: c_uint = if (recommended) 1 else 6;
    while (group < end) : (group += 1) {
        _ = printf("%s = {\n", builtin_rngs.pr_rng_catalog_label(group).?);
        var i: usize = 0;
        while (builtin_rngs.pr_rng_catalog_name(group, i)) |name| : (i += 1) {
            if (i % 4 == 0) _ = printf("      ");
            _ = printf("%s", name);
            if (builtin_rngs.pr_rng_catalog_name(group, i + 1) != null) {
                _ = printf(",");
                if (i % 4 != 3) _ = printf("%*s", @as(c_int, 17) - @as(c_int, @intCast(std.mem.len(name))), @as([*:0]const u8, "")) else _ = printf("\n");
            } else _ = printf("\n");
        }
        _ = printf("}\n");
    }
    if (!recommended) _ = printf("... and nonrecommended_rngs includes all of the above, in order\n");
}

pub fn main(init: std.process.Init.Minimal) !void {
    run(init) catch |err| {
        if (err == error.InputExhausted) {
            _ = write(2, "error reading from file\n", 24);
        } else fail(@errorName(err));
    };
    report.flush() catch |err| fail(@errorName(err));
}
fn run(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const rng = args.next() orelse {
        usage();
        return;
    };
    if (eq(rng, "--help") or eq(rng, "-help") or eq(rng, "-h") or eq(rng, "--h")) {
        usage();
        return;
    }
    if (eq(rng, "--version") or eq(rng, "-version") or eq(rng, "--v") or eq(rng, "-v")) {
        _ = printf("practrand-zig " ++ version ++ " (reference PractRand 0.96)\n");
        return;
    }
    if (eq(rng, "--list_recommended_rngs") or eq(rng, "--list_reference_rngs") or eq(rng, "--list-rngs")) {
        listGenerators(rng);
        return;
    }
    const stdin_input = eq(rng, "stdin") or eq(rng, "stdin8") or eq(rng, "stdin16") or eq(rng, "stdin32") or eq(rng, "stdin64");
    var width: u7 = if (eq(rng, "stdin8")) 8 else if (eq(rng, "stdin16")) 16 else if (eq(rng, "stdin32")) 32 else if (eq(rng, "stdin64")) 64 else 0;
    var folding: u8 = 1;
    var expanded = false;
    var threaded = true;
    var use_gpu = false;
    var reference_compatible = false;
    var filter = report.Filter{};
    var end_on_failure = true;
    var minimum = Length{ .seconds = 2 };
    var maximum = Length{ .blocks = 1 << 35 };
    var seed: []const u8 = "unknown";
    var seed_set = false;
    var target: builtin_rngs.Target = .output;
    var seed_walk: @import("seed_testing.zig").Mode = .original;
    var seed_walk_set = false;
    var events: std.ArrayList(Event) = .empty;
    var lengths: std.ArrayList(struct { action: Action, text: []const u8 }) = .empty;
    while (args.next()) |arg| {
        if (eq(arg, "-table_narrow") or eq(arg, "-table_wide") or eq(arg, "-table_scoring")) {
            filter.table = if (eq(arg, "-table_narrow")) .narrow else if (eq(arg, "-table_wide")) .wide else .scoring;
            continue;
        }
        if (eq(arg, "--full-precision")) {
            filter.full_precision = true;
            continue;
        }
        if (eq(arg, "--reference-compatible")) {
            reference_compatible = true;
            continue;
        }
        if (eq(arg, "-gpu") or eq(arg, "--gpu")) {
            use_gpu = true;
            continue;
        }
        if (eq(arg, "-a")) {
            filter.smart = false;
            filter.threshold = 1;
            continue;
        }
        if (eq(arg, "-singlethreaded") or eq(arg, "-multithreaded")) {
            threaded = eq(arg, "-multithreaded");
            continue;
        }
        if (eq(arg, "-ttnormal")) {
            target = .output;
            continue;
        }
        if (eq(arg, "-ttep")) {
            target = .entropy;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-ttseed")) {
            // Preserve the native CLI's atoi conversion and negative-only
            // rejection, independently of its stricter expression factory.
            const bits = atoi(arg[7..].ptr);
            if (bits < 0) fail("-ttseed### - bits negative?");
            target = .{ .seeding = .{ .bits = @intCast(bits) } };
            continue;
        }
        if (eq(arg, "--seed-walk")) {
            const value = args.next() orelse fail("--seed-walk requires original, gray or balanced-gray");
            seed_walk = if (eq(value, "original")) .original else if (eq(value, "gray")) .gray else if (eq(value, "balanced-gray")) .balanced_gray else fail("--seed-walk requires original, gray or balanced-gray");
            seed_walk_set = true;
            continue;
        }
        if (eq(arg, "-do_metatest") or eq(arg, "-no_metatest")) {
            filter.metatest = eq(arg, "-do_metatest");
            continue;
        }
        if (eq(arg, "-no_selftest") or eq(arg, "-skip_selftest")) continue;
        if (eq(arg, "-tlfail") or eq(arg, "-tlmaxonly")) {
            end_on_failure = eq(arg, "-tlfail");
            continue;
        }
        if (eq(arg, "-tf") or eq(arg, "-te") or eq(arg, "-e") or eq(arg, "-p") or eq(arg, "-seed") or eq(arg, "-tlmin") or eq(arg, "-tlmax") or eq(arg, "-tlshow")) {
            const value = args.next() orelse fail(try std.fmt.allocPrint(a, "{s} requires a value", .{arg}));
            if (eq(arg, "-tf")) {
                if (eq(value, "0")) folding = 0 else if (eq(value, "1")) folding = 1 else if (eq(value, "2")) folding = 2 else fail("unsupported folding; use -tf 0, -tf 1, or -tf 2");
            } else if (eq(arg, "-te")) {
                if (eq(value, "0")) expanded = false else if (eq(value, "1")) expanded = true else fail("unsupported battery; use -te 0 or -te 1");
            } else if (eq(arg, "-seed")) {
                seed = value;
                seed_set = true;
            } else if (eq(arg, "-e") or eq(arg, "-p")) {
                const threshold = std.fmt.parseFloat(f64, value) catch fail(try std.fmt.allocPrint(a, "invalid report threshold for {s}: {s}", .{ arg, value }));
                const smart = eq(arg, "-e");
                if (!std.math.isFinite(threshold) or threshold < (if (smart) @as(f64, 0.000001) else 1e-10) or threshold > (if (smart) @as(f64, 1000) else 1)) fail(try std.fmt.allocPrint(a, "invalid report threshold for {s}: {s}", .{ arg, value }));
                filter.smart = smart;
                filter.threshold = threshold;
            } else {
                try lengths.append(a, .{ .action = if (eq(arg, "-tlmin")) .minimum else if (eq(arg, "-tlmax")) .maximum else .show, .text = value });
            }
        } else fail(try std.fmt.allocPrint(a, "unsupported option: {s}", .{arg}));
    }
    if (target == .seeding) target.seeding.mode = seed_walk else if (seed_walk_set) fail("--seed-walk requires -ttseed[BITS]");
    if (stdin_input and target == .seeding) fail("seed testing requires a seedable RNG, not stdin");
    if (stdin_input and target == .entropy) fail("entropy testing requires an RNG supporting entropy accumulation, not stdin");
    for (lengths.items) |item| {
        const point = length(item.text, target) catch fail(try std.fmt.allocPrint(a, "invalid test length: {s}", .{item.text}));
        switch (item.action) {
            .minimum => minimum = point,
            .maximum => maximum = point,
            .show => try event(&events, a, point, .show),
        }
    }
    if (use_gpu and !expanded) fail("-gpu requires the Expanded battery (-te 1)");
    var diagnostic: [1024]u8 = @splat(0);
    var generator: ?builtin_rngs.Generator = null;
    if (!stdin_input) {
        generator = builtin_rngs.Generator.initTarget(a, rng, if (seed_set) seed else null, target, &diagnostic) catch |err| {
            if (err == error.InvalidGenerator or err == error.GeneratorFailed) fail(try std.fmt.allocPrint(a, "{s}: {s}", .{ rng, std.mem.sliceTo(&diagnostic, 0) }));
            if (err == error.InvalidSeed) fail(try std.fmt.allocPrint(a, "invalid 128-bit hexadecimal seed for {s}: {s}", .{ rng, seed }));
            return err;
        };
        width = generator.?.width;
        seed = generator.?.seed;
        if (diagnostic[0] != 0) _ = printf("warning: %.*s\n", @as(c_int, @intCast(std.mem.sliceTo(&diagnostic, 0).len)), &diagnostic);
    }
    defer if (generator) |*source| source.deinit();
    const rng_name = if (generator) |source| source.name else try std.fmt.allocPrint(a, "RNG_{s}", .{rng});
    try event(&events, a, minimum, .minimum);
    try event(&events, a, maximum, .maximum);
    // Deterministic modes make exactly one pass. Bound prefetch as well as
    // counting so the reader cannot request seeds beyond the final cycle.
    var input_limit = switch (maximum) {
        .blocks => |n| n *| 1024,
        .seconds => std.math.maxInt(u64),
    };
    if (target == .seeding) {
        const config = target.seeding;
        const bits = generator.?.seed_bits;
        if (config.mode != .original and bits <= 60) {
            const cycle_bytes = @as(u64, 1) << @intCast(bits + 3);
            input_limit = @min(input_limit, cycle_bytes);
            try event(&events, a, .{ .blocks = cycle_bytes / 1024 }, .maximum);
        }
    }
    const start = now();
    var gpu_executor: Gpu = undefined;
    if (use_gpu) try gpu_executor.init(a, @import("expanded.zig").maximum_transform_input_bytes, null);
    defer if (use_gpu) gpu_executor.deinit();
    var streams = try stream_module.Streams.init(a, width, folding, expanded, if (reference_compatible) .reference else .improved);
    defer streams.deinit();
    streams.gpu = if (use_gpu) &gpu_executor else null;
    const folding_names = [_][*:0]const u8{ "none", "standard", "extra" };
    _ = printf("RNG_test using PractRand-compatible tests (rewrite " ++ version ++ "; reference 0.96)\nRNG = %.*s, seed = %.*s\ntest set = %s, folding = %s", @as(c_int, @intCast(rng_name.len)), rng_name.ptr, @as(c_int, @intCast(seed.len)), seed.ptr, if (expanded) @as([*:0]const u8, "expanded") else "core", folding_names[folding]);
    if (folding == 1) {
        if (width == 0) _ = printf("(unknown format)") else _ = printf(" (%d bit)", @as(c_int, width));
    }
    _ = printf("\n");
    if (target == .seeding) _ = printf("seed walk = %s, bits = %u\n", @as([*:0]const u8, switch (target.seeding.mode) {
        .original => "original",
        .gray => "gray",
        .balanced_gray => "balanced-gray",
    }), generator.?.seed_bits);
    // Counting is shared; the selected result policy reaches every scoring job.
    if (reference_compatible) _ = printf("results = reference-compatible (PractRand 0.96; documented corrections)\n");
    if (use_gpu) _ = printf("GPU = %s, alongside CPU counting\n", @as([*:0]const u8, &gpu_executor.device_name));
    _ = printf("\n");
    var pool: @import("worker_pool.zig").Pool = undefined;
    if (threaded) {
        if (use_gpu and gpu_executor.supports_counts and gpu_executor.hasCountPair()) {
            try pool.initWithLimit(streams.top_streams * @import("expanded.zig").family_count);
        } else if (use_gpu) try pool.initForGpu() else try pool.init();
    }
    defer if (threaded) pool.deinit();
    const executor: ?*@import("worker_pool.zig").Pool = if (threaded) &pool else null;
    var buffer: []u8 = try a.alignedAlloc(u8, .fromByteUnits(16 << 10), if (expanded and threaded) expanded_parallel_input_bytes else input_buffer_bytes);
    // Generated prefetch cannot cancel a blocked stream nested in a transform.
    // Read such expressions on the caller, keeping shutdown bounded.
    const prefetch_input = expanded and threaded and use_gpu and (generator == null or !generator.?.stream_input);
    var reader: @import("input_reader.zig").Reader = undefined;
    if (prefetch_input) {
        const double_prefetch = gpu_executor.fpf_add != null and (generator == null or gpu_executor.fpf_add_pair == null);
        const capacity = if (double_prefetch) 2 * buffer.len else buffer.len;
        if (generator) |*source| {
            try reader.initGenerated(.{ .context = source, .fill = GeneratedInput.fill }, input_limit, capacity);
        } else try reader.init(0, input_limit, capacity);
    }
    defer if (prefetch_input) reader.deinit();
    const overlap_input = expanded and threaded and !use_gpu;
    var alternate = if (overlap_input) try a.alloc(u8, buffer.len) else buffer;
    var feeder: Service = undefined;
    if (overlap_input) try feeder.init();
    defer if (overlap_input) feeder.deinit();
    var input_job = InputJob{ .streams = &streams, .executor = executor };
    var input_request: Service.Request = .{};
    var power: u64 = 1;
    var showing_powers = false;
    var elapsed: f64 = 0;
    while (true) {
        const blocks = streams.blocks();
        var show_now = false;
        var finished = false;
        var i: usize = 0;
        while (i < events.items.len) {
            const e = events.items[i];
            const due = switch (e.at) {
                .blocks => |n| blocks >= n,
                .seconds => |n| elapsed >= n,
            };
            if (!due) {
                i += 1;
                continue;
            }
            showing_powers = showing_powers or e.action == .minimum;
            show_now = show_now or e.action != .minimum or e.at == .blocks;
            finished = finished or e.action == .maximum;
            _ = events.swapRemove(i);
        }
        // Events at the same tested prefix share one report, independent of ordering.
        show_now = show_now or (blocks == power and showing_powers);
        if (show_now and blocks != 0) {
            if (try show(&streams, allocator, rng_name, seed, elapsed, filter, executor, target) and end_on_failure) return;
        }
        if (finished) return;
        if (blocks == power) {
            if (power > std.math.maxInt(u64) / 2) return;
            power *= 2;
        }
        var step: u64 = @min(power - blocks, maximum_step_blocks);
        for (events.items) |e| switch (e.at) {
            .blocks => |n| {
                if (n > blocks) step = @min(step, n - blocks);
            },
            else => {},
        };
        var left = step;
        while (left != 0) {
            const n: usize = @intCast(@min(left, buffer.len / 1024) * 1024);
            var used: usize = 0;
            if (prefetch_input) {
                used = reader.readInto(buffer[0..n]) catch {
                    if (generator != null) fail(std.mem.sliceTo(&reader.diagnostic, 0));
                    fail("error reading from standard input");
                };
                if (used < n) {
                    _ = write(2, "error reading from file\n", 24);
                    return;
                }
            } else if (generator) |*source| {
                source.fill(buffer[0..n], &diagnostic) catch |err| {
                    if (overlap_input) try feeder.wait(&input_request);
                    if (err == error.InputExhausted) return err;
                    fail(std.mem.sliceTo(&diagnostic, 0));
                };
                used = n;
            } else {
                while (used < n) {
                    const got = read(0, buffer[used..n].ptr, n - used);
                    if (got < 0) {
                        if (overlap_input) try feeder.wait(&input_request);
                        fail("error reading from standard input");
                    }
                    if (got == 0) {
                        if (overlap_input) try feeder.wait(&input_request);
                        _ = write(2, "error reading from file\n", 24);
                        return;
                    }
                    used += @intCast(got);
                }
            }
            if (overlap_input) {
                try feeder.wait(&input_request);
                input_job.bytes = buffer[0..n];
                input_request = Service.Request.init(.{ .context = &input_job, .run = InputJob.run });
                feeder.start(&input_request);
                std.mem.swap([]u8, &buffer, &alternate);
                left -= n / 1024;
                continue;
            }
            try streams.update(buffer[0..n], executor);
            left -= n / 1024;
        }
        if (overlap_input) try feeder.wait(&input_request);
        elapsed = now() - start;
    }
}

// The reader is joined before the borrowed generator is destroyed. Diagnostic
// errors are published with the failed input, rather than with speculative fills.
const GeneratedInput = struct {
    fn fill(raw: *anyopaque, output: []u8, diagnostic: *[1024]u8) !void {
        const source: *builtin_rngs.Generator = @ptrCast(@alignCast(raw));
        try source.fill(output, diagnostic);
    }
};

// The caller reads the next buffer while this service owns the current logical
// update. Both updates and checkpoint flushes remain ordered, and the outer
// step is drained before the clock or checkpoint state is observed.
const InputJob = struct {
    streams: *stream_module.Streams,
    executor: ?*@import("worker_pool.zig").Pool,
    bytes: []const u8 = &.{},
    fn run(raw: *anyopaque) !void {
        const job: *InputJob = @ptrCast(@alignCast(raw));
        try job.streams.update(job.bytes, job.executor);
    }
};

test "input counting service joins ordered buffers and publishes update failures" {
    const Pool = @import("worker_pool.zig").Pool;
    var pool: Pool = undefined;
    try pool.init();
    defer pool.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var expected = try stream_module.Streams.init(a, 16, 0, false, .improved);
    defer expected.deinit();
    var actual = try stream_module.Streams.init(a, 16, 0, false, .improved);
    defer actual.deinit();
    var feeder: Service = undefined;
    try feeder.init();
    defer feeder.deinit();
    var bytes: [16 * 1024]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0xf11e);
    var job = InputJob{ .streams = &actual, .executor = &pool, .bytes = &bytes };
    var request: Service.Request = .{};
    for (0..3) |_| {
        random.random().bytes(&bytes);
        try expected.update(&bytes, null);
        request = Service.Request.init(.{ .context = &job, .run = InputJob.run });
        feeder.start(&request);
        try feeder.wait(&request);
        try std.testing.expectEqual(expected.blocks(), actual.blocks());
        try std.testing.expectEqualSlices(u64, expected.items[0].battery.core.histograms, actual.items[0].battery.core.histograms);
    }
    var failed = try stream_module.Streams.init(a, 16, 0, false, .improved);
    defer failed.deinit();
    const birthday = &failed.items[0].battery.core.birthday;
    birthday.buffer.deinit(birthday.allocator);
    birthday.buffer = .empty;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    birthday.allocator = failing.allocator();
    var failed_feeder: Service = undefined;
    try failed_feeder.init();
    defer failed_feeder.deinit();
    var failed_job = InputJob{ .streams = &failed, .executor = &pool, .bytes = &bytes };
    var failed_request = Service.Request.init(.{ .context = &failed_job, .run = InputJob.run });
    failed_feeder.start(&failed_request);
    try std.testing.expectError(error.OutOfMemory, failed_feeder.wait(&failed_request));
    try std.testing.expect(failed_request.completed and failed_feeder.head == null and failed_feeder.running == null);
}
