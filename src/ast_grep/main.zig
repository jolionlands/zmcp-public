//! zmcp-ast-grep — pure-Zig port of the `sg-mcp` Python MCP server.
//! Shells out to the `ast-grep` CLI (resolved via PATH, AST_GREP_BIN override).
//!
//! Tools (parity with sg-mcp main.py):
//!   dump_syntax_tree(code, language, format?)                       — ast-grep run --pattern <code> --lang <language> --debug-query=<format>
//!   test_match_code_rule(code, yaml)                                — ast-grep scan --inline-rules <yaml> --json --stdin
//!   find_code(project_folder, pattern, language?, max_results?, output_format?)      — ast-grep run --pattern <p> [--lang l] --json=stream <folder>
//!   find_code_by_rule(project_folder, yaml, max_results?, output_format?)            — ast-grep scan --inline-rules <y> --json=stream <folder>

const std = @import("std");
const builtin = @import("builtin");
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

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    g_env_io = init.io;
    const io = init.io;
    try mcp.run(arena, io, .{ .name = "zmcp-ast-grep", .version = "0.1.0" }, &tool_table);
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "dump_syntax_tree",
        .description = "Dump code's syntax structure or dump a query's pattern structure. Useful to discover correct syntax kind and syntax tree structure when debugging a rule. Use format=cst to inspect the code's concrete syntax tree, format=pattern to inspect how ast-grep interprets a pattern, format=ast for the abstract syntax tree.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "code":     { "type": "string", "description": "The code you need" },
        \\    "language": { "type": "string", "description": "The language of the code. Supported: bash, c, cpp, csharp, css, elixir, go, haskell, html, java, javascript, json, jsx, kotlin, lua, nix, php, python, ruby, rust, scala, solidity, swift, tsx, typescript, yaml" },
        \\    "format":   { "type": "string", "enum": ["pattern", "cst", "ast"], "default": "cst", "description": "Code dump format. Available values: pattern, ast, cst" }
        \\  },
        \\  "required": ["code", "language"]
        \\}
        ,
        .handler = handleDumpSyntaxTree,
        .read_only = true,
    },
    .{
        .name = "test_match_code_rule",
        .description = "Test code against an ast-grep YAML rule (the rule must have id, language, rule fields). Useful to test a rule before using it in a project. Returns the list of matches, or an error when nothing matches.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "code": { "type": "string", "description": "The code to test against the rule" },
        \\    "yaml": { "type": "string", "description": "The ast-grep YAML rule to search. It must have id, language, rule fields." }
        \\  },
        \\  "required": ["code", "yaml"]
        \\}
        ,
        .handler = handleTestMatchCodeRule,
        .read_only = true,
    },
    .{
        .name = "find_code",
        .description = "Find code in a project folder that matches the given ast-grep pattern. Pattern is good for simple, single-AST-node results; for more complex usage use find_code_by_rule. output_format 'text' (default) gives file:line-range headers with the complete match text; 'json' gives full match objects with metadata. max_results limits the number of complete matches returned (not individual lines).",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "project_folder": { "type": "string", "description": "The absolute path to the project folder. It must be absolute path." },
        \\    "pattern":        { "type": "string", "description": "The ast-grep pattern to search for. Note, the pattern must have valid AST structure." },
        \\    "language":       { "type": "string", "default": "", "description": "The language of the code. Supported: bash, c, cpp, csharp, css, elixir, go, haskell, html, java, javascript, json, jsx, kotlin, lua, nix, php, python, ruby, rust, scala, solidity, swift, tsx, typescript, yaml. If not specified, will be auto-detected based on file extensions." },
        \\    "max_results":    { "type": "integer", "default": 0, "description": "Maximum results to return" },
        \\    "output_format":  { "type": "string", "default": "text", "description": "'text' or 'json'" }
        \\  },
        \\  "required": ["project_folder", "pattern"]
        \\}
        ,
        .handler = handleFindCode,
        .read_only = true,
    },
    .{
        .name = "find_code_by_rule",
        .description = "Find code using an ast-grep YAML rule in a project folder. YAML rules are more powerful than simple patterns and can perform complex searches like finding an AST inside/having another AST. Tip: when using relational rules (inside/has), add `stopBy: end` to ensure complete traversal. Supports 'text' (default) or 'json' output; max_results limits the number of complete matches returned.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "project_folder": { "type": "string", "description": "The absolute path to the project folder. It must be absolute path." },
        \\    "yaml":           { "type": "string", "description": "The ast-grep YAML rule to search. It must have id, language, rule fields." },
        \\    "max_results":    { "type": "integer", "default": 0, "description": "Maximum results to return" },
        \\    "output_format":  { "type": "string", "default": "text", "description": "'text' or 'json'" }
        \\  },
        \\  "required": ["project_folder", "yaml"]
        \\}
        ,
        .handler = handleFindCodeByRule,
        .read_only = true,
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
    stdin_text: ?[]const u8,
) anyerror!ExecResult;

