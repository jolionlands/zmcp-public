//! zmcp-docker — MCP server wrapping the local `docker` CLI. READ-ONLY by default.
//! argv only (no shell); binary resolved via PATH.
//!
//! Read-only tools:
//!   docker_ps(all?)                                  — docker ps [--all]
//!   docker_images(all?)                              — docker images [--all]
//!   docker_logs(container, tail?, since?)            — docker logs --tail N [--since S] <container>
//!   docker_inspect(target)                           — docker inspect <target>
//!   docker_stats(container?)                         — docker stats --no-stream [container]
//!   docker_compose_ps(file?, project_dir?, all?)     — docker compose ... ps
//!   docker_compose_logs(service?, tail?, since?, file?, project_dir?) — docker compose ... logs --no-color
//! Mutating tools (refused unless env ZMCP_DOCKER_ALLOW_WRITE=1):
//!   docker_start / docker_stop / docker_restart (container)
//!
//! Safety: container/image/service/file/dir/since args must not start with '-'
//! (option injection), must be non-empty and free of control characters.
//! Output is capped at MAX_OUTPUT_BYTES.

const std = @import("std");
const mcp = @import("mcp");

const Io = std.Io;

pub const MAX_OUTPUT_BYTES: usize = 64 * 1024;
/// Hard cap on bytes captured from the child before it is killed.
const MAX_CAPTURE_BYTES: usize = 4 * 1024 * 1024;
pub const DEFAULT_TAIL: u32 = 100;
pub const MAX_TAIL: u32 = 5000;

pub const write_env = "ZMCP_DOCKER_ALLOW_WRITE";

/// Set once at startup from the environment (or by tests).
var write_enabled: bool = false;

pub fn main(init: std.process.Init) !void {
    if (init.environ_map.get(write_env)) |v| {
        write_enabled = isTruthyFlag(v);
    }
    try mcp.run(init.gpa, init.io, .{ .name = "zmcp-docker", .version = "0.1.0" }, &tool_table);
}

/// Only exactly "1" enables writes.
fn isTruthyFlag(v: []const u8) bool {
    return std.mem.eql(u8, v, "1");
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "docker_ps",
        .description = "List containers (docker ps). Running only by default; all=true includes stopped. Read-only.",
        .input_schema_json =
        \\{"type":"object","properties":{"all":{"type":"boolean","default":false,"description":"Include stopped containers"}}}
        ,
        .handler = handlePs,
        .read_only = true,
    },
    .{
        .name = "docker_images",
        .description = "List local images (docker images). Read-only.",
        .input_schema_json =
        \\{"type":"object","properties":{"all":{"type":"boolean","default":false,"description":"Include intermediate images"}}}
        ,
        .handler = handleImages,
        .read_only = true,
    },
    .{
        .name = "docker_logs",
        .description = "Fetch container logs (docker logs --tail N). tail defaults to 100, max 5000; output is byte-capped (the end of the log is kept). since accepts e.g. '10m' or an RFC3339 timestamp. Read-only.",
        .input_schema_json =
        \\{"type":"object","properties":{"container":{"type":"string","description":"Container name or id"},"tail":{"type":"integer","default":100,"description":"Number of lines from the end (max 5000)"},"since":{"type":"string","description":"Only logs since this time/duration, e.g. 10m"}},"required":["container"]}
        ,
        .handler = handleLogs,
        .read_only = true,
    },
    .{
        .name = "docker_inspect",
        .description = "Low-level JSON details of a container, image, network or volume (docker inspect). Environment variables whose NAME looks secret-like (password, secret, token, key, credential, passwd, auth, dsn) are shown as NAME=[redacted], and user:pass@ credentials in URLs are masked; this is a name-based heuristic, so other secrets in labels/commands may still appear. Output is byte-capped. Read-only.",
        .input_schema_json =
        \\{"type":"object","properties":{"target":{"type":"string","description":"Container/image/etc. name or id"}},"required":["target"]}
        ,
        .handler = handleInspect,
        .read_only = true,
    },
    .{
        .name = "docker_stats",
        .description = "One-shot resource usage snapshot (docker stats --no-stream) for all running containers or a single one. Read-only.",
        .input_schema_json =
        \\{"type":"object","properties":{"container":{"type":"string","description":"Optional container name or id"}}}
        ,
        .handler = handleStats,
        .read_only = true,
    },
    .{
        .name = "docker_compose_ps",
        .description = "List compose services (docker compose ps). Optional compose file and project directory. Read-only.",
        .input_schema_json =
        \\{"type":"object","properties":{"file":{"type":"string","description":"Compose file path (-f)"},"project_dir":{"type":"string","description":"Project directory (--project-directory)"},"all":{"type":"boolean","default":false,"description":"Include stopped containers"}}}
        ,
        .handler = handleComposePs,
        .read_only = true,
    },
    .{
        .name = "docker_compose_logs",
        .description = "Compose service logs (docker compose logs --no-color --tail N). tail defaults to 100, max 5000; output byte-capped. Read-only.",
        .input_schema_json =
        \\{"type":"object","properties":{"service":{"type":"string","description":"Optional service name"},"tail":{"type":"integer","default":100,"description":"Lines per service (max 5000)"},"since":{"type":"string","description":"Only logs since this time/duration"},"file":{"type":"string","description":"Compose file path (-f)"},"project_dir":{"type":"string","description":"Project directory (--project-directory)"}}}
        ,
        .handler = handleComposeLogs,
        .read_only = true,
    },
    .{
        .name = "docker_start",
        .description = "Start a stopped container. MUTATING: refused unless the server runs with ZMCP_DOCKER_ALLOW_WRITE=1.",
        .input_schema_json =
        \\{"type":"object","properties":{"container":{"type":"string","description":"Container name or id"}},"required":["container"]}
        ,
        .handler = handleStart,
    },
    .{
        .name = "docker_stop",
        .description = "Stop a running container. MUTATING: refused unless the server runs with ZMCP_DOCKER_ALLOW_WRITE=1.",
        .input_schema_json =
        \\{"type":"object","properties":{"container":{"type":"string","description":"Container name or id"}},"required":["container"]}
        ,
        .handler = handleStop,
        .destructive = true,
    },
    .{
        .name = "docker_restart",
        .description = "Restart a container. MUTATING: refused unless the server runs with ZMCP_DOCKER_ALLOW_WRITE=1.",
        .input_schema_json =
        \\{"type":"object","properties":{"container":{"type":"string","description":"Container name or id"}},"required":["container"]}
        ,
        .handler = handleRestart,
        .destructive = true,
    },
};

