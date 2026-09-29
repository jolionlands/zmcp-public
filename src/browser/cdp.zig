//! Chrome DevTools Protocol client: synchronous request/response over a
//! message transport (a WebSocket in production, a scripted fake in tests).
//!
//! * `call` sends {id,method,params,sessionId} and reads messages until the
//!   reply with that id arrives; everything else is an event and is drained
//!   into bounded ring buffers (console, network) or per-session state
//!   (navigation URL, load counter, pending dialog).
//! * All waits use a monotonic deadline, so a chatty page cannot starve a
//!   timeout.
//! * Flat sessions: one `Target.attachToTarget {flatten:true}` session per tab.
//!
//! Field names were checked against devtools-protocol master
//! (browser_protocol.json / js_protocol.json).

const std = @import("std");
const ws = @import("ws.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const CONSOLE_CAP: usize = 200;
pub const NETWORK_CAP: usize = 200;

pub const CallError = ws.Error || error{ DialogOpened, BadJson };

// ---------------------------------------------------------------- json helpers

pub fn getObj(v: Value, key: []const u8) ?Value {
    if (v != .object) return null;
    return v.object.get(key);
}

pub fn getStr(v: Value, key: []const u8) ?[]const u8 {
    const x = getObj(v, key) orelse return null;
    return if (x == .string) x.string else null;
}

pub fn getInt(v: Value, key: []const u8) ?i64 {
    const x = getObj(v, key) orelse return null;
    return switch (x) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f) and @abs(f) < 1e15) @as(i64, @intFromFloat(f)) else null,
        else => null,
    };
}

pub fn getNum(v: Value, key: []const u8) ?f64 {
    const x = getObj(v, key) orelse return null;
    return switch (x) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

pub fn getBool(v: Value, key: []const u8) ?bool {
    const x = getObj(v, key) orelse return null;
    return if (x == .bool) x.bool else null;
}

pub fn getArr(v: Value, key: []const u8) ?[]const Value {
    const x = getObj(v, key) orelse return null;
    return if (x == .array) x.array.items else null;
}

/// Append `s` as a JSON string literal (with quotes).
pub fn appendJsonString(list: *std.ArrayList(u8), alloc: Allocator, s: []const u8) Allocator.Error!void {
    try list.append(alloc, '"');
    for (s) |c| switch (c) {
        '"' => try list.appendSlice(alloc, "\\\""),
        '\\' => try list.appendSlice(alloc, "\\\\"),
        '\n' => try list.appendSlice(alloc, "\\n"),
        '\r' => try list.appendSlice(alloc, "\\r"),
        '\t' => try list.appendSlice(alloc, "\\t"),
        0...8, 11, 12, 14...31, 0x7f => try list.print(alloc, "\\u{x:0>4}", .{c}),
        else => try list.append(alloc, c),
    };
    try list.append(alloc, '"');
}

/// Build a small JSON object string from string/int/bool fields, e.g.
/// obj(a, .{ .url = "x", .n = 3 }). Values may also be `Raw` (verbatim JSON).
pub const Raw = struct { json: []const u8 };

pub fn obj(alloc: Allocator, fields: anytype) Allocator.Error![]const u8 {
    var l: std.ArrayList(u8) = .empty;
    try l.append(alloc, '{');
    inline for (std.meta.fields(@TypeOf(fields)), 0..) |f, i| {
        if (i > 0) try l.append(alloc, ',');
        try appendJsonString(&l, alloc, f.name);
        try l.append(alloc, ':');
        const v = @field(fields, f.name);
        const T = @TypeOf(v);
        switch (@typeInfo(T)) {
            .bool => try l.appendSlice(alloc, if (v) "true" else "false"),
            .int, .comptime_int => try l.print(alloc, "{d}", .{v}),
            .float, .comptime_float => try l.print(alloc, "{d}", .{v}),
            .pointer => try appendJsonString(&l, alloc, v),
            .@"struct" => try l.appendSlice(alloc, v.json),
            else => @compileError("obj: unsupported field type " ++ @typeName(T)),
        }
    }
    try l.append(alloc, '}');
    return l.items;
}

// ---------------------------------------------------------------- ring buffer

/// Fixed-capacity ring; evicted items get `deinit(alloc)` called.
pub fn Ring(comptime T: type) type {
    return struct {
        const Self = @This();
        buf: []T = &.{},
        head: usize = 0,
        len: usize = 0,

        pub fn init(alloc: Allocator, cap: usize) Allocator.Error!Self {
            return .{ .buf = try alloc.alloc(T, cap) };
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            self.clear(alloc);
            alloc.free(self.buf);
            self.buf = &.{};
        }

        pub fn clear(self: *Self, alloc: Allocator) void {
            var i: usize = 0;
            while (i < self.len) : (i += 1) self.buf[(self.head + i) % self.buf.len].deinit(alloc);
            self.head = 0;
            self.len = 0;
        }

        pub fn push(self: *Self, alloc: Allocator, item: T) void {
            if (self.buf.len == 0) {
                var it = item;
                it.deinit(alloc);
                return;
            }
            if (self.len == self.buf.len) {
                self.buf[self.head].deinit(alloc);
                self.buf[self.head] = item;
                self.head = (self.head + 1) % self.buf.len;
            } else {
                self.buf[(self.head + self.len) % self.buf.len] = item;
                self.len += 1;
            }
        }

        /// Logical index: 0 is the oldest retained item.
        pub fn at(self: *Self, i: usize) *T {
            return &self.buf[(self.head + i) % self.buf.len];
        }
    };
}

pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warning = 2,
    @"error" = 3,

    pub fn name(self: Level) []const u8 {
        return switch (self) {
            .debug => "debug",
            .info => "info",
            .warning => "warning",
            .@"error" => "error",
        };
    }
    pub fn parse(s: []const u8) ?Level {
        if (std.mem.eql(u8, s, "debug") or std.mem.eql(u8, s, "verbose")) return .debug;
        if (std.mem.eql(u8, s, "info") or std.mem.eql(u8, s, "log")) return .info;
        if (std.mem.eql(u8, s, "warning") or std.mem.eql(u8, s, "warn")) return .warning;
        if (std.mem.eql(u8, s, "error")) return .@"error";
        return null;
    }
};