var exec_fn: ExecFn = execReal;

fn setExecForTesting(f: ExecFn) void {
    exec_fn = f;
}

const PathHit = struct {
    path: []u8,
    is_script: bool,
};

// ---------------------------------------------------------------------------
// Pure helpers (unit tested)
// ---------------------------------------------------------------------------

fn astGrepArgv(
    alloc: std.mem.Allocator,
    config: ?[]const u8,
    command: []const u8,
    rest: []const []const u8,
) ![][]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(alloc);
    try argv.append(alloc, "ast-grep");
    try argv.append(alloc, command);
    if (config) |c| {
        try argv.append(alloc, "--config");
        try argv.append(alloc, c);
    }
    try argv.appendSlice(alloc, rest);
    return argv.toOwnedSlice(alloc);
}

const Matches = struct {
    items: std.ArrayList(std.json.Value) = .empty,
    parsed: std.ArrayList(std.json.Parsed(std.json.Value)) = .empty,
    total: usize = 0,

    fn deinit(self: *Matches, alloc: std.mem.Allocator) void {
        for (self.parsed.items) |*p| p.deinit();
        self.parsed.deinit(alloc);
        self.items.deinit(alloc);
    }
};

fn parseMatches(alloc: std.mem.Allocator, stdout: []const u8, max_results: usize) !Matches {
    var out: Matches = .{};
    errdefer out.deinit(alloc);
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] != '{') continue;
        out.total += 1;
        if (max_results == 0 or out.items.items.len < max_results) {
            const p = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
            try out.parsed.append(alloc, p);
            try out.items.append(alloc, p.value);
        }
    }
    return out;
}

fn jStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn matchLine(m: std.json.Value, endpoint: []const u8) i64 {
    if (m != .object) return 0;
    const range = m.object.get("range") orelse return 0;
    if (range != .object) return 0;
    const ep = range.object.get(endpoint) orelse return 0;
    if (ep != .object) return 0;
    const line = ep.object.get("line") orelse return 0;
    return switch (line) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}

fn formatMatchesAsText(alloc: std.mem.Allocator, items: []const std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var first = true;
    for (items) |m| {
        if (m != .object) continue;
        const file = jStr(m.object, "file") orelse "";
        const start = matchLine(m, "start") + 1;
        const end = matchLine(m, "end") + 1;
        const text = std.mem.trimEnd(u8, jStr(m.object, "text") orelse "", " \t\r\n\x0b\x0c");
        if (!first) try out.writer.writeAll("\n\n");
        first = false;
        if (start == end) {
            try out.writer.print("{s}:{d}\n{s}", .{ file, start, text });
        } else {
            try out.writer.print("{s}:{d}-{d}\n{s}", .{ file, start, end, text });
        }
    }
    return out.toOwnedSlice();
}

fn shapeFindOutput(
    alloc: std.mem.Allocator,
    matches: *const Matches,
    max_results: usize,
    output_format: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, output_format, "json")) {
        var arr: std.json.Array = .init(alloc);
        for (matches.items.items) |v| try arr.append(v);
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try std.json.Stringify.value(std.json.Value{ .array = arr }, .{}, &out.writer);
        return out.toOwnedSlice();
    }
    if (matches.items.items.len == 0) return alloc.dupe(u8, "No matches found");
    const body = try formatMatchesAsText(alloc, matches.items.items);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("Found {d} matches", .{matches.items.items.len});
    if (max_results != 0 and matches.total > max_results) {
        try out.writer.print(" (showing first {d} of {d})", .{ max_results, matches.total });
    }
    try out.writer.print(":\n\n{s}", .{body});
    return out.toOwnedSlice();
}

