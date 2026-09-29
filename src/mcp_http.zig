//! Hosted MCP transport for mcp.zig: streamable HTTP plus legacy HTTP+SSE.
//!
//! Enabled by `ZMCP_HTTP=host:port` (a bare port means 127.0.0.1:port).
//!
//! Endpoints
//!   GET    /healthz            200 {"status":"ok"} (no token needed)
//!   POST   /mcp                one JSON-RPC message -> application/json
//!                              (or one `event: message` SSE frame when the
//!                              request's Accept includes text/event-stream);
//!                              notifications -> 202. `initialize` issues an
//!                              `Mcp-Session-Id` response header.
//!   GET    /mcp                Accept: text/event-stream opens a server
//!                              stream (keepalive comments); otherwise 405
//!   DELETE /mcp                ends the session named by Mcp-Session-Id
//!   GET    /sse                legacy (2024-11-05) stream; first frame is
//!                              `event: endpoint` -> /messages?sessionId=<id>
//!   POST   /messages?sessionId legacy request channel: 202 now, the JSON-RPC
//!                              response arrives on the /sse stream
//!
//! Safety
//!   * Binds loopback only unless ZMCP_HTTP_ALLOW_REMOTE=1.
//!   * ZMCP_HTTP_TOKEN set -> every endpoint except /healthz needs
//!     `Authorization: Bearer <token>` (constant-time compare), else 401.
//!     A token that is set but empty is a startup error (never "no auth"),
//!     and a non-loopback bind without a token is refused unless
//!     ZMCP_HTTP_INSECURE=1 explicitly accepts unauthenticated remote access.
//!   * Origin (and, on loopback binds, Host) headers are validated against
//!     loopback names plus the ZMCP_HTTP_ORIGINS allowlist (comma separated
//!     origins or hosts) to stop DNS rebinding; violations get 403. Requests
//!     without an Origin header (curl, SDKs) pass.
//!   * Body size cap (ZMCP_HTTP_MAX_BODY, default 4 MiB), header cap 16 KiB,
//!     a total read deadline per request (slow-loris), a cap on concurrent
//!     connections and on sessions.
//!   * Session ids are 128-bit random hex from the OS CSPRNG.
//!   * One request per connection (Connection: close). Each connection has its
//!     own thread, but the backend callback serializes tool handlers.
//!
//! The read deadline is enforced with poll() on POSIX; on Windows there is
//! no read timeout (blocking reads), so run behind a token there.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = Io.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;

/// The MCP core, as seen by the transport.
pub const Backend = struct {
    ctx: *anyopaque,
    /// Handle one JSON-RPC message. Returns the owned response text (no
    /// trailing newline, allocated with `alloc`) or null when there is none.
    call: *const fn (ctx: *anyopaque, alloc: Allocator, io: Io, body: []const u8) anyerror!?[]u8,
};

/// Raw environment strings (owned) that configure the listener.
pub const EnvStrings = struct {
    allow_remote: ?[]u8 = null,
    token: ?[]u8 = null,
    origins: ?[]u8 = null,
    max_body: ?[]u8 = null,
    /// ZMCP_HTTP_INSECURE: "1" allows a non-loopback bind without a token.
    insecure: ?[]u8 = null,

    pub fn deinit(self: *EnvStrings, a: Allocator) void {
        inline for (.{ "allow_remote", "token", "origins", "max_body", "insecure" }) |f| {
            if (@field(self, f)) |v| a.free(v);
            @field(self, f) = null;
        }
    }
};

pub const Config = struct {
    /// Required bearer token (null = no auth).
    token: ?[]const u8 = null,
    /// Extra allowed Origin/Host values (full origin or bare host).
    origins: []const []const u8 = &.{},
    allow_remote: bool = false,
    max_body: usize = 4 * 1024 * 1024,
    max_sessions: usize = 64,
    max_connections: usize = 32,
    /// Total time allowed to receive one request (headers + body).
    read_timeout_ms: u32 = 15_000,
    /// Interval of SSE keepalive comments.
    keepalive_ms: u32 = 15_000,
    /// Wake-up granularity of stream loops (queue check, disconnect check).
    poll_ms: u32 = 100,
    /// Per-session queued responses before /messages answers 503.
    max_queue: usize = 256,
};

pub const MAX_HEADER_BYTES: usize = 16 * 1024;

// ---------------------------------------------------------------------------
// Address policy
// ---------------------------------------------------------------------------

pub const BindError = error{ InvalidAddress, NonLoopbackRefused };

/// Parse ZMCP_HTTP: "host:port", "[v6]:port", ":port" or a bare port. A bare
/// port and "localhost" bind loopback.
pub fn parseBindAddress(text: []const u8) BindError!net.IpAddress {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return error.InvalidAddress;
    if (std.fmt.parseInt(u16, t, 10)) |port| return .{ .ip4 = .loopback(port) } else |_| {}
    if (t[0] == ':') {
        const port = std.fmt.parseInt(u16, t[1..], 10) catch return error.InvalidAddress;
        return .{ .ip4 = .loopback(port) };
    }
    if (t[0] != '[' and std.mem.findScalar(u8, t, ':') == null) return error.InvalidAddress; // port is required
    if (std.ascii.startsWithIgnoreCase(t, "localhost:")) {
        const port = std.fmt.parseInt(u16, t["localhost:".len..], 10) catch return error.InvalidAddress;
        return .{ .ip4 = .loopback(port) };
    }
    return net.IpAddress.parseLiteral(t) catch error.InvalidAddress;
}

pub fn isLoopbackAddress(addr: net.IpAddress) bool {
    switch (addr) {
        .ip4 => |a| return a.bytes[0] == 127,
        .ip6 => |a| {
            const b = a.bytes;
            if (std.mem.allEqual(u8, b[0..15], 0) and b[15] == 1) return true; // ::1
            // ::ffff:127.x.y.z
            return std.mem.allEqual(u8, b[0..10], 0) and b[10] == 0xff and b[11] == 0xff and b[12] == 127;
        },
    }
}

/// Refuse a non-loopback bind unless remote access was explicitly allowed.
pub fn checkBind(addr: net.IpAddress, allow_remote: bool) BindError!void {
    if (!allow_remote and !isLoopbackAddress(addr)) return error.NonLoopbackRefused;
}

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8 = "",
    content_length: ?usize = null,
    has_transfer_encoding: bool = false,
    expect_continue: bool = false,
    authorization: ?[]const u8 = null,
    origin: ?[]const u8 = null,
    host: ?[]const u8 = null,
    accept: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
};

pub const ParseError = error{BadRequest};

/// Parse a request head (everything before the blank line). The result
/// points into `head`.
pub fn parseRequest(head: []const u8) ParseError!Request {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const first = lines.next() orelse return error.BadRequest;
    var parts = std.mem.splitScalar(u8, first, ' ');
    const method = parts.next() orelse return error.BadRequest;
    const target = parts.next() orelse return error.BadRequest;
    const version = parts.next() orelse return error.BadRequest;
    if (parts.next() != null or method.len == 0 or target.len == 0) return error.BadRequest;
    if (!std.mem.startsWith(u8, version, "HTTP/1.")) return error.BadRequest;
    if (target[0] != '/') return error.BadRequest;

    var req: Request = .{ .method = method, .path = target };
    if (std.mem.findScalar(u8, target, '?')) |q| {
        req.path = target[0..q];
        req.query = target[q + 1 ..];
    }

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.findScalar(u8, line, ':') orelse return error.BadRequest;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            const n = std.fmt.parseInt(usize, value, 10) catch return error.BadRequest;
            if (req.content_length) |prev| if (prev != n) return error.BadRequest;
            req.content_length = n;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            req.has_transfer_encoding = true;
        } else if (std.ascii.eqlIgnoreCase(name, "expect")) {
            req.expect_continue = std.ascii.eqlIgnoreCase(value, "100-continue");
        } else if (std.ascii.eqlIgnoreCase(name, "authorization")) {
            req.authorization = value;
        } else if (std.ascii.eqlIgnoreCase(name, "origin")) {
            req.origin = value;
        } else if (std.ascii.eqlIgnoreCase(name, "host")) {
            req.host = value;
        } else if (std.ascii.eqlIgnoreCase(name, "accept")) {
            req.accept = value;
        } else if (std.ascii.eqlIgnoreCase(name, "mcp-session-id")) {
            req.session_id = value;
        }
    }
    return req;
}

