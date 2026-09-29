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
        .description = "AST-aware diff between two files on disk (confined to ZMCP_DIFF_ROOT, default the server working directory). Returns ANSI-colored output by default.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "old": { "type": "string", "description": "Path to the old or left-hand file; must resolve inside ZMCP_DIFF_ROOT (default: server cwd), max 8 MiB." },
        \\    "new": { "type": "string", "description": "Path to the new or right-hand file; must resolve inside ZMCP_DIFF_ROOT (default: server cwd), max 8 MiB." },
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

/// Unpredictable temp path: 128 random bits in the name. Callers must create
/// it with `writeTempFile` (exclusive create) so a pre-planted file or symlink
/// can never be followed or overwritten.
fn tempPath(alloc: std.mem.Allocator, io: Io, stem: []const u8, ext: []const u8) ![]u8 {
    const root = try tempRoot(alloc);
    defer alloc.free(root);
    var raw: [16]u8 = undefined;
    io.randomSecure(&raw) catch return error.EntropyUnavailable;
    const hex = std.fmt.bytesToHex(raw, .lower);
    return std.fmt.allocPrint(alloc, "{s}/zmcp-{s}-{s}.{s}", .{ root, stem, &hex, ext });
}

fn writeTempFile(io: Io, path: []const u8, data: []const u8) !void {
    const f = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    defer f.close(io);
    try f.writeStreamingAll(io, data);
}

/// Extension used for temp files: 1-16 ASCII alphanumerics, nothing else, so
/// it can never alter the directory or add path components.
fn validExt(ext: []const u8) bool {
    if (ext.len == 0 or ext.len > 16) return false;
    for (ext) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return true;
}

/// Git revisions are passed as a single argv element that must never parse as
/// an option: no leading '-', no NUL/whitespace/control characters.
fn validRev(rev: []const u8) bool {
    if (rev.len == 0 or rev.len > 256 or rev[0] == '-') return false;
    for (rev) |c| if (c <= ' ' or c == 0x7f) return false;
    return true;
}

const max_input_bytes: u64 = 8 * 1024 * 1024;

/// Canonicalise `path` (relative paths resolve against `root`) and require it to
/// live inside `root` (canonical; default cwd) and be at most `max_input_bytes`.
/// Fails closed. Result is allocated from `alloc`.
fn confineFile(alloc: std.mem.Allocator, io: Io, root_arg: ?[]const u8, path: []const u8) ![]u8 {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    const cwd = std.Io.Dir.cwd();
    var tmp = std.heap.ArenaAllocator.init(alloc);
    defer tmp.deinit();
    const a = tmp.allocator();
    const root = cwd.realPathFileAlloc(io, root_arg orelse ".", a) catch return error.RootNotAccessible;
    const joined = if (std.fs.path.isAbsolute(path)) path else try std.fs.path.join(a, &.{ root, path });
    const real = try cwd.realPathFileAlloc(io, joined, a);
    const inside = std.mem.eql(u8, real, root) or
        (std.mem.startsWith(u8, real, root) and (root[root.len - 1] == std.fs.path.sep or real[root.len] == std.fs.path.sep));
    if (!inside) return error.OutsideRoot;
    const st = try cwd.statFile(io, real, .{});
    if (st.kind != .file) return error.InvalidPath;
    if (st.size > max_input_bytes) return error.FileTooLarge;
    return alloc.dupe(u8, real);
}

fn confineMsg(alloc: std.mem.Allocator, which: []const u8, err: anyerror) ![]const u8 {
    return switch (err) {
        error.OutsideRoot => std.fmt.allocPrint(alloc, "error: {s} is outside ZMCP_DIFF_ROOT (default: the server's working directory)", .{which}),
        error.FileTooLarge => std.fmt.allocPrint(alloc, "error: {s} exceeds the {d} byte input limit", .{ which, max_input_bytes }),
        else => std.fmt.allocPrint(alloc, "error: cannot read {s}: {s}", .{ which, @errorName(err) }),
    };
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
    const root_env = envOwned(alloc, "ZMCP_DIFF_ROOT");
    const root: ?[]const u8 = if (root_env) |r| (if (r.len > 0) r else null) else null;
    const old_real = confineFile(alloc, io, root, old) catch |e|
        return .{ .text = try confineMsg(alloc, "old", e), .is_error = true };
    const new_real = confineFile(alloc, io, root, new) catch |e|
        return .{ .text = try confineMsg(alloc, "new", e), .is_error = true };
    return runDifft(alloc, io, args, old_real, new_real);
}

