// Statistical transforms and calibration preserve PractRand 0.96's conventions.
const std = @import("std");
const builtin = @import("builtin");
const data = @import("calibration_data.zig");
// Only the reference path retains the historical target-dependent intermediates.
const ReferenceWide = if (builtin.cpu.arch == .x86_64) f80 else f64;
pub const Arithmetic = enum { improved, reference };

// Neumaier compensation keeps small centered terms and model residuals alive.
pub const Sum = struct {
    high: f64 = 0,
    low: f64 = 0,
    pub fn add(sum: *Sum, term: f64) void {
        @setFloatMode(.strict);
        const next = sum.high + term;
        // Preserve legitimate infinite tails; compensation of infinity is undefined.
        if (!std.math.isFinite(next)) {
            sum.high = next;
            sum.low = 0;
            return;
        }
        sum.low += if (@abs(sum.high) >= @abs(term)) (sum.high - next) + term else (term - next) + sum.high;
        sum.high = next;
    }
    pub fn addProduct(sum: *Sum, a: f64, b: f64) void {
        const product = a * b;
        sum.add(product);
        if (std.math.isFinite(product)) sum.add(@mulAdd(f64, a, b, -product));
    }
    pub fn addInteger(sum: *Sum, n: u64) void {
        sum.add(f(n >> 32) * 4294967296);
        sum.add(f(@as(u32, @truncate(n))));
    }
    pub fn scale(sum: *Sum, factor: f64) void {
        @setFloatMode(.strict);
        const high = sum.high * factor;
        sum.low = if (std.math.isFinite(high)) sum.low * factor + @mulAdd(f64, sum.high, factor, -high) else 0;
        sum.high = high;
    }
    pub fn value(sum: Sum) f64 {
        return sum.high + sum.low;
    }
};
pub fn f(x: anytype) f64 {
    return @floatFromInt(x);
}
// Retain integer low bits before subtracting a nearby binary64 expectation.
pub fn countDifference(count: u64, expected: f64) f64 {
    const high = f(count);
    const low = (f(count >> 32) * 4294967296 - high) + f(@as(u32, @truncate(count)));
    return (high - expected) + low;
}
fn countResidual(count: u64, total: Sum, probability_value: f64) f64 {
    const expected = total.high * probability_value;
    const low = @mulAdd(f64, total.high, probability_value, -expected) + total.low * probability_value;
    return countDifference(count, expected) - low;
}
pub fn pow(x: f64, y: f64) f64 {
    return std.math.pow(f64, x, y);
}
pub fn normal(chis: f64, dof: f64) f64 {
    return (chis - dof) / @sqrt(dof);
}
pub fn suspicion(p: f64, arithmetic: Arithmetic) f64 {
    if (p > 0.5) return -suspicion(1 - p, arithmetic);
    if (arithmetic == .improved and p >= 0.25) return std.math.log1p(2 * p - 1) / @log(@as(f64, 2));
    return @log(p) / @log(@as(f64, 2)) + 1;
}
pub fn probability(s: f64) f64 {
    return if (s < 0) pow(2, s - 1) else 1 - pow(0.5, s + 1);
}
pub fn rawSuspicion(raw: f64) f64 {
    const m = @abs(raw);
    const sign: f64 = if (raw < 0) 1 else -1;
    const edges = [_]f64{ 8, 12, 16, 20, 24, 28 };
    const offsets = [_]f64{ 0, 4, 7, 11, 16, 22, 29 };
    var low: f64 = 0;
    for (edges, 0..) |edge, i| {
        if (m < edge) return sign * (offsets[i] + (m - low) * (0.5 + f(i) * 0.25));
        low = edge;
    }
    return sign * ((m - 28) * 2 + 29);
}
fn referenceGTest(probs: ?[]const f64, counts: []const u64) f64 {
    var total: ReferenceWide = 0;
    var sum: ReferenceWide = 0;
    for (counts, 0..) |count, i| {
        const observed: ReferenceWide = @floatFromInt(count);
        total += observed;
        if (count != 0) sum += observed * @log(observed / @as(ReferenceWide, if (probs) |p| p[i] else 1));
    }
    const divisor: f64 = if (probs == null) f(counts.len) else 1;
    sum -= total * @as(ReferenceWide, @log(@as(f64, @floatCast(total)) / divisor));
    return @as(f64, @floatCast(sum)) * 2;
}
fn centeredDeviance(observed: f64, expected: f64, delta: f64) f64 {
    @setFloatMode(.strict);
    const d = delta / expected;
    if (@abs(d) < 0.01) {
        var series: f64 = 1.0 / 90.0;
        inline for (0..8) |j| {
            const k = 9 - j;
            series = @as(f64, if (k % 2 == 0) 1.0 else -1.0) / @as(f64, k * (k - 1)) + d * series;
        }
        return expected * d * d * series;
    }
    if (@abs(d) <= 0.5) {
        // log(1+d)=2*atanh(v), v=d/(2+d). Cancel its linear part
        // algebraically; |v|<=1/3 makes the remaining odd series converge fast.
        const v = d / (2 + d);
        const square = v * v;
        var term = v * square;
        var sum = Sum{};
        var k: usize = 3;
        while (true) : (k += 2) {
            const contribution = term / f(k);
            sum.add(contribution);
            term *= square;
            if (@abs(term / f(k + 2)) <= @abs(sum.value()) * 0x1p-55 * (1 - square)) break;
        }
        return expected * @mulAdd(f64, 2 * (1 + d), sum.value(), d * v);
    }
    return @mulAdd(f64, observed, if (d < -0.5) @log(observed / expected) else if (!std.math.isFinite(d)) @log(observed) - @log(expected) else std.math.log1p(d), -delta);
}

// FPF's nominal expected counts need not sum to its observed total. Keep the
// signed linear residual separate from the small, nonnegative deviance terms.
pub const NominalGTest = struct {
    deviance: Sum = .{},
    residual: Sum = .{},
    pub fn add(t: *NominalGTest, counts: []const u64, expected: f64) void {
        for (counts) |count| {
            const delta = countDifference(count, expected);
            t.residual.add(delta);
            const term = if (count == 0) expected else if (expected == 0) std.math.inf(f64) else centeredDeviance(f(count), expected, delta);
            t.deviance.add(term);
        }
    }
    pub fn value(t: NominalGTest) f64 {
        var sum = t.deviance;
        sum.add(t.residual.high);
        sum.add(t.residual.low);
        return 2 * sum.value();
    }
};

// Center at expected counts before taking logarithms. For small d, evaluate
// (1+d)*log1p(d)-d as a series, rather than cancelling its linear terms.
// Explicit models need the linear residual N*(1-sum(p)); do not renormalize them.
pub fn gTest(probs: ?[]const f64, counts: []const u64, arithmetic: Arithmetic) f64 {
    @setFloatMode(.strict);
    if (arithmetic == .reference) return referenceGTest(probs, counts);
    var total = Sum{};
    for (counts) |count| {
        total.add(@as(f64, @floatFromInt(count >> 32)) * 4294967296);
        total.add(@floatFromInt(@as(u32, @truncate(count))));
    }
    if (total.high == 0) return std.math.nan(f64);
    var model = Sum{};
    var deviance = Sum{};
    const bins: f64 = @floatFromInt(counts.len);
    for (counts, 0..) |count, i| {
        const observed: f64 = @floatFromInt(count);
        const observed_low = (@as(f64, @floatFromInt(count >> 32)) * 4294967296 - observed) + @as(f64, @floatFromInt(@as(u32, @truncate(count))));
        const expected = if (probs) |p| total.high * @as(f64, p[i]) else total.high / bins;
        // Recover product/division rounding so a one-count difference survives
        // even when the expected count is larger than f64's exact-integer range.
        const expected_low = if (probs) |p| @mulAdd(f64, total.high, p[i], -expected) + total.low * p[i] else (@mulAdd(f64, -expected, bins, total.high) + total.low) / bins;
        if (probs) |p| model.add(p[i]);
        if (expected == 0) {
            if (count != 0) return std.math.inf(f64);
            continue;
        }
        const delta = (observed - expected) + (observed_low - expected_low);
        const term = if (count == 0) expected + expected_low else centeredDeviance(observed, expected, delta);
        if (!std.math.isFinite(term)) return @floatCast(term);
        deviance.add(term);
    }
    if (probs != null) {
        // Keep the model's tiny departure from one separate from the nonlinear
        // terms. The residual can be negative for an over-normalized model.
        const residual = (1 - model.high) - model.low;
        deviance.add(total.high * residual);
        deviance.add(total.low * residual);
    }
    return @floatCast(2 * deviance.value());
}