pub const ConsoleEntry = struct {
    seq: u64,
    /// Session id of the tab that produced it (owned).
    tab: []u8,
    level: Level,
    text: []u8,
    /// "url:line" or empty (owned).
    loc: []u8,

    pub fn deinit(self: *ConsoleEntry, alloc: Allocator) void {
        alloc.free(self.tab);
        alloc.free(self.text);
        alloc.free(self.loc);
    }
};

pub const NetEntry = struct {
    seq: u64,
    tab: []u8,
    request_id: []u8,
    method: []u8,
    url: []u8,
    rtype: []u8,
    mime: []u8,
    /// Failure text (owned, may be empty).
    err: []u8,
    status: i64 = 0,
    done: bool = false,

    pub fn deinit(self: *NetEntry, alloc: Allocator) void {
        alloc.free(self.tab);
        alloc.free(self.request_id);
        alloc.free(self.method);
        alloc.free(self.url);
        alloc.free(self.rtype);
        alloc.free(self.mime);
        alloc.free(self.err);
    }
};

pub const Dialog = struct {
    session: []u8,
    kind: []u8,
    message: []u8,
    default_prompt: []u8,

    pub fn deinit(self: *Dialog, alloc: Allocator) void {
        alloc.free(self.session);
        alloc.free(self.kind);
        alloc.free(self.message);
        alloc.free(self.default_prompt);
    }
};

pub const Session = struct {
    id: []u8,
    target_id: []u8,
    url: []u8,
    main_frame: []u8,
    load_count: u32 = 0,
    /// Bumped on every main-frame navigation; refs are tied to an epoch.
    nav_epoch: u32 = 0,
    alive: bool = true,
    crashed: bool = false,
};

// ---------------------------------------------------------------- transport

pub const Transport = struct {
    ctx: *anyopaque,
    send_fn: *const fn (ctx: *anyopaque, text: []const u8) ws.Error!void,
    /// Next message; slice valid until the next call.
    recv_fn: *const fn (ctx: *anyopaque, timeout_ms: i64) ws.Error![]const u8,
};

/// Transport over a ws.Conn.
pub fn wsTransport(conn: *ws.Conn) Transport {
    const F = struct {
        fn send(ctx: *anyopaque, text: []const u8) ws.Error!void {
            const c: *ws.Conn = @ptrCast(@alignCast(ctx));
            return c.sendText(text);
        }
        fn recv(ctx: *anyopaque, timeout_ms: i64) ws.Error![]const u8 {
            const c: *ws.Conn = @ptrCast(@alignCast(ctx));
            const m = try c.recv(timeout_ms);
            return m.data;
        }
    };
    return .{ .ctx = conn, .send_fn = F.send, .recv_fn = F.recv };
}

pub const Reply = struct {
    /// The "result" object (or .null).
    result: Value = .null,
    err_code: i64 = 0,
    err_msg: ?[]const u8 = null,

    pub fn ok(self: Reply) bool {
        return self.err_msg == null;
    }
};

