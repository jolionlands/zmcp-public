//! JSON-RPC 2.0 client over an abstract byte transport, for LSP servers.
//! A reader thread frames incoming bytes, answers server->client requests
//! (so servers never stall), stores publishDiagnostics, and hands responses
//! to whichever thread is waiting on that id.

const std = @import("std");
const proto = @import("proto.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Transport = struct {
    ctx: *anyopaque,
    /// Blocks until at least one byte is available; returns 0 at EOF.
    readFn: *const fn (ctx: *anyopaque, buf: []u8) anyerror!usize,
    writeFn: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,
};

pub const RequestError = error{ Timeout, ServerClosed, WriteFailed, ServerError, BadResponse, OutOfMemory };

const Response = struct { id: i64, body: []u8 };
const Diag = struct { seq: u64, body: []u8 };

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    tr: Transport,
    /// Sent for workspace/workspaceFolders. Borrowed; must outlive the client.
    root_uri: []const u8 = "",
    root_name: []const u8 = "",

    mu: Io.Mutex = .init,
    wmu: Io.Mutex = .init,
    next_id: i64 = 1,
    pending: std.ArrayList(i64) = .empty,
    responses: std.ArrayList(Response) = .empty,
    diags: std.StringHashMapUnmanaged(Diag) = .empty,
    diag_seq: u64 = 0,
    closed: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    err_buf: [256]u8 = undefined,
    err_len: usize = 0,

    pub fn init(gpa: Allocator, io: Io, tr: Transport) Client {
        return .{ .gpa = gpa, .io = io, .tr = tr };
    }

    pub fn start(self: *Client) !void {
        self.thread = try std.Thread.spawn(.{}, readerMain, .{self});
    }

    /// Join the reader thread. The transport must already be closed/EOF.
    pub fn join(self: *Client) void {
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    pub fn deinit(self: *Client) void {
        self.pending.deinit(self.gpa);
        for (self.responses.items) |r| self.gpa.free(r.body);
        self.responses.deinit(self.gpa);
        var it = self.diags.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.body);
        }
        self.diags.deinit(self.gpa);
    }

    pub fn isClosed(self: *const Client) bool {
        return self.closed.load(.acquire);
    }

    pub fn lastError(self: *const Client) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    fn lock(self: *Client) void {
        self.mu.lockUncancelable(self.io);
    }
    fn unlock(self: *Client) void {
        self.mu.unlock(self.io);
    }

    // ------------------------------------------------------------ sending

    fn sendBody(self: *Client, body: []const u8) !void {
        const framed = try proto.frame(self.gpa, body);
        defer self.gpa.free(framed);
        self.wmu.lockUncancelable(self.io);
        defer self.wmu.unlock(self.io);
        try self.tr.writeFn(self.tr.ctx, framed);
    }

    pub fn notify(self: *Client, method: []const u8, params_json: []const u8) !void {
        const m = try std.json.Stringify.valueAlloc(self.gpa, method, .{});
        defer self.gpa.free(m);
        const body = try std.fmt.allocPrint(self.gpa, "{{\"jsonrpc\":\"2.0\",\"method\":{s},\"params\":{s}}}", .{ m, params_json });
        defer self.gpa.free(body);
        try self.sendBody(body);
    }

    /// Send a request and wait up to `timeout_ms`. Returns the `result` value,
    /// allocated (leaky) from `alloc`; use an arena.
    pub fn request(self: *Client, alloc: Allocator, method: []const u8, params_json: []const u8, timeout_ms: u32) RequestError!std.json.Value {
        if (self.isClosed()) return error.ServerClosed;
        self.lock();
        const id = self.next_id;
        self.next_id += 1;
        self.pending.append(self.gpa, id) catch {
            self.unlock();
            return error.OutOfMemory;
        };
        self.unlock();

        const m = std.json.Stringify.valueAlloc(self.gpa, method, .{}) catch return error.OutOfMemory;
        defer self.gpa.free(m);
        const body = std.fmt.allocPrint(self.gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":{s},\"params\":{s}}}", .{ id, m, params_json }) catch return error.OutOfMemory;
        defer self.gpa.free(body);
        self.sendBody(body) catch {
            self.dropPending(id);
            return error.WriteFailed;
        };

        const t0 = Io.Clock.awake.now(self.io).toMilliseconds();
        var step: i64 = 1;
        while (true) {
            if (self.takeResponse(id)) |raw| {
                defer self.gpa.free(raw);
                return self.decode(alloc, raw);
            }
            if (self.isClosed()) {
                // The response may have landed just before EOF.
                if (self.takeResponse(id)) |raw| {
                    defer self.gpa.free(raw);
                    return self.decode(alloc, raw);
                }
                self.dropPending(id);
                return error.ServerClosed;
            }
            const now = Io.Clock.awake.now(self.io).toMilliseconds();
            if (now - t0 >= timeout_ms) {
                self.dropPending(id);
                var buf: [64]u8 = undefined;
                const p = std.fmt.bufPrint(&buf, "{{\"id\":{d}}}", .{id}) catch "{}";
                self.notify("$/cancelRequest", p) catch {};
                return error.Timeout;
            }
            self.io.sleep(Io.Duration.fromMilliseconds(step), .awake) catch {};
            if (step < 10) step += 1;
        }
    }

    fn dropPending(self: *Client, id: i64) void {
        self.lock();
        defer self.unlock();
        for (self.pending.items, 0..) |p, i| {
            if (p == id) {
                _ = self.pending.swapRemove(i);
                break;
            }
        }
        // A response that raced in after the drop.
        for (self.responses.items, 0..) |r, i| {
            if (r.id == id) {
                self.gpa.free(r.body);
                _ = self.responses.swapRemove(i);
                break;
            }
        }
    }

    fn takeResponse(self: *Client, id: i64) ?[]u8 {
        self.lock();
        defer self.unlock();
        for (self.responses.items, 0..) |r, i| {
            if (r.id == id) {
                const body = r.body;
                _ = self.responses.swapRemove(i);
                for (self.pending.items, 0..) |p, j| {
                    if (p == id) {
                        _ = self.pending.swapRemove(j);
                        break;
                    }
                }
                return body;
            }
        }
        return null;
    }

    fn decode(self: *Client, alloc: Allocator, raw: []const u8) RequestError!std.json.Value {
        const v = std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{}) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.BadResponse,
        };
        if (v != .object) return error.BadResponse;
        if (v.object.get("error")) |e| {
            var msg: []const u8 = "server error";
            if (e == .object) {
                if (e.object.get("message")) |mv| if (mv == .string) {
                    msg = mv.string;
                };
            }
            const n = @min(msg.len, self.err_buf.len);
            @memcpy(self.err_buf[0..n], msg[0..n]);
            self.err_len = n;
            return error.ServerError;
        }
        return v.object.get("result") orelse .null;
    }

    // ------------------------------------------------------------ diagnostics

    /// Sequence number of the latest publishDiagnostics for `path` (0 if none).
    pub fn diagSeq(self: *Client, path: []const u8) u64 {
        self.lock();
        defer self.unlock();
        return if (self.diags.get(path)) |d| d.seq else 0;
    }

    /// Copy of the raw publishDiagnostics params for `path` newer than `after`.
    pub fn diagBody(self: *Client, alloc: Allocator, path: []const u8, after: u64) ?[]u8 {
        self.lock();
        defer self.unlock();
        const d = self.diags.get(path) orelse return null;
        if (d.seq <= after) return null;
        return alloc.dupe(u8, d.body) catch null;
    }

    pub fn waitDiag(self: *Client, alloc: Allocator, path: []const u8, after: u64, timeout_ms: u32) ?[]u8 {
        const t0 = Io.Clock.awake.now(self.io).toMilliseconds();
        while (true) {
            if (self.diagBody(alloc, path, after)) |b| return b;
            if (self.isClosed()) return null;
            if (Io.Clock.awake.now(self.io).toMilliseconds() - t0 >= timeout_ms) return null;
            self.io.sleep(Io.Duration.fromMilliseconds(5), .awake) catch {};
        }
    }

    // ------------------------------------------------------------ reader thread

    fn readerMain(self: *Client) void {
        var framer = proto.Framer.init(self.gpa);
        defer framer.deinit();
        var buf: [16 * 1024]u8 = undefined;
        outer: while (true) {
            const n = self.tr.readFn(self.tr.ctx, &buf) catch break;
            if (n == 0) break;
            framer.feed(buf[0..n]) catch break;
            while (true) {
                const body = framer.next() catch break :outer;
                if (body) |b| self.handleMessage(b) else break;
            }
        }
        self.closed.store(true, .release);
    }

    fn handleMessage(self: *Client, body: []const u8) void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, body, .{}) catch return;
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return;
        const method = root.object.get("method");
        const id = root.object.get("id");
        if (method) |mv| {
            if (mv != .string) return;
            if (id) |idv| {
                self.answerServerRequest(mv.string, idv, root.object.get("params") orelse .null);
            } else if (std.mem.eql(u8, mv.string, "textDocument/publishDiagnostics")) {
                self.storeDiagnostics(body, root.object.get("params") orelse .null);
            }
            return;
        }
        const idv = id orelse return;
        const num: i64 = switch (idv) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            .string => |s| std.fmt.parseInt(i64, s, 10) catch return,
            else => return,
        };
        self.lock();
        defer self.unlock();
        var wanted = false;
        for (self.pending.items) |p| {
            if (p == num) wanted = true;
        }
        if (!wanted) return; // abandoned (timed out) or unknown
        const copy = self.gpa.dupe(u8, body) catch return;
        self.responses.append(self.gpa, .{ .id = num, .body = copy }) catch self.gpa.free(copy);
    }

    fn storeDiagnostics(self: *Client, body: []const u8, params: std.json.Value) void {
        if (params != .object) return;
        const uri = params.object.get("uri") orelse return;
        if (uri != .string) return;
        const path = (proto.uriToPath(self.gpa, uri.string) catch return) orelse (self.gpa.dupe(u8, uri.string) catch return);
        // Keep only the params object text: cheap re-slice of the full message.
        const copy = self.gpa.dupe(u8, body) catch {
            self.gpa.free(path);
            return;
        };
        self.lock();
        defer self.unlock();
        self.diag_seq += 1;
        const gop = self.diags.getOrPut(self.gpa, path) catch {
            self.gpa.free(path);
            self.gpa.free(copy);
            return;
        };
        if (gop.found_existing) {
            self.gpa.free(path);
            self.gpa.free(gop.value_ptr.body);
        }
        gop.value_ptr.* = .{ .seq = self.diag_seq, .body = copy };
    }

    fn answerServerRequest(self: *Client, method: []const u8, id: std.json.Value, params: std.json.Value) void {
        const id_json = std.json.Stringify.valueAlloc(self.gpa, id, .{}) catch return;
        defer self.gpa.free(id_json);

        var result: []const u8 = "null";
        var owned: ?[]u8 = null;
        defer if (owned) |o| self.gpa.free(o);
        var not_found = false;

        if (std.mem.eql(u8, method, "workspace/configuration")) {
            // One null per requested item: "no client-side settings".
            var n: usize = 0;
            if (params == .object) if (params.object.get("items")) |it| if (it == .array) {
                n = it.array.items.len;
            };
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.gpa);
            out.append(self.gpa, '[') catch return;
            for (0..n) |i| {
                if (i > 0) out.append(self.gpa, ',') catch return;
                out.appendSlice(self.gpa, "null") catch return;
            }
            out.append(self.gpa, ']') catch return;
            owned = out.toOwnedSlice(self.gpa) catch return;
            result = owned.?;
        } else if (std.mem.eql(u8, method, "workspace/workspaceFolders")) {
            owned = std.json.Stringify.valueAlloc(self.gpa, [_]struct { uri: []const u8, name: []const u8 }{.{ .uri = self.root_uri, .name = self.root_name }}, .{}) catch return;
            result = owned.?;
        } else if (std.mem.eql(u8, method, "workspace/applyEdit")) {
            result = "{\"applied\":false,\"failureReason\":\"client is read-only\"}";
        } else if (std.mem.eql(u8, method, "window/showDocument")) {
            result = "{\"success\":false}";
        } else if (std.mem.eql(u8, method, "client/registerCapability") or
            std.mem.eql(u8, method, "client/unregisterCapability") or
            std.mem.eql(u8, method, "window/workDoneProgress/create") or
            std.mem.eql(u8, method, "window/showMessageRequest") or
            std.mem.endsWith(u8, method, "/refresh"))
        {
            result = "null";
        } else {
            not_found = true;
        }

        const body = if (not_found)
            std.fmt.allocPrint(self.gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"method not found\"}}}}", .{id_json}) catch return
        else
            std.fmt.allocPrint(self.gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_json, result }) catch return;
        defer self.gpa.free(body);
        self.sendBody(body) catch {};
    }
};