/// Value of query parameter `key` (no percent-decoding; ids are hex).
pub fn queryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.findScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

fn acceptsEventStream(accept: ?[]const u8) bool {
    const a = accept orelse return false;
    return std.ascii.indexOfIgnoreCase(a, "text/event-stream") != null;
}

// ---------------------------------------------------------------------------
// Origin / auth
// ---------------------------------------------------------------------------

/// Strip a port and IPv6 brackets: "localhost:80" -> "localhost", "[::1]:80" -> "::1".
fn hostOnly(hostport: []const u8) []const u8 {
    if (hostport.len > 0 and hostport[0] == '[') {
        const end = std.mem.findScalar(u8, hostport, ']') orelse return hostport;
        return hostport[1..end];
    }
    if (std.mem.findScalar(u8, hostport, ':')) |c| return hostport[0..c];
    return hostport;
}

fn isLoopbackHost(host: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    if (std.mem.eql(u8, host, "::1")) return true;
    if (std.mem.startsWith(u8, host, "127.")) {
        const a = net.Ip4Address.parse(host, 0) catch return false;
        return a.bytes[0] == 127;
    }
    return false;
}

fn onAllowlist(cfg: *const Config, origin_or_host: []const u8, host: []const u8) bool {
    for (cfg.origins) |allowed| {
        if (std.ascii.eqlIgnoreCase(allowed, origin_or_host)) return true;
        if (std.ascii.eqlIgnoreCase(allowed, host)) return true;
    }
    return false;
}

/// DNS-rebinding guard for the Origin header. No Origin (non-browser client)
/// passes; the literal "null" only passes when allowlisted.
pub fn originAllowed(cfg: *const Config, origin: ?[]const u8) bool {
    const o = origin orelse return true;
    var rest = o;
    if (std.mem.find(u8, o, "://")) |i| rest = o[i + 3 ..];
    if (std.mem.findScalar(u8, rest, '/')) |i| rest = rest[0..i];
    const host = hostOnly(rest);
    if (std.mem.eql(u8, o, "null")) return onAllowlist(cfg, o, o);
    return isLoopbackHost(host) or onAllowlist(cfg, o, host);
}

/// Host header check for loopback-only servers (rebinding sends the
/// attacker's hostname here). Skipped when remote access is allowed.
pub fn hostAllowed(cfg: *const Config, host: ?[]const u8) bool {
    if (cfg.allow_remote) return true;
    const h = host orelse return true;
    const only = hostOnly(h);
    return isLoopbackHost(only) or onAllowlist(cfg, h, only);
}

/// Constant-time bearer check. True when no token is configured.
pub fn bearerOk(cfg: *const Config, header: ?[]const u8) bool {
    const token = cfg.token orelse return true;
    const h = header orelse return false;
    const prefix = "Bearer ";
    if (h.len < prefix.len or !std.ascii.eqlIgnoreCase(h[0..prefix.len], prefix)) return false;
    const given = std.mem.trim(u8, h[prefix.len..], " \t");
    // Hash both sides so neither content nor length is compared early-exit.
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(given, &a, .{});
    std.crypto.hash.sha2.Sha256.hash(token, &b, .{});
    return std.crypto.timing_safe.eql([32]u8, a, b);
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

pub const id_len = 32;
pub const SessionKind = enum { streamable, legacy };

const Entry = struct {
    id: [id_len]u8,
    kind: SessionKind,
    seq: u64,
    queue: std.ArrayList([]u8) = .empty,
};

pub const PopResult = union(enum) { msg: []u8, none, gone };

pub const Sessions = struct {
    gpa: Allocator,
    max: usize,
    mutex: Io.Mutex = .init,
    entries: std.ArrayList(Entry) = .empty,
    seq: u64 = 0,

    pub fn init(gpa: Allocator, max: usize) Sessions {
        return .{ .gpa = gpa, .max = max };
    }

    pub fn deinit(self: *Sessions) void {
        for (self.entries.items) |*e| freeQueue(self.gpa, e);
        self.entries.deinit(self.gpa);
    }

    fn freeQueue(gpa: Allocator, e: *Entry) void {
        for (e.queue.items) |m| gpa.free(m);
        e.queue.deinit(gpa);
    }

    fn indexOf(self: *Sessions, id: []const u8, kind: SessionKind) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (e.kind == kind and std.mem.eql(u8, &e.id, id)) return i;
        }
        return null;
    }

    /// New session with a random 128-bit id. At the cap, the oldest
    /// streamable session is evicted (they hold no resources); if none can be
    /// evicted, error.TooManySessions.
    pub fn create(self: *Sessions, io: Io, kind: SessionKind) error{ TooManySessions, EntropyUnavailable, OutOfMemory }![id_len]u8 {
        var raw: [id_len / 2]u8 = undefined;
        io.randomSecure(&raw) catch return error.EntropyUnavailable;
        const hex = std.fmt.bytesToHex(raw, .lower);

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.entries.items.len >= self.max) {
            var oldest: ?usize = null;
            for (self.entries.items, 0..) |e, i| {
                if (e.kind != .streamable) continue;
                if (oldest == null or e.seq < self.entries.items[oldest.?].seq) oldest = i;
            }
            const victim = oldest orelse return error.TooManySessions;
            var gone = self.entries.orderedRemove(victim);
            freeQueue(self.gpa, &gone);
        }
        self.seq += 1;
        try self.entries.append(self.gpa, .{ .id = hex, .kind = kind, .seq = self.seq });
        return hex;
    }

    pub fn has(self: *Sessions, io: Io, id: []const u8, kind: SessionKind) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.indexOf(id, kind) != null;
    }

    pub fn remove(self: *Sessions, io: Io, id: []const u8, kind: SessionKind) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const i = self.indexOf(id, kind) orelse return false;
        var gone = self.entries.orderedRemove(i);
        freeQueue(self.gpa, &gone);
        return true;
    }

    /// Queue `msg` (owned by the caller unless this returns success) on a
    /// legacy session's stream.
    pub fn push(self: *Sessions, io: Io, id: []const u8, msg: []u8, max_queue: usize) error{ NoSession, QueueFull, OutOfMemory }!void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const i = self.indexOf(id, .legacy) orelse return error.NoSession;
        const e = &self.entries.items[i];
        if (e.queue.items.len >= max_queue) return error.QueueFull;
        try e.queue.append(self.gpa, msg);
    }

    pub fn pop(self: *Sessions, io: Io, id: []const u8) PopResult {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const i = self.indexOf(id, .legacy) orelse return .gone;
        const e = &self.entries.items[i];
        if (e.queue.items.len == 0) return .none;
        return .{ .msg = e.queue.orderedRemove(0) };
    }

    pub fn count(self: *Sessions, io: Io) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.entries.items.len;
    }
};

// ---------------------------------------------------------------------------
// Routing (pure: no socket I/O)
// ---------------------------------------------------------------------------

/// A complete small HTTP reply. All slices must outlive the write.
pub const Reply = struct {
    status: u16,
    content_type: []const u8 = "application/json",
    body: []const u8 = "",
    /// Extra raw header lines, each ending in "\r\n".
    extra: []const u8 = "",
};

pub const Decision = union(enum) {
    reply: Reply,
    health,
    /// POST /mcp: read the body; `sse` selects the framing of the answer.
    mcp_post: struct { sse: bool },
    /// GET /mcp with Accept: text/event-stream.
    mcp_stream,
    /// DELETE /mcp (session already validated).
    mcp_delete: [id_len]u8,
    /// GET /sse.
    legacy_sse,
    /// POST /messages for this (valid) legacy session.
    legacy_post: [id_len]u8,
};

fn err(status: u16, comptime msg: []const u8, extra: []const u8) Decision {
    return .{ .reply = .{
        .status = status,
        .body = "{\"error\":\"" ++ msg ++ "\"}",
        .extra = extra,
    } };
}

