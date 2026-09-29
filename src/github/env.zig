//! Environment access for zmcp-github: token lookup and GitHub host
//! (github.com, GitHub Enterprise Server, ghe.com) endpoint derivation.
//!
//! The process environment comes from `init.environ_map` (stored by main via
//! `init`); the old `globalEnviron()` trick is empty on Linux/macOS, which made
//! GITHUB_TOKEN invisible there. Tests replace the environment with
//! `test_env`. The token is never logged or echoed.

const std = @import("std");

var g_environ: ?*const std.process.Environ.Map = null;

/// Test hook replacing the process environment.
pub var test_env: ?[]const [2][]const u8 = null;

pub fn init(map: *const std.process.Environ.Map) void {
    g_environ = map;
}

/// Non-empty value of an environment variable, or null.
pub fn get(name: []const u8) ?[]const u8 {
    if (test_env) |te| {
        for (te) |kv| if (std.mem.eql(u8, kv[0], name) and kv[1].len > 0) return kv[1];
        return null;
    }
    const m = g_environ orelse return null;
    const v = m.get(name) orelse return null;
    return if (v.len == 0) null else v;
}

/// True when the variable is set to 1/true/yes/on (case-insensitive).
pub fn flag(name: []const u8) bool {
    const v = get(name) orelse return false;
    const t = std.mem.trim(u8, v, " \t");
    inline for (.{ "1", "true", "yes", "on" }) |s| if (std.ascii.eqlIgnoreCase(t, s)) return true;
    return false;
}

pub const token_vars = [_][]const u8{ "GITHUB_TOKEN", "GITHUB_PERSONAL_ACCESS_TOKEN", "GH_TOKEN" };

/// First set of GITHUB_TOKEN, GITHUB_PERSONAL_ACCESS_TOKEN, GH_TOKEN.
pub fn token() ?[]const u8 {
    for (token_vars) |n| if (get(n)) |v| {
        const t = std.mem.trim(u8, v, " \t\r\n");
        if (t.len > 0) return t;
    };
    return null;
}

pub const Endpoints = struct {
    /// REST base, no trailing slash, e.g. https://api.github.com
    rest: []const u8,
    /// GraphQL endpoint URL.
    graphql: []const u8,
};

pub const EndpointError = error{InvalidHost};

fn isLoopback(host: []const u8) bool {
    return std.mem.eql(u8, host, "localhost") or std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "[::1]");
}

fn hostOf(url_after_scheme: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, url_after_scheme, "/:") orelse url_after_scheme.len;
    if (url_after_scheme.len > 0 and url_after_scheme[0] == '[') {
        const close = std.mem.indexOfScalar(u8, url_after_scheme, ']') orelse return url_after_scheme;
        return url_after_scheme[0 .. close + 1];
    }
    return url_after_scheme[0..end];
}

