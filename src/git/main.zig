//! zmcp-git - pure-Zig port of the reference `mcp-server-git`.
//! Shells out to the local `git` CLI (resolved via PATH, GIT_BIN override).
//!
//! Tools (parity with mcp-server-git; every tool takes repo_path):
//!   git_status(repo_path)
//!   git_diff_unstaged(repo_path)
//!   git_diff_staged(repo_path)
//!   git_diff(repo_path, target)
//!   git_log(repo_path, max_count?, since?, until?)
//!   git_show(repo_path, revision)
//!   git_branch(repo_path, branch_type?)              - list only
//!   git_add(repo_path, files[])
//!   git_commit(repo_path, message)
//!   git_reset(repo_path)                             - unstage everything
//!   git_checkout(repo_path, branch_name)
//!   git_create_branch(repo_path, branch_name, base_branch?)
//!
//! Safety model:
//!   * git is spawned with an argv array only, never through a shell.
//!   * Every ref / path / revision supplied by the caller is rejected when it
//!     begins with '-' (option injection), contains control characters, or is
//!     empty; paths and revisions are additionally placed after `--` where git
//!     allows it.
//!   * Output is capped (MAX_OUTPUT_BYTES) and sanitised to valid UTF-8.
//!   * There are deliberately no push / fetch / pull / clean / force / config
//!     tools, and external diff drivers / pagers are disabled.

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

/// Text returned to the model is truncated past this many bytes.
const MAX_OUTPUT_BYTES: usize = 256 * 1024;
/// Hard ceiling on what we read from the child before giving up.
const MAX_CAPTURE_BYTES: usize = 16 * 1024 * 1024;
const MAX_STDERR_BYTES: usize = 1024 * 1024;
const DEFAULT_LOG_COUNT: i64 = 10;
const MAX_LOG_COUNT: i64 = 1000;

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    g_env_io = init.io;
    const io = init.io;
    try mcp.run(arena, io, .{ .name = "zmcp-git", .version = "0.1.0" }, &tool_table);
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "git_status",
        .description = "Shows the working tree status of a git repository.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "repo_path": { "type": "string", "description": "Path to the git repository." }
        \\  },
        \\  "required": ["repo_path"]
        \\}
        ,
        .handler = handleStatus,
        .read_only = true,
    },
    .{
        .name = "git_diff_unstaged",
        .description = "Shows changes in the working directory that are not yet staged.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "repo_path": { "type": "string", "description": "Path to the git repository." }
        \\  },
        \\  "required": ["repo_path"]
        \\}
        ,
        .handler = handleDiffUnstaged,
        .read_only = true,
    },
    .{
        .name = "git_diff_staged",
        .description = "Shows changes that are staged for commit.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "repo_path": { "type": "string", "description": "Path to the git repository." }
        \\  },
        \\  "required": ["repo_path"]
        \\}
        ,
        .handler = handleDiffStaged,
        .read_only = true,
    },
    .{
        .name = "git_diff",
        .description = "Shows differences between the working tree and a branch, tag or commit.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "repo_path": { "type": "string", "description": "Path to the git repository." },
        \\    "target":    { "type": "string", "description": "Branch, tag or commit to diff against. Must not start with '-'." }
        \\  },
        \\  "required": ["repo_path", "target"]
        \\}
        ,
        .handler = handleDiff,
        .read_only = true,
    },
    .{
        .name = "git_log",
        .description = "Shows the commit log (hash, author, date, message). Optionally bounded by max_count (default 10) and since/until dates (e.g. '2 weeks ago', '2024-01-01').",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "repo_path": { "type": "string", "description": "Path to the git repository." },
        \\    "max_count": { "type": "integer", "default": 10, "description": "Maximum number of commits to show (1-1000)." },
        \\    "since":     { "type": "string", "description": "Only commits more recent than this date." },
        \\    "until":     { "type": "string", "description": "Only commits older than this date." }
        \\  },
        \\  "required": ["repo_path"]
        \\}
        ,
        .handler = handleLog,
        .read_only = true,
    },
    .{
        .name = "git_show",
        .description = "Shows the contents (metadata and diff) of a commit.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "repo_path": { "type": "string", "description": "Path to the git repository." },
        \\    "revision":  { "type": "string", "description": "Commit hash, branch or tag to show. Must not start with '-'." }
        \\  },
        \\  "required": ["repo_path", "revision"]
        \\}
        ,
        .handler = handleShow,
        .read_only = true,
    },
    .{
        .name = "git_branch",
        .description = "Lists git branches. branch_type is 'local' (default), 'remote' or 'all'.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "repo_path":   { "type": "string", "description": "Path to the git repository." },
        \\    "branch_type": { "type": "string", "enum": ["local", "remote", "all"], "default": "local", "description": "Which branches to list." }
        \\  },
        \\  "required": ["repo_path"]
        \\}
        ,
        .handler = handleBranch,
        .read_only = true,
    },
    .{
        .name = "git_add",
        .description = "Adds file contents to the staging area.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "repo_path": { "type": "string", "description": "Path to the git repository." },
        \\    "files":     { "type": "array", "items": { "type": "string" }, "description": "Paths to stage. Must not start with '-'." }
        \\  },
        \\  "required": ["repo_path", "files"]
        \\}
        ,
        .handler = handleAdd,
    },
    .{
        .name = "git_commit",
        .description = "Records staged changes to the repository.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "repo_path": { "type": "string", "description": "Path to the git repository." },
        \\    "message":   { "type": "string", "description": "Commit message." }
        \\  },
        \\  "required": ["repo_path", "message"]
        \\}
        ,
        .handler = handleCommit,
    },
    .{
        .name = "git_reset",
        .description = "Unstages all staged changes (mixed reset of the index; the working tree is not touched).",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "repo_path": { "type": "string", "description": "Path to the git repository." }
        \\  },
        \\  "required": ["repo_path"]
        \\}
        ,
        .handler = handleReset,
        .destructive = true,
    },
    .{
        .name = "git_checkout",
        .description = "Switches to an existing branch.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "repo_path":   { "type": "string", "description": "Path to the git repository." },
        \\    "branch_name": { "type": "string", "description": "Name of the branch to check out. Must not start with '-'." }
        \\  },
        \\  "required": ["repo_path", "branch_name"]
        \\}
        ,
        .handler = handleCheckout,
        .destructive = true,
    },
    .{
        .name = "git_create_branch",
        .description = "Creates a new branch (optionally from a base branch/commit) and switches to it.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "repo_path":   { "type": "string", "description": "Path to the git repository." },
        \\    "branch_name": { "type": "string", "description": "Name of the new branch. Must not start with '-'." },
        \\    "base_branch": { "type": "string", "description": "Optional starting point (branch, tag or commit). Defaults to HEAD." }
        \\  },
        \\  "required": ["repo_path", "branch_name"]
        \\}
        ,
        .handler = handleCreateBranch,
    },
};

