// Explicit hardware checks: built only by -Dvulkan=true; no software fallback.
const std = @import("std");
const Gpu = @import("gpu.zig").Executor;
const TieBits = @import("classification.zig").TieBits;
const cpu = @import("classification.zig");
const workers = @import("worker_pool.zig");
const library = if (@import("gpu_options").native_fpf) @import("gpu_options").native_fpf_library else if (@import("builtin").os.tag == .macos) "@rpath/libpractrand_vulkan.dylib" else "libpractrand_vulkan.so";
const ClassifyJob = struct {
    gpu: *Gpu,
    random: *TieBits,
    input: []const u8,
    output: []u8,
    fn run(raw: *anyopaque) !void {
        const job: *@This() = @ptrCast(@alignCast(raw));
        try job.gpu.classify(job.random, job.input, job.output);
    }
};

test "paired counters preserve both histories through input reuse and library fallbacks" {
    const b = @import("battery.zig");
    const M = b.Modulo3(0);
    const D = b.Distribution(9, 0, true);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var device: Gpu = undefined;
    try device.init(a, 1 << 20, library);
    defer device.deinit();
    if (!@import("gpu_options").native_fpf) try std.testing.expect(device.hasCountPair());
    const pair = device.pair_dispatch;
    const extended = device.extended_mod3;
    const input = try a.alloc(u8, 3 << 20);
    const left_m = try a.alloc(u64, M.count_bins);
    const right_m = try a.alloc(u64, M.count_bins);
    const left_d = try a.alloc(u64, D.count_bins);
    const right_d = try a.alloc(u64, D.count_bins);
    const left_odd = try a.alloc(u64, D.count_bins);
    const right_odd = try a.alloc(u64, D.count_bins);
    const Work = struct {
        mod3: *M,
        dc7: *D,
        bytes: []const u8,
        device: *Gpu,
        fn run(raw: *anyopaque) !void {
            const w: *@This() = @ptrCast(@alignCast(raw));
            try b.gpuCounters(w.mod3, w.dc7, w.bytes, w.device);
        }
    };
    for (0..4) |fixture| {
        for ([_][]u64{ left_m, right_m, left_d, right_d, left_odd, right_odd }) |counts| {
            @memset(counts, 0);
            counts[0] = (1 << 40) + 17;
        }
        var expected_m = M{ .counts = left_m };
        var actual_m = M{ .counts = right_m };
        var expected_d = D{ .counts = left_d, .odd_counts = left_odd };
        var actual_d = D{ .counts = right_d, .odd_counts = right_odd };
        for ([_]usize{ 1024, 5 * 1024, (1 << 20) + 1024, 3 << 20 }, 0..) |len, call| {
            // Reuse the same address with changed contents; pointer identity is
            // never permission to reuse uploaded bytes from an earlier call.
            var rng = std.Random.DefaultPrng.init(0xc097 + call);
            if (fixture == 0) rng.random().bytes(input) else @memset(input, (if (fixture == 1) @as(u8, 0) else if (fixture == 2) @as(u8, 255) else @as(u8, 0x55)) ^ @as(u8, @intCast(call)));
            device.pair_dispatch = if (call == 1) null else pair;
            device.extended_mod3 = if (call == 2) null else extended;
            if (call == 0) {
                // DC7 may enter offload with an odd CPU history independently
                // of the Mod3 state in the same bounded submission.
                expected_d.update(input[0..1]);
                actual_d.update(input[0..1]);
            }
            expected_m.update(input[0..len]);
            expected_d.update(input[0..len]);
            var work = Work{ .mod3 = &actual_m, .dc7 = &actual_d, .bytes = input[0..len], .device = &device };
            var request = Gpu.Request.init(.{ .context = &work, .run = Work.run });
            device.start(&request);
            try device.wait(&request);
            try std.testing.expectEqualDeep(expected_m, actual_m);
            try std.testing.expectEqualDeep(expected_d, actual_d);
        }
    }
}

