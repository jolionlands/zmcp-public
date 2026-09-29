//! Pure helpers for the LSP bridge: Content-Length framing, file:// URIs,
//! and 1-based character <-> 0-based UTF-16 position conversion. No I/O.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------- framing

pub const MAX_BODY: usize = 64 * 1024 * 1024;
const MAX_HEADER: usize = 16 * 1024;

pub const FrameError = error{ BadHeader, MissingContentLength, TooLarge, OutOfMemory };

/// Incremental Content-Length frame reader. Feed it arbitrary byte chunks;
/// `next` yields complete message bodies. Headers are case-insensitive, any
/// number of them may precede the blank line (Content-Type is ignored).
pub const Framer = struct {
    alloc: Allocator,
    buf: std.ArrayList(u8) = .empty,
    start: usize = 0,

    pub fn init(alloc: Allocator) Framer {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Framer) void {
        self.buf.deinit(self.alloc);
    }

    pub fn feed(self: *Framer, bytes: []const u8) !void {
        if (self.start > 0 and self.start == self.buf.items.len) {
            self.buf.clearRetainingCapacity();
            self.start = 0;
        } else if (self.start > 64 * 1024) {
            const rest = self.buf.items.len - self.start;
            std.mem.copyForwards(u8, self.buf.items[0..rest], self.buf.items[self.start..]);
            self.buf.shrinkRetainingCapacity(rest);
            self.start = 0;
        }
        try self.buf.appendSlice(self.alloc, bytes);
    }

    /// Next complete body, or null when more bytes are needed. The slice is
    /// valid until the next `feed`/`next` call.
    pub fn next(self: *Framer) FrameError!?[]const u8 {
        const avail = self.buf.items[self.start..];
        const sep = std.mem.indexOf(u8, avail, "\r\n\r\n") orelse {
            if (avail.len > MAX_HEADER) return error.BadHeader;
            return null;
        };
        if (sep > MAX_HEADER) return error.BadHeader;
        var content_length: ?usize = null;
        var lines = std.mem.splitSequence(u8, avail[0..sep], "\r\n");
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadHeader;
            const name = std.mem.trim(u8, line[0..colon], " \t");
            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                const v = std.mem.trim(u8, line[colon + 1 ..], " \t");
                content_length = std.fmt.parseInt(usize, v, 10) catch return error.BadHeader;
            }
        }
        const len = content_length orelse return error.MissingContentLength;
        if (len > MAX_BODY) return error.TooLarge;
        const body_start = sep + 4;
        if (avail.len < body_start + len) return null;
        const body = avail[body_start .. body_start + len];
        self.start += body_start + len;
        return body;
    }
};

/// `Content-Length: N\r\n\r\n` + body, as one owned buffer.
pub fn frame(alloc: Allocator, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
}

// ---------------------------------------------------------------- URIs

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