fn validateExit(alloc: std.mem.Allocator, argv: []const []const u8, result: ExecResult) !?[]u8 {
    switch (result.term) {
        .exited => |code| {
            if (code == 0) return null;
            if (code == 1) {
                const s = std.mem.trim(u8, result.stdout, " \t\r\n");
                if (s.len == 0 or std.mem.eql(u8, s, "[]") or s[0] == '[' or s[0] == '{') return null;
            }
            const stderr_trim = std.mem.trim(u8, result.stderr, " \t\r\n");
            const detail = if (stderr_trim.len > 0) stderr_trim else "(no error output)";
            const repr = try argvRepr(alloc, argv);
            return try std.fmt.allocPrint(alloc, "Command {s} failed with exit code {d}: {s}", .{ repr, code, detail });
        },
        else => {
            const repr = try argvRepr(alloc, argv);
            return try std.fmt.allocPrint(alloc, "Command {s} failed: process terminated abnormally", .{repr});
        },
    }
}

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

fn findOnPath(alloc: std.mem.Allocator, io: Io, name: []const u8) !?PathHit {
    const path_env = envOwned(alloc, "PATH") orelse return null;
    defer alloc.free(path_env);

    const is_windows = builtin.os.tag == .windows;
    const sep: u8 = if (is_windows) ';' else ':';
    const exts: []const []const u8 = if (is_windows) &.{ "", ".exe", ".cmd", ".bat" } else &.{""};

    var it = std.mem.splitScalar(u8, path_env, sep);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        for (exts) |ext| {
            const candidate = try std.fmt.allocPrint(alloc, "{s}/{s}{s}", .{ dir, name, ext });
            if (std.Io.Dir.accessAbsolute(io, candidate, .{})) |_| {
                const is_script = std.ascii.eqlIgnoreCase(ext, ".cmd") or std.ascii.eqlIgnoreCase(ext, ".bat");
                return .{ .path = candidate, .is_script = is_script };
            } else |_| {
                alloc.free(candidate);
            }
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

fn getStr(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn getMaxResults(args: std.json.Value) usize {
    if (args != .object) return 0;
    const v = args.object.get("max_results") orelse return 0;
    const raw: i64 = switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => return 0,
    };
    return @intCast(@max(raw, 0));
}

fn oneOf(val: []const u8, choices: []const []const u8) bool {
    for (choices) |c| if (std.mem.eql(u8, val, c)) return true;
    return false;
}

const missing_binary_msg = "Command 'ast-grep' not found. Please ensure ast-grep is installed and in PATH.";

/// Run ast-grep through the injectable exec seam, mapping failures to clean
/// MCP tool errors (never a crash / JSON-RPC error).
fn runAstGrep(
    alloc: std.mem.Allocator,
    io: Io,
    command: []const u8,
    rest: []const []const u8,
    stdin_text: ?[]const u8,
) !union(enum) { ok: ExecResult, err: mcp.ToolResult } {
    var config_msg: ?[]const u8 = null;
    const config = try checkedConfig(alloc, io, &config_msg);
    if (config_msg) |msg| return .{ .err = .{ .text = msg, .is_error = true } };

    const argv = try astGrepArgv(alloc, config, command, rest);
    const result = exec_fn(alloc, io, argv, stdin_text) catch |err| switch (err) {
        error.ExecutableNotFound => return .{ .err = .{ .text = missing_binary_msg, .is_error = true } },
        error.InvalidBatchScriptArg => return .{ .err = .{
            .text = "ast-grep resolved to a .cmd/.bat shim and arguments containing newlines cannot be passed through cmd.exe. Use single-line (flow-style) YAML/patterns, or install a native ast-grep.exe.",
            .is_error = true,
        } },
        else => return .{ .err = .{
            .text = try std.fmt.allocPrint(alloc, "ast-grep execution failed: {s}", .{@errorName(err)}),
            .is_error = true,
        } },
    };
    if (try validateExit(alloc, argv, result)) |msg| {
        return .{ .err = .{ .text = msg, .is_error = true } };
    }
    return .{ .ok = result };
}

/// Config path from AST_GREP_CONFIG. If set but the file is missing, the
/// reference exits at startup; we surface a clean per-tool error instead.
fn checkedConfig(alloc: std.mem.Allocator, io: Io, err_msg: *?[]const u8) !?[]const u8 {
    err_msg.* = null;
    const path = envOwned(alloc, "AST_GREP_CONFIG") orelse return null;
    if (path.len == 0) return null;
    std.Io.Dir.accessAbsolute(io, path, .{}) catch {
        err_msg.* = try std.fmt.allocPrint(
            alloc,
            "Error: Config file '{s}' specified in AST_GREP_CONFIG does not exist",
            .{path},
        );
        return null;
    };
    return path;
}

fn handleDumpSyntaxTree(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const code = getStr(args, "code") orelse return .{ .text = "error: code is required", .is_error = true };
    const language = getStr(args, "language") orelse return .{ .text = "error: language is required", .is_error = true };
    const format = getStr(args, "format") orelse "cst";
    if (!oneOf(format, &.{ "pattern", "cst", "ast" })) {
        return .{
            .text = try std.fmt.allocPrint(alloc, "Invalid format: {s}. Must be 'pattern', 'cst' or 'ast'.", .{format}),
            .is_error = true,
        };
    }

    const debug_query = try std.fmt.allocPrint(alloc, "--debug-query={s}", .{format});
    switch (try runAstGrep(alloc, io, "run", &.{ "--pattern", code, "--lang", language, debug_query }, null)) {
        .err => |e| return e,
        .ok => |result| return .{ .text = std.mem.trim(u8, result.stderr, " \t\r\n") },
    }
}

fn handleTestMatchCodeRule(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const code = getStr(args, "code") orelse return .{ .text = "error: code is required", .is_error = true };
    const yaml = getStr(args, "yaml") orelse return .{ .text = "error: yaml is required", .is_error = true };

    switch (try runAstGrep(alloc, io, "scan", &.{ "--inline-rules", yaml, "--json", "--stdin" }, code)) {
        .err => |e| return e,
        .ok => |result| {
            const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
            const parsed = std.json.parseFromSlice(std.json.Value, alloc, if (trimmed.len > 0) trimmed else "[]", .{}) catch {
                return .{
                    .text = try std.fmt.allocPrint(alloc, "Failed to parse ast-grep JSON output: {s}", .{std.mem.trim(u8, result.stdout, " \t\r\n")}),
                    .is_error = true,
                };
            };
            const matches = parsed.value;
            if (matches == .array and matches.array.items.len == 0) {
                return .{
                    .text = "No matches found for the given code and rule. Try adding `stopBy: end` to your inside/has rule.",
                    .is_error = true,
                };
            }
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            try std.json.Stringify.value(matches, .{}, &out.writer);
            return .{ .text = out.written() };
        },
    }
}

fn findCommon(
    alloc: std.mem.Allocator,
    io: Io,
    args: std.json.Value,
    command: []const u8,
    lead_args: []const []const u8,
) !mcp.ToolResult {
    const project_folder = getStr(args, "project_folder") orelse return .{ .text = "error: project_folder is required", .is_error = true };
    const output_format = getStr(args, "output_format") orelse "text";
    if (!oneOf(output_format, &.{ "text", "json" })) {
        return .{
            .text = try std.fmt.allocPrint(alloc, "Invalid output_format: {s}. Must be 'text' or 'json'.", .{output_format}),
            .is_error = true,
        };
    }
    const max_results = getMaxResults(args);

    var rest: std.ArrayList([]const u8) = .empty;
    try rest.appendSlice(alloc, lead_args);
    try rest.append(alloc, "--json=stream");
    try rest.append(alloc, project_folder);

    switch (try runAstGrep(alloc, io, command, rest.items, null)) {
        .err => |e| return e,
        .ok => |result| {
            var matches = try parseMatches(alloc, result.stdout, max_results);
            defer matches.deinit(alloc);
            return .{ .text = try shapeFindOutput(alloc, &matches, max_results, output_format) };
        },
    }
}

fn handleFindCode(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const pattern = getStr(args, "pattern") orelse return .{ .text = "error: pattern is required", .is_error = true };
    var lead: std.ArrayList([]const u8) = .empty;
    try lead.append(alloc, "--pattern");
    try lead.append(alloc, pattern);
    if (getStr(args, "language")) |language| {
        if (language.len > 0) {
            try lead.append(alloc, "--lang");
            try lead.append(alloc, language);
        }
    }
    return findCommon(alloc, io, args, "run", lead.items);
}

fn handleFindCodeByRule(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const yaml = getStr(args, "yaml") orelse return .{ .text = "error: yaml is required", .is_error = true };
    return findCommon(alloc, io, args, "scan", &.{ "--inline-rules", yaml });
}

// ---------------------------------------------------------------------------
// Real process execution
// ---------------------------------------------------------------------------

fn astGrepBin(alloc: std.mem.Allocator) ![]const u8 {
    if (envOwned(alloc, "AST_GREP_BIN")) |v| return v;
    return alloc.dupe(u8, "ast-grep");
}

fn writeChildStdin(io: Io, file: std.Io.File, data: []const u8) void {
    var buf: [4096]u8 = undefined;
    var fw: std.Io.File.Writer = .init(file, io, &buf);
    fw.interface.writeAll(data) catch {};
    fw.interface.flush() catch {};
    file.close(io);
}

fn execReal(
    alloc: std.mem.Allocator,
    io: Io,
    argv: []const []const u8,
    stdin_text: ?[]const u8,
) !ExecResult {
    // Zig's Windows spawn does its own PATH + PATHEXT resolution for argv[0]
    // and transparently wraps .cmd/.bat shims (e.g. npm's ast-grep.cmd) in
    // `cmd.exe /c` — the same trick the reference pulls with shell=True.
    // Args containing LF/CR cannot survive a batch shim; spawn reports
    // error.InvalidBatchScriptArg, which runAstGrep maps to a clean message.
    const bin = try astGrepBin(alloc);
    var resolved: std.ArrayList([]const u8) = .empty;
    defer resolved.deinit(alloc);
    try resolved.append(alloc, bin);
    try resolved.appendSlice(alloc, argv[1..]);

    var child = std.process.spawn(io, .{
        .argv = resolved.items,
        .stdin = if (stdin_text != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.ExecutableNotFound,
        else => return err,
    };
    defer child.kill(io);

    // Feed stdin from a helper thread so a large input cannot deadlock
    // against a child that is simultaneously filling stdout/stderr.
    var stdin_thread: ?std.Thread = null;
    if (stdin_text) |input| {
        stdin_thread = std.Thread.spawn(.{}, writeChildStdin, .{ io, child.stdin.?, input }) catch null;
        if (stdin_thread == null) {
            writeChildStdin(io, child.stdin.?, input);
            child.stdin = null;
        }
    }
    defer {
        if (stdin_thread) |t| {
            t.join();
            child.stdin = null;
        }
    }

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(alloc, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    while (multi_reader.fill(64, .none)) |_| {
        if (stdout_reader.buffered().len > 1024 * 1024 * 16) return error.StreamTooLong;
        if (stderr_reader.buffered().len > 1024 * 1024 * 8) return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }

    try multi_reader.checkAnyError();
    if (stdin_thread) |t| {
        t.join();
        child.stdin = null;
        stdin_thread = null;
    }

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

const sample_match_1 =
    \\{"text":"console.log('a');","file":"src/a.js","range":{"start":{"line":2,"column":0},"end":{"line":2,"column":16}},"ruleId":"x"}
;
const sample_match_2 =
    \\{"text":"console.log('b');\nconsole.log('c');\n","file":"src/b.js","range":{"start":{"line":9,"column":0},"end":{"line":10,"column":16}}}
;
const sample_match_3 =
    \\{"text":"foo();","file":"src/c.js","range":{"start":{"line":0,"column":0},"end":{"line":0,"column":6}}}
;

var fake_argv: []const []const u8 = &.{};
var fake_stdin: ?[]const u8 = null;
var fake_result: ExecResult = .{ .term = .{ .exited = 0 }, .stdout = @constCast(""), .stderr = @constCast("") };
var fake_error: ?anyerror = null;

fn fakeExec(
    alloc: std.mem.Allocator,
    io: Io,
    argv: []const []const u8,
    stdin_text: ?[]const u8,
) !ExecResult {
    _ = alloc;
    _ = io;
    fake_argv = argv;
    fake_stdin = stdin_text;
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

    /// Initialize IN PLACE: arena_state must not move after this call, since
    /// `arena` points into it.
    fn init(ctx: *TestCtx) void {
        ctx.arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        ctx.arena = ctx.arena_state.allocator();
        setExecForTesting(fakeExec);
        fake_argv = &.{};
        fake_stdin = null;
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

test "argv: dump_syntax_tree builds run --pattern --lang --debug-query (default cst)" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fakeOk("", "tree-output\n");

    const args = try testArgs(ctx.arena,
        \\{"code": "let x = 1;", "language": "javascript"}
    );
    const res = try handleDumpSyntaxTree(ctx.arena, std.testing.io, args);
    try std.testing.expect(!res.is_error);

    try expectArgv(&.{ "ast-grep", "run", "--pattern", "let x = 1;", "--lang", "javascript", "--debug-query=cst" });
}

test "argv: dump_syntax_tree honors format=pattern and rejects invalid format" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fakeOk("", "pattern-tree\n");

    const args = try testArgs(ctx.arena,
        \\{"code": "foo($A)", "language": "javascript", "format": "pattern"}
    );
    const res = try handleDumpSyntaxTree(ctx.arena, std.testing.io, args);
    try std.testing.expect(!res.is_error);
    try expectArgv(&.{ "ast-grep", "run", "--pattern", "foo($A)", "--lang", "javascript", "--debug-query=pattern" });

    const bad = try testArgs(ctx.arena,
        \\{"code": "x", "language": "javascript", "format": "xml"}
    );
    const bad_res = try handleDumpSyntaxTree(ctx.arena, std.testing.io, bad);
    try std.testing.expect(bad_res.is_error);
}

test "argv: test_match_code_rule builds scan --inline-rules --json --stdin and pipes code on stdin" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fakeOk("[{\"text\":\"x\"}]", "");

    const args = try testArgs(ctx.arena,
        \\{"code": "console.log(1);", "yaml": "id: r\nlanguage: JavaScript\nrule: {pattern: 'console.log($A)'}"}
    );
    const res = try handleTestMatchCodeRule(ctx.arena, std.testing.io, args);
    try std.testing.expect(!res.is_error);

    try expectArgv(&.{ "ast-grep", "scan", "--inline-rules", "id: r\nlanguage: JavaScript\nrule: {pattern: 'console.log($A)'}", "--json", "--stdin" });
    try std.testing.expectEqualStrings("console.log(1);", fake_stdin.?);
}

test "argv: find_code builds run --pattern [--lang] --json=stream folder" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fakeOk("", "");

    const with_lang = try testArgs(ctx.arena,
        \\{"project_folder": "/proj", "pattern": "foo($A)", "language": "javascript"}
    );
    _ = try handleFindCode(ctx.arena, std.testing.io, with_lang);
    try expectArgv(&.{ "ast-grep", "run", "--pattern", "foo($A)", "--lang", "javascript", "--json=stream", "/proj" });

    const no_lang = try testArgs(ctx.arena,
        \\{"project_folder": "/proj", "pattern": "foo($A)"}
    );
    _ = try handleFindCode(ctx.arena, std.testing.io, no_lang);
    try expectArgv(&.{ "ast-grep", "run", "--pattern", "foo($A)", "--json=stream", "/proj" });
}

test "argv: find_code_by_rule builds scan --inline-rules --json=stream folder" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fakeOk("", "");

    const args = try testArgs(ctx.arena,
        \\{"project_folder": "/proj", "yaml": "id: r\nlanguage: JavaScript\nrule: {pattern: 'x'}"}
    );
    _ = try handleFindCodeByRule(ctx.arena, std.testing.io, args);
    try expectArgv(&.{ "ast-grep", "scan", "--inline-rules", "id: r\nlanguage: JavaScript\nrule: {pattern: 'x'}", "--json=stream", "/proj" });
}

test "argv: config path is injected after the subcommand" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();

    const argv = try astGrepArgv(ctx.arena, "/cfg/sgconfig.yaml", "scan", &.{ "--json", "/proj" });
    try std.testing.expectEqual(@as(usize, 6), argv.len);
    try std.testing.expectEqualStrings("ast-grep", argv[0]);
    try std.testing.expectEqualStrings("scan", argv[1]);
    try std.testing.expectEqualStrings("--config", argv[2]);
    try std.testing.expectEqualStrings("/cfg/sgconfig.yaml", argv[3]);
    try std.testing.expectEqualStrings("--json", argv[4]);
    try std.testing.expectEqualStrings("/proj", argv[5]);

    const no_cfg = try astGrepArgv(ctx.arena, null, "run", &.{"--pattern"});
    try std.testing.expectEqualSlices([]const u8, &.{ "ast-grep", "run", "--pattern" }, no_cfg);
}

test "parseMatches skips warnings and counts only json lines" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();

    const stdout = "WARN[0000] some ast-grep warning\n" ++ sample_match_1 ++ "\n\n   \n" ++ sample_match_2 ++ "\n";
    var m = try parseMatches(ctx.arena, stdout, 0);
    defer m.deinit(ctx.arena);
    try std.testing.expectEqual(@as(usize, 2), m.total);
    try std.testing.expectEqual(@as(usize, 2), m.items.items.len);
}

test "parseMatches truncates kept matches but counts total" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();

    const stdout = sample_match_1 ++ "\n" ++ sample_match_2 ++ "\n" ++ sample_match_3 ++ "\n";
    var m = try parseMatches(ctx.arena, stdout, 2);
    defer m.deinit(ctx.arena);
    try std.testing.expectEqual(@as(usize, 3), m.total);
    try std.testing.expectEqual(@as(usize, 2), m.items.items.len);
}

