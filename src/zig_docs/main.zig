//! zmcp-zig-docs - pure-Zig port of the local `zig_docs` MCP.
//! Zig tool wrappers plus stdlib symbol/file lookup.

const std = @import("std");
const mcp = @import("mcp");

/// The `io` handed to `main`; environment lookups go through `mcp.envAlloc`,
/// which reads the real process environment behind it on every OS.
var g_env_io: ?std.Io = null;

/// Owned copy of environment variable `key` (caller frees), or null if unset.
fn envOwned(alloc: std.mem.Allocator, key: []const u8) ?[]u8 {
    const io = g_env_io orelse return null;
    return mcp.envAlloc(alloc, io, key);
}


const Io = std.Io;
const DEFAULT_ZIG_BIN = "zig"; // resolved via PATH; set ZIG_BIN to override

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    g_env_io = init.io;
    const io = init.io;
    try mcp.run(arena, io, .{ .name = "zmcp-zig-docs", .version = "0.1.0" }, &tool_table);
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "zig_version",
        .description = "Show `zig version` for the configured compiler (ZIG_BIN). Useful sanity check.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {}
        \\}
        ,
        .handler = handleVersion,
        .read_only = true,
    },
    .{
        .name = "zig_targets",
        .description = "List `zig targets`. The full output is many MB - pass `filter` to substring-match only the matching lines. e.g. filter='aarch64'.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "filter": { "type": "string", "description": "Substring to grep for. Omit for the full dump." },
        \\    "max_lines": { "type": "integer", "description": "Cap lines returned (default 300)." }
        \\  }
        \\}
        ,
        .handler = handleTargets,
        .read_only = true,
    },
    .{
        .name = "zig_fmt_check",
        .description = "Run `zig fmt --check <path>`. Returns 0+empty if formatted, else the suggested output.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "path": { "type": "string", "description": "Absolute path to a .zig file or directory." }
        \\  },
        \\  "required": ["path"]
        \\}
        ,
        .handler = handleFmtCheck,
        .read_only = true,
    },
    .{
        .name = "zig_build",
        .description = "Run `zig build [step]` in cwd. Returns combined output and exit code.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "cwd": { "type": "string", "description": "Absolute path to a project root containing build.zig." },
        \\    "step": { "type": "string", "description": "Optional build step." },
        \\    "extra_args": { "type": "array", "items": { "type": "string" }, "description": "Extra args appended after the step." }
        \\  },
        \\  "required": ["cwd"]
        \\}
        ,
        .handler = handleBuild,
        .destructive = true,
    },
    .{
        .name = "zig_test_file",
        .description = "Run `zig test <file>` for a single-file test. Returns combined output.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "path": { "type": "string", "description": "Absolute path to a .zig file." }
        \\  },
        \\  "required": ["path"]
        \\}
        ,
        .handler = handleTestFile,
        .destructive = true,
    },
    .{
        .name = "zig_std_symbol",
        .description = "Find where a stdlib symbol is defined. Greps `pub fn <name>` / `pub const <name>` / `pub var <name>` across $ZIG_STD. Returns file:line refs.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "name": { "type": "string", "description": "Bare symbol name, e.g. 'splitScalar' or 'ArrayList'." },
        \\    "max_results": { "type": "integer", "description": "Cap (default 40)." }
        \\  },
        \\  "required": ["name"]
        \\}
        ,
        .handler = handleStdSymbol,
        .read_only = true,
    },
    .{
        .name = "zig_std_file",
        .description = "Read the first N lines of a file under the Zig stdlib. Path may be absolute (inside $ZIG_STD) or relative to $ZIG_STD.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "path": { "type": "string", "description": "Absolute path under $ZIG_STD or a path relative to $ZIG_STD." },
        \\    "max_lines": { "type": "integer", "description": "Default 400." }
        \\  },
        \\  "required": ["path"]
        \\}
        ,
        .handler = handleStdFile,
        .read_only = true,
    },
};

const RunResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
};

const SymbolHit = struct {
    path: []u8,
    line: usize,
    src: []u8,
};

