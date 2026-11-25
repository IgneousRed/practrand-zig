// NearSeq3 from PractRand 0.96 (CC0); see LICENSES/PractRand.txt.
const std = @import("std");
const b = @import("battery.zig");
const s = @import("statistics.zig");
const sample_capacity = 2048;
const size_count = 7;
const tightening_fraction = 0.5;
const A = std.mem.Allocator;

pub const Model = struct {
    arithmetic: s.Arithmetic,
    distribution: s.Hamming,
    mean: f64,
    scale: f64,
    fn init(a: A, bits: usize, arithmetic: s.Arithmetic) !Model {
        return switch (arithmetic) {
            .improved => initWith(.improved, a, bits),
            .reference => initWith(.reference, a, bits),
        };
    }
    fn initWith(comptime arithmetic: s.Arithmetic, a: A, bits: usize) !Model {
        const distribution = try s.Hamming.init(a, bits, arithmetic);
        const midpoint = bits / 2;
        var mean = s.Accumulator(arithmetic){};
        for (distribution.pdf, 0..) |p, i| {
            const score = if (p != 0) distribution.score(i) else 0;
            if (i == midpoint) mean.scale(2);
            mean.add(score * p);
        }
        var variance = s.Accumulator(arithmetic){};
        for (distribution.pdf, 0..) |p, i| {
            const score = if (p != 0) distribution.score(i) - mean.value() else 0;
            if (i == midpoint) variance.scale(2);
            variance.add(score * score * p);
        }
        return .{ .distribution = distribution, .arithmetic = arithmetic, .mean = mean.value(), .scale = 1 / @sqrt(variance.value()) };
    }
};
const Score = struct {
    count: usize = 0,
    pairs: usize = 0,
    core: f64 = 0,
    both: f64 = 0,
    distance: f64 = 0,
};
fn above(weight: u32, threshold: i32) bool {
    return threshold < 0 or weight > @as(u32, @intCast(threshold));
}
const Size = struct {
    threshold: i32,
    count: usize = 0,
    core_hw: []u32,
    both_hw: []u32,
    before: []u64,
    after: []u64,
    old: std.ArrayList(Score) = .empty,
    const Scored = struct { score: Score, threshold: i32 };
    fn score(t: Size, model: Model, double: Model, filter: bool) !Scored {
        return switch (model.arithmetic) {
            .improved => t.scoreWith(.improved, model, double, filter),
            .reference => t.scoreWith(.reference, model, double, filter),
        };
    }
    fn scoreWith(t: Size, comptime arithmetic: s.Arithmetic, model: Model, double: Model, filter: bool) !Scored {
        const distribution = model.distribution;
        var next = t.threshold - 1;
        while (next >= 0) : (next -= 1) {
            if (distribution.cdf[@intCast(next)] <= tightening_fraction * distribution.cdf[@intCast(t.threshold)]) break;
        }
        if (filter and next < 0) return error.NearSeqThresholdBelowZero;
        const cutoff = if (filter) next else -1;
        var result = Score{};
        var core = s.Accumulator(arithmetic){};
        var both = s.Accumulator(arithmetic){};
        var distance_sum = s.Accumulator(arithmetic){};
        for (0..t.count) |i| {
            if (!above(t.core_hw[i], cutoff)) continue;
            both.add(double.distribution.score(t.both_hw[i]) - double.mean);
            result.count += 1;
        }
        result.both = both.value() * double.scale;
        // Upstream stores filter_rate in an integer, so its CDF contribution is zero.
        const inverse = if (arithmetic == .reference) 1 / distribution.cdf[@intCast(t.threshold)] else 0;
        const start: usize = @intCast(cutoff + 1);
        const end: usize = @intCast(t.threshold + 1);
        var conditional: [(64 << (size_count - 1)) / 2 + 1]f64 = undefined;
        if (arithmetic == .improved) distribution.conditionalPdf(conditional[0..end]);
        var biased_mean = s.Accumulator(arithmetic){};
        for (start..end) |i| {
            const p = if (arithmetic == .reference) distribution.pdf[i] * inverse else conditional[i];
            const value = if (p != 0) distribution.score(i) else 0;
            biased_mean.add(value * p);
        }
        var variance = s.Accumulator(arithmetic){};
        for (start..end) |i| {
            const p = if (arithmetic == .reference) distribution.pdf[i] * inverse else conditional[i];
            const value = if (p != 0) distribution.score(i) - biased_mean.value() else 0;
            variance.add(value * value * p);
        }
        for (0..t.count) |i| {
            // The current-threshold score also excludes this next-threshold subset.
            if (!above(t.core_hw[i], next)) continue;
            core.add(distribution.score(t.core_hw[i]) - biased_mean.value());
        }
        result.core = core.value() * (1 / @sqrt(variance.value() * s.f(t.count)));
        const words = t.before.len / sample_capacity;
        result.pairs = switch (words) {
            inline 1, 2, 4, 8, 16, 32, 64 => |n| t.distanceScore(arithmetic, n, double, cutoff, &distance_sum),
            else => unreachable,
        };
        result.distance = distance_sum.value() * double.scale;
        return .{ .score = result, .threshold = next };
    }
    fn distanceScore(t: Size, comptime arithmetic: s.Arithmetic, comptime words: usize, double: Model, cutoff: i32, distance_sum: *s.Accumulator(arithmetic)) usize {
        var pairs: usize = 0;
        for (0..t.count) |i| {
            if (!above(t.core_hw[i], cutoff)) continue;
            for (0..i) |j| {
                if (!above(t.core_hw[j], cutoff)) continue;
                var distance: usize = 0;
                for (0..words) |k| {
                    distance += @popCount(t.before[i * words + k] ^ t.before[j * words + k]);
                    distance += @popCount(t.after[i * words + k] ^ t.after[j * words + k]);
                }
                distance_sum.add(double.distribution.score(distance) - double.mean);
                pairs += 1;
            }
        }
        return pairs;
    }
    fn tighten(t: *Size, model: Model, double: Model) !void {
        const scored = try t.score(model, double, true);
        try t.old.append(std.heap.page_allocator, scored.score);
        const words = t.before.len / sample_capacity;
        var kept: usize = 0;
        for (0..t.count) |i| {
            if (above(t.core_hw[i], scored.threshold)) continue;
            if (kept != i) {
                @memcpy(t.before[kept * words ..][0..words], t.before[i * words ..][0..words]);
                @memcpy(t.after[kept * words ..][0..words], t.after[i * words ..][0..words]);
                t.core_hw[kept] = t.core_hw[i];
                t.both_hw[kept] = t.both_hw[i];
            }
            kept += 1;
        }
        if (@import("builtin").is_test and scored.score.count != t.count - kept) @panic("tightening must account for every removed sample");
        t.count = kept;
        t.threshold = scored.threshold;
    }
    fn sample(t: *Size, weight: u32, window: []const u64, position: usize, model: Model, double: Model) !void {
        while (t.count >= sample_capacity) try t.tighten(model, double);
        const words = t.before.len / sample_capacity;
        const before = t.before[t.count * words ..][0..words];
        const after = t.after[t.count * words ..][0..words];
        @memcpy(before, window[position - words ..][0..words]);
        @memcpy(after, window[position + words ..][0..words]);
        var combined: u32 = 0;
        for (before, after) |pre, post| combined += @as(u32, @popCount(pre)) + @popCount(post);
        t.core_hw[t.count] = weight;
        t.both_hw[t.count] = combined;
        t.count += 1;
    }
};

