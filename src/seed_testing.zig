const std = @import("std");

pub const Mode = enum(c_int) { original = 1, gray, balanced_gray };
pub const Config = struct { bits: c_uint = 0, mode: Mode = .original };

/// A single exhaustive pass, translated by an XOR offset for replayable starts.
pub const Walk = struct {
    mode: Mode,
    bits: u8,
    current: u128,
    step: u128 = 0,
    exhausted: bool = false,

    pub fn init(mode: Mode, bits: u8, offset: u128) !Walk {
        if (mode == .original or bits < 16 or bits > 128) return error.InvalidSeedWalk;
        if (mode == .balanced_gray and !std.math.isPowerOfTwo(bits)) return error.InvalidBalancedWidth;
        return .{ .mode = mode, .bits = bits, .current = offset & mask(bits) };
    }

    pub fn next(walk: *Walk) !u128 {
        if (walk.exhausted) return error.SeedCycleExhausted;
        const value = walk.current;
        const next_step = (walk.step +% 1) & mask(walk.bits);
        if (next_step == 0) {
            walk.exhausted = true;
        } else {
            const bit = if (walk.mode == .gray) @ctz(next_step) else balancedBit(walk.bits, walk.step);
            walk.current ^= @as(u128, 1) << @intCast(bit);
        }
        walk.step = next_step;
        return value;
    }
};

fn mask(bits: u8) u128 {
    return @as(u128, std.math.maxInt(u128)) >> @intCast(128 - bits);
}

/// Interleave half-cycle indices (k, k-2p), (k+1, k-2p), modulo L.
/// Their difference identifies 2p or 2p+1, proving uniqueness recursively.
/// Each edge advances one half by +/-1, including the closing edge.
pub fn balancedBit(initial_width: u8, initial_step: u128) u7 {
    var width = initial_width;
    var step = initial_step;
    var offset: u7 = 0;
    while (width > 4) {
        const half = width / 2;
        const half_mask = mask(half);
        const k = (step >> 1) & half_mask;
        if (step & 1 == 0) {
            step = k;
        } else {
            const phase = step >> @intCast(half + 1);
            const y = (k -% (phase << 1)) & half_mask;
            step = if (k == half_mask) (y -% 1) & half_mask else y;
            offset += @intCast(half);
        }
        width = half;
    }
    const base = [_]u2{ 0, 1, 2, 1, 0, 3, 1, 3, 2, 3, 0, 2, 1, 2, 0, 3 };
    return offset + @as(u7, base[@intCast(step & 15)]);
}

test "balanced cycles visit each small word once and close with one flip" {
    inline for (.{ 4, 8, 16 }) |bits| {
        const count = 1 << bits;
        var seen: [count]bool = @splat(false);
        var value: u128 = 0;
        for (0..count) |step| {
            try std.testing.expect(!seen[@intCast(value)]);
            seen[@intCast(value)] = true;
            value ^= @as(u128, 1) << balancedBit(bits, step);
        }
        try std.testing.expectEqual(@as(u128, 0), value);
    }
}

test "deterministic walks exhaust exactly once and reflect Gray code directly" {
    for ([_]Mode{ .gray, .balanced_gray }) |mode| {
        var walk = try Walk.init(mode, 16, 0x1234);
        var seen: [65536]bool = @splat(false);
        var previous: ?u128 = null;
        for (0..65536) |i| {
            const value = try walk.next();
            if (mode == .gray) try std.testing.expectEqual(@as(u128, i ^ (i >> 1)) ^ 0x1234, value);
            try std.testing.expect(!seen[@intCast(value)]);
            seen[@intCast(value)] = true;
            if (previous) |last| try std.testing.expectEqual(@as(u8, 1), @popCount(last ^ value));
            previous = value;
        }
        try std.testing.expectError(error.SeedCycleExhausted, walk.next());
    }
    for ([_]u8{ 32, 64, 128 }) |bits| {
        var walk = try Walk.init(.balanced_gray, bits, 0);
        var counts: [128]u32 = @splat(0);
        for (0..1 << 16) |i| counts[balancedBit(bits, i)] += 1;
        const mean = (1 << 16) / @as(u32, bits);
        for (counts[0..bits]) |count| try std.testing.expect(count * 5 >= mean * 4 and count * 5 <= mean * 6);
        walk.step = mask(bits);
        _ = try walk.next();
        try std.testing.expectError(error.SeedCycleExhausted, walk.next());
    }
    try std.testing.expectError(error.InvalidBalancedWidth, Walk.init(.balanced_gray, 24, 0));
}

test "balanced edge selector matches direct rank construction at large carry boundaries" {
    const Oracle = struct {
        fn word(width: u8, rank: u128) u128 {
            if (width == 4) {
                const words = [_]u8{ 0, 1, 3, 7, 5, 4, 12, 14, 6, 2, 10, 11, 15, 13, 9, 8 };
                return words[@intCast(rank)];
            }
            const half = width / 2;
            const k = (rank >> 1) & mask(half);
            const p = rank >> @intCast(half + 1);
            const x = (k + (rank & 1)) & mask(half);
            const y = (k -% (2 * p)) & mask(half);
            return word(half, x) | (word(half, y) << @intCast(half));
        }
    };
    for ([_]u8{ 16, 32, 64, 128 }) |bits| {
        for (0..bits) |bit| {
            const pivot = @as(u128, 1) << @intCast(bit);
            for (0..5) |delta| {
                const rank = (pivot +% delta -% 2) & mask(bits);
                const expected = Oracle.word(bits, rank) ^ Oracle.word(bits, (rank +% 1) & mask(bits));
                try std.testing.expectEqual(expected, @as(u128, 1) << balancedBit(bits, rank));
            }
        }
    }
}
