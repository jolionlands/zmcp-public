//! Slices: named profiles (config file), ad-hoc `--servers` lists, name
//! validation with "did you mean" suggestions, and the glob/readonly rules
//! the gateway enforces on its own tool view.
//!
//! Config file: {"profiles": {"dev": {"servers": ["memory","git"],
//!   "tools_allow": ["git_*"], "tools_deny": ["git_reset"], "readonly": false}}}
//! Globs are exact names or a trailing `*` (same as ZMCP_TOOLS in mcp.zig).

const std = @import("std");
const mcp = @import("mcp");

/// A one-line error message buffer for user-facing startup errors.
pub const Diag = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *Diag, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.buf, fmt, args) catch self.buf[0..self.buf.len];
        self.len = s.len;
    }

    pub fn text(self: *const Diag) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Slice = struct {
    allow: []const []const u8 = &.{},
    deny: []const []const u8 = &.{},
    readonly: bool = false,

    pub fn isEmpty(self: Slice) bool {
        return self.allow.len == 0 and self.deny.len == 0 and !self.readonly;
    }
};

pub const Profile = struct {
    name: []const u8,
    /// Empty means "all servers".
    servers: []const []const u8 = &.{},
    slice: Slice = .{},
};

pub const Reason = enum {
    allow,
    deny,
    readonly,

    pub fn message(self: Reason) []const u8 {
        return switch (self) {
            .allow => "not in the profile's tools_allow",
            .deny => "denied by the profile's tools_deny",
            .readonly => "not marked read-only (readonly profile)",
        };
    }
};

fn matchesAny(patterns: []const []const u8, name: []const u8) bool {
    for (patterns) |p| if (mcp.globMatch(p, name)) return true;
    return false;
}

/// Why the slice hides `tool_name`, or null when it is exposed. Deny beats
/// allow; an allowlist hides everything it does not name; readonly hides
/// tools without annotations.readOnlyHint.
pub fn hiddenBy(sl: Slice, tool_name: []const u8, read_only: bool) ?Reason {
    if (matchesAny(sl.deny, tool_name)) return .deny;
    if (sl.allow.len > 0 and !matchesAny(sl.allow, tool_name)) return .allow;
    if (sl.readonly and !read_only) return .readonly;
    return null;
}

/// Valid server name: `[a-z0-9][a-z0-9_-]*`, at most 48 bytes. This is the
/// only thing ever placed after the "zmcp-" prefix of a binary name, so it
/// rules out path separators, dots and spaces.
pub fn validServerName(name: []const u8) bool {
    if (name.len == 0 or name.len > 48) return false;
    if (!(std.ascii.isLower(name[0]) or std.ascii.isDigit(name[0]))) return false;
    for (name) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_' or c == '-')) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Config parsing
// ---------------------------------------------------------------------------

pub const Config = struct {
    arena: *std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    profiles: []const Profile,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
        self.gpa.destroy(self.arena);
    }

    pub fn find(self: *const Config, name: []const u8) ?*const Profile {
        for (self.profiles) |*p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }
};

pub const ParseError = error{InvalidConfig} || std.mem.Allocator.Error;

fn stringList(a: std.mem.Allocator, v: ?std.json.Value, what: []const u8, prof: []const u8, diag: *Diag) ParseError![]const []const u8 {
    const x = v orelse return &.{};
    if (x != .array) {
        diag.set("profile '{s}': {s} must be an array of strings", .{ prof, what });
        return error.InvalidConfig;
    }
    var out: std.ArrayList([]const u8) = .empty;
    for (x.array.items) |it| {
        if (it != .string or it.string.len == 0) {
            diag.set("profile '{s}': {s} must be an array of non-empty strings", .{ prof, what });
            return error.InvalidConfig;
        }
        try out.append(a, it.string);
    }
    return out.items;
}