pub const Client = struct {
    alloc: Allocator,
    io: Io,
    tr: Transport,
    next_id: u32 = 1,
    console: Ring(ConsoleEntry),
    network: Ring(NetEntry),
    console_seq: u64 = 0,
    net_seq: u64 = 0,
    dialog: ?Dialog = null,
    dialog_seq: u64 = 0,
    sessions: std.ArrayList(*Session) = .empty,
    scratch: std.heap.ArenaAllocator,
    default_timeout_ms: i64 = 30_000,

    pub fn init(alloc: Allocator, io: Io, tr: Transport) Allocator.Error!Client {
        return .{
            .alloc = alloc,
            .io = io,
            .tr = tr,
            .console = try Ring(ConsoleEntry).init(alloc, CONSOLE_CAP),
            .network = try Ring(NetEntry).init(alloc, NETWORK_CAP),
            .scratch = std.heap.ArenaAllocator.init(alloc),
        };
    }

    pub fn deinit(self: *Client) void {
        self.console.deinit(self.alloc);
        self.network.deinit(self.alloc);
        if (self.dialog) |*d| d.deinit(self.alloc);
        for (self.sessions.items) |s| self.freeSession(s);
        self.sessions.deinit(self.alloc);
        self.scratch.deinit();
    }

    fn freeSession(self: *Client, s: *Session) void {
        self.alloc.free(s.id);
        self.alloc.free(s.target_id);
        self.alloc.free(s.url);
        self.alloc.free(s.main_frame);
        self.alloc.destroy(s);
    }

    pub fn nowMs(self: *Client) i64 {
        return Io.Clock.awake.now(self.io).toMilliseconds();
    }

    pub fn sleepMs(self: *Client, ms: i64) void {
        self.io.sleep(Io.Duration.fromMilliseconds(ms), .awake) catch {};
    }

    // ------------------------------------------------------------ sessions

    pub fn findSession(self: *Client, session_id: []const u8) ?*Session {
        for (self.sessions.items) |s| if (std.mem.eql(u8, s.id, session_id)) return s;
        return null;
    }

    pub fn findSessionByTarget(self: *Client, target_id: []const u8) ?*Session {
        for (self.sessions.items) |s| if (s.alive and std.mem.eql(u8, s.target_id, target_id)) return s;
        return null;
    }

    pub fn addSession(self: *Client, id: []const u8, target_id: []const u8, url: []const u8) Allocator.Error!*Session {
        const s = try self.alloc.create(Session);
        errdefer self.alloc.destroy(s);
        const id_c = try self.alloc.dupe(u8, id);
        errdefer self.alloc.free(id_c);
        const t_c = try self.alloc.dupe(u8, target_id);
        errdefer self.alloc.free(t_c);
        const u_c = try self.alloc.dupe(u8, url);
        errdefer self.alloc.free(u_c);
        const f_c = try self.alloc.dupe(u8, "");
        errdefer self.alloc.free(f_c);
        s.* = .{ .id = id_c, .target_id = t_c, .url = u_c, .main_frame = f_c };
        try self.sessions.append(self.alloc, s);
        return s;
    }

    fn setOwned(self: *Client, slot: *[]u8, new: []const u8) void {
        const c = self.alloc.dupe(u8, new) catch return;
        self.alloc.free(slot.*);
        slot.* = c;
    }

    // ------------------------------------------------------------ calls

    /// Send one command and wait for its reply. Replies are parsed into
    /// `arena`. Non-matching messages are events and are processed inline.
    /// `params_json` must be a JSON object string (or empty for none).
    pub fn call(self: *Client, arena: Allocator, session: ?[]const u8, method: []const u8, params_json: []const u8, timeout_ms: i64) CallError!Reply {
        const id = self.next_id;
        self.next_id += 1;
        var req: std.ArrayList(u8) = .empty;
        defer req.deinit(self.alloc);
        try req.print(self.alloc, "{{\"id\":{d},\"method\":", .{id});
        try appendJsonString(&req, self.alloc, method);
        try req.appendSlice(self.alloc, ",\"params\":");
        try req.appendSlice(self.alloc, if (params_json.len == 0) "{}" else params_json);
        if (session) |s| {
            try req.appendSlice(self.alloc, ",\"sessionId\":");
            try appendJsonString(&req, self.alloc, s);
        }
        try req.append(self.alloc, '}');
        try self.tr.send_fn(self.tr.ctx, req.items);

        const dialog_before = self.dialog_seq;
        const deadline = self.nowMs() + timeout_ms;
        while (true) {
            if (self.dialog_seq != dialog_before and !std.mem.eql(u8, method, "Page.handleJavaScriptDialog")) {
                return error.DialogOpened;
            }
            const remaining = deadline - self.nowMs();
            if (remaining <= 0) return error.Timeout;
            const data = try self.tr.recv_fn(self.tr.ctx, remaining);
            const v = std.json.parseFromSliceLeaky(Value, arena, data, .{}) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue, // garbage message: ignore
            };
            if (v != .object) continue;
            if (getObj(v, "id")) |idv| {
                const rid: i64 = switch (idv) {
                    .integer => |i| i,
                    else => -1,
                };
                if (rid != id) continue; // stale reply of a timed-out call
                var r: Reply = .{};
                if (getObj(v, "error")) |e| {
                    r.err_code = getInt(e, "code") orelse 0;
                    r.err_msg = getStr(e, "message") orelse "unknown CDP error";
                    if (getStr(e, "data")) |d| {
                        r.err_msg = try std.fmt.allocPrint(arena, "{s} ({s})", .{ r.err_msg.?, d });
                    }
                } else if (getObj(v, "result")) |res| {
                    r.result = res;
                }
                return r;
            }
            if (getStr(v, "method")) |m| {
                self.handleEvent(getStr(v, "sessionId"), m, getObj(v, "params") orelse .null);
            }
        }
    }

    /// Wait up to `timeout_ms` for one message and process it as an event.
    /// Returns false when nothing arrived.
    pub fn pump(self: *Client, timeout_ms: i64) ws.Error!bool {
        _ = self.scratch.reset(.retain_capacity);
        const data = self.tr.recv_fn(self.tr.ctx, @max(timeout_ms, 0)) catch |e| switch (e) {
            error.Timeout => return false,
            else => return e,
        };
        const v = std.json.parseFromSliceLeaky(Value, self.scratch.allocator(), data, .{}) catch return true;
        if (v != .object) return true;
        if (getStr(v, "method")) |m| self.handleEvent(getStr(v, "sessionId"), m, getObj(v, "params") orelse .null);
        return true;
    }

    /// Process events for `ms` milliseconds (or until the connection drops).
    pub fn pumpFor(self: *Client, ms: i64) ws.Error!void {
        const deadline = self.nowMs() + ms;
        while (true) {
            const rem = deadline - self.nowMs();
            if (rem <= 0) return;
            _ = try self.pump(rem);
        }
    }

    // ------------------------------------------------------------ events

    pub fn handleEvent(self: *Client, session: ?[]const u8, method: []const u8, p: Value) void {
        const sid = session orelse "";
        if (std.mem.eql(u8, method, "Runtime.consoleAPICalled")) {
            self.onConsoleApi(sid, p);
        } else if (std.mem.eql(u8, method, "Runtime.exceptionThrown")) {
            self.onException(sid, p);
        } else if (std.mem.eql(u8, method, "Log.entryAdded")) {
            const e = getObj(p, "entry") orelse return;
            const lvl = Level.parse(getStr(e, "level") orelse "info") orelse .info;
            var loc_buf: [400]u8 = undefined;
            const loc = fmtLoc(&loc_buf, getStr(e, "url") orelse "", getInt(e, "lineNumber"));
            self.pushConsole(sid, lvl, getStr(e, "text") orelse "", loc);
        } else if (std.mem.eql(u8, method, "Network.requestWillBeSent")) {
            self.onRequest(sid, p);
        } else if (std.mem.eql(u8, method, "Network.responseReceived")) {
            const rid = getStr(p, "requestId") orelse return;
            if (self.findNet(sid, rid)) |e| {
                const resp = getObj(p, "response") orelse return;
                e.status = getInt(resp, "status") orelse 0;
                self.setOwned(&e.mime, getStr(resp, "mimeType") orelse "");
            }
        } else if (std.mem.eql(u8, method, "Network.loadingFailed")) {
            const rid = getStr(p, "requestId") orelse return;
            if (self.findNet(sid, rid)) |e| {
                e.done = true;
                var buf: [200]u8 = undefined;
                const t = getStr(p, "errorText") orelse "failed";
                const s = if (getBool(p, "canceled") orelse false) std.fmt.bufPrint(&buf, "{s} (canceled)", .{t}) catch t else t;
                self.setOwned(&e.err, s);
            }
        } else if (std.mem.eql(u8, method, "Network.loadingFinished")) {
            const rid = getStr(p, "requestId") orelse return;
            if (self.findNet(sid, rid)) |e| e.done = true;
        } else if (std.mem.eql(u8, method, "Page.javascriptDialogOpening")) {
            if (self.dialog) |*d| d.deinit(self.alloc);
            self.dialog = null;
            const d: Dialog = .{
                .session = self.alloc.dupe(u8, sid) catch return,
                .kind = self.alloc.dupe(u8, getStr(p, "type") orelse "alert") catch return,
                .message = self.alloc.dupe(u8, clip(getStr(p, "message") orelse "", 2000)) catch return,
                .default_prompt = self.alloc.dupe(u8, clip(getStr(p, "defaultPrompt") orelse "", 500)) catch return,
            };
            self.dialog = d;
            self.dialog_seq += 1;
        } else if (std.mem.eql(u8, method, "Page.javascriptDialogClosed")) {
            if (self.dialog) |*d| d.deinit(self.alloc);
            self.dialog = null;
        } else if (std.mem.eql(u8, method, "Page.frameNavigated")) {
            const s = self.findSession(sid) orelse return;
            const fr = getObj(p, "frame") orelse return;
            if (getStr(fr, "parentId") != null) return;
            self.setOwned(&s.url, getStr(fr, "url") orelse "");
            self.setOwned(&s.main_frame, getStr(fr, "id") orelse "");
            s.nav_epoch += 1;
        } else if (std.mem.eql(u8, method, "Page.navigatedWithinDocument")) {
            const s = self.findSession(sid) orelse return;
            if (getStr(p, "frameId")) |f| if (std.mem.eql(u8, f, s.main_frame)) {
                self.setOwned(&s.url, getStr(p, "url") orelse "");
            };
        } else if (std.mem.eql(u8, method, "Page.loadEventFired")) {
            if (self.findSession(sid)) |s| s.load_count += 1;
        } else if (std.mem.eql(u8, method, "Target.detachedFromTarget")) {
            if (getStr(p, "sessionId")) |x| if (self.findSession(x)) |s| {
                s.alive = false;
            };
        } else if (std.mem.eql(u8, method, "Target.targetDestroyed")) {
            if (getStr(p, "targetId")) |t| for (self.sessions.items) |s| {
                if (std.mem.eql(u8, s.target_id, t)) s.alive = false;
            };
        } else if (std.mem.eql(u8, method, "Inspector.targetCrashed") or std.mem.eql(u8, method, "Target.targetCrashed")) {
            if (self.findSession(sid)) |s| s.crashed = true;
        }
    }

    fn clip(s: []const u8, n: usize) []const u8 {
        if (s.len <= n) return s;
        var e = n;
        while (e > 0 and (s[e] & 0xC0) == 0x80) e -= 1;
        return s[0..e];
    }

    fn fmtLoc(buf: []u8, url: []const u8, line: ?i64) []const u8 {
        if (url.len == 0) return "";
        const u = clip(url, 300);
        if (line) |l| return std.fmt.bufPrint(buf, "{s}:{d}", .{ u, l + 1 }) catch u;
        return u;
    }

    fn pushConsole(self: *Client, sid: []const u8, level: Level, text: []const u8, loc: []const u8) void {
        const a = self.alloc;
        const tab = a.dupe(u8, sid) catch return;
        const t = a.dupe(u8, clip(text, 2000)) catch {
            a.free(tab);
            return;
        };
        const l = a.dupe(u8, loc) catch {
            a.free(tab);
            a.free(t);
            return;
        };
        self.console_seq += 1;
        self.console.push(a, .{ .seq = self.console_seq, .tab = tab, .level = level, .text = t, .loc = l });
    }

    fn remoteObjText(arena: Allocator, ro: Value) []const u8 {
        if (getObj(ro, "value")) |v| switch (v) {
            .string => |s| return s,
            .integer => |i| return std.fmt.allocPrint(arena, "{d}", .{i}) catch "?",
            .float => |f| return std.fmt.allocPrint(arena, "{d}", .{f}) catch "?",
            .bool => |b| return if (b) "true" else "false",
            .null => return "null",
            else => {},
        };
        if (getStr(ro, "unserializableValue")) |u| return u;
        if (getStr(ro, "description")) |d| return d;
        return getStr(ro, "type") orelse "?";
    }

    fn onConsoleApi(self: *Client, sid: []const u8, p: Value) void {
        const ty = getStr(p, "type") orelse "log";
        const lvl: Level = if (std.mem.eql(u8, ty, "error") or std.mem.eql(u8, ty, "assert"))
            .@"error"
        else if (std.mem.eql(u8, ty, "warning"))
            .warning
        else if (std.mem.eql(u8, ty, "debug") or std.mem.eql(u8, ty, "trace"))
            .debug
        else
            .info;
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var text: std.ArrayList(u8) = .empty;
        if (getArr(p, "args")) |args| for (args, 0..) |a, i| {
            if (i > 0) text.append(arena, ' ') catch return;
            text.appendSlice(arena, remoteObjText(arena, a)) catch return;
            if (text.items.len > 2000) break;
        };
        var loc_buf: [400]u8 = undefined;
        var loc: []const u8 = "";
        if (getObj(p, "stackTrace")) |st| if (getArr(st, "callFrames")) |cf| if (cf.len > 0) {
            loc = fmtLoc(&loc_buf, getStr(cf[0], "url") orelse "", getInt(cf[0], "lineNumber"));
        };
        self.pushConsole(sid, lvl, text.items, loc);
    }

    fn onException(self: *Client, sid: []const u8, p: Value) void {
        const d = getObj(p, "exceptionDetails") orelse return;
        var buf: [2100]u8 = undefined;
        var text: []const u8 = getStr(d, "text") orelse "Uncaught";
        if (getObj(d, "exception")) |ex| if (getStr(ex, "description")) |desc| {
            const first = if (std.mem.indexOfScalar(u8, desc, '\n')) |nl| desc[0..nl] else desc;
            text = std.fmt.bufPrint(&buf, "{s}", .{clip(first, 2000)}) catch text;
        };
        var loc_buf: [400]u8 = undefined;
        const loc = fmtLoc(&loc_buf, getStr(d, "url") orelse "", getInt(d, "lineNumber"));
        self.pushConsole(sid, .@"error", text, loc);
    }

    fn findNet(self: *Client, sid: []const u8, rid: []const u8) ?*NetEntry {
        var i = self.network.len;
        while (i > 0) {
            i -= 1;
            const e = self.network.at(i);
            if (std.mem.eql(u8, e.request_id, rid) and std.mem.eql(u8, e.tab, sid)) return e;
        }
        return null;
    }

    fn onRequest(self: *Client, sid: []const u8, p: Value) void {
        const rid = getStr(p, "requestId") orelse return;
        const req = getObj(p, "request") orelse return;
        if (getObj(p, "redirectResponse")) |rr| {
            if (self.findNet(sid, rid)) |old| {
                old.status = getInt(rr, "status") orelse old.status;
                old.done = true;
            }
        }
        const a = self.alloc;
        const url = clip(getStr(req, "url") orelse "", 400);
        var e: NetEntry = .{
            .seq = 0,
            .tab = a.dupe(u8, sid) catch return,
            .request_id = &.{},
            .method = &.{},
            .url = &.{},
            .rtype = &.{},
            .mime = &.{},
            .err = &.{},
        };
        // Allocate the rest; on failure free what we have.
        e.request_id = a.dupe(u8, rid) catch return self.abortEntry(&e);
        e.method = a.dupe(u8, getStr(req, "method") orelse "GET") catch return self.abortEntry(&e);
        e.url = a.dupe(u8, url) catch return self.abortEntry(&e);
        e.rtype = a.dupe(u8, getStr(p, "type") orelse "") catch return self.abortEntry(&e);
        e.mime = a.dupe(u8, "") catch return self.abortEntry(&e);
        e.err = a.dupe(u8, "") catch return self.abortEntry(&e);
        self.net_seq += 1;
        e.seq = self.net_seq;
        self.network.push(a, e);
    }

    fn abortEntry(self: *Client, e: *NetEntry) void {
        // Slices not yet allocated are empty (len 0, free is a no-op).
        e.deinit(self.alloc);
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Scripted fake CDP endpoint: every request is parsed and passed to
/// `respond`, which returns the messages to deliver (events first, then the
/// reply, in the order given). Also usable directly as a Transport.
pub const Fake = struct {
    pub const Respond = *const fn (f: *Fake, arena: Allocator, id: i64, method: []const u8, session: ?[]const u8, params: Value, out: *std.ArrayList([]const u8)) anyerror!void;

    alloc: Allocator,
    respond: Respond,
    user: ?*anyopaque = null,
    queue: std.ArrayList([]u8) = .empty,
    cur: ?[]u8 = null,
    /// Every request received ("method sessionId params").
    log: std.ArrayList([]u8) = .empty,
    /// When true, recv on an empty queue reports Closed instead of Timeout.
    closed_when_empty: bool = false,

    pub fn init(alloc: Allocator, respond: Respond) Fake {
        return .{ .alloc = alloc, .respond = respond };
    }

    pub fn deinit(self: *Fake) void {
        for (self.queue.items) |m| self.alloc.free(m);
        self.queue.deinit(self.alloc);
        if (self.cur) |c| self.alloc.free(c);
        for (self.log.items) |m| self.alloc.free(m);
        self.log.deinit(self.alloc);
    }

    pub fn transport(self: *Fake) Transport {
        return .{ .ctx = self, .send_fn = sendFn, .recv_fn = recvFn };
    }

    /// Queue an unsolicited event to be delivered on the next recv.
    pub fn pushEvent(self: *Fake, msg: []const u8) !void {
        try self.queue.append(self.alloc, try self.alloc.dupe(u8, msg));
    }

    fn sendFn(ctx: *anyopaque, text: []const u8) ws.Error!void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.handle(text) catch return error.IoFailed;
    }

    fn handle(self: *Fake, text: []const u8) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const v = try std.json.parseFromSliceLeaky(Value, arena, text, .{});
        const id = getInt(v, "id") orelse return error.BadRequest;
        const method = getStr(v, "method") orelse return error.BadRequest;
        const sess = getStr(v, "sessionId");
        const params = getObj(v, "params") orelse .null;
        try self.log.append(self.alloc, try std.fmt.allocPrint(self.alloc, "{s} {s} {s}", .{ method, sess orelse "-", text }));
        var out: std.ArrayList([]const u8) = .empty;
        try self.respond(self, arena, id, method, sess, params, &out);
        for (out.items) |m| try self.queue.append(self.alloc, try self.alloc.dupe(u8, m));
    }

    fn recvFn(ctx: *anyopaque, _: i64) ws.Error![]const u8 {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        if (self.cur) |c| {
            self.alloc.free(c);
            self.cur = null;
        }
        if (self.queue.items.len == 0) return if (self.closed_when_empty) error.Closed else error.Timeout;
        self.cur = self.queue.orderedRemove(0);
        return self.cur.?;
    }

    /// True when some logged request line contains `needle`.
    pub fn saw(self: *const Fake, needle: []const u8) bool {
        for (self.log.items) |l| if (std.mem.indexOf(u8, l, needle) != null) return true;
        return false;
    }
};

