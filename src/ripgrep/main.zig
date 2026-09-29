//! zmcp-ripgrep — MCP server wrapping the local `rg` (ripgrep) CLI.
//! No shell is involved: rg is spawned with an argv array only. rg is resolved
//! via PATH.
//!
//! Tools:
//!   rg_search(pattern, path?, glob?, fixed_strings?, ignore_case?, context?, max_count?, hidden?, max_results?)
//!       rg --json ... -e <pattern> -- <path>   -> compact `file:line:text` (context lines as `file-line-text`)
//!   rg_files(path?, glob?, hidden?, max_results?)
//!       rg --files ... -- <path>
//!   rg_count(pattern, path?, glob?, fixed_strings?, ignore_case?, hidden?, max_results?)
//!       rg --count --with-filename ... -e <pattern> -- <path>
//!
//! Safety: the pattern is always passed as the value of `-e`, the glob as a
//! single `--glob=<value>` argument, and the path after `--`, so none of them
//! can ever be interpreted as a flag. `--no-config` keeps output deterministic.
//! Output is capped both in result count and in bytes.

const std = @import("std");
const mcp = @import("mcp");


const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    const io = init.io;
    try mcp.run(arena, io, .{ .name = "zmcp-ripgrep", .version = "0.1.0" }, &tool_table);
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "rg_search",
        .read_only = true,
        .description = "Search file contents with ripgrep (regex by default). Returns compact `file:line:text` lines (context lines as `file-line-text`). Respects .gitignore; set hidden=true to include dotfiles. max_count limits matches per file; max_results limits total matches returned. Output is size-capped.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "pattern":       { "type": "string", "description": "Regex (or literal if fixed_strings) to search for" },
        \\    "path":          { "type": "string", "default": ".", "description": "File or directory to search (default: current directory)" },
        \\    "glob":          { "type": "string", "description": "Only search files matching this glob, e.g. '*.zig' or '!vendor/**'" },
        \\    "fixed_strings": { "type": "boolean", "default": false, "description": "Treat pattern as a literal string" },
        \\    "ignore_case":   { "type": "boolean", "default": false, "description": "Case-insensitive search" },
        \\    "context":       { "type": "integer", "default": 0, "description": "Lines of context before and after each match (0-20)" },
        \\    "max_count":     { "type": "integer", "default": 0, "description": "Max matches per file (0 = unlimited)" },
        \\    "hidden":        { "type": "boolean", "default": false, "description": "Search hidden files and directories" },
        \\    "max_results":   { "type": "integer", "default": 200, "description": "Max total matches returned (hard cap 2000)" }
        \\  },
        \\  "required": ["pattern"]
        \\}
        ,
        .handler = handleSearch,
    },
    .{
        .name = "rg_files",
        .read_only = true,
        .description = "List files that ripgrep would search (respects .gitignore), optionally filtered by glob. One path per line, size-capped.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "path":        { "type": "string", "default": ".", "description": "Directory to list (default: current directory)" },
        \\    "glob":        { "type": "string", "description": "Only list files matching this glob, e.g. '*.zig'" },
        \\    "hidden":      { "type": "boolean", "default": false, "description": "Include hidden files" },
        \\    "max_results": { "type": "integer", "default": 1000, "description": "Max files returned (hard cap 5000)" }
        \\  }
        \\}
        ,
        .handler = handleFiles,
    },
    .{
        .name = "rg_count",
        .read_only = true,
        .description = "Count matching lines per file with ripgrep. Returns `file:count` lines plus a total, size-capped.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "pattern":       { "type": "string", "description": "Regex (or literal if fixed_strings) to count" },
        \\    "path":          { "type": "string", "default": ".", "description": "File or directory to search (default: current directory)" },
        \\    "glob":          { "type": "string", "description": "Only search files matching this glob" },
        \\    "fixed_strings": { "type": "boolean", "default": false, "description": "Treat pattern as a literal string" },
        \\    "ignore_case":   { "type": "boolean", "default": false, "description": "Case-insensitive search" },
        \\    "hidden":        { "type": "boolean", "default": false, "description": "Search hidden files and directories" },
        \\    "max_results":   { "type": "integer", "default": 1000, "description": "Max files listed (hard cap 5000); total still counts all" }
        \\  },
        \\  "required": ["pattern"]
        \\}
        ,
        .handler = handleCount,
    },
};

// ---------------------------------------------------------------------------
// Limits
// ---------------------------------------------------------------------------

