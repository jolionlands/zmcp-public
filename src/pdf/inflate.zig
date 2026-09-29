//! Small, defensive DEFLATE decoder (RFC 1950/1951), puff-style.
//!
//! Used instead of std.compress.flate.Decompress because the std decoder
//! asserts (crashes) on some truncated inputs (tossBitsShort near EOF), and
//! PDF streams are untrusted. This decoder never asserts: on any error it
//! returns the bytes decoded so far, and output is capped at `limit`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const MAXBITS = 15;

const Huffman = struct {
    count: [MAXBITS + 1]u16 = [_]u16{0} ** (MAXBITS + 1),
    symbol: [320]u16 = [_]u16{0} ** 320,

    /// Build from code lengths. Over-subscribed sets are rejected; incomplete
    /// sets are accepted (invalid codes fail at decode time).
    fn build(self: *Huffman, lengths: []const u8) error{Oversubscribed}!void {
        self.count = [_]u16{0} ** (MAXBITS + 1);
        for (lengths) |l| self.count[l] += 1;
        if (self.count[0] == lengths.len) return; // no codes
        var left: i32 = 1;
        var len: usize = 1;
        while (len <= MAXBITS) : (len += 1) {
            left <<= 1;
            left -= self.count[len];
            if (left < 0) return error.Oversubscribed;
        }
        var offs: [MAXBITS + 1]u16 = undefined;
        offs[1] = 0;
        len = 1;
        while (len < MAXBITS) : (len += 1) offs[len + 1] = offs[len] + self.count[len];
        for (lengths, 0..) |l, sym| {
            if (l != 0) {
                self.symbol[offs[l]] = @intCast(sym);
                offs[l] += 1;
            }
        }
    }
};

const State = struct {
    in: []const u8,
    pos: usize = 0,
    bitbuf: u32 = 0,
    bitcnt: u5 = 0,
    out: *std.ArrayList(u8),
    alloc: Allocator,
    limit: usize,

    fn bits(self: *State, need: u5) error{EndOfInput}!u32 {
        var val = self.bitbuf;
        var cnt: u6 = self.bitcnt;
        while (cnt < need) {
            if (self.pos >= self.in.len) return error.EndOfInput;
            val |= @as(u32, self.in[self.pos]) << @intCast(cnt);
            self.pos += 1;
            cnt += 8;
        }
        self.bitbuf = if (need >= 32) 0 else val >> @intCast(need);
        self.bitcnt = @intCast(cnt - need);
        return val & ((@as(u32, 1) << @intCast(need)) - 1);
    }

    fn decode(self: *State, h: *const Huffman) error{ EndOfInput, InvalidCode }!u16 {
        var code: i32 = 0;
        var first: i32 = 0;
        var index: i32 = 0;
        var len: usize = 1;
        while (len <= MAXBITS) : (len += 1) {
            code |= @intCast(try self.bits(1));
            const count: i32 = h.count[len];
            if (code - count < first) return h.symbol[@intCast(index + (code - first))];
            index += count;
            first += count;
            first <<= 1;
            code <<= 1;
        }
        return error.InvalidCode;
    }
};

