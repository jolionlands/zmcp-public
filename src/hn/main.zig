//! zmcp-hn — Hacker News search, top stories, and thread fetch.
//!
//! Tools:
//!   hn_search(query, n?)  — full-text search via Algolia HN API
//!   hn_top(n?)            — top stories via Firebase + resolve each item
//!   hn_thread(id)         — story + nested comment tree via Algolia /items/<id>

const std = @import("std");
const mcp = @import("mcp");

const UA_PRODUCT = "zmcp-hn/0.1.0";
const DEFAULT_N: usize = 10;
const MAX_N: usize = 50;
const COMMENT_TRUNCATE: usize = 500;

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    const io = init.io;

    try mcp.run(
        arena,
        io,
        .{ .name = "zmcp-hn", .version = "0.1.0" },
        &tool_table,
    );
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "hn_search",
        .read_only = true,
        .description = "Search Hacker News stories via the Algolia HN API. Returns top-N hits with title, points, author, url, story_id, created_at.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "query": { "type": "string", "description": "Full-text search query." },
        \\    "n": { "type": "integer", "description": "Max results to return (default 10, max 50).", "minimum": 1, "maximum": 50 }
        \\  },
        \\  "required": ["query"]
        \\}
        ,
        .handler = handleSearch,
    },
    .{
        .name = "hn_top",
        .read_only = true,
        .description = "Fetch the current top N Hacker News stories from the Firebase API.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "n": { "type": "integer", "description": "Number of top stories to return (default 10, max 50).", "minimum": 1, "maximum": 50 }
        \\  },
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleTop,
    },
    .{
        .name = "hn_thread",
        .read_only = true,
        .description = "Fetch a Hacker News story and its full nested comment tree. Uses Algolia /items/<id> for convenience.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "id": { "type": "integer", "description": "HN story/item id." }
        \\  },
        \\  "required": ["id"],
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleThread,
    },
};

// ---------------------------------------------------------------------------
// HTTP helper
// ---------------------------------------------------------------------------

fn fetchUrl(allocator: std.mem.Allocator, io: std.Io, url: []const u8) ![]const u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    const ua_owned = try mcp.userAgent(allocator, io, UA_PRODUCT);
    defer allocator.free(ua_owned);

    var resp_buf: std.Io.Writer.Allocating = .init(allocator);
    defer resp_buf.deinit();

    _ = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &resp_buf.writer,
        .method = .GET,
        .extra_headers = &.{
            .{ .name = "User-Agent", .value = ua_owned },
            .{ .name = "Accept", .value = "application/json" },
        },
    });

    return allocator.dupe(u8, resp_buf.written());
}

// ---------------------------------------------------------------------------
// HTML stripping (basic subset needed for HN text fields)
// ---------------------------------------------------------------------------

/// Strip HTML tags and decode common entities. Result owned by caller.
fn stripHtml(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '<') {
            if (std.ascii.startsWithIgnoreCase(input[i..], "<p>")) {
                try out.writer.writeAll("\n\n");
                i += 3;
                continue;
            }
            if (std.ascii.startsWithIgnoreCase(input[i..], "<br>") or
                std.ascii.startsWithIgnoreCase(input[i..], "<br/>") or
                std.ascii.startsWithIgnoreCase(input[i..], "<br />"))
            {
                try out.writer.writeAll("\n");
                const end = std.mem.indexOfScalarPos(u8, input, i, '>') orelse input.len - 1;
                i = end + 1;
                continue;
            }
            // skip all other tags
            const end = std.mem.indexOfScalarPos(u8, input, i, '>') orelse input.len - 1;
            i = end + 1;
            continue;
        }
        if (input[i] == '&') {
            if (std.mem.startsWith(u8, input[i..], "&amp;")) {
                try out.writer.writeByte('&');
                i += 5;
            } else if (std.mem.startsWith(u8, input[i..], "&lt;")) {
                try out.writer.writeByte('<');
                i += 4;
            } else if (std.mem.startsWith(u8, input[i..], "&gt;")) {
                try out.writer.writeByte('>');
                i += 4;
            } else if (std.mem.startsWith(u8, input[i..], "&quot;")) {
                try out.writer.writeByte('"');
                i += 6;
            } else if (std.mem.startsWith(u8, input[i..], "&#x27;")) {
                try out.writer.writeByte('\'');
                i += 6;
            } else if (std.mem.startsWith(u8, input[i..], "&#x2F;") or
                std.mem.startsWith(u8, input[i..], "&#x2f;"))
            {
                try out.writer.writeByte('/');
                i += 6;
            } else {
                try out.writer.writeByte(input[i]);
                i += 1;
            }
            continue;
        }
        try out.writer.writeByte(input[i]);
        i += 1;
    }

    return allocator.dupe(u8, out.written());
}