test "GPU C8 matches CPU bytes and exact RNG progress across tails and reused batches" {
    const a = std.testing.allocator;
    const capacity = 2 << 20;
    var device: Gpu = undefined;
    try device.init(a, capacity, library);
    defer device.deinit();
    const input = try a.alloc(u8, capacity + 16);
    defer a.free(input);
    const output = try a.alloc(u8, capacity / 16 + 64);
    defer a.free(output);
    const expected = try a.alloc(u8, capacity / 16);
    defer a.free(expected);
    for (0..4) |fixture| {
        var generator = std.Random.DefaultPrng.init(0xc8c8);
        if (fixture == 0) generator.random().bytes(input) else @memset(input, if (fixture == 1) 0 else if (fixture == 2) 255 else 0x55);
        for ([_]u64{ 0, 1, std.math.maxInt(u64) }) |seed| {
            for ([_]usize{ 0, 1, 7, 15 }) |alignment| {
                var reference = TieBits.init(seed);
                var actual = reference;
                for ([_]usize{ 0, 32, 64, 96, 1024, 65536, 65568, 1 << 20, capacity }) |len| {
                    const bytes = input[alignment..][0..len];
                    cpu.classify(&reference, bytes, expected[0 .. len / 16]);
                    @memset(output, 0xa5);
                    const begin = 16 + alignment;
                    var job = ClassifyJob{ .gpu = &device, .random = &actual, .input = bytes, .output = output[begin..][0 .. len / 16] };
                    var request = Gpu.Request.init(.{ .context = &job, .run = ClassifyJob.run });
                    device.start(&request);
                    try device.wait(&request);
                    try std.testing.expectEqualSlices(u8, expected[0 .. len / 16], output[begin..][0 .. len / 16]);
                    try std.testing.expectEqualDeep(reference, actual);
                    for (output[0..begin]) |guard| try std.testing.expectEqual(@as(u8, 0xa5), guard);
                    for (output[begin + len / 16 ..]) |guard| try std.testing.expectEqual(@as(u8, 0xa5), guard);
                    // Leave a partial tie word before the next GPU call. This
                    // crosses every byte position, including half-word refills.
                    cpu.classify(&reference, bytes.ptr[0..16], expected[0..1]);
                    cpu.classify(&actual, bytes.ptr[0..16], output[0..1]);
                    try std.testing.expectEqual(expected[0], output[0]);
                    try std.testing.expectEqualDeep(reference, actual);
                }
            }
        }
    }
}

test "GPU service and CPU pool progress independently and join failures before reuse" {
    const Gate = struct {
        mutex: std.c.pthread_mutex_t = .{},
        changed: std.c.pthread_cond_t = .{},
        ready: bool = false,
        released: bool = false,
        cpu_ran: bool = false,
        fn gpu(raw: *anyopaque) !void {
            const gate: *@This() = @ptrCast(@alignCast(raw));
            _ = std.c.pthread_mutex_lock(&gate.mutex);
            defer _ = std.c.pthread_mutex_unlock(&gate.mutex);
            gate.ready = true;
            _ = std.c.pthread_cond_broadcast(&gate.changed);
            while (!gate.released) _ = std.c.pthread_cond_wait(&gate.changed, &gate.mutex);
            return error.ExpectedGpuJobFailure;
        }
        fn cpu(raw: *anyopaque) !void {
            const gate: *@This() = @ptrCast(@alignCast(raw));
            _ = std.c.pthread_mutex_lock(&gate.mutex);
            defer _ = std.c.pthread_mutex_unlock(&gate.mutex);
            while (!gate.ready) _ = std.c.pthread_cond_wait(&gate.changed, &gate.mutex);
            gate.cpu_ran = true;
            gate.released = true;
            _ = std.c.pthread_cond_broadcast(&gate.changed);
        }
    };
    var device: Gpu = undefined;
    try device.init(std.testing.allocator, 1024, library);
    defer device.deinit();
    var pool: workers.Pool = undefined;
    try pool.initForGpu();
    defer pool.deinit();
    var gate = Gate{};
    defer _ = std.c.pthread_cond_destroy(&gate.changed);
    defer _ = std.c.pthread_mutex_destroy(&gate.mutex);
    var request = Gpu.Request.init(.{ .context = &gate, .run = Gate.gpu });
    device.start(&request);
    try pool.run(&.{ .{ .context = &gate, .run = Gate.cpu }, .{ .context = &gate, .run = Gate.cpu } });
    try std.testing.expectError(error.ExpectedGpuJobFailure, device.wait(&request));
    try std.testing.expect(gate.cpu_ran);
    const input: [1024]u8 = @splat(0x55);
    var output: [64]u8 = undefined;
    var expected: [64]u8 = undefined;
    var actual = TieBits.init(42);
    var reference = actual;
    cpu.classify(&reference, &input, &expected);
    var job = ClassifyJob{ .gpu = &device, .random = &actual, .input = &input, .output = &output };
    var reuse_request = Gpu.Request.init(.{ .context = &job, .run = ClassifyJob.run });
    device.start(&reuse_request);
    try device.wait(&reuse_request);
    try std.testing.expectEqualSlices(u8, &expected, &output);
    try std.testing.expectEqualDeep(reference, actual);
}

