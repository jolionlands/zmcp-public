//! zmcp-rss - pure-Zig port of the local `rss` MCP.
//! Fetch RSS/Atom feeds, extract headline fields, and merge/sort results.

const std = @import("std");
const mcp = @import("mcp");

const UA_PRODUCT = "zmcp-rss/0.1.0";
const SUMMARY_LIMIT: usize = 400;

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    const io = init.io;
    try mcp.run(arena, io, .{ .name = "zmcp-rss", .version = "0.1.0" }, &tool_table);
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "rss_fetch",
        .read_only = true,
        .description = "Fetch one RSS or Atom feed URL. Returns items sorted by date desc. Optional limit defaults to 25.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "url": { "type": "string", "description": "Feed URL." },
        \\    "limit": { "type": "integer", "description": "Default 25." }
        \\  },
        \\  "required": ["url"]
        \\}
        ,
        .handler = handleFetch,
    },
    .{
        .name = "rss_fetch_many",
        .read_only = true,
        .description = "Fetch multiple feed URLs and merge them, sorted by date desc. One failing feed does not fail the whole call.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "urls": { "type": "array", "items": { "type": "string" } },
        \\    "limit_per_feed": { "type": "integer", "description": "Default 10." },
        \\    "total_limit": { "type": "integer", "description": "Default 50 after merge." }
        \\  },
        \\  "required": ["urls"]
        \\}
        ,
        .handler = handleFetchMany,
    },
};

const HttpResp = struct {
    status: u16,
    body: []u8,
};

const FeedItem = struct {
    title: []u8,
    link: []u8,
    pub_date: []u8,
    summary: []u8,
    source: []u8,
};

const FeedError = struct {
    url: []u8,
    message: []u8,
};

fn httpsGet(alloc: std.mem.Allocator, io: std.Io, url: []const u8) !HttpResp {
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();
    const ua_owned = try mcp.userAgent(alloc, io, UA_PRODUCT);
    defer alloc.free(ua_owned);

    var resp_buf: std.Io.Writer.Allocating = .init(alloc);
    defer resp_buf.deinit();
    var decompress_buf: [128 * 1024]u8 = undefined;

    const fetch_res = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &resp_buf.writer,
        .method = .GET,
        .extra_headers = &.{
            .{ .name = "User-Agent", .value = ua_owned },
            .{ .name = "Accept", .value = "application/atom+xml, application/rss+xml, application/xml;q=0.9, */*;q=0.5" },
        },
        .decompress_buffer = &decompress_buf,
    });

    return .{
        .status = @intFromEnum(fetch_res.status),
        .body = try alloc.dupe(u8, resp_buf.written()),
    };
}

fn getStr(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
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

fn getUrls(args: std.json.Value) ?std.json.Array {
    if (args != .object) return null;
    const v = args.object.get("urls") orelse return null;
    return if (v == .array) v.array else null;
}

fn trimWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and std.ascii.isWhitespace(s[start])) : (start += 1) {}
    while (end > start and std.ascii.isWhitespace(s[end - 1])) : (end -= 1) {}
    return s[start..end];
}