fn isHex(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

fn toId(s: []const u8) ?[id_len]u8 {
    if (s.len != id_len or !isHex(s)) return null;
    var out: [id_len]u8 = undefined;
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

/// Validate a request and decide what to do with it, before any body bytes
/// are read. Order: Origin/Host (403), auth (401), route (404/405), body
/// framing and size (411/413), sessions (404).
pub fn decide(cfg: *const Config, sessions: *Sessions, io: Io, req: Request) Decision {
    if (!originAllowed(cfg, req.origin)) return err(403, "origin not allowed", "");
    if (!hostAllowed(cfg, req.host)) return err(403, "host not allowed", "");

    const is_get = std.mem.eql(u8, req.method, "GET");
    const is_post = std.mem.eql(u8, req.method, "POST");
    const is_delete = std.mem.eql(u8, req.method, "DELETE");

    if (std.mem.eql(u8, req.path, "/healthz")) {
        if (!is_get) return err(405, "method not allowed", "Allow: GET\r\n");
        return .health;
    }

    if (!bearerOk(cfg, req.authorization)) {
        return err(401, "unauthorized", "WWW-Authenticate: Bearer\r\n");
    }

    if (std.mem.eql(u8, req.path, "/mcp")) {
        if (is_post) {
            if (bodyProblem(cfg, req)) |d| return d;
            if (req.session_id) |sid| {
                const id = toId(sid) orelse return err(404, "unknown session", "");
                if (!sessions.has(io, &id, .streamable)) return err(404, "unknown session", "");
            }
            return .{ .mcp_post = .{ .sse = acceptsEventStream(req.accept) } };
        }
        if (is_get) {
            if (!acceptsEventStream(req.accept)) return err(405, "method not allowed", "Allow: POST, DELETE\r\n");
            if (req.session_id) |sid| {
                const id = toId(sid) orelse return err(404, "unknown session", "");
                if (!sessions.has(io, &id, .streamable)) return err(404, "unknown session", "");
            }
            return .mcp_stream;
        }
        if (is_delete) {
            const sid = req.session_id orelse return err(400, "missing Mcp-Session-Id", "");
            const id = toId(sid) orelse return err(404, "unknown session", "");
            if (!sessions.has(io, &id, .streamable)) return err(404, "unknown session", "");
            return .{ .mcp_delete = id };
        }
        return err(405, "method not allowed", "Allow: POST, GET, DELETE\r\n");
    }

    if (std.mem.eql(u8, req.path, "/sse")) {
        if (!is_get) return err(405, "method not allowed", "Allow: GET\r\n");
        return .legacy_sse;
    }

    if (std.mem.eql(u8, req.path, "/messages")) {
        if (!is_post) return err(405, "method not allowed", "Allow: POST\r\n");
        if (bodyProblem(cfg, req)) |d| return d;
        const sid = queryParam(req.query, "sessionId") orelse return err(400, "missing sessionId", "");
        const id = toId(sid) orelse return err(404, "unknown session", "");
        if (!sessions.has(io, &id, .legacy)) return err(404, "unknown session", "");
        return .{ .legacy_post = id };
    }

    return err(404, "not found", "");
}

fn bodyProblem(cfg: *const Config, req: Request) ?Decision {
    if (req.has_transfer_encoding) return err(411, "content-length required (chunked bodies are not supported)", "");
    const n = req.content_length orelse return err(411, "content-length required", "");
    if (n > cfg.max_body) return err(413, "body too large", "");
    return null;
}

// ---------------------------------------------------------------------------
// Response writing
// ---------------------------------------------------------------------------

fn statusText(code: u16) []const u8 {
    return switch (code) {
        100 => "Continue",
        200 => "OK",
        202 => "Accepted",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        411 => "Length Required",
        413 => "Payload Too Large",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        else => "Unknown",
    };
}

pub fn writeReply(w: *Io.Writer, r: Reply) Io.Writer.Error!void {
    try w.print("HTTP/1.1 {d} {s}\r\n", .{ r.status, statusText(r.status) });
    if (r.body.len > 0) try w.print("Content-Type: {s}\r\n", .{r.content_type});
    try w.print("Content-Length: {d}\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n", .{r.body.len});
    try w.writeAll(r.extra);
    try w.writeAll("\r\n");
    try w.writeAll(r.body);
    try w.flush();
}

/// Headers that open an SSE response (no Content-Length: the body is
/// delimited by closing the connection).
pub fn writeSseHead(w: *Io.Writer, extra: []const u8) Io.Writer.Error!void {
    try w.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache, no-transform\r\nConnection: close\r\nX-Accel-Buffering: no\r\nX-Content-Type-Options: nosniff\r\n");
    try w.writeAll(extra);
    try w.writeAll("\r\n");
}

/// One SSE frame: optional `event:` line, then one `data:` line per line of
/// `data`, then a blank line.
pub fn writeSseEvent(w: *Io.Writer, event: ?[]const u8, data: []const u8) Io.Writer.Error!void {
    if (event) |e| try w.print("event: {s}\n", .{e});
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        const l = std.mem.trimEnd(u8, line, "\r");
        try w.print("data: {s}\n", .{l});
    }
    try w.writeAll("\n");
}

pub fn isInitializeRequest(alloc: Allocator, body: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const m = parsed.value.object.get("method") orelse return false;
    return m == .string and std.mem.eql(u8, m.string, "initialize");
}

// ---------------------------------------------------------------------------
// Connection I/O
// ---------------------------------------------------------------------------

const has_poll = builtin.os.tag != .windows;

const Conn = struct {
    io: Io,
    stream: net.Stream,
    deadline_ms: i64,

    fn nowMs(io: Io) i64 {
        return Io.Clock.awake.now(io).toMilliseconds();
    }

    fn pollIn(self: *Conn, timeout_ms: i64) bool {
        if (!has_poll) return true;
        var fds = [1]posix.pollfd{.{ .fd = self.stream.socket.handle, .events = posix.POLL.IN, .revents = 0 }};
        const t: i32 = @intCast(std.math.clamp(timeout_ms, 0, 60_000));
        const n = posix.poll(&fds, t) catch return true;
        return n > 0;
    }

    fn rawRead(self: *Conn, buf: []u8) error{ReadFailed}!usize {
        var d = [1][]u8{buf};
        return self.io.vtable.netRead(self.io.userdata, self.stream.socket.handle, &d) catch return error.ReadFailed;
    }

    /// Read some bytes before the request deadline. 0 means the peer closed.
    fn read(self: *Conn, buf: []u8) error{ Timeout, ReadFailed }!usize {
        const remaining = self.deadline_ms - nowMs(self.io);
        if (remaining <= 0) return error.Timeout;
        if (!self.pollIn(remaining)) return error.Timeout;
        return self.rawRead(buf);
    }

    /// Stream loops: wait up to `ms` for the peer. Returns false when the
    /// peer has closed (or errored); stray bytes are discarded.
    fn peerAlive(self: *Conn, ms: u32) bool {
        if (!has_poll) {
            self.io.sleep(Io.Duration.fromMilliseconds(ms), .awake) catch return false;
            return true;
        }
        if (!self.pollIn(ms)) return true;
        var scratch: [256]u8 = undefined;
        const n = self.rawRead(&scratch) catch return false;
        return n != 0;
    }
};

pub const Listener = struct {
    gpa: Allocator,
    io: Io,
    cfg: Config,
    backend: Backend,
    sessions: Sessions,
    server: net.Server,
    stop: std.atomic.Value(bool) = .init(false),
    active: std.atomic.Value(usize) = .init(0),

    pub fn init(gpa: Allocator, io: Io, cfg: Config, backend: Backend, addr: net.IpAddress) !*Listener {
        try checkBind(addr, cfg.allow_remote);
        const l = try gpa.create(Listener);
        errdefer gpa.destroy(l);
        var a = addr;
        const server = try a.listen(io, .{ .reuse_address = true });
        l.* = .{
            .gpa = gpa,
            .io = io,
            .cfg = cfg,
            .backend = backend,
            .sessions = .init(gpa, cfg.max_sessions),
            .server = server,
        };
        return l;
    }

    pub fn port(self: *const Listener) u16 {
        return self.server.socket.address.getPort();
    }

    /// Accept loop; returns after `shutdown`.
    pub fn serve(self: *Listener) void {
        while (!self.stop.load(.acquire)) {
            const stream = self.server.accept(self.io) catch |e| switch (e) {
                error.SocketNotListening, error.Canceled => return,
                else => {
                    self.io.sleep(Io.Duration.fromMilliseconds(50), .awake) catch return;
                    continue;
                },
            };
            if (self.stop.load(.acquire)) {
                stream.close(self.io);
                return;
            }
            if (self.active.load(.acquire) >= self.cfg.max_connections) {
                self.rejectBusy(stream);
                continue;
            }
            _ = self.active.fetchAdd(1, .acq_rel);
            const th = std.Thread.spawn(.{}, connMain, .{ self, stream }) catch {
                _ = self.active.fetchSub(1, .acq_rel);
                self.rejectBusy(stream);
                continue;
            };
            th.detach();
        }
    }

    fn rejectBusy(self: *Listener, stream: net.Stream) void {
        defer stream.close(self.io);
        var buf: [512]u8 = undefined;
        var sw = stream.writer(self.io, &buf);
        writeReply(&sw.interface, .{ .status = 503, .body = "{\"error\":\"too many connections\"}", .extra = "Retry-After: 1\r\n" }) catch {};
    }

    /// Ask `serve` to return, and wake its blocking accept.
    pub fn shutdown(self: *Listener) void {
        self.stop.store(true, .release);
        const p = self.port();
        const target: net.IpAddress = switch (self.server.socket.address) {
            .ip4 => .{ .ip4 = .loopback(p) },
            .ip6 => .{ .ip6 = .loopback(p) },
        };
        if (target.connect(self.io, .{ .mode = .stream })) |s| s.close(self.io) else |_| {}
    }

    /// Wait (bounded) for connection threads, then release everything.
    pub fn deinit(self: *Listener) void {
        self.stop.store(true, .release);
        var waited: u32 = 0;
        while (self.active.load(.acquire) != 0 and waited < 5000) : (waited += 20) {
            self.io.sleep(Io.Duration.fromMilliseconds(20), .awake) catch break;
        }
        self.server.deinit(self.io);
        self.sessions.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }
};

fn connMain(l: *Listener, stream: net.Stream) void {
    defer {
        stream.close(l.io);
        _ = l.active.fetchSub(1, .acq_rel);
    }
    handleConnection(l, stream) catch {};
}

const ConnError = error{ Closed, WriteFailed, OutOfMemory, Timeout, ReadFailed };

fn handleConnection(l: *Listener, stream: net.Stream) ConnError!void {
    const io = l.io;
    var conn: Conn = .{ .io = io, .stream = stream, .deadline_ms = Conn.nowMs(io) + l.cfg.read_timeout_ms };
    var wbuf: [4096]u8 = undefined;
    var sw = stream.writer(io, &wbuf);
    const w = &sw.interface;

    var hdr: [MAX_HEADER_BYTES]u8 = undefined;
    var hlen: usize = 0;
    const head_end: usize = while (true) {
        if (std.mem.find(u8, hdr[0..hlen], "\r\n\r\n")) |i| break i;
        if (hlen == hdr.len) {
            writeReply(w, .{ .status = 431, .body = "{\"error\":\"headers too large\"}" }) catch {};
            return;
        }
        const n = conn.read(hdr[hlen..]) catch |e| {
            if (e == error.Timeout and hlen > 0) writeReply(w, .{ .status = 408, .body = "{\"error\":\"request timeout\"}" }) catch {};
            return;
        };
        if (n == 0) return;
        hlen += n;
    };

    const req = parseRequest(hdr[0..head_end]) catch {
        writeReply(w, .{ .status = 400, .body = "{\"error\":\"bad request\"}" }) catch {};
        return;
    };

    switch (decide(&l.cfg, &l.sessions, io, req)) {
        .reply => |r| writeReply(w, r) catch return,
        .health => writeReply(w, .{ .status = 200, .body = "{\"status\":\"ok\"}" }) catch return,
        .mcp_post => |p| try handleMcpPost(l, &conn, w, req, hdr[head_end + 4 .. hlen], p.sse),
        .mcp_stream => {
            writeSseHead(w, "") catch return;
            // Prime the stream so clients and proxies see it is live.
            w.writeAll(": stream open\n\n") catch return;
            w.flush() catch return;
            streamLoop(l, &conn, w, null);
        },
        .mcp_delete => |id| {
            _ = l.sessions.remove(io, &id, .streamable);
            writeReply(w, .{ .status = 204 }) catch return;
        },
        .legacy_sse => try handleLegacySse(l, &conn, w),
        .legacy_post => |id| try handleLegacyPost(l, &conn, w, req, hdr[head_end + 4 .. hlen], id),
    }
}

/// Read the request body (Content-Length already validated against the cap).
/// `already` is whatever followed the headers in the first reads.
fn readBody(l: *Listener, conn: *Conn, w: *Io.Writer, req: Request, already: []const u8) ConnError![]u8 {
    const len = req.content_length orelse 0;
    const buf = try l.gpa.alloc(u8, len);
    errdefer l.gpa.free(buf);
    const have = @min(already.len, len);
    @memcpy(buf[0..have], already[0..have]);
    var filled = have;
    if (filled < len and req.expect_continue) {
        w.writeAll("HTTP/1.1 100 Continue\r\n\r\n") catch return error.WriteFailed;
        w.flush() catch return error.WriteFailed;
    }
    while (filled < len) {
        const n = conn.read(buf[filled..]) catch |e| {
            if (e == error.Timeout) writeReply(w, .{ .status = 408, .body = "{\"error\":\"request timeout\"}" }) catch {};
            return e;
        };
        if (n == 0) return error.Closed;
        filled += n;
    }
    return buf;
}

fn handleMcpPost(l: *Listener, conn: *Conn, w: *Io.Writer, req: Request, already: []const u8, sse: bool) ConnError!void {
    const body = try readBody(l, conn, w, req, already);
    defer l.gpa.free(body);

    var session_hdr: [64]u8 = undefined;
    var extra: []const u8 = "";
    if (isInitializeRequest(l.gpa, body)) {
        if (l.sessions.create(l.io, .streamable)) |id| {
            extra = std.fmt.bufPrint(&session_hdr, "Mcp-Session-Id: {s}\r\n", .{id}) catch "";
        } else |_| {}
    }

    const resp = l.backend.call(l.backend.ctx, l.gpa, l.io, body) catch {
        writeReply(w, .{
            .status = 500,
            .body = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"internal error\"}}",
        }) catch {};
        return;
    };
    const text = resp orelse {
        writeReply(w, .{ .status = 202, .extra = extra }) catch return;
        return;
    };
    defer l.gpa.free(text);

    if (sse) {
        writeSseHead(w, extra) catch return;
        writeSseEvent(w, "message", text) catch return;
        w.flush() catch return;
    } else {
        writeReply(w, .{ .status = 200, .body = text, .extra = extra }) catch return;
    }
}

fn handleLegacyPost(l: *Listener, conn: *Conn, w: *Io.Writer, req: Request, already: []const u8, id: [id_len]u8) ConnError!void {
    const body = try readBody(l, conn, w, req, already);
    defer l.gpa.free(body);
    // Acknowledge first: the answer travels on the /sse stream, and a slow
    // tool call must not hold this POST open.
    writeReply(w, .{ .status = 202, .content_type = "text/plain", .body = "Accepted" }) catch return;

    const resp = l.backend.call(l.backend.ctx, l.gpa, l.io, body) catch return;
    const text = resp orelse return;
    l.sessions.push(l.io, &id, text, l.cfg.max_queue) catch {
        l.gpa.free(text);
    };
}

fn handleLegacySse(l: *Listener, conn: *Conn, w: *Io.Writer) ConnError!void {
    const id = l.sessions.create(l.io, .legacy) catch {
        writeReply(w, .{ .status = 503, .body = "{\"error\":\"too many sessions\"}", .extra = "Retry-After: 1\r\n" }) catch {};
        return;
    };
    defer _ = l.sessions.remove(l.io, &id, .legacy);
    writeSseHead(w, "") catch return;
    var ep: [64]u8 = undefined;
    const endpoint = std.fmt.bufPrint(&ep, "/messages?sessionId={s}", .{id}) catch return;
    writeSseEvent(w, "endpoint", endpoint) catch return;
    w.flush() catch return;
    streamLoop(l, conn, w, id);
}

/// Serve an open SSE stream until the peer goes away, a write fails, or the
/// listener stops. With `legacy_id`, queued responses are delivered as
/// `event: message` frames.
fn streamLoop(l: *Listener, conn: *Conn, w: *Io.Writer, legacy_id: ?[id_len]u8) void {
    // Streams outlive the request read deadline.
    var idle_ms: u32 = 0;
    while (!l.stop.load(.acquire)) {
        if (legacy_id) |id| {
            switch (l.sessions.pop(l.io, &id)) {
                .msg => |m| {
                    defer l.gpa.free(m);
                    writeSseEvent(w, "message", m) catch return;
                    w.flush() catch return;
                    idle_ms = 0;
                    continue;
                },
                .gone => return,
                .none => {},
            }
        }
        if (!conn.peerAlive(l.cfg.poll_ms)) return;
        idle_ms += l.cfg.poll_ms;
        if (idle_ms >= l.cfg.keepalive_ms) {
            w.writeAll(": keepalive\n\n") catch return;
            w.flush() catch return;
            idle_ms = 0;
        }
    }
}

/// Startup auth policy (pure). `token_env` is the raw ZMCP_HTTP_TOKEN value
/// (null = unset). Returns the trimmed token to enforce, or null for "no
/// auth", which is only acceptable on loopback binds (or with `insecure`).
pub fn authPolicy(token_env: ?[]const u8, loopback: bool, insecure: bool) error{ EmptyToken, TokenRequired }!?[]const u8 {
    if (token_env) |v| {
        const t = std.mem.trim(u8, v, " \t\r\n");
        if (t.len == 0) return error.EmptyToken;
        return t;
    }
    if (!loopback and !insecure) return error.TokenRequired;
    return null;
}

// ---------------------------------------------------------------------------
// Entry point used by mcp.run
// ---------------------------------------------------------------------------

pub fn serve(
    gpa: Allocator,
    io: Io,
    addr_text: []const u8,
    env: EnvStrings,
    backend: Backend,
    server_name: []const u8,
) !void {
    var cfg: Config = .{};
    if (env.allow_remote) |v| cfg.allow_remote = std.mem.eql(u8, std.mem.trim(u8, v, " \t\r\n"), "1");
    const insecure = if (env.insecure) |v| std.mem.eql(u8, std.mem.trim(u8, v, " \t\r\n"), "1") else false;
    if (env.max_body) |v| {
        if (std.fmt.parseInt(usize, std.mem.trim(u8, v, " \t\r\n"), 10)) |n| {
            if (n > 0) cfg.max_body = n;
        } else |_| {}
    }
    var origins: std.ArrayList([]const u8) = .empty;
    defer origins.deinit(gpa);
    if (env.origins) |v| {
        var it = std.mem.tokenizeAny(u8, v, ", \t\r\n");
        while (it.next()) |o| try origins.append(gpa, o);
        cfg.origins = origins.items;
    }

    const addr = parseBindAddress(addr_text) catch {
        std.debug.print("{s}: ZMCP_HTTP={s} is not host:port\n", .{ server_name, addr_text });
        return error.InvalidAddress;
    };
    checkBind(addr, cfg.allow_remote) catch {
        std.debug.print("{s}: refusing non-loopback bind {s}; set ZMCP_HTTP_ALLOW_REMOTE=1 (and ZMCP_HTTP_TOKEN) to expose it\n", .{ server_name, addr_text });
        return error.NonLoopbackRefused;
    };
    cfg.token = authPolicy(env.token, isLoopbackAddress(addr), insecure) catch |e| {
        switch (e) {
            error.EmptyToken => std.debug.print("{s}: ZMCP_HTTP_TOKEN is set but empty; refusing to start without authentication (unset it for a loopback-only server, or set a real token)\n", .{server_name}),
            error.TokenRequired => std.debug.print("{s}: refusing non-loopback bind {s} without ZMCP_HTTP_TOKEN; set a token, or ZMCP_HTTP_INSECURE=1 to knowingly serve every tool to anyone who can reach it\n", .{ server_name, addr_text }),
        }
        return e;
    };
    if (cfg.token == null and !isLoopbackAddress(addr)) {
        std.debug.print("{s}: WARNING ZMCP_HTTP_INSECURE=1: remote bind without a token; anyone who can reach it can call every tool\n", .{server_name});
    }

    const l = try Listener.init(gpa, io, cfg, backend, addr);
    defer l.deinit();
    std.debug.print("{s}: MCP over HTTP on port {d} (POST /mcp, GET /sse, GET /healthz){s}\n", .{
        server_name, l.port(), if (cfg.token != null) ", bearer token required" else "",
    });
    l.serve();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testIo() Io {
    const t = std.Io.Threaded.global_single_threaded;
    return t.io();
}

fn mk(method: []const u8, path: []const u8) Request {
    return .{ .method = method, .path = path };
}

fn expectReply(d: Decision, status: u16) !void {
    switch (d) {
        .reply => |r| try std.testing.expectEqual(status, r.status),
        else => return error.TestExpectedReply,
    }
}

test "parseRequest reads request line and headers case-insensitively" {
    const r = try parseRequest("POST /messages?sessionId=abc&x=1 HTTP/1.1\r\nHost: 127.0.0.1:8787\r\nCONTENT-LENGTH: 12\r\nauthorization: Bearer t0k\r\nOrigin: http://localhost:3000\r\nAccept: application/json, text/event-stream\r\nMcp-Session-Id: sid\r\nExpect: 100-continue");
    try std.testing.expectEqualStrings("POST", r.method);
    try std.testing.expectEqualStrings("/messages", r.path);
    try std.testing.expectEqualStrings("sessionId=abc&x=1", r.query);
    try std.testing.expectEqual(@as(?usize, 12), r.content_length);
    try std.testing.expectEqualStrings("Bearer t0k", r.authorization.?);
    try std.testing.expectEqualStrings("http://localhost:3000", r.origin.?);
    try std.testing.expectEqualStrings("127.0.0.1:8787", r.host.?);
    try std.testing.expect(acceptsEventStream(r.accept));
    try std.testing.expectEqualStrings("sid", r.session_id.?);
    try std.testing.expect(r.expect_continue);
    try std.testing.expectEqualStrings("abc", queryParam(r.query, "sessionId").?);
    try std.testing.expect(queryParam(r.query, "nope") == null);

    try std.testing.expectError(error.BadRequest, parseRequest("GET"));
    try std.testing.expectError(error.BadRequest, parseRequest("GET / HTTP/2.0"));
    try std.testing.expectError(error.BadRequest, parseRequest("GET nopath HTTP/1.1"));
    try std.testing.expectError(error.BadRequest, parseRequest("GET / HTTP/1.1\r\nno colon here"));
    try std.testing.expectError(error.BadRequest, parseRequest("POST / HTTP/1.1\r\nContent-Length: abc"));
    try std.testing.expectError(error.BadRequest, parseRequest("POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2"));
}

test "routing: paths, methods, health, unknown" {
    const cfg: Config = .{};
    var s = Sessions.init(std.testing.allocator, 4);
    defer s.deinit();
    const io = testIo();

    try std.testing.expect(decide(&cfg, &s, io, mk("GET", "/healthz")) == .health);
    try expectReply(decide(&cfg, &s, io, mk("POST", "/healthz")), 405);
    try expectReply(decide(&cfg, &s, io, mk("GET", "/nope")), 404);
    try expectReply(decide(&cfg, &s, io, mk("PUT", "/mcp")), 405);
    // GET /mcp without an event-stream Accept is 405.
    try expectReply(decide(&cfg, &s, io, mk("GET", "/mcp")), 405);
    var g = mk("GET", "/mcp");
    g.accept = "text/event-stream";
    try std.testing.expect(decide(&cfg, &s, io, g) == .mcp_stream);

    var p = mk("POST", "/mcp");
    p.content_length = 10;
    const dp = decide(&cfg, &s, io, p);
    try std.testing.expect(dp == .mcp_post and !dp.mcp_post.sse);
    p.accept = "application/json, text/event-stream";
    try std.testing.expect(decide(&cfg, &s, io, p).mcp_post.sse);

    try std.testing.expect(decide(&cfg, &s, io, mk("GET", "/sse")) == .legacy_sse);
    try expectReply(decide(&cfg, &s, io, mk("POST", "/sse")), 405);
    try expectReply(decide(&cfg, &s, io, mk("GET", "/messages")), 405);
}

test "routing: body framing and cap" {
    const cfg: Config = .{ .max_body = 100 };
    var s = Sessions.init(std.testing.allocator, 4);
    defer s.deinit();
    const io = testIo();

    var p = mk("POST", "/mcp");
    try expectReply(decide(&cfg, &s, io, p), 411); // no Content-Length
    p.content_length = 101;
    try expectReply(decide(&cfg, &s, io, p), 413);
    p.content_length = 100;
    try std.testing.expect(decide(&cfg, &s, io, p) == .mcp_post);
    p.has_transfer_encoding = true;
    try expectReply(decide(&cfg, &s, io, p), 411);
}

test "auth: bearer token required, constant-time compare, healthz exempt" {
    const cfg: Config = .{ .token = "s3cret" };
    var s = Sessions.init(std.testing.allocator, 4);
    defer s.deinit();
    const io = testIo();

    var p = mk("POST", "/mcp");
    p.content_length = 2;
    try expectReply(decide(&cfg, &s, io, p), 401);
    p.authorization = "Bearer wrong";
    try expectReply(decide(&cfg, &s, io, p), 401);
    p.authorization = "Bearer s3cre"; // prefix of the token
    try expectReply(decide(&cfg, &s, io, p), 401);
    p.authorization = "Basic s3cret";
    try expectReply(decide(&cfg, &s, io, p), 401);
    p.authorization = "s3cret";
    try expectReply(decide(&cfg, &s, io, p), 401);
    p.authorization = "Bearer s3cret";
    try std.testing.expect(decide(&cfg, &s, io, p) == .mcp_post);
    p.authorization = "bearer  s3cret ";
    try std.testing.expect(decide(&cfg, &s, io, p) == .mcp_post);

    try std.testing.expect(decide(&cfg, &s, io, mk("GET", "/healthz")) == .health);
    try expectReply(decide(&cfg, &s, io, mk("GET", "/sse")), 401);
    var m = mk("POST", "/messages");
    m.query = "sessionId=00000000000000000000000000000000";
    m.content_length = 2;
    try expectReply(decide(&cfg, &s, io, m), 401);
}

test "origin: rejects rebinding origins, allows loopback and allowlist" {
    var cfg: Config = .{ .origins = &.{ "https://app.example.com", "trusted.local" } };
    var s = Sessions.init(std.testing.allocator, 4);
    defer s.deinit();
    const io = testIo();
    var g = mk("GET", "/sse");

    const bad = [_][]const u8{ "http://evil.example", "https://localhost.evil.com", "http://127.0.0.1.evil.com", "null", "http://192.168.1.5:80", "https://app.example.com.evil.io" };
    for (bad) |o| {
        g.origin = o;
        try expectReply(decide(&cfg, &s, io, g), 403);
    }
    const good = [_][]const u8{ "http://localhost:3000", "https://127.0.0.1", "http://[::1]:8787", "http://LOCALHOST", "https://app.example.com", "http://trusted.local:9000" };
    for (good) |o| {
        g.origin = o;
        try std.testing.expect(decide(&cfg, &s, io, g) == .legacy_sse);
    }
    g.origin = null;
    try std.testing.expect(decide(&cfg, &s, io, g) == .legacy_sse);

    // Host header: rebinding to an attacker name is refused on loopback binds.
    g.host = "evil.example:8787";
    try expectReply(decide(&cfg, &s, io, g), 403);
    g.host = "127.0.0.1:8787";
    try std.testing.expect(decide(&cfg, &s, io, g) == .legacy_sse);
    g.host = "[::1]:8787";
    try std.testing.expect(decide(&cfg, &s, io, g) == .legacy_sse);
    cfg.allow_remote = true;
    g.host = "myhost.lan:8787";
    try std.testing.expect(decide(&cfg, &s, io, g) == .legacy_sse);
}

test "authPolicy: empty token is an error, remote needs a token or explicit insecure" {
    // Set-but-empty (or blank) is never "no auth", even with insecure.
    try std.testing.expectError(error.EmptyToken, authPolicy("", true, false));
    try std.testing.expectError(error.EmptyToken, authPolicy("  \r\n", false, false));
    try std.testing.expectError(error.EmptyToken, authPolicy("", false, true));
    // Loopback without a token keeps working.
    try std.testing.expect((try authPolicy(null, true, false)) == null);
    // Remote without a token is refused unless explicitly insecure.
    try std.testing.expectError(error.TokenRequired, authPolicy(null, false, false));
    try std.testing.expect((try authPolicy(null, false, true)) == null);
    // A real token is trimmed and enforced everywhere.
    try std.testing.expectEqualStrings("s3cret", (try authPolicy(" s3cret\n", false, false)).?);
    try std.testing.expectEqualStrings("s3cret", (try authPolicy("s3cret", true, false)).?);
}

test "bind policy: loopback by default, remote only when allowed" {
    const ok = [_][]const u8{ "127.0.0.1:8787", "8787", ":8787", "localhost:80", "[::1]:9", "127.5.5.5:1", "127.0.0.1:0" };
    for (ok) |t| try checkBind(try parseBindAddress(t), false);
    const remote = [_][]const u8{ "0.0.0.0:8787", "192.168.1.10:80", "10.0.0.1:80", "[::]:80", "[2001:db8::1]:80", "8.8.8.8:1" };
    for (remote) |t| {
        const a = try parseBindAddress(t);
        try std.testing.expectError(error.NonLoopbackRefused, checkBind(a, false));
        try checkBind(a, true);
    }
    try std.testing.expectError(error.InvalidAddress, parseBindAddress(""));
    try std.testing.expectError(error.InvalidAddress, parseBindAddress("127.0.0.1"));
    try std.testing.expectError(error.InvalidAddress, parseBindAddress("example.com:80"));
    try std.testing.expectError(error.InvalidAddress, parseBindAddress("127.0.0.1:99999"));
}

test "SSE framing: event/data lines, multi-line data, endpoint event" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeSseEvent(&aw.writer, "message", "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}");
    try writeSseEvent(&aw.writer, "endpoint", "/messages?sessionId=abc");
    try writeSseEvent(&aw.writer, null, "a\nb\r\nc");
    try std.testing.expectEqualStrings(
        "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n" ++
            "event: endpoint\ndata: /messages?sessionId=abc\n\n" ++
            "data: a\ndata: b\ndata: c\n\n",
        aw.written(),
    );

    var h: Io.Writer.Allocating = .init(std.testing.allocator);
    defer h.deinit();
    try writeSseHead(&h.writer, "Mcp-Session-Id: x\r\n");
    try std.testing.expect(std.mem.startsWith(u8, h.written(), "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, h.written(), "Mcp-Session-Id: x\r\n\r\n"));
}

test "sessions: random hex ids, validation, delete, legacy queue, cap and eviction" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var s = Sessions.init(alloc, 3);
    defer s.deinit();

    const a = try s.create(io, .streamable);
    const b = try s.create(io, .streamable);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    try std.testing.expect(isHex(&a) and a.len == 32);
    try std.testing.expect(s.has(io, &a, .streamable));
    try std.testing.expect(!s.has(io, &a, .legacy)); // kinds are separate namespaces
    try std.testing.expect(s.remove(io, &a, .streamable));
    try std.testing.expect(!s.remove(io, &a, .streamable));
    try std.testing.expect(!s.has(io, &a, .streamable));

    const l1 = try s.create(io, .legacy);
    try std.testing.expect(s.pop(io, &l1) == .none);
    try s.push(io, &l1, try alloc.dupe(u8, "one"), 2);
    try s.push(io, &l1, try alloc.dupe(u8, "two"), 2);
    const over = try alloc.dupe(u8, "three");
    defer alloc.free(over);
    try std.testing.expectError(error.QueueFull, s.push(io, &l1, over, 2));
    try std.testing.expectError(error.NoSession, s.push(io, &b, over, 2)); // streamable: no queue
    const m1 = s.pop(io, &l1).msg;
    defer alloc.free(m1);
    try std.testing.expectEqualStrings("one", m1);
    // Leave "two" queued: deinit must free it (leak check).

    // Cap: full at 3 (b, l1, c). Streamable creation evicts the oldest streamable.
    const c = try s.create(io, .streamable);
    try std.testing.expectEqual(@as(usize, 3), s.count(io));
    const d = try s.create(io, .streamable);
    try std.testing.expect(!s.has(io, &b, .streamable)); // oldest evicted
    try std.testing.expect(s.has(io, &c, .streamable) and s.has(io, &d, .streamable));
    // A legacy stream never evicts another legacy stream.
    var s2 = Sessions.init(alloc, 1);
    defer s2.deinit();
    _ = try s2.create(io, .legacy);
    try std.testing.expectError(error.TooManySessions, s2.create(io, .legacy));
}

test "routing: streamable session header validation and DELETE" {
    const cfg: Config = .{};
    var s = Sessions.init(std.testing.allocator, 4);
    defer s.deinit();
    const io = testIo();
    const id = try s.create(io, .streamable);

    var d = mk("DELETE", "/mcp");
    try expectReply(decide(&cfg, &s, io, d), 400); // no header
    d.session_id = "0123456789abcdef0123456789abcdef";
    try expectReply(decide(&cfg, &s, io, d), 404); // unknown
    d.session_id = "not-hex";
    try expectReply(decide(&cfg, &s, io, d), 404);
    d.session_id = &id;
    try std.testing.expect(decide(&cfg, &s, io, d) == .mcp_delete);

    var p = mk("POST", "/mcp");
    p.content_length = 2;
    p.session_id = "0123456789abcdef0123456789abcdef";
    try expectReply(decide(&cfg, &s, io, p), 404);
    p.session_id = &id;
    try std.testing.expect(decide(&cfg, &s, io, p) == .mcp_post);

    // Legacy messages: unknown session 404, known ok, streamable id rejected.
    var m = mk("POST", "/messages");
    m.content_length = 2;
    try expectReply(decide(&cfg, &s, io, m), 400); // no sessionId
    m.query = "sessionId=0123456789abcdef0123456789abcdef";
    try expectReply(decide(&cfg, &s, io, m), 404);
    var qbuf: [64]u8 = undefined;
    m.query = try std.fmt.bufPrint(&qbuf, "sessionId={s}", .{id});
    try expectReply(decide(&cfg, &s, io, m), 404);
    const lid = try s.create(io, .legacy);
    m.query = try std.fmt.bufPrint(&qbuf, "sessionId={s}", .{lid});
    try std.testing.expect(decide(&cfg, &s, io, m) == .legacy_post);
}

// --- end-to-end -------------------------------------------------------------

const EchoBackend = struct {
    fn call(_: *anyopaque, alloc: Allocator, _: Io, body: []const u8) anyerror!?[]u8 {
        if (std.mem.find(u8, body, "\"boom\"") != null) return error.Boom;
        if (std.mem.find(u8, body, "\"id\"") == null) return null; // notification
        if (std.mem.find(u8, body, "\"initialize\"") != null) return try alloc.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"init\":true}}");
        return try alloc.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":true}}");
    }
};

