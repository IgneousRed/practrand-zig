const std = @import("std");
const seeding = @import("seed_testing.zig");
pub const SeedTest = seeding.Config;
pub const Target = union(enum) { output, seeding: SeedTest, entropy };
extern "c" fn pr_rng_open([*:0]const u8, c_int, *c_uint, [*]u8, usize) ?*anyopaque;
extern "c" fn pr_rng_seedable(*const anyopaque) c_int;
extern "c" fn pr_rng_has_stream(*const anyopaque) c_int;
extern "c" fn pr_rng_seed(*anyopaque, u64, u64, [*]u8, usize) c_int;
extern "c" fn pr_rng_destroy(*anyopaque) void;
extern "c" fn pr_rng_name(*const anyopaque) [*:0]const u8;
extern "c" fn pr_rng_width(*const anyopaque) c_int;
extern "c" fn pr_rng_fill(*anyopaque, [*]u8, usize, [*]u8, usize) c_int;
extern "c" fn pr_rng_seed_word(*anyopaque, u64, u64, *u64, [*]u8, usize) c_int;
extern "c" fn pr_rng_random_seed(*u64) c_int;
pub extern "c" fn pr_rng_factory_count() usize;
pub extern "c" fn pr_rng_factory_name(usize) ?[*:0]const u8;
pub extern "c" fn pr_rng_catalog_name(c_uint, usize) ?[*:0]const u8;
pub extern "c" fn pr_rng_catalog_label(c_uint) ?[*:0]const u8;

pub fn parseSeed(text: []const u8) !u128 {
    const digits = if (std.mem.startsWith(u8, text, "0x")) text[2..] else text;
    if (digits.len == 0) return error.InvalidSeed;
    var value: u128 = 0;
    for (digits) |char| {
        if (value >> 124 != 0) return error.InvalidSeed;
        const digit = std.fmt.charToDigit(char, 16) catch return error.InvalidSeed;
        value = value * 16 + digit;
    }
    return value;
}

pub const Generator = struct {
    handle: *anyopaque,
    name: []const u8,
    seed: []const u8,
    width: u7,
    seed_bits: c_uint = 0,
    stream_input: bool = false,
    walk: ?seeding.Walk = null,
    pending: u64 = 0,
    remaining: u4 = 0,
    pub fn init(a: std.mem.Allocator, expression: []const u8, seed_text: ?[]const u8, diagnostic: *[1024]u8) !Generator {
        return initTarget(a, expression, seed_text, .output, diagnostic);
    }
    pub fn initTarget(a: std.mem.Allocator, expression: []const u8, seed_text: ?[]const u8, target: Target, diagnostic: *[1024]u8) !Generator {
        const expression_z = try a.dupeSentinel(u8, expression, 0);
        defer a.free(expression_z);
        diagnostic[0] = 0;
        var bits: c_uint = if (target == .seeding) target.seeding.bits else 0;
        const mode: c_int = switch (target) {
            .output => 0,
            .seeding => |config| @backingInt(config.mode),
            .entropy => 4,
        };
        const handle = pr_rng_open(expression_z, mode, &bits, diagnostic, diagnostic.len) orelse return error.InvalidGenerator;
        errdefer pr_rng_destroy(handle);
        const seedable = pr_rng_seedable(handle) != 0;
        var low: u64 = 0;
        const seed: u128 = if (!seedable) 0 else if (seed_text) |text| try parseSeed(text) else blk: {
            if (pr_rng_random_seed(&low) != 0) return error.EntropyUnavailable;
            break :blk low;
        };
        if (target != .seeding or target.seeding.mode == .original) switch (pr_rng_seed(handle, @truncate(seed), @truncate(seed >> 64), diagnostic, diagnostic.len)) {
            0 => {},
            1 => return error.InputExhausted,
            else => return error.GeneratorFailed,
        };
        const width = pr_rng_width(handle);
        const walk = if (target == .seeding and target.seeding.mode != .original) try seeding.Walk.init(target.seeding.mode, @intCast(bits), seed) else null;
        return .{ .handle = handle, .name = std.mem.span(pr_rng_name(handle)), .seed = seed_text orelse (if (seedable) try std.fmt.allocPrint(a, "{x}", .{seed}) else "unknown"), .stream_input = pr_rng_has_stream(handle) != 0, .seed_bits = @intCast(bits), .walk = walk, .width = switch (width) {
            8, 16, 32, 64 => @intCast(width),
            else => 0,
        } };
    }
    pub fn deinit(source: *Generator) void {
        pr_rng_destroy(source.handle);
    }
    pub fn fill(source: *Generator, output: []u8, diagnostic: *[1024]u8) !void {
        if (source.walk) |*walk| {
            for (output) |*byte| {
                if (source.remaining == 0) {
                    const seed = try walk.next();
                    switch (pr_rng_seed_word(source.handle, @truncate(seed), @truncate(seed >> 64), &source.pending, diagnostic, diagnostic.len)) {
                        0 => {},
                        1 => return error.InputExhausted,
                        else => return error.GeneratorFailed,
                    }
                    source.remaining = 8;
                }
                byte.* = @truncate(source.pending);
                source.pending >>= 8;
                source.remaining -= 1;
            }
            return;
        }
        switch (pr_rng_fill(source.handle, output.ptr, output.len, diagnostic, diagnostic.len)) {
            0 => {},
            1 => return error.InputExhausted,
            else => return error.GeneratorFailed,
        }
    }
};

test "builtin seed parsing uses the original 128-bit hexadecimal convention" {
    try std.testing.expectEqual(@as(u128, 0x10), try parseSeed("10"));
    try std.testing.expectEqual(std.math.maxInt(u128), try parseSeed("0xffffffffffffffffffffffffffffffff"));
    for ([_][]const u8{ "", "0x", "-1", "+1", "1_0", "xyz", "100000000000000000000000000000000" }) |text| try std.testing.expectError(error.InvalidSeed, parseSeed(text));
}