/// Absolute filesystem path -> `file://` URI (percent-encoded UTF-8).
pub fn pathToUri(alloc: Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "file://");
    var rest = path;
    const drive = path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':';
    if (drive) {
        try out.append(alloc, '/');
        try out.append(alloc, path[0]);
        try out.append(alloc, ':');
        rest = path[2..];
    } else if (path.len == 0 or (path[0] != '/' and path[0] != '\\')) {
        return error.NotAbsolute;
    }
    for (rest) |c| {
        if (isUnreserved(c) or c == '/') {
            try out.append(alloc, c);
        } else if (c == '\\' and drive) {
            try out.append(alloc, '/');
        } else {
            try out.print(alloc, "%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice(alloc);
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// `file://` URI -> path. Returns null for non-file schemes or bad escapes.
/// A leading `/C:/` becomes `C:/` (and backslashes on Windows targets).
pub fn uriToPath(alloc: Allocator, uri: []const u8) !?[]u8 {
    const prefix = "file://";
    if (uri.len < prefix.len or !std.ascii.eqlIgnoreCase(uri[0..prefix.len], prefix)) return null;
    var rest = uri[prefix.len..];
    // Authority: empty or localhost; anything else is a remote host.
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const auth = rest[0..slash];
    if (auth.len != 0 and !std.ascii.eqlIgnoreCase(auth, "localhost")) return null;
    rest = rest[slash..];
    var out: std.ArrayList(u8) = .empty;
    var ok = false;
    defer if (!ok) out.deinit(alloc);
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const c = rest[i];
        if (c == '%') {
            if (i + 2 >= rest.len) return null;
            const hi = hexVal(rest[i + 1]) orelse return null;
            const lo = hexVal(rest[i + 2]) orelse return null;
            try out.append(alloc, hi * 16 + lo);
            i += 2;
        } else if (c == '#' or c == '?') {
            break; // fragment/query are not part of the path
        } else {
            try out.append(alloc, c);
        }
    }
    const items = out.items;
    if (items.len >= 3 and items[0] == '/' and std.ascii.isAlphabetic(items[1]) and items[2] == ':') {
        std.mem.copyForwards(u8, items[0 .. items.len - 1], items[1..]);
        out.shrinkRetainingCapacity(items.len - 1);
        if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, out.items, '/', '\\');
    }
    const owned = try out.toOwnedSlice(alloc);
    ok = true;
    return owned;
}

// ---------------------------------------------------------------- positions

fn seqLen(first: u8, rest: []const u8) struct { len: usize, cp: u21 } {
    // Decode one UTF-8 sequence; invalid bytes count as one U+FFFD of length 1.
    const n = std.unicode.utf8ByteSequenceLength(first) catch return .{ .len = 1, .cp = 0xFFFD };
    if (n > rest.len) return .{ .len = 1, .cp = 0xFFFD };
    const cp = std.unicode.utf8Decode(rest[0..n]) catch return .{ .len = 1, .cp = 0xFFFD };
    return .{ .len = n, .cp = cp };
}

/// 0-based code point column -> 0-based UTF-16 code unit column. A column past
/// the end of the line clamps to the line's UTF-16 length.
pub fn cpToUtf16(line: []const u8, cp_col: usize) u32 {
    var i: usize = 0;
    var cps: usize = 0;
    var units: u32 = 0;
    while (i < line.len and cps < cp_col) {
        const s = seqLen(line[i], line[i..]);
        units += if (s.cp >= 0x10000) 2 else 1;
        i += s.len;
        cps += 1;
    }
    return units;
}

/// 0-based UTF-16 column -> 0-based byte offset in `line` (clamped to len).
/// A column that lands inside a surrogate pair rounds up to the next character.
pub fn utf16ToByte(line: []const u8, col16: usize) usize {
    var i: usize = 0;
    var units: usize = 0;
    while (i < line.len and units < col16) {
        const s = seqLen(line[i], line[i..]);
        units += if (s.cp >= 0x10000) 2 else 1;
        i += s.len;
    }
    return i;
}

/// 0-based UTF-16 column -> 0-based code point column.
pub fn utf16ToCp(line: []const u8, col16: usize) usize {
    var i: usize = 0;
    var units: usize = 0;
    var cps: usize = 0;
    while (i < line.len and units < col16) {
        const s = seqLen(line[i], line[i..]);
        units += if (s.cp >= 0x10000) 2 else 1;
        i += s.len;
        cps += 1;
    }
    // Past the end of the line: keep counting virtual columns 1:1.
    if (units < col16) cps += col16 - units;
    return cps;
}

/// Text of 0-based `line_no` without its line terminator, or null if past EOF.
pub fn lineAt(text: []const u8, line_no: usize) ?[]const u8 {
    var start: usize = 0;
    var n: usize = 0;
    while (true) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n');
        const end = nl orelse text.len;
        if (n == line_no) {
            var l = text[start..end];
            if (l.len > 0 and l[l.len - 1] == '\r') l = l[0 .. l.len - 1];
            return l;
        }
        if (nl == null) return null;
        start = end + 1;
        n += 1;
    }
}

/// Byte offset of the start of 0-based `line_no` (text.len if it is the empty
/// line after a trailing newline); null past EOF.
pub fn lineStart(text: []const u8, line_no: usize) ?usize {
    var start: usize = 0;
    var n: usize = 0;
    while (n < line_no) : (n += 1) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return null;
        start = nl + 1;
    }
    return start;
}

