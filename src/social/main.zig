//! zmcp-social — keyless social search (port of extensions/social/server.mjs).
//!
//! Tools:
//!   hn_search       Search Hacker News stories + comments via Algolia
//!   hn_top          Front-page items via the firebaseio HN API
//!   reddit_search   Search Reddit via the public .json endpoint
//!   reddit_sub      List posts in a subreddit (hot / top / new / rising)
//!   reddit_thread   Read a post + its top-level comments
//!
//! All endpoints are public/anonymous — no keys, no OAuth, no state.
//! Optional REDDIT_USERNAME sets the Reddit-style User-Agent
//! (`linux:zmcp-social:0.1.0 (by /u/NAME)`); ZMCP_CONTACT is added to the HN UA.
//! Network access goes through the FetchFn seam so tests inject canned HTTP.

const std = @import("std");
const mcp = @import("mcp");

const UA_PRODUCT = "zmcp-social/0.1.0";
const REDDIT_ANON_NOTE = "\n(Note: no REDDIT_USERNAME is set, so Reddit requests are anonymous and may be rate-limited or blocked; set REDDIT_USERNAME to identify this client per Reddit's API rules.)";
const HN_ALGOLIA = "https://hn.algolia.com/api/v1";
const HN_FIREBASE = "https://hacker-news.firebaseio.com/v0";
const REDDIT = "https://www.reddit.com";
const BODY_TRUNCATE: usize = 500;
const ERR_SNIPPET: usize = 200;

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    const io = init.io;

    try mcp.run(
        arena,
        io,
        .{ .name = "zmcp-social", .version = "0.1.0" },
        &tool_table,
    );
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "hn_search",
        .description = "Search Hacker News stories + comments via Algolia. Returns top N hits with title, url, points, num_comments.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "query": { "type": "string", "description": "Search query." },
        \\    "tags": { "type": "string", "description": "Algolia tag filter, e.g. 'story', 'comment', 'show_hn'. Default: story." },
        \\    "limit": { "type": "integer", "description": "Max hits (default 10, max 100)." },
        \\    "sort": { "type": "string", "enum": ["relevance", "date"], "description": "Sort order (default relevance)." }
        \\  },
        \\  "required": ["query"]
        \\}
        ,
        .handler = handleHnSearch,
        .read_only = true,
    },
    .{
        .name = "hn_top",
        .description = "Fetch the current front page of Hacker News (story ids → title, url, points, by, kids count).",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "limit": { "type": "integer", "description": "Max stories (default 15)." }
        \\  }
        \\}
        ,
        .handler = handleHnTop,
        .read_only = true,
    },
    .{
        .name = "reddit_search",
        .description = "Reddit-wide search via the public .json endpoint. Returns top N posts.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "query": { "type": "string", "description": "Search query." },
        \\    "subreddit": { "type": "string", "description": "Restrict to one subreddit (no leading r/)." },
        \\    "sort": { "type": "string", "enum": ["relevance", "hot", "top", "new"], "description": "Default relevance." },
        \\    "limit": { "type": "integer", "description": "Max posts (default 10, max 25)." }
        \\  },
        \\  "required": ["query"]
        \\}
        ,
        .handler = handleRedditSearch,
        .read_only = true,
    },
    .{
        .name = "reddit_sub",
        .description = "List posts in a subreddit (hot / top / new / rising).",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "subreddit": { "type": "string", "description": "Subreddit name (no leading r/)." },
        \\    "sort": { "type": "string", "enum": ["hot", "top", "new", "rising"], "description": "Default hot." },
        \\    "time": { "type": "string", "enum": ["hour", "day", "week", "month", "year", "all"], "description": "Time window for sort=top." },
        \\    "limit": { "type": "integer", "description": "Max posts (default 10)." }
        \\  },
        \\  "required": ["subreddit"]
        \\}
        ,
        .handler = handleRedditSub,
        .read_only = true,
    },
    .{
        .name = "reddit_thread",
        .description = "Fetch a Reddit post plus its top-level comments.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "subreddit": { "type": "string", "description": "Subreddit name (no leading r/)." },
        \\    "post_id": { "type": "string", "description": "Post id (the alnum chunk after /comments/)." },
        \\    "limit": { "type": "integer", "description": "Max comments (default 10)." }
        \\  },
        \\  "required": ["subreddit", "post_id"]
        \\}
        ,
        .handler = handleRedditThread,
        .read_only = true,
    },
};

// ---------------------------------------------------------------------------
// HTTP seam — all network access goes through FetchFn so tests inject canned
// responses. Real implementation follows the src/weather/main.zig pattern.
// ---------------------------------------------------------------------------

pub const HttpResp = struct {
    status: u16,
    body: []u8,
};

pub const FetchFn = *const fn (
    alloc: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
) anyerror!HttpResp;

