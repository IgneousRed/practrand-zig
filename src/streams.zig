const std = @import("std");
const b = @import("battery.zig");
const expanded_suite = @import("expanded.zig");
const suite = @import("suite.zig");
const Pool = @import("worker_pool.zig").Pool;
const Job = @import("worker_pool.zig").Job;
const folded_buffer_bytes = 1 << 20;
const A = std.mem.Allocator;
const Arithmetic = @import("statistics.zig").Arithmetic;

pub fn folds(width: u7, folding: u8) []const [2]u7 {
    return switch (folding) {
        0 => &.{},
        1 => switch (width) {
            8 => &.{.{ 1, 8 }},
            16 => &.{ .{ 4, 16 }, .{ 1, 16 } },
            32 => &.{ .{ 8, 32 }, .{ 1, 32 } },
            64 => &.{ .{ 16, 64 }, .{ 4, 64 }, .{ 1, 64 } },
            else => &.{ .{ 1, 8 }, .{ 4, 32 }, .{ 1, 32 } },
        },
        2 => &.{ .{ 1, 8 }, .{ 1, 16 }, .{ 1, 32 }, .{ 1, 64 }, .{ 4, 16 }, .{ 4, 32 }, .{ 4, 64 }, .{ 8, 32 }, .{ 8, 64 } },
        else => unreachable,
    };
}

const Stream = struct {
    battery: suite.Battery,
    child: ?usize = null,
    keep: u7 = 0,
    width: u7 = 0,
    prefix: []const u8 = "",
    buffer: []u8,
    used: usize = 0,
    fn init(a: A, keep: u7, width: u7, expanded: bool, tables: *const b.Tables) !Stream {
        const buffer: []u8 = if (keep == 0) &.{} else try a.alignedAlloc(u8, .fromByteUnits(16 << 10), if (expanded) 2 * expanded_suite.transform_flush_bytes + 1024 else folded_buffer_bytes);
        const prefix = if (keep == 0) "" else try std.fmt.allocPrint(a, "[Low{d}/{d}]", .{ keep, width });
        return .{ .battery = try suite.Battery.init(a, expanded, tables), .buffer = buffer, .keep = keep, .width = width, .prefix = prefix };
    }
};
// Results are reconstructible and have a separate lifetime from counting state.
const ScoreCache = struct {
    blocks: u64 = 0,
    items: []const b.Result = &.{},
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    fn score(cache: *ScoreCache, stream: *const Stream, models: *const b.Models, tables: *const b.Tables, arithmetic: Arithmetic) !void {
        if (stream.battery.blocks() == cache.blocks) return;
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        var fresh = b.Results{ .allocator = scratch.allocator(), .prefix = stream.prefix, .models = models, .tables = tables, .arithmetic = arithmetic };
        try stream.battery.results(&fresh);
        try cache.publish(fresh.items.items, stream.battery.blocks());
    }
    // Publish compact output only after scoring and copying have succeeded.
    fn publish(cache: *ScoreCache, results: []const b.Result, blocks: u64) !void {
        var arena = std.heap.ArenaAllocator.init(cache.arena.child_allocator);
        errdefer arena.deinit();
        const items = try arena.allocator().dupe(b.Result, results);
        for (items) |*item| item.name = try arena.allocator().dupe(u8, item.name);
        cache.arena.deinit();
        cache.* = .{ .arena = arena, .items = items, .blocks = blocks };
    }
};
const ScoreJob = struct {
    stream: *Stream,
    cache: *ScoreCache,
    models: *const b.Models,
    tables: *const b.Tables,
    arithmetic: Arithmetic,
    fn run(raw: *anyopaque) !void {
        const job: *ScoreJob = @ptrCast(@alignCast(raw));
        job.stream.battery.prepareCheckpoint();
        try job.cache.score(job.stream, job.models, job.tables, job.arithmetic);
    }
};