// ---------------------------------------------------------------- test transport

/// In-memory byte pipe used by tests (and usable as a fake-server channel).
pub const MemPipe = struct {
    io: Io,
    mu: Io.Mutex = .init,
    buf: std.ArrayList(u8) = .empty,
    closed: bool = false,
    alloc: Allocator,

    pub fn push(self: *MemPipe, bytes: []const u8) !void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        try self.buf.appendSlice(self.alloc, bytes);
    }

    pub fn close(self: *MemPipe) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.closed = true;
    }

    pub fn pull(self: *MemPipe, out: []u8) usize {
        while (true) {
            {
                self.mu.lockUncancelable(self.io);
                defer self.mu.unlock(self.io);
                if (self.buf.items.len > 0) {
                    const n = @min(out.len, self.buf.items.len);
                    @memcpy(out[0..n], self.buf.items[0..n]);
                    std.mem.copyForwards(u8, self.buf.items[0 .. self.buf.items.len - n], self.buf.items[n..]);
                    self.buf.shrinkRetainingCapacity(self.buf.items.len - n);
                    return n;
                }
                if (self.closed) return 0;
            }
            self.io.sleep(Io.Duration.fromMilliseconds(1), .awake) catch {};
        }
    }

    pub fn deinit(self: *MemPipe) void {
        self.buf.deinit(self.alloc);
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testIo() Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const Duplex = struct {
    /// client -> server
    c2s: MemPipe,
    /// server -> client
    s2c: MemPipe,
    /// Bytes to deliver to the client in odd-sized pieces.
    pub fn readFn(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *Duplex = @ptrCast(@alignCast(ctx));
        // Deliver at most 7 bytes per read to exercise split frames.
        const cap = @min(buf.len, 7);
        return self.s2c.pull(buf[0..cap]);
    }
    pub fn writeFn(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *Duplex = @ptrCast(@alignCast(ctx));
        try self.c2s.push(bytes);
    }
};

/// Read one framed message from `pipe`; caller owns the returned body.
fn readFramed(alloc: Allocator, pipe: *MemPipe, framer: *proto.Framer) !?[]u8 {
    var buf: [4096]u8 = undefined;
    while (true) {
        if (try framer.next()) |b| return try alloc.dupe(u8, b);
        const n = pipe.pull(&buf);
        if (n == 0) return null;
        try framer.feed(buf[0..n]);
    }
}

fn sendFramed(alloc: Allocator, pipe: *MemPipe, body: []const u8) !void {
    const f = try proto.frame(alloc, body);
    defer alloc.free(f);
    try pipe.push(f);
}

const FakeCtx = struct {
    d: *Duplex,
    saw_config_reply: bool = false,
    saw_register_reply: bool = false,
};

/// Fake server: on `ping` it first fires notifications and server requests
/// (interleaved), then a stale response for an unrelated id, then the answer.
fn fakeServer(ctx: *FakeCtx) void {
    const alloc = testing.allocator;
    var framer = proto.Framer.init(alloc);
    defer framer.deinit();
    while (true) {
        const msg = (readFramed(alloc, &ctx.d.c2s, &framer) catch return) orelse return;
        defer alloc.free(msg);
        var p = std.json.parseFromSlice(std.json.Value, alloc, msg, .{}) catch return;
        defer p.deinit();
        const o = p.value.object;
        const method = if (o.get("method")) |m| m.string else null;
        if (method == null) {
            // reply to one of our server->client requests
            const rid = o.get("id").?.integer;
            if (rid == 900) {
                const rv = o.get("result").?;
                ctx.saw_config_reply = rv == .array and rv.array.items.len == 2 and rv.array.items[0] == .null and rv.array.items[1] == .null;
            }
            if (rid == 901) ctx.saw_register_reply = o.get("result").? == .null;
            continue;
        }
        if (o.get("id")) |idv| {
            const id = idv.integer;
            if (std.mem.eql(u8, method.?, "ping")) {
                sendFramed(alloc, &ctx.d.s2c, "{\"jsonrpc\":\"2.0\",\"method\":\"window/logMessage\",\"params\":{\"type\":3,\"message\":\"hi\"}}") catch return;
                sendFramed(alloc, &ctx.d.s2c, "{\"jsonrpc\":\"2.0\",\"id\":900,\"method\":\"workspace/configuration\",\"params\":{\"items\":[{\"section\":\"a\"},{\"section\":\"b\"}]}}") catch return;
                sendFramed(alloc, &ctx.d.s2c, "{\"jsonrpc\":\"2.0\",\"id\":901,\"method\":\"client/registerCapability\",\"params\":{\"registrations\":[]}}") catch return;
                sendFramed(alloc, &ctx.d.s2c, "{\"jsonrpc\":\"2.0\",\"id\":424242,\"result\":\"stale\"}") catch return;
                sendFramed(alloc, &ctx.d.s2c, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///w/a%20b.zig\",\"diagnostics\":[]}}") catch return;
                const r = std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"pong\":true}}}}", .{id}) catch return;
                defer alloc.free(r);
                sendFramed(alloc, &ctx.d.s2c, r) catch return;
            } else if (std.mem.eql(u8, method.?, "boom")) {
                const r = std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32603,\"message\":\"kaboom\"}}}}", .{id}) catch return;
                defer alloc.free(r);
                sendFramed(alloc, &ctx.d.s2c, r) catch return;
            } else if (std.mem.eql(u8, method.?, "hang")) {
                // never answer
            }
        } else if (std.mem.eql(u8, method.?, "exit")) {
            ctx.d.s2c.close();
            return;
        }
    }
}