const max_output_bytes: usize = 64 * 1024; // returned text cap
const max_line_chars: usize = 300; // per matched line text cap
const max_child_stdout: usize = 8 * 1024 * 1024; // stop reading rg after this
const max_child_stderr: usize = 1024 * 1024;
const default_search_results: usize = 200;
const hard_search_results: usize = 2000;
const default_list_results: usize = 1000;
const hard_list_results: usize = 5000;
const max_context: i64 = 20;

const missing_binary_msg = "Command 'rg' not found. Please install ripgrep (https://github.com/BurntSushi/ripgrep) and ensure it is in PATH.";

// ---------------------------------------------------------------------------
// Process-execution seam (injectable for offline unit tests)
// ---------------------------------------------------------------------------

pub const ExecResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    /// True if stdout was cut off at max_child_stdout and rg was killed.
    truncated: bool = false,
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

// ---------------------------------------------------------------------------
// Argument helpers
// ---------------------------------------------------------------------------

fn getStr(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn getBool(args: std.json.Value, key: []const u8) bool {
    if (args != .object) return false;
    const v = args.object.get(key) orelse return false;
    return v == .bool and v.bool;
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

fn limitArg(args: std.json.Value, default: usize, hard: usize) usize {
    const raw = getInt(args, "max_results") orelse return default;
    if (raw <= 0) return default;
    return @min(@as(usize, @intCast(raw)), hard);
}

fn errResult(text: []const u8) mcp.ToolResult {
    return .{ .text = text, .is_error = true };
}

// ---------------------------------------------------------------------------
// argv builders (pure)
// ---------------------------------------------------------------------------

const Opts = struct {
    pattern: ?[]const u8 = null,
    path: []const u8 = ".",
    glob: ?[]const u8 = null,
    fixed_strings: bool = false,
    ignore_case: bool = false,
    context: usize = 0,
    max_count: usize = 0,
    hidden: bool = false,
};

const Mode = enum { search, files, count };

/// Builds `rg <mode flags> <options> [-e pattern] -- <path>`. The glob goes in
/// as one `--glob=<v>` argument; the pattern as the value of `-e`; the path
/// after `--`. Nothing user-supplied can therefore become a flag.
fn buildArgv(alloc: std.mem.Allocator, mode: Mode, o: Opts) ![][]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(alloc);
    try argv.append(alloc, "rg");
    try argv.append(alloc, "--no-config");
    switch (mode) {
        .search => {
            try argv.append(alloc, "--json");
        },
        .files => try argv.append(alloc, "--files"),
        .count => {
            try argv.append(alloc, "--count");
            try argv.append(alloc, "--with-filename");
            try argv.append(alloc, "--no-heading");
        },
    }
    if (o.hidden) try argv.append(alloc, "--hidden");
    if (o.glob) |g| try argv.append(alloc, try std.fmt.allocPrint(alloc, "--glob={s}", .{g}));
    if (mode != .files) {
        if (o.fixed_strings) try argv.append(alloc, "--fixed-strings");
        if (o.ignore_case) try argv.append(alloc, "--ignore-case");
    }
    if (mode == .search) {
        if (o.context > 0) try argv.append(alloc, try std.fmt.allocPrint(alloc, "--context={d}", .{o.context}));
        if (o.max_count > 0) try argv.append(alloc, try std.fmt.allocPrint(alloc, "--max-count={d}", .{o.max_count}));
    }
    if (mode != .files) {
        try argv.append(alloc, "-e");
        try argv.append(alloc, o.pattern orelse "");
    }
    try argv.append(alloc, "--");
    try argv.append(alloc, o.path);
    return argv.toOwnedSlice(alloc);
}

fn optsFromArgs(args: std.json.Value) Opts {
    var o: Opts = .{};
    o.pattern = getStr(args, "pattern");
    if (getStr(args, "path")) |p| {
        if (p.len > 0) o.path = p;
    }
    if (getStr(args, "glob")) |g| {
        if (g.len > 0) o.glob = g;
    }
    o.fixed_strings = getBool(args, "fixed_strings");
    o.ignore_case = getBool(args, "ignore_case");
    o.hidden = getBool(args, "hidden");
    if (getInt(args, "context")) |c| o.context = @intCast(std.math.clamp(c, 0, max_context));
    if (getInt(args, "max_count")) |m| o.max_count = @intCast(@max(m, 0));
    return o;
}

// ---------------------------------------------------------------------------
// Output shaping (pure)
// ---------------------------------------------------------------------------

fn argvRepr(alloc: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeByte('[');
    for (argv, 0..) |a, i| {
        if (i > 0) try out.writer.writeAll(", ");
        try out.writer.print("'{s}'", .{a});
    }
    try out.writer.writeByte(']');
    return out.toOwnedSlice();
}

/// Longest prefix of s that is <= max bytes and ends on a UTF-8 boundary.
fn utf8Prefix(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

fn jGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

/// {"text": "..."} -> text, {"bytes": ...} -> null.
fn textField(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    const t = jGet(x, "text") orelse return null;
    return if (t == .string) t.string else null;
}

const SearchShape = struct {
    text: []u8,
    matches: usize,
    truncated: bool,
};

/// Parses `rg --json` output into compact lines. Stops once max_matches
/// match lines or max_bytes of text were produced.
fn shapeSearch(
    alloc: std.mem.Allocator,
    stdout: []const u8,
    max_matches: usize,
    max_bytes: usize,
) !SearchShape {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var matches: usize = 0;
    var total_matches_seen: usize = 0;
    var truncated = false;

    var it = std.mem.splitScalar(u8, stdout, '\n');
    lines: while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] != '{') continue;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer parsed.deinit();
        const root = parsed.value;
        const ty_v = jGet(root, "type") orelse continue;
        if (ty_v != .string) continue;
        const is_match = std.mem.eql(u8, ty_v.string, "match");
        const is_ctx = std.mem.eql(u8, ty_v.string, "context");
        if (!is_match and !is_ctx) continue;
        const data = jGet(root, "data") orelse continue;

        if (is_match) {
            total_matches_seen += 1;
            if (matches >= max_matches) {
                truncated = true;
                break :lines;
            }
        }
        const path = textField(jGet(data, "path")) orelse "<non-utf8 path>";
        const lnum: i64 = if (jGet(data, "line_number")) |n| (if (n == .integer) n.integer else 0) else 0;
        const raw_text = textField(jGet(data, "lines")) orelse "<non-utf8 line>";
        var text = std.mem.trimEnd(u8, raw_text, "\r\n");
        var cut = false;
        if (text.len > max_line_chars) {
            text = utf8Prefix(text, max_line_chars);
            cut = true;
        }
        const sep: u8 = if (is_match) ':' else '-';
        const before = out.written().len;
        try out.writer.print("{s}{c}{d}{c}{s}{s}\n", .{ path, sep, lnum, sep, text, if (cut) " [...]" else "" });
        if (out.written().len > max_bytes) {
            // Roll back the line that overflowed the byte cap.
            out.writer.end = before;
            truncated = true;
            break :lines;
        }
        if (is_match) matches += 1;
    }

    const body = std.mem.trimEnd(u8, out.written(), "\n");
    var res: std.Io.Writer.Allocating = .init(alloc);
    defer res.deinit();
    if (matches == 0) {
        try res.writer.writeAll("No matches found");
    } else {
        try res.writer.print("{s}\n\n{d} match(es) shown", .{ body, matches });
        if (truncated) try res.writer.writeAll(" (output truncated; narrow the pattern/path/glob or raise limits)");
    }
    return .{ .text = try res.toOwnedSlice(), .matches = matches, .truncated = truncated };
}

