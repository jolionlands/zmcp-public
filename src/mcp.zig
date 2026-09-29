//! Tiny MCP server library for stdio JSON-RPC.
//!
//! Implements the line-delimited JSON-RPC framing per the MCP spec:
//!   - one JSON object per line on stdin (\n-terminated)
//!   - one JSON object per line on stdout
//!   - logging goes to stderr, never stdout
//!
//! Surface intentionally small. Each tool defines:
//!   const tools = [_]ToolDef{ .{ .name = "...", .description = "...", .schema = ..., .handler = ... } };
//! and calls `try mcp.run(allocator, io, "<server-name>", "<version>", &tools);`
//!
//! Environment (read once by `run`, so every server gets it with no edits):
//!   ZMCP_TOOL_MODE=full|compact|lazy   how tools/list is exposed (default full)
//!   ZMCP_MAX_RESULT_BYTES=N            cap text results (default unlimited)
//!   ZMCP_TOOLS=a,b,git_*               allowlist (trailing-* globs); others off
//!   ZMCP_TOOLS_DENY=x,y*               denylist, wins over the allowlist
//!   ZMCP_READONLY=1                    keep only tools marked read_only
//!   ZMCP_HTTP=host:port                serve streamable HTTP + SSE instead of
//!                                      stdio (see mcp_http.zig for the rest)

const std = @import("std");
const builtin = @import("builtin");

pub const Io = std.Io;

const compact = @import("mcp_compact.zig");
const http = @import("mcp_http.zig");

/// Re-exported helpers (see mcp_compact.zig).
pub const compactJson = compact.compactJson;
pub const firstSentence = compact.firstSentence;
pub const truncateResult = compact.truncateResult;
pub const compactSchema = compact.compactSchema;
pub const utf8SafeLen = compact.utf8SafeLen;
pub const TOOL_DESC_CAP = compact.TOOL_DESC_CAP;

test {
    _ = compact;
    _ = http;
}

// Zig 0.16's std.os.windows no longer exposes GetStdHandle / ReadFile /
// STD_INPUT_HANDLE, so declare them here (same shape as hippo/src/mcp.zig).
const STD_INPUT_HANDLE: std.os.windows.DWORD = @bitCast(@as(i32, -10));
extern "kernel32" fn GetStdHandle(nStdHandle: std.os.windows.DWORD) callconv(.winapi) ?std.os.windows.HANDLE;
extern "kernel32" fn ReadFile(
    hFile: std.os.windows.HANDLE,
    lpBuffer: ?[*]u8,
    nNumberOfBytesToRead: std.os.windows.DWORD,
    lpNumberOfBytesRead: ?*std.os.windows.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) c_int;

pub const ToolHandler = *const fn (
    allocator: std.mem.Allocator,
    io: Io,
    args_json: std.json.Value,
) anyerror!ToolResult;

pub const ToolResult = struct {
    /// Plain text result. Owned by allocator passed to handler.
    /// To return an error to the model, set is_error=true and put the
    /// error message in text.
    text: []const u8,
    is_error: bool = false,
    /// Optional image content, emitted before the text item.
    image: ?Image = null,
};

/// MCP image content: base64-encoded bytes plus a MIME type such as
/// "image/png". Owned by the allocator passed to the handler.
pub const Image = struct {
    data_base64: []const u8,
    mime_type: []const u8,
};

pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    /// JSON Schema string describing the input. Must be a valid JSON object.
    input_schema_json: []const u8,
    handler: ToolHandler,
    /// The tool never changes state. Emitted as annotations.readOnlyHint and
    /// the only kind of tool kept when ZMCP_READONLY=1.
    read_only: bool = false,
    /// The tool can destroy or overwrite data (annotations.destructiveHint).
    destructive: bool = false,
};

pub const ServerInfo = struct {
    name: []const u8,
    version: []const u8,
};

/// Optional routing hook for servers whose tool table is built at runtime
/// (the gateway): when set, a call to any tool in the table goes here with
/// the tool's name instead of to `ToolDef.handler` (which is then never
/// invoked and may be a stub). `hook_ctx` is passed back unchanged.
pub const CallHook = *const fn (
    hook_ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: Io,
    name: []const u8,
    args_json: std.json.Value,
) anyerror!ToolResult;

/// Extra knobs for `runWithExtras`. All defaults reproduce `run` exactly.
pub const Extras = struct {
    /// Replace the exposure mode read from ZMCP_TOOL_MODE.
    mode: ?ToolMode = null,
    /// Ignore ZMCP_TOOLS / ZMCP_TOOLS_DENY / ZMCP_READONLY for this table
    /// (the caller slices its own table).
    ignore_slice_env: bool = false,
    hook: ?CallHook = null,
    hook_ctx: ?*anyopaque = null,
};

const ProtocolVersion = "2024-11-05";

/// Cap on a single inbound line. Lines past this get a -32600 error and the
/// buffer is reset instead of growing unboundedly.
pub const MAX_MCP_LINE_BYTES: usize = 16 * 1024 * 1024;

/// Lines at or below this size keep the retain-capacity fast path; above it
/// the retained capacity is released after processing so one oversized line
/// isn't pinned for the server's lifetime (mirrors pi-zig
/// MAX_READER_RETAINED_LINE_BYTES).
const MAX_RETAINED_LINE_BYTES: usize = 256 * 1024;

/// How tools/list is exposed to the model.
pub const ToolMode = enum {
    /// Every tool with its full description and schema (the historical output).
    full,
    /// Same tools, minified schemas, first-sentence descriptions.
    compact,
    /// Three meta tools (tools_search, tool_schema, tool_call) instead of the
    /// real list; real tools stay callable by name.
    lazy,
};

/// Which tools a server exposes. Applied once at startup, before the
/// ZMCP_TOOL_MODE rendering, so it composes with full/compact/lazy.
pub const Slice = struct {
    /// Names or trailing-* globs; empty = everything allowed.
    allow: []const []const u8 = &.{},
    /// Names or trailing-* globs; wins over `allow`.
    deny: []const []const u8 = &.{},
    /// Keep only tools with `read_only = true`.
    read_only: bool = false,

    pub fn isEmpty(self: Slice) bool {
        return self.allow.len == 0 and self.deny.len == 0 and !self.read_only;
    }
};

pub const Options = struct {
    mode: ToolMode = .full,
    /// 0 = unlimited. Text results longer than this are cut on a UTF-8
    /// boundary and end with a "[truncated N bytes; narrow the query]" note.
    max_result_bytes: usize = 0,
    slice: Slice = .{},
};

/// Why a tool is not exposed.
pub const DisableReason = enum {
    allow,
    deny,
    readonly,

    /// Text for the JSON-RPC error / tool result.
    pub fn message(self: DisableReason) []const u8 {
        return switch (self) {
            .allow => "tool disabled by ZMCP_TOOLS",
            .deny => "tool disabled by ZMCP_TOOLS_DENY",
            .readonly => "tool disabled by ZMCP_READONLY",
        };
    }
};

pub const Disabled = struct { name: []const u8, reason: DisableReason };

/// `pattern` is an exact name or ends in `*` (prefix glob); "*" matches all.
pub fn globMatch(pattern: []const u8, name: []const u8) bool {
    if (pattern.len > 0 and pattern[pattern.len - 1] == '*') {
        return std.mem.startsWith(u8, name, pattern[0 .. pattern.len - 1]);
    }
    return std.mem.eql(u8, pattern, name);
}

fn matchesAny(patterns: []const []const u8, name: []const u8) bool {
    for (patterns) |p| if (globMatch(p, name)) return true;
    return false;
}

/// Deny beats allow; an allowlist hides everything it does not name;
/// read-only hides tools not marked read_only.
pub fn disableReason(sl: Slice, t: ToolDef) ?DisableReason {
    if (matchesAny(sl.deny, t.name)) return .deny;
    if (sl.allow.len > 0 and !matchesAny(sl.allow, t.name)) return .allow;
    if (sl.read_only and !t.read_only) return .readonly;
    return null;
}

/// Split a comma/whitespace separated env value; entries point into `text`.
pub fn parseNameList(allocator: std.mem.Allocator, text: ?[]const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.tokenizeAny(u8, text orelse return &.{}, ", \t\r\n");
    while (it.next()) |tok| try out.append(allocator, tok);
    return out.toOwnedSlice(allocator);
}

/// Patterns in `patterns` that match no tool in `tools` (for startup warnings).
pub fn unmatchedPatterns(allocator: std.mem.Allocator, patterns: []const []const u8, tools: []const ToolDef) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    for (patterns) |p| {
        var hit = false;
        for (tools) |t| {
            if (globMatch(p, t.name)) {
                hit = true;
                break;
            }
        }
        if (!hit) try out.append(allocator, p);
    }
    return out.toOwnedSlice(allocator);
}

fn parseFlag(text: ?[]const u8) bool {
    const t = std.mem.trim(u8, text orelse return false, " \t\r\n");
    return std.mem.eql(u8, t, "1") or std.ascii.eqlIgnoreCase(t, "true") or std.ascii.eqlIgnoreCase(t, "yes");
}

/// Parse ZMCP_TOOL_MODE. Unset, empty or unknown values mean `full`.
pub fn parseToolMode(text: ?[]const u8) ToolMode {
    const t = std.mem.trim(u8, text orelse return .full, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(t, "compact")) return .compact;
    if (std.ascii.eqlIgnoreCase(t, "lazy")) return .lazy;
    return .full;
}

/// Parse ZMCP_MAX_RESULT_BYTES. Unset, invalid or 0 mean unlimited.
pub fn parseByteLimit(text: ?[]const u8) usize {
    const t = std.mem.trim(u8, text orelse return 0, " \t\r\n");
    return std.fmt.parseInt(usize, t, 10) catch 0;
}

/// The process environment behind `io`, when `io` is the standard Threaded
/// Io that `std.process.Init` provides (otherwise null: variables read as
/// unset).
fn processEnviron(io: Io) ?std.process.Environ {
    if (builtin.os.tag == .windows) return .{ .block = .global };
    const ref = std.Io.Threaded.global_single_threaded.io();
    if (io.vtable != ref.vtable) return null;
    const t: *std.Io.Threaded = @ptrCast(@alignCast(io.userdata));
    return t.environ.process_environ;
}

/// Environment variable lookup for the shared library. Caller frees.
pub fn envAlloc(allocator: std.mem.Allocator, io: Io, key: []const u8) ?[]u8 {
    const environ = processEnviron(io) orelse return null;
    return environ.getAlloc(allocator, key) catch null;
}

pub const REPO_URL = "https://" ++ "github.com/jolionlands/zmcp-public";