fn okReply(arena: Allocator, out: *std.ArrayList([]const u8), id: i64, result: []const u8) !void {
    try out.append(arena, try std.fmt.allocPrint(arena, "{{\"id\":{d},\"result\":{s}}}", .{ id, result }));
}

fn corrRespond(f: *Fake, arena: Allocator, id: i64, method: []const u8, session: ?[]const u8, params: Value, out: *std.ArrayList([]const u8)) anyerror!void {
    _ = f;
    _ = session;
    _ = params;
    if (std.mem.eql(u8, method, "Test.echo")) {
        // interleaved events BEFORE the reply, a stale reply, and a garbage line
        try out.append(arena, "{\"method\":\"Runtime.consoleAPICalled\",\"sessionId\":\"S1\",\"params\":{\"type\":\"error\",\"args\":[{\"type\":\"string\",\"value\":\"boom\"},{\"type\":\"number\",\"value\":42}],\"stackTrace\":{\"callFrames\":[{\"url\":\"http://x/a.js\",\"lineNumber\":6}]}}}");
        try out.append(arena, "not json at all");
        try out.append(arena, "{\"id\":9999,\"result\":{\"stale\":true}}");
        try out.append(arena, "{\"method\":\"Network.requestWillBeSent\",\"sessionId\":\"S1\",\"params\":{\"requestId\":\"R1\",\"request\":{\"url\":\"http://x/api\",\"method\":\"POST\"},\"type\":\"XHR\"}}");
        try out.append(arena, "{\"method\":\"Network.responseReceived\",\"sessionId\":\"S1\",\"params\":{\"requestId\":\"R1\",\"response\":{\"status\":404,\"mimeType\":\"text/html\"}}}");
        try okReply(arena, out, id, "{\"echo\":true}");
        try out.append(arena, "{\"method\":\"Network.loadingFinished\",\"sessionId\":\"S1\",\"params\":{\"requestId\":\"R1\"}}");
    } else if (std.mem.eql(u8, method, "Test.fail")) {
        try out.append(arena, try std.fmt.allocPrint(arena, "{{\"id\":{d},\"error\":{{\"code\":-32000,\"message\":\"Could not find node\"}}}}", .{id}));
    } else if (std.mem.eql(u8, method, "Test.silent")) {
        // never replies
    } else if (std.mem.eql(u8, method, "Test.dialog")) {
        try out.append(arena, "{\"method\":\"Page.javascriptDialogOpening\",\"sessionId\":\"S1\",\"params\":{\"url\":\"http://x\",\"message\":\"Sure?\",\"type\":\"confirm\",\"hasBrowserHandler\":false}}");
    } else {
        try okReply(arena, out, id, "{}");
    }
}

