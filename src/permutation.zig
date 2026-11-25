// Limited permutation tests from PractRand 0.96 (CC0); see LICENSES/PractRand.txt.
const std = @import("std");
const b = @import("battery.zig");
const s = @import("statistics.zig");
const minimum_samples = 32 * bins;
const maximum_plain_blocks = 1 << 39;
const result_weight = 0.05;
const bins = 1 << 15;
const pairs = [_][2]usize{ .{ 0, 1 }, .{ 2, 3 }, .{ 1, 3 }, .{ 4, 5 }, .{ 6, 7 }, .{ 5, 7 }, .{ 3, 7 }, .{ 8, 9 }, .{ 10, 11 }, .{ 9, 11 }, .{ 12, 13 }, .{ 14, 15 }, .{ 13, 15 }, .{ 11, 15 }, .{ 7, 15 } };

fn index(comptime T: type, comptime n: usize, comptime weighted: bool, values: [n]T) usize {
    var result: usize = 0;
    inline for (pairs[0 .. n - 1], 0..) |pair, bit| {
        const a = values[pair[0]];
        const c = values[pair[1]];
        const less = if (weighted and @popCount(a) != @popCount(c)) @popCount(a) < @popCount(c) else a < c;
        result |= @as(usize, @intFromBool(less)) << bit;
    }
    return result;
}
fn probabilities(comptime arithmetic: s.Arithmetic) [bins]f64 {
    @setEvalBranchQuota(10_000_000);
    var base: [128]f64 = @splat(0);
    var counts: [128]u16 = @splat(0);
    for (0..40320) |permutation| {
        var values: [8]u8 = undefined;
        var remaining = permutation;
        var used: u8 = 0;
        for (&values, 0..) |*value, position| {
            var digit = remaining % (8 - position);
            remaining /= 8 - position;
            var next: u3 = 0;
            while (true) : (next += 1) {
                if (used & (@as(u8, 1) << next) != 0) continue;
                if (digit == 0) break;
                digit -= 1;
            }
            value.* = next;
            used |= @as(u8, 1) << next;
        }
        const bin = index(u8, 8, false, values);
        if (arithmetic == .reference) base[bin] += 1.0 / 40320.0 else counts[bin] += 1;
    }
    if (arithmetic == .improved) for (&base, counts) |*p, count| {
        p.* = s.f(count) / 40320;
    };
    var result: [bins]f64 = undefined;
    for (@import("permutation_data.zig").ratios, 0..) |ratio, i| {
        const chance = base[i & 127] * base[(i >> 7) & 127];
        result[i] = chance * ratio;
        result[i + bins / 2] = chance * (1 - ratio);
    }
    return result;
}
const improved_probabilities = probabilities(.improved);
const reference_probabilities = probabilities(.reference);

pub fn Permutation(comptime word_bits: u7, comptime weighted: bool) type {
    return struct {
        const Self = @This();
        const Word = @Int(.unsigned, word_bits);
        pub const count_bins = bins;
        counts: []u64,
        pub fn update(t: *Self, bytes: []const u8) void {
            var offset: usize = 0;
            while (offset < bytes.len) : (offset += 16 * @sizeOf(Word)) {
                var values: [16]Word = undefined;
                inline for (&values, 0..) |*value, i| value.* = std.mem.readInt(Word, bytes[offset + i * @sizeOf(Word) ..][0..@sizeOf(Word)], .little);
                t.counts[index(Word, 16, weighted, values)] += 1;
            }
        }
        pub fn results(t: Self, blocks: u64, r: *b.Results) !void {
            if (blocks * (1024 / @sizeOf(Word) / 16) < minimum_samples) return;
            if (!weighted and blocks >= maximum_plain_blocks) return;
            const raw = s.normal(s.gTest(if (r.arithmetic == .reference) &reference_probabilities else &improved_probabilities, t.counts, r.arithmetic), bins - 1);
            const name = comptime std.fmt.comptimePrint("LPerm16{s}({d})", .{ if (weighted) "A" else "", word_bits });
            try r.add(name, raw, raw, .raw_normal, result_weight);
        }
    };
}

test "integer-first permutation probabilities preserve total mass" {
    var sum = s.Sum{};
    for (improved_probabilities) |p| sum.add(p);
    try std.testing.expectApproxEqAbs(@as(f64, 1), sum.value(), 2e-16);
    var old_sum = s.Sum{};
    for (reference_probabilities) |p| old_sum.add(p);
    try std.testing.expect(old_sum.value() < 1 - 1e-15);
}
