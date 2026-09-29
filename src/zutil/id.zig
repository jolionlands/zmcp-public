//! id: uuid4, uuid7, ulid, nanoid, random_hex, random_token (OS randomness via std.Io).

const std = @import("std");
const u = @import("util.zig");

pub const Kind = enum { uuid4, uuid7, ulid, nanoid, random_hex, random_token };

pub const MAX_COUNT = 100;
pub const MAX_BYTES = 1024;

pub fn handle(a: std.mem.Allocator, io: std.Io, args: std.json.Value) u.Err![]u8 {
    const k_s = try u.reqStr(args, "kind");
    const kind = std.meta.stringToEnum(Kind, k_s) orelse return u.fail("unknown kind '{s}' (uuid4|uuid7|ulid|nanoid|random_hex|random_token)", .{k_s});
    const count = (try u.optInt(args, "count")) orelse 1;
    if (count < 1 or count > MAX_COUNT) return u.fail("count must be 1..{d}", .{MAX_COUNT});
    const bytes = try u.optInt(args, "bytes");
    if (bytes) |b| if (b < 1 or b > MAX_BYTES) return u.fail("bytes must be 1..{d}", .{MAX_BYTES});
    const now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    var rng: IoRng = .{ .io = io };
    return generate(a, &rng, kind, @intCast(count), if (bytes) |b| @intCast(b) else null, now_ms);
}

pub const IoRng = struct {
    io: std.Io,
    pub fn fill(self: *IoRng, buf: []u8) void {
        self.io.random(buf);
    }
};

const b64url = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// `rng` needs `fill(*Self, []u8) void`.
pub fn generate(a: std.mem.Allocator, rng: anytype, kind: Kind, count: usize, bytes: ?usize, now_ms: i64) u.Err![]u8 {
    var out: u.Out = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    var last_ms: i64 = -1; // uuid7 / ulid monotonic state
    var last_rand: u128 = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (i > 0) try w.writeByte('\n');
        switch (kind) {
            .uuid4 => {
                var b: [16]u8 = undefined;
                rng.fill(&b);
                b[6] = (b[6] & 0x0f) | 0x40;
                b[8] = (b[8] & 0x3f) | 0x80;
                try writeUuid(w, &b);
            },
            .uuid7 => {
                // RFC 9562 layout: 48-bit unix ms | ver 7 | 12 rand | var 10 | 62 rand.
                // Within one call the timestamp is bumped by 1 ms if needed so the batch sorts.
                var ms = now_ms;
                if (ms <= last_ms) ms = last_ms + 1;
                last_ms = ms;
                var b: [16]u8 = undefined;
                rng.fill(&b);
                const t: u48 = @intCast(@as(u64, @intCast(ms)) & 0xffff_ffff_ffff);
                std.mem.writeInt(u48, b[0..6], t, .big);
                b[6] = (b[6] & 0x0f) | 0x70;
                b[8] = (b[8] & 0x3f) | 0x80;
                try writeUuid(w, &b);
            },
            .ulid => {
                // 48-bit ms + 80 random bits, Crockford base32. Same-ms IDs in one call increment
                // the random part (ULID spec monotonicity) so the batch is strictly increasing.
                var r: u128 = undefined;
                if (now_ms == last_ms) {
                    if (last_rand == (@as(u128, 1) << 80) - 1) return u.fail("ulid: random part overflow", .{});
                    r = last_rand + 1;
                } else {
                    var rb: [10]u8 = undefined;
                    rng.fill(&rb);
                    r = 0;
                    for (rb) |x| r = (r << 8) | x;
                }
                last_ms = now_ms;
                last_rand = r;
                var s: [26]u8 = undefined;
                var t: u64 = @as(u64, @intCast(now_ms)) & 0xffff_ffff_ffff;
                var j: usize = 10;
                while (j > 0) {
                    j -= 1;
                    s[j] = crockford[@intCast(t & 31)];
                    t >>= 5;
                }
                j = 26;
                var rr = r;
                while (j > 10) {
                    j -= 1;
                    s[j] = crockford[@intCast(rr & 31)];
                    rr >>= 5;
                }
                try w.writeAll(&s);
            },
            .nanoid => {
                const n = bytes orelse 21;
                if (n > 256) return u.fail("nanoid length must be <= 256", .{});
                var buf: [256]u8 = undefined;
                rng.fill(buf[0..n]);
                for (buf[0..n]) |x| try w.writeByte(b64url[x & 63]); // 64 symbols: no modulo bias
            },
            .random_hex, .random_token => {
                const n = bytes orelse (if (kind == .random_hex) @as(usize, 16) else 32);
                const buf = try a.alloc(u8, n);
                defer a.free(buf);
                rng.fill(buf);
                if (kind == .random_hex) {
                    try u.writeHex(w, buf);
                } else {
                    const enc = std.base64.url_safe_no_pad.Encoder;
                    const tmp = try a.alloc(u8, enc.calcSize(n));
                    defer a.free(tmp);
                    try w.writeAll(enc.encode(tmp, buf));
                }
            },
        }
    }
    return out.toOwnedSlice();
}

