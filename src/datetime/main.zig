//! zmcp-datetime — current time + formatting + simple math.
//!
//! Tools:
//!   now           → current ISO-8601 UTC + Unix ms
//!   now_iso       → ISO-8601 UTC string only
//!   now_unix_ms   → integer Unix ms only
//!   now_unix_s    → integer Unix seconds only

const std = @import("std");
const mcp = @import("mcp");

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    const io = init.io;

    try mcp.run(
        arena,
        io,
        .{ .name = "zmcp-datetime", .version = "0.1.0" },
        &tool_table,
    );
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "now",
        .description = "Return the current UTC time as both ISO-8601 string and Unix milliseconds.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {},
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleNow,
        .read_only = true,
    },
    .{
        .name = "now_iso",
        .description = "Return the current UTC time as an ISO-8601 string.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {},
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleNowIso,
        .read_only = true,
    },
    .{
        .name = "now_unix_ms",
        .description = "Return current Unix time in milliseconds.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {},
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleNowUnixMs,
        .read_only = true,
    },
    .{
        .name = "now_unix_s",
        .description = "Return current Unix time in seconds.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {},
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleNowUnixS,
        .read_only = true,
    },
};

fn handleNow(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    _ = args;
    const ts_ms = nowMs(io);
    var iso_buf: [32]u8 = undefined;
    const iso = formatIso8601(&iso_buf, ts_ms);
    const text = try std.fmt.allocPrint(allocator, "{{\"iso\":\"{s}\",\"unix_ms\":{d}}}", .{ iso, ts_ms });
    return .{ .text = text };
}

fn handleNowIso(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    _ = args;
    const ts_ms = nowMs(io);
    var iso_buf: [32]u8 = undefined;
    const iso = formatIso8601(&iso_buf, ts_ms);
    return .{ .text = try allocator.dupe(u8, iso) };
}

fn handleNowUnixMs(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    _ = args;
    const ts_ms = nowMs(io);
    return .{ .text = try std.fmt.allocPrint(allocator, "{d}", .{ts_ms}) };
}

fn handleNowUnixS(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    _ = args;
    const ts_ms = nowMs(io);
    return .{ .text = try std.fmt.allocPrint(allocator, "{d}", .{@divFloor(ts_ms, 1000)}) };
}

fn nowMs(io: std.Io) i64 {
    const ts = std.Io.Timestamp.now(io, .real);
    return ts.toMilliseconds();
}

fn formatIso8601(buf: []u8, ts_ms: i64) []u8 {
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(@divFloor(ts_ms, 1000)) };
    const day_secs = epoch_secs.getDaySeconds();
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const ms = @as(u32, @intCast(@mod(ts_ms, 1000)));

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
        ms,
    }) catch unreachable;
}

test "formatIso8601 produces 24-char ISO string" {
    var buf: [32]u8 = undefined;
    const s = formatIso8601(&buf, 0);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.000Z", s);
}

test "formatIso8601 known date" {
    var buf: [32]u8 = undefined;
    // 2024-01-01T00:00:00.000Z = 1704067200000 ms
    const s = formatIso8601(&buf, 1704067200000);
    try std.testing.expectEqualStrings("2024-01-01T00:00:00.000Z", s);
}
