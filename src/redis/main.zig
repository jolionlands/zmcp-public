//! zmcp-redis - native Zig port of the reference Redis MCP server
//! (modelcontextprotocol/servers-archived src/redis: tools set/get/delete/list).
//! RESP2 is spoken directly over a plain TCP socket; no client library.
//! Env: REDIS_URL (redis://[user]:[password]@host:port[/db]; default
//! redis://localhost:6379; rediss/TLS is unsupported), ZMCP_REDIS_ALLOW_WRITE=1
//! to enable set/delete. Only fixed commands are ever sent (GET SET DEL SCAN
//! TTL TYPE HSCAN AUTH SELECT); there is no command passthrough.

const std = @import("std");
const mcp = @import("mcp");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const MAX_KEY_LEN: usize = 1024;
pub const MAX_PATTERN_LEN: usize = 256;
pub const MAX_SET_VALUE: usize = 1024 * 1024;
pub const MAX_DEL_KEYS: usize = 100;
pub const MAX_OUTPUT: usize = 64 * 1024;
pub const MAX_REPLY_BYTES: usize = 32 * 1024 * 1024;
const MAX_BULK: usize = 16 * 1024 * 1024;
const MAX_ARRAY: usize = 100_000;
const MAX_DEPTH: usize = 8;
const DEFAULT_LIMIT: usize = 100;
const MAX_LIMIT: usize = 1000;
const MAX_SCAN_ITERS: usize = 200;
const HASH_VALUE_CAP: usize = 1024;

// ---------------------------------------------------------------- RESP2

pub const Resp = union(enum) {
    simple: []const u8,
    err: []const u8,
    int: i64,
    bulk: ?[]const u8,
    array: ?[]const Resp,
};

pub const ParseError = error{ Incomplete, Protocol, TooLarge, OutOfMemory };

pub const Parsed = struct { value: Resp, used: usize };

/// Parse one RESP2 value from the start of `buf`. Returns error.Incomplete if
/// more bytes are needed. Slices in the result are copied into `arena`.
pub fn parse(arena: Allocator, buf: []const u8) ParseError!Parsed {
    return parseDepth(arena, buf, 0);
}

fn readLine(buf: []const u8) ParseError!struct { line: []const u8, next: usize } {
    const idx = std.mem.indexOf(u8, buf, "\r\n") orelse {
        if (buf.len > 1024 * 1024) return error.TooLarge;
        return error.Incomplete;
    };
    return .{ .line = buf[0..idx], .next = idx + 2 };
}

fn parseInt(s: []const u8) ParseError!i64 {
    return std.fmt.parseInt(i64, s, 10) catch error.Protocol;
}

fn parseDepth(arena: Allocator, buf: []const u8, depth: usize) ParseError!Parsed {
    if (buf.len == 0) return error.Incomplete;
    if (depth > MAX_DEPTH) return error.Protocol;
    const l = try readLine(buf[1..]);
    const head = 1 + l.next;
    switch (buf[0]) {
        '+' => return .{ .value = .{ .simple = try arena.dupe(u8, l.line) }, .used = head },
        '-' => return .{ .value = .{ .err = try arena.dupe(u8, l.line) }, .used = head },
        ':' => return .{ .value = .{ .int = try parseInt(l.line) }, .used = head },
        '$' => {
            const n = try parseInt(l.line);
            if (n == -1) return .{ .value = .{ .bulk = null }, .used = head };
            if (n < 0) return error.Protocol;
            const len: usize = @intCast(n);
            if (len > MAX_BULK) return error.TooLarge;
            if (buf.len < head + len + 2) return error.Incomplete;
            if (buf[head + len] != '\r' or buf[head + len + 1] != '\n') return error.Protocol;
            return .{
                .value = .{ .bulk = try arena.dupe(u8, buf[head .. head + len]) },
                .used = head + len + 2,
            };
        },
        '*' => {
            const n = try parseInt(l.line);
            if (n == -1) return .{ .value = .{ .array = null }, .used = head };
            if (n < 0) return error.Protocol;
            const cnt: usize = @intCast(n);
            if (cnt > MAX_ARRAY) return error.TooLarge;
            const items = try arena.alloc(Resp, cnt);
            var pos = head;
            for (items) |*it| {
                const p = try parseDepth(arena, buf[pos..], depth + 1);
                it.* = p.value;
                pos += p.used;
            }
            return .{ .value = .{ .array = items }, .used = pos };
        },
        else => return error.Protocol,
    }
}

/// Encode a command as a RESP array of bulk strings.
pub fn encodeCommand(w: *Io.Writer, args: []const []const u8) Io.Writer.Error!void {
    try w.print("*{d}\r\n", .{args.len});
    for (args) |a| {
        try w.print("${d}\r\n", .{a.len});
        try w.writeAll(a);
        try w.writeAll("\r\n");
    }
}

// ---------------------------------------------------------------- URL / config

pub const Config = struct {
    host: []const u8 = "localhost",
    port: u16 = 6379,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    db: u32 = 0,
};

pub const UrlError = error{ TlsUnsupported, InvalidUrl, InvalidPort, InvalidDb, OutOfMemory };

pub fn urlErrorMessage(e: UrlError) []const u8 {
    return switch (e) {
        error.TlsUnsupported => "REDIS_URL uses rediss:// (TLS), which is not supported; use redis://",
        error.InvalidUrl => "REDIS_URL is invalid; expected redis://[user]:[password]@host:port[/db]",
        error.InvalidPort => "REDIS_URL has an invalid port",
        error.InvalidDb => "REDIS_URL has an invalid database number",
        error.OutOfMemory => "out of memory",
    };
}

