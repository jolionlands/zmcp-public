//! zmcp-arxiv - pure-Zig port of the local `arxiv` MCP.
//! Search arXiv via the export API and fetch single-paper metadata.

const std = @import("std");
const mcp = @import("mcp");

const UA_PRODUCT = "zmcp-arxiv/0.1.0";
const SUMMARY_LIMIT: usize = 600;
const MIN_FETCH_GAP_MS: i64 = 3100;

var last_fetch_ms: i64 = 0;

/// arXiv's requested acknowledgement for API users (wording recalled from
/// arXiv's API terms of use; could not be fetched when added).
const ACKNOWLEDGEMENT = "Thank you to arXiv for use of its open access interoperability.";

fn nowMillis(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    const io = init.io;
    try mcp.run(arena, io, .{ .name = "zmcp-arxiv", .version = "0.1.0" }, &tool_table);
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "arxiv_search",
        .description = "Search arXiv via the export API. `query` uses arXiv search syntax: bare words search all fields; prefixes ti:, abs:, au:, cat: scope it. Returns title, authors, summary, pdf_url, and categories for each hit.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "query": { "type": "string", "description": "arXiv query, e.g. 'speculative decoding Snapdragon'." },
        \\    "max": { "type": "integer", "description": "Default 20, cap 100." },
        \\    "sort": { "type": "string", "description": "relevance | lastUpdatedDate | submittedDate. Default relevance." },
        \\    "order": { "type": "string", "description": "ascending | descending. Default descending." },
        \\    "max_results": { "type": "integer", "description": "Legacy alias for max." }
        \\  },
        \\  "required": ["query"]
        \\}
        ,
        .handler = handleSearch,
        .read_only = true,
    },
    .{
        .name = "arxiv_get",
        .description = "Fetch a single paper by arXiv id, e.g. '2402.07577' or 'cs.LG/0102001'. Returns full metadata plus abstract and pdf url.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "id": { "type": "string", "description": "arXiv id without version suffix." }
        \\  },
        \\  "required": ["id"]
        \\}
        ,
        .handler = handleGet,
        .read_only = true,
    },
};

const HttpResp = struct {
    status: u16,
    body: []u8,
};