fn httpsGet(alloc: std.mem.Allocator, io: std.Io, url: []const u8) !HttpResp {
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();

    var resp_buf: std.Io.Writer.Allocating = .init(alloc);
    defer resp_buf.deinit();
    var decompress_buf: [128 * 1024]u8 = undefined;

    const ua = try userAgentFor(alloc, io, url);
    defer alloc.free(ua);

    const fetch_res = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &resp_buf.writer,
        .method = .GET,
        .extra_headers = &.{
            .{ .name = "User-Agent", .value = ua },
            .{ .name = "Accept", .value = "application/json" },
        },
        .decompress_buffer = &decompress_buf,
    });

    return .{
        .status = @intFromEnum(fetch_res.status),
        .body = try alloc.dupe(u8, resp_buf.written()),
    };
}

/// Reddit's required UA format `<platform>:<app id>:<version> (by /u/<user>)`
/// when REDDIT_USERNAME is set; otherwise (and for HN) the generic zmcp UA.
pub fn redditUserAgent(alloc: std.mem.Allocator, username: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "linux:zmcp-social:0.1.0 (by /u/{s})", .{username});
}

fn redditUsername(alloc: std.mem.Allocator, io: std.Io) ?[]u8 {
    const u = mcp.envAlloc(alloc, io, "REDDIT_USERNAME") orelse return null;
    const t = std.mem.trim(u8, u, " \t\r\n/");
    const t2 = if (std.mem.startsWith(u8, t, "u/")) t[2..] else t;
    if (t2.len == 0) {
        alloc.free(u);
        return null;
    }
    const out = alloc.dupe(u8, t2) catch {
        alloc.free(u);
        return null;
    };
    alloc.free(u);
    return out;
}

fn userAgentFor(alloc: std.mem.Allocator, io: std.Io, url: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, url, REDDIT)) {
        if (redditUsername(alloc, io)) |name| {
            defer alloc.free(name);
            return redditUserAgent(alloc, name);
        }
    }
    return mcp.userAgent(alloc, io, UA_PRODUCT);
}

/// Error text for Reddit results; adds the anonymous-request note when
/// REDDIT_USERNAME is unset.
fn redditErrText(alloc: std.mem.Allocator, io: std.Io, comptime fmt: []const u8, args: anytype) ![]u8 {
    const base = try std.fmt.allocPrint(alloc, fmt, args);
    if (redditUsername(alloc, io)) |name| {
        alloc.free(name);
        return base;
    }
    defer alloc.free(base);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ base, REDDIT_ANON_NOTE });
}

// ---------------------------------------------------------------------------
// Argument extraction helpers
// ---------------------------------------------------------------------------

fn argStr(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn argInt(args: std.json.Value, key: []const u8) ?i64 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

/// `limit` arg with default and cap. Non-positive values fall back to default.
fn limitArg(args: std.json.Value, default: usize, max: usize) usize {
    const v = argInt(args, "limit") orelse return default;
    if (v <= 0) return default;
    return @min(@as(usize, @intCast(v)), max);
}

// ---------------------------------------------------------------------------
// JSON value helpers
// ---------------------------------------------------------------------------

fn objGet(v: std.json.Value, key: []const u8) std.json.Value {
    if (v != .object) return .null;
    return v.object.get(key) orelse .null;
}

fn arrItems(v: std.json.Value) []const std.json.Value {
    if (v != .array) return &.{};
    return v.array.items;
}

fn jsonOptStr(v: std.json.Value, field: []const u8) ?[]const u8 {
    const fv = objGet(v, field);
    return if (fv == .string) fv.string else null;
}

fn jsonStr(v: std.json.Value, field: []const u8) []const u8 {
    return jsonOptStr(v, field) orelse "";
}

fn jsonInt(v: std.json.Value, field: []const u8) i64 {
    const fv = objGet(v, field);
    return switch (fv) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}

/// JS `a || b` semantics: empty string counts as missing.
fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    if (s) |v| {
        if (v.len > 0) return v;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Percent encoding (encodeURIComponent parity) + UTF-8-safe truncation
// ---------------------------------------------------------------------------

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or switch (c) {
        '-', '_', '.', '!', '~', '*', '\'', '(', ')' => true,
        else => false,
    };
}

pub fn percentEncode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    for (s) |c| {
        if (isUnreserved(c)) {
            try out.writer.writeByte(c);
        } else {
            try out.writer.print("%{X:0>2}", .{c});
        }
    }
    return alloc.dupe(u8, out.written());
}

/// Truncate to at most `max` bytes without splitting a UTF-8 codepoint.
pub fn truncateUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

// ---------------------------------------------------------------------------
// URL builders
// ---------------------------------------------------------------------------

pub fn hnSearchUrl(alloc: std.mem.Allocator, query: []const u8, tags: []const u8, limit: usize, by_date: bool) ![]u8 {
    const q = try percentEncode(alloc, query);
    defer alloc.free(q);
    const t = try percentEncode(alloc, tags);
    defer alloc.free(t);
    const endpoint = if (by_date) "search_by_date" else "search";
    return std.fmt.allocPrint(alloc, HN_ALGOLIA ++ "/{s}?query={s}&tags={s}&hitsPerPage={d}", .{ endpoint, q, t, limit });
}