fn pctDecode(alloc: Allocator, s: []const u8) UrlError![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%') {
            if (i + 2 >= s.len) return error.InvalidUrl;
            const b = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return error.InvalidUrl;
            try out.append(alloc, b);
            i += 2;
        } else try out.append(alloc, s[i]);
    }
    return out.items;
}

pub fn parseUrl(alloc: Allocator, url: []const u8) UrlError!Config {
    var rest: []const u8 = undefined;
    if (std.ascii.startsWithIgnoreCase(url, "rediss://")) return error.TlsUnsupported;
    if (std.ascii.startsWithIgnoreCase(url, "redis://")) {
        rest = url["redis://".len..];
    } else return error.InvalidUrl;

    var cfg: Config = .{};
    if (std.mem.indexOfAny(u8, rest, "?#")) |q| rest = rest[0..q];
    var authority = rest;
    var path: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '/')) |s| {
        authority = rest[0..s];
        path = rest[s + 1 ..];
    }
    if (path.len > 0) {
        cfg.db = std.fmt.parseInt(u32, path, 10) catch return error.InvalidDb;
    }
    var hostport = authority;
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| {
        const ui = authority[0..at];
        hostport = authority[at + 1 ..];
        const colon = std.mem.indexOfScalar(u8, ui, ':') orelse return error.InvalidUrl;
        const user = try pctDecode(alloc, ui[0..colon]);
        const pass = try pctDecode(alloc, ui[colon + 1 ..]);
        if (user.len > 0) cfg.username = user;
        if (pass.len > 0) cfg.password = pass;
    }
    var port_s: []const u8 = "";
    if (hostport.len > 0 and hostport[0] == '[') {
        const close = std.mem.indexOfScalar(u8, hostport, ']') orelse return error.InvalidUrl;
        cfg.host = hostport[1..close];
        const tail = hostport[close + 1 ..];
        if (tail.len > 0) {
            if (tail[0] != ':') return error.InvalidUrl;
            port_s = tail[1..];
        }
    } else if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |c| {
        if (c > 0) cfg.host = hostport[0..c];
        port_s = hostport[c + 1 ..];
    } else if (hostport.len > 0) {
        cfg.host = hostport;
    }
    if (std.mem.indexOfScalar(u8, cfg.host, ':') != null and hostport[0] != '[') return error.InvalidUrl;
    if (port_s.len > 0) cfg.port = std.fmt.parseInt(u16, port_s, 10) catch return error.InvalidPort;
    if (cfg.host.len == 0) cfg.host = "localhost";
    return cfg;
}

// ---------------------------------------------------------------- session

pub const SessionError = error{ RedisError, ConnectionClosed, Protocol, TooLarge, IoFailed, OutOfMemory };

/// One connection's worth of state. `r`/`w` are abstract so tests can use
/// canned buffers instead of a socket.
pub const Session = struct {
    arena: Allocator,
    r: *Io.Reader,
    w: *Io.Writer,
    acc: std.ArrayList(u8) = .empty,
    /// Message of the last Redis error reply (server generated, no secrets).
    err_msg: []const u8 = "",

    fn recv(self: *Session) SessionError!Resp {
        while (true) {
            if (parse(self.arena, self.acc.items)) |p| {
                const rest = self.acc.items[p.used..];
                std.mem.copyForwards(u8, self.acc.items[0..rest.len], rest);
                self.acc.items.len = rest.len;
                return p.value;
            } else |e| switch (e) {
                error.Incomplete => {},
                error.Protocol => return error.Protocol,
                error.TooLarge => return error.TooLarge,
                error.OutOfMemory => return error.OutOfMemory,
            }
            if (self.acc.items.len > MAX_REPLY_BYTES) return error.TooLarge;
            self.r.fill(1) catch return error.ConnectionClosed;
            const b = self.r.buffered();
            try self.acc.appendSlice(self.arena, b);
            self.r.toss(b.len);
        }
    }

    /// Send one command and read its reply. Error replies become
    /// error.RedisError with the text in `err_msg`.
    pub fn cmd(self: *Session, args: []const []const u8) SessionError!Resp {
        encodeCommand(self.w, args) catch return error.IoFailed;
        self.w.flush() catch return error.IoFailed;
        const v = try self.recv();
        if (v == .err) {
            self.err_msg = v.err;
            return error.RedisError;
        }
        return v;
    }
};

// ---------------------------------------------------------------- globals / seam

var g_url: ?[]const u8 = null;
var g_allow_write: bool = false;
var g_alloc: Allocator = undefined;
/// Test seam: when set, handlers use this session instead of connecting.
var test_session: ?*Session = null;

const NetConn = struct {
    stream: Io.net.Stream,
    rbuf: [4096]u8 = undefined,
    wbuf: [4096]u8 = undefined,
    reader: Io.net.Stream.Reader = undefined,
    writer: Io.net.Stream.Writer = undefined,
    session: Session = undefined,
};

fn connectStream(io: Io, cfg: Config) !Io.net.Stream {
    // Connect timeouts are unimplemented in Zig 0.16's posix backend (panics),
    // so none is set; the OS connect timeout applies.
    const opts: Io.net.IpAddress.ConnectOptions = .{ .mode = .stream };
    if (Io.net.IpAddress.parse(cfg.host, cfg.port)) |addr| {
        return addr.connect(io, opts);
    } else |_| {
        const hn = try Io.net.HostName.init(cfg.host);
        return hn.connect(io, cfg.port, opts);
    }
}

