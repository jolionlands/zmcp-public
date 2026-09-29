//! Connection handling for zmcp-postgres.
//!
//! DATABASE_URL (URI or `key=value` DSN) is translated into the PG* environment
//! variables that psql/libpq honour, so the password and the rest of the DSN
//! never appear in argv (`ps`) or in psql's own error text. Everything here is
//! pure (no I/O) and unit tested.

const std = @import("std");

pub const EnvPair = struct { key: []const u8, value: []const u8 };

pub const Parsed = struct {
    /// PG* variables to set for the child (never contains PGOPTIONS; see `options`).
    pairs: []const EnvPair,
    /// `options` (libpq) value from the DSN, merged into PGOPTIONS by the caller.
    options: ?[]const u8 = null,
    /// The password, kept only so it can be scrubbed from error text.
    password: ?[]const u8 = null,
};

pub const ParseResult = union(enum) {
    ok: Parsed,
    /// Message that never contains the DSN's values (only key names).
    err: []const u8,
};

const KeyMap = struct { key: []const u8, env: []const u8 };

const key_map = [_]KeyMap{
    .{ .key = "host", .env = "PGHOST" },
    .{ .key = "hostaddr", .env = "PGHOSTADDR" },
    .{ .key = "port", .env = "PGPORT" },
    .{ .key = "dbname", .env = "PGDATABASE" },
    .{ .key = "user", .env = "PGUSER" },
    .{ .key = "password", .env = "PGPASSWORD" },
    .{ .key = "passfile", .env = "PGPASSFILE" },
    .{ .key = "channel_binding", .env = "PGCHANNELBINDING" },
    .{ .key = "connect_timeout", .env = "PGCONNECT_TIMEOUT" },
    .{ .key = "sslmode", .env = "PGSSLMODE" },
    .{ .key = "sslcert", .env = "PGSSLCERT" },
    .{ .key = "sslkey", .env = "PGSSLKEY" },
    .{ .key = "sslrootcert", .env = "PGSSLROOTCERT" },
    .{ .key = "sslcrl", .env = "PGSSLCRL" },
    .{ .key = "sslsni", .env = "PGSSLSNI" },
    .{ .key = "requirepeer", .env = "PGREQUIREPEER" },
    .{ .key = "krbsrvname", .env = "PGKRBSRVNAME" },
    .{ .key = "gsslib", .env = "PGGSSLIB" },
    .{ .key = "gssencmode", .env = "PGGSSENCMODE" },
    .{ .key = "target_session_attrs", .env = "PGTARGETSESSIONATTRS" },
    .{ .key = "service", .env = "PGSERVICE" },
    .{ .key = "application_name", .env = "PGAPPNAME" },
};

fn envFor(key: []const u8) ?[]const u8 {
    for (key_map) |m| if (std.mem.eql(u8, m.key, key)) return m.env;
    return null;
}

const Builder = struct {
    alloc: std.mem.Allocator,
    pairs: std.ArrayList(EnvPair) = .empty,
    options: ?[]const u8 = null,
    password: ?[]const u8 = null,
    bad_key: ?[]const u8 = null,

    /// Later settings override earlier ones for the same variable.
    fn set(self: *Builder, key: []const u8, value: []const u8) !void {
        if (std.mem.eql(u8, key, "options")) {
            self.options = value;
            return;
        }
        const env = envFor(key) orelse {
            self.bad_key = key;
            return error.UnknownKey;
        };
        if (std.mem.eql(u8, env, "PGPASSWORD")) self.password = value;
        for (self.pairs.items) |*p| {
            if (std.mem.eql(u8, p.key, env)) {
                p.value = value;
                return;
            }
        }
        try self.pairs.append(self.alloc, .{ .key = env, .value = value });
    }
};

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Percent-decode; null on a malformed escape or a decoded NUL.
pub fn percentDecode(alloc: std.mem.Allocator, s: []const u8) !?[]u8 {
    var out = try std.ArrayList(u8).initCapacity(alloc, s.len);
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%') {
            if (i + 2 >= s.len) {
                out.deinit(alloc);
                return null;
            }
            const hi = hexVal(s[i + 1]) orelse {
                out.deinit(alloc);
                return null;
            };
            const lo = hexVal(s[i + 2]) orelse {
                out.deinit(alloc);
                return null;
            };
            const b = hi * 16 + lo;
            if (b == 0) {
                out.deinit(alloc);
                return null;
            }
            try out.append(alloc, b);
            i += 2;
        } else try out.append(alloc, s[i]);
    }
    return try out.toOwnedSlice(alloc);
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