/// Shapes `--files` output (one path per line), capped by count and bytes.
fn shapeFiles(alloc: std.mem.Allocator, stdout: []const u8, max_files: usize, max_bytes: usize, child_truncated: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var shown: usize = 0;
    var total: usize = 0;
    var bytes_full = false;
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        total += 1;
        if (bytes_full or shown >= max_files) continue;
        if (out.written().len + line.len + 1 > max_bytes) {
            bytes_full = true;
            continue;
        }
        try out.writer.print("{s}\n", .{line});
        shown += 1;
    }
    if (total == 0) return alloc.dupe(u8, "No files found");
    var res: std.Io.Writer.Allocating = .init(alloc);
    defer res.deinit();
    try res.writer.print("{s}\n{d} file(s) shown", .{ std.mem.trimEnd(u8, out.written(), "\n"), shown });
    if (total > shown or child_truncated) try res.writer.print(" of at least {d} (truncated)", .{total});
    return res.toOwnedSlice();
}

/// Shapes `--count --with-filename` output (`path:count` per line).
fn shapeCount(alloc: std.mem.Allocator, stdout: []const u8, max_files: usize, max_bytes: usize, child_truncated: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var shown: usize = 0;
    var files: usize = 0;
    var total: u64 = 0;
    var bytes_full = false;
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        // Paths may contain ':'; the count is after the LAST colon.
        const colon = std.mem.lastIndexOfScalar(u8, line, ':') orelse continue;
        const n = std.fmt.parseInt(u64, line[colon + 1 ..], 10) catch continue;
        files += 1;
        total += n;
        if (bytes_full or shown >= max_files) continue;
        if (out.written().len + line.len + 1 > max_bytes) {
            bytes_full = true;
            continue;
        }
        try out.writer.print("{s}\n", .{line});
        shown += 1;
    }
    if (files == 0) return alloc.dupe(u8, "No matches found");
    var res: std.Io.Writer.Allocating = .init(alloc);
    defer res.deinit();
    try res.writer.print("{s}\n\nTotal: {d} matching line(s) in {d} file(s)", .{ std.mem.trimEnd(u8, out.written(), "\n"), total, files });
    if (files > shown) try res.writer.print(" (showing {d} files)", .{shown});
    if (child_truncated) try res.writer.writeAll(" (rg output truncated; totals are lower bounds)");
    return res.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Runner + handlers