/// Connect, AUTH and SELECT as configured. Caller closes `conn.stream`.
fn openConn(arena: Allocator, io: Io, cfg: Config, conn: *NetConn) !*Session {
    conn.reader = conn.stream.reader(io, &conn.rbuf);
    conn.writer = conn.stream.writer(io, &conn.wbuf);
    conn.session = .{ .arena = arena, .r = &conn.reader.interface, .w = &conn.writer.interface };
    const s = &conn.session;
    if (cfg.password) |pw| {
        if (cfg.username) |u| {
            _ = try s.cmd(&.{ "AUTH", u, pw });
        } else {
            _ = try s.cmd(&.{ "AUTH", pw });
        }
    }
    if (cfg.db != 0) {
        var nb: [16]u8 = undefined;
        const n = std.fmt.bufPrint(&nb, "{d}", .{cfg.db}) catch unreachable;
        _ = try s.cmd(&.{ "SELECT", n });
    }
    return s;
}

// ---------------------------------------------------------------- helpers

fn fail(allocator: Allocator, comptime fmt: []const u8, args: anytype) !mcp.ToolResult {
    return .{ .text = try std.fmt.allocPrint(allocator, fmt, args), .is_error = true };
}

fn ok(allocator: Allocator, text: []const u8) !mcp.ToolResult {
    return .{ .text = try allocator.dupe(u8, text) };
}

fn errText(allocator: Allocator, sess: ?*Session, err: anyerror) !mcp.ToolResult {
    if (err == error.RedisError) {
        if (sess) |s| return fail(allocator, "redis error: {s}", .{s.err_msg});
    }
    // Only error names, never URLs or credentials.
    return fail(allocator, "redis: {s}", .{@errorName(err)});
}

fn getStr(args: std.json.Value, name: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

fn validKey(key: []const u8) ?[]const u8 {
    if (key.len == 0) return "key must not be empty";
    if (key.len > MAX_KEY_LEN) return "key too long (max 1024 bytes)";
    return null;
}

fn getLimit(args: std.json.Value) usize {
    if (args != .object) return DEFAULT_LIMIT;
    const v = args.object.get("limit") orelse return DEFAULT_LIMIT;
    const n: i64 = switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => return DEFAULT_LIMIT,
    };
    if (n < 1) return 1;
    return @min(@as(usize, @intCast(n)), MAX_LIMIT);
}

/// Truncate at a UTF-8 boundary to at most `cap` bytes and note it.
fn capText(arena: Allocator, s: []const u8, cap: usize) ![]const u8 {
    if (s.len <= cap) return s;
    var end = cap;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return std.fmt.allocPrint(arena, "{s}\n[truncated: showing {d} of {d} bytes]", .{ s[0..end], end, s.len });
}

fn writeGuard(allocator: Allocator) !?mcp.ToolResult {
    if (g_allow_write) return null;
    return try fail(allocator, "writes disabled: set ZMCP_REDIS_ALLOW_WRITE=1 to enable set/delete", .{});
}

const Guard = struct { arena_state: std.heap.ArenaAllocator, conn: NetConn = undefined, connected: bool = false };

/// Open the session for a tool call (test seam or real TCP).
fn openSession(g: *Guard, io: Io) !*Session {
    if (test_session) |t| return t;
    const url = g_url orelse "redis://localhost:6379";
    const cfg = parseUrl(g.arena_state.allocator(), url) catch |e| {
        g_url_err = urlErrorMessage(e);
        return error.BadUrl;
    };
    g.conn = undefined;
    g.connected = false;
    const stream = connectStream(io, cfg) catch |e| return e;
    g.connected = true;
    g.conn.stream = stream;
    return try openConn(g.arena_state.allocator(), io, cfg, &g.conn);
}

var g_url_err: []const u8 = "";

fn closeGuard(g: *Guard, io: Io) void {
    if (g.connected) g.conn.stream.close(io);
    g.arena_state.deinit();
}

fn failOpen(allocator: Allocator, err: anyerror) !mcp.ToolResult {
    if (err == error.BadUrl) return fail(allocator, "{s}", .{g_url_err});
    if (err == error.RedisError) return fail(allocator, "redis: authentication or database selection failed", .{});
    return fail(allocator, "cannot connect to Redis (check REDIS_URL): {s}", .{@errorName(err)});
}

// ---------------------------------------------------------------- tools

fn toolGet(allocator: Allocator, io: Io, args: std.json.Value) anyerror!mcp.ToolResult {
    const key = getStr(args, "key") orelse return fail(allocator, "missing required argument: key", .{});
    if (validKey(key)) |m| return fail(allocator, "{s}", .{m});
    var g: Guard = .{ .arena_state = .init(allocator) };
    defer closeGuard(&g, io);
    const arena = g.arena_state.allocator();
    const s = openSession(&g, io) catch |e| return failOpen(allocator, e);
    const r = s.cmd(&.{ "GET", key }) catch |e| return errText(allocator, s, e);
    if (r != .bulk) return fail(allocator, "unexpected reply", .{});
    const v = r.bulk orelse return ok(allocator, "Key not found");
    return ok(allocator, try capText(arena, v, MAX_OUTPUT));
}