test "parseMatches rejects malformed json lines" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();

    try std.testing.expectError(error.SyntaxError, parseMatches(ctx.arena, "{not json}\n", 0));
}

test "find_code text output shapes header, ranges and truncation notice" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fakeOk(sample_match_1 ++ "\n" ++ sample_match_2 ++ "\n" ++ sample_match_3 ++ "\n", "");

    const args = try testArgs(ctx.arena,
        \\{"project_folder": "/proj", "pattern": "x", "max_results": 2}
    );
    const res = try handleFindCode(ctx.arena, std.testing.io, args);
    try std.testing.expect(!res.is_error);
    try std.testing.expectEqualStrings(
        "Found 2 matches (showing first 2 of 3):\n\nsrc/a.js:3\nconsole.log('a');\n\nsrc/b.js:10-11\nconsole.log('b');\nconsole.log('c');",
        res.text,
    );
}

test "find_code text output with no matches" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fakeOk("", "");

    const args = try testArgs(ctx.arena,
        \\{"project_folder": "/proj", "pattern": "x"}
    );
    const res = try handleFindCode(ctx.arena, std.testing.io, args);
    try std.testing.expect(!res.is_error);
    try std.testing.expectEqualStrings("No matches found", res.text);
}

test "find_code json output emits kept matches" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fakeOk(sample_match_1 ++ "\n" ++ sample_match_2 ++ "\n", "");

    const args = try testArgs(ctx.arena,
        \\{"project_folder": "/proj", "pattern": "x", "output_format": "json"}
    );
    const res = try handleFindCode(ctx.arena, std.testing.io, args);
    try std.testing.expect(!res.is_error);
    try std.testing.expectEqualStrings("[" ++ sample_match_1 ++ "," ++ sample_match_2 ++ "]", res.text);
}

