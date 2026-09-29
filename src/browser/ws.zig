//! Minimal RFC 6455 WebSocket client (no TLS, meant for a loopback DevTools
//! socket). Generic over a `ByteStream` so it can be unit-tested against
//! canned byte buffers and an in-process fake server.
//!
//! Client frames are always masked; server frames must not be. Handles 7/16/64
//! bit lengths, fragmentation with continuation frames, ping -> pong, and
//! close. The handshake sends NO Origin header (Chrome only checks Origin when
//! one is present) and verifies Sec-WebSocket-Accept.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Error = error{
    /// No data within the timeout (the connection is still usable).
    Timeout,
    /// Peer closed the connection or sent a close frame.
    Closed,
    IoFailed,
    Protocol,
    TooLarge,
    HandshakeFailed,
    OutOfMemory,
};

pub const Opcode = struct {
    pub const cont: u8 = 0x0;
    pub const text: u8 = 0x1;
    pub const binary: u8 = 0x2;
    pub const close: u8 = 0x8;
    pub const ping: u8 = 0x9;
    pub const pong: u8 = 0xA;
};

pub const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Blocking byte transport. `read_fn` returns >0 bytes read, 0 for EOF, or
/// error.Timeout when nothing arrived within `timeout_ms`.
pub const ByteStream = struct {
    ctx: *anyopaque,
    read_fn: *const fn (ctx: *anyopaque, buf: []u8, timeout_ms: i64) Error!usize,
    write_fn: *const fn (ctx: *anyopaque, data: []const u8) Error!void,
};

// ---------------------------------------------------------------- framing

/// Append one frame to `out`. `mask` non-null => client frame.
pub fn encodeFrame(alloc: Allocator, out: *std.ArrayList(u8), opcode: u8, payload: []const u8, mask: ?[4]u8, fin: bool) Allocator.Error!void {
    const mbit: u8 = if (mask != null) 0x80 else 0;
    try out.append(alloc, (if (fin) @as(u8, 0x80) else 0) | (opcode & 0x0f));
    if (payload.len < 126) {
        try out.append(alloc, mbit | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= 0xffff) {
        try out.append(alloc, mbit | 126);
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, @intCast(payload.len), .big);
        try out.appendSlice(alloc, &b);
    } else {
        try out.append(alloc, mbit | 127);
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, payload.len, .big);
        try out.appendSlice(alloc, &b);
    }
    if (mask) |m| {
        try out.appendSlice(alloc, &m);
        const start = out.items.len;
        try out.appendSlice(alloc, payload);
        for (out.items[start..], 0..) |*c, i| c.* ^= m[i & 3];
    } else {
        try out.appendSlice(alloc, payload);
    }
}

pub const Header = struct {
    fin: bool,
    opcode: u8,
    len: u64,
    header_len: usize,
};

/// Parse a server->client frame header from `buf`. Returns null when more
/// bytes are needed. Rejects reserved bits, masked frames, oversized or
/// fragmented control frames.
pub fn parseHeader(buf: []const u8) error{Protocol}!?Header {
    if (buf.len < 2) return null;
    const b0 = buf[0];
    const b1 = buf[1];
    if (b0 & 0x70 != 0) return error.Protocol; // RSV bits without extensions
    if (b1 & 0x80 != 0) return error.Protocol; // server frames are unmasked
    const opcode = b0 & 0x0f;
    const fin = b0 & 0x80 != 0;
    var len: u64 = b1 & 0x7f;
    var hl: usize = 2;
    if (len == 126) {
        if (buf.len < 4) return null;
        len = std.mem.readInt(u16, buf[2..4], .big);
        hl = 4;
    } else if (len == 127) {
        if (buf.len < 10) return null;
        len = std.mem.readInt(u64, buf[2..10], .big);
        if (len >> 63 != 0) return error.Protocol;
        hl = 10;
    }
    switch (opcode) {
        Opcode.cont, Opcode.text, Opcode.binary => {},
        Opcode.close, Opcode.ping, Opcode.pong => {
            if (!fin or len > 125) return error.Protocol;
        },
        else => return error.Protocol,
    }
    return .{ .fin = fin, .opcode = opcode, .len = len, .header_len = hl };
}