// ---------------------------------------------------------------------------
// Process-execution seam (injectable for offline unit tests)
// ---------------------------------------------------------------------------

pub const ExecResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    /// True if capture stopped early because MAX_CAPTURE_BYTES was hit.
    truncated: bool = false,
};

pub const ExecFn = *const fn (alloc: std.mem.Allocator, io: Io, argv: []const []const u8) anyerror!ExecResult;

var exec_fn: ExecFn = execReal;

// ---------------------------------------------------------------------------
// Pure helpers (unit tested)
// ---------------------------------------------------------------------------

pub const RefError = error{ EmptyArg, LeadingDash, BadChar };

/// Validate an identifier-like argument (container, image, service, path, since).
pub fn validateRef(s: []const u8) RefError!void {
    if (s.len == 0) return error.EmptyArg;
    if (s[0] == '-') return error.LeadingDash;
    for (s) |c| if (c < 0x20 or c == 0x7f) return error.BadChar;
}

fn refErrorText(alloc: std.mem.Allocator, name: []const u8, err: RefError) ![]const u8 {
    const why = switch (err) {
        error.EmptyArg => "must not be empty",
        error.LeadingDash => "must not start with '-'",
        error.BadChar => "must not contain control characters",
    };
    return std.fmt.allocPrint(alloc, "error: invalid {s}: {s}", .{ name, why });
}

// ---------------------------------------------------------------------------
// docker inspect redaction (pure)
// ---------------------------------------------------------------------------

const secret_name_parts = [_][]const u8{ "password", "secret", "token", "key", "credential", "passwd", "auth", "dsn" };

/// True when an environment variable NAME looks secret-like (case-insensitive).
pub fn envNameLooksSecret(name: []const u8) bool {
    for (secret_name_parts) |p| if (std.ascii.indexOfIgnoreCase(name, p) != null) return true;
    return false;
}