// ---------------------------------------------------------------------------

const RunOutcome = union(enum) { ok: ExecResult, err: mcp.ToolResult };

/// Runs rg. Exit 0 = matches, 1 = no matches (both fine). Exit 2 is an error,
/// unless rg produced output (partial results, e.g. permission denied on one
/// file); in that case stderr is appended by the caller via `warn`.
fn runRg(alloc: std.mem.Allocator, io: Io, argv: []const []const u8) !RunOutcome {
    const result = exec_fn(alloc, io, argv) catch |err| switch (err) {
        error.ExecutableNotFound => return .{ .err = errResult(missing_binary_msg) },
        else => return .{ .err = errResult(try std.fmt.allocPrint(alloc, "rg execution failed: {s}", .{@errorName(err)})) },
    };
    switch (result.term) {
        .exited => |code| {
            if (code == 0 or code == 1) return .{ .ok = result };
            if (code == 2 and std.mem.trim(u8, result.stdout, " \t\r\n").len > 0) return .{ .ok = result };
            const stderr_trim = std.mem.trim(u8, result.stderr, " \t\r\n");
            const detail = if (stderr_trim.len > 0) stderr_trim else "(no error output)";
            const repr = try argvRepr(alloc, argv);
            return .{ .err = errResult(try std.fmt.allocPrint(alloc, "Command {s} failed with exit code {d}: {s}", .{ repr, code, detail })) };
        },
        else => {
            const repr = try argvRepr(alloc, argv);
            return .{ .err = errResult(try std.fmt.allocPrint(alloc, "Command {s} failed: process terminated abnormally", .{repr})) };
        },
    }
}

/// Append a short note when rg exited 2 but still produced results.
fn withWarning(alloc: std.mem.Allocator, text: []u8, result: ExecResult) ![]const u8 {
    if (result.term != .exited or result.term.exited != 2) return text;
    const s = std.mem.trim(u8, result.stderr, " \t\r\n");
    if (s.len == 0) return text;
    return std.fmt.allocPrint(alloc, "{s}\n\nrg warnings:\n{s}", .{ text, utf8Prefix(s, 2048) });
}

fn handleSearch(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const opts = optsFromArgs(args);
    const pattern = opts.pattern orelse return errResult("error: pattern is required");
    if (pattern.len == 0) return errResult("error: pattern must not be empty");
    const max_results = limitArg(args, default_search_results, hard_search_results);

    const argv = try buildArgv(alloc, .search, opts);
    switch (try runRg(alloc, io, argv)) {
        .err => |e| return e,
        .ok => |result| {
            const shape = try shapeSearch(alloc, result.stdout, max_results, max_output_bytes);
            var text: []const u8 = shape.text;
            if (result.truncated) text = try std.fmt.allocPrint(alloc, "{s}\n(rg output exceeded {d} bytes and was cut off)", .{ text, max_child_stdout });
            return .{ .text = try withWarning(alloc, @constCast(text), result) };
        },
    }
}

fn handleFiles(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const opts = optsFromArgs(args);
    const max_results = limitArg(args, default_list_results, hard_list_results);
    const argv = try buildArgv(alloc, .files, opts);
    switch (try runRg(alloc, io, argv)) {
        .err => |e| return e,
        .ok => |result| {
            const text = try shapeFiles(alloc, result.stdout, max_results, max_output_bytes, result.truncated);
            return .{ .text = try withWarning(alloc, text, result) };
        },
    }
}

