// Statistical kernels adapted from Chris Doty-Humphrey's PractRand 0.96 (CC0).
// See LICENSES/PractRand.txt for the original dedication.
const std = @import("std");
const s = @import("statistics.zig");
const A = std.mem.Allocator;
const Family = enum { bcfn, dc6, gap, fpf, birthday, brank, mod3, tmf };
const families = std.enums.values(Family);
const birthday_radix_bits = 11;
const birthday_radix_minimum = 4096;
const mod3_batch_log2 = 4;
const bcfn_narrow_minimum_bytes = 256 << 10;
const bcfn_delta_maximum_bytes = 16 << 20;
const rank_block_minimum_size = 128;
const rank_wide_minimum_size = 512;
const rank_block_width = 4;
const rank_wide_block_width = 8;
pub const birthday_sample_capacity = 1 << 24;
extern "c" fn erfc(f64) f64;
const f = s.f;
const pow = s.pow;
pub const Kind = enum { good_s, bad_s, bad_p, raw_normal, raw, passfail, good_p };
pub const Result = struct {
    name: []const u8,
    raw: f64,
    value: f64,
    kind: Kind,
    weight: f64,
    arithmetic: s.Arithmetic = .reference,
    // Preserve the tail even if the displayed probability rounds to zero or one.
    tail_suspicion: ?f64 = null,
    pub fn suspicion(r: Result) f64 {
        if (r.tail_suspicion) |tail| return tail;
        return switch (r.kind) {
            .good_s, .bad_s => r.value,
            .bad_p, .good_p => s.suspicion(r.value, r.arithmetic),
            .raw_normal => s.rawSuspicion(r.raw),
            .raw => 0,
            .passfail => if (r.value == 0) 0 else -9999,
        };
    }
    pub fn probability(r: Result) f64 {
        return switch (r.kind) {
            .bad_p, .good_p => r.value,
            .raw => 0.5,
            .passfail => if (r.value == 0) 0.5 else 0,
            else => s.probability(r.suspicion()),
        };
    }
};
pub const Results = struct {
    arithmetic: s.Arithmetic = .improved,
    models: ?*const Models = null,
    tables: ?*const Tables = null,
    allocator: A,
    items: std.ArrayList(Result) = .empty,
    prefix: []const u8 = "",
    fn dc6Model(r: *Results, blocks: u64) !DC6.Model {
        if (r.models) |models| if (findModel(DC6.Model, models.dc6, blocks)) |model| {
            return model;
        };
        return DC6.model(r.allocator, blocks, if (r.tables) |tables| tables.dc8 else try DC6.probabilities(r.allocator));
    }
    fn gapModel(r: *Results, blocks: u64) !Gap.Model {
        if (r.models) |models| if (findModel(Gap.Model, models.gap, blocks)) |model| {
            return model;
        };
        return Gap.model(r.allocator, blocks, r.arithmetic);
    }
    // Unprefixed names must outlive the result collection (literals or its arena).
    pub fn add(r: *Results, name: []const u8, raw: f64, value: f64, kind: Kind, weight: f64) !void {
        try r.items.append(r.allocator, .{ .name = if (r.prefix.len == 0) name else try r.formatName("{s}{s}", .{ r.prefix, name }), .raw = raw, .value = value, .kind = kind, .weight = weight, .arithmetic = r.arithmetic });
    }
    fn addTail(r: *Results, name: []const u8, raw: f64, tail: f64, kind: Kind, weight: f64) !void {
        try r.add(name, raw, s.probability(tail), kind, weight);
        r.items.items[r.items.items.len - 1].tail_suspicion = tail;
    }
    pub fn calibrated(r: *Results, name: []const u8, key: []const u8, blocks: u64, raw: f64, kind: Kind, weight: f64) !void {
        if (s.calibration(key, blocks)) |row| try r.add(name, raw, -s.calibrated(row, raw, true, r.arithmetic), kind, weight) else try r.add(name, raw, raw, .raw_normal, weight);
    }
    pub fn formatName(r: *Results, comptime format: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(r.allocator, format, args);
    }
};
fn word(comptime T: type, b: []const u8, i: usize) T {
    return std.mem.readInt(T, b[i..][0..@sizeOf(T)], .little);
}
fn sampledBlock(input: *[]const u8, skip: *u8, stride: u8) ?[]const u8 {
    const n: usize = @min(input.len / 1024, skip.*);
    skip.* -= @intCast(n);
    input.* = input.*[n * 1024 ..];
    if (input.len == 0) return null;
    const block = input.*[0..1024];
    input.* = input.*[1024..];
    skip.* = stride - 1;
    return block;
}

pub const BCFN = BitCount(2);
pub fn BitCount(comptime units: u2) type {
    return struct {
        const Self = @This();
        pub const count_bins = 32 * 8192;
        const chances = [_]f64{ 0, 0.5, 0.375, 0.2734375, 0.196380615234375, 0.139949934091419, 0.0993467537479669, 0.07038609217001513, 0.04981910993614015, 0.03524463548583874, 0.02492780589297954, 0.01762877240484652, 0.01246618536376026, 0.008815193220481631, 0.006233378016746476, 0.004407697493275419, 0.003116724676252416, 0.002203861357197468, 0.001558366796642998, 0.001101932254924341, 0.0007791839556370945, 0.0005509663245030477, 0.0003895920474830278, 0.000275483186881639, 0.0001947960324495749 };
        const level_probabilities = blk: {
            @setEvalBranchQuota(1_000_000);
            var values: [32][14]f64 = undefined;
            for (0..32) |level| {
                const nlevel = level + units + 3;
                const balanced = if (nlevel < chances.len) chances[nlevel] else chances[24] * pow(0.5, 0.5 * f(nlevel - 24));
                const p1 = 0.5 - 0.5 * balanced;
                for (&values[level], 0..) |*p, ones| p.* = @exp(@log(p1) * f(ones) + @log(1 - p1) * f(13 - ones));
            }
            break :blk values;
        };
        fn improvedProbabilities(level: usize, bits: usize, out: []f64) void {
            const nlevel = level + units + 3;
            const balanced = if (nlevel < chances.len) chances[nlevel] else chances[24] * pow(0.5, 0.5 * f(nlevel - 24));
            const log_one = std.math.log1p(-balanced);
            const log_zero = std.math.log1p(balanced);
            var by_weight: [14]f64 = undefined;
            for (by_weight[0 .. bits + 1], 0..) |*p, ones| {
                // The marginal is 2^-bits times powers of (1 +/- balanced).
                // Exact binary scaling avoids rounding a large -bits*ln(2).
                p.* = std.math.ldexp(@exp(@mulAdd(f64, log_one, f(ones), log_zero * f(bits - ones))), -@as(i32, @intCast(bits)));
            }
            for (out, 0..) |*p, i| p.* = by_weight[@popCount(i)];
        }
        counts: []u64,
        index: [32]u16 = @splat(0),
        warmup: [32]u8 = @splat(12),
        odd: [32]bool = @splat(false),
        saved: [32]i64 = @splat(0),
        fn record(t: *Self, level: usize, bits: i64) void {
            const index = ((t.index[level] << 1) | @intFromBool(bits < 0)) & 8191;
            t.index[level] = index;
            if (t.warmup[level] != 0) t.warmup[level] -= 1 else t.counts[level * 8192 + index] += 1;
        }
        pub fn update(t: *Self, b: []const u8) void {
            if (b.len < bcfn_narrow_minimum_bytes) {
                t.updateDense(b, t.counts[0 .. 4 * 8192]);
                return;
            }
            t.updateNarrow(b);
        }
        noinline fn updateNarrow(t: *Self, b: []const u8) void {
            // Each bounded call can add at most one count per input byte to a
            // bin. Private narrow deltas improve locality; published totals stay wide.
            var dense: [4 * 8192]u32 = undefined;
            var offset: usize = 0;
            while (offset < b.len) {
                const n = @min(b.len - offset, bcfn_delta_maximum_bytes);
                @memset(&dense, 0);
                t.updateDense(b[offset..][0..n], &dense);
                for (t.counts[0..dense.len], &dense) |*total, count| total.* += count;
                offset += n;
            }
        }
        fn updateDense(t: *Self, b: []const u8, dense: anytype) void {
            // One 1 KiB prefix finishes all four dense levels' exclusions,
            // including 64-bit input units. The steady loop has no warmup work.
            var start: usize = 0;
            if (t.warmup[3] != 0) {
                start = @min(b.len, 1024);
                t.updateDenseMode(b[0..start], dense, true);
            }
            t.updateDenseMode(b[start..], dense, false);
        }
        fn updateDenseMode(t: *Self, b: []const u8, dense: anytype, comptime warming: bool) void {
            const Word = @Int(.unsigned, 8 << @as(usize, units));
            var i: usize = 0;
            while (i < b.len) : (i += 8 * @sizeOf(Word)) {
                // Eight centered word counts sum to at most +/-256.
                var weights: [8]i16 = undefined;
                inline for (0..8) |j| weights[j] = @as(i16, @intCast(@popCount(word(Word, b, i + j * @sizeOf(Word))))) - (4 << @as(u6, units));
                inline for (0..4) |level| {
                    const symbols = 8 >> level;
                    if (warming) {
                        const skip = @min(t.warmup[level], symbols);
                        var index = t.index[level];
                        for (0..skip) |j| index = ((index << 1) | @intFromBool(weights[j] < 0)) & 8191;
                        t.warmup[level] -= @intCast(skip);
                        for (skip..symbols) |j| {
                            index = ((index << 1) | @intFromBool(weights[j] < 0)) & 8191;
                            dense[level * 8192 + index] += 1;
                        }
                        t.index[level] = index;
                    } else {
                        var index = t.index[level];
                        inline for (0..symbols) |j| {
                            index = ((index << 1) | @intFromBool(weights[j] < 0)) & 8191;
                            dense[level * 8192 + index] += 1;
                        }
                        t.index[level] = index;
                    }
                    if (level < 3) inline for (0..(4 >> level)) |j| {
                        weights[j] = weights[j * 2] + weights[j * 2 + 1];
                    };
                }
                var bits: i64 = weights[0];
                for (4..32) |level| {
                    const previous = level - 1;
                    if (!t.odd[previous]) {
                        t.odd[previous] = true;
                        t.saved[previous] = bits;
                        break;
                    }
                    t.odd[previous] = false;
                    bits += t.saved[previous];
                    t.record(level, bits);
                }
            }
        }
        pub fn results(t: Self, blocks: u64, r: *Results) !void {
            const thresholds = [_]f64{ 1536, 8192, 32768, 65536, 262144, 1048576, 2097152, 8388608, 16777216, 67108864, 134217728, 268435456 };
            const safety = [_]f64{ 8, 6, 4.5, 3, 2, 1.5 };
            var counts: [8192]u64 = undefined;
            var probs: [8192]f64 = undefined;
            for (0..32) |level| {
                const nlevel = level + units + 3;
                const balanced = if (nlevel < chances.len) chances[nlevel] else chances[24] * pow(0.5, 0.5 * f(nlevel - 24));
                const samples = @max(0, f(blocks) * 1024 * pow(0.5, f(level + units)) * (1 - balanced) - 14);
                const adjusted = samples / safety[@min(level + units, 5)];
                var ebits: usize = 4;
                for (thresholds, 0..) |threshold, j| {
                    if (adjusted >= threshold) ebits = @min(13, j + 4);
                }
                if (adjusted < 1536 and (level != 0 or samples < 768)) continue;
                const key = try r.formatName("{s}BCFN-{d}/4", .{ if (ebits == 4 and adjusted > 8192) "" else "_", ebits });
                const cb: u64 = @intFromFloat(adjusted / (1 - chances[5]) / 256);
                const source = t.counts[level * 8192 ..][0..8192];
                if (r.arithmetic == .reference) for (&probs, 0..) |*p, j| {
                    p.* = level_probabilities[level][@popCount(j)];
                };
                var weight = if (level + units < 5) f(level + units + 2) / 8 else pow(0.5, f((level + units + 2) / 2));
                weight = @min(0.375, weight);
                if (level == 0) weight += 0.125;
                if (s.calibration(key, cb)) |row| {
                    const bins = @as(usize, 1) << @intCast(ebits);
                    @memcpy(counts[0..bins], source[0..bins]);
                    for (bins..8192) |i| counts[i & (bins - 1)] += source[i];
                    if (r.arithmetic == .reference) {
                        for (bins..8192) |i| probs[i & (bins - 1)] += probs[i];
                    } else improvedProbabilities(level, ebits, probs[0..bins]);
                    const raw = s.normal(s.gTest(probs[0..bins], counts[0..bins], r.arithmetic), f(bins - 1));
                    try r.add(try r.formatName("BCFN(" ++ std.fmt.comptimePrint("{d}", .{units}) ++ "+{d},13-{d}U)", .{ level, 13 - ebits }), raw, -s.calibrated(row, raw, true, r.arithmetic), .good_s, weight);
                } else {
                    if (r.arithmetic == .improved) improvedProbabilities(level, 13, &probs);
                    const raw = s.normal(s.gTest(&probs, source, r.arithmetic), 8191);
                    try r.add(try r.formatName("BCFN(" ++ std.fmt.comptimePrint("{d}", .{units}) ++ "+{d},13)", .{level}), raw, if (@abs(raw) > 25 + @as(f64, if (samples > 12345) 0 else 5)) 1 else 0, .passfail, weight);
                }
            }
        }
    };
}