/// Replace `user:pass@` (any userinfo) in every `scheme://userinfo@host` found
/// in `s`. Returns `s` itself when nothing matched.
pub fn redactUrlUserinfo(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var cur: []const u8 = s;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, cur, from, "://")) |i| {
        const astart = i + 3;
        var aend = astart;
        while (aend < cur.len and switch (cur[aend]) {
            '/', '?', '#', ' ', '\t', '\n', '\r', '"', '\'' => false,
            else => true,
        }) aend += 1;
        from = astart;
        const at = std.mem.lastIndexOfScalar(u8, cur[astart..aend], '@') orelse continue;
        if (std.mem.eql(u8, cur[astart .. astart + at], "[redacted]")) continue;
        cur = try std.mem.concat(alloc, u8, &.{ cur[0..astart], "[redacted]", cur[astart + at ..] });
        from = astart + "[redacted]".len;
    }
    return cur;
}

fn redactEnvEntry(alloc: std.mem.Allocator, entry: []const u8) ![]const u8 {
    const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return entry;
    const name = entry[0..eq];
    if (envNameLooksSecret(name)) return std.fmt.allocPrint(alloc, "{s}=[redacted]", .{name});
    const v = try redactUrlUserinfo(alloc, entry[eq + 1 ..]);
    if (v.ptr == entry[eq + 1 ..].ptr) return entry;
    return std.fmt.allocPrint(alloc, "{s}={s}", .{ name, v });
}

fn redactInspectValue(alloc: std.mem.Allocator, v: *std.json.Value, depth: usize) !void {
    if (depth > 64) return error.TooDeep;
    switch (v.*) {
        .string => |s| v.* = .{ .string = try redactUrlUserinfo(alloc, s) },
        .array => |*arr| for (arr.items) |*x| try redactInspectValue(alloc, x, depth + 1),
        .object => |*obj| {
            var it = obj.iterator();
            while (it.next()) |e| {
                // Config.Env (containers, images) and service/task Env lists.
                if (std.mem.eql(u8, e.key_ptr.*, "Env") and e.value_ptr.* == .array) {
                    for (e.value_ptr.array.items) |*x| {
                        if (x.* == .string) x.* = .{ .string = try redactEnvEntry(alloc, x.string) } else try redactInspectValue(alloc, x, depth + 1);
                    }
                    continue;
                }
                try redactInspectValue(alloc, e.value_ptr, depth + 1);
            }
        },
        else => {},
    }
}

/// Parse `docker inspect` JSON, redact secret-like env vars and URL userinfo,
/// and re-serialise. Errors (never raw output) if the input is not valid JSON.
pub fn redactInspect(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{});
    try redactInspectValue(alloc, &root, 0);
    return std.json.Stringify.valueAlloc(alloc, root, .{ .whitespace = .indent_4 });
}

fn clampTail(raw: ?i64) u32 {
    const v = raw orelse return DEFAULT_TAIL;
    if (v < 0) return DEFAULT_TAIL;
    return @intCast(@min(v, @as(i64, MAX_TAIL)));
}

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

fn errResult(text: []const u8) mcp.ToolResult {
    return .{ .text = text, .is_error = true };
}

const Argv = std.ArrayList([]const u8);

fn compose(alloc: std.mem.Allocator, argv: *Argv, file: ?[]const u8, project_dir: ?[]const u8) !void {
    try argv.appendSlice(alloc, &.{ "docker", "compose" });
    if (file) |f| try argv.appendSlice(alloc, &.{ "-f", f });
    if (project_dir) |d| try argv.appendSlice(alloc, &.{ "--project-directory", d });
}

/// Truncate to `max` bytes. keep_tail keeps the END (logs); else keeps the start.
fn capOutput(alloc: std.mem.Allocator, data: []const u8, max: usize, keep_tail: bool, force_note: bool) ![]const u8 {
    if (data.len <= max and !force_note) return data;
    if (data.len <= max) return std.fmt.allocPrint(alloc, "{s}\n[output truncated at capture limit]", .{data});
    if (keep_tail) {
        return std.fmt.allocPrint(alloc, "[output truncated: showing last {d} of {d} bytes]\n{s}", .{ max, data.len, data[data.len - max ..] });
    }
    return std.fmt.allocPrint(alloc, "{s}\n[output truncated: showing first {d} of {d} bytes]", .{ data[0..max], max, data.len });
}

const Mode = struct { keep_tail: bool = false, merge_stderr: bool = false, redact_inspect: bool = false };

