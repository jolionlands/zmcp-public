//! zmcp-diff-render - pure-Zig port of the local Node `diff_render` MCP.
//! Wraps native difftastic (`difft`) plus `git show` for AST-aware diffs.

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
const COLOR_CHOICES = [_][]const u8{ "always", "auto", "never" };
const DISPLAY_CHOICES = [_][]const u8{ "side-by-side", "side-by-side-show-both", "inline", "json" };

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    g_env_io = init.io;
    const io = init.io;
    try mcp.run(arena, io, .{ .name = "zmcp-diff-render", .version = "0.1.0" }, &tool_table);
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "diff_files",
        .description = "AST-aware diff between two files on disk. Returns ANSI-colored output by default.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "old": { "type": "string", "description": "Absolute path to the old or left-hand file." },
        \\    "new": { "type": "string", "description": "Absolute path to the new or right-hand file." },
        \\    "color": { "type": "string", "enum": ["always", "auto", "never"], "description": "Default 'always'." },
        \\    "display": { "type": "string", "enum": ["side-by-side", "side-by-side-show-both", "inline", "json"], "description": "Optional display mode override." },
        \\    "language": { "type": "string", "description": "Optional language override, e.g. 'Zig' or 'JavaScript'." },
        \\    "width": { "type": "integer", "description": "Optional display width in columns." }
        \\  },
        \\  "required": ["old", "new"]
        \\}
        ,
        .handler = handleDiffFiles,
        .read_only = true,
    },
    .{
        .name = "diff_strings",
        .description = "AST-aware diff between two strings. Writes temp files with the supplied extension and runs difftastic on them.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "old": { "type": "string", "description": "Old or left string." },
        \\    "new": { "type": "string", "description": "New or right string." },
        \\    "ext": { "type": "string", "description": "File extension without dot, e.g. 'zig', 'ts', 'md'." },
        \\    "color": { "type": "string", "enum": ["always", "auto", "never"] },
        \\    "display": { "type": "string", "enum": ["side-by-side", "side-by-side-show-both", "inline", "json"] },
        \\    "width": { "type": "integer" }
        \\  },
        \\  "required": ["old", "new", "ext"]
        \\}
        ,
        .handler = handleDiffStrings,
        .read_only = true,
    },
    .{
        .name = "diff_git_show",
        .description = "Diff a file between two git revisions using `git show REV:PATH`, then render with difftastic.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "repo": { "type": "string", "description": "Absolute path to the git repo root." },
        \\    "path": { "type": "string", "description": "Repo-relative file path." },
        \\    "old_rev": { "type": "string", "description": "Old revision, e.g. HEAD~1 or a sha." },
        \\    "new_rev": { "type": "string", "description": "New revision. Default HEAD." },
        \\    "color": { "type": "string", "enum": ["always", "auto", "never"] },
        \\    "display": { "type": "string", "enum": ["side-by-side", "side-by-side-show-both", "inline", "json"] }
        \\  },
        \\  "required": ["repo", "path", "old_rev"]
        \\}
        ,
        .handler = handleDiffGitShow,
        .read_only = true,
    },
    .{
        .name = "diff_languages",
        .description = "List the languages difftastic recognizes, one per line.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {}
        \\}
        ,
        .handler = handleDiffLanguages,
        .read_only = true,
    },
};

fn getStr(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn getInt(args: std.json.Value, key: []const u8) ?i64 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn oneOf(val: []const u8, choices: []const []const u8) bool {
    for (choices) |c| if (std.mem.eql(u8, val, c)) return true;
    return false;
}

fn difftBin(alloc: std.mem.Allocator) ![]u8 {
    if (envOwned(alloc, "DIFFT_BIN")) |v| return v;
    return alloc.dupe(u8, "difft"); // resolved via PATH; set DIFFT_BIN to override
}

const RunResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
};

fn runCapture(
    alloc: std.mem.Allocator,
    io: Io,
    argv: []const []const u8,
    cwd: ?[]const u8,
) !RunResult {
    var opts = std.process.RunOptions{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024 * 8),
        .stderr_limit = .limited(1024 * 1024 * 4),
    };
    if (cwd) |p| opts.cwd = .{ .path = p };
    const result = try std.process.run(alloc, io, opts);
    return .{ .term = result.term, .stdout = result.stdout, .stderr = result.stderr };
}

fn isExitedZero(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn tempRoot(alloc: std.mem.Allocator) ![]u8 {
    for ([_][]const u8{ "TEMP", "TMP", "TMPDIR" }) |key| {
        if (envOwned(alloc, key)) |v| return v;
    }
    return alloc.dupe(u8, if (@import("builtin").os.tag == .windows) "." else "/tmp");
}

fn tempPath(alloc: std.mem.Allocator, io: Io, stem: []const u8, ext: []const u8) ![]u8 {
    const root = try tempRoot(alloc);
    defer alloc.free(root);
    const ts = Io.Timestamp.now(io, .real).toMilliseconds();
    return std.fmt.allocPrint(alloc, "{s}/zmcp-{s}-{d}.{s}", .{ root, stem, ts, ext });
}

fn writeTempFile(io: Io, path: []const u8, data: []const u8) !void {
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = data });
}