fn toolSet(allocator: Allocator, io: Io, args: std.json.Value) anyerror!mcp.ToolResult {
    if (try writeGuard(allocator)) |r| return r;
    const key = getStr(args, "key") orelse return fail(allocator, "missing required argument: key", .{});
    const value = getStr(args, "value") orelse return fail(allocator, "missing required argument: value", .{});
    if (validKey(key)) |m| return fail(allocator, "{s}", .{m});
    if (value.len > MAX_SET_VALUE) return fail(allocator, "value too large (max 1 MiB)", .{});
    var ex: ?i64 = null;
    if (args == .object) if (args.object.get("expireSeconds")) |v| {
        switch (v) {
            .integer => |i| ex = i,
            .float => |f| {
                if (f != @floor(f) or f > 1e12 or f < -1e12) return fail(allocator, "expireSeconds must be an integer", .{});
                ex = @intFromFloat(f);
            },
            .null => {},
            else => return fail(allocator, "expireSeconds must be an integer", .{}),
        }
        if (ex) |e| if (e < 1 or e > 315_360_000) return fail(allocator, "expireSeconds must be between 1 and 315360000", .{});
    };
    var g: Guard = .{ .arena_state = .init(allocator) };
    defer closeGuard(&g, io);
    const s = openSession(&g, io) catch |e| return failOpen(allocator, e);
    var nb: [24]u8 = undefined;
    const r = (if (ex) |e| blk: {
        const n = std.fmt.bufPrint(&nb, "{d}", .{e}) catch unreachable;
        break :blk s.cmd(&.{ "SET", key, value, "EX", n });
    } else s.cmd(&.{ "SET", key, value })) catch |e| return errText(allocator, s, e);
    _ = r;
    return ok(allocator, "OK");
}

fn toolDelete(allocator: Allocator, io: Io, args: std.json.Value) anyerror!mcp.ToolResult {
    if (try writeGuard(allocator)) |r| return r;
    if (args != .object) return fail(allocator, "missing required argument: key", .{});
    const kv = args.object.get("key") orelse return fail(allocator, "missing required argument: key", .{});
    var g: Guard = .{ .arena_state = .init(allocator) };
    defer closeGuard(&g, io);
    const arena = g.arena_state.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, "DEL");
    switch (kv) {
        .string => |s| try argv.append(arena, s),
        .array => |a| for (a.items) |it| {
            if (it != .string) return fail(allocator, "key array must contain strings", .{});
            try argv.append(arena, it.string);
        },
        else => return fail(allocator, "key must be a string or array of strings", .{}),
    }
    if (argv.items.len < 2) return fail(allocator, "no keys given", .{});
    if (argv.items.len - 1 > MAX_DEL_KEYS) return fail(allocator, "too many keys (max 100)", .{});
    for (argv.items[1..]) |k| if (validKey(k)) |m| return fail(allocator, "{s}", .{m});
    const s = openSession(&g, io) catch |e| return failOpen(allocator, e);
    const r = s.cmd(argv.items) catch |e| return errText(allocator, s, e);
    if (r != .int) return fail(allocator, "unexpected reply", .{});
    const text = try std.fmt.allocPrint(allocator, "Deleted {d} key(s)", .{r.int});
    return .{ .text = text };
}

const ScanResult = struct { items: std.ArrayList([]const u8), complete: bool };

/// SCAN / HSCAN loop (never KEYS/HGETALL). Collects up to `max_items` entries.
fn scanLoop(s: *Session, arena: Allocator, hash_key: ?[]const u8, pattern: ?[]const u8, max_items: usize) !ScanResult {
    var out: ScanResult = .{ .items = .empty, .complete = false };
    var cursor: []const u8 = "0";
    var iter: usize = 0;
    while (iter < MAX_SCAN_ITERS) : (iter += 1) {
        var argv: std.ArrayList([]const u8) = .empty;
        if (hash_key) |hk| {
            try argv.appendSlice(arena, &.{ "HSCAN", hk, cursor });
        } else try argv.appendSlice(arena, &.{ "SCAN", cursor });
        if (pattern) |p| try argv.appendSlice(arena, &.{ "MATCH", p });
        try argv.appendSlice(arena, &.{ "COUNT", "500" });
        const r = try s.cmd(argv.items);
        if (r != .array or r.array == null or r.array.?.len != 2) return error.Protocol;
        const pair = r.array.?;
        if (pair[0] != .bulk or pair[0].bulk == null or pair[1] != .array) return error.Protocol;
        cursor = pair[0].bulk.?;
        for (pair[1].array orelse &[_]Resp{}) |e| {
            if (e != .bulk or e.bulk == null) return error.Protocol;
            if (out.items.items.len >= max_items) return out;
            try out.items.append(arena, e.bulk.?);
        }
        if (std.mem.eql(u8, cursor, "0")) {
            out.complete = true;
            return out;
        }
        if (out.items.items.len >= max_items) return out;
    }
    return out;
}

fn toolList(allocator: Allocator, io: Io, args: std.json.Value) anyerror!mcp.ToolResult {
    const pattern = getStr(args, "pattern") orelse "*";
    if (pattern.len > MAX_PATTERN_LEN) return fail(allocator, "pattern too long (max 256 bytes)", .{});
    const limit = getLimit(args);
    var g: Guard = .{ .arena_state = .init(allocator) };
    defer closeGuard(&g, io);
    const arena = g.arena_state.allocator();
    const s = openSession(&g, io) catch |e| return failOpen(allocator, e);
    const res = scanLoop(s, arena, null, pattern, limit) catch |e| return errText(allocator, s, e);
    if (res.items.items.len == 0) {
        return ok(allocator, if (res.complete) "No keys found" else "No keys found yet (scan incomplete; narrow the pattern)");
    }
    var buf: std.Io.Writer.Allocating = .init(arena);
    for (res.items.items, 0..) |k, i| {
        if (i > 0) try buf.writer.writeByte('\n');
        try buf.writer.writeAll(k);
    }
    if (!res.complete or res.items.items.len >= limit) try buf.writer.writeAll("\n[more keys may exist; narrow the pattern or raise limit]");
    return ok(allocator, try capText(arena, buf.written(), MAX_OUTPUT));
}