// ---------------------------------------------------------------------------
// Date formatting (Unix timestamp -> "yyyy-mm-dd")
// ---------------------------------------------------------------------------

fn formatDate(buf: []u8, unix_s: i64) []u8 {
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, unix_s)) };
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
    }) catch unreachable;
}

// ---------------------------------------------------------------------------
// JSON field helpers
// ---------------------------------------------------------------------------

fn jsonStr(v: std.json.Value, field: []const u8) []const u8 {
    if (v != .object) return "";
    const fv = v.object.get(field) orelse return "";
    return switch (fv) {
        .string => |s| s,
        else => "",
    };
}

fn jsonInt(v: std.json.Value, field: []const u8) i64 {
    if (v != .object) return 0;
    const fv = v.object.get(field) orelse return 0;
    return switch (fv) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}

fn jsonOptStr(v: std.json.Value, field: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const fv = v.object.get(field) orelse return null;
    return switch (fv) {
        .string => |s| s,
        .null => null,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// hn_search
// ---------------------------------------------------------------------------

fn handleSearch(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const query = jsonStr(args, "query");
    if (query.len == 0) return .{ .text = "Missing required argument: query", .is_error = true };

    const n: usize = if (jsonInt(args, "n") > 0)
        @min(@as(usize, @intCast(jsonInt(args, "n"))), MAX_N)
    else
        DEFAULT_N;

    var url_buf: [1024]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buf,
        "https://hn.algolia.com/api/v1/search?query={s}&tags=story&hitsPerPage={d}",
        .{ query, n },
    );

    const body = fetchUrl(allocator, io, url) catch |err| {
        return .{ .text = try std.fmt.allocPrint(allocator, "HTTP error: {}", .{err}), .is_error = true };
    };
    defer allocator.free(body);

    return searchInner(allocator, query, body);
}

/// Testable inner function — takes raw JSON body bytes.
pub fn searchInner(allocator: std.mem.Allocator, query: []const u8, body: []const u8) !mcp.ToolResult {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch |err| {
        return .{ .text = try std.fmt.allocPrint(allocator, "JSON parse error: {}", .{err}), .is_error = true };
    };
    defer parsed.deinit();

    const root = parsed.value;
    const hits_v = if (root == .object) root.object.get("hits") orelse .null else std.json.Value{ .null = {} };
    const hits = if (hits_v == .array) hits_v.array.items else &[_]std.json.Value{};
    const nb_hits = jsonInt(root, "nbHits");

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.print("Search: {s}\nResults: {d} of {d}\n\n", .{ query, hits.len, nb_hits });

    var date_buf: [16]u8 = undefined;
    for (hits) |h| {
        const title = blk: {
            if (jsonOptStr(h, "title")) |t| break :blk t;
            if (jsonOptStr(h, "story_title")) |t| break :blk t;
            break :blk "(untitled)";
        };
        const points = jsonInt(h, "points");
        const author = jsonOptStr(h, "author") orelse "(unknown)";
        const story_id = jsonStr(h, "objectID");
        const created_at_i = jsonInt(h, "created_at_i");
        const date_str = if (created_at_i != 0) formatDate(&date_buf, created_at_i) else "unknown";

        try out.writer.print("[{d}] {s} — {s} ({s}) https://news.ycombinator.com/item?id={s}\n", .{
            points,
            title,
            author,
            date_str,
            story_id,
        });
    }

    return .{ .text = try allocator.dupe(u8, out.written()) };
}

// ---------------------------------------------------------------------------
// hn_top
// ---------------------------------------------------------------------------

fn handleTop(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const n: usize = if (jsonInt(args, "n") > 0)
        @min(@as(usize, @intCast(jsonInt(args, "n"))), MAX_N)
    else
        DEFAULT_N;

    const ids_body = fetchUrl(allocator, io, "https://hacker-news.firebaseio.com/v0/topstories.json") catch |err| {
        return .{ .text = try std.fmt.allocPrint(allocator, "HTTP error fetching topstories: {}", .{err}), .is_error = true };
    };
    defer allocator.free(ids_body);

    const ids_parsed = std.json.parseFromSlice(std.json.Value, allocator, ids_body, .{}) catch |err| {
        return .{ .text = try std.fmt.allocPrint(allocator, "JSON parse error: {}", .{err}), .is_error = true };
    };
    defer ids_parsed.deinit();

    const ids_arr = if (ids_parsed.value == .array) ids_parsed.value.array.items else
        return .{ .text = "Unexpected response from topstories API", .is_error = true };
    const take = @min(n, ids_arr.len);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.print("Top {d} Hacker News stories:\n\n", .{take});

    var date_buf: [16]u8 = undefined;
    var url_buf: [256]u8 = undefined;
    for (ids_arr[0..take]) |id_v| {
        const id: i64 = switch (id_v) {
            .integer => |n2| n2,
            else => continue,
        };

        const item_url = try std.fmt.bufPrint(&url_buf, "https://hacker-news.firebaseio.com/v0/item/{d}.json", .{id});
        const item_body = fetchUrl(allocator, io, item_url) catch continue;
        defer allocator.free(item_body);

        const item_parsed = std.json.parseFromSlice(std.json.Value, allocator, item_body, .{}) catch continue;
        defer item_parsed.deinit();
        const item = item_parsed.value;

        const title = jsonOptStr(item, "title") orelse "(untitled)";
        const by = jsonOptStr(item, "by") orelse "(unknown)";
        const score = jsonInt(item, "score");
        const time_v = jsonInt(item, "time");
        const date_str = if (time_v != 0) formatDate(&date_buf, time_v) else "unknown";
        const num_comments = jsonInt(item, "descendants");
        const link = jsonOptStr(item, "url") orelse "";

        try out.writer.print("[{d}] {s} — {s} ({s}) https://news.ycombinator.com/item?id={d}\n", .{
            score,
            title,
            by,
            date_str,
            id,
        });
        if (link.len > 0) {
            try out.writer.print("  link -> {s}\n", .{link});
        }
        try out.writer.print("  {d} comments\n", .{num_comments});
    }

    return .{ .text = try allocator.dupe(u8, out.written()) };
}

// ---------------------------------------------------------------------------
// hn_thread  (uses Algolia /items/<id> for the nested tree)
// ---------------------------------------------------------------------------

fn handleThread(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const id = jsonInt(args, "id");
    if (id <= 0) return .{ .text = "Missing or invalid required argument: id", .is_error = true };

    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://hn.algolia.com/api/v1/items/{d}", .{id});

    const body = fetchUrl(allocator, io, url) catch |err| {
        return .{ .text = try std.fmt.allocPrint(allocator, "HTTP error: {}", .{err}), .is_error = true };
    };
    defer allocator.free(body);

    return threadInner(allocator, body);
}

/// Testable inner function — takes raw JSON body bytes.
pub fn threadInner(allocator: std.mem.Allocator, body: []const u8) !mcp.ToolResult {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch |err| {
        return .{ .text = try std.fmt.allocPrint(allocator, "JSON parse error: {}", .{err}), .is_error = true };
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root == .null) {
        return .{ .text = try allocator.dupe(u8, "Story not found."), .is_error = true };
    }

    const title = jsonOptStr(root, "title") orelse "(untitled)";
    const author = jsonOptStr(root, "author") orelse "(unknown)";
    const points = jsonInt(root, "points");
    const story_id = jsonInt(root, "id");
    const url_field = jsonOptStr(root, "url") orelse "";
    const story_text_raw = jsonOptStr(root, "text") orelse "";

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.print("# {s}\n", .{title});
    try out.writer.print("by {s} · {d} points\n", .{ author, points });
    try out.writer.print("https://news.ycombinator.com/item?id={d}\n", .{story_id});
    if (url_field.len > 0) {
        try out.writer.print("Link: {s}\n", .{url_field});
    }
    if (story_text_raw.len > 0) {
        const story_text = try stripHtml(allocator, story_text_raw);
        defer allocator.free(story_text);
        try out.writer.print("\n{s}\n", .{story_text});
    }
    try out.writer.writeAll("\n---  comments  ---\n");

    const children_v = if (root == .object) root.object.get("children") orelse .null else std.json.Value{ .null = {} };
    if (children_v == .array) {
        try renderComments(allocator, &out, children_v.array.items, 0);
    }

    return .{ .text = try allocator.dupe(u8, out.written()) };
}

fn renderComments(
    allocator: std.mem.Allocator,
    out: *std.Io.Writer.Allocating,
    items: []const std.json.Value,
    depth: usize,
) !void {
    const indent_unit = "  ";
    const max_depth: usize = 6;
    const effective_depth = @min(depth, max_depth);

    for (items) |item| {
        if (item != .object) continue;

        const text_raw = jsonOptStr(item, "text") orelse "";
        const item_author = jsonOptStr(item, "author") orelse "(unknown)";
        const created_at = jsonOptStr(item, "created_at") orelse "";
        // created_at looks like "2023-01-15T10:30:00.000Z"; take the date portion
        const date_part = if (created_at.len >= 10) created_at[0..10] else created_at;

        // Write indent
        for (0..effective_depth) |_| {
            try out.writer.writeAll(indent_unit);
        }

        try out.writer.print("• {s}", .{item_author});
        if (date_part.len > 0) {
            try out.writer.print(" ({s})", .{date_part});
        }
        try out.writer.writeByte('\n');

        if (text_raw.len > 0) {
            const text_clean = try stripHtml(allocator, text_raw);
            defer allocator.free(text_clean);

            const truncated = text_clean.len > COMMENT_TRUNCATE;
            const display_text = if (truncated) text_clean[0..COMMENT_TRUNCATE] else text_clean;

            var line_it = std.mem.splitScalar(u8, display_text, '\n');
            while (line_it.next()) |ln| {
                for (0..effective_depth) |_| {
                    try out.writer.writeAll(indent_unit);
                }
                try out.writer.print("  {s}\n", .{ln});
            }
            if (truncated) {
                for (0..effective_depth) |_| {
                    try out.writer.writeAll(indent_unit);
                }
                try out.writer.writeAll("  [...truncated...]\n");
            }
        }

        // Recurse into children
        const children_v = item.object.get("children") orelse .null;
        if (children_v == .array) {
            try renderComments(allocator, out, children_v.array.items, depth + 1);
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "searchInner formats hits correctly" {
    const allocator = std.testing.allocator;

    const fixture =
        \\{
        \\  "hits": [
        \\    {
        \\      "objectID": "12345",
        \\      "title": "A Cool Story",
        \\      "author": "pg",
        \\      "points": 999,
        \\      "created_at_i": 1704067200,
        \\      "url": "https://example.com"
        \\    },
        \\    {
        \\      "objectID": "67890",
        \\      "title": "Another Post",
        \\      "author": "dang",
        \\      "points": 42,
        \\      "created_at_i": 1704153600,
        \\      "url": null
        \\    }
        \\  ],
        \\  "nbHits": 1234
        \\}
    ;

    const result = try searchInner(allocator, "cool stuff", fixture);
    defer allocator.free(result.text);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "A Cool Story") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "pg") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "999") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "https://news.ycombinator.com/item?id=12345") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "2024-01-01") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "cool stuff") != null);
}