pub const NearSeq3 = struct {
    sizes: [size_count]Size,
    models: []const Model,
    previous: [128]u64 = @splat(0),
    started: bool = false,
    pub fn prepareModels(a: A, arithmetic: s.Arithmetic) ![]const Model {
        const models = try a.alloc(Model, size_count + 1);
        for (models, 0..) |*model, i| model.* = try Model.init(a, @as(usize, 64) << @intCast(i), arithmetic);
        return models;
    }
    // Samples live in the run arena; old scores grow independently and are released by deinit.
    pub fn init(a: A, models: []const Model) !NearSeq3 {
        var t: NearSeq3 = .{ .sizes = undefined, .models = models };
        for (&t.sizes, 0..) |*size, i| {
            const words = @as(usize, 1) << @intCast(i);
            const threshold = s.f(words * 32) - @sqrt(64 + s.f(i) * 24) * s.pow(2, s.f(i) * 0.5);
            size.* = .{ .threshold = @intFromFloat(threshold), .core_hw = try a.alloc(u32, sample_capacity), .both_hw = try a.alloc(u32, sample_capacity), .before = try a.alloc(u64, sample_capacity * words), .after = try a.alloc(u64, sample_capacity * words) };
        }
        return t;
    }
    pub fn deinit(t: *NearSeq3) void {
        for (&t.sizes) |*size| size.old.deinit(std.heap.page_allocator);
    }
    pub fn update(t: *NearSeq3, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) : (offset += 1024) {
            const block = bytes[offset..][0..1024];
            if (!t.started) {
                @memcpy(std.mem.sliceAsBytes(&t.previous), block);
                t.started = true;
                continue;
            }
            var window: [256]u64 = undefined;
            @memcpy(window[0..128], &t.previous);
            @memcpy(std.mem.sliceAsBytes(window[128..256]), block);
            var weights: [128]u32 = undefined;
            for (&weights, window[64..192]) |*weight, value| weight.* = @popCount(value);
            // Each size sees the same ordered samples as upstream's interleaved tree.
            inline for (&t.sizes, 0..) |*size, level| {
                const words = @as(usize, 1) << @intCast(level);
                const n = weights.len / words;
                for (weights[0..n], 0..) |weight, i| {
                    const eligible = if (level < 5) !above(weight, size.threshold) else weight < @as(u32, @intCast(size.threshold));
                    if (eligible) try size.sample(weight, &window, 64 + i * words, t.models[level], t.models[level + 1]);
                }
                if (level + 1 < size_count) for (0..n / 2) |i| {
                    weights[i] = weights[i * 2] + weights[i * 2 + 1];
                };
            }
            @memcpy(&t.previous, window[128..256]);
        }
    }
    pub fn results(t: NearSeq3, blocks: u64, r: *b.Results) !void {
        switch (r.arithmetic) {
            .improved => try t.resultsWith(.improved, blocks, r),
            .reference => try t.resultsWith(.reference, blocks, r),
        }
    }
    fn resultsWith(t: NearSeq3, comptime arithmetic: s.Arithmetic, blocks: u64, r: *b.Results) !void {
        if (blocks < 2) return;
        const step = s.pow(tightening_fraction, 1.5);
        for (t.sizes, 0..) |size, level| {
            var core = s.Accumulator(arithmetic){};
            var both = s.Accumulator(arithmetic){};
            var distance = s.Accumulator(arithmetic){};
            var hw_variance = s.Accumulator(arithmetic){};
            var pd_variance = s.Accumulator(arithmetic){};
            for (0..size.old.items.len + 1) |i| {
                const data = if (i < size.old.items.len) size.old.items[i] else (try size.score(t.models[level], t.models[level + 1], false)).score;
                hw_variance.scale(step * step);
                core.scale(step);
                both.scale(step);
                pd_variance.scale(step * step);
                distance.scale(step);
                hw_variance.add(s.f(data.count));
                core.add(data.core);
                both.add(data.both);
                pd_variance.add(s.f(data.pairs));
                distance.add(data.distance);
            }
            if (hw_variance.value() == 0) continue;
            const scale = 1 / @sqrt(hw_variance.value());
            core.scale(scale);
            both.scale(scale);
            const denominator = @sqrt(1 + s.f(level));
            try r.add(try r.formatName("NS3[{d}:hw:core]", .{level}), core.value(), -s.normalSuspicion(core.value(), r.arithmetic), .bad_s, 0.2 / denominator);
            try r.add(try r.formatName("NS3[{d}:hw:both]", .{level}), both.value(), -s.normalSuspicion(both.value(), r.arithmetic), .bad_s, 0.5 / denominator);
            try r.add(try r.formatName("NS3[{d}:hw:all-]", .{level}), (both.value() + 0.5 * core.value()) / @sqrt(@as(f64, 1.25)), -s.normalSuspicion(both.value() + 0.5 * core.value(), r.arithmetic) / @sqrt(@as(f64, 1.25)), .bad_s, 0.2 / denominator);
            if (pd_variance.value() == 0) continue;
            distance.scale(1 / @sqrt(pd_variance.value()));
            try r.add(try r.formatName("NS3[{d}:pd:both]", .{level}), distance.value(), -s.normalSuspicion(distance.value(), r.arithmetic), .bad_s, 1 / denominator);
        }
    }
};