pub fn redditSearchUrl(alloc: std.mem.Allocator, query: []const u8, sub: ?[]const u8, sort: []const u8, limit: usize) ![]u8 {
    const q = try percentEncode(alloc, query);
    defer alloc.free(q);
    if (sub) |s| {
        return std.fmt.allocPrint(alloc, REDDIT ++ "/r/{s}/search.json?q={s}&sort={s}&limit={d}&restrict_sr=true", .{ s, q, sort, limit });
    }
    return std.fmt.allocPrint(alloc, REDDIT ++ "/search.json?q={s}&sort={s}&limit={d}&restrict_sr=false", .{ q, sort, limit });
}

pub fn redditSubUrl(alloc: std.mem.Allocator, sub: []const u8, sort: []const u8, limit: usize, time: ?[]const u8) ![]u8 {
    if (std.mem.eql(u8, sort, "top") and time != null) {
        return std.fmt.allocPrint(alloc, REDDIT ++ "/r/{s}/{s}.json?limit={d}&t={s}", .{ sub, sort, limit, time.? });
    }
    return std.fmt.allocPrint(alloc, REDDIT ++ "/r/{s}/{s}.json?limit={d}", .{ sub, sort, limit });
}

pub fn redditThreadUrl(alloc: std.mem.Allocator, sub: []const u8, post_id: []const u8, limit: usize) ![]u8 {
    return std.fmt.allocPrint(alloc, REDDIT ++ "/r/{s}/comments/{s}.json?limit={d}", .{ sub, post_id, limit });
}

// ---------------------------------------------------------------------------
// Tool implementations — each takes a FetchFn so tests inject canned HTTP.
// ---------------------------------------------------------------------------

fn handleHnSearch(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    return hnSearchImpl(alloc, io, args, httpsGet);
}

fn handleHnTop(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    return hnTopImpl(alloc, io, args, httpsGet);
}

fn handleRedditSearch(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    return redditSearchImpl(alloc, io, args, httpsGet);
}

fn handleRedditSub(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    return redditSubImpl(alloc, io, args, httpsGet);
}

fn handleRedditThread(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    return redditThreadImpl(alloc, io, args, httpsGet);
}

pub fn hnSearchImpl(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value, fetch: FetchFn) !mcp.ToolResult {
    const query = argStr(args, "query") orelse return .{ .text = "query is required", .is_error = true };
    if (query.len == 0) return .{ .text = "query is required", .is_error = true };
    const tags = argStr(args, "tags") orelse "story";
    const limit = limitArg(args, 10, 100);
    const sort = argStr(args, "sort") orelse "relevance";
    const url = try hnSearchUrl(alloc, query, tags, limit, std.mem.eql(u8, sort, "date"));

    const resp = fetch(alloc, io, url) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "HN fetch failed: {}", .{err}), .is_error = true };
    };
    if (resp.status != 200) {
        return .{ .text = try std.fmt.allocPrint(alloc, "HN HTTP {d}: {s}", .{ resp.status, truncateUtf8(resp.body, ERR_SNIPPET) }), .is_error = true };
    }

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{}) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "HN fetch failed: {}", .{err}), .is_error = true };
    };
    defer parsed.deinit();

    const hits = arrItems(objGet(parsed.value, "hits"));
    const take = @min(limit, hits.len);
    if (take == 0) return .{ .text = "(no results)" };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    for (hits[0..take], 0..) |h, i| {
        const title = nonEmpty(jsonOptStr(h, "title")) orelse
            nonEmpty(jsonOptStr(h, "story_title")) orelse "(no title)";
        const link = nonEmpty(jsonOptStr(h, "url")) orelse
            try std.fmt.allocPrint(alloc, "https://news.ycombinator.com/item?id={s}", .{jsonStr(h, "objectID")});
        const author = jsonOptStr(h, "author") orelse "?";
        const created = jsonOptStr(h, "created_at") orelse "";
        if (i > 0) try out.writer.writeAll("\n\n");
        try out.writer.print("{d}. {s}\n   {s}\n   {d} pts · {d} comments · {s} · {s}", .{
            i + 1,
            title,
            link,
            jsonInt(h, "points"),
            jsonInt(h, "num_comments"),
            author,
            created[0..@min(10, created.len)],
        });
    }
    return .{ .text = try alloc.dupe(u8, out.written()) };
}

pub fn hnTopImpl(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value, fetch: FetchFn) !mcp.ToolResult {
    const limit = limitArg(args, 15, std.math.maxInt(usize));

    const resp = fetch(alloc, io, HN_FIREBASE ++ "/topstories.json") catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "HN top failed: {}", .{err}), .is_error = true };
    };
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{}) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "HN top failed: {}", .{err}), .is_error = true };
    };
    defer parsed.deinit();
    if (parsed.value != .array) {
        return .{ .text = "HN top failed: unexpected topstories response", .is_error = true };
    }

    const ids = parsed.value.array.items;
    const take = @min(limit, ids.len);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var count: usize = 0;
    for (ids[0..take]) |id_v| {
        const id: i64 = switch (id_v) {
            .integer => |n| n,
            else => continue,
        };
        const item_url = try std.fmt.allocPrint(alloc, HN_FIREBASE ++ "/item/{d}.json", .{id});
        const iresp = fetch(alloc, io, item_url) catch continue;
        var iparsed = std.json.parseFromSlice(std.json.Value, alloc, iresp.body, .{}) catch continue;
        defer iparsed.deinit();
        const it = iparsed.value;
        if (it != .object) continue; // deleted/null items

        const title = jsonOptStr(it, "title") orelse "(no title)";
        const link = nonEmpty(jsonOptStr(it, "url")) orelse
            try std.fmt.allocPrint(alloc, "https://news.ycombinator.com/item?id={d}", .{id});
        const by = jsonOptStr(it, "by") orelse "?";
        if (count > 0) try out.writer.writeAll("\n\n");
        try out.writer.print("{d}. {s}\n   {s}\n   {d} pts · {d} comments · {s}", .{
            count + 1,
            title,
            link,
            jsonInt(it, "score"),
            arrItems(objGet(it, "kids")).len,
            by,
        });
        count += 1;
    }
    if (count == 0) return .{ .text = "(no stories)" };
    return .{ .text = try alloc.dupe(u8, out.written()) };
}