/// Honest identifying User-Agent: `<product> (+repo-url[; contact: X])`.
/// `product` is e.g. "zmcp-rss/0.1.0". ZMCP_CONTACT (email or URL), when
/// set, is appended inside the parentheses. Caller frees.
pub fn userAgent(allocator: std.mem.Allocator, io: Io, product: []const u8) std.mem.Allocator.Error![]u8 {
    const contact = envAlloc(allocator, io, "ZMCP_CONTACT");
    defer if (contact) |c| allocator.free(c);
    return userAgentWith(allocator, product, contact);
}

pub fn userAgentWith(allocator: std.mem.Allocator, product: []const u8, contact: ?[]const u8) std.mem.Allocator.Error![]u8 {
    const c = std.mem.trim(u8, contact orelse "", " \t\r\n");
    if (c.len == 0) return std.fmt.allocPrint(allocator, "{s} (+{s})", .{ product, REPO_URL });
    return std.fmt.allocPrint(allocator, "{s} (+{s}; contact: {s})", .{ product, REPO_URL, c });
}

test "userAgentWith formats repo url and optional contact" {
    const a = std.testing.allocator;
    const ua_a = try userAgentWith(a, "zmcp-x/0.1.0", null);
    defer a.free(ua_a);
    try std.testing.expectEqualStrings("zmcp-x/0.1.0 (+https://" ++ "github.com/jolionlands/zmcp-public)", ua_a);
    const ua_b = try userAgentWith(a, "zmcp-x/0.1.0", " me@example.com ");
    defer a.free(ua_b);
    try std.testing.expectEqualStrings("zmcp-x/0.1.0 (+https://" ++ "github.com/jolionlands/zmcp-public; contact: me@example.com)", ua_b);
}

/// Options read from the environment, plus the memory their name lists
/// point into.
pub const LoadedOptions = struct {
    opts: Options,
    texts: [5]?[]u8,
    allow: []const []const u8,
    deny: []const []const u8,

    pub fn deinit(self: *LoadedOptions, allocator: std.mem.Allocator) void {
        for (self.texts) |t| if (t) |m| allocator.free(m);
        allocator.free(self.allow);
        allocator.free(self.deny);
    }
};

/// Options from ZMCP_TOOL_MODE / ZMCP_MAX_RESULT_BYTES / ZMCP_TOOLS /
/// ZMCP_TOOLS_DENY / ZMCP_READONLY.
pub fn loadOptions(allocator: std.mem.Allocator, io: Io) !LoadedOptions {
    var texts: [5]?[]u8 = undefined;
    const keys = [_][]const u8{ "ZMCP_TOOL_MODE", "ZMCP_MAX_RESULT_BYTES", "ZMCP_TOOLS", "ZMCP_TOOLS_DENY", "ZMCP_READONLY" };
    for (keys, 0..) |k, i| texts[i] = envAlloc(allocator, io, k);
    errdefer for (texts) |t| if (t) |m| allocator.free(m);
    const allow = try parseNameList(allocator, texts[2]);
    errdefer allocator.free(allow);
    const deny = try parseNameList(allocator, texts[3]);
    return .{
        .opts = .{
            .mode = parseToolMode(texts[0]),
            .max_result_bytes = parseByteLimit(texts[1]),
            .slice = .{ .allow = allow, .deny = deny, .read_only = parseFlag(texts[4]) },
        },
        .texts = texts,
        .allow = allow,
        .deny = deny,
    };
}

/// Per-process server state shared by every transport: what the server is,
/// its tools, the exposure options, the cached tools/list body, and the lock
/// that keeps tool handlers running one at a time (as on stdio) when several
/// HTTP connections are live.
pub const Ctx = struct {
    /// Long-lived, thread-safe allocator (owns the cache).
    gpa: std.mem.Allocator,
    server: ServerInfo,
    tools: []const ToolDef,
    opts: Options = .{},
    /// Rendered `[...]` tools array for compact/lazy, built once on first use.
    list_cache: ?[]u8 = null,
    cache_mutex: Io.Mutex = .init,
    /// Serializes handleLine across HTTP connection threads.
    dispatch_mutex: Io.Mutex = .init,
    /// Tools removed by `opts.slice` (name + why), for clear call errors.
    disabled: []const Disabled = &.{},
    /// Backing store of the sliced `tools`, when slicing changed anything.
    owned_tools: ?[]ToolDef = null,
    /// Routes every tool call when set (see `CallHook`).
    hook: ?CallHook = null,
    hook_ctx: ?*anyopaque = null,

    /// Apply `opts.slice` to `tools` once, before serving. With an empty
    /// slice nothing is copied and `tools` stays the caller's table.
    pub fn applySlice(self: *Ctx) !void {
        if (self.opts.slice.isEmpty()) return;
        var kept: std.ArrayList(ToolDef) = .empty;
        errdefer kept.deinit(self.gpa);
        var off: std.ArrayList(Disabled) = .empty;
        errdefer off.deinit(self.gpa);
        for (self.tools) |t| {
            if (disableReason(self.opts.slice, t)) |r| {
                try off.append(self.gpa, .{ .name = t.name, .reason = r });
            } else try kept.append(self.gpa, t);
        }
        const kept_slice = try kept.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(kept_slice);
        self.disabled = try off.toOwnedSlice(self.gpa);
        self.owned_tools = kept_slice;
        self.tools = kept_slice;
    }

    pub fn deinit(self: *Ctx) void {
        if (self.list_cache) |c| self.gpa.free(c);
        self.list_cache = null;
        if (self.owned_tools) |t| self.gpa.free(t);
        self.owned_tools = null;
        if (self.disabled.len > 0) self.gpa.free(self.disabled);
        self.disabled = &.{};
    }

    fn disabledReasonOf(self: *const Ctx, name: []const u8) ?DisableReason {
        for (self.disabled) |d| {
            if (std.mem.eql(u8, d.name, name)) return d.reason;
        }
        return null;
    }
};

/// Warn (stderr only, never stdout) about allow/deny entries that match no tool.
fn warnUnmatched(allocator: std.mem.Allocator, server: ServerInfo, sl: Slice, tools: []const ToolDef) void {
    const lists = [_]struct { name: []const u8, items: []const []const u8 }{
        .{ .name = "ZMCP_TOOLS", .items = sl.allow },
        .{ .name = "ZMCP_TOOLS_DENY", .items = sl.deny },
    };
    for (lists) |l| {
        const missing = unmatchedPatterns(allocator, l.items, tools) catch continue;
        defer allocator.free(missing);
        for (missing) |m| std.debug.print("{s}: warning: {s} names unknown tool '{s}'\n", .{ server.name, l.name, m });
    }
}

/// Run the server until stdin EOF or a fatal error. Returns when the host closes
/// the connection. Pass a reclaiming allocator for `allocator` (for example
/// `std.process.Init.gpa`), not the permanent `Init.arena` allocator.
///
/// With ZMCP_HTTP=host:port set, serves streamable HTTP (+ legacy SSE)
/// instead of stdio and returns only on a fatal listener error.
pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    server: ServerInfo,
    tools: []const ToolDef,
) !void {
    return runWithExtras(allocator, io, server, tools, .{});
}

/// `run` with the `Extras` overrides (runtime-built tool tables, call hook).
pub fn runWithExtras(
    allocator: std.mem.Allocator,
    io: Io,
    server: ServerInfo,
    tools: []const ToolDef,
    extras: Extras,
) !void {
    var loaded = try loadOptions(allocator, io);
    defer loaded.deinit(allocator);
    if (extras.mode) |m| loaded.opts.mode = m;
    if (extras.ignore_slice_env) loaded.opts.slice = .{};
    var ctx: Ctx = .{
        .gpa = allocator,
        .server = server,
        .tools = tools,
        .opts = loaded.opts,
        .hook = extras.hook,
        .hook_ctx = extras.hook_ctx,
    };
    defer ctx.deinit();
    warnUnmatched(allocator, server, loaded.opts.slice, tools);
    try ctx.applySlice();

    if (envAlloc(allocator, io, "ZMCP_HTTP")) |addr_text| {
        defer allocator.free(addr_text);
        return runHttp(&ctx, io, addr_text);
    }

    var stdout_buf: [16 * 1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const stdout = &stdout_file_writer.interface;

    if (builtin.os.tag == .windows) {
        // std.Io stdin was reported to spin at ~100% CPU on Windows pipes
        // (hippo, 2026-05-20). Read the raw handle with a blocking ReadFile.
        var source = try WindowsStdin.init();
        return serveChunks(allocator, io, &ctx, stdout, &source);
    }

    var stdin_buf: [16 * 1024]u8 = undefined;
    var stdin_file_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buf);
    const stdin = &stdin_file_reader.interface;

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);

    while (true) {
        // Release capacity retained from an oversized previous line; below
        // the threshold keep the retain fast path. See MAX_RETAINED_LINE_BYTES.
        if (line.capacity > MAX_RETAINED_LINE_BYTES) {
            line.clearAndFree(allocator);
        } else {
            line.clearRetainingCapacity();
        }
        readLine(stdin, allocator, &line) catch |err| switch (err) {
            error.EndOfStream => return,
            error.LineTooLong => {
                try writeLineTooLong(allocator, stdout);
                continue;
            },
            else => return err,
        };
        try dispatchLine(allocator, io, &ctx, stdout, line.items);
    }
}

/// HTTP backend callback: handle one JSON-RPC message, return the owned
/// response text (no trailing newline) or null when it produces none
/// (notification). Handlers are serialized like on stdio.
fn httpCall(p: *anyopaque, allocator: std.mem.Allocator, io: Io, body: []const u8) anyerror!?[]u8 {
    const ctx: *Ctx = @ptrCast(@alignCast(p));
    ctx.dispatch_mutex.lockUncancelable(io);
    defer ctx.dispatch_mutex.unlock(io);
    var sw: std.Io.Writer.Allocating = .init(allocator);
    errdefer sw.deinit();
    try handleLineCtx(ctx, allocator, body, io, &sw.writer);
    const out = try sw.toOwnedSlice();
    const trimmed = std.mem.trimEnd(u8, out, "\r\n");
    if (trimmed.len == 0) {
        allocator.free(out);
        return null;
    }
    defer allocator.free(out);
    return try allocator.dupe(u8, trimmed);
}

