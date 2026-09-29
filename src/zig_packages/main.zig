//! zmcp-zig-packages — drop-in replacement for the Node `zig_packages`
//! extension. Uses GitHub Search API (same backend as Zigistry).
//!
//! Tools:
//!   zig_pkg_search(query, limit?, sort?, topic?)
//!   zig_pkg_readme(repo)

const std = @import("std");
const mcp = @import("mcp");

const UA_PRODUCT = "zmcp-zig-packages/0.1.0";
const MAX_LIMIT: usize = 30;
const DEFAULT_LIMIT: usize = 15;
const README_MAX_CHARS: usize = 12000;

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    const io = init.io;
    try mcp.run(arena, io, .{ .name = "zmcp-zig-packages", .version = "0.1.0" }, &tool_table);
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "zig_pkg_search",
        .description = "Search Zig packages on GitHub. Combines free-text `query` with `language:zig` and an optional `topic:` filter (e.g. 'zig-package'). Returns name, description, stars, updated, html_url. Uses unauthenticated GitHub Search API \xe2\x80\x94 limit 60 req/hr/IP, so use sparingly.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "query": { "type": "string", "description": "Free-text terms (e.g. 'sqlite' or 'http client')." },
        \\    "limit": { "type": "integer", "description": "Default 15, max 30." },
        \\    "sort":  { "type": "string",  "description": "stars (default) | updated | best-match" },
        \\    "topic": { "type": "string",  "description": "Optional GitHub topic filter — e.g. 'zig-package', 'zig-library', 'allocator'. Omit for any language:zig repo." }
        \\  },
        \\  "required": ["query"]
        \\}
        ,
        .handler = handleSearch,
        .read_only = true,
    },
    .{
        .name = "zig_pkg_readme",
        .description = "Fetch the README.md of a GitHub repo, decoded from the api/repos/{owner}/{repo}/readme endpoint. Pass 'owner/repo'.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "repo": { "type": "string", "description": "owner/repo (e.g. 'karlseguin/http.zig')." }
        \\  },
        \\  "required": ["repo"]
        \\}
        ,
        .handler = handleReadme,
        .read_only = true,
    },
};

// ---------------------------------------------------------------------------
// HTTPS helper
// ---------------------------------------------------------------------------

const HttpResp = struct {
    status: u16,
    body: []u8,
    rl_remaining: ?[]const u8,
    rl_reset: ?[]const u8,
};

fn httpsGet(
    alloc: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
) !HttpResp {
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();
    const ua_owned = try mcp.userAgent(alloc, io, UA_PRODUCT);
    defer alloc.free(ua_owned);

    var resp_buf: std.Io.Writer.Allocating = .init(alloc);
    defer resp_buf.deinit();

    // Provide an explicit decompress buffer so gzip responses are inflated.
    var decompress_buf: [64 * 1024]u8 = undefined;

    const fetch_res = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &resp_buf.writer,
        .method = .GET,
        .extra_headers = &.{
            .{ .name = "User-Agent", .value = ua_owned },
            .{ .name = "Accept", .value = "application/vnd.github+json" },
            .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
        },
        .decompress_buffer = &decompress_buf,
    });

    const body = try alloc.dupe(u8, resp_buf.written());

    return .{
        .status = @intFromEnum(fetch_res.status),
        .body = body,
        .rl_remaining = null,
        .rl_reset = null,
    };
}

// ---------------------------------------------------------------------------
// Arg helpers
// ---------------------------------------------------------------------------

fn getStr(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn getInt(args: std.json.Value, key: []const u8, default: i64) i64 {
    if (args != .object) return default;
    const v = args.object.get(key) orelse return default;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => default,
    };
}

// ---------------------------------------------------------------------------
// URL-encoding (RFC 3986 unreserved + colon for `topic:` qualifier)
// ---------------------------------------------------------------------------

fn isUnreserved(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or
        c == '-' or c == '_' or c == '.' or c == '~';
}

fn urlEncodePlus(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    for (s) |c| {
        if (c == ' ') {
            try out.writer.writeByte('+');
        } else if (isUnreserved(c)) {
            try out.writer.writeByte(c);
        } else {
            try out.writer.print("%{X:0>2}", .{c});
        }
    }
    return alloc.dupe(u8, out.written());
}

fn isValidRepoPath(s: []const u8) bool {
    if (s.len < 3) return false;
    var saw_slash = false;
    for (s) |c| {
        if (c == '/') {
            if (saw_slash) return false;
            saw_slash = true;
        } else if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) {
            return false;
        }
    }
    return saw_slash;
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