/// Sec-WebSocket-Accept for a given Sec-WebSocket-Key (28 base64 chars).
pub fn acceptKey(key_b64: []const u8) [28]u8 {
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(key_b64);
    h.update(GUID);
    var digest: [20]u8 = undefined;
    h.final(&digest);
    var out: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &digest);
    return out;
}

pub const Message = struct {
    /// Opcode.text or Opcode.binary.
    opcode: u8,
    /// Valid until the next call to `recv`.
    data: []const u8,
};

pub const DEFAULT_MAX_MESSAGE: usize = 64 * 1024 * 1024;

pub const Conn = struct {
    alloc: Allocator,
    stream: ByteStream,
    /// Raw received bytes; `rpos` is the consumed prefix.
    rbuf: std.ArrayList(u8) = .empty,
    rpos: usize = 0,
    /// Partially assembled fragmented message.
    frag: std.ArrayList(u8) = .empty,
    frag_op: ?u8 = null,
    /// Storage for the message returned by `recv`.
    msg: std.ArrayList(u8) = .empty,
    wbuf: std.ArrayList(u8) = .empty,
    prng: std.Random.DefaultPrng,
    max_message: usize = DEFAULT_MAX_MESSAGE,
    closed: bool = false,

    pub fn init(alloc: Allocator, stream: ByteStream, seed: u64) Conn {
        return .{ .alloc = alloc, .stream = stream, .prng = std.Random.DefaultPrng.init(seed) };
    }

    pub fn deinit(self: *Conn) void {
        self.rbuf.deinit(self.alloc);
        self.frag.deinit(self.alloc);
        self.msg.deinit(self.alloc);
        self.wbuf.deinit(self.alloc);
    }

    fn pending(self: *const Conn) []const u8 {
        return self.rbuf.items[self.rpos..];
    }

    fn consume(self: *Conn, n: usize) void {
        self.rpos += n;
        if (self.rpos == self.rbuf.items.len) {
            self.rbuf.clearRetainingCapacity();
            self.rpos = 0;
        } else if (self.rpos > 1 << 20 and self.rpos * 2 > self.rbuf.items.len) {
            const rest = self.rbuf.items.len - self.rpos;
            std.mem.copyForwards(u8, self.rbuf.items[0..rest], self.rbuf.items[self.rpos..]);
            self.rbuf.items.len = rest;
            self.rpos = 0;
        }
    }

    /// Read more bytes into rbuf (one read call).
    fn fill(self: *Conn, timeout_ms: i64) Error!void {
        try self.rbuf.ensureUnusedCapacity(self.alloc, 16 * 1024);
        const spare = self.rbuf.unusedCapacitySlice();
        const n = try self.stream.read_fn(self.stream.ctx, spare, timeout_ms);
        if (n == 0) {
            self.closed = true;
            return error.Closed;
        }
        self.rbuf.items.len += n;
    }

    fn sendFrame(self: *Conn, opcode: u8, payload: []const u8) Error!void {
        var m: [4]u8 = undefined;
        self.prng.random().bytes(&m);
        self.wbuf.clearRetainingCapacity();
        try encodeFrame(self.alloc, &self.wbuf, opcode, payload, m, true);
        try self.stream.write_fn(self.stream.ctx, self.wbuf.items);
        if (self.wbuf.capacity > 1 << 20) self.wbuf.clearAndFree(self.alloc);
    }

    pub fn sendText(self: *Conn, payload: []const u8) Error!void {
        if (self.closed) return error.Closed;
        return self.sendFrame(Opcode.text, payload);
    }

    /// Send a close frame (best effort) and mark the connection closed.
    pub fn close(self: *Conn) void {
        if (!self.closed) {
            self.sendFrame(Opcode.close, &[_]u8{ 0x03, 0xe8 }) catch {};
            self.closed = true;
        }
    }

    /// Next complete data message. Control frames are handled internally.
    /// error.Timeout leaves all partial state intact so the call can be
    /// retried. `timeout_ms` applies to each wait for bytes.
    pub fn recv(self: *Conn, timeout_ms: i64) Error!Message {
        if (self.closed) return error.Closed;
        while (true) {
            const buf = self.pending();
            const hdr = (try parseHeader(buf)) orelse {
                try self.fill(timeout_ms);
                continue;
            };
            if (hdr.len > self.max_message) return error.TooLarge;
            const len: usize = @intCast(hdr.len);
            if (hdr.opcode != Opcode.cont and hdr.opcode != Opcode.text and hdr.opcode != Opcode.binary) {
                // control frames are tiny
            } else if (self.frag.items.len + len > self.max_message) return error.TooLarge;
            if (buf.len < hdr.header_len + len) {
                try self.fill(timeout_ms);
                continue;
            }
            const payload = buf[hdr.header_len .. hdr.header_len + len];
            switch (hdr.opcode) {
                Opcode.ping => {
                    var tmp: [125]u8 = undefined;
                    @memcpy(tmp[0..len], payload);
                    self.consume(hdr.header_len + len);
                    try self.sendFrame(Opcode.pong, tmp[0..len]);
                },
                Opcode.pong => self.consume(hdr.header_len + len),
                Opcode.close => {
                    var tmp: [125]u8 = undefined;
                    @memcpy(tmp[0..len], payload);
                    self.consume(hdr.header_len + len);
                    if (!self.closed) {
                        self.sendFrame(Opcode.close, tmp[0..@min(len, 2)]) catch {};
                        self.closed = true;
                    }
                    return error.Closed;
                },
                Opcode.text, Opcode.binary => {
                    if (self.frag_op != null) return error.Protocol;
                    if (hdr.fin) {
                        self.msg.clearRetainingCapacity();
                        try self.msg.appendSlice(self.alloc, payload);
                        self.consume(hdr.header_len + len);
                        return self.finishMsg(hdr.opcode);
                    }
                    self.frag.clearRetainingCapacity();
                    try self.frag.appendSlice(self.alloc, payload);
                    self.frag_op = hdr.opcode;
                    self.consume(hdr.header_len + len);
                },
                Opcode.cont => {
                    const op = self.frag_op orelse return error.Protocol;
                    try self.frag.appendSlice(self.alloc, payload);
                    self.consume(hdr.header_len + len);
                    if (hdr.fin) {
                        std.mem.swap(std.ArrayList(u8), &self.msg, &self.frag);
                        self.frag.clearRetainingCapacity();
                        self.frag_op = null;
                        return self.finishMsg(op);
                    }
                },
                else => return error.Protocol,
            }
        }
    }

    fn finishMsg(self: *Conn, op: u8) Message {
        const m: Message = .{ .opcode = op, .data = self.msg.items };
        // Release very large buffers after the caller is done with them, on
        // the next message. (Capacity is trimmed lazily in recv paths.)
        if (self.frag.capacity > 4 << 20) self.frag.clearAndFree(self.alloc);
        return m;
    }
};

