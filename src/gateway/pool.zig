//! Child-process pool: lazy spawn, reuse, idle reaping, an LRU cap on live
//! children and bounded respawn. Pure logic over three seams (`Spawner`,
//! `Conn`, `Clock`) so it is unit-tested with a fake clock and fake children;
//! `proc.zig` provides the real ones.
//!
//! Not thread-safe by itself: the gateway serializes access (one mutex around
//! every pool call), which also serializes tool calls across children.

const std = @import("std");
const Io = std.Io;

pub const ExchangeError = error{
    /// The child did not answer within the timeout (it is killed).
    Timeout,
    /// The child closed its stdout / exited before answering.
    ChildExited,
    /// The request could not be written (the child never saw it).
    WriteFailed,
    /// The child sent a line larger than the gateway accepts.
    ResponseTooLarge,
    ChildFailed,
    OutOfMemory,
};

pub const SpawnError = error{
    /// No `zmcp-<name>` binary found.
    NotFound,
    SpawnFailed,
    OutOfMemory,
};

pub const RequestError = ExchangeError || SpawnError || error{HandshakeFailed};

pub const Conn = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Send `line` (one JSON-RPC request with numeric `id`), return the
        /// raw response line carrying that id. Other lines are skipped.
        exchange: *const fn (ctx: *anyopaque, io: Io, gpa: std.mem.Allocator, line: []const u8, id: u64, timeout_ms: u64) ExchangeError![]u8,
        /// Send a notification (no response expected).
        notify: *const fn (ctx: *anyopaque, io: Io, line: []const u8) ExchangeError!void,
        /// Kill the child and free `ctx`.
        close: *const fn (ctx: *anyopaque, io: Io) void,
    };

    pub fn exchange(self: Conn, io: Io, gpa: std.mem.Allocator, line: []const u8, id: u64, timeout_ms: u64) ExchangeError![]u8 {
        return self.vtable.exchange(self.ctx, io, gpa, line, id, timeout_ms);
    }
    pub fn notify(self: Conn, io: Io, line: []const u8) ExchangeError!void {
        return self.vtable.notify(self.ctx, io, line);
    }
    pub fn close(self: Conn, io: Io) void {
        self.vtable.close(self.ctx, io);
    }
};

pub const Spawner = struct {
    ctx: *anyopaque,
    spawnFn: *const fn (ctx: *anyopaque, io: Io, server: []const u8) SpawnError!Conn,

    pub fn spawn(self: Spawner, io: Io, server: []const u8) SpawnError!Conn {
        return self.spawnFn(self.ctx, io, server);
    }
};

/// Monotonic milliseconds.
pub const Clock = struct {
    ctx: ?*anyopaque = null,
    nowFn: *const fn (ctx: ?*anyopaque, io: Io) i64 = realNow,

    pub fn now(self: Clock, io: Io) i64 {
        return self.nowFn(self.ctx, io);
    }
};

fn realNow(_: ?*anyopaque, io: Io) i64 {
    return Io.Timestamp.now(io, .awake).toMilliseconds();
}

pub const Options = struct {
    idle_ms: u64 = 300_000,
    max_live: usize = 8,
    call_timeout_ms: u64 = 120_000,
    /// Spawn+handshake attempts per request before giving up.
    max_spawn_attempts: u8 = 2,
    /// Handshake budget (initialize round trip).
    handshake_timeout_ms: u64 = 30_000,
};

pub const Slot = struct {
    name: []u8,
    conn: ?Conn = null,
    last_used_ms: i64 = 0,
    spawns: u32 = 0,
    crashes: u32 = 0,
};

