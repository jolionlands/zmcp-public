//! codec: base64, base64url, hex, url (percent), html entities, utf8-bytes.

const std = @import("std");
const u = @import("util.zig");

pub const Op = enum { base64, base64url, hex, url, html, @"utf8-bytes" };

pub fn handle(a: std.mem.Allocator, args: std.json.Value) u.Err![]u8 {
    const op_s = try u.reqStr(args, "op");
    const op = std.meta.stringToEnum(Op, op_s) orelse return u.fail("unknown op '{s}' (base64|base64url|hex|url|html|utf8-bytes)", .{op_s});
    const mode_s = try u.reqStr(args, "mode");
    const enc = if (std.mem.eql(u8, mode_s, "encode")) true else if (std.mem.eql(u8, mode_s, "decode")) false else return u.fail("mode must be 'encode' or 'decode'", .{});
    const text = try u.reqStr(args, "text");
    return convert(a, op, enc, text);
}

pub fn convert(a: std.mem.Allocator, op: Op, encode: bool, text: []const u8) u.Err![]u8 {
    var out: u.Out = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    switch (op) {
        .base64, .base64url => {
            const url = op == .base64url;
            if (encode) {
                const enc = if (url) std.base64.url_safe_no_pad.Encoder else std.base64.standard.Encoder;
                const buf = try a.alloc(u8, enc.calcSize(text.len));
                defer a.free(buf);
                try w.writeAll(enc.encode(buf, text));
            } else {
                const bytes = try b64Decode(a, text, url);
                defer a.free(bytes);
                try writeBytesOrHex(w, bytes);
            }
        },
        .hex => {
            if (encode) {
                try u.writeHex(w, text);
            } else {
                const bytes = try u.parseHexBytes(a, text);
                defer a.free(bytes);
                try writeBytesOrHex(w, bytes);
            }
        },
        .url => {
            if (encode) {
                for (text) |c| {
                    if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
                        try w.writeByte(c);
                    } else try w.print("%{X:0>2}", .{c});
                }
            } else {
                var bytes: std.ArrayList(u8) = .empty;
                defer bytes.deinit(a);
                var i: usize = 0;
                while (i < text.len) : (i += 1) {
                    if (text[i] == '%') {
                        if (i + 2 >= text.len) return u.fail("url: truncated %-escape at position {d}", .{i});
                        const hi = u.hexNibble(text[i + 1]);
                        const lo = u.hexNibble(text[i + 2]);
                        if (hi == null or lo == null) return u.fail("url: invalid %-escape at position {d}", .{i});
                        try bytes.append(a, (hi.? << 4) | lo.?);
                        i += 2;
                    } else try bytes.append(a, text[i]); // '+' stays '+' (not form-decoded)
                }
                try writeBytesOrHex(w, bytes.items);
            }
        },
        .html => {
            if (encode) {
                for (text) |c| switch (c) {
                    '&' => try w.writeAll("&amp;"),
                    '<' => try w.writeAll("&lt;"),
                    '>' => try w.writeAll("&gt;"),
                    '"' => try w.writeAll("&quot;"),
                    '\'' => try w.writeAll("&#39;"),
                    else => try w.writeByte(c),
                };
            } else try htmlDecode(w, text);
        },
        .@"utf8-bytes" => {
            if (encode) {
                var cps: usize = 0;
                var view = std.unicode.Utf8View.init(text) catch return u.fail("utf8-bytes: input is not valid UTF-8", .{});
                var it = view.iterator();
                while (it.nextCodepoint()) |_| cps += 1;
                for (text, 0..) |b, i| {
                    if (i > 0) try w.writeByte(' ');
                    try u.writeHex(w, &.{b});
                }
                try w.print(" ({d} bytes, {d} code points)", .{ text.len, cps });
            } else {
                const bytes = try u.parseHexBytes(a, text);
                defer a.free(bytes);
                if (!std.unicode.utf8ValidateSlice(bytes)) {
                    var i: usize = 0;
                    while (i < bytes.len) {
                        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return u.fail("utf8-bytes: invalid UTF-8 at byte {d}", .{i});
                        if (i + n > bytes.len or !std.unicode.utf8ValidateSlice(bytes[i .. i + n])) return u.fail("utf8-bytes: invalid UTF-8 at byte {d}", .{i});
                        i += n;
                    }
                }
                try w.writeAll(bytes);
            }
        },
    }
    return out.toOwnedSlice();
}