test "queued GPU requests retain independent failures and borrowed storage" {
    const Context = struct {
        gpu: *Gpu,
        input: [1024]u8 = @splat(0x55),
        output: [64]u8 = undefined,
        random: TieBits = TieBits.init(13),
        fail: bool = false,
        calls: usize = 0,
        fn run(raw: *anyopaque) !void {
            const c: *@This() = @ptrCast(@alignCast(raw));
            try c.gpu.classify(&c.random, &c.input, &c.output);
            c.calls += 1;
            if (c.fail) return error.ExpectedQueuedFailure;
        }
    };
    var device: Gpu = undefined;
    try device.init(std.testing.allocator, 1024, library);
    defer device.deinit();
    var contexts: [8]Context = @splat(.{ .gpu = &device });
    var requests: [8]Gpu.Request = undefined;
    contexts[3].fail = true;
    for (&contexts, &requests) |*context, *request| {
        request.* = Gpu.Request.init(.{ .context = context, .run = Context.run });
        device.start(request);
    }
    for (&contexts, &requests, 0..) |*context, *request, i| {
        if (i == 3) try std.testing.expectError(error.ExpectedQueuedFailure, device.wait(request)) else try device.wait(request);
        var random = TieBits.init(13);
        var expected: [64]u8 = undefined;
        cpu.classify(&random, &context.input, &expected);
        try std.testing.expectEqualSlices(u8, &expected, &context.output);
        try std.testing.expectEqualDeep(random, context.random);
        try std.testing.expectEqual(@as(usize, 1), context.calls);
    }
    contexts[3].fail = false;
    requests[3] = Gpu.Request.init(.{ .context = &contexts[3], .run = Context.run });
    device.start(&requests[3]);
    try device.wait(&requests[3]);
    try std.testing.expectEqual(@as(usize, 2), contexts[3].calls);
}