test "find_code rejects invalid output_format" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();

    const args = try testArgs(ctx.arena,
        \\{"project_folder": "/proj", "pattern": "x", "output_format": "xml"}
    );
    const res = try handleFindCode(ctx.arena, std.testing.io, args);
    try std.testing.expect(res.is_error);
    try std.testing.expectEqualStrings("Invalid output_format: xml. Must be 'text' or 'json'.", res.text);

    const args2 = try testArgs(ctx.arena,
        \\{"project_folder": "/proj", "yaml": "y", "output_format": "yaml"}
    );
    const res2 = try handleFindCodeByRule(ctx.arena, std.testing.io, args2);
    try std.testing.expect(res2.is_error);
}

test "exit code 1 with json-ish stdout is not an error" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fake_result = .{ .term = .{ .exited = 1 }, .stdout = @constCast(sample_match_1 ++ "\n"), .stderr = @constCast("") };
    fake_error = null;

    const args = try testArgs(ctx.arena,
        \\{"project_folder": "/proj", "pattern": "x"}
    );
    const res = try handleFindCode(ctx.arena, std.testing.io, args);
    try std.testing.expect(!res.is_error);
    try std.testing.expect(std.mem.startsWith(u8, res.text, "Found 1 matches"));

    // empty stdout / "[]" are also valid "no matches"
    fake_result = .{ .term = .{ .exited = 1 }, .stdout = @constCast(""), .stderr = @constCast("some warning") };
    const res2 = try handleFindCode(ctx.arena, std.testing.io, args);
    try std.testing.expect(!res2.is_error);
    try std.testing.expectEqualStrings("No matches found", res2.text);

    fake_result = .{ .term = .{ .exited = 1 }, .stdout = @constCast("[]"), .stderr = @constCast("") };
    const res3 = try handleFindCode(ctx.arena, std.testing.io, args);
    try std.testing.expect(!res3.is_error);
}

