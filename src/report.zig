const std = @import("std");
const b = @import("battery.zig");
const s = @import("statistics.zig");
extern "c" fn printf([*:0]const u8, ...) c_int;
extern "c" fn fflush(?*std.c.FILE) c_int;
extern "c" fn ferror(*std.c.FILE) c_int;
extern "c" var __stdoutp: *std.c.FILE;
extern "c" var stdout: *std.c.FILE;

pub fn flush() !void {
    const output = if (@import("builtin").os.tag == .macos) __stdoutp else stdout;
    // A failed printf can leave only the sticky error after its buffer drains.
    if (fflush(output) != 0 or ferror(output) != 0) return error.OutputFailed;
}

pub const Table = enum { narrow, wide, scoring };
pub const Filter = struct { smart: bool = true, threshold: f64 = 0.1, full_precision: bool = false, table: Table = .narrow, metatest: bool = false };
// Keep reference selection exactly as before; improved selection avoids
// subtracting tiny tails from one half and uses retained scores when available.
fn selected(r: b.Result, p: f64, threshold: f64) bool {
    if (r.arithmetic == .reference) return !(@abs(0.5 - p) < 0.5 - threshold);
    if (threshold >= 0.5) return true;
    if (r.tail_suspicion != null or r.kind == .good_s or r.kind == .bad_s or r.kind == .raw_normal)
        return @abs(r.suspicion()) >= -s.suspicion(threshold, .improved);
    return p <= threshold or 1 - p <= threshold;
}
fn exponential(suspicion: f64, precise: bool) void {
    const decimal = (@abs(suspicion) + 1) / (@log(@as(f64, 10)) / @log(@as(f64, 2)));
    const digits = @ceil(decimal);
    var sig = s.pow(0.1, decimal - digits);
    if (precise) sig = @floor(sig * 10) * 0.1 else sig = @floor(sig);
    if (digits > (if (precise) @as(f64, 9999) else 999)) {
        _ = printf(if (precise) " %d         " else " %d        ", @as(c_int, if (suspicion > 0) 1 else 0));
    } else if (precise and digits <= 999) {
        _ = printf(if (suspicion > 0) "1-%3.1fe-%.0f " else "  %3.1fe-%.0f ", sig, digits);
    } else {
        _ = printf(if (suspicion > 0) "1-%1.0fe-%.0f  " else "  %1.0fe-%.0f  ", @floor(sig), digits);
    }
    if (digits < 100) _ = printf(" ");
    if (digits < 10) _ = printf(" ");
}
fn row(r: b.Result, score: f64, p: f64, weight: f64, filter: Filter) void {
    _ = printf("  %-34.*s", @as(c_int, @intCast(r.name.len)), r.name.ptr);
    if (filter.table == .scoring) {
        if (@abs(r.raw) < 99.95) _ = printf("%+5.1f ", r.raw) else if (@abs(r.raw) < 9999) _ = printf("%+5.0f ", r.raw) else _ = printf(if (r.raw < 0) "-9999 " else "+9999 ");
        const suspicion = -r.suspicion() * (@log(@as(f64, 2)) / @log(@as(f64, 10)));
        if (@abs(suspicion) < 9.95) _ = printf("%+4.1f ", suspicion) else if (@abs(suspicion) < 999.5) _ = printf("%+4.0f ", suspicion) else _ = printf(if (suspicion < 0) "-999 " else if (suspicion > 0) "+999 " else "nan? ");
        if (weight > 1e-10) _ = printf("%4.2f ", -@log10(weight)) else _ = printf("???  ");
        if (score == 0) {
            _ = printf("0    ");
        } else if (score < 9.95) {
            _ = printf("%.1f  ", score);
        } else if (score < 99.5) {
            _ = printf("%.0f.  ", score);
        } else if (score < 999.5) {
            _ = printf("%.0f  ", score);
        } else if (score < 9999.5) {
            _ = printf("%.0f ", score);
        } else _ = printf("9999+");
    } else {
        if (@abs(r.raw) < 999.95) _ = printf("R=%+6.1f  ", r.raw) else if (@abs(r.raw) <= 99999) _ = printf("R=%+6.0f  ", r.raw) else _ = printf(if (r.raw < 0) "R<-99999  " else "R>+99999  ");
        switch (r.kind) {
            .passfail => {
                _ = printf(if (p != 0) "  \"pass\"      " else "  \"fail\"      ");
            },
            .raw => {
                _ = printf("              ");
            },
            .raw_normal, .bad_p, .good_p => {
                _ = printf(if (r.kind == .good_p) "p = " else "p~= ");
                const distance = @abs(p - 0.5);
                if (distance > 0.49) exponential(r.suspicion(), false) else if (r.kind == .good_p) _ = printf("%5.3f     ", p) else if (distance >= 0.4) _ = printf("%4.2f      ", p) else _ = printf("%3.1f       ", p);
            },
            .good_s, .bad_s => {
                _ = printf(if (r.kind == .bad_s) "p~=" else "p =");
                if (p >= 0.01 and p <= 0.99) _ = printf(" %.3f     ", p) else exponential(r.suspicion(), true);
            },
        }
        if (filter.table == .wide) {
            _ = printf("W=%6.3f ", weight * 100);
            if (score == 0) {
                _ = printf("S=0    ");
            } else if (score < 0.95) {
                _ = printf("S=%.1f  ", score);
            } else if (score < 9.995) {
                _ = printf("S=%.2f ", score);
            } else if (score < 99.95) {
                _ = printf("S=%.1f  ", score);
            } else if (score < 999.5) {
                _ = printf("S=%.0f  ", score);
            } else if (score < 9999) {
                _ = printf("S=%.0f ", score);
            } else _ = printf("S>9999 ");
        }
    }
    const limits = [_]f64{ 999, 325, 165, 85, 45, 25, 17, 12, 8.5, 6, 4, 3, 2, 1, 0 };
    const labels = [_][:0]const u8{ "  FAIL !!!!!!!!  ", "  FAIL !!!!!!!   ", "  FAIL !!!!!!    ", "  FAIL !!!!!     ", "  FAIL !!!!      ", "  FAIL !!!       ", "  FAIL !!        ", "  FAIL !         ", "  FAIL           ", " VERY SUSPICIOUS ", "very suspicious  ", "suspicious       ", "mildly suspicious", "unusual          ", "normalish        " };
    var label: [:0]const u8 = "normal           ";
    for (limits, labels) |limit, candidate| {
        if (score > limit) {
            label = candidate;
            break;
        }
    }
    _ = printf("%s", label.ptr);
    if (filter.full_precision) _ = printf(" raw=%.17g p=%.17g suspicion=%.17g", r.raw, p, r.suspicion());
    _ = printf("\n");
}
pub const Unit = enum { bytes, seeds, entropy_strings };
pub fn checkpoint(a: std.mem.Allocator, results: []const b.Result, rng: []const u8, seed: []const u8, blocks: u64, seconds: f64, filter: Filter, sample_unit: Unit) !bool {
    _ = printf("rng=%.*s, seed=%.*s\nlength= ", @as(c_int, @intCast(rng.len)), rng.ptr, @as(c_int, @intCast(seed.len)), seed.ptr);
    const bytes = blocks * 1024;
    const l2 = @log(s.f(bytes)) / @log(@as(f64, 2)) - @as(f64, if (sample_unit == .bytes) 0 else 3);
    const unit: [*:0]const u8 = switch (sample_unit) {
        .bytes => "bytes",
        .seeds => "seeds",
        .entropy_strings => "entropy strings",
    };
    const units: usize = @min(5, (std.math.log2_int(u64, bytes) / 10) - 1);
    const labels = [_][:0]const u8{ "kilobyte", "megabyte", "gigabyte", "terabyte", "petabyte", "exabyte" };
    const quantity = s.f(bytes) * s.pow(0.5, s.f(units * 10 + 10));
    if (!std.math.isPowerOfTwo(bytes)) {
        _ = printf("%.3f %ss (2^%.3f %s), time= ", quantity, labels[units].ptr, l2, unit);
    } else {
        _ = printf("%.0f %s%s (2^%.0f %s), time= ", quantity, labels[units].ptr, if (bytes == @as(u64, 1024) << @intCast(units * 10)) @as([*:0]const u8, "") else "s", l2, unit);
    }
    _ = printf(if (seconds < 99.95) "%.1f seconds\n" else "%.0f seconds\n", seconds);
    const probabilities = try a.alloc(f64, results.len);
    var weight: f64 = 0;
    for (results, probabilities) |r, *p| {
        if (!std.math.isFinite(r.weight) or r.weight <= 0) {
            _ = printf("\nerror: garbage weight in test results\n\ttest=%.*s\n\tweight=%f\n", @as(c_int, @intCast(r.name.len)), r.name.ptr, r.weight);
            _ = fflush(null);
            return error.InvalidWeight;
        }
        p.* = r.probability();
        if (!std.math.isFinite(p.*) or p.* < 0 or p.* > 1) {
            _ = printf("\nerror: garbage p-value in test results\n\ttest=%.*s\n\tpvalue=%f\n", @as(c_int, @intCast(r.name.len)), r.name.ptr, p.*);
            _ = fflush(null);
            return error.InvalidPvalue;
        }
        weight += r.weight;
    }
    var marked: usize = 0;
    var biggest: f64 = 0;
    var metatest_squared: f64 = 0;
    const Scored = struct { index: usize, score: f64 };
    const order = try a.alloc(Scored, results.len);
    // Sum selected scores in upstream result order, before presentation sorting.
    for (results, probabilities, 0..) |r, p, index| {
        const normalized = r.weight / weight;
        const threshold = if (filter.smart) filter.threshold * normalized * 0.5 else filter.threshold;
        if (!selected(r, p, threshold)) continue;
        const score = @max(0, (@abs(r.suspicion()) + @log(normalized) / @log(@as(f64, 2))) * @log(@as(f64, 2)) / @log(@as(f64, 10)));
        order[marked] = .{ .index = index, .score = score };
        marked += 1;
        biggest = @max(biggest, score);
        if (filter.metatest and score > 0) metatest_squared += score * score;
    }
    std.mem.sort(Scored, order[0..marked], results, struct {
        fn lessThan(items: []const b.Result, left: Scored, right: Scored) bool {
            return std.mem.lessThan(u8, items[left.index].name, items[right.index].name);
        }
    }.lessThan);
    if (marked != 0) {
        _ = printf(switch (filter.table) {
            .narrow => "  Test Name                         Raw       Processed     Evaluation       \n",
            .wide => "  Test Name                         Raw       Processed     Weight%%  Score  Evaluation       \n",
            .scoring => "  Test Name                         Raw   Sus  WMod Scor Evaluation       \n",
        });
        for (order[0..marked]) |item| {
            const r = results[item.index];
            row(r, item.score, probabilities[item.index], r.weight / weight, filter);
        }
    }
    if (marked != results.len) {
        if (marked == 0) _ = printf("  no anomalies in %d test result(s)\n", @as(c_int, @intCast(results.len))) else _ = printf("  ...and %d test result(s) without anomalies\n", @as(c_int, @intCast(results.len - marked)));
    }
    if (filter.metatest and results.len != 0) {
        const score = @sqrt(metatest_squared);
        const label: [:0]const u8 = if (score < 0.25) "no problems" else if (score < 2) "minor blip" else if (score < 4) "major blip" else if (score < 7) "suspicious" else if (score < 10) "very suspicious" else "extreme ; probably a failure";
        _ = printf("  metatest score: %.1f, evaluated as: %s\n", score, label.ptr);
    }
    _ = printf("\n");
    try flush();
    return biggest > 8.5;
}

