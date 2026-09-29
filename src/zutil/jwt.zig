//! jwt_decode: decode header and payload of a JWT. Never verifies the signature.

const std = @import("std");
const u = @import("util.zig");

const MAX_SHOWN = 4096;

pub fn handle(a: std.mem.Allocator, io: std.Io, args: std.json.Value) u.Err![]u8 {
    const token = try u.reqStr(args, "token");
    const now_s = @divFloor(std.Io.Timestamp.now(io, .real).toMilliseconds(), 1000);
    return decode(a, token, now_s);
}

fn b64urlDecode(a: std.mem.Allocator, s: []const u8, what: []const u8) u.Err![]u8 {
    var end = s.len;
    while (end > 0 and s[end - 1] == '=') end -= 1;
    const body = s[0..end];
    const dec = std.base64.url_safe_no_pad.Decoder;
    const n = dec.calcSizeForSlice(body) catch return u.fail("jwt: {s} is not valid base64url", .{what});
    const buf = try a.alloc(u8, n);
    errdefer a.free(buf);
    dec.decode(buf, body) catch return u.fail("jwt: {s} is not valid base64url", .{what});
    return buf;
}

pub fn decode(a: std.mem.Allocator, token_in: []const u8, now_s: i64) u.Err![]u8 {
    var token = std.mem.trim(u8, token_in, " \t\r\n\"'");
    if (token.len > 7 and std.ascii.eqlIgnoreCase(token[0..7], "bearer ")) token = std.mem.trim(u8, token[7..], " ");
    var parts = std.mem.splitScalar(u8, token, '.');
    const h_s = parts.next() orelse "";
    const p_s = parts.next() orelse return u.fail("jwt: expected 3 dot-separated parts (header.payload.signature)", .{});
    const s_s = parts.next() orelse return u.fail("jwt: expected 3 dot-separated parts (header.payload.signature); got 2 (JWE tokens have 5 and are encrypted)", .{});
    if (parts.next() != null) return u.fail("jwt: more than 3 parts; this looks like an encrypted JWE, which cannot be decoded", .{});

    const h_raw = try b64urlDecode(a, h_s, "header");
    defer a.free(h_raw);
    const p_raw = try b64urlDecode(a, p_s, "payload");
    defer a.free(p_raw);
    const hp = std.json.parseFromSlice(std.json.Value, a, h_raw, .{}) catch return u.fail("jwt: header is not valid JSON", .{});
    defer hp.deinit();
    const pp = std.json.parseFromSlice(std.json.Value, a, p_raw, .{}) catch return u.fail("jwt: payload is not valid JSON (opaque/non-JWT payload?)", .{});
    defer pp.deinit();
    if (hp.value != .object) return u.fail("jwt: header is not a JSON object", .{});

    var out: u.Out = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("NOT VERIFIED: signature was not checked (no key). Do not trust these claims for auth decisions.\n");

    const hj = try std.json.Stringify.valueAlloc(a, hp.value, .{});
    defer a.free(hj);
    try w.writeAll("header: ");
    try writeCapped(w, hj);
    const pj = try std.json.Stringify.valueAlloc(a, pp.value, .{});
    defer a.free(pj);
    try w.writeAll("\npayload: ");
    try writeCapped(w, pj);

    if (hp.value.object.get("alg")) |alg| if (alg == .string) {
        if (std.ascii.eqlIgnoreCase(alg.string, "none")) try w.writeAll("\nwarning: alg=none (unsigned token)");
    };

    if (pp.value == .object) {
        const claims = [_][]const u8{ "exp", "nbf", "iat" };
        for (claims) |c| {
            const v = pp.value.object.get(c) orelse continue;
            const secs: i64 = switch (v) {
                .integer => |i| i,
                .float => |f| if (std.math.isFinite(f) and @abs(f) < 1e15) @as(i64, @intFromFloat(@floor(f))) else {
                    try w.print("\n{s}: invalid number", .{c});
                    continue;
                },
                else => {
                    try w.print("\n{s}: not a number (NumericDate expected)", .{c});
                    continue;
                },
            };
            if (secs < -62135596800 or secs > 253402300799) {
                try w.print("\n{s}: {d} (out of range; milliseconds instead of seconds?)", .{ c, secs });
                continue;
            }
            try w.print("\n{s}: ", .{c});
            try u.writeIsoUtc(w, secs);
            const diff = secs - now_s;
            if (std.mem.eql(u8, c, "exp")) {
                if (diff <= 0) {
                    try w.writeAll(" EXPIRED ");
                    try u.writeSpan(w, diff);
                    try w.writeAll(" ago");
                } else {
                    try w.writeAll(" not expired, expires in ");
                    try u.writeSpan(w, diff);
                }
            } else if (std.mem.eql(u8, c, "nbf")) {
                if (diff > 0) {
                    try w.writeAll(" NOT YET VALID, starts in ");
                    try u.writeSpan(w, diff);
                } else try w.writeAll(" already valid");
            } else {
                try w.writeAll(if (diff > 0) " (in the future)" else " ");
                if (diff <= 0) {
                    try u.writeSpan(w, diff);
                    try w.writeAll(" ago");
                }
            }
        }
        if (pp.value.object.get("exp") == null) try w.writeAll("\nexp: absent (token never expires by claim)");
    }
    const sig_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(std.mem.trimEnd(u8, s_s, "=")) catch 0;
    if (s_s.len == 0) {
        try w.writeAll("\nsignature: absent");
    } else try w.print("\nsignature: present, {d} bytes (not shown, not verified)", .{sig_len});
    return out.toOwnedSlice();
}