const Paper = struct {
    id: []u8,
    title: []u8,
    authors: [][]u8,
    summary: []u8,
    published: []u8,
    updated: []u8,
    pdf_url: ?[]u8,
    categories: [][]u8,
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
            .{ .name = "Accept", .value = "application/atom+xml, application/xml;q=0.9, */*;q=0.5" },
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

fn collapseWhitespace(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const decoded = try decode(alloc, s);
    defer alloc.free(decoded);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var last_space = false;
    for (decoded) |c| {
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

fn tagAttr(tag_text: []const u8, attr: []const u8) ?[]const u8 {
    var key_buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{s}=\"", .{attr}) catch return null;
    const key_idx = std.mem.indexOf(u8, tag_text, key) orelse return null;
    const val_start = key_idx + key.len;
    const val_end_rel = std.mem.indexOfScalar(u8, tag_text[val_start..], '"') orelse return null;
    return tag_text[val_start .. val_start + val_end_rel];
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

fn extractAuthors(alloc: std.mem.Allocator, block: []const u8) !std.ArrayList([]u8) {
    var authors: std.ArrayList([]u8) = .empty;
    errdefer {
        for (authors.items) |author| alloc.free(author);
        authors.deinit(alloc);
    }
    var pos: usize = 0;
    while (pos < block.len) {
        const start_rel = std.mem.indexOf(u8, block[pos..], "<author>") orelse break;
        const start = pos + start_rel;
        const end_rel = std.mem.indexOf(u8, block[start..], "</author>") orelse break;
        const end = start + end_rel + "</author>".len;
        const author_block = block[start..end];
        if (tagTextIn(author_block, "name")) |name_raw| {
            try authors.append(alloc, try collapseWhitespace(alloc, name_raw));
        }
        pos = end;
    }
    return authors;
}

fn extractCategories(alloc: std.mem.Allocator, block: []const u8) !std.ArrayList([]u8) {
    var cats: std.ArrayList([]u8) = .empty;
    errdefer {
        for (cats.items) |cat| alloc.free(cat);
        cats.deinit(alloc);
    }
    var pos: usize = 0;
    while (pos < block.len) {
        const start_rel = std.mem.indexOf(u8, block[pos..], "<category") orelse break;
        const start = pos + start_rel;
        const end_rel = std.mem.indexOfScalar(u8, block[start..], '>') orelse break;
        const tag_text = block[start .. start + end_rel + 1];
        if (tagAttr(tag_text, "term")) |term_raw| {
            try cats.append(alloc, try decode(alloc, term_raw));
        }
        pos = start + end_rel + 1;
    }
    return cats;
}

fn extractPdfUrl(alloc: std.mem.Allocator, block: []const u8) !?[]u8 {
    var pos: usize = 0;
    while (pos < block.len) {
        const start_rel = std.mem.indexOf(u8, block[pos..], "<link") orelse break;
        const start = pos + start_rel;
        const end_rel = std.mem.indexOfScalar(u8, block[start..], '>') orelse break;
        const tag_text = block[start .. start + end_rel + 1];
        const title = tagAttr(tag_text, "title");
        if (title != null and std.mem.eql(u8, title.?, "pdf")) {
            if (tagAttr(tag_text, "href")) |href_raw| return try decode(alloc, href_raw);
        }
        pos = start + end_rel + 1;
    }
    return null;
}

fn normalizeId(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    const decoded = try collapseWhitespace(alloc, raw);
    defer alloc.free(decoded);
    const slash = std.mem.lastIndexOfScalar(u8, decoded, '/') orelse 0;
    const tail = if (slash > 0) decoded[slash + 1 ..] else decoded;
    if (std.mem.lastIndexOfScalar(u8, tail, 'v')) |v_idx| {
        const suffix = tail[v_idx + 1 ..];
        var digits_only = suffix.len > 0;
        for (suffix) |c| {
            if (!std.ascii.isDigit(c)) {
                digits_only = false;
                break;
            }
        }
        if (digits_only) {
            return alloc.dupe(u8, tail[0..v_idx]);
        }
    }
    return alloc.dupe(u8, tail);
}

fn clipSummary(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    const clean = try collapseWhitespace(alloc, raw);
    defer alloc.free(clean);
    const clipped = if (clean.len > SUMMARY_LIMIT) clean[0..SUMMARY_LIMIT] else clean;
    return alloc.dupe(u8, clipped);
}

fn parsePapers(alloc: std.mem.Allocator, xml: []const u8) !std.ArrayList(Paper) {
    var papers: std.ArrayList(Paper) = .empty;
    errdefer {
        for (papers.items) |paper| freePaper(alloc, paper);
        papers.deinit(alloc);
    }

    var entries = try collectBlocks(alloc, xml, "<entry", "</entry>");
    defer entries.deinit(alloc);

    for (entries.items) |block| {
        const id_raw = tagTextIn(block, "id") orelse "";
        const title_raw = tagTextIn(block, "title") orelse "";
        const summary_raw = tagTextIn(block, "summary") orelse "";
        const published_raw = tagTextIn(block, "published") orelse "";
        const updated_raw = tagTextIn(block, "updated") orelse "";
        var authors = try extractAuthors(alloc, block);
        var categories = try extractCategories(alloc, block);
        const pdf_url = try extractPdfUrl(alloc, block);

        try papers.append(alloc, .{
            .id = try normalizeId(alloc, id_raw),
            .title = try collapseWhitespace(alloc, title_raw),
            .authors = try authors.toOwnedSlice(alloc),
            .summary = try clipSummary(alloc, summary_raw),
            .published = try collapseWhitespace(alloc, published_raw),
            .updated = try collapseWhitespace(alloc, updated_raw),
            .pdf_url = pdf_url,
            .categories = try categories.toOwnedSlice(alloc),
        });
    }

    return papers;
}

fn freePaper(alloc: std.mem.Allocator, paper: Paper) void {
    alloc.free(paper.id);
    alloc.free(paper.title);
    for (paper.authors) |author| alloc.free(author);
    alloc.free(paper.authors);
    alloc.free(paper.summary);
    alloc.free(paper.published);
    alloc.free(paper.updated);
    if (paper.pdf_url) |pdf| alloc.free(pdf);
    for (paper.categories) |cat| alloc.free(cat);
    alloc.free(paper.categories);
}

fn papersToJson(alloc: std.mem.Allocator, papers: []const Paper) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var js = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try js.beginArray();
    for (papers) |paper| {
        try writePaper(&js, paper);
    }
    try js.endArray();
    return out.toOwnedSlice();
}

fn paperToJson(alloc: std.mem.Allocator, paper: Paper) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var js = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try writePaper(&js, paper);
    return out.toOwnedSlice();
}

fn writePaper(js: *std.json.Stringify, paper: Paper) !void {
    try js.beginObject();
    try js.objectField("id");
    try js.write(paper.id);
    try js.objectField("title");
    try js.write(paper.title);
    try js.objectField("authors");
    try js.beginArray();
    for (paper.authors) |author| try js.write(author);
    try js.endArray();
    try js.objectField("summary");
    try js.write(paper.summary);
    try js.objectField("published");
    try js.write(paper.published);
    try js.objectField("updated");
    try js.write(paper.updated);
    try js.objectField("pdf_url");
    if (paper.pdf_url) |pdf| {
        try js.write(pdf);
    } else {
        try js.write(null);
    }
    try js.objectField("categories");
    try js.beginArray();
    for (paper.categories) |cat| try js.write(cat);
    try js.endArray();
    try js.endObject();
}

fn rateLimitedGet(alloc: std.mem.Allocator, io: std.Io, url: []const u8) !HttpResp {
    const now = nowMillis(io);
    const elapsed = now - last_fetch_ms;
    if (elapsed < MIN_FETCH_GAP_MS) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(MIN_FETCH_GAP_MS - elapsed)), .awake) catch {};
    }
    last_fetch_ms = nowMillis(io);
    return httpsGet(alloc, io, url);
}

