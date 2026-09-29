//! Result post-processing for zmcp-aws: secret redaction, ResponseMetadata
//! removal, list truncation and the 64 KiB output cap. Pure (no I/O).

const std = @import("std");

pub const REDACTED = "[REDACTED]";
pub const MAX_OUTPUT: usize = 64 * 1024;

/// Key names (normalised: lowercase, no `_ - . space`) whose string values are
/// always redacted (substring match).
const secret_key_parts = [_][]const u8{
    "secretaccesskey", "secretstring",       "secretbinary", "sessiontoken", "securitytoken",
    "accesskeyid",     "privatekey",         "keymaterial",  "clientsecret", "secretkey",
    "apikey",          "authorizationtoken", "accesstoken",  "idtoken",      "refreshtoken",
    "authtoken",       "bearertoken",        "userdata",     "sharedsecret", "passwd",
};
/// Exact normalised key names that are redacted.
const secret_key_exact = [_][]const u8{ "secret", "token", "pwd", "signature" };
/// `password` keys are redacted unless the key ends with one of these
/// (timestamps/flags/policy metadata, not values).
const password_benign_suffix = [_][]const u8{ "lastused", "lastchanged", "lastset", "enabled", "required", "policy", "length", "age", "count", "reuseprevention" };

/// Sibling-pair rule: an object with a name-like key whose text looks secret has
/// its value-like key redacted (ECS/CodeBuild env vars, tags, CFN params).
const name_keys = [_][]const u8{ "name", "key", "parameterkey" };
const value_keys = [_][]const u8{ "value", "parametervalue" };
const secret_name_parts = [_][]const u8{ "secret", "password", "passwd", "token", "apikey", "privatekey", "credential", "accesskey" };