fn runHttp(ctx: *Ctx, io: Io, addr_text: []const u8) !void {
    const allocator = ctx.gpa;
    var env = http.EnvStrings{};
    defer env.deinit(allocator);
    const keys = .{ "ZMCP_HTTP_ALLOW_REMOTE", "ZMCP_HTTP_TOKEN", "ZMCP_HTTP_ORIGINS", "ZMCP_HTTP_MAX_BODY" };
    env.allow_remote = envAlloc(allocator, io, keys[0]);
    env.token = envAlloc(allocator, io, keys[1]);
    env.origins = envAlloc(allocator, io, keys[2]);
    env.max_body = envAlloc(allocator, io, keys[3]);
    http.serve(allocator, io, addr_text, env, .{ .ctx = ctx, .call = httpCall }, ctx.server.name) catch |err| switch (err) {
        // Configuration mistakes were already explained on stderr; exit
        // without a stack trace.
        error.InvalidAddress, error.NonLoopbackRefused => std.process.exit(2),
        else => return err,
    };
}

/// Handle one complete, CR-stripped line and flush the reply. Shared by the
/// POSIX and Windows read loops.
fn dispatchLine(
    allocator: std.mem.Allocator,
    io: Io,
    ctx: *Ctx,
    stdout: *Io.Writer,
    line: []const u8,
) !void {
    if (line.len == 0) return;
    try handleLineCtx(ctx, allocator, line, io, stdout);
    try stdout.flush();
}

/// The -32600 reply for a line over MAX_MCP_LINE_BYTES. Shared by both loops.
fn writeLineTooLong(allocator: std.mem.Allocator, stdout: *Io.Writer) !void {
    try writeErrorResponse(allocator, stdout, .null, -32600, "invalid request", "line too long");
    try stdout.flush();
}

/// Blocking stdin source for Windows: kernel32!ReadFile on the raw handle.
/// On a pipe the thread sleeps until the parent writes, at 0% CPU.
const WindowsStdin = struct {
    handle: std.os.windows.HANDLE,
    buf: [16 * 1024]u8 = undefined,

    fn init() !WindowsStdin {
        const handle = GetStdHandle(STD_INPUT_HANDLE) orelse return error.NoStdinHandle;
        if (handle == std.os.windows.INVALID_HANDLE_VALUE) return error.NoStdinHandle;
        return .{ .handle = handle };
    }

    /// Next chunk, or null on EOF (0 bytes read, or BROKEN_PIPE when the
    /// parent closes its end).
    fn read(self: *WindowsStdin) !?[]const u8 {
        var n: std.os.windows.DWORD = 0;
        if (ReadFile(self.handle, &self.buf, @intCast(self.buf.len), &n, null) == 0) {
            return switch (std.os.windows.GetLastError()) {
                .BROKEN_PIPE, .HANDLE_EOF => null,
                else => error.ReadFailed,
            };
        }
        if (n == 0) return null;
        return self.buf[0..n];
    }
};

/// Split every complete `\n`-terminated line out of `bytes` into `out`
/// (slices into `bytes`, trailing `\r` stripped). Returns the number of bytes
/// consumed; `bytes[consumed..]` is the partial tail with no newline yet.
fn splitLines(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    out: *std.ArrayList([]const u8),
) !usize {
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, bytes, start, '\n')) |nl| {
        var line = bytes[start..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        try out.append(allocator, line);
        start = nl + 1;
    }
    return start;
}

/// Chunked read loop used on Windows. `source.read()` returns the next chunk
/// or null on EOF. Framing matches `readLine`: a line over
/// MAX_MCP_LINE_BYTES gets one -32600 reply and is skipped to its newline;
/// an unterminated final line at EOF is still handled.
fn serveChunks(
    allocator: std.mem.Allocator,
    io: Io,
    ctx: *Ctx,
    stdout: *Io.Writer,
    source: anytype,
) !void {
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    // True while skipping the rest of an oversized line.
    var discarding = false;

    while (try source.read()) |read_chunk| {
        var chunk = read_chunk;
        if (discarding) {
            const nl = std.mem.indexOfScalar(u8, chunk, '\n') orelse continue;
            discarding = false;
            try writeLineTooLong(allocator, stdout);
            chunk = chunk[nl + 1 ..];
        }
        try pending.appendSlice(allocator, chunk);

        lines.clearRetainingCapacity();
        const consumed = try splitLines(allocator, pending.items, &lines);
        for (lines.items) |line| {
            if (line.len > MAX_MCP_LINE_BYTES) {
                try writeLineTooLong(allocator, stdout);
                continue;
            }
            try dispatchLine(allocator, io, ctx, stdout, line);
        }

        const tail_len = pending.items.len - consumed;
        if (tail_len > MAX_MCP_LINE_BYTES) {
            // Oversized partial line: drop it and skip to its newline.
            discarding = true;
            pending.clearAndFree(allocator);
        } else if (tail_len == 0 and pending.capacity > MAX_RETAINED_LINE_BYTES) {
            pending.clearAndFree(allocator);
        } else {
            std.mem.copyForwards(u8, pending.items[0..tail_len], pending.items[consumed..]);
            pending.shrinkRetainingCapacity(tail_len);
        }
        if (lines.capacity > 1024) lines.clearAndFree(allocator);
    }

    if (discarding) {
        try writeLineTooLong(allocator, stdout);
    } else {
        try dispatchLine(allocator, io, ctx, stdout, pending.items);
    }
}

fn readLine(
    reader: *Io.Reader,
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
) !void {
    while (true) {
        const byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => {
                if (out.items.len == 0) return error.EndOfStream;
                return;
            },
            else => return err,
        };
        if (byte == '\n') {
            // strip optional trailing \r
            if (out.items.len > 0 and out.items[out.items.len - 1] == '\r') {
                _ = out.pop();
            }
            return;
        }
        if (out.items.len >= MAX_MCP_LINE_BYTES) {
            // Oversized line: drain to the next newline so framing stays in
            // sync, then let the caller emit an error and reset the buffer.
            while (reader.takeByte()) |b| {
                if (b == '\n') break;
            } else |_| {}
            return error.LineTooLong;
        }
        try out.append(allocator, byte);
    }
}

/// Handle one line with default (full-mode, uncapped) options. Kept for
/// callers and tests that have no Ctx.
fn handleLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    io: Io,
    server: ServerInfo,
    tools: []const ToolDef,
    stdout: *Io.Writer,
) !void {
    return handleLineOpts(allocator, line, io, server, tools, .{}, stdout);
}

fn handleLineOpts(
    allocator: std.mem.Allocator,
    line: []const u8,
    io: Io,
    server: ServerInfo,
    tools: []const ToolDef,
    opts: Options,
    stdout: *Io.Writer,
) !void {
    var ctx: Ctx = .{ .gpa = allocator, .server = server, .tools = tools, .opts = opts };
    defer ctx.deinit();
    try ctx.applySlice();
    return handleLineCtx(&ctx, allocator, line, io, stdout);
}

fn handleLineCtx(
    ctx: *Ctx,
    allocator: std.mem.Allocator,
    line: []const u8,
    io: Io,
    stdout: *Io.Writer,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| {
        try writeErrorResponse(allocator, stdout, .null, -32700, "parse error", @errorName(err));
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        try writeErrorResponse(allocator, stdout, .null, -32600, "invalid request", "expected a JSON object");
        return;
    }
    const method_v = root.object.get("method") orelse return; // notification with no method - skip
    if (method_v != .string) {
        try writeErrorResponse(allocator, stdout, .null, -32600, "invalid request", "method must be a string");
        return;
    }
    const method = method_v.string;
    const id_v = root.object.get("id");
    const params = root.object.get("params") orelse std.json.Value{ .null = {} };

    if (std.mem.eql(u8, method, "initialize")) {
        if (id_v) |request_id| try writeInitializeResponse(allocator, stdout, request_id, ctx.server, ctx.opts.mode);
    } else if (std.mem.eql(u8, method, "initialized") or std.mem.eql(u8, method, "notifications/initialized")) {
        // notification, no response
    } else if (std.mem.eql(u8, method, "tools/list")) {
        if (id_v) |request_id| try writeToolsListCtx(ctx, allocator, io, stdout, request_id);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        try handleToolCall(ctx, allocator, io, stdout, id_v, params);
    } else if (std.mem.eql(u8, method, "ping")) {
        if (id_v) |request_id| try writeEmptyResponse(allocator, stdout, request_id);
    } else if (id_v) |request_id| {
        // JSON-RPC notifications (no id) get no response.
        try writeErrorResponse(allocator, stdout, request_id, -32601, "method not found", method);
    }
}

fn writeInitializeResponse(
    allocator: std.mem.Allocator,
    stdout: *Io.Writer,
    id: std.json.Value,
    server: ServerInfo,
    mode: ToolMode,
) !void {
    var sw: std.Io.Writer.Allocating = .init(allocator);
    defer sw.deinit();
    var js = std.json.Stringify{ .writer = &sw.writer };

    try js.beginObject();
    try js.objectField("jsonrpc");
    try js.write("2.0");
    try js.objectField("id");
    try js.write(id);
    try js.objectField("result");
    try js.beginObject();
    try js.objectField("protocolVersion");
    try js.write(ProtocolVersion);
    try js.objectField("capabilities");
    try js.beginObject();
    try js.objectField("tools");
    try js.beginObject();
    if (mode != .full) {
        // The tool set is static in every mode: say so explicitly rather
        // than leaving list_changed support implied.
        try js.objectField("listChanged");
        try js.write(false);
    }
    try js.endObject();
    try js.endObject();
    try js.objectField("serverInfo");
    try js.beginObject();
    try js.objectField("name");
    try js.write(server.name);
    try js.objectField("version");
    try js.write(server.version);
    try js.endObject();
    try js.endObject();
    try js.endObject();

    try stdout.writeAll(sw.written());
    try stdout.writeByte('\n');
}

/// `annotations` for tools that declare a hint; nothing for the rest, so
/// tools without markers serialize exactly as before.
fn writeAnnotations(js: *std.json.Stringify, t: ToolDef) !void {
    if (!t.read_only and !t.destructive) return;
    try js.objectField("annotations");
    try js.beginObject();
    if (t.read_only) {
        try js.objectField("readOnlyHint");
        try js.write(true);
    }
    if (t.destructive) {
        try js.objectField("destructiveHint");
        try js.write(true);
    }
    try js.endObject();
}

fn writeToolsList(
    allocator: std.mem.Allocator,
    stdout: *Io.Writer,
    id: std.json.Value,
    tools: []const ToolDef,
) !void {
    var sw: std.Io.Writer.Allocating = .init(allocator);
    defer sw.deinit();
    var js = std.json.Stringify{ .writer = &sw.writer };

    try js.beginObject();
    try js.objectField("jsonrpc");
    try js.write("2.0");
    try js.objectField("id");
    try js.write(id);
    try js.objectField("result");
    try js.beginObject();
    try js.objectField("tools");
    try js.beginArray();
    for (tools) |t| {
        try js.beginObject();
        try js.objectField("name");
        try js.write(t.name);
        try js.objectField("description");
        try js.write(t.description);
        try js.objectField("inputSchema");
        // Re-parse and re-emit so schemas derived from multi-line Zig string
        // literals stay single-line safe for MCP's line-delimited transport.
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, t.input_schema_json, .{});
        defer parsed.deinit();
        try js.write(parsed.value);
        try writeAnnotations(&js, t);
        try js.endObject();
    }
    try js.endArray();
    try js.endObject();
    try js.endObject();

    try stdout.writeAll(sw.written());
    try stdout.writeByte('\n');
}