fn getStr(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn getInt(args: std.json.Value, key: []const u8, default: i64) i64 {
    if (args != .object) return default;
    const v = args.object.get(key) orelse return default;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => default,
    };
}

fn getStrArray(args: std.json.Value, key: []const u8, alloc: std.mem.Allocator) ![]const []const u8 {
    if (args != .object) return &.{};
    const v = args.object.get(key) orelse return &.{};
    if (v != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    for (v.array.items) |item| {
        if (item == .string) try out.append(alloc, item.string);
    }
    return out.toOwnedSlice(alloc);
}

fn zigBin(alloc: std.mem.Allocator) ![]u8 {
    if (envOwned(alloc, "ZIG_BIN")) |v| return v;
    return alloc.dupe(u8, DEFAULT_ZIG_BIN);
}

fn zigStd(alloc: std.mem.Allocator) ![]u8 {
    if (envOwned(alloc, "ZIG_STD")) |v| return v;
    const bin = try zigBin(alloc);
    defer alloc.free(bin);
    const slash = std.mem.lastIndexOfScalar(u8, bin, '/') orelse return error.NoPath;
    const dir = bin[0..slash];
    return std.fmt.allocPrint(alloc, "{s}/lib/std", .{dir});
}

fn runCapture(
    alloc: std.mem.Allocator,
    io: Io,
    argv: []const []const u8,
    cwd: ?[]const u8,
) !RunResult {
    var opts = std.process.RunOptions{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024 * 16),
        .stderr_limit = .limited(1024 * 1024 * 16),
    };
    if (cwd) |p| opts.cwd = .{ .path = p };
    const result = try std.process.run(alloc, io, opts);
    return .{ .term = result.term, .stdout = result.stdout, .stderr = result.stderr };
}

fn trimLineEndings(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and (s[end - 1] == '\r' or s[end - 1] == '\n')) : (end -= 1) {}
    return s[0..end];
}

fn joinedOutput(alloc: std.mem.Allocator, code: i32, stdout: []const u8, stderr: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "exit={d}\n--- stdout ---\n{s}\n--- stderr ---\n{s}", .{ code, stdout, stderr });
}

fn firstPubDeclLine(line: []const u8, name: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    const prefixes = [_][]const u8{ "pub fn ", "pub const ", "pub var " };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, trimmed, prefix)) {
            const rest = trimmed[prefix.len..];
            if (std.mem.startsWith(u8, rest, name)) {
                const after = rest[name.len..];
                if (after.len == 0) return true;
                const c = after[0];
                return c == '(' or c == ':' or c == ' ' or c == '=' or c == '{';
            }
        }
    }
    return false;
}

fn collectSymbolHits(
    alloc: std.mem.Allocator,
    io: Io,
    dir_path: []const u8,
    root_path: []const u8,
    name: []const u8,
    max_results: usize,
    hits: *std.ArrayList(SymbolHit),
) !void {
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    while (hits.items.len < max_results) {
        const entry = iter.next(io) catch null orelse break;
        const full_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, entry.name });
        defer alloc.free(full_path);
        switch (entry.kind) {
            .directory => try collectSymbolHits(alloc, io, full_path, root_path, name, max_results, hits),
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                const text = std.Io.Dir.readFileAlloc(dir, io, entry.name, alloc, .limited(1024 * 1024 * 4)) catch continue;
                defer alloc.free(text);
                var lines = std.mem.splitScalar(u8, text, '\n');
                var line_no: usize = 0;
                while (lines.next()) |line| {
                    line_no += 1;
                    const clean = std.mem.trim(u8, line, "\r");
                    if (firstPubDeclLine(clean, name)) {
                        const rel = if (std.mem.startsWith(u8, full_path, root_path) and full_path.len > root_path.len + 1)
                            full_path[root_path.len + 1 ..]
                        else
                            full_path;
                        try hits.append(alloc, .{
                            .path = try alloc.dupe(u8, rel),
                            .line = line_no,
                            .src = try alloc.dupe(u8, std.mem.trim(u8, clean, " \t")),
                        });
                        if (hits.items.len >= max_results) break;
                    }
                }
            },
            else => {},
        }
    }
}

