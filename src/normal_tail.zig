// Positive normal log tails; fdlibm rational coefficients via musl erf.c.
// Copyright (C) 1993 by Sun Microsystems, Inc. All rights reserved.
// Developed at SunPro, a Sun Microsystems, Inc. business.
// Permission to use, copy, modify, and distribute this software is freely
// granted, provided that this notice is preserved.
// Adaptation: pure binary64 evaluation, direct logarithmic tails, and the
// DLMF 7.12.1 asymptotic expansion beyond the original erfc underflow cutoff.
const std = @import("std");

fn polynomial(x: f64, comptime coefficients: []const f64) f64 {
    @setFloatMode(.strict);
    var value = coefficients[coefficients.len - 1];
    inline for (0..coefficients.len - 1) |i| value = @mulAdd(f64, value, x, coefficients[coefficients.len - 2 - i]);
    return value;
}
const pp = [_]f64{ 1.28379167095512558561e-01, -3.25042107247001499370e-01, -2.84817495755985104766e-02, -5.77027029648944159157e-03, -2.37630166566501626084e-05 };
const qq = [_]f64{ 1, 3.97917223959155352819e-01, 6.50222499887672944485e-02, 5.08130628187576562776e-03, 1.32494738004321644526e-04, -3.96022827877536812320e-06 };
const pa = [_]f64{ -2.36211856075265944077e-03, 4.14856118683748331666e-01, -3.72207876035701323847e-01, 3.18346619901161753674e-01, -1.10894694282396677476e-01, 3.54783043256182359371e-02, -2.16637559486879084300e-03 };
const qa = [_]f64{ 1, 1.06420880400844228286e-01, 5.40397917702171048937e-01, 7.18286544141962662868e-02, 1.26171219808761642112e-01, 1.36370839120290507362e-02, 1.19844998467991074170e-02 };
const ra = [_]f64{ -9.86494403484714822705e-03, -6.93858572707181764372e-01, -1.05586262253232909814e+01, -6.23753324503260060396e+01, -1.62396669462573470355e+02, -1.84605092906711035994e+02, -8.12874355063065934246e+01, -9.81432934416914548592e+00 };
const sa = [_]f64{ 1, 1.96512716674392571292e+01, 1.37657754143519042600e+02, 4.34565877475229228821e+02, 6.45387271733267880336e+02, 4.29008140027567833386e+02, 1.08635005541779435134e+02, 6.57024977031928170135e+00, -6.04244152148580987438e-02 };
const rb = [_]f64{ -9.86494292470009928597e-03, -7.99283237680523006574e-01, -1.77579549177547519889e+01, -1.60636384855821916062e+02, -6.37566443368389627722e+02, -1.02509513161107724954e+03, -4.83519191608651397019e+02 };
const sb = [_]f64{ 1, 3.03380607434824582924e+01, 3.25792512996573918826e+02, 1.53672958608443695994e+03, 3.19985821950859553908e+03, 2.55305040643316442583e+03, 4.74528541206955367215e+02, -2.24409524465858183362e+01 };

// Input is nonnegative. The caller supplies odd symmetry for signed scores.
pub fn positiveSuspicion(norm: f64) f64 {
    @setFloatMode(.strict);
    if (std.math.isNan(norm)) return norm;
    // The linear limit avoids losing subnormal inputs in norm/sqrt(2).
    if (norm < 0x1p-54) return norm * 1.1511040990721624445669473852183134;
    const x = norm * @sqrt(@as(f64, 0.5));
    const ln2 = @log(@as(f64, 2));
    if (x < 0.84375) {
        const z = x * x;
        const erf = @mulAdd(f64, x, polynomial(z, &pp) / polynomial(z, &qq), x);
        return -std.math.log1p(-erf) / ln2;
    }
    if (x < 1.25) {
        const z = x - 1;
        const erfc = (1 - @as(f64, 8.45062911510467529297e-01)) - polynomial(z, &pa) / polynomial(z, &qa);
        return -@log(erfc) / ln2;
    }
    const square = (norm * 0.5) * norm;
    if (std.math.isInf(square)) return std.math.inf(f64);
    var correction: f64 = undefined;
    if (x < 28) {
        const z = 1 / (x * x);
        const ratio = if (x < 0x1.6db6d00000000p+1) polynomial(z, &ra) / polynomial(z, &sa) else polynomial(z, &rb) / polynomial(z, &sb);
        correction = 0.5625 - ratio + @log(x);
    } else {
        // For positive x the first omitted term bounds the asymptotic error.
        // At x>=28 this terminates before terms can begin to grow.
        const inverse_square = (1 / x) / x;
        var term: f64 = 1;
        var remainder: f64 = 0;
        var k: usize = 1;
        while (true) : (k += 1) {
            term *= -@as(f64, @floatFromInt(2 * k - 1)) * 0.5 * inverse_square;
            remainder += term;
            if (@abs(term) < 0x1p-57) break;
        }
        correction = @log(x) + 0.57236494292470008707171367567652936 - std.math.log1p(remainder);
    }
    // Use the original normal variate for z^2/2; scaling by sqrt(1/2) first
    // would introduce an extra rounding into the dominant term.
    return @mulAdd(f64, norm * 0.5, norm, correction) / ln2;
}