// ---------------------------------------------------------------------------
// Tool exposure modes
// ---------------------------------------------------------------------------

const META_SEARCH = "tools_search";
const META_SCHEMA = "tool_schema";
const META_CALL = "tool_call";

fn isMetaName(name: []const u8) bool {
    return std.mem.eql(u8, name, META_SEARCH) or std.mem.eql(u8, name, META_SCHEMA) or std.mem.eql(u8, name, META_CALL);
}

/// Render the `[...]` tools array for compact/lazy mode.
fn buildToolsArray(ctx: *Ctx) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(ctx.gpa);
    errdefer aw.deinit();
    var js = std.json.Stringify{ .writer = &aw.writer };
    try js.beginArray();
    switch (ctx.opts.mode) {
        .full, .compact => for (ctx.tools) |t| {
            try js.beginObject();
            try js.objectField("name");
            try js.write(t.name);
            try js.objectField("description");
            try js.write(compact.firstSentence(t.description, compact.TOOL_DESC_CAP));
            try js.objectField("inputSchema");
            var parsed = try std.json.parseFromSlice(std.json.Value, ctx.gpa, t.input_schema_json, .{});
            defer parsed.deinit();
            try compact.writeCompactSchema(&js, parsed.value);
            try writeAnnotations(&js, t);
            try js.endObject();
        },
        .lazy => {
            var desc_buf: [256]u8 = undefined;
            const search_desc = try std.fmt.bufPrint(
                &desc_buf,
                "Search this server's {d} tools by keyword; returns 'name: description' lines. Then use tool_schema for arguments and tool_call to run one.",
                .{ctx.tools.len},
            );
            const metas = [_]struct { name: []const u8, desc: []const u8, schema: []const u8 }{
                .{
                    .name = META_SEARCH,
                    .desc = search_desc,
                    .schema = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"Keywords; every one must match the tool name or description. Empty lists all.\"},\"limit\":{\"type\":\"integer\",\"description\":\"Max results (default 20, max 100).\"}}}",
                },
                .{
                    .name = META_SCHEMA,
                    .desc = "Get the input schema of one or more tools by name.",
                    .schema = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"Tool name; several may be comma-separated.\"},\"names\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}}}",
                },
                .{
                    .name = META_CALL,
                    .desc = "Run a tool by name with an arguments object (see tool_schema).",
                    .schema = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"arguments\":{\"type\":\"object\"}},\"required\":[\"name\"]}",
                },
            };
            for (metas) |m| {
                try js.beginObject();
                try js.objectField("name");
                try js.write(m.name);
                try js.objectField("description");
                try js.write(m.desc);
                try js.objectField("inputSchema");
                var parsed = try std.json.parseFromSlice(std.json.Value, ctx.gpa, m.schema, .{});
                defer parsed.deinit();
                try js.write(parsed.value);
                try js.endObject();
            }
        },
    }
    try js.endArray();
    return aw.toOwnedSlice();
}

/// The cached tools array (built on first use, never rewritten afterwards,
/// so the returned slice stays valid until `Ctx.deinit`).
fn toolsArrayCached(ctx: *Ctx, io: Io) ![]const u8 {
    ctx.cache_mutex.lockUncancelable(io);
    defer ctx.cache_mutex.unlock(io);
    if (ctx.list_cache) |c| return c;
    const built = try buildToolsArray(ctx);
    ctx.list_cache = built;
    return built;
}

fn writeToolsListCtx(
    ctx: *Ctx,
    allocator: std.mem.Allocator,
    io: Io,
    stdout: *Io.Writer,
    id: std.json.Value,
) !void {
    if (ctx.opts.mode == .full) return writeToolsList(allocator, stdout, id, ctx.tools);
    const arr = try toolsArrayCached(ctx, io);
    var sw: std.Io.Writer.Allocating = .init(allocator);
    defer sw.deinit();
    var js = std.json.Stringify{ .writer = &sw.writer };
    try js.beginObject();
    try js.objectField("jsonrpc");
    try js.write("2.0");
    try js.objectField("id");
    try js.write(id);
    try js.objectField("result");
    try js.beginObject();
    try js.objectField("tools");
    try js.beginWriteRaw();
    try sw.writer.writeAll(arr);
    js.endWriteRaw();
    try js.endObject();
    try js.endObject();
    try stdout.writeAll(sw.written());
    try stdout.writeByte('\n');
}

fn findTool(tools: []const ToolDef, name: []const u8) ?*const ToolDef {
    for (tools) |*t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

fn errResult(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !ToolResult {
    return .{ .text = try std.fmt.allocPrint(arena, fmt, args), .is_error = true };
}

/// Append `text` with runs of whitespace collapsed to single spaces.
fn appendOneLine(arena: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var prev_space = false;
    for (text) |c| {
        const sp = c == ' ' or c == '\n' or c == '\r' or c == '\t';
        if (sp) {
            if (!prev_space) try out.append(arena, ' ');
        } else try out.append(arena, c);
        prev_space = sp;
    }
}

/// True when every whitespace-separated token of `query` occurs
/// (case-insensitively) in `a` or `b`. An empty query matches everything.
fn matchesAll(query: []const u8, a: []const u8, b: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, query, " \t\r\n");
    while (it.next()) |tok| {
        if (std.ascii.indexOfIgnoreCase(a, tok) == null and std.ascii.indexOfIgnoreCase(b, tok) == null) return false;
    }
    return true;
}

fn metaSearch(arena: std.mem.Allocator, tools: []const ToolDef, args: std.json.Value) !ToolResult {
    var query: []const u8 = "";
    var limit: usize = 20;
    if (args == .object) {
        if (args.object.get("query")) |q| {
            if (q != .string) return errResult(arena, "query must be a string", .{});
            query = q.string;
        }
        if (args.object.get("limit")) |l| switch (l) {
            .integer => |n| limit = if (n < 1) 1 else @min(@as(usize, @intCast(n)), 100),
            .null => {},
            else => return errResult(arena, "limit must be an integer", .{}),
        };
    } else if (args != .null) return errResult(arena, "arguments must be an object", .{});

    var out: std.ArrayList(u8) = .empty;
    var matched: usize = 0;
    var shown: usize = 0;
    // Two passes so name hits list before description-only hits.
    for ([_]bool{ true, false }) |name_pass| {
        for (tools) |t| {
            const in_name = matchesAll(query, t.name, "");
            const in_any = in_name or matchesAll(query, t.name, t.description);
            if (!in_any or in_name != name_pass) continue;
            matched += 1;
            if (shown >= limit) continue;
            shown += 1;
            try out.appendSlice(arena, t.name);
            try out.appendSlice(arena, ": ");
            try appendOneLine(arena, &out, compact.firstSentence(t.description, compact.TOOL_DESC_CAP));
            try out.append(arena, '\n');
        }
    }
    if (matched == 0) {
        return .{ .text = try std.fmt.allocPrint(arena, "no tools match '{s}'; try fewer or different words, or an empty query to list all {d}", .{ query, tools.len }) };
    }
    if (matched > shown) {
        try out.print(arena, "... {d} more matches; raise limit or narrow the query\n", .{matched - shown});
    }
    return .{ .text = std.mem.trimEnd(u8, out.items, "\n") };
}

fn metaSchema(arena: std.mem.Allocator, tools: []const ToolDef, args: std.json.Value) !ToolResult {
    if (args != .object) return errResult(arena, "arguments must be an object with name or names", .{});
    var wanted: std.ArrayList([]const u8) = .empty;
    if (args.object.get("name")) |n| {
        if (n != .string) return errResult(arena, "name must be a string", .{});
        var it = std.mem.tokenizeAny(u8, n.string, ", \t\r\n");
        while (it.next()) |tok| try wanted.append(arena, tok);
    }
    if (args.object.get("names")) |ns| {
        if (ns != .array) return errResult(arena, "names must be an array of strings", .{});
        for (ns.array.items) |item| {
            if (item != .string) return errResult(arena, "names must be an array of strings", .{});
            try wanted.append(arena, item.string);
        }
    }
    if (wanted.items.len == 0) return errResult(arena, "provide name (or names): the tool(s) to describe", .{});

    var aw: std.Io.Writer.Allocating = .init(arena);
    var js = std.json.Stringify{ .writer = &aw.writer };
    var unknown: std.ArrayList([]const u8) = .empty;
    var found: usize = 0;
    try js.beginObject();
    try js.objectField("tools");
    try js.beginArray();
    for (wanted.items) |name| {
        const t = findTool(tools, name) orelse {
            try unknown.append(arena, name);
            continue;
        };
        found += 1;
        try js.beginObject();
        try js.objectField("name");
        try js.write(t.name);
        try js.objectField("description");
        try js.write(compact.firstSentence(t.description, compact.TOOL_DESC_CAP));
        try js.objectField("inputSchema");
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, t.input_schema_json, .{});
        try compact.writeCompactSchema(&js, parsed);
        try writeAnnotations(&js, t.*);
        try js.endObject();
    }
    try js.endArray();
    if (unknown.items.len > 0) {
        try js.objectField("unknown");
        try js.write(unknown.items);
    }
    try js.endObject();
    return .{ .text = aw.written(), .is_error = found == 0 };
}

/// Run a lazy-mode meta tool. Errors returned here become JSON-RPC tool
/// errors exactly like a failing real handler.
fn callMeta(ctx: *Ctx, arena: std.mem.Allocator, io: Io, name: []const u8, args: std.json.Value) anyerror!ToolResult {
    if (std.mem.eql(u8, name, META_SEARCH)) return metaSearch(arena, ctx.tools, args);
    if (std.mem.eql(u8, name, META_SCHEMA)) return metaSchema(arena, ctx.tools, args);

    // tool_call: dispatch to the real handler with the same result semantics.
    if (args != .object) return errResult(arena, "arguments must be an object with name and arguments", .{});
    const n = args.object.get("name") orelse return errResult(arena, "missing name", .{});
    if (n != .string) return errResult(arena, "name must be a string", .{});
    if (isMetaName(n.string)) return errResult(arena, "'{s}' is a meta tool; call it directly", .{n.string});
    const tool = findTool(ctx.tools, n.string) orelse {
        if (ctx.disabledReasonOf(n.string)) |r| return errResult(arena, "{s}: '{s}'", .{ r.message(), n.string });
        return errResult(arena, "unknown tool '{s}'; use tools_search to find tool names", .{n.string});
    };
    var inner: std.json.Value = args.object.get("arguments") orelse .null;
    if (inner == .string) {
        // Some models pass the arguments object as a JSON string.
        inner = std.json.parseFromSliceLeaky(std.json.Value, arena, inner.string, .{}) catch
            return errResult(arena, "arguments is a string that is not valid JSON", .{});
    }
    if (ctx.hook) |hk| return hk(ctx.hook_ctx, arena, io, tool.name, inner);
    return tool.handler(arena, io, inner);
}