fn handleVersion(alloc: std.mem.Allocator, io: Io, _: std.json.Value) !mcp.ToolResult {
    const zig = try zigBin(alloc);
    const result = try runCapture(alloc, io, &.{ zig, "version" }, null);
    const code: i32 = switch (result.term) {
        .exited => |c| @intCast(c),
        else => -1,
    };
    if (code != 0) return .{ .text = try std.fmt.allocPrint(alloc, "zig version failed: {s}", .{if (result.stderr.len > 0) result.stderr else result.stdout}), .is_error = true };
    return .{ .text = try std.fmt.allocPrint(alloc, "{s}\n{s}", .{ zig, trimLineEndings(result.stdout) }) };
}

fn handleTargets(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const zig = try zigBin(alloc);
    const result = try runCapture(alloc, io, &.{ zig, "targets" }, null);
    const code: i32 = switch (result.term) {
        .exited => |c| @intCast(c),
        else => -1,
    };
    if (code != 0) return .{ .text = try std.fmt.allocPrint(alloc, "zig targets failed: {s}", .{if (result.stderr.len > 0) result.stderr else result.stdout}), .is_error = true };
    const filter = getStr(args, "filter");
    const max_lines: usize = @intCast(@max(getInt(args, "max_lines", 300), 0));
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var count: usize = 0;
    var kept: usize = 0;
    var it = std.mem.splitScalar(u8, trimLineEndings(result.stdout), '\n');
    while (it.next()) |line| {
        const match = if (filter) |f|
            std.ascii.indexOfIgnoreCase(line, f) != null
        else
            true;
        if (!match) continue;
        count += 1;
        if (kept < max_lines) {
            if (kept > 0) try out.writer.writeByte('\n');
            try out.writer.writeAll(line);
            kept += 1;
        }
    }
    const tail = if (count > kept) try std.fmt.allocPrint(alloc, "\n(+ {d} more lines)", .{count - kept}) else "";
    return .{ .text = try std.fmt.allocPrint(alloc, "{d} line(s):\n{s}{s}", .{ count, out.written(), tail }) };
}

fn handleFmtCheck(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const path = getStr(args, "path") orelse return .{ .text = "path is required", .is_error = true };
    const zig = try zigBin(alloc);
    const result = try runCapture(alloc, io, &.{ zig, "fmt", "--check", path }, null);
    const code: i32 = switch (result.term) {
        .exited => |c| @intCast(c),
        else => -1,
    };
    if (code == 0 and trimLineEndings(result.stdout).len == 0 and trimLineEndings(result.stderr).len == 0) {
        return .{ .text = "OK (already formatted)" };
    }
    return .{ .text = try joinedOutput(alloc, code, result.stdout, result.stderr) };
}

fn handleBuild(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const cwd = getStr(args, "cwd") orelse return .{ .text = "cwd is required", .is_error = true };
    const step = getStr(args, "step");
    const extra = try getStrArray(args, "extra_args", alloc);
    const zig = try zigBin(alloc);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, zig);
    try argv.append(alloc, "build");
    if (step) |s| try argv.append(alloc, s);
    for (extra) |item| try argv.append(alloc, item);
    const result = try runCapture(alloc, io, argv.items, cwd);
    const code: i32 = switch (result.term) {
        .exited => |c| @intCast(c),
        else => -1,
    };
    return .{ .text = try joinedOutput(alloc, code, result.stdout, result.stderr) };
}

fn handleTestFile(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const path = getStr(args, "path") orelse return .{ .text = "path is required", .is_error = true };
    const zig = try zigBin(alloc);
    const result = try runCapture(alloc, io, &.{ zig, "test", path }, null);
    const code: i32 = switch (result.term) {
        .exited => |c| @intCast(c),
        else => -1,
    };
    return .{ .text = try joinedOutput(alloc, code, result.stdout, result.stderr) };
}