test "call correlates by id across interleaved events, stale replies and garbage" {
    const a = testing.allocator;
    var fake = Fake.init(a, corrRespond);
    defer fake.deinit();
    var c = try Client.init(a, testing.io, fake.transport());
    defer c.deinit();
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const r = try c.call(arena, "S1", "Test.echo", "{\"x\":1}", 1000);
    try testing.expect(r.ok());
    try testing.expectEqual(true, getBool(r.result, "echo").?);
    // Events that arrived before the reply were drained; the one after is
    // picked up by the next pump.
    try testing.expectEqual(@as(usize, 1), c.console.len);
    const ce = c.console.at(0);
    try testing.expectEqual(Level.@"error", ce.level);
    try testing.expectEqualStrings("boom 42", ce.text);
    try testing.expectEqualStrings("http://x/a.js:7", ce.loc);
    try testing.expectEqual(@as(usize, 1), c.network.len);
    try testing.expectEqual(@as(i64, 404), c.network.at(0).status);
    try testing.expect(!c.network.at(0).done);
    try testing.expect(try c.pump(10));
    try testing.expect(c.network.at(0).done);
    try testing.expect(!(try c.pump(1)));
    // request framing
    try testing.expect(fake.saw("Test.echo S1 {\"id\":1,\"method\":\"Test.echo\",\"params\":{\"x\":1},\"sessionId\":\"S1\"}"));

    const e = try c.call(arena, null, "Test.fail", "", 1000);
    try testing.expect(!e.ok());
    try testing.expectEqualStrings("Could not find node", e.err_msg.?);
    try testing.expect(fake.saw("Test.fail - {\"id\":2,\"method\":\"Test.fail\",\"params\":{}}"));
}