var echo_ctx: u8 = 0;

const TestServer = struct {
    l: *Listener,
    thread: std.Thread,

    fn start(cfg: Config) !TestServer {
        const io = testIo();
        const addr: net.IpAddress = .{ .ip4 = .loopback(0) };
        const l = try Listener.init(std.testing.allocator, io, cfg, .{ .ctx = &echo_ctx, .call = EchoBackend.call }, addr);
        return .{ .l = l, .thread = try std.Thread.spawn(.{}, Listener.serve, .{l}) };
    }

    fn stop(self: *TestServer) void {
        self.l.shutdown();
        self.thread.join();
        self.l.deinit();
    }

    /// Send raw bytes, read until the server closes the connection.
    fn exchange(self: *TestServer, request: []const u8) ![]u8 {
        const io = testIo();
        const addr: net.IpAddress = .{ .ip4 = .loopback(self.l.port()) };
        const stream = try addr.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var wb: [512]u8 = undefined;
        var sw = stream.writer(io, &wb);
        try sw.interface.writeAll(request);
        try sw.interface.flush();
        var rb: [1024]u8 = undefined;
        var sr = stream.reader(io, &rb);
        return sr.interface.allocRemaining(std.testing.allocator, .limited(1 << 20)) catch |e| switch (e) {
            error.ReadFailed => return try std.testing.allocator.dupe(u8, ""),
            else => return e,
        };
    }
};