test "searchInner handles empty hits" {
    const allocator = std.testing.allocator;

    const fixture =
        \\{"hits": [], "nbHits": 0}
    ;

    const result = try searchInner(allocator, "nothing", fixture);
    defer allocator.free(result.text);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Results: 0") != null);
}

test "threadInner formats story and comments" {
    const allocator = std.testing.allocator;

    const fixture =
        \\{
        \\  "id": 42,
        \\  "title": "Launch HN: My Cool Startup",
        \\  "author": "founder",
        \\  "points": 350,
        \\  "url": "https://mycoolstartup.com",
        \\  "text": null,
        \\  "created_at": "2024-01-01T10:00:00.000Z",
        \\  "children": [
        \\    {
        \\      "id": 101,
        \\      "author": "alice",
        \\      "text": "This is a great project!",
        \\      "created_at": "2024-01-01T11:00:00.000Z",
        \\      "children": [
        \\        {
        \\          "id": 102,
        \\          "author": "bob",
        \\          "text": "I agree with alice.",
        \\          "created_at": "2024-01-01T12:00:00.000Z",
        \\          "children": []
        \\        }
        \\      ]
        \\    },
        \\    {
        \\      "id": 103,
        \\      "author": "charlie",
        \\      "text": "How does it &amp; handle scaling?",
        \\      "created_at": "2024-01-01T13:00:00.000Z",
        \\      "children": []
        \\    }
        \\  ]
        \\}
    ;

    const result = try threadInner(allocator, fixture);
    defer allocator.free(result.text);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Launch HN: My Cool Startup") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "founder") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "350") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "https://mycoolstartup.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "This is a great project") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "bob") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "I agree with alice") != null);
    // HTML entity decoded: &amp; -> &
    try std.testing.expect(std.mem.indexOf(u8, result.text, "How does it & handle scaling") != null);
}

