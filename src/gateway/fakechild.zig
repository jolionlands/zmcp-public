//! zmcp-fake: a tiny MCP server used only by the gateway's end-to-end tests
//! (built by `zig build test`, never installed). It proves lazy spawn,
//! reuse, reaping and respawn through real processes and pipes.

const std = @import("std");
const mcp = @import("mcp");

/// Unique per process: lets tests tell one spawn from the next.
var instance: ?i96 = null;

pub fn main(init: std.process.Init) !void {
    try mcp.run(init.gpa, init.io, .{ .name = "zmcp-fake", .version = "0.0.1" }, &tools);
}

fn instanceId(io: std.Io) i96 {
    if (instance) |i| return i;
    const now = std.Io.Timestamp.now(io, .real).nanoseconds;
    instance = now;
    return now;
}

fn argString(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn echo(arena: std.mem.Allocator, _: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    return .{ .text = try std.fmt.allocPrint(arena, "echo:{s}", .{argString(args, "text") orelse ""}) };
}

fn pid(arena: std.mem.Allocator, io: std.Io, _: std.json.Value) anyerror!mcp.ToolResult {
    return .{ .text = try std.fmt.allocPrint(arena, "instance:{d}", .{instanceId(io)}) };
}

fn crash(_: std.mem.Allocator, _: std.Io, _: std.json.Value) anyerror!mcp.ToolResult {
    std.process.exit(3);
}

fn slow(arena: std.mem.Allocator, io: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    var ms: i64 = 100;
    if (args == .object) if (args.object.get("ms")) |v| if (v == .integer) {
        ms = v.integer;
    };
    try io.sleep(std.Io.Duration.fromMilliseconds(ms), .awake);
    return .{ .text = try arena.dupe(u8, "done") };
}

fn image(_: std.mem.Allocator, _: std.Io, _: std.json.Value) anyerror!mcp.ToolResult {
    return .{ .text = "pixel", .image = .{ .data_base64 = "iVBORw0KGgo=", .mime_type = "image/png" } };
}

fn fail(arena: std.mem.Allocator, _: std.Io, _: std.json.Value) anyerror!mcp.ToolResult {
    return .{ .text = try arena.dupe(u8, "nope"), .is_error = true };
}

/// Report an environment variable (name only, never logged by the gateway).
fn env(arena: std.mem.Allocator, io: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    const name = argString(args, "name") orelse return .{ .text = "missing name", .is_error = true };
    const v = mcp.envAlloc(arena, io, name);
    return .{ .text = if (v) |x| x else "<unset>" };
}

const tools = [_]mcp.ToolDef{
    .{ .name = "fake_echo", .description = "Echo text back. Test helper.", .input_schema_json = "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}}}", .handler = echo, .read_only = true },
    .{ .name = "fake_pid", .description = "Report this process's unique instance id.", .input_schema_json = "{\"type\":\"object\",\"properties\":{}}", .handler = pid, .read_only = true },
    .{ .name = "fake_crash", .description = "Exit the process immediately (simulates a crash).", .input_schema_json = "{\"type\":\"object\",\"properties\":{}}", .handler = crash },
    .{ .name = "fake_slow", .description = "Sleep for ms milliseconds, then answer.", .input_schema_json = "{\"type\":\"object\",\"properties\":{\"ms\":{\"type\":\"integer\"}}}", .handler = slow },
    .{ .name = "fake_image", .description = "Return a tiny image plus a caption.", .input_schema_json = "{\"type\":\"object\",\"properties\":{}}", .handler = image, .read_only = true },
    .{ .name = "fake_fail", .description = "Always returns isError.", .input_schema_json = "{\"type\":\"object\",\"properties\":{}}", .handler = fail },
    .{ .name = "fake_env", .description = "Report an environment variable of the child.", .input_schema_json = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}}}", .handler = env, .read_only = true },
};