/// Parse and validate config text. Server names are checked for shape only
/// here; whether they exist is `resolveServers`' job (needs the catalog).
pub fn parseConfig(gpa: std.mem.Allocator, text: []const u8, diag: *Diag) ParseError!Config {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    var cfg: Config = .{ .arena = arena, .gpa = gpa, .profiles = &.{} };
    errdefer cfg.deinit();
    const a = arena.allocator();

    const root = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{ .allocate = .alloc_always }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diag.set("config is not valid JSON ({s})", .{@errorName(e)});
            return error.InvalidConfig;
        },
    };
    if (root != .object) {
        diag.set("config must be a JSON object with a \"profiles\" object", .{});
        return error.InvalidConfig;
    }
    const profs = root.object.get("profiles") orelse {
        diag.set("config has no \"profiles\" object", .{});
        return error.InvalidConfig;
    };
    if (profs != .object) {
        diag.set("\"profiles\" must be an object of name -> profile", .{});
        return error.InvalidConfig;
    }
    var list: std.ArrayList(Profile) = .empty;
    var it = profs.object.iterator();
    while (it.next()) |e| {
        const pname = e.key_ptr.*;
        const pv = e.value_ptr.*;
        if (pname.len == 0 or pname.len > 48 or std.mem.findAny(u8, pname, " \t\r\n/\\") != null) {
            diag.set("invalid profile name '{s}'", .{pname});
            return error.InvalidConfig;
        }
        if (pv != .object) {
            diag.set("profile '{s}' must be an object", .{pname});
            return error.InvalidConfig;
        }
        const servers = try stringList(a, pv.object.get("servers"), "servers", pname, diag);
        for (servers) |s| {
            if (!validServerName(s)) {
                diag.set("profile '{s}': invalid server name '{s}' (use lowercase letters, digits, - and _)", .{ pname, s });
                return error.InvalidConfig;
            }
        }
        var ro = false;
        if (pv.object.get("readonly")) |r| {
            if (r != .bool) {
                diag.set("profile '{s}': readonly must be true or false", .{pname});
                return error.InvalidConfig;
            }
            ro = r.bool;
        }
        try list.append(a, .{
            .name = pname,
            .servers = servers,
            .slice = .{
                .allow = try stringList(a, pv.object.get("tools_allow"), "tools_allow", pname, diag),
                .deny = try stringList(a, pv.object.get("tools_deny"), "tools_deny", pname, diag),
                .readonly = ro,
            },
        });
    }
    cfg.profiles = list.items;
    return cfg;
}

// ---------------------------------------------------------------------------
// Server-name resolution
// ---------------------------------------------------------------------------

fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len > 40 or b.len > 40) return @max(a.len, b.len);
    var prev: [41]usize = undefined;
    var cur: [41]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ca, i| {
        cur[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (ca == cb) 0 else 1;
            cur[j + 1] = @min(@min(cur[j] + 1, prev[j + 1] + 1), prev[j] + cost);
        }
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return prev[b.len];
}

