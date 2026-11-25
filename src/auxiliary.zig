// PractRand 0.96's arbee (CC0). Entropy and seeds are explicit inputs;
// acquiring system entropy belongs to the caller.
const std = @import("std");
pub const Arbee = struct {
    // Raw state defaults remain zero; use init, initSeeded, or initEntropy.
    a: u64 = 0,
    b: u64 = 0,
    c: u64 = 0,
    d: u64 = 0,
    counter: u64 = 0,
    pub fn init(seed_value: u64) Arbee {
        return initSeeded(seed_value, 0);
    }
    pub fn initSeeded(seed_low: u64, seed_high: u64) Arbee {
        var t = Arbee{ .a = seed_low, .b = seed_high, .c = seed_low, .d = seed_high };
        for (0..8) |_| _ = t.next();
        return t;
    }
    /// Matches upstream's default constructor, distinct from seeding with zero.
    pub fn initEntropy() Arbee {
        var t: Arbee = .{};
        t.resetEntropy();
        return t;
    }
    pub fn seed(t: *Arbee, seed_low: u64, seed_high: u64) void {
        t.* = initSeeded(seed_low, seed_high);
    }
    pub fn resetEntropy(t: *Arbee) void {
        // Upstream's precomputed state after eight steps from {1, 2, 3, 4, 0}.
        t.* = .{
            .a = 6297939664007638733,
            .b = 10847301951251065963,
            .c = 8760839667624891872,
            .d = 11710998636947437130,
            .counter = 8,
        };
    }
    // Each narrow output consumes a whole word, without retaining unused bits.
    pub fn raw8(t: *Arbee) u8 {
        return @truncate(t.next());
    }
    pub fn raw16(t: *Arbee) u16 {
        return @truncate(t.next());
    }
    pub fn raw32(t: *Arbee) u32 {
        return @truncate(t.next());
    }
    pub fn raw64(t: *Arbee) u64 {
        return t.next();
    }
    pub fn next(t: *Arbee) u64 {
        const e = t.a +% std.math.rotl(u64, t.b, 21);
        t.a = t.b ^ std.math.rotl(u64, t.c, 39);
        t.b = t.c +% std.math.rotl(u64, t.d, 28);
        t.c = e +% t.d +% t.counter;
        t.counter +%= 1;
        t.d = e +% t.a;
        return t.d;
    }
    pub fn addEntropy8(t: *Arbee, value: u8) void {
        t.addEntropy16(value);
    }
    pub fn addEntropy16(t: *Arbee, value: u16) void {
        t.b ^= value;
        _ = t.next();
    }
    pub fn addEntropy32(t: *Arbee, value: u32) void {
        t.b ^= value;
        t.d +%= value;
        _ = t.next();
    }
    pub fn addEntropy64(t: *Arbee, value: u64) void {
        t.b ^= value;
        t.d +%= value;
        _ = t.next();
        _ = t.next();
    }
    /// Matches add_entropy_N: little-endian 8-byte chunks, then 4/2/1 bytes.
    /// Call boundaries matter: mixing adjacent slices separately can differ.
    pub fn addEntropy(t: *Arbee, bytes: []const u8) void {
        var data = bytes;
        while (data.len >= 8) : (data = data[8..]) {
            t.addEntropy64(std.mem.readInt(u64, data[0..8], .little));
        }
        if (data.len >= 4) {
            t.addEntropy32(std.mem.readInt(u32, data[0..4], .little));
            data = data[4..];
        }
        if (data.len >= 2) {
            t.addEntropy16(std.mem.readInt(u16, data[0..2], .little));
            data = data[2..];
        }
        if (data.len != 0) t.addEntropy8(data[0]);
    }
    pub fn flushBuffers(t: *Arbee) void {
        for (0..7) |_| _ = t.next();
    }
};