const lbase = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const lext = [29]u5{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const dbase = [30]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const dext = [30]u5{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

const Err = error{ EndOfInput, InvalidCode, Invalid, Oversubscribed, Limit, OutOfMemory };

fn codes(s: *State, lencode: *const Huffman, distcode: *const Huffman) Err!void {
    while (true) {
        var sym = try s.decode(lencode);
        if (sym < 256) {
            if (s.out.items.len >= s.limit) return error.Limit;
            try s.out.append(s.alloc, @intCast(sym));
        } else if (sym == 256) {
            return;
        } else {
            sym -= 257;
            if (sym >= 29) return error.Invalid;
            const len: usize = lbase[sym] + try s.bits(lext[sym]);
            const dsym = try s.decode(distcode);
            if (dsym >= 30) return error.Invalid;
            const dist: usize = dbase[dsym] + try s.bits(dext[dsym]);
            if (dist > s.out.items.len) return error.Invalid;
            if (s.out.items.len + len > s.limit) return error.Limit;
            try s.out.ensureUnusedCapacity(s.alloc, len);
            var k: usize = 0;
            while (k < len) : (k += 1) {
                s.out.appendAssumeCapacity(s.out.items[s.out.items.len - dist]);
            }
        }
    }
}

fn stored(s: *State) Err!void {
    s.bitbuf = 0;
    s.bitcnt = 0;
    if (s.pos + 4 > s.in.len) return error.EndOfInput;
    const len = std.mem.readInt(u16, s.in[s.pos..][0..2], .little);
    const nlen = std.mem.readInt(u16, s.in[s.pos + 2 ..][0..2], .little);
    s.pos += 4;
    if (len != ~nlen) return error.Invalid;
    const avail = @min(@as(usize, len), s.in.len - s.pos);
    const room = s.limit -| s.out.items.len;
    const n = @min(avail, room);
    try s.out.appendSlice(s.alloc, s.in[s.pos .. s.pos + n]);
    s.pos += n;
    if (n < len) return if (room < len) error.Limit else error.EndOfInput;
}

fn dynamic(s: *State) Err!void {
    const nlen = (try s.bits(5)) + 257;
    const ndist = (try s.bits(5)) + 1;
    const ncode = (try s.bits(4)) + 4;
    if (nlen > 286 or ndist > 30) return error.Invalid;
    const order = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
    var lengths = [_]u8{0} ** 320;
    var i: usize = 0;
    while (i < ncode) : (i += 1) lengths[order[i]] = @intCast(try s.bits(3));
    var lencode: Huffman = .{};
    try lencode.build(lengths[0..19]);
    i = 0;
    var lens = [_]u8{0} ** 320;
    while (i < nlen + ndist) {
        const sym = try s.decode(&lencode);
        if (sym < 16) {
            lens[i] = @intCast(sym);
            i += 1;
        } else {
            var prev: u8 = 0;
            var rep: usize = undefined;
            if (sym == 16) {
                if (i == 0) return error.Invalid;
                prev = lens[i - 1];
                rep = 3 + try s.bits(2);
            } else if (sym == 17) {
                rep = 3 + try s.bits(3);
            } else {
                rep = 11 + try s.bits(7);
            }
            if (i + rep > nlen + ndist) return error.Invalid;
            while (rep > 0) : (rep -= 1) {
                lens[i] = prev;
                i += 1;
            }
        }
    }
    if (lens[256] == 0) return error.Invalid;
    var lit: Huffman = .{};
    try lit.build(lens[0..nlen]);
    var dist: Huffman = .{};
    try dist.build(lens[nlen .. nlen + ndist]);
    try codes(s, &lit, &dist);
}

fn fixedTables() struct { lit: Huffman, dist: Huffman } {
    var l = [_]u8{0} ** 288;
    for (0..144) |i| l[i] = 8;
    for (144..256) |i| l[i] = 9;
    for (256..280) |i| l[i] = 7;
    for (280..288) |i| l[i] = 8;
    var lit: Huffman = .{};
    lit.build(&l) catch unreachable;
    var dl = [_]u8{5} ** 30;
    var dist: Huffman = .{};
    dist.build(&dl) catch unreachable;
    return .{ .lit = lit, .dist = dist };
}

/// Raw DEFLATE. Returns everything decoded before an error or the limit.
pub fn inflateRaw(alloc: Allocator, input: []const u8, limit: usize) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var s: State = .{ .in = input, .out = &out, .alloc = alloc, .limit = limit };
    while (true) {
        const last = s.bits(1) catch break;
        const typ = s.bits(2) catch break;
        const r: Err!void = switch (typ) {
            0 => stored(&s),
            1 => blk: {
                const t = fixedTables();
                break :blk codes(&s, &t.lit, &t.dist);
            },
            2 => dynamic(&s),
            else => error.Invalid,
        };
        r catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => break,
        };
        if (last == 1) break;
    }
    return out.toOwnedSlice(alloc);
}

/// zlib-wrapped (header skipped, checksum ignored); a missing/invalid zlib
/// header falls back to raw deflate.
pub fn inflate(alloc: Allocator, input: []const u8, limit: usize) Allocator.Error![]u8 {
    if (input.len >= 2) {
        const cmf = input[0];
        const flg = input[1];
        if ((cmf & 0x0f) == 8 and ((@as(u32, cmf) << 8) | flg) % 31 == 0) {
            var skip: usize = 2;
            if (flg & 0x20 != 0) skip += 4;
            if (skip <= input.len) {
                const r = try inflateRaw(alloc, input[skip..], limit);
                if (r.len > 0 or input.len - skip < 4) return r;
                alloc.free(r);
            }
        }
    }
    return inflateRaw(alloc, input, limit);
}

test "inflate: stored, fixed, dynamic (via std compressor), truncated" {
    const t = std.testing;
    const a = t.allocator;
    const tp = @import("testpdf.zig");
    // stored block
    const stored_z = [_]u8{ 0x78, 0x01, 0x01, 0x05, 0x00, 0xfa, 0xff, 'h', 'e', 'l', 'l', 'o', 0, 0, 0, 0 };
    const r0 = try inflate(a, &stored_z, 1000);
    defer a.free(r0);
    try t.expectEqualStrings("hello", r0);
    // round trip large, repetitive + varied data
    var buf: [20000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    for (&buf, 0..) |*c, i| c.* = if (i % 7 < 4) @intCast('a' + i % 5) else prng.random().int(u8);
    const z = try tp.zlib(a, &buf);
    defer a.free(z);
    const r1 = try inflate(a, z, 1 << 20);
    defer a.free(r1);
    try t.expectEqualSlices(u8, &buf, r1);
    // limit
    const r2 = try inflate(a, z, 1000);
    defer a.free(r2);
    try t.expect(r2.len <= 1000 and r2.len > 0);
    try t.expectEqualSlices(u8, buf[0..r2.len], r2);
    // truncation returns a prefix
    const r3 = try inflate(a, z[0 .. z.len / 2], 1 << 20);
    defer a.free(r3);
    try t.expect(r3.len > 0 and r3.len < buf.len);
    try t.expectEqualSlices(u8, buf[0..r3.len], r3);
    // garbage never crashes
    var g: [64]u8 = undefined;
    var k: usize = 0;
    while (k < 200) : (k += 1) {
        prng.random().bytes(&g);
        const r = try inflateRaw(a, &g, 1 << 16);
        a.free(r);
    }
}