fn appendDecoded(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        if (std.mem.startsWith(u8, s[i..], "<![CDATA[")) {
            const end = std.mem.indexOf(u8, s[i + 9 ..], "]]>") orelse {
                try out.appendSlice(alloc, s[i..]);
                break;
            };
            try out.appendSlice(alloc, s[i + 9 .. i + 9 + end]);
            i += 9 + end + 3;
            continue;
        }
        if (s[i] == '&') {
            if (std.mem.startsWith(u8, s[i..], "&amp;")) {
                try out.append(alloc, '&');
                i += 5;
                continue;
            } else if (std.mem.startsWith(u8, s[i..], "&lt;")) {
                try out.append(alloc, '<');
                i += 4;
                continue;
            } else if (std.mem.startsWith(u8, s[i..], "&gt;")) {
                try out.append(alloc, '>');
                i += 4;
                continue;
            } else if (std.mem.startsWith(u8, s[i..], "&quot;")) {
                try out.append(alloc, '"');
                i += 6;
                continue;
            } else if (std.mem.startsWith(u8, s[i..], "&apos;") or std.mem.startsWith(u8, s[i..], "&#39;")) {
                try out.append(alloc, '\'');
                i += if (std.mem.startsWith(u8, s[i..], "&apos;")) 6 else 5;
                continue;
            } else if (std.mem.startsWith(u8, s[i..], "&#x")) {
                if (std.mem.indexOfScalar(u8, s[i..], ';')) |semi| {
                    const hex = s[i + 3 .. i + semi];
                    const n = std.fmt.parseInt(u21, hex, 16) catch 0;
                    var buf: [4]u8 = undefined;
                    const utf8 = std.unicode.utf8Encode(n, &buf) catch 0;
                    try out.appendSlice(alloc, buf[0..utf8]);
                    i += semi + 1;
                    continue;
                }
            } else if (std.mem.startsWith(u8, s[i..], "&#")) {
                if (std.mem.indexOfScalar(u8, s[i..], ';')) |semi| {
                    const dec = s[i + 2 .. i + semi];
                    const n = std.fmt.parseInt(u21, dec, 10) catch 0;
                    var buf: [4]u8 = undefined;
                    const utf8 = std.unicode.utf8Encode(n, &buf) catch 0;
                    try out.appendSlice(alloc, buf[0..utf8]);
                    i += semi + 1;
                    continue;
                }
            }
        }
        try out.append(alloc, s[i]);
        i += 1;
    }
}

fn decode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try appendDecoded(&out, alloc, s);
    return out.toOwnedSlice(alloc);
}

fn stripTags(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const decoded = try decode(alloc, s);
    defer alloc.free(decoded);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var in_tag = false;
    var last_space = false;
    for (decoded) |c| {
        if (c == '<') {
            in_tag = true;
            if (!last_space and out.items.len > 0) {
                try out.append(alloc, ' ');
                last_space = true;
            }
            continue;
        }
        if (c == '>') {
            in_tag = false;
            continue;
        }
        if (in_tag) continue;
        if (std.ascii.isWhitespace(c)) {
            if (!last_space and out.items.len > 0) {
                try out.append(alloc, ' ');
                last_space = true;
            }
        } else {
            try out.append(alloc, c);
            last_space = false;
        }
    }
    const trimmed = trimWhitespace(out.items);
    const clipped = if (trimmed.len > SUMMARY_LIMIT) trimmed[0..SUMMARY_LIMIT] else trimmed;
    return alloc.dupe(u8, clipped);
}

fn maybeIsoDate(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const trimmed = trimWhitespace(s);
    if (trimmed.len == 0) return alloc.dupe(u8, "");
    return alloc.dupe(u8, trimmed);
}

fn tagTextIn(block: []const u8, tag: []const u8) ?[]const u8 {
    var start_pat_buf: [64]u8 = undefined;
    var end_pat_buf: [64]u8 = undefined;
    const start_pat = std.fmt.bufPrint(&start_pat_buf, "<{s}", .{tag}) catch return null;
    const open_idx = std.mem.indexOf(u8, block, start_pat) orelse return null;
    const gt_rel = std.mem.indexOfScalar(u8, block[open_idx..], '>') orelse return null;
    const content_start = open_idx + gt_rel + 1;
    const end_pat = std.fmt.bufPrint(&end_pat_buf, "</{s}>", .{tag}) catch return null;
    const end_rel = std.mem.indexOf(u8, block[content_start..], end_pat) orelse return null;
    return block[content_start .. content_start + end_rel];
}

fn tagAttrIn(block: []const u8, tag: []const u8, attr: []const u8) ?[]const u8 {
    var start_pat_buf: [64]u8 = undefined;
    const start_pat = std.fmt.bufPrint(&start_pat_buf, "<{s}", .{tag}) catch return null;
    const open_idx = std.mem.indexOf(u8, block, start_pat) orelse return null;
    const gt_rel = std.mem.indexOfScalar(u8, block[open_idx..], '>') orelse return null;
    const tag_body = block[open_idx .. open_idx + gt_rel + 1];

    var key_buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{s}=\"", .{attr}) catch return null;
    const key_idx = std.mem.indexOf(u8, tag_body, key) orelse return null;
    const val_start = key_idx + key.len;
    const val_end_rel = std.mem.indexOfScalar(u8, tag_body[val_start..], '"') orelse return null;
    return tag_body[val_start .. val_start + val_end_rel];
}