pub const DC6 = Distribution(9, 0, false);
pub fn Distribution(comptime length: usize, comptime units: u2, comptime alternating: bool) type {
    return struct {
        const Self = @This();
        const paired = alternating and (units == 1 or units == 2);
        const bits = 2 + @as(usize, units);
        const classes = 1 << bits;
        const word_bits = 8 << @as(usize, units);
        pub const count_bins = 1 << (bits * length);
        const key = std.fmt.comptimePrint("DC6-{d}x{d}Bytes-1", .{ length, @as(usize, 1) << units });
        const name = if (alternating) std.fmt.comptimePrint("DC7-{d}x{d}Bytes-1", .{ length, @as(usize, 1) << units }) else key;
        const base = blk: {
            @setEvalBranchQuota(10000);
            const outcomes = pow(2, word_bits);
            var values: [classes]f64 = @splat(0);
            var combination: u64 = 1;
            for (0..word_bits + 1) |ones| {
                values[(ones >> 1) & (classes - 1)] += f(combination) / outcomes;
                if (ones != word_bits) combination = combination * (word_bits - ones) / (ones + 1);
            }
            break :blk values;
        };
        const codes = blk: {
            var order: [classes]usize = undefined;
            for (&order, 0..) |*entry, i| entry.* = i;
            for (1..classes) |i| {
                var j = i;
                while (j != 0 and base[order[j - 1]] < base[order[j]]) : (j -= 1) std.mem.swap(usize, &order[j - 1], &order[j]);
            }
            var values: [classes]u32 = @splat(0);
            for (order, 0..) |original, rank| {
                for (0..bits) |bit| values[original] |= @as(u32, @intCast((rank >> @intCast(bit)) & 1)) << @intCast(bit * length);
            }
            break :blk values;
        };
        const mask = blk: {
            var value: u32 = 0;
            for (0..bits) |bit| value |= ((@as(u32, 1) << @intCast(length - 1)) - 1) << @intCast(bit * length);
            break :blk value;
        };
        const lookup = blk: {
            @setEvalBranchQuota(10000);
            var values: [256]u32 = undefined;
            for (&values, 0..) |*v, i| v.* = codes[(@popCount(@as(u8, @intCast(i))) >> 1) & (classes - 1)];
            break :blk values;
        };
        const chunk_symbols = 8 / bits;
        const chunk_bits = chunk_symbols * bits;
        const permutation = blk: {
            @setEvalBranchQuota(10000);
            var values: [1 << chunk_bits]u32 = @splat(0);
            for (&values, 0..) |*v, i| for (0..chunk_symbols) |j| {
                v.* |= codes[(i >> @intCast(j * bits)) & (classes - 1)] << @intCast(j);
            };
            break :blk values;
        };
        pub const Model = DistributionModel;
        pub fn probabilities(a: A) ![]const f64 {
            const probs = try a.alloc(f64, count_bins);
            probs[0] = 1;
            var filled: usize = 1;
            while (filled < probs.len) : (filled *= classes) {
                for (0..classes) |ordinal| {
                    const code = classes - 1 - ordinal;
                    for (0..filled) |i| probs[code * filled + i] = probs[i] * base[code];
                }
            }
            return probs;
        }
        fn model(a: A, blocks: u64, source: []const f64) !Model {
            const probs = try a.dupe(f64, source);
            const widths = try a.alloc(u64, probs.len);
            @memset(widths, 1);
            const bins = s.simplify(probs, widths, f(blocks) * (1024 >> @as(u3, units)) / 25);
            return .{ .blocks = blocks, .probabilities = probs[0..bins], .widths = widths[0..bins] };
        }
        counts: []u64,
        odd_counts: if (alternating) []u64 else void = if (alternating) &.{} else {},
        odd: if (alternating) bool else void = if (alternating) false else {},
        index: u32 = 0,
        warmup: u8 = length - 1,
        fn record(t: *Self, code: u32) void {
            t.index = ((t.index & mask) << 1) | code;
            if (t.warmup != 0) {
                t.warmup -= 1;
            } else if (alternating) {
                const counts = if (t.odd) t.odd_counts else t.counts;
                counts[t.index] += 1;
            } else t.counts[t.index] += 1;
            if (alternating) t.odd = !t.odd;
        }
        pub fn countAt(t: *const Self, odd: bool, index: usize) u64 {
            return if (alternating and odd) t.odd_counts[index] else t.counts[index];
        }
        fn codeAtOffset(bytes: []const u8, offset: usize) u32 {
            return if (units == 0) lookup[bytes[offset]] else codes[(@popCount(word(@Int(.unsigned, word_bits), bytes, offset)) >> 1) & (classes - 1)];
        }
        pub fn update(t: *Self, bytes: []const u8) void {
            if (paired) {
                const size = 1 << @as(usize, units);
                var offset: usize = 0;
                while (t.warmup != 0 and offset < bytes.len) : (offset += size) t.record(codeAtOffset(bytes, offset));
                if (t.odd and offset < bytes.len) {
                    t.record(codeAtOffset(bytes, offset));
                    offset += size;
                }
                var index = t.index;
                while (offset + 4 * size <= bytes.len) : (offset += 4 * size) {
                    var values: [4]u32 = undefined;
                    inline for (0..4) |j| values[j] = codeAtOffset(bytes, offset + j * size);
                    inline for (0..4) |j| {
                        index = ((index & mask) << 1) | values[j];
                        const counts = if (j & 1 == 0) t.counts else t.odd_counts;
                        counts[index] += 1;
                    }
                }
                t.index = index;
                while (offset < bytes.len) : (offset += size) t.record(codeAtOffset(bytes, offset));
                return;
            }

            if (units == 0) {
                for (bytes) |v| t.record(lookup[v]);
            } else {
                const Word = @Int(.unsigned, word_bits);
                var offset: usize = 0;
                while (offset < bytes.len) : (offset += @sizeOf(Word)) t.record(codes[(@popCount(word(Word, bytes, offset)) >> 1) & (classes - 1)]);
            }
        }
        fn reordered(i: usize) u32 {
            var result: u32 = 0;
            inline for (0..length / chunk_symbols) |chunk| result |= permutation[(i >> (chunk * chunk_bits)) & (permutation.len - 1)] << (chunk * chunk_symbols);
            inline for (length / chunk_symbols * chunk_symbols..length) |position| result |= codes[(i >> (position * bits)) & (classes - 1)] << position;
            return result;
        }
        fn prepareModel(blocks: u64, r: *Results) !Model {
            if (r.models) |models| if (models.distributions) |cache| if (cache.find(length, units, blocks)) |prepared| return prepared;
            if (units == 0 and length == 9) {
                const prepared = try r.dc6Model(blocks);
                return .{ .blocks = prepared.blocks, .probabilities = prepared.probabilities, .widths = prepared.widths };
            }
            return model(r.allocator, blocks, if (r.tables) |tables| try tables.distribution(length, units, r.allocator) else try probabilities(r.allocator));
        }
        fn gather(comptime channels: usize, sources: [channels][]const u64, a: A, prepared_model: Model) ![channels][]u64 {
            var counts: [channels][]u64 = undefined;
            inline for (0..channels) |channel| counts[channel] = try a.alloc(u64, prepared_model.probabilities.len);
            var offset: usize = 0;
            for (prepared_model.widths, 0..) |width, bin| {
                var totals: [channels]u64 = @splat(0);
                for (offset..offset + @as(usize, @intCast(width))) |i| {
                    const index = reordered(i);
                    inline for (0..channels) |channel| totals[channel] += sources[channel][index];
                }
                inline for (0..channels) |channel| counts[channel][bin] = totals[channel];
                offset += @intCast(width);
            }
            return counts;
        }
        fn gatherThree(t: Self, a: A, split: Model, combined: Model) ![3][]u64 {
            const even = try a.alloc(u64, split.probabilities.len);
            const odd = try a.alloc(u64, split.probabilities.len);
            const both = try a.alloc(u64, combined.probabilities.len);
            @memset(even, 0);
            @memset(odd, 0);
            @memset(both, 0);
            var split_bin: usize = 0;
            var combined_bin: usize = 0;
            var split_end: usize = @intCast(split.widths[0]);
            var combined_end: usize = @intCast(combined.widths[0]);
            var offset: usize = 0;
            // The two models partition the same reordered source. Their
            // boundaries need not nest: advance at their ordered union.
            while (offset < count_bins) {
                const end = @min(split_end, combined_end);
                var even_total: u64 = 0;
                var odd_total: u64 = 0;
                for (offset..end) |i| {
                    const index = reordered(i);
                    even_total += t.counts[index];
                    odd_total += t.odd_counts[index];
                }
                even[split_bin] += even_total;
                odd[split_bin] += odd_total;
                both[combined_bin] += even_total + odd_total;
                offset = end;
                if (offset == split_end and offset < count_bins) {
                    split_bin += 1;
                    split_end += @intCast(split.widths[split_bin]);
                }
                if (offset == combined_end and offset < count_bins) {
                    combined_bin += 1;
                    combined_end += @intCast(combined.widths[combined_bin]);
                }
            }
            return .{ even, odd, both };
        }
        fn score(source: []const u64, blocks: u64, r: *Results, reported_name: []const u8, prepared_model: Model) !void {
            const counts = try gather(1, .{source}, r.allocator, prepared_model);
            try scoreCounts(counts[0], blocks, r, reported_name, prepared_model);
        }
        fn scoreCounts(counts: []const u64, blocks: u64, r: *Results, reported_name: []const u8, prepared_model: Model) !void {
            const probs = prepared_model.probabilities;
            const raw = s.normal(s.gTest(probs, counts, r.arithmetic), f(probs.len - 1));
            var weight = pow(2, 1 - f(units) / 2);
            if (units != 0) weight *= 0.75;
            if (count_bins < 128 * 1024) weight *= 0.5;
            const minimum = s.minimumLength(key);
            if (minimum != 0 and blocks >= minimum) {
                try r.calibrated(reported_name, key, blocks, raw, .good_s, weight);
            } else if (blocks > @as(u64, units) * 16 * 1024 * 1024) {
                try r.add(reported_name, raw, 0, .raw_normal, weight / 5);
            } else try r.add(reported_name, raw, 0, .raw, 0.01);
        }
        pub fn results(t: Self, blocks: u64, r: *Results) !void {
            if (blocks == 0) return;
            if (!alternating) return score(t.counts, blocks, r, name, try prepareModel(blocks, r));
            const first = r.items.items.len;
            if (blocks / 2 != 0) {
                // Even and odd samples use the same immutable probability model.
                const split_model = try prepareModel(blocks / 2, r);
                const combined_model = try prepareModel(blocks, r);
                const counts = try gatherThree(t, r.allocator, split_model, combined_model);
                try scoreCounts(counts[0], blocks / 2, r, try r.formatName("{s}:even", .{name}), split_model);
                try scoreCounts(counts[1], blocks / 2, r, try r.formatName("{s}:odd", .{name}), split_model);
                try scoreCounts(counts[2], blocks, r, try r.formatName("{s}:both", .{name}), combined_model);
            } else {
                const both = try r.allocator.alloc(u64, count_bins);
                for (both, t.counts, t.odd_counts) |*total, even, odd| total.* = even + odd;
                try score(both, blocks, r, try r.formatName("{s}:both", .{name}), try prepareModel(blocks, r));
            }
            if (r.items.items.len != first + 3) return;
            const items = r.items.items;
            const result_name = try r.formatName("{s}:indep", .{name});
            if (r.arithmetic == .reference) {
                const raw = -2 * (@log(items[first].probability()) + @log(items[first + 1].probability()));
                try r.add(result_name, s.normal(raw, 4), s.chiSquare4Tail(raw, .reference), .good_p, 0.5);
            } else {
                const combined = s.combineTwoSuspicions(items[first].suspicion(), items[first + 1].suspicion());
                try r.addTail(result_name, s.normal(combined.chis, 4), combined.suspicion, .good_p, 0.5);
            }
        }
    };
}
pub const FPF = FloatingPattern(4);
pub fn FloatingPattern(comptime stride_log: u3) type {
    return struct {
        const Self = @This();
        pub const count_bins = 52 * 16384;
        const stride_bits = 1 << stride_log;
        const name = std.fmt.comptimePrint("FPF/{d}", .{stride_bits});
        const tail_bytes = if (stride_log == 6) 0 else if (stride_log == 5) 4 else if (stride_log == 4) 6 else 8;
        counts: []u64,
        tail: [tail_bytes]u8 = @splat(0),
        started: bool = false,
        fn sample(t: *Self, v: u64) void {
            const e: usize = @min(@ctz(v), 51);
            const sig = (v >> @as(u6, @intCast(if (e < 51) e + 1 else e))) & 16383;
            t.counts[e * 16384 + sig] += 1;
        }
        pub fn update(t: *Self, bytes: []const u8) void {
            if (stride_log >= 5) {
                // Only the 32-bit stride overlaps input calls. Keep FPF/64 aligned.
                if (stride_log == 5 and t.started) {
                    var head: [8]u8 = undefined;
                    @memcpy(head[0..4], &t.tail);
                    @memcpy(head[4..8], bytes[0..4]);
                    t.sample(word(u64, &head, 0));
                }
                var offset: usize = 0;
                while (offset + 8 <= bytes.len) : (offset += stride_bits / 8) t.sample(word(u64, bytes, offset));
            } else if (stride_log == 4) {
                if (t.started) {
                    var head: [14]u8 = undefined;
                    @memcpy(head[0..6], &t.tail);
                    @memcpy(head[6..14], bytes[0..8]);
                    for (0..3) |i| t.sample(word(u64, &head, i * 2));
                }
                var offset: usize = if (t.started) 0 else 2;
                while (offset + 8 <= bytes.len) : (offset += 2) t.sample(word(u64, bytes, offset));
            } else {
                if (t.started) {
                    var head: [16]u8 = undefined;
                    @memcpy(head[0..8], &t.tail);
                    @memcpy(head[8..16], bytes[0..8]);
                    var bit: usize = stride_bits;
                    while (bit < 64) : (bit += stride_bits) {
                        const offset = bit / 8;
                        const shift: u6 = @intCast(bit & 7);
                        var value = word(u64, &head, offset) >> shift;
                        if (shift != 0) value |= @as(u64, head[offset + 8]) << @as(u6, @intCast(64 - @as(u7, shift)));
                        t.sample(value);
                    }
                }
                var offset: usize = 0;
                while (offset + 8 < bytes.len) : (offset += 1) {
                    const value = word(u64, bytes, offset);
                    inline for (0..8 / stride_bits) |part| {
                        const shift = part * stride_bits;
                        if (shift != 0 or t.started or offset != 0) {
                            const window = if (shift == 0) value else (value >> shift) | (@as(u64, bytes[offset + 8]) << (64 - shift));
                            t.sample(window);
                        }
                    }
                }
                t.sample(word(u64, bytes, offset));
            }
            t.finishInput(bytes);
        }
        fn finishInput(t: *Self, bytes: []const u8) void {
            @memcpy(&t.tail, bytes[bytes.len - tail_bytes ..]);
            t.started = true;
        }
        pub fn results(t: Self, blocks: u64, r: *Results) !void {
            const samples = (f(blocks) * 8192 - 64) / stride_bits;
            const calibration_blocks: u64 = @intFromFloat(samples / 512 + 0.5);
            var inter_counts: [52]u64 = @splat(0);
            var inter_probs: [52]f64 = undefined;
            var counts: [16384]u64 = undefined;
            var probs: [16384]f64 = undefined;
            var over_raw: f64 = 0;
            var improved_overall = s.NominalGTest{};
            var over_bins: usize = 0;
            for (0..52) |e| {
                const group = t.counts[e * 16384 ..][0..16384];
                for (group) |count| inter_counts[e] += count;
                if (inter_counts[e] == 0) continue;
                const expected = pow(0.5, f(e) + (if (e == 51) @as(f64, 0) else 1)) * samples;
                const ebits: i32 = @intFromFloat(@min(14, @floor((@log(expected) / @log(@as(f64, 2)) - 4) * 0.75 + 0.1)));
                if (ebits < 1) continue;
                const bins = @as(usize, 1) << @intCast(ebits);
                @memcpy(counts[0..bins], group[0..bins]);
                for (group[bins..], bins..) |count, i| counts[i & (bins - 1)] += count;
                if (r.arithmetic == .reference) @memset(probs[0..bins], 1 / f(bins));
                const expected_bin = expected * pow(0.5, f(ebits));
                if (r.arithmetic == .reference) {
                    for (counts[0..bins]) |count| {
                        if (count != 0) over_raw += f(count) * @log(f(count) / expected_bin);
                    }
                } else improved_overall.add(counts[0..bins], expected_bin);
                over_bins += bins;
                if (ebits < 3) continue;
                const raw = s.normal(s.gTest(if (r.arithmetic == .reference) probs[0..bins] else null, counts[0..bins], r.arithmetic), f(bins - 1));
                try r.calibrated(try r.formatName(name ++ ":({d},14-{d})", .{ e, 14 - ebits }), try r.formatName("FPF/16({d})", .{ebits}), calibration_blocks, raw, .good_s, f(ebits) * 0.00625 / 14);
            }
            if (over_bins >= 2) {
                const raw = s.normal(if (r.arithmetic == .reference) 2 * over_raw else improved_overall.value(), f(over_bins - 1));
                if (samples >= 3000) try r.calibrated(name ++ ":all", "FPF-14+6/16:overall", calibration_blocks, raw, .good_s, 0.25) else try r.add(name ++ ":all", raw, raw, .raw_normal, 0.25);
            }
            if (samples >= 1000) {
                for (&inter_probs, 0..) |*p, e| p.* = pow(0.5, f(e) + (if (e == 51) @as(f64, 0) else 1));
                const bins = s.simplify(&inter_probs, &inter_counts, samples / 40);
                const raw = s.normal(s.gTest(inter_probs[0..bins], inter_counts[0..bins], r.arithmetic), f(bins - 1)) / @sqrt(@as(f64, 2));
                try r.calibrated(name ++ ":cross", "FPF-14+6/16:cross", calibration_blocks, raw, if (samples >= 4000) .good_s else .bad_s, 0.25);
            }
        }
    };
}

