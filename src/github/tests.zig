//! Offline tests for zmcp-github: fake transport, no network, no token.

const std = @import("std");
const mcp = @import("mcp");
const core = @import("core.zig");
const genv = @import("env.zig");
const main = @import("main.zig");
const ts = core.testing_support;
const Resp = core.Resp;

const RO_ENV = [_][2][]const u8{.{ "GITHUB_TOKEN", "test-token" }};
const RW_ENV = RO_ENV ++ [_][2][]const u8{.{ "ZMCP_GITHUB_ALLOW_WRITE", "1" }};
const DES_ENV = RW_ENV ++ [_][2][]const u8{.{ "ZMCP_GITHUB_ALLOW_DESTRUCTIVE", "1" }};
const RO_FLAG_ENV = DES_ENV ++ [_][2][]const u8{.{ "GITHUB_READ_ONLY", "1" }};
const NO_ENV = [_][2][]const u8{};
const GHES_ENV = RO_ENV ++ [_][2][]const u8{.{ "GITHUB_HOST", "https://ghe.example.com/" }};

const Rig = struct {
    arena: std.heap.ArenaAllocator,

    fn init(env: []const [2][]const u8, queue: []const Resp) Rig {
        ts.setup(env, queue);
        return .{ .arena = .init(std.testing.allocator) };
    }
    fn deinit(self: *Rig) void {
        self.arena.deinit();
        ts.restore();
    }
    fn call(self: *Rig, name: []const u8, args: []const u8) !mcp.ToolResult {
        const a = self.arena.allocator();
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, args, .{});
        for (main.all_tools) |t| if (std.mem.eql(u8, t.def.name, name)) return t.def.handler(a, std.testing.io, v);
        return error.NoSuchTool;
    }
    fn n(_: *Rig) usize {
        return ts.calls.items.len;
    }
    fn req(_: *Rig, i: usize) core.FetchRequest {
        return ts.calls.items[i];
    }
    fn url(self: *Rig, i: usize) []const u8 {
        return self.req(i).url;
    }
};

fn ok(body: []const u8) Resp {
    return .{ .status = 200, .body = body };
}
fn st(status: u16, body: []const u8) Resp {
    return .{ .status = status, .body = body };
}

fn has(hay: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, hay, needle) == null) {
        std.debug.print("\nexpected to find: {s}\nin: {s}\n", .{ needle, hay });
        return error.TestExpectedContains;
    }
}
fn hasNot(hay: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, hay, needle) != null) {
        std.debug.print("\nexpected NOT to find: {s}\nin: {s}\n", .{ needle, hay });
        return error.TestUnexpectedContains;
    }
}

const API = "https://api.github.com";

// ---------------------------------------------------------------------------
// Table, classification, toolsets
// ---------------------------------------------------------------------------

const write_tools = [_][]const u8{
    "create_branch",                 "create_or_update_file",      "delete_file",                 "push_files",
    "create_repository",             "fork_repository",            "delete_repository",           "star_repository",
    "unstar_repository",             "issue_write",                "add_issue_comment",           "update_issue_comment",
    "sub_issue_write",               "label_write",                "create_pull_request",         "update_pull_request",
    "merge_pull_request",            "update_pull_request_branch", "pull_request_review_write",   "add_comment_to_pending_review",
    "add_reply_to_pull_request_comment", "request_copilot_review", "actions_run_trigger",         "dismiss_notification",
    "mark_all_notifications_read",   "manage_notification_subscription", "manage_repository_notification_subscription", "create_gist",
    "update_gist",                   "discussion_comment_write",   "projects_write",
};
const destructive_tools = [_][]const u8{
    "delete_file", "delete_repository", "merge_pull_request", "actions_run_trigger", "label_write", "pull_request_review_write", "discussion_comment_write", "projects_write",
};

fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

test "tool table: schemas are JSON objects, descriptions terse, marks exact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (main.all_tools) |t| {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), t.def.input_schema_json, .{});
        try std.testing.expect(v == .object);
        try std.testing.expect(t.def.description.len > 0 and t.def.description.len <= 170);
        try std.testing.expect(std.mem.indexOfScalar(u8, t.def.description, '\n') == null);
        try std.testing.expect(!(t.def.read_only and t.def.destructive));
        try std.testing.expect(t.def.read_only != inList(&write_tools, t.def.name));
        try std.testing.expectEqual(inList(&destructive_tools, t.def.name), t.def.destructive);
        try std.testing.expect(main.toolsets.len > 0);
    }
    for (write_tools) |w| {
        var found = false;
        for (main.all_tools) |t| if (std.mem.eql(u8, t.def.name, w)) {
            found = true;
        };
        try std.testing.expect(found);
    }
}

test "official tool names are all present or listed as skipped" {
    const official = [_][]const u8{
        "actions_get",                    "actions_list",                      "actions_run_trigger",                  "get_job_logs",
        "get_code_scanning_alert",        "list_code_scanning_alerts",         "get_me",                               "get_team_members",
        "get_teams",                      "request_copilot_review",            "get_dependabot_alert",                 "list_dependabot_alerts",
        "discussion_comment_write",       "get_discussion",                    "get_discussion_comments",              "list_discussion_categories",
        "list_discussions",               "create_gist",                       "get_gist",                             "list_gists",
        "update_gist",                    "get_repository_tree",               "add_issue_comment",                    "get_label",
        "issue_read",                     "issue_write",                       "list_issue_types",                     "list_issues",
        "search_issues",                  "sub_issue_write",                   "update_issue_comment",                 "label_write",
        "list_label",                     "dismiss_notification",              "get_notification_details",             "list_notifications",
        "manage_notification_subscription", "manage_repository_notification_subscription", "mark_all_notifications_read", "search_orgs",
        "projects_get",                   "projects_list",                     "projects_write",                       "add_comment_to_pending_review",
        "add_reply_to_pull_request_comment", "create_pull_request",            "list_pull_requests",                   "merge_pull_request",
        "pull_request_read",              "pull_request_review_write",         "search_pull_requests",                 "update_pull_request",
        "update_pull_request_branch",     "create_branch",                     "create_or_update_file",                "create_repository",
        "delete_file",                    "delete_repository",                 "fork_repository",                      "get_commit",
        "get_file_contents",              "get_latest_release",                "get_release_by_tag",                   "get_tag",
        "list_branches",                  "list_commits",                      "list_releases",                        "list_repository_collaborators",
        "list_tags",                      "push_files",                        "search_code",                          "search_commits",
        "search_repositories",            "get_secret_scanning_alert",         "list_secret_scanning_alerts",          "get_global_security_advisory",
        "list_global_security_advisories", "list_org_repository_security_advisories", "list_repository_security_advisories", "list_starred_repositories",
        "star_repository",                "unstar_repository",                 "search_users",
    };
    for (official) |name| {
        var found = false;
        for (main.all_tools) |t| if (std.mem.eql(u8, t.def.name, name)) {
            found = true;
        };
        if (!found) std.debug.print("missing official tool: {s}\n", .{name});
        try std.testing.expect(found);
    }
}

test "toolset parsing: default, all, list, unknown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var unk: []const u8 = "";
    try std.testing.expectEqual(main.defaultMask(), main.parseToolsets(arena.allocator(), null, &unk));
    try std.testing.expectEqual(~@as(u64, 0), main.parseToolsets(arena.allocator(), "all", &unk));
    const m = main.parseToolsets(arena.allocator(), "default, actions,nope", &unk);
    try std.testing.expectEqual(main.defaultMask() | (@as(u64, 1) << 5), m);
    try std.testing.expectEqualStrings("nope", unk);
    try std.testing.expectEqual(main.defaultMask(), main.parseToolsets(arena.allocator(), "nope", &unk));
}

fn listed(table: []const mcp.ToolDef, name: []const u8) bool {
    for (table) |t| if (std.mem.eql(u8, t.name, name)) return true;
    return false;
}

test "buildTable: default set, all, custom, read-only, individual tools" {
    defer ts.restore();
    genv.test_env = &RO_ENV;
    const d = try main.buildTable(std.testing.allocator);
    defer std.testing.allocator.free(d);
    try std.testing.expect(listed(d, "get_me") and listed(d, "list_issues") and listed(d, "github_toolsets") and listed(d, "search_users"));
    try std.testing.expect(!listed(d, "actions_list") and !listed(d, "get_gist") and !listed(d, "github_api_get"));

    genv.test_env = &[_][2][]const u8{.{ "ZMCP_GITHUB_TOOLSETS", "all" }};
    const a = try main.buildTable(std.testing.allocator);
    defer std.testing.allocator.free(a);
    try std.testing.expect(listed(a, "actions_list") and listed(a, "github_api_get") and listed(a, "list_discussions"));
    try std.testing.expect(a.len > d.len);
    // names are unique even though get_label is declared in two toolsets
    for (a, 0..) |x, i| for (a[i + 1 ..]) |y| try std.testing.expect(!std.mem.eql(u8, x.name, y.name));

    genv.test_env = &[_][2][]const u8{ .{ "ZMCP_GITHUB_TOOLSETS", "gists" }, .{ "GITHUB_READ_ONLY", "1" } };
    const g = try main.buildTable(std.testing.allocator);
    defer std.testing.allocator.free(g);
    try std.testing.expect(listed(g, "get_gist") and listed(g, "list_gists") and !listed(g, "create_gist") and !listed(g, "get_me"));

    genv.test_env = &[_][2][]const u8{ .{ "GITHUB_TOOLSETS", "labels" }, .{ "ZMCP_GITHUB_TOOLS", "get_me,list_tags" } };
    const l = try main.buildTable(std.testing.allocator);
    defer std.testing.allocator.free(l);
    try std.testing.expect(listed(l, "list_label") and listed(l, "get_me") and listed(l, "list_tags") and !listed(l, "list_issues"));
}

test "github_toolsets lists groups with counts and how to enable" {
    var rig = Rig.init(&RO_ENV, &.{});
    defer rig.deinit();
    const tbl = try main.buildTable(std.testing.allocator);
    defer std.testing.allocator.free(tbl);
    const r = try rig.call("github_toolsets", "{}");
    try std.testing.expect(!r.is_error);
    try has(r.text, "ZMCP_GITHUB_TOOLSETS");
    try has(r.text, "context: 3 tools, ON (default)");
    try has(r.text, "actions: 4 tools, off");
    try has(r.text, "discussions: 5 tools");
    try std.testing.expectEqual(@as(usize, 0), rig.n());
}