/// Translate a libpq connection string (URI or key=value) into env pairs.
pub fn parseDsn(alloc: std.mem.Allocator, dsn_raw: []const u8) !ParseResult {
    const dsn = std.mem.trim(u8, dsn_raw, " \t\r\n");
    if (dsn.len == 0) return .{ .err = "DATABASE_URL is empty" };
    var b: Builder = .{ .alloc = alloc };
    const r = if (startsWithIgnoreCase(dsn, "postgresql://") or startsWithIgnoreCase(dsn, "postgres://"))
        parseUri(alloc, &b, dsn)
    else
        parseKeyValue(alloc, &b, dsn);
    r catch |err| switch (err) {
        error.UnknownKey => return .{ .err = try std.fmt.allocPrint(alloc, "unsupported connection parameter '{s}' in DATABASE_URL", .{b.bad_key orelse "?"}) },
        error.BadDsn => return .{ .err = "DATABASE_URL is not a valid PostgreSQL URI or key=value connection string" },
        else => return err,
    };
    return .{ .ok = .{
        .pairs = try b.pairs.toOwnedSlice(alloc),
        .options = b.options,
        .password = b.password,
    } };
}

fn dec(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    return (try percentDecode(alloc, s)) orelse error.BadDsn;
}

fn parseUri(alloc: std.mem.Allocator, b: *Builder, dsn: []const u8) !void {
    const scheme_len: usize = if (startsWithIgnoreCase(dsn, "postgresql://")) 13 else 11;
    var rest = dsn[scheme_len..];
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '?')) |q| {
        query = rest[q + 1 ..];
        rest = rest[0..q];
    }
    var path: []const u8 = "";
    var authority = rest;
    if (std.mem.indexOfScalar(u8, rest, '/')) |s| {
        authority = rest[0..s];
        path = rest[s + 1 ..];
    }
    var hostports = authority;
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| {
        const userinfo = authority[0..at];
        hostports = authority[at + 1 ..];
        var user = userinfo;
        var pass: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, userinfo, ':')) |c| {
            user = userinfo[0..c];
            pass = userinfo[c + 1 ..];
        }
        if (user.len > 0) try b.set("user", try dec(alloc, user));
        if (pass) |p| if (p.len > 0) try b.set("password", try dec(alloc, p));
    }
    if (hostports.len > 0) {
        var hosts: std.ArrayList(u8) = .empty;
        var ports: std.ArrayList(u8) = .empty;
        var any_port = false;
        var it = std.mem.splitScalar(u8, hostports, ',');
        var first = true;
        while (it.next()) |hp| {
            var host: []const u8 = hp;
            var port: []const u8 = "";
            if (hp.len > 0 and hp[0] == '[') {
                const close = std.mem.indexOfScalar(u8, hp, ']') orelse return error.BadDsn;
                host = hp[1..close];
                const after = hp[close + 1 ..];
                if (after.len > 0) {
                    if (after[0] != ':') return error.BadDsn;
                    port = after[1..];
                }
            } else if (std.mem.lastIndexOfScalar(u8, hp, ':')) |c| {
                host = hp[0..c];
                port = hp[c + 1 ..];
            }
            if (!first) {
                try hosts.append(alloc, ',');
                try ports.append(alloc, ',');
            }
            first = false;
            try hosts.appendSlice(alloc, try dec(alloc, host));
            if (port.len > 0) any_port = true;
            try ports.appendSlice(alloc, try dec(alloc, port));
        }
        if (hosts.items.len > 0 and !allCommas(hosts.items)) try b.set("host", try hosts.toOwnedSlice(alloc));
        if (any_port) try b.set("port", try ports.toOwnedSlice(alloc));
    }
    if (path.len > 0) try b.set("dbname", try dec(alloc, path));

    var qit = std.mem.splitScalar(u8, query, '&');
    while (qit.next()) |kv| {
        if (kv.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return error.BadDsn;
        const k = try dec(alloc, kv[0..eq]);
        const v = try dec(alloc, kv[eq + 1 ..]);
        try b.set(k, v);
    }
}

fn allCommas(s: []const u8) bool {
    for (s) |c| if (c != ',') return false;
    return true;
}