/// Run argv through the exec seam and shape the result into a ToolResult.
fn run(alloc: std.mem.Allocator, io: Io, argv: []const []const u8, mode: Mode) !mcp.ToolResult {
    const res = exec_fn(alloc, io, argv) catch |err| switch (err) {
        error.ExecutableNotFound => return errResult("error: 'docker' CLI not found. Install Docker and ensure `docker` is on PATH."),
        else => return errResult(try std.fmt.allocPrint(alloc, "error: docker execution failed: {s}", .{@errorName(err)})),
    };
    const stderr_trim = std.mem.trim(u8, res.stderr, " \t\r\n");
    switch (res.term) {
        .exited => |code| if (code != 0) {
            const detail = if (stderr_trim.len > 0) stderr_trim else "(no error output)";
            const capped = try capOutput(alloc, detail, MAX_OUTPUT_BYTES, true, false);
            return errResult(try std.fmt.allocPrint(alloc, "error: docker exited with code {d}: {s}", .{ code, capped }));
        },
        else => return errResult("error: docker terminated abnormally"),
    }
    var body: []const u8 = res.stdout;
    if (mode.redact_inspect) {
        // Never fall back to raw output: it may carry Config.Env secrets.
        if (res.truncated) return errResult("error: docker inspect output too large to redact safely; refusing to return it");
        body = redactInspect(alloc, res.stdout) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => return errResult("error: docker inspect output was not valid JSON; refusing to return it unredacted"),
        };
    }
    if (mode.merge_stderr and stderr_trim.len > 0) {
        // `docker logs` relays the container's stderr on our stderr.
        body = try std.mem.concat(alloc, u8, &.{ res.stdout, res.stderr });
    }
    const capped = try capOutput(alloc, body, MAX_OUTPUT_BYTES, mode.keep_tail, res.truncated);
    if (capped.len == 0) return .{ .text = "(no output)" };
    return .{ .text = capped };
}

// ---------------------------------------------------------------------------
// argv builders (pure)
// ---------------------------------------------------------------------------

fn buildPs(alloc: std.mem.Allocator, args: std.json.Value) ![]const []const u8 {
    var a: Argv = .empty;
    try a.appendSlice(alloc, &.{ "docker", "ps" });
    if (getBool(args, "all")) try a.append(alloc, "--all");
    return a.toOwnedSlice(alloc);
}

fn buildImages(alloc: std.mem.Allocator, args: std.json.Value) ![]const []const u8 {
    var a: Argv = .empty;
    try a.appendSlice(alloc, &.{ "docker", "images" });
    if (getBool(args, "all")) try a.append(alloc, "--all");
    return a.toOwnedSlice(alloc);
}

const Built = union(enum) { argv: []const []const u8, err: []const u8 };

fn checked(alloc: std.mem.Allocator, name: []const u8, v: []const u8) !?[]const u8 {
    validateRef(v) catch |e| return try refErrorText(alloc, name, e);
    return null;
}

fn buildLogs(alloc: std.mem.Allocator, args: std.json.Value) !Built {
    const container = getStr(args, "container") orelse return .{ .err = "error: container is required" };
    if (try checked(alloc, "container", container)) |m| return .{ .err = m };
    var a: Argv = .empty;
    try a.appendSlice(alloc, &.{ "docker", "logs", "--tail" });
    try a.append(alloc, try std.fmt.allocPrint(alloc, "{d}", .{clampTail(getInt(args, "tail"))}));
    if (getStr(args, "since")) |s| {
        if (try checked(alloc, "since", s)) |m| return .{ .err = m };
        try a.appendSlice(alloc, &.{ "--since", s });
    }
    try a.append(alloc, container);
    return .{ .argv = try a.toOwnedSlice(alloc) };
}

fn buildInspect(alloc: std.mem.Allocator, args: std.json.Value) !Built {
    const target = getStr(args, "target") orelse return .{ .err = "error: target is required" };
    if (try checked(alloc, "target", target)) |m| return .{ .err = m };
    return .{ .argv = try alloc.dupe([]const u8, &.{ "docker", "inspect", target }) };
}

fn buildStats(alloc: std.mem.Allocator, args: std.json.Value) !Built {
    var a: Argv = .empty;
    try a.appendSlice(alloc, &.{ "docker", "stats", "--no-stream" });
    if (getStr(args, "container")) |c| {
        if (try checked(alloc, "container", c)) |m| return .{ .err = m };
        try a.append(alloc, c);
    }
    return .{ .argv = try a.toOwnedSlice(alloc) };
}

const OptRef = union(enum) { none, val: []const u8, err: []const u8 };