// ---------------------------------------------------------------------------
// Process-execution seam (injectable for offline unit tests)
// ---------------------------------------------------------------------------

pub const ExecResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
};

pub const ExecFn = *const fn (
    alloc: std.mem.Allocator,
    io: Io,
    argv: []const []const u8,
) anyerror!ExecResult;

var exec_fn: ExecFn = execReal;

fn setExecForTesting(f: ExecFn) void {
    exec_fn = f;
}

fn gitBin(alloc: std.mem.Allocator) ![]const u8 {
    if (envOwned(alloc, "GIT_BIN")) |v| return v;
    return alloc.dupe(u8, "git");
}

fn execReal(alloc: std.mem.Allocator, io: Io, argv: []const []const u8) !ExecResult {
    const bin = try gitBin(alloc);
    defer alloc.free(bin);
    var resolved: std.ArrayList([]const u8) = .empty;
    defer resolved.deinit(alloc);
    try resolved.append(alloc, bin);
    try resolved.appendSlice(alloc, argv[1..]);

    const result = std.process.run(alloc, io, .{
        .argv = resolved.items,
        .stdout_limit = .limited(MAX_CAPTURE_BYTES),
        .stderr_limit = .limited(MAX_STDERR_BYTES),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.ExecutableNotFound,
        else => return err,
    };
    return .{ .term = result.term, .stdout = result.stdout, .stderr = result.stderr };
}

// ---------------------------------------------------------------------------
// Pure helpers (unit tested)
// ---------------------------------------------------------------------------

/// Validates a caller-supplied value that git would interpret as a ref, revision,
/// branch name or path. Returns an error message, or null when acceptable.
fn checkValue(val: []const u8) ?[]const u8 {
    if (val.len == 0) return "must not be empty";
    if (val[0] == '-') return "must not start with '-'";
    for (val) |c| {
        if (c < 0x20 or c == 0x7f) return "must not contain control characters";
    }
    return null;
}

/// Validates repo_path. It is passed to `git -C`, which consumes it as the
/// option's value, but we still reject leading '-' as defence in depth.
fn checkRepoPath(val: []const u8) ?[]const u8 {
    if (val.len == 0) return "must not be empty";
    if (val[0] == '-') return "must not start with '-'";
    if (std.mem.indexOfScalar(u8, val, 0) != null) return "must not contain NUL";
    return null;
}

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
        .float => |f| if (std.math.isFinite(f) and @abs(f) < 1e15) @as(i64, @intFromFloat(f)) else null,
        else => null,
    };
}

fn toolErr(alloc: std.mem.Allocator, comptime fmt: []const u8, a: anytype) !mcp.ToolResult {
    return .{ .text = try std.fmt.allocPrint(alloc, fmt, a), .is_error = true };
}