/// Run difft on two already-trusted absolute paths (confined user files or our
/// own temp files).
fn runDifft(alloc: std.mem.Allocator, io: Io, args: std.json.Value, old: []const u8, new: []const u8) !mcp.ToolResult {
    const difft = try difftBin(alloc);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, difft);
    appendCommonDifftArgs(alloc, &argv, args) catch |e| switch (e) {
        error.InvalidColor => return .{ .text = "error: invalid color", .is_error = true },
        error.InvalidDisplay => return .{ .text = "error: invalid display", .is_error = true },
        else => return e,
    };
    try argv.append(alloc, old);
    try argv.append(alloc, new);

    const result = try runCapture(alloc, io, argv.items, null);
    return renderDifftResult(alloc, result);
}

fn handleDiffStrings(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const old = getStr(args, "old") orelse return .{ .text = "error: old is required", .is_error = true };
    const new = getStr(args, "new") orelse return .{ .text = "error: new is required", .is_error = true };
    const ext = getStr(args, "ext") orelse return .{ .text = "error: ext is required", .is_error = true };

    if (!validExt(ext)) return .{ .text = "error: ext must be 1-16 alphanumeric characters", .is_error = true };
    if (old.len > max_input_bytes or new.len > max_input_bytes)
        return .{ .text = "error: input exceeds the size limit", .is_error = true };

    const old_path = try tempPath(alloc, io, "old", ext);
    const new_path = try tempPath(alloc, io, "new", ext);

    try writeTempFile(io, old_path, old);
    defer std.Io.Dir.deleteFileAbsolute(io, old_path) catch {};
    try writeTempFile(io, new_path, new);
    defer std.Io.Dir.deleteFileAbsolute(io, new_path) catch {};

    return runDifft(alloc, io, args, old_path, new_path);
}

fn handleDiffGitShow(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const repo = getStr(args, "repo") orelse return .{ .text = "error: repo is required", .is_error = true };
    const path = getStr(args, "path") orelse return .{ .text = "error: path is required", .is_error = true };
    const old_rev = getStr(args, "old_rev") orelse return .{ .text = "error: old_rev is required", .is_error = true };
    const new_rev = getStr(args, "new_rev") orelse "HEAD";

    if (!validRev(old_rev)) return .{ .text = "error: invalid old_rev", .is_error = true };
    if (!validRev(new_rev)) return .{ .text = "error: invalid new_rev", .is_error = true };
    if (path.len == 0 or std.mem.indexOfAny(u8, path, "\x00\r\n") != null)
        return .{ .text = "error: invalid path", .is_error = true };
    if (repo.len == 0 or std.mem.indexOfScalar(u8, repo, 0) != null)
        return .{ .text = "error: invalid repo", .is_error = true };

    // Specs start with a validated rev (never '-'), so they cannot parse as options.
    const old_spec = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ old_rev, path });
    const new_spec = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ new_rev, path });

    const old_res = try runCapture(alloc, io, &.{ "git", "show", "--no-ext-diff", "--no-textconv", old_spec, "--" }, repo);
    if (!isExitedZero(old_res.term)) return .{ .text = if (old_res.stderr.len > 0) old_res.stderr else old_res.stdout, .is_error = true };
    const new_res = try runCapture(alloc, io, &.{ "git", "show", "--no-ext-diff", "--no-textconv", new_spec, "--" }, repo);
    if (!isExitedZero(new_res.term)) return .{ .text = if (new_res.stderr.len > 0) new_res.stderr else new_res.stdout, .is_error = true };

    const raw_ext = if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot| path[dot + 1 ..] else "txt";
    const ext = if (validExt(raw_ext)) raw_ext else "txt";
    const old_path = try tempPath(alloc, io, "git-old", ext);
    const new_path = try tempPath(alloc, io, "git-new", ext);

    try writeTempFile(io, old_path, old_res.stdout);
    defer std.Io.Dir.deleteFileAbsolute(io, old_path) catch {};
    try writeTempFile(io, new_path, new_res.stdout);
    defer std.Io.Dir.deleteFileAbsolute(io, new_path) catch {};

    return runDifft(alloc, io, args, old_path, new_path);
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