pub fn redditSearchImpl(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value, fetch: FetchFn) !mcp.ToolResult {
    const query = argStr(args, "query") orelse return .{ .text = "query is required", .is_error = true };
    if (query.len == 0) return .{ .text = "query is required", .is_error = true };
    const sort = argStr(args, "sort") orelse "relevance";
    const limit = limitArg(args, 10, 25);
    const url = try redditSearchUrl(alloc, query, argStr(args, "subreddit"), sort, limit);

    const resp = fetch(alloc, io, url) catch |err| {
        return .{ .text = try redditErrText(alloc, io, "Reddit fetch failed: {}", .{err}), .is_error = true };
    };
    if (resp.status != 200) {
        return .{ .text = try redditErrText(alloc, io, "Reddit HTTP {d}: {s}", .{ resp.status, truncateUtf8(resp.body, ERR_SNIPPET) }), .is_error = true };
    }

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{}) catch |err| {
        return .{ .text = try redditErrText(alloc, io, "Reddit fetch failed: {}", .{err}), .is_error = true };
    };
    defer parsed.deinit();

    const children = arrItems(objGet(objGet(parsed.value, "data"), "children"));
    const take = @min(limit, children.len);
    if (take == 0) return .{ .text = "(no posts)" };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    for (children[0..take], 0..) |p, i| {
        const d = objGet(p, "data");
        const link = try std.fmt.allocPrint(alloc, REDDIT ++ "{s}", .{jsonStr(d, "permalink")});
        if (i > 0) try out.writer.writeAll("\n\n");
        try out.writer.print("{d}. {s}\n   {s}\n   {d} ups · {d} comments · r/{s} · u/{s}", .{
            i + 1,
            jsonStr(d, "title"),
            link,
            jsonInt(d, "ups"),
            jsonInt(d, "num_comments"),
            jsonStr(d, "subreddit"),
            jsonStr(d, "author"),
        });
    }
    return .{ .text = try alloc.dupe(u8, out.written()) };
}

pub fn redditSubImpl(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value, fetch: FetchFn) !mcp.ToolResult {
    const sub = argStr(args, "subreddit") orelse return .{ .text = "subreddit is required", .is_error = true };
    if (sub.len == 0) return .{ .text = "subreddit is required", .is_error = true };
    const sort = argStr(args, "sort") orelse "hot";
    const limit = limitArg(args, 10, std.math.maxInt(usize));
    const url = try redditSubUrl(alloc, sub, sort, limit, argStr(args, "time"));

    const resp = fetch(alloc, io, url) catch |err| {
        return .{ .text = try redditErrText(alloc, io, "Reddit fetch failed: {}", .{err}), .is_error = true };
    };
    if (resp.status != 200) {
        return .{ .text = try redditErrText(alloc, io, "Reddit HTTP {d}: {s}", .{ resp.status, truncateUtf8(resp.body, ERR_SNIPPET) }), .is_error = true };
    }

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{}) catch |err| {
        return .{ .text = try redditErrText(alloc, io, "Reddit fetch failed: {}", .{err}), .is_error = true };
    };
    defer parsed.deinit();

    const children = arrItems(objGet(objGet(parsed.value, "data"), "children"));
    const take = @min(limit, children.len);
    if (take == 0) return .{ .text = "(no posts)" };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    for (children[0..take], 0..) |p, i| {
        const d = objGet(p, "data");
        const link = try std.fmt.allocPrint(alloc, REDDIT ++ "{s}", .{jsonStr(d, "permalink")});
        if (i > 0) try out.writer.writeAll("\n\n");
        try out.writer.print("{d}. {s}\n   {s}\n   {d} ups · {d} comments · u/{s}", .{
            i + 1,
            jsonStr(d, "title"),
            link,
            jsonInt(d, "ups"),
            jsonInt(d, "num_comments"),
            jsonStr(d, "author"),
        });
    }
    return .{ .text = try alloc.dupe(u8, out.written()) };
}