fn normKey(buf: []u8, key: []const u8) ?[]const u8 {
    if (key.len > buf.len) return null;
    var n: usize = 0;
    for (key) |c| {
        if (c == '_' or c == '-' or c == '.' or c == ' ') continue;
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    return buf[0..n];
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// True when a string value under `key` must be redacted.
pub fn isSecretKey(key: []const u8) bool {
    var buf: [128]u8 = undefined;
    const k = normKey(&buf, key) orelse return false;
    for (secret_key_exact) |e| if (std.mem.eql(u8, k, e)) return true;
    for (secret_key_parts) |p| if (contains(k, p)) return true;
    if (contains(k, "password")) {
        for (password_benign_suffix) |s| if (std.mem.endsWith(u8, k, s)) return false;
        return true;
    }
    return false;
}

fn nameLooksSecret(name: []const u8) bool {
    var buf: [128]u8 = undefined;
    const k = normKey(&buf, name) orelse return false;
    for (secret_name_parts) |p| if (contains(k, p)) return true;
    return false;
}

fn eqAny(list: []const []const u8, k: []const u8) bool {
    var buf: [64]u8 = undefined;
    const n = normKey(&buf, k) orelse return false;
    for (list) |l| if (std.mem.eql(u8, l, n)) return true;
    return false;
}

fn isValueEnd(c: u8) bool {
    return switch (c) {
        '&', '"', ' ', '\'', '\n', '\r', '\t', ';', ',', '<', '>', ')' => true,
        else => false,
    };
}

const scrub_needles = [_][]const u8{
    "X-Amz-Signature=", "X-Amz-Security-Token=", "Signature=", "AWSAccessKeyId=", "X-Amz-Credential=",
    "access_token=",    "api_key=",              "apikey=",    "token=",          "password=",
    "passwd=",          "secret=",               "sig=",       "Bearer ",         "Authorization: Basic ",
};

fn hasPrivateKeyMarker(s: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(s, "PRIVATE KEY-----") != null or
        std.ascii.indexOfIgnoreCase(s, "PRIVATE KEY BLOCK-----") != null;
}

/// Replace the password in `user:pass@host` userinfo (with or without a scheme).
fn scrubUserinfo(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var cur = s;
    var from: usize = 0;
    while (std.mem.indexOfScalarPos(u8, cur, from, '@')) |at| {
        from = at + 1;
        var ts = at;
        while (ts > 0) : (ts -= 1) {
            const c = cur[ts - 1];
            if (c == '/' or c == '"' or c == '\'' or c == '<' or c == '>' or c == '=' or c == ',' or c == ' ' or c == '\n' or c == '\r' or c == '\t' or c == '(') break;
        }
        const tok = cur[ts..at];
        const colon = std.mem.indexOfScalar(u8, tok, ':') orelse continue;
        const pstart = ts + colon + 1;
        if (pstart >= at) continue; // empty password
        if (at + 1 >= cur.len or isValueEnd(cur[at + 1])) continue; // no host
        if (std.mem.eql(u8, cur[pstart..at], REDACTED)) continue;
        cur = try std.mem.concat(alloc, u8, &.{ cur[0..pstart], REDACTED, cur[at..] });
        from = pstart + REDACTED.len + 1;
    }
    return cur;
}

/// Replace values of secret-looking query parameters / key=value pairs, bearer
/// tokens, URL userinfo passwords and PEM private keys in a free-form string.
/// Returns the input unchanged (same pointer) when clean.
pub fn scrubString(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (s.len < 8) return s;
    if (hasPrivateKeyMarker(s)) return REDACTED;
    var cur: []const u8 = s;
    for (scrub_needles) |n| {
        var from: usize = 0;
        while (std.ascii.indexOfIgnoreCasePos(cur, from, n)) |i| {
            const vstart = i + n.len;
            var vend = vstart;
            while (vend < cur.len and !isValueEnd(cur[vend])) vend += 1;
            if (vend == vstart or std.mem.eql(u8, cur[vstart..vend], REDACTED)) {
                from = vend;
                continue;
            }
            cur = try std.mem.concat(alloc, u8, &.{ cur[0..vstart], REDACTED, cur[vend..] });
            from = vstart + REDACTED.len;
        }
    }
    return scrubUserinfo(alloc, cur);
}

fn isUpperAlnum(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
}
fn isB64(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '/' or c == '+' or c == '=';
}

fn labelBefore(text: []const u8, end: usize) bool {
    const lo = end -| 40;
    var line_start = lo;
    if (std.mem.lastIndexOfScalar(u8, text[lo..end], '\n')) |nl| line_start = lo + nl + 1;
    const win = text[line_start..end];
    for ([_][]const u8{ "secret", "key", "token", "credential", "password" }) |l| {
        if (std.ascii.indexOfIgnoreCase(win, l) != null) return true;
    }
    return false;
}

/// Scrub free-form (non-JSON) CLI text: everything `scrubString` does, plus
/// AKIA/ASIA access key ids and 40-char base64-ish secret access keys that sit
/// next to a key-name-like label. Heuristic, best effort.
pub fn scrubText(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    const base = try scrubString(alloc, s);
    if (std.mem.eql(u8, base, REDACTED)) return base;
    var out: std.ArrayList(u8) = .empty;
    var changed = false;
    var i: usize = 0;
    while (i < base.len) {
        // AKIA/ASIA + 16 [0-9A-Z]
        if (i + 20 <= base.len and (std.mem.startsWith(u8, base[i..], "AKIA") or std.mem.startsWith(u8, base[i..], "ASIA")) and
            (i == 0 or !std.ascii.isAlphanumeric(base[i - 1])))
        {
            var ok = true;
            for (base[i + 4 .. i + 20]) |c| if (!isUpperAlnum(c)) {
                ok = false;
                break;
            };
            if (ok and (i + 20 == base.len or !std.ascii.isAlphanumeric(base[i + 20]))) {
                try out.appendSlice(alloc, REDACTED);
                changed = true;
                i += 20;
                continue;
            }
        }
        // exactly-40-char base64-ish run after a key-ish label
        if (isB64(base[i]) and (i == 0 or !isB64(base[i - 1]))) {
            var e = i;
            while (e < base.len and isB64(base[e])) e += 1;
            if (e - i == 40 and labelBefore(base, i)) {
                try out.appendSlice(alloc, REDACTED);
                changed = true;
                i = e;
                continue;
            }
            try out.appendSlice(alloc, base[i..e]);
            i = e;
            continue;
        }
        try out.append(alloc, base[i]);
        i += 1;
    }
    if (!changed) return base;
    return out.items;
}

fn redactStrings(v: *std.json.Value, depth: usize) usize {
    if (depth > 64) return 0;
    var n: usize = 0;
    switch (v.*) {
        .string => |s| if (s.len > 0) {
            v.* = .{ .string = REDACTED };
            n += 1;
        },
        .array => |*arr| for (arr.items) |*x| {
            n += redactStrings(x, depth + 1);
        },
        .object => |*obj| {
            var it = obj.iterator();
            while (it.next()) |e| n += redactStrings(e.value_ptr, depth + 1);
        },
        else => {},
    }
    return n;
}

/// Redact in place. Returns the number of redactions.
pub fn redactValue(alloc: std.mem.Allocator, v: *std.json.Value, depth: usize) !usize {
    if (depth > 64) return 0;
    var count: usize = 0;
    switch (v.*) {
        .string => |s| {
            const t = try scrubString(alloc, s);
            if (t.ptr != s.ptr) {
                v.* = .{ .string = t };
                count += 1;
            }
        },
        .array => |*arr| for (arr.items) |*x| {
            count += try redactValue(alloc, x, depth + 1);
        },
        .object => |*obj| {
            // Name/value pair rule.
            var secret_pair = false;
            {
                var it = obj.iterator();
                while (it.next()) |e| {
                    if (e.value_ptr.* == .string and eqAny(&name_keys, e.key_ptr.*) and nameLooksSecret(e.value_ptr.string)) secret_pair = true;
                }
            }
            var it = obj.iterator();
            while (it.next()) |e| {
                const val = e.value_ptr;
                const key = e.key_ptr.*;
                if (val.* == .string and val.string.len > 0) {
                    if (isSecretKey(key) or (secret_pair and eqAny(&value_keys, key))) {
                        val.* = .{ .string = REDACTED };
                        count += 1;
                        continue;
                    }
                }
                // Secret-named object (e.g. UserData: {Value: ...}): hide its strings.
                if (val.* == .object and isSecretKey(key)) {
                    count += redactStrings(val, 0);
                    continue;
                }
                // Lambda-style environment maps: hide every value.
                if (val.* == .object and std.ascii.eqlIgnoreCase(key, "Variables")) {
                    var vit = val.object.iterator();
                    while (vit.next()) |ve| {
                        if (ve.value_ptr.* == .string) {
                            ve.value_ptr.* = .{ .string = REDACTED };
                            count += 1;
                        }
                    }
                    continue;
                }
                count += try redactValue(alloc, val, depth + 1);
            }
        },
        else => {},
    }
    return count;
}

/// Keep the first `n` items of every array longer than `n`, appending a marker.
/// Returns how many arrays were shortened.
fn truncateArrays(alloc: std.mem.Allocator, v: *std.json.Value, n: usize, depth: usize) !usize {
    if (depth > 64) return 0;
    var cut: usize = 0;
    switch (v.*) {
        .array => |*arr| {
            if (arr.items.len > n + 1) {
                const more = arr.items.len - n;
                arr.shrinkRetainingCapacity(n);
                try arr.append(.{ .string = try std.fmt.allocPrint(alloc, "[+{d} more items omitted]", .{more}) });
                cut += 1;
            }
            for (arr.items[0..@min(arr.items.len, n)]) |*x| cut += try truncateArrays(alloc, x, n, depth + 1);
        },
        .object => |*obj| {
            var it = obj.iterator();
            while (it.next()) |e| cut += try truncateArrays(alloc, e.value_ptr, n, depth + 1);
        },
        else => {},
    }
    return cut;
}

const token_keys = [_][]const u8{ "NextToken", "nextToken", "NextMarker", "Marker", "NextContinuationToken", "NextPageToken", "LastEvaluatedKey", "NextPageMarker" };

pub const Compacted = struct {
    text: []const u8,
    redactions: usize = 0,
    truncated_lists: usize = 0,
    hard_cut: bool = false,
};

fn capText(alloc: std.mem.Allocator, s: []const u8, cap: usize) !struct { []const u8, bool } {
    if (s.len <= cap) return .{ s, false };
    var end = cap;
    // do not split a UTF-8 sequence
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return .{ try alloc.dupe(u8, s[0..end]), true };
}

/// Compact CLI JSON output: drop ResponseMetadata, redact, shorten long lists
/// until it fits `cap`. Non-JSON input is scrubbed and cut at `cap`.
pub fn compactOutput(alloc: std.mem.Allocator, raw: []const u8, cap: usize) !Compacted {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    var parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, trimmed, .{}) catch {
        const scrubbed = try scrubText(alloc, trimmed);
        const c = try capText(alloc, scrubbed, cap);
        return .{ .text = c[0], .hard_cut = c[1] };
    };
    var redactions: usize = 0;
    if (parsed == .object) _ = parsed.object.orderedRemove("ResponseMetadata");
    redactions += try redactValue(alloc, &parsed, 0);

    var text: []const u8 = try std.json.Stringify.valueAlloc(alloc, parsed, .{});
    var cut: usize = 0;
    if (text.len > cap) {
        const steps = [_]usize{ 100, 50, 20, 10, 5, 3, 1 };
        for (steps) |n| {
            cut += try truncateArrays(alloc, &parsed, n, 0);
            text = try std.json.Stringify.valueAlloc(alloc, parsed, .{});
            if (text.len <= cap) break;
        }
    }
    var hard = false;
    if (text.len > cap) {
        const c = try capText(alloc, text, cap);
        text = c[0];
        hard = c[1];
    }
    return .{ .text = text, .redactions = redactions, .truncated_lists = cut, .hard_cut = hard };
}

/// If a JSON result carries a continuation token at top level, describe how to
/// continue. Returns null when there is none.
pub fn pagingHint(alloc: std.mem.Allocator, json_text: []const u8, used_max_items: bool) !?[]const u8 {
    if (std.mem.indexOf(u8, json_text, "Token\"") == null and std.mem.indexOf(u8, json_text, "Marker\"") == null and std.mem.indexOf(u8, json_text, "LastEvaluatedKey") == null) return null;
    const p = std.json.parseFromSliceLeaky(std.json.Value, alloc, json_text, .{}) catch return null;
    if (p != .object) return null;
    for (token_keys) |k| {
        const v = p.object.get(k) orelse continue;
        if (v == .null) continue;
        if (used_max_items and std.mem.eql(u8, k, "NextToken")) {
            return try std.fmt.allocPrint(alloc, "more results: repeat the call with params {{\"starting-token\":\"{s}\"}} (same max_items).", .{if (v == .string) v.string else "<NextToken>"});
        }
        return try std.fmt.allocPrint(alloc, "more results: {s} is set; pass it back as the matching param (e.g. next-token/marker/exclusive-start-key), or raise max_items.", .{k});
    }
    return null;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn arenaTest() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

test "isSecretKey matches secret-like names, not benign ones" {
    const yes = [_][]const u8{ "SecretAccessKey", "AccessKeyId", "SessionToken", "Password", "MasterUserPassword", "PrivateKey", "secret_access_key", "SecretString", "KeyMaterial", "UserData", "ClientSecret", "api-key", "Secret", "Token", "AuthorizationToken", "DBPassword", "PRIVATE_KEY", "session-token", "refreshToken" };
    for (yes) |k| try testing.expect(isSecretKey(k));
    const no = [_][]const u8{ "NextToken", "SecretList", "SecretName", "PasswordLastUsed", "PasswordPolicy", "MinimumPasswordLength", "HasPassword", "PasswordResetRequired", "InstanceId", "Name", "Arn", "Tokens", "KeyId", "KeyName", "AccessKeyLastUsed", "PasswordReusePrevention" };
    for (no) |k| {
        // HasPassword is a bool in practice; only strings are ever redacted.
        if (std.mem.eql(u8, k, "HasPassword")) continue;
        try testing.expect(!isSecretKey(k));
    }
}

test "redactValue redacts nested keys, arrays, env pairs and Lambda Variables" {
    var arena = arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\{"Credentials":{"AccessKeyId":"AKIAXXXXXXXXXXXXXXXX","SecretAccessKey":"wJalr","SessionToken":"FQoG","Expiration":"2030"},
        \\ "Users":[{"UserName":"bob","PasswordLastUsed":"2024","Password":"hunter2"}],
        \\ "Environment":{"Variables":{"DB":"postgres://u:p@h/db","X":"y"}},
        \\ "environment":[{"name":"DB_PASSWORD","value":"abc"},{"name":"REGION","value":"eu"}],
        \\ "Code":{"Location":"https://x.s3.amazonaws.com/f.zip?X-Amz-Signature=abcdef&X-Amz-Expires=600"},
        \\ "Key":"-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----",
        \\ "Count":3}
    ;
    var v = try std.json.parseFromSliceLeaky(std.json.Value, a, src, .{});
    const n = try redactValue(a, &v, 0);
    try testing.expect(n >= 9);
    const out = try std.json.Stringify.valueAlloc(a, v, .{});
    for ([_][]const u8{ "AKIAXXXX", "wJalr", "FQoG", "hunter2", "postgres://", "\"abc\"", "abcdef", "MIIE" }) |bad|
        try testing.expect(!contains(out, bad));
    for ([_][]const u8{ "bob", "2024", "\"eu\"", "X-Amz-Expires=600", "\"Count\":3", "2030" }) |good|
        try testing.expect(contains(out, good));
}

test "scrubString handles presigned URLs and leaves clean strings alone" {
    var arena = arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    const clean = "arn:aws:s3:::bucket/key=value-ok-long";
    try testing.expectEqual(clean.ptr, (try scrubString(a, clean)).ptr);
    const u = try scrubString(a, "https://h/p?a=1&x-amz-signature=DEADBEEF&X-Amz-Security-Token=TOK123&b=2");
    try testing.expectEqualStrings("https://h/p?a=1&x-amz-signature=[REDACTED]&X-Amz-Security-Token=[REDACTED]&b=2", u);
    try testing.expectEqualStrings(REDACTED, try scrubString(a, "-----BEGIN PRIVATE KEY-----\nabc"));
}

test "scrubString works without '=' : userinfo and bearer" {
    var arena = arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("postgres://admin:[REDACTED]@host/db", try scrubString(a, "postgres://admin:pw@host/db"));
    try testing.expectEqualStrings("admin:[REDACTED]@host:5432", try scrubString(a, "admin:secretpw@host:5432"));
    try testing.expectEqualStrings("Authorization: Bearer [REDACTED]", try scrubString(a, "Authorization: Bearer abc.def.ghi"));
    try testing.expectEqualStrings("Authorization: Basic [REDACTED]", try scrubString(a, "Authorization: Basic dXNlcjpwdw=="));
    // password containing '@'
    const r = try scrubString(a, "mysql://u:p@ss@db.local/x");
    try testing.expect(!contains(r, "p@ss") and !contains(r, ":ss") and contains(r, "db.local"));
    // benign: no password, email-ish, timestamps
    const c1 = "https://user@example.com/path/long";
    try testing.expectEqual(c1.ptr, (try scrubString(a, c1)).ptr);
    const c2 = "contact bob@example.com for details";
    try testing.expectEqual(c2.ptr, (try scrubString(a, c2)).ptr);
}

test "scrubString new needles are case-insensitive" {
    var arena = arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "GET /x?access_token=abc123&z=1", "GET /x?access_token=[REDACTED]&z=1" },
        .{ "curl ?API_KEY=k1 done", "curl ?API_KEY=[REDACTED] done" },
        .{ "cfg apikey=k2;other=1", "cfg apikey=[REDACTED];other=1" },
        .{ "a Token=zzz b", "a Token=[REDACTED] b" },
        .{ "db Password=hunter2 x", "db Password=[REDACTED] x" },
        .{ "db PASSWD=hunter2 x", "db PASSWD=[REDACTED] x" },
        .{ "the Secret=s3 x", "the Secret=[REDACTED] x" },
        .{ "https://h/p?sig=AbC&se=1", "https://h/p?sig=[REDACTED]&se=1" },
    };
    for (cases) |c| try testing.expectEqualStrings(c[1], try scrubString(a, c[0]));
    // idempotent
    const once = try scrubString(a, "x?token=abc&password=def zz");
    try testing.expectEqualStrings(once, try scrubString(a, once));
}