// ---------------------------------------------------------------- handshake

pub const HandshakeOpts = struct {
    /// Value for the Host header ("127.0.0.1:9222").
    host: []const u8,
    path: []const u8,
    timeout_ms: i64 = 10_000,
};

/// Perform the client opening handshake on an already connected stream.
/// Leftover bytes after the response headers are kept for `recv`.
pub fn handshake(conn: *Conn, opts: HandshakeOpts) Error!void {
    var key_raw: [16]u8 = undefined;
    conn.prng.random().bytes(&key_raw);
    var key_b64: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&key_b64, &key_raw);

    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(conn.alloc);
    try req.print(conn.alloc, "GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n", .{ opts.path, opts.host, key_b64 });
    try conn.stream.write_fn(conn.stream.ctx, req.items);

    // Read until the blank line.
    while (true) {
        if (std.mem.indexOf(u8, conn.pending(), "\r\n\r\n")) |_| break;
        if (conn.pending().len > 16 * 1024) return error.HandshakeFailed;
        conn.fill(opts.timeout_ms) catch |e| switch (e) {
            error.Closed => return error.HandshakeFailed,
            else => return e,
        };
    }
    const buf = conn.pending();
    const end = std.mem.indexOf(u8, buf, "\r\n\r\n").?;
    const head = buf[0..end];
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const status = lines.next() orelse return error.HandshakeFailed;
    // "HTTP/1.1 101 Switching Protocols"
    var st = std.mem.tokenizeScalar(u8, status, ' ');
    _ = st.next() orelse return error.HandshakeFailed;
    const code = st.next() orelse return error.HandshakeFailed;
    if (!std.mem.eql(u8, code, "101")) return error.HandshakeFailed;
    const want = acceptKey(&key_b64);
    var got_accept = false;
    while (lines.next()) |l| {
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, l[0..colon], " \t"), "sec-websocket-accept")) {
            if (!std.mem.eql(u8, std.mem.trim(u8, l[colon + 1 ..], " \t"), &want)) return error.HandshakeFailed;
            got_accept = true;
        }
    }
    if (!got_accept) return error.HandshakeFailed;
    conn.consume(end + 4);
}