fn mod3Probabilities(a: A) ![]const [29511]f64 {
    const tables = try a.alloc([29511]f64, 5);
    for (0..5) |level| for (3..10) |exponent| {
        const bins = std.math.pow(usize, 3, exponent);
        const probs = tables[level][(bins - 27) / 2 ..][0..bins];
        const values = pow(2, f(@as(usize, 8) << @intCast(level)));
        const base1 = @floor(values / 3) / values;
        const base2 = @floor(values / 3 + 1) / values;
        var by_zeroes: [10]f64 = undefined;
        for (by_zeroes[0 .. exponent + 1], 0..) |*p, zeroes| p.* = pow(base1, f(exponent - zeroes)) * pow(base2, f(zeroes));
        for (probs[0..bins], 0..) |*p, i| {
            var x = i;
            var zeroes: usize = 0;
            for (0..exponent) |_| {
                if (x % 3 == 0) zeroes += 1;
                x /= 3;
            }
            p.* = by_zeroes[zeroes];
        }
    };
    return tables;
}
pub const Mod3 = Modulo3(5);
pub fn Modulo3(comptime fraction: u3) type {
    return struct {
        const Self = @This();
        pub const count_bins = 16 * 19683;
        counts: []u64,
        index: [16]u32 = @splat(0),
        warmup: [16]u8 = @splat(8),
        odd: [16]bool = @splat(false),
        saved: [16]u8 = @splat(0),
        phase: u64 = 0,
        scale: u6 = 0,
        total_on: u64 = 0,
        fn nextIndex(index: u32, rem: u8) u32 {
            // Nine base-3 digits plus one trit stay below three times 19683.
            const next = index * 3 + rem;
            return if (next >= 2 * 19683) next - 2 * 19683 else if (next >= 19683) next - 19683 else next;
        }
        fn record(t: *Self, level: usize, rem: u8) void {
            t.index[level] = nextIndex(t.index[level], rem);
            if (t.warmup[level] != 0) t.warmup[level] -= 1 else t.counts[level * 19683 + t.index[level]] += 1;
        }
        pub fn update(t: *Self, b: []const u8) void {
            var offset: usize = 0;
            while (offset < b.len) {
                const on = @as(u64, 1) << t.scale;
                if (t.phase >= on) {
                    const end = on << fraction;
                    const skip = @min(end - t.phase, (b.len - offset) / 1024);
                    offset += @intCast(skip * 1024);
                    t.phase += skip;
                    if (t.phase == end) {
                        t.phase = 0;
                        t.scale += 1;
                        if (fraction != 0) {
                            t.warmup = @splat(8);
                            t.odd = @splat(false);
                        }
                    }
                    continue;
                }
                const n = @min(on - t.phase, (b.len - offset) / 1024);
                const input = b[offset..][0..@intCast(n * 1024)];
                const batch_bytes = 1 << mod3_batch_log2;
                var position: usize = 0;
                while (position < input.len) : (position += batch_bytes) {
                    const V = @Vector(batch_bytes, u8);
                    const bytes: V = input[position..][0..batch_bytes].*;
                    var remainders: [batch_bytes]u8 = bytes % @as(V, @splat(3));
                    // Whole 1 KiB input blocks keep these subtrees aligned at every call boundary.
                    inline for (0..mod3_batch_log2) |level| {
                        // Keep rolling state local and update warmup once per batch.
                        // The first eight windows need prior-batch trits; the last eight
                        // are complete nine-trit windows contained in this batch.
                        if (level == 0 and batch_bytes == 16) {
                            const skip = @min(t.warmup[0], 8);
                            var index = t.index[0];
                            for (0..skip) |i| index = nextIndex(index, remainders[i]);
                            t.warmup[0] -= @intCast(skip);
                            for (skip..8) |i| {
                                index = nextIndex(index, remainders[i]);
                                t.counts[index] += 1;
                            }
                            var indices: @Vector(8, u32) = @splat(0);
                            inline for (0..9) |digit| {
                                const mask = comptime blk: {
                                    var m: [8]i32 = undefined;
                                    for (&m, 0..) |*v, i| v.* = @intCast(i + digit);
                                    break :blk m;
                                };
                                const digits = @shuffle(u8, @as(@Vector(16, u8), remainders), undefined, @as(@Vector(8, i32), mask));
                                indices = indices * @as(@Vector(8, u32), @splat(3)) + @as(@Vector(8, u32), @intCast(digits));
                            }
                            for (@as([8]u32, indices)) |bin| t.counts[bin] += 1;
                            t.index[0] = indices[7];
                        } else {
                            const symbols = batch_bytes >> level;
                            const skip = @min(t.warmup[level], symbols);
                            var index = t.index[level];
                            for (0..skip) |i| index = nextIndex(index, remainders[i]);
                            t.warmup[level] -= @intCast(skip);
                            for (skip..symbols) |i| {
                                index = nextIndex(index, remainders[i]);
                                t.counts[level * 19683 + index] += 1;
                            }
                            t.index[level] = index;
                        }
                        inline for (0..(batch_bytes >> (level + 1))) |i| {
                            const sum = remainders[i * 2] + remainders[i * 2 + 1];
                            remainders[i] = if (sum >= 3) sum - 3 else sum;
                        }
                    }
                    var rem = remainders[0];
                    for (mod3_batch_log2..16) |level| {
                        t.record(level, rem);
                        if (!t.odd[level]) {
                            t.odd[level] = true;
                            t.saved[level] = rem;
                            break;
                        }
                        t.odd[level] = false;
                        const sum = rem + t.saved[level];
                        rem = if (sum >= 3) sum - 3 else sum;
                    }
                }
                offset += @intCast(n * 1024);
                t.phase += n;
                t.total_on += n;
            }
        }
        pub fn results(t: Self, r: *Results) !void {
            if (t.total_on == 0) return;
            const tables = if (r.tables) |tables| tables.mod3 else try mod3Probabilities(r.allocator);
            var counts: [19683]u64 = undefined;
            for (0..16) |level| {
                const predicted = ((t.total_on * 1024) >> @intCast(level)) -| (8 * (level + 1));
                if (predicted < 200) break;
                const exponent: usize = @intFromFloat(@min(9, @max(3, @floor(@log(f(predicted)) / @log(@as(f64, 4)) - 2.9))));
                const bins = std.math.pow(usize, 3, exponent);
                @memset(counts[0..bins], 0);
                for (t.counts[level * 19683 ..][0..19683], 0..) |v, i| counts[i % bins] += v;
                var actual: u64 = 0;
                for (counts[0..bins]) |v| actual += v;
                if (actual < 200) break;
                const raw = s.normal(s.gTest(if (level < 5) tables[level][(bins - 27) / 2 ..][0..bins] else null, counts[0..bins], r.arithmetic), f(bins - 1));
                try r.calibrated(try r.formatName("mod3n(" ++ std.fmt.comptimePrint("{d}", .{fraction}) ++ "):({d},9-{d})", .{ level, 9 - exponent }), try r.formatName("mod3_simple({d})", .{exponent}), t.total_on, raw, .good_s, 0.1 * pow(0.7, f(level -| 2)));
            }
        }
    };
}

