const std = @import("std");
const rng = @import("builtin_rngs");
extern "c" fn pr_rng_seed(*anyopaque, u64, u64, [*]u8, usize) c_int;

test "native reseeding discards a buffered partial output word" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: [1024]u8 = @splat(0);
    for ([_][]const u8{ "sfc16", "sfc32", "sfc64" }) |expression| {
        var source = try rng.Generator.init(arena.allocator(), expression, "0", &diagnostic);
        defer source.deinit();
        var fresh = try rng.Generator.init(arena.allocator(), expression, "1", &diagnostic);
        defer fresh.deinit();
        var actual: [33]u8 = undefined;
        var expected: [33]u8 = undefined;
        try source.fill(actual[0..3], &diagnostic);
        try std.testing.expectEqual(@as(c_int, 0), pr_rng_seed(source.handle, 1, 0, &diagnostic, diagnostic.len));
        try source.fill(&actual, &diagnostic);
        try fresh.fill(&expected, &diagnostic);
        try std.testing.expectEqualSlices(u8, &expected, &actual);
    }
}

test "all retained builtin byte vectors match whole and irregular fills" {
    const Case = struct { expression: []const u8, seed: []const u8, name: []const u8, width: u7, sha256: []const u8 };
    const Fixture = struct { format_version: u8, reference_version: []const u8, bytes: usize, factory_names: []const []const u8, cases: []const Case };
    const fixtures = try std.json.parseFromSlice(Fixture, std.testing.allocator, @embedFile("rng-vectors.json"), .{ .ignore_unknown_fields = true });
    defer fixtures.deinit();
    try std.testing.expectEqual(@as(u8, 1), fixtures.value.format_version);
    try std.testing.expectEqualStrings("0.96", fixtures.value.reference_version);
    try std.testing.expectEqual(fixtures.value.factory_names.len + 6 + 13 + 2, rng.pr_rng_factory_count());
    var original: usize = 0;
    for (0..rng.pr_rng_factory_count()) |i| {
        const name = std.mem.span(rng.pr_rng_factory_name(i).?);
        if (std.mem.eql(u8, name, "SeedingTester") or std.mem.eql(u8, name, "RecursiveSeed64") or std.mem.eql(u8, name, "EntropyPoolingTester")) continue;
        if (std.mem.startsWith(u8, name, "file") or std.mem.startsWith(u8, name, "stdin")) continue;
        if (std.mem.startsWith(u8, name, "xsm") or std.mem.startsWith(u8, name, "rarns")) continue;
        if (std.mem.eql(u8, name, "ranrot_var32_fixed") or std.mem.eql(u8, name, "ranrot_var64_fixed")) continue;
        try std.testing.expectEqualStrings(fixtures.value.factory_names[original], name);
        original += 1;
    }
    try std.testing.expectEqual(fixtures.value.factory_names.len, original);
    const output = try std.testing.allocator.alloc(u8, fixtures.value.bytes);
    defer std.testing.allocator.free(output);
    var diagnostic: [1024]u8 = @splat(0);
    for (fixtures.value.cases) |case| {
        for ([_]bool{ false, true }) |split| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var generator = rng.Generator.init(arena.allocator(), case.expression, case.seed, &diagnostic) catch |err| {
                std.debug.print("{s}: {s}\n", .{ case.expression, std.mem.sliceTo(&diagnostic, 0) });
                return err;
            };
            defer generator.deinit();
            try std.testing.expectEqualStrings(case.name, generator.name);
            try std.testing.expectEqual(case.width, generator.width);
            if (split) {
                var offset: usize = 0;
                var call: usize = 0;
                while (offset < output.len) : (call += 1) {
                    const sizes = [_]usize{ 1, 7, 3, 1024, 11, 31, 128 };
                    const count = @min(sizes[call % sizes.len], output.len - offset);
                    try generator.fill(output[offset..][0..count], &diagnostic);
                    offset += count;
                }
            } else try generator.fill(output, &diagnostic);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(output, &digest, .{});
            const actual = std.fmt.bytesToHex(digest, .lower);
            if (!std.mem.eql(u8, case.sha256, &actual)) std.debug.print("byte mismatch: {s}, seed {s}, split={}\n", .{ case.expression, case.seed, split });
            try std.testing.expectEqualStrings(case.sha256, &actual);
        }
    }
}

test "removed recommended slots and malformed expressions diagnose before generation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: [1024]u8 = @splat(0);
    for ([_][]const u8{ "xsm16", "rarns64", "recommended_rngs(12)", "recommended_rngs(22)" }) |expression| {
        try std.testing.expectError(error.InvalidGenerator, rng.Generator.init(arena.allocator(), expression, "0", &diagnostic));
        try std.testing.expect(std.mem.indexOf(u8, std.mem.sliceTo(&diagnostic, 0), "no longer supported") != null);
    }
    for ([_][]const u8{ "unknown_rng", "sfc16(", "chacha(0)", "recommended_rngs(0)", "sfc64(1)" }) |expression| try std.testing.expectError(error.InvalidGenerator, rng.Generator.init(arena.allocator(), expression, "0", &diagnostic));
    try std.testing.expectEqualStrings("xsm64", std.mem.span(rng.pr_rng_catalog_name(0, 11).?));
    try std.testing.expectEqualStrings("mrc16", std.mem.span(rng.pr_rng_catalog_name(0, 26).?));
}