test "exit code 1 with garbage stdout is an error; other codes map stderr" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fake_result = .{ .term = .{ .exited = 1 }, .stdout = @constCast("not-json-at-all"), .stderr = @constCast("bad pattern\n") };
    fake_error = null;

    const args = try testArgs(ctx.arena,
        \\{"project_folder": "/proj", "pattern": "x"}
    );
    const res = try handleFindCode(ctx.arena, std.testing.io, args);
    try std.testing.expect(res.is_error);
    try std.testing.expectEqualStrings(
        "Command ['ast-grep', 'run', '--pattern', 'x', '--json=stream', '/proj'] failed with exit code 1: bad pattern",
        res.text,
    );

    fake_result = .{ .term = .{ .exited = 2 }, .stdout = @constCast(""), .stderr = @constCast("") };
    const res2 = try handleFindCode(ctx.arena, std.testing.io, args);
    try std.testing.expect(res2.is_error);
    try std.testing.expect(std.mem.endsWith(u8, res2.text, "failed with exit code 2: (no error output)"));
}

test "missing binary maps to a clean tool error" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fake_error = error.ExecutableNotFound;

    const args = try testArgs(ctx.arena,
        \\{"project_folder": "/proj", "pattern": "x"}
    );
    const res = try handleFindCode(ctx.arena, std.testing.io, args);
    try std.testing.expect(res.is_error);
    try std.testing.expectEqualStrings(
        "Command 'ast-grep' not found. Please ensure ast-grep is installed and in PATH.",
        res.text,
    );
}

