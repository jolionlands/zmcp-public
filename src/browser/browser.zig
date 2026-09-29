//! Browser connection state shared by the tool handlers: lazily launches (or
//! attaches to) Chrome, owns the CDP client, the active tab, the current
//! ref -> DOM node map, and turns transport errors into model-readable text.

const std = @import("std");
const cdp = @import("cdp.zig");
const ws = @import("ws.zig");
const launch = @import("launch.zig");
const policy = @import("policy.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// error.Fail means `Browser.last_err` holds the message for the model.
pub const Err = error{ Fail, OutOfMemory };

pub const Settings = struct {
    allow_local: bool = false,
    origins: []const []const u8 = &.{},
    no_eval: bool = false,
    attach: bool = false,
    cdp_url: []const u8 = "http://127.0.0.1:9222",
    launch: launch.Config = .{},
};

pub const PageInfo = struct {
    target_id: []const u8,
    title: []const u8,
    url: []const u8,
};

pub const Browser = struct {
    gpa: Allocator,
    io: Io,
    env: ?*const std.process.Environ.Map = null,
    settings: Settings = .{},

    tcp: ?*ws.Tcp = null,
    conn: ?*ws.Conn = null,
    client: ?*cdp.Client = null,
    launched: ?launch.Launched = null,
    active: ?*cdp.Session = null,

    /// refs[n-1] is the DOM backend node id of "e<n>" in the last snapshot.
    refs: []i64 = &.{},
    ref_session: []u8 = &.{},
    ref_epoch: u32 = 0,

    /// Tabs this server opened in an attached browser (closed on exit).
    owned: std.ArrayList([]u8) = .empty,
    /// Target ids in first-seen order (stable tab indexes).
    tab_order: std.ArrayList([]u8) = .empty,

    last_err: []const u8 = "",

    pub fn policyNow(self: *const Browser) policy.Policy {
        return .{ .allow_local = self.settings.allow_local, .allow_origins = self.settings.origins };
    }

    pub fn failf(self: *Browser, arena: Allocator, comptime fmt: []const u8, args: anytype) Err {
        self.last_err = try std.fmt.allocPrint(arena, fmt, args);
        return error.Fail;
    }

    // ------------------------------------------------------------ lifecycle

    /// Make sure a browser connection and an active tab exist.
    pub fn ensure(self: *Browser, arena: Allocator) Err!*cdp.Client {
        if (self.client) |c| {
            const dead = if (self.conn) |cn| cn.closed else false;
            if (!dead) {
                if (self.active == null or !self.active.?.alive) try self.pickActive(arena);
                return c;
            }
            self.teardown();
        }
        self.connectNew(arena) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Fail => {
                self.teardown();
                return error.Fail;
            },
        };
        return self.client.?;
    }

    fn connectNew(self: *Browser, arena: Allocator) Err!void {
        var host: []const u8 = "127.0.0.1";
        var port: u16 = 0;
        var path: []const u8 = "";
        if (self.settings.attach) {
            const t = launch.parseAttachUrl(self.settings.cdp_url) catch |e| return self.failf(arena, "bad CDP_URL {s}: {s}", .{ self.settings.cdp_url, if (e == error.NotLoopback) "only loopback hosts are allowed" else "expected http://127.0.0.1:9222" });
            host = t.host;
            port = t.port;
            const p = launch.fetchBrowserPath(self.gpa, self.io, host, port) catch |e|
                return self.failf(arena, "cannot reach Chrome at {s} ({s}). Start it with --remote-debugging-port={d} or unset ZMCP_BROWSER_ATTACH to launch a private browser.", .{ self.settings.cdp_url, @errorName(e), port });
            path = try arena.dupe(u8, p);
            self.gpa.free(p);
        } else {
            const env = self.env orelse return self.failf(arena, "environment unavailable", .{});
            var detail: ?[]u8 = null;
            const l = launch.launch(self.gpa, self.io, env, self.settings.launch, &detail, 15_000) catch |e| {
                defer if (detail) |d| self.gpa.free(d);
                return self.failf(arena, "cannot start browser: {s}{s}{s}", .{ @errorName(e), if (detail != null) " - " else "", detail orelse "" });
            };
            self.launched = l;
            // Signal-based cleanup is POSIX-only; on Windows child.id is a handle, not a pid.
            if (comptime @import("builtin").os.tag != .windows) {
                if (l.child.id) |pid| launch.armSignalKill(@intCast(pid));
            }
            host = try arena.dupe(u8, l.endpoint.host);
            port = l.endpoint.port;
            path = try arena.dupe(u8, l.endpoint.path);
        }

        const tcp = ws.Tcp.connect(self.gpa, self.io, host, port) catch |e|
            return self.failf(arena, "cannot connect to DevTools port {d}: {s}", .{ port, @errorName(e) });
        self.tcp = tcp;
        const conn = try self.gpa.create(ws.Conn);
        var seed: [8]u8 = undefined;
        self.io.random(&seed);
        conn.* = ws.Conn.init(self.gpa, tcp.byteStream(), std.mem.readInt(u64, &seed, .little));
        self.conn = conn;
        const host_hdr = try std.fmt.allocPrint(arena, "{s}:{d}", .{ if (std.mem.indexOfScalar(u8, host, ':') != null) "[::1]" else host, port });
        ws.handshake(conn, .{ .host = host_hdr, .path = path }) catch |e|
            return self.failf(arena, "DevTools WebSocket handshake failed: {s}", .{@errorName(e)});

        const client = try self.gpa.create(cdp.Client);
        client.* = try cdp.Client.init(self.gpa, self.io, cdp.wsTransport(conn));
        self.client = client;

        if (self.settings.attach) {
            // Never hijack one of the user's tabs: work in a fresh one.
            const r = try self.browserCmd(arena, "Target.createTarget", "{\"url\":\"about:blank\"}");
            const tid = cdp.getStr(r.result, "targetId") orelse return self.failf(arena, "Target.createTarget returned no targetId", .{});
            self.noteOwned(tid);
            self.active = try self.attachTarget(arena, tid, "about:blank");
        } else {
            try self.pickActive(arena);
        }
    }

    /// Attach to the first page target (creating one if the browser has none).
    fn pickActive(self: *Browser, arena: Allocator) Err!void {
        if (!self.settings.attach) {
            const pages = try self.listPages(arena);
            for (pages) |p| {
                const s = self.client.?.findSessionByTarget(p.target_id) orelse try self.attachTarget(arena, p.target_id, p.url);
                self.active = s;
                return;
            }
        }
        const r = try self.browserCmd(arena, "Target.createTarget", "{\"url\":\"about:blank\"}");
        const tid = cdp.getStr(r.result, "targetId") orelse return self.failf(arena, "Target.createTarget returned no targetId", .{});
        self.noteOwned(tid);
        self.active = try self.attachTarget(arena, tid, "about:blank");
    }

    /// Best-effort graceful close, then kill and delete the temp profile.
    pub fn teardown(self: *Browser) void {
        if (self.client) |c| {
            if (self.conn) |cn| if (!cn.closed) {
                var ar = std.heap.ArenaAllocator.init(self.gpa);
                defer ar.deinit();
                if (self.settings.attach) {
                    // Never close the user's browser: only the tabs we opened.
                    for (self.owned.items) |t| {
                        const pj = cdp.obj(ar.allocator(), .{ .targetId = t }) catch continue;
                        _ = c.call(ar.allocator(), null, "Target.closeTarget", pj, 500) catch {};
                    }
                } else {
                    _ = c.call(ar.allocator(), null, "Browser.close", "", 500) catch {};
                }
                cn.close();
            };
            c.deinit();
            self.gpa.destroy(c);
            self.client = null;
        }
        if (self.conn) |cn| {
            cn.deinit();
            self.gpa.destroy(cn);
            self.conn = null;
        }
        if (self.tcp) |t| {
            t.destroy(self.gpa);
            self.tcp = null;
        }
        if (self.launched) |*l| {
            launch.shutdown(self.gpa, self.io, l);
            self.launched = null;
        }
        self.active = null;
        for (self.owned.items) |t| self.gpa.free(t);
        self.owned.clearAndFree(self.gpa);
        for (self.tab_order.items) |t| self.gpa.free(t);
        self.tab_order.clearAndFree(self.gpa);
        self.clearRefs();
    }

    pub fn clearRefs(self: *Browser) void {
        self.gpa.free(self.refs);
        self.gpa.free(self.ref_session);
        self.refs = &.{};
        self.ref_session = &.{};
        self.ref_epoch = 0;
    }

    pub fn setRefs(self: *Browser, refs: []const i64, sess: *cdp.Session) Allocator.Error!void {
        const r = try self.gpa.dupe(i64, refs);
        errdefer self.gpa.free(r);
        const sid = try self.gpa.dupe(u8, sess.id);
        self.clearRefs();
        self.refs = r;
        self.ref_session = sid;
        self.ref_epoch = sess.nav_epoch;
    }

    // ------------------------------------------------------------ commands

    pub fn mapErr(self: *Browser, arena: Allocator, method: []const u8, e: cdp.CallError) Err {
        switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Timeout => return self.failf(arena, "Chrome did not answer {s} in time; the page may be hung or blocked by a dialog (see browser_handle_dialog).", .{method}),
            error.DialogOpened => {
                const c = self.client.?;
                if (c.dialog) |d| return self.failf(arena, "A JavaScript {s} dialog opened: \"{s}\". Call browser_handle_dialog to accept or dismiss it.", .{ d.kind, d.message });
                return self.failf(arena, "A JavaScript dialog opened; call browser_handle_dialog.", .{});
            },
            error.TooLarge => return self.failf(arena, "{s}: response too large", .{method}),
            else => {
                self.teardown();
                return self.failf(arena, "Lost the connection to the browser during {s}; it will be restarted on the next call (open pages are lost).", .{method});
            },
        }
    }

    /// Command on the active tab; a CDP error reply becomes a failure.
    pub fn cmd(self: *Browser, arena: Allocator, method: []const u8, params: []const u8) Err!cdp.Reply {
        const r = try self.cmdRaw(arena, method, params);
        if (r.err_msg) |m| return self.failf(arena, "{s}: {s}", .{ method, m });
        return r;
    }

    /// Like `cmd` but a CDP error reply is returned for the caller to judge.
    pub fn cmdRaw(self: *Browser, arena: Allocator, method: []const u8, params: []const u8) Err!cdp.Reply {
        return self.cmdTimeout(arena, method, params, 30_000);
    }

    /// Command with an explicit timeout on the active tab (CallError kept).
    pub fn cmdTimeout(self: *Browser, arena: Allocator, method: []const u8, params: []const u8, timeout_ms: i64) Err!cdp.Reply {
        const c = try self.ensure(arena);
        const s = self.active orelse return self.failf(arena, "no active tab", .{});
        if (c.dialog) |d| if (std.mem.eql(u8, d.session, s.id) and !std.mem.eql(u8, method, "Page.handleJavaScriptDialog")) {
            return self.failf(arena, "A JavaScript {s} dialog is open: \"{s}\". Call browser_handle_dialog first.", .{ d.kind, d.message });
        };
        const r = c.call(arena, s.id, method, params, timeout_ms) catch |e| return self.mapErr(arena, method, e);
        if (r.err_msg) |m| if (std.mem.indexOf(u8, m, "Session with given id not found") != null) {
            s.alive = false;
            return self.failf(arena, "This tab was closed. Use browser_tabs to list or open tabs.", .{});
        };
        return r;
    }

    /// Browser-level command (no session).
    pub fn browserCmd(self: *Browser, arena: Allocator, method: []const u8, params: []const u8) Err!cdp.Reply {
        const c = self.client.?;
        const r = c.call(arena, null, method, params, c.default_timeout_ms) catch |e| return self.mapErr(arena, method, e);
        if (r.err_msg) |m| return self.failf(arena, "{s}: {s}", .{ method, m });
        return r;
    }

    pub fn sessionCmd(self: *Browser, arena: Allocator, sess: *cdp.Session, method: []const u8, params: []const u8) Err!cdp.Reply {
        const c = self.client.?;
        const r = c.call(arena, sess.id, method, params, c.default_timeout_ms) catch |e| return self.mapErr(arena, method, e);
        if (r.err_msg) |m| return self.failf(arena, "{s}: {s}", .{ method, m });
        return r;
    }

    // ------------------------------------------------------------ tabs

    /// Remember a tab we created in an attached browser.
    pub fn noteOwned(self: *Browser, target_id: []const u8) void {
        if (!self.settings.attach) return;
        const d = self.gpa.dupe(u8, target_id) catch return;
        self.owned.append(self.gpa, d) catch self.gpa.free(d);
    }

    pub fn attachTarget(self: *Browser, arena: Allocator, target_id: []const u8, url: []const u8) Err!*cdp.Session {
        const c = self.client.?;
        if (c.findSessionByTarget(target_id)) |s| return s;
        const p = try cdp.obj(arena, .{ .targetId = target_id, .flatten = true });
        const r = try self.browserCmd(arena, "Target.attachToTarget", p);
        const sid = cdp.getStr(r.result, "sessionId") orelse return self.failf(arena, "attach returned no sessionId", .{});
        const s = try c.addSession(sid, target_id, url);
        for ([_][]const u8{ "Page.enable", "Runtime.enable", "Network.enable", "Log.enable", "Accessibility.enable" }) |m| {
            _ = try self.sessionCmd(arena, s, m, "");
        }
        // Headless window size includes browser chrome; pin the viewport so it
        // is exactly the configured size (not for headed / attached browsers).
        if (!self.settings.attach and !self.settings.launch.headed) {
            const vp = try cdp.obj(arena, .{ .width = self.settings.launch.window_width, .height = self.settings.launch.window_height, .deviceScaleFactor = 1, .mobile = false });
            _ = try self.sessionCmd(arena, s, "Emulation.setDeviceMetricsOverride", vp);
        }
        return s;
    }

    /// Page targets in browser order.
    pub fn listPages(self: *Browser, arena: Allocator) Err![]PageInfo {
        const r = try self.browserCmd(arena, "Target.getTargets", "");
        var out: std.ArrayList(PageInfo) = .empty;
        for (cdp.getArr(r.result, "targetInfos") orelse &.{}) |t| {
            const ty = cdp.getStr(t, "type") orelse continue;
            if (!std.mem.eql(u8, ty, "page")) continue;
            try out.append(arena, .{
                .target_id = cdp.getStr(t, "targetId") orelse continue,
                .title = cdp.getStr(t, "title") orelse "",
                .url = cdp.getStr(t, "url") orelse "",
            });
        }
        // Chrome's target order changes with activity; keep first-seen order so
        // tab indexes stay stable between calls.
        for (out.items) |pg| {
            var known = false;
            for (self.tab_order.items) |t| {
                if (std.mem.eql(u8, t, pg.target_id)) known = true;
            }
            if (!known) try self.tab_order.append(self.gpa, try self.gpa.dupe(u8, pg.target_id));
        }
        var k: usize = 0;
        while (k < self.tab_order.items.len) {
            var present = false;
            for (out.items) |pg| {
                if (std.mem.eql(u8, pg.target_id, self.tab_order.items[k])) present = true;
            }
            if (present) {
                k += 1;
            } else {
                self.gpa.free(self.tab_order.orderedRemove(k));
            }
        }
        var ordered: std.ArrayList(PageInfo) = .empty;
        for (self.tab_order.items) |t| {
            for (out.items) |pg| {
                if (std.mem.eql(u8, pg.target_id, t)) try ordered.append(arena, pg);
            }
        }
        return ordered.items;
    }

    pub fn pageTitle(self: *Browser, arena: Allocator) []const u8 {
        const s = self.active orelse return "";
        const p = cdp.obj(arena, .{ .targetId = s.target_id }) catch return "";
        const r = self.browserCmd(arena, "Target.getTargetInfo", p) catch return "";
        const ti = cdp.getObj(r.result, "targetInfo") orelse return "";
        return cdp.getStr(ti, "title") orelse "";
    }

    // ------------------------------------------------------------ refs

    /// "e12" (also "12" or "[ref=e12]") -> DOM backend node id.
    pub fn resolveRef(self: *Browser, arena: Allocator, ref_in: []const u8) Err!i64 {
        var r = std.mem.trim(u8, ref_in, " []");
        if (std.mem.startsWith(u8, r, "ref=")) r = r[4..];
        if (r.len > 0 and (r[0] == 'e' or r[0] == 'E')) r = r[1..];
        const n = std.fmt.parseInt(usize, r, 10) catch return self.failf(arena, "invalid ref \"{s}\" (expected e<number> from browser_snapshot)", .{ref_in});
        const s = self.active orelse return self.failf(arena, "no active tab", .{});
        if (self.refs.len == 0) return self.failf(arena, "no snapshot yet: call browser_snapshot first to get refs", .{});
        if (!std.mem.eql(u8, self.ref_session, s.id) or self.ref_epoch != s.nav_epoch) {
            return self.failf(arena, "ref {s} is stale (the tab or page changed since the last snapshot): call browser_snapshot again", .{ref_in});
        }
        if (n == 0 or n > self.refs.len) return self.failf(arena, "ref {s} does not exist in the last snapshot", .{ref_in});
        return self.refs[n - 1];
    }

    /// Turn a CDP "node gone" error into the stale-ref message.
    pub fn nodeErr(self: *Browser, arena: Allocator, ref: []const u8, method: []const u8, msg: []const u8) Err {
        if (std.mem.indexOf(u8, msg, "find node") != null or std.mem.indexOf(u8, msg, "No node") != null or
            std.mem.indexOf(u8, msg, "not found") != null or std.mem.indexOf(u8, msg, "detached") != null or
            std.mem.indexOf(u8, msg, "does not belong") != null)
        {
            return self.failf(arena, "ref {s} is stale (element no longer in the page): call browser_snapshot again", .{ref});
        }
        return self.failf(arena, "{s} failed for {s}: {s}", .{ method, ref, msg });
    }
};