fn handleCount(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const opts = optsFromArgs(args);
    const pattern = opts.pattern orelse return errResult("error: pattern is required");
    if (pattern.len == 0) return errResult("error: pattern must not be empty");
    const max_results = limitArg(args, default_list_results, hard_list_results);
    const argv = try buildArgv(alloc, .count, opts);
    switch (try runRg(alloc, io, argv)) {
        .err => |e| return e,
        .ok => |result| {
            const text = try shapeCount(alloc, result.stdout, max_results, max_output_bytes, result.truncated);
            return .{ .text = try withWarning(alloc, text, result) };
        },
    }
}

// ---------------------------------------------------------------------------
// Real process execution
// ---------------------------------------------------------------------------

fn execReal(alloc: std.mem.Allocator, io: Io, argv: []const []const u8) !ExecResult {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.ExecutableNotFound,
        else => return err,
    };
    defer child.kill(io);

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(alloc, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    var truncated = false;
    while (multi_reader.fill(64, .none)) |_| {
        if (stdout_reader.buffered().len > max_child_stdout) {
            truncated = true;
            break;
        }
        if (stderr_reader.buffered().len > max_child_stderr) break;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }

    if (truncated) {
        // Keep whole lines only, then stop rg; a partial result is still useful.
        const buffered = stdout_reader.buffered();
        const keep = if (std.mem.lastIndexOfScalar(u8, buffered, '\n')) |i| i + 1 else buffered.len;
        const out_copy = try alloc.dupe(u8, buffered[0..keep]);
        const err_copy = try alloc.dupe(u8, stderr_reader.buffered());
        child.kill(io);
        return .{ .term = .{ .exited = 0 }, .stdout = out_copy, .stderr = err_copy, .truncated = true };
    }

    try multi_reader.checkAnyError();
    const term = try child.wait(io);
    return .{
        .term = term,
        .stdout = try multi_reader.toOwnedSlice(0),
        .stderr = try multi_reader.toOwnedSlice(1),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

var fake_argv: []const []const u8 = &.{};
var fake_result: ExecResult = .{ .term = .{ .exited = 0 }, .stdout = @constCast(""), .stderr = @constCast("") };
var fake_error: ?anyerror = null;

fn fakeExec(alloc: std.mem.Allocator, io: Io, argv: []const []const u8) !ExecResult {
    _ = alloc;
    _ = io;
    fake_argv = argv;
    if (fake_error) |e| return e;
    return fake_result;
}

fn fakeOk(stdout: []const u8, stderr: []const u8) void {
    fake_result = .{ .term = .{ .exited = 0 }, .stdout = @constCast(stdout), .stderr = @constCast(stderr) };
    fake_error = null;
}

fn fakeExit(code: u8, stdout: []const u8, stderr: []const u8) void {
    fake_result = .{ .term = .{ .exited = code }, .stdout = @constCast(stdout), .stderr = @constCast(stderr) };
    fake_error = null;
}

fn testArgs(arena: std.mem.Allocator, json: []const u8) !std.json.Value {
    const p = try std.json.parseFromSlice(std.json.Value, arena, json, .{});
    return p.value;
}

const TestCtx = struct {
    arena_state: std.heap.ArenaAllocator,
    arena: std.mem.Allocator,

    fn init(ctx: *TestCtx) void {
        ctx.arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        ctx.arena = ctx.arena_state.allocator();
        setExecForTesting(fakeExec);
        fake_argv = &.{};
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

const json_match_1 =
    \\{"type":"match","data":{"path":{"text":"src/a.zig"},"lines":{"text":"const foo = 1;\n"},"line_number":3,"absolute_offset":10,"submatches":[]}}
;
const json_ctx_1 =
    \\{"type":"context","data":{"path":{"text":"src/a.zig"},"lines":{"text":"// before\n"},"line_number":2,"absolute_offset":0,"submatches":[]}}
;
const json_match_2 =
    \\{"type":"match","data":{"path":{"text":"src/b.zig"},"lines":{"text":"foo();\r\n"},"line_number":9,"absolute_offset":0,"submatches":[]}}
;
const json_begin =
    \\{"type":"begin","data":{"path":{"text":"src/a.zig"}}}
;
const json_summary =
    \\{"type":"summary","data":{"elapsed_total":{"secs":0,"nanos":1,"human":"0s"},"stats":{}}}
;

test "argv: search builds flags, -e pattern and -- path" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();

    const args = try testArgs(ctx.arena,
        \\{"pattern":"foo.*bar","path":"src","glob":"*.zig","fixed_strings":true,"ignore_case":true,"context":2,"max_count":5,"hidden":true}
    );
    const res = try handleSearch(ctx.arena, std.testing.io, args);
    try std.testing.expect(!res.is_error);
    try expectArgv(&.{
        "rg",              "--no-config",   "--json",     "--hidden",
        "--glob=*.zig",    "--fixed-strings", "--ignore-case", "--context=2",
        "--max-count=5",   "-e",            "foo.*bar",   "--",
        "src",
    });
}

test "argv: defaults to path . and minimal flags" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    const args = try testArgs(ctx.arena,
        \\{"pattern":"x"}
    );
    _ = try handleSearch(ctx.arena, std.testing.io, args);
    try expectArgv(&.{ "rg", "--no-config", "--json", "-e", "x", "--", "." });
}

test "argv: dash-leading pattern, glob and path cannot become flags" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    const args = try testArgs(ctx.arena,
        \\{"pattern":"--files","path":"--hidden","glob":"--no-ignore"}
    );
    _ = try handleSearch(ctx.arena, std.testing.io, args);
    try expectArgv(&.{ "rg", "--no-config", "--json", "--glob=--no-ignore", "-e", "--files", "--", "--hidden" });

    _ = try handleCount(ctx.arena, std.testing.io, args);
    try expectArgv(&.{ "rg", "--no-config", "--count", "--with-filename", "--no-heading", "--glob=--no-ignore", "-e", "--files", "--", "--hidden" });
}

test "argv: files and count modes" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    const f = try testArgs(ctx.arena,
        \\{"path":"/proj","glob":"*.md","hidden":true,"pattern":"ignored","ignore_case":true}
    );
    _ = try handleFiles(ctx.arena, std.testing.io, f);
    try expectArgv(&.{ "rg", "--no-config", "--files", "--hidden", "--glob=*.md", "--", "/proj" });

    const c = try testArgs(ctx.arena,
        \\{"pattern":"TODO","ignore_case":true,"fixed_strings":true,"context":9,"max_count":3}
    );
    _ = try handleCount(ctx.arena, std.testing.io, c);
    try expectArgv(&.{ "rg", "--no-config", "--count", "--with-filename", "--no-heading", "--fixed-strings", "--ignore-case", "-e", "TODO", "--", "." });
}