// Carry a calibrated log-tail into probability combinations without first
// rounding a tiny probability to zero (or its complement to one).
pub fn logProbability(score: f64) f64 {
    return if (score < 0) (score - 1) * @log(@as(f64, 2)) else std.math.log1p(-pow(0.5, score + 1));
}

// Adjacent-bin merging is part of the calibrated test, including its tie rules.
pub fn simplify(probs: []f64, counts: []u64, samples: f64) usize {
    const n = probs.len;
    if (n <= 2) return n;
    const minimum = 1 / @max(samples, 2);
    var combined: usize = 0;
    var j: isize = 0;
    while (j < n) : (j += 1) {
        const i: usize = @intCast(j);
        if (n - combined <= 2) {
            probs[i - combined] = probs[i];
            counts[i - combined] = counts[i];
            continue;
        }
        const below = if (i > combined) probs[i - combined - 1] else 9;
        const above = if (i + 1 < n) probs[i + 1] else 9;
        const other = @min(below, above);
        const current = probs[i];
        if (current < minimum and other >= current and other < 0.5) {
            if (below < above) {
                probs[i] += probs[i - combined - 1];
                counts[i] += counts[i - combined - 1];
                combined += 1;
                j -= 1;
            } else {
                probs[i + 1] += probs[i];
                counts[i + 1] += counts[i];
                combined += 1;
            }
            if (j + 1 > combined and probs[@as(usize, @intCast(j)) - combined] < minimum) {
                const from = @as(usize, @intCast(j)) - combined;
                probs[@intCast(j)] = probs[from];
                counts[@intCast(j)] = counts[from];
                j -= 1;
            }
        } else if (combined != 0) {
            probs[i - combined] = probs[i];
            counts[i - combined] = counts[i];
        }
    }
    return n - combined;
}
// A compile-time policy keeps reference sums exactly in their old order.
pub fn Accumulator(comptime arithmetic: Arithmetic) type {
    return if (arithmetic == .improved) Sum else struct {
        high: f64 = 0,
        pub fn add(sum: *@This(), term: f64) void {
            sum.high += term;
        }
        pub fn scale(sum: *@This(), factor: f64) void {
            sum.high *= factor;
        }
        pub fn value(sum: @This()) f64 {
            return sum.high;
        }
    };
}
fn orderedRarityScore(p: f64, arithmetic: Arithmetic) f64 {
    // Rounded cumulative tail midpoints can fall just outside [0, 1].
    // Their limiting score already exceeds the statistic's existing cap.
    if (p <= 0 or p >= 1) return 35;
    return @min(-@log(p) - (if (arithmetic == .improved) std.math.log1p(-p) else @log(1 - p)), 35);
}

pub fn rarity(probs: []const f64, counts: []const u64, arithmetic: Arithmetic) f64 {
    return switch (arithmetic) {
        .improved => centeredRarity(true, probs, counts),
        .reference => rarityWith(.reference, probs, counts),
    };
}
fn rarityWith(comptime arithmetic: Arithmetic, probs: []const f64, counts: []const u64) f64 {
    var mean = Accumulator(arithmetic){};
    var cumulative = Accumulator(arithmetic){};
    var midpoint: usize = 0;
    var mid_distance: f64 = 1.5;
    for (probs, 0..) |p, i| {
        const middle = cumulative.value() + p * 0.5;
        mean.add(p * orderedRarityScore(middle, arithmetic));
        cumulative.add(p);
        if (@abs(middle - 0.5) < mid_distance) {
            midpoint = i;
            mid_distance = @abs(cumulative.value() - 0.5);
        }
    }
    var variance = Accumulator(arithmetic){};
    var actual = Accumulator(arithmetic){};
    var total: u64 = 0;
    cumulative = .{};
    for (0..midpoint) |i| {
        const p = cumulative.value() + probs[i] * 0.5;
        cumulative.add(probs[i]);
        const score = orderedRarityScore(p, arithmetic) - mean.value();
        variance.add(score * score * probs[i]);
        actual.add(score * f(counts[i]));
        total += counts[i];
    }
    cumulative = .{};
    var i = probs.len;
    while (i > midpoint) {
        i -= 1;
        const p = cumulative.value() + probs[i] * 0.5;
        cumulative.add(probs[i]);
        const score = orderedRarityScore(p, arithmetic) - mean.value();
        variance.add(score * score * probs[i]);
        actual.add(score * f(counts[i]));
        total += counts[i];
    }
    return actual.value() / @sqrt(variance.value() * f(total));
}
fn centeredRarity(comptime ordered: bool, probs: []const f64, counts: []const u64) f64 {
    var total = Sum{};
    var mass = Sum{};
    var midpoint: usize = if (ordered) 0 else probs.len;
    var mid_distance: f64 = 1.5;
    for (probs, counts, 0..) |p, count, i| {
        const middle = mass.value() + p * 0.5;
        total.addInteger(count);
        mass.add(p);
        if (ordered and @abs(middle - 0.5) < mid_distance) {
            midpoint = i;
            mid_distance = @abs(mass.value() - 0.5);
        }
    }
    const missing_mass = (1 - mass.high) - mass.low;
    var mean = Sum{};
    var model_bias = Sum{};
    var variance = Sum{};
    var actual = Sum{};
    // Both passes use identical score weights. Ordered rarity's mean uses the
    // forward CDF, whereas its upper-half actual scores use the reverse CDF.
    // Their difference is zero for an exactly normalized model; retain it for
    // represented non-unit models rather than silently renormalizing them.
    for (0..2) |pass| {
        var cumulative = Sum{};
        for (0..probs.len) |j| {
            if (j == midpoint) cumulative = .{};
            const i = if (j < midpoint) j else probs.len - 1 - (j - midpoint);
            const middle = cumulative.value() + probs[i] * 0.5;
            cumulative.add(probs[i]);
            const weight = if (ordered) orderedRarityScore(middle, .improved) else @min(-@log(probs[i]), 750);
            if (pass == 0) {
                // 1 - forward_midpoint = reverse_midpoint + (1 - sum(p)).
                const mean_weight = if (ordered and j >= midpoint) orderedRarityScore(middle + missing_mass, .improved) else weight;
                mean.addProduct(probs[i], mean_weight);
                // Preserve a tiny non-unit model residual before subtracting
                // nearly equal logarithmic weights. Capped scores keep their
                // original piecewise meaning outside the uncapped interior.
                const uncapped = ordered and j >= midpoint and weight < 35 and mean_weight < 35;
                // log((q+m)*(1-q-m)/(q*(1-q))), centered before the
                // logarithm. This also retains the quadratic term at q=1/2.
                const shift = if (uncapped) (missing_mass / middle) * ((1 - 2 * middle) - missing_mass) / (1 - middle) else 0;
                const bias = if (uncapped and shift > -0.5) std.math.log1p(shift) else weight - mean_weight;
                model_bias.addProduct(probs[i], bias);
            } else {
                const score = weight - mean.value();
                variance.addProduct(score * score, probs[i]);
                actual.addProduct(weight, countResidual(counts[i], total, probs[i]));
            }
        }
    }
    actual.addProduct(total.high, model_bias.value());
    actual.addProduct(total.low, model_bias.value());
    return actual.value() / @sqrt(variance.value() * total.value());
}