fn statusOf(resp: []const u8) ?u16 {
    if (resp.len < 12 or !std.mem.startsWith(u8, resp, "HTTP/1.1 ")) return null;
    return std.fmt.parseInt(u16, resp[9..12], 10) catch null;
}

fn bodyOf(resp: []const u8) []const u8 {
    const i = std.mem.find(u8, resp, "\r\n\r\n") orelse return "";
    return resp[i + 4 ..];
}

fn postText(buf: []u8, target: []const u8, headers: []const u8, body: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "POST {s} HTTP/1.1\r\nHost: 127.0.0.1\r\n{s}Content-Length: {d}\r\n\r\n{s}", .{ target, headers, body.len, body });
}

test "e2e: POST /mcp json, notification, sse framing, healthz, auth, origin, caps" {
    var srv = try TestServer.start(.{ .token = "tok", .max_body = 64, .read_timeout_ms = 400 });
    defer srv.stop();
    const alloc = std.testing.allocator;
    var rq: [512]u8 = undefined;
    const auth = "Authorization: Bearer tok\r\n";

    // healthz needs no token.
    {
        const r = try srv.exchange("GET /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
        defer alloc.free(r);
        try std.testing.expectEqual(@as(?u16, 200), statusOf(r));
        try std.testing.expectEqualStrings("{\"status\":\"ok\"}", bodyOf(r));
    }
    // No token -> 401.
    {
        const r = try srv.exchange(try postText(&rq, "/mcp", "", "{}"));
        defer alloc.free(r);
        try std.testing.expectEqual(@as(?u16, 401), statusOf(r));
    }
    // Evil Origin -> 403 (even with the token).
    {
        const r = try srv.exchange(try postText(&rq, "/mcp", auth ++ "Origin: http://evil.example\r\n", "{}"));
        defer alloc.free(r);
        try std.testing.expectEqual(@as(?u16, 403), statusOf(r));
    }
    // JSON request -> application/json body; initialize also issues a session id.
    var sid_buf: [32]u8 = undefined;
    {
        const r = try srv.exchange(try postText(&rq, "/mcp", auth, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}"));
        defer alloc.free(r);
        try std.testing.expectEqual(@as(?u16, 200), statusOf(r));
        try std.testing.expect(std.mem.find(u8, r, "Content-Type: application/json\r\n") != null);
        try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"init\":true}}", bodyOf(r));
        const i = std.mem.find(u8, r, "Mcp-Session-Id: ").? + "Mcp-Session-Id: ".len;
        @memcpy(&sid_buf, r[i .. i + 32]);
        try std.testing.expect(isHex(&sid_buf));
    }
    // Known session id is accepted on the next call; unknown is 404; DELETE ends it.
    {
        var hb: [128]u8 = undefined;
        const hdrs = try std.fmt.bufPrint(&hb, auth ++ "Mcp-Session-Id: {s}\r\n", .{sid_buf});
        const r = try srv.exchange(try postText(&rq, "/mcp", hdrs, "{\"jsonrpc\":\"2.0\",\"id\":5}"));
        defer alloc.free(r);
        try std.testing.expectEqual(@as(?u16, 200), statusOf(r));
        const r2 = try srv.exchange(try postText(&rq, "/mcp", auth ++ "Mcp-Session-Id: 0123456789abcdef0123456789abcdef\r\n", "{}"));
        defer alloc.free(r2);
        try std.testing.expectEqual(@as(?u16, 404), statusOf(r2));
        var db: [256]u8 = undefined;
        const del = try std.fmt.bufPrint(&db, "DELETE /mcp HTTP/1.1\r\n{s}\r\n", .{hdrs});
        const r3 = try srv.exchange(del);
        defer alloc.free(r3);
        try std.testing.expectEqual(@as(?u16, 204), statusOf(r3));
        const r4 = try srv.exchange(try postText(&rq, "/mcp", hdrs, "{\"jsonrpc\":\"2.0\",\"id\":5}"));
        defer alloc.free(r4);
        try std.testing.expectEqual(@as(?u16, 404), statusOf(r4));
    }
    // Notification -> 202, empty body.
    {
        const r = try srv.exchange(try postText(&rq, "/mcp", auth, "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}"));
        defer alloc.free(r);
        try std.testing.expectEqual(@as(?u16, 202), statusOf(r));
        try std.testing.expectEqualStrings("", bodyOf(r));
    }
    // Accept: text/event-stream -> one SSE frame then close.
    {
        const r = try srv.exchange(try postText(&rq, "/mcp", auth ++ "Accept: application/json, text/event-stream\r\n", "{\"jsonrpc\":\"2.0\",\"id\":7}"));
        defer alloc.free(r);
        try std.testing.expectEqual(@as(?u16, 200), statusOf(r));
        try std.testing.expect(std.mem.find(u8, r, "Content-Type: text/event-stream\r\n") != null);
        try std.testing.expectEqualStrings("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":true}}\n\n", bodyOf(r));
    }
    // Backend failure -> 500 JSON-RPC internal error, server survives.
    {
        const r = try srv.exchange(try postText(&rq, "/mcp", auth, "\"boom\""));
        defer alloc.free(r);
        try std.testing.expectEqual(@as(?u16, 500), statusOf(r));
    }
    // Body cap: rejected from the header alone, body never read.
    {
        const r = try srv.exchange("POST /mcp HTTP/1.1\r\nAuthorization: Bearer tok\r\nContent-Length: 65\r\n\r\n");
        defer alloc.free(r);
        try std.testing.expectEqual(@as(?u16, 413), statusOf(r));
    }
    // Malformed request line, chunked body, oversized headers: no crash.
    {
        const r = try srv.exchange("garbage\r\n\r\n");
        defer alloc.free(r);
        try std.testing.expectEqual(@as(?u16, 400), statusOf(r));
        const r2 = try srv.exchange("POST /mcp HTTP/1.1\r\nAuthorization: Bearer tok\r\nTransfer-Encoding: chunked\r\n\r\n");
        defer alloc.free(r2);
        try std.testing.expectEqual(@as(?u16, 411), statusOf(r2));
        const big = try alloc.alloc(u8, MAX_HEADER_BYTES + 100);
        defer alloc.free(big);
        @memset(big, 'a');
        const r3 = try srv.exchange(big);
        defer alloc.free(r3);
        // The server may reset the connection while we are still sending, so
        // an empty read is as good as the 431.
        try std.testing.expect(statusOf(r3) == null or statusOf(r3).? == 431);
    }
    // Slow input: a request that never finishes is cut off by the deadline
    // (408 or closed), and the server still answers afterwards.
    if (has_poll) {
        const r = try srv.exchange("POST /mcp HTTP/1.1\r\nAuthorization: Bearer tok\r\nContent-Length: 50\r\n\r\n{\"partial\"");
        defer alloc.free(r);
        try std.testing.expect(statusOf(r) == null or statusOf(r).? == 408);
        const ok = try srv.exchange("GET /healthz HTTP/1.1\r\n\r\n");
        defer alloc.free(ok);
        try std.testing.expectEqual(@as(?u16, 200), statusOf(ok));
    }
}