/// Truncates to MAX_OUTPUT_BYTES (on a UTF-8 boundary) and replaces invalid
/// UTF-8 sequences with '?' so the JSON-RPC layer always gets valid text.
fn shapeOutput(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var slice = raw;
    var truncated = false;
    if (slice.len > MAX_OUTPUT_BYTES) {
        var cut: usize = MAX_OUTPUT_BYTES;
        while (cut > 0 and (slice[cut] & 0xC0) == 0x80) cut -= 1;
        slice = slice[0..cut];
        truncated = true;
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < slice.len) {
        const b = slice[i];
        if (b < 0x80) {
            try out.append(alloc, b);
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(b) catch {
            try out.append(alloc, '?');
            i += 1;
            continue;
        };
        if (i + n <= slice.len and std.unicode.utf8ValidateSlice(slice[i .. i + n])) {
            try out.appendSlice(alloc, slice[i .. i + n]);
            i += n;
        } else {
            try out.append(alloc, '?');
            i += 1;
        }
    }
    if (truncated) {
        try out.print(alloc, "\n[output truncated: showing first {d} of {d} bytes]", .{ slice.len, raw.len });
    }
    return out.toOwnedSlice(alloc);
}

/// Builds `git --no-pager -C <repo> <rest...>`.
fn gitArgv(alloc: std.mem.Allocator, repo: []const u8, rest: []const []const u8) ![][]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(alloc);
    try argv.appendSlice(alloc, &.{ "git", "--no-pager", "-C", repo });
    try argv.appendSlice(alloc, rest);
    return argv.toOwnedSlice(alloc);
}