fn collectBlocks(alloc: std.mem.Allocator, xml: []const u8, open_tag: []const u8, close_tag: []const u8) !std.ArrayList([]const u8) {
    var blocks: std.ArrayList([]const u8) = .empty;
    errdefer blocks.deinit(alloc);
    var pos: usize = 0;
    while (pos < xml.len) {
        const start_rel = std.mem.indexOf(u8, xml[pos..], open_tag) orelse break;
        const start = pos + start_rel;
        const end_rel = std.mem.indexOf(u8, xml[start..], close_tag) orelse break;
        const end = start + end_rel + close_tag.len;
        try blocks.append(alloc, xml[start..end]);
        pos = end;
    }
    return blocks;
}

fn parseFeedItems(alloc: std.mem.Allocator, xml: []const u8, source_url: []const u8) !std.ArrayList(FeedItem) {
    var items: std.ArrayList(FeedItem) = .empty;
    errdefer {
        for (items.items) |it| {
            alloc.free(it.title);
            alloc.free(it.link);
            alloc.free(it.pub_date);
            alloc.free(it.summary);
            alloc.free(it.source);
        }
        items.deinit(alloc);
    }

    var rss_items = try collectBlocks(alloc, xml, "<item", "</item>");
    defer rss_items.deinit(alloc);
    if (rss_items.items.len > 0) {
        for (rss_items.items) |block| {
            const title_raw = tagTextIn(block, "title") orelse "";
            const link_raw = tagTextIn(block, "link") orelse (tagAttrIn(block, "link", "href") orelse "");
            const date_raw = tagTextIn(block, "pubDate") orelse (tagTextIn(block, "dc:date") orelse "");
            const summary_raw = tagTextIn(block, "description") orelse (tagTextIn(block, "content:encoded") orelse "");
            try items.append(alloc, .{
                .title = try decode(alloc, title_raw),
                .link = try decode(alloc, link_raw),
                .pub_date = try maybeIsoDate(alloc, date_raw),
                .summary = try stripTags(alloc, summary_raw),
                .source = try alloc.dupe(u8, source_url),
            });
        }
        return items;
    }

    var atom_entries = try collectBlocks(alloc, xml, "<entry", "</entry>");
    defer atom_entries.deinit(alloc);
    for (atom_entries.items) |block| {
        const title_raw = tagTextIn(block, "title") orelse "";
        const link_raw = tagAttrIn(block, "link", "href") orelse (tagTextIn(block, "link") orelse "");
        const date_raw = tagTextIn(block, "updated") orelse (tagTextIn(block, "published") orelse "");
        const summary_raw = tagTextIn(block, "summary") orelse (tagTextIn(block, "content") orelse "");
        try items.append(alloc, .{
            .title = try decode(alloc, title_raw),
            .link = try decode(alloc, link_raw),
            .pub_date = try maybeIsoDate(alloc, date_raw),
            .summary = try stripTags(alloc, summary_raw),
            .source = try alloc.dupe(u8, source_url),
        });
    }
    return items;
}

fn lessByDate(_: void, a: FeedItem, b: FeedItem) bool {
    return std.mem.order(u8, a.pub_date, b.pub_date) == .gt;
}

fn itemsToJson(alloc: std.mem.Allocator, items: []const FeedItem) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var js = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try js.beginArray();
    for (items) |it| {
        try js.beginObject();
        try js.objectField("title");
        try js.write(it.title);
        try js.objectField("link");
        try js.write(it.link);
        try js.objectField("pubDate");
        try js.write(it.pub_date);
        try js.objectField("summary");
        try js.write(it.summary);
        try js.objectField("source");
        try js.write(it.source);
        try js.endObject();
    }
    try js.endArray();
    return out.toOwnedSlice();
}