fn handleToolCall(
    ctx: *Ctx,
    allocator: std.mem.Allocator,
    io: Io,
    stdout: *Io.Writer,
    id: ?std.json.Value,
    params: std.json.Value,
) !void {
    if (params != .object) {
        if (id) |request_id| try writeErrorResponse(allocator, stdout, request_id, -32602, "invalid params", "expected object");
        return;
    }
    const name_v = params.object.get("name") orelse {
        if (id) |request_id| try writeErrorResponse(allocator, stdout, request_id, -32602, "invalid params", "missing name");
        return;
    };
    if (name_v != .string) {
        if (id) |request_id| try writeErrorResponse(allocator, stdout, request_id, -32602, "invalid params", "name must be a string");
        return;
    }
    const args_v = params.object.get("arguments") orelse std.json.Value{ .null = {} };
    const tool_name = name_v.string;

    const meta = ctx.opts.mode == .lazy and isMetaName(tool_name);
    const handler: ?ToolHandler = blk: {
        if (meta) break :blk null;
        for (ctx.tools) |t| {
            if (std.mem.eql(u8, t.name, tool_name)) break :blk t.handler;
        }
        if (id) |request_id| {
            if (ctx.disabledReasonOf(tool_name)) |r| {
                try writeErrorResponse(allocator, stdout, request_id, -32601, r.message(), tool_name);
            } else try writeErrorResponse(allocator, stdout, request_id, -32601, "tool not found", tool_name);
        }
        return;
    };

    // Allocate a small arena for the tool invocation so handlers don't have
    // to track every allocation.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var result = (if (handler) |h|
        (if (ctx.hook) |hk| hk(ctx.hook_ctx, arena, io, tool_name, args_v) else h(arena, io, args_v))
    else
        callMeta(ctx, arena, io, tool_name, args_v)) catch |err| {
        if (id) |request_id| try writeErrorResponse(allocator, stdout, request_id, -32000, "tool error", @errorName(err));
        return;
    };
    if (id == null) return;
    const request_id = id.?;

    if (ctx.opts.max_result_bytes != 0) {
        if (try compact.truncateResult(arena, result.text, ctx.opts.max_result_bytes)) |cut| result.text = cut;
    }

    var sw: std.Io.Writer.Allocating = .init(allocator);
    defer sw.deinit();
    var js = std.json.Stringify{ .writer = &sw.writer };

    try js.beginObject();
    try js.objectField("jsonrpc");
    try js.write("2.0");
    try js.objectField("id");
    try js.write(request_id);
    try js.objectField("result");
    try js.beginObject();
    try js.objectField("content");
    try js.beginArray();
    if (result.image) |img| {
        try js.beginObject();
        try js.objectField("type");
        try js.write("image");
        try js.objectField("data");
        try js.write(img.data_base64);
        try js.objectField("mimeType");
        try js.write(img.mime_type);
        try js.endObject();
    }
    try js.beginObject();
    try js.objectField("type");
    try js.write("text");
    try js.objectField("text");
    try js.write(result.text);
    try js.endObject();
    try js.endArray();
    if (result.is_error) {
        try js.objectField("isError");
        try js.write(true);
    }
    try js.endObject();
    try js.endObject();

    try stdout.writeAll(sw.written());
    try stdout.writeByte('\n');
}

fn writeEmptyResponse(
    allocator: std.mem.Allocator,
    stdout: *Io.Writer,
    id: std.json.Value,
) !void {
    var sw: std.Io.Writer.Allocating = .init(allocator);
    defer sw.deinit();
    var js = std.json.Stringify{ .writer = &sw.writer };

    try js.beginObject();
    try js.objectField("jsonrpc");
    try js.write("2.0");
    try js.objectField("id");
    try js.write(id);
    try js.objectField("result");
    try js.beginObject();
    try js.endObject();
    try js.endObject();

    try stdout.writeAll(sw.written());
    try stdout.writeByte('\n');
}

fn writeErrorResponse(
    allocator: std.mem.Allocator,
    stdout: *Io.Writer,
    id: std.json.Value,
    code: i64,
    message: []const u8,
    data: []const u8,
) !void {
    var sw: std.Io.Writer.Allocating = .init(allocator);
    defer sw.deinit();
    var js = std.json.Stringify{ .writer = &sw.writer };

    try js.beginObject();
    try js.objectField("jsonrpc");
    try js.write("2.0");
    try js.objectField("id");
    try js.write(id);
    try js.objectField("error");
    try js.beginObject();
    try js.objectField("code");
    try js.write(code);
    try js.objectField("message");
    try js.write(message);
    try js.objectField("data");
    try js.write(data);
    try js.endObject();
    try js.endObject();

    try stdout.writeAll(sw.written());
    try stdout.writeByte('\n');
}

fn imageToolForTest(_: std.mem.Allocator, _: Io, _: std.json.Value) anyerror!ToolResult {
    return .{ .text = "caption", .image = .{ .data_base64 = "AAAA", .mime_type = "image/png" } };
}

test "tools/call emits image content before text when a handler returns one" {
    const alloc = std.testing.allocator;
    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    const tools = [_]ToolDef{.{ .name = "img", .description = "", .input_schema_json = "{}", .handler = imageToolForTest }};
    try handleLine(alloc, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"img\"}}", testIo(), .{ .name = "t", .version = "0" }, &tools, &sw.writer);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"image\",\"data\":\"AAAA\",\"mimeType\":\"image/png\"},{\"type\":\"text\",\"text\":\"caption\"}]}}\n",
        sw.written(),
    );
}

test "ProtocolVersion is non-empty" {
    try std.testing.expect(ProtocolVersion.len > 0);
}

fn testIo() Io {
    const t = std.Io.Threaded.global_single_threaded;
    return t.io();
}

fn handleLineForTest(allocator: std.mem.Allocator, line: []const u8) ![]const u8 {
    var sw: std.Io.Writer.Allocating = .init(allocator);
    defer sw.deinit();
    try handleLine(allocator, line, testIo(), .{ .name = "test", .version = "0.0.0" }, &.{}, &sw.writer);
    return try allocator.dupe(u8, sw.written());
}

test "handleLine rejects non-object JSON roots instead of panicking" {
    // Batch arrays and bare scalars are parseable but not valid requests;
    // each must yield a -32600 error and the loop would continue.
    for ([_][]const u8{ "[]", "[1,2]", "\"hi\"", "42", "null" }) |line| {
        const out = try handleLineForTest(std.testing.allocator, line);
        defer std.testing.allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "-32600") != null);
    }
}

test "handleLine rejects non-string method" {
    const out = try handleLineForTest(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":42}");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "-32600") != null);
}

test "handleLine rejects tools/call with non-string params.name" {
    const out = try handleLineForTest(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":42}}");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "-32602") != null);
}

test "unknown-method notification gets no response, request still errors" {
    const notif = try handleLineForTest(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"nope/unknown\"}");
    defer std.testing.allocator.free(notif);
    try std.testing.expectEqual(@as(usize, 0), notif.len);

    const req = try handleLineForTest(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"nope/unknown\"}");
    defer std.testing.allocator.free(req);
    try std.testing.expect(std.mem.indexOf(u8, req, "-32601") != null);
}

test "known-method notifications get no response" {
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"method\":\"initialize\"}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"tools/list\"}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"missing\"}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}",
    }) | line| {
        const out = try handleLineForTest(std.testing.allocator, line);
        defer std.testing.allocator.free(out);
        try std.testing.expectEqual(@as(usize, 0), out.len);
    }
}

test "readLine caps oversized lines and keeps framing in sync" {
    const alloc = std.testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(alloc);
    try input.appendNTimes(alloc, 'x', MAX_MCP_LINE_BYTES + 8);
    try input.append(alloc, '\n');
    try input.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n");

    var reader: Io.Reader = .fixed(input.items);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);

    try std.testing.expectError(error.LineTooLong, readLine(&reader, alloc, &line));

    // The oversized remainder was drained, so the next line reads cleanly
    // and the server loop would continue.
    line.clearRetainingCapacity();
    try readLine(&reader, alloc, &line);
    try std.testing.expect(std.mem.indexOf(u8, line.items, "\"ping\"") != null);
}

test "splitLines keeps partial tails and strips CR" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, "{\"a\":1}\r\n{\"b\"");
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(std.testing.allocator);
    const consumed = try splitLines(std.testing.allocator, buf.items, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("{\"a\":1}", out.items[0]);
    try std.testing.expectEqual(@as(usize, 9), consumed);
}

/// Feeds fixed chunks to serveChunks, then EOF.
const TestChunks = struct {
    chunks: []const []const u8,
    i: usize = 0,
    fn read(self: *TestChunks) !?[]const u8 {
        if (self.i == self.chunks.len) return null;
        defer self.i += 1;
        return self.chunks[self.i];
    }
};

fn serveChunksForTest(allocator: std.mem.Allocator, chunks: []const []const u8) ![]const u8 {
    var sw: std.Io.Writer.Allocating = .init(allocator);
    defer sw.deinit();
    var src: TestChunks = .{ .chunks = chunks };
    var ctx: Ctx = .{ .gpa = allocator, .server = .{ .name = "test", .version = "0.0.0" }, .tools = &.{} };
    defer ctx.deinit();
    try serveChunks(allocator, testIo(), &ctx, &sw.writer, &src);
    return try allocator.dupe(u8, sw.written());
}

test "serveChunks reassembles lines split across chunks and handles a final unterminated line" {
    const out = try serveChunksForTest(std.testing.allocator, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"met",
        "hod\":\"ping\"}\r\n\n{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}\n",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}",
    });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}\n",
        out,
    );
}