pub fn redditThreadImpl(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value, fetch: FetchFn) !mcp.ToolResult {
    const sub = argStr(args, "subreddit") orelse return .{ .text = "subreddit + post_id are required", .is_error = true };
    const post_id = argStr(args, "post_id") orelse return .{ .text = "subreddit + post_id are required", .is_error = true };
    if (sub.len == 0 or post_id.len == 0) {
        return .{ .text = "subreddit + post_id are required", .is_error = true };
    }
    const limit = limitArg(args, 10, std.math.maxInt(usize));
    const url = try redditThreadUrl(alloc, sub, post_id, limit);

    const resp = fetch(alloc, io, url) catch |err| {
        return .{ .text = try redditErrText(alloc, io, "Reddit fetch failed: {}", .{err}), .is_error = true };
    };
    if (resp.status != 200) {
        return .{ .text = try redditErrText(alloc, io, "Reddit HTTP {d}: {s}", .{ resp.status, truncateUtf8(resp.body, ERR_SNIPPET) }), .is_error = true };
    }

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{}) catch |err| {
        return .{ .text = try redditErrText(alloc, io, "Reddit fetch failed: {}", .{err}), .is_error = true };
    };
    defer parsed.deinit();

    // Reddit returns [post_listing, comments_listing] as two listings.
    const listings = arrItems(parsed.value);
    var post: std.json.Value = .null;
    if (listings.len > 0) {
        const post_children = arrItems(objGet(objGet(listings[0], "data"), "children"));
        if (post_children.len > 0) post = objGet(post_children[0], "data");
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("Post: {s}\nBy u/{s} in r/{s} · {d} ups\n{s}\n\n{s}", .{
        jsonStr(post, "title"),
        jsonStr(post, "author"),
        jsonStr(post, "subreddit"),
        jsonInt(post, "ups"),
        jsonStr(post, "url"),
        truncateUtf8(jsonStr(post, "selftext"), BODY_TRUNCATE),
    });

    if (listings.len > 1) {
        const comments = arrItems(objGet(objGet(listings[1], "data"), "children"));
        var count: usize = 0;
        for (comments) |c| {
            if (count >= limit) break;
            const cd = objGet(c, "data");
            const body_text = nonEmpty(jsonOptStr(cd, "body")) orelse continue;
            try out.writer.print("\n\n--- Comment {d} (u/{s}, {d} ups) ---\n{s}", .{
                count + 1,
                jsonStr(cd, "author"),
                jsonInt(cd, "ups"),
                truncateUtf8(body_text, BODY_TRUNCATE),
            });
            count += 1;
        }
    }
    return .{ .text = try alloc.dupe(u8, out.written()) };
}

// ---------------------------------------------------------------------------
// Tests — mock fetch seam + canned API responses
// ---------------------------------------------------------------------------

const TestFixture = struct {
    url_part: []const u8,
    status: u16,
    body: []const u8,
};

var test_fixtures: []const TestFixture = &.{};

fn mockFetch(alloc: std.mem.Allocator, io: std.Io, url: []const u8) anyerror!HttpResp {
    _ = io;
    // Longest url_part wins so specific item URLs beat prefix matches.
    var best: ?TestFixture = null;
    for (test_fixtures) |f| {
        if (std.mem.indexOf(u8, url, f.url_part) != null) {
            if (best == null or f.url_part.len > best.?.url_part.len) best = f;
        }
    }
    const f = best orelse return error.NoFixture;
    if (f.status == 0) return error.ConnectionRefused;
    return .{ .status = f.status, .body = try alloc.dupe(u8, f.body) };
}

fn testIo() std.Io {
    const t = std.Io.Threaded.global_single_threaded;
    return t.io();
}

fn parseArgs(alloc: std.mem.Allocator, s: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, s, .{});
}

// --- helpers ---

test "percentEncode matches encodeURIComponent unreserved set" {
    const alloc = std.testing.allocator;
    const enc = try percentEncode(alloc, "a b!~*'()&=+/");
    defer alloc.free(enc);
    try std.testing.expectEqualStrings("a%20b!~*'()%26%3D%2B%2F", enc);

    const utf = try percentEncode(alloc, "é");
    defer alloc.free(utf);
    try std.testing.expectEqualStrings("%C3%A9", utf);
}

test "truncateUtf8 does not split a multibyte codepoint" {
    try std.testing.expectEqualStrings("hello", truncateUtf8("hello", 10));
    try std.testing.expectEqualStrings("hel", truncateUtf8("hello", 3));
    // 'é' is 2 bytes; cutting at byte 2 would split it, so back off to 1.
    try std.testing.expectEqualStrings("h", truncateUtf8("héllo", 2));
    try std.testing.expectEqualStrings("hé", truncateUtf8("héllo", 3));
}

// --- URL construction ---

test "hnSearchUrl encodes query and tags, relevance endpoint" {
    const alloc = std.testing.allocator;
    const url = try hnSearchUrl(alloc, "zig lang", "show_hn", 10, false);
    defer alloc.free(url);
    try std.testing.expectEqualStrings(
        "https://hn.algolia.com/api/v1/search?query=zig%20lang&tags=show_hn&hitsPerPage=10",
        url,
    );
}

test "hnSearchUrl by_date uses search_by_date endpoint" {
    const alloc = std.testing.allocator;
    const url = try hnSearchUrl(alloc, "zig", "story", 25, true);
    defer alloc.free(url);
    try std.testing.expectEqualStrings(
        "https://hn.algolia.com/api/v1/search_by_date?query=zig&tags=story&hitsPerPage=25",
        url,
    );
}