fn toolTtl(allocator: Allocator, io: Io, args: std.json.Value) anyerror!mcp.ToolResult {
    const key = getStr(args, "key") orelse return fail(allocator, "missing required argument: key", .{});
    if (validKey(key)) |m| return fail(allocator, "{s}", .{m});
    var g: Guard = .{ .arena_state = .init(allocator) };
    defer closeGuard(&g, io);
    const s = openSession(&g, io) catch |e| return failOpen(allocator, e);
    const r = s.cmd(&.{ "TTL", key }) catch |e| return errText(allocator, s, e);
    if (r != .int) return fail(allocator, "unexpected reply", .{});
    const text = switch (r.int) {
        -2 => try allocator.dupe(u8, "Key not found"),
        -1 => try allocator.dupe(u8, "No expiry"),
        else => try std.fmt.allocPrint(allocator, "{d} seconds", .{r.int}),
    };
    return .{ .text = text };
}

fn toolType(allocator: Allocator, io: Io, args: std.json.Value) anyerror!mcp.ToolResult {
    const key = getStr(args, "key") orelse return fail(allocator, "missing required argument: key", .{});
    if (validKey(key)) |m| return fail(allocator, "{s}", .{m});
    var g: Guard = .{ .arena_state = .init(allocator) };
    defer closeGuard(&g, io);
    const s = openSession(&g, io) catch |e| return failOpen(allocator, e);
    const r = s.cmd(&.{ "TYPE", key }) catch |e| return errText(allocator, s, e);
    if (r != .simple) return fail(allocator, "unexpected reply", .{});
    if (std.mem.eql(u8, r.simple, "none")) return ok(allocator, "Key not found");
    return ok(allocator, r.simple);
}

fn toolHash(allocator: Allocator, io: Io, args: std.json.Value) anyerror!mcp.ToolResult {
    const key = getStr(args, "key") orelse return fail(allocator, "missing required argument: key", .{});
    if (validKey(key)) |m| return fail(allocator, "{s}", .{m});
    const limit = getLimit(args);
    var g: Guard = .{ .arena_state = .init(allocator) };
    defer closeGuard(&g, io);
    const arena = g.arena_state.allocator();
    const s = openSession(&g, io) catch |e| return failOpen(allocator, e);
    const res = scanLoop(s, arena, key, null, limit * 2) catch |e| return errText(allocator, s, e);
    const it = res.items.items;
    if (it.len == 0) return ok(allocator, "Hash empty or key not found");
    var buf: std.Io.Writer.Allocating = .init(arena);
    var i: usize = 0;
    while (i + 1 < it.len) : (i += 2) {
        try buf.writer.print("{s}: {s}\n", .{ it[i], try capText(arena, it[i + 1], HASH_VALUE_CAP) });
    }
    if (!res.complete) try buf.writer.writeAll("[more fields may exist; raise limit]");
    return ok(allocator, try capText(arena, buf.written(), MAX_OUTPUT));
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "get",
        .read_only = true,
        .description = "Get value by key from Redis",
        .input_schema_json =
        \\{"type":"object","properties":{"key":{"type":"string"}},"required":["key"]}
        ,
        .handler = toolGet,
    },
    .{
        .name = "set",
        .destructive = true,
        .description = "Set a Redis key-value pair with optional expiration (needs ZMCP_REDIS_ALLOW_WRITE=1)",
        .input_schema_json =
        \\{"type":"object","properties":{"key":{"type":"string"},"value":{"type":"string"},"expireSeconds":{"type":"integer"}},"required":["key","value"]}
        ,
        .handler = toolSet,
    },
    .{
        .name = "delete",
        .destructive = true,
        .description = "Delete one or more keys (needs ZMCP_REDIS_ALLOW_WRITE=1)",
        .input_schema_json =
        \\{"type":"object","properties":{"key":{"oneOf":[{"type":"string"},{"type":"array","items":{"type":"string"}}]}},"required":["key"]}
        ,
        .handler = toolDelete,
    },
    .{
        .name = "list",
        .read_only = true,
        .description = "List keys matching a glob pattern (SCAN, capped)",
        .input_schema_json =
        \\{"type":"object","properties":{"pattern":{"type":"string","description":"default *"},"limit":{"type":"integer","description":"default 100, max 1000"}}}
        ,
        .handler = toolList,
    },
    .{
        .name = "ttl",
        .read_only = true,
        .description = "Remaining time to live of a key in seconds",
        .input_schema_json =
        \\{"type":"object","properties":{"key":{"type":"string"}},"required":["key"]}
        ,
        .handler = toolTtl,
    },
    .{
        .name = "type",
        .read_only = true,
        .description = "Type of the value stored at a key",
        .input_schema_json =
        \\{"type":"object","properties":{"key":{"type":"string"}},"required":["key"]}
        ,
        .handler = toolType,
    },
    .{
        .name = "hgetall",
        .read_only = true,
        .description = "Read fields of a hash (HSCAN, capped)",
        .input_schema_json =
        \\{"type":"object","properties":{"key":{"type":"string"},"limit":{"type":"integer","description":"max fields, default 100"}},"required":["key"]}
        ,
        .handler = toolHash,
    },
};