fn writeCapped(w: *std.Io.Writer, s: []const u8) !void {
    if (s.len <= MAX_SHOWN) return w.writeAll(s);
    try w.writeAll(s[0..MAX_SHOWN]);
    try w.print("... [truncated, {d} bytes total]", .{s.len});
}

// ------------------------------------------------------------------- tests

// header {"alg":"HS256","typ":"JWT"}, payload {"sub":"1234567890","name":"John Doe","iat":1516239022}
// (the canonical jwt.io example; signature is the jwt.io one, which we never check)
const jwtio = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c";

test "jwt.io example decodes, says not verified, shows iat" {
    const got = try decode(std.testing.allocator, jwtio, 1516239022 + 3600);
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "NOT VERIFIED") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "header: {\"alg\":\"HS256\",\"typ\":\"JWT\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"name\":\"John Doe\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "iat: 2018-01-18T01:30:22Z 1h ago") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "exp: absent") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "signature: present, 32 bytes") != null);
    // the signature text itself is never echoed
    try std.testing.expect(std.mem.indexOf(u8, got, "SflKxw") == null);
}

fn mk(a: std.mem.Allocator, h: []const u8, p: []const u8) ![]u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const hb = try a.alloc(u8, enc.calcSize(h.len));
    defer a.free(hb);
    const pb = try a.alloc(u8, enc.calcSize(p.len));
    defer a.free(pb);
    return std.fmt.allocPrint(a, "{s}.{s}.c2ln", .{ enc.encode(hb, h), enc.encode(pb, p) });
}

test "expired token, not-yet-valid token, alg none" {
    const a = std.testing.allocator;
    const tok = try mk(a, "{\"alg\":\"HS256\"}", "{\"exp\":1700000000,\"nbf\":1699990000,\"iat\":1699990000}");
    defer a.free(tok);
    const expired = try decode(a, tok, 1700000000 + 2 * 86400 + 3600);
    defer a.free(expired);
    try std.testing.expect(std.mem.indexOf(u8, expired, "exp: 2023-11-14T22:13:20Z EXPIRED 2d 1h ago") != null);
    try std.testing.expect(std.mem.indexOf(u8, expired, "nbf: 2023-11-14T19:26:40Z already valid") != null);
    const live = try decode(a, tok, 1700000000 - 90);
    defer a.free(live);
    try std.testing.expect(std.mem.indexOf(u8, live, "not expired, expires in 1m 30s") != null);
    const early = try mk(a, "{\"alg\":\"none\"}", "{\"nbf\":2000000000}");
    defer a.free(early);
    const e = try decode(a, early, 1700000000);
    defer a.free(e);
    try std.testing.expect(std.mem.indexOf(u8, e, "NOT YET VALID") != null);
    try std.testing.expect(std.mem.indexOf(u8, e, "alg=none") != null);
}

test "bad tokens" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.Fail, decode(a, "abc", 0));
    try std.testing.expectError(error.Fail, decode(a, "a.b", 0));
    try std.testing.expectError(error.Fail, decode(a, "a.b.c.d.e", 0));
    try std.testing.expectError(error.Fail, decode(a, "!!!.???.x", 0));
    const notjson = try mk(a, "notjson", "{}");
    defer a.free(notjson);
    try std.testing.expectError(error.Fail, decode(a, notjson, 0));
    // Bearer prefix and quotes are tolerated
    const ok = try decode(a, "Bearer " ++ jwtio, 0);
    defer a.free(ok);
}