/// Split "scheme://rest" and enforce https (http only for loopback). Returns
/// the normalised "scheme://rest" without trailing slashes.
fn normalise(alloc: std.mem.Allocator, raw: []const u8) EndpointError![]const u8 {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    const floor: usize = if (std.mem.indexOf(u8, s, "://")) |i| i + 3 else 0;
    while (s.len > floor and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    if (s.len == 0) return error.InvalidHost;
    for (s) |c| if (c <= ' ' or c == '?' or c == '#' or c == '@' or c == '\\' or c > 126) return error.InvalidHost;
    var scheme: []const u8 = "https";
    var rest = s;
    if (std.mem.indexOf(u8, s, "://")) |i| {
        scheme = s[0..i];
        rest = s[i + 3 ..];
    }
    const is_https = std.ascii.eqlIgnoreCase(scheme, "https");
    const is_http = std.ascii.eqlIgnoreCase(scheme, "http");
    if (!is_https and !is_http) return error.InvalidHost;
    const host = hostOf(rest);
    if (host.len == 0) return error.InvalidHost;
    if (is_http and !isLoopback(host)) return error.InvalidHost;
    return std.fmt.allocPrint(alloc, "{s}://{s}", .{ if (is_http) "http" else "https", rest }) catch error.InvalidHost;
}

/// Derive REST and GraphQL endpoints from a normalised root URL that is a
/// GitHub *web* host (GITHUB_HOST semantics).
fn fromWebHost(alloc: std.mem.Allocator, root: []const u8) EndpointError!Endpoints {
    const scheme_end = std.mem.indexOf(u8, root, "://").? + 3;
    const rest = root[scheme_end..];
    const host = hostOf(rest);
    const scheme = root[0 .. scheme_end - 3];
    if (std.mem.eql(u8, rest, "github.com") or std.mem.eql(u8, rest, "www.github.com")) {
        return .{ .rest = "https://api.github.com", .graphql = "https://api.github.com/graphql" };
    }
    if (std.mem.endsWith(u8, host, ".ghe.com") and !std.mem.startsWith(u8, host, "api.")) {
        const r = std.fmt.allocPrint(alloc, "{s}://api.{s}", .{ scheme, rest }) catch return error.InvalidHost;
        return .{ .rest = r, .graphql = std.fmt.allocPrint(alloc, "{s}/graphql", .{r}) catch return error.InvalidHost };
    }
    if (std.mem.startsWith(u8, host, "api.") and std.mem.endsWith(u8, host, ".ghe.com")) {
        return .{ .rest = root, .graphql = std.fmt.allocPrint(alloc, "{s}/graphql", .{root}) catch return error.InvalidHost };
    }
    // GitHub Enterprise Server: https://HOST/api/v3 and /api/graphql.
    return .{
        .rest = std.fmt.allocPrint(alloc, "{s}/api/v3", .{root}) catch return error.InvalidHost,
        .graphql = std.fmt.allocPrint(alloc, "{s}/api/graphql", .{root}) catch return error.InvalidHost,
    };
}

/// Derive endpoints from an explicit REST base (GITHUB_API_URL semantics).
fn fromApiUrl(alloc: std.mem.Allocator, root: []const u8) EndpointError!Endpoints {
    if (std.mem.endsWith(u8, root, "/api/v3")) {
        const base = root[0 .. root.len - "/api/v3".len];
        return .{ .rest = root, .graphql = std.fmt.allocPrint(alloc, "{s}/api/graphql", .{base}) catch return error.InvalidHost };
    }
    return .{ .rest = root, .graphql = std.fmt.allocPrint(alloc, "{s}/graphql", .{root}) catch return error.InvalidHost };
}

/// Resolve REST/GraphQL endpoints: GITHUB_API_URL wins, then GITHUB_HOST,
/// else api.github.com. Anything not https (except loopback) is refused so
/// the token can never travel in cleartext.
pub fn endpoints(alloc: std.mem.Allocator) EndpointError!Endpoints {
    if (get("GITHUB_API_URL")) |v| return fromApiUrl(alloc, try normalise(alloc, v));
    if (get("GITHUB_HOST")) |v| return fromWebHost(alloc, try normalise(alloc, v));
    return .{ .rest = "https://api.github.com", .graphql = "https://api.github.com/graphql" };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn withEnv(pairs: []const [2][]const u8) void {
    test_env = pairs;
}

test "token order: GITHUB_TOKEN, GITHUB_PERSONAL_ACCESS_TOKEN, GH_TOKEN; empty is unset" {
    defer test_env = null;
    withEnv(&.{ .{ "GH_TOKEN", "c" }, .{ "GITHUB_PERSONAL_ACCESS_TOKEN", "b" } });
    try std.testing.expectEqualStrings("b", token().?);
    withEnv(&.{ .{ "GH_TOKEN", "c" }, .{ "GITHUB_PERSONAL_ACCESS_TOKEN", "b" }, .{ "GITHUB_TOKEN", "a" } });
    try std.testing.expectEqualStrings("a", token().?);
    withEnv(&.{ .{ "GITHUB_TOKEN", "" }, .{ "GH_TOKEN", "c" } });
    try std.testing.expectEqualStrings("c", token().?);
    withEnv(&.{});
    try std.testing.expect(token() == null);
}

test "Linux regression: token is read from an Environ.Map" {
    defer {
        test_env = null;
        g_environ = null;
    }
    test_env = null;
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("GITHUB_TOKEN", "from-map");
    init(&map);
    try std.testing.expectEqualStrings("from-map", token().?);
}

test "default endpoints" {
    defer test_env = null;
    withEnv(&.{});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const e = try endpoints(arena.allocator());
    try std.testing.expectEqualStrings("https://api.github.com", e.rest);
    try std.testing.expectEqualStrings("https://api.github.com/graphql", e.graphql);
}

test "GHES and ghe.com derivation" {
    defer test_env = null;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    withEnv(&.{.{ "GITHUB_HOST", "https://ghe.example.com//" }});
    var e = try endpoints(a);
    try std.testing.expectEqualStrings("https://ghe.example.com/api/v3", e.rest);
    try std.testing.expectEqualStrings("https://ghe.example.com/api/graphql", e.graphql);
    withEnv(&.{.{ "GITHUB_HOST", "https://octocorp.ghe.com" }});
    e = try endpoints(a);
    try std.testing.expectEqualStrings("https://api.octocorp.ghe.com", e.rest);
    try std.testing.expectEqualStrings("https://api.octocorp.ghe.com/graphql", e.graphql);
    withEnv(&.{.{ "GITHUB_HOST", "github.com" }});
    e = try endpoints(a);
    try std.testing.expectEqualStrings("https://api.github.com", e.rest);
    withEnv(&.{.{ "GITHUB_API_URL", "https://ghe.example.com/api/v3/" }});
    e = try endpoints(a);
    try std.testing.expectEqualStrings("https://ghe.example.com/api/v3", e.rest);
    try std.testing.expectEqualStrings("https://ghe.example.com/api/graphql", e.graphql);
    withEnv(&.{.{ "GITHUB_API_URL", "https://api.octocorp.ghe.com" }});
    e = try endpoints(a);
    try std.testing.expectEqualStrings("https://api.octocorp.ghe.com/graphql", e.graphql);
    withEnv(&.{ .{ "GITHUB_API_URL", "https://ghe.example.com/api/v3" }, .{ "GITHUB_HOST", "https://other.example.com" } });
    e = try endpoints(a);
    try std.testing.expectEqualStrings("https://ghe.example.com/api/v3", e.rest);
}

test "non-https hosts and junk are refused, loopback http allowed" {
    defer test_env = null;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "http://ghe.example.com", "ftp://x.com", "https://", "https://a b.com", "https://u@x.com", "https://x.com/?a=b" }) |bad| {
        withEnv(&.{.{ "GITHUB_HOST", bad }});
        try std.testing.expectError(error.InvalidHost, endpoints(a));
        withEnv(&.{.{ "GITHUB_API_URL", bad }});
        try std.testing.expectError(error.InvalidHost, endpoints(a));
    }
    withEnv(&.{.{ "GITHUB_API_URL", "http://localhost:8080/api/v3" }});
    const e = try endpoints(a);
    try std.testing.expectEqualStrings("http://localhost:8080/api/v3", e.rest);
}