pub const Gap = struct {
    pub const count_bins = 33280;
    const Model = struct { blocks: u64, probabilities: []const f64, highest: usize };
    fn model(a: A, blocks: u64, arithmetic: s.Arithmetic) !Model {
        const probs = try a.alloc(f64, 33280);
        var lopped: f64 = 0;
        var model_mass = s.Sum{};
        var retained = s.Sum{};
        var highest: usize = 0;
        for (probs, 0..) |*p, i| {
            const first = if (i < 512) i else if (i < 16896) 512 + ((i - 512) << 5) else 524800 + ((i - 16896) << 7);
            const last: usize = if (i == 33279) 123456789 else first + (if (i < 512) @as(usize, 1) else if (i < 16896) @as(usize, 32) else @as(usize, 128)) - 1;
            const fraction = @min(1, (f(first + last) / 2 + 1) / (f(blocks) * 512));
            const probability = if (arithmetic == .reference) reference_probabilities[i] else improved_probabilities[i];
            if (arithmetic == .reference) {
                lopped += probability * fraction;
                p.* = probability * (1 - fraction);
            } else {
                model_mass.add(probability);
                var mass = s.Sum{ .high = probability };
                mass.addProduct(-probability, fraction);
                p.* = mass.value();
                retained.add(mass.high);
                retained.add(mass.low);
            }
            if (p.* != 0) highest = i;
        }
        // 1-sum(p*f) = sum(p*(1-f)) + (1-sum(p)). Preserve the
        // represented model residual rather than renormalizing it away.
        var denominator = s.Sum{ .high = 1 - model_mass.high };
        denominator.add(-model_mass.low);
        denominator.add(retained.high);
        denominator.add(retained.low);
        for (probs) |*p| p.* /= if (arithmetic == .reference) 1 - lopped else denominator.value();
        return .{ .blocks = blocks, .probabilities = probs, .highest = highest };
    }
    fn probabilities(comptime arithmetic: s.Arithmetic) [33280]f64 {
        @setEvalBranchQuota(100_000_000);
        var values: [33280]f64 = undefined;
        for (&values, 0..) |*p, i| {
            const first = if (i < 512) i else if (i < 16896) 512 + ((i - 512) << 5) else 524800 + ((i - 16896) << 7);
            const last: usize = if (i == 33279) 123456789 else first + (if (i < 512) @as(usize, 1) else if (i < 16896) @as(usize, 32) else @as(usize, 128)) - 1;
            p.* = binProbability(first, last + 1 - first, arithmetic);
        }
        return values;
    }
    const reference_probabilities = probabilities(.reference);
    const improved_probabilities = probabilities(.improved);
    fn binProbability(first: usize, width: usize, arithmetic: s.Arithmetic) f64 {
        if (arithmetic == .reference) return pow(65535.0 / 65536.0, f(first)) - pow(65535.0 / 65536.0, f(first + width));
        const log_q = std.math.log1p(-@as(f64, 1) / 65536);
        return @exp(f(first) * log_q) * -std.math.expm1(f(width) * log_q);
    }
    counts: []u64,
    last: []u32,
    warmup: u32 = 65536,
    blocks: u64 = 0,
    extreme: u64 = 0,
    autofail: bool = false,
    pub fn update(t: *Gap, b: []const u8) void {
        if (t.autofail) return;
        if (t.warmup != 0 and b.len > 65536) {
            var offset: usize = 0;
            while (offset < b.len) {
                const n = @min(65536, b.len - offset);
                t.update(b[offset..][0..n]);
                offset += n;
            }
            return;
        }
        const ofs = if (t.warmup != 0) t.updateWords(b, true) else t.updateWords(b, false);
        const old = t.blocks;
        t.blocks += b.len / 1024;
        if (old >> 19 != t.blocks >> 19) {
            if (t.warmup != 0) t.autofail = true;
            var old_flags: u32 = 0;
            for (t.last) |v| old_flags |= @intFromBool(ofs -% v > 0x18000000);
            t.autofail = t.autofail or old_flags != 0;
        }
    }
    fn updateWords(t: *Gap, b: []const u8, comptime warming: bool) u32 {
        var ofs = @as(u32, @truncate(t.blocks)) *% 512;
        var i: usize = 0;
        // Inputs consist of complete 1 KiB blocks. Load four values together,
        // but publish each last-seen position before reading the next one.
        while (i < b.len) : (i += 8) {
            const values = word(u64, b, i);
            inline for (0..4) |lane| {
                const v: u16 = @truncate(values >> (lane * 16));
                const prior = t.last[v];
                ofs +%= 1;
                t.last[v] = ofs;
                if (warming and prior == 0) {
                    t.warmup -= 1;
                } else {
                    const lag = ofs -% prior -% 1;
                    const index: usize = if (lag < 512) lag else if (lag - 512 < 524288) 512 + ((lag - 512) >> 5) else 16896 + ((lag - 524800) >> 7);
                    if (index < t.counts.len) t.counts[index] += 1 else t.extreme += 1;
                }
            }
        }
        return ofs;
    }
    pub fn results(t: Gap, r: *Results) !void {
        if (t.blocks < 3) return;
        if (t.autofail) {
            try r.add("Gap-16:!", 1, 1, .passfail, 0.000001);
            return;
        }
        const counts = try r.allocator.dupe(u64, t.counts);
        const prepared_model = try r.gapModel(t.blocks);
        const probs = try r.allocator.dupe(f64, prepared_model.probabilities);
        const highest = prepared_model.highest;
        var total = t.extreme;
        for (counts) |count| total += count;
        if (total == 0) {
            try r.add("Gap-16:?", 0, 0, if (t.blocks > 16) .passfail else .raw, 0.0001);
            return;
        }
        const rare = s.rarity(probs[0 .. highest + 1], t.counts[0 .. highest + 1], r.arithmetic);
        counts[counts.len - 1] += t.extreme;
        var bins = s.simplify(probs[0 .. highest + 1], counts[0 .. highest + 1], f(t.blocks) * 512 / 40);
        const fine = s.normal(s.gTest(probs[0..bins], counts[0..bins], r.arithmetic), f(bins - 1));
        bins = s.simplify(probs[0..bins], counts[0..bins], @sqrt(f(t.blocks) * 512));
        const coarse = s.normal(s.gTest(probs[0..bins], counts[0..bins], r.arithmetic), f(bins - 1));
        try r.calibrated("Gap-16:A", "Gap-16:A", t.blocks, fine, .good_s, 0.5);
        try r.calibrated("Gap-16:B", "Gap-16:B", t.blocks, coarse, .good_s, 0.5);
        try r.add("Gap-16:C", rare, rare, .bad_s, 0.5);
    }
};
const rank_scores = blk: {
    @setEvalBranchQuota(100_000);
    var values: [16]f64 = undefined;
    var probs: [16]f64 = undefined;
    probs[0] = 0.2887880950866024212789;
    for (1..16) |i| probs[i] = probs[i - 1] * 2 / pow(f((@as(u32, 1) << @intCast(i)) - 1), 2);
    var sum: f64 = 0;
    for (probs) |p| sum += p;
    for (&probs) |*p| p.* /= sum;
    var mean: f64 = 0;
    for (probs, &values) |p, *score| {
        score.* = -@log(p) / @log(@as(f64, 2));
        mean += score.* * p;
    }
    var variance: f64 = 0;
    for (probs, &values) |p, *score| {
        score.* -= mean;
        variance += score.* * score.* * p;
    }
    for (&values) |*score| score.* /= @sqrt(variance);
    break :blk values;
};
// Eliminate a short column block with one cached XOR combination per row.
// Pivots form an identity on selected columns, including rank-deficient blocks.
fn rankBlocked(matrix: []u64, size: usize, table: []u64, comptime width: usize) usize {
    const stride = size / 64;
    var rank: usize = 0;
    var col: usize = 0;
    while (col < size and rank < size) : (col += width) {
        const word_index = col / 64;
        const shift: u6 = @intCast(col % 64);
        const first = rank;
        var pivots: [width]?usize = @splat(null);
        for (0..width) |bit| {
            const mask = @as(u64, 1) << @intCast(col % 64 + bit);
            var candidate = rank;
            while (candidate < size) : (candidate += 1) {
                for (pivots[0..bit], 0..) |previous, pbit| {
                    if (previous) |pivot| {
                        const previous_mask = @as(u64, 1) << @intCast(col % 64 + pbit);
                        if (matrix[candidate * stride + word_index] & previous_mask != 0)
                            for (word_index..stride) |j| {
                                matrix[candidate * stride + j] ^= matrix[pivot * stride + j];
                            };
                    }
                }
                if (matrix[candidate * stride + word_index] & mask != 0) break;
            }
            if (candidate == size) continue;
            for (word_index..stride) |j| std.mem.swap(u64, &matrix[rank * stride + j], &matrix[candidate * stride + j]);
            for (first..rank) |previous| {
                if (matrix[previous * stride + word_index] & mask != 0)
                    for (word_index..stride) |j| {
                        matrix[previous * stride + j] ^= matrix[rank * stride + j];
                    };
            }
            pivots[bit] = rank;
            rank += 1;
            if (rank == size) return rank;
        }
        if (rank == first) continue;
        const words = stride - word_index;
        @memset(table[0..words], 0);
        for (1..(1 << width)) |key| {
            const bit = @ctz(key);
            const prior = key & (key - 1);
            const destination = table[key * stride ..][0..words];
            const source = table[prior * stride ..][0..words];
            if (pivots[bit]) |pivot| {
                const row = matrix[pivot * stride + word_index ..][0..words];
                for (destination, source, row) |*out, left, right| out.* = left ^ right;
            } else @memcpy(destination, source);
        }
        for (rank..size) |row| {
            const key: usize = @intCast((matrix[row * stride + word_index] >> shift) & ((1 << width) - 1));
            if (key == 0) continue;
            const destination = matrix[row * stride + word_index ..][0..words];
            const source = table[key * stride ..][0..words];
            for (destination, source) |*out, value| out.* ^= value;
        }
    }
    return rank;
}
fn rankScalar(matrix: []u64, size: usize) usize {
    const stride = size / 64;
    var rank: usize = 0;
    for (0..size) |col| {
        const w = col / 64;
        const mask = @as(u64, 1) << @intCast(col % 64);
        var pivot = rank;
        while (pivot < size and matrix[pivot * stride + w] & mask == 0) : (pivot += 1) {}
        if (pivot == size) continue;
        for (w..stride) |j| std.mem.swap(u64, &matrix[rank * stride + j], &matrix[pivot * stride + j]);
        for (rank + 1..size) |row| {
            if (matrix[row * stride + w] & mask != 0) for (w..stride) |j| {
                matrix[row * stride + j] ^= matrix[rank * stride + j];
            };
        }
        rank += 1;
        if (rank == size) break;
    }
    return rank;
}

pub const BRank = MatrixRank(12);
pub fn MatrixRank(comptime effort: u5) type {
    return struct {
        const Self = @This();
        const rate: u64 = @intFromFloat(pow(2, f(effort) / 2));
        allocator: A,
        matrix: []u64,
        size: usize = 64,
        step: usize = 64,
        loaded: usize = 0,
        wait: i64 = 512,
        count: u64 = 0,
        score: f64 = 0,
        score_low: f64 = 0,
        last_size: usize = 0,
        pub fn init(a: A) !Self {
            return .{ .allocator = a, .matrix = try a.alloc(u64, 64) };
        }
        fn finish(t: *Self) !void {
            const table: []u64 = if (t.size >= rank_block_minimum_size) try t.allocator.alloc(u64, @as(usize, if (t.size >= rank_wide_minimum_size) 1 << rank_wide_block_width else 1 << rank_block_width) * (t.size / 64)) else &.{};
            defer t.allocator.free(table);
            const rank = if (t.size >= rank_wide_minimum_size) rankBlocked(t.matrix, t.size, table, rank_wide_block_width) else if (table.len != 0) rankBlocked(t.matrix, t.size, table, rank_block_width) else rankScalar(t.matrix, t.size);
            const deficit = t.size - rank;
            const score = if (deficit < 16) rank_scores[deficit] else rank_scores[15] + (rank_scores[15] - rank_scores[14]) * f(deficit - 15);
            const next_count = t.count + 1;
            const next_size = t.size + (if (t.size >= 128 or next_count & 7 == 0) t.step else 0);
            // Allocate the next workspace before publishing the completed matrix.
            const next = if (next_size == t.size) t.matrix else try t.allocator.alloc(u64, next_size * next_size / 64);
            if (next_size != t.size) t.allocator.free(t.matrix);
            t.matrix = next;
            t.count = next_count;
            var accumulated = s.Sum{ .high = t.score, .low = t.score_low };
            accumulated.add(score);
            t.score = accumulated.high;
            t.score_low = accumulated.low;
            t.last_size = t.size;
            t.size = next_size;
            t.loaded = 0;
            if (std.math.isPowerOfTwo(t.size)) {
                const l2 = std.math.log2_int_ceil(usize, t.size);
                t.step = @as(usize, 1) << @intCast(@max(6, (l2 + 7) / 2));
            }
            const n = t.size / 64;
            t.wait += @intCast(n * n * n * 256 + n * n * 256);
        }
        pub fn update(t: *Self, b: []const u8) !void {
            var offset: usize = 0;
            while (offset < b.len) {
                if (t.wait > 0) {
                    const skip = @min(@as(usize, @intCast(@divTrunc(t.wait + @as(i64, @intCast(rate - 1)), @as(i64, @intCast(rate))))), (b.len - offset) / 1024);
                    offset += skip * 1024;
                    t.wait -= @intCast(skip * rate);
                } else {
                    const bytes = @min(t.matrix.len * 8 - t.loaded, b.len - offset);
                    @memcpy(std.mem.sliceAsBytes(t.matrix)[t.loaded..][0..bytes], b[offset..][0..bytes]);
                    const blocks = (bytes + 1023) / 1024;
                    t.loaded += bytes;
                    if (t.loaded == t.matrix.len * 8) try t.finish();
                    t.wait -= @intCast(blocks * rate);
                    offset += blocks * 1024;
                }
            }
        }
        pub fn results(t: Self, r: *Results) !void {
            if (t.count == 0) return;
            const raw = (if (r.arithmetic == .reference) t.score else t.score + t.score_low) / @sqrt(f(t.count));
            if (t.count < 16) {
                const name = try r.formatName("BRank(" ++ std.fmt.comptimePrint("{d}", .{effort}) ++ "):score:{d}({d})", .{ t.last_size, t.count });
                if (r.arithmetic == .reference) {
                    const p = if (raw > 0) 1 - 0.5 * @exp(-raw) else 0.5 * @exp(raw);
                    try r.add(name, raw, p, .bad_p, 0.01);
                } else try r.addTail(name, raw, raw / @log(@as(f64, 2)), .bad_p, 0.01);
            } else {
                const row = s.calibration("BRank", t.count).?;
                const extrapolate = t.count >= 32 or raw > 0;
                try r.add(try r.formatName("BRank(" ++ std.fmt.comptimePrint("{d}", .{effort}) ++ "):score:{d}", .{t.last_size}), raw, -s.calibrated(row, raw, extrapolate, r.arithmetic), if (t.count > 32) .good_s else .bad_s, if (extrapolate) 0.25 else 0.125);
            }
        }
    };
}

fn birthdaySort(a: A, items: []u64, workspace: *std.ArrayList(u64), low_bits: u6) !void {
    if (items.len < birthday_radix_minimum) {
        std.mem.sortUnstable(u64, items, {}, std.sort.asc(u64));
        return;
    }
    // A sequential reduction can avoid histogram work for the many high
    // zero digits in spacings, and all histogram work for equal masked keys.
    var varying: u64 = 0;
    for (items) |v| varying |= v ^ items[0];
    varying >>= low_bits;
    if (varying == 0) return;
    const digits = (64 - @clz(varying) + birthday_radix_bits - 1) / birthday_radix_bits;
    switch (digits) {
        inline 1...((64 + birthday_radix_bits - 1) / birthday_radix_bits) => |n| return birthdaySortDigits(n, a, items, workspace, low_bits),
        else => unreachable,
    }
}
fn birthdaySortDigits(comptime passes: usize, a: A, items: []u64, workspace: *std.ArrayList(u64), low_bits: u6) !void {
    var histograms: [passes][1 << birthday_radix_bits]usize = @splat(@splat(0));
    for (items) |v| {
        const key = v >> low_bits;
        inline for (0..passes) |pass| histograms[pass][(key >> (pass * birthday_radix_bits)) & ((1 << birthday_radix_bits) - 1)] += 1;
    }
    try workspace.ensureTotalCapacityPrecise(a, items.len);
    var source = items;
    var target = workspace.allocatedSlice()[0..items.len];
    for (0..passes) |pass| {
        const shift: u6 = @intCast(@as(usize, low_bits) + pass * birthday_radix_bits);
        const offsets = &histograms[pass];
        var total: usize = 0;
        for (offsets) |*offset| {
            const n = offset.*;
            offset.* = total;
            total += n;
        }
        for (source) |v| {
            const digit = (v >> shift) & ((1 << birthday_radix_bits) - 1);
            target[offsets[digit]] = v;
            offsets[digit] += 1;
        }
        std.mem.swap([]u64, &source, &target);
    }
    if (source.ptr != items.ptr) @memcpy(items, source);
}
pub const Birthday = BirthdayTest(4);
pub fn BirthdayTest(comptime fraction: u3) type {
    return struct {
        const Self = @This();
        allocator: A,
        buffer: std.ArrayList(u64) = .empty,
        skip: u8 = (1 << fraction) - 1,
        flushes: u64 = 0,
        bits: u7 = 18,
        filter_bits: u6 = 0,
        lambda: f64 = 0,
        duplicates: u64 = 0,
        old_lambda: f64 = 0,
        old_duplicates: u64 = 0,
        fn measure(t: *Self, full: bool) !void {
            const n = t.buffer.items.len;
            var lambda = pow(f(n), 3) / pow(2, f(t.bits) + 2);
            if (lambda < 0.1) return;
            var flush_data = false;
            if (full) {
                t.flushes += 1;
                if (t.lambda > 64) {
                    flush_data = true;
                    if (t.bits < 64) {
                        if (t.flushes == 1) {
                            while (lambda > 128 and t.bits < 64) {
                                t.bits += 1;
                                lambda *= 0.5;
                            }
                        } else t.bits = 64;
                    } else t.filter_bits += 1;
                }
                lambda = pow(2, 70 - f(t.bits));
            } else {
                while (lambda > 128 and t.bits < 64) {
                    t.bits += 1;
                    lambda *= 0.5;
                }
            }
            // Both radix sorts share scratch only for this measurement.
            var workspace: std.ArrayList(u64) = .empty;
            defer workspace.deinit(t.allocator);
            // Equal masked keys may retain arbitrary low-bit order. Keep the
            // complete samples so a later measurement can request more bits.
            const low_bits: u6 = @intCast(64 - t.bits);
            try birthdaySort(t.allocator, t.buffer.items, &workspace, low_bits);
            const mask = if (t.bits == 64) std.math.maxInt(u64) else @as(u64, std.math.maxInt(u64)) << @as(u6, @intCast(64 - t.bits));
            // A separate lifetime for partial deltas avoids disturbing surviving samples.
            const deltas = if (full) t.buffer.items[0 .. n - 1] else try t.allocator.alloc(u64, n - 1);
            defer if (!full) t.allocator.free(deltas);
            for (deltas, 0..) |*delta, i| delta.* = (t.buffer.items[i + 1] & mask) - (t.buffer.items[i] & mask);
            try birthdaySort(t.allocator, deltas, &workspace, low_bits);
            var dups: u64 = 0;
            for (1..deltas.len) |i| {
                if (deltas[i] == deltas[i - 1]) dups += 1;
            }
            if (full) {
                if (flush_data) {
                    t.old_duplicates = t.duplicates;
                    t.old_lambda = t.lambda;
                    t.duplicates = 0;
                    t.lambda = 0;
                }
                t.duplicates += dups;
                t.lambda += lambda;
                t.buffer.clearRetainingCapacity();
            } else {
                t.duplicates = dups;
                t.lambda = lambda;
            }
        }
        pub fn update(t: *Self, b: []const u8) !void {
            var input = b;
            while (sampledBlock(&input, &t.skip, 1 << fraction)) |block| {
                var i: usize = 0;
                while (i < 1024) : (i += 16) {
                    const mask = (@as(u64, 1) << t.filter_bits) - 1;
                    if (t.flushes == 0 or word(u64, block, i + 8) & mask == 0) {
                        try t.buffer.append(t.allocator, word(u64, block, i));
                        if (t.buffer.items.len == birthday_sample_capacity) try t.measure(true);
                    }
                }
                if (t.flushes == 0 and std.math.isPowerOfTwo(t.buffer.items.len)) try t.measure(false);
            }
        }
        fn poisson(lambda: f64, n: u64, arithmetic: s.Arithmetic) f64 {
            if (n == 0) return if (arithmetic == .reference and lambda < 5) s.suspicion(0.5 * @exp(-lambda), .reference) else -lambda / @log(@as(f64, 2));
            const norm = (if (arithmetic == .reference) f(n) - lambda else s.countDifference(n, lambda)) / @sqrt(lambda);
            if (norm >= 4 or (lambda > 64 and norm <= -4)) {
                const log_p = if (arithmetic == .reference) @log(lambda / f(n)) * f(n) + f(n) - lambda else s.poissonLogTail(lambda, n);
                const score = log_p / @log(@as(f64, 2)) + 1;
                return if (norm > 0) -score else score;
            }
            if (lambda <= 64) {
                if (arithmetic == .improved) return s.smallPoissonSuspicion(lambda, n);
                var term = @exp(-lambda);
                var sum: f64 = 0;
                for (0..@intCast(n)) |i| {
                    sum += term;
                    term *= lambda / f(i + 1);
                }
                return s.suspicion(sum + term * 0.5, arithmetic);
            }
            if (arithmetic == .improved) return s.normalSuspicion(norm, .improved);
            const p = if (norm > 0) 1 - 0.5 * erfc(norm * 0.7071067811865475244) else 0.5 * erfc(-norm * 0.7071067811865475244);
            return s.suspicion(p, .reference);
        }
        pub fn results(t: Self, r: *Results) !void {
            const lambda = t.lambda + t.old_lambda;
            if (lambda == 0) return;
            const n = t.duplicates + t.old_duplicates;
            const raw = (if (r.arithmetic == .reference) f(n) - lambda else s.countDifference(n, lambda)) / @sqrt(lambda);
            const processed = poisson(lambda, n, r.arithmetic);
            const bits = @as(usize, t.bits) + t.filter_bits;
            const name = if (bits >= 64) try r.formatName("BDayS2(" ++ std.fmt.comptimePrint("{d}", .{fraction}) ++ ",24)[64+{d}]", .{bits - 64}) else try r.formatName("BDayS2(" ++ std.fmt.comptimePrint("{d}", .{fraction}) ++ ",24)[{d}]", .{bits});
            try r.add(name, raw, if (lambda < 16) @floatFromInt(@intFromBool(@abs(processed) > 30)) else -processed, if (lambda < 16) .passfail else if (lambda < 256) .bad_s else .good_s, 0.25 * pow(0.6, f(fraction)));
        }
    };
}