fn parseKeyValue(alloc: std.mem.Allocator, b: *Builder, dsn: []const u8) !void {
    var i: usize = 0;
    while (true) {
        while (i < dsn.len and std.ascii.isWhitespace(dsn[i])) i += 1;
        if (i >= dsn.len) return;
        const k0 = i;
        while (i < dsn.len and dsn[i] != '=' and !std.ascii.isWhitespace(dsn[i])) i += 1;
        const key = dsn[k0..i];
        while (i < dsn.len and std.ascii.isWhitespace(dsn[i])) i += 1;
        if (key.len == 0 or i >= dsn.len or dsn[i] != '=') return error.BadDsn;
        i += 1;
        while (i < dsn.len and std.ascii.isWhitespace(dsn[i])) i += 1;
        var val: std.ArrayList(u8) = .empty;
        if (i < dsn.len and dsn[i] == '\'') {
            i += 1;
            while (true) {
                if (i >= dsn.len) return error.BadDsn;
                const c = dsn[i];
                if (c == '\\' and i + 1 < dsn.len) {
                    try val.append(alloc, dsn[i + 1]);
                    i += 2;
                } else if (c == '\'') {
                    i += 1;
                    break;
                } else {
                    try val.append(alloc, c);
                    i += 1;
                }
            }
        } else {
            while (i < dsn.len and !std.ascii.isWhitespace(dsn[i])) {
                if (dsn[i] == '\\' and i + 1 < dsn.len) {
                    try val.append(alloc, dsn[i + 1]);
                    i += 2;
                } else {
                    try val.append(alloc, dsn[i]);
                    i += 1;
                }
            }
        }
        try b.set(key, try val.toOwnedSlice(alloc));
    }
}

// ---------------------------------------------------------------------------
// PGOPTIONS
// ---------------------------------------------------------------------------

/// PGOPTIONS for the child: any options from the environment/DSN first, then
/// ours (later `-c` wins), so neither can loosen the guarantees below.
pub fn buildPgOptions(alloc: std.mem.Allocator, user_options: ?[]const u8, read_only: bool, statement_timeout_ms: u32) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (user_options) |u| {
        const t = std.mem.trim(u8, u, " \t\r\n");
        if (t.len > 0) {
            try out.appendSlice(alloc, t);
            try out.append(alloc, ' ');
        }
    }
    try out.print(alloc, "-c default_transaction_read_only={s} -c statement_timeout={d} -c standard_conforming_strings=on -c application_name=zmcp-postgres", .{
        if (read_only) "on" else "off",
        statement_timeout_ms,
    });
    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Redaction
// ---------------------------------------------------------------------------

/// Remove secrets from text that may echo them: every occurrence of each
/// non-empty `secrets` entry, and the userinfo part of any `scheme://user:pw@`.
pub fn redact(alloc: std.mem.Allocator, text: []const u8, secrets: []const []const u8) ![]const u8 {
    var cur: []const u8 = text;
    for (secrets) |s| {
        if (s.len == 0) continue;
        if (std.mem.indexOf(u8, cur, s) == null) continue;
        cur = try std.mem.replaceOwned(u8, alloc, cur, s, "***");
    }
    // strip userinfo in URLs
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < cur.len) {
        if (std.mem.startsWith(u8, cur[i..], "://")) {
            try out.appendSlice(alloc, "://");
            i += 3;
            var j = i;
            while (j < cur.len and cur[j] != '@' and cur[j] != '/' and cur[j] != '?' and !std.ascii.isWhitespace(cur[j]) and cur[j] != '"' and cur[j] != '\'') j += 1;
            if (j < cur.len and cur[j] == '@') {
                try out.appendSlice(alloc, "***@");
                i = j + 1;
            }
            continue;
        }
        try out.append(alloc, cur[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn pairVal(p: Parsed, key: []const u8) ?[]const u8 {
    for (p.pairs) |kv| if (std.mem.eql(u8, kv.key, key)) return kv.value;
    return null;
}

test "parse URI with user, password, port, db and params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseDsn(arena.allocator(), "postgresql://bob:s%40cr%3At@db.example.com:6543/my%20db?sslmode=require&application_name=x&options=-c%20search_path%3Dfoo");
    const p = r.ok;
    try std.testing.expectEqualStrings("bob", pairVal(p, "PGUSER").?);
    try std.testing.expectEqualStrings("s@cr:t", pairVal(p, "PGPASSWORD").?);
    try std.testing.expectEqualStrings("s@cr:t", p.password.?);
    try std.testing.expectEqualStrings("db.example.com", pairVal(p, "PGHOST").?);
    try std.testing.expectEqualStrings("6543", pairVal(p, "PGPORT").?);
    try std.testing.expectEqualStrings("my db", pairVal(p, "PGDATABASE").?);
    try std.testing.expectEqualStrings("require", pairVal(p, "PGSSLMODE").?);
    try std.testing.expectEqualStrings("x", pairVal(p, "PGAPPNAME").?);
    try std.testing.expectEqualStrings("-c search_path=foo", p.options.?);
}

test "parse URI variants: ipv6, multi-host, socket dir, no auth, postgres scheme" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v6 = (try parseDsn(a, "postgres://u@[::1]:5433/d")).ok;
    try std.testing.expectEqualStrings("::1", pairVal(v6, "PGHOST").?);
    try std.testing.expectEqualStrings("5433", pairVal(v6, "PGPORT").?);
    try std.testing.expect(v6.password == null);
    const multi = (try parseDsn(a, "postgresql://h1:1,h2:2/d")).ok;
    try std.testing.expectEqualStrings("h1,h2", pairVal(multi, "PGHOST").?);
    try std.testing.expectEqualStrings("1,2", pairVal(multi, "PGPORT").?);
    const sock = (try parseDsn(a, "postgresql:///d?host=%2Fvar%2Frun%2Fpostgresql&port=5433")).ok;
    try std.testing.expectEqualStrings("/var/run/postgresql", pairVal(sock, "PGHOST").?);
    try std.testing.expectEqualStrings("d", pairVal(sock, "PGDATABASE").?);
    const bare = (try parseDsn(a, "postgresql://")).ok;
    try std.testing.expectEqual(@as(usize, 0), bare.pairs.len);
}

test "parse key=value DSN with quotes and escapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = (try parseDsn(arena.allocator(), "host=localhost port = 5432 dbname='my db' user=u password='p\\'w d'")).ok;
    try std.testing.expectEqualStrings("localhost", pairVal(r, "PGHOST").?);
    try std.testing.expectEqualStrings("5432", pairVal(r, "PGPORT").?);
    try std.testing.expectEqualStrings("my db", pairVal(r, "PGDATABASE").?);
    try std.testing.expectEqualStrings("p'w d", pairVal(r, "PGPASSWORD").?);
}