test "validRev rejects option-like and malformed revs" {
    try std.testing.expect(validRev("HEAD~1"));
    try std.testing.expect(validRev("a1b2c3d"));
    try std.testing.expect(validRev("feature/x@{1}"));
    try std.testing.expect(!validRev("--output=/tmp/x"));
    try std.testing.expect(!validRev("-p"));
    try std.testing.expect(!validRev(""));
    try std.testing.expect(!validRev("HEAD\nfoo"));
    try std.testing.expect(!validRev("HEAD foo"));
    try std.testing.expect(!validRev("HEAD\x00"));
}

test "validExt" {
    try std.testing.expect(validExt("zig"));
    try std.testing.expect(!validExt(""));
    try std.testing.expect(!validExt("../../x"));
    try std.testing.expect(!validExt("a/b"));
}

test "diff_git_show rejects option-like revs before running git" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var map: std.json.ObjectMap = .{};
    try map.put(arena, "repo", .{ .string = "." });
    try map.put(arena, "path", .{ .string = "a.zig" });
    try map.put(arena, "old_rev", .{ .string = "--output=/tmp/zmcp-x" });
    const r = try handleDiffGitShow(arena, std.testing.io, .{ .object = map });
    try std.testing.expect(r.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "invalid old_rev") != null);

    try map.put(arena, "old_rev", .{ .string = "HEAD" });
    try map.put(arena, "new_rev", .{ .string = "--output=/tmp/zmcp-x" });
    const r2 = try handleDiffGitShow(arena, std.testing.io, .{ .object = map });
    try std.testing.expect(r2.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r2.text, "invalid new_rev") != null);
}

test "confineFile enforces root, prefix boundary and size cap" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "root", .default_dir);
    try tmp.dir.createDir(io, "root-evil", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "root/a.txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "root-evil/b.txt", .data = "x" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const base = buf[0..n];
    const root = try std.fmt.allocPrint(gpa, "{s}/root", .{base});
    defer gpa.free(root);

    const ok = try confineFile(gpa, io, root, "a.txt");
    gpa.free(ok);
    try std.testing.expectError(error.OutsideRoot, confineFile(gpa, io, root, "../root-evil/b.txt"));
    try std.testing.expectError(error.OutsideRoot, confineFile(gpa, io, root, "/etc/passwd"));
    try std.testing.expectError(error.InvalidPath, confineFile(gpa, io, root, ""));
    try std.testing.expectError(error.InvalidPath, confineFile(gpa, io, root, "a.txt\x00"));
    try std.testing.expectError(error.FileNotFound, confineFile(gpa, io, root, "nope.txt"));

    // Size cap: sparse file just over the limit.
    const f = try tmp.dir.createFile(io, "root/big.bin", .{});
    try f.setLength(io, max_input_bytes + 1);
    f.close(io);
    try std.testing.expectError(error.FileTooLarge, confineFile(gpa, io, root, "big.bin"));
}

test "temp files are unpredictable and exclusively created" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    g_env_io = io;
    defer g_env_io = null;
    const p1 = try tempPath(gpa, io, "old", "zig");
    defer gpa.free(p1);
    const p2 = try tempPath(gpa, io, "old", "zig");
    defer gpa.free(p2);
    try std.testing.expect(!std.mem.eql(u8, p1, p2));

    try writeTempFile(io, p1, "one");
    defer std.Io.Dir.deleteFileAbsolute(io, p1) catch {};
    try std.testing.expectError(error.PathAlreadyExists, writeTempFile(io, p1, "two"));
}