const ref_p = blk: {
    var values: [129]f64 = undefined;
    const tail = [_]f64{ 1e-7, 2e-7, 5e-7, 1e-6, 2e-6, 5e-6, 1e-5, 2e-5, 5e-5, 1e-4, 2e-4, 5e-4, 0.001, 0.002, 0.005 };
    for (tail, 0..) |p, i| {
        values[i] = p;
        values[128 - i] = 1 - p;
    }
    for (15..114) |i| values[i] = @as(f64, @floatFromInt(i - 14)) / 100;
    break :blk values;
};
fn sampleAt(row: *const data.Row, p: f64) f64 {
    const index = probabilityIndex(p, row.limit);
    if (index <= f(row.limit)) return row.values[row.limit];
    if (index >= f(128 - row.limit)) return row.values[128 - row.limit];
    const lo: usize = @intFromFloat(@floor(index));
    // Preserve the upstream interpolation expression used to derive tail slopes.
    return row.values[lo] + row.values[lo + 1] * (index - @floor(index));
}
fn probabilityIndex(p: f64, limit: usize) f64 {
    if (p > 0.5) return 128 - probabilityIndex(1 - p, limit);
    if (p >= 0.01) return p * 100 + 14;
    var i = limit;
    while (p >= ref_p[i + 1]) i += 1;
    return if (p <= ref_p[i]) f(i) else f(i) + (p - ref_p[i]) / (ref_p[i + 1] - ref_p[i]);
}
pub fn calibration(name: []const u8, blocks: u64) ?usize {
    // Imported rows are sorted by name and block count; only neighbors can win.
    var lo: usize = 0;
    var hi: usize = data.rows.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (std.mem.order(u8, data.rows[mid].name, name) == .lt) lo = mid + 1 else hi = mid;
    }
    var lower: ?usize = null;
    for (data.rows[lo..], lo..) |*row, index| {
        if (!std.mem.eql(u8, row.name, name)) break;
        if (row.blocks >= blocks) {
            const previous = lower orelse return index;
            const target = @log(f(blocks));
            return if (@abs(@log(f(row.blocks)) - target) < @abs(@log(f(data.rows[previous].blocks)) - target)) index else previous;
        }
        lower = index;
    }
    return lower;
}
pub fn minimumLength(name: []const u8) u64 {
    return data.rows[calibration(name, 0) orelse return 0].blocks;
}
const Prepared = struct {
    middle: f64,
    p1: f64,
    low: f64,
    high: f64,
    low_a: f64,
    low_b: f64,
    high_a: f64,
    high_b: f64,
};
const prepared = blk: {
    @setEvalBranchQuota(1_000_000);
    var values: [data.rows.len]Prepared = undefined;
    for (&data.rows, 0..) |*row, row_index| {
        const thresholds = [_]u64{ 100000000, 25000000, 4000000, 1000000, 250000, 40000, 10000, 2500, 1112, 625, 400, 205, 100 };
        const p1s = [_]f64{ 0.0001, 0.0002, 0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.03, 0.04, 0.05, 0.07, 0.1 };
        const p2s = [_]f64{ 0.0002, 0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.04, 0.06, 0.08, 0.10, 0.14, 0.2 };
        var p1: f64 = 0;
        var p2: f64 = 0;
        for (thresholds, 0..) |n, i| if (row.samples >= n) {
            p1 = p1s[i];
            p2 = p2s[i];
            break;
        };
        const middle = if (p1 == 0) 0 else sampleAt(row, 0.5);

        var value = Prepared{ .middle = middle, .p1 = p1, .low = 0, .high = 0, .low_a = 0, .low_b = 0, .high_a = 0, .high_b = 0 };
        if (p1 != 0) {
            value.low = sampleAt(row, p1);
            value.high = sampleAt(row, 1 - p1);
            value.low_a = @min((sampleAt(row, p2) - value.low) / (suspicion(p2, .reference) - suspicion(p1, .reference)), 100);
            value.low_b = value.low - suspicion(p1, .reference) * value.low_a;
            value.high_a = @min((sampleAt(row, 1 - p2) - value.high) / (suspicion(1 - p2, .reference) - suspicion(1 - p1, .reference)), 100);
            value.high_b = value.high - suspicion(1 - p1, .reference) * value.high_a;
        }
        values[row_index] = value;
    }
    break :blk values;
};
pub fn calibrated(row_index: usize, input: f64, extrapolate: bool, arithmetic: Arithmetic) f64 {
    if (std.math.isNan(input)) return input;
    const row = &data.rows[row_index];
    const meta = prepared[row_index];
    const middle = meta.middle;
    var sample = input;
    if (sample < middle - 0.001) sample += 0.001 else if (sample > middle + 0.001) sample -= 0.001;
    if (extrapolate and meta.p1 != 0) {
        if (sample < meta.low) return (sample - meta.low_b) / meta.low_a;
        if (sample > meta.high) return (sample - meta.high_b) / meta.high_a;
    }
    if (sample <= row.values[row.limit]) return suspicion(ref_p[row.limit], arithmetic);
    if (sample >= row.values[128 - row.limit]) return suspicion(ref_p[128 - row.limit], arithmetic);
    var low: usize = row.limit + 1;
    var high: usize = 127 - row.limit;
    var lower: usize = undefined;
    var fraction: f64 = undefined;
    while (true) {
        const mid = (low + high) / 2;
        const value = row.values[mid];
        if (value < sample) {
            low = mid + 1;
            if (high < low) {
                lower = mid;
                fraction = (sample - value) / (row.values[mid + 1] - value);
                break;
            }
        } else if (value > sample) {
            high = mid - 1;
            if (high < low) {
                lower = mid - 1;
                fraction = (sample - row.values[mid - 1]) / (value - row.values[mid - 1]);
                break;
            }
        } else {
            lower = mid;
            fraction = 0;
            break;
        }
    }
    return suspicion(interpolatedProbability(lower, fraction, arithmetic), arithmetic);
}
fn interpolatedProbability(lower: usize, fraction: f64, arithmetic: Arithmetic) f64 {
    if (arithmetic == .reference) {
        const index = f(lower) + fraction;
        const lo: usize = @intFromFloat(@floor(index));
        return ref_p[lo] + (ref_p[lo + 1] - ref_p[lo]) * (index - f(lo));
    }
    return @mulAdd(f64, ref_p[lower + 1] - ref_p[lower], fraction, ref_p[lower]);
}

test "calibration preserves NaN for fatal result validation" {
    for (0..data.rows.len) |row| {
        try std.testing.expect(std.math.isNan(calibrated(row, std.math.nan(f64), false, .improved)));
        try std.testing.expect(std.math.isNan(calibrated(row, std.math.nan(f64), true, .improved)));
    }
}

// log1p(x)-x without cancelling its linear term near zero.
pub fn log1pMinusX(x: f64) f64 {
    @setFloatMode(.strict);
    if (@abs(x) >= 0.01) return std.math.log1p(x) - x;
    var series: f64 = -1.0 / 12.0;
    inline for (0..10) |j| {
        const k = 11 - j;
        series = @as(f64, if (k % 2 == 0) -1.0 else 1.0) / @as(f64, k) + x * series;
    }
    return x * x * series;
}

// Preserve the low integer bits before forming lambda-n above 2^53.
pub fn poissonLogTail(lambda: f64, n: u64) f64 {
    const high = f(n);
    const d = -countDifference(n, lambda) / high;
    // Forming d can round to -1 for a positive but very small lambda/n.
    if (d < -0.5) {
        const ratio = lambda / high;
        const log_ratio = if (ratio > 0) @log(ratio) else @log(lambda) - @log(high);
        return high * log_ratio + (high - lambda);
    }
    return high * log1pMinusX(d);
}

fn nextPoissonTerm(term: Sum, lambda: f64, divisor: f64) Sum {
    var product = term;
    product.scale(lambda);
    const high = product.high / divisor;
    return .{ .high = high, .low = (@mulAdd(f64, -high, divisor, product.high) + product.low) / divisor };
}
// Birthday's existing small-lambda branch (lambda<=64 and norm<4).
// Preserve its midpoint convention: P(X<n)+P(X=n)/2, or its direct complement.
pub fn smallPoissonSuspicion(lambda: f64, n: u64) f64 {
    var term = Sum{ .high = @exp(-lambda) };
    var sum = Sum{};
    for (0..@intCast(n)) |i| {
        if (f(n) <= lambda) {
            sum.add(term.high);
            sum.add(term.low);
        }
        term = nextPoissonTerm(term, lambda, f(i + 1));
    }
    sum.add(term.high * 0.5);
    sum.add(term.low * 0.5);
    if (f(n) <= lambda) {
        if (sum.value() <= 0.5) return suspicion(sum.value(), .improved);
        // At the mean, Poisson skew can put the lower midpoint CDF just over
        // one half. Reuse P(X=n) and evaluate its smaller complement directly.
        sum = .{ .high = term.high * 0.5, .low = term.low * 0.5 };
    }
    var k = n;
    while (term.value() != 0) {
        k += 1;
        term = nextPoissonTerm(term, lambda, f(k));
        sum.add(term.high);
        sum.add(term.low);
        // Subsequent ratios decrease, so the geometric bound includes every
        // omitted term. Stop below a quarter of a binary64 relative ulp.
        const ratio = lambda / f(k + 1);
        if (term.value() * ratio <= sum.value() * 0x1p-54 * (1 - ratio)) break;
    }
    return -suspicion(sum.value(), .improved);
}