test "bad and unknown DSNs give value-free errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = try parseDsn(a, "postgresql://u:hunter2@h/d?bogus=hunter2");
    try std.testing.expect(u == .err);
    try std.testing.expect(std.mem.indexOf(u8, u.err, "bogus") != null);
    try std.testing.expect(std.mem.indexOf(u8, u.err, "hunter2") == null);
    const bad = try parseDsn(a, "postgresql://u:hunter2@h/d?x");
    try std.testing.expect(bad == .err);
    try std.testing.expect(std.mem.indexOf(u8, bad.err, "hunter2") == null);
    const bad2 = try parseDsn(a, "postgresql://u:%zz@h/d");
    try std.testing.expect(bad2 == .err);
    const bad3 = try parseDsn(a, "just some words");
    try std.testing.expect(bad3 == .err);
    try std.testing.expect((try parseDsn(a, "   ")) == .err);
    const kv = try parseDsn(a, "host=h password=hunter2 nonsense=1");
    try std.testing.expect(kv == .err);
    try std.testing.expect(std.mem.indexOf(u8, kv.err, "hunter2") == null);
}

test "percentDecode rejects truncated escapes and NUL" {
    const a = std.testing.allocator;
    try std.testing.expect((try percentDecode(a, "%")) == null);
    try std.testing.expect((try percentDecode(a, "a%4")) == null);
    try std.testing.expect((try percentDecode(a, "%00")) == null);
    const ok = (try percentDecode(a, "a%2Fb")).?;
    defer a.free(ok);
    try std.testing.expectEqualStrings("a/b", ok);
}

test "PGOPTIONS puts ours last" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ro = try buildPgOptions(a, "-c default_transaction_read_only=off", true, 30000);
    try std.testing.expect(std.mem.indexOf(u8, ro, "off").? < std.mem.lastIndexOf(u8, ro, "default_transaction_read_only=on").?);
    try std.testing.expect(std.mem.endsWith(u8, ro, "application_name=zmcp-postgres"));
    try std.testing.expect(std.mem.indexOf(u8, ro, "statement_timeout=30000") != null);
    const rw = try buildPgOptions(a, null, false, 5);
    try std.testing.expect(std.mem.startsWith(u8, rw, "-c default_transaction_read_only=off "));
}

test "redact scrubs passwords and URL userinfo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t1 = try redact(a, "connection to postgresql://bob:hunter2@h:5432/d failed: password hunter2 wrong", &.{"hunter2"});
    try std.testing.expect(std.mem.indexOf(u8, t1, "hunter2") == null);
    try std.testing.expect(std.mem.indexOf(u8, t1, "bob") == null);
    try std.testing.expect(std.mem.indexOf(u8, t1, "@h:5432/d") != null);
    const t2 = try redact(a, "see https://example.com/x and postgres://u:p@host/db", &.{""});
    try std.testing.expectEqualStrings("see https://example.com/x and postgres://***@host/db", t2);
}
