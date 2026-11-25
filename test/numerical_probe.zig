// Run the same probe on each target; compare raw bit patterns, not display rounding.
const s = @import("statistics");
const std = @import("std");
extern "c" fn printf([*:0]const u8, ...) c_int;
extern "c" fn fflush(?*anyopaque) c_int;
fn emit(name: [*:0]const u8, value: f64) !void {
    if (printf("%s %016llx\n", name, @as(c_ulonglong, @bitCast(value))) < 0) return error.OutputFailed;
}
pub fn main() !void {
    // Volatile reads prevent compile-time evaluation from hiding runtime math.
    var inputs = [_]f64{ 0.49999999999999994, 1e-18, 0.7, 4, 1600, 1e12 };
    const values: *volatile [inputs.len]f64 = &inputs;
    try emit("suspicion-near-half", s.suspicion(values[0], .improved));
    try emit("normal-near-zero", s.normalSuspicion(values[1], .improved));
    try emit("normal-moderate", s.normalSuspicion(values[2], .improved));
    try emit("dc7-moderate", s.chiSquare4Suspicion(values[3]));
    try emit("dc7-extreme", s.chiSquare4Suspicion(values[4]));
    try emit("birthday-centered", s.poissonLogTail(values[5], 1000004000000));
    var counts = [_]u64{ 1000000000000000001, 999999999999999999 };
    try emit("gtest-large-counts", s.gTest(null, &counts, .improved));
    var pdf: [2049]f64 = undefined;
    var cdf: [2049]f64 = undefined;
    s.Hamming.fill(4096, &pdf, &cdf, .improved);
    try emit("hamming-center-pdf", pdf[2048]);
    try emit("hamming-center-cdf", cdf[2048]);
    s.Hamming.fill(1074, pdf[0..538], cdf[0..538], .improved);
    try emit("hamming-subnormal", pdf[0]);
    var nominal = s.NominalGTest{};
    nominal.add(&.{ 1000000000001, 999999999999 }, values[5]);
    try emit("fpf-nominal-centered", nominal.value());
    try emit("integer-residual", s.countDifference(9007199254740993, 9007199254740992));
    try emit("rarity-centered", s.unorderedRarity(&.{ 0.125, 0.375, 0.5 }, &.{ 1000000000000000001, 2999999999999999999, 4000000000000000000 }, .improved));
    try emit("ordered-rarity-nonunit", s.rarity(&.{ 0.125, 0.375, 0.4 }, &.{ 13, 38, 49 }, .improved));
    try emit("normal-former-cancellation", s.normalSuspicion(values[2] * 4, .improved));
    try emit("normal-extreme-log", s.normalSuspicion(values[3] * 10, .improved));
    try emit("poisson-direct-upper", s.smallPoissonSuspicion(values[3] * 16, 95));
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const hamming = try s.Hamming.init(arena.allocator(), 8192, .improved);
    try emit("hamming-log-underflow", hamming.score(0));
    try emit("hamming-log-next", hamming.score(1));
    var conditional: [901]f64 = undefined;
    hamming.conditionalPdf(&conditional);
    try emit("hamming-conditional-underflow", conditional[900]);
    try emit("hamming-conditional-previous", conditional[899]);
    var moderate = s.NominalGTest{};
    moderate.add(&.{ 1010100000000, 989900000000 }, values[5]);
    try emit("gtest-moderate-deviation", moderate.value());
    try emit("dc7-combined-underflow", s.combineTwoSuspicions(values[3] * 300, values[3] * 300).suspicion);
    try emit("dc7-combined-unequal", s.combineTwoSuspicions(values[3] * 300, values[3] * 300 + 1).suspicion);
    if (fflush(null) != 0) return error.OutputFailed;
}
