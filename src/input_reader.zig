// Cancellable input prefetch. Only copied bytes reach the statistical caller;
// arbitrary report events never redefine its logical input-call boundaries.
const std = @import("std");
const slot_count = 4;
extern "c" fn read(c_int, [*]u8, usize) isize;
extern "c" fn write(c_int, [*]const u8, usize) isize;
extern "c" fn pipe([*]c_int) c_int;
extern "c" fn close(c_int) c_int;
extern "c" fn poll([*]std.c.pollfd, std.c.nfds_t, c_int) c_int;

pub const Reader = struct {
    // The source is borrowed until deinit joins the producer. Only that producer
    // may advance it; bounded speculative fills can outlive the consumed prefix.
    pub const Generated = struct {
        context: *anyopaque,
        fill: *const fn (*anyopaque, []u8, *[1024]u8) anyerror!void,
    };
    const Source = union(enum) { descriptor: c_int, generated: Generated };

    const Slot = struct {
        bytes: []u8 = &.{},
        written: usize = 0,
        consumed: usize = 0,
        finished: bool = false,
        next: ?usize = null,
    };
    source: Source,
    diagnostic: [1024]u8 = @splat(0),
    cancel: [2]c_int = .{ -1, -1 },
    slots: [slot_count]Slot = @splat(.{}),
    free_ids: [slot_count]usize = undefined,
    free_count: usize = 0,
    active_slots: usize = 0,
    head: ?usize = null,
    tail: ?usize = null,
    remaining: u64,
    terminal: bool = false,
    failed: bool = false,
    stopping: bool = false,
    mutex: std.c.pthread_mutex_t = .{},
    changed: std.c.pthread_cond_t = .{},
    thread: std.Thread = undefined,
    pub fn init(r: *Reader, source: c_int, limit: u64, prefetch_bytes: usize) !void {
        try r.initSource(.{ .descriptor = source }, limit, prefetch_bytes);
    }
    pub fn initGenerated(r: *Reader, source: Generated, limit: u64, prefetch_bytes: usize) !void {
        try r.initSource(.{ .generated = source }, limit, prefetch_bytes);
    }
    fn initSource(r: *Reader, source: Source, limit: u64, prefetch_bytes: usize) !void {
        r.* = .{ .source = source, .remaining = limit };
        errdefer {
            for (r.slots[0..r.active_slots]) |slot| std.heap.page_allocator.free(slot.bytes);
            if (r.cancel[0] >= 0) _ = close(r.cancel[0]);
            if (r.cancel[1] >= 0) _ = close(r.cancel[1]);
        }
        for (0..slot_count) |id| {
            r.slots[id].bytes = try std.heap.page_allocator.alloc(u8, prefetch_bytes / slot_count);
            r.active_slots += 1;
            r.free_ids[r.free_count] = id;
            r.free_count += 1;
        }
        if (source == .descriptor and pipe(&r.cancel) != 0) return error.InputReaderInitializationFailed;
        r.thread = try std.Thread.spawn(.{}, worker, .{r});
    }
    pub fn deinit(r: *Reader) void {
        _ = std.c.pthread_mutex_lock(&r.mutex);
        r.stopping = true;
        _ = std.c.pthread_cond_broadcast(&r.changed);
        _ = std.c.pthread_mutex_unlock(&r.mutex);
        if (r.cancel[1] >= 0) _ = write(r.cancel[1], "x", 1);
        r.thread.join();
        if (r.cancel[0] >= 0) _ = close(r.cancel[0]);
        if (r.cancel[1] >= 0) _ = close(r.cancel[1]);
        for (r.slots[0..r.active_slots]) |slot| std.heap.page_allocator.free(slot.bytes);
        _ = std.c.pthread_cond_destroy(&r.changed);
        _ = std.c.pthread_mutex_destroy(&r.mutex);
    }
    // All queue metadata holds the mutex. The writer modifies only bytes AFTER
    // written; the consumer copies the published prefix before releasing its slot.
    pub fn readInto(r: *Reader, destination: []u8) !usize {
        var used: usize = 0;
        _ = std.c.pthread_mutex_lock(&r.mutex);
        defer _ = std.c.pthread_mutex_unlock(&r.mutex);
        while (used < destination.len) {
            if (r.head) |id| {
                const slot = &r.slots[id];
                if (slot.consumed < slot.written) {
                    const n = @min(destination.len - used, slot.written - slot.consumed);
                    const input = slot.bytes[slot.consumed..][0..n];
                    _ = std.c.pthread_mutex_unlock(&r.mutex);
                    @memcpy(destination[used..][0..n], input);
                    _ = std.c.pthread_mutex_lock(&r.mutex);
                    slot.consumed += n;
                    used += n;
                }
                if (slot.finished and slot.consumed == slot.written) {
                    r.head = slot.next;
                    if (r.head == null) r.tail = null;
                    r.free_ids[r.free_count] = id;
                    r.free_count += 1;
                    _ = std.c.pthread_cond_broadcast(&r.changed);
                    continue;
                }
                if (used == destination.len) break;
                if (slot.consumed < slot.written) continue;
            } else if (r.terminal) {
                if (r.failed) return error.InputReadFailed;
                break;
            }
            _ = std.c.pthread_cond_wait(&r.changed, &r.mutex);
        }
        return used;
    }
    fn worker(r: *Reader) void {
        _ = std.c.pthread_mutex_lock(&r.mutex);
        defer _ = std.c.pthread_mutex_unlock(&r.mutex);
        while (!r.stopping) {
            if (r.remaining == 0) {
                r.terminal = true;
                _ = std.c.pthread_cond_broadcast(&r.changed);
                return;
            }
            while (r.free_count == 0 and !r.stopping) {
                _ = std.c.pthread_cond_wait(&r.changed, &r.mutex);
            }
            if (r.stopping) return;
            r.free_count -= 1;
            const id = r.free_ids[r.free_count];
            const bytes = r.slots[id].bytes;
            r.slots[id] = .{ .bytes = bytes };
            if (r.tail) |tail| r.slots[tail].next = id else r.head = id;
            r.tail = id;
            _ = std.c.pthread_cond_broadcast(&r.changed);
            const slot = &r.slots[id];
            const target: usize = @intCast(@min(r.remaining, bytes.len));
            while (slot.written < target and !r.stopping) {
                const position = slot.written;
                const count = @min(target - position, 1 << 20);
                _ = std.c.pthread_mutex_unlock(&r.mutex);
                const got: isize = switch (r.source) {
                    .descriptor => |fd| input: {
                        var descriptors = [_]std.c.pollfd{ .{ .fd = fd, .events = 1, .revents = 0 }, .{ .fd = r.cancel[0], .events = 1, .revents = 0 } };
                        const ready = poll(&descriptors, 2, -1);
                        const interrupted = ready < 0 and std.c._errno().* == @backingInt(std.c.E.INTR);
                        break :input if (interrupted) -2 else if (ready < 0) -1 else if (descriptors[1].revents != 0) -2 else read(fd, bytes[position..].ptr, count);
                    },
                    .generated => |source| input: {
                        source.fill(source.context, bytes[position..][0..count], &r.diagnostic) catch break :input -1;
                        break :input @intCast(count);
                    },
                };
                _ = std.c.pthread_mutex_lock(&r.mutex);
                if (r.stopping) return;
                if (got == -2) continue;
                if (got <= 0) {
                    slot.finished = true;
                    r.terminal = true;
                    r.failed = got < 0;
                    _ = std.c.pthread_cond_broadcast(&r.changed);
                    return;
                }
                slot.written += @intCast(got);
                r.remaining -= @intCast(got);
                _ = std.c.pthread_cond_broadcast(&r.changed);
            }
            slot.finished = true;
            _ = std.c.pthread_cond_broadcast(&r.changed);
        }
    }
};