/// Runs git through the exec seam and maps every failure to a tool error.
fn runGit(
    alloc: std.mem.Allocator,
    io: Io,
    repo: []const u8,
    rest: []const []const u8,
    empty_msg: []const u8,
) !mcp.ToolResult {
    const argv = try gitArgv(alloc, repo, rest);
    const result = exec_fn(alloc, io, argv) catch |err| switch (err) {
        error.ExecutableNotFound => return .{
            .text = "Command 'git' not found. Please ensure git is installed and in PATH.",
            .is_error = true,
        },
        error.StreamTooLong => return .{
            .text = "git output exceeded the maximum size and was discarded; narrow the request.",
            .is_error = true,
        },
        else => return toolErr(alloc, "git execution failed: {s}", .{@errorName(err)}),
    };
    switch (result.term) {
        .exited => |code| if (code != 0) {
            const se = std.mem.trim(u8, result.stderr, " \t\r\n");
            const so = std.mem.trim(u8, result.stdout, " \t\r\n");
            const detail = if (se.len > 0) se else if (so.len > 0) so else "(no error output)";
            const shaped = try shapeOutput(alloc, detail);
            return toolErr(alloc, "git {s} failed with exit code {d}: {s}", .{ rest[0], code, shaped });
        },
        else => return toolErr(alloc, "git {s} failed: process terminated abnormally", .{rest[0]}),
    }
    const body = try shapeOutput(alloc, result.stdout);
    if (std.mem.trim(u8, body, " \t\r\n").len == 0) return .{ .text = empty_msg };
    return .{ .text = body };
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// Extracts and validates repo_path; on failure `bad` holds the tool error.
const RepoCheck = union(enum) { ok: []const u8, bad: mcp.ToolResult };

fn repoOf(alloc: std.mem.Allocator, args: std.json.Value) !RepoCheck {
    const repo = getStr(args, "repo_path") orelse return .{ .bad = .{ .text = "error: repo_path is required", .is_error = true } };
    if (checkRepoPath(repo)) |m| return .{ .bad = try toolErr(alloc, "error: invalid repo_path: {s}", .{m}) };
    return .{ .ok = repo };
}

/// Required string argument that must pass checkValue.
const RefCheck = union(enum) { ok: []const u8, bad: mcp.ToolResult };

fn refArg(alloc: std.mem.Allocator, args: std.json.Value, key: []const u8) !RefCheck {
    const v = getStr(args, key) orelse return .{ .bad = try toolErr(alloc, "error: {s} is required", .{key}) };
    if (checkValue(v)) |m| return .{ .bad = try toolErr(alloc, "error: invalid {s}: {s}", .{ key, m }) };
    return .{ .ok = v };
}

fn handleStatus(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const repo = switch (try repoOf(alloc, args)) {
        .ok => |r| r,
        .bad => |b| return b,
    };
    return runGit(alloc, io, repo, &.{"status"}, "(no output)");
}

fn handleDiffUnstaged(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const repo = switch (try repoOf(alloc, args)) {
        .ok => |r| r,
        .bad => |b| return b,
    };
    return runGit(alloc, io, repo, &.{ "diff", "--no-ext-diff" }, "(no unstaged changes)");
}

fn handleDiffStaged(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const repo = switch (try repoOf(alloc, args)) {
        .ok => |r| r,
        .bad => |b| return b,
    };
    return runGit(alloc, io, repo, &.{ "diff", "--no-ext-diff", "--cached" }, "(no staged changes)");
}

fn handleDiff(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const repo = switch (try repoOf(alloc, args)) {
        .ok => |r| r,
        .bad => |b| return b,
    };
    const target = switch (try refArg(alloc, args, "target")) {
        .ok => |r| r,
        .bad => |b| return b,
    };
    return runGit(alloc, io, repo, &.{ "diff", "--no-ext-diff", target, "--" }, "(no differences)");
}

fn handleLog(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const repo = switch (try repoOf(alloc, args)) {
        .ok => |r| r,
        .bad => |b| return b,
    };
    const count = std.math.clamp(getInt(args, "max_count") orelse DEFAULT_LOG_COUNT, 1, MAX_LOG_COUNT);

    var rest: std.ArrayList([]const u8) = .empty;
    try rest.append(alloc, "log");
    try rest.append(alloc, "--no-ext-diff");
    try rest.append(alloc, try std.fmt.allocPrint(alloc, "--max-count={d}", .{count}));
    try rest.append(alloc, "--format=Commit: %H%nAuthor: %an <%ae>%nDate: %ad%nMessage: %B%n---");
    // since/until are attached to their option (`--since=<v>`), so the value can
    // never be parsed as a separate option; we still apply the shared checks.
    inline for (.{ "since", "until" }) |key| {
        if (getStr(args, key)) |v| {
            if (checkValue(v)) |m| return toolErr(alloc, "error: invalid {s}: {s}", .{ key, m });
            try rest.append(alloc, try std.fmt.allocPrint(alloc, "--" ++ key ++ "={s}", .{v}));
        }
    }
    try rest.append(alloc, "--");
    return runGit(alloc, io, repo, rest.items, "(no commits)");
}

fn handleShow(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const repo = switch (try repoOf(alloc, args)) {
        .ok => |r| r,
        .bad => |b| return b,
    };
    const rev = switch (try refArg(alloc, args, "revision")) {
        .ok => |r| r,
        .bad => |b| return b,
    };
    return runGit(alloc, io, repo, &.{ "show", "--no-ext-diff", rev, "--" }, "(no output)");
}

fn handleBranch(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const repo = switch (try repoOf(alloc, args)) {
        .ok => |r| r,
        .bad => |b| return b,
    };
    const kind = getStr(args, "branch_type") orelse "local";
    if (std.mem.eql(u8, kind, "local")) return runGit(alloc, io, repo, &.{ "branch", "--list" }, "(no branches)");
    if (std.mem.eql(u8, kind, "remote")) return runGit(alloc, io, repo, &.{ "branch", "--list", "--remotes" }, "(no branches)");
    if (std.mem.eql(u8, kind, "all")) return runGit(alloc, io, repo, &.{ "branch", "--list", "--all" }, "(no branches)");
    return toolErr(alloc, "Invalid branch_type: {s}. Must be 'local', 'remote' or 'all'.", .{kind});
}

fn handleAdd(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const repo = switch (try repoOf(alloc, args)) {
        .ok => |r| r,
        .bad => |b| return b,
    };
    if (args != .object) return .{ .text = "error: files is required", .is_error = true };
    const files_v = args.object.get("files") orelse return .{ .text = "error: files is required", .is_error = true };
    if (files_v != .array) return .{ .text = "error: files must be an array of strings", .is_error = true };
    if (files_v.array.items.len == 0) return .{ .text = "error: files must not be empty", .is_error = true };

    var rest: std.ArrayList([]const u8) = .empty;
    try rest.append(alloc, "add");
    try rest.append(alloc, "--");
    for (files_v.array.items) |f| {
        if (f != .string) return .{ .text = "error: files must be an array of strings", .is_error = true };
        if (checkValue(f.string)) |m| return toolErr(alloc, "error: invalid file '{s}': {s}", .{ f.string, m });
        try rest.append(alloc, f.string);
    }
    const res = try runGit(alloc, io, repo, rest.items, "");
    if (res.is_error) return res;
    return .{ .text = "Files staged successfully" };
}

fn handleCommit(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const repo = switch (try repoOf(alloc, args)) {
        .ok => |r| r,
        .bad => |b| return b,
    };
    const msg = getStr(args, "message") orelse return .{ .text = "error: message is required", .is_error = true };
    if (std.mem.trim(u8, msg, " \t\r\n").len == 0) return .{ .text = "error: message must not be empty", .is_error = true };
    if (std.mem.indexOfScalar(u8, msg, 0) != null) return .{ .text = "error: message must not contain NUL", .is_error = true };
    // The message travels as the separate value of -m, so a leading '-' is data.
    return runGit(alloc, io, repo, &.{ "commit", "-m", msg }, "Changes committed");
}

fn handleReset(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const repo = switch (try repoOf(alloc, args)) {
        .ok => |r| r,
        .bad => |b| return b,
    };
    const res = try runGit(alloc, io, repo, &.{ "reset", "--mixed" }, "");
    if (res.is_error) return res;
    return .{ .text = "All staged changes reset" };
}

fn handleCheckout(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const repo = switch (try repoOf(alloc, args)) {
        .ok => |r| r,
        .bad => |b| return b,
    };
    const name = switch (try refArg(alloc, args, "branch_name")) {
        .ok => |r| r,
        .bad => |b| return b,
    };
    const res = try runGit(alloc, io, repo, &.{ "checkout", name, "--" }, "");
    if (res.is_error) return res;
    return .{ .text = try std.fmt.allocPrint(alloc, "Switched to branch '{s}'", .{name}) };
}

fn handleCreateBranch(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const repo = switch (try repoOf(alloc, args)) {
        .ok => |r| r,
        .bad => |b| return b,
    };
    const name = switch (try refArg(alloc, args, "branch_name")) {
        .ok => |r| r,
        .bad => |b| return b,
    };
    var base: ?[]const u8 = null;
    if (getStr(args, "base_branch")) |b| {
        if (checkValue(b)) |m| return toolErr(alloc, "error: invalid base_branch: {s}", .{m});
        base = b;
    }
    const res = if (base) |b|
        try runGit(alloc, io, repo, &.{ "checkout", "-b", name, b, "--" }, "")
    else
        try runGit(alloc, io, repo, &.{ "checkout", "-b", name, "--" }, "");
    if (res.is_error) return res;
    return .{ .text = try std.fmt.allocPrint(alloc, "Created and switched to branch '{s}'", .{name}) };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

var fake_argv: []const []const u8 = &.{};
var fake_calls: usize = 0;
var fake_result: ExecResult = .{ .term = .{ .exited = 0 }, .stdout = @constCast(""), .stderr = @constCast("") };
var fake_error: ?anyerror = null;

fn fakeExec(alloc: std.mem.Allocator, io: Io, argv: []const []const u8) !ExecResult {
    _ = alloc;
    _ = io;
    fake_argv = argv;
    fake_calls += 1;
    if (fake_error) |e| return e;
    return fake_result;
}

fn fakeOk(stdout: []const u8, stderr: []const u8) void {
    fake_result = .{ .term = .{ .exited = 0 }, .stdout = @constCast(stdout), .stderr = @constCast(stderr) };
    fake_error = null;
}

fn testArgs(arena: std.mem.Allocator, json: []const u8) !std.json.Value {
    const p = try std.json.parseFromSlice(std.json.Value, arena, json, .{});
    return p.value;
}

const TestCtx = struct {
    arena_state: std.heap.ArenaAllocator,
    arena: std.mem.Allocator,

    /// Initialize IN PLACE: arena_state must not move after this call.
    fn init(ctx: *TestCtx) void {
        ctx.arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        ctx.arena = ctx.arena_state.allocator();
        setExecForTesting(fakeExec);
        fake_argv = &.{};
        fake_calls = 0;
        fakeOk("", "");
    }

    fn deinit(ctx: *TestCtx) void {
        setExecForTesting(execReal);
        ctx.arena_state.deinit();
    }
};

fn expectArgv(want: []const []const u8) !void {
    try std.testing.expectEqual(want.len, fake_argv.len);
    for (want, fake_argv) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "argv: status / diff_unstaged / diff_staged" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fakeOk("out\n", "");

    const a = try testArgs(ctx.arena,
        \\{"repo_path": "/r"}
    );
    _ = try handleStatus(ctx.arena, std.testing.io, a);
    try expectArgv(&.{ "git", "--no-pager", "-C", "/r", "status" });
    _ = try handleDiffUnstaged(ctx.arena, std.testing.io, a);
    try expectArgv(&.{ "git", "--no-pager", "-C", "/r", "diff", "--no-ext-diff" });
    _ = try handleDiffStaged(ctx.arena, std.testing.io, a);
    try expectArgv(&.{ "git", "--no-pager", "-C", "/r", "diff", "--no-ext-diff", "--cached" });
}

test "argv: diff, show, checkout, create_branch use -- separators" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fakeOk("out\n", "");

    _ = try handleDiff(ctx.arena, std.testing.io, try testArgs(ctx.arena,
        \\{"repo_path": "/r", "target": "main"}
    ));
    try expectArgv(&.{ "git", "--no-pager", "-C", "/r", "diff", "--no-ext-diff", "main", "--" });

    _ = try handleShow(ctx.arena, std.testing.io, try testArgs(ctx.arena,
        \\{"repo_path": "/r", "revision": "abc123"}
    ));
    try expectArgv(&.{ "git", "--no-pager", "-C", "/r", "show", "--no-ext-diff", "abc123", "--" });

    _ = try handleCheckout(ctx.arena, std.testing.io, try testArgs(ctx.arena,
        \\{"repo_path": "/r", "branch_name": "dev"}
    ));
    try expectArgv(&.{ "git", "--no-pager", "-C", "/r", "checkout", "dev", "--" });

    _ = try handleCreateBranch(ctx.arena, std.testing.io, try testArgs(ctx.arena,
        \\{"repo_path": "/r", "branch_name": "feat"}
    ));
    try expectArgv(&.{ "git", "--no-pager", "-C", "/r", "checkout", "-b", "feat", "--" });

    _ = try handleCreateBranch(ctx.arena, std.testing.io, try testArgs(ctx.arena,
        \\{"repo_path": "/r", "branch_name": "feat", "base_branch": "main"}
    ));
    try expectArgv(&.{ "git", "--no-pager", "-C", "/r", "checkout", "-b", "feat", "main", "--" });
}

test "argv: log defaults, clamping and since/until" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fakeOk("x", "");

    _ = try handleLog(ctx.arena, std.testing.io, try testArgs(ctx.arena,
        \\{"repo_path": "/r"}
    ));
    try std.testing.expectEqualStrings("--max-count=10", fake_argv[6]);
    try std.testing.expectEqualStrings("--", fake_argv[fake_argv.len - 1]);

    _ = try handleLog(ctx.arena, std.testing.io, try testArgs(ctx.arena,
        \\{"repo_path": "/r", "max_count": 999999, "since": "2 weeks ago", "until": "2024-01-01"}
    ));
    try std.testing.expectEqualStrings("--max-count=1000", fake_argv[6]);
    try std.testing.expectEqualStrings("--since=2 weeks ago", fake_argv[8]);
    try std.testing.expectEqualStrings("--until=2024-01-01", fake_argv[9]);

    _ = try handleLog(ctx.arena, std.testing.io, try testArgs(ctx.arena,
        \\{"repo_path": "/r", "max_count": -5}
    ));
    try std.testing.expectEqualStrings("--max-count=1", fake_argv[6]);
}