pub const TMF = TripleMirror(2);
pub fn TripleMirror(comptime minimum: u2) type {
    return struct {
        const Self = @This();
        pub const count_bins = (16 - @as(usize, minimum)) * 8192;
        counts: []u64,
        state: [16]u8 = @splat(0),
        saved: [32]u64 = @splat(0),
        skip: u8 = 0,
        pub fn update(t: *Self, b: []const u8) void {
            var input = b;
            while (sampledBlock(&input, &t.skip, 1 << minimum)) |block| {
                const words = [_]u64{ word(u64, block, 0), word(u64, block, 8) };
                const current = words[0];
                for (minimum..16) |level| {
                    const old = t.state[level];
                    t.state[level] += 1;
                    if (old == 0) t.saved[level] = current else if (old == 1) t.saved[level + 16] = current else {
                        const first = if (old == 2) level else level + 16;
                        const second = if (old == 2) level + 16 else level;
                        const a = t.saved[first];
                        const v = t.saved[second];
                        t.saved[first] = current;
                        if (old == 3) t.state[level] = 2;
                        for (0..16) |pos| {
                            const shift = pos * 4;
                            const index = ((level - minimum) << 13) | (a & 7) | (pos << 9) | (((v >> @as(u6, @intCast(shift))) & 7) << 3) | (((words[pos / 8] >> @as(u6, @intCast(pos * 8 % 64))) & 7) << 6);
                            t.counts[index] += 1;
                        }
                    }
                    // State parity already determines when the next level receives a sample.
                    if (old & 1 != 0) break;
                }
            }
        }
        pub fn results(t: Self, blocks: u64, r: *Results) !void {
            for (minimum..16) |level| {
                if (blocks >> @intCast(level) < 6144) break;
                const raw = s.normal(s.gTest(null, t.counts[(level - minimum) * 8192 ..][0..8192], r.arithmetic), 8176);
                try r.add(try r.formatName("TMFn(" ++ std.fmt.comptimePrint("{d}", .{minimum}) ++ "+{d}):wl", .{level - minimum}), raw, raw, .raw_normal, 0.01);
            }
        }
    };
}

fn findModel(comptime T: type, items: []const T, blocks: u64) ?T {
    for (items) |model| if (model.blocks == blocks) {
        return model;
    };
    return null;
}
// Constructed once in the run arena, then shared read-only by all scoring jobs.
pub const Tables = struct {
    arithmetic: s.Arithmetic = .improved,
    dc8: []const f64 = &.{},
    dc16: []const f64 = &.{},
    dc32: []const f64 = &.{},
    mod3: []const [29511]f64 = &.{},
    near: []const @import("near_seq.zig").Model = &.{},
    pub fn init(a: A, expanded: bool, arithmetic: s.Arithmetic) !Tables {
        return .{
            .arithmetic = arithmetic,
            .dc8 = try DC6.probabilities(a),
            .dc16 = if (expanded) try Distribution(6, 1, false).probabilities(a) else &.{},
            .dc32 = if (expanded) try Distribution(5, 2, false).probabilities(a) else &.{},
            .mod3 = try mod3Probabilities(a),
            .near = if (expanded) try @import("near_seq.zig").NearSeq3.prepareModels(a, arithmetic) else &.{},
        };
    }
    fn distribution(tables: Tables, comptime length: usize, comptime units: u2, a: A) ![]const f64 {
        if (length == 9 and units == 0) return tables.dc8;
        if (length == 6 and units == 1 and tables.dc16.len != 0) return tables.dc16;
        if (length == 5 and units == 2 and tables.dc32.len != 0) return tables.dc32;
        return Distribution(length, units, false).probabilities(a);
    }
};
pub const DistributionModel = struct { blocks: u64, probabilities: []const f64, widths: []const u64 };
// Only checkpoint preparation mutates this bounded cache. Scoring jobs borrow
// immutable entries after preparation and join before the next preparation.
pub const DistributionCache = struct {
    const capacity = 48;
    const Entry = struct { length: usize, units: u2, model: DistributionModel, storage: []u64, touched: u64 };
    allocator: A = std.heap.page_allocator,
    byte_limit: usize = 64 << 20,
    entries: [capacity]?Entry = @splat(null),
    payload_bytes: usize = 0,
    clock: u64 = 0,
    protected_from: u64 = 1,
    pub fn beginCheckpoint(cache: *DistributionCache) void {
        cache.protected_from = cache.clock + 1;
    }
    pub fn find(cache: *const DistributionCache, comptime length: usize, comptime units: u2, blocks: u64) ?DistributionModel {
        for (cache.entries) |entry| if (entry) |value| {
            if (value.length == length and value.units == units and value.model.blocks == blocks) return value.model;
        };
        return null;
    }
    fn discard(cache: *DistributionCache, index: usize) void {
        const entry = cache.entries[index].?;
        cache.payload_bytes -= entry.storage.len * @sizeOf(u64);
        cache.allocator.free(entry.storage);
        cache.entries[index] = null;
    }
    pub fn deinit(cache: *DistributionCache) void {
        for (0..capacity) |i| if (cache.entries[i] != null) cache.discard(i);
    }
    fn ensure(cache: *DistributionCache, comptime length: usize, comptime units: u2, blocks: u64, tables: *const Tables) !void {
        if (blocks == 0) return;
        cache.clock += 1;
        for (&cache.entries) |*entry| if (entry.*) |*value| {
            if (value.length == length and value.units == units and value.model.blocks == blocks) {
                value.touched = cache.clock;
                return;
            }
        };
        // Reserve for the largest possible compact model before constructing it.
        // Current-checkpoint entries cannot be evicted: admitted models will be
        // available to scoring, while unadmitted misses use its existing path.
        const D = Distribution(length, units, false);
        var available = cache.byte_limit - cache.payload_bytes;
        var slot = false;
        for (cache.entries) |entry| {
            if (entry) |value| {
                if (value.touched < cache.protected_from) {
                    available += value.storage.len * @sizeOf(u64);
                    slot = true;
                }
            } else slot = true;
        }
        if (!slot or available < D.count_bins * 2 * @sizeOf(u64)) return;
        var scratch = std.heap.ArenaAllocator.init(cache.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const model = try D.model(a, blocks, try tables.distribution(length, units, a));
        const bytes = model.probabilities.len * 2 * @sizeOf(u64);
        // Allocate and copy before evicting so failure leaves existing entries valid.
        const storage = try cache.allocator.alloc(u64, model.probabilities.len * 2);
        const probabilities = std.mem.bytesAsSlice(f64, std.mem.sliceAsBytes(storage[0..model.probabilities.len]));
        const widths = storage[model.probabilities.len..];
        @memcpy(probabilities, model.probabilities);
        @memcpy(widths, model.widths);
        while (true) {
            var empty: ?usize = null;
            var oldest: ?usize = null;
            for (cache.entries, 0..) |entry, i| {
                if (entry) |value| {
                    if (value.touched < cache.protected_from and (oldest == null or value.touched < cache.entries[oldest.?].?.touched)) oldest = i;
                } else if (empty == null) empty = i;
            }
            if (empty != null and cache.payload_bytes + bytes <= cache.byte_limit) {
                cache.entries[empty.?] = .{ .length = length, .units = units, .model = .{ .blocks = blocks, .probabilities = probabilities, .widths = widths }, .storage = storage, .touched = cache.clock };
                cache.payload_bytes += bytes;
                return;
            }
            cache.discard(oldest.?);
        }
    }
    pub fn prepareExpanded(cache: *DistributionCache, blocks: u64, tables: *const Tables) !void {
        inline for (.{ .{ 9, 0 }, .{ 6, 1 }, .{ 5, 2 } }) |parameters| {
            for ([_]u64{ blocks, blocks / 2, blocks / 16 }) |count| try cache.ensure(parameters[0], parameters[1], count, tables);
        }
    }
};

pub const Models = struct {
    distributions: ?*const DistributionCache = null,
    dc6: []const DC6.Model = &.{},
    gap: []const Gap.Model = &.{},
    pub fn init(a: A, batteries: []const *const Battery, tables: *const Tables) !Models {
        var dc6: std.ArrayList(DC6.Model) = .empty;
        var gap: std.ArrayList(Gap.Model) = .empty;
        for (batteries) |t| {
            if (t.blocks != 0 and findModel(DC6.Model, dc6.items, t.blocks) == null) try dc6.append(a, try DC6.model(a, t.blocks, tables.dc8));
            if (t.gap.blocks >= 3 and !t.gap.autofail and findModel(Gap.Model, gap.items, t.gap.blocks) == null) try gap.append(a, try Gap.model(a, t.gap.blocks, tables.arithmetic));
        }
        return .{ .dc6 = dc6.items, .gap = gap.items };
    }
};
const CountJob = struct {
    battery: *Battery,
    bytes: []const u8,
    family: Family,
    fn run(raw: *anyopaque) !void {
        const job: *CountJob = @ptrCast(@alignCast(raw));
        try job.battery.updateFamily(job.bytes, job.family);
    }
};
// Named fields retain one contiguous mapping without parallel positional wiring.
pub fn allocateHistograms(comptime sizes: anytype) !struct {
    memory: []u64,
    counts: std.enums.EnumFieldStruct(std.meta.FieldEnum(@TypeOf(sizes)), []u64, null),
} {
    const names = @typeInfo(@TypeOf(sizes)).@"struct".field_names;
    const entries = comptime blk: {
        var total: usize = 0;
        for (names) |name| total += @field(sizes, name);
        break :blk total;
    };
    const memory = try std.posix.mmap(null, entries * @sizeOf(u64), .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    const histograms = std.mem.bytesAsSlice(u64, memory);
    var counts: std.enums.EnumFieldStruct(std.meta.FieldEnum(@TypeOf(sizes)), []u64, null) = undefined;
    var offset: usize = 0;
    inline for (names) |name| {
        const n = @field(sizes, name);
        @field(counts, name) = histograms[offset..][0..n];
        offset += n;
    }
    return .{ .memory = histograms, .counts = counts };
}
pub fn freeHistograms(memory: []u64) void {
    std.posix.munmap(@alignCast(std.mem.sliceAsBytes(memory)));
}

test "named histograms are disjoint zeroed slices of one mapping" {
    const storage = try allocateHistograms(.{ .first = 3, .second = 5 });
    defer freeHistograms(storage.memory);
    try std.testing.expectEqual(@as(usize, 8), storage.memory.len);
    try std.testing.expectEqual(storage.memory[0..3].ptr, storage.counts.first.ptr);
    try std.testing.expectEqual(storage.memory[3..8].ptr, storage.counts.second.ptr);
    for (storage.memory) |count| try std.testing.expectEqual(@as(u64, 0), count);
    storage.counts.first[2] = 7;
    try std.testing.expectEqual(@as(u64, 0), storage.counts.second[0]);
}
pub const Battery = struct {
    histograms: []u64,
    blocks: u64 = 0,
    bcfn: BCFN,
    dc6: DC6,
    gap: Gap,
    fpf: FPF,
    birthday: Birthday,
    brank: BRank,
    mod3: Mod3,
    tmf: TMF,
    // The caller owns the run arena; deinit releases mappings and growing workspaces.
    pub fn init(a: A) !Battery {
        const last = try a.alloc(u32, 65536);
        @memset(last, 0);
        const storage = try allocateHistograms(.{ .bcfn = BCFN.count_bins, .dc6 = DC6.count_bins, .gap = Gap.count_bins, .fpf = FPF.count_bins, .mod3 = Mod3.count_bins, .tmf = TMF.count_bins });
        errdefer freeHistograms(storage.memory);
        const counts = storage.counts;
        var birthday = Birthday{ .allocator = std.heap.page_allocator, .buffer = try std.ArrayList(u64).initCapacity(std.heap.page_allocator, birthday_sample_capacity) };
        errdefer birthday.buffer.deinit(birthday.allocator);
        return .{ .histograms = storage.memory, .bcfn = .{ .counts = counts.bcfn }, .dc6 = .{ .counts = counts.dc6 }, .gap = .{ .counts = counts.gap, .last = last }, .fpf = .{ .counts = counts.fpf }, .birthday = birthday, .brank = try BRank.init(std.heap.page_allocator), .mod3 = .{ .counts = counts.mod3 }, .tmf = .{ .counts = counts.tmf } };
    }
    pub fn deinit(t: *Battery) void {
        freeHistograms(t.histograms);
        t.birthday.buffer.deinit(t.birthday.allocator);
        t.brank.allocator.free(t.brank.matrix);
    }
    // Only complete 1 KiB blocks enter a battery. All surviving state has one owner.
    pub fn update(t: *Battery, bytes: []const u8, executor: ?*@import("worker_pool.zig").Pool) !void {
        if (@import("builtin").is_test and (bytes.len == 0 or bytes.len % 1024 != 0)) @panic("battery input must contain complete nonempty blocks");
        if (executor) |pool| {
            var contexts: [families.len]CountJob = undefined;
            var jobs: [families.len]@import("worker_pool.zig").Job = undefined;
            for (&contexts, &jobs, families) |*context, *job, family| {
                context.* = .{ .battery = t, .bytes = bytes, .family = family };
                job.* = .{ .context = context, .run = CountJob.run };
            }
            try pool.run(&jobs);
        } else for (families) |family| try t.updateFamily(bytes, family);
        t.blocks += bytes.len / 1024;
    }
    fn updateFamily(t: *Battery, bytes: []const u8, family: Family) !void {
        switch (family) {
            .bcfn => t.bcfn.update(bytes),
            .dc6 => t.dc6.update(bytes),
            .gap => t.gap.update(bytes),
            .fpf => t.fpf.update(bytes),
            .birthday => try t.birthday.update(bytes),
            .brank => try t.brank.update(bytes),
            .mod3 => t.mod3.update(bytes),
            .tmf => t.tmf.update(bytes),
        }
    }
    pub fn results(t: Battery, r: *Results) !void {
        if (t.blocks == 0) return;
        try t.bcfn.results(t.blocks, r);
        try t.dc6.results(t.blocks, r);
        try t.gap.results(r);
        try t.fpf.results(t.blocks, r);
        try t.birthday.results(r);
        try t.brank.results(r);
        try t.mod3.results(r);
        try t.tmf.results(t.blocks, r);
    }
};

test "bad RNG input yields zero NS3 and DC7 probabilities instead of NaN" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zero: [4 * 1024]u8 = @splat(0);
    const NearSeq3 = @import("near_seq.zig").NearSeq3;
    var ns3 = try NearSeq3.init(a, try NearSeq3.prepareModels(a, .improved));
    defer ns3.deinit();
    try ns3.update(zero[0 .. 2 * 1024]);
    var results = Results{ .allocator = a };
    try ns3.results(2, &results);
    var found_ns3 = false;
    for (results.items.items) |r| {
        try std.testing.expect(std.math.isFinite(r.probability()));
        if (std.mem.eql(u8, r.name, "NS3[4:hw:both]")) {
            try std.testing.expectEqual(@as(f64, 0), r.probability());
            found_ns3 = true;
        }
    }
    try std.testing.expect(found_ns3);
    const DC7 = Distribution(9, 0, true);
    var dc7 = DC7{ .counts = try a.alloc(u64, DC7.count_bins), .odd_counts = try a.alloc(u64, DC7.count_bins) };
    @memset(dc7.counts, 0);
    @memset(dc7.odd_counts, 0);
    dc7.update(&zero);
    results.items.clearRetainingCapacity();
    try dc7.results(4, &results);
    const independence = results.items.items[results.items.items.len - 1];
    try std.testing.expectEqualStrings("DC7-9x1Bytes-1:indep", independence.name);
    try std.testing.expectEqual(@as(f64, 0), independence.probability());
    try std.testing.expect(std.math.isFinite(independence.suspicion()));
    try std.testing.expect(independence.suspicion() < -5000);
    results.items.clearRetainingCapacity();
    results.arithmetic = .reference;
    try dc7.results(4, &results);
    try std.testing.expectEqual(-std.math.inf(f64), results.items.items[results.items.items.len - 1].suspicion());
}

test "FPF histograms and reports do not depend on the first checkpoint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = try a.alloc(u8, 256 * 1024);
    var random = std.Random.DefaultPrng.init(0x93d48a27);
    random.random().bytes(input);
    inline for (.{ 2, 4, 5, 6 }) |stride_log| {
        const Pattern = FloatingPattern(stride_log);
        const counts = try a.alloc(u64, 2 * Pattern.count_bins);
        @memset(counts, 0);
        var whole = Pattern{ .counts = counts[0..Pattern.count_bins] };
        whole.update(input);
        var expected = Results{ .allocator = a };
        try whole.results(input.len / 1024, &expected);
        for ([_]usize{ 1, 3, 5, 17, 255 }) |first_blocks| {
            var split = Pattern{ .counts = counts[Pattern.count_bins..] };
            @memset(split.counts, 0);
            var offset = first_blocks * 1024;
            split.update(input[0..offset]);
            while (true) {
                var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
                defer scratch.deinit();
                var actual = Results{ .allocator = scratch.allocator() };
                try split.results(offset / 1024, &actual);
                if (offset == input.len) {
                    try std.testing.expectEqualSlices(u64, whole.counts, split.counts);
                    try std.testing.expectEqualDeep(expected.items.items, actual.items.items);
                    break;
                }
                const end = @min(input.len, offset + 37 * 1024);
                split.update(input[offset..end]);
                offset = end;
            }
        }
    }
}