test "call times out on a silent endpoint and aborts when a dialog opens" {
    const a = testing.allocator;
    var fake = Fake.init(a, corrRespond);
    defer fake.deinit();
    var c = try Client.init(a, testing.io, fake.transport());
    defer c.deinit();
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.Timeout, c.call(arena, "S1", "Test.silent", "", 30));
    try testing.expectError(error.DialogOpened, c.call(arena, "S1", "Test.dialog", "", 1000));
    try testing.expect(c.dialog != null);
    try testing.expectEqualStrings("Sure?", c.dialog.?.message);
    try testing.expectEqualStrings("confirm", c.dialog.?.kind);
    // Handling the dialog is allowed while it is open.
    const r = try c.call(arena, "S1", "Page.handleJavaScriptDialog", "{\"accept\":true}", 1000);
    try testing.expect(r.ok());
    try c.tr.send_fn(c.tr.ctx, "{\"id\":77,\"method\":\"noop\"}");
    fake.closed_when_empty = true;
    try testing.expectError(error.Closed, c.call(arena, "S1", "Test.silent", "", 1000));
}

test "ring buffer evicts oldest and frees entries" {
    const a = testing.allocator;
    var r = try Ring(ConsoleEntry).init(a, 3);
    defer r.deinit(a);
    var i: u64 = 1;
    while (i <= 5) : (i += 1) {
        r.push(a, .{
            .seq = i,
            .tab = try a.dupe(u8, "t"),
            .level = .info,
            .text = try std.fmt.allocPrint(a, "m{d}", .{i}),
            .loc = try a.dupe(u8, ""),
        });
    }
    try testing.expectEqual(@as(usize, 3), r.len);
    try testing.expectEqual(@as(u64, 3), r.at(0).seq);
    try testing.expectEqual(@as(u64, 5), r.at(2).seq);
    try testing.expectEqualStrings("m4", r.at(1).text);
    r.clear(a);
    try testing.expectEqual(@as(usize, 0), r.len);
    r.push(a, .{ .seq = 9, .tab = try a.dupe(u8, "t"), .level = .info, .text = try a.dupe(u8, "z"), .loc = try a.dupe(u8, "") });
    try testing.expectEqual(@as(u64, 9), r.at(0).seq);
}