test "argv: context clamped, negative max_count ignored" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    const args = try testArgs(ctx.arena,
        \\{"pattern":"x","context":9999,"max_count":-4}
    );
    _ = try handleSearch(ctx.arena, std.testing.io, args);
    try expectArgv(&.{ "rg", "--no-config", "--json", "--context=20", "-e", "x", "--", "." });
}

test "search: missing and empty pattern are tool errors" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    const a = try testArgs(ctx.arena, "{}");
    try std.testing.expect((try handleSearch(ctx.arena, std.testing.io, a)).is_error);
    try std.testing.expect((try handleCount(ctx.arena, std.testing.io, a)).is_error);
    const b = try testArgs(ctx.arena,
        \\{"pattern":""}
    );
    try std.testing.expect((try handleSearch(ctx.arena, std.testing.io, b)).is_error);
    try std.testing.expectEqual(@as(usize, 0), fake_argv.len);
}

test "shapeSearch: compact match and context lines, ignores begin/end/summary" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    const stdout = json_begin ++ "\n" ++ json_ctx_1 ++ "\n" ++ json_match_1 ++ "\n" ++ json_match_2 ++ "\n" ++ json_summary ++ "\n";
    const s = try shapeSearch(ctx.arena, stdout, 100, 10000);
    try std.testing.expectEqual(@as(usize, 2), s.matches);
    try std.testing.expect(!s.truncated);
    try std.testing.expectEqualStrings(
        "src/a.zig-2-// before\nsrc/a.zig:3:const foo = 1;\nsrc/b.zig:9:foo();\n\n2 match(es) shown",
        s.text,
    );
}

test "shapeSearch: caps match count and reports truncation" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    const stdout = json_match_1 ++ "\n" ++ json_match_2 ++ "\n" ++ json_match_1 ++ "\n";
    const s = try shapeSearch(ctx.arena, stdout, 2, 10000);
    try std.testing.expectEqual(@as(usize, 2), s.matches);
    try std.testing.expect(s.truncated);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "truncated") != null);
}

test "shapeSearch: caps output bytes" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    const stdout = json_match_1 ++ "\n" ++ json_match_2 ++ "\n";
    // First line is "src/a.zig:3:const foo = 1;\n" = 27 bytes; second would overflow 40.
    const s = try shapeSearch(ctx.arena, stdout, 100, 40);
    try std.testing.expectEqual(@as(usize, 1), s.matches);
    try std.testing.expect(s.truncated);
    try std.testing.expect(std.mem.startsWith(u8, s.text, "src/a.zig:3:const foo = 1;\n\n1 match(es)"));
}