test "GPU counter deltas and rolling state match CPU through splits and fallback" {
    const b = @import("battery.zig");
    var device: Gpu = undefined;
    try device.init(std.testing.allocator, 1 << 20, library);
    defer device.deinit();
    const extension = device.extended_mod3;
    try std.testing.expectEqual(@as(usize, 9), device.mod3Layers());
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = try a.alloc(u8, 3 << 20);
    inline for (.{ 0, 2 }) |kind| {
        const T = switch (kind) {
            0 => b.Modulo3(0),
            2 => b.Distribution(9, 0, true),
            else => unreachable,
        };
        const Work = struct {
            state: *T,
            gpu: *Gpu,
            bytes: []const u8,
            fn run(raw: *anyopaque) !void {
                const w: *@This() = @ptrCast(@alignCast(raw));
                switch (kind) {
                    0 => try b.gpuMod3(w.state, w.bytes, w.gpu),
                    2 => try b.gpuDc7(w.state, w.bytes, w.gpu),
                    else => unreachable,
                }
            }
        };
        const left_counts = try a.alloc(u64, T.count_bins);
        const right_counts = try a.alloc(u64, T.count_bins);
        const left_odd = if (kind == 2) try a.alloc(u64, T.count_bins) else &.{};
        const right_odd = if (kind == 2) try a.alloc(u64, T.count_bins) else &.{};
        // Exercise both the optional layout and the unchanged version-11
        // entry point with the same backend, including CPU/GPU transitions.
        for (0..(if (kind == 0) @as(usize, 8) else 4)) |case| {
            const fixture = case % 4;
            device.extended_mod3 = if (case < 4) extension else null;
            var random = std.Random.DefaultPrng.init(0xc017);
            if (fixture == 0) random.random().bytes(input) else @memset(input, if (fixture == 1) 0 else if (fixture == 2) 255 else 0x55);
            @memset(left_counts, 0);
            @memset(right_counts, 0);
            left_counts[0] = (1 << 32) + 123;
            right_counts[0] = left_counts[0];
            var left = T{ .counts = left_counts };
            var right = T{ .counts = right_counts };
            if (kind == 2) {
                @memset(left_odd, 0);
                @memset(right_odd, 0);
                left_odd[0] = (1 << 32) + 17;
                right_odd[0] = left_odd[0];
                left.odd_counts = left_odd;
                right.odd_counts = right_odd;
            }
            for ([_]usize{ 1024, 5 * 1024, (1 << 20) + 1024, 0, 7 * 1024, 3 << 20 }, 0..) |len, call| {
                if (len != 0) left.update(input[0..len]);
                if (call == 1 or call == 4) right.update(input[0..len]) else {
                    var work = Work{ .state = &right, .gpu = &device, .bytes = input[0..len] };
                    const job = workers.Job{ .context = &work, .run = Work.run };
                    var request = Gpu.Request.init(job);
                    device.start(&request);
                    try device.wait(&request);
                }
                if (kind == 2) {
                    for (0..T.count_bins) |bin| {
                        try std.testing.expectEqual(left.countAt(false, bin), right.countAt(false, bin));
                        try std.testing.expectEqual(left.countAt(true, bin), right.countAt(true, bin));
                    }
                } else try std.testing.expectEqualSlices(u64, left_counts, right_counts);
                if (kind == 2) {
                    try std.testing.expectEqual(left.index, right.index);
                    try std.testing.expectEqual(left.warmup, right.warmup);
                    try std.testing.expectEqual(left.odd, right.odd);
                } else if (kind == 3) {
                    try std.testing.expectEqualDeep(left.tail, right.tail);
                    try std.testing.expectEqual(left.started, right.started);
                } else {
                    try std.testing.expectEqualDeep(left.index, right.index);
                    try std.testing.expectEqualDeep(left.warmup, right.warmup);
                    try std.testing.expectEqualDeep(left.odd, right.odd);
                    try std.testing.expectEqualDeep(left.saved, right.saved);
                    if (kind == 0) {
                        try std.testing.expectEqual(left.phase, right.phase);
                        try std.testing.expectEqual(left.scale, right.scale);
                        try std.testing.expectEqual(left.total_on, right.total_on);
                    }
                }
            }
        }
    }
}

comptime {
    _ = @import("input_reader.zig");
}