// Golden outputs captured from the unchanged PractRand 0.96 Raw::arbee source.
// Every vector contains four consecutive raw64 outputs after the named operation.
test "Arbee seeding and reset match upstream vectors" {
    const seeds = [_][2]u64{
        .{ 0, 0 },
        .{ 1, 0 },
        .{ 0xffffffffffffffff, 0xffffffffffffffff },
        .{ 0x0123456789abcdef, 0xfedcba9876543210 },
    };
    const expected = [_][4]u64{
        .{ 0xba572bed60de9585, 0xa795ffbc6d37cfba, 0x93f85c0220dbe40e, 0x6bf4d06f6d84bb62 },
        .{ 0x83e9778c525bf31d, 0xcc1bd91df26b8521, 0xa2dac8ac68755421, 0x99f40f432a29c3e3 },
        .{ 0xa6c6a484ac7ddc25, 0xca8f96ca4af089a6, 0xc34a88bb99b85569, 0x7414f8d371b8f5b2 },
        .{ 0xa9cbd7ec3834f7a4, 0x11dbf1a6319f5b18, 0x544d375a0db7537e, 0x910d4d74f97b548e },
    };
    for (seeds, expected) |words, outputs| {
        var actual = Arbee.initSeeded(words[0], words[1]);
        try std.testing.expectEqual(@as(u64, 8), actual.counter);
        for (outputs) |word| try std.testing.expectEqual(word, actual.raw64());
        actual.seed(words[0], words[1]);
        try std.testing.expectEqualDeep(Arbee.initSeeded(words[0], words[1]), actual);
    }
    try std.testing.expectEqualDeep(Arbee.initSeeded(42, 0), Arbee.init(42));
    var reset = Arbee.initEntropy();
    var stepped: Arbee = .{ .a = 1, .b = 2, .c = 3, .d = 4 };
    for (0..8) |_| _ = stepped.next();
    try std.testing.expectEqualDeep(stepped, reset);
    const reset_outputs = [4]u64{
        0xae316973354f8d02,
        0xfe7254126533e612,
        0xb75280b0fcff7100,
        0x27746561d2221982,
    };
    for (reset_outputs) |word| try std.testing.expectEqual(word, reset.next());
    reset.resetEntropy();
    try std.testing.expectEqualDeep(Arbee.initEntropy(), reset);
}

test "Arbee entropy bytes match upstream for every tail and unaligned input" {
    // Reference: seed(0x0123456789abcdef, 0xfedcba9876543210), then
    // add_entropy_N(bytes, len) for len 0..32; bytes[j] = (j * 37 + 11) mod 256.
    const expected = [_][4]u64{
        .{ 0xa9cbd7ec3834f7a4, 0x11dbf1a6319f5b18, 0x544d375a0db7537e, 0x910d4d74f97b548e },
        .{ 0x61dbf1a6319f5b1a, 0x1445245a3e975545, 0x0114b6c56bb55488, 0x5a5dbd2eaf156f17 },
        .{ 0x61dbf1a6319f4c1a, 0xd41525503e935545, 0xc4f1b319cbb53388, 0x1ead77f07535895f },
        .{ 0x041525503e93558d, 0xa4ecdc1422152046, 0xced587172d4b89ca, 0x508bc631a748f1b8 },
        .{ 0xe8dd21234171107f, 0x78c69229c3358818, 0x519bc85cc2760fc6, 0x38916d5c4d4f4cf5 },
        .{ 0x08c69229c33587ab, 0x91e105761f95edf7, 0xe8b6c61e93154a38, 0x5e869faf24e0489f },
        .{ 0x08c69229c335b7eb, 0xa235019e9f86edf7, 0xd8190d1f4b15ddf9, 0x3d9e38c84a2a26c3 },
        .{ 0x3235019e9f86ed5f, 0xf89c1414b675d838, 0xce2f1335987c276f, 0xd002abffb1487b16 },
        .{ 0x442e0b82410f03ab, 0x04263fca45a8c99b, 0x66b4116b9ec7d1cc, 0xec6f40daf5564b03 },
        .{ 0x34263fca45a8c991, 0x2624c264c767de8e, 0x7be2f4a3a2b04b24, 0x1af8691fa825a9df },
        .{ 0x34263fca45a87811, 0xc7ecccf1c75ddb8d, 0x27cd832292b0d1a4, 0xbc7d0f167b830e73 },
        .{ 0x97ecccf1c75ddbba, 0x483144254310d0e4, 0x0ce03e4d4f7ca1cd, 0xd5f26a317d8afef0 },
        .{ 0xa1e56cfabd1f2ce2, 0x9acf2c8cfe1af119, 0x26dde047474d7b23, 0x70d260077cf2a112 },
        .{ 0x6acf2c8cfe1af160, 0x68c726fb3f2d4bbb, 0xe43bc120adbca054, 0xd8ee15e1b5273c5f },
        .{ 0x6acf2c8cfe1ad3a0, 0xb713250fbf14543d, 0x1a71f79865bc7296, 0xb69a1663d85ad78d },
        .{ 0xc713250fbf14544f, 0x1ab9a49753dc6f00, 0xa6e5d9d198c0d758, 0x643f26fb55589f14 },
        .{ 0x93db4a8621443b9b, 0x64f449a642db6195, 0x7d6085baa6f363fe, 0x913bf7c36a36a123 },
        .{ 0xf4f449a642db619b, 0xa1a2fcae82135165, 0x24e025475960a45d, 0xbaba15adc455ec95 },
        .{ 0xf4f449a642dad99b, 0x9c22f4be81f36167, 0xdec825e85961bc5f, 0xbc3410ad14e71cd5 },
        .{ 0x4c22f4be81f361f8, 0x832e64eaba0195c6, 0xb0791bf7aa2d1bfc, 0x8e32a3c5d6c43cb6 },
        .{ 0x17a0bf4344c1a25c, 0xcae9f7999fed1ad0, 0x81b9ca1dbf22559f, 0xd619c9a9b791d1b1 },
        .{ 0xfae9f7999fed1a9f, 0xe0a8ef2242c23fbf, 0x05011181ac13d349, 0xd0f24315a1d4be99 },
        .{ 0xfae9f7999fed085f, 0xc124f05dc2c7403f, 0xee44d36d84141a09, 0xec4a154ca631962f },
        .{ 0x7124f05dc2c73fea, 0x4e39106bb7341fda, 0x9b6373d5720395e0, 0x6e2f62f6507a3186 },
        .{ 0xd562d9e600009475, 0x11031c4c188dce9a, 0xf83484bb9d70e143, 0x33cb82fbb5adb8d5 },
        .{ 0x01031c4c188dce35, 0x763b09b3bdd0c1a3, 0xc1f3a158da9fba43, 0xea4484836e5d9d35 },
        .{ 0x01031c4c188d5fb5, 0xf8830f26bdeabba3, 0x03f52f750a9feac0, 0x1a9b7493b8f63e5c },
        .{ 0x08830f26bdeabb5c, 0x0df2045ac23fbb78, 0x1446ab0da2f03e9a, 0x5e98c21ff7cb6a63 },
        .{ 0xdb86a333415f14c6, 0xab1eaa9fe29e4f07, 0xaea6e1e9e6756e2a, 0xafef997c0eb4a31c },
        .{ 0x3b1eaa9fe29e4eed, 0x8db672daf1d5685f, 0xfee93cddcce6a338, 0x72bf74e14abfaa10 },
        .{ 0x3b1eaa9fe29e26ad, 0x9d0b64a071a85f5d, 0xf927eb8964e63677, 0x5b41b909b3fac912 },
        .{ 0xad0b64a071a85efe, 0x18a5568f60064e2f, 0x6ab75581cf3cc9c6, 0xf9edef1e62b38269 },
        .{ 0x083068d5002a0eac, 0x9c43950364de9896, 0x6f04d3a8db95c570, 0xb403e7e6937658ec },
    };
    var buffer: [39]u8 = undefined;
    for (0..8) |alignment| {
        const bytes = buffer[alignment..][0..32];
        for (bytes, 0..) |*byte, j| byte.* = @truncate(j * 37 + 11);
        for (expected, 0..) |outputs, len| {
            var actual = Arbee.initSeeded(0x0123456789abcdef, 0xfedcba9876543210);
            actual.addEntropy(bytes[0..len]);
            for (outputs) |word| try std.testing.expectEqual(word, actual.next());
        }
    }
}