test "argv: branch types, add, commit, reset" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fakeOk("* main\n", "");

    _ = try handleBranch(ctx.arena, std.testing.io, try testArgs(ctx.arena,
        \\{"repo_path": "/r"}
    ));
    try expectArgv(&.{ "git", "--no-pager", "-C", "/r", "branch", "--list" });
    _ = try handleBranch(ctx.arena, std.testing.io, try testArgs(ctx.arena,
        \\{"repo_path": "/r", "branch_type": "all"}
    ));
    try expectArgv(&.{ "git", "--no-pager", "-C", "/r", "branch", "--list", "--all" });
    const bad = try handleBranch(ctx.arena, std.testing.io, try testArgs(ctx.arena,
        \\{"repo_path": "/r", "branch_type": "x"}
    ));
    try std.testing.expect(bad.is_error);

    _ = try handleAdd(ctx.arena, std.testing.io, try testArgs(ctx.arena,
        \\{"repo_path": "/r", "files": ["a.txt", "dir/b.txt"]}
    ));
    try expectArgv(&.{ "git", "--no-pager", "-C", "/r", "add", "--", "a.txt", "dir/b.txt" });

    _ = try handleCommit(ctx.arena, std.testing.io, try testArgs(ctx.arena,
        \\{"repo_path": "/r", "message": "-hello --amend"}
    ));
    try expectArgv(&.{ "git", "--no-pager", "-C", "/r", "commit", "-m", "-hello --amend" });

    _ = try handleReset(ctx.arena, std.testing.io, try testArgs(ctx.arena,
        \\{"repo_path": "/r"}
    ));
    try expectArgv(&.{ "git", "--no-pager", "-C", "/r", "reset", "--mixed" });
}