test "prefetch preserves arbitrary reads across slots, partial EOF and reused storage" {
    var descriptors: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), pipe(&descriptors));
    defer _ = close(descriptors[0]);
    var reader: Reader = undefined;
    try reader.init(descriptors[0], std.math.maxInt(u64), 16 << 10);
    defer reader.deinit();
    const input = try std.testing.allocator.alloc(u8, 131071);
    defer std.testing.allocator.free(input);
    var generator = std.Random.DefaultPrng.init(0x1a2b);
    generator.random().bytes(input);
    const Writer = struct {
        fn run(fd: c_int, bytes: []const u8) void {
            defer _ = close(fd);
            var offset: usize = 0;
            while (offset < bytes.len) {
                const n = write(fd, bytes[offset..].ptr, @min(bytes.len - offset, 1027));
                if (n <= 0) return;
                offset += @intCast(n);
            }
        }
    };
    const thread = try std.Thread.spawn(.{}, Writer.run, .{ descriptors[1], input });
    var output: [33001]u8 = undefined;
    var offset: usize = 0;
    var call: usize = 0;
    var equal = true;
    while (offset < input.len) {
        const sizes = [_]usize{ 1, 511, 17003, 33001, 9, 4097 };
        const wanted = sizes[call % sizes.len];
        const got = try reader.readInto(output[0..wanted]);
        try std.testing.expect(got != 0);
        equal = equal and std.mem.eql(u8, input[offset..][0..got], output[0..got]);
        offset += got;
        call += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), try reader.readInto(&output));
    thread.join();
    try std.testing.expect(equal);
}