test "redditSearchUrl with and without subreddit" {
    const alloc = std.testing.allocator;
    const with_sub = try redditSearchUrl(alloc, "zig & rustc", "zig", "top", 5);
    defer alloc.free(with_sub);
    try std.testing.expectEqualStrings(
        "https://www.reddit.com/r/zig/search.json?q=zig%20%26%20rustc&sort=top&limit=5&restrict_sr=true",
        with_sub,
    );

    const no_sub = try redditSearchUrl(alloc, "zig", null, "relevance", 10);
    defer alloc.free(no_sub);
    try std.testing.expectEqualStrings(
        "https://www.reddit.com/search.json?q=zig&sort=relevance&limit=10&restrict_sr=false",
        no_sub,
    );
}

test "redditSubUrl appends &t= only for sort=top with time" {
    const alloc = std.testing.allocator;
    const top = try redditSubUrl(alloc, "zig", "top", 10, "week");
    defer alloc.free(top);
    try std.testing.expectEqualStrings("https://www.reddit.com/r/zig/top.json?limit=10&t=week", top);

    const hot = try redditSubUrl(alloc, "zig", "hot", 10, "week");
    defer alloc.free(hot);
    try std.testing.expectEqualStrings("https://www.reddit.com/r/zig/hot.json?limit=10", hot);

    const top_no_time = try redditSubUrl(alloc, "zig", "top", 10, null);
    defer alloc.free(top_no_time);
    try std.testing.expectEqualStrings("https://www.reddit.com/r/zig/top.json?limit=10", top_no_time);
}

test "redditThreadUrl shape" {
    const alloc = std.testing.allocator;
    const url = try redditThreadUrl(alloc, "zig", "1abc2de", 10);
    defer alloc.free(url);
    try std.testing.expectEqualStrings("https://www.reddit.com/r/zig/comments/1abc2de.json?limit=10", url);
}

// --- hn_search ---

const HN_SEARCH_FIXTURE =
    \\{"hits":[
    \\  {"objectID":"111","title":"Zig is great","url":"https://ziglang.org","points":321,"num_comments":45,"author":"andrew","created_at":"2024-03-01T12:00:00.000Z"},
    \\  {"objectID":"222","title":null,"story_title":"Comment on story","url":null,"points":null,"num_comments":null,"author":"dang","created_at":"2024-03-02T00:00:00.000Z"}
    \\]}
;

test "hnSearchImpl formats hits with fallbacks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    test_fixtures = &.{.{ .url_part = "hn.algolia.com", .status = 200, .body = HN_SEARCH_FIXTURE }};
    var args = try parseArgs(alloc, "{\"query\":\"zig\"}");
    defer args.deinit();

    const result = try hnSearchImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings(
        "1. Zig is great\n" ++
            "   https://ziglang.org\n" ++
            "   321 pts · 45 comments · andrew · 2024-03-01\n" ++
            "\n" ++
            "2. Comment on story\n" ++
            "   https://news.ycombinator.com/item?id=222\n" ++
            "   0 pts · 0 comments · dang · 2024-03-02",
        result.text,
    );
}

test "hnSearchImpl empty hits yields (no results)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    test_fixtures = &.{.{ .url_part = "hn.algolia.com", .status = 200, .body = "{\"hits\":[]}" }};
    var args = try parseArgs(alloc, "{\"query\":\"nothing\"}");
    defer args.deinit();

    const result = try hnSearchImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("(no results)", result.text);
}

test "hnSearchImpl requires query" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var args = try parseArgs(alloc, "{}");
    defer args.deinit();
    const result = try hnSearchImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings("query is required", result.text);
}

test "hnSearchImpl HTTP error surfaces status and body snippet" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    test_fixtures = &.{.{ .url_part = "hn.algolia.com", .status = 500, .body = "algolia exploded" }};
    var args = try parseArgs(alloc, "{\"query\":\"zig\"}");
    defer args.deinit();

    const result = try hnSearchImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings("HN HTTP 500: algolia exploded", result.text);
}

test "hnSearchImpl malformed JSON is an error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    test_fixtures = &.{.{ .url_part = "hn.algolia.com", .status = 200, .body = "<html>oops</html>" }};
    var args = try parseArgs(alloc, "{\"query\":\"zig\"}");
    defer args.deinit();

    const result = try hnSearchImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.startsWith(u8, result.text, "HN fetch failed:"));
}

test "hnSearchImpl clamps limit to 100 in the request URL" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // Mock only matches when the URL carries the clamped hitsPerPage.
    test_fixtures = &.{.{ .url_part = "hitsPerPage=100", .status = 200, .body = "{\"hits\":[]}" }};
    var args = try parseArgs(alloc, "{\"query\":\"zig\",\"limit\":500}");
    defer args.deinit();

    const result = try hnSearchImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("(no results)", result.text);
}