// Input is ln(p); use expm1 for the complementary tail near p=1.
pub fn suspicionFromLogP(log_p: f64) f64 {
    if (log_p > 0) return std.math.nan(f64);
    const ln2 = @log(@as(f64, 2));
    if (log_p > -ln2) return -(@log(-std.math.expm1(log_p)) / ln2 + 1);
    return (log_p + ln2) / ln2;
}

pub fn chiSquare4Suspicion(chis: f64) f64 {
    if (chis < 0) return std.math.nan(f64);
    if (chis == std.math.inf(f64)) return -std.math.inf(f64);
    // Avoid underflow even when dividing the smallest positive chis by two.
    if (chis > 0 and chis < 2e-150) return 2 - 2 * @log(chis) / @log(@as(f64, 2));
    const x = chis / 2;
    return suspicionFromLogP(log1pMinusX(x));
}

// DC7's two-component Fisher statistic and its retained signed log-tail.
pub fn combineTwoSuspicions(first: f64, second: f64) struct { chis: f64, suspicion: f64 } {
    @setFloatMode(.strict);
    const chis = -2 * (logProbability(first) + logProbability(second));
    if (first > 512 and second > 512) {
        // q_i=1-p_i=2^(-s_i-1). Here x=-ln(p1*p2) is q1+q2
        // to relative error <2^-512, and 1-exp(-x)*(1+x) is x^2/2
        // with equally negligible relative error. Scale by the larger q
        // before taking log2; neither q nor x needs to be representable.
        const smaller = @min(first, second);
        if (std.math.isInf(smaller)) return .{ .chis = chis, .suspicion = smaller };
        const correction = 2 * (1 - std.math.log1p(pow(0.5, @abs(first - second))) / @log(@as(f64, 2)));
        return .{ .chis = chis, .suspicion = @mulAdd(f64, 2, smaller, correction) };
    }
    return .{ .chis = chis, .suspicion = chiSquare4Suspicion(chis) };
}

// Reference mode preserves upstream's regularized-gamma evaluation at DoF = 4.
pub fn chiSquare4Tail(chis: f64, arithmetic: Arithmetic) f64 {
    if (arithmetic == .improved) {
        if (chis < 0) return std.math.nan(f64);
        if (chis == std.math.inf(f64)) return 0;
        const x = chis / 2;
        // The log form also avoids losing accuracy near zero or underflowing
        // exp(-x) before multiplication can restore a representable tail.
        return if (x >= 1 and x < 700) @exp(-x) * (1 + x) else @exp(log1pMinusX(x));
    }
    // An underflowed component probability gives DC7 an infinite statistic.
    if (chis == std.math.inf(f64)) return 0;
    const x = chis / 2;
    var p = (1 - @exp(-x)) - @exp(@log(x) - x);
    if (p < 0) p = 0;
    if (p > 1) p = 1;
    return 1 - p;
}

extern "c" fn frexp(f64, *c_int) f64;
extern "c" fn ldexp(f64, c_int) f64;
pub const Hamming = struct {
    bits: usize,
    pdf: []const f64,
    cdf: []const f64,
    log_cdf: []const f64 = &.{},
    pub fn init(a: std.mem.Allocator, bits: usize, arithmetic: Arithmetic) !Hamming {
        const pdf = try a.alloc(f64, bits / 2 + 1);
        const cdf = try a.alloc(f64, pdf.len);
        const log_cdf: []f64 = if (arithmetic == .improved) try a.alloc(f64, pdf.len) else &.{};
        fillWithLogs(bits, pdf, cdf, log_cdf, arithmetic);
        return .{ .bits = bits, .pdf = pdf, .cdf = cdf, .log_cdf = log_cdf };
    }
    pub fn fill(bits: usize, pdf: []f64, cdf: []f64, arithmetic: Arithmetic) void {
        fillWithLogs(bits, pdf, cdf, &.{}, arithmetic);
    }
    fn fillWithLogs(bits: usize, pdf: []f64, cdf: []f64, log_cdf: []f64, arithmetic: Arithmetic) void {
        @setFloatMode(.strict);
        if (arithmetic == .improved) {
            var sum = Sum{};
            var scaled_sum = Sum{};
            var p: f64 = 1;
            var exponent: i32 = -@as(i32, @intCast(bits));
            for (pdf, cdf, 0..) |*density, *cumulative, i| {
                if (i != 0) {
                    p /= f(i);
                    p *= f(bits + 1 - i);
                    const split = std.math.frexp(p);
                    p = split.significand;
                    exponent += split.exponent;
                    if (log_cdf.len != 0) scaled_sum.scale(std.math.ldexp(@as(f64, 1), -split.exponent));
                }
                density.* = std.math.ldexp(p, exponent);
                sum.add(density.*);
                cumulative.* = sum.value();
                if (log_cdf.len != 0) {
                    scaled_sum.add(p);
                    // Preserve the existing ordinary CDF and threshold decisions.
                    // Only subnormal/underflowed tails need the scaled log form.
                    log_cdf[i] = if (cumulative.* >= std.math.floatMin(f64)) @log(cumulative.*) else @log(scaled_sum.value()) + f(exponent) * @log(@as(f64, 2));
                }
            }
            return;
        }
        var sum: ReferenceWide = 0;
        if (bits <= 128) {
            var p: ReferenceWide = pow(0.5, f(bits));
            sum = p;
            pdf[0] = @floatCast(p);
            cdf[0] = @floatCast(sum);
            for (1..pdf.len) |i| {
                p /= @as(ReferenceWide, @floatFromInt(i));
                p *= @as(ReferenceWide, @floatFromInt(bits + 1 - i));
                sum += p;
                pdf[i] = @floatCast(p);
                cdf[i] = @floatCast(sum);
            }
        } else {
            var p: f64 = 1;
            var exponent: c_int = -@as(c_int, @intCast(bits));
            pdf[0] = if (exponent > -1070) ldexp(p, exponent) else 0;
            sum = pdf[0];
            cdf[0] = @floatCast(sum);
            for (1..pdf.len) |i| {
                p /= f(i);
                p *= f(bits + 1 - i);
                var adjustment: c_int = undefined;
                p = frexp(p, &adjustment);
                exponent += adjustment;
                pdf[i] = if (exponent > -1070) ldexp(p, exponent) else 0;
                sum += pdf[i];
                cdf[i] = @floatCast(sum);
            }
        }
    }
    pub fn score(t: Hamming, weight: usize) f64 {
        const index = @min(weight, t.bits - weight);
        return if (t.log_cdf.len != 0) -t.log_cdf[index] else -@log(t.cdf[index]);
    }
    // Lower-half conditional PDF, P(X=i | X<=threshold). No absolute tiny
    // probabilities are needed when their shared binomial scale underflows.
    pub fn conditionalPdf(t: Hamming, out: []f64) void {
        const threshold = out.len - 1;
        const denominator = t.cdf[threshold];
        if (denominator >= std.math.floatMin(f64)) {
            for (out, t.pdf[0..out.len]) |*p, density| p.* = density / denominator;
            return;
        }
        out[threshold] = 1;
        var total = Sum{ .high = 1 };
        var term = Sum{ .high = 1 };
        var i = threshold;
        while (i != 0) {
            term.scale(f(i));
            const divisor = f(t.bits + 1 - i);
            const high = term.high / divisor;
            const low = (@mulAdd(f64, -high, divisor, term.high) + term.low) / divisor;
            term = .{ .high = high, .low = low };
            i -= 1;
            out[i] = term.value();
            total.add(term.high);
            total.add(term.low);
        }
        for (out) |*p| p.* /= total.value();
    }
};
fn legacyErf(a: f64) f64 {
    if (a < 0) return -legacyErf(-a);
    if (a >= 8) return 1;
    const square = a * a;
    var x = square * a;
    var result = a - x / 3;
    var i: usize = 1;
    while (x > 1e-18) : (i += 1) {
        x *= square;
        x /= f(i * 2);
        result += x / (4 * f(i) + 1);
        x *= square;
        x /= f(i * 2 + 1);
        result -= x / (4 * f(i) + 3);
    }
    return (2 / @sqrt(@as(f64, 3.14159265358979323))) * result;
}
fn scaledErfc(x: f64) f64 {
    if (x < 2) return (1 - legacyErf(x)) * @exp(x * x);
    const square = x * x;
    var c = square;
    var d: f64 = 0;
    var result = square;
    var i: usize = 1;
    while (i < 500) : (i += 1) {
        var a = f(i) - 0.5;
        d = 1 / (1 + a * d);
        c = 1 + a / c;
        var e = c * d;
        result *= e;
        if (e == 1) break;
        a = f(i);
        d = 1 / (square + a * d);
        c = square + a / c;
        e = c * d;
        result *= e;
        if (e == 1) break;
    }
    return x / result / @sqrt(@as(f64, 3.14159265358979));
}
pub fn normalSuspicion(norm: f64, arithmetic: Arithmetic) f64 {
    if (norm < 0) return -normalSuspicion(-norm, arithmetic);
    if (arithmetic == .improved) return @import("normal_tail.zig").positiveSuspicion(norm);
    const x = norm * @sqrt(@as(f64, 0.5));
    // Infinite inputs and overflowing squares have an infinite limiting suspicion.
    if (std.math.isInf(x * x)) return std.math.inf(f64);
    return -(@log(scaledErfc(x)) - x * x) / @log(@as(f64, 2));
}

