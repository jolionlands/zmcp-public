//! hash: sha256 sha512 sha1 md5 blake3 crc32 xxh64, optional HMAC.

const std = @import("std");
const u = @import("util.zig");
const crypto = std.crypto;

pub const Alg = enum { sha256, sha512, sha1, md5, blake3, crc32, xxh64 };

pub fn handle(a: std.mem.Allocator, args: std.json.Value) u.Err![]u8 {
    const alg_s = try u.reqStr(args, "alg");
    const alg = std.meta.stringToEnum(Alg, alg_s) orelse return u.fail("unknown alg '{s}' (sha256|sha512|sha1|md5|blake3|crc32|xxh64)", .{alg_s});
    const text = try u.optStr(args, "text");
    const hexb = try u.optStr(args, "hex_bytes");
    const key = try u.optStr(args, "hmac_key");
    if (text != null and hexb != null) return u.fail("give either 'text' or 'hex_bytes', not both", .{});
    var owned: ?[]u8 = null;
    defer if (owned) |o| a.free(o);
    const data: []const u8 = if (text) |t| t else if (hexb) |h| blk: {
        owned = try u.parseHexBytes(a, h);
        break :blk owned.?;
    } else return u.fail("missing 'text' or 'hex_bytes'", .{});
    return compute(a, alg, data, key);
}

pub fn compute(a: std.mem.Allocator, alg: Alg, data: []const u8, key: ?[]const u8) u.Err![]u8 {
    var buf: [64]u8 = undefined;
    const digest: []const u8 = if (key) |k| switch (alg) {
        .sha256 => hmac(crypto.auth.hmac.sha2.HmacSha256, &buf, data, k),
        .sha512 => hmac(crypto.auth.hmac.sha2.HmacSha512, &buf, data, k),
        .sha1 => hmac(crypto.auth.hmac.HmacSha1, &buf, data, k),
        .md5 => hmac(crypto.auth.hmac.HmacMd5, &buf, data, k),
        else => return u.fail("hmac_key is supported for sha256, sha512, sha1, md5 only (not {s})", .{@tagName(alg)}),
    } else switch (alg) {
        .sha256 => plain(crypto.hash.sha2.Sha256, &buf, data),
        .sha512 => plain(crypto.hash.sha2.Sha512, &buf, data),
        .sha1 => plain(crypto.hash.Sha1, &buf, data),
        .md5 => plain(crypto.hash.Md5, &buf, data),
        .blake3 => plain(crypto.hash.Blake3, &buf, data),
        .crc32 => blk: {
            const c = std.hash.Crc32.hash(data);
            std.mem.writeInt(u32, buf[0..4], c, .big);
            break :blk buf[0..4];
        },
        .xxh64 => blk: {
            const c = std.hash.XxHash64.hash(0, data);
            std.mem.writeInt(u64, buf[0..8], c, .big);
            break :blk buf[0..8];
        },
    };
    var out: u.Out = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("{s}{s}: ", .{ if (key != null) "hmac-" else "", @tagName(alg) });
    try u.writeHex(w, digest);
    switch (alg) {
        .md5, .sha1 => if (key == null) try w.writeAll("\nwarning: not collision-resistant; do not use for security (integrity checks against accidents only)"),
        .crc32 => try w.writeAll("\nnote: CRC-32/IEEE (zlib/PNG), non-cryptographic"),
        .xxh64 => try w.writeAll("\nnote: XXH64 seed 0, non-cryptographic"),
        else => {},
    }
    try w.print("\ninput: {d} bytes{s}", .{ data.len, if (key != null) ", keyed (key not echoed)" else "" });
    return out.toOwnedSlice();
}

fn plain(comptime H: type, buf: *[64]u8, data: []const u8) []const u8 {
    var out: [H.digest_length]u8 = undefined;
    H.hash(data, &out, .{});
    @memcpy(buf[0..out.len], &out);
    return buf[0..out.len];
}

fn hmac(comptime M: type, buf: *[64]u8, data: []const u8, key: []const u8) []const u8 {
    var out: [M.mac_length]u8 = undefined;
    M.create(&out, data, key);
    @memcpy(buf[0..out.len], &out);
    return buf[0..out.len];
}

fn expectHash(alg: Alg, data: []const u8, key: ?[]const u8, want_hex: []const u8) !void {
    const got = try compute(std.testing.allocator, alg, data, key);
    defer std.testing.allocator.free(got);
    const prefix_len = std.mem.indexOf(u8, got, ": ").? + 2;
    const end = std.mem.indexOfScalarPos(u8, got, prefix_len, '\n') orelse got.len;
    try std.testing.expectEqualStrings(want_hex, got[prefix_len..end]);
}

test "known-answer vectors: empty and abc" {
    try expectHash(.sha256, "", null, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    try expectHash(.sha256, "abc", null, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    try expectHash(.sha256, "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", null, "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
    try expectHash(.sha512, "abc", null, "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f");
    try expectHash(.sha512, "", null, "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e");
    try expectHash(.sha1, "abc", null, "a9993e364706816aba3e25717850c26c9cd0d89d");
    try expectHash(.sha1, "", null, "da39a3ee5e6b4b0d3255bfef95601890afd80709");
    try expectHash(.md5, "", null, "d41d8cd98f00b204e9800998ecf8427e");
    try expectHash(.md5, "abc", null, "900150983cd24fb0d6963f7d28e17f72");
    try expectHash(.md5, "message digest", null, "f96b697d7cb7938d525a2f31aaf161d0");
    try expectHash(.blake3, "", null, "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262");
    try expectHash(.blake3, "abc", null, "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85");
    try expectHash(.crc32, "123456789", null, "cbf43926");
    try expectHash(.crc32, "", null, "00000000");
    try expectHash(.xxh64, "", null, "ef46db3751d8e999");
    try expectHash(.xxh64, "abc", null, "44bc2cf5ad770999");
}

test "million a sha256" {
    const a = try std.testing.allocator.alloc(u8, 1_000_000);
    defer std.testing.allocator.free(a);
    @memset(a, 'a');
    try expectHash(.sha256, a, null, "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
}

test "HMAC RFC 2202 / RFC 4231 vectors" {
    // RFC 4231 test case 2
    try expectHash(.sha256, "what do ya want for nothing?", "Jefe", "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
    try expectHash(.sha512, "what do ya want for nothing?", "Jefe", "164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea2505549758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737");
    // RFC 2202 test case 2
    try expectHash(.sha1, "what do ya want for nothing?", "Jefe", "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79");
    try expectHash(.md5, "what do ya want for nothing?", "Jefe", "750c783e6ab0b503eaa86e310a5db738");
}

test "hmac rejects unsupported alg and never echoes key" {
    try std.testing.expectError(error.Fail, compute(std.testing.allocator, .crc32, "x", "k"));
    const got = try compute(std.testing.allocator, .sha256, "x", "supersecretkey");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "supersecretkey") == null);
    try std.testing.expect(std.mem.startsWith(u8, got, "hmac-sha256: "));
}

test "md5/sha1 carry warning" {
    const got = try compute(std.testing.allocator, .md5, "x", null);
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "not collision-resistant") != null);
}