pub const Pool = struct {
    gpa: std.mem.Allocator,
    spawner: Spawner,
    clock: Clock,
    opts: Options,
    slots: std.ArrayList(Slot) = .empty,
    next_id: u64 = 1,

    pub fn init(gpa: std.mem.Allocator, spawner: Spawner, clock: Clock, opts: Options) Pool {
        return .{ .gpa = gpa, .spawner = spawner, .clock = clock, .opts = opts };
    }

    pub fn deinit(self: *Pool, io: Io) void {
        self.shutdown(io);
        for (self.slots.items) |s| self.gpa.free(s.name);
        self.slots.deinit(self.gpa);
    }

    fn slotFor(self: *Pool, name: []const u8) !*Slot {
        for (self.slots.items) |*s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        const owned = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned);
        try self.slots.append(self.gpa, .{ .name = owned });
        return &self.slots.items[self.slots.items.len - 1];
    }

    fn find(self: *const Pool, name: []const u8) ?*const Slot {
        for (self.slots.items) |*s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    pub fn liveCount(self: *const Pool) usize {
        var n: usize = 0;
        for (self.slots.items) |s| {
            if (s.conn != null) n += 1;
        }
        return n;
    }

    pub fn isLive(self: *const Pool, name: []const u8) bool {
        const s = self.find(name) orelse return false;
        return s.conn != null;
    }

    pub fn spawnCount(self: *const Pool, name: []const u8) u32 {
        const s = self.find(name) orelse return 0;
        return s.spawns;
    }

    pub fn crashCount(self: *const Pool, name: []const u8) u32 {
        const s = self.find(name) orelse return 0;
        return s.crashes;
    }

    fn kill(self: *Pool, io: Io, slot: *Slot) void {
        _ = self;
        if (slot.conn) |c| c.close(io);
        slot.conn = null;
    }

    /// Close children idle for at least `idle_ms`. Returns how many.
    pub fn reapIdle(self: *Pool, io: Io) usize {
        if (self.opts.idle_ms == 0) return 0;
        const now = self.clock.now(io);
        var n: usize = 0;
        for (self.slots.items) |*s| {
            if (s.conn == null) continue;
            const idle = now - s.last_used_ms;
            if (idle >= 0 and @as(u64, @intCast(idle)) >= self.opts.idle_ms) {
                self.kill(io, s);
                n += 1;
            }
        }
        return n;
    }

    pub fn shutdown(self: *Pool, io: Io) void {
        for (self.slots.items) |*s| self.kill(io, s);
    }

    /// Make room for one more live child by closing the least recently used
    /// idle one other than `keep`.
    fn evictFor(self: *Pool, io: Io, keep: *const Slot) void {
        while (self.liveCount() >= @max(self.opts.max_live, 1)) {
            var victim: ?*Slot = null;
            for (self.slots.items) |*s| {
                if (s == keep or s.conn == null) continue;
                if (victim == null or s.last_used_ms < victim.?.last_used_ms) victim = s;
            }
            const v = victim orelse return;
            self.kill(io, v);
        }
    }

    fn handshake(self: *Pool, io: Io, conn: Conn) RequestError!void {
        const id = self.next_id;
        self.next_id += 1;
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"initialize\",\"params\":{{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{{}},\"clientInfo\":{{\"name\":\"zmcp-gateway\",\"version\":\"0.1.0\"}}}}}}", .{id}) catch unreachable;
        const resp = conn.exchange(io, self.gpa, line, id, self.opts.handshake_timeout_ms) catch return error.HandshakeFailed;
        defer self.gpa.free(resp);
        if (std.mem.indexOf(u8, resp, "\"result\"") == null) return error.HandshakeFailed;
        conn.notify(io, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}") catch return error.HandshakeFailed;
    }

    /// Spawn + handshake, retrying up to max_spawn_attempts.
    fn connect(self: *Pool, io: Io, slot: *Slot) RequestError!Conn {
        var attempt: u8 = 0;
        var last: RequestError = error.SpawnFailed;
        while (attempt < @max(self.opts.max_spawn_attempts, 1)) : (attempt += 1) {
            const conn = self.spawner.spawn(io, slot.name) catch |e| {
                last = e;
                // A missing binary will not appear by retrying.
                if (e == error.NotFound) return e;
                continue;
            };
            self.handshake(io, conn) catch |e| {
                conn.close(io);
                last = e;
                continue;
            };
            slot.spawns += 1;
            return conn;
        }
        return last;
    }

    /// Send `method` with `params_json` (a JSON value text) to `server`'s
    /// child, spawning it first if needed. Returns the raw response line
    /// (owned by `alloc`). On a crash/timeout the child is marked dead and
    /// the error is returned; the next call respawns it. A request that
    /// could not even be written is retried once on a fresh child.
    pub fn request(self: *Pool, io: Io, alloc: std.mem.Allocator, server: []const u8, method: []const u8, params_json: []const u8) RequestError![]u8 {
        _ = self.reapIdle(io);
        const slot = try self.slotFor(server);
        var write_retry: u8 = 1;
        while (true) {
            if (slot.conn == null) {
                self.evictFor(io, slot);
                slot.conn = try self.connect(io, slot);
                slot.last_used_ms = self.clock.now(io);
            }
            const conn = slot.conn.?;
            const id = self.next_id;
            self.next_id += 1;
            var aw: Io.Writer.Allocating = .init(self.gpa);
            defer aw.deinit();
            aw.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":", .{ id, method }) catch return error.OutOfMemory;
            aw.writer.writeAll(params_json) catch return error.OutOfMemory;
            aw.writer.writeAll("}") catch return error.OutOfMemory;

            const resp = conn.exchange(io, alloc, aw.written(), id, self.opts.call_timeout_ms) catch |e| {
                self.kill(io, slot);
                slot.crashes += 1;
                if (e == error.WriteFailed and write_retry > 0) {
                    write_retry -= 1;
                    continue;
                }
                return e;
            };
            slot.last_used_ms = self.clock.now(io);
            return resp;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests: fake clock + fake children
// ---------------------------------------------------------------------------

pub const FakeWorld = struct {
    gpa: std.mem.Allocator,
    now_ms: i64 = 1_000,
    spawns: u32 = 0,
    live: i32 = 0,
    closed: u32 = 0,
    /// Fail this many upcoming spawns.
    spawn_fail: u32 = 0,
    spawn_not_found: bool = false,
    /// Errors returned by the next tools/call exchanges, in order.
    call_errors: [4]?ExchangeError = .{ null, null, null, null },
    call_error_idx: usize = 0,
    /// Fail the next handshake.
    handshake_fail: bool = false,
    calls: u32 = 0,
    notifies: u32 = 0,
    last_serial: u32 = 0,
    /// Names of servers in spawn order.
    spawn_log: [16][]const u8 = undefined,
    /// Raw `result` value returned for tools/call when set.
    result_json: ?[]const u8 = null,
    /// Copy of the last tools/call request line (owned; free with `reset`).
    last_request: ?[]u8 = null,
    /// Keep a copy of tools/call request lines in `last_request`.
    record: bool = false,

    pub fn reset(self: *FakeWorld) void {
        if (self.last_request) |l| self.gpa.free(l);
        self.last_request = null;
    }

    pub fn clock(self: *FakeWorld) Clock {
        return .{ .ctx = self, .nowFn = struct {
            fn f(c: ?*anyopaque, _: Io) i64 {
                const w: *FakeWorld = @ptrCast(@alignCast(c.?));
                return w.now_ms;
            }
        }.f };
    }

    pub fn spawner(self: *FakeWorld) Spawner {
        return .{ .ctx = self, .spawnFn = fakeSpawn };
    }
};

const FakeConn = struct {
    world: *FakeWorld,
    serial: u32,
};

const fake_vtable: Conn.VTable = .{ .exchange = fakeExchange, .notify = fakeNotify, .close = fakeClose };

fn fakeSpawn(ctx: *anyopaque, _: Io, server: []const u8) SpawnError!Conn {
    const w: *FakeWorld = @ptrCast(@alignCast(ctx));
    if (w.spawn_not_found) return error.NotFound;
    if (w.spawn_fail > 0) {
        w.spawn_fail -= 1;
        return error.SpawnFailed;
    }
    const c = w.gpa.create(FakeConn) catch return error.OutOfMemory;
    if (w.spawns < w.spawn_log.len) w.spawn_log[w.spawns] = server;
    w.spawns += 1;
    w.live += 1;
    w.last_serial += 1;
    c.* = .{ .world = w, .serial = w.last_serial };
    return .{ .ctx = c, .vtable = &fake_vtable };
}

fn fakeExchange(ctx: *anyopaque, _: Io, gpa: std.mem.Allocator, line: []const u8, id: u64, _: u64) ExchangeError![]u8 {
    const c: *FakeConn = @ptrCast(@alignCast(ctx));
    const w = c.world;
    if (std.mem.indexOf(u8, line, "\"method\":\"initialize\"") != null) {
        if (w.handshake_fail) {
            w.handshake_fail = false;
            return error.ChildExited;
        }
        return std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"protocolVersion\":\"2024-11-05\"}}}}", .{id}) catch error.OutOfMemory;
    }
    w.calls += 1;
    if (w.call_error_idx < w.call_errors.len) {
        const e = w.call_errors[w.call_error_idx];
        w.call_error_idx += 1;
        if (e) |err| return err;
    }
    if (w.record) {
        if (w.last_request) |l| w.gpa.free(l);
        w.last_request = w.gpa.dupe(u8, line) catch return error.OutOfMemory;
    }
    if (w.result_json) |rj| {
        return std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}", .{ id, rj }) catch error.OutOfMemory;
    }
    return std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"child#{d}\"}}]}}}}", .{ id, c.serial }) catch error.OutOfMemory;
}