test "Arbee scalar entropy and buffer flushing match upstream" {
    var actual = Arbee.initSeeded(0x0123456789abcdef, 0xfedcba9876543210);
    actual.addEntropy8(0xff);
    actual.addEntropy16(0xfedc);
    actual.addEntropy32(0xfedcba98);
    actual.addEntropy64(0xfedcba9876543210);
    var unflushed = actual;
    const outputs = [4]u64{
        0x890929a7f94551d0,
        0x75e05a812d2c70e9,
        0x1810be320f65192a,
        0x1f39d6c91c0a0eba,
    };
    for (outputs) |word| try std.testing.expectEqual(word, unflushed.next());
    actual.flushBuffers();
    const flushed_outputs = [4]u64{
        0xbcbb13d8d1598c30,
        0xe7c998585e383356,
        0xcdf4b2be1ce1dc3b,
        0x58afc32f0b7d1255,
    };
    for (flushed_outputs) |word| try std.testing.expectEqual(word, actual.next());
}

test "Arbee typed outputs consume full words and arithmetic wraps" {
    var actual = Arbee.init(42);
    var reference = actual;
    try std.testing.expectEqual(@as(u8, @truncate(reference.next())), actual.raw8());
    try std.testing.expectEqual(@as(u16, @truncate(reference.next())), actual.raw16());
    try std.testing.expectEqual(@as(u32, @truncate(reference.next())), actual.raw32());
    try std.testing.expectEqual(reference.next(), actual.raw64());
    try std.testing.expectEqualDeep(reference, actual);

    const max = std.math.maxInt(u64);
    actual = .{ .a = max, .b = max, .c = max, .d = max, .counter = max };
    const outputs = [4]u64{
        0xfffffffffffffffe,
        0x0000017fffe00000,
        0x0ffe02800f800004,
        0x5ffdfc0013817fae,
    };
    for (outputs) |word| try std.testing.expectEqual(word, actual.next());
    try std.testing.expectEqual(@as(u64, 3), actual.counter);
}