test "scrubString PEM needle is case-insensitive and matches PGP blocks" {
    var arena = arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(REDACTED, try scrubString(a, "-----begin rsa private key-----\nabc"));
    try testing.expectEqualStrings(REDACTED, try scrubString(a, "-----BEGIN PGP PRIVATE KEY BLOCK-----\nabc"));
}

test "compactOutput non-JSON fallback scrubs urls, key ids and secret keys" {
    var arena = arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    const c = try compactOutput(a, "endpoint postgres://admin:pw@host/db\nAccessKeyId     AKIAIOSFODNN7EXAMPLE\nTemp ASIAIOSFODNN7EXAMPLE ok\nSecretAccessKey wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\n", MAX_OUTPUT);
    for ([_][]const u8{ ":pw@", "AKIAIOSFODNN7", "ASIAIOSFODNN7", "wJalrXUtnFEMI" }) |bad| try testing.expect(!contains(c.text, bad));
    try testing.expect(contains(c.text, "host/db") and contains(c.text, "ok"));
    // 40-char run without a label is left alone; AKIA embedded in a longer word too
    const t = try compactOutput(a, "sha1 da39a3ee5e6b4b0d3255bfef95601890afd80709 done\nXAKIAIOSFODNN7EXAMPLE", MAX_OUTPUT);
    try testing.expect(contains(t.text, "da39a3ee5e6b4b0d3255bfef95601890afd80709") and contains(t.text, "XAKIA"));
}

