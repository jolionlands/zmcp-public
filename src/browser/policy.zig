//! Navigation URL policy for browser_navigate.
//!
//! Only http, https and about:blank are allowed. Loopback / private / link
//! local / intranet-style hosts are refused unless allow_local is set. An
//! optional origin allowlist restricts navigation further. The host parser
//! follows the WHATWG URL rules Chrome uses (decimal/hex/octal/short IPv4,
//! trailing dots, IPv6 incl. v4-mapped) so `http://2130706433/`,
//! `http://0x7f.1/` and `http://[::ffff:127.0.0.1]/` cannot sneak past.
//!
//! Limits (documented in the tool README): this checks the URL we are asked
//! to load and the URL the tab ends up at; DNS rebinding (a public name that
//! resolves to a private address) is not detected.

const std = @import("std");
const Io = std.Io;

pub const Policy = struct {
    allow_local: bool = false,
    /// Entries: "https://host[:port]", "host", or "*.suffix".
    allow_origins: []const []const u8 = &.{},
};

/// Returns null when `url` may be navigated to, else a static reason.
pub fn check(p: Policy, url_in: []const u8) ?[]const u8 {
    const url = std.mem.trim(u8, url_in, " \t\r\n");
    if (url.len == 0) return "empty URL";
    for (url) |c| if (c <= 0x20 or c == 0x7f) return "URL must not contain spaces or control characters (percent-encode them)";
    if (std.ascii.eqlIgnoreCase(url, "about:blank")) return null;

    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return "URL needs a scheme (http, https or about:blank)";
    const scheme = url[0..colon];
    if (scheme.len == 0) return "URL needs a scheme (http, https or about:blank)";
    for (scheme) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return "malformed URL scheme";
    }
    const is_https = std.ascii.eqlIgnoreCase(scheme, "https");
    if (!is_https and !std.ascii.eqlIgnoreCase(scheme, "http")) {
        return "blocked scheme: only http, https and about:blank are allowed (file:, chrome:, devtools:, view-source:, data:, javascript: etc. are refused)";
    }
    const rest = url[colon + 1 ..];
    if (!std.mem.startsWith(u8, rest, "//")) return "malformed URL: expected http(s)://host";
    const after = rest[2..];
    const auth_end = std.mem.indexOfAny(u8, after, "/\\?#") orelse after.len;
    const authority = after[0..auth_end];
    if (authority.len == 0) return "URL has no host";
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return "credentials in the URL (user@host) are not allowed";

    var host: []const u8 = undefined;
    var port_str: []const u8 = "";
    if (authority[0] == '[') {
        const rb = std.mem.indexOfScalar(u8, authority, ']') orelse return "malformed IPv6 host";
        host = authority[1..rb];
        const tail = authority[rb + 1 ..];
        if (tail.len > 0) {
            if (tail[0] != ':') return "malformed host";
            port_str = tail[1..];
        }
    } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |ci| {
        host = authority[0..ci];
        port_str = authority[ci + 1 ..];
    } else {
        host = authority;
    }
    var port: u16 = if (is_https) 443 else 80;
    if (port_str.len > 0) {
        port = std.fmt.parseInt(u16, port_str, 10) catch return "invalid port";
    }
    if (host.len == 0) return "URL has no host";
    if (host.len > 253) return "host too long";
    for (host) |c| {
        if (c >= 0x80) return "non-ASCII host not supported (use the punycode form)";
        if (c == '%') return "percent-encoded host not allowed";
    }
    var buf: [256]u8 = undefined;
    const lower = std.ascii.lowerString(&buf, host);
    var h: []const u8 = lower;
    if (h.len > 1 and h[h.len - 1] == '.') h = h[0 .. h.len - 1];
    if (h.len == 0) return "URL has no host";

    if (!p.allow_local) {
        if (localReason(h)) |r| return r;
    }
    if (p.allow_origins.len > 0) {
        var ok: bool = false;
        for (p.allow_origins) |o| {
            if (originMatches(o, is_https, h, port)) {
                ok = true;
                break;
            }
        }
        if (!ok) return "origin not in ZMCP_BROWSER_ALLOW_ORIGINS";
    }
    return null;
}