test "shapeSearch: long lines are cut on a utf8 boundary; binary lines and junk are tolerated" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    const long = try std.fmt.allocPrint(ctx.arena,
        \\{{"type":"match","data":{{"path":{{"text":"l.txt"}},"lines":{{"text":"{s}\n"}},"line_number":1}}}}
    , .{"é" ** 400});
    const bin =
        \\{"type":"match","data":{"path":{"bytes":"AAAA"},"lines":{"bytes":"AAAA"},"line_number":7}}
    ;
    const stdout = try std.fmt.allocPrint(ctx.arena, "garbage\n{{not json}}\n{s}\n{s}\n", .{ long, bin });
    const s = try shapeSearch(ctx.arena, stdout, 10, 100000);
    try std.testing.expectEqual(@as(usize, 2), s.matches);
    try std.testing.expect(std.unicode.utf8ValidateSlice(s.text));
    try std.testing.expect(std.mem.indexOf(u8, s.text, " [...]") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "<non-utf8 path>:7:<non-utf8 line>") != null);
}

test "shapeSearch: no matches" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    const s = try shapeSearch(ctx.arena, json_summary ++ "\n", 10, 1000);
    try std.testing.expectEqualStrings("No matches found", s.text);
}

test "shapeFiles: lists, caps count and reports total" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    const t = try shapeFiles(ctx.arena, "a.zig\nb.zig\nc.zig\n", 2, 1000, false);
    try std.testing.expectEqualStrings("a.zig\nb.zig\n2 file(s) shown of at least 3 (truncated)", t);
    const t2 = try shapeFiles(ctx.arena, "a.zig\n", 10, 1000, false);
    try std.testing.expectEqualStrings("a.zig\n1 file(s) shown", t2);
    const t3 = try shapeFiles(ctx.arena, "", 10, 1000, false);
    try std.testing.expectEqualStrings("No files found", t3);
    // byte cap
    const t4 = try shapeFiles(ctx.arena, "aaaaaaaaaa\nbbbbbbbbbb\n", 10, 12, false);
    try std.testing.expect(std.mem.startsWith(u8, t4, "aaaaaaaaaa\n1 file(s) shown"));
    try std.testing.expect(std.mem.indexOf(u8, t4, "truncated") != null);
}

test "shapeCount: totals, colons in paths, junk lines" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    const t = try shapeCount(ctx.arena, "a.zig:3\nweird:name.txt:4\nnot a count\n", 10, 1000, false);
    try std.testing.expectEqualStrings("a.zig:3\nweird:name.txt:4\n\nTotal: 7 matching line(s) in 2 file(s)", t);
    const t2 = try shapeCount(ctx.arena, "a:1\nb:2\nc:3\n", 1, 1000, false);
    try std.testing.expect(std.mem.indexOf(u8, t2, "Total: 6 matching line(s) in 3 file(s) (showing 1 files)") != null);
    const t3 = try shapeCount(ctx.arena, "", 10, 1000, false);
    try std.testing.expectEqualStrings("No matches found", t3);
}

test "handler: search end-to-end via fake exec, max_results honoured" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fakeOk(json_match_1 ++ "\n" ++ json_match_2 ++ "\n", "");
    const args = try testArgs(ctx.arena,
        \\{"pattern":"foo","max_results":1}
    );
    const res = try handleSearch(ctx.arena, std.testing.io, args);
    try std.testing.expect(!res.is_error);
    try std.testing.expect(std.mem.startsWith(u8, res.text, "src/a.zig:3:const foo = 1;"));
    try std.testing.expect(std.mem.indexOf(u8, res.text, "src/b.zig") == null);
}

test "exit codes: 1 is no matches; 2 is error unless partial output" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    const args = try testArgs(ctx.arena,
        \\{"pattern":"x"}
    );

    fakeExit(1, "", "");
    const r1 = try handleSearch(ctx.arena, std.testing.io, args);
    try std.testing.expect(!r1.is_error);
    try std.testing.expectEqualStrings("No matches found", r1.text);

    fakeExit(2, "", "regex parse error:\n    (\n    ^\nerror: unclosed group\n");
    const r2 = try handleSearch(ctx.arena, std.testing.io, args);
    try std.testing.expect(r2.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r2.text, "failed with exit code 2: regex parse error") != null);

    fakeExit(2, json_match_1 ++ "\n", "x/y: Permission denied (os error 13)\n");
    const r3 = try handleSearch(ctx.arena, std.testing.io, args);
    try std.testing.expect(!r3.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r3.text, "rg warnings:\nx/y: Permission denied") != null);

    fake_result = .{ .term = .{ .unknown = 9 }, .stdout = @constCast(""), .stderr = @constCast("") };
    const r4 = try handleSearch(ctx.arena, std.testing.io, args);
    try std.testing.expect(r4.is_error);
}

