// PractRand 0.96 C8 counts (CC0), with fully consumed Arbee words for ties.
const std = @import("std");
const Arbee = @import("auxiliary.zig").Arbee;

// One byte per classification, regardless of ties. Retain unused bits across
// calls and CPU/GPU handoffs; batching must not alter the random sequence.
pub const TieBits = struct {
    generator: Arbee,
    pending: u64 = 0,
    remaining: u7 = 0,

    pub fn init(seed: u64) TieBits {
        return .{ .generator = Arbee.init(seed) };
    }
    pub fn take(t: *TieBits, comptime T: type) T {
        if (T != u8 and T != u16 and T != u32) @compileError("tie groups must be u8, u16, or u32");
        const bits = @bitSizeOf(T);
        const low = t.pending;
        if (t.remaining < bits) {
            const needed = bits - t.remaining;
            const fresh = t.generator.next();
            const value = low | (fresh << @intCast(t.remaining));
            t.pending = fresh >> @intCast(needed);
            t.remaining = 64 - needed;
            return @truncate(value);
        }
        t.pending >>= bits;
        t.remaining -= bits;
        return @truncate(low);
    }
};

const masks = [_]u64{ 0x5555555555555555, 0x3333333333333333, 0x0f0f0f0f0f0f0f0f, 0x00ff00ff00ff00ff, 0x0000ffff0000ffff, 0x00000000ffffffff };
pub fn classify(random_state: *TieBits, input: []const u8, output: []u8) void {
    if (@import("builtin").is_test and (input.len % 16 != 0 or output.len != input.len / 16)) @panic("invalid CPU classification batch");
    const V = @Vector(4, u64);
    var offset: usize = 0;
    while (offset + 64 <= input.len) : (offset += 64) {
        const words: @Vector(8, u64) = @bitCast(input[offset..][0..64].*);
        const x = @shuffle(u64, words, undefined, @as(@Vector(4, i32), .{ 0, 2, 4, 6 }));
        const y = @shuffle(u64, words, undefined, @as(@Vector(4, i32), .{ 1, 3, 5, 7 }));
        const ties = random_state.take(u32);
        const random: V = .{ ties, ties >> 8, ties >> 16, ties >> 24 };
        var values: @Vector(4, u8) = @splat(0);
        inline for (0..8) |bit| {
            const counts: V = switch (bit) {
                0...5 => @as(V, @intCast(@popCount(x ^ @as(V, @splat(masks[bit]))))) +
                    @as(V, @intCast(@popCount(y ^ @as(V, @splat(masks[bit]))))),
                6 => @as(V, @splat(64)) - @as(V, @intCast(@popCount(x))) + @as(V, @intCast(@popCount(y))),
                7 => @as(V, @intCast(@popCount(x))) + @as(V, @intCast(@popCount(y))),
                else => unreachable,
            };
            const selected = (counts > @as(V, @splat(64))) |
                ((counts == @as(V, @splat(64))) & ((random & @as(V, @splat(@as(u64, 1) << bit))) != @as(V, @splat(0))));
            values = (values << @as(@Vector(4, u8), @splat(1))) |
                @select(u8, selected, @as(@Vector(4, u8), @splat(1)), @as(@Vector(4, u8), @splat(0)));
        }
        output[offset / 16 ..][0..4].* = values;
    }
    // Reserve the next tie byte for every remaining complete classification.
    if (offset < input.len) classifyScalar(random_state, input[offset..], output[offset / 16 ..]);
}
fn classifyScalar(random_state: *TieBits, input: []const u8, output: []u8) void {
    for (0..input.len / 16) |index| {
        const random = random_state.take(u8);
        const offset = index * 16;
        const x = std.mem.readInt(u64, input[offset..][0..8], .little);
        const y = std.mem.readInt(u64, input[offset + 8 ..][0..8], .little);
        var counts: [8]u32 = undefined;
        inline for (masks, 0..) |mask, i| counts[i] = @as(u32, @popCount(x ^ mask)) + @popCount(y ^ mask);
        counts[6] = 64 - @as(u32, @popCount(x)) + @popCount(y);
        counts[7] = @as(u32, @popCount(x)) + @popCount(y);
        var value: u8 = 0;
        for (counts, 0..) |count, bit| {
            const tie = random & (@as(u8, 1) << @intCast(bit)) != 0;
            value = (value << 1) | @intFromBool(count > 64 or (count == 64 and tie));
        }
        output[index] = value;
    }
}