fn optRef(alloc: std.mem.Allocator, args: std.json.Value, key: []const u8) !OptRef {
    const v = getStr(args, key) orelse return .none;
    if (try checked(alloc, key, v)) |m| return .{ .err = m };
    return .{ .val = v };
}

fn buildComposePs(alloc: std.mem.Allocator, args: std.json.Value) !Built {
    const file = switch (try optRef(alloc, args, "file")) {
        .none => null,
        .val => |v| v,
        .err => |m| return .{ .err = m },
    };
    const dir = switch (try optRef(alloc, args, "project_dir")) {
        .none => null,
        .val => |v| v,
        .err => |m| return .{ .err = m },
    };
    var a: Argv = .empty;
    try compose(alloc, &a, file, dir);
    try a.append(alloc, "ps");
    if (getBool(args, "all")) try a.append(alloc, "--all");
    return .{ .argv = try a.toOwnedSlice(alloc) };
}

fn buildComposeLogs(alloc: std.mem.Allocator, args: std.json.Value) !Built {
    const file = switch (try optRef(alloc, args, "file")) {
        .none => null,
        .val => |v| v,
        .err => |m| return .{ .err = m },
    };
    const dir = switch (try optRef(alloc, args, "project_dir")) {
        .none => null,
        .val => |v| v,
        .err => |m| return .{ .err = m },
    };
    var a: Argv = .empty;
    try compose(alloc, &a, file, dir);
    try a.appendSlice(alloc, &.{ "logs", "--no-color", "--tail" });
    try a.append(alloc, try std.fmt.allocPrint(alloc, "{d}", .{clampTail(getInt(args, "tail"))}));
    switch (try optRef(alloc, args, "since")) {
        .none => {},
        .val => |v| try a.appendSlice(alloc, &.{ "--since", v }),
        .err => |m| return .{ .err = m },
    }
    switch (try optRef(alloc, args, "service")) {
        .none => {},
        .val => |v| try a.append(alloc, v),
        .err => |m| return .{ .err = m },
    }
    return .{ .argv = try a.toOwnedSlice(alloc) };
}

const WriteVerb = enum { start, stop, restart };

fn buildWrite(alloc: std.mem.Allocator, verb: WriteVerb, args: std.json.Value) !Built {
    const container = getStr(args, "container") orelse return .{ .err = "error: container is required" };
    if (try checked(alloc, "container", container)) |m| return .{ .err = m };
    return .{ .argv = try alloc.dupe([]const u8, &.{ "docker", @tagName(verb), container }) };
}