test "compactOutput drops ResponseMetadata and redacts" {
    var arena = arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    const c = try compactOutput(a, "{\n \"ResponseMetadata\": {\"RequestId\": \"x\"},\n \"Account\": \"123\", \"SecretAccessKey\": \"zzz\"\n}\n", MAX_OUTPUT);
    try testing.expectEqualStrings("{\"Account\":\"123\",\"SecretAccessKey\":\"[REDACTED]\"}", c.text);
    try testing.expectEqual(@as(usize, 1), c.redactions);
}

test "compactOutput shortens long lists to fit and reports it" {
    var arena = arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    var sb: std.ArrayList(u8) = .empty;
    try sb.appendSlice(a, "{\"Items\":[");
    for (0..5000) |i| {
        if (i > 0) try sb.append(a, ',');
        try sb.print(a, "{{\"Id\":\"i-{d:0>8}\",\"Pad\":\"xxxxxxxxxxxxxxxxxxxxxxxx\"}}", .{i});
    }
    try sb.appendSlice(a, "]}");
    const c = try compactOutput(a, sb.items, MAX_OUTPUT);
    try testing.expect(c.text.len <= MAX_OUTPUT);
    try testing.expect(c.truncated_lists >= 1);
    try testing.expect(contains(c.text, "more items omitted"));
    try testing.expect(!c.hard_cut);
    // valid JSON still
    _ = try std.json.parseFromSliceLeaky(std.json.Value, a, c.text, .{});
}