test "extreme statistics retain failing tails while NaNs remain invalid" {
    const inf = std.math.inf(f64);
    try std.testing.expectEqual(@as(f64, 0), chiSquare4Tail(inf, .improved));
    try std.testing.expectEqual(@as(f64, 0), probability(-normalSuspicion(inf, .improved)));
    try std.testing.expectEqual(@as(f64, 1), probability(-normalSuspicion(-inf, .improved)));
    for ([_]f64{ 1e154, 2e154, 1e200, std.math.floatMax(f64) }) |magnitude| {
        const positive = normalSuspicion(magnitude, .improved);
        const negative = normalSuspicion(-magnitude, .improved);
        try std.testing.expect(!std.math.isNan(positive));
        try std.testing.expectEqual(-positive, negative);
        try std.testing.expectEqual(@as(f64, 0), probability(-positive));
        try std.testing.expectEqual(@as(f64, 1), probability(-negative));
    }
    try std.testing.expectApproxEqAbs(@as(f64, 1), chiSquare4Tail(0, .improved), 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), probability(-normalSuspicion(0, .improved)), 1e-15);
    try std.testing.expect(std.math.isNan(chiSquare4Tail(std.math.nan(f64), .improved)));
    try std.testing.expect(std.math.isNan(normalSuspicion(std.math.nan(f64), .improved)));
}
pub fn unorderedRarity(probs: []const f64, counts: []const u64, arithmetic: Arithmetic) f64 {
    return switch (arithmetic) {
        .improved => centeredRarity(false, probs, counts),
        .reference => unorderedRarityWith(.reference, probs, counts),
    };
}
fn unorderedRarityWith(comptime arithmetic: Arithmetic, probs: []const f64, counts: []const u64) f64 {
    var mean = Accumulator(arithmetic){};
    for (probs) |p| mean.add(p * @min(-@log(p), 750));
    var variance = Accumulator(arithmetic){};
    var actual = Accumulator(arithmetic){};
    var total: u64 = 0;
    for (probs, counts) |p, count| {
        const score = @min(-@log(p), 750) - mean.value();
        variance.add(score * score * p);
        actual.add(score * f(count));
        total += count;
    }
    return actual.value() / @sqrt(variance.value() * f(total));
}
const MergeBin = struct {
    probability: f64,
    count: u64,
    serial: usize,
    fn compare(_: void, a: MergeBin, b: MergeBin) std.math.Order {
        const order = std.math.order(a.probability, b.probability);
        return if (order == .eq) std.math.order(a.serial, b.serial) else order;
    }
};
// Original leaves and newly merged probabilities are each ordered by the
// same (probability, insertion serial) key. Nonnegative probabilities make
// newly produced sums nondecreasing; serials resolve equal sums identically.
const MergeQueues = struct {
    entries: []MergeBin,
    leaf: usize = 0,
    merged: usize = 0,
    end: usize = 0,
    fn takeLeaf(q: MergeQueues) bool {
        return q.merged == q.end or (q.leaf < q.entries.len and MergeBin.compare({}, q.entries[q.leaf], q.entries[q.merged]) == .lt);
    }
    fn peek(q: MergeQueues) MergeBin {
        return q.entries[if (q.takeLeaf()) q.leaf else q.merged];
    }
    fn pop(q: *MergeQueues) MergeBin {
        if (q.takeLeaf()) {
            defer q.leaf += 1;
            return q.entries[q.leaf];
        }
        defer q.merged += 1;
        return q.entries[q.merged];
    }
};
pub fn simplifyUnordered(a: std.mem.Allocator, probs: []f64, counts: []u64, samples: f64) !usize {
    if (probs.len <= 2) return probs.len;
    const entries = try a.alloc(MergeBin, probs.len);
    defer a.free(entries);
    for (entries, probs, counts, 0..) |*entry, p, count, i| entry.* = .{ .probability = p, .count = count, .serial = i };
    // The serial makes every key unique; stable-sort machinery is unnecessary.
    std.mem.sortUnstable(MergeBin, entries, {}, struct {
        fn less(_: void, left: MergeBin, right: MergeBin) bool {
            return MergeBin.compare({}, left, right) == .lt;
        }
    }.less);
    var queue = MergeQueues{ .entries = entries };
    const minimum = 1 / @max(samples, 2);
    var n = entries.len;
    while (n > 2) {
        const first_was_leaf = queue.takeLeaf();
        const first = queue.pop();
        const second = queue.peek();
        if (first.probability >= minimum or second.probability >= minimum) {
            if (first_was_leaf) queue.leaf -= 1 else queue.merged -= 1;
            break;
        }
        _ = queue.pop();
        // M completed merges consume at least M+1 original leaves. The new
        // entry therefore fits in consumed leaf storage before remaining input.
        if (@import("builtin").is_test and queue.end >= queue.leaf) @panic("merged queue overlaps unconsumed leaves");
        entries[queue.end] = .{ .probability = first.probability + second.probability, .count = first.count + second.count, .serial = entries.len + queue.end };
        queue.end += 1;
        n -= 1;
    }
    for (0..n) |i| {
        const entry = queue.pop();
        probs[i] = entry.probability;
        counts[i] = entry.count;
    }
    return n;
}

test "ordered rarity caps rounded cumulative endpoints before logarithms" {
    for ([_]f64{ -2.220446049250313e-16, 0, 1, 1.0000000000000002 }) |p| {
        try std.testing.expectEqual(@as(f64, 35), orderedRarityScore(p, .improved));
    }
    try std.testing.expectApproxEqAbs(-2 * @log(@as(f64, 0.5)), orderedRarityScore(0.5, .improved), 1e-15);
    const probs = [_]f64{ 0.25, 0.75, 4e-16, 1e-17 };
    const counts = [_]u64{ 250, 750, 0, 0 };
    try std.testing.expect(std.math.isFinite(rarity(&probs, &counts, .improved)));
}

test "centered G-test matches independent 110-digit logarithmic controls" {
    // Controls evaluate 2*sum(n*ln(n/(N*p))) with Python Decimal at 110
    // digits; f64 probabilities are converted exactly with Decimal.from_float.
    try std.testing.expectApproxEqRel(@as(f64, 0.2003346738542735), gTest(null, &.{ 11, 9 }, .improved), 2e-13);
    try std.testing.expectApproxEqRel(@as(f64, 0.0020000003333334668), gTest(null, &.{ 1001, 999 }, .improved), 2e-13);
    try std.testing.expectApproxEqRel(@as(f64, 2e-09), gTest(null, &.{ 1000000001, 999999999 }, .improved), 2e-13);
    try std.testing.expectApproxEqRel(@as(f64, 2e-15), gTest(null, &.{ 1000000000000001, 999999999999999 }, .improved), 2e-13);
    try std.testing.expectApproxEqRel(@as(f64, 2e-18), gTest(null, &.{ 1000000000000000001, 999999999999999999 }, .improved), 2e-13);
    try std.testing.expectApproxEqRel(@as(f64, 2.168404344971009e-19), gTest(null, &.{ 9223372036854775809, 9223372036854775807 }, .improved), 2e-13);
    try std.testing.expectApproxEqRel(@as(f64, 27.725887222397812), gTest(null, &.{ 0, 20 }, .improved), 2e-13);
    try std.testing.expectApproxEqRel(@as(f64, 1.3862943611198904e+18), gTest(null, &.{ 1, 1000000000000000000 }, .improved), 2e-13);
    try std.testing.expectApproxEqRel(@as(f64, 60.81976621622466), gTest(&.{ 0.25, 0.5 }, &.{ 25, 75 }, .improved), 2e-13);
    try std.testing.expectApproxEqRel(@as(f64, -4.4408920985006256e-07), gTest(&.{ 0.5, 0.5000000000000001 }, &.{ 1000000000, 1000000000 }, .improved), 2e-13);
    try std.testing.expectApproxEqRel(@as(f64, 333.06690738754696), gTest(&.{ 0.3333333333333333, 0.3333333333333333, 0.3333333333333333 }, &.{ 1000000000000000000, 1000000000000000000, 1000000000000000000 }, .improved), 2e-13);
    try std.testing.expectApproxEqRel(@as(f64, 2.5833333333332755e-12), gTest(&.{ 0.125, 0.375, 0.5 }, &.{ 1000000000001, 2999999999998, 4000000000001 }, .improved), 2e-13);
    try std.testing.expectEqual(@as(f64, 0), gTest(&.{ 0.5, 0.5, 0 }, &.{ 10, 10, 0 }, .improved));
    try std.testing.expectEqual(std.math.inf(f64), gTest(&.{ 0, 1 }, &.{ 1, 1 }, .improved));
    try std.testing.expect(std.math.isNan(gTest(null, &.{ 0, 0 }, .improved)));
    const probs = [_]f64{ 0.5, 0.5 };
    const counts = [_]u64{ 1000000001, 999999999 };
    try std.testing.expectEqual(referenceGTest(&probs, &counts), gTest(&probs, &counts, .reference));
}