test "hnSearchImpl slices hits to limit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const body =
        \\{"hits":[
        \\  {"objectID":"1","title":"one"},
        \\  {"objectID":"2","title":"two"},
        \\  {"objectID":"3","title":"three"}
        \\]}
    ;
    test_fixtures = &.{.{ .url_part = "hn.algolia.com", .status = 200, .body = body }};
    var args = try parseArgs(alloc, "{\"query\":\"zig\",\"limit\":2}");
    defer args.deinit();

    const result = try hnSearchImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "2. two") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "three") == null);
}

// --- hn_top ---

test "hnTopImpl formats stories and skips failed items" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    test_fixtures = &.{
        .{ .url_part = "topstories.json", .status = 200, .body = "[101,102,103]" },
        .{ .url_part = "item/101.json", .status = 200, .body = "{\"id\":101,\"title\":\"First story\",\"url\":\"https://a.com\",\"score\":50,\"kids\":[1,2,3],\"by\":\"alice\"}" },
        .{ .url_part = "item/102.json", .status = 200, .body = "null" }, // deleted story
        .{ .url_part = "item/103.json", .status = 200, .body = "{\"id\":103,\"title\":\"Third story\",\"score\":7,\"by\":\"bob\"}" },
    };
    var args = try parseArgs(alloc, "{}");
    defer args.deinit();

    const result = try hnTopImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings(
        "1. First story\n" ++
            "   https://a.com\n" ++
            "   50 pts · 3 comments · alice\n" ++
            "\n" ++
            "2. Third story\n" ++
            "   https://news.ycombinator.com/item?id=103\n" ++
            "   7 pts · 0 comments · bob",
        result.text,
    );
}

test "hnTopImpl empty list yields (no stories)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    test_fixtures = &.{.{ .url_part = "topstories.json", .status = 200, .body = "[]" }};
    var args = try parseArgs(alloc, "{\"limit\":5}");
    defer args.deinit();

    const result = try hnTopImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("(no stories)", result.text);
}

test "hnTopImpl malformed topstories JSON is an error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    test_fixtures = &.{.{ .url_part = "topstories.json", .status = 200, .body = "not json" }};
    var args = try parseArgs(alloc, "{}");
    defer args.deinit();

    const result = try hnTopImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.startsWith(u8, result.text, "HN top failed:"));
}

test "hnTopImpl network failure is an error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    test_fixtures = &.{.{ .url_part = "topstories.json", .status = 0, .body = "" }};
    var args = try parseArgs(alloc, "{}");
    defer args.deinit();

    const result = try hnTopImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.startsWith(u8, result.text, "HN top failed:"));
}

// --- reddit_search ---

const REDDIT_SEARCH_FIXTURE =
    \\{"data":{"children":[
    \\  {"data":{"title":"Zig 0.16 released","permalink":"/r/zig/comments/abc/zig_016/","ups":900,"num_comments":120,"subreddit":"zig","author":"coredev"}},
    \\  {"data":{"title":"Why Zig?","permalink":"/r/programming/comments/def/why_zig/","ups":150,"num_comments":80,"subreddit":"programming","author":"curious"}}
    \\]}}
;

test "redditSearchImpl formats posts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    test_fixtures = &.{.{ .url_part = "reddit.com", .status = 200, .body = REDDIT_SEARCH_FIXTURE }};
    var args = try parseArgs(alloc, "{\"query\":\"zig\"}");
    defer args.deinit();

    const result = try redditSearchImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings(
        "1. Zig 0.16 released\n" ++
            "   https://www.reddit.com/r/zig/comments/abc/zig_016/\n" ++
            "   900 ups · 120 comments · r/zig · u/coredev\n" ++
            "\n" ++
            "2. Why Zig?\n" ++
            "   https://www.reddit.com/r/programming/comments/def/why_zig/\n" ++
            "   150 ups · 80 comments · r/programming · u/curious",
        result.text,
    );
}

test "redditSearchImpl empty children yields (no posts)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    test_fixtures = &.{.{ .url_part = "reddit.com", .status = 200, .body = "{\"data\":{\"children\":[]}}" }};
    var args = try parseArgs(alloc, "{\"query\":\"zig\"}");
    defer args.deinit();

    const result = try redditSearchImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("(no posts)", result.text);
}

test "redditSearchImpl requires query" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var args = try parseArgs(alloc, "{}");
    defer args.deinit();
    const result = try redditSearchImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings("query is required", result.text);
}

test "redditSearchImpl HTTP error surfaces status and snippet" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    test_fixtures = &.{.{ .url_part = "reddit.com", .status = 403, .body = "blocked" }};
    var args = try parseArgs(alloc, "{\"query\":\"zig\"}");
    defer args.deinit();

    const result = try redditSearchImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.startsWith(u8, result.text, "Reddit HTTP 403: blocked"));
    try std.testing.expect(result.is_error);
}

test "redditSearchImpl clamps limit to 25 in the request URL" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    test_fixtures = &.{.{ .url_part = "limit=25&restrict_sr=false", .status = 200, .body = "{\"data\":{\"children\":[]}}" }};
    var args = try parseArgs(alloc, "{\"query\":\"zig\",\"limit\":100}");
    defer args.deinit();

    const result = try redditSearchImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("(no posts)", result.text);
}