test "compactOutput: non-JSON text is scrubbed and hard-capped" {
    var arena = arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    const big = try a.alloc(u8, MAX_OUTPUT + 500);
    @memset(big, 'k');
    const c = try compactOutput(a, big, MAX_OUTPUT);
    try testing.expect(c.hard_cut);
    try testing.expectEqual(MAX_OUTPUT, c.text.len);
    const t = try compactOutput(a, "2024-01-01 00:00:00 my-bucket\n", MAX_OUTPUT);
    try testing.expectEqualStrings("2024-01-01 00:00:00 my-bucket", t.text);
}

test "pagingHint explains how to continue" {
    var arena = arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    const h1 = (try pagingHint(a, "{\"Items\":[],\"NextToken\":\"abc123\"}", true)).?;
    try testing.expect(contains(h1, "starting-token") and contains(h1, "abc123"));
    const h2 = (try pagingHint(a, "{\"Items\":[],\"NextToken\":\"abc123\"}", false)).?;
    try testing.expect(contains(h2, "NextToken") and !contains(h2, "starting-token"));
    try testing.expect((try pagingHint(a, "{\"Items\":[]}", false)) == null);
}

test "compactOutput keeps numbers readable" {
    var arena = arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    const c = try compactOutput(a, "{\"i\":5,\"f\":0.5,\"z\":0.0,\"g\":1.0,\"e\":12.25,\"big\":12345678901234567890,\"n\":-3}", MAX_OUTPUT);
    try testing.expect(contains(c.text, "\"i\":5") and contains(c.text, "\"f\":0.5") and contains(c.text, "\"n\":-3"));
}
