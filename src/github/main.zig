//! zmcp-github: pure-Zig GitHub MCP server (REST + GraphQL), tool-compatible
//! with the official github/github-mcp-server (Go).
//!
//! Auth: GITHUB_TOKEN, GITHUB_PERSONAL_ACCESS_TOKEN or GH_TOKEN (first set).
//! Host: GITHUB_API_URL, or GITHUB_HOST for GitHub Enterprise Server / ghe.com.
//! Toolsets: ZMCP_GITHUB_TOOLSETS (or GITHUB_TOOLSETS) = comma list | all | default.
//!   default = context,repos,issues,pull_requests,users (same as the official server).
//!   ZMCP_GITHUB_TOOLS / GITHUB_TOOLS add individual tools on top.
//! Safety: writes need ZMCP_GITHUB_ALLOW_WRITE=1; destructive tools also need
//!   ZMCP_GITHUB_ALLOW_DESTRUCTIVE=1; GITHUB_READ_ONLY=1 always refuses writes
//!   (and hides write tools from tools/list).
//!
//! Parity with the official server (README "Tools", verified 2026-09; names,
//! parameters and toolsets follow it). Status: same = same name/params,
//! diff = same name, documented deviation, skip = not implemented (reason).
//!
//! context: get_me same | get_teams same | get_team_members same
//! repos: get_file_contents same | list_branches same | list_commits same |
//!   get_commit same | list_tags same | get_tag same | list_releases same |
//!   get_latest_release same | get_release_by_tag same |
//!   list_repository_collaborators same | search_repositories same |
//!   search_code same (adds text-match fragments) | search_commits same |
//!   create_branch same | create_or_update_file same (allow_symlink_write not
//!   supported) | delete_file same | push_files same | create_repository same |
//!   fork_repository same | delete_repository same (destructive)
//! issues: issue_read same | issue_write diff (no issue_fields; duplicate_of
//!   posts a "Duplicate of #N" comment) | add_issue_comment same (reactions ok) |
//!   update_issue_comment same | list_issues diff (REST: page/perPage instead of
//!   the `after` cursor, no field_filters/fields) | search_issues diff (keyword
//!   search, not semantic) | sub_issue_write same | list_issue_types same |
//!   get_label same | list_issue_fields skip (issue-fields is a preview API)
//! labels: get_label same | list_label same | label_write same
//! pull_requests: list_pull_requests same | pull_request_read same (9 methods) |
//!   search_pull_requests same | create_pull_request same | update_pull_request
//!   same | merge_pull_request same | update_pull_request_branch same |
//!   pull_request_review_write same (5 methods) |
//!   add_comment_to_pending_review same | add_reply_to_pull_request_comment same
//! users: search_users same
//! orgs: search_orgs same
//! actions: actions_get same | actions_list same | actions_run_trigger same |
//!   get_job_logs same (default returns the URL; tail_lines default 500)
//! code_security: get_code_scanning_alert same | list_code_scanning_alerts same
//! secret_protection: get_secret_scanning_alert same | list_secret_scanning_alerts same
//! dependabot: get_dependabot_alert same | list_dependabot_alerts same
//! security_advisories: get_global_security_advisory same |
//!   list_global_security_advisories same | list_repository_security_advisories
//!   same | list_org_repository_security_advisories same
//! discussions: list_discussions same | get_discussion same |
//!   get_discussion_comments same | list_discussion_categories same |
//!   discussion_comment_write same (GraphQL)
//! gists: list_gists same | get_gist same | create_gist same | update_gist same
//! git: get_repository_tree diff (compact `type path size` lines)
//! notifications: list_notifications same | get_notification_details same |
//!   dismiss_notification same | mark_all_notifications_read same |
//!   manage_notification_subscription same |
//!   manage_repository_notification_subscription same
//! stargazers: list_starred_repositories same | star_repository same |
//!   unstar_repository same
//! projects: projects_list diff (list_projects, list_project_fields,
//!   list_project_items) | projects_get diff (get_project, get_project_field,
//!   get_project_item) | projects_write diff (add/update/update_items/delete
//!   item). skip: create_project, views, status updates, iteration fields
//!   (rare, GraphQL-only, large schemas)
//! copilot: request_copilot_review same | assign_copilot_to_issue skip
//!   (Copilot coding-agent assignment) | copilot_issue_intents skip (same)
//! skip (with reason): governance (create_repository_ruleset,
//!   repository_ruleset_read, custom_properties_read/write: org-admin schemas,
//!   large nested objects), code_quality get_code_quality_finding (preview API),
//!   remote-server-only tools (create_pull_request_with_copilot, Copilot Spaces,
//!   github_support_docs_search), OAuth scope discovery/challenge, insiders mode,
//!   lockdown mode, i18n description overrides.
//! Extra (not official): github_toolsets (discovery) and github_api_get (read-only
//!   GET escape hatch, toolset `raw`, off by default; official has no equivalent).
//! Renamed from the previous zmcp-github: repo_view/repo_list -> get_file_contents /
//!   search_repositories / get_me, issue_list -> list_issues, issue_view ->
//!   issue_read, issue_comment -> add_issue_comment, pr_list -> list_pull_requests,
//!   pr_view -> pull_request_read get, pr_diff -> pull_request_read get_diff,
//!   workflow_runs -> actions_list, release_list -> list_releases,
//!   search_repos -> search_repositories, gh_run -> github_api_get.