test "serveChunks caps oversized lines and keeps framing in sync" {
    const alloc = std.testing.allocator;
    const big = try alloc.alloc(u8, MAX_MCP_LINE_BYTES / 2 + 1);
    defer alloc.free(big);
    @memset(big, 'x');
    // One oversized line spread over three chunks (the newline lands in the
    // third), then a ping in the same chunk as the newline.
    const out = try serveChunksForTest(alloc, &.{
        big,
        big,
        "xx\n{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"ping\"}\n",
    });
    defer alloc.free(out);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "-32600"));
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":5,\"result\"") != null);

    // An oversized line that arrives complete within one read errors once too.
    var one: std.ArrayList(u8) = .empty;
    defer one.deinit(alloc);
    try one.appendNTimes(alloc, 'x', MAX_MCP_LINE_BYTES + 1);
    try one.appendSlice(alloc, "\n{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"ping\"}\n");
    const out1 = try serveChunksForTest(alloc, &.{one.items});
    defer alloc.free(out1);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out1, "-32600"));
    try std.testing.expect(std.mem.indexOf(u8, out1, "\"id\":6,\"result\"") != null);

    // Oversized and still unterminated at EOF: one error, no crash.
    const out2 = try serveChunksForTest(alloc, &.{ big, big });
    defer alloc.free(out2);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out2, "-32600"));
}

// ---------------------------------------------------------------------------
// Tool exposure mode / result cap tests
// ---------------------------------------------------------------------------

fn echoTool(arena: std.mem.Allocator, _: Io, args: std.json.Value) anyerror!ToolResult {
    const text = if (args == .object) (args.object.get("text") orelse return .{ .text = "missing text", .is_error = true }) else return error.BadArgs;
    if (text != .string) return .{ .text = "text must be a string", .is_error = true };
    return .{ .text = try std.fmt.allocPrint(arena, "echo:{s}", .{text.string}) };
}

fn wideTool(_: std.mem.Allocator, _: Io, _: std.json.Value) anyerror!ToolResult {
    return .{ .text = "h\u{e9}llo w\u{f6}rld \u{20ac}\u{20ac}\u{20ac}" };
}

fn failTool(_: std.mem.Allocator, _: Io, _: std.json.Value) anyerror!ToolResult {
    return error.Kaput;
}

const sample_tools = [_]ToolDef{
    .{
        .name = "echo",
        .description = "Echo the given text back. Useful for testing the transport end to end; it never touches the network.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "title": "EchoArgs",
        \\  "properties": {
        \\    "text": {"type": "string", "description": "The text to echo back to the caller. Any Unicode is fine, and it is returned verbatim with an echo: prefix."},
        \\    "loud": {"type": "boolean", "description": "Shout."}
        \\  },
        \\  "required": ["text"],
        \\  "additionalProperties": false
        \\}
        ,
        .handler = echoTool,
    },
    .{
        .name = "wide",
        .description = "Return a fixed non-ASCII string. Handy for truncation tests.",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{},\"required\":[],\"additionalProperties\":false,\"title\":\"Nothing\"}",
        .handler = wideTool,
    },
    .{
        .name = "fail",
        .description = "Always errors. Used to check error propagation through tool_call.",
        .input_schema_json = "{\"type\":\"object\"}",
        .handler = failTool,
    },
};

fn runLine(alloc: std.mem.Allocator, opts: Options, line: []const u8) ![]u8 {
    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    try handleLineOpts(alloc, line, testIo(), .{ .name = "t", .version = "0" }, &sample_tools, opts, &sw.writer);
    return alloc.dupe(u8, sw.written());
}

fn expectContains(hay: []const u8, needle: []const u8) !void {
    if (std.mem.find(u8, hay, needle) == null) {
        std.debug.print("\n--- missing: {s}\n--- in: {s}\n", .{ needle, hay });
        return error.TestExpectedContains;
    }
}

const list_req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}";

test "full mode output is byte-identical to the historical format" {
    const alloc = std.testing.allocator;
    const out = try runLine(alloc, .{}, list_req);
    defer alloc.free(out);
    const want =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[" ++
        "{\"name\":\"echo\",\"description\":\"Echo the given text back. Useful for testing the transport end to end; it never touches the network.\",\"inputSchema\":{\"type\":\"object\",\"title\":\"EchoArgs\",\"properties\":{\"text\":{\"type\":\"string\",\"description\":\"The text to echo back to the caller. Any Unicode is fine, and it is returned verbatim with an echo: prefix.\"},\"loud\":{\"type\":\"boolean\",\"description\":\"Shout.\"}},\"required\":[\"text\"],\"additionalProperties\":false}}," ++
        "{\"name\":\"wide\",\"description\":\"Return a fixed non-ASCII string. Handy for truncation tests.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{},\"required\":[],\"additionalProperties\":false,\"title\":\"Nothing\"}}," ++
        "{\"name\":\"fail\",\"description\":\"Always errors. Used to check error propagation through tool_call.\",\"inputSchema\":{\"type\":\"object\"}}" ++
        "]}}\n";
    try std.testing.expectEqualStrings(want, out);

    const init = try runLine(alloc, .{}, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}");
    defer alloc.free(init);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"t\",\"version\":\"0\"}}}\n",
        init,
    );

    const call = try runLine(alloc, .{}, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"hi\"}}}");
    defer alloc.free(call);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"echo:hi\"}]}}\n", call);
}

test "compact mode is measurably smaller and semantically the same" {
    const alloc = std.testing.allocator;
    const full = try runLine(alloc, .{}, list_req);
    defer alloc.free(full);
    const comp = try runLine(alloc, .{ .mode = .compact }, list_req);
    defer alloc.free(comp);
    // Same three tools, but at least 25% fewer bytes on this table.
    try std.testing.expect(comp.len * 4 < full.len * 3);
    try expectContains(comp, "\"name\":\"echo\"");
    try expectContains(comp, "\"name\":\"wide\"");
    try expectContains(comp, "\"name\":\"fail\"");
    try expectContains(comp, "\"description\":\"Echo the given text back.\"");
    try expectContains(comp, "\"description\":\"Shout.\""); // short descriptions untouched
    try expectContains(comp, "\"required\":[\"text\"]");
    try std.testing.expect(std.mem.find(u8, comp, "EchoArgs") == null);
    try std.testing.expect(std.mem.find(u8, comp, "additionalProperties") == null);
    try std.testing.expect(std.mem.find(u8, comp, "\"required\":[]") == null);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, comp, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 3), parsed.value.object.get("result").?.object.get("tools").?.array.items.len);

    // Cached: a second call in the same Ctx reuses the same buffer.
    var ctx: Ctx = .{ .gpa = alloc, .server = .{ .name = "t", .version = "0" }, .tools = &sample_tools, .opts = .{ .mode = .compact } };
    defer ctx.deinit();
    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    try handleLineCtx(&ctx, alloc, list_req, testIo(), &sw.writer);
    const first_cache = ctx.list_cache.?.ptr;
    try handleLineCtx(&ctx, alloc, list_req, testIo(), &sw.writer);
    try std.testing.expect(ctx.list_cache.?.ptr == first_cache);
    try std.testing.expectEqualStrings(comp, sw.written()[0..comp.len]);
    try std.testing.expectEqualStrings(comp, sw.written()[comp.len..]);

    // Direct calls by real name still work.
    const call = try runLine(alloc, .{ .mode = .compact }, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"hi\"}}}");
    defer alloc.free(call);
    try expectContains(call, "echo:hi");
}

test "capabilities declare listChanged:false outside full mode only" {
    const alloc = std.testing.allocator;
    const init_req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}";
    const compact_init = try runLine(alloc, .{ .mode = .compact }, init_req);
    defer alloc.free(compact_init);
    try expectContains(compact_init, "\"capabilities\":{\"tools\":{\"listChanged\":false}}");
    const lazy_init = try runLine(alloc, .{ .mode = .lazy }, init_req);
    defer alloc.free(lazy_init);
    try expectContains(lazy_init, "\"capabilities\":{\"tools\":{\"listChanged\":false}}");
}

test "lazy mode lists three meta tools" {
    const alloc = std.testing.allocator;
    const lazy = try runLine(alloc, .{ .mode = .lazy }, list_req);
    defer alloc.free(lazy);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, lazy, .{});
    defer parsed.deinit();
    const arr = parsed.value.object.get("result").?.object.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqualStrings("tools_search", arr[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("tool_schema", arr[1].object.get("name").?.string);
    try std.testing.expectEqualStrings("tool_call", arr[2].object.get("name").?.string);
    try expectContains(lazy, "Search this server's 3 tools");
}

fn callText(alloc: std.mem.Allocator, opts: Options, name: []const u8, args_json: []const u8) ![]u8 {
    const line = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}", .{ name, args_json });
    defer alloc.free(line);
    return runLine(alloc, opts, line);
}