test "improved report filtering preserves tail thresholds and reference selection" {
    var r = b.Result{ .name = "tail", .raw = 0, .value = 1e-18, .kind = .good_p, .weight = 1, .arithmetic = .improved };
    // Scalar boundary below the CLI limit; CLI limits themselves are unchanged.
    try std.testing.expect(!selected(r, r.probability(), 1e-20));
    r.arithmetic = .reference;
    try std.testing.expect(selected(r, r.probability(), 1e-20));
    r.arithmetic = .improved;
    const threshold: f64 = 1e-10; // supported -p lower bound
    r.value = @bitCast(@as(u64, @bitCast(threshold)) + 1);
    try std.testing.expect(!selected(r, r.probability(), threshold));
    r.value = threshold;
    try std.testing.expect(selected(r, r.probability(), threshold));
    r.value = @bitCast(@as(u64, @bitCast(threshold)) - 1);
    try std.testing.expect(selected(r, r.probability(), threshold));
    // Both rounded probability endpoints retain finite, distinguishable tails.
    for ([_]f64{ -100, 100 }) |score| {
        r.value = if (score > 0) 1 else 0;
        r.tail_suspicion = score;
        try std.testing.expect(!selected(r, r.probability(), 0x1p-110));
        try std.testing.expect(selected(r, r.probability(), 0x1p-100));
        try std.testing.expect(!selected(r, r.probability(), 0));
    }
    r.tail_suspicion = null;
    r.kind = .good_s;
    r.value = 99;
    try std.testing.expect(selected(r, r.probability(), 0x1p-100));
    r.kind = .passfail;
    r.value = 1;
    try std.testing.expect(selected(r, r.probability(), 0));
    r.value = 0;
    try std.testing.expect(!selected(r, r.probability(), 0.49));
    try std.testing.expect(selected(r, r.probability(), 0.5));
    try std.testing.expect(selected(r, r.probability(), 1));
    r.kind = .raw;
    try std.testing.expect(!selected(r, r.probability(), 0.1));
}