fn writeUuid(w: *std.Io.Writer, b: *const [16]u8) !void {
    for (b, 0..) |x, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) try w.writeByte('-');
        try u.writeHex(w, &.{x});
    }
}

// ------------------------------------------------------------------- tests

const TestRng = struct {
    state: u64 = 12345,
    pub fn fill(self: *TestRng, buf: []u8) void {
        for (buf) |*x| {
            self.state = self.state *% 6364136223846793005 +% 1442695040888963407;
            x.* = @intCast(self.state >> 56);
        }
    }
};

const FF = struct {
    pub fn fill(_: *FF, buf: []u8) void {
        @memset(buf, 0xff);
    }
};

test "uuid4 layout" {
    var r: TestRng = .{};
    const s = try generate(std.testing.allocator, &r, .uuid4, 5, null, 0);
    defer std.testing.allocator.free(s);
    var it = std.mem.splitScalar(u8, s, '\n');
    var n: usize = 0;
    while (it.next()) |line| : (n += 1) {
        try std.testing.expectEqual(@as(usize, 36), line.len);
        try std.testing.expect(line[8] == '-' and line[13] == '-' and line[18] == '-' and line[23] == '-');
        try std.testing.expectEqual(@as(u8, '4'), line[14]);
        try std.testing.expect(std.mem.indexOfScalar(u8, "89ab", line[19]) != null);
    }
    try std.testing.expectEqual(@as(usize, 5), n);
}

test "uuid7 layout: timestamp, version, variant, monotonic batch" {
    var r: TestRng = .{};
    // 2022-02-22T19:22:22Z = 1645557742000 ms = 0x017F22E279B0 (RFC 9562 example)
    const s = try generate(std.testing.allocator, &r, .uuid7, 3, null, 1645557742000);
    defer std.testing.allocator.free(s);
    var it = std.mem.splitScalar(u8, s, '\n');
    var prev: []const u8 = "";
    var k: usize = 0;
    while (it.next()) |line| : (k += 1) {
        try std.testing.expectEqual(@as(usize, 36), line.len);
        try std.testing.expectEqual(@as(u8, '7'), line[14]);
        try std.testing.expect(std.mem.indexOfScalar(u8, "89ab", line[19]) != null);
        if (k == 0) try std.testing.expect(std.mem.startsWith(u8, line, "017f22e2-79b0-7"));
        if (k == 1) try std.testing.expect(std.mem.startsWith(u8, line, "017f22e2-79b1-7")); // bumped 1 ms
        if (k > 0) try std.testing.expect(std.mem.order(u8, prev, line) == .lt);
        prev = line;
    }
}

test "ulid format, timestamp encoding, monotonic" {
    var r: TestRng = .{};
    const s = try generate(std.testing.allocator, &r, .ulid, 4, null, 1469918176385);
    defer std.testing.allocator.free(s);
    var it = std.mem.splitScalar(u8, s, '\n');
    var prev: []const u8 = "";
    var k: usize = 0;
    while (it.next()) |line| : (k += 1) {
        try std.testing.expectEqual(@as(usize, 26), line.len);
        for (line) |c| try std.testing.expect(std.mem.indexOfScalar(u8, crockford, c) != null);
        try std.testing.expect(std.mem.startsWith(u8, line, "01ARYZ6S41")); // ULID spec example time
        if (k > 0) try std.testing.expect(std.mem.order(u8, prev, line) == .lt);
        prev = line;
    }
}

test "ulid same-ms increment carries and overflow errors" {
    var f: FF = .{};
    try std.testing.expectError(error.Fail, generate(std.testing.allocator, &f, .ulid, 2, null, 1000));
}

test "nanoid, random_hex, random_token sizes and alphabets" {
    var r: TestRng = .{};
    const n = try generate(std.testing.allocator, &r, .nanoid, 1, null, 0);
    defer std.testing.allocator.free(n);
    try std.testing.expectEqual(@as(usize, 21), n.len);
    for (n) |c| try std.testing.expect(std.mem.indexOfScalar(u8, b64url, c) != null);
    const h = try generate(std.testing.allocator, &r, .random_hex, 1, 8, 0);
    defer std.testing.allocator.free(h);
    try std.testing.expectEqual(@as(usize, 16), h.len);
    const t = try generate(std.testing.allocator, &r, .random_token, 1, null, 0);
    defer std.testing.allocator.free(t);
    try std.testing.expectEqual(@as(usize, 43), t.len); // 32 bytes -> 43 base64url chars
    const many = try generate(std.testing.allocator, &r, .random_hex, 100, null, 0);
    defer std.testing.allocator.free(many);
    try std.testing.expectEqual(@as(usize, 99), std.mem.count(u8, many, "\n"));
}

test "real io randomness differs between calls" {
    var thr: std.Io.Threaded = .init_single_threaded;
    const io = thr.io();
    var rng: IoRng = .{ .io = io };
    const a1 = try generate(std.testing.allocator, &rng, .random_hex, 1, 16, 0);
    defer std.testing.allocator.free(a1);
    const a2 = try generate(std.testing.allocator, &rng, .random_hex, 1, 16, 0);
    defer std.testing.allocator.free(a2);
    try std.testing.expect(!std.mem.eql(u8, a1, a2));
}