pub fn main(init: std.process.Init) !void {
    g_alloc = init.gpa;
    g_url = init.environ_map.get("REDIS_URL");
    if (init.environ_map.get("ZMCP_REDIS_ALLOW_WRITE")) |v| g_allow_write = std.mem.eql(u8, v, "1");
    try mcp.run(init.gpa, init.io, .{ .name = "zmcp-redis", .version = "0.1.0" }, &tool_table);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectResp(buf: []const u8) !Parsed {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Values are arena-copied; only inspect in callers via helper below.
    return parse(arena.allocator(), buf);
}

test "parse simple, error, int" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const p1 = try parse(a.allocator(), "+OK\r\nrest");
    try testing.expectEqualStrings("OK", p1.value.simple);
    try testing.expectEqual(@as(usize, 5), p1.used);
    const p2 = try parse(a.allocator(), "-WRONGTYPE bad\r\n");
    try testing.expectEqualStrings("WRONGTYPE bad", p2.value.err);
    const p3 = try parse(a.allocator(), ":-42\r\n");
    try testing.expectEqual(@as(i64, -42), p3.value.int);
}

test "parse bulk with CRLF inside, empty, nil" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const p = try parse(a.allocator(), "$8\r\nab\r\ncd\r\n\r\n");
    try testing.expectEqualStrings("ab\r\ncd\r\n", p.value.bulk.?);
    try testing.expectEqual(@as(usize, 14), p.used);
    const e = try parse(a.allocator(), "$0\r\n\r\n");
    try testing.expectEqualStrings("", e.value.bulk.?);
    const n = try parse(a.allocator(), "$-1\r\n");
    try testing.expect(n.value.bulk == null);
    const na = try parse(a.allocator(), "*-1\r\n");
    try testing.expect(na.value.array == null);
}

test "parse nested arrays" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const p = try parse(a.allocator(), "*2\r\n$1\r\n0\r\n*2\r\n$1\r\na\r\n:7\r\n");
    const arr = p.value.array.?;
    try testing.expectEqual(@as(usize, 2), arr.len);
    try testing.expectEqualStrings("0", arr[0].bulk.?);
    try testing.expectEqual(@as(i64, 7), arr[1].array.?[1].int);
}

test "parse incomplete at every split point" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const msg = "*2\r\n$3\r\nfoo\r\n$-1\r\n";
    var i: usize = 0;
    while (i < msg.len) : (i += 1) {
        try testing.expectError(error.Incomplete, parse(a.allocator(), msg[0..i]));
    }
    const p = try parse(a.allocator(), msg);
    try testing.expectEqual(msg.len, p.used);
}

test "parse protocol errors and limits" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    try testing.expectError(error.Protocol, parse(a.allocator(), "?x\r\n"));
    try testing.expectError(error.Protocol, parse(a.allocator(), ":abc\r\n"));
    try testing.expectError(error.Protocol, parse(a.allocator(), "$3\r\nfooXX"));
    try testing.expectError(error.TooLarge, parse(a.allocator(), "$999999999999\r\n"));
    try testing.expectError(error.Protocol, parse(a.allocator(), "$-5\r\n"));
}

test "encode command" {
    var w: Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();
    try encodeCommand(&w.writer, &.{ "SET", "k", "a\r\nb" });
    try testing.expectEqualStrings("*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$4\r\na\r\nb\r\n", w.written());
}

test "url parsing" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const c1 = try parseUrl(a.allocator(), "redis://localhost:6379");
    try testing.expectEqualStrings("localhost", c1.host);
    try testing.expectEqual(@as(u16, 6379), c1.port);
    try testing.expect(c1.password == null);
    const c2 = try parseUrl(a.allocator(), "redis://:p%40ss@10.0.0.5:6380/3");
    try testing.expectEqualStrings("10.0.0.5", c2.host);
    try testing.expectEqual(@as(u16, 6380), c2.port);
    try testing.expectEqualStrings("p@ss", c2.password.?);
    try testing.expect(c2.username == null);
    try testing.expectEqual(@as(u32, 3), c2.db);
    const c3 = try parseUrl(a.allocator(), "redis://bob:pw@[::1]:7000");
    try testing.expectEqualStrings("::1", c3.host);
    try testing.expectEqual(@as(u16, 7000), c3.port);
    try testing.expectEqualStrings("bob", c3.username.?);
    const c4 = try parseUrl(a.allocator(), "redis://example.com");
    try testing.expectEqual(@as(u16, 6379), c4.port);
    try testing.expectError(error.TlsUnsupported, parseUrl(a.allocator(), "rediss://h:1"));
    try testing.expectError(error.InvalidUrl, parseUrl(a.allocator(), "http://h"));
    try testing.expectError(error.InvalidPort, parseUrl(a.allocator(), "redis://h:99999"));
    try testing.expectError(error.InvalidDb, parseUrl(a.allocator(), "redis://h/abc"));
    try testing.expectError(error.InvalidUrl, parseUrl(a.allocator(), "redis://onlyuser@h"));
    try testing.expectError(error.InvalidUrl, parseUrl(a.allocator(), "redis://:p%zz@h"));
}

/// Run a tool against canned server bytes; returns text and sent bytes.
const Run = struct { text: []u8, is_error: bool, sent: []u8 };