test "fixed Ranrot streams match independent integer controls with irregular fills" {
    const Case = struct { expression: []const u8, seed: []const u8, name: []const u8, width: u7, sha256: []const u8 };
    const Fixture = struct { bytes: usize, cases: []const Case };
    const fixture = try std.json.parseFromSlice(Fixture, std.testing.allocator, @embedFile("ranrot-fixed.json"), .{ .ignore_unknown_fields = true });
    defer fixture.deinit();
    const output = try std.testing.allocator.alloc(u8, fixture.value.bytes);
    defer std.testing.allocator.free(output);
    for (fixture.value.cases) |case| {
        for ([_]bool{ false, true }) |split| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var diagnostic: [1024]u8 = @splat(0);
            var source = try rng.Generator.init(arena.allocator(), case.expression, case.seed, &diagnostic);
            defer source.deinit();
            try std.testing.expectEqualStrings("", std.mem.sliceTo(&diagnostic, 0));
            try std.testing.expectEqualStrings(case.name, source.name);
            try std.testing.expectEqual(case.width, source.width);
            const sizes = [_]usize{ 1, 7, 3, 1024, 11, 31, 128 };
            var offset: usize = 0;
            var call: usize = 0;
            while (offset < output.len) : (call += 1) {
                const count = @min(if (split) sizes[call % sizes.len] else output.len, output.len - offset);
                try source.fill(output[offset..][0..count], &diagnostic);
                offset += count;
            }
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(output, &digest, .{});
            try std.testing.expectEqualStrings(case.sha256, &std.fmt.bytesToHex(digest, .lower));
        }
    }
}

test "seeding streams match independent original-library vectors across irregular fills" {
    const Case = struct { expression: []const u8, seed: []const u8, mode: []const u8, bits: u8, resolved_bits: u8, bytes: usize, sha256: []const u8 };
    const Fixture = struct { format_version: u8, cases: []const Case };
    const fixture = try std.json.parseFromSlice(Fixture, std.testing.allocator, @embedFile("seed-vectors.json"), .{ .ignore_unknown_fields = true });
    defer fixture.deinit();
    try std.testing.expectEqual(@as(u8, 1), fixture.value.format_version);
    var diagnostic: [1024]u8 = @splat(0);
    for (fixture.value.cases) |case| {
        const mode: @TypeOf(@as(rng.SeedTest, .{}).mode) = if (std.mem.eql(u8, case.mode, "original")) .original else if (std.mem.eql(u8, case.mode, "gray")) .gray else .balanced_gray;
        const output = try std.testing.allocator.alloc(u8, case.bytes);
        defer std.testing.allocator.free(output);
        for ([_]bool{ false, true }) |split| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var source = try rng.Generator.initTarget(arena.allocator(), case.expression, case.seed, .{ .seeding = .{ .bits = case.bits, .mode = mode } }, &diagnostic);
            defer source.deinit();
            try std.testing.expectEqual(@as(u7, 64), source.width);
            try std.testing.expectEqual(case.resolved_bits, source.seed_bits);
            if (split) {
                var offset: usize = 0;
                var call: usize = 0;
                const sizes = [_]usize{ 1, 7, 3, 1024, 11, 31, 128 };
                while (offset < output.len) : (call += 1) {
                    const count = @min(sizes[call % sizes.len], output.len - offset);
                    try source.fill(output[offset..][0..count], &diagnostic);
                    offset += count;
                }
            } else try source.fill(output, &diagnostic);
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(output, &hash, .{});
            const actual = std.fmt.bytesToHex(hash, .lower);
            if (!std.mem.eql(u8, case.sha256, &actual)) std.debug.print("seeding mismatch: {s}, {s}, {} bits, seed {s}, split={}\n", .{ case.expression, case.mode, case.bits, case.seed, split });
            try std.testing.expectEqualStrings(case.sha256, &actual);
        }
    }
}

test "original native seed target accepts tiny widths without factory validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: [1024]u8 = @splat(0);
    for ([_]c_uint{ 1, 2, 6, 7, 8, 15 }) |bits| {
        // Initialize only: the unchanged original walk can stall once a tiny
        // space is exhausted by its recent-history rejection (UB052).
        var source = try rng.Generator.initTarget(arena.allocator(), "sfc64", "0", .{ .seeding = .{ .bits = bits } }, &diagnostic);
        defer source.deinit();
        try std.testing.expectEqual(bits, source.seed_bits);
    }
    // The expression factory is a separate upstream entry point with bounds.
    try std.testing.expectError(error.InvalidGenerator, rng.Generator.init(arena.allocator(), "SeedingTester(sfc64,8)", "0", &diagnostic));
}

test "deterministic seeding preserves the last partial word and then exhausts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: [1024]u8 = @splat(0);
    for ([_]@TypeOf(@as(rng.SeedTest, .{}).mode){ .gray, .balanced_gray }) |mode| {
        var source = try rng.Generator.initTarget(arena.allocator(), "sfc64", "0", .{ .seeding = .{ .bits = 16, .mode = mode } }, &diagnostic);
        defer source.deinit();
        const output = try arena.allocator().alloc(u8, 8 * 65536);
        try source.fill(output[0 .. output.len - 1], &diagnostic);
        try source.fill(output[output.len - 1 ..], &diagnostic);
        try std.testing.expectError(error.SeedCycleExhausted, source.fill(output[0..1], &diagnostic));
    }
    try std.testing.expectError(error.InvalidGenerator, rng.Generator.initTarget(arena.allocator(), "sfc64", "0", .{ .seeding = .{ .bits = 24, .mode = .balanced_gray } }, &diagnostic));
}