fn fakeNotify(ctx: *anyopaque, _: Io, _: []const u8) ExchangeError!void {
    const c: *FakeConn = @ptrCast(@alignCast(ctx));
    c.world.notifies += 1;
}

fn fakeClose(ctx: *anyopaque, _: Io) void {
    const c: *FakeConn = @ptrCast(@alignCast(ctx));
    c.world.live -= 1;
    c.world.closed += 1;
    c.world.gpa.destroy(c);
}

fn testPool(w: *FakeWorld, opts: Options) Pool {
    return Pool.init(std.testing.allocator, w.spawner(), w.clock(), opts);
}

fn callOk(p: *Pool, server: []const u8) ![]u8 {
    return p.request(std.testing.io, std.testing.allocator, server, "tools/call", "{\"name\":\"x\"}");
}

fn expectChild(resp: []u8, serial: u32) !void {
    defer std.testing.allocator.free(resp);
    var buf: [16]u8 = undefined;
    const want = try std.fmt.bufPrint(&buf, "child#{d}", .{serial});
    try std.testing.expect(std.mem.indexOf(u8, resp, want) != null);
}

test "lazy spawn: nothing starts until the first request; then it is reused" {
    var w: FakeWorld = .{ .gpa = std.testing.allocator };
    var p = testPool(&w, .{});
    defer p.deinit(std.testing.io);
    try std.testing.expectEqual(@as(u32, 0), w.spawns);
    try std.testing.expectEqual(@as(usize, 0), p.liveCount());

    try expectChild(try callOk(&p, "git"), 1);
    try std.testing.expectEqual(@as(u32, 1), w.spawns);
    try std.testing.expectEqual(@as(u32, 1), w.notifies); // initialized notification sent
    try expectChild(try callOk(&p, "git"), 1); // same child
    try std.testing.expectEqual(@as(u32, 1), w.spawns);
    try std.testing.expect(p.isLive("git"));
    try std.testing.expect(!p.isLive("docker"));
    try std.testing.expectEqual(@as(u32, 1), p.spawnCount("git"));
}