fn runTool(comptime handler: mcp.ToolHandler, args_json: []const u8, canned: []const u8) !Run {
    const alloc = testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, args_json, .{});
    defer parsed.deinit();
    var r: Io.Reader = .fixed(canned);
    var w: Io.Writer.Allocating = .init(alloc);
    defer w.deinit();
    var sarena = std.heap.ArenaAllocator.init(alloc);
    defer sarena.deinit();
    var sess: Session = .{ .arena = sarena.allocator(), .r = &r, .w = &w.writer };
    test_session = &sess;
    defer test_session = null;
    const res = try handler(alloc, testing.io, parsed.value);
    return .{ .text = @constCast(res.text), .is_error = res.is_error, .sent = try alloc.dupe(u8, w.written()) };
}

fn freeRun(r: Run) void {
    testing.allocator.free(r.text);
    testing.allocator.free(r.sent);
}

test "get hit, miss and error" {
    const r = try runTool(toolGet, "{\"key\":\"k\"}", "$3\r\nfoo\r\n");
    defer freeRun(r);
    try testing.expectEqualStrings("foo", r.text);
    try testing.expectEqualStrings("*2\r\n$3\r\nGET\r\n$1\r\nk\r\n", r.sent);
    const m = try runTool(toolGet, "{\"key\":\"k\"}", "$-1\r\n");
    defer freeRun(m);
    try testing.expectEqualStrings("Key not found", m.text);
    const e = try runTool(toolGet, "{\"key\":\"k\"}", "-WRONGTYPE Operation against a key\r\n");
    defer freeRun(e);
    try testing.expect(e.is_error);
    try testing.expectEqualStrings("redis error: WRONGTYPE Operation against a key", e.text);
    const bad = try runTool(toolGet, "{}", "");
    defer freeRun(bad);
    try testing.expect(bad.is_error);
    const long = try runTool(toolGet, "{\"key\":\"" ++ "k" ** 1025 ++ "\"}", "");
    defer freeRun(long);
    try testing.expect(long.is_error);
}

test "get truncates large values" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.print(testing.allocator, "${d}\r\n", .{MAX_OUTPUT + 100});
    try buf.appendNTimes(testing.allocator, 'x', MAX_OUTPUT + 100);
    try buf.appendSlice(testing.allocator, "\r\n");
    const r = try runTool(toolGet, "{\"key\":\"k\"}", buf.items);
    defer freeRun(r);
    try testing.expect(std.mem.indexOf(u8, r.text, "[truncated") != null);
    try testing.expect(r.text.len < MAX_OUTPUT + 100);
}

test "connection closed mid-reply" {
    const r = try runTool(toolGet, "{\"key\":\"k\"}", "$5\r\nab");
    defer freeRun(r);
    try testing.expect(r.is_error);
}

test "write gating" {
    g_allow_write = false;
    const s = try runTool(toolSet, "{\"key\":\"k\",\"value\":\"v\"}", "+OK\r\n");
    defer freeRun(s);
    try testing.expect(s.is_error);
    try testing.expectEqual(@as(usize, 0), s.sent.len);
    try testing.expect(std.mem.indexOf(u8, s.text, "ZMCP_REDIS_ALLOW_WRITE") != null);
    const d = try runTool(toolDelete, "{\"key\":\"k\"}", ":1\r\n");
    defer freeRun(d);
    try testing.expect(d.is_error);
    try testing.expectEqual(@as(usize, 0), d.sent.len);
}

test "set and delete when allowed" {
    g_allow_write = true;
    defer g_allow_write = false;
    const s = try runTool(toolSet, "{\"key\":\"k\",\"value\":\"v\"}", "+OK\r\n");
    defer freeRun(s);
    try testing.expectEqualStrings("OK", s.text);
    try testing.expectEqualStrings("*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$1\r\nv\r\n", s.sent);
    const e = try runTool(toolSet, "{\"key\":\"k\",\"value\":\"v\",\"expireSeconds\":60}", "+OK\r\n");
    defer freeRun(e);
    try testing.expectEqualStrings("*5\r\n$3\r\nSET\r\n$1\r\nk\r\n$1\r\nv\r\n$2\r\nEX\r\n$2\r\n60\r\n", e.sent);
    const bad = try runTool(toolSet, "{\"key\":\"k\",\"value\":\"v\",\"expireSeconds\":0}", "");
    defer freeRun(bad);
    try testing.expect(bad.is_error);
    const d = try runTool(toolDelete, "{\"key\":[\"a\",\"b\"]}", ":2\r\n");
    defer freeRun(d);
    try testing.expectEqualStrings("Deleted 2 key(s)", d.text);
    try testing.expectEqualStrings("*3\r\n$3\r\nDEL\r\n$1\r\na\r\n$1\r\nb\r\n", d.sent);
    const empty = try runTool(toolDelete, "{\"key\":[]}", "");
    defer freeRun(empty);
    try testing.expect(empty.is_error);
}