test "lazy meta tools: search, schema, dispatch and errors" {
    const alloc = std.testing.allocator;
    const lazy: Options = .{ .mode = .lazy };

    // tools_search: case-insensitive, name hits first, one line each.
    {
        const out = try callText(alloc, lazy, "tools_search", "{\"query\":\"ECHO\"}");
        defer alloc.free(out);
        try expectContains(out, "\"text\":\"echo: Echo the given text back.\"");
        try std.testing.expect(std.mem.find(u8, out, "wide") == null);
    }
    {
        const out = try callText(alloc, lazy, "tools_search", "{\"query\":\"truncation non-ascii\"}");
        defer alloc.free(out);
        try expectContains(out, "wide: Return a fixed non-ASCII string.");
    }
    {
        const out = try callText(alloc, lazy, "tools_search", "{\"query\":\"\",\"limit\":2}");
        defer alloc.free(out);
        try expectContains(out, "echo: ");
        try expectContains(out, "wide: ");
        try expectContains(out, "... 1 more matches");
    }
    {
        const out = try callText(alloc, lazy, "tools_search", "{\"query\":\"zzz-nothing\"}");
        defer alloc.free(out);
        try expectContains(out, "no tools match");
        try std.testing.expect(std.mem.find(u8, out, "isError") == null); // an empty search is not an error
    }
    {
        const out = try callText(alloc, lazy, "tools_search", "{\"query\":5}");
        defer alloc.free(out);
        try expectContains(out, "\"isError\":true");
    }

    // tool_schema: compact schema for just the named tools.
    {
        const out = try callText(alloc, lazy, "tool_schema", "{\"name\":\"echo\"}");
        defer alloc.free(out);
        try expectContains(out, "\\\"name\\\":\\\"echo\\\"");
        try expectContains(out, "\\\"required\\\":[\\\"text\\\"]");
        try std.testing.expect(std.mem.find(u8, out, "EchoArgs") == null);
        try std.testing.expect(std.mem.find(u8, out, "wide") == null);
    }
    {
        const out = try callText(alloc, lazy, "tool_schema", "{\"names\":[\"wide\",\"nope\"]}");
        defer alloc.free(out);
        try expectContains(out, "\\\"name\\\":\\\"wide\\\"");
        try expectContains(out, "\\\"unknown\\\":[\\\"nope\\\"]");
        try std.testing.expect(std.mem.find(u8, out, "isError") == null);
    }
    {
        const out = try callText(alloc, lazy, "tool_schema", "{\"name\":\"nope\"}");
        defer alloc.free(out);
        try expectContains(out, "\"isError\":true");
    }
    {
        const out = try callText(alloc, lazy, "tool_schema", "{}");
        defer alloc.free(out);
        try expectContains(out, "\"isError\":true");
    }

    // tool_call: same result semantics as a direct call.
    {
        const direct = try callText(alloc, .{}, "echo", "{\"text\":\"hi\"}");
        defer alloc.free(direct);
        const via = try callText(alloc, lazy, "tool_call", "{\"name\":\"echo\",\"arguments\":{\"text\":\"hi\"}}");
        defer alloc.free(via);
        try std.testing.expectEqualStrings(direct, via);
    }
    {
        // arguments given as a JSON string are accepted.
        const via = try callText(alloc, lazy, "tool_call", "{\"name\":\"echo\",\"arguments\":\"{\\\"text\\\":\\\"s\\\"}\"}");
        defer alloc.free(via);
        try expectContains(via, "echo:s");
    }
    {
        // Handler-level is_error results pass through untouched.
        const via = try callText(alloc, lazy, "tool_call", "{\"name\":\"echo\",\"arguments\":{}}");
        defer alloc.free(via);
        try expectContains(via, "missing text");
        try expectContains(via, "\"isError\":true");
    }
    {
        // A handler that returns an error is a JSON-RPC -32000, as when called directly.
        const via = try callText(alloc, lazy, "tool_call", "{\"name\":\"fail\",\"arguments\":{}}");
        defer alloc.free(via);
        try expectContains(via, "\"code\":-32000");
        try expectContains(via, "Kaput");
    }
    {
        const via = try callText(alloc, lazy, "tool_call", "{\"name\":\"ghost\",\"arguments\":{}}");
        defer alloc.free(via);
        try expectContains(via, "unknown tool 'ghost'");
        try expectContains(via, "\"isError\":true");
        const meta = try callText(alloc, lazy, "tool_call", "{\"name\":\"tool_call\"}");
        defer alloc.free(meta);
        try expectContains(meta, "meta tool");
        const noname = try callText(alloc, lazy, "tool_call", "{}");
        defer alloc.free(noname);
        try expectContains(noname, "missing name");
        const badjson = try callText(alloc, lazy, "tool_call", "{\"name\":\"echo\",\"arguments\":\"{nope\"}");
        defer alloc.free(badjson);
        try expectContains(badjson, "not valid JSON");
    }

    // Real names stay directly callable in lazy mode; meta names exist only there.
    {
        const direct = try callText(alloc, lazy, "echo", "{\"text\":\"d\"}");
        defer alloc.free(direct);
        try expectContains(direct, "echo:d");
        const full_meta = try callText(alloc, .{}, "tools_search", "{}");
        defer alloc.free(full_meta);
        try expectContains(full_meta, "-32601");
        const compact_meta = try callText(alloc, .{ .mode = .compact }, "tool_call", "{}");
        defer alloc.free(compact_meta);
        try expectContains(compact_meta, "-32601");
    }
}

test "ZMCP_MAX_RESULT_BYTES truncates text results on a UTF-8 boundary, off by default" {
    const alloc = std.testing.allocator;
    const line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"wide\"}}";
    const full_text = "h\u{e9}llo w\u{f6}rld \u{20ac}\u{20ac}\u{20ac}";
    const unlimited = try runLine(alloc, .{}, line);
    defer alloc.free(unlimited);
    try expectContains(unlimited, full_text);
    try std.testing.expect(std.mem.find(u8, unlimited, "truncated") == null);

    // Every cap below the text length must yield valid UTF-8 JSON that
    // reports how many bytes were dropped and keeps a true prefix.
    var cap: usize = 1;
    while (cap < full_text.len) : (cap += 1) {
        const out = try runLine(alloc, .{ .max_result_bytes = cap }, line);
        defer alloc.free(out);
        try std.testing.expect(std.unicode.utf8ValidateSlice(out));
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out, .{});
        defer parsed.deinit();
        const text = parsed.value.object.get("result").?.object.get("content").?.array.items[0].object.get("text").?.string;
        try expectContains(text, "bytes; narrow the query]");
        const kept = text[0..std.mem.find(u8, text, "\n[truncated").?];
        try std.testing.expect(std.mem.startsWith(u8, full_text, kept));
        try std.testing.expect(kept.len <= cap);
    }
    const exact = try runLine(alloc, .{ .max_result_bytes = full_text.len }, line);
    defer alloc.free(exact);
    try std.testing.expectEqualStrings(unlimited, exact);
}

test "env option parsing" {
    try std.testing.expectEqual(ToolMode.full, parseToolMode(null));
    try std.testing.expectEqual(ToolMode.full, parseToolMode(""));
    try std.testing.expectEqual(ToolMode.full, parseToolMode("bogus"));
    try std.testing.expectEqual(ToolMode.compact, parseToolMode("compact"));
    try std.testing.expectEqual(ToolMode.compact, parseToolMode(" COMPACT\n"));
    try std.testing.expectEqual(ToolMode.lazy, parseToolMode("Lazy"));
    try std.testing.expectEqual(@as(usize, 0), parseByteLimit(null));
    try std.testing.expectEqual(@as(usize, 0), parseByteLimit("abc"));
    try std.testing.expectEqual(@as(usize, 0), parseByteLimit("-5"));
    try std.testing.expectEqual(@as(usize, 4096), parseByteLimit(" 4096 "));
}

test "re-exported compactJson works through the mcp namespace" {
    const out = try compactJson(std.testing.allocator, "{ \"a\" : null, \"b\" : [ 1 , 2 ] }");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"b\":[1,2]}", out);
}

test "hosted transport drives the real MCP core (initialize, tools/call, lazy) over HTTP" {
    const alloc = std.testing.allocator;
    var ctx: Ctx = .{ .gpa = alloc, .server = .{ .name = "t", .version = "0" }, .tools = &sample_tools, .opts = .{ .mode = .lazy } };
    defer ctx.deinit();
    const io = testIo();
    const l = try http.Listener.init(alloc, io, .{}, .{ .ctx = &ctx, .call = httpCall }, .{ .ip4 = .loopback(0) });
    const th = try std.Thread.spawn(.{}, http.Listener.serve, .{l});
    defer {
        l.shutdown();
        th.join();
        l.deinit();
    }

    const posts = [_]struct { body: []const u8, want: []const u8 }{
        .{ .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}", .want = "\"listChanged\":false" },
        .{ .body = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}", .want = "\"name\":\"tools_search\"" },
        .{ .body = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"tool_call\",\"arguments\":{\"name\":\"echo\",\"arguments\":{\"text\":\"net\"}}}}", .want = "echo:net" },
    };
    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(l.port()) };
    for (posts) |p| {
        const stream = try addr.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var wb: [1024]u8 = undefined;
        var sw = stream.writer(io, &wb);
        try sw.interface.print("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {d}\r\n\r\n{s}", .{ p.body.len, p.body });
        try sw.interface.flush();
        var rb: [1024]u8 = undefined;
        var sr = stream.reader(io, &rb);
        const resp = try sr.interface.allocRemaining(alloc, .limited(1 << 20));
        defer alloc.free(resp);
        try expectContains(resp, "HTTP/1.1 200 OK");
        try expectContains(resp, p.want);
    }
}

// ---------------------------------------------------------------------------
// Tool slicing tests (ZMCP_TOOLS / ZMCP_TOOLS_DENY / ZMCP_READONLY)
// ---------------------------------------------------------------------------

fn okTool(_: std.mem.Allocator, _: Io, _: std.json.Value) anyerror!ToolResult {
    return .{ .text = "ran" };
}

fn mk(name: []const u8, ro: bool, destructive: bool) ToolDef {
    return .{ .name = name, .description = "Does a thing.", .input_schema_json = "{\"type\":\"object\"}", .handler = okTool, .read_only = ro, .destructive = destructive };
}

const slice_tools = [_]ToolDef{
    mk("git_status", true, false),
    mk("git_log", true, false),
    mk("git_diff", true, false),
    mk("git_diff_stat", true, false),
    mk("git_push", false, true),
    mk("fs_write", false, true),
    mk("echo", false, false),
};

fn runWith(alloc: std.mem.Allocator, tools: []const ToolDef, opts: Options, line: []const u8) ![]u8 {
    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    try handleLineOpts(alloc, line, testIo(), .{ .name = "t", .version = "0" }, tools, opts, &sw.writer);
    return alloc.dupe(u8, sw.written());
}

/// Names in a tools/list reply, comma-joined.
fn listedNames(alloc: std.mem.Allocator, opts: Options) ![]u8 {
    const out = try runWith(alloc, &slice_tools, opts, list_req);
    defer alloc.free(out);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out, .{});
    defer parsed.deinit();
    var names: std.ArrayList(u8) = .empty;
    errdefer names.deinit(alloc);
    for (parsed.value.object.get("result").?.object.get("tools").?.array.items, 0..) |t, i| {
        if (i > 0) try names.append(alloc, ',');
        try names.appendSlice(alloc, t.object.get("name").?.string);
    }
    return names.toOwnedSlice(alloc);
}

fn expectListed(opts: Options, want: []const u8) !void {
    const got = try listedNames(std.testing.allocator, opts);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "slice: unset policy leaves every tool and the wire format untouched" {
    try expectListed(.{}, "git_status,git_log,git_diff,git_diff_stat,git_push,fs_write,echo");
    try std.testing.expect((Slice{}).isEmpty());
    // Tools without markers serialize with no annotations key at all.
    const out = try runLine(std.testing.allocator, .{}, list_req);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "annotations") == null);
}

test "slice: glob matching" {
    try std.testing.expect(globMatch("git_log", "git_log"));
    try std.testing.expect(!globMatch("git_log", "git_log2"));
    try std.testing.expect(globMatch("git_*", "git_log"));
    try std.testing.expect(globMatch("git_*", "git_"));
    try std.testing.expect(!globMatch("git_*", "fs_write"));
    try std.testing.expect(globMatch("*", "anything"));
    try std.testing.expect(!globMatch("", "x"));
}

test "slice: allowlist with exact names and globs" {
    try expectListed(.{ .slice = .{ .allow = &.{ "git_status", "echo" } } }, "git_status,echo");
    try expectListed(.{ .slice = .{ .allow = &.{ "git_log", "git_diff*" } } }, "git_log,git_diff,git_diff_stat");
    try expectListed(.{ .slice = .{ .allow = &.{"nope"} } }, "");
}