test "console and network rings are bounded at 200 with correct eviction" {
    const a = testing.allocator;
    var fake = Fake.init(a, corrRespond);
    defer fake.deinit();
    var c = try Client.init(a, testing.io, fake.transport());
    defer c.deinit();
    var i: usize = 0;
    while (i < 450) : (i += 1) {
        var buf: [256]u8 = undefined;
        const m = try std.fmt.bufPrint(&buf, "{{\"method\":\"Network.requestWillBeSent\",\"sessionId\":\"S1\",\"params\":{{\"requestId\":\"r{d}\",\"request\":{{\"url\":\"http://x/{d}\",\"method\":\"GET\"}}}}}}", .{ i, i });
        try fake.pushEvent(m);
        const m2 = try std.fmt.bufPrint(&buf, "{{\"method\":\"Log.entryAdded\",\"sessionId\":\"S1\",\"params\":{{\"entry\":{{\"level\":\"warning\",\"text\":\"w{d}\",\"url\":\"http://x\",\"lineNumber\":0}}}}}}", .{i});
        try fake.pushEvent(m2);
    }
    while (try c.pump(1)) {}
    try testing.expectEqual(@as(usize, CONSOLE_CAP), c.console.len);
    try testing.expectEqual(@as(usize, NETWORK_CAP), c.network.len);
    try testing.expectEqualStrings("w250", c.console.at(0).text);
    try testing.expectEqualStrings("http://x/449", c.network.at(NETWORK_CAP - 1).url);
    try testing.expectEqual(@as(u64, 450), c.network.at(NETWORK_CAP - 1).seq);
}