fn handleSearch(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const query = getStr(args, "query") orelse return .{
        .text = "error: query required",
        .is_error = true,
    };
    if (query.len == 0) return .{ .text = "error: query required", .is_error = true };

    const requested_limit: i64 = getInt(args, "limit", DEFAULT_LIMIT);
    const limit: usize = @intCast(@max(1, @min(@as(i64, MAX_LIMIT), requested_limit)));

    const sort_raw = getStr(args, "sort");
    const sort_opt: ?[]const u8 = if (sort_raw) |s| (if (std.mem.eql(u8, s, "best-match")) null else s) else null;
    const topic = getStr(args, "topic");

    // Build q="<query> language:zig [topic:<topic>]"
    var q_buf: std.Io.Writer.Allocating = .init(alloc);
    defer q_buf.deinit();
    try q_buf.writer.writeAll(query);
    try q_buf.writer.writeAll(" language:zig");
    if (topic) |t| {
        try q_buf.writer.print(" topic:{s}", .{t});
    }
    const q_encoded = try urlEncodePlus(alloc, q_buf.written());

    var url_buf: std.Io.Writer.Allocating = .init(alloc);
    defer url_buf.deinit();
    try url_buf.writer.print(
        "https://api.github.com/search/repositories?q={s}&per_page={d}",
        .{ q_encoded, limit },
    );
    if (sort_opt) |s| {
        try url_buf.writer.print("&sort={s}&order=desc", .{s});
    }

    const resp = httpsGet(alloc, io, url_buf.written()) catch |err| {
        return .{
            .text = try std.fmt.allocPrint(alloc, "zig_pkg_search failed: {s}", .{@errorName(err)}),
            .is_error = true,
        };
    };

    if (resp.status == 403 or resp.status == 429) {
        return .{
            .text = try std.fmt.allocPrint(
                alloc,
                "GitHub rate-limited (HTTP {d}). Try again later.",
                .{resp.status},
            ),
            .is_error = true,
        };
    }
    if (resp.status != 200) {
        const snippet_len = @min(resp.body.len, 200);
        return .{
            .text = try std.fmt.allocPrint(
                alloc,
                "github HTTP {d}: {s}",
                .{ resp.status, resp.body[0..snippet_len] },
            ),
            .is_error = true,
        };
    }

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{}) catch |err| {
        const snip_len = @min(resp.body.len, 240);
        return .{
            .text = try std.fmt.allocPrint(
                alloc,
                "json parse failed: {s} | status={d} body_len={d} body_head=\"{s}\"",
                .{ @errorName(err), resp.status, resp.body.len, resp.body[0..snip_len] },
            ),
            .is_error = true,
        };
    };
    defer parsed.deinit();

    const root = parsed.value;
    const total_count: i64 = if (root == .object)
        switch (root.object.get("total_count") orelse .null) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            else => 0,
        }
    else
        0;
    const items_v = if (root == .object) root.object.get("items") orelse .null else .null;
    const items = if (items_v == .array) items_v.array.items else &[_]std.json.Value{};

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("{d}/{d} matching:\n", .{ items.len, total_count });

    // Build a simple JSON-array literal for the rows.
    var js = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try js.beginArray();
    for (items) |it| {
        if (it != .object) continue;
        try js.beginObject();
        try writeJsonStringField(&js, "full_name", jsonStrOpt(it, "full_name") orelse "");
        try writeJsonStringField(&js, "description", jsonStrOpt(it, "description") orelse "");
        try js.objectField("stars");
        try js.write(jsonIntOpt(it, "stargazers_count") orelse 0);
        try writeJsonStringField(&js, "updated", jsonStrOpt(it, "pushed_at") orelse "");
        try writeJsonStringField(&js, "html_url", jsonStrOpt(it, "html_url") orelse "");
        // license — d.license?.spdx_id
        const license_v = it.object.get("license") orelse .null;
        const license_str: []const u8 = if (license_v == .object)
            (switch (license_v.object.get("spdx_id") orelse .null) {
                .string => |s| s,
                else => "",
            })
        else
            "";
        try writeJsonStringField(&js, "license", license_str);
        // topics array
        try js.objectField("topics");
        const topics_v = it.object.get("topics") orelse .null;
        if (topics_v == .array) {
            try js.beginArray();
            for (topics_v.array.items) |t| {
                if (t == .string) try js.write(t.string);
            }
            try js.endArray();
        } else {
            try js.beginArray();
            try js.endArray();
        }
        try writeJsonStringField(&js, "homepage", jsonStrOpt(it, "homepage") orelse "");
        try js.endObject();
    }
    try js.endArray();

    return .{ .text = try alloc.dupe(u8, out.written()) };
}