// Stream records use indexes for nested transforms; the worker pool is supplied per operation.
// The allocator owns stream storage and buffers for the run; deinit releases independent resources.
pub const Streams = struct {
    items: []Stream = &.{},
    caches: []ScoreCache = &.{},
    top_streams: usize = 0,
    tables: b.Tables = .{},
    arithmetic: Arithmetic = .improved,
    distributions: b.DistributionCache = .{},
    gpu: ?*@import("gpu.zig").Executor = null,
    pub fn init(a: A, width: u7, folding: u8, expanded: bool, arithmetic: Arithmetic) !Streams {
        const parameters = folds(width, folding);
        const tables = try b.Tables.init(a, expanded, arithmetic);
        var streams: std.ArrayList(Stream) = .empty;
        errdefer for (streams.items) |*stream| stream.battery.deinit();
        try streams.ensureTotalCapacity(a, parameters.len + 1);
        streams.appendAssumeCapacity(try Stream.init(a, 0, 0, expanded, &tables));
        for (parameters) |parameter| streams.appendAssumeCapacity(try Stream.init(a, parameter[0], parameter[1], expanded, &tables));
        // Expanded preserves upstream's nested transform calls as well as prefixes.
        if (expanded and folding == 1) switch (width) {
            0 => {
                streams.items[2].child = 3;
                streams.items[3].width = 4;
            },
            16 => {
                streams.items[1].child = 2;
                streams.items[2].width = 4;
            },
            32 => {
                streams.items[1].child = 2;
                streams.items[2].width = 8;
            },
            64 => {
                streams.items[1].child = 2;
                streams.items[2].keep = 4;
                streams.items[2].width = 16;
                streams.items[2].child = 3;
                streams.items[3].width = 4;
            },
            else => {},
        };
        const top_streams = if (expanded and folding == 1) (if (width == 0) @as(usize, 3) else 2) else streams.items.len;
        const caches = try a.alloc(ScoreCache, streams.items.len);
        @memset(caches, .{});
        return .{ .items = streams.items, .caches = caches, .top_streams = top_streams, .tables = tables, .arithmetic = arithmetic };
    }
    pub fn deinit(streams: *Streams) void {
        streams.distributions.deinit();
        for (streams.items, streams.caches) |*stream, *cache| {
            cache.arena.deinit();
            stream.battery.deinit();
        }
    }
    pub fn blocks(streams: *const Streams) u64 {
        return if (streams.items.len == 0) 0 else streams.items[0].battery.blocks();
    }
    pub fn update(streams: *Streams, bytes: []const u8, executor: ?*Pool) !void {
        if (executor != null and streams.top_streams > 1 and streams.items[0].battery == .expanded) {
            var contexts: [folds(0, 2).len + 1]StreamJob = undefined;
            var jobs: [folds(0, 2).len + 1]Job = undefined;
            for (0..streams.top_streams) |index| {
                contexts[index] = .{ .streams = streams, .index = index, .bytes = bytes, .executor = executor.? };
                jobs[index] = .{ .context = &contexts[index], .run = StreamJob.run };
            }
            try executor.?.run(jobs[0..streams.top_streams]);
        } else for (0..streams.top_streams) |index| try streams.updateStream(index, bytes, executor);
    }
    fn feedBattery(streams: *Streams, index: usize, bytes: []const u8, executor: ?*Pool) anyerror!void {
        const t = &streams.items[index];
        try t.battery.update(bytes, executor, streams.gpu);
        if (t.child) |child| try streams.updateStream(child, bytes, executor);
    }
    fn flush(streams: *Streams, index: usize, executor: ?*Pool) !void {
        const t = &streams.items[index];
        const full = t.used / 1024 * 1024;
        if (full == 0) return;
        try streams.feedBattery(index, t.buffer[0..full], executor);
        std.mem.copyForwards(u8, t.buffer[0 .. t.used - full], t.buffer[full..t.used]);
        t.used -= full;
    }
    fn updateStream(streams: *Streams, index: usize, bytes: []const u8, executor: ?*Pool) !void {
        const t = &streams.items[index];
        if (t.keep == 0) return streams.feedBattery(index, bytes, executor);
        inline for (.{ .{ 1, 4 }, .{ 1, 8 }, .{ 1, 16 }, .{ 1, 32 }, .{ 1, 64 }, .{ 4, 16 }, .{ 4, 32 }, .{ 4, 64 }, .{ 8, 32 }, .{ 8, 64 }, .{ 16, 64 } }) |parameters| {
            if (t.keep == parameters[0] and t.width == parameters[1]) {
                var offset: usize = 0;
                while (offset < bytes.len) {
                    const n = @min(bytes.len - offset, if (t.battery == .expanded) expanded_suite.maximum_transform_input_bytes else bytes.len);
                    try streams.fold(index, parameters[0], parameters[1], bytes[offset..][0..n], executor);
                    offset += n;
                }
                return;
            }
        }
        unreachable;
    }
    fn fold(streams: *Streams, index: usize, comptime keep: u7, comptime width: u7, bytes: []const u8, executor: ?*Pool) !void {
        const t = &streams.items[index];
        if (width == 4) {
            var offset: usize = 0;
            while (offset < bytes.len) : (offset += 4) {
                var value: u8 = 0;
                inline for (0..4) |j| {
                    value |= (bytes[offset + j] & 1) << (j * 2);
                    value |= ((bytes[offset + j] >> 4) & 1) << (j * 2 + 1);
                }
                t.buffer[t.used] = value;
                t.used += 1;
            }
            if (t.used >= expanded_suite.transform_flush_bytes) try streams.flush(index, executor);
            return;
        }
        const stride: usize = width / 8;
        var offset: usize = 0;
        const mask: u8 = if (keep < 8) (@as(u8, 1) << @intCast(keep)) - 1 else 0;
        while (offset < bytes.len) {
            const inputs = @min((t.buffer.len - t.used) * 8 / keep, (bytes.len - offset) / stride);
            const end = offset + inputs * stride;
            while (offset < end) {
                if (keep >= 8) {
                    const n: usize = keep / 8;
                    @memcpy(t.buffer[t.used..][0..n], bytes[offset..][0..n]);
                    t.used += n;
                    offset += stride;
                } else {
                    var value: u8 = 0;
                    var bits: u4 = 0;
                    while (bits < 8) : (bits += @intCast(keep)) {
                        value |= (bytes[offset] & mask) << @intCast(bits);
                        offset += stride;
                    }
                    t.buffer[t.used] = value;
                    t.used += 1;
                }
            }
            if (t.used == t.buffer.len) {
                try streams.feedBattery(index, t.buffer, executor);
                t.used = 0;
            }
        }
        if (t.used >= (if (t.battery == .expanded) expanded_suite.transform_flush_bytes else 1024))
            try streams.flush(index, executor);
    }
    // The caller owns checkpoint scratch; cached result names live in per-stream arenas.
    pub fn checkpoint(streams: *Streams, a: A, executor: ?*Pool) ![]const b.Result {
        if (streams.items.len == 0) return &.{};
        for (0..streams.items.len) |index| try streams.flush(index, executor);
        streams.distributions.beginCheckpoint();
        for (streams.items, streams.caches) |*stream, cache| {
            if (stream.battery == .expanded and stream.battery.blocks() != cache.blocks)
                try streams.distributions.prepareExpanded(stream.battery.blocks(), &streams.tables);
        }
        const batteries = try a.alloc(*const b.Battery, streams.items.len);
        var model_count: usize = 0;
        for (streams.items, streams.caches) |*stream, cache| {
            if (stream.battery.blocks() != cache.blocks and stream.battery == .core) {
                batteries[model_count] = &stream.battery.core;
                model_count += 1;
            }
        }
        var models = try b.Models.init(a, batteries[0..model_count], &streams.tables);
        if (streams.items[0].battery == .expanded) models.distributions = &streams.distributions;
        const contexts = try a.alloc(ScoreJob, streams.items.len);
        const jobs = try a.alloc(Job, streams.items.len);
        var n: usize = 0;
        for (streams.items, streams.caches) |*stream, *cache| {
            if (stream.battery.blocks() == cache.blocks) continue;
            contexts[n] = .{ .stream = stream, .cache = cache, .models = &models, .tables = &streams.tables, .arithmetic = streams.arithmetic };
            jobs[n] = .{ .context = &contexts[n], .run = ScoreJob.run };
            n += 1;
        }
        if (executor) |pool| try pool.run(jobs[0..n]) else for (jobs[0..n]) |task| try task.run(task.context);
        var results: std.ArrayList(b.Result) = .empty;
        for (streams.caches) |cache| try results.appendSlice(a, cache.items);
        return results.items;
    }
};