// ---------------------------------------------------------------------------
// Safety gates
// ---------------------------------------------------------------------------

test "gate: every write tool is refused by default and never hits the transport" {
    var rig = Rig.init(&RO_ENV, &.{});
    defer rig.deinit();
    for (write_tools) |name| {
        const r = try rig.call(name, "{}");
        if (!r.is_error) std.debug.print("not refused: {s}\n", .{name});
        try std.testing.expect(r.is_error);
        try has(r.text, "ZMCP_GITHUB_ALLOW_WRITE");
        try has(r.text, name);
    }
    try std.testing.expectEqual(@as(usize, 0), rig.n());
}

test "gate: GITHUB_READ_ONLY=1 refuses even with allow-write and allow-destructive" {
    var rig = Rig.init(&RO_FLAG_ENV, &.{});
    defer rig.deinit();
    for (write_tools) |name| {
        const r = try rig.call(name, "{\"method\":\"delete\"}");
        try std.testing.expect(r.is_error);
        try has(r.text, "GITHUB_READ_ONLY");
    }
    try std.testing.expectEqual(@as(usize, 0), rig.n());
}

test "gate: destructive tools additionally need ZMCP_GITHUB_ALLOW_DESTRUCTIVE" {
    var rig = Rig.init(&RW_ENV, &.{});
    defer rig.deinit();
    for ([_][]const u8{ "merge_pull_request", "delete_file", "delete_repository", "actions_run_trigger" }) |name| {
        const r = try rig.call(name, "{\"method\":\"cancel_workflow_run\"}");
        try std.testing.expect(r.is_error);
        try has(r.text, "ZMCP_GITHUB_ALLOW_DESTRUCTIVE");
    }
    const cases = [_][2][]const u8{
        .{ "label_write", "{\"method\":\"delete\",\"owner\":\"o\",\"repo\":\"r\",\"name\":\"x\"}" },
        .{ "pull_request_review_write", "{\"method\":\"delete_pending\",\"owner\":\"o\",\"repo\":\"r\",\"pullNumber\":1}" },
        .{ "projects_write", "{\"method\":\"delete_project_item\",\"owner\":\"o\",\"project_number\":1,\"item_id\":2}" },
        .{ "discussion_comment_write", "{\"method\":\"delete\",\"commentNodeID\":\"DC_x\"}" },
    };
    for (cases) |cs| {
        const r = try rig.call(cs[0], cs[1]);
        try std.testing.expect(r.is_error);
        try has(r.text, "ZMCP_GITHUB_ALLOW_DESTRUCTIVE");
    }
    try std.testing.expectEqual(@as(usize, 0), rig.n());
}

test "gate: additive writes pass with allow-write alone" {
    var rig = Rig.init(&RW_ENV, &.{ok("{\"id\":9,\"html_url\":\"u\"}")});
    defer rig.deinit();
    const r = try rig.call("add_issue_comment", "{\"owner\":\"o\",\"repo\":\"r\",\"issue_number\":3,\"body\":\"hi\"}");
    try std.testing.expect(!r.is_error);
    try std.testing.expectEqual(@as(usize, 1), rig.n());
}

// ---------------------------------------------------------------------------
// Env and host resolution
// ---------------------------------------------------------------------------

test "auth: token env order reaches the transport and never appears in output" {
    var rig = Rig.init(&[_][2][]const u8{.{ "GH_TOKEN", "from-gh" }}, &.{ok("{\"login\":\"octo\"}")});
    defer rig.deinit();
    const r = try rig.call("get_me", "{}");
    try std.testing.expectEqualStrings("from-gh", rig.req(0).token);
    try std.testing.expectEqualStrings(API ++ "/user", rig.url(0));
    try hasNot(r.text, "from-gh");
}

test "auth: missing token is a clean error before any request" {
    var rig = Rig.init(&NO_ENV, &.{});
    defer rig.deinit();
    const r = try rig.call("get_me", "{}");
    try std.testing.expect(r.is_error);
    try has(r.text, "GITHUB_TOKEN");
    try std.testing.expectEqual(@as(usize, 0), rig.n());
}

test "host: GHES REST and GraphQL URLs derive from GITHUB_HOST" {
    var rig = Rig.init(&GHES_ENV, &.{ ok("{}"), ok("{\"data\":{\"repository\":{\"discussionCategories\":{\"nodes\":[]}}}}") });
    defer rig.deinit();
    _ = try rig.call("get_me", "{}");
    try std.testing.expectEqualStrings("https://ghe.example.com/api/v3/user", rig.url(0));
    _ = try rig.call("list_discussion_categories", "{\"owner\":\"o\",\"repo\":\"r\"}");
    try std.testing.expectEqualStrings("https://ghe.example.com/api/graphql", rig.url(1));
}

test "host: invalid GITHUB_API_URL refuses before any request" {
    var rig = Rig.init(&(RO_ENV ++ [_][2][]const u8{.{ "GITHUB_API_URL", "http://evil.example.com" }}), &.{});
    defer rig.deinit();
    const r = try rig.call("get_me", "{}");
    try std.testing.expect(r.is_error);
    try has(r.text, "invalid");
    try std.testing.expectEqual(@as(usize, 0), rig.n());
}

// ---------------------------------------------------------------------------
// Validation and encoding
// ---------------------------------------------------------------------------

test "validators" {
    try std.testing.expect(core.validOwner("octo-cat") and core.validOwner("a.b_c"));
    for ([_][]const u8{ "", "-x", "a/b", "a b", "..", "a..b", "a?b", "a#b", "x%2F" }) |bad| try std.testing.expect(!core.validOwner(bad));
    try std.testing.expect(core.validRef("feature/x-1") and core.validRef("v1.0.0"));
    for ([_][]const u8{ "", "-x", "/x", "x/", "a..b", "a b", "a~1", "a^", "a:b", "a?b", "a*b", "a[b", "a\\b", "a@{u}", "a//b", "a#b", "a%b" }) |bad| try std.testing.expect(!core.validRef(bad));
    try std.testing.expect(core.validSha("deadBEEF01"));
    for ([_][]const u8{ "", "xyz1", "abc", "abcdefg" }) |bad| try std.testing.expect(!core.validSha(bad));
    try std.testing.expect(core.validPath("src/a b/c.txt"));
    for ([_][]const u8{ "", "/etc/passwd", "a/../b", "../a", "a//b", "a/./b", "a?b", "a#b", "a%2e", "a\\b" }) |bad| try std.testing.expect(!core.validPath(bad));
}

test "injection table: bad owner/repo/branch/path/sha never reach the transport" {
    var rig = Rig.init(&DES_ENV, &.{});
    defer rig.deinit();
    const cases = [_][2][]const u8{
        .{ "get_file_contents", "{\"owner\":\"o/../x\",\"repo\":\"r\"}" },
        .{ "get_file_contents", "{\"owner\":\"o\",\"repo\":\"r/x\"}" },
        .{ "get_file_contents", "{\"owner\":\"o\",\"repo\":\"-r\"}" },
        .{ "get_file_contents", "{\"owner\":\"o\",\"repo\":\"r\",\"path\":\"../../etc/passwd\"}" },
        .{ "get_file_contents", "{\"owner\":\"o\",\"repo\":\"r\",\"path\":\"a?x=1\"}" },
        .{ "get_file_contents", "{\"owner\":\"o\",\"repo\":\"r\",\"ref\":\"main?x=1\"}" },
        .{ "get_file_contents", "{\"owner\":\"o\",\"repo\":\"r\",\"sha\":\"nothex\"}" },
        .{ "list_commits", "{\"owner\":\"o\",\"repo\":\"r\",\"sha\":\"-rf\"}" },
        .{ "get_commit", "{\"owner\":\"o\",\"repo\":\"r\",\"sha\":\"a/../b\"}" },
        .{ "create_branch", "{\"owner\":\"o\",\"repo\":\"r\",\"branch\":\"a..b\"}" },
        .{ "create_branch", "{\"owner\":\"o\",\"repo\":\"r\",\"branch\":\"ok\",\"from_branch\":\"-x\"}" },
        .{ "create_or_update_file", "{\"owner\":\"o\",\"repo\":\"r\",\"path\":\"/abs\",\"content\":\"x\",\"message\":\"m\",\"branch\":\"b\"}" },
        .{ "delete_file", "{\"owner\":\"o\",\"repo\":\"r\",\"path\":\"a/../b\",\"message\":\"m\",\"branch\":\"b\"}" },
        .{ "push_files", "{\"owner\":\"o\",\"repo\":\"r\",\"branch\":\"b\",\"message\":\"m\",\"files\":[{\"path\":\"../x\",\"content\":\"c\"}]}" },
        .{ "issue_read", "{\"method\":\"get\",\"owner\":\"o\",\"repo\":\"r x\",\"issue_number\":1}" },
        .{ "issue_read", "{\"method\":\"nope\",\"owner\":\"o\",\"repo\":\"r\",\"issue_number\":1}" },
        .{ "issue_read", "{\"method\":\"get\",\"owner\":\"o\",\"repo\":\"r\",\"issue_number\":-4}" },
        .{ "get_release_by_tag", "{\"owner\":\"o\",\"repo\":\"r\",\"tag\":\"v1/../x\"}" },
        .{ "actions_get", "{\"method\":\"get_workflow_run\",\"owner\":\"o\",\"repo\":\"r\",\"resource_id\":\"1/../2\"}" },
        .{ "actions_list", "{\"method\":\"list_workflow_runs\",\"owner\":\"o\",\"repo\":\"r\",\"resource_id\":\"a/b\"}" },
        .{ "actions_run_trigger", "{\"method\":\"run_workflow\",\"owner\":\"o\",\"repo\":\"r\",\"workflow_id\":\"ci.yml\",\"ref\":\"a..b\"}" },
        .{ "get_team_members", "{\"org\":\"o\",\"team_slug\":\"../x\"}" },
        .{ "get_gist", "{\"gist_id\":\"a/b\"}" },
        .{ "get_notification_details", "{\"notificationID\":\"1/2\"}" },
        .{ "github_api_get", "{\"path\":\"/../etc\"}" },
        .{ "github_api_get", "{\"path\":\"//evil.com/x\"}" },
        .{ "github_api_get", "{\"path\":\"https://evil.com/x\"}" },
        .{ "github_api_get", "{\"path\":\"/user#frag\"}" },
        .{ "github_api_get", "{\"path\":\"/graphql\"}" },
    };
    for (cases) |cs| {
        const r = try rig.call(cs[0], cs[1]);
        if (!r.is_error) std.debug.print("accepted bad input: {s} {s}\n", .{ cs[0], cs[1] });
        try std.testing.expect(r.is_error);
    }
    try std.testing.expectEqual(@as(usize, 0), rig.n());
}