fn writeRefusal(alloc: std.mem.Allocator, tool: []const u8) !mcp.ToolResult {
    return errResult(try std.fmt.allocPrint(
        alloc,
        "refused: {s} modifies container state and this server is read-only. Restart zmcp-docker with {s}=1 to enable docker_start/docker_stop/docker_restart.",
        .{ tool, write_env },
    ));
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

fn runBuilt(alloc: std.mem.Allocator, io: Io, b: Built, mode: Mode) !mcp.ToolResult {
    return switch (b) {
        .err => |m| errResult(m),
        .argv => |v| run(alloc, io, v, mode),
    };
}

fn handlePs(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    return run(alloc, io, try buildPs(alloc, args), .{});
}

fn handleImages(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    return run(alloc, io, try buildImages(alloc, args), .{});
}

fn handleLogs(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    return runBuilt(alloc, io, try buildLogs(alloc, args), .{ .keep_tail = true, .merge_stderr = true });
}

fn handleInspect(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    return runBuilt(alloc, io, try buildInspect(alloc, args), .{ .redact_inspect = true });
}

fn handleStats(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    return runBuilt(alloc, io, try buildStats(alloc, args), .{});
}

fn handleComposePs(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    return runBuilt(alloc, io, try buildComposePs(alloc, args), .{});
}

fn handleComposeLogs(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    return runBuilt(alloc, io, try buildComposeLogs(alloc, args), .{ .keep_tail = true, .merge_stderr = true });
}

fn handleWrite(alloc: std.mem.Allocator, io: Io, args: std.json.Value, verb: WriteVerb) !mcp.ToolResult {
    if (!write_enabled) return writeRefusal(alloc, try std.fmt.allocPrint(alloc, "docker_{s}", .{@tagName(verb)}));
    return runBuilt(alloc, io, try buildWrite(alloc, verb, args), .{ .merge_stderr = true });
}

fn handleStart(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    return handleWrite(alloc, io, args, .start);
}
fn handleStop(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    return handleWrite(alloc, io, args, .stop);
}
fn handleRestart(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    return handleWrite(alloc, io, args, .restart);
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
        if (stdout_reader.buffered().len > MAX_CAPTURE_BYTES or stderr_reader.buffered().len > MAX_CAPTURE_BYTES) {
            truncated = true;
            break;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }

    if (truncated) {
        return .{
            .term = .{ .exited = 0 },
            .stdout = try multi_reader.toOwnedSlice(0),
            .stderr = try multi_reader.toOwnedSlice(1),
            .truncated = true,
        };
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
// Tests (no docker required)
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

const TestCtx = struct {
    arena_state: std.heap.ArenaAllocator,
    arena: std.mem.Allocator,

    fn init(ctx: *TestCtx) void {
        ctx.arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        ctx.arena = ctx.arena_state.allocator();
        exec_fn = fakeExec;
        fake_argv = &.{};
        fake_calls = 0;
        fake_error = null;
        fake_result = .{ .term = .{ .exited = 0 }, .stdout = @constCast(""), .stderr = @constCast("") };
        write_enabled = false;
    }

    fn deinit(ctx: *TestCtx) void {
        exec_fn = execReal;
        write_enabled = false;
        ctx.arena_state.deinit();
    }

    fn args(ctx: *TestCtx, json: []const u8) !std.json.Value {
        const p = try std.json.parseFromSlice(std.json.Value, ctx.arena, json, .{});
        return p.value;
    }
};

fn expectArgv(want: []const []const u8) !void {
    try std.testing.expectEqual(want.len, fake_argv.len);
    for (want, fake_argv) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "validateRef rejects empty, leading dash, control chars" {
    try validateRef("nginx");
    try validateRef("registry.local:5000/app:1.2");
    try std.testing.expectError(error.EmptyArg, validateRef(""));
    try std.testing.expectError(error.LeadingDash, validateRef("-v"));
    try std.testing.expectError(error.LeadingDash, validateRef("--privileged"));
    try std.testing.expectError(error.BadChar, validateRef("a\nb"));
    try std.testing.expectError(error.BadChar, validateRef("a\x00b"));
}

test "argv: ps / images" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    _ = try handlePs(ctx.arena, std.testing.io, try ctx.args("{}"));
    try expectArgv(&.{ "docker", "ps" });
    _ = try handlePs(ctx.arena, std.testing.io, try ctx.args("{\"all\":true}"));
    try expectArgv(&.{ "docker", "ps", "--all" });
    _ = try handleImages(ctx.arena, std.testing.io, try ctx.args("{}"));
    try expectArgv(&.{ "docker", "images" });
}

test "argv: logs default tail, clamped tail, since" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    _ = try handleLogs(ctx.arena, std.testing.io, try ctx.args("{\"container\":\"web\"}"));
    try expectArgv(&.{ "docker", "logs", "--tail", "100", "web" });
    _ = try handleLogs(ctx.arena, std.testing.io, try ctx.args("{\"container\":\"web\",\"tail\":999999,\"since\":\"10m\"}"));
    try expectArgv(&.{ "docker", "logs", "--tail", "5000", "--since", "10m", "web" });
    _ = try handleLogs(ctx.arena, std.testing.io, try ctx.args("{\"container\":\"web\",\"tail\":-5}"));
    try expectArgv(&.{ "docker", "logs", "--tail", "100", "web" });
}

test "argv: inspect, stats, compose" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    _ = try handleInspect(ctx.arena, std.testing.io, try ctx.args("{\"target\":\"abc123\"}"));
    try expectArgv(&.{ "docker", "inspect", "abc123" });
    _ = try handleStats(ctx.arena, std.testing.io, try ctx.args("{}"));
    try expectArgv(&.{ "docker", "stats", "--no-stream" });
    _ = try handleStats(ctx.arena, std.testing.io, try ctx.args("{\"container\":\"db\"}"));
    try expectArgv(&.{ "docker", "stats", "--no-stream", "db" });
    _ = try handleComposePs(ctx.arena, std.testing.io, try ctx.args("{\"file\":\"dc.yml\",\"project_dir\":\"/srv/app\",\"all\":true}"));
    try expectArgv(&.{ "docker", "compose", "-f", "dc.yml", "--project-directory", "/srv/app", "ps", "--all" });
    _ = try handleComposeLogs(ctx.arena, std.testing.io, try ctx.args("{\"service\":\"api\",\"tail\":20,\"since\":\"1h\"}"));
    try expectArgv(&.{ "docker", "compose", "logs", "--no-color", "--tail", "20", "--since", "1h", "api" });
}

test "injection: leading-dash args rejected without spawning" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    const io = std.testing.io;
    const cases = [_]struct { h: mcp.ToolHandler, json: []const u8 }{
        .{ .h = handleLogs, .json = "{\"container\":\"--help\"}" },
        .{ .h = handleLogs, .json = "{\"container\":\"web\",\"since\":\"-1\"}" },
        .{ .h = handleInspect, .json = "{\"target\":\"-f\"}" },
        .{ .h = handleStats, .json = "{\"container\":\"--all\"}" },
        .{ .h = handleComposePs, .json = "{\"file\":\"--evil\"}" },
        .{ .h = handleComposePs, .json = "{\"project_dir\":\"-x\"}" },
        .{ .h = handleComposeLogs, .json = "{\"service\":\"-x\"}" },
        .{ .h = handleLogs, .json = "{\"container\":\"\"}" },
    };
    for (cases) |c| {
        const r = try c.h(ctx.arena, io, try ctx.args(c.json));
        try std.testing.expect(r.is_error);
        try std.testing.expect(std.mem.indexOf(u8, r.text, "invalid") != null);
    }
    // Same with write enabled: still rejected.
    write_enabled = true;
    const r = try handleStop(ctx.arena, io, try ctx.args("{\"container\":\"-t\"}"));
    try std.testing.expect(r.is_error);
    try std.testing.expectEqual(@as(usize, 0), fake_calls);
}