const Case = struct { h: mcp.ToolHandler, json: []const u8 };

test "injection: values beginning with '-' are rejected without spawning git" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();

    const cases = [_]Case{
        .{ .h = handleDiff, .json = "{\"repo_path\":\"/r\",\"target\":\"--output=/tmp/x\"}" },
        .{ .h = handleDiff, .json = "{\"repo_path\":\"/r\",\"target\":\"-p\"}" },
        .{ .h = handleShow, .json = "{\"repo_path\":\"/r\",\"revision\":\"--output=/tmp/x\"}" },
        .{ .h = handleCheckout, .json = "{\"repo_path\":\"/r\",\"branch_name\":\"-f\"}" },
        .{ .h = handleCreateBranch, .json = "{\"repo_path\":\"/r\",\"branch_name\":\"--orphan\"}" },
        .{ .h = handleCreateBranch, .json = "{\"repo_path\":\"/r\",\"branch_name\":\"ok\",\"base_branch\":\"--track\"}" },
        .{ .h = handleAdd, .json = "{\"repo_path\":\"/r\",\"files\":[\"ok\",\"--force\"]}" },
        .{ .h = handleAdd, .json = "{\"repo_path\":\"/r\",\"files\":[\"-A\"]}" },
        .{ .h = handleLog, .json = "{\"repo_path\":\"/r\",\"since\":\"--all\"}" },
        .{ .h = handleLog, .json = "{\"repo_path\":\"/r\",\"until\":\"-1\"}" },
        .{ .h = handleStatus, .json = "{\"repo_path\":\"--git-dir=/etc\"}" },
        .{ .h = handleCommit, .json = "{\"repo_path\":\"-c\",\"message\":\"m\"}" },
    };
    for (cases) |c| {
        const res = try c.h(ctx.arena, std.testing.io, try testArgs(ctx.arena, c.json));
        if (!res.is_error) std.debug.print("not rejected: {s}\n", .{c.json});
        try std.testing.expect(res.is_error);
    }
    try std.testing.expectEqual(@as(usize, 0), fake_calls);
}

