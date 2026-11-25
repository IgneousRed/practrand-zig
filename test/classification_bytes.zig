// Byte-for-byte comparison with the diagnostic original classification owner.
const std = @import("std");
const classification = @import("classification");
extern "c" fn write(c_int, [*]const u8, usize) isize;

fn emit(bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = write(1, bytes[offset..].ptr, bytes.len - offset);
        if (written <= 0) return error.OutputFailed;
        offset += @intCast(written);
    }
}

pub fn main() !void {
    const blocks = 16385;
    const a = std.heap.page_allocator;
    const input = try a.alloc(u8, blocks * 1024);
    defer a.free(input);
    const output = try a.alloc(u8, input.len / 16);
    defer a.free(output);
    for (0..5) |fixture| {
        for (input, 0..) |*byte, i| byte.* = switch (fixture) {
            0 => @truncate(i * 37 + 11),
            1 => 0,
            2 => 255,
            3 => 0x55,
            4 => if (i % 16 == 0) 1 else 0,
            else => unreachable,
        };
        for (0..2) |schedule| {
            var random = classification.TieBits.init(0x9e3779b97f4a7c15);
            if (schedule == 0) {
                classification.classify(&random, input, output);
            } else {
                const chunks = [_]usize{ 1, 3, 7, 31, 2048 };
                var offset: usize = 0;
                var step: usize = 0;
                while (offset < input.len) : (step += 1) {
                    const count = @min(chunks[step % chunks.len] * 1024, input.len - offset);
                    classification.classify(&random, input[offset..][0..count], output[offset / 16 ..][0 .. count / 16]);
                    offset += count;
                }
            }
            try emit(output);
            if (random.remaining != 0) return error.IncompleteTieWord;
            var next: [8]u8 = undefined;
            std.mem.writeInt(u64, &next, random.generator.next(), .little);
            try emit(&next);
        }
    }
}