test "write gate: refused by default, no spawn; allowed when enabled" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    const io = std.testing.io;
    const hs = [_]mcp.ToolHandler{ handleStart, handleStop, handleRestart };
    for (hs) |h| {
        const r = try h(ctx.arena, io, try ctx.args("{\"container\":\"web\"}"));
        try std.testing.expect(r.is_error);
        try std.testing.expect(std.mem.indexOf(u8, r.text, "refused") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.text, "ZMCP_DOCKER_ALLOW_WRITE=1") != null);
    }
    try std.testing.expectEqual(@as(usize, 0), fake_calls);

    write_enabled = true;
    const r = try handleRestart(ctx.arena, io, try ctx.args("{\"container\":\"web\"}"));
    try std.testing.expect(!r.is_error);
    try expectArgv(&.{ "docker", "restart", "web" });
    _ = try handleStart(ctx.arena, io, try ctx.args("{\"container\":\"web\"}"));
    try expectArgv(&.{ "docker", "start", "web" });
    _ = try handleStop(ctx.arena, io, try ctx.args("{\"container\":\"web\"}"));
    try expectArgv(&.{ "docker", "stop", "web" });
}

test "isTruthyFlag only accepts exactly 1" {
    try std.testing.expect(isTruthyFlag("1"));
    try std.testing.expect(!isTruthyFlag(""));
    try std.testing.expect(!isTruthyFlag("0"));
    try std.testing.expect(!isTruthyFlag("true"));
}

test "output cap: head kept for generic, tail kept for logs" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    const big = try ctx.arena.alloc(u8, MAX_OUTPUT_BYTES + 100);
    @memset(big, 'a');
    @memcpy(big[big.len - 3 ..], "END");
    fake_result.stdout = big;

    const r = try handlePs(ctx.arena, std.testing.io, try ctx.args("{}"));
    try std.testing.expect(!r.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "truncated") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "END") == null);

    const l = try handleLogs(ctx.arena, std.testing.io, try ctx.args("{\"container\":\"web\"}"));
    try std.testing.expect(std.mem.indexOf(u8, l.text, "truncated") != null);
    try std.testing.expect(std.mem.endsWith(u8, l.text, "END"));
    try std.testing.expect(l.text.len < MAX_OUTPUT_BYTES + 100);
}

test "missing docker binary and non-zero exit give clear errors" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fake_error = error.ExecutableNotFound;
    const r = try handlePs(ctx.arena, std.testing.io, try ctx.args("{}"));
    try std.testing.expect(r.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "'docker' CLI not found") != null);

    fake_error = null;
    fake_result = .{ .term = .{ .exited = 1 }, .stdout = @constCast(""), .stderr = @constCast("No such container: x\n") };
    const e = try handleInspect(ctx.arena, std.testing.io, try ctx.args("{\"target\":\"x\"}"));
    try std.testing.expect(e.is_error);
    try std.testing.expect(std.mem.indexOf(u8, e.text, "No such container") != null);
}