fn handleStdSymbol(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const name = getStr(args, "name") orelse return .{ .text = "name is required", .is_error = true };
    const max_results: usize = @intCast(@max(getInt(args, "max_results", 40), 0));
    const std_root = zigStd(alloc) catch |err| return .{ .text = try std.fmt.allocPrint(alloc, "zig_std_symbol failed: {s}", .{@errorName(err)}), .is_error = true };

    var hits: std.ArrayList(SymbolHit) = .empty;
    defer {
        for (hits.items) |hit| {
            alloc.free(hit.path);
            alloc.free(hit.src);
        }
        hits.deinit(alloc);
    }
    collectSymbolHits(alloc, io, std_root, std_root, name, max_results, &hits) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "zig_std_symbol failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    if (hits.items.len == 0) {
        return .{ .text = try std.fmt.allocPrint(alloc, "(no pub fn/const/var named '{s}' under $ZIG_STD)", .{name}) };
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("{d} hit(s):\n\n", .{hits.items.len});
    for (hits.items, 0..) |hit, idx| {
        if (idx > 0) try out.writer.writeByte('\n');
        try out.writer.print("{d}. {s}:{d}\n   {s}", .{ idx + 1, hit.path, hit.line, hit.src });
    }
    return .{ .text = out.written() };
}

fn handleStdFile(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const path_arg = getStr(args, "path") orelse return .{ .text = "path is required", .is_error = true };
    const max_lines: usize = @intCast(@max(getInt(args, "max_lines", 400), 0));
    const std_root = zigStd(alloc) catch |err| return .{ .text = try std.fmt.allocPrint(alloc, "zig_std_file failed: {s}", .{@errorName(err)}), .is_error = true };
    const path_norm = std.mem.replaceOwned(u8, alloc, path_arg, "\\", "/") catch try alloc.dupe(u8, path_arg);
    defer alloc.free(path_norm);
    const full_path = if (std.mem.indexOf(u8, path_norm, ":/") != null)
        try alloc.dupe(u8, path_norm)
    else
        try std.fmt.allocPrint(alloc, "{s}/{s}", .{ std_root, path_norm });
    defer alloc.free(full_path);
    if (!std.mem.startsWith(u8, full_path, std_root)) {
        return .{ .text = try std.fmt.allocPrint(alloc, "zig_std_file failed: path escapes $ZIG_STD: {s}", .{full_path}), .is_error = true };
    }
    var dir = std.Io.Dir.openDirAbsolute(io, std_root, .{}) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "zig_std_file failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    defer dir.close(io);
    const rel = if (full_path.len > std_root.len + 1) full_path[std_root.len + 1 ..] else std.fs.path.basename(full_path);
    const text = std.Io.Dir.readFileAlloc(dir, io, rel, alloc, .limited(1024 * 1024 * 8)) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "zig_std_file failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    defer alloc.free(text);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var it = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    var shown: usize = 0;
    while (it.next()) |line| {
        line_no += 1;
        if (shown < max_lines) {
            try out.writer.print("{s}{d: >5}  {s}", .{ if (shown == 0) "" else "\n", line_no, std.mem.trim(u8, line, "\r") });
            shown += 1;
        }
    }
    const tail = if (line_no > shown) try std.fmt.allocPrint(alloc, "\n... (+ {d} more lines)", .{line_no - shown}) else "";
    return .{ .text = try std.fmt.allocPrint(alloc, "{s} ({d} lines total)\n\n{s}{s}", .{ full_path, line_no, out.written(), tail }) };
}

test "env lookup reads the real process environment (not an empty block)" {
    const alloc = std.testing.allocator;
    g_env_io = std.testing.io;
    defer g_env_io = null;
    const v = envOwned(alloc, "PATH") orelse return error.SkipZigTest;
    defer alloc.free(v);
    try std.testing.expect(v.len > 0);
    try std.testing.expect(envOwned(alloc, "ZMCP_SURELY_UNSET_ENV_VAR_12345") == null);
}