test "prefetch cancellation releases blocked poll and preserves borrowed descriptor" {
    var descriptors: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), pipe(&descriptors));
    defer _ = close(descriptors[0]);
    defer _ = close(descriptors[1]);
    var reader: Reader = undefined;
    try reader.init(descriptors[0], std.math.maxInt(u64), 16 << 10);
    _ = std.c.pthread_mutex_lock(&reader.mutex);
    while (reader.head == null) _ = std.c.pthread_cond_wait(&reader.changed, &reader.mutex);
    _ = std.c.pthread_mutex_unlock(&reader.mutex);
    reader.deinit();
    try std.testing.expectEqual(@as(isize, 1), write(descriptors[1], "q", 1));
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 1), read(descriptors[0], &byte, 1));
    try std.testing.expectEqual(@as(u8, 'q'), byte[0]);
}

test "prefetch reports input error, then can be reinitialized with a bounded open pipe" {
    var reader: Reader = undefined;
    try reader.init(std.math.maxInt(c_int), 1024, 16 << 10);
    var output: [4096]u8 = undefined;
    try std.testing.expectError(error.InputReadFailed, reader.readInto(&output));
    reader.deinit();
    var descriptors: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), pipe(&descriptors));
    defer _ = close(descriptors[0]);
    defer _ = close(descriptors[1]);
    try std.testing.expectEqual(@as(isize, 3), write(descriptors[1], "abc", 3));
    try reader.init(descriptors[0], 3, 16 << 10);
    defer reader.deinit();
    try std.testing.expectEqual(@as(usize, 3), try reader.readInto(&output));
    try std.testing.expectEqualSlices(u8, "abc", output[0..3]);
    try std.testing.expectEqual(@as(usize, 0), try reader.readInto(&output));
}

const GeneratedFixture = struct {
    position: usize = 0,
    fail_at: ?usize = null,
    fn fill(raw: *anyopaque, output: []u8, diagnostic: *[1024]u8) !void {
        const source: *@This() = @ptrCast(@alignCast(raw));
        if (source.fail_at) |limit| if (source.position >= limit) {
            const message = "injected generator failure";
            @memcpy(diagnostic[0..message.len], message);
            diagnostic[message.len] = 0;
            return error.InjectedGeneratorFailure;
        };
        for (output, 0..) |*byte, i| byte.* = @intCast((source.position + i) % 251);
        source.position += output.len;
    }
};

test "generated prefetch preserves irregular reads and exact byte limit" {
    var source = GeneratedFixture{};
    const limit = 131071;
    {
        var reader: Reader = undefined;
        try reader.initGenerated(.{ .context = &source, .fill = GeneratedFixture.fill }, limit, 16 << 10);
        defer reader.deinit();
        var output: [33001]u8 = undefined;
        var offset: usize = 0;
        var call: usize = 0;
        while (offset < limit) : (call += 1) {
            const sizes = [_]usize{ 1, 511, 17003, 33001, 9, 4097 };
            const got = try reader.readInto(output[0..sizes[call % sizes.len]]);
            try std.testing.expect(got != 0);
            for (output[0..got], 0..) |byte, i| try std.testing.expectEqual(@as(u8, @intCast((offset + i) % 251)), byte);
            offset += got;
        }
        try std.testing.expectEqual(@as(usize, 0), try reader.readInto(&output));
    }
    try std.testing.expectEqual(@as(usize, limit), source.position);
}

test "generated prefetch reports failure only after the valid prefix is consumed" {
    var source = GeneratedFixture{ .fail_at = 8 };
    var reader: Reader = undefined;
    try reader.initGenerated(.{ .context = &source, .fill = GeneratedFixture.fill }, 100, 16);
    defer reader.deinit();
    var output: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 8), try reader.readInto(&output));
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, &output);
    try std.testing.expectError(error.InputReadFailed, reader.readInto(output[0..1]));
    try std.testing.expectEqualStrings("injected generator failure", std.mem.sliceTo(&reader.diagnostic, 0));
}

test "generated prefetch cancellation joins a producer waiting on full slots" {
    var source = GeneratedFixture{};
    var reader: Reader = undefined;
    try reader.initGenerated(.{ .context = &source, .fill = GeneratedFixture.fill }, std.math.maxInt(u64), 16 << 10);
    _ = std.c.pthread_mutex_lock(&reader.mutex);
    while (reader.free_count != 0 or reader.tail == null or !reader.slots[reader.tail.?].finished)
        _ = std.c.pthread_cond_wait(&reader.changed, &reader.mutex);
    _ = std.c.pthread_mutex_unlock(&reader.mutex);
    reader.deinit();
    try std.testing.expectEqual(@as(usize, 16 << 10), source.position);
}