test "logs merges stderr into output" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fake_result = .{ .term = .{ .exited = 0 }, .stdout = @constCast("out\n"), .stderr = @constCast("err\n") };
    const r = try handleLogs(ctx.arena, std.testing.io, try ctx.args("{\"container\":\"web\"}"));
    try std.testing.expectEqualStrings("out\nerr\n", r.text);
}

test "tool table: names unique and schemas valid JSON" {
    for (tool_table, 0..) |t, i| {
        for (tool_table[i + 1 ..]) |u| try std.testing.expect(!std.mem.eql(u8, t.name, u.name));
        var p = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, t.input_schema_json, .{});
        p.deinit();
    }
    try std.testing.expectEqual(@as(usize, 10), tool_table.len);
}

test "redactInspect: secret-like env names and URL userinfo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw =
        \\[{"Id":"abc","Config":{"Env":["PATH=/usr/bin","DB_PASSWORD=hunter2","api_key=k1","AWS_SECRET_ACCESS_KEY=zzz","GITHUB_TOKEN=t","DATABASE_DSN=x","AUTH_HEADER=b","MY_CREDENTIALS=c","PGPASSWD=p","REDIS_URL=redis://user:pw@cache:6379/0","PLAIN=hello","NOEQUALS"],
        \\"Labels":{"url":"https://bob:s3cr3t@git.example.com/repo.git"}},"State":{"Status":"running"}}]
    ;
    const out = try redactInspect(a, raw);
    for ([_][]const u8{ "hunter2", "\"k1", "zzz", "\"t\"", "GITHUB_TOKEN=t", "user:pw", "s3cr3t", "bob:" }) |bad|
        try std.testing.expect(std.mem.indexOf(u8, out, bad) == null);
    for ([_][]const u8{ "DB_PASSWORD=[redacted]", "api_key=[redacted]", "AWS_SECRET_ACCESS_KEY=[redacted]", "GITHUB_TOKEN=[redacted]", "DATABASE_DSN=[redacted]", "AUTH_HEADER=[redacted]", "MY_CREDENTIALS=[redacted]", "PGPASSWD=[redacted]", "PATH=/usr/bin", "PLAIN=hello", "NOEQUALS", "[redacted]@cache:6379/0", "[redacted]@git.example.com/repo.git", "\"Status\": \"running\"" }) |good|
        try std.testing.expect(std.mem.indexOf(u8, out, good) != null);
}

test "redactUrlUserinfo leaves clean strings alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = "https://example.com/a@b";
    try std.testing.expectEqual(c.ptr, (try redactUrlUserinfo(a, c)).ptr);
    try std.testing.expectEqualStrings("s://[redacted]@h:1/p y", try redactUrlUserinfo(a, "s://u:p@h:1/p y"));
}

test "handleInspect redacts env, and errors on non-JSON instead of returning raw" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fake_result = .{ .term = .{ .exited = 0 }, .stdout = @constCast("[{\"Config\":{\"Env\":[\"SECRET_X=abc\",\"A=b\"]}}]"), .stderr = @constCast("") };
    const r = try handleInspect(ctx.arena, std.testing.io, try ctx.args("{\"target\":\"web\"}"));
    try std.testing.expect(!r.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "abc") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "SECRET_X=[redacted]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "A=b") != null);

    fake_result = .{ .term = .{ .exited = 0 }, .stdout = @constCast("Env: SECRET_X=abc not json"), .stderr = @constCast("") };
    const e = try handleInspect(ctx.arena, std.testing.io, try ctx.args("{\"target\":\"web\"}"));
    try std.testing.expect(e.is_error);
    try std.testing.expect(std.mem.indexOf(u8, e.text, "abc") == null);

    fake_result = .{ .term = .{ .exited = 0 }, .stdout = @constCast("[{\"Config\":{\"Env\":[\"SECRET_X=abc"), .stderr = @constCast(""), .truncated = true };
    const t = try handleInspect(ctx.arena, std.testing.io, try ctx.args("{\"target\":\"web\"}"));
    try std.testing.expect(t.is_error);
}