// ---------------------------------------------------------------- TCP

/// A connected TCP socket usable as a ByteStream. Heap allocate (the Io
/// writer points into `wbuf`).
pub const Tcp = struct {
    io: Io,
    stream: Io.net.Stream,
    rbuf: [4096]u8 = undefined,
    wbuf: [4096]u8 = undefined,
    reader: Io.net.Stream.Reader = undefined,
    writer: Io.net.Stream.Writer = undefined,

    pub fn connect(alloc: Allocator, io: Io, ip: []const u8, port: u16) !*Tcp {
        const addr = try Io.net.IpAddress.parse(ip, port);
        const stream = try addr.connect(io, .{ .mode = .stream });
        const t = try alloc.create(Tcp);
        t.* = .{ .io = io, .stream = stream };
        t.reader = stream.reader(io, &t.rbuf);
        t.writer = stream.writer(io, &t.wbuf);
        return t;
    }

    pub fn destroy(self: *Tcp, alloc: Allocator) void {
        self.stream.close(self.io);
        alloc.destroy(self);
    }

    pub fn byteStream(self: *Tcp) ByteStream {
        return .{ .ctx = self, .read_fn = readFn, .write_fn = writeFn };
    }

    fn readFn(ctx: *anyopaque, buf: []u8, timeout_ms: i64) Error!usize {
        const self: *Tcp = @ptrCast(@alignCast(ctx));
        if (builtin.os.tag == .windows) {
            // No poll on Windows sockets through std.Io: blocking read.
            self.reader.interface.fill(1) catch return 0;
            const b = self.reader.interface.buffered();
            const n = @min(b.len, buf.len);
            @memcpy(buf[0..n], b[0..n]);
            self.reader.interface.toss(n);
            return n;
        }
        const posix = std.posix;
        var fds = [1]posix.pollfd{.{ .fd = self.stream.socket.handle, .events = posix.POLL.IN, .revents = 0 }};
        const to: i32 = @intCast(std.math.clamp(timeout_ms, 0, std.math.maxInt(i32)));
        const ready = posix.poll(&fds, to) catch return error.IoFailed;
        if (ready == 0) return error.Timeout;
        return posix.read(self.stream.socket.handle, buf) catch |e| switch (e) {
            error.ConnectionResetByPeer => return 0,
            else => return error.IoFailed,
        };
    }

    fn writeFn(ctx: *anyopaque, data: []const u8) Error!void {
        const self: *Tcp = @ptrCast(@alignCast(ctx));
        self.writer.interface.writeAll(data) catch return error.IoFailed;
        self.writer.interface.flush() catch return error.IoFailed;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Canned-buffer stream: serves `input` in `chunk`-sized reads, records writes.
pub const BufStream = struct {
    input: []const u8,
    pos: usize = 0,
    chunk: usize = 1 << 30,
    written: std.ArrayList(u8) = .empty,
    alloc: Allocator,

    pub fn byteStream(self: *BufStream) ByteStream {
        return .{ .ctx = self, .read_fn = readFn, .write_fn = writeFn };
    }
    fn readFn(ctx: *anyopaque, buf: []u8, _: i64) Error!usize {
        const self: *BufStream = @ptrCast(@alignCast(ctx));
        if (self.pos >= self.input.len) return error.Timeout;
        const n = @min(@min(buf.len, self.chunk), self.input.len - self.pos);
        @memcpy(buf[0..n], self.input[self.pos .. self.pos + n]);
        self.pos += n;
        return n;
    }
    fn writeFn(ctx: *anyopaque, data: []const u8) Error!void {
        const self: *BufStream = @ptrCast(@alignCast(ctx));
        try self.written.appendSlice(self.alloc, data);
    }
};

fn serverFrame(alloc: Allocator, out: *std.ArrayList(u8), op: u8, payload: []const u8, fin: bool) !void {
    try encodeFrame(alloc, out, op, payload, null, fin);
}

test "accept key matches RFC 6455 example" {
    const k = acceptKey("dGhlIHNhbXBsZSBub25jZQ==");
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &k);
}

test "masked client frame matches RFC example" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try encodeFrame(testing.allocator, &out, Opcode.text, "Hello", .{ 0x37, 0xfa, 0x21, 0x3d }, true);
    try testing.expectEqualSlices(u8, &.{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 }, out.items);
}