test "an empty stream owner can be queried and released" {
    var streams = Streams{};
    defer streams.deinit();
    var pool: Pool = undefined;
    try pool.init();
    defer pool.deinit();
    try streams.update(&.{}, null);
    try streams.update(&.{}, &pool);
    try std.testing.expectEqual(@as(u64, 0), streams.blocks());
    try std.testing.expectEqual(@as(usize, 0), (try streams.checkpoint(std.testing.allocator, null)).len);
}

test "cache publication copies names and preserves the previous result on allocation failure" {
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var cache = ScoreCache{ .arena = .init(allocator.allocator()) };
    defer cache.arena.deinit();
    var name = [_]u8{ 'b', 'e', 'f', 'o', 'r', 'e' };
    var result = b.Result{ .name = &name, .raw = 0, .value = 0.5, .kind = .good_p, .weight = 1 };
    try cache.publish(&.{result}, 1);
    @memset(&name, 'x');
    try std.testing.expectEqualStrings("before", cache.items[0].name);
    allocator.fail_index = allocator.alloc_index;
    result.name = "after";
    try std.testing.expectError(error.OutOfMemory, cache.publish(&.{result}, 2));
    try std.testing.expectEqual(@as(u64, 1), cache.blocks);
    try std.testing.expectEqualStrings("before", cache.items[0].name);
    allocator.fail_index = std.math.maxInt(usize);
    try cache.publish(&.{result}, 2);
    try std.testing.expectEqual(@as(u64, 2), cache.blocks);
    try std.testing.expectEqualStrings("after", cache.items[0].name);
}