test "encoding: path segments and query values are percent-encoded" {
    var rig = Rig.init(&RO_ENV, &.{ ok("[]"), ok("{\"total_count\":0,\"items\":[]}") });
    defer rig.deinit();
    _ = try rig.call("get_file_contents", "{\"owner\":\"o\",\"repo\":\"r\",\"path\":\"dir one/\\u00e9.txt\",\"ref\":\"feat/x\"}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/contents/dir%20one/%C3%A9.txt?ref=feat%2Fx", rig.url(0));
    _ = try rig.call("search_repositories", "{\"query\":\"language:zig stars:>5 &x=1\"}");
    try std.testing.expectEqualStrings(API ++ "/search/repositories?per_page=30&page=1&q=language%3Azig%20stars%3A%3E5%20%26x%3D1", rig.url(1));
}

// ---------------------------------------------------------------------------
// Request shapes per tool family
// ---------------------------------------------------------------------------

test "repos: get_file_contents decodes text, flags binary and oversized files" {
    var rig = Rig.init(&RO_ENV, &.{
        ok("{\"type\":\"file\",\"path\":\"a.txt\",\"sha\":\"abc123\",\"size\":6,\"content\":\"aGVsbG8K\\n\",\"encoding\":\"base64\",\"download_url\":\"https://raw/x\"}"),
        ok("{\"type\":\"file\",\"path\":\"b.bin\",\"sha\":\"abc123\",\"size\":3,\"content\":\"AAEC\",\"encoding\":\"base64\",\"download_url\":\"https://raw/b\"}"),
        ok("{\"type\":\"file\",\"path\":\"big\",\"sha\":\"abc123\",\"size\":2000000,\"content\":\"\",\"encoding\":\"none\",\"download_url\":\"https://raw/big\"}"),
        ok("[{\"name\":\"a\",\"type\":\"file\",\"size\":1,\"path\":\"a\",\"sha\":\"s\",\"url\":\"https://api/x\",\"html_url\":\"h\"}]"),
    });
    defer rig.deinit();
    const r1 = try rig.call("get_file_contents", "{\"owner\":\"o\",\"repo\":\"r\",\"path\":\"a.txt\"}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/contents/a.txt", rig.url(0));
    try has(r1.text, "hello\n");
    try has(r1.text, "\"sha\":\"abc123\"");
    const r2 = try rig.call("get_file_contents", "{\"owner\":\"o\",\"repo\":\"r\",\"path\":\"b.bin\"}");
    try has(r2.text, "binary file");
    const r3 = try rig.call("get_file_contents", "{\"owner\":\"o\",\"repo\":\"r\",\"path\":\"big\"}");
    try has(r3.text, "too large");
    try has(r3.text, "https://raw/big");
    const r4 = try rig.call("get_file_contents", "{\"owner\":\"o\",\"repo\":\"r\",\"fields\":[\"name\",\"type\"]}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/contents/", rig.url(3));
    try std.testing.expectEqualStrings("[{\"name\":\"a\",\"type\":\"file\"}]", r4.text);
}

test "repos: get_file_contents ref vs sha precedence" {
    var rig = Rig.init(&RO_ENV, &.{ok("[]")});
    defer rig.deinit();
    _ = try rig.call("get_file_contents", "{\"owner\":\"o\",\"repo\":\"r\",\"ref\":\"refs/heads/dev\",\"sha\":\"abcdef1\"}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/contents/?ref=abcdef1", rig.url(0));
}

test "repos: list_commits query and compact output" {
    var rig = Rig.init(&RO_ENV, &.{ok(
        \\[{"sha":"abc","html_url":"h","author":{"login":"u","avatar_url":"AV"},"commit":{"message":"fix: a\n\nbody","author":{"name":"N","date":"2024-01-01"}},"parents":[{"sha":"p"}]}]
    )});
    defer rig.deinit();
    const r = try rig.call("list_commits", "{\"owner\":\"o\",\"repo\":\"r\",\"sha\":\"main\",\"path\":\"src/a.zig\",\"author\":\"me\",\"perPage\":5,\"page\":2}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/commits?per_page=5&page=2&sha=main&path=src%2Fa.zig&author=me", rig.url(0));
    try has(r.text, "\"sha\":\"abc\"");
    try has(r.text, "\"login\":\"u\"");
    try hasNot(r.text, "AV");
    try hasNot(r.text, "parents");
}

test "repos: create_branch resolves default branch then POSTs the ref" {
    var rig = Rig.init(&RW_ENV, &.{
        ok("{\"default_branch\":\"main\"}"),
        ok("{\"object\":{\"sha\":\"aaaa1111\"}}"),
        st(201, "{\"ref\":\"refs/heads/feat\",\"object\":{\"sha\":\"aaaa1111\"}}"),
    });
    defer rig.deinit();
    const r = try rig.call("create_branch", "{\"owner\":\"o\",\"repo\":\"r\",\"branch\":\"feat\"}");
    try std.testing.expect(!r.is_error);
    try std.testing.expectEqualStrings(API ++ "/repos/o/r", rig.url(0));
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/git/ref/heads/main", rig.url(1));
    try std.testing.expectEqual(std.http.Method.POST, rig.req(2).method);
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/git/refs", rig.url(2));
    try std.testing.expectEqualStrings("{\"ref\":\"refs/heads/feat\",\"sha\":\"aaaa1111\"}", rig.req(2).body.?);
}

test "repos: create_or_update_file PUTs base64 content" {
    var rig = Rig.init(&RW_ENV, &.{st(201, "{\"content\":{\"path\":\"a.txt\",\"sha\":\"s1\"},\"commit\":{\"sha\":\"c1\",\"html_url\":\"u\"}}")});
    defer rig.deinit();
    const r = try rig.call("create_or_update_file", "{\"owner\":\"o\",\"repo\":\"r\",\"path\":\"a b.txt\",\"content\":\"hello\",\"message\":\"add\",\"branch\":\"main\",\"sha\":\"abc123\"}");
    try std.testing.expect(!r.is_error);
    try std.testing.expectEqual(std.http.Method.PUT, rig.req(0).method);
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/contents/a%20b.txt", rig.url(0));
    try std.testing.expectEqualStrings("{\"message\":\"add\",\"content\":\"aGVsbG8=\",\"branch\":\"main\",\"sha\":\"abc123\"}", rig.req(0).body.?);
}

test "repos: delete_file reads the blob sha then DELETEs with a body" {
    var rig = Rig.init(&DES_ENV, &.{ ok("{\"sha\":\"abc123\"}"), ok("{\"commit\":{\"sha\":\"c2\",\"html_url\":\"u\"}}") });
    defer rig.deinit();
    const r = try rig.call("delete_file", "{\"owner\":\"o\",\"repo\":\"r\",\"path\":\"a.txt\",\"message\":\"rm\",\"branch\":\"main\"}");
    try std.testing.expect(!r.is_error);
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/contents/a.txt?ref=main", rig.url(0));
    try std.testing.expectEqual(std.http.Method.DELETE, rig.req(1).method);
    try std.testing.expectEqualStrings("{\"message\":\"rm\",\"sha\":\"abc123\",\"branch\":\"main\"}", rig.req(1).body.?);
}

test "repos: push_files builds tree, commit and fast-forwards the ref" {
    var rig = Rig.init(&RW_ENV, &.{
        ok("{\"object\":{\"sha\":\"aaaa1111\"}}"),
        ok("{\"tree\":{\"sha\":\"bbbb2222\"}}"),
        st(201, "{\"sha\":\"cccc3333\"}"),
        st(201, "{\"sha\":\"dddd4444\"}"),
        ok("{}"),
    });
    defer rig.deinit();
    const r = try rig.call("push_files", "{\"owner\":\"o\",\"repo\":\"r\",\"branch\":\"main\",\"message\":\"m\",\"files\":[{\"path\":\"a.txt\",\"content\":\"A\"},{\"path\":\"d/b.txt\",\"content\":\"B\"}]}");
    try std.testing.expect(!r.is_error);
    try std.testing.expectEqual(@as(usize, 5), rig.n());
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/git/trees", rig.url(2));
    try std.testing.expectEqualStrings("{\"base_tree\":\"bbbb2222\",\"tree\":[{\"path\":\"a.txt\",\"mode\":\"100644\",\"type\":\"blob\",\"content\":\"A\"},{\"path\":\"d/b.txt\",\"mode\":\"100644\",\"type\":\"blob\",\"content\":\"B\"}]}", rig.req(2).body.?);
    try std.testing.expectEqualStrings("{\"message\":\"m\",\"tree\":\"cccc3333\",\"parents\":[\"aaaa1111\"]}", rig.req(3).body.?);
    try std.testing.expectEqual(std.http.Method.PATCH, rig.req(4).method);
    try std.testing.expectEqualStrings("{\"sha\":\"dddd4444\",\"force\":false}", rig.req(4).body.?);
    try has(r.text, "dddd4444");
}

test "repos: create_repository, fork, delete and stars use the right verbs and paths" {
    var rig = Rig.init(&DES_ENV, &.{ st(201, "{\"full_name\":\"me/x\"}"), st(202, "{\"full_name\":\"me/r\"}"), st(204, ""), st(204, ""), st(204, "") });
    defer rig.deinit();
    _ = try rig.call("create_repository", "{\"name\":\"x\",\"private\":true,\"autoInit\":true,\"organization\":\"acme\"}");
    try std.testing.expectEqualStrings(API ++ "/orgs/acme/repos", rig.url(0));
    try std.testing.expectEqualStrings("{\"name\":\"x\",\"private\":true,\"auto_init\":true}", rig.req(0).body.?);
    _ = try rig.call("fork_repository", "{\"owner\":\"o\",\"repo\":\"r\"}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/forks", rig.url(1));
    _ = try rig.call("delete_repository", "{\"owner\":\"o\",\"repo\":\"r\"}");
    try std.testing.expectEqual(std.http.Method.DELETE, rig.req(2).method);
    _ = try rig.call("star_repository", "{\"owner\":\"o\",\"repo\":\"r\"}");
    try std.testing.expectEqual(std.http.Method.PUT, rig.req(3).method);
    try std.testing.expectEqualStrings(API ++ "/user/starred/o/r", rig.url(3));
    _ = try rig.call("unstar_repository", "{\"owner\":\"o\",\"repo\":\"r\"}");
    try std.testing.expectEqual(std.http.Method.DELETE, rig.req(4).method);
}