/// Up to `out.len` known names closest to `name` (substring or small edit
/// distance), best first. Returns the count written.
pub fn closest(name: []const u8, known: []const []const u8, out: [][]const u8) usize {
    const Cand = struct { name: []const u8, score: usize };
    var cands: [64]Cand = undefined;
    var n: usize = 0;
    for (known) |k| {
        var score = editDistance(name, k);
        if (std.mem.indexOf(u8, k, name) != null or std.mem.indexOf(u8, name, k) != null) score = @min(score, 1);
        const limit = @max(@as(usize, 2), name.len / 3);
        if (score > limit) continue;
        if (n < cands.len) {
            cands[n] = .{ .name = k, .score = score };
            n += 1;
        }
    }
    std.mem.sort(Cand, cands[0..n], {}, struct {
        fn lt(_: void, x: Cand, y: Cand) bool {
            if (x.score != y.score) return x.score < y.score;
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);
    const m = @min(n, out.len);
    for (0..m) |i| out[i] = cands[i].name;
    return m;
}

pub const ResolveError = error{ UnknownServer, InvalidServerName } || std.mem.Allocator.Error;

/// Check every requested server against `known` (deduplicating, keeping
/// order). An empty request means all of `known`. On failure `diag` names
/// the bad entry and its closest matches.
pub fn resolveServers(
    a: std.mem.Allocator,
    requested: []const []const u8,
    known: []const []const u8,
    context: []const u8,
    diag: *Diag,
) ResolveError![]const []const u8 {
    if (requested.len == 0) return a.dupe([]const u8, known);
    var out: std.ArrayList([]const u8) = .empty;
    for (requested) |r| {
        if (!validServerName(r)) {
            diag.set("{s}: invalid server name '{s}'", .{ context, r });
            return error.InvalidServerName;
        }
        var found: ?[]const u8 = null;
        for (known) |k| {
            if (std.mem.eql(u8, k, r)) found = k;
        }
        const k = found orelse {
            var near: [3][]const u8 = undefined;
            const n = closest(r, known, &near);
            if (n == 0) {
                diag.set("{s}: unknown server '{s}' (run `zmcp-gateway list` to see available servers)", .{ context, r });
            } else {
                var buf: [200]u8 = undefined;
                var w: std.Io.Writer = .fixed(&buf);
                for (near[0..n], 0..) |c, i| {
                    if (i > 0) w.writeAll(", ") catch break;
                    w.writeAll(c) catch break;
                }
                diag.set("{s}: unknown server '{s}'; closest matches: {s}", .{ context, r, w.buffered() });
            }
            return error.UnknownServer;
        };
        var dup = false;
        for (out.items) |o| {
            if (std.mem.eql(u8, o, k)) dup = true;
        }
        if (!dup) try out.append(a, k);
    }
    return out.items;
}

/// Split "a,b, c" into names (slices of `text`).
pub fn splitNames(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    return mcp.parseNameList(a, text);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseConfig accepts a full profile and defaults" {
    const alloc = std.testing.allocator;
    var d: Diag = .{};
    var cfg = try parseConfig(alloc,
        \\{"profiles":{"dev":{"servers":["memory","git","ripgrep"],"tools_deny":["git_reset"],"readonly":false},
        \\ "all":{}, "ro":{"servers":["git"],"tools_allow":["git_status","git_log*"],"readonly":true}}}
    , &d);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 3), cfg.profiles.len);
    const dev = cfg.find("dev").?;
    try std.testing.expectEqual(@as(usize, 3), dev.servers.len);
    try std.testing.expectEqualStrings("git_reset", dev.slice.deny[0]);
    try std.testing.expect(!dev.slice.readonly);
    try std.testing.expectEqual(@as(usize, 0), cfg.find("all").?.servers.len);
    const ro = cfg.find("ro").?;
    try std.testing.expect(ro.slice.readonly);
    try std.testing.expectEqual(@as(usize, 2), ro.slice.allow.len);
    try std.testing.expect(cfg.find("missing") == null);
}

test "parseConfig rejects bad shapes with a message" {
    const alloc = std.testing.allocator;
    const bad = [_]struct { text: []const u8, want: []const u8 }{
        .{ .text = "nope", .want = "not valid JSON" },
        .{ .text = "[]", .want = "JSON object" },
        .{ .text = "{}", .want = "no \"profiles\"" },
        .{ .text = "{\"profiles\":[]}", .want = "must be an object" },
        .{ .text = "{\"profiles\":{\"a\":1}}", .want = "profile 'a' must be an object" },
        .{ .text = "{\"profiles\":{\"a\":{\"servers\":\"git\"}}}", .want = "servers must be an array" },
        .{ .text = "{\"profiles\":{\"a\":{\"servers\":[\"../x\"]}}}", .want = "invalid server name" },
        .{ .text = "{\"profiles\":{\"a\":{\"servers\":[\"Git\"]}}}", .want = "invalid server name" },
        .{ .text = "{\"profiles\":{\"a\":{\"tools_deny\":[1]}}}", .want = "tools_deny" },
        .{ .text = "{\"profiles\":{\"a\":{\"readonly\":\"yes\"}}}", .want = "readonly must be" },
        .{ .text = "{\"profiles\":{\"a b\":{}}}", .want = "invalid profile name" },
    };
    for (bad) |b| {
        var d: Diag = .{};
        try std.testing.expectError(error.InvalidConfig, parseConfig(alloc, b.text, &d));
        if (std.mem.indexOf(u8, d.text(), b.want) == null) {
            std.debug.print("want '{s}' in '{s}'\n", .{ b.want, d.text() });
            return error.TestUnexpectedResult;
        }
    }
}