const StreamJob = struct {
    streams: *Streams,
    index: usize,
    bytes: []const u8,
    executor: *Pool,
    fn run(raw: *anyopaque) !void {
        const job: *StreamJob = @ptrCast(@alignCast(raw));
        try job.streams.updateStream(job.index, job.bytes, job.executor);
    }
};

test "parallel stream updates preserve the serial call history and checkpoint state" {
    const Oracle = struct {
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
            inline for (.{ "size", "step", "loaded", "wait", "count", "score", "score_low", "last_size" }) |name| try std.testing.expectEqualDeep(@field(lm, name), @field(rm, name));
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
        fn streams(left: *const Streams, right: *const Streams) !void {
            for (left.items, right.items) |ls, rs| {
                try std.testing.expectEqual(ls.used, rs.used);
                try std.testing.expectEqualSlices(u8, ls.buffer[0..ls.used], rs.buffer[0..rs.used]);
                switch (ls.battery) {
                    .core => |battery_left| try battery(battery_left, rs.battery.core),
                    .expanded => |battery_left| try battery(battery_left, rs.battery.expanded),
                }
            }
        }
    };
    var executor: Pool = undefined;
    try executor.init();
    defer executor.deinit();
    const cases = [_]struct { width: u7, folding: u8, expanded: bool }{
        .{ .width = 16, .folding = 2, .expanded = true },
        .{ .width = 64, .folding = 1, .expanded = true },
        .{ .width = 32, .folding = 1, .expanded = false },
    };
    var input: [32 * 1024]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0x51ea);
    random.random().bytes(&input);
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var serial = try Streams.init(allocator, case.width, case.folding, case.expanded, .improved);
        defer serial.deinit();
        var parallel = try Streams.init(allocator, case.width, case.folding, case.expanded, .improved);
        defer parallel.deinit();
        for (0..2) |_| {
            for ([_]usize{ 1, 3, 17, 32 }) |blocks_count| {
                try serial.update(input[0 .. blocks_count * 1024], null);
                try parallel.update(input[0 .. blocks_count * 1024], &executor);
            }
            try Oracle.streams(&serial, &parallel);
            const expected = try serial.checkpoint(allocator, null);
            const actual = try parallel.checkpoint(allocator, &executor);
            try std.testing.expectEqualDeep(expected, actual);
            try Oracle.streams(&serial, &parallel);
        }
    }
}