test "repos: search_code asks for text matches; search_commits and users URLs" {
    var rig = Rig.init(&RO_ENV, &.{
        ok("{\"total_count\":1,\"items\":[{\"path\":\"a.zig\",\"repository\":{\"full_name\":\"o/r\"},\"html_url\":\"h\",\"score\":1,\"text_matches\":[{\"fragment\":\"const x = 1;\"}]}]}"),
        ok("{\"total_count\":0,\"items\":[]}"),
        ok("{\"total_count\":0,\"items\":[]}"),
        ok("{\"total_count\":0,\"items\":[]}"),
    });
    defer rig.deinit();
    const r = try rig.call("search_code", "{\"query\":\"repo:o/r x\",\"perPage\":10}");
    try std.testing.expectEqualStrings("application/vnd.github.text-match+json", rig.req(0).accept);
    try has(r.text, "\"total_count\":1");
    try has(r.text, "const x = 1;");
    try hasNot(r.text, "score");
    _ = try rig.call("search_commits", "{\"query\":\"fix\",\"sort\":\"author-date\",\"order\":\"desc\"}");
    try std.testing.expectEqualStrings(API ++ "/search/commits?per_page=30&page=1&q=fix&sort=author-date&order=desc", rig.url(1));
    _ = try rig.call("search_users", "{\"query\":\"tom\"}");
    try std.testing.expectEqualStrings(API ++ "/search/users?per_page=30&page=1&q=tom", rig.url(2));
    _ = try rig.call("search_orgs", "{\"query\":\"acme\"}");
    try std.testing.expectEqualStrings(API ++ "/search/users?per_page=30&page=1&q=acme%20type%3Aorg", rig.url(3));
}

test "repos: get_repository_tree compact lines and filter" {
    var rig = Rig.init(&RO_ENV, &.{ ok("{\"default_branch\":\"main\"}"), ok("{\"tree\":[{\"path\":\"src\",\"type\":\"tree\"},{\"path\":\"src/a.zig\",\"type\":\"blob\",\"size\":10},{\"path\":\"README.md\",\"type\":\"blob\",\"size\":3}],\"truncated\":false}") });
    defer rig.deinit();
    const r = try rig.call("get_repository_tree", "{\"owner\":\"o\",\"repo\":\"r\",\"recursive\":true,\"path_filter\":\"src\"}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/git/trees/main?recursive=1", rig.url(1));
    try std.testing.expectEqualStrings("tree src\nblob src/a.zig 10\n", r.text);
}

test "issues: issue_read methods hit the right endpoints and trim output" {
    var rig = Rig.init(&RO_ENV, &.{
        ok(
            \\{"number":7,"title":"Bug","state":"open","user":{"login":"u","avatar_url":"AV"},"labels":[{"name":"bug","color":"f00"}],"assignees":[{"login":"a"}],"comments":2,"body":"Long body text","html_url":"h","reactions":{"+1":3}}
        ),
        ok("[{\"id\":1,\"user\":{\"login\":\"c\"},\"body\":\"hi\",\"created_at\":\"t\",\"html_url\":\"u\"}]"),
        ok("[]"),
        ok("{}"),
        ok("[{\"name\":\"bug\",\"color\":\"f00\",\"description\":\"d\"}]"),
    });
    defer rig.deinit();
    const r = try rig.call("issue_read", "{\"method\":\"get\",\"owner\":\"o\",\"repo\":\"r\",\"issue_number\":7,\"max_chars\":8}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/issues/7", rig.url(0));
    try has(r.text, "\"labels\":[\"bug\"]");
    try has(r.text, "\"user\":\"u\"");
    try has(r.text, "Long bod...[+");
    try has(r.text, "untrusted");
    try hasNot(r.text, "AV");
    try hasNot(r.text, "reactions");
    const c = try rig.call("issue_read", "{\"method\":\"get_comments\",\"owner\":\"o\",\"repo\":\"r\",\"issue_number\":7,\"perPage\":2}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/issues/7/comments?per_page=2&page=1", rig.url(1));
    try has(c.text, "\"body\":\"hi\"");
    _ = try rig.call("issue_read", "{\"method\":\"get_sub_issues\",\"owner\":\"o\",\"repo\":\"r\",\"issue_number\":7}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/issues/7/sub_issues?per_page=30&page=1", rig.url(2));
    _ = try rig.call("issue_read", "{\"method\":\"get_parent\",\"owner\":\"o\",\"repo\":\"r\",\"issue_number\":7}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/issues/7/parent", rig.url(3));
    _ = try rig.call("issue_read", "{\"method\":\"get_labels\",\"owner\":\"o\",\"repo\":\"r\",\"issue_number\":7}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/issues/7/labels?per_page=30&page=1", rig.url(4));
}

test "issues: issue_write create/update bodies and sub-issue parent attach" {
    var rig = Rig.init(&RW_ENV, &.{
        st(201, "{\"id\":555,\"number\":9,\"title\":\"T\",\"state\":\"open\",\"html_url\":\"u\"}"),
        ok("{}"),
        ok("{\"number\":9,\"title\":\"T2\",\"state\":\"closed\",\"state_reason\":\"not_planned\",\"html_url\":\"u\"}"),
    });
    defer rig.deinit();
    const r = try rig.call("issue_write", "{\"method\":\"create\",\"owner\":\"o\",\"repo\":\"r\",\"title\":\"T\",\"body\":\"B\",\"labels\":[\"bug\"],\"assignees\":[\"a\"],\"parent_issue_number\":3}");
    try std.testing.expect(!r.is_error);
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/issues", rig.url(0));
    try std.testing.expectEqualStrings("{\"title\":\"T\",\"body\":\"B\",\"labels\":[\"bug\"],\"assignees\":[\"a\"]}", rig.req(0).body.?);
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/issues/3/sub_issues", rig.url(1));
    try std.testing.expectEqualStrings("{\"sub_issue_id\":555}", rig.req(1).body.?);
    const u = try rig.call("issue_write", "{\"method\":\"update\",\"owner\":\"o\",\"repo\":\"r\",\"issue_number\":9,\"title\":\"T2\",\"state\":\"closed\",\"state_reason\":\"not_planned\"}");
    try std.testing.expect(!u.is_error);
    try std.testing.expectEqual(std.http.Method.PATCH, rig.req(2).method);
    try std.testing.expectEqualStrings("{\"title\":\"T2\",\"state\":\"closed\",\"state_reason\":\"not_planned\"}", rig.req(2).body.?);
}

test "issues: issue_write rejects unsupported issue_fields and bad enums" {
    var rig = Rig.init(&RW_ENV, &.{});
    defer rig.deinit();
    const a = try rig.call("issue_write", "{\"method\":\"create\",\"owner\":\"o\",\"repo\":\"r\",\"title\":\"t\",\"issue_fields\":[]}");
    try std.testing.expect(a.is_error);
    const b = try rig.call("issue_write", "{\"method\":\"update\",\"owner\":\"o\",\"repo\":\"r\",\"issue_number\":1,\"state\":\"bogus\"}");
    try std.testing.expect(b.is_error);
    try std.testing.expectEqual(@as(usize, 0), rig.n());
}

test "issues: comments, reactions and sub_issue_write" {
    var rig = Rig.init(&RW_ENV, &.{ st(201, "{\"id\":1,\"html_url\":\"u\"}"), ok("{\"id\":2}"), ok("{\"id\":3,\"content\":\"+1\"}"), ok("{\"id\":4,\"content\":\"eyes\"}"), ok("{\"number\":2}"), ok("{\"number\":2}"), ok("{\"number\":2}") });
    defer rig.deinit();
    _ = try rig.call("add_issue_comment", "{\"owner\":\"o\",\"repo\":\"r\",\"issue_number\":3,\"body\":\"hi \\\"q\\\"\"}");
    try std.testing.expectEqualStrings("{\"body\":\"hi \\\"q\\\"\"}", rig.req(0).body.?);
    _ = try rig.call("update_issue_comment", "{\"owner\":\"o\",\"repo\":\"r\",\"comment_id\":44,\"body\":\"edit\"}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/issues/comments/44", rig.url(1));
    _ = try rig.call("add_issue_comment", "{\"owner\":\"o\",\"repo\":\"r\",\"issue_number\":3,\"reaction\":\"+1\"}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/issues/3/reactions", rig.url(2));
    _ = try rig.call("add_issue_comment", "{\"owner\":\"o\",\"repo\":\"r\",\"issue_number\":3,\"comment_id\":8,\"reaction\":\"eyes\"}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/issues/comments/8/reactions", rig.url(3));
    const bad = try rig.call("add_issue_comment", "{\"owner\":\"o\",\"repo\":\"r\",\"issue_number\":3,\"reaction\":\"x\"}");
    try std.testing.expect(bad.is_error);
    const both = try rig.call("add_issue_comment", "{\"owner\":\"o\",\"repo\":\"r\",\"issue_number\":3,\"reaction\":\"+1\",\"body\":\"b\"}");
    try std.testing.expect(both.is_error);
    _ = try rig.call("sub_issue_write", "{\"method\":\"add\",\"owner\":\"o\",\"repo\":\"r\",\"issue_number\":1,\"sub_issue_id\":99,\"replace_parent\":true}");
    try std.testing.expectEqual(std.http.Method.POST, rig.req(4).method);
    try std.testing.expectEqualStrings("{\"sub_issue_id\":99,\"replace_parent\":true}", rig.req(4).body.?);
    _ = try rig.call("sub_issue_write", "{\"method\":\"remove\",\"owner\":\"o\",\"repo\":\"r\",\"issue_number\":1,\"sub_issue_id\":99}");
    try std.testing.expectEqual(std.http.Method.DELETE, rig.req(5).method);
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/issues/1/sub_issue", rig.url(5));
    _ = try rig.call("sub_issue_write", "{\"method\":\"reprioritize\",\"owner\":\"o\",\"repo\":\"r\",\"issue_number\":1,\"sub_issue_id\":99,\"after_id\":7}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/issues/1/sub_issues/priority", rig.url(6));
    try std.testing.expectEqualStrings("{\"sub_issue_id\":99,\"after_id\":7}", rig.req(6).body.?);
}