test "direct DC7 survival retains finite and subnormal tails and reference arithmetic" {
    for ([_]f64{ 1e-20, 2e-16, 1e-12, 1e-8 }) |chis| try std.testing.expectEqual(@as(f64, 1), chiSquare4Tail(chis, .improved));
    try std.testing.expectApproxEqRel(@as(f64, 1.0), chiSquare4Tail(0, .improved), 2e-14);
    try std.testing.expectApproxEqRel(@as(f64, 0.9097959895689501), chiSquare4Tail(1, .improved), 2e-14);
    try std.testing.expectApproxEqRel(@as(f64, 0.40600584970983805), chiSquare4Tail(4, .improved), 2e-14);
    try std.testing.expectApproxEqRel(@as(f64, 9.83662422461598e-21), chiSquare4Tail(100, .improved), 2e-14);
    try std.testing.expectApproxEqRel(@as(f64, 3.569412779777384e-215), chiSquare4Tail(1000, .improved), 2e-14);
    try std.testing.expectEqual(@as(f64, 1.5e-323), chiSquare4Tail(1500, .improved));
    try std.testing.expectEqual(@as(f64, 0), chiSquare4Tail(100, .reference));
    try std.testing.expect(std.math.isNan(chiSquare4Tail(-1, .improved)));
    try std.testing.expectEqual(std.math.inf(f64), -logProbability(-std.math.inf(f64)));
    try std.testing.expectApproxEqRel(@as(f64, -1386.9875083004506), logProbability(-2000), 1e-15);
    try std.testing.expect(logProbability(60) < 0);
}

test "near-neutral scores retain first-order information" {
    // Decimal ln(2*p)/ln(2), with the binary64 input converted exactly.
    const below_half: f64 = @bitCast(@as(u64, 0x3fdfffffffffffff));
    try std.testing.expectApproxEqRel(@as(f64, -1.6017132519074589e-16), suspicion(below_half, .improved), 2e-15);
    try std.testing.expectEqual(@as(f64, 0), suspicion(0.5, .improved));
    try std.testing.expectEqual(@log(below_half) / @log(@as(f64, 2)) + 1, suspicion(below_half, .reference));
    // sqrt(2/pi)/ln(2) is the derivative at zero; higher terms here are <1e-36.
    try std.testing.expectApproxEqRel(@as(f64, 1.1511040990721626e-18), normalSuspicion(1e-18, .improved), 2e-15);
    try std.testing.expectEqual(-normalSuspicion(1e-18, .improved), normalSuspicion(-1e-18, .improved));
    try std.testing.expectEqual(-(@log(scaledErfc(0.25)) - 0.0625) / @log(@as(f64, 2)), normalSuspicion(0.25 / @sqrt(@as(f64, 0.5)), .reference));
}

test "DC7 log tails survive both probability endpoints" {
    // 110-digit Decimal: ln(p)=ln(1+chis/2)-chis/2, then the signed log2 tail.
    const inputs = [_]f64{ 1e-20, 1e-8, 1, 4, 100, 1600 };
    const expected = [_]f64{ 134.8771237954945, 55.150849523006784, 2.470664613274469, -0.30042758105677064, -65.46232670247667, -1143.5103742787621 };
    for (inputs, expected) |chis, control| try std.testing.expectApproxEqRel(control, chiSquare4Suspicion(chis), 2e-14);
    try std.testing.expectEqual(@as(f64, 2150), chiSquare4Suspicion(std.math.floatTrueMin(f64)));
    try std.testing.expectEqual(std.math.inf(f64), chiSquare4Suspicion(0));
    try std.testing.expectEqual(-std.math.inf(f64), chiSquare4Suspicion(std.math.inf(f64)));
    try std.testing.expect(std.math.isNan(chiSquare4Suspicion(-1)));
    try std.testing.expect(std.math.isNan(chiSquare4Suspicion(std.math.nan(f64))));
    try std.testing.expectEqual(@as(f64, 0), suspicionFromLogP(-@log(@as(f64, 2))));
}

test "centered birthday expression matches independent decimal controls" {
    // Decimal at 110 digits: n*ln(lambda/n)+n-lambda; n remains an exact integer.
    try std.testing.expectApproxEqRel(@as(f64, -7.999989333354667), poissonLogTail(1e12, 1000004000000), 2e-15);
    try std.testing.expectApproxEqRel(@as(f64, -8.000010666688), poissonLogTail(1e12, 999996000000), 2e-15);
    try std.testing.expectApproxEqRel(@as(f64, -5.421010862427522e-20), poissonLogTail(9223372036854775808, 9223372036854775809), 2e-15);
    try std.testing.expectEqual(@as(f64, 0), poissonLogTail(1e12, 1000000000000));
    try std.testing.expectApproxEqRel(@as(f64, -4.044653167389282e19), poissonLogTail(1, 1000000000000000000), 2e-15);
}

test "compensated rarity agrees with independent decimal moments" {
    var sum = Sum{};
    for ([_]f64{ 1e16, 1, -1e16 }) |value| sum.add(value);
    try std.testing.expectEqual(@as(f64, 1), sum.value());
    const probs = [_]f64{ 0.125, 0.375, 0.5 };
    const counts = [_]u64{ 13, 38, 49 };
    // 110-digit Decimal moments using ln(p), or -ln(midpoint*(1-midpoint)).
    try std.testing.expectApproxEqRel(@as(f64, 0.19091283114346252), unorderedRarity(&probs, &counts, .improved), 2e-13);
    try std.testing.expectApproxEqRel(@as(f64, 0.1255964733316152), rarity(&probs, &counts, .improved), 2e-13);
}

test "portable Hamming retains representable subnormal tails" {
    var pdf: [538]f64 = undefined;
    var cdf: [538]f64 = undefined;
    Hamming.fill(1074, &pdf, &cdf, .improved);
    // Exact binomial coefficients: 2^-1074, 1074*2^-1074.
    try std.testing.expectEqual(@as(u64, 1), @as(u64, @bitCast(pdf[0])));
    try std.testing.expectEqual(@as(u64, 1074), @as(u64, @bitCast(pdf[1])));
    try std.testing.expectEqual(@as(u64, 1075), @as(u64, @bitCast(cdf[1])));
    Hamming.fill(1074, &pdf, &cdf, .reference);
    try std.testing.expectEqual(@as(f64, 0), pdf[0]);
    var small_pdf: [5]f64 = undefined;
    var small_cdf: [5]f64 = undefined;
    Hamming.fill(8, &small_pdf, &small_cdf, .improved);
    const numerators = [_]f64{ 1, 8, 28, 56, 70 };
    var total: f64 = 0;
    for (numerators, small_pdf, small_cdf) |n, p, cumulative| {
        total += n;
        try std.testing.expectEqual(n / 256, p);
        try std.testing.expectEqual(total / 256, cumulative);
    }
}