test "frame length encodings 7/16/64 bit" {
    const a = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const p125 = try a.alloc(u8, 125);
    defer a.free(p125);
    @memset(p125, 'a');
    try encodeFrame(a, &out, Opcode.text, p125, null, true);
    try testing.expectEqual(@as(u8, 125), out.items[1]);
    out.clearRetainingCapacity();
    const p126 = try a.alloc(u8, 126);
    defer a.free(p126);
    @memset(p126, 'a');
    try encodeFrame(a, &out, Opcode.text, p126, null, true);
    try testing.expectEqual(@as(u8, 126), out.items[1]);
    try testing.expectEqual(@as(u16, 126), std.mem.readInt(u16, out.items[2..4], .big));
    const h = (try parseHeader(out.items)).?;
    try testing.expectEqual(@as(u64, 126), h.len);
    try testing.expectEqual(@as(usize, 4), h.header_len);
    out.clearRetainingCapacity();
    const p64k = try a.alloc(u8, 70_000);
    defer a.free(p64k);
    @memset(p64k, 'b');
    try encodeFrame(a, &out, Opcode.binary, p64k, null, true);
    try testing.expectEqual(@as(u8, 127), out.items[1]);
    const h2 = (try parseHeader(out.items)).?;
    try testing.expectEqual(@as(u64, 70_000), h2.len);
    try testing.expectEqual(@as(usize, 10), h2.header_len);
}

test "parseHeader rejects bad frames and asks for more bytes" {
    try testing.expectEqual(@as(?Header, null), try parseHeader(&.{0x81}));
    try testing.expectEqual(@as(?Header, null), try parseHeader(&.{ 0x81, 126, 0 }));
    try testing.expectError(error.Protocol, parseHeader(&.{ 0xC1, 0x00 })); // RSV1
    try testing.expectError(error.Protocol, parseHeader(&.{ 0x81, 0x80 })); // masked from server
    try testing.expectError(error.Protocol, parseHeader(&.{ 0x09, 0x00 })); // fragmented ping
    try testing.expectError(error.Protocol, parseHeader(&.{ 0x89, 126, 0, 200 })); // ping > 125
    try testing.expectError(error.Protocol, parseHeader(&.{ 0x83, 0x00 })); // reserved opcode
}