const std = @import("std");
const mcp = @import("mcp");
const core = @import("core.zig");
const genv = @import("env.zig");
const repos = @import("repos.zig");
const issues = @import("issues.zig");
const pulls = @import("pulls.zig");
const actions = @import("actions.zig");
const social = @import("social.zig");

const Call = core.Call;
const T = core.T;

pub const server_name = "zmcp-github";
pub const server_version = "0.2.0";

pub const Toolset = struct { name: []const u8, desc: []const u8, default: bool = false };

pub const toolsets = [_]Toolset{
    .{ .name = "context", .desc = "current user and teams", .default = true },
    .{ .name = "repos", .desc = "files, commits, branches, releases, search, repo writes", .default = true },
    .{ .name = "issues", .desc = "issues, comments, sub-issues, issue types", .default = true },
    .{ .name = "pull_requests", .desc = "PRs, reviews, review threads, merge", .default = true },
    .{ .name = "users", .desc = "user search", .default = true },
    .{ .name = "actions", .desc = "workflows, runs, jobs, logs, dispatch" },
    .{ .name = "code_security", .desc = "code scanning alerts" },
    .{ .name = "secret_protection", .desc = "secret scanning alerts" },
    .{ .name = "dependabot", .desc = "Dependabot alerts" },
    .{ .name = "security_advisories", .desc = "global/repo/org advisories" },
    .{ .name = "discussions", .desc = "discussions and comments (GraphQL)" },
    .{ .name = "gists", .desc = "gists" },
    .{ .name = "git", .desc = "repository tree" },
    .{ .name = "labels", .desc = "labels" },
    .{ .name = "notifications", .desc = "notifications and subscriptions" },
    .{ .name = "orgs", .desc = "organization search" },
    .{ .name = "projects", .desc = "Projects v2 items and fields" },
    .{ .name = "stargazers", .desc = "stars" },
    .{ .name = "copilot", .desc = "request Copilot review" },
    .{ .name = "raw", .desc = "github_api_get read-only REST escape hatch" },
};

// ---------------------------------------------------------------------------
// Extra tools
// ---------------------------------------------------------------------------

/// Bitmask of enabled toolsets (index into `toolsets`); set at startup.
var g_enabled: u64 = 0;
var g_unknown: []const u8 = "";

fn toolsetIndex(name: []const u8) ?usize {
    for (toolsets, 0..) |t, i| if (std.mem.eql(u8, t.name, name)) return i;
    return null;
}

pub fn defaultMask() u64 {
    var m: u64 = 0;
    for (toolsets, 0..) |t, i| if (t.default) {
        m |= @as(u64, 1) << @intCast(i);
    };
    return m;
}

/// Parse a toolset list ("all", "default", names). Unknown names are collected.
pub fn parseToolsets(alloc: std.mem.Allocator, spec: ?[]const u8, unknown: *[]const u8) u64 {
    const s = spec orelse return defaultMask();
    var m: u64 = 0;
    var bad: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |raw_name| {
        const name = std.mem.trim(u8, raw_name, " \t");
        if (name.len == 0) continue;
        if (std.mem.eql(u8, name, "all")) {
            m = ~@as(u64, 0);
        } else if (std.mem.eql(u8, name, "default")) {
            m |= defaultMask();
        } else if (toolsetIndex(name)) |i| {
            m |= @as(u64, 1) << @intCast(i);
        } else {
            if (bad.items.len > 0) bad.append(alloc, ',') catch {};
            bad.appendSlice(alloc, name) catch {};
        }
    }
    unknown.* = bad.items;
    return if (m == 0) defaultMask() else m;
}

fn countIn(comptime set: []const u8) usize {
    var n: usize = 0;
    for (all_tools) |t| if (std.mem.eql(u8, t.set, set)) {
        n += 1;
    };
    return n;
}

fn githubToolsets(c: *Call) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(c.alloc, "GitHub toolsets (name: tools, state, contents). Enable with env ZMCP_GITHUB_TOOLSETS=a,b,c or all (default keeps the default set); restart the server to apply. Individual tools: ZMCP_GITHUB_TOOLS=name,name.\n");
    inline for (toolsets, 0..) |t, i| {
        const on = (g_enabled >> @intCast(i)) & 1 == 1;
        try out.print(c.alloc, "{s}: {d} tools, {s}{s} - {s}\n", .{ t.name, countIn(t.name), if (on) "ON" else "off", if (t.default) " (default)" else "", t.desc });
    }
    if (g_unknown.len > 0) try out.print(c.alloc, "ignored unknown toolset names: {s}\n", .{g_unknown});
    try out.appendSlice(c.alloc, "Writes need ZMCP_GITHUB_ALLOW_WRITE=1; destructive tools also ZMCP_GITHUB_ALLOW_DESTRUCTIVE=1; GITHUB_READ_ONLY=1 forces read-only.");
    return out.items;
}

