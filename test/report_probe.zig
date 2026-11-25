// Exercise the real checkpoint renderer with the original formatter's inputs.
const std = @import("std");
const report = @import("report");
extern "c" fn printf([*:0]const u8, ...) c_int;

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const mode = args.next().?;
    if (std.mem.eql(u8, mode, "metatest")) {
        const reference = if (args.next()) |policy| std.mem.eql(u8, policy, "reference") else false;
        var cases = std.mem.tokenizeScalar(u8, @embedFile("metatest_cases.tsv"), '\n');
        while (cases.next()) |line| {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            const name = fields.next().?;
            const smart = std.mem.eql(u8, fields.next().?, "1");
            const threshold = try std.fmt.parseFloat(f64, fields.next().?);
            const Results = @typeInfo(@TypeOf(report.checkpoint)).@"fn".param_types[1].?;
            var results: [2]std.meta.Child(Results) = undefined;
            var count: usize = 0;
            for (0..2) |i| {
                const kind = fields.next().?;
                const value = try std.fmt.parseFloat(f64, fields.next().?);
                const weight = try std.fmt.parseFloat(f64, fields.next().?);
                if (std.mem.eql(u8, kind, "none")) continue;
                results[count] = .{
                    .name = if (i == 0) "z-result" else "a-result",
                    .kind = std.meta.stringToEnum(@TypeOf(results[count].kind), kind).?,
                    .raw = 0,
                    .value = value,
                    .weight = weight,
                    .arithmetic = if (reference) .reference else .improved,
                };
                count += 1;
            }
            _ = printf("case=%.*s\n", @as(c_int, @intCast(name.len)), name.ptr);
            const failed = try report.checkpoint(arena.allocator(), results[0..count], "probe", "0", 1, 0, .{ .smart = smart, .threshold = threshold, .metatest = true }, .bytes);
            _ = printf("stop=%d\n", @as(c_int, @intFromBool(failed)));
        }
        return;
    }
    const table = std.meta.stringToEnum(report.Table, mode) orelse return error.InvalidTable;
    var lines = std.mem.tokenizeScalar(u8, @embedFile("report_cases.tsv"), '\n');
    while (lines.next()) |line| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const Result = @typeInfo(@TypeOf(report.checkpoint)).@"fn".param_types[1].?;
        var results: [2]std.meta.Child(Result) = undefined;
        results[0] = .{
            .name = fields.next().?,
            .kind = std.meta.stringToEnum(@TypeOf(results[0].kind), fields.next().?).?,
            .raw = try std.fmt.parseFloat(f64, fields.next().?),
            .value = try std.fmt.parseFloat(f64, fields.next().?),
            .weight = try std.fmt.parseFloat(f64, fields.next().?),
        };
        // The second result makes the requested weight already normalized.
        results[1] = .{ .name = "zzz-control", .kind = .raw, .raw = 0, .value = 0, .weight = 1 - results[0].weight };
        _ = try report.checkpoint(arena.allocator(), results[0..if (results[0].weight == 1) @as(usize, 1) else 2], "probe", "0", 1, 0, .{ .smart = false, .threshold = 1, .table = table }, .bytes);
    }
}