test "missing rg binary maps to a clear tool error for all tools" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fake_error = error.ExecutableNotFound;
    const args = try testArgs(ctx.arena,
        \\{"pattern":"x"}
    );
    inline for (.{ handleSearch, handleFiles, handleCount }) |h| {
        const res = try h(ctx.arena, std.testing.io, args);
        try std.testing.expect(res.is_error);
        try std.testing.expectEqualStrings(missing_binary_msg, res.text);
    }
}

test "utf8Prefix never splits a code point" {
    try std.testing.expectEqualStrings("a", utf8Prefix("aé", 2));
    try std.testing.expectEqualStrings("aé", utf8Prefix("aé", 3));
    try std.testing.expectEqualStrings("", utf8Prefix("é", 1));
}

// ---------------------------------------------------------------------------
// Integration tests against the real rg binary (skipped when absent)
// ---------------------------------------------------------------------------

fn rgAvailable(io: Io) bool {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const argv = [_][]const u8{ "rg", "--version" };
    _ = execReal(arena_state.allocator(), io, &argv) catch return false;
    return true;
}

test "integration: search, files and count with real rg" {
    const io = std.testing.io;
    if (!rgAvailable(io)) {
        std.debug.print("skipping integration test: rg not found on PATH\n", .{});
        return;
    }
    setExecForTesting(execReal);
    defer setExecForTesting(execReal);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "one.txt", .data = "alpha\n--files here\nBeta\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "two.md", .data = "alpha alpha\n" });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const tmp_path = try arena.dupe(u8, path_buf[0..n]);

    var map: std.json.ObjectMap = .empty;
    try map.put(arena, "pattern", .{ .string = "alpha" });
    try map.put(arena, "path", .{ .string = tmp_path });
    const args = std.json.Value{ .object = map };

    const res = try handleSearch(arena, io, args);
    try std.testing.expect(!res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "one.txt:1:alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "two.md:1:alpha alpha") != null);

    // dash-leading pattern is matched literally, not treated as a flag
    var m2: std.json.ObjectMap = .empty;
    try m2.put(arena, "pattern", .{ .string = "--files" });
    try m2.put(arena, "path", .{ .string = tmp_path });
    try m2.put(arena, "fixed_strings", .{ .bool = true });
    const r2 = try handleSearch(arena, io, .{ .object = m2 });
    try std.testing.expect(!r2.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r2.text, "one.txt:2:--files here") != null);

    // glob filter + ignore_case
    var m3: std.json.ObjectMap = .empty;
    try m3.put(arena, "pattern", .{ .string = "beta" });
    try m3.put(arena, "path", .{ .string = tmp_path });
    try m3.put(arena, "ignore_case", .{ .bool = true });
    try m3.put(arena, "glob", .{ .string = "*.txt" });
    const r3 = try handleSearch(arena, io, .{ .object = m3 });
    try std.testing.expect(std.mem.indexOf(u8, r3.text, "one.txt:3:Beta") != null);

    // files
    var m4: std.json.ObjectMap = .empty;
    try m4.put(arena, "path", .{ .string = tmp_path });
    try m4.put(arena, "glob", .{ .string = "*.md" });
    const r4 = try handleFiles(arena, io, .{ .object = m4 });
    try std.testing.expect(!r4.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r4.text, "two.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, r4.text, "one.txt") == null);

    // count
    const r5 = try handleCount(arena, io, args);
    try std.testing.expect(!r5.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r5.text, "Total: 2 matching line(s) in 2 file(s)") != null);

    // no match => not an error
    var m6: std.json.ObjectMap = .empty;
    try m6.put(arena, "pattern", .{ .string = "zzzzqqq" });
    try m6.put(arena, "path", .{ .string = tmp_path });
    const r6 = try handleSearch(arena, io, .{ .object = m6 });
    try std.testing.expect(!r6.is_error);
    try std.testing.expectEqualStrings("No matches found", r6.text);

    // invalid regex => clean error
    var m7: std.json.ObjectMap = .empty;
    try m7.put(arena, "pattern", .{ .string = "(" });
    try m7.put(arena, "path", .{ .string = tmp_path });
    const r7 = try handleSearch(arena, io, .{ .object = m7 });
    try std.testing.expect(r7.is_error);
}