test "Birthday full buffers and filter changes match original 0.96" {
    // Reusing a zero block exercises 16 GiB of logical input without a fixture file.
    // Golden rows come from test/reference_values.cpp.
    var t = Birthday{ .allocator = std.heap.page_allocator };
    defer t.buffer.deinit(t.allocator);
    const bytes: [16 * 1024]u8 = @splat(0);
    const names = [_][]const u8{ "BDayS2(4,24)[63]", "BDayS2(4,24)[64+0]", "BDayS2(4,24)[64+0]", "BDayS2(4,24)[64+1]" };
    const raw = [_]f64{ 1572847.75, 2421568.3983815289, 3145711.625, 3632359.5257755239 };
    const suspicion = [_]f64{ -381067939.84514499, -535943085.23805428, -812467186.53028405, -833356613.02807939 };
    for (0..4) |flush| {
        for (0..262144) |_| try t.update(&bytes);
        var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer scratch.deinit();
        var r = Results{ .allocator = scratch.allocator() };
        try t.results(&r);
        try std.testing.expectEqual(@as(usize, 1), r.items.items.len);
        const result = r.items.items[0];
        try std.testing.expectEqualStrings(names[flush], result.name);
        try std.testing.expectApproxEqRel(raw[flush], result.raw, 1e-12);
        try std.testing.expectApproxEqRel(suspicion[flush], result.suspicion(), 1e-12);
    }
    // A filter tightened halfway through a sampled block applies immediately.
    try t.buffer.resize(t.allocator, birthday_sample_capacity - 32);
    @memset(t.buffer.items, 0);
    t.lambda = 128;
    t.skip = 0;
    var mixed: [1024]u8 = @splat(0);
    for (0..64) |i| std.mem.writeInt(u64, mixed[i * 16 + 8 ..][0..8], 2, .little);
    try t.update(&mixed);
    try std.testing.expectEqual(@as(u6, 2), t.filter_bits);
    try std.testing.expectEqual(@as(usize, 0), t.buffer.items.len);
}

test "Gap rarity remains finite at the upstream rounding checkpoint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const model = try Gap.model(a, 2816, .improved);
    const probs = model.probabilities[0 .. model.highest + 1];
    const counts = try a.alloc(u64, probs.len);
    for (counts, probs) |*count, p| count.* = @intFromFloat(@round(p * 2816 * 512));
    try std.testing.expect(std.math.isFinite(s.rarity(probs, counts, .improved)));
}

test "Mod3 counting matches direct nine-symbol windows across sampling boundaries" {
    const Oracle = struct {
        fn fill(input: []const u8, comptime fraction: u3, counts: []u64) void {
            var start: usize = 0;
            var active_blocks: usize = 1;
            while (start < input.len) {
                const end = if (fraction == 0) input.len else @min(input.len, start + active_blocks * 1024);
                const active = input[start..end];
                for (0..16) |level| {
                    const width = @as(usize, 1) << @intCast(level);
                    const symbols = active.len / width;
                    if (symbols <= 8) continue;
                    for (8..symbols) |last| {
                        var index: usize = 0;
                        for (last - 8..last + 1) |group| {
                            var sum: u32 = 0;
                            for (active[group * width ..][0..width]) |byte| sum += byte;
                            index = index * 3 + sum % 3;
                        }
                        counts[level * 19683 + index] += 1;
                    }
                }
                if (fraction == 0) break;
                start += active_blocks * 1024 * (1 << fraction);
                active_blocks *= 2;
            }
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = try a.alloc(u8, 67 * 1024);
    var random = std.Random.DefaultPrng.init(0x1603);
    random.random().bytes(input);
    inline for (.{ 0, 5 }) |fraction| {
        const Test = Modulo3(fraction);
        var actual = Test{ .counts = try a.alloc(u64, Test.count_bins) };
        @memset(actual.counts, 0);
        var offset: usize = 0;
        var call: usize = 0;
        while (offset < input.len) : (call += 1) {
            const end = @min(input.len, offset + (call % 17 + 1) * 1024);
            actual.update(input[offset..end]);
            offset = end;
        }
        const expected = try a.alloc(u64, Test.count_bins);
        @memset(expected, 0);
        Oracle.fill(input, fraction, expected);
        try std.testing.expectEqualSlices(u64, expected, actual.counts);
    }
}

test "Gap periodic age checks preserve wrapping boundaries and warmup failure" {
    const input: [1024]u8 = @splat(0);
    for ([_]u64{ (1 << 19) - 1, (1 << 23) - 1 }) |blocks| {
        for (0..4) |fixture| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var t = Gap{ .counts = try a.alloc(u64, 33280), .last = try a.alloc(u32, 65536), .warmup = if (fixture == 3) 1 else 0, .blocks = blocks };
            @memset(t.counts, 0);
            const initial: u32 = @truncate(blocks * 512);
            const finished = initial +% 512;
            @memset(t.last, initial -% 1);
            if (fixture == 1) t.last[65535] = finished -% 0x18000000;
            if (fixture == 2) t.last[65535] = finished -% 0x18000001;
            if (fixture == 3) t.last[65534] = 0;
            t.update(&input);
            try std.testing.expectEqual(blocks + 1, t.blocks);
            try std.testing.expectEqual(fixture >= 2, t.autofail);
        }
    }
}

test "BCFN histograms match independent thirteen-sign windows" {
    const Oracle = struct {
        fn fill(a: A, input: []const u8, comptime units: u2, counts: []u64) !void {
            const Word = @Int(.unsigned, 8 << @as(usize, units));
            const words = input.len / @sizeOf(Word);
            const prefix = try a.alloc(i64, words + 1);
            prefix[0] = 0;
            for (0..words) |i| prefix[i + 1] = prefix[i] + @as(i64, @intCast(@popCount(std.mem.readInt(Word, input[i * @sizeOf(Word) ..][0..@sizeOf(Word)], .little)))) - (4 << @as(u6, units));
            // Sum each group from the original word weights, without the carry tree.
            for (0..32) |level| {
                const width = @as(usize, 1) << @intCast(level);
                const symbols = words / width;
                if (symbols <= 12) continue;
                for (12..symbols) |last| {
                    var index: usize = 0;
                    for (last - 12..last + 1) |group| {
                        const weight = prefix[(group + 1) * width] - prefix[group * width];
                        index = (index << 1) | @intFromBool(weight < 0);
                    }
                    counts[level * 8192 + index] += 1;
                }
            }
        }
    };
    inline for (0..4) |units| {
        for (0..4) |fixture| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const input = try a.alloc(u8, 67 * 1024);
            var random = std.Random.DefaultPrng.init(0xbcf0);
            if (fixture == 0) random.random().bytes(input) else @memset(input, if (fixture == 1) 0 else if (fixture == 2) 255 else 0x55);
            const Test = BitCount(units);
            var actual = Test{ .counts = try a.alloc(u64, Test.count_bins) };
            @memset(actual.counts, 0);
            var offset: usize = 0;
            var call: usize = 0;
            while (offset < input.len) : (call += 1) {
                const end = @min(input.len, offset + (call % 17 + 1) * 1024);
                actual.update(input[offset..end]);
                offset = end;
            }
            const expected = try a.alloc(u64, Test.count_bins);
            @memset(expected, 0);
            try Oracle.fill(a, input, units, expected);
            try std.testing.expectEqualSlices(u64, expected, actual.counts);
        }
    }
}

