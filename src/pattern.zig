// Pat5 from PractRand 0.96 (CC0); see LICENSES/PractRand.txt.
const std = @import("std");
const b = @import("battery.zig");
const s = @import("statistics.zig");
const pattern_count = 8;
const pattern_words = 11;
const center = pattern_words / 2;
const base_bins = 1 << 16;

fn chances(comptime arithmetic: s.Arithmetic, comptime bits: usize, comptime shift: u5, comptime output_bits: u5) [1 << output_bits]f64 {
    var pdf: [bits / 2 + 1]f64 = undefined;
    var cdf: [pdf.len]f64 = undefined;
    s.Hamming.fill(bits, &pdf, &cdf, arithmetic);
    var result: [1 << output_bits]f64 = @splat(0);
    for (0..bits + 1) |weight| result[@min(weight >> shift, result.len - 1)] += pdf[@min(weight, bits - weight)];
    return result;
}
fn probabilities(comptime arithmetic: s.Arithmetic) [base_bins]f64 {
    @setEvalBranchQuota(2_000_000);
    const primary = chances(arithmetic, 9, 0, 2);
    const secondary = chances(arithmetic, 64, 0, 6);
    const tertiary = chances(arithmetic, 128, 1, 5);
    const quaternary = chances(arithmetic, 128, 3, 3);
    var values: [base_bins]f64 = undefined;
    for (&values, 0..) |*p, i| {
        var chance: f64 = 1;
        chance *= primary[i & 3];
        chance *= secondary[(i >> 2) & 63];
        chance *= tertiary[(i >> 8) & 31];
        chance *= quaternary[(i >> 13) & 7];
        p.* = chance;
    }
    return values;
}
const improved_probabilities = probabilities(.improved);
const reference_probabilities = probabilities(.reference);

pub const Pat5 = struct {
    pub const count_bins = pattern_count * base_bins;
    counts: []u64,
    patterns: [pattern_count]?[pattern_words]u32 = @splat(null),
    previous: [center]u32 = @splat(0),
    started: bool = false,
    fn at(t: *const Pat5, bytes: []const u8, position: isize) u32 {
        if (position < 0) return t.previous[@intCast(@as(isize, center) + position)];
        const offset: usize = @intCast(position * 4);
        return std.mem.readInt(u32, bytes[offset..][0..4], .little);
    }
    pub fn update(t: *Pat5, bytes: []const u8) void {
        const first: usize = if (t.started) 0 else center;
        // Upstream omits the final five centers on every input call.
        for (first..bytes.len / 4 - center) |i| {
            const value = std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
            if (value & ((1 << 20) - 1) != 0) continue;
            const pi = value >> 29;
            const position: isize = @intCast(i);
            if (t.patterns[pi]) |pattern| {
                var distance = [_]u32{ @popCount(pattern[center] ^ value), 0, 0, 0 };
                for (1..center + 1) |j| {
                    const group: usize = if (j == 1) 1 else if (j < 4) 2 else 3;
                    distance[group] += @as(u32, @popCount(pattern[center - j] ^ t.at(bytes, position - @as(isize, @intCast(j))))) + @popCount(pattern[center + j] ^ t.at(bytes, position + @as(isize, @intCast(j))));
                }
                const index = (@as(usize, pi) << 16) | @min(distance[0], 3) | (@as(usize, @min(distance[1], 63)) << 2) | (@as(usize, @min(distance[2] >> 1, 31)) << 8) | (@as(usize, @min(distance[3] >> 3, 7)) << 13);
                t.counts[index] += 1;
            } else if (@popCount(value ^ t.at(bytes, position + 1)) > 4) {
                var pattern: [pattern_words]u32 = undefined;
                for (&pattern, 0..) |*word, j| word.* = t.at(bytes, position + @as(isize, @intCast(j)) - center);
                t.patterns[pi] = pattern;
            }
        }
        for (&t.previous, 0..) |*word, i| word.* = std.mem.readInt(u32, bytes[bytes.len - center * 4 + i * 4 ..][0..4], .little);
        t.started = true;
    }
    pub fn results(t: Pat5, blocks: u64, r: *b.Results) !void {
        if (blocks == 0) return;
        const base_probabilities = if (r.arithmetic == .reference) &reference_probabilities else &improved_probabilities;
        var samples: [pattern_count]u64 = @splat(0);
        var total: i64 = 0;
        for (&samples, t.patterns, 0..) |*count, pattern, i| {
            for (t.counts[i * base_bins ..][0..base_bins]) |n| count.* += n;
            total += @intCast(count.*);
            if (pattern == null) total -= 1;
        }
        if (total < 100) return;
        const opportunities = blocks * 256 - pattern_words + 1;
        if (opportunities > 300) {
            const probs = try r.allocator.alloc(f64, count_bins);
            for (probs, 0..) |*p, i| p.* = base_probabilities[i & (base_bins - 1)] / pattern_count;
            const raw = s.unorderedRarity(probs, t.counts, r.arithmetic);
            try r.add("Pat5(*,r)", raw, 0, .raw_normal, 0.125);
            if (opportunities > 3000) {
                const counts = try r.allocator.dupe(u64, t.counts);
                const n = try s.simplifyUnordered(r.allocator, probs, counts, s.f(total) / 40);
                const normal = s.normal(s.gTest(probs[0..n], counts[0..n], r.arithmetic), s.f(n - 1));
                try r.add("Pat5(*,g)", normal, 0, .raw_normal, 0.125);
            }
        }
        for (samples, 0..) |count, i| {
            if (count < 30) continue;
            const group = t.counts[i * base_bins ..][0..base_bins];
            const raw = s.unorderedRarity(base_probabilities, group, r.arithmetic);
            try r.add(try r.formatName("Pat5({d},r)", .{i}), raw, 0, .raw_normal, 0.001 / @as(f64, pattern_count));
            if (count > 300) {
                const probs = try r.allocator.dupe(f64, base_probabilities);
                const counts = try r.allocator.dupe(u64, group);
                const n = try s.simplifyUnordered(r.allocator, probs, counts, s.f(count) / 40);
                const normal = s.normal(s.gTest(probs[0..n], counts[0..n], r.arithmetic), s.f(n - 1));
                try r.add(try r.formatName("Pat5({d},g)", .{i}), normal, 0, .raw_normal, 0.001 / @as(f64, pattern_count));
            }
        }
    }
};