fn handleReadme(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const repo = getStr(args, "repo") orelse return .{
        .text = "error: repo required (owner/repo)",
        .is_error = true,
    };
    if (!isValidRepoPath(repo)) return .{
        .text = "error: repo must be owner/repo",
        .is_error = true,
    };

    var url_buf: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://api.github.com/repos/{s}/readme", .{repo});

    const resp = httpsGet(alloc, io, url) catch |err| {
        return .{
            .text = try std.fmt.allocPrint(alloc, "zig_pkg_readme failed: {s}", .{@errorName(err)}),
            .is_error = true,
        };
    };

    if (resp.status == 404) return .{ .text = "(no README for that repo)" };
    if (resp.status != 200) {
        return .{
            .text = try std.fmt.allocPrint(alloc, "github HTTP {d}", .{resp.status}),
            .is_error = true,
        };
    }

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{}) catch |err| {
        return .{
            .text = try std.fmt.allocPrint(alloc, "json parse failed: {s}", .{@errorName(err)}),
            .is_error = true,
        };
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return .{ .text = "(unexpected README response)", .is_error = true };
    const content_v = root.object.get("content") orelse return .{ .text = "(README returned no content)" };
    if (content_v != .string) return .{ .text = "(README returned no content)" };

    // GitHub returns base64 with embedded newlines. Strip them.
    var clean: std.Io.Writer.Allocating = .init(alloc);
    defer clean.deinit();
    for (content_v.string) |c| {
        if (c != '\n' and c != '\r' and c != ' ') try clean.writer.writeByte(c);
    }
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(clean.written()) catch |err| {
        return .{
            .text = try std.fmt.allocPrint(alloc, "base64 decode failed: {s}", .{@errorName(err)}),
            .is_error = true,
        };
    };
    const decoded = try alloc.alloc(u8, decoded_len);
    std.base64.standard.Decoder.decode(decoded, clean.written()) catch |err| {
        return .{
            .text = try std.fmt.allocPrint(alloc, "base64 decode failed: {s}", .{@errorName(err)}),
            .is_error = true,
        };
    };

    const readme_name = jsonStrOpt(root, "name") orelse "README.md";
    const trimmed: []const u8 = if (decoded.len > README_MAX_CHARS) decoded[0..README_MAX_CHARS] else decoded;
    const suffix: []const u8 = if (decoded.len > README_MAX_CHARS)
        try std.fmt.allocPrint(alloc, "\n\n... (+ {d} more chars)", .{decoded.len - README_MAX_CHARS})
    else
        "";

    return .{
        .text = try std.fmt.allocPrint(
            alloc,
            "=== {s}/{s} ===\n{s}{s}",
            .{ repo, readme_name, trimmed, suffix },
        ),
    };
}

// ---------------------------------------------------------------------------
// Small JSON helpers
// ---------------------------------------------------------------------------

fn jsonStrOpt(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return switch (f) {
        .string => |s| s,
        else => null,
    };
}

fn jsonIntOpt(v: std.json.Value, key: []const u8) ?i64 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return switch (f) {
        .integer => |i| i,
        .float => |fl| @as(i64, @intFromFloat(fl)),
        else => null,
    };
}

fn writeJsonStringField(js: *std.json.Stringify, name: []const u8, val: []const u8) !void {
    try js.objectField(name);
    try js.write(val);
}

// ---------------------------------------------------------------------------
// Tests (offline only — no live HTTP)
// ---------------------------------------------------------------------------

test "isValidRepoPath" {
    try std.testing.expect(isValidRepoPath("karlseguin/http.zig"));
    try std.testing.expect(isValidRepoPath("ziglang/zig"));
    try std.testing.expect(!isValidRepoPath("noslash"));
    try std.testing.expect(!isValidRepoPath("a/b/c"));
    try std.testing.expect(!isValidRepoPath("a/b!"));
}

test "urlEncodePlus encodes spaces as + and colons as %3A" {
    const alloc = std.testing.allocator;
    const enc = try urlEncodePlus(alloc, "http client topic:zig-library");
    defer alloc.free(enc);
    try std.testing.expectEqualStrings("http+client+topic%3Azig-library", enc);
}

test "getInt with default" {
    const alloc = std.testing.allocator;
    var p = try std.json.parseFromSlice(std.json.Value, alloc, "{\"limit\":7}", .{});
    defer p.deinit();
    try std.testing.expectEqual(@as(i64, 7), getInt(p.value, "limit", 15));
    try std.testing.expectEqual(@as(i64, 99), getInt(p.value, "missing", 99));
}