fn writeBytesOrHex(w: *std.Io.Writer, bytes: []const u8) !void {
    if (std.unicode.utf8ValidateSlice(bytes)) {
        try w.writeAll(bytes);
    } else {
        try w.print("(not valid UTF-8; {d} bytes as hex) ", .{bytes.len});
        try u.writeHex(w, bytes);
    }
}

fn b64Val(c: u8, url: bool) ?u8 {
    return switch (c) {
        'A'...'Z' => c - 'A',
        'a'...'z' => c - 'a' + 26,
        '0'...'9' => c - '0' + 52,
        '+' => if (url) null else 62,
        '/' => if (url) null else 63,
        '-' => if (url) 62 else null,
        '_' => if (url) 63 else null,
        else => null,
    };
}

/// Lenient on whitespace and missing '=' padding; strict on alphabet
/// (standard and url-safe alphabets are not interchangeable).
fn b64Decode(a: std.mem.Allocator, text: []const u8, url: bool) u.Err![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var acc: u32 = 0;
    var bits: u5 = 0;
    var pad: usize = 0;
    for (text, 0..) |c, i| {
        if (c == ' ' or c == '\n' or c == '\r' or c == '\t') continue;
        if (c == '=') {
            pad += 1;
            continue;
        }
        if (pad > 0) return u.fail("base64: data after '=' padding at position {d}", .{i});
        const v = b64Val(c, url) orelse {
            if (url and (c == '+' or c == '/')) return u.fail("base64url: '{c}' at position {d} is standard-alphabet; use op base64", .{ c, i });
            if (!url and (c == '-' or c == '_')) return u.fail("base64: '{c}' at position {d} is url-safe alphabet; use op base64url", .{ c, i });
            return u.fail("base64: invalid character '{c}' at position {d}", .{ c, i });
        };
        acc = (acc << 6) | v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            try out.append(a, @intCast((acc >> bits) & 0xff));
        }
    }
    // leftover bits: 6 bits (1 char) can never be valid; nonzero trailing bits are sloppy but tolerated only if zero
    if (bits >= 6) return u.fail("base64: truncated input (dangling single character)", .{});
    if (bits > 0 and (acc & ((@as(u32, 1) << bits) - 1)) != 0) return u.fail("base64: non-zero trailing bits (corrupt or truncated)", .{});
    return out.toOwnedSlice(a);
}

const entities = [_]struct { []const u8, []const u8 }{
    .{ "amp", "&" },        .{ "lt", "<" },          .{ "gt", ">" },
    .{ "quot", "\"" },      .{ "apos", "'" },        .{ "nbsp", "\u{a0}" },
    .{ "copy", "\u{a9}" },  .{ "reg", "\u{ae}" },    .{ "hellip", "\u{2026}" },
    .{ "mdash", "\u{2014}" }, .{ "ndash", "\u{2013}" }, .{ "euro", "\u{20ac}" },
    .{ "lsquo", "\u{2018}" }, .{ "rsquo", "\u{2019}" }, .{ "ldquo", "\u{201c}" },
    .{ "rdquo", "\u{201d}" }, .{ "trade", "\u{2122}" }, .{ "times", "\u{d7}" },
};

fn lookupEntity(name: []const u8) ?[]const u8 {
    for (entities) |e| if (std.mem.eql(u8, e[0], name)) return e[1];
    return null;
}

fn htmlDecode(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '&') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, ';')) |semi| {
                const name = text[i + 1 .. semi];
                if (name.len > 0 and name.len <= 10) {
                    if (name[0] == '#') {
                        const cp: ?u21 = blk: {
                            const n = if (name.len > 1 and (name[1] == 'x' or name[1] == 'X'))
                                std.fmt.parseInt(u32, name[2..], 16) catch break :blk null
                            else
                                std.fmt.parseInt(u32, name[1..], 10) catch break :blk null;
                            if (n > 0x10ffff or (n >= 0xd800 and n < 0xe000)) break :blk null;
                            break :blk @intCast(n);
                        };
                        if (cp) |c| {
                            var b: [4]u8 = undefined;
                            const n = std.unicode.utf8Encode(c, &b) catch unreachable;
                            try w.writeAll(b[0..n]);
                            i = semi + 1;
                            continue;
                        }
                    } else {
                        if (lookupEntity(name)) |rep| {
                            try w.writeAll(rep);
                            i = semi + 1;
                            continue;
                        }
                    }
                }
            }
        }
        try w.writeByte(text[i]);
        i += 1;
    }
}