test "recv: fragmentation, interleaved ping, byte-at-a-time reads" {
    const a = testing.allocator;
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(a);
    try serverFrame(a, &wire, Opcode.text, "hel", false);
    try serverFrame(a, &wire, Opcode.ping, "pp", true); // control frame between fragments
    try serverFrame(a, &wire, Opcode.cont, "lo ", false);
    try serverFrame(a, &wire, Opcode.cont, "world", true);
    try serverFrame(a, &wire, Opcode.text, "second", true);

    var bs: BufStream = .{ .input = wire.items, .chunk = 1, .alloc = a };
    defer bs.written.deinit(a);
    var c = Conn.init(a, bs.byteStream(), 1);
    defer c.deinit();
    const m1 = try c.recv(10);
    try testing.expectEqual(Opcode.text, m1.opcode);
    try testing.expectEqualStrings("hello world", m1.data);
    const m2 = try c.recv(10);
    try testing.expectEqualStrings("second", m2.data);
    // The ping was answered with a masked pong echoing "pp".
    try testing.expectEqual(@as(u8, 0x8A), bs.written.items[0]);
    try testing.expectEqual(@as(u8, 0x82), bs.written.items[1]);
    const mk = bs.written.items[2..6];
    try testing.expectEqual(@as(u8, 'p' ^ mk[0]), bs.written.items[6]);
    // Nothing more: timeout, connection still usable.
    try testing.expectError(error.Timeout, c.recv(1));
}

test "recv: timeout mid-frame keeps state and resumes" {
    const a = testing.allocator;
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(a);
    try serverFrame(a, &wire, Opcode.text, "abcdef", true);
    var bs: BufStream = .{ .input = wire.items[0..5], .alloc = a };
    defer bs.written.deinit(a);
    var c = Conn.init(a, bs.byteStream(), 1);
    defer c.deinit();
    try testing.expectError(error.Timeout, c.recv(1));
    bs.input = wire.items;
    const m = try c.recv(1);
    try testing.expectEqualStrings("abcdef", m.data);
}

test "recv: close frame is echoed and reported" {
    const a = testing.allocator;
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(a);
    try serverFrame(a, &wire, Opcode.close, &.{ 0x03, 0xe8 }, true);
    var bs: BufStream = .{ .input = wire.items, .alloc = a };
    defer bs.written.deinit(a);
    var c = Conn.init(a, bs.byteStream(), 1);
    defer c.deinit();
    try testing.expectError(error.Closed, c.recv(1));
    try testing.expectEqual(@as(u8, 0x88), bs.written.items[0]);
    try testing.expect(c.closed);
    try testing.expectError(error.Closed, c.sendText("x"));
}

test "recv: message over the cap is refused; stray continuation is a protocol error" {
    const a = testing.allocator;
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(a);
    try serverFrame(a, &wire, Opcode.text, "0123456789", true);
    var bs: BufStream = .{ .input = wire.items, .alloc = a };
    defer bs.written.deinit(a);
    var c = Conn.init(a, bs.byteStream(), 1);
    defer c.deinit();
    c.max_message = 5;
    try testing.expectError(error.TooLarge, c.recv(1));

    var w2: std.ArrayList(u8) = .empty;
    defer w2.deinit(a);
    try serverFrame(a, &w2, Opcode.cont, "x", true);
    var bs2: BufStream = .{ .input = w2.items, .alloc = a };
    defer bs2.written.deinit(a);
    var c2 = Conn.init(a, bs2.byteStream(), 1);
    defer c2.deinit();
    try testing.expectError(error.Protocol, c2.recv(1));
}