/// LSP (line, utf16 character) -> byte offset into `text`.
pub fn lspToOffset(text: []const u8, line: usize, col16: usize) ?usize {
    const ls = lineStart(text, line) orelse return null;
    const l = lineAt(text, line) orelse return null;
    return ls + utf16ToByte(l, col16);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "framer: single, multi-header, case-insensitive, split reads" {
    var f = Framer.init(testing.allocator);
    defer f.deinit();
    const msg = "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\ncontent-length: 7\r\n\r\n{\"a\":1}" ++
        "Content-Length: 2\r\n\r\n{}";
    // Feed one byte at a time.
    var got: usize = 0;
    for (msg) |b| {
        try f.feed(&.{b});
        while (try f.next()) |body| {
            if (got == 0) try testing.expectEqualStrings("{\"a\":1}", body) else try testing.expectEqualStrings("{}", body);
            got += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), got);
}

test "framer: two frames in one chunk, partial body, errors" {
    var f = Framer.init(testing.allocator);
    defer f.deinit();
    try f.feed("Content-Length: 3\r\n\r\nabcContent-Length: 4\r\n\r\nde");
    try testing.expectEqualStrings("abc", (try f.next()).?);
    try testing.expect((try f.next()) == null);
    try f.feed("fg");
    try testing.expectEqualStrings("defg", (try f.next()).?);
    try testing.expect((try f.next()) == null);

    var g = Framer.init(testing.allocator);
    defer g.deinit();
    try g.feed("Content-Type: x\r\n\r\n");
    try testing.expectError(error.MissingContentLength, g.next());
    var h = Framer.init(testing.allocator);
    defer h.deinit();
    try h.feed("Content-Length: nope\r\n\r\n");
    try testing.expectError(error.BadHeader, h.next());
    var k = Framer.init(testing.allocator);
    defer k.deinit();
    try k.feed("Content-Length: 99999999999\r\n\r\n");
    try testing.expectError(error.TooLarge, k.next());
}

test "frame writes byte length not char count" {
    const out = try frame(testing.allocator, "{\"s\":\"\xc3\xa9\"}");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Content-Length: 10\r\n\r\n{\"s\":\"\xc3\xa9\"}", out);
}

test "uri round trip with spaces, unicode and reserved chars" {
    const p = "/tmp/my dir/caf\xc3\xa9 #1?.zig";
    const uri = try pathToUri(testing.allocator, p);
    defer testing.allocator.free(uri);
    try testing.expectEqualStrings("file:///tmp/my%20dir/caf%C3%A9%20%231%3F.zig", uri);
    const back = (try uriToPath(testing.allocator, uri)).?;
    defer testing.allocator.free(back);
    try testing.expectEqualStrings(p, back);
}

test "uri decode: localhost, drive letters, lower-case hex, rejects" {
    const a = (try uriToPath(testing.allocator, "file://localhost/a/b%2fc")).?;
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("/a/b/c", a);
    if (builtin.os.tag != .windows) {
        const w = (try uriToPath(testing.allocator, "file:///C:/x/y.zig")).?;
        defer testing.allocator.free(w);
        try testing.expectEqualStrings("C:/x/y.zig", w);
    }
    try testing.expect((try uriToPath(testing.allocator, "http://x/y")) == null);
    try testing.expect((try uriToPath(testing.allocator, "file://host/y")) == null);
    try testing.expect((try uriToPath(testing.allocator, "file:///a%zz")) == null);
    try testing.expect((try uriToPath(testing.allocator, "file:///a%2")) == null);
    try testing.expectError(error.NotAbsolute, pathToUri(testing.allocator, "rel/path"));
    const d = try pathToUri(testing.allocator, "C:\\Users\\me\\a b.zig");
    defer testing.allocator.free(d);
    try testing.expectEqualStrings("file:///C:/Users/me/a%20b.zig", d);
}

test "utf16 conversion: ascii, 2-byte, 3-byte, astral" {
    const line = "a\xc3\xa9\xe4\xb8\xad\xf0\x9f\x98\x80z"; // a é 中 😀 z
    // code point cols: a0 é1 中2 😀3 z4 end5
    try testing.expectEqual(@as(u32, 0), cpToUtf16(line, 0));
    try testing.expectEqual(@as(u32, 1), cpToUtf16(line, 1));
    try testing.expectEqual(@as(u32, 3), cpToUtf16(line, 3));
    try testing.expectEqual(@as(u32, 5), cpToUtf16(line, 4)); // after the surrogate pair
    try testing.expectEqual(@as(u32, 6), cpToUtf16(line, 5));
    try testing.expectEqual(@as(u32, 6), cpToUtf16(line, 99)); // clamp
    // utf16 -> byte offsets
    try testing.expectEqual(@as(usize, 0), utf16ToByte(line, 0));
    try testing.expectEqual(@as(usize, 1), utf16ToByte(line, 1));
    try testing.expectEqual(@as(usize, 3), utf16ToByte(line, 2));
    try testing.expectEqual(@as(usize, 6), utf16ToByte(line, 3));
    try testing.expectEqual(@as(usize, 10), utf16ToByte(line, 5));
    try testing.expectEqual(@as(usize, 11), utf16ToByte(line, 6));
    // utf16 -> cp
    try testing.expectEqual(@as(usize, 4), utf16ToCp(line, 5));
    try testing.expectEqual(@as(usize, 5), utf16ToCp(line, 6));
    try testing.expectEqual(@as(usize, 3), utf16ToCp(line, 3));
}

test "invalid utf-8 counts one column per byte" {
    try testing.expectEqual(@as(u32, 2), cpToUtf16("\xff\xfe\xfd", 2));
    try testing.expectEqual(@as(usize, 2), utf16ToByte("\xff\xfe\xfd", 2));
}

test "lineAt, lineStart, lspToOffset handle CRLF and trailing newline" {
    const t = "one\r\ntw\xc3\xa9o\nlast";
    try testing.expectEqualStrings("one", lineAt(t, 0).?);
    try testing.expectEqualStrings("tw\xc3\xa9o", lineAt(t, 1).?);
    try testing.expectEqualStrings("last", lineAt(t, 2).?);
    try testing.expect(lineAt(t, 3) == null);
    try testing.expectEqual(@as(usize, 5), lineStart(t, 1).?);
    try testing.expectEqual(@as(usize, 5 + 4), lspToOffset(t, 1, 3).?); // after "twé"
    try testing.expectEqual(@as(usize, 0), lineStart("x", 0).?);
    try testing.expect(lineStart("x", 1) == null);
    try testing.expectEqualStrings("", lineAt("a\n", 1).?);
}