test "validation: empty, control chars, missing and mistyped arguments" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();

    const bad = [_]Case{
        .{ .h = handleStatus, .json = "{}" },
        .{ .h = handleStatus, .json = "{\"repo_path\":\"\"}" },
        .{ .h = handleStatus, .json = "{\"repo_path\":5}" },
        .{ .h = handleDiff, .json = "{\"repo_path\":\"/r\"}" },
        .{ .h = handleDiff, .json = "{\"repo_path\":\"/r\",\"target\":\"\"}" },
        .{ .h = handleDiff, .json = "{\"repo_path\":\"/r\",\"target\":\"a\\nb\"}" },
        .{ .h = handleAdd, .json = "{\"repo_path\":\"/r\",\"files\":[]}" },
        .{ .h = handleAdd, .json = "{\"repo_path\":\"/r\",\"files\":\"a\"}" },
        .{ .h = handleAdd, .json = "{\"repo_path\":\"/r\",\"files\":[1]}" },
        .{ .h = handleCommit, .json = "{\"repo_path\":\"/r\",\"message\":\"  \"}" },
        .{ .h = handleCommit, .json = "{\"repo_path\":\"/r\"}" },
    };
    for (bad) |c| {
        const res = try c.h(ctx.arena, std.testing.io, try testArgs(ctx.arena, c.json));
        if (!res.is_error) std.debug.print("not rejected: {s}\n", .{c.json});
        try std.testing.expect(res.is_error);
    }
    try std.testing.expectEqual(@as(usize, 0), fake_calls);
}

test "no dangerous tools are exposed" {
    for (tool_table) |t| {
        for ([_][]const u8{ "push", "force", "clean", "fetch", "pull", "rebase", "config" }) |w| {
            try std.testing.expect(std.mem.indexOf(u8, t.name, w) == null);
        }
    }
    try std.testing.expectEqual(@as(usize, 12), tool_table.len);
}

test "output: truncation, utf8 sanitising and empty messages" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();

    const big = try ctx.arena.alloc(u8, MAX_OUTPUT_BYTES + 1000);
    @memset(big, 'a');
    fakeOk(big, "");
    const a = try testArgs(ctx.arena,
        \\{"repo_path": "/r"}
    );
    const res = try handleStatus(ctx.arena, std.testing.io, a);
    try std.testing.expect(!res.is_error);
    try std.testing.expect(res.text.len < MAX_OUTPUT_BYTES + 200);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "[output truncated") != null);

    fakeOk("ok \xff\xfe bad \xc3\xa9", "");
    const r2 = try handleStatus(ctx.arena, std.testing.io, a);
    try std.testing.expect(std.unicode.utf8ValidateSlice(r2.text));
    try std.testing.expectEqualStrings("ok ?? bad \xc3\xa9", r2.text);

    fakeOk("  \n", "");
    const r3 = try handleDiffStaged(ctx.arena, std.testing.io, a);
    try std.testing.expectEqualStrings("(no staged changes)", r3.text);
}

test "errors: non-zero exit, missing binary, oversized capture" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    const a = try testArgs(ctx.arena,
        \\{"repo_path": "/r"}
    );

    fake_result = .{ .term = .{ .exited = 128 }, .stdout = @constCast(""), .stderr = @constCast("fatal: not a git repository\n") };
    const r1 = try handleStatus(ctx.arena, std.testing.io, a);
    try std.testing.expect(r1.is_error);
    try std.testing.expectEqualStrings("git status failed with exit code 128: fatal: not a git repository", r1.text);

    fake_error = error.ExecutableNotFound;
    const r2 = try handleStatus(ctx.arena, std.testing.io, a);
    try std.testing.expect(r2.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r2.text, "not found") != null);

    fake_error = error.StreamTooLong;
    const r3 = try handleStatus(ctx.arena, std.testing.io, a);
    try std.testing.expect(r3.is_error);
}

// ---------------------------------------------------------------------------
// Integration test against a real temp repository (skipped when git absent)
// ---------------------------------------------------------------------------