/// Reads lines from an open SSE stream.
const SseClient = struct {
    stream: net.Stream,
    rb: [1024]u8 = undefined,
    reader: net.Stream.Reader = undefined,

    fn open(self: *SseClient, port: u16, request: []const u8) !void {
        const io = testIo();
        const addr: net.IpAddress = .{ .ip4 = .loopback(port) };
        self.stream = try addr.connect(io, .{ .mode = .stream });
        var wb: [512]u8 = undefined;
        var sw = self.stream.writer(io, &wb);
        try sw.interface.writeAll(request);
        try sw.interface.flush();
        self.reader = self.stream.reader(io, &self.rb);
    }

    fn close(self: *SseClient) void {
        self.stream.close(testIo());
    }

    /// Next line without the newline (blocks).
    fn line(self: *SseClient, alloc: Allocator) ![]u8 {
        const l = try self.reader.interface.takeDelimiterInclusive('\n');
        return alloc.dupe(u8, std.mem.trimEnd(u8, l, "\r\n"));
    }

    fn expectLine(self: *SseClient, want: []const u8) !void {
        const l = try self.line(std.testing.allocator);
        defer std.testing.allocator.free(l);
        try std.testing.expectEqualStrings(want, l);
    }

    /// Skip HTTP response headers (through the blank line).
    fn skipHead(self: *SseClient) !void {
        while (true) {
            const l = try self.line(std.testing.allocator);
            defer std.testing.allocator.free(l);
            if (l.len == 0) return;
        }
    }
};