test "list uses SCAN with MATCH, follows cursor, never KEYS" {
    const canned = "*2\r\n$2\r\n17\r\n*2\r\n$1\r\na\r\n$1\r\nb\r\n" ++ "*2\r\n$1\r\n0\r\n*1\r\n$1\r\nc\r\n";
    const r = try runTool(toolList, "{\"pattern\":\"user:*\"}", canned);
    defer freeRun(r);
    try testing.expectEqualStrings("a\nb\nc", r.text);
    try testing.expect(std.mem.indexOf(u8, r.sent, "SCAN") != null);
    try testing.expect(std.mem.indexOf(u8, r.sent, "KEYS") == null);
    try testing.expect(std.mem.indexOf(u8, r.sent, "$5\r\nMATCH\r\n$6\r\nuser:*\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, r.sent, "$2\r\n17\r\n") != null);
}

test "list limit and empty" {
    const canned = "*2\r\n$1\r\n0\r\n*3\r\n$1\r\na\r\n$1\r\nb\r\n$1\r\nc\r\n";
    const r = try runTool(toolList, "{\"limit\":2}", canned);
    defer freeRun(r);
    try testing.expect(std.mem.startsWith(u8, r.text, "a\nb\n[more"));
    const e = try runTool(toolList, "{}", "*2\r\n$1\r\n0\r\n*0\r\n");
    defer freeRun(e);
    try testing.expectEqualStrings("No keys found", e.text);
    const p = try runTool(toolList, "{\"pattern\":\"" ++ "p" ** 257 ++ "\"}", "");
    defer freeRun(p);
    try testing.expect(p.is_error);
}

test "ttl, type, hgetall" {
    const t = try runTool(toolTtl, "{\"key\":\"k\"}", ":-1\r\n");
    defer freeRun(t);
    try testing.expectEqualStrings("No expiry", t.text);
    const t2 = try runTool(toolTtl, "{\"key\":\"k\"}", ":30\r\n");
    defer freeRun(t2);
    try testing.expectEqualStrings("30 seconds", t2.text);
    const ty = try runTool(toolType, "{\"key\":\"k\"}", "+hash\r\n");
    defer freeRun(ty);
    try testing.expectEqualStrings("hash", ty.text);
    const h = try runTool(toolHash, "{\"key\":\"h\"}", "*2\r\n$1\r\n0\r\n*4\r\n$1\r\nf\r\n$1\r\nv\r\n$1\r\ng\r\n$1\r\nw\r\n");
    defer freeRun(h);
    try testing.expectEqualStrings("f: v\ng: w\n", h.text);
    try testing.expect(std.mem.indexOf(u8, h.sent, "HSCAN") != null);
    try testing.expect(std.mem.indexOf(u8, h.sent, "HGETALL") == null);
}

test "split reads through a reader that yields one byte at a time" {
    const alloc = testing.allocator;
    var sarena = std.heap.ArenaAllocator.init(alloc);
    defer sarena.deinit();
    const data = "$8\r\nab\r\ncd\r\n\r\n";
    // Reader with 1-byte buffer over a fixed source: fixed readers hand over
    // everything at once, so feed the Session's accumulator in pieces instead.
    var r: Io.Reader = .fixed("");
    var w: Io.Writer.Allocating = .init(alloc);
    defer w.deinit();
    var sess: Session = .{ .arena = sarena.allocator(), .r = &r, .w = &w.writer };
    try sess.acc.appendSlice(sarena.allocator(), data[0..5]);
    try testing.expectError(error.ConnectionClosed, sess.recv());
    sess.acc.clearRetainingCapacity();
    try sess.acc.appendSlice(sarena.allocator(), data);
    const v = try sess.recv();
    try testing.expectEqualStrings("ab\r\ncd\r\n", v.bulk.?);
}

test "fake TCP server end to end" {
    const io = testing.io;
    const alloc = testing.allocator;
    var addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    const Fake = struct {
        fn serve(srv: *Io.net.Server, sio: Io) void {
            const st = srv.accept(sio) catch return;
            defer st.close(sio);
            var rb: [512]u8 = undefined;
            var wb: [512]u8 = undefined;
            var rd = st.reader(sio, &rb);
            var wr = st.writer(sio, &wb);
            // AUTH reply, then GET reply (sent in two chunks to test split reads).
            var seen: usize = 0;
            while (seen < 2) {
                rd.interface.fill(1) catch return;
                const b = rd.interface.buffered();
                // count commands by '*' at line start
                for (b, 0..) |c, i| {
                    if (c == '*' and (i == 0 or b[i - 1] == '\n')) seen += 1;
                }
                rd.interface.toss(b.len);
                if (seen == 1) {
                    wr.interface.writeAll("+OK\r\n") catch return;
                    wr.interface.flush() catch return;
                }
            }
            wr.interface.writeAll("$5\r\nhe") catch return;
            wr.interface.flush() catch return;
            wr.interface.writeAll("llo\r\n") catch return;
            wr.interface.flush() catch return;
        }
    };
    var fut = io.async(Fake.serve, .{ &server, io });
    defer fut.await(io);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "redis://:secret@127.0.0.1:{d}", .{port});
    g_url = url;
    defer g_url = null;
    var pj = try std.json.parseFromSlice(std.json.Value, alloc, "{\"key\":\"k\"}", .{});
    defer pj.deinit();
    const r = try toolGet(alloc, io, pj.value);
    defer alloc.free(r.text);
    try testing.expect(!r.is_error);
    try testing.expectEqualStrings("hello", r.text);
}

test "bad url reports clear error without leaking" {
    g_url = "rediss://:topsecret@h:1";
    defer g_url = null;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"key\":\"k\"}", .{});
    defer parsed.deinit();
    const r = try toolGet(testing.allocator, testing.io, parsed.value);
    defer testing.allocator.free(r.text);
    try testing.expect(r.is_error);
    try testing.expect(std.mem.indexOf(u8, r.text, "TLS") != null);
    try testing.expect(std.mem.indexOf(u8, r.text, "topsecret") == null);
}

test "annotations: get/list/ttl/type/hgetall read_only, set/delete destructive" {
    for (tool_table) |t| {
        try std.testing.expect(!(t.read_only and t.destructive));
        const w = std.mem.eql(u8, t.name, "set") or std.mem.eql(u8, t.name, "delete");
        try std.testing.expectEqual(w, t.destructive);
        try std.testing.expectEqual(!w, t.read_only);
    }
}