test "test_match_code_rule errors on empty matches and returns matches otherwise" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fakeOk("[]\n", "");

    const args = try testArgs(ctx.arena,
        \\{"code": "let x = 1;", "yaml": "id: r\nlanguage: JavaScript\nrule: {pattern: 'y'}"}
    );
    const res = try handleTestMatchCodeRule(ctx.arena, std.testing.io, args);
    try std.testing.expect(res.is_error);
    try std.testing.expectEqualStrings(
        "No matches found for the given code and rule. Try adding `stopBy: end` to your inside/has rule.",
        res.text,
    );

    fakeOk("[{\"text\":\"foo();\"}]\n", "");
    const res2 = try handleTestMatchCodeRule(ctx.arena, std.testing.io, args);
    try std.testing.expect(!res2.is_error);
    try std.testing.expectEqualStrings("[{\"text\":\"foo();\"}]", res2.text);
}

test "dump_syntax_tree returns trimmed stderr" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fakeOk("", "  root\n    identifier  \n\n");

    const args = try testArgs(ctx.arena,
        \\{"code": "x", "language": "javascript"}
    );
    const res = try handleDumpSyntaxTree(ctx.arena, std.testing.io, args);
    try std.testing.expect(!res.is_error);
    try std.testing.expectEqualStrings("root\n    identifier", res.text);
}