fn gitAvailable(alloc: std.mem.Allocator, io: Io) bool {
    setExecForTesting(execReal);
    const r = execReal(alloc, io, &.{ "git", "--version" }) catch return false;
    alloc.free(r.stdout);
    alloc.free(r.stderr);
    return switch (r.term) {
        .exited => |c| c == 0,
        else => false,
    };
}

fn setup(arena: std.mem.Allocator, io: Io, repo: []const u8, rest: []const []const u8) !void {
    const argv = try gitArgv(arena, repo, rest);
    const r = try execReal(arena, io, argv);
    switch (r.term) {
        .exited => |c| if (c == 0) return,
        else => {},
    }
    std.debug.print("setup failed: {s}\n", .{r.stderr});
    return error.SetupFailed;
}

const Extra = struct { []const u8, std.json.Value };

fn callWith(arena: std.mem.Allocator, h: mcp.ToolHandler, repo: []const u8, extra: []const Extra) !mcp.ToolResult {
    var map: std.json.ObjectMap = .empty;
    try map.put(arena, "repo_path", .{ .string = repo });
    for (extra) |kv| try map.put(arena, kv[0], kv[1]);
    return h(arena, std.testing.io, .{ .object = map });
}

test "integration: full workflow against a temp git repo" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    if (!gitAvailable(alloc, io)) {
        std.debug.print("skipping integration test: git not found on PATH\n", .{});
        return;
    }
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const repo = try arena.dupe(u8, path_buf[0..n]);

    try setup(arena, io, repo, &.{ "init", "-q" });
    try setup(arena, io, repo, &.{ "config", "user.name", "Test" });
    try setup(arena, io, repo, &.{ "config", "user.email", "t@example.com" });
    try setup(arena, io, repo, &.{ "config", "commit.gpgsign", "false" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one\n" });

    // status shows the untracked file
    var r = try callWith(arena, handleStatus, repo, &.{});
    try std.testing.expect(!r.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "a.txt") != null);

    // add + staged diff
    var files: std.json.Array = .init(arena);
    try files.append(.{ .string = "a.txt" });
    r = try callWith(arena, handleAdd, repo, &.{.{ "files", .{ .array = files } }});
    try std.testing.expect(!r.is_error);
    r = try callWith(arena, handleDiffStaged, repo, &.{});
    try std.testing.expect(std.mem.indexOf(u8, r.text, "+one") != null);

    // reset unstages
    r = try callWith(arena, handleReset, repo, &.{});
    try std.testing.expect(!r.is_error);
    r = try callWith(arena, handleDiffStaged, repo, &.{});
    try std.testing.expectEqualStrings("(no staged changes)", r.text);

    // add again + commit
    r = try callWith(arena, handleAdd, repo, &.{.{ "files", .{ .array = files } }});
    try std.testing.expect(!r.is_error);
    r = try callWith(arena, handleCommit, repo, &.{.{ "message", .{ .string = "first commit" } }});
    try std.testing.expect(!r.is_error);

    // log
    r = try callWith(arena, handleLog, repo, &.{.{ "max_count", .{ .integer = 5 } }});
    try std.testing.expect(!r.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "first commit") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "Test <t@example.com>") != null);

    // show HEAD
    r = try callWith(arena, handleShow, repo, &.{.{ "revision", .{ .string = "HEAD" } }});
    try std.testing.expect(!r.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "+one") != null);

    // unstaged diff after modifying the file; git_diff against HEAD
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one\ntwo\n" });
    r = try callWith(arena, handleDiffUnstaged, repo, &.{});
    try std.testing.expect(std.mem.indexOf(u8, r.text, "+two") != null);
    r = try callWith(arena, handleDiff, repo, &.{.{ "target", .{ .string = "HEAD" } }});
    try std.testing.expect(std.mem.indexOf(u8, r.text, "+two") != null);

    // branches
    r = try callWith(arena, handleCreateBranch, repo, &.{.{ "branch_name", .{ .string = "feature" } }});
    try std.testing.expect(!r.is_error);
    r = try callWith(arena, handleBranch, repo, &.{});
    try std.testing.expect(std.mem.indexOf(u8, r.text, "* feature") != null);
    r = try callWith(arena, handleCheckout, repo, &.{.{ "branch_name", .{ .string = "feature" } }});
    try std.testing.expect(!r.is_error);
    r = try callWith(arena, handleCheckout, repo, &.{.{ "branch_name", .{ .string = "does-not-exist" } }});
    try std.testing.expect(r.is_error);

    // injection attempt against a real repo leaves no side effect file
    r = try callWith(arena, handleDiff, repo, &.{.{ "target", .{ .string = "--output=pwned.txt" } }});
    try std.testing.expect(r.is_error);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "pwned.txt", .{}));

    // a non-repo path yields a clean tool error
    r = try callWith(arena, handleStatus, "/definitely/not/a/repo", &.{});
    try std.testing.expect(r.is_error);
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