fn skipKey(k: []const u8) bool {
    if (std.mem.eql(u8, k, "node_id") or std.mem.eql(u8, k, "gravatar_id") or std.mem.eql(u8, k, "url")) return true;
    if (std.mem.eql(u8, k, "html_url")) return false;
    return std.mem.endsWith(u8, k, "_url");
}

fn writeCompact(js: *std.json.Stringify, v: std.json.Value) !void {
    switch (v) {
        .object => |o| {
            try js.beginObject();
            var it = o.iterator();
            while (it.next()) |e| {
                if (skipKey(e.key_ptr.*)) continue;
                if (e.value_ptr.* == .null) continue;
                try js.objectField(e.key_ptr.*);
                try writeCompact(js, e.value_ptr.*);
            }
            try js.endObject();
        },
        .array => |a| {
            try js.beginArray();
            for (a.items) |x| try writeCompact(js, x);
            try js.endArray();
        },
        else => try js.write(v),
    }
}

pub fn validApiPath(s: []const u8) bool {
    if (s.len < 2 or s.len > 2000 or s[0] != '/' or s[1] == '/') return false;
    if (std.mem.indexOf(u8, s, "..") != null or std.mem.indexOf(u8, s, "://") != null) return false;
    for (s) |ch| {
        if (ch <= ' ' or ch == 127 or ch == '\\' or ch == '#') return false;
    }
    return true;
}

fn githubApiGet(c: *Call) ![]const u8 {
    const path = try c.req("path");
    if (!validApiPath(path)) return core.fail(c.alloc, "invalid 'path': must start with a single '/', no '..', spaces, '#', or scheme", .{});
    if (std.mem.startsWith(u8, path, "/graphql") or std.mem.startsWith(u8, path, "/api/graphql")) return core.fail(c.alloc, "github_api_get is GET-only REST", .{});
    const p = c.paging();
    const body = try c.ok(.GET, path, null, core.accept_json);
    const v = c.parse(body) catch return body;
    const o = try core.Out.init(c.alloc);
    try writeCompact(&o.js, v);
    return c.withHint(try std.mem.concat(c.alloc, u8, &.{ o.text(), core.UNTRUSTED }), p);
}

const extra_tools = [_]core.Tool{
    T("meta", "github_toolsets", "List GitHub toolsets with tool counts and how to enable them.", "{\"type\":\"object\",\"properties\":{}}", githubToolsets, .ro),
    T("raw", "github_api_get", "GET any GitHub REST path (read-only; trims *_url noise).", core.S("\"path\":{\"type\":\"string\"}," ++ core.PG, "\"path\""), githubApiGet, .ro),
};

pub const all_tools = repos.tools ++ issues.tools ++ pulls.tools ++ actions.tools ++ social.tools ++ extra_tools;

// ---------------------------------------------------------------------------
// Table construction (runtime: mcp.run takes a slice)
// ---------------------------------------------------------------------------

fn splitContains(list: ?[]const u8, name: []const u8) bool {
    const l = list orelse return false;
    var it = std.mem.splitScalar(u8, l, ',');
    while (it.next()) |x| if (std.mem.eql(u8, std.mem.trim(u8, x, " \t"), name)) return true;
    return false;
}

/// Build the enabled tool slice from the environment.
pub fn buildTable(alloc: std.mem.Allocator) ![]mcp.ToolDef {
    const spec = genv.get("ZMCP_GITHUB_TOOLSETS") orelse genv.get("GITHUB_TOOLSETS");
    g_enabled = parseToolsets(alloc, spec, &g_unknown);
    const extra = genv.get("ZMCP_GITHUB_TOOLS") orelse genv.get("GITHUB_TOOLS");
    const read_only = genv.flag("GITHUB_READ_ONLY");
    var out: std.ArrayList(mcp.ToolDef) = .empty;
    for (all_tools) |t| {
        const by_set = std.mem.eql(u8, t.set, "meta") or blk: {
            const i = toolsetIndex(t.set) orelse break :blk false;
            break :blk (g_enabled >> @intCast(i)) & 1 == 1;
        };
        if (!by_set and !splitContains(extra, t.def.name)) continue;
        if (read_only and !t.def.read_only) continue;
        var dup = false;
        for (out.items) |x| if (std.mem.eql(u8, x.name, t.def.name)) {
            dup = true;
        };
        if (dup) continue;
        try out.append(alloc, t.def);
    }
    return out.toOwnedSlice(alloc);
}

pub fn main(init: std.process.Init) !void {
    genv.init(init.environ_map);
    const table = try buildTable(init.gpa);
    defer init.gpa.free(table);
    try mcp.run(init.gpa, init.io, .{ .name = server_name, .version = server_version }, table);
}

test {
    _ = genv;
    _ = actions;
    _ = repos;
    _ = @import("tests.zig");
}
