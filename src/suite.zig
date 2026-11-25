const std = @import("std");
const core = @import("battery.zig");
const expanded = @import("expanded.zig");
const Pool = @import("worker_pool.zig").Pool;

pub const Battery = union(enum) {
    core: core.Battery,
    expanded: expanded.Battery,
    pub fn init(a: std.mem.Allocator, use_expanded: bool, tables: *const core.Tables) !Battery {
        return if (use_expanded) .{ .expanded = try expanded.Battery.init(a, tables.near) } else .{ .core = try core.Battery.init(a) };
    }
    pub fn blocks(t: *const Battery) u64 {
        return switch (t.*) {
            inline else => |*battery| battery.blocks,
        };
    }
    pub fn deinit(t: *Battery) void {
        switch (t.*) {
            inline else => |*battery| battery.deinit(),
        }
    }
    pub fn update(t: *Battery, bytes: []const u8, executor: ?*Pool, gpu: ?*@import("gpu.zig").Executor) !void {
        switch (t.*) {
            .core => |*battery| try battery.update(bytes, executor),
            .expanded => |*battery| try battery.update(bytes, executor, gpu),
        }
    }
    pub fn prepareCheckpoint(t: *Battery) void {
        switch (t.*) {
            .core => {},
            .expanded => |*battery| battery.prepareCheckpoint(),
        }
    }
    pub fn results(t: *const Battery, r: *core.Results) !void {
        switch (t.*) {
            inline else => |*battery| try battery.results(r),
        }
    }
};