test "slice: denylist, and deny beats allow" {
    try expectListed(.{ .slice = .{ .deny = &.{ "git_push", "fs_*" } } }, "git_status,git_log,git_diff,git_diff_stat,echo");
    try expectListed(.{ .slice = .{ .allow = &.{"git_*"}, .deny = &.{ "git_push", "git_diff*" } } }, "git_status,git_log");
    try expectListed(.{ .slice = .{ .allow = &.{"git_push"}, .deny = &.{"git_push"} } }, "");
}

test "slice: readonly keeps only read_only tools and composes with allow/deny" {
    try expectListed(.{ .slice = .{ .read_only = true } }, "git_status,git_log,git_diff,git_diff_stat");
    try expectListed(.{ .slice = .{ .read_only = true, .allow = &.{ "git_log", "git_push" } } }, "git_log");
    try expectListed(.{ .slice = .{ .read_only = true, .deny = &.{"git_diff*"} } }, "git_status,git_log");
}

test "slice: annotations emitted for hinted tools in every mode" {
    const alloc = std.testing.allocator;
    for ([_]ToolMode{ .full, .compact }) |mode| {
        const out = try runWith(alloc, &slice_tools, .{ .mode = mode }, list_req);
        defer alloc.free(out);
        try expectContains(out, "\"name\":\"git_status\",\"description\":\"Does a thing.\",\"inputSchema\":{\"type\":\"object\"},\"annotations\":{\"readOnlyHint\":true}");
        try expectContains(out, "\"name\":\"git_push\",\"description\":\"Does a thing.\",\"inputSchema\":{\"type\":\"object\"},\"annotations\":{\"destructiveHint\":true}");
        try expectContains(out, "\"name\":\"echo\",\"description\":\"Does a thing.\",\"inputSchema\":{\"type\":\"object\"}}");
    }
}

test "slice: disabled tools are rejected by tools/call and tool_call with a clear error" {
    const alloc = std.testing.allocator;
    const opts: Options = .{ .slice = .{ .allow = &.{ "git_status", "git_p*" }, .deny = &.{"git_push"}, .read_only = false } };
    // Allowed tool runs.
    const ok = try runWith(alloc, &slice_tools, opts, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"git_status\"}}");
    defer alloc.free(ok);
    try expectContains(ok, "\"text\":\"ran\"");
    // Not on the allowlist.
    const off = try runWith(alloc, &slice_tools, opts, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\"}}");
    defer alloc.free(off);
    try expectContains(off, "\"code\":-32601");
    try expectContains(off, "tool disabled by ZMCP_TOOLS\"");
    try expectContains(off, "\"data\":\"echo\"");
    // Denied (deny wins over the glob that allowed it).
    const denied = try runWith(alloc, &slice_tools, opts, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"git_push\"}}");
    defer alloc.free(denied);
    try expectContains(denied, "tool disabled by ZMCP_TOOLS_DENY");
    // Read-only mode.
    const ro = try runWith(alloc, &slice_tools, .{ .slice = .{ .read_only = true } }, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"fs_write\"}}");
    defer alloc.free(ro);
    try expectContains(ro, "tool disabled by ZMCP_READONLY");
    // A name that never existed is still plain "tool not found".
    const ghost = try runWith(alloc, &slice_tools, opts, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"ghost\"}}");
    defer alloc.free(ghost);
    try expectContains(ghost, "tool not found");

    // Same through lazy tool_call.
    const lazy: Options = .{ .mode = .lazy, .slice = opts.slice };
    const via_off = try runWith(alloc, &slice_tools, lazy, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"tool_call\",\"arguments\":{\"name\":\"echo\"}}}");
    defer alloc.free(via_off);
    try expectContains(via_off, "tool disabled by ZMCP_TOOLS: 'echo'");
    try expectContains(via_off, "\"isError\":true");
    const via_ok = try runWith(alloc, &slice_tools, lazy, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"tool_call\",\"arguments\":{\"name\":\"git_status\"}}}");
    defer alloc.free(via_ok);
    try expectContains(via_ok, "\"text\":\"ran\"");
    // Direct call of a disabled tool in lazy mode is rejected too.
    const lazy_direct = try runWith(alloc, &slice_tools, lazy, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"fs_write\"}}");
    defer alloc.free(lazy_direct);
    try expectContains(lazy_direct, "tool disabled by ZMCP_TOOLS");
}

test "slice: lazy mode search, schema and counts only see the sliced set" {
    const alloc = std.testing.allocator;
    const lazy: Options = .{ .mode = .lazy, .slice = .{ .allow = &.{ "git_log", "git_diff*" } } };

    const list = try runWith(alloc, &slice_tools, lazy, list_req);
    defer alloc.free(list);
    try expectContains(list, "Search this server's 3 tools");

    const all = try runWith(alloc, &slice_tools, lazy, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"tools_search\",\"arguments\":{}}}");
    defer alloc.free(all);
    try expectContains(all, "git_log: ");
    try expectContains(all, "git_diff: ");
    try expectContains(all, "git_diff_stat: ");
    try std.testing.expect(std.mem.find(u8, all, "git_push") == null);
    try std.testing.expect(std.mem.find(u8, all, "fs_write") == null);
    try std.testing.expect(std.mem.find(u8, all, "echo") == null);

    const searched = try runWith(alloc, &slice_tools, lazy, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"tools_search\",\"arguments\":{\"query\":\"push\"}}}");
    defer alloc.free(searched);
    try expectContains(searched, "no tools match");

    const schema = try runWith(alloc, &slice_tools, lazy, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"tool_schema\",\"arguments\":{\"names\":[\"git_log\",\"git_push\"]}}}");
    defer alloc.free(schema);
    try expectContains(schema, "\\\"name\\\":\\\"git_log\\\"");
    try expectContains(schema, "\\\"annotations\\\":{\\\"readOnlyHint\\\":true}");
    try expectContains(schema, "\\\"unknown\\\":[\\\"git_push\\\"]");
}

test "slice: env list parsing and unknown-name detection" {
    const alloc = std.testing.allocator;
    const names = try parseNameList(alloc, " git_status, git_log ,git_diff*\n,,x ");
    defer alloc.free(names);
    try std.testing.expectEqual(@as(usize, 4), names.len);
    try std.testing.expectEqualStrings("git_status", names[0]);
    try std.testing.expectEqualStrings("git_diff*", names[2]);
    const none = try parseNameList(alloc, null);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    const blank = try parseNameList(alloc, "  ,  ");
    defer alloc.free(blank);
    try std.testing.expectEqual(@as(usize, 0), blank.len);

    const missing = try unmatchedPatterns(alloc, &.{ "git_log", "typo_tool", "nothing_*", "git_*" }, &slice_tools);
    defer alloc.free(missing);
    try std.testing.expectEqual(@as(usize, 2), missing.len);
    try std.testing.expectEqualStrings("typo_tool", missing[0]);
    try std.testing.expectEqualStrings("nothing_*", missing[1]);

    try std.testing.expect(parseFlag("1"));
    try std.testing.expect(parseFlag(" true\n"));
    try std.testing.expect(!parseFlag("0"));
    try std.testing.expect(!parseFlag(null));
    try std.testing.expect(!parseFlag(""));
}

test "slice: applySlice computes the table once and frees cleanly" {
    const alloc = std.testing.allocator;
    var ctx: Ctx = .{ .gpa = alloc, .server = .{ .name = "t", .version = "0" }, .tools = &slice_tools, .opts = .{ .slice = .{ .read_only = true } } };
    defer ctx.deinit();
    try ctx.applySlice();
    try std.testing.expectEqual(@as(usize, 4), ctx.tools.len);
    try std.testing.expectEqual(@as(usize, 3), ctx.disabled.len);
    try std.testing.expectEqual(DisableReason.readonly, ctx.disabled[0].reason);
    // Empty policy: no copy at all.
    var plain: Ctx = .{ .gpa = alloc, .server = .{ .name = "t", .version = "0" }, .tools = &slice_tools };
    defer plain.deinit();
    try plain.applySlice();
    try std.testing.expect(plain.tools.ptr == (&slice_tools).ptr);
    try std.testing.expect(plain.owned_tools == null);
}

// ---------------------------------------------------------------------------
// runWith / CallHook tests
// ---------------------------------------------------------------------------

fn hookForTest(hook_ctx: ?*anyopaque, arena: std.mem.Allocator, _: Io, name: []const u8, args: std.json.Value) anyerror!ToolResult {
    const counter: *usize = @ptrCast(@alignCast(hook_ctx.?));
    counter.* += 1;
    const has_args = args == .object;
    return .{ .text = try std.fmt.allocPrint(arena, "hook:{s}:{}", .{ name, has_args }) };
}

fn neverCalled(_: std.mem.Allocator, _: Io, _: std.json.Value) anyerror!ToolResult {
    return error.HandlerMustNotRun;
}

test "call hook routes direct and lazy tool_call to the hook, not the handler" {
    const alloc = std.testing.allocator;
    var count: usize = 0;
    const tools = [_]ToolDef{.{ .name = "dyn", .description = "d", .input_schema_json = "{}", .handler = neverCalled }};

    var ctx: Ctx = .{ .gpa = alloc, .server = .{ .name = "t", .version = "0" }, .tools = &tools, .hook = hookForTest, .hook_ctx = &count };
    defer ctx.deinit();
    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    try handleLineCtx(&ctx, alloc, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"dyn\",\"arguments\":{\"a\":1}}}", testIo(), &sw.writer);
    try expectContains(sw.written(), "hook:dyn:true");
    try std.testing.expectEqual(@as(usize, 1), count);

    // Unknown names still error without reaching the hook.
    sw.clearRetainingCapacity();
    try handleLineCtx(&ctx, alloc, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"nope\"}}", testIo(), &sw.writer);
    try expectContains(sw.written(), "-32601");
    try std.testing.expectEqual(@as(usize, 1), count);

    // Lazy mode: tool_call reaches the hook too.
    ctx.opts.mode = .lazy;
    sw.clearRetainingCapacity();
    try handleLineCtx(&ctx, alloc, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"tool_call\",\"arguments\":{\"name\":\"dyn\",\"arguments\":{}}}}", testIo(), &sw.writer);
    try expectContains(sw.written(), "hook:dyn:true");
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "Ctx without a hook still calls the handler (backward compatible)" {
    const alloc = std.testing.allocator;
    const out = try runLine(alloc, .{}, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"x\"}}}");
    defer alloc.free(out);
    try expectContains(out, "echo:x");
}