// Decimal controls: exact represented inputs, 450-digit erf integration series;
// z>=30 uses 100 asymptotic terms with an omitted-term bound far below one ulp.
test "normal log tails agree with independent controls across every regime" {
    const controls = [_][2]f64{
        .{ 0.0, 0.0 },
        .{ 5e-324, 5e-324 },
        .{ 1e-323, 1e-323 },
        .{ 1e-300, 1.1511040990721624e-300 },
        .{ 1e-18, 1.1511040990721624e-18 },
        .{ 5.551115123125783e-17, 6.38991137265156e-17 },
        .{ 1e-12, 1.1511040990726216e-12 },
        .{ 0.01, 0.011557015752344963 },
        .{ 0.1, 0.11975438189515841 },
        .{ 0.25, 0.31726968011834955 },
        .{ 0.5, 0.6964820669741186 },
        .{ 0.7, 1.0471377527428538 },
        .{ 1.0, 1.656032797424106 },
        .{ 1.1932426932522988, 2.102996071749405 },
        .{ 1.193242693252299, 2.102996071749406 },
        .{ 1.1932426932522993, 2.1029960717494065 },
        .{ 1.5, 2.9038525679898832 },
        .{ 1.7677669529663687, 3.6971277295709926 },
        .{ 1.7677669529663689, 3.697127729570993 },
        .{ 1.767766952966369, 3.697127729570994 },
        .{ 2.0, 4.457981276971885 },
        .{ 2.819234736590765, 7.698599075324567 },
        .{ 3.0, 8.53293385132495 },
        .{ 4.0, 13.9464670377193 },
        .{ 4.040608251495768, 14.195159888654278 },
        .{ 4.040608251495769, 14.195159888654283 },
        .{ 4.04060825149577, 14.195159888654288 },
        .{ 5.0, 20.734198474007734 },
        .{ 6.0, 28.916833728188745 },
        .{ 8.0, 49.513712155086075 },
        .{ 10.0, 75.79651110679066 },
        .{ 12.0, 107.79460396946254 },
        .{ 16.0, 188.99629482352097 },
        .{ 30.0, 654.4470056263212 },
        .{ 39.597979746446654, 1136.7069336674842 },
        .{ 39.59797974644666, 1136.7069336674847 },
        .{ 39.59797974644667, 1136.706933667485 },
        .{ 40.0, 1159.8046091506376 },
        .{ 100.0, 7220.444952932782 },
        .{ 1000.0, 721357.8119782738 },
        .{ 1e+150, 7.213475204444816e+299 },
    };
    var control_previous: f64 = 0;
    for (controls) |control| {
        const actual = positiveSuspicion(control[0]);
        try std.testing.expect(actual >= control_previous);
        control_previous = actual;
        if (control[1] < 0x1p-1022) {
            try std.testing.expectEqual(control[1], actual);
        } else try std.testing.expectApproxEqRel(control[1], actual, 2e-15);
    }
    try std.testing.expectEqual(std.math.inf(f64), positiveSuspicion(std.math.inf(f64)));
    try std.testing.expect(std.math.isNan(positiveSuspicion(std.math.nan(f64))));
    var previous: f64 = 0;
    for (1..16385) |i| {
        const actual = positiveSuspicion(@as(f64, @floatFromInt(i)) / 256);
        try std.testing.expect(actual > previous);
        previous = actual;
    }
}