// ---------------------------------------------------------------------------
// Integration tests against the real ast-grep binary (skipped when absent)
// ---------------------------------------------------------------------------

fn astGrepAvailable(alloc: std.mem.Allocator, io: Io) bool {
    const hit = findOnPath(alloc, io, "ast-grep") catch return false;
    if (hit) |h| {
        alloc.free(h.path);
        return true;
    }
    return false;
}

test "integration: find_code with real ast-grep binary" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    if (!astGrepAvailable(alloc, io)) {
        std.debug.print("skipping integration test: ast-grep not found on PATH\n", .{});
        return;
    }
    setExecForTesting(execReal);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "hello.js", .data = "function main() {\n  console.log('hi');\n}\n" });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(io, &path_buf);
    const tmp_path = try arena.dupe(u8, path_buf[0..tmp_path_len]);

    // Build args as a JSON object directly: tmp_path contains backslashes on
    // Windows, which would need escaping in an interpolated JSON string.
    var map: std.json.ObjectMap = .empty;
    try map.put(arena, "project_folder", .{ .string = tmp_path });
    try map.put(arena, "pattern", .{ .string = "console.log($A)" });
    try map.put(arena, "language", .{ .string = "javascript" });
    const args = std.json.Value{ .object = map };
    const res = try handleFindCode(arena, io, args);
    try std.testing.expect(!res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "Found 1 match") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "hello.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "console.log('hi')") != null);
}

test "integration: dump_syntax_tree with real ast-grep binary" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    if (!astGrepAvailable(alloc, io)) {
        std.debug.print("skipping integration test: ast-grep not found on PATH\n", .{});
        return;
    }
    setExecForTesting(execReal);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try testArgs(arena,
        \\{"code": "let x = 1;", "language": "javascript", "format": "pattern"}
    );
    const res = try handleDumpSyntaxTree(arena, io, args);
    try std.testing.expect(!res.is_error);
    try std.testing.expect(res.text.len > 0);
}

test "integration: test_match_code_rule with real ast-grep binary" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    if (!astGrepAvailable(alloc, io)) {
        std.debug.print("skipping integration test: ast-grep not found on PATH\n", .{});
        return;
    }
    setExecForTesting(execReal);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Flow-style (single-line) YAML: multi-line YAML cannot survive the
    // Windows .cmd shim — the Python reference breaks identically there.
    const args = try testArgs(arena,
        \\{"code": "console.log(42);\n", "yaml": "{id: test-rule, language: JavaScript, rule: {pattern: 'console.log($A)'}}"}
    );
    const res = try handleTestMatchCodeRule(arena, io, args);
    try std.testing.expect(!res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "console.log(42);") != null);
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