test "issues: list_issues maps official params, drops PRs, adds pagination hint" {
    var rig = Rig.init(&RO_ENV, &.{.{
        .status = 200,
        .body =
        \\[{"number":1,"title":"Issue","state":"open","user":{"login":"u"},"labels":[{"name":"bug"}],"body":"b"},{"number":2,"title":"A PR","pull_request":{"url":"x"}}]
        ,
        .link = "<https://api.github.com/x?page=2>; rel=\"next\", <https://api.github.com/x?page=9>; rel=\"last\"",
    }});
    defer rig.deinit();
    const r = try rig.call("list_issues", "{\"owner\":\"o\",\"repo\":\"r\",\"state\":\"OPEN\",\"labels\":[\"bug\",\"help wanted\"],\"orderBy\":\"UPDATED_AT\",\"direction\":\"DESC\",\"since\":\"2024-01-01T00:00:00Z\"}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/issues?per_page=30&page=1&state=open&labels=bug%2Chelp%20wanted&sort=updated&direction=desc&since=2024-01-01T00%3A00%3A00Z", rig.url(0));
    try has(r.text, "\"number\":1");
    try hasNot(r.text, "A PR");
    try has(r.text, "[more results: next page=2 (perPage=30)]");
}

test "issues: search_issues scopes to is:issue and repo; labels and types" {
    var rig = Rig.init(&RO_ENV, &.{ ok("{\"total_count\":0,\"items\":[]}"), ok("[{\"id\":1,\"name\":\"Bug\",\"description\":\"d\",\"is_enabled\":true}]"), ok("{\"name\":\"bug\",\"color\":\"f00\"}") });
    defer rig.deinit();
    _ = try rig.call("search_issues", "{\"query\":\"login fails\",\"owner\":\"o\",\"repo\":\"r\",\"sort\":\"updated\",\"order\":\"desc\"}");
    try std.testing.expectEqualStrings(API ++ "/search/issues?per_page=30&page=1&q=login%20fails%20is%3Aissue%20repo%3Ao%2Fr&sort=updated&order=desc", rig.url(0));
    const t = try rig.call("list_issue_types", "{\"owner\":\"acme\"}");
    try std.testing.expectEqualStrings(API ++ "/orgs/acme/issue-types", rig.url(1));
    try has(t.text, "Bug");
    _ = try rig.call("get_label", "{\"owner\":\"o\",\"repo\":\"r\",\"name\":\"good first issue\"}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/labels/good%20first%20issue", rig.url(2));
}

test "labels: label_write create/update/delete" {
    var rig = Rig.init(&DES_ENV, &.{ st(201, "{\"name\":\"n\",\"color\":\"aabbcc\"}"), ok("{\"name\":\"n2\",\"color\":\"aabbcc\"}"), st(204, "") });
    defer rig.deinit();
    _ = try rig.call("label_write", "{\"method\":\"create\",\"owner\":\"o\",\"repo\":\"r\",\"name\":\"n\",\"color\":\"aabbcc\",\"description\":\"d\"}");
    try std.testing.expectEqualStrings("{\"name\":\"n\",\"color\":\"aabbcc\",\"description\":\"d\"}", rig.req(0).body.?);
    _ = try rig.call("label_write", "{\"method\":\"update\",\"owner\":\"o\",\"repo\":\"r\",\"name\":\"n\",\"new_name\":\"n2\"}");
    try std.testing.expectEqual(std.http.Method.PATCH, rig.req(1).method);
    try std.testing.expectEqualStrings("{\"new_name\":\"n2\"}", rig.req(1).body.?);
    _ = try rig.call("label_write", "{\"method\":\"delete\",\"owner\":\"o\",\"repo\":\"r\",\"name\":\"n2\"}");
    try std.testing.expectEqual(std.http.Method.DELETE, rig.req(2).method);
    const bad = try rig.call("label_write", "{\"method\":\"create\",\"owner\":\"o\",\"repo\":\"r\",\"name\":\"n\",\"color\":\"#fff\"}");
    try std.testing.expect(bad.is_error);
}

test "pulls: pull_request_read methods" {
    var rig = Rig.init(&RO_ENV, &.{
        ok("{\"number\":5,\"title\":\"P\",\"state\":\"open\",\"draft\":false,\"merged\":false,\"user\":{\"login\":\"u\"},\"head\":{\"ref\":\"f\",\"sha\":\"abcd1234\"},\"base\":{\"ref\":\"main\"},\"changed_files\":2,\"body\":\"desc\",\"html_url\":\"h\"}"),
        ok("diff --git a/x b/x\n+line\n"),
        ok("[{\"filename\":\"a.zig\",\"status\":\"modified\",\"additions\":1,\"deletions\":0,\"changes\":1,\"patch\":\"@@ big\"}]"),
        ok("{\"head\":{\"sha\":\"abcd1234\"}}"),
        ok("{\"state\":\"success\",\"sha\":\"abcd1234\",\"total_count\":1,\"statuses\":[{\"context\":\"ci\",\"state\":\"success\"}]}"),
        ok("{\"head\":{\"sha\":\"abcd1234\"}}"),
        ok("{\"total_count\":1,\"check_runs\":[{\"id\":1,\"name\":\"build\",\"status\":\"completed\",\"conclusion\":\"success\",\"html_url\":\"h\"}]}"),
    });
    defer rig.deinit();
    const g = try rig.call("pull_request_read", "{\"method\":\"get\",\"owner\":\"o\",\"repo\":\"r\",\"pullNumber\":5}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/pulls/5", rig.url(0));
    try has(g.text, "\"head\":\"f\"");
    try has(g.text, "\"head_sha\":\"abcd1234\"");
    const d = try rig.call("pull_request_read", "{\"method\":\"get_diff\",\"owner\":\"o\",\"repo\":\"r\",\"pullNumber\":5}");
    try std.testing.expectEqualStrings("application/vnd.github.v3.diff", rig.req(1).accept);
    try has(d.text, "+line");
    const f = try rig.call("pull_request_read", "{\"method\":\"get_files\",\"owner\":\"o\",\"repo\":\"r\",\"pullNumber\":5}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/pulls/5/files?per_page=30&page=1", rig.url(2));
    try hasNot(f.text, "@@ big");
    const s = try rig.call("pull_request_read", "{\"method\":\"get_status\",\"owner\":\"o\",\"repo\":\"r\",\"pullNumber\":5}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/commits/abcd1234/status", rig.url(4));
    try has(s.text, "ci: success");
    const ck = try rig.call("pull_request_read", "{\"method\":\"get_check_runs\",\"owner\":\"o\",\"repo\":\"r\",\"pullNumber\":5}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/commits/abcd1234/check-runs?per_page=30&page=1", rig.url(6));
    try has(ck.text, "\"name\":\"build\"");
}

test "pulls: huge diff is capped with a hint" {
    const big = try std.testing.allocator.alloc(u8, 200 * 1024);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    var rig = Rig.init(&RO_ENV, &.{ok(big)});
    defer rig.deinit();
    const d = try rig.call("pull_request_read", "{\"method\":\"get_diff\",\"owner\":\"o\",\"repo\":\"r\",\"pullNumber\":5}");
    try std.testing.expect(d.text.len < 70 * 1024);
    try has(d.text, "truncated");
}