// GPU lower counters return bounded deltas; these CPU histograms and rolling
// metadata remain authoritative, including when a later small call stays on CPU.
const Gpu = @import("gpu.zig").Executor;
fn mergeGpuCounts(destination: []u64, delta: []const u32) void {
    for (destination, delta) |*total, count| total.* += count;
}
fn gpuDc7Input(t: *const Distribution(9, 0, true), input: []const u8) Gpu.CountInput {
    const D = Distribution(9, 0, true);
    return .{ .kind = .dc7, .bytes = input, .initial = .{ t.index, 0, 0, 0, 0, 0, 0, 0, 0 }, .warmup = .{ t.warmup, 0, 0, 0, 0, 0, 0, 0, 0 }, .odd = @intFromBool(t.odd), .mask = D.mask, .lookup = &D.lookup };
}
fn mergeGpuDc7(t: *Distribution(9, 0, true), input: []const u8, delta: []const u32) void {
    const D = Distribution(9, 0, true);
    mergeGpuCounts(t.counts, delta[0..D.count_bins]);
    mergeGpuCounts(t.odd_counts, delta[D.count_bins..]);
    const begin = input.len -| 9;
    var index: u32 = if (begin == 0) t.index else 0;
    for (input[begin..]) |value| index = ((index & D.mask) << 1) | D.lookup[value];
    t.index = index;
    t.warmup -= @intCast(@min(input.len, t.warmup));
    if (input.len & 1 != 0) t.odd = !t.odd;
}
pub fn gpuDc7(t: *Distribution(9, 0, true), bytes: []const u8, device: *Gpu) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const input = bytes[offset..][0..@min(bytes.len - offset, device.capacity)];
        mergeGpuDc7(t, input, try device.count(gpuDc7Input(t, input)));
        offset += input.len;
    }
}
fn gpuTrit(bytes: []const u8) u8 {
    var sum: u32 = 0;
    for (bytes) |byte| sum += byte;
    return @intCast(sum % 3);
}
fn gpuMod3Input(t: *const Modulo3(0), input: []const u8, layers: usize) Gpu.CountInput {
    var parameters = Gpu.CountInput{ .kind = .mod3, .bytes = input };
    for (0..layers) |level| {
        parameters.initial[level] = t.index[level];
        parameters.warmup[level] = t.warmup[level];
    }
    return parameters;
}
fn mergeGpuMod3(t: *Modulo3(0), input: []const u8, delta: []const u32, layers: usize) void {
    mergeGpuCounts(t.counts[0 .. layers * 19683], delta[0 .. layers * 19683]);
    const upper: [*]const u16 = @ptrCast(delta[layers * 19683 ..].ptr);
    for (upper[0 .. input.len >> @intCast(layers)]) |value| {
        var rem: u8 = @intCast(value);
        for (layers..16) |level| {
            t.record(level, rem);
            if (!t.odd[level]) {
                t.odd[level] = true;
                t.saved[level] = rem;
                break;
            }
            t.odd[level] = false;
            const sum = rem + t.saved[level];
            rem = if (sum >= 3) sum - 3 else sum;
        }
    }
    // A whole 1 KiB call contains complete pairs through these levels. The
    // optimized CPU's levels0..3 never mutate saved/odd, so leave those alone.
    for (0..layers) |level| {
        const group = @as(usize, 1) << @intCast(level);
        const symbols = input.len / group;
        const begin = symbols -| 9;
        var index: u32 = if (begin == 0) t.index[level] else 0;
        for (begin..symbols) |i| index = Modulo3(0).nextIndex(index, gpuTrit(input[i * group ..][0..group]));
        t.index[level] = index;
        t.warmup[level] -= @intCast(@min(symbols, t.warmup[level]));
        if (level >= 4) {
            t.odd[level] = false;
            t.saved[level] = gpuTrit(input[input.len - 2 * group ..][0..group]);
        }
    }
    // Match the existing deferred phase/scale transition at the END of a call.
    var left: u64 = input.len / 1024;
    while (left != 0) {
        const on = @as(u64, 1) << t.scale;
        if (t.phase == on) {
            t.phase = 0;
            t.scale += 1;
            continue;
        }
        const blocks = @min(left, on - t.phase);
        t.phase += blocks;
        t.total_on += blocks;
        left -= blocks;
    }
}
pub fn gpuMod3(t: *Modulo3(0), bytes: []const u8, device: *Gpu) !void {
    const layers = device.mod3Layers();
    var offset: usize = 0;
    while (offset < bytes.len) {
        const input = bytes[offset..][0..@min(bytes.len - offset, device.capacity)];
        const delta = try device.countMod3(gpuMod3Input(t, input, layers));
        mergeGpuMod3(t, input, delta, layers);
        offset += input.len;
    }
}
pub fn gpuCounters(mod3: *Modulo3(0), dc7: *Distribution(9, 0, true), bytes: []const u8, device: *Gpu) !void {
    if (!device.hasCountPair()) {
        try gpuMod3(mod3, bytes, device);
        try gpuDc7(dc7, bytes, device);
        return;
    }
    var offset: usize = 0;
    while (offset < bytes.len) {
        const input = bytes[offset..][0..@min(bytes.len - offset, device.capacity)];
        const result = try device.countPair(gpuMod3Input(mod3, input, 9), gpuDc7Input(dc7, input));
        mergeGpuMod3(mod3, input, result.mod3, 9);
        mergeGpuDc7(dc7, input, result.dc7);
        offset += input.len;
    }
}
pub fn gpuFpfParallel(t: *FloatingPattern(2), bytes: []const u8, device: *Gpu) !void {
    try gpuFpfWith16(t, null, bytes, device);
}

pub fn gpuFpfWith16(t: *FloatingPattern(2), aligned: ?*FloatingPattern(4), bytes: []const u8, device: *Gpu) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const input = bytes[offset..][0..@min(bytes.len - offset, device.fpf_capacity)];
        try device.addFpfWith16(input, &t.tail, t.started, t.counts, if (aligned) |other| other.counts else null);
        t.finishInput(input);
        if (aligned) |other| other.finishInput(input);
        offset += input.len;
    }
}

test "paired DC16 and DC32 match independently assembled windows across odd word calls" {
    inline for (.{ @as(u2, 1), @as(u2, 2) }) |units| {
        const size = 1 << @as(usize, units);
        const length = if (units == 1) 6 else 5;
        const bits = 2 + @as(usize, units);
        const Word = @Int(.unsigned, 8 * size);
        const T = Distribution(length, units, true);
        const seed: u64 = (1 << 40) + 9;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const input = try a.alloc(u8, 4097 * size);
        for (0..3) |fixture| {
            var rng = std.Random.DefaultPrng.init(0xd216);
            if (fixture == 0) rng.random().bytes(input) else @memset(input, if (fixture == 1) 0 else 255);
            const even = try a.alloc(u64, T.count_bins);
            const odd = try a.alloc(u64, T.count_bins);
            @memset(even, seed);
            @memset(odd, seed);
            var last: u32 = 0;
            for (length - 1..input.len / size) |end| {
                var index: u32 = 0;
                for (0..length) |position| {
                    const code = T.codes[(@popCount(word(Word, input, (end - (length - 1) + position) * size)) >> 1) & ((1 << bits) - 1)];
                    inline for (0..bits) |plane| index |= ((code >> @intCast(plane * length)) & 1) << @intCast(plane * length + length - 1 - position);
                }
                const counts = if (end & 1 == 0) even else odd;
                counts[index] += 1;
                last = index;
            }
            var actual = T{ .counts = try a.alloc(u64, T.count_bins), .odd_counts = try a.alloc(u64, T.count_bins) };
            @memset(actual.counts, seed);
            @memset(actual.odd_counts, seed);
            const sizes = [_]usize{ size, 2 * size, 3 * size, 7 * size, 512 * size, 9 * size, 1024 * size };
            var used: usize = 0;
            var call: usize = 0;
            while (used < input.len) : (call += 1) {
                const n = @min(sizes[call % sizes.len], input.len - used);
                actual.update(input[used..][0..n]);
                used += n;
            }
            for (even, odd, 0..) |e, o, bin| {
                try std.testing.expectEqual(e, actual.countAt(false, bin));
                try std.testing.expectEqual(o, actual.countAt(true, bin));
            }
            try std.testing.expectEqual(last, actual.index);
            try std.testing.expectEqual(@as(u8, 0), actual.warmup);
            try std.testing.expectEqual(input.len / size & 1 != 0, actual.odd);
        }
    }
}

test "Birthday radix agrees with comparison sort across widths and cutoff" {
    const a = std.testing.allocator;
    var workspace: std.ArrayList(u64) = .empty;
    defer workspace.deinit(a);
    for ([_]usize{ birthday_radix_minimum - 1, birthday_radix_minimum, birthday_radix_minimum * 2 + 17 }) |len| {
        const actual = try a.alloc(u64, len);
        defer a.free(actual);
        const expected = try a.alloc(u64, len);
        defer a.free(expected);
        for ([_]u7{ 0, 1, 8, 11, 16, 32, 63, 64 }) |bits| {
            var random = std.Random.DefaultPrng.init(0xbdad);
            const mask: u64 = if (bits == 0) 0 else @as(u64, std.math.maxInt(u64)) >> @as(u6, @intCast(64 - bits));
            for (actual) |*v| v.* = (random.random().int(u64) & mask) | ~mask;
            @memcpy(expected, actual);
            std.mem.sortUnstable(u64, expected, {}, std.sort.asc(u64));
            try birthdaySort(a, actual, &workspace, 0);
            try std.testing.expectEqualSlices(u64, expected, actual);
        }
    }
}

test "BCFN bounded narrow deltas preserve wide totals and mixed-call state" {
    const a = std.testing.allocator;
    const input = try a.alloc(u8, (1 << 20) + 3 * 1024);
    defer a.free(input);
    inline for (0..4) |units| {
        const T = BitCount(units);
        const left = try a.alloc(u64, T.count_bins);
        defer a.free(left);
        const right = try a.alloc(u64, T.count_bins);
        defer a.free(right);
        for (0..4) |fixture| {
            var random = std.Random.DefaultPrng.init(0xb0c0f0);
            if (fixture == 0) random.random().bytes(input) else @memset(input, if (fixture == 1) 0 else if (fixture == 2) 255 else 0x55);
            @memset(left, (1 << 40) + 17);
            @memset(right, (1 << 40) + 17);
            var actual = T{ .counts = left };
            var expected = T{ .counts = right };
            actual.update(input[0..1024]);
            actual.update(input[1024 .. input.len - 1024]);
            actual.update(input[input.len - 1024 ..]);
            var offset: usize = 0;
            while (offset < input.len) : (offset += 1024) expected.update(input[offset..][0..1024]);
            try std.testing.expectEqualSlices(u64, expected.counts, actual.counts);
            try std.testing.expectEqualDeep(expected.index, actual.index);
            try std.testing.expectEqualDeep(expected.warmup, actual.warmup);
            try std.testing.expectEqualDeep(expected.odd, actual.odd);
            try std.testing.expectEqualDeep(expected.saved, actual.saved);
        }
    }
}

test "blocked binary elimination matches independent row-basis ranks" {
    const a = std.testing.allocator;
    var random = std.Random.DefaultPrng.init(0xb10c0a);
    for ([_]usize{ 64, 128, 192, 256, 512 }) |size| {
        const stride = size / 64;
        const matrix = try a.alloc(u64, size * stride);
        defer a.free(matrix);
        const basis = try a.alloc(u64, size * stride);
        defer a.free(basis);
        const row = try a.alloc(u64, stride);
        defer a.free(row);
        const occupied = try a.alloc(bool, size);
        defer a.free(occupied);
        const table = try a.alloc(u64, 256 * stride);
        defer a.free(table);
        const copy = try a.alloc(u64, size * stride);
        defer a.free(copy);
        for (0..6) |fixture| {
            random.random().bytes(std.mem.sliceAsBytes(matrix));
            if (fixture == 0) @memset(matrix, 0);
            if (fixture == 1) {
                @memset(matrix, 0);
                for (0..size) |i| matrix[i * stride + i / 64] = @as(u64, 1) << @intCast(i % 64);
            }
            if (fixture == 2) @memset(matrix, ~@as(u64, 0));
            if (fixture == 4) @memcpy(matrix[matrix.len / 2 ..], matrix[0 .. matrix.len / 2]);
            if (fixture == 5) for (matrix) |*value| {
                value.* &= 0x8888888888888888;
            };
            @memset(occupied, false);
            @memset(basis, 0);
            var expected: usize = 0;
            for (0..size) |i| {
                @memcpy(row, matrix[i * stride ..][0..stride]);
                for (0..size) |col| {
                    if (row[col / 64] & (@as(u64, 1) << @intCast(col % 64)) == 0) continue;
                    if (occupied[col]) {
                        for (row, basis[col * stride ..][0..stride]) |*out, value| out.* ^= value;
                    } else {
                        occupied[col] = true;
                        expected += 1;
                        @memcpy(basis[col * stride ..][0..stride], row);
                        break;
                    }
                }
            }
            @memcpy(copy, matrix);
            try std.testing.expectEqual(expected, rankScalar(copy, size));
            inline for (.{ 4, 8 }) |width| {
                @memcpy(copy, matrix);
                try std.testing.expectEqual(expected, rankBlocked(copy, size, table, width));
            }
        }
    }
}

test "BRank retains a finite tail when its probability rounds to one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rank = try BRank.init(arena.allocator());
    rank.count = 1;
    rank.score = 40;
    var improved = Results{ .allocator = arena.allocator(), .arithmetic = .improved };
    var reference = Results{ .allocator = arena.allocator(), .arithmetic = .reference };
    try rank.results(&improved);
    try rank.results(&reference);
    try std.testing.expectEqual(@as(f64, 1), improved.items.items[0].probability());
    try std.testing.expectApproxEqRel(@as(f64, 57.70780163555854), improved.items.items[0].suspicion(), 2e-15);
    try std.testing.expectEqual(std.math.inf(f64), reference.items.items[0].suspicion());
    try std.testing.expectEqual(reference.items.items[0].kind, improved.items.items[0].kind);
}

test "Gap bin probabilities match independent geometric controls" {
    // 110-digit Decimal: q^first*(1-q^width), q=65535/65536 exactly.
    const first = [_]usize{ 400, 512, 65504, 524800 };
    const width = [_]usize{ 1, 32, 32, 128 };
    const expected = [_]f64{ 1.5165939738546544e-05, 0.00048436681848208215, 0.0001796724954994552, 6.494324547683718e-07 };
    for (first, width, expected) |a, n, control| {
        try std.testing.expectApproxEqRel(control, Gap.binProbability(a, n, .improved), 3e-15);
        try std.testing.expectEqual(pow(65535.0 / 65536.0, f(a)) - pow(65535.0 / 65536.0, f(a + n)), Gap.binProbability(a, n, .reference));
    }
}

test "Birthday raw score retains a one-count residual above 2^53" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var birthday = Birthday{ .allocator = arena.allocator() };
    birthday.lambda = 9007199254740992;
    birthday.duplicates = 9007199254740993;
    var improved = Results{ .allocator = arena.allocator(), .arithmetic = .improved };
    var reference = Results{ .allocator = arena.allocator(), .arithmetic = .reference };
    try birthday.results(&improved);
    try birthday.results(&reference);
    try std.testing.expectApproxEqRel(@as(f64, 1.0536712127723509e-8), improved.items.items[0].raw, 2e-15);
    try std.testing.expect(improved.items.items[0].suspicion() < 0);
    try std.testing.expectEqual(@as(f64, 0), reference.items.items[0].raw);
}