test "idle reaping with a fake clock, then respawn on next use" {
    var w: FakeWorld = .{ .gpa = std.testing.allocator };
    var p = testPool(&w, .{ .idle_ms = 5_000 });
    defer p.deinit(std.testing.io);
    try expectChild(try callOk(&p, "git"), 1);
    w.now_ms += 4_999;
    try std.testing.expectEqual(@as(usize, 0), p.reapIdle(std.testing.io));
    try std.testing.expect(p.isLive("git"));
    w.now_ms += 1;
    try std.testing.expectEqual(@as(usize, 1), p.reapIdle(std.testing.io));
    try std.testing.expect(!p.isLive("git"));
    try std.testing.expectEqual(@as(i32, 0), w.live);
    // Next call respawns (new serial).
    try expectChild(try callOk(&p, "git"), 2);
    try std.testing.expectEqual(@as(u32, 2), p.spawnCount("git"));
}

test "a request reaps other idle children before running (no timer needed)" {
    var w: FakeWorld = .{ .gpa = std.testing.allocator };
    var p = testPool(&w, .{ .idle_ms = 1_000 });
    defer p.deinit(std.testing.io);
    try expectChild(try callOk(&p, "git"), 1);
    w.now_ms += 2_000;
    try expectChild(try callOk(&p, "docker"), 2);
    try std.testing.expect(!p.isLive("git"));
    try std.testing.expect(p.isLive("docker"));
    // idle_ms = 0 disables reaping.
    var p0 = testPool(&w, .{ .idle_ms = 0 });
    defer p0.deinit(std.testing.io);
    try expectChild(try callOk(&p0, "git"), 3);
    w.now_ms += 10_000_000;
    try std.testing.expectEqual(@as(usize, 0), p0.reapIdle(std.testing.io));
}

test "use refreshes idle time" {
    var w: FakeWorld = .{ .gpa = std.testing.allocator };
    var p = testPool(&w, .{ .idle_ms = 5_000 });
    defer p.deinit(std.testing.io);
    try expectChild(try callOk(&p, "git"), 1);
    w.now_ms += 4_000;
    try expectChild(try callOk(&p, "git"), 1);
    w.now_ms += 4_000; // 8s since spawn, 4s since last use
    try std.testing.expectEqual(@as(usize, 0), p.reapIdle(std.testing.io));
}