test "nominal G-test preserves small deviances and signed total residuals" {
    // 110-digit Decimal controls: 2*sum(n*ln(n/E)), without normalizing E.
    var balanced = NominalGTest{};
    balanced.add(&.{ 1000000000001, 999999999999 }, 1e12);
    try std.testing.expectApproxEqRel(@as(f64, 2e-12), balanced.value(), 2e-15);
    var large = NominalGTest{};
    large.add(&.{ 9223372036854775809, 9223372036854775807 }, 9223372036854775808);
    try std.testing.expectApproxEqRel(@as(f64, 2.168404344971009e-19), large.value(), 2e-15);
    var mixed = NominalGTest{};
    mixed.add(&.{ 11, 9 }, 10);
    mixed.add(&.{ 23, 17 }, 20);
    try std.testing.expectApproxEqRel(@as(f64, 1.1037404201872265), mixed.value(), 2e-14);
    var above = NominalGTest{};
    above.add(&.{ 20, 20 }, 10);
    try std.testing.expectApproxEqRel(@as(f64, 55.451774444795625), above.value(), 2e-15);
    var below = NominalGTest{};
    below.add(&.{ 5, 5 }, 10);
    try std.testing.expectApproxEqRel(@as(f64, -13.862943611198906), below.value(), 2e-15);
    var zero = NominalGTest{};
    zero.add(&.{ 0, 0 }, 10);
    try std.testing.expectEqual(@as(f64, 0), zero.value());
    var impossible = NominalGTest{};
    impossible.add(&.{1}, 0);
    try std.testing.expectEqual(std.math.inf(f64), impossible.value());
}

test "centered rarity preserves exact expectations and non-unit models" {
    const probs = [_]f64{ 0.125, 0.375, 0.5 };
    const balanced = [_]u64{ 1000000000000000000, 3000000000000000000, 4000000000000000000 };
    try std.testing.expectEqual(@as(f64, 0), unorderedRarity(&probs, &balanced, .improved));
    try std.testing.expectEqual(@as(f64, 0), rarity(&probs, &balanced, .improved));
    const perturbed = [_]u64{ 1000000000000000001, 2999999999999999999, 4000000000000000000 };
    try std.testing.expectApproxEqRel(@as(f64, 8.85962282096594e-10), unorderedRarity(&probs, &perturbed, .improved), 2e-14);
    // Direct Decimal mean/variance/numerator; ordered weights use forward means
    // and reverse upper-half scores. Non-unit totals must not be normalized away.
    const nonunit = [_]f64{ 0.125, 0.375, 0.4 };
    const counts = [_]u64{ 13, 38, 49 };
    try std.testing.expectApproxEqRel(@as(f64, 5.066187667659633), rarity(&nonunit, &counts, .improved), 2e-14);
    try std.testing.expectApproxEqRel(@as(f64, 2.5268560343015913), unorderedRarity(&nonunit, &counts, .improved), 2e-14);
    try std.testing.expectApproxEqRel(@as(f64, 5.066187667659633), rarity(&nonunit, &counts, .reference), 2e-14);
    // Exact represented probabilities: preserve a tiny model-mass departure
    // through the distinct forward-mean/reverse-score correction as well.
    try std.testing.expectApproxEqRel(@as(f64, -0.0004625969117157675), rarity(&.{ 0.125, 0.375, 0.5 + 0x1p-45 }, &balanced, .improved), 2e-13);
    try std.testing.expectApproxEqRel(@as(f64, 0.00046259691171576534), rarity(&.{ 0.125, 0.375, 0.5 - 0x1p-45 }, &balanced, .improved), 2e-13);
}

test "compensation retains product residuals through scaling and infinite tails" {
    var sum = Sum{};
    sum.addProduct(1 + 0x1p-27, 1 - 0x1p-27);
    sum.scale(0.5);
    sum.add(-0.5);
    try std.testing.expectEqual(@as(f64, -0x1p-55), sum.value());
    sum.add(std.math.inf(f64));
    sum.add(1);
    sum.scale(0.5);
    try std.testing.expectEqual(std.math.inf(f64), sum.value());
    sum.add(-std.math.inf(f64));
    try std.testing.expect(std.math.isNan(sum.value()));
}

test "integer residual and local calibration fraction survive rounding boundaries" {
    try std.testing.expectEqual(@as(f64, 1), countDifference(9007199254740993, 9007199254740992));
    try std.testing.expectEqual(@as(f64, -1), countDifference(9007199254740991, 9007199254740992));
    try std.testing.expectEqual(@as(f64, -1), countDifference(std.math.maxInt(u64), 18446744073709551616));
    // 0.01 + (0.02-0.01)*1e-16 rounded once from the represented f64 inputs.
    try std.testing.expectEqual(@as(f64, 0.010000000000000002), interpolatedProbability(15, 1e-16, .improved));
    try std.testing.expectEqual(@as(f64, 0.01), interpolatedProbability(15, 1e-16, .reference));
    try std.testing.expectEqual(@as(f64, 0.01), interpolatedProbability(15, 0, .improved));
    try std.testing.expectEqual(@as(f64, 0.02), interpolatedProbability(15, 1, .improved));
}

test "small Poisson midpoint tails match independent Decimal controls" {
    // Direct 450-digit Poisson CDF with half of the observed mass included.
    const controls = [_]struct { lambda: f64, n: u64, score: f64 }{
        .{ .lambda = 0.1, .n = 1, .score = 3.3242177059218205 },
        .{ .lambda = 0.5, .n = 1, .score = 1.047895044069741 },
        .{ .lambda = 1.0, .n = 1, .score = 0.15784712645626106 },
        .{ .lambda = 1.0, .n = 4, .score = 5.464472299502802 },
        .{ .lambda = 5.0, .n = 2, .score = -2.598765360329609 },
        .{ .lambda = 5.0, .n = 5, .score = 0.0838351488068588 },
        .{ .lambda = 5.0, .n = 13, .score = 8.523853826598314 },
        .{ .lambda = 16.0, .n = 1, .score = -18.913195652781102 },
        .{ .lambda = 16.0, .n = 16, .score = 0.04797560520894279 },
        .{ .lambda = 16.0, .n = 31, .score = 10.211389450149701 },
        .{ .lambda = 64.0, .n = 1, .score = -86.2880884975352 },
        .{ .lambda = 64.0, .n = 32, .score = -16.464288626891694 },
        .{ .lambda = 64.0, .n = 64, .score = 0.024083607912501456 },
        .{ .lambda = 64.0, .n = 65, .score = 0.1768939056512429 },
        .{ .lambda = 64.0, .n = 95, .score = 11.764300386418748 },
    };
    for (controls) |control| try std.testing.expectApproxEqRel(control.score, smallPoissonSuspicion(control.lambda, control.n), 3e-14);
}

test "Hamming log CDF preserves finite underflowed and subnormal tail scores" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const model = try Hamming.init(arena.allocator(), 8192, .improved);
    const reference = try Hamming.init(arena.allocator(), 8192, .reference);
    try std.testing.expectEqual(@as(f64, 0), model.cdf[0]);
    try std.testing.expectApproxEqRel(@as(f64, 5678.261703147072), model.score(0), 2e-15);
    // P(X<=1) = (1+8192)*2^-8192, before conversion to binary64.
    try std.testing.expectApproxEqRel(@as(f64, 5669.25066773693), model.score(1), 2e-15);
    try std.testing.expectEqual(model.score(0), model.score(8192));
    try std.testing.expectEqual(std.math.inf(f64), reference.score(0));
    for (model.cdf, 0..) |p, i| {
        try std.testing.expect(std.math.isFinite(model.score(i)));
        if (i > 0) try std.testing.expect(model.score(i) < model.score(i - 1));
        if (p >= std.math.floatMin(f64)) try std.testing.expectEqual(-@log(p), model.score(i));
    }
    const subnormal = try Hamming.init(arena.allocator(), 1075, .improved);
    try std.testing.expectApproxEqRel(@as(f64, 745.1332191019412), subnormal.score(0), 2e-15);
    try std.testing.expect(subnormal.cdf[1] > 0 and subnormal.cdf[1] < std.math.floatMin(f64));
    try std.testing.expectApproxEqRel(f(1075) * @log(@as(f64, 2)) - @log(@as(f64, 1076)), subnormal.score(1), 2e-15);
}