// ------------------------------------------------------------------- tests

fn t(op: Op, enc: bool, s: []const u8, want: []const u8) !void {
    const got = try convert(std.testing.allocator, op, enc, s);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}

fn tErr(op: Op, enc: bool, s: []const u8, needle: []const u8) !void {
    if (convert(std.testing.allocator, op, enc, s)) |got| {
        std.testing.allocator.free(got);
        return error.ExpectedFailure;
    } else |e| {
        try std.testing.expect(e == error.Fail);
        try std.testing.expect(std.mem.indexOf(u8, u.lastError(), needle) != null);
    }
}

test "base64 RFC 4648 vectors" {
    const v = [_][2][]const u8{ .{ "", "" }, .{ "f", "Zg==" }, .{ "fo", "Zm8=" }, .{ "foo", "Zm9v" }, .{ "foob", "Zm9vYg==" }, .{ "fooba", "Zm9vYmE=" }, .{ "foobar", "Zm9vYmFy" } };
    for (v) |p| {
        try t(.base64, true, p[0], p[1]);
        try t(.base64, false, p[1], p[0]);
    }
    try t(.base64, false, "Zm9v\nYmFy", "foobar"); // whitespace ignored
    try t(.base64, false, "Zg", "f"); // missing padding tolerated
}

test "base64 edge cases" {
    try tErr(.base64, false, "Zm9v!", "invalid character");
    try tErr(.base64, false, "Z", "truncated");
    try tErr(.base64, false, "Zh==", "trailing bits");
    try tErr(.base64, false, "Zg==Zg", "after '='");
    try tErr(.base64, false, "-_-_", "base64url");
    try t(.base64, true, "\xfb\xff", "+/8="); // standard alphabet
    try t(.base64url, true, "\xfb\xff", "-_8"); // url-safe, no padding
    try t(.base64url, false, "-_8", "(not valid UTF-8; 2 bytes as hex) fbff");
    try tErr(.base64url, false, "+/8=", "standard-alphabet");
    try t(.base64, true, "h\u{e9}llo \u{1f600}", "aMOpbGxvIPCfmIA=");
}

test "hex" {
    try t(.hex, true, "Hello", "48656c6c6f");
    try t(.hex, false, "48 65:6C 6c,6f", "Hello");
    try t(.hex, false, "0x48 0x69", "Hi");
    try tErr(.hex, false, "abc", "odd");
    try tErr(.hex, false, "zz", "invalid character");
    try t(.hex, true, "", "");
}

test "url percent encoding" {
    try t(.url, true, "a b&c=d/é~-._", "a%20b%26c%3Dd%2F%C3%A9~-._");
    try t(.url, false, "a%20b%26c%3Dd%2F%C3%A9+x", "a b&c=d/é+x"); // '+' literal
    try tErr(.url, false, "100%", "truncated");
    try tErr(.url, false, "%zz", "invalid %-escape");
    try tErr(.url, false, "%4", "truncated");
    try t(.url, false, "%FF", "(not valid UTF-8; 1 bytes as hex) ff");
}

test "html entities" {
    try t(.html, true, "<a href=\"x\">'&'</a>", "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;");
    try t(.html, false, "&lt;b&gt; &amp;amp; &#65;&#x42;&#x1F600; &copy; &bogus; & x;", "<b> &amp; AB\u{1f600} \u{a9} &bogus; & x;");
    try t(.html, false, "&#xD800; &#99999999;", "&#xD800; &#99999999;");
}

test "utf8-bytes" {
    try t(.@"utf8-bytes", true, "a\u{20ac}", "61 e2 82 ac (4 bytes, 2 code points)");
    try t(.@"utf8-bytes", false, "e2 82 ac", "\u{20ac}");
    try tErr(.@"utf8-bytes", false, "e2 82", "invalid UTF-8");
    try tErr(.@"utf8-bytes", false, "ff", "invalid UTF-8");
}