fn appendCommonDifftArgs(alloc: std.mem.Allocator, list: *std.ArrayList([]const u8), args: std.json.Value) !void {
    const color = getStr(args, "color") orelse "always";
    if (!oneOf(color, &COLOR_CHOICES)) return error.InvalidColor;
    try list.append(alloc, try std.fmt.allocPrint(alloc, "--color={s}", .{color}));

    if (getStr(args, "display")) |display| {
        if (!oneOf(display, &DISPLAY_CHOICES)) return error.InvalidDisplay;
        try list.append(alloc, try std.fmt.allocPrint(alloc, "--display={s}", .{display}));
    }
    if (getStr(args, "language")) |lang| {
        try list.append(alloc, try std.fmt.allocPrint(alloc, "--language={s}", .{lang}));
    }
    if (getInt(args, "width")) |width| {
        try list.append(alloc, try std.fmt.allocPrint(alloc, "--width={d}", .{width}));
    }
}

fn renderDifftResult(alloc: std.mem.Allocator, result: RunResult) !mcp.ToolResult {
    const text = if (result.stdout.len > 0) result.stdout else result.stderr;
    if (isExitedZero(result.term)) {
        return .{ .text = if (text.len > 0) text else try alloc.dupe(u8, "(no output)") };
    }
    return .{ .text = if (text.len > 0) text else try alloc.dupe(u8, "difft failed"), .is_error = true };
}

fn handleDiffFiles(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const old = getStr(args, "old") orelse return .{ .text = "error: old is required", .is_error = true };
    const new = getStr(args, "new") orelse return .{ .text = "error: new is required", .is_error = true };
    const difft = try difftBin(alloc);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, difft);
    try appendCommonDifftArgs(alloc, &argv, args);
    try argv.append(alloc, old);
    try argv.append(alloc, new);

    const result = try runCapture(alloc, io, argv.items, null);
    return renderDifftResult(alloc, result);
}

fn handleDiffStrings(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const old = getStr(args, "old") orelse return .{ .text = "error: old is required", .is_error = true };
    const new = getStr(args, "new") orelse return .{ .text = "error: new is required", .is_error = true };
    const ext = getStr(args, "ext") orelse return .{ .text = "error: ext is required", .is_error = true };

    const old_path = try tempPath(alloc, io, "old", ext);
    const new_path = try tempPath(alloc, io, "new", ext);
    defer std.Io.Dir.deleteFileAbsolute(io, old_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, new_path) catch {};

    try writeTempFile(io, old_path, old);
    try writeTempFile(io, new_path, new);

    var file_args_obj: std.json.ObjectMap = .{};
    try file_args_obj.put(alloc, "old", .{ .string = old_path });
    try file_args_obj.put(alloc, "new", .{ .string = new_path });
    if (getStr(args, "color")) |v| try file_args_obj.put(alloc, "color", .{ .string = v });
    if (getStr(args, "display")) |v| try file_args_obj.put(alloc, "display", .{ .string = v });
    if (getInt(args, "width")) |v| try file_args_obj.put(alloc, "width", .{ .integer = v });

    return handleDiffFiles(alloc, io, .{ .object = file_args_obj });
}

fn handleDiffGitShow(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const repo = getStr(args, "repo") orelse return .{ .text = "error: repo is required", .is_error = true };
    const path = getStr(args, "path") orelse return .{ .text = "error: path is required", .is_error = true };
    const old_rev = getStr(args, "old_rev") orelse return .{ .text = "error: old_rev is required", .is_error = true };
    const new_rev = getStr(args, "new_rev") orelse "HEAD";

    const old_spec = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ old_rev, path });
    const new_spec = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ new_rev, path });

    const old_res = try runCapture(alloc, io, &.{ "git", "show", old_spec }, repo);
    if (!isExitedZero(old_res.term)) return .{ .text = if (old_res.stderr.len > 0) old_res.stderr else old_res.stdout, .is_error = true };
    const new_res = try runCapture(alloc, io, &.{ "git", "show", new_spec }, repo);
    if (!isExitedZero(new_res.term)) return .{ .text = if (new_res.stderr.len > 0) new_res.stderr else new_res.stdout, .is_error = true };

    const ext = if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot| path[dot + 1 ..] else "txt";
    const old_path = try tempPath(alloc, io, "git-old", ext);
    const new_path = try tempPath(alloc, io, "git-new", ext);
    defer std.Io.Dir.deleteFileAbsolute(io, old_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, new_path) catch {};

    try writeTempFile(io, old_path, old_res.stdout);
    try writeTempFile(io, new_path, new_res.stdout);

    var file_args_obj: std.json.ObjectMap = .{};
    try file_args_obj.put(alloc, "old", .{ .string = old_path });
    try file_args_obj.put(alloc, "new", .{ .string = new_path });
    if (getStr(args, "color")) |v| try file_args_obj.put(alloc, "color", .{ .string = v });
    if (getStr(args, "display")) |v| try file_args_obj.put(alloc, "display", .{ .string = v });

    return handleDiffFiles(alloc, io, .{ .object = file_args_obj });
}

fn handleDiffLanguages(alloc: std.mem.Allocator, io: Io, _: std.json.Value) !mcp.ToolResult {
    const difft = try difftBin(alloc);
    const result = try runCapture(alloc, io, &.{ difft, "--list-languages" }, null);
    return renderDifftResult(alloc, result);
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