// --- reddit_sub ---

test "redditSubImpl formats posts without subreddit in meta" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const body =
        \\{"data":{"children":[
        \\  {"data":{"title":"Hot post","permalink":"/r/zig/comments/hot/hot_post/","ups":42,"num_comments":7,"author":"poster"}}
        \\]}}
    ;
    test_fixtures = &.{.{ .url_part = "/r/zig/hot.json", .status = 200, .body = body }};
    var args = try parseArgs(alloc, "{\"subreddit\":\"zig\"}");
    defer args.deinit();

    const result = try redditSubImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings(
        "1. Hot post\n" ++
            "   https://www.reddit.com/r/zig/comments/hot/hot_post/\n" ++
            "   42 ups · 7 comments · u/poster",
        result.text,
    );
}

test "redditSubImpl requires subreddit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var args = try parseArgs(alloc, "{}");
    defer args.deinit();
    const result = try redditSubImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings("subreddit is required", result.text);
}

test "redditSubImpl top with time adds t param to URL" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    test_fixtures = &.{.{ .url_part = "/r/zig/top.json?limit=10&t=month", .status = 200, .body = "{\"data\":{\"children\":[]}}" }};
    var args = try parseArgs(alloc, "{\"subreddit\":\"zig\",\"sort\":\"top\",\"time\":\"month\"}");
    defer args.deinit();

    const result = try redditSubImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("(no posts)", result.text);
}

// --- reddit_thread ---

test "redditThreadImpl formats post and comments, filters bodyless" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const body =
        \\[{"data":{"children":[{"data":{"title":"Post title","author":"op","subreddit":"zig","ups":42,"url":"https://example.com/post","selftext":"post body text"}}]}},
        \\ {"data":{"children":[
        \\   {"data":{"author":"c1","ups":10,"body":"first comment"}},
        \\   {"data":{"author":"deleted","ups":0}},
        \\   {"data":{"author":"c2","ups":5,"body":"second comment"}}
        \\ ]}}]
    ;
    test_fixtures = &.{.{ .url_part = "/r/zig/comments/xyz.json", .status = 200, .body = body }};
    var args = try parseArgs(alloc, "{\"subreddit\":\"zig\",\"post_id\":\"xyz\"}");
    defer args.deinit();

    const result = try redditThreadImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings(
        "Post: Post title\n" ++
            "By u/op in r/zig · 42 ups\n" ++
            "https://example.com/post\n" ++
            "\n" ++
            "post body text\n" ++
            "\n" ++
            "--- Comment 1 (u/c1, 10 ups) ---\n" ++
            "first comment\n" ++
            "\n" ++
            "--- Comment 2 (u/c2, 5 ups) ---\n" ++
            "second comment",
        result.text,
    );
}

test "redditThreadImpl requires subreddit + post_id" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var args = try parseArgs(alloc, "{\"subreddit\":\"zig\"}");
    defer args.deinit();
    const result = try redditThreadImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings("subreddit + post_id are required", result.text);
}

test "redditThreadImpl truncates selftext and comment bodies at 500 chars" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var long_buf: [600]u8 = undefined;
    @memset(&long_buf, 'x');
    const long600 = long_buf[0..600];
    const long500 = long_buf[0..500];

    const body = try std.mem.concat(alloc, u8, &.{
        "[{\"data\":{\"children\":[{\"data\":{\"title\":\"T\",\"author\":\"op\",\"subreddit\":\"zig\",\"ups\":1,\"url\":\"\",\"selftext\":\"",
        long600,
        "\"}}]}},",
        " {\"data\":{\"children\":[{\"data\":{\"author\":\"c\",\"ups\":1,\"body\":\"",
        long600,
        "\"}}]}}]",
    });

    test_fixtures = &.{.{ .url_part = "comments/xyz.json", .status = 200, .body = body }};
    var args = try parseArgs(alloc, "{\"subreddit\":\"zig\",\"post_id\":\"xyz\"}");
    defer args.deinit();

    const result = try redditThreadImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, long500) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, long600) == null);
}

test "redditThreadImpl empty listing still renders head" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    test_fixtures = &.{.{ .url_part = "reddit.com", .status = 200, .body = "[]" }};
    var args = try parseArgs(alloc, "{\"subreddit\":\"zig\",\"post_id\":\"xyz\"}");
    defer args.deinit();

    // Empty array: no post listing — head still renders with empty fields.
    const result = try redditThreadImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.startsWith(u8, result.text, "Post: "));
}

test "redditUserAgent uses Reddit's required format" {
    const alloc = std.testing.allocator;
    const ua = try redditUserAgent(alloc, "someuser");
    defer alloc.free(ua);
    try std.testing.expectEqualStrings("linux:zmcp-social:0.1.0 (by /u/someuser)", ua);
}

test "userAgentFor keeps HN on the generic zmcp UA" {
    const alloc = std.testing.allocator;
    const ua = try userAgentFor(alloc, testIo(), "https://hn.algolia.com/api/v1/search");
    defer alloc.free(ua);
    try std.testing.expect(std.mem.startsWith(u8, ua, "zmcp-social/0.1.0 (+"));
}