test "classification bytes and RNG progress match direct bit counting" {
    var input: [1040]u8 = undefined;
    var output: [128]u8 = undefined;
    var expected: [64]u8 = undefined;
    for (0..5) |fixture| {
        var random = std.Random.DefaultPrng.init(0xc8c8);
        if (fixture == 0) random.random().bytes(&input) else @memset(&input, if (fixture == 1 or fixture == 4) 0 else if (fixture == 2) 255 else 0x55);
        // Odd parity makes all eight counts odd, so no count can be a tie.
        if (fixture == 4) for (0..input.len / 16) |index| {
            input[index * 16] = 1;
        };
        for ([_]u64{ 0, 1, std.math.maxInt(u64) }) |seed| {
            for ([_]usize{ 0, 1, 7, 15 }) |alignment| {
                for ([_]usize{ 0, 16, 32, 48, 64, 80, 96, 112, 128, 144, 1024 }) |len| {
                    const bytes = input[alignment..][0..len];
                    var reference = Arbee.init(seed);
                    var tie_bits: u64 = 0;
                    for (0..len / 16) |index| {
                        if (index % 8 == 0) tie_bits = reference.next();
                        var value: u8 = 0;
                        for (0..8) |dimension| {
                            var count: usize = 0;
                            for (0..128) |bit| {
                                const source = (bytes[index * 16 + bit / 8] >> @as(u3, @intCast(bit % 8))) & 1;
                                const flip = if (dimension < 6) ((bit % 64 >> @as(u6, @intCast(dimension))) & 1) == 0 else if (dimension == 6) bit < 64 else false;
                                count += source ^ @as(u8, @intFromBool(flip));
                            }
                            const tie = (tie_bits >> @as(u6, @intCast(index % 8 * 8 + dimension))) & 1 != 0;
                            value = (value << 1) | @intFromBool(count > 64 or (count == 64 and tie));
                        }
                        expected[index] = value;
                    }
                    var actual = TieBits.init(seed);
                    @memset(&output, 0xa5);
                    const begin = 16 + alignment;
                    classify(&actual, bytes, output[begin..][0 .. len / 16]);
                    try std.testing.expectEqualSlices(u8, expected[0 .. len / 16], output[begin..][0 .. len / 16]);
                    try std.testing.expectEqualDeep(reference, actual.generator);
                    const used = len / 16 % 8;
                    try std.testing.expectEqual(@as(u7, @intCast(if (used == 0) 0 else 64 - used * 8)), actual.remaining);
                    try std.testing.expectEqual(if (used == 0) @as(u64, 0) else tie_bits >> @as(u6, @intCast(used * 8)), actual.pending);
                    for (output[0..begin]) |guard| try std.testing.expectEqual(@as(u8, 0xa5), guard);
                    for (output[begin + len / 16 ..]) |guard| try std.testing.expectEqual(@as(u8, 0xa5), guard);
                }
            }
        }
    }
}

test "classification retains every tie bit across scalar and vector call boundaries" {
    var input: [1024]u8 = undefined;
    var expected: [64]u8 = undefined;
    var actual: [64]u8 = undefined;
    for (0..2) |fixture| {
        var random = std.Random.DefaultPrng.init(0x8b17);
        if (fixture == 0) @memset(&input, 0) else random.random().bytes(&input);
        var reference = TieBits.init(42);
        classify(&reference, &input, &expected);
        for (0..8) |prefix| {
            var state = TieBits.init(42);
            var offset = prefix * 16;
            classify(&state, input[0..offset], actual[0 .. offset / 16]);
            var step: usize = 0;
            while (offset < input.len) : (step += 1) {
                const n = @min((step % 7 + 1) * 16, input.len - offset);
                classify(&state, input[offset..][0..n], actual[offset / 16 ..][0 .. n / 16]);
                offset += n;
            }
            try std.testing.expectEqualSlices(u8, &expected, &actual);
            try std.testing.expectEqualDeep(reference, state);
        }
    }
}

test "mixed CPU and GPU tie group widths consume the complete Arbee byte stream" {
    var reference = Arbee.init(42);
    var expected: [24]u8 = undefined;
    for (0..3) |word| std.mem.writeInt(u64, expected[word * 8 ..][0..8], reference.next(), .little);
    for (0..8) |prefix| {
        var state = TieBits.init(42);
        var actual: [24]u8 = undefined;
        for (actual[0..prefix]) |*byte| byte.* = state.take(u8);
        std.mem.writeInt(u32, actual[prefix..][0..4], state.take(u32), .little);
        std.mem.writeInt(u16, actual[prefix + 4 ..][0..2], state.take(u16), .little);
        actual[prefix + 6] = state.take(u8);
        std.mem.writeInt(u32, actual[prefix + 7 ..][0..4], state.take(u32), .little);
        for (actual[prefix + 11 ..]) |*byte| byte.* = state.take(u8);
        try std.testing.expectEqualSlices(u8, &expected, &actual);
        try std.testing.expectEqualDeep(reference, state.generator);
        try std.testing.expectEqual(@as(u7, 0), state.remaining);
        try std.testing.expectEqual(@as(u64, 0), state.pending);
    }
}