test "hiddenBy: glob allow/deny and readonly, deny wins" {
    const sl: Slice = .{ .allow = &.{ "git_*", "fs_read" }, .deny = &.{ "git_reset", "git_push*" } };
    try std.testing.expect(hiddenBy(sl, "git_status", false) == null);
    try std.testing.expect(hiddenBy(sl, "fs_read", false) == null);
    try std.testing.expectEqual(Reason.deny, hiddenBy(sl, "git_reset", false).?);
    try std.testing.expectEqual(Reason.deny, hiddenBy(sl, "git_push_force", false).?);
    try std.testing.expectEqual(Reason.allow, hiddenBy(sl, "fs_write", false).?);
    const ro: Slice = .{ .readonly = true };
    try std.testing.expect(hiddenBy(ro, "x", true) == null);
    try std.testing.expectEqual(Reason.readonly, hiddenBy(ro, "x", false).?);
    try std.testing.expect(hiddenBy(.{}, "anything", false) == null);
    try std.testing.expect(hiddenBy(.{ .allow = &.{"*"} }, "anything", false) == null);
}

test "validServerName blocks path separators and odd characters" {
    try std.testing.expect(validServerName("web-search"));
    try std.testing.expect(validServerName("zig_docs2"));
    for ([_][]const u8{ "", "..", "a/b", "a\\b", "a.b", "-x", "A", "a b", "a;rm", "$(x)" }) |bad| {
        try std.testing.expect(!validServerName(bad));
    }
    try std.testing.expect(!validServerName("x" ** 49));
}

test "resolveServers: all when empty, dedup, unknown names suggest the closest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const known = [_][]const u8{ "git", "github", "memory", "ripgrep", "docker", "fs" };
    var d: Diag = .{};

    const all = try resolveServers(a, &.{}, &known, "x", &d);
    try std.testing.expectEqual(@as(usize, 6), all.len);

    const some = try resolveServers(a, &.{ "memory", "git", "memory" }, &known, "profile 'dev'", &d);
    try std.testing.expectEqual(@as(usize, 2), some.len);
    try std.testing.expectEqualStrings("memory", some[0]);

    try std.testing.expectError(error.UnknownServer, resolveServers(a, &.{"gitt"}, &known, "profile 'dev'", &d));
    try std.testing.expect(std.mem.indexOf(u8, d.text(), "unknown server 'gitt'") != null);
    try std.testing.expect(std.mem.indexOf(u8, d.text(), "git") != null);
    try std.testing.expect(std.mem.indexOf(u8, d.text(), "profile 'dev'") != null);

    try std.testing.expectError(error.UnknownServer, resolveServers(a, &.{"zzzzzz"}, &known, "--servers", &d));
    try std.testing.expect(std.mem.indexOf(u8, d.text(), "zmcp-gateway list") != null);

    try std.testing.expectError(error.InvalidServerName, resolveServers(a, &.{"../etc"}, &known, "--servers", &d));
}

test "closest ranks near names first" {
    const known = [_][]const u8{ "ripgrep", "git", "github", "gitlab" };
    var out: [3][]const u8 = undefined;
    const n = closest("gitt", &known, &out);
    try std.testing.expect(n >= 1);
    try std.testing.expectEqualStrings("git", out[0]);
    try std.testing.expectEqual(@as(usize, 0), closest("qqqqqqqq", &known, &out));
}