test "threadInner truncates long comments" {
    const allocator = std.testing.allocator;

    // Build a comment body with >500 chars
    var long_text_buf: [600]u8 = undefined;
    @memset(&long_text_buf, 'x');
    var fixture_buf: [1024]u8 = undefined;
    const fixture = try std.fmt.bufPrint(&fixture_buf,
        \\{{
        \\  "id": 1,
        \\  "title": "Story",
        \\  "author": "a",
        \\  "points": 1,
        \\  "children": [
        \\    {{
        \\      "id": 2,
        \\      "author": "b",
        \\      "text": "{s}",
        \\      "created_at": "2024-01-01T00:00:00.000Z",
        \\      "children": []
        \\    }}
        \\  ]
        \\}}
    , .{long_text_buf[0..600]});

    const result = try threadInner(allocator, fixture);
    defer allocator.free(result.text);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "[...truncated...]") != null);
}

test "threadInner null story" {
    const allocator = std.testing.allocator;
    const result = try threadInner(allocator, "null");
    defer allocator.free(result.text);
    try std.testing.expect(result.is_error);
}

test "stripHtml basic" {
    const allocator = std.testing.allocator;
    const out = try stripHtml(allocator, "<p>Hello &amp; world<br/>How are you?</p>");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Hello & world") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "How are you?") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<") == null);
}