test "handshake against canned response (accept verified, leftover kept)" {
    const a = testing.allocator;
    // We don't know the random key ahead of time, so run the handshake against
    // a tiny in-process TCP server that derives the accept value.
    const io = testing.io;
    var addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    const Fake = struct {
        fn serve(srv: *Io.net.Server, sio: Io, bad_accept: bool) void {
            const st = srv.accept(sio) catch return;
            defer st.close(sio);
            var rb: [2048]u8 = undefined;
            var wb: [2048]u8 = undefined;
            var rd = st.reader(sio, &rb);
            var wr = st.writer(sio, &wb);
            // Read request headers.
            var req: [2048]u8 = undefined;
            var n: usize = 0;
            while (std.mem.indexOf(u8, req[0..n], "\r\n\r\n") == null) {
                rd.interface.fill(1) catch return;
                const b = rd.interface.buffered();
                @memcpy(req[n .. n + b.len], b);
                n += b.len;
                rd.interface.toss(b.len);
            }
            const head = req[0..n];
            // No Origin header must be sent.
            if (std.ascii.indexOfIgnoreCase(head, "\r\norigin:") != null) return;
            const ki = std.ascii.indexOfIgnoreCase(head, "sec-websocket-key:") orelse return;
            const rest = head[ki + "sec-websocket-key:".len ..];
            const line = rest[0..std.mem.indexOf(u8, rest, "\r\n").?];
            const key = std.mem.trim(u8, line, " ");
            const acc = acceptKey(key);
            var resp: [512]u8 = undefined;
            const s = std.fmt.bufPrint(&resp, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{if (bad_accept) "AAAAAAAAAAAAAAAAAAAAAAAAAAA=" else &acc}) catch return;
            wr.interface.writeAll(s) catch return;
            // Immediately follow with a text frame in the same segment.
            var f: [16]u8 = undefined;
            f[0] = 0x81;
            f[1] = 2;
            f[2] = 'o';
            f[3] = 'k';
            wr.interface.writeAll(f[0..4]) catch return;
            wr.interface.flush() catch return;
            // Then echo one client message back (unmask).
            var got: [64]u8 = undefined;
            var gl: usize = 0;
            while (true) {
                rd.interface.fill(1) catch return;
                const b = rd.interface.buffered();
                @memcpy(got[gl .. gl + b.len], b);
                gl += b.len;
                rd.interface.toss(b.len);
                if (gl >= 2 and gl >= 6 + (got[1] & 0x7f)) break;
            }
            const plen = got[1] & 0x7f;
            var out: [64]u8 = undefined;
            out[0] = 0x81;
            out[1] = plen;
            for (0..plen) |i| out[2 + i] = got[6 + i] ^ got[2 + (i & 3)];
            wr.interface.writeAll(out[0 .. 2 + plen]) catch return;
            wr.interface.flush() catch return;
        }
    };

    {
        var fut = io.async(Fake.serve, .{ &server, io, false });
        defer fut.await(io);
        const tcp = try Tcp.connect(a, io, "127.0.0.1", port);
        defer tcp.destroy(a);
        var c = Conn.init(a, tcp.byteStream(), 7);
        defer c.deinit();
        try handshake(&c, .{ .host = "127.0.0.1", .path = "/devtools/browser/x" });
        const m = try c.recv(2000);
        try testing.expectEqualStrings("ok", m.data);
        try c.sendText("{\"id\":1}");
        const m2 = try c.recv(2000);
        try testing.expectEqualStrings("{\"id\":1}", m2.data);
    }
    {
        var fut = io.async(Fake.serve, .{ &server, io, true });
        defer fut.await(io);
        const tcp = try Tcp.connect(a, io, "127.0.0.1", port);
        defer tcp.destroy(a);
        var c = Conn.init(a, tcp.byteStream(), 7);
        defer c.deinit();
        try testing.expectError(error.HandshakeFailed, handshake(&c, .{ .host = "127.0.0.1", .path = "/" }));
    }
}