const FullGpuStateOracle = struct {
    fn battery(left: anytype, right: @TypeOf(left)) !void {
        try std.testing.expectEqual(left.blocks, right.blocks);
        try std.testing.expectEqualSlices(u64, left.histograms, right.histograms);
        inline for (.{ "bcfn", "mod3", "gap", "tmf", "pat", "fpf", "fpf64", "fpf32", "fpf16", "fpf4", "perm64", "perm32", "weighted64", "weighted32" }) |name| {
            if (@hasField(@TypeOf(left), name)) try std.testing.expectEqualDeep(@field(left, name), @field(right, name));
        }
        inline for (.{ "dc6", "dc7", "dc7_16", "dc7_32" }) |name| {
            if (@hasField(@TypeOf(left), name)) {
                const l = @field(left, name);
                const r = @field(right, name);
                try std.testing.expectEqual(l.index, r.index);
                try std.testing.expectEqual(l.warmup, r.warmup);
                try std.testing.expectEqualDeep(l.odd, r.odd);
            }
        }
        const lb = left.birthday;
        const rb = right.birthday;
        try std.testing.expectEqualSlices(u64, lb.buffer.items, rb.buffer.items);
        inline for (.{ "skip", "flushes", "bits", "filter_bits", "lambda", "duplicates", "old_lambda", "old_duplicates" }) |name| try std.testing.expectEqualDeep(@field(lb, name), @field(rb, name));
        const lm = left.brank;
        const rm = right.brank;
        inline for (.{ "size", "step", "loaded", "wait", "count", "score", "last_size" }) |name| try std.testing.expectEqualDeep(@field(lm, name), @field(rm, name));
        try std.testing.expectEqualSlices(u64, lm.matrix[0 .. lm.loaded / 8], rm.matrix[0 .. rm.loaded / 8]);
        if (@hasField(@TypeOf(left), "classified")) {
            const lc = left.classified;
            const rc = right.classified;
            try std.testing.expectEqualDeep(lc.random, rc.random);
            try std.testing.expectEqual(lc.used, rc.used);
            try std.testing.expectEqualSlices(u8, lc.buffer[0..lc.used], rc.buffer[0..rc.used]);
            inline for (.{ "bcfn", "dc8", "dc16", "dc32", "fpf", "gap", "mod3", "tmf" }) |name| try std.testing.expectEqualDeep(@field(lc, name), @field(rc, name));
            try std.testing.expectEqualDeep(left.near.previous, right.near.previous);
            try std.testing.expectEqual(left.near.started, right.near.started);
            for (left.near.sizes, right.near.sizes) |ls, rs| {
                try std.testing.expectEqual(ls.threshold, rs.threshold);
                try std.testing.expectEqual(ls.count, rs.count);
                try std.testing.expectEqualSlices(u32, ls.core_hw[0..ls.count], rs.core_hw[0..rs.count]);
                try std.testing.expectEqualSlices(u32, ls.both_hw[0..ls.count], rs.both_hw[0..rs.count]);
                const words = ls.before.len / 2048;
                try std.testing.expectEqualSlices(u64, ls.before[0 .. ls.count * words], rs.before[0 .. rs.count * words]);
                try std.testing.expectEqualSlices(u64, ls.after[0 .. ls.count * words], rs.after[0 .. rs.count * words]);
                try std.testing.expectEqualDeep(ls.old.items, rs.old.items);
            }
        }
    }
};

test "GPU and CPU preserve complete battery state across original128MiB calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Streams = @import("streams.zig").Streams;
    var expected = try Streams.init(a, 16, 0, true, .improved);
    defer expected.deinit();
    var actual = try Streams.init(a, 16, 0, true, .improved);
    defer actual.deinit();
    var device: Gpu = undefined;
    try device.init(a, 16 << 20, library);
    defer device.deinit();
    actual.gpu = &device;
    var pool: workers.Pool = undefined;
    try pool.initForGpu();
    defer pool.deinit();
    const input = try a.alloc(u8, 128 << 20);
    var random = std.Random.DefaultPrng.init(0x42c801);
    random.random().bytes(input);
    // The repeated halfword keeps its FPF/16 alignment on both sides of a
    // GPU batch boundary. Break the run immediately before the next batch.
    const boundary = @min(device.fpf_capacity, input.len / 2);
    const pattern = input[boundary - 64 .. boundary + 64];
    for (0..pattern.len / 4) |i| {
        const value: u32 = if (i == 15) 0x1234abcd else 0x12341234;
        std.mem.writeInt(u32, pattern[4 * i ..][0..4], value, .little);
    }
    if (!@import("gpu_options").native_fpf) try std.testing.expect(device.fpf_add_pair != null);
    for (0..2) |call| {
        // Start FPF/16 on the paired path, then continue its history on CPU.
        if (call == 1) device.fpf_add_pair = null;
        try expected.update(input, &pool);
        try actual.update(input, &pool);
        try FullGpuStateOracle.battery(expected.items[0].battery.expanded, actual.items[0].battery.expanded);
    }
}