test "LRU cap: the least recently used idle child is reaped to make room" {
    var w: FakeWorld = .{ .gpa = std.testing.allocator };
    var p = testPool(&w, .{ .max_live = 2, .idle_ms = 0 });
    defer p.deinit(std.testing.io);
    try expectChild(try callOk(&p, "a"), 1);
    w.now_ms += 10;
    try expectChild(try callOk(&p, "b"), 2);
    w.now_ms += 10;
    try expectChild(try callOk(&p, "a"), 1); // a is now more recent than b
    w.now_ms += 10;
    try expectChild(try callOk(&p, "c"), 3); // evicts b (LRU)
    try std.testing.expect(p.isLive("a"));
    try std.testing.expect(!p.isLive("b"));
    try std.testing.expect(p.isLive("c"));
    try std.testing.expectEqual(@as(usize, 2), p.liveCount());
    try std.testing.expectEqual(@as(i32, 2), w.live);
    w.now_ms += 10;
    try expectChild(try callOk(&p, "b"), 4); // evicts a (older than c)
    try std.testing.expect(!p.isLive("a"));
    try std.testing.expect(p.isLive("c") and p.isLive("b"));
}

test "crash mid-call: error returned, child marked dead, next call respawns" {
    var w: FakeWorld = .{ .gpa = std.testing.allocator };
    w.call_errors[0] = error.ChildExited;
    var p = testPool(&w, .{});
    defer p.deinit(std.testing.io);
    try std.testing.expectError(error.ChildExited, callOk(&p, "git"));
    try std.testing.expect(!p.isLive("git"));
    try std.testing.expectEqual(@as(i32, 0), w.live);
    try std.testing.expectEqual(@as(u32, 1), p.crashCount("git"));
    try expectChild(try callOk(&p, "git"), 2);
    try std.testing.expectEqual(@as(u32, 2), w.spawns);
}

test "timeout kills the child and reports Timeout (never retried)" {
    var w: FakeWorld = .{ .gpa = std.testing.allocator };
    w.call_errors[0] = error.Timeout;
    var p = testPool(&w, .{});
    defer p.deinit(std.testing.io);
    try std.testing.expectError(error.Timeout, callOk(&p, "git"));
    try std.testing.expectEqual(@as(u32, 1), w.calls); // not re-sent
    try std.testing.expect(!p.isLive("git"));
}

test "a write failure (idle crash) is retried once on a fresh child" {
    var w: FakeWorld = .{ .gpa = std.testing.allocator };
    w.call_errors[0] = error.WriteFailed;
    var p = testPool(&w, .{});
    defer p.deinit(std.testing.io);
    try expectChild(try callOk(&p, "git"), 2);
    try std.testing.expectEqual(@as(u32, 2), w.spawns);
    // Two write failures in a row: give up (bounded).
    var w2: FakeWorld = .{ .gpa = std.testing.allocator };
    w2.call_errors[0] = error.WriteFailed;
    w2.call_errors[1] = error.WriteFailed;
    var p2 = testPool(&w2, .{});
    defer p2.deinit(std.testing.io);
    try std.testing.expectError(error.WriteFailed, callOk(&p2, "git"));
    try std.testing.expectEqual(@as(u32, 2), w2.spawns);
}

test "spawn failures are bounded; a missing binary is not retried" {
    var w: FakeWorld = .{ .gpa = std.testing.allocator };
    w.spawn_fail = 5;
    var p = testPool(&w, .{ .max_spawn_attempts = 2 });
    defer p.deinit(std.testing.io);
    try std.testing.expectError(error.SpawnFailed, callOk(&p, "git"));
    try std.testing.expectEqual(@as(u32, 3), w.spawn_fail); // exactly 2 attempts
    // One failure then success within the attempt budget.
    w.spawn_fail = 1;
    try expectChild(try callOk(&p, "git"), 1);

    var nf: FakeWorld = .{ .gpa = std.testing.allocator };
    nf.spawn_not_found = true;
    var pn = testPool(&nf, .{ .max_spawn_attempts = 3 });
    defer pn.deinit(std.testing.io);
    try std.testing.expectError(error.NotFound, callOk(&pn, "git"));
}

test "handshake failure closes the child and retries" {
    var w: FakeWorld = .{ .gpa = std.testing.allocator };
    w.handshake_fail = true;
    var p = testPool(&w, .{});
    defer p.deinit(std.testing.io);
    try expectChild(try callOk(&p, "git"), 2);
    try std.testing.expectEqual(@as(u32, 1), w.closed); // the first child was closed
    try std.testing.expectEqual(@as(i32, 1), w.live);
}

test "shutdown and deinit close every live child" {
    var w: FakeWorld = .{ .gpa = std.testing.allocator };
    var p = testPool(&w, .{});
    try expectChild(try callOk(&p, "a"), 1);
    try expectChild(try callOk(&p, "b"), 2);
    try std.testing.expectEqual(@as(i32, 2), w.live);
    p.shutdown(std.testing.io);
    try std.testing.expectEqual(@as(i32, 0), w.live);
    try std.testing.expectEqual(@as(usize, 0), p.liveCount());
    p.deinit(std.testing.io);
}