test "navigation events update the session; redirect closes the previous entry" {
    const a = testing.allocator;
    var fake = Fake.init(a, corrRespond);
    defer fake.deinit();
    var c = try Client.init(a, testing.io, fake.transport());
    defer c.deinit();
    const s = try c.addSession("S1", "T1", "about:blank");
    c.handleEvent("S1", "Page.frameNavigated", try std.json.parseFromSliceLeaky(Value, c.scratch.allocator(), "{\"frame\":{\"id\":\"F\",\"url\":\"http://a/\"}}", .{}));
    c.handleEvent("S1", "Page.frameNavigated", try std.json.parseFromSliceLeaky(Value, c.scratch.allocator(), "{\"frame\":{\"id\":\"F2\",\"parentId\":\"F\",\"url\":\"http://iframe/\"}}", .{}));
    try testing.expectEqualStrings("http://a/", s.url);
    try testing.expectEqual(@as(u32, 1), s.nav_epoch);
    c.handleEvent("S1", "Page.navigatedWithinDocument", try std.json.parseFromSliceLeaky(Value, c.scratch.allocator(), "{\"frameId\":\"F\",\"url\":\"http://a/#x\"}", .{}));
    try testing.expectEqualStrings("http://a/#x", s.url);
    c.handleEvent("S1", "Page.loadEventFired", .null);
    try testing.expectEqual(@as(u32, 1), s.load_count);
    c.handleEvent("S1", "Network.requestWillBeSent", try std.json.parseFromSliceLeaky(Value, c.scratch.allocator(), "{\"requestId\":\"R\",\"request\":{\"url\":\"http://a/\",\"method\":\"GET\"}}", .{}));
    c.handleEvent("S1", "Network.requestWillBeSent", try std.json.parseFromSliceLeaky(Value, c.scratch.allocator(), "{\"requestId\":\"R\",\"request\":{\"url\":\"http://b/\",\"method\":\"GET\"},\"redirectResponse\":{\"status\":301}}", .{}));
    try testing.expectEqual(@as(usize, 2), c.network.len);
    try testing.expectEqual(@as(i64, 301), c.network.at(0).status);
    try testing.expect(c.network.at(0).done);
    c.handleEvent("S1", "Network.loadingFailed", try std.json.parseFromSliceLeaky(Value, c.scratch.allocator(), "{\"requestId\":\"R\",\"errorText\":\"net::ERR_BLOCKED_BY_CLIENT\"}", .{}));
    try testing.expectEqualStrings("net::ERR_BLOCKED_BY_CLIENT", c.network.at(1).err);
    c.handleEvent("S1", "Target.detachedFromTarget", try std.json.parseFromSliceLeaky(Value, c.scratch.allocator(), "{\"sessionId\":\"S1\"}", .{}));
    try testing.expect(!s.alive);
}

test "obj builder and json string escaping" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const j = try obj(arena, .{ .url = "a\"b\\c\n\x01", .n = 3, .yes = true, .f = 1.5, .raw = Raw{ .json = "[1,2]" } });
    try testing.expectEqualStrings("{\"url\":\"a\\\"b\\\\c\\n\\u0001\",\"n\":3,\"yes\":true,\"f\":1.5,\"raw\":[1,2]}", j);
    _ = try std.json.parseFromSliceLeaky(Value, arena, j, .{});
}