test "moderate centered deviance matches independent Decimal controls" {
    // 110-digit direct n*ln(n/E)+E-n, around both series boundaries.
    const cases = [_][3]f64{
        .{ 990000000001, 1000000000000, 50167505.02352289 },
        .{ 990000000000, 1000000000000, 50167505.033573225 },
        .{ 989999999999, 1000000000000, 50167505.04362357 },
        .{ 1010000000000, 1000000000000, 49834161.69976368 },
        .{ 1010100000000, 1000000000000, 50834145.1167554 },
        .{ 510000000000, 1000000000000, 146594277835.47955 },
        .{ 500000000000, 1000000000000, 153426409720.02734 },
        .{ 1500000000000, 1000000000000, 108197662162.24657 },
        .{ 1500000000001, 1000000000000, 108197662162.65204 },
    };
    for (cases) |c| try std.testing.expectApproxEqRel(c[2], centeredDeviance(c[0], c[1], c[0] - c[1]), 2e-15);
}

test "conditional Hamming probabilities survive subnormal and zero CDFs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { bits: usize, threshold: usize, last: f64, previous: f64 }{
        .{ .bits = 4096, .threshold = 800, .last = 0.7574757066894421, .previous = 0.18379756304263078 },
        .{ .bits = 8, .threshold = 3, .last = 0.6021505376344086, .previous = 0.3010752688172043 },
        .{ .bits = 1075, .threshold = 0, .last = 1.0, .previous = 0.0 },
        .{ .bits = 1075, .threshold = 1, .last = 0.9990706319702602, .previous = 0.0009293680297397769 },
        .{ .bits = 4096, .threshold = 900, .last = 0.7186428091398811, .previous = 0.20230795377725774 },
        .{ .bits = 4096, .threshold = 880, .last = 0.7266019826254894, .previous = 0.19875963466286312 },
    };
    for (cases) |c| {
        const model = try Hamming.init(arena.allocator(), c.bits, .improved);
        const conditional = try arena.allocator().alloc(f64, c.threshold + 1);
        model.conditionalPdf(conditional);
        try std.testing.expectApproxEqRel(c.last, conditional[c.threshold], 2e-15);
        if (c.threshold != 0) try std.testing.expectApproxEqRel(c.previous, conditional[c.threshold - 1], 2e-15);
        var total = Sum{};
        for (conditional) |p| {
            try std.testing.expect(std.math.isFinite(p) and p >= 0 and p <= 1);
            total.add(p);
        }
        try std.testing.expectApproxEqAbs(@as(f64, 1), total.value(), 2e-15);
    }
}

test "DC7 combination retains finite extreme upper tails" {
    // 1500-digit Decimal controls: convert each suspicion to p, then evaluate
    // x=-ln(p1*p2), survival=exp(-x)*(1+x), and its signed base-two tail.
    const cases = [_][3]f64{
        .{ 0, 0, 0.309622563923675 },
        .{ 512, 512, 1024 },
        .{ 512.0000000000001, 512.0000000000001, 1024.0000000000002 },
        .{ 513, 514, 1026.8300749985576 },
        .{ 1022, 1024, 2045.3561438102254 },
        .{ 1074, 1075, 2148.830074998558 },
        .{ 1200, 1200, 2400 },
        .{ 1200, 1201, 2400.830074998558 },
        .{ 1200, 1400, 2402 },
        .{ -1200, 1200, -1190.2970139473439 },
    };
    for (cases) |c| {
        const result = combineTwoSuspicions(c[0], c[1]);
        try std.testing.expectApproxEqRel(c[2], result.suspicion, 2e-15);
        try std.testing.expectEqual(result.suspicion, combineTwoSuspicions(c[1], c[0]).suspicion);
    }
    const underflowed = combineTwoSuspicions(1200, 1200);
    try std.testing.expectEqual(@as(f64, 0), underflowed.chis);
    try std.testing.expectEqual(@as(f64, 2400), underflowed.suspicion);
    try std.testing.expectEqual(@as(f64, 1), probability(underflowed.suspicion));
    const inf = std.math.inf(f64);
    try std.testing.expectEqual(@as(f64, 2402), combineTwoSuspicions(1200, inf).suspicion);
    try std.testing.expectEqual(inf, combineTwoSuspicions(inf, inf).suspicion);
    try std.testing.expectEqual(-inf, combineTwoSuspicions(-inf, inf).suspicion);
    const nan = std.math.nan(f64);
    try std.testing.expect(std.math.isNan(combineTwoSuspicions(nan, 1200).suspicion));
    try std.testing.expect(std.math.isNan(combineTwoSuspicions(1200, nan).suspicion));
    try std.testing.expect(std.math.isNan(combineTwoSuspicions(inf, nan).suspicion));
}

test "implicit power-of-two uniform G-test matches explicit FPF models exactly" {
    var counts: [16384]u64 = undefined;
    var probabilities: [counts.len]f64 = undefined;
    var random = std.Random.DefaultPrng.init(0xf0f123);
    for (0..7) |fixture| {
        for (&counts, 0..) |*count, i| count.* = switch (fixture) {
            0 => 0,
            1 => if (i == 0) 1 else 0,
            2 => i % 17,
            3 => (@as(u64, 1) << 54) + i % 31,
            4 => std.math.maxInt(u64) - i % 31,
            5 => random.random().int(u64),
            else => if (i & 1 == 0) 0 else std.math.maxInt(u64),
        };
        for (1..15) |bits| {
            const n = @as(usize, 1) << @intCast(bits);
            @memset(probabilities[0..n], 1 / f(n));
            const explicit = gTest(probabilities[0..n], counts[0..n], .improved);
            const implicit = gTest(null, counts[0..n], .improved);
            try std.testing.expectEqual(@as(u64, @bitCast(explicit)), @as(u64, @bitCast(implicit)));
        }
    }
}

test "two-queue probability merges preserve heap ties and counts exactly" {
    const Oracle = struct {
        fn simplify(a: std.mem.Allocator, probs: []f64, counts: []u64, samples: f64) !usize {
            if (probs.len <= 2) return probs.len;
            const entries = try a.alloc(MergeBin, probs.len);
            for (entries, probs, counts, 0..) |*entry, p, count, i| entry.* = .{ .probability = p, .count = count, .serial = i };
            var queue = std.PriorityQueue(MergeBin, void, MergeBin.compare).fromOwnedSlice(entries, {});
            defer queue.deinit(a);
            const minimum = 1 / @max(samples, 2);
            var serial = probs.len;
            while (queue.items.len > 2) {
                const first = queue.pop().?;
                const second = queue.peek().?;
                if (first.probability >= minimum or second.probability >= minimum) {
                    try queue.push(a, first);
                    break;
                }
                _ = queue.pop();
                // Equivalent probabilities keep insertion order, as in upstream's multimap.
                try queue.push(a, .{ .probability = first.probability + second.probability, .count = first.count + second.count, .serial = serial });
                serial += 1;
            }
            const n = queue.items.len;
            for (0..n) |i| {
                const entry = queue.pop().?;
                probs[i] = entry.probability;
                counts[i] = entry.count;
            }
            return n;
        }
    };

    var random = std.Random.DefaultPrng.init(0x5eed123);
    for ([_]usize{ 0, 1, 2, 3, 17, 128, 1024 }) |n| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const original = try a.alloc(f64, n);
        const original_counts = try a.alloc(u64, n);
        for (original_counts, 0..) |*count, i| count.* = (@as(u64, 1) << 40) + i * 7;
        for (0..6) |fixture| {
            for (original, 0..) |*pvalue, i| pvalue.* = switch (fixture) {
                0 => 1 / f(@max(n, 1)),
                1 => if (i % 3 == 0) 0 else 0.125,
                2 => std.math.ldexp(@as(f64, 1), -@as(i32, @intCast(i % 1075))),
                3 => f(random.random().int(u16) % 31) / 4096,
                4 => if (i % 2 == 0) 0x1p-1000 else 0x1p-999,
                else => 0,
            };
            for ([_]f64{ 0, 2, 3, 40, 1000, 1e12, 0x1p1023 }) |samples| {
                const actual_p = try a.dupe(f64, original);
                const actual_c = try a.dupe(u64, original_counts);
                const expected_p = try a.dupe(f64, original);
                const expected_c = try a.dupe(u64, original_counts);
                const expected = try Oracle.simplify(a, expected_p, expected_c, samples);
                const actual = try simplifyUnordered(a, actual_p, actual_c, samples);
                try std.testing.expectEqual(expected, actual);
                try std.testing.expectEqualSlices(u64, expected_c[0..expected], actual_c[0..actual]);
                for (expected_p[0..expected], actual_p[0..actual]) |want, got| try std.testing.expectEqual(@as(u64, @bitCast(want)), @as(u64, @bitCast(got)));
            }
        }
    }
}