test "client: correlation with interleaved notifications, server requests, stale responses, errors, timeout" {
    const alloc = testing.allocator;
    const io = testIo();
    var d: Duplex = .{
        .c2s = .{ .io = io, .alloc = alloc },
        .s2c = .{ .io = io, .alloc = alloc },
    };
    defer d.c2s.deinit();
    defer d.s2c.deinit();
    var fake: FakeCtx = .{ .d = &d };
    const server_thread = try std.Thread.spawn(.{}, fakeServer, .{&fake});

    var c = Client.init(alloc, io, .{ .ctx = &d, .readFn = Duplex.readFn, .writeFn = Duplex.writeFn });
    defer c.deinit();
    try c.start();

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const r1 = try c.request(arena, "ping", "{}", 3000);
    try testing.expect(r1 == .object);
    try testing.expect(r1.object.get("pong").?.bool);

    // Diagnostics were captured under the decoded path.
    try testing.expect(c.diagSeq("/w/a b.zig") > 0);
    try testing.expect(c.diagBody(arena, "/w/a b.zig", 0) != null);
    try testing.expect(c.diagBody(arena, "/w/a b.zig", 999) == null);

    try testing.expectError(error.ServerError, c.request(arena, "boom", "{}", 3000));
    try testing.expectEqualStrings("kaboom", c.lastError());

    try testing.expectError(error.Timeout, c.request(arena, "hang", "{}", 60));

    // A second ping still works after a timeout (late responses are dropped).
    const r2 = try c.request(arena, "ping", "{}", 3000);
    try testing.expect(r2.object.get("pong").?.bool);

    try c.notify("exit", "null");
    server_thread.join();
    c.join();
    try testing.expect(c.isClosed());
    try testing.expect(fake.saw_config_reply);
    try testing.expect(fake.saw_register_reply);
    try testing.expectError(error.ServerClosed, c.request(arena, "ping", "{}", 100));
}