test "NearSeq model moments agree with exact binomial Decimal controls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Exact binomial(8, 1/2) probabilities and their lower CDF, evaluated with
    // 110-digit Decimal logarithms and the existing mirrored-score convention.
    const model = try Model.init(arena.allocator(), 8, .improved);
    try std.testing.expectApproxEqRel(@as(f64, 1.2421280162174761), model.mean, 2e-15);
    try std.testing.expectApproxEqRel(@as(f64, 1.1780090634645073), model.scale, 2e-15);
}

test "NearSeq sample and pair scores retain finite underflowed Hamming tails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before = try a.alloc(u64, sample_capacity * 64);
    const after = try a.alloc(u64, sample_capacity * 64);
    @memset(before, 0);
    @memset(after, 0);
    var core = [_]u32{ 2010, 2010 };
    var both = [_]u32{ 0, 0 };
    const size = Size{ .threshold = 1900, .count = 2, .core_hw = &core, .both_hw = &both, .before = before, .after = after };
    const improved = (try size.score(try Model.init(a, 4096, .improved), try Model.init(a, 8192, .improved), false)).score;
    const reference = (try size.score(try Model.init(a, 4096, .reference), try Model.init(a, 8192, .reference), false)).score;
    try std.testing.expect(std.math.isFinite(improved.both) and improved.both > 1000);
    try std.testing.expect(std.math.isFinite(improved.distance) and improved.distance > 1000);
    try std.testing.expectEqual(std.math.inf(f64), reference.both);
    try std.testing.expectEqual(std.math.inf(f64), reference.distance);
    try std.testing.expectEqual(reference.count, improved.count);
    try std.testing.expectEqual(reference.pairs, improved.pairs);
}

test "NearSeq conditional moments stay finite without changing threshold exhaustion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before = try a.alloc(u64, sample_capacity * 64);
    const after = try a.alloc(u64, sample_capacity * 64);
    @memset(before, 0);
    @memset(after, 0);
    var core = [_]u32{ 800, 800 };
    var both = [_]u32{ 0, 0 };
    var size = Size{ .threshold = 800, .count = 2, .core_hw = &core, .both_hw = &both, .before = before, .after = after };
    const model = try Model.init(a, 4096, .improved);
    const double = try Model.init(a, 8192, .improved);
    try std.testing.expectEqual(@as(f64, 0), model.distribution.cdf[800]);
    const result = try size.score(model, double, false);
    try std.testing.expect(std.math.isFinite(result.score.core));
    try std.testing.expect(std.math.isFinite(result.score.both));
    try std.testing.expect(std.math.isFinite(result.score.distance));
    try std.testing.expectEqual(@as(i32, 799), result.threshold);
    try std.testing.expectEqual(@as(usize, 2), result.score.count);
    size.threshold = 0;
    try std.testing.expectError(error.NearSeqThresholdBelowZero, size.score(model, double, true));
}