test "pulls: review threads use GraphQL with variables and cursor" {
    var rig = Rig.init(&RO_ENV, &.{ok(
        \\{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":true,"endCursor":"CUR"},"nodes":[{"id":"PRRT_1","isResolved":false,"isOutdated":false,"path":"a.zig","line":3,"comments":{"nodes":[{"databaseId":11,"author":{"login":"rev"},"body":"nit","createdAt":"t","url":"u"}]}}]}}}}}
    )});
    defer rig.deinit();
    const r = try rig.call("pull_request_read", "{\"method\":\"get_review_comments\",\"owner\":\"o\",\"repo\":\"r\",\"pullNumber\":5,\"perPage\":10,\"after\":\"PREV\"}");
    try std.testing.expectEqual(std.http.Method.POST, rig.req(0).method);
    try std.testing.expectEqualStrings(API ++ "/graphql", rig.url(0));
    try has(rig.req(0).body.?, "\"variables\":{\"o\":\"o\",\"r\":\"r\",\"n\":5,\"per\":10,\"after\":\"PREV\"}");
    try has(rig.req(0).body.?, "reviewThreads(first:$per,after:$after)");
    try has(r.text, "\"id\":\"PRRT_1\"");
    try has(r.text, "\"user\":\"rev\"");
    try has(r.text, "[more threads: after=CUR (perPage=10)]");
}

test "pulls: create, update (+draft via GraphQL), merge, update-branch" {
    var rig = Rig.init(&DES_ENV, &.{
        st(201, "{\"number\":12,\"title\":\"T\",\"state\":\"open\",\"draft\":false,\"html_url\":\"u\"}"),
        ok("{}"),
        ok("{\"number\":12,\"title\":\"T2\",\"state\":\"open\",\"draft\":false,\"node_id\":\"PR_kw1\",\"html_url\":\"u\"}"),
        ok("{\"data\":{}}"),
        ok("{\"merged\":true,\"sha\":\"m1\",\"message\":\"Pull Request successfully merged\"}"),
        ok("{\"message\":\"Updating pull request branch.\",\"url\":\"u\"}"),
    });
    defer rig.deinit();
    _ = try rig.call("create_pull_request", "{\"owner\":\"o\",\"repo\":\"r\",\"title\":\"T\",\"head\":\"me:feat\",\"base\":\"main\",\"body\":\"B\",\"draft\":false,\"reviewers\":[\"rev1\"]}");
    try std.testing.expectEqualStrings("{\"title\":\"T\",\"head\":\"me:feat\",\"base\":\"main\",\"body\":\"B\",\"draft\":false}", rig.req(0).body.?);
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/pulls/12/requested_reviewers", rig.url(1));
    try std.testing.expectEqualStrings("{\"reviewers\":[\"rev1\"]}", rig.req(1).body.?);
    _ = try rig.call("update_pull_request", "{\"owner\":\"o\",\"repo\":\"r\",\"pullNumber\":12,\"title\":\"T2\",\"draft\":true}");
    try std.testing.expectEqual(std.http.Method.PATCH, rig.req(2).method);
    try std.testing.expectEqualStrings("{\"title\":\"T2\"}", rig.req(2).body.?);
    try has(rig.req(3).body.?, "convertPullRequestToDraft");
    try has(rig.req(3).body.?, "\"variables\":{\"id\":\"PR_kw1\"}");
    const m = try rig.call("merge_pull_request", "{\"owner\":\"o\",\"repo\":\"r\",\"pullNumber\":12,\"merge_method\":\"squash\",\"expectedHeadSha\":\"abc1234\"}");
    try std.testing.expectEqual(std.http.Method.PUT, rig.req(4).method);
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/pulls/12/merge", rig.url(4));
    try std.testing.expectEqualStrings("{\"merge_method\":\"squash\",\"sha\":\"abc1234\"}", rig.req(4).body.?);
    try has(m.text, "\"merged\":true");
    _ = try rig.call("update_pull_request_branch", "{\"owner\":\"o\",\"repo\":\"r\",\"pullNumber\":12,\"expectedHeadSha\":\"abc1234\"}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/pulls/12/update-branch", rig.url(5));
    try std.testing.expectEqualStrings("{\"expected_head_sha\":\"abc1234\"}", rig.req(5).body.?);
}

test "pulls: pending review workflow and thread resolution" {
    var rig = Rig.init(&DES_ENV, &.{
        st(200, "{\"id\":77,\"state\":\"PENDING\",\"html_url\":\"u\"}"),
        ok("{\"data\":{\"viewer\":{\"login\":\"me\"},\"repository\":{\"pullRequest\":{\"id\":\"PR_1\",\"reviews\":{\"nodes\":[{\"id\":\"PRR_other\",\"author\":{\"login\":\"x\"}},{\"id\":\"PRR_mine\",\"author\":{\"login\":\"me\"}}]}}}}}"),
        ok("{\"data\":{\"addPullRequestReviewThread\":{\"thread\":{\"id\":\"PRRT_9\"}}}}"),
        ok("[{\"id\":76,\"state\":\"APPROVED\"},{\"id\":77,\"state\":\"PENDING\"}]"),
        ok("{\"id\":77,\"state\":\"COMMENTED\",\"html_url\":\"u\"}"),
        ok("{\"data\":{\"resolveReviewThread\":{\"thread\":{\"id\":\"PRRT_9\",\"isResolved\":true}}}}"),
    });
    defer rig.deinit();
    _ = try rig.call("pull_request_review_write", "{\"method\":\"create\",\"owner\":\"o\",\"repo\":\"r\",\"pullNumber\":5}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/pulls/5/reviews", rig.url(0));
    try std.testing.expectEqualStrings("{}", rig.req(0).body.?);
    const c = try rig.call("add_comment_to_pending_review", "{\"owner\":\"o\",\"repo\":\"r\",\"pullNumber\":5,\"path\":\"a.zig\",\"body\":\"nit\",\"subjectType\":\"LINE\",\"line\":3,\"side\":\"RIGHT\"}");
    try std.testing.expect(!c.is_error);
    try has(rig.req(2).body.?, "\"input\":{\"pullRequestReviewId\":\"PRR_mine\",\"path\":\"a.zig\",\"body\":\"nit\",\"subjectType\":\"LINE\",\"line\":3,\"side\":\"RIGHT\"}");
    _ = try rig.call("pull_request_review_write", "{\"method\":\"submit_pending\",\"owner\":\"o\",\"repo\":\"r\",\"pullNumber\":5,\"event\":\"COMMENT\",\"body\":\"done\"}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/pulls/5/reviews/77/events", rig.url(4));
    try std.testing.expectEqualStrings("{\"body\":\"done\",\"event\":\"COMMENT\"}", rig.req(4).body.?);
    const t = try rig.call("pull_request_review_write", "{\"method\":\"resolve_thread\",\"threadId\":\"PRRT_9\"}");
    try has(t.text, "resolved");
    try has(rig.req(5).body.?, "resolveReviewThread");
    const bad = try rig.call("pull_request_review_write", "{\"method\":\"resolve_thread\",\"threadId\":\"PRRT\\\" x\"}");
    try std.testing.expect(bad.is_error);
}

test "pulls: replies, reactions, search and copilot review" {
    var rig = Rig.init(&RW_ENV, &.{ st(201, "{\"id\":5,\"html_url\":\"u\"}"), ok("{\"total_count\":0,\"items\":[]}"), ok("{}") });
    defer rig.deinit();
    _ = try rig.call("add_reply_to_pull_request_comment", "{\"owner\":\"o\",\"repo\":\"r\",\"pullNumber\":5,\"commentId\":11,\"body\":\"ok\"}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/pulls/5/comments/11/replies", rig.url(0));
    _ = try rig.call("search_pull_requests", "{\"query\":\"is:open author:me\",\"owner\":\"o\"}");
    try std.testing.expectEqualStrings(API ++ "/search/issues?per_page=30&page=1&q=is%3Aopen%20author%3Ame%20is%3Apr%20user%3Ao", rig.url(1));
    _ = try rig.call("request_copilot_review", "{\"owner\":\"o\",\"repo\":\"r\",\"pullNumber\":5}");
    try has(rig.req(2).body.?, "copilot-pull-request-reviewer[bot]");
}

test "actions: list/get shapes, filters and compact output" {
    var rig = Rig.init(&RO_ENV, &.{
        ok("{\"total_count\":1,\"workflow_runs\":[{\"id\":9,\"name\":\"CI\",\"status\":\"completed\",\"conclusion\":\"failure\",\"head_branch\":\"main\",\"head_sha\":\"abc\",\"actor\":{\"login\":\"u\",\"avatar_url\":\"AV\"},\"html_url\":\"h\",\"repository\":{\"id\":1}}]}"),
        ok("{\"total_count\":0,\"workflows\":[]}"),
        ok("{\"total_count\":0,\"jobs\":[]}"),
        ok("{\"id\":5,\"name\":\"build\",\"status\":\"completed\",\"conclusion\":\"failure\",\"steps\":[{\"name\":\"Run tests\",\"conclusion\":\"failure\"}]}"),
    });
    defer rig.deinit();
    const r = try rig.call("actions_list", "{\"method\":\"list_workflow_runs\",\"owner\":\"o\",\"repo\":\"r\",\"resource_id\":\"ci.yml\",\"workflow_runs_filter\":{\"branch\":\"main\",\"status\":\"completed\"},\"perPage\":5}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/actions/workflows/ci.yml/runs?per_page=5&page=1&branch=main&status=completed", rig.url(0));
    try has(r.text, "\"conclusion\":\"failure\"");
    try hasNot(r.text, "AV");
    try hasNot(r.text, "repository");
    _ = try rig.call("actions_list", "{\"method\":\"list_workflows\",\"owner\":\"o\",\"repo\":\"r\"}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/actions/workflows?per_page=30&page=1", rig.url(1));
    _ = try rig.call("actions_list", "{\"method\":\"list_workflow_jobs\",\"owner\":\"o\",\"repo\":\"r\",\"resource_id\":\"9\",\"workflow_jobs_filter\":{\"filter\":\"latest\"}}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/actions/runs/9/jobs?per_page=30&page=1&filter=latest", rig.url(2));
    const j = try rig.call("actions_get", "{\"method\":\"get_workflow_job\",\"owner\":\"o\",\"repo\":\"r\",\"resource_id\":\"5\"}");
    try has(j.text, "Run tests: failure");
}

test "actions: log URL without following, log content tailed, failed_only" {
    var rig = Rig.init(&RO_ENV, &.{
        .{ .status = 302, .body = "", .location = "https://logs.example/z" },
        .{ .status = 302, .body = "", .location = "https://logs.example/j" },
        ok("2024-01-01T00:00:00.0000000Z a\n2024-01-01T00:00:01.0000000Z b\n2024-01-01T00:00:02.0000000Z c\n"),
        ok("{\"jobs\":[{\"id\":1,\"name\":\"ok\",\"conclusion\":\"success\"},{\"id\":2,\"name\":\"bad\",\"conclusion\":\"failure\"}]}"),
        ok("2024-01-01T00:00:00.0000000Z boom\n"),
    });
    defer rig.deinit();
    const u = try rig.call("actions_get", "{\"method\":\"get_workflow_run_logs_url\",\"owner\":\"o\",\"repo\":\"r\",\"resource_id\":\"9\"}");
    try std.testing.expect(!rig.req(0).follow);
    try has(u.text, "https://logs.example/z");
    const l1 = try rig.call("get_job_logs", "{\"owner\":\"o\",\"repo\":\"r\",\"job_id\":5}");
    try has(l1.text, "https://logs.example/j");
    const l2 = try rig.call("get_job_logs", "{\"owner\":\"o\",\"repo\":\"r\",\"job_id\":5,\"return_content\":true,\"tail_lines\":2}");
    try std.testing.expectEqualStrings("[log truncated: last 2 of 3 lines]\nb\nc\n", l2.text);
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/actions/jobs/5/logs", rig.url(2));
    const l3 = try rig.call("get_job_logs", "{\"owner\":\"o\",\"repo\":\"r\",\"run_id\":9,\"failed_only\":true,\"return_content\":true}");
    try has(l3.text, "== job 2 bad ==");
    try has(l3.text, "boom");
    try hasNot(l3.text, "job 1");
}

test "actions: run_workflow dispatch body, rerun, cancel, delete logs" {
    var rig = Rig.init(&DES_ENV, &.{ st(204, ""), st(201, ""), st(202, ""), st(204, "") });
    defer rig.deinit();
    _ = try rig.call("actions_run_trigger", "{\"method\":\"run_workflow\",\"owner\":\"o\",\"repo\":\"r\",\"workflow_id\":\"ci.yml\",\"ref\":\"main\",\"inputs\":{\"k\":\"v\"}}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/actions/workflows/ci.yml/dispatches", rig.url(0));
    try std.testing.expectEqualStrings("{\"ref\":\"main\",\"inputs\":{\"k\":\"v\"}}", rig.req(0).body.?);
    _ = try rig.call("actions_run_trigger", "{\"method\":\"rerun_failed_jobs\",\"owner\":\"o\",\"repo\":\"r\",\"run_id\":9}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/actions/runs/9/rerun-failed-jobs", rig.url(1));
    _ = try rig.call("actions_run_trigger", "{\"method\":\"cancel_workflow_run\",\"owner\":\"o\",\"repo\":\"r\",\"run_id\":9}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/actions/runs/9/cancel", rig.url(2));
    _ = try rig.call("actions_run_trigger", "{\"method\":\"delete_workflow_run_logs\",\"owner\":\"o\",\"repo\":\"r\",\"run_id\":9}");
    try std.testing.expectEqual(std.http.Method.DELETE, rig.req(3).method);
}

test "security: alerts endpoints; secret values are never returned" {
    var rig = Rig.init(&RO_ENV, &.{
        ok("{\"number\":1,\"state\":\"open\",\"secret_type\":\"github_pat\",\"secret_type_display_name\":\"GitHub PAT\",\"secret\":\"ghp_SUPERSECRET\",\"html_url\":\"h\"}"),
        ok("[{\"number\":2,\"state\":\"open\",\"secret\":\"ghp_SUPERSECRET2\",\"secret_type\":\"x\"}]"),
        ok("[{\"number\":3,\"state\":\"open\",\"rule\":{\"id\":\"r1\",\"severity\":\"error\",\"description\":\"d\"},\"tool\":{\"name\":\"CodeQL\"},\"html_url\":\"h\"}]"),
        .{ .status = 200, .body = "[{\"number\":4,\"state\":\"open\",\"dependency\":{\"package\":{\"name\":\"lodash\",\"ecosystem\":\"npm\"}},\"security_advisory\":{\"severity\":\"high\",\"ghsa_id\":\"GHSA-x\"}}]", .link = "<https://api.github.com/x?per_page=30&after=CURSOR1>; rel=\"next\"" },
    });
    defer rig.deinit();
    const a = try rig.call("get_secret_scanning_alert", "{\"owner\":\"o\",\"repo\":\"r\",\"alertNumber\":1}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/secret-scanning/alerts/1", rig.url(0));
    try hasNot(a.text, "SUPERSECRET");
    const b = try rig.call("list_secret_scanning_alerts", "{\"owner\":\"o\",\"repo\":\"r\",\"state\":\"open\",\"secret_type\":\"github_pat\"}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/secret-scanning/alerts?per_page=30&page=1&state=open&secret_type=github_pat", rig.url(1));
    try hasNot(b.text, "SUPERSECRET");
    const c = try rig.call("list_code_scanning_alerts", "{\"owner\":\"o\",\"repo\":\"r\",\"severity\":\"error\",\"tool_name\":\"CodeQL\",\"ref\":\"main\"}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/code-scanning/alerts?per_page=30&page=1&severity=error&tool_name=CodeQL&ref=main", rig.url(2));
    try has(c.text, "\"tool\":\"CodeQL\"");
    const d = try rig.call("list_dependabot_alerts", "{\"owner\":\"o\",\"repo\":\"r\",\"severity\":\"high\"}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/dependabot/alerts?per_page=30&severity=high", rig.url(3));
    try has(d.text, "\"package\":\"lodash\"");
    try has(d.text, "[more results: after=CURSOR1]");
}

test "security: advisories" {
    var rig = Rig.init(&RO_ENV, &.{ ok("[]"), ok("[]"), ok("[]"), ok("{\"ghsa_id\":\"GHSA-1\",\"summary\":\"s\",\"severity\":\"high\"}") });
    defer rig.deinit();
    _ = try rig.call("list_global_security_advisories", "{\"ecosystem\":\"npm\",\"severity\":\"high\",\"cwes\":[\"79\",\"89\"],\"isWithdrawn\":false}");
    try std.testing.expectEqualStrings(API ++ "/advisories?per_page=30&page=1&ecosystem=npm&severity=high&is_withdrawn=false&cwes=79%2C89", rig.url(0));
    _ = try rig.call("list_repository_security_advisories", "{\"owner\":\"o\",\"repo\":\"r\",\"state\":\"published\"}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/security-advisories?per_page=30&page=1&state=published", rig.url(1));
    _ = try rig.call("list_org_repository_security_advisories", "{\"org\":\"acme\"}");
    try std.testing.expectEqualStrings(API ++ "/orgs/acme/security-advisories?per_page=30&page=1", rig.url(2));
    _ = try rig.call("get_global_security_advisory", "{\"ghsaId\":\"GHSA-xxxx-yyyy-zzzz\"}");
    try std.testing.expectEqualStrings(API ++ "/advisories/GHSA-xxxx-yyyy-zzzz", rig.url(3));
}

test "notifications: list filters, dismiss done, subscriptions" {
    var rig = Rig.init(&RW_ENV, &.{ ok("[{\"id\":\"1\",\"unread\":true,\"reason\":\"mention\",\"subject\":{\"title\":\"T\",\"type\":\"Issue\",\"url\":\"u\"},\"repository\":{\"full_name\":\"o/r\"}}]"), st(204, ""), st(205, ""), ok("{}"), st(204, ""), ok("{}"), ok("{}") });
    defer rig.deinit();
    const l = try rig.call("list_notifications", "{\"filter\":\"include_read_notifications\",\"owner\":\"o\",\"repo\":\"r\"}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/notifications?per_page=30&page=1&all=true", rig.url(0));
    try has(l.text, "\"title\":\"T\"");
    _ = try rig.call("dismiss_notification", "{\"threadID\":\"12\",\"state\":\"done\"}");
    try std.testing.expectEqual(std.http.Method.DELETE, rig.req(1).method);
    try std.testing.expectEqualStrings(API ++ "/notifications/threads/12", rig.url(1));
    _ = try rig.call("dismiss_notification", "{\"threadID\":\"12\",\"state\":\"read\"}");
    try std.testing.expectEqual(std.http.Method.PATCH, rig.req(2).method);
    _ = try rig.call("mark_all_notifications_read", "{}");
    try std.testing.expectEqual(std.http.Method.PUT, rig.req(3).method);
    try std.testing.expectEqualStrings(API ++ "/notifications", rig.url(3));
    _ = try rig.call("manage_notification_subscription", "{\"notificationID\":\"12\",\"action\":\"delete\"}");
    try std.testing.expectEqual(std.http.Method.DELETE, rig.req(4).method);
    _ = try rig.call("manage_notification_subscription", "{\"notificationID\":\"12\",\"action\":\"ignore\"}");
    try std.testing.expectEqualStrings("{\"ignored\":true}", rig.req(5).body.?);
    _ = try rig.call("manage_repository_notification_subscription", "{\"owner\":\"o\",\"repo\":\"r\",\"action\":\"watch\"}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/subscription", rig.url(6));
}

test "gists: list, get, create, update" {
    var rig = Rig.init(&RW_ENV, &.{
        ok("[{\"id\":\"g1\",\"description\":\"d\",\"public\":true,\"files\":{\"a.txt\":{\"size\":1},\"b.md\":{\"size\":2}},\"html_url\":\"h\",\"owner\":{\"avatar_url\":\"AV\"}}]"),
        ok("{\"id\":\"g1\",\"files\":{\"a.txt\":{\"content\":\"hello\"}},\"html_url\":\"h\"}"),
        st(201, "{\"id\":\"g2\",\"html_url\":\"h\",\"public\":false}"),
        ok("{\"id\":\"g2\",\"html_url\":\"h\"}"),
    });
    defer rig.deinit();
    const l = try rig.call("list_gists", "{\"username\":\"octo\"}");
    try std.testing.expectEqualStrings(API ++ "/users/octo/gists?per_page=30&page=1", rig.url(0));
    try has(l.text, "\"files\":[\"a.txt\",\"b.md\"]");
    try hasNot(l.text, "AV");
    const g = try rig.call("get_gist", "{\"gist_id\":\"g1\"}");
    try has(g.text, "--- a.txt ---\nhello");
    _ = try rig.call("create_gist", "{\"filename\":\"n.txt\",\"content\":\"body\",\"description\":\"d\",\"public\":false}");
    try std.testing.expectEqualStrings("{\"description\":\"d\",\"public\":false,\"files\":{\"n.txt\":{\"content\":\"body\"}}}", rig.req(2).body.?);
    _ = try rig.call("update_gist", "{\"gist_id\":\"g2\",\"filename\":\"n.txt\",\"content\":\"new\"}");
    try std.testing.expectEqual(std.http.Method.PATCH, rig.req(3).method);
    try std.testing.expectEqualStrings("{\"files\":{\"n.txt\":{\"content\":\"new\"}}}", rig.req(3).body.?);
}

test "discussions: GraphQL request shape, compact output, comment writes" {
    var rig = Rig.init(&DES_ENV, &.{
        ok("{\"data\":{\"repository\":{\"discussions\":{\"totalCount\":1,\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":\"C1\"},\"nodes\":[{\"number\":4,\"title\":\"Q\",\"closed\":false,\"author\":{\"login\":\"u\"},\"category\":{\"name\":\"General\"},\"comments\":{\"totalCount\":2},\"url\":\"h\"}]}}}}"),
        ok("{\"data\":{\"repository\":{\"discussion\":{\"id\":\"D_1\"}}}}"),
        ok("{\"data\":{\"addDiscussionComment\":{\"comment\":{\"id\":\"DC_1\",\"url\":\"u\"}}}}"),
        ok("{\"data\":{\"deleteDiscussionComment\":{\"comment\":{\"id\":\"DC_1\"}}}}"),
        ok("{\"errors\":[{\"message\":\"Could not resolve to a Repository\"}],\"data\":null}"),
    });
    defer rig.deinit();
    const l = try rig.call("list_discussions", "{\"owner\":\"o\",\"repo\":\"r\",\"orderBy\":\"CREATED_AT\",\"direction\":\"DESC\",\"perPage\":5}");
    try has(rig.req(0).body.?, "\"variables\":{\"o\":\"o\",\"r\":\"r\",\"first\":5,\"order\":{\"field\":\"CREATED_AT\",\"direction\":\"DESC\"}}");
    try has(l.text, "\"number\":4");
    try has(l.text, "[more results: after=C1 (perPage=5)]");
    const a = try rig.call("discussion_comment_write", "{\"method\":\"add\",\"owner\":\"o\",\"repo\":\"r\",\"discussionNumber\":4,\"body\":\"hey\"}");
    try std.testing.expect(!a.is_error);
    try has(rig.req(2).body.?, "\"variables\":{\"input\":{\"discussionId\":\"D_1\",\"body\":\"hey\"}}");
    _ = try rig.call("discussion_comment_write", "{\"method\":\"delete\",\"commentNodeID\":\"DC_1\"}");
    try has(rig.req(3).body.?, "deleteDiscussionComment");
    const e = try rig.call("list_discussion_categories", "{\"owner\":\"o\",\"repo\":\"nope\"}");
    try std.testing.expect(e.is_error);
    try has(e.text, "Could not resolve to a Repository");
}

test "projects: owner type detection, listing and item updates by field name" {
    var rig = Rig.init(&RW_ENV, &.{
        ok("{\"type\":\"Organization\"}"),
        ok("[{\"number\":3,\"title\":\"Roadmap\",\"public\":true}]"),
        ok("[{\"id\":10,\"name\":\"Status\",\"data_type\":\"single_select\",\"options\":[{\"id\":\"o1\",\"name\":\"Todo\"},{\"id\":\"o2\",\"name\":\"Done\"}]}]"),
        ok("{\"id\":55,\"content_type\":\"Issue\"}"),
    });
    defer rig.deinit();
    const l = try rig.call("projects_list", "{\"method\":\"list_projects\",\"owner\":\"acme\",\"query\":\"road\",\"perPage\":10}");
    try std.testing.expectEqualStrings(API ++ "/users/acme", rig.url(0));
    try std.testing.expectEqualStrings(API ++ "/orgs/acme/projectsV2?per_page=10&q=road", rig.url(1));
    try has(l.text, "\"title\":\"Roadmap\"");
    _ = try rig.call("projects_write", "{\"method\":\"update_project_item\",\"owner\":\"acme\",\"owner_type\":\"org\",\"project_number\":3,\"item_id\":55,\"updated_field\":{\"name\":\"Status\",\"value\":\"Done\"}}");
    try std.testing.expectEqualStrings(API ++ "/orgs/acme/projectsV2/3/fields?per_page=100", rig.url(2));
    try std.testing.expectEqual(std.http.Method.PATCH, rig.req(3).method);
    try std.testing.expectEqualStrings(API ++ "/orgs/acme/projectsV2/3/items/55", rig.url(3));
    try std.testing.expectEqualStrings("{\"fields\":[{\"id\":10,\"value\":\"o2\"}]}", rig.req(3).body.?);
}

test "stargazers and context" {
    var rig = Rig.init(&RO_ENV, &.{ ok("[{\"full_name\":\"a/b\",\"stargazers_count\":5}]"), ok("[{\"slug\":\"core\",\"name\":\"Core\",\"organization\":{\"login\":\"acme\"}}]"), ok("[{\"login\":\"m\"}]") });
    defer rig.deinit();
    _ = try rig.call("list_starred_repositories", "{\"username\":\"octo\",\"sort\":\"updated\",\"direction\":\"desc\"}");
    try std.testing.expectEqualStrings(API ++ "/users/octo/starred?per_page=30&page=1&sort=updated&direction=desc", rig.url(0));
    const t = try rig.call("get_teams", "{}");
    try std.testing.expectEqualStrings(API ++ "/user/teams?per_page=30&page=1", rig.url(1));
    try has(t.text, "\"org\":\"acme\"");
    _ = try rig.call("get_team_members", "{\"org\":\"acme\",\"team_slug\":\"core\"}");
    try std.testing.expectEqualStrings(API ++ "/orgs/acme/teams/core/members?per_page=30&page=1", rig.url(2));
}

// ---------------------------------------------------------------------------
// Pagination, errors, GraphQL helper, compaction
// ---------------------------------------------------------------------------

test "pagination: caps perPage at 100, floors at 1, page floors at 1, hint only with next link" {
    var rig = Rig.init(&RO_ENV, &.{ ok("[]"), ok("[]"), .{ .status = 200, .body = "[]", .link = "<x>; rel=\"next\"" } });
    defer rig.deinit();
    _ = try rig.call("list_branches", "{\"owner\":\"o\",\"repo\":\"r\",\"perPage\":5000,\"page\":0}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/branches?per_page=100&page=1", rig.url(0));
    const r = try rig.call("list_branches", "{\"owner\":\"o\",\"repo\":\"r\",\"perPage\":-3}");
    try std.testing.expectEqualStrings(API ++ "/repos/o/r/branches?per_page=1&page=1", rig.url(1));
    try hasNot(r.text, "more results");
    const h = try rig.call("list_tags", "{\"owner\":\"o\",\"repo\":\"r\",\"page\":4,\"perPage\":50}");
    try has(h.text, "[more results: next page=5 (perPage=50)]");
}

test "errors: status mapping never leaks the token and includes reset/retry hints" {
    const Case = struct { resp: Resp, want: []const u8 };
    const cases = [_]Case{
        .{ .resp = st(401, "{\"message\":\"Bad credentials\"}"), .want = "GitHub 401" },
        .{ .resp = st(403, "{\"message\":\"Resource not accessible by personal access token\"}"), .want = "GitHub 403: forbidden" },
        .{ .resp = .{ .status = 403, .body = "{\"message\":\"API rate limit exceeded\"}", .rl_remaining = "0", .rl_reset = "1700000000" }, .want = "resets at 2023-11-14T22:13:20Z" },
        .{ .resp = .{ .status = 403, .body = "{\"message\":\"You have exceeded a secondary rate limit\"}", .retry_after = "60" }, .want = "retry after 60s" },
        .{ .resp = .{ .status = 429, .body = "{}", .retry_after = "7" }, .want = "retry after 7s" },
        .{ .resp = st(404, "{\"message\":\"Not Found\"}"), .want = "GitHub 404" },
        .{ .resp = st(409, "{\"message\":\"Merge conflict\"}"), .want = "GitHub 409: conflict. Merge conflict" },
        .{ .resp = st(422, "{\"message\":\"Validation Failed\",\"errors\":[{\"resource\":\"Issue\",\"field\":\"title\",\"code\":\"missing_field\"}]}"), .want = "title" },
        .{ .resp = st(500, "<html>oops</html>"), .want = "GitHub HTTP 500" },
    };
    for (cases) |cs| {
        var rig = Rig.init(&RO_ENV, &.{cs.resp});
        defer rig.deinit();
        const r = try rig.call("get_me", "{}");
        try std.testing.expect(r.is_error);
        try has(r.text, cs.want);
        try hasNot(r.text, "test-token");
        try hasNot(r.text, "Authorization");
    }
}

test "graphql helper: request shape, data extraction, errors" {
    var rig = Rig.init(&RO_ENV, &.{ ok("{\"data\":{\"viewer\":{\"login\":\"me\"}}}"), ok("{\"errors\":[{\"message\":\"boom\"}]}"), st(502, "bad gateway") });
    defer rig.deinit();
    var c: core.Call = .{ .alloc = rig.arena.allocator(), .io = std.testing.io, .args = .null };
    const d = try c.graphql("query($x:Int!){viewer{login}}", "{\"x\":1}");
    try std.testing.expectEqual(std.http.Method.POST, rig.req(0).method);
    try std.testing.expectEqualStrings(API ++ "/graphql", rig.url(0));
    try std.testing.expectEqualStrings("{\"query\":\"query($x:Int!){viewer{login}}\",\"variables\":{\"x\":1}}", rig.req(0).body.?);
    try std.testing.expectEqualStrings("me", d.object.get("viewer").?.object.get("login").?.string);
    try std.testing.expectError(error.ToolFail, c.graphql("q", null));
    try has(core.fail_msg, "boom");
    try std.testing.expectError(error.ToolFail, c.graphql("q", null));
    try has(core.fail_msg, "502");
}

test "compaction: projection DSL drops noise, truncates, maps arrays" {
    var rig = Rig.init(&RO_ENV, &.{});
    defer rig.deinit();
    var c: core.Call = .{ .alloc = rig.arena.allocator(), .io = std.testing.io, .args = .null, .max_chars = 5 };
    const v = try std.json.parseFromSliceLeaky(std.json.Value, c.alloc,
        \\{"number":1,"title":"T","body":"0123456789","empty":"","none":null,"user":{"login":"u","avatar_url":"A"},"labels":[{"name":"a"},{"name":"b"}],"draft":false}
    , .{});
    const out = try c.obj(v, "number,title,body~B,empty,none,user.login>user,labels[].name>labels,draft,missing");
    try std.testing.expectEqualStrings("{\"number\":1,\"title\":\"T\",\"body\":\"01234...[+5 chars truncated]\",\"user\":\"u\",\"labels\":[\"a\",\"b\"],\"draft\":false}", out);
}

test "compaction: outputs beyond 64 KiB are truncated with a hint" {
    const big = try std.testing.allocator.alloc(u8, 300 * 1024);
    defer std.testing.allocator.free(big);
    @memset(big, 'y');
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = core.capText(arena.allocator(), big);
    try std.testing.expect(t.len < 66 * 1024);
    try has(t, "truncated");
}

test "github_api_get: GET-only, trims url noise, keeps html_url" {
    var rig = Rig.init(&RO_ENV, &.{.{ .status = 200, .body = "{\"id\":1,\"node_id\":\"N\",\"url\":\"https://api/x\",\"html_url\":\"https://h\",\"avatar_url\":\"A\",\"name\":\"n\",\"owner\":{\"login\":\"o\",\"followers_url\":\"f\"}}", .link = "<x>; rel=\"next\"" }});
    defer rig.deinit();
    const r = try rig.call("github_api_get", "{\"path\":\"/repos/o/r?x=1\"}");
    try std.testing.expectEqual(std.http.Method.GET, rig.req(0).method);
    try std.testing.expectEqualStrings(API ++ "/repos/o/r?x=1", rig.url(0));
    try has(r.text, "\"html_url\":\"https://h\"");
    try has(r.text, "\"login\":\"o\"");
    try hasNot(r.text, "avatar_url");
    try hasNot(r.text, "node_id");
    try hasNot(r.text, "followers_url");
    try has(r.text, "more results");
}