pub var g: Browser = .{ .gpa = undefined, .io = undefined };

const testing = std.testing;

test "resolveRef: formats, staleness and bounds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var b: Browser = .{ .gpa = testing.allocator, .io = testing.io };
    var s: cdp.Session = .{ .id = @constCast("S1"), .target_id = @constCast("T1"), .url = @constCast(""), .main_frame = @constCast("") };
    b.active = &s;
    try testing.expectError(error.Fail, b.resolveRef(arena, "e1"));
    try testing.expect(std.mem.indexOf(u8, b.last_err, "browser_snapshot") != null);
    try b.setRefs(&.{ 10, 20, 30 }, &s);
    defer b.clearRefs();
    try testing.expectEqual(@as(i64, 20), try b.resolveRef(arena, "e2"));
    try testing.expectEqual(@as(i64, 30), try b.resolveRef(arena, "[ref=e3]"));
    try testing.expectEqual(@as(i64, 10), try b.resolveRef(arena, "1"));
    try testing.expectError(error.Fail, b.resolveRef(arena, "e9"));
    try testing.expectError(error.Fail, b.resolveRef(arena, "abc"));
    s.nav_epoch += 1; // page navigated
    try testing.expectError(error.Fail, b.resolveRef(arena, "e1"));
    try testing.expect(std.mem.indexOf(u8, b.last_err, "stale") != null);
}
