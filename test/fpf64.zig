const std = @import("std");
const b = @import("battery");
const Pattern = b.FloatingPattern(6);

fn fill(input: []u8) void {
    var state: u64 = 0;
    var offset: usize = 0;
    while (offset < input.len) : (offset += 8) {
        state +%= 0x9e3779b97f4a7c15;
        var value = state;
        value = (value ^ (value >> 30)) *% 0xbf58476d1ce4e5b9;
        value = (value ^ (value >> 27)) *% 0x94d049bb133111eb;
        value ^= value >> 31;
        std.mem.writeInt(u64, input[offset..][0..8], value, .little);
    }
}

test "FPF64 histograms match an independent aligned bit-window oracle" {
    const a = std.testing.allocator;
    const input = try a.alloc(u8, 256 * 1024);
    defer a.free(input);
    const expected = try a.alloc(u64, Pattern.count_bins);
    defer a.free(expected);
    const actual = try a.alloc(u64, Pattern.count_bins);
    defer a.free(actual);
    for (0..4) |fixture| {
        fill(input);
        if (fixture == 0) @memset(input, 0);
        if (fixture == 1) @memset(input, 255);
        if (fixture == 2) {
            // Exercise every trailing-zero count, the capped exponent and
            // arbitrary significands; every 65th word is entirely zero.
            var offset: usize = 0;
            while (offset < input.len) : (offset += 8) {
                const exponent = (offset / 8) % 65;
                const value = std.mem.readInt(u64, input[offset..][0..8], .little);
                const shifted = if (exponent == 64) 0 else (value | 1) << @as(u6, @intCast(exponent));
                std.mem.writeInt(u64, input[offset..][0..8], shifted, .little);
            }
        }
        @memset(expected, 0);
        @memset(actual, 0);
        // Read individual bits rather than using the kernel's word/ctz/mask
        // extraction. The approved window starts at each multiple of 64 bits.
        var offset: usize = 0;
        while (offset < input.len) : (offset += 8) {
            var exponent: usize = 0;
            while (exponent < 51 and input[offset + exponent / 8] & (@as(u8, 1) << @as(u3, @intCast(exponent % 8))) == 0) : (exponent += 1) {}
            const start = exponent + @intFromBool(exponent < 51);
            var significand: usize = 0;
            for (0..14) |bit| {
                const position = start + bit;
                if (position < 64) significand += @as(usize, (input[offset + position / 8] >> @as(u3, @intCast(position % 8))) & 1) * (@as(usize, 1) << @intCast(bit));
            }
            expected[exponent * 16384 + significand] += 1;
        }
        var pattern = Pattern{ .counts = actual };
        // Differently sized calls also require retaining the approved alignment.
        offset = 0;
        for ([_]usize{ 1, 3, 17, 235 }) |blocks| {
            try std.testing.expect(offset + blocks * 1024 <= input.len);
            pattern.update(input[offset..][0 .. blocks * 1024]);
            offset += blocks * 1024;
        }
        try std.testing.expectEqual(input.len, offset);
        try std.testing.expectEqualSlices(u64, expected, actual);
    }
}

test "FPF64 reference scoring matches retained original single-call results" {
    const Row = struct { name: []const u8, kind: b.Kind, raw: f64, value: f64, probability: f64, suspicion: f64, weight: f64 };
    const Case = struct { blocks: usize, input_sha256: []const u8, results: []const Row };
    const Fixture = struct { format_version: u8, reference_version: []const u8, driver_sha256: []const u8, cases: []const Case };
    const fixture = try std.json.parseFromSlice(Fixture, std.testing.allocator, @embedFile("reference-results/fpf64.json"), .{ .ignore_unknown_fields = true });
    defer fixture.deinit();
    try std.testing.expectEqual(@as(u8, 1), fixture.value.format_version);
    try std.testing.expectEqualStrings("0.96", fixture.value.reference_version);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(@embedFile("reference_fpf64.cpp"), &digest, .{});
    try std.testing.expectEqualStrings(fixture.value.driver_sha256, &std.fmt.bytesToHex(digest, .lower));
    try std.testing.expectEqual(@as(usize, 3), fixture.value.cases.len);
    for (fixture.value.cases, [_]usize{ 1, 8, 256 }) |case, blocks| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        try std.testing.expectEqual(blocks, case.blocks);
        const input = try a.alloc(u8, blocks * 1024);
        fill(input);
        std.crypto.hash.sha2.Sha256.hash(input, &digest, .{});
        try std.testing.expectEqualStrings(case.input_sha256, &std.fmt.bytesToHex(digest, .lower));
        const counts = try a.alloc(u64, Pattern.count_bins);
        @memset(counts, 0);
        var pattern = Pattern{ .counts = counts };
        pattern.update(input);
        var results = b.Results{ .allocator = a, .arithmetic = .reference };
        try pattern.results(blocks, &results);
        try std.testing.expect(case.results.len != 0);
        try std.testing.expectEqual(case.results.len, results.items.items.len);
        for (case.results, results.items.items) |expected, actual| {
            try std.testing.expectEqualStrings(expected.name, actual.name);
            try std.testing.expectEqual(expected.kind, actual.kind);
            // Existing compare_values.py tolerances for cross-target original
            // arithmetic; no fixture-comparison exemption or tolerance changes.
            for ([_]f64{ expected.raw, expected.value, expected.suspicion }, [_]f64{ actual.raw, actual.value, actual.suspicion() }) |left, right| {
                try std.testing.expect(std.math.isFinite(left) and std.math.isFinite(right));
                try std.testing.expectApproxEqAbs(left, right, @max(1e-6, @abs(left) * 1e-10));
            }
            try std.testing.expectApproxEqAbs(expected.probability, actual.probability(), 1e-10);
            try std.testing.expectApproxEqAbs(expected.weight, actual.weight, 1e-15);
        }
    }
}