test "e2e: legacy SSE round trip (endpoint event, 202, response on stream, 404 unknown)" {
    var srv = try TestServer.start(.{ .keepalive_ms = 200, .poll_ms = 20 });
    defer srv.stop();
    const alloc = std.testing.allocator;

    var c: SseClient = undefined;
    try c.open(srv.l.port(), "GET /sse HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/event-stream\r\n\r\n");
    var c_open = true;
    defer if (c_open) c.close();
    const status = try c.line(alloc);
    defer alloc.free(status);
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK", status);
    try c.skipHead();
    try c.expectLine("event: endpoint");
    const data = try c.line(alloc);
    defer alloc.free(data);
    const prefix = "data: /messages?sessionId=";
    try std.testing.expect(std.mem.startsWith(u8, data, prefix));
    const sid = data[prefix.len..];
    try std.testing.expectEqual(@as(usize, 32), sid.len);
    try std.testing.expect(isHex(sid));
    try c.expectLine("");

    // POST -> 202 immediately; the answer arrives on the stream.
    var rq: [512]u8 = undefined;
    var tb: [96]u8 = undefined;
    const target = try std.fmt.bufPrint(&tb, "/messages?sessionId={s}", .{sid});
    const r = try srv.exchange(try postText(&rq, target, "", "{\"jsonrpc\":\"2.0\",\"id\":3}"));
    defer alloc.free(r);
    try std.testing.expectEqual(@as(?u16, 202), statusOf(r));
    try c.expectLine("event: message");
    try c.expectLine("data: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":true}}");
    try c.expectLine("");

    // Idle: keepalive comment.
    try c.expectLine(": keepalive");

    // Unknown session -> 404.
    const r404 = try srv.exchange(try postText(&rq, "/messages?sessionId=0123456789abcdef0123456789abcdef", "", "{}"));
    defer alloc.free(r404);
    try std.testing.expectEqual(@as(?u16, 404), statusOf(r404));

    // Client disconnect ends the session cleanly (no crash, id forgotten).
    c.close();
    c_open = false;
    var waited: u32 = 0;
    while (srv.l.sessions.count(testIo()) != 0 and waited < 3000) : (waited += 20) {
        try testIo().sleep(Io.Duration.fromMilliseconds(20), .awake);
    }
    try std.testing.expectEqual(@as(usize, 0), srv.l.sessions.count(testIo()));
}

test "e2e: GET /mcp opens an event stream with keepalives; plain GET is 405" {
    var srv = try TestServer.start(.{ .keepalive_ms = 100, .poll_ms = 20 });
    defer srv.stop();
    const alloc = std.testing.allocator;

    const r = try srv.exchange("GET /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    defer alloc.free(r);
    try std.testing.expectEqual(@as(?u16, 405), statusOf(r));

    var c: SseClient = undefined;
    try c.open(srv.l.port(), "GET /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/event-stream\r\n\r\n");
    defer c.close();
    try c.expectLine("HTTP/1.1 200 OK");
    try c.skipHead();
    try c.expectLine(": stream open");
    try c.expectLine("");
    try c.expectLine(": keepalive");
    try c.expectLine("");
}