test "Gap startup normalization agrees with rational geometric controls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // 110-digit q^first*(1-q^width), q=65535/65536, retaining the
    // existing binary64 startup fractions. Allow for base-table rounding.
    const cases = [_]struct { blocks: u64, bin: usize, p: f64 }{
        .{ .blocks = 3, .bin = 0, .p = 0.0013122639094430152 },
        .{ .blocks = 3, .bin = 400, .p = 0.0009644016020256521 },
        .{ .blocks = 3, .bin = 512, .p = 0.027340860222117645 },
        .{ .blocks = 128, .bin = 0, .p = 4.147737398006036e-05 },
        .{ .blocks = 128, .bin = 400, .p = 4.0973364085908566e-05 },
        .{ .blocks = 128, .bin = 512, .p = 0.0013060377443233678 },
        .{ .blocks = 1024, .bin = 0, .p = 1.743774723674086e-05 },
        .{ .blocks = 1024, .bin = 400, .p = 1.7318415994077746e-05 },
        .{ .blocks = 1024, .bin = 512, .p = 0.0005529775717062096 },
    };
    for (cases) |c| {
        const model = try Gap.model(arena.allocator(), c.blocks, .improved);
        try std.testing.expectApproxEqRel(c.p, model.probabilities[c.bin], 2e-14);
    }
}

test "BCFN direct marginals agree with independent Bernoulli controls" {
    // Exact represented balance constants and 110-digit Bernoulli powers;
    // no 13-bit table folding or log/exp evaluation in the control formula.
    const cases = [_]struct { level: usize, bits: usize, ones: usize, p: f64 }{
        .{ .level = 0, .bits = 4, .ones = 0, .p = 0.10554146750993773 },
        .{ .level = 0, .bits = 4, .ones = 2, .p = 0.06007572766668173 },
        .{ .level = 0, .bits = 4, .ones = 4, .p = 0.03419597187561826 },
        .{ .level = 0, .bits = 9, .ones = 0, .p = 0.006348951935454217 },
        .{ .level = 0, .bits = 9, .ones = 4, .p = 0.002057092694906878 },
        .{ .level = 0, .bits = 9, .ones = 9, .p = 0.0005028560044306623 },
        .{ .level = 0, .bits = 13, .ones = 0, .p = 0.0006700777044178974 },
        .{ .level = 0, .bits = 13, .ones = 6, .p = 0.00012358134052434602 },
        .{ .level = 0, .bits = 13, .ones = 13, .p = 1.71956497849967e-05 },
        .{ .level = 12, .bits = 4, .ones = 0, .p = 0.06305278939364577 },
        .{ .level = 12, .bits = 4, .ones = 2, .p = 0.06249939287586419 },
        .{ .level = 12, .bits = 4, .ones = 4, .p = 0.06195085336296435 },
        .{ .level = 12, .bits = 9, .ones = 0, .p = 0.001992208020545653 },
        .{ .level = 12, .bits = 9, .ones = 4, .p = 0.001957391388013405 },
        .{ .level = 12, .bits = 9, .ones = 9, .p = 0.001914725007376828 },
        .{ .level = 12, .bits = 13, .ones = 0, .p = 0.00012561427274779697 },
        .{ .level = 12, .bits = 13, .ones = 6, .p = 0.00012233577337128292 },
        .{ .level = 12, .bits = 13, .ones = 13, .p = 0.00011861884816240272 },
        .{ .level = 19, .bits = 4, .ones = 0, .p = 0.06254871323952074 },
        .{ .level = 19, .bits = 4, .ones = 2, .p = 0.06249999525681331 },
        .{ .level = 19, .bits = 4, .ones = 4, .p = 0.06245131521960014 },
        .{ .level = 19, .bits = 9, .ones = 0, .p = 0.0019565518182635116 },
        .{ .level = 19, .bits = 9, .ones = 4, .p = 0.001953505164493974 },
        .{ .level = 19, .bits = 9, .ones = 9, .p = 0.001949703517822327 },
        .{ .level = 19, .bits = 13, .ones = 0, .p = 0.00012237979861882728 },
        .{ .level = 19, .bits = 13, .ones = 6, .p = 0.00012209406351503367 },
        .{ .level = 19, .bits = 13, .ones = 13, .p = 0.00012176154897628541 },
    };
    var probs: [8192]f64 = undefined;
    for (cases) |c| {
        const bins = @as(usize, 1) << @intCast(c.bits);
        BCFN.improvedProbabilities(c.level, c.bits, probs[0..bins]);
        const index = (@as(usize, 1) << @intCast(c.ones)) - 1;
        try std.testing.expectApproxEqRel(c.p, probs[index], 3e-15);
        var mass = s.Sum{};
        for (probs[0..bins]) |p| mass.add(p);
        try std.testing.expectApproxEqAbs(@as(f64, 1), mass.value(), 3e-15);
    }
}

test "Distribution cache preserves models and bounds payload with eviction" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const tables = try Tables.init(arena.allocator(), true, .improved);
    var cache = DistributionCache{ .allocator = a };
    defer cache.deinit();
    inline for (.{ .{ 9, 0 }, .{ 6, 1 }, .{ 5, 2 } }) |parameters| {
        const D = Distribution(parameters[0], parameters[1], false);
        for ([_]u64{ 1, 4096, 1 << 24 }) |blocks| {
            try cache.ensure(parameters[0], parameters[1], blocks, &tables);
            const actual = cache.find(parameters[0], parameters[1], blocks).?;
            var scratch = std.heap.ArenaAllocator.init(a);
            defer scratch.deinit();
            const expected = try D.model(scratch.allocator(), blocks, try tables.distribution(parameters[0], parameters[1], scratch.allocator()));
            try std.testing.expectEqualSlices(f64, expected.probabilities, actual.probabilities);
            try std.testing.expectEqualSlices(u64, expected.widths, actual.widths);
            try std.testing.expect(cache.payload_bytes <= cache.byte_limit);
        }
    }
    cache.deinit();
    for (1..DistributionCache.capacity + 1) |blocks| {
        cache.beginCheckpoint();
        try cache.ensure(9, 0, blocks, &tables);
    }
    cache.beginCheckpoint();
    try cache.ensure(9, 0, 1, &tables);
    try cache.ensure(9, 0, DistributionCache.capacity + 1, &tables);
    try std.testing.expect(cache.find(9, 0, 1) != null);
    try std.testing.expect(cache.find(9, 0, 2) == null);
    try std.testing.expect(cache.find(9, 0, DistributionCache.capacity + 1) != null);
    cache.deinit();
    cache.byte_limit = DC6.count_bins * 2 * @sizeOf(u64);
    cache.beginCheckpoint();
    try cache.ensure(9, 0, 1 << 50, &tables);
    try std.testing.expectEqual(cache.byte_limit, cache.payload_bytes);
    // Admission does not evict a model already needed by this checkpoint.
    try cache.ensure(6, 1, 1 << 50, &tables);
    try std.testing.expect(cache.find(9, 0, 1 << 50) != null);
    try std.testing.expect(cache.find(6, 1, 1 << 50) == null);
    cache.beginCheckpoint();
    try cache.ensure(6, 1, 1 << 50, &tables);
    try std.testing.expect(cache.find(9, 0, 1 << 50) == null);
    try std.testing.expect(cache.find(6, 1, 1 << 50) != null);
    try std.testing.expect(cache.payload_bytes <= cache.byte_limit);
    cache.deinit();
    cache.byte_limit = 0;
    try cache.ensure(5, 2, 1, &tables);
    try std.testing.expect(cache.find(5, 2, 1) == null);
}

test "Distribution cache allocation failure preserves an eviction candidate" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const tables = try Tables.init(arena.allocator(), true, .improved);
    var completed = false;
    for (0..8) |offset| {
        var failing = std.testing.FailingAllocator.init(a, .{});
        var cache = DistributionCache{ .allocator = failing.allocator(), .byte_limit = DC6.count_bins * 2 * @sizeOf(u64) };
        defer cache.deinit();
        try cache.ensure(9, 0, 1 << 50, &tables);
        const previous = cache.find(9, 0, 1 << 50).?;
        const payload = cache.payload_bytes;
        cache.beginCheckpoint();
        failing.fail_index = failing.alloc_index + offset;
        cache.ensure(6, 1, 1 << 50, &tables) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(payload, cache.payload_bytes);
            const preserved = cache.find(9, 0, 1 << 50).?;
            try std.testing.expectEqual(previous.probabilities.ptr, preserved.probabilities.ptr);
            try std.testing.expect(cache.find(6, 1, 1 << 50) == null);
            continue;
        };
        try std.testing.expect(cache.find(9, 0, 1 << 50) == null);
        try std.testing.expect(cache.find(6, 1, 1 << 50) != null);
        completed = true;
        break;
    }
    try std.testing.expect(completed);
}

test "Distribution shared traversal preserves crossing compact model boundaries" {
    const D = Distribution(3, 0, true);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var even: [D.count_bins]u64 = undefined;
    var odd: [D.count_bins]u64 = undefined;
    var both: [D.count_bins]u64 = undefined;
    for (&even, &odd, &both, 0..) |*e, *o, *b, i| {
        e.* = (1 << 33) + i * 17;
        o.* = (1 << 34) + (D.count_bins - i) * 31;
        b.* = e.* + o.*;
    }
    const split = D.Model{ .blocks = 17, .probabilities = &.{ 0.1, 0.2, 0.3, 0.4 }, .widths = &.{ 7, 23, 1, 33 } };
    const combined = D.Model{ .blocks = 34, .probabilities = &.{ 0.2, 0.3, 0.5 }, .widths = &.{ 16, 8, 40 } };
    const state = D{ .counts = &even, .odd_counts = &odd };
    const expected_split = try D.gather(2, .{ &even, &odd }, a, split);
    const expected_combined = try D.gather(1, .{&both}, a, combined);
    const actual = try D.gatherThree(state, a, split, combined);
    try std.testing.expectEqualSlices(u64, expected_split[0], actual[0]);
    try std.testing.expectEqualSlices(u64, expected_split[1], actual[1]);
    try std.testing.expectEqualSlices(u64, expected_combined[0], actual[2]);
}

test "Birthday key precision preserves spacings and all bits for later measurements" {
    const a = std.testing.allocator;
    var workspace: std.ArrayList(u64) = .empty;
    defer workspace.deinit(a);
    for ([_]usize{ 4095, 4096, 4097, 65536 }) |n| {
        const values = try a.alloc(u64, n);
        defer a.free(values);
        const expected = try a.alloc(u64, n);
        defer a.free(expected);
        const actual = try a.alloc(u64, n);
        defer a.free(actual);
        for (0..3) |fixture| {
            var random = std.Random.DefaultPrng.init(0xb17);
            for (values) |*value| value.* = switch (fixture) {
                0 => random.random().int(u64),
                1 => 0x1234567890000000 | (random.random().int(u64) & 0xfffff),
                else => 0x123456789abcdef0,
            };
            @memcpy(expected, values);
            std.mem.sortUnstable(u64, expected, {}, std.sort.asc(u64));
            // Refine the same surviving samples, including an entirely equal
            // coarse key and boundaries around the radix-sort cutoff.
            @memcpy(actual, values);
            for ([_]u6{ 63, 46, 33, 22, 11, 1, 0 }) |low_bits| {
                try birthdaySort(a, actual, &workspace, low_bits);
                const mask = @as(u64, std.math.maxInt(u64)) << low_bits;
                for (expected, actual) |want, got| try std.testing.expectEqual(want & mask, got & mask);
                for (1..n) |i| try std.testing.expectEqual((expected[i] & mask) - (expected[i - 1] & mask), (actual[i] & mask) - (actual[i - 1] & mask));
            }
            try std.testing.expectEqualSlices(u64, expected, actual);
        }
    }
}

test "Gap batches preserve sequential history with duplicate words and wrapping positions" {
    const Oracle = struct {
        fn update(t: *Gap, b: []const u8) void {
            if (t.autofail) return;
            if (t.warmup != 0 and b.len > 65536) {
                var offset: usize = 0;
                while (offset < b.len) {
                    const n = @min(65536, b.len - offset);
                    update(t, b[offset..][0..n]);
                    offset += n;
                }
                return;
            }
            var ofs = @as(u32, @truncate(t.blocks)) *% 512;
            const warming = t.warmup != 0;
            var i: usize = 0;
            while (i < b.len) : (i += 2) {
                const v = word(u16, b, i);
                const prior = t.last[v];
                ofs +%= 1;
                t.last[v] = ofs;
                if (warming and prior == 0) {
                    t.warmup -= 1;
                    continue;
                }
                const lag = ofs -% prior -% 1;
                const index: usize = if (lag < 512) lag else if (lag - 512 < 524288) 512 + ((lag - 512) >> 5) else 16896 + ((lag - 524800) >> 7);
                if (index < t.counts.len) t.counts[index] += 1 else t.extreme += 1;
            }
            const old = t.blocks;
            t.blocks += b.len / 1024;
            if (old >> 19 != t.blocks >> 19) {
                if (t.warmup != 0) t.autofail = true;
                var old_flags: u32 = 0;
                for (t.last) |v| old_flags |= @intFromBool(ofs -% v > 0x18000000);
                t.autofail = t.autofail or old_flags != 0;
            }
        }
    };
    const a = std.testing.allocator;
    const values = try a.alloc(u8, 256 << 10);
    defer a.free(values);
    for (0..3) |fixture| {
        var random = std.Random.DefaultPrng.init(0x6a9);
        random.random().bytes(values);
        if (fixture == 1) @memset(values, 0x55);
        if (fixture == 2) for (0..values.len / 2) |i| {
            // Repeats within a batch and across adjacent batches.
            std.mem.writeInt(u16, values[i * 2 ..][0..2], @intCast((i / 3) % 65536), .little);
        };
        for ([_]u64{ 0, (1 << 23) - 1 }) |blocks| {
            var actual = Gap{ .counts = try a.alloc(u64, Gap.count_bins), .last = try a.alloc(u32, 65536), .blocks = blocks, .warmup = if (blocks == 0) 65536 else 0 };
            defer a.free(actual.counts);
            defer a.free(actual.last);
            @memset(actual.counts, 0);
            @memset(actual.last, if (blocks == 0) 0 else @as(u32, @truncate(blocks * 512)) -% 17);
            var expected = actual;
            expected.counts = try a.dupe(u64, actual.counts);
            defer a.free(expected.counts);
            expected.last = try a.dupe(u32, actual.last);
            defer a.free(expected.last);
            var offset: usize = 0;
            for ([_]usize{ 1024, 3072, 65536, 1024, (256 << 10) - 70656 }) |n| {
                actual.update(values[offset..][0..n]);
                Oracle.update(&expected, values[offset..][0..n]);
                try std.testing.expectEqualDeep(expected, actual);
                offset += n;
            }
            try std.testing.expectEqual(values.len, offset);
        }
    }
}