fn urlEncodeComponent(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.writer.writeByte(c);
        } else {
            try out.writer.print("%{X:0>2}", .{c});
        }
    }
    return alloc.dupe(u8, out.written());
}

fn handleSearch(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const query = getStr(args, "query") orelse return .{ .text = "query required", .is_error = true };
    const max_raw = if (getInt(args, "max", -1) >= 0) getInt(args, "max", 20) else getInt(args, "max_results", 20);
    const max = @min(@max(max_raw, 1), 100);
    const sort = getStr(args, "sort") orelse "relevance";
    const order = getStr(args, "order") orelse "descending";

    const enc_query = try urlEncodeComponent(alloc, query);
    defer alloc.free(enc_query);
    const enc_sort = try urlEncodeComponent(alloc, sort);
    defer alloc.free(enc_sort);
    const enc_order = try urlEncodeComponent(alloc, order);
    defer alloc.free(enc_order);

    const url = try std.fmt.allocPrint(
        alloc,
        "http://export.arxiv.org/api/query?search_query={s}&max_results={d}&sortBy={s}&sortOrder={s}",
        .{ enc_query, max, enc_sort, enc_order },
    );
    defer alloc.free(url);

    const resp = rateLimitedGet(alloc, io, url) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "arxiv_search failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    if (resp.status == 429) return .{ .text = "arxiv rate-limited (HTTP 429); back off", .is_error = true };
    if (resp.status != 200) return .{ .text = try std.fmt.allocPrint(alloc, "arxiv HTTP {d}", .{resp.status}), .is_error = true };

    var papers = try parsePapers(alloc, resp.body);
    defer {
        for (papers.items) |paper| freePaper(alloc, paper);
        papers.deinit(alloc);
    }

    const body = try papersToJson(alloc, papers.items);
    return .{ .text = try std.fmt.allocPrint(alloc, "{d} hit(s):\n{s}\n\n{s}", .{ papers.items.len, body, ACKNOWLEDGEMENT }) };
}

fn handleGet(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const id = getStr(args, "id") orelse return .{ .text = "id required", .is_error = true };
    const enc_id = try urlEncodeComponent(alloc, id);
    defer alloc.free(enc_id);

    const url = try std.fmt.allocPrint(alloc, "http://export.arxiv.org/api/query?id_list={s}", .{enc_id});
    defer alloc.free(url);

    const resp = rateLimitedGet(alloc, io, url) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "arxiv_get failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    if (resp.status != 200) return .{ .text = try std.fmt.allocPrint(alloc, "arxiv HTTP {d}", .{resp.status}), .is_error = true };

    var papers = try parsePapers(alloc, resp.body);
    defer {
        for (papers.items) |paper| freePaper(alloc, paper);
        papers.deinit(alloc);
    }
    if (papers.items.len == 0) return .{ .text = "(no entry returned)" };

    const body = try paperToJson(alloc, papers.items[0]);
    defer alloc.free(body);
    return .{ .text = try std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ body, ACKNOWLEDGEMENT }) };
}

test "acknowledgement wording" {
    try std.testing.expectEqualStrings("Thank you to arXiv for use of its open access interoperability.", ACKNOWLEDGEMENT);
}