const LOCAL_MSG = "blocked: loopback/private/intranet host (set ZMCP_BROWSER_ALLOW_LOCAL=1 to allow)";

fn localReason(h: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, h, ':') != null) {
        const a = Io.net.Ip6Address.parse(h, 0) catch return "invalid IPv6 host";
        return if (isLocalV6(a.bytes)) LOCAL_MSG else null;
    }
    // Last label numeric => Chrome parses the whole host as IPv4 (or fails).
    const dot = std.mem.lastIndexOfScalar(u8, h, '.');
    const last = if (dot) |d| h[d + 1 ..] else h;
    if (endsInNumber(last)) {
        const v4 = parseIpv4(h) orelse return "invalid IPv4 host";
        return if (isLocalV4(v4)) LOCAL_MSG else null;
    }
    if (dot == null) return LOCAL_MSG; // single-label name: intranet
    const suffixes = [_][]const u8{ ".localhost", ".local", ".internal", ".localdomain", ".lan", ".home.arpa", ".intranet", ".corp", ".private" };
    for (suffixes) |s| if (std.mem.endsWith(u8, h, s)) return LOCAL_MSG;
    return null;
}

fn endsInNumber(label: []const u8) bool {
    if (label.len == 0) return false;
    if (label.len > 2 and label[0] == '0' and (label[1] == 'x' or label[1] == 'X')) {
        for (label[2..]) |c| if (!std.ascii.isHex(c)) return false;
        return true;
    }
    if (label.len == 2 and label[0] == '0' and (label[1] == 'x' or label[1] == 'X')) return true;
    for (label) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn parsePart(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var base: u8 = 10;
    var t = s;
    if (t.len >= 2 and t[0] == '0' and (t[1] == 'x' or t[1] == 'X')) {
        base = 16;
        t = t[2..];
    } else if (t.len >= 2 and t[0] == '0') {
        base = 8;
        t = t[1..];
    }
    if (t.len == 0) return 0;
    return std.fmt.parseInt(u64, t, base) catch null;
}

/// WHATWG IPv4 parser (1-4 parts, each decimal / 0x hex / 0 octal).
pub fn parseIpv4(h: []const u8) ?u32 {
    var parts: [4][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, h, '.');
    while (it.next()) |p| {
        if (n == 4) return null;
        parts[n] = p;
        n += 1;
    }
    if (n == 0) return null;
    var nums: [4]u64 = undefined;
    for (parts[0..n], 0..) |p, i| nums[i] = parsePart(p) orelse return null;
    for (nums[0 .. n - 1]) |v| if (v > 255) return null;
    const last = nums[n - 1];
    const limit = std.math.pow(u64, 256, 5 - n);
    if (last >= limit) return null;
    var ip: u64 = last;
    for (nums[0 .. n - 1], 0..) |v, i| ip += v * std.math.pow(u64, 256, 3 - i);
    return @intCast(ip);
}

fn isLocalV4(ip: u32) bool {
    const a: u8 = @intCast(ip >> 24);
    const b: u8 = @intCast((ip >> 16) & 0xff);
    const c: u8 = @intCast((ip >> 8) & 0xff);
    if (a == 0 or a == 10 or a == 127) return true;
    if (a == 100 and b >= 64 and b <= 127) return true; // CGNAT
    if (a == 169 and b == 254) return true; // link-local + cloud metadata
    if (a == 172 and b >= 16 and b <= 31) return true;
    if (a == 192 and b == 0 and c == 0) return true;
    if (a == 192 and b == 168) return true;
    if (a == 198 and (b == 18 or b == 19)) return true;
    if (a >= 224) return true; // multicast, reserved, broadcast
    return false;
}

fn isLocalV6(b: [16]u8) bool {
    var all_zero_prefix: bool = true;
    for (b[0..10]) |x| {
        if (x != 0) all_zero_prefix = false;
    }
    // ::, ::1, IPv4-compatible (::a.b.c.d) and IPv4-mapped (::ffff:a.b.c.d)
    if (all_zero_prefix and ((b[10] == 0 and b[11] == 0) or (b[10] == 0xff and b[11] == 0xff))) {
        if (b[10] == 0xff) return isLocalV4(std.mem.readInt(u32, b[12..16], .big));
        return true;
    }
    // NAT64 64:ff9b::/96 embeds a v4 address.
    if (b[0] == 0x00 and b[1] == 0x64 and b[2] == 0xff and b[3] == 0x9b) {
        var z: bool = true;
        for (b[4..12]) |x| {
            if (x != 0) z = false;
        }
        if (z) return isLocalV4(std.mem.readInt(u32, b[12..16], .big));
    }
    if (b[0] & 0xfe == 0xfc) return true; // fc00::/7 unique local
    if (b[0] == 0xfe and b[1] & 0xc0 == 0x80) return true; // fe80::/10
    if (b[0] == 0xff) return true; // multicast
    if (b[0] == 0x20 and b[1] == 0x02) return true; // 6to4 can embed anything
    return false;
}

fn originMatches(entry_in: []const u8, is_https: bool, host: []const u8, port: u16) bool {
    const entry = std.mem.trim(u8, entry_in, " \t");
    if (entry.len == 0) return false;
    if (std.mem.indexOf(u8, entry, "://")) |si| {
        const es = entry[0..si];
        const want_https = std.ascii.eqlIgnoreCase(es, "https");
        if (!want_https and !std.ascii.eqlIgnoreCase(es, "http")) return false;
        if (want_https != is_https) return false;
        var hp = entry[si + 3 ..];
        if (std.mem.indexOfScalar(u8, hp, '/')) |sl| hp = hp[0..sl];
        var eh = hp;
        var eport: u16 = if (want_https) 443 else 80;
        if (std.mem.lastIndexOfScalar(u8, hp, ':')) |ci| {
            eh = hp[0..ci];
            eport = std.fmt.parseInt(u16, hp[ci + 1 ..], 10) catch return false;
        }
        return eport == port and hostMatches(eh, host);
    }
    return hostMatches(entry, host);
}

fn hostMatches(pattern: []const u8, host: []const u8) bool {
    if (std.mem.startsWith(u8, pattern, "*.")) {
        const suffix = pattern[1..]; // ".example.com"
        return host.len > suffix.len and std.ascii.endsWithIgnoreCase(host, suffix);
    }
    return std.ascii.eqlIgnoreCase(pattern, host);
}

/// Split a comma-separated origin list (slices into `csv`; caller frees the
/// returned slice).
pub fn parseOrigins(alloc: std.mem.Allocator, csv: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    var it = std.mem.tokenizeAny(u8, csv, ", \t");
    while (it.next()) |t| try out.append(alloc, t);
    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectBlocked(p: Policy, url: []const u8) !void {
    if (check(p, url) == null) {
        std.debug.print("expected blocked: {s}\n", .{url});
        return error.TestExpectedBlocked;
    }
}
fn expectAllowed(p: Policy, url: []const u8) !void {
    if (check(p, url)) |r| {
        std.debug.print("expected allowed: {s} (got: {s})\n", .{ url, r });
        return error.TestExpectedAllowed;
    }
}

test "schemes: only http, https, about:blank" {
    const p: Policy = .{};
    try expectAllowed(p, "https://example.com/");
    try expectAllowed(p, "http://example.com:8080/a?b#c");
    try expectAllowed(p, "HTTPS://Example.COM");
    try expectAllowed(p, "about:blank");
    for ([_][]const u8{
        "file:///etc/passwd",           "chrome://settings",       "chrome-untrusted://x",
        "devtools://devtools/bundled/", "view-source:https://a.b", "data:text/html,<h1>x</h1>",
        "javascript:alert(1)",          "blob:https://a.b/x",      "ftp://a.b/",
        "about:srcdoc",                 "about:blank#x",           "ws://a.b/",
        "",                             "example.com",             "//example.com",
        "http:example.com",             "http://",                 "java\nscript:alert(1)",
        "chrome-extension://abc/x",     "filesystem:https://a.b/x",
    }) |u| try expectBlocked(p, u);
}

test "loopback and private hosts blocked by default" {
    const p: Policy = .{};
    for ([_][]const u8{
        "http://localhost/",              "http://LOCALHOST:3000/",        "http://localhost./",
        "http://foo.localhost/",          "http://127.0.0.1/",             "http://127.1/",
        "http://2130706433/",             "http://0x7f000001/",            "http://0x7f.0.0.1/",
        "http://0177.0.0.1/",             "http://017700000001/",          "http://0/",
        "http://10.0.0.5/",               "http://172.16.0.1/",            "http://172.31.255.255/",
        "http://192.168.1.1/",            "http://169.254.169.254/latest", "http://100.64.0.1/",
        "http://[::1]/",                  "http://[::]/",                  "http://[::ffff:127.0.0.1]/",
        "http://[::ffff:7f00:1]/",        "http://[fe80::1]/",             "http://[fd00::1]/",
        "http://[64:ff9b::7f00:1]/",      "http://router/",                "http://metadata.google.internal/",
        "http://printer.local/",          "http://1.2.3.4.5/",             "http://256.1.1.1/",
        "http://user:pw@example.com/",    "http://exa%6Dple.com/",         "http://\xef\xbc\x91\xef\xbc\x92\xef\xbc\x97.0.0.1/",
        "http://example.com:99999/",      "http://224.0.0.1/",             "http://[::ffff:10.0.0.1]/",
        "http://0300.0250.0.1/",
    }) |u| try expectBlocked(p, u);
}

test "public hosts allowed" {
    const p: Policy = .{};
    for ([_][]const u8{
        "http://example.com/",   "https://93.184.216.34/", "http://8.8.8.8/",
        "https://a.b.c.example.org:8443/x", "http://172.32.0.1/", "http://172.15.255.255/",
        "http://[2606:4700:4700::1111]/", "http://100.63.255.255/", "http://11.0.0.1/",
    }) |u| try expectAllowed(p, u);
}

test "ALLOW_LOCAL lifts the local block but not the scheme block" {
    const p: Policy = .{ .allow_local = true };
    try expectAllowed(p, "http://127.0.0.1:8000/");
    try expectAllowed(p, "http://localhost:3000/");
    try expectAllowed(p, "http://[::1]/");
    try expectBlocked(p, "file:///etc/passwd");
    try expectBlocked(p, "http://user@127.0.0.1/");
}

test "origin allowlist" {
    const origins = [_][]const u8{ "https://example.com", "docs.example.org", "*.cdn.net", "http://app.test:3000" };
    const p: Policy = .{ .allow_origins = &origins };
    try expectAllowed(p, "https://example.com/path");
    try expectBlocked(p, "http://example.com/"); // scheme differs
    try expectBlocked(p, "https://example.com:8443/"); // port differs
    try expectAllowed(p, "https://docs.example.org/");
    try expectAllowed(p, "http://docs.example.org/");
    try expectAllowed(p, "https://a.cdn.net/");
    try expectBlocked(p, "https://cdn.net/");
    try expectBlocked(p, "https://evilcdn.net/");
    try expectBlocked(p, "https://other.com/");
    try expectAllowed(p, "http://app.test:3000/");
    try expectBlocked(p, "http://app.test:3001/");
    try expectAllowed(p, "about:blank");
}

test "parseOrigins splits on commas and spaces" {
    const o = try parseOrigins(testing.allocator, "https://a.com, b.com ,*.c.com");
    defer testing.allocator.free(o);
    try testing.expectEqual(@as(usize, 3), o.len);
    try testing.expectEqualStrings("b.com", o[1]);
}

test "parseIpv4 forms" {
    try testing.expectEqual(@as(?u32, 0x7f000001), parseIpv4("127.0.0.1"));
    try testing.expectEqual(@as(?u32, 0x7f000001), parseIpv4("127.1"));
    try testing.expectEqual(@as(?u32, 0x7f000001), parseIpv4("0x7f.1"));
    try testing.expectEqual(@as(?u32, 0xffffffff), parseIpv4("4294967295"));
    try testing.expectEqual(@as(?u32, null), parseIpv4("4294967296"));
    try testing.expectEqual(@as(?u32, null), parseIpv4("1.2.3.4.5"));
    try testing.expectEqual(@as(?u32, null), parseIpv4("1..2"));
}