const FpfChecks = struct {
    test "independent FPF requests merge under their lease and recover failed calls" {
        const b = @import("battery.zig");
        const T = b.FloatingPattern(2);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var device: Gpu = undefined;
        try device.init(a, 1 << 20, library);
        defer device.deinit();
        var pool: workers.Pool = undefined;
        try pool.initForGpu();
        defer pool.deinit();
        try std.testing.expect(device.fpf_capacity > device.capacity);
        const input = try a.alloc(u8, 9 << 20);
        var rng = std.Random.DefaultPrng.init(0xff4401);
        rng.random().bytes(input);
        const Work = struct {
            device: *Gpu,
            state: T,
            bytes: []const u8,
            fn run(raw: *anyopaque) !void {
                const w: *@This() = @ptrCast(@alignCast(raw));
                for ([_]usize{ 1024, (1 << 20) + 1024, 3 << 20 }) |n| try b.gpuFpfParallel(&w.state, w.bytes[0..n], w.device);
            }
        };
        var contexts: [3]Work = undefined;
        var jobs: [3]workers.Job = undefined;
        var references: [3]T = undefined;
        for (&contexts, &jobs, &references, 0..) |*w, *job, *reference, i| {
            const bytes = input[i * (3 << 20) ..][0 .. 3 << 20];
            const counts = try a.alloc(u64, T.count_bins);
            @memset(counts, (1 << 40) + 13 + i);
            const expected = try a.dupe(u64, counts);
            reference.* = .{ .counts = expected };
            w.* = .{ .device = &device, .state = .{ .counts = counts }, .bytes = bytes };
            job.* = .{ .context = w, .run = Work.run };
            if (i != 0) {
                reference.update(bytes[0 .. i * 1024]);
                w.state.update(bytes[0 .. i * 1024]);
            }
            for ([_]usize{ 1024, (1 << 20) + 1024, 3 << 20 }) |n| reference.update(bytes[0..n]);
        }
        var message: [512:0]u8 = @splat(0);
        const tail: [8]u8 = @splat(0);
        try std.testing.expect(device.fpf_add.?(device.context, input.ptr, 1, &tail, 0, contexts[0].state.counts.ptr, &message, message.len) != 0);
        try pool.run(&jobs);
        references[0].update(input);
        try b.gpuFpfParallel(&contexts[0].state, input, &device);
        for (contexts, references) |w, reference| {
            try std.testing.expectEqualSlices(u64, reference.counts, w.state.counts);
            try std.testing.expectEqualDeep(reference.tail, w.state.tail);
            try std.testing.expectEqual(reference.started, w.state.started);
        }
    }
};
comptime {
    _ = FpfChecks;
}

test "FPF preserves every exponent including constant and rare windows" {
    const T = @import("battery.zig").FloatingPattern(2);
    const a = std.testing.allocator;
    var device: Gpu = undefined;
    try device.init(a, 1024, library);
    defer device.deinit();
    const actual = try a.alloc(u64, T.count_bins);
    defer a.free(actual);
    const expected = try a.alloc(u64, T.count_bins);
    defer a.free(expected);
    var input: [1024]u8 = undefined;
    for (0..54) |fixture| {
        const word: u64 = if (fixture == 52) 0 else if (fixture == 53) ~@as(u64, 0) else @as(u64, 1) << @intCast(fixture);
        for (0..input.len / 8) |i| std.mem.writeInt(u64, input[i * 8 ..][0..8], word, .little);
        @memset(actual, (1 << 40) + 17);
        @memset(expected, (1 << 40) + 17);
        var left = T{ .counts = expected };
        var right = T{ .counts = actual };
        for (0..2) |_| {
            left.update(&input);
            try @import("battery.zig").gpuFpfParallel(&right, &input, &device);
        }
        try std.testing.expectEqualSlices(u64, expected, actual);
        try std.testing.expectEqualDeep(left.tail, right.tail);
        try std.testing.expectEqual(left.started, right.started);
    }
}