fn mergedToJson(alloc: std.mem.Allocator, items: []const FeedItem, errors: []const FeedError) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var js = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try js.beginObject();
    try js.objectField("items");
    try js.beginArray();
    for (items) |it| {
        try js.beginObject();
        try js.objectField("title");
        try js.write(it.title);
        try js.objectField("link");
        try js.write(it.link);
        try js.objectField("pubDate");
        try js.write(it.pub_date);
        try js.objectField("summary");
        try js.write(it.summary);
        try js.objectField("source");
        try js.write(it.source);
        try js.endObject();
    }
    try js.endArray();
    try js.objectField("errors");
    try js.beginArray();
    for (errors) |er| {
        try js.beginObject();
        try js.objectField("url");
        try js.write(er.url);
        try js.objectField("error");
        try js.write(er.message);
        try js.endObject();
    }
    try js.endArray();
    try js.endObject();
    return out.toOwnedSlice();
}

fn freeItems(alloc: std.mem.Allocator, items: []FeedItem) void {
    for (items) |it| {
        alloc.free(it.title);
        alloc.free(it.link);
        alloc.free(it.pub_date);
        alloc.free(it.summary);
        alloc.free(it.source);
    }
}

fn freeErrors(alloc: std.mem.Allocator, errors: []FeedError) void {
    for (errors) |er| {
        alloc.free(er.url);
        alloc.free(er.message);
    }
}

fn handleFetch(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const url = getStr(args, "url") orelse return .{ .text = "url required", .is_error = true };
    const limit_raw = getInt(args, "limit", 25);
    const limit: usize = @intCast(@max(limit_raw, 1));

    const resp = httpsGet(alloc, io, url) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "rss_fetch failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    if (resp.status != 200) return .{ .text = try std.fmt.allocPrint(alloc, "HTTP {d}", .{resp.status}), .is_error = true };

    var items = try parseFeedItems(alloc, resp.body, url);
    defer {
        freeItems(alloc, items.items);
        items.deinit(alloc);
    }
    std.mem.sort(FeedItem, items.items, {}, lessByDate);
    if (items.items.len > limit) items.items.len = limit;
    const body = try itemsToJson(alloc, items.items);
    return .{ .text = try std.fmt.allocPrint(alloc, "{d} item(s):\n{s}", .{ items.items.len, body }) };
}

fn handleFetchMany(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const urls = getUrls(args) orelse return .{ .text = "urls required", .is_error = true };
    if (urls.items.len == 0) return .{ .text = "urls required", .is_error = true };
    const per_feed_raw = getInt(args, "limit_per_feed", 10);
    const total_raw = getInt(args, "total_limit", 50);
    const per_feed: usize = @intCast(@max(per_feed_raw, 1));
    const total: usize = @intCast(@max(total_raw, 1));

    var all_items: std.ArrayList(FeedItem) = .empty;
    var errors: std.ArrayList(FeedError) = .empty;
    defer {
        freeItems(alloc, all_items.items);
        all_items.deinit(alloc);
        freeErrors(alloc, errors.items);
        errors.deinit(alloc);
    }

    for (urls.items) |url_v| {
        if (url_v != .string) continue;
        const resp = httpsGet(alloc, io, url_v.string) catch |err| {
            try errors.append(alloc, .{
                .url = try alloc.dupe(u8, url_v.string),
                .message = try alloc.dupe(u8, @errorName(err)),
            });
            continue;
        };
        if (resp.status != 200) {
            try errors.append(alloc, .{
                .url = try alloc.dupe(u8, url_v.string),
                .message = try std.fmt.allocPrint(alloc, "HTTP {d}", .{resp.status}),
            });
            continue;
        }
        var parsed = parseFeedItems(alloc, resp.body, url_v.string) catch |err| {
            try errors.append(alloc, .{
                .url = try alloc.dupe(u8, url_v.string),
                .message = try alloc.dupe(u8, @errorName(err)),
            });
            continue;
        };
        std.mem.sort(FeedItem, parsed.items, {}, lessByDate);
        if (parsed.items.len > per_feed) parsed.items.len = per_feed;
        for (parsed.items) |it| try all_items.append(alloc, it);
        parsed = .empty;
    }

    std.mem.sort(FeedItem, all_items.items, {}, lessByDate);
    if (all_items.items.len > total) all_items.items.len = total;
    const body = try mergedToJson(alloc, all_items.items, errors.items);
    return .{ .text = try std.fmt.allocPrint(alloc, "{d} item(s) merged from {d} feed(s) ({d} errored):\n{s}", .{ all_items.items.len, urls.items.len, errors.items.len, body }) };
}
