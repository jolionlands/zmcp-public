//! zmcp-notion - compact pure-Zig port of makenotion/notion-mcp-server.
//!
//! Upstream generates ~22 tools from the Notion OpenAPI spec. This port ships a
//! small hand-written set that returns compact text instead of raw JSON.
//! Auth: NOTION_TOKEN, or OPENAPI_MCP_HEADERS (JSON with Authorization and
//! optionally Notion-Version), like upstream. Writes need ZMCP_NOTION_ALLOW_WRITE=1.

const std = @import("std");
const mcp = @import("mcp");

const API_BASE = "https://api.notion.com";
const NOTION_VERSION = "2025-09-03";
const UA_PRODUCT = "zmcp-notion/0.1.0";
const MAX_OUT: usize = 64 * 1024;
const MAX_REQUESTS_PER_CALL: u32 = 25;
const MAX_BLOCKS_WRITE: usize = 100;
const RICH_TEXT_CHUNK: usize = 2000;

var g_environ: ?*const std.process.Environ.Map = null;

pub fn main(init: std.process.Init) !void {
    g_environ = init.environ_map;
    try mcp.run(init.gpa, init.io, .{ .name = "zmcp-notion", .version = "0.1.0" }, &tool_table);
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "notion_search",
        .description = "Search pages/data sources by title. Paginate with cursor.",
        .input_schema_json =
        \\{"type":"object","properties":{"query":{"type":"string"},"kind":{"type":"string","enum":["page","data_source"]},"cursor":{"type":"string"},"limit":{"type":"integer","description":"1-100, default 20"}}}
        ,
        .handler = handleSearch,
        .read_only = true,
    },
    .{
        .name = "notion_page",
        .description = "Get a page's title and flattened properties (not its body; see notion_blocks).",
        .input_schema_json =
        \\{"type":"object","properties":{"page_id":{"type":"string"}},"required":["page_id"]}
        ,
        .handler = handlePage,
        .read_only = true,
    },
    .{
        .name = "notion_blocks",
        .description = "Read a page/block body as markdown-ish text. depth=nested levels to expand (default 2, max 4).",
        .input_schema_json =
        \\{"type":"object","properties":{"block_id":{"type":"string","description":"page or block id"},"cursor":{"type":"string"},"depth":{"type":"integer"}},"required":["block_id"]}
        ,
        .handler = handleBlocks,
        .read_only = true,
    },
    .{
        .name = "notion_query",
        .description = "Query a data source (database rows). filter/sorts are Notion JSON as strings.",
        .input_schema_json =
        \\{"type":"object","properties":{"data_source_id":{"type":"string"},"filter":{"type":"string","description":"JSON object"},"sorts":{"type":"string","description":"JSON array"},"cursor":{"type":"string"},"limit":{"type":"integer","description":"1-100, default 25"}},"required":["data_source_id"]}
        ,
        .handler = handleQuery,
        .read_only = true,
    },
    .{
        .name = "notion_database",
        .description = "Get a database (lists its data source ids), or with data_source=true a data source schema.",
        .input_schema_json =
        \\{"type":"object","properties":{"id":{"type":"string"},"data_source":{"type":"boolean"}},"required":["id"]}
        ,
        .handler = handleDatabase,
        .read_only = true,
    },
    .{
        .name = "notion_create_page",
        .description = "Create a page (needs ZMCP_NOTION_ALLOW_WRITE=1). parent_type page|data_source; properties is Notion JSON string (else title, page parent only); content lines become blocks (# h1..###, - bullet, 1. num, [ ] todo, > quote, ---, ``` code).",
        .input_schema_json =
        \\{"type":"object","properties":{"parent_id":{"type":"string"},"parent_type":{"type":"string","enum":["page","data_source"]},"title":{"type":"string"},"properties":{"type":"string"},"content":{"type":"string"}},"required":["parent_id"]}
        ,
        .handler = handleCreatePage,
    },
    .{
        .name = "notion_update_page",
        .description = "Update page properties (JSON string) or trash it (needs ZMCP_NOTION_ALLOW_WRITE=1).",
        .input_schema_json =
        \\{"type":"object","properties":{"page_id":{"type":"string"},"properties":{"type":"string"},"trash":{"type":"boolean"}},"required":["page_id"]}
        ,
        .handler = handleUpdatePage,
        .destructive = true,
    },
    .{
        .name = "notion_append_blocks",
        .description = "Append content (same line syntax as create_page, max 100 lines) to a page/block (needs ZMCP_NOTION_ALLOW_WRITE=1).",
        .input_schema_json =
        \\{"type":"object","properties":{"block_id":{"type":"string"},"content":{"type":"string"}},"required":["block_id","content"]}
        ,
        .handler = handleAppend,
    },
    .{
        .name = "notion_comments",
        .description = "List comments on a page/block; with text, add one (page_id or discussion_id; needs ZMCP_NOTION_ALLOW_WRITE=1).",
        .input_schema_json =
        \\{"type":"object","properties":{"block_id":{"type":"string","description":"list target"},"cursor":{"type":"string"},"text":{"type":"string"},"page_id":{"type":"string"},"discussion_id":{"type":"string"}}}
        ,
        .handler = handleComments,
    },
    .{
        .name = "notion_users",
        .description = "List workspace users.",
        .input_schema_json =
        \\{"type":"object","properties":{"cursor":{"type":"string"}}}
        ,
        .handler = handleUsers,
        .read_only = true,
    },
};

// ---------------------------------------------------------------------------
// Transport seam + env
// ---------------------------------------------------------------------------

const HttpResp = struct { status: u16, body: []const u8 };

const FetchRequest = struct {
    method: std.http.Method,
    url: []const u8,
    authorization: []const u8,
    notion_version: []const u8,
    body: ?[]const u8 = null,
};

const FetchFn = *const fn (alloc: std.mem.Allocator, io: std.Io, req: FetchRequest) anyerror!HttpResp;
var fetch_impl: FetchFn = httpsFetch;

/// Test hook replacing the process environment.
var test_env: ?[]const [2][]const u8 = null;

fn env(name: []const u8) ?[]const u8 {
    if (test_env) |te| {
        for (te) |kv| if (std.mem.eql(u8, kv[0], name)) return kv[1];
        return null;
    }
    const m = g_environ orelse return null;
    const v = m.get(name) orelse return null;
    return if (v.len == 0) null else v;
}

fn httpsFetch(alloc: std.mem.Allocator, io: std.Io, req: FetchRequest) !HttpResp {
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();
    const ua_owned = try mcp.userAgent(alloc, io, UA_PRODUCT);
    defer alloc.free(ua_owned);
    var resp_buf: std.Io.Writer.Allocating = .init(alloc);
    defer resp_buf.deinit();
    var decompress_buf: [128 * 1024]u8 = undefined;
    var hdrs: [4]std.http.Header = undefined;
    hdrs[0] = .{ .name = "Authorization", .value = req.authorization };
    hdrs[1] = .{ .name = "Notion-Version", .value = req.notion_version };
    hdrs[2] = .{ .name = "User-Agent", .value = ua_owned };
    var n: usize = 3;
    if (req.body != null) {
        hdrs[3] = .{ .name = "Content-Type", .value = "application/json" };
        n = 4;
    }
    const res = try client.fetch(.{
        .location = .{ .url = req.url },
        .response_writer = &resp_buf.writer,
        .method = req.method,
        .payload = req.body,
        .extra_headers = hdrs[0..n],
        .decompress_buffer = &decompress_buf,
    });
    return .{ .status = @intFromEnum(res.status), .body = try alloc.dupe(u8, resp_buf.written()) };
}

const Auth = struct { authorization: []const u8, version: []const u8 };

fn resolveAuth(alloc: std.mem.Allocator) !?Auth {
    if (env("NOTION_TOKEN")) |t| {
        return .{ .authorization = try std.fmt.allocPrint(alloc, "Bearer {s}", .{t}), .version = NOTION_VERSION };
    }
    if (env("OPENAPI_MCP_HEADERS")) |h| {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, h, .{}) catch return null;
        if (parsed != .object) return null;
        var authz: ?[]const u8 = null;
        var ver: []const u8 = NOTION_VERSION;
        var it = parsed.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* != .string) continue;
            if (std.ascii.eqlIgnoreCase(e.key_ptr.*, "authorization")) authz = e.value_ptr.string;
            if (std.ascii.eqlIgnoreCase(e.key_ptr.*, "notion-version")) ver = e.value_ptr.string;
        }
        const a = authz orelse return null;
        if (std.mem.indexOfScalar(u8, a, ' ') == null) {
            return .{ .authorization = try std.fmt.allocPrint(alloc, "Bearer {s}", .{a}), .version = ver };
        }
        return .{ .authorization = a, .version = ver };
    }
    return null;
}

fn writesAllowed() bool {
    const v = env("ZMCP_NOTION_ALLOW_WRITE") orelse return false;
    return std.mem.eql(u8, v, "1");
}

const write_refused = "refused: writes are disabled; set ZMCP_NOTION_ALLOW_WRITE=1 to allow create/update/append/comment";

const Api = union(enum) { ok: std.json.Value, fail: []const u8 };

fn mapError(alloc: std.mem.Allocator, status: u16, body: []const u8) ![]const u8 {
    var detail: []const u8 = "";
    if (std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{})) |v| {
        if (v == .object) if (v.object.get("message")) |m| if (m == .string) {
            detail = m.string[0..@min(m.string.len, 300)];
        };
    } else |_| {}
    const hint: []const u8 = switch (status) {
        401 => "unauthorized: NOTION_TOKEN is invalid or expired",
        403 => "forbidden: the integration lacks the capability for this action",
        404 => "not found, or not shared with the integration (share the page/database with it in Notion)",
        409 => "conflict: retry the request",
        429 => "rate limited: wait and retry",
        400 => "invalid request",
        else => if (status >= 500) "Notion server error: retry later" else "request failed",
    };
    if (detail.len > 0) return std.fmt.allocPrint(alloc, "Notion API {d}: {s} ({s})", .{ status, hint, detail });
    return std.fmt.allocPrint(alloc, "Notion API {d}: {s}", .{ status, hint });
}

fn call(alloc: std.mem.Allocator, io: std.Io, method: std.http.Method, path: []const u8, body: ?[]const u8) !Api {
    const auth = (try resolveAuth(alloc)) orelse
        return .{ .fail = "missing credentials: set NOTION_TOKEN (or OPENAPI_MCP_HEADERS with an Authorization header)" };
    const url = try std.fmt.allocPrint(alloc, "{s}{s}", .{ API_BASE, path });
    const resp = fetch_impl(alloc, io, .{
        .method = method,
        .url = url,
        .authorization = auth.authorization,
        .notion_version = auth.version,
        .body = body,
    }) catch |e| return .{ .fail = try std.fmt.allocPrint(alloc, "network error: {s}", .{@errorName(e)}) };
    if (resp.status < 200 or resp.status >= 300) return .{ .fail = try mapError(alloc, resp.status, resp.body) };
    const v = std.json.parseFromSliceLeaky(std.json.Value, alloc, resp.body, .{}) catch
        return .{ .fail = "invalid JSON in Notion response" };
    return .{ .ok = v };
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

const Buf = struct {
    a: std.mem.Allocator,
    l: std.ArrayList(u8) = .empty,
    fn add(self: *Buf, s: []const u8) !void {
        try self.l.appendSlice(self.a, s);
    }
    fn addc(self: *Buf, c: u8) !void {
        try self.l.append(self.a, c);
    }
    fn print(self: *Buf, comptime f: []const u8, args: anytype) !void {
        try self.l.print(self.a, f, args);
    }
    fn indent(self: *Buf, n: usize) !void {
        for (0..n) |_| try self.add("  ");
    }
};

fn text(s: []const u8) mcp.ToolResult {
    return .{ .text = s };
}
fn err(s: []const u8) mcp.ToolResult {
    return .{ .text = s, .is_error = true };
}
fn errf(alloc: std.mem.Allocator, comptime f: []const u8, args: anytype) !mcp.ToolResult {
    return err(try std.fmt.allocPrint(alloc, f, args));
}

/// Cap to MAX_OUT at a UTF-8 boundary and add a truncation note.
fn finish(alloc: std.mem.Allocator, b: *Buf) !mcp.ToolResult {
    if (b.l.items.len <= MAX_OUT) return text(b.l.items);
    var cut: usize = MAX_OUT;
    while (cut > 0 and (b.l.items[cut] & 0xC0) == 0x80) cut -= 1;
    return text(try std.fmt.allocPrint(alloc, "{s}\n...[truncated at {d} bytes; use cursor/limit/depth to narrow]", .{ b.l.items[0..cut], cut }));
}

fn getStr(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    if (v != .string or v.string.len == 0) return null;
    return v.string;
}
fn getInt(args: std.json.Value, key: []const u8, default: i64, lo: i64, hi: i64) i64 {
    if (args != .object) return default;
    const v = args.object.get(key) orelse return default;
    const n: i64 = switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => return default,
    };
    return std.math.clamp(n, lo, hi);
}
fn getBool(args: std.json.Value, key: []const u8) ?bool {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return if (v == .bool) v.bool else null;
}
fn field(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}
fn fstr(v: std.json.Value, key: []const u8) ?[]const u8 {
    const f = field(v, key) orelse return null;
    return if (f == .string) f.string else null;
}
fn farr(v: std.json.Value, key: []const u8) []const std.json.Value {
    const f = field(v, key) orelse return &.{};
    return if (f == .array) f.array.items else &.{};
}
fn fbool(v: std.json.Value, key: []const u8) bool {
    const f = field(v, key) orelse return false;
    return f == .bool and f.bool;
}

/// Notion ids are 32 hex chars, optionally dashed (36). Blocks path injection.
fn validId(s: []const u8) bool {
    if (s.len != 32 and s.len != 36) return false;
    for (s) |c| if (!std.ascii.isHex(c) and c != '-') return false;
    return true;
}

fn urlEncode(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(alloc, c);
        } else try out.print(alloc, "%{X:0>2}", .{c});
    }
    return out.items;
}

fn newObj() std.json.ObjectMap {
    return .empty;
}
fn jstr(s: []const u8) std.json.Value {
    return .{ .string = s };
}
fn objVal(o: std.json.ObjectMap) std.json.Value {
    return .{ .object = o };
}
fn toJson(alloc: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    return std.json.Stringify.valueAlloc(alloc, v, .{});
}

/// Parse a JSON-string argument and require an object or array.
fn parseJsonArg(alloc: std.mem.Allocator, s: []const u8, want_array: bool) !?std.json.Value {
    const v = std.json.parseFromSliceLeaky(std.json.Value, alloc, s, .{}) catch return null;
    if (want_array and v != .array) return null;
    if (!want_array and v != .object) return null;
    return v;
}

fn idArg(alloc: std.mem.Allocator, args: std.json.Value, key: []const u8) !union(enum) { id: []const u8, bad: mcp.ToolResult } {
    const s = getStr(args, key) orelse return .{ .bad = try errf(alloc, "missing required argument: {s}", .{key}) };
    if (!validId(s)) return .{ .bad = try errf(alloc, "invalid {s}: expected a 32-hex-char Notion id", .{key}) };
    return .{ .id = s };
}

// ---------------------------------------------------------------------------
// Notion JSON -> text
// ---------------------------------------------------------------------------

fn richText(b: *Buf, arr: []const std.json.Value) !void {
    for (arr) |item| {
        const pt = fstr(item, "plain_text") orelse continue;
        if (pt.len == 0) continue;
        var bold = false;
        var ital = false;
        var code = false;
        var strike = false;
        if (field(item, "annotations")) |an| {
            bold = fbool(an, "bold");
            ital = fbool(an, "italic");
            code = fbool(an, "code");
            strike = fbool(an, "strikethrough");
        }
        const href = fstr(item, "href");
        if (href != null) try b.addc('[');
        if (bold) try b.add("**");
        if (ital) try b.addc('*');
        if (strike) try b.add("~~");
        if (code) try b.addc('`');
        try b.add(pt);
        if (code) try b.addc('`');
        if (strike) try b.add("~~");
        if (ital) try b.addc('*');
        if (bold) try b.add("**");
        if (href) |h| try b.print("]({s})", .{h});
    }
}

fn richPlain(alloc: std.mem.Allocator, arr: []const std.json.Value) ![]const u8 {
    var b = Buf{ .a = alloc };
    for (arr) |item| if (fstr(item, "plain_text")) |t| try b.add(t);
    return b.l.items;
}

fn fileUrl(v: std.json.Value) ?[]const u8 {
    // Hosted file URLs are signed and long; only surface external links.
    const t = fstr(v, "type") orelse return null;
    if (std.mem.eql(u8, t, "external")) if (field(v, "external")) |e| return fstr(e, "url");
    return null;
}

const BlockCtx = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    b: *Buf,
    requests_left: u32 = MAX_REQUESTS_PER_CALL,
};

/// Render one block line (without children). Pure; unit-tested on fixtures.
fn renderBlockLine(b: *Buf, blk: std.json.Value) !void {
    const t = fstr(blk, "type") orelse return;
    const body = field(blk, t) orelse .null;
    const rt = farr(body, "rich_text");
    if (std.mem.eql(u8, t, "paragraph")) {
        try richText(b, rt);
    } else if (std.mem.eql(u8, t, "heading_1")) {
        try b.add("# ");
        try richText(b, rt);
    } else if (std.mem.eql(u8, t, "heading_2")) {
        try b.add("## ");
        try richText(b, rt);
    } else if (std.mem.eql(u8, t, "heading_3") or std.mem.eql(u8, t, "heading_4")) {
        try b.add("### ");
        try richText(b, rt);
    } else if (std.mem.eql(u8, t, "bulleted_list_item")) {
        try b.add("- ");
        try richText(b, rt);
    } else if (std.mem.eql(u8, t, "numbered_list_item")) {
        try b.add("1. ");
        try richText(b, rt);
    } else if (std.mem.eql(u8, t, "to_do")) {
        try b.add(if (fbool(body, "checked")) "- [x] " else "- [ ] ");
        try richText(b, rt);
    } else if (std.mem.eql(u8, t, "toggle")) {
        try b.add("> ");
        try richText(b, rt);
    } else if (std.mem.eql(u8, t, "quote")) {
        try b.add("> ");
        try richText(b, rt);
    } else if (std.mem.eql(u8, t, "callout")) {
        try b.add("> ");
        if (field(body, "icon")) |ic| if (fstr(ic, "emoji")) |e| try b.print("{s} ", .{e});
        try richText(b, rt);
    } else if (std.mem.eql(u8, t, "code")) {
        try b.print("```{s}\n", .{fstr(body, "language") orelse ""});
        try richText(b, rt);
        try b.add("\n```");
    } else if (std.mem.eql(u8, t, "divider")) {
        try b.add("---");
    } else if (std.mem.eql(u8, t, "equation")) {
        try b.print("$${s}$$", .{fstr(body, "expression") orelse ""});
    } else if (std.mem.eql(u8, t, "child_page")) {
        try b.print("[page: {s}]", .{fstr(body, "title") orelse ""});
    } else if (std.mem.eql(u8, t, "child_database")) {
        try b.print("[database: {s}]", .{fstr(body, "title") orelse ""});
    } else if (std.mem.eql(u8, t, "bookmark") or std.mem.eql(u8, t, "embed") or std.mem.eql(u8, t, "link_preview")) {
        try b.print("[{s}] {s}", .{ t, fstr(body, "url") orelse "" });
    } else if (std.mem.eql(u8, t, "image") or std.mem.eql(u8, t, "file") or std.mem.eql(u8, t, "pdf") or std.mem.eql(u8, t, "video") or std.mem.eql(u8, t, "audio")) {
        try b.print("[{s}]", .{t});
        if (fileUrl(body)) |u| try b.print(" {s}", .{u});
        const cap = farr(body, "caption");
        if (cap.len > 0) {
            try b.addc(' ');
            try richText(b, cap);
        }
    } else if (std.mem.eql(u8, t, "table_row")) {
        try b.addc('|');
        for (farr(body, "cells")) |cell| {
            try b.addc(' ');
            if (cell == .array) try richText(b, cell.array.items);
            try b.add(" |");
        }
    } else {
        try b.print("[{s}]", .{t});
        try richText(b, rt);
    }
}

fn renderBlocks(ctx: *BlockCtx, blocks: []const std.json.Value, level: usize, remaining: u32) anyerror!void {
    for (blocks) |blk| {
        try ctx.b.indent(level);
        try renderBlockLine(ctx.b, blk);
        const id = fstr(blk, "id") orelse "";
        const t = fstr(blk, "type") orelse "";
        const is_page = std.mem.eql(u8, t, "child_page") or std.mem.eql(u8, t, "child_database");
        if (is_page) try ctx.b.print(" {s}", .{id});
        if (fbool(blk, "has_children") and !is_page) {
            if (remaining > 0 and ctx.requests_left > 0) {
                ctx.requests_left -= 1;
                const path = try std.fmt.allocPrint(ctx.alloc, "/v1/blocks/{s}/children?page_size=100", .{id});
                switch (try call(ctx.alloc, ctx.io, .GET, path, null)) {
                    .ok => |v| {
                        try ctx.b.addc('\n');
                        try renderBlocks(ctx, farr(v, "results"), level + 1, remaining - 1);
                        if (fbool(v, "has_more")) {
                            try ctx.b.indent(level + 1);
                            try ctx.b.print("...(more: notion_blocks block_id={s} cursor={s})\n", .{ id, fstr(v, "next_cursor") orelse "" });
                        }
                        // The trailing newline below closes this block; avoid a blank line.
                        if (ctx.b.l.items.len > 0 and ctx.b.l.items[ctx.b.l.items.len - 1] == '\n') {
                            _ = ctx.b.l.pop();
                        }
                        // fallthrough to the final addc after the block
                    },
                    .fail => |m| try ctx.b.print(" (children unavailable: {s})", .{m}),
                }
            } else {
                try ctx.b.print(" (+children id={s})", .{id});
            }
        }
        try ctx.b.addc('\n');
    }
}

fn propText(alloc: std.mem.Allocator, p: std.json.Value) ![]const u8 {
    const t = fstr(p, "type") orelse return "";
    var b = Buf{ .a = alloc };
    const val = field(p, t) orelse .null;
    if (std.mem.eql(u8, t, "title") or std.mem.eql(u8, t, "rich_text")) {
        if (val == .array) try richText(&b, val.array.items);
    } else if (std.mem.eql(u8, t, "number")) {
        if (val == .integer) try b.print("{d}", .{val.integer});
        if (val == .float) try b.print("{d}", .{val.float});
    } else if (std.mem.eql(u8, t, "select") or std.mem.eql(u8, t, "status")) {
        if (fstr(val, "name")) |n| try b.add(n);
    } else if (std.mem.eql(u8, t, "multi_select")) {
        if (val == .array) for (val.array.items, 0..) |o, i| {
            if (i > 0) try b.add(", ");
            try b.add(fstr(o, "name") orelse "");
        };
    } else if (std.mem.eql(u8, t, "date")) {
        if (val == .object) {
            if (fstr(val, "start")) |s| try b.add(s);
            if (fstr(val, "end")) |e| try b.print(" -> {s}", .{e});
        }
    } else if (std.mem.eql(u8, t, "checkbox") or std.mem.eql(u8, t, "boolean")) {
        if (val == .bool) try b.add(if (val.bool) "true" else "false");
    } else if (std.mem.eql(u8, t, "string")) {
        if (val == .string) try b.add(val.string);
    } else if (std.mem.eql(u8, t, "url") or std.mem.eql(u8, t, "email") or std.mem.eql(u8, t, "phone_number") or
        std.mem.eql(u8, t, "created_time") or std.mem.eql(u8, t, "last_edited_time"))
    {
        if (val == .string) try b.add(val.string);
    } else if (std.mem.eql(u8, t, "people")) {
        if (val == .array) for (val.array.items, 0..) |o, i| {
            if (i > 0) try b.add(", ");
            try b.add(fstr(o, "name") orelse fstr(o, "id") orelse "");
        };
    } else if (std.mem.eql(u8, t, "created_by") or std.mem.eql(u8, t, "last_edited_by")) {
        if (val == .object) try b.add(fstr(val, "name") orelse fstr(val, "id") orelse "");
    } else if (std.mem.eql(u8, t, "relation")) {
        if (val == .array) for (val.array.items, 0..) |o, i| {
            if (i > 0) try b.add(", ");
            try b.add(fstr(o, "id") orelse "");
        };
    } else if (std.mem.eql(u8, t, "files")) {
        if (val == .array) for (val.array.items, 0..) |o, i| {
            if (i > 0) try b.add(", ");
            try b.add(fstr(o, "name") orelse "");
        };
    } else if (std.mem.eql(u8, t, "unique_id")) {
        if (val == .object) {
            if (fstr(val, "prefix")) |pf| try b.print("{s}-", .{pf});
            if (field(val, "number")) |n| if (n == .integer) try b.print("{d}", .{n.integer});
        }
    } else if (std.mem.eql(u8, t, "formula") or std.mem.eql(u8, t, "rollup")) {
        if (val == .object) if (fstr(val, "type")) |ft| {
            if (std.mem.eql(u8, ft, "array")) {
                for (farr(val, "array"), 0..) |item, i| {
                    if (i > 0) try b.add(", ");
                    try b.add(try propText(alloc, item));
                }
            } else {
                var o = newObj();
                try o.put(alloc, "type", jstr(ft));
                if (val.object.get(ft)) |x| try o.put(alloc, ft, x);
                return try propText(alloc, objVal(o));
            }
        };
    }
    return b.l.items;
}

fn pageTitle(alloc: std.mem.Allocator, page: std.json.Value) ![]const u8 {
    const props = field(page, "properties") orelse return "";
    if (props != .object) return "";
    var it = props.object.iterator();
    while (it.next()) |e| {
        if (fstr(e.value_ptr.*, "type")) |t| if (std.mem.eql(u8, t, "title")) return propText(alloc, e.value_ptr.*);
    }
    return "";
}

fn flattenProps(b: *Buf, alloc: std.mem.Allocator, page: std.json.Value, sep: []const u8) !void {
    const props = field(page, "properties") orelse return;
    if (props != .object) return;
    var it = props.object.iterator();
    var first = true;
    while (it.next()) |e| {
        if (fstr(e.value_ptr.*, "type")) |t| if (std.mem.eql(u8, t, "title")) continue;
        const v = try propText(alloc, e.value_ptr.*);
        if (v.len == 0) continue;
        const shown = if (v.len > 300) v[0..300] else v;
        if (!first) try b.add(sep);
        first = false;
        try b.print("{s}: {s}", .{ e.key_ptr.*, shown });
    }
}

fn pageLine(b: *Buf, alloc: std.mem.Allocator, p: std.json.Value, with_props: bool) !void {
    const obj = fstr(p, "object") orelse "page";
    try b.print("[{s}] {s} | ", .{ obj, fstr(p, "id") orelse "" });
    if (std.mem.eql(u8, obj, "page")) {
        try b.add(try pageTitle(alloc, p));
    } else {
        try b.add(try richPlain(alloc, farr(p, "title")));
    }
    if (with_props) {
        try b.add(" | ");
        try flattenProps(b, alloc, p, "; ");
    } else if (fstr(p, "url")) |u| try b.print(" | {s}", .{u});
    try b.addc('\n');
}

fn cursorHint(b: *Buf, v: std.json.Value) !void {
    if (fbool(v, "has_more")) {
        if (fstr(v, "next_cursor")) |c| try b.print("next_cursor: {s}\n", .{c});
    }
}

// ---------------------------------------------------------------------------
// Content text -> blocks
// ---------------------------------------------------------------------------

fn richTextJson(alloc: std.mem.Allocator, s: []const u8) !std.json.Value {
    var arr = std.json.Array.init(alloc);
    var i: usize = 0;
    while (true) {
        var end = @min(i + RICH_TEXT_CHUNK, s.len);
        while (end < s.len and end > i and (s[end] & 0xC0) == 0x80) end -= 1;
        var content = newObj();
        try content.put(alloc, "content", jstr(s[i..end]));
        var item = newObj();
        try item.put(alloc, "type", jstr("text"));
        try item.put(alloc, "text", objVal(content));
        try arr.append(objVal(item));
        if (end >= s.len) break;
        i = end;
    }
    return .{ .array = arr };
}

fn blockJson(alloc: std.mem.Allocator, kind: []const u8, s: []const u8, extra: ?[2][]const u8) !std.json.Value {
    var inner = newObj();
    try inner.put(alloc, "rich_text", try richTextJson(alloc, s));
    if (extra) |x| {
        if (std.mem.eql(u8, x[0], "checked")) {
            try inner.put(alloc, "checked", .{ .bool = std.mem.eql(u8, x[1], "true") });
        } else try inner.put(alloc, x[0], jstr(x[1]));
    }
    var o = newObj();
    try o.put(alloc, "object", jstr("block"));
    try o.put(alloc, "type", jstr(kind));
    try o.put(alloc, kind, objVal(inner));
    return objVal(o);
}

fn dividerJson(alloc: std.mem.Allocator) !std.json.Value {
    var o = newObj();
    try o.put(alloc, "object", jstr("block"));
    try o.put(alloc, "type", jstr("divider"));
    try o.put(alloc, "divider", objVal(newObj()));
    return objVal(o);
}

const Blocks = union(enum) { ok: std.json.Array, bad: []const u8 };

/// Convert line-oriented content into Notion block JSON (max 100 blocks).
fn contentToBlocks(alloc: std.mem.Allocator, content: []const u8) !Blocks {
    var blocks = std.json.Array.init(alloc);
    var lines = std.mem.splitScalar(u8, content, '\n');
    var in_code = false;
    var lang: []const u8 = "plain text";
    var code: Buf = .{ .a = alloc };
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (in_code) {
            if (std.mem.startsWith(u8, line, "```")) {
                in_code = false;
                try blocks.append(try blockJson(alloc, "code", code.l.items, .{ "language", lang }));
                code.l.clearRetainingCapacity();
            } else {
                if (code.l.items.len > 0) try code.addc('\n');
                try code.add(line);
            }
            continue;
        }
        const tl = std.mem.trim(u8, line, " \t");
        if (tl.len == 0) continue;
        if (std.mem.startsWith(u8, tl, "```")) {
            in_code = true;
            const l = std.mem.trim(u8, tl[3..], " ");
            lang = if (l.len > 0) l else "plain text";
            continue;
        }
        const blk: std.json.Value = if (std.mem.startsWith(u8, tl, "### "))
            try blockJson(alloc, "heading_3", tl[4..], null)
        else if (std.mem.startsWith(u8, tl, "## "))
            try blockJson(alloc, "heading_2", tl[3..], null)
        else if (std.mem.startsWith(u8, tl, "# "))
            try blockJson(alloc, "heading_1", tl[2..], null)
        else if (std.mem.eql(u8, tl, "---"))
            try dividerJson(alloc)
        else if (std.mem.startsWith(u8, tl, "- [ ] "))
            try blockJson(alloc, "to_do", tl[6..], .{ "checked", "false" })
        else if (std.mem.startsWith(u8, tl, "- [x] "))
            try blockJson(alloc, "to_do", tl[6..], .{ "checked", "true" })
        else if (std.mem.startsWith(u8, tl, "[ ] "))
            try blockJson(alloc, "to_do", tl[4..], .{ "checked", "false" })
        else if (std.mem.startsWith(u8, tl, "[x] "))
            try blockJson(alloc, "to_do", tl[4..], .{ "checked", "true" })
        else if (std.mem.startsWith(u8, tl, "- ") or std.mem.startsWith(u8, tl, "* "))
            try blockJson(alloc, "bulleted_list_item", tl[2..], null)
        else if (std.mem.startsWith(u8, tl, "> "))
            try blockJson(alloc, "quote", tl[2..], null)
        else if (numberedPrefix(tl)) |n|
            try blockJson(alloc, "numbered_list_item", tl[n..], null)
        else
            try blockJson(alloc, "paragraph", tl, null);
        try blocks.append(blk);
    }
    if (in_code) try blocks.append(try blockJson(alloc, "code", code.l.items, .{ "language", lang }));
    if (blocks.items.len > MAX_BLOCKS_WRITE) return .{ .bad = "content produces more than 100 blocks; split it across calls" };
    return .{ .ok = blocks };
}

fn numberedPrefix(s: []const u8) ?usize {
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i == 0 or i + 1 >= s.len) return null;
    if (s[i] == '.' and s[i + 1] == ' ') return i + 2;
    return null;
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

fn pathWithCursor(alloc: std.mem.Allocator, base: []const u8, cursor: ?[]const u8) ![]const u8 {
    const c = cursor orelse return base;
    return std.fmt.allocPrint(alloc, "{s}{s}start_cursor={s}", .{ base, if (std.mem.indexOfScalar(u8, base, '?') != null) "&" else "?", try urlEncode(alloc, c) });
}

fn handleSearch(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    var body = newObj();
    if (getStr(args, "query")) |q| try body.put(alloc, "query", jstr(q));
    if (getStr(args, "kind")) |k| {
        if (!std.mem.eql(u8, k, "page") and !std.mem.eql(u8, k, "data_source")) return err("kind must be page or data_source");
        var f = newObj();
        try f.put(alloc, "property", jstr("object"));
        try f.put(alloc, "value", jstr(k));
        try body.put(alloc, "filter", objVal(f));
    }
    if (getStr(args, "cursor")) |c| try body.put(alloc, "start_cursor", jstr(c));
    try body.put(alloc, "page_size", .{ .integer = getInt(args, "limit", 20, 1, 100) });
    switch (try call(alloc, io, .POST, "/v1/search", try toJson(alloc, objVal(body)))) {
        .fail => |m| return err(m),
        .ok => |v| {
            var b = Buf{ .a = alloc };
            const results = farr(v, "results");
            if (results.len == 0) try b.add("no results\n");
            for (results) |p| try pageLine(&b, alloc, p, false);
            try cursorHint(&b, v);
            return finish(alloc, &b);
        },
    }
}

fn handlePage(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const id = switch (try idArg(alloc, args, "page_id")) {
        .id => |i| i,
        .bad => |r| return r,
    };
    switch (try call(alloc, io, .GET, try std.fmt.allocPrint(alloc, "/v1/pages/{s}", .{id}), null)) {
        .fail => |m| return err(m),
        .ok => |p| {
            var b = Buf{ .a = alloc };
            try b.print("id: {s}\ntitle: {s}\n", .{ fstr(p, "id") orelse "", try pageTitle(alloc, p) });
            if (fstr(p, "url")) |u| try b.print("url: {s}\n", .{u});
            if (field(p, "parent")) |par| if (fstr(par, "type")) |pt| {
                try b.print("parent: {s} {s}\n", .{ pt, fstr(par, pt) orelse "" });
            };
            if (fbool(p, "archived") or fbool(p, "in_trash")) try b.add("trashed: true\n");
            if (fstr(p, "last_edited_time")) |t| try b.print("last_edited: {s}\n", .{t});
            try flattenProps(&b, alloc, p, "\n");
            try b.addc('\n');
            return finish(alloc, &b);
        },
    }
}

fn handleBlocks(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const id = switch (try idArg(alloc, args, "block_id")) {
        .id => |i| i,
        .bad => |r| return r,
    };
    const depth: u32 = @intCast(getInt(args, "depth", 2, 0, 4));
    const path = try pathWithCursor(alloc, try std.fmt.allocPrint(alloc, "/v1/blocks/{s}/children?page_size=100", .{id}), getStr(args, "cursor"));
    switch (try call(alloc, io, .GET, path, null)) {
        .fail => |m| return err(m),
        .ok => |v| {
            var b = Buf{ .a = alloc };
            var ctx = BlockCtx{ .alloc = alloc, .io = io, .b = &b };
            const blocks = farr(v, "results");
            if (blocks.len == 0) try b.add("(empty)\n");
            try renderBlocks(&ctx, blocks, 0, depth);
            try cursorHint(&b, v);
            return finish(alloc, &b);
        },
    }
}

fn handleQuery(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const id = switch (try idArg(alloc, args, "data_source_id")) {
        .id => |i| i,
        .bad => |r| return r,
    };
    var body = newObj();
    if (getStr(args, "filter")) |f| {
        const fv = (try parseJsonArg(alloc, f, false)) orelse return err("filter must be a JSON object string");
        try body.put(alloc, "filter", fv);
    }
    if (getStr(args, "sorts")) |s| {
        const sv = (try parseJsonArg(alloc, s, true)) orelse return err("sorts must be a JSON array string");
        try body.put(alloc, "sorts", sv);
    }
    if (getStr(args, "cursor")) |c| try body.put(alloc, "start_cursor", jstr(c));
    try body.put(alloc, "page_size", .{ .integer = getInt(args, "limit", 25, 1, 100) });
    const path = try std.fmt.allocPrint(alloc, "/v1/data_sources/{s}/query", .{id});
    switch (try call(alloc, io, .POST, path, try toJson(alloc, objVal(body)))) {
        .fail => |m| return err(m),
        .ok => |v| {
            var b = Buf{ .a = alloc };
            const rows = farr(v, "results");
            if (rows.len == 0) try b.add("no rows\n");
            for (rows) |p| try pageLine(&b, alloc, p, true);
            try cursorHint(&b, v);
            return finish(alloc, &b);
        },
    }
}

fn handleDatabase(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const id = switch (try idArg(alloc, args, "id")) {
        .id => |i| i,
        .bad => |r| return r,
    };
    const is_ds = getBool(args, "data_source") orelse false;
    const path = try std.fmt.allocPrint(alloc, "/v1/{s}/{s}", .{ if (is_ds) "data_sources" else "databases", id });
    switch (try call(alloc, io, .GET, path, null)) {
        .fail => |m| return err(m),
        .ok => |v| {
            var b = Buf{ .a = alloc };
            try b.print("id: {s}\ntitle: {s}\n", .{ fstr(v, "id") orelse "", try richPlain(alloc, farr(v, "title")) });
            if (fstr(v, "url")) |u| try b.print("url: {s}\n", .{u});
            const desc = try richPlain(alloc, farr(v, "description"));
            if (desc.len > 0) try b.print("description: {s}\n", .{desc});
            for (farr(v, "data_sources")) |ds| {
                try b.print("data_source: {s} {s}\n", .{ fstr(ds, "id") orelse "", fstr(ds, "name") orelse "" });
            }
            if (field(v, "properties")) |props| if (props == .object) {
                try b.add("properties:\n");
                var it = props.object.iterator();
                while (it.next()) |e| {
                    const t = fstr(e.value_ptr.*, "type") orelse "?";
                    try b.print("  {s} ({s})", .{ e.key_ptr.*, t });
                    if (std.mem.eql(u8, t, "select") or std.mem.eql(u8, t, "multi_select") or std.mem.eql(u8, t, "status")) {
                        if (field(e.value_ptr.*, t)) |cfg| {
                            try b.add(": ");
                            for (farr(cfg, "options"), 0..) |o, i| {
                                if (i > 0) try b.add(", ");
                                try b.add(fstr(o, "name") orelse "");
                            }
                        }
                    }
                    try b.addc('\n');
                }
            };
            return finish(alloc, &b);
        },
    }
}

const PropsArg = union(enum) { none, ok: std.json.Value, bad: mcp.ToolResult };

fn propertiesArg(alloc: std.mem.Allocator, args: std.json.Value) !PropsArg {
    const s = getStr(args, "properties") orelse return .none;
    const v = (try parseJsonArg(alloc, s, false)) orelse return .{ .bad = err("properties must be a JSON object string") };
    return .{ .ok = v };
}

fn handleCreatePage(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    if (!writesAllowed()) return err(write_refused);
    const pid = switch (try idArg(alloc, args, "parent_id")) {
        .id => |i| i,
        .bad => |r| return r,
    };
    const ptype = getStr(args, "parent_type") orelse "page";
    const is_page = std.mem.eql(u8, ptype, "page");
    if (!is_page and !std.mem.eql(u8, ptype, "data_source")) return err("parent_type must be page or data_source");
    var body = newObj();
    var parent = newObj();
    try parent.put(alloc, if (is_page) "page_id" else "data_source_id", jstr(pid));
    try body.put(alloc, "parent", objVal(parent));
    switch (try propertiesArg(alloc, args)) {
        .bad => |r| return r,
        .ok => |v| try body.put(alloc, "properties", v),
        .none => {
            const title = getStr(args, "title") orelse return err("provide properties (JSON string) or title");
            if (!is_page) return err("data_source parent needs properties JSON (title property name varies)");
            var tp = newObj();
            try tp.put(alloc, "title", try richTextJson(alloc, title));
            var props = newObj();
            try props.put(alloc, "title", objVal(tp));
            try body.put(alloc, "properties", objVal(props));
        },
    }
    if (getStr(args, "content")) |c| {
        switch (try contentToBlocks(alloc, c)) {
            .bad => |m| return err(m),
            .ok => |arr| if (arr.items.len > 0) try body.put(alloc, "children", .{ .array = arr }),
        }
    }
    switch (try call(alloc, io, .POST, "/v1/pages", try toJson(alloc, objVal(body)))) {
        .fail => |m| return err(m),
        .ok => |p| return text(try std.fmt.allocPrint(alloc, "created page {s} {s}", .{ fstr(p, "id") orelse "", fstr(p, "url") orelse "" })),
    }
}

fn handleUpdatePage(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    if (!writesAllowed()) return err(write_refused);
    const id = switch (try idArg(alloc, args, "page_id")) {
        .id => |i| i,
        .bad => |r| return r,
    };
    var body = newObj();
    switch (try propertiesArg(alloc, args)) {
        .bad => |r| return r,
        .ok => |v| try body.put(alloc, "properties", v),
        .none => {},
    }
    if (getBool(args, "trash")) |t| try body.put(alloc, "in_trash", .{ .bool = t });
    if (body.count() == 0) return err("nothing to update: pass properties and/or trash");
    const path = try std.fmt.allocPrint(alloc, "/v1/pages/{s}", .{id});
    switch (try call(alloc, io, .PATCH, path, try toJson(alloc, objVal(body)))) {
        .fail => |m| return err(m),
        .ok => |p| return text(try std.fmt.allocPrint(alloc, "updated page {s}", .{fstr(p, "id") orelse id})),
    }
}

fn handleAppend(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    if (!writesAllowed()) return err(write_refused);
    const id = switch (try idArg(alloc, args, "block_id")) {
        .id => |i| i,
        .bad => |r| return r,
    };
    const content = getStr(args, "content") orelse return err("missing required argument: content");
    const arr = switch (try contentToBlocks(alloc, content)) {
        .bad => |m| return err(m),
        .ok => |a| a,
    };
    if (arr.items.len == 0) return err("content is empty");
    var body = newObj();
    try body.put(alloc, "children", .{ .array = arr });
    const path = try std.fmt.allocPrint(alloc, "/v1/blocks/{s}/children", .{id});
    switch (try call(alloc, io, .PATCH, path, try toJson(alloc, objVal(body)))) {
        .fail => |m| return err(m),
        .ok => return text(try std.fmt.allocPrint(alloc, "appended {d} blocks", .{arr.items.len})),
    }
}

fn handleComments(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    if (getStr(args, "text")) |t| {
        if (!writesAllowed()) return err(write_refused);
        var body = newObj();
        if (getStr(args, "discussion_id")) |d| {
            if (!validId(d)) return err("invalid discussion_id");
            try body.put(alloc, "discussion_id", jstr(d));
        } else {
            const pid = switch (try idArg(alloc, args, "page_id")) {
                .id => |i| i,
                .bad => |r| return r,
            };
            var par = newObj();
            try par.put(alloc, "page_id", jstr(pid));
            try body.put(alloc, "parent", objVal(par));
        }
        try body.put(alloc, "rich_text", try richTextJson(alloc, t));
        switch (try call(alloc, io, .POST, "/v1/comments", try toJson(alloc, objVal(body)))) {
            .fail => |m| return err(m),
            .ok => |c| return text(try std.fmt.allocPrint(alloc, "created comment {s}", .{fstr(c, "id") orelse ""})),
        }
    }
    const id = switch (try idArg(alloc, args, "block_id")) {
        .id => |i| i,
        .bad => |r| return r,
    };
    const path = try pathWithCursor(alloc, try std.fmt.allocPrint(alloc, "/v1/comments?block_id={s}&page_size=50", .{id}), getStr(args, "cursor"));
    switch (try call(alloc, io, .GET, path, null)) {
        .fail => |m| return err(m),
        .ok => |v| {
            var b = Buf{ .a = alloc };
            const rs = farr(v, "results");
            if (rs.len == 0) try b.add("no comments\n");
            for (rs) |c| {
                const by = if (field(c, "created_by")) |u| (fstr(u, "id") orelse "") else "";
                try b.print("[{s}] {s} (discussion {s}): ", .{ fstr(c, "created_time") orelse "", by, fstr(c, "discussion_id") orelse "" });
                try richText(&b, farr(c, "rich_text"));
                try b.addc('\n');
            }
            try cursorHint(&b, v);
            return finish(alloc, &b);
        },
    }
}

fn handleUsers(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const path = try pathWithCursor(alloc, "/v1/users?page_size=100", getStr(args, "cursor"));
    switch (try call(alloc, io, .GET, path, null)) {
        .fail => |m| return err(m),
        .ok => |v| {
            var b = Buf{ .a = alloc };
            for (farr(v, "results")) |u| {
                try b.print("{s} | {s} | {s}", .{ fstr(u, "id") orelse "", fstr(u, "type") orelse "", fstr(u, "name") orelse "" });
                if (field(u, "person")) |p| if (fstr(p, "email")) |e| try b.print(" | {s}", .{e});
                try b.addc('\n');
            }
            try cursorHint(&b, v);
            return finish(alloc, &b);
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const ID1 = "0123456789abcdef0123456789abcdef";

const Mock = struct {
    var last_method: std.http.Method = .GET;
    var last_url: []const u8 = "";
    var last_auth: []const u8 = "";
    var last_version: []const u8 = "";
    var last_body: ?[]const u8 = null;
    var calls: u32 = 0;
    var status: u16 = 200;
    var response: []const u8 = "{}";

    fn freeLast() void {
        const a = std.testing.allocator;
        if (last_url.len > 0) a.free(last_url);
        if (last_auth.len > 0) a.free(last_auth);
        if (last_version.len > 0) a.free(last_version);
        if (last_body) |b| a.free(b);
        last_url = "";
        last_auth = "";
        last_version = "";
        last_body = null;
    }
    fn fetch(_: std.mem.Allocator, _: std.Io, req: FetchRequest) anyerror!HttpResp {
        const a = std.testing.allocator;
        freeLast();
        last_method = req.method;
        last_url = try a.dupe(u8, req.url);
        last_auth = try a.dupe(u8, req.authorization);
        last_version = try a.dupe(u8, req.notion_version);
        last_body = if (req.body) |b| try a.dupe(u8, b) else null;
        calls += 1;
        return .{ .status = status, .body = response };
    }
    fn reset(env_pairs: []const [2][]const u8, resp: []const u8) void {
        freeLast();
        calls = 0;
        status = 200;
        response = resp;
        fetch_impl = fetch;
        test_env = env_pairs;
    }
};

const env_rw = [_][2][]const u8{ .{ "NOTION_TOKEN", "ntn_secret" }, .{ "ZMCP_NOTION_ALLOW_WRITE", "1" } };
const env_ro = [_][2][]const u8{.{ "NOTION_TOKEN", "ntn_secret" }};

fn parseArgs(alloc: std.mem.Allocator, s: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, alloc, s, .{});
}

test "tool table: valid schemas and compact size" {
    var total: usize = 0;
    for (tool_table) |t| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), t.input_schema_json, .{});
        try std.testing.expect(v == .object);
        total += t.description.len + t.input_schema_json.len;
    }
    try std.testing.expectEqual(@as(usize, 10), tool_table.len);
    try std.testing.expect(total < 6000);
}

test "search request building and result formatting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    Mock.reset(&env_ro,
        \\{"results":[{"object":"page","id":"p1","url":"https://n/p1","properties":{"Name":{"type":"title","title":[{"plain_text":"Hello"}]}}},{"object":"data_source","id":"d1","title":[{"plain_text":"Tasks"}]}],"has_more":true,"next_cursor":"CUR"}
    );
    defer Mock.reset(&.{}, "{}");
    const r = try handleSearch(a, undefined, try parseArgs(a, "{\"query\":\"hi\",\"kind\":\"page\",\"cursor\":\"c1\",\"limit\":500}"));
    try std.testing.expect(!r.is_error);
    try std.testing.expectEqualStrings("https://api.notion.com/v1/search", Mock.last_url);
    try std.testing.expectEqual(std.http.Method.POST, Mock.last_method);
    try std.testing.expectEqualStrings("Bearer ntn_secret", Mock.last_auth);
    try std.testing.expectEqualStrings("2025-09-03", Mock.last_version);
    try std.testing.expectEqualStrings(
        "{\"query\":\"hi\",\"filter\":{\"property\":\"object\",\"value\":\"page\"},\"start_cursor\":\"c1\",\"page_size\":100}",
        Mock.last_body.?,
    );
    try std.testing.expectEqualStrings(
        "[page] p1 | Hello | https://n/p1\n[data_source] d1 | Tasks\nnext_cursor: CUR\n",
        r.text,
    );
}

test "missing credentials gives a clear error naming the env var" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    Mock.reset(&.{}, "{}");
    const r = try handleUsers(a, undefined, try parseArgs(a, "{}"));
    try std.testing.expect(r.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "NOTION_TOKEN") != null);
    try std.testing.expectEqual(@as(u32, 0), Mock.calls);
}

test "OPENAPI_MCP_HEADERS fallback with version override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = [_][2][]const u8{.{ "OPENAPI_MCP_HEADERS", "{\"Authorization\":\"Bearer abc\",\"Notion-Version\":\"2022-06-28\"}" }};
    Mock.reset(&e, "{\"results\":[]}");
    defer Mock.reset(&.{}, "{}");
    const r = try handleUsers(a, undefined, try parseArgs(a, "{\"cursor\":\"a b\"}"));
    try std.testing.expect(!r.is_error);
    try std.testing.expectEqualStrings("Bearer abc", Mock.last_auth);
    try std.testing.expectEqualStrings("2022-06-28", Mock.last_version);
    try std.testing.expectEqualStrings("https://api.notion.com/v1/users?page_size=100&start_cursor=a%20b", Mock.last_url);
}

test "write gating refuses without env and makes no request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    Mock.reset(&env_ro, "{}");
    defer Mock.reset(&.{}, "{}");
    const cases = [_]struct { f: *const fn (std.mem.Allocator, std.Io, std.json.Value) anyerror!mcp.ToolResult, args: []const u8 }{
        .{ .f = handleCreatePage, .args = "{\"parent_id\":\"" ++ ID1 ++ "\",\"title\":\"x\"}" },
        .{ .f = handleUpdatePage, .args = "{\"page_id\":\"" ++ ID1 ++ "\",\"trash\":true}" },
        .{ .f = handleAppend, .args = "{\"block_id\":\"" ++ ID1 ++ "\",\"content\":\"x\"}" },
        .{ .f = handleComments, .args = "{\"page_id\":\"" ++ ID1 ++ "\",\"text\":\"x\"}" },
    };
    for (cases) |c| {
        const r = try c.f(a, undefined, try parseArgs(a, c.args));
        try std.testing.expect(r.is_error);
        try std.testing.expect(std.mem.indexOf(u8, r.text, "ZMCP_NOTION_ALLOW_WRITE") != null);
    }
    try std.testing.expectEqual(@as(u32, 0), Mock.calls);
}

test "create page body with title and content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    Mock.reset(&env_rw, "{\"id\":\"newid\",\"url\":\"https://n/new\"}");
    defer Mock.reset(&.{}, "{}");
    const r = try handleCreatePage(a, undefined, try parseArgs(a, "{\"parent_id\":\"" ++ ID1 ++ "\",\"title\":\"T\",\"content\":\"# H\\n- b\\n\\n---\"}"));
    try std.testing.expect(!r.is_error);
    try std.testing.expectEqualStrings("created page newid https://n/new", r.text);
    try std.testing.expectEqualStrings("https://api.notion.com/v1/pages", Mock.last_url);
    try std.testing.expectEqualStrings(
        "{\"parent\":{\"page_id\":\"" ++ ID1 ++ "\"},\"properties\":{\"title\":{\"title\":[{\"type\":\"text\",\"text\":{\"content\":\"T\"}}]}},\"children\":[" ++
            "{\"object\":\"block\",\"type\":\"heading_1\",\"heading_1\":{\"rich_text\":[{\"type\":\"text\",\"text\":{\"content\":\"H\"}}]}}," ++
            "{\"object\":\"block\",\"type\":\"bulleted_list_item\",\"bulleted_list_item\":{\"rich_text\":[{\"type\":\"text\",\"text\":{\"content\":\"b\"}}]}}," ++
            "{\"object\":\"block\",\"type\":\"divider\",\"divider\":{}}]}",
        Mock.last_body.?,
    );
}

test "create page under data source needs properties; passes them through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    Mock.reset(&env_rw, "{\"id\":\"x\"}");
    defer Mock.reset(&.{}, "{}");
    var r = try handleCreatePage(a, undefined, try parseArgs(a, "{\"parent_id\":\"" ++ ID1 ++ "\",\"parent_type\":\"data_source\",\"title\":\"T\"}"));
    try std.testing.expect(r.is_error);
    r = try handleCreatePage(a, undefined, try parseArgs(a, "{\"parent_id\":\"" ++ ID1 ++ "\",\"parent_type\":\"data_source\",\"properties\":\"{\\\"Name\\\":{\\\"title\\\":[]}}\"}"));
    try std.testing.expect(!r.is_error);
    try std.testing.expectEqualStrings("{\"parent\":{\"data_source_id\":\"" ++ ID1 ++ "\"},\"properties\":{\"Name\":{\"title\":[]}}}", Mock.last_body.?);
}

test "update page validates properties JSON and builds PATCH" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    Mock.reset(&env_rw, "{\"id\":\"pp\"}");
    defer Mock.reset(&.{}, "{}");
    var r = try handleUpdatePage(a, undefined, try parseArgs(a, "{\"page_id\":\"" ++ ID1 ++ "\",\"properties\":\"[1]\"}"));
    try std.testing.expect(r.is_error);
    r = try handleUpdatePage(a, undefined, try parseArgs(a, "{\"page_id\":\"" ++ ID1 ++ "\"}"));
    try std.testing.expect(r.is_error);
    try std.testing.expectEqual(@as(u32, 0), Mock.calls);
    r = try handleUpdatePage(a, undefined, try parseArgs(a, "{\"page_id\":\"" ++ ID1 ++ "\",\"properties\":\"{\\\"A\\\":{\\\"checkbox\\\":true}}\",\"trash\":false}"));
    try std.testing.expect(!r.is_error);
    try std.testing.expectEqual(std.http.Method.PATCH, Mock.last_method);
    try std.testing.expectEqualStrings("{\"properties\":{\"A\":{\"checkbox\":true}},\"in_trash\":false}", Mock.last_body.?);
}

test "append blocks: url, body, block limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    Mock.reset(&env_rw, "{}");
    defer Mock.reset(&.{}, "{}");
    var r = try handleAppend(a, undefined, try parseArgs(a, "{\"block_id\":\"" ++ ID1 ++ "\",\"content\":\"1. one\\n- [x] done\\n```zig\\nconst a = 1;\\n```\"}"));
    try std.testing.expectEqualStrings("appended 3 blocks", r.text);
    try std.testing.expectEqualStrings("https://api.notion.com/v1/blocks/" ++ ID1 ++ "/children", Mock.last_url);
    try std.testing.expect(std.mem.indexOf(u8, Mock.last_body.?, "\"numbered_list_item\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, Mock.last_body.?, "\"checked\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, Mock.last_body.?, "\"language\":\"zig\"") != null);
    var many: Buf = .{ .a = a };
    for (0..101) |_| try many.add("x\\n");
    const args = try std.fmt.allocPrint(a, "{{\"block_id\":\"{s}\",\"content\":\"{s}\"}}", .{ ID1, many.l.items });
    r = try handleAppend(a, undefined, try parseArgs(a, args));
    try std.testing.expect(r.is_error);
}

test "query validates filter/sorts and builds body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    Mock.reset(&env_ro,
        \\{"results":[{"object":"page","id":"r1","properties":{"Name":{"type":"title","title":[{"plain_text":"Row"}]},"Status":{"type":"status","status":{"name":"Done"}},"Empty":{"type":"rich_text","rich_text":[]}}}],"has_more":false}
    );
    defer Mock.reset(&.{}, "{}");
    var r = try handleQuery(a, undefined, try parseArgs(a, "{\"data_source_id\":\"" ++ ID1 ++ "\",\"filter\":\"[1]\"}"));
    try std.testing.expect(r.is_error);
    r = try handleQuery(a, undefined, try parseArgs(a, "{\"data_source_id\":\"" ++ ID1 ++ "\",\"sorts\":\"{bad\"}"));
    try std.testing.expect(r.is_error);
    r = try handleQuery(a, undefined, try parseArgs(a, "{\"data_source_id\":\"../x\"}"));
    try std.testing.expect(r.is_error);
    try std.testing.expectEqual(@as(u32, 0), Mock.calls);
    r = try handleQuery(a, undefined, try parseArgs(a, "{\"data_source_id\":\"" ++ ID1 ++ "\",\"filter\":\"{\\\"property\\\":\\\"Status\\\",\\\"status\\\":{\\\"equals\\\":\\\"Done\\\"}}\",\"sorts\":\"[{\\\"timestamp\\\":\\\"last_edited_time\\\",\\\"direction\\\":\\\"descending\\\"}]\",\"limit\":5}"));
    try std.testing.expect(!r.is_error);
    try std.testing.expectEqualStrings("https://api.notion.com/v1/data_sources/" ++ ID1 ++ "/query", Mock.last_url);
    try std.testing.expectEqualStrings(
        "{\"filter\":{\"property\":\"Status\",\"status\":{\"equals\":\"Done\"}},\"sorts\":[{\"timestamp\":\"last_edited_time\",\"direction\":\"descending\"}],\"page_size\":5}",
        Mock.last_body.?,
    );
    try std.testing.expectEqualStrings("[page] r1 | Row | Status: Done\n", r.text);
}

test "property flattening across types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\{"n":{"type":"number","number":4.5},"s":{"type":"select","select":{"name":"A"}},
        \\"m":{"type":"multi_select","multi_select":[{"name":"x"},{"name":"y"}]},
        \\"d":{"type":"date","date":{"start":"2026-01-01","end":"2026-01-02"}},
        \\"c":{"type":"checkbox","checkbox":true},"u":{"type":"url","url":"https://e.com"},
        \\"p":{"type":"people","people":[{"id":"u1","name":"Ann"},{"id":"u2"}]},
        \\"r":{"type":"relation","relation":[{"id":"r1"}]},
        \\"f":{"type":"formula","formula":{"type":"string","string":"fx"}},
        \\"ro":{"type":"rollup","rollup":{"type":"number","number":7}},
        \\"ra":{"type":"rollup","rollup":{"type":"array","array":[{"type":"number","number":1},{"type":"number","number":2}]}},
        \\"i":{"type":"unique_id","unique_id":{"prefix":"T","number":12}},
        \\"fl":{"type":"files","files":[{"name":"a.pdf"}]},
        \\"nul":{"type":"select","select":null},
        \\"rt":{"type":"rich_text","rich_text":[{"plain_text":"bold","annotations":{"bold":true}}]}}
    ;
    const props = try parseArgs(a, src);
    const want = [_][2][]const u8{
        .{ "n", "4.5" },  .{ "s", "A" },                    .{ "m", "x, y" },   .{ "d", "2026-01-01 -> 2026-01-02" },
        .{ "c", "true" }, .{ "u", "https://e.com" },        .{ "p", "Ann, u2" }, .{ "r", "r1" },
        .{ "f", "fx" },   .{ "ro", "7" },                   .{ "ra", "1, 2" },  .{ "i", "T-12" },
        .{ "fl", "a.pdf" }, .{ "nul", "" },                 .{ "rt", "**bold**" },
    };
    for (want) |w| try std.testing.expectEqualStrings(w[1], try propText(a, props.object.get(w[0]).?));
}

test "block to text on fixtures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\[{"id":"b1","type":"heading_2","has_children":false,"heading_2":{"rich_text":[{"plain_text":"Title"}]}},
        \\{"id":"b2","type":"paragraph","has_children":false,"paragraph":{"rich_text":[{"plain_text":"see "},{"plain_text":"link","href":"https://x.y"},{"plain_text":"code","annotations":{"code":true}}]}},
        \\{"id":"b3","type":"to_do","has_children":false,"to_do":{"checked":true,"rich_text":[{"plain_text":"done"}]}},
        \\{"id":"b4","type":"code","has_children":false,"code":{"language":"zig","rich_text":[{"plain_text":"x"}]}},
        \\{"id":"b5","type":"divider","has_children":false,"divider":{}},
        \\{"id":"b6","type":"child_page","has_children":false,"child_page":{"title":"Sub"}},
        \\{"id":"b7","type":"image","has_children":false,"image":{"type":"file","file":{"url":"https://signed/long"},"caption":[{"plain_text":"cap"}]}},
        \\{"id":"b8","type":"table_row","has_children":false,"table_row":{"cells":[[{"plain_text":"a"}],[{"plain_text":"b"}]]}},
        \\{"id":"b9","type":"toggle","has_children":true,"toggle":{"rich_text":[{"plain_text":"more"}]}},
        \\{"id":"b10","type":"synthetic_thing","has_children":false,"synthetic_thing":{}}]
    ;
    const blocks = try parseArgs(a, src);
    var b = Buf{ .a = a };
    var ctx = BlockCtx{ .alloc = a, .io = undefined, .b = &b };
    try renderBlocks(&ctx, blocks.array.items, 0, 0);
    try std.testing.expectEqualStrings(
        "## Title\n" ++
            "see [link](https://x.y)`code`\n" ++
            "- [x] done\n" ++
            "```zig\nx\n```\n" ++
            "---\n" ++
            "[page: Sub] b6\n" ++
            "[image] cap\n" ++
            "| a | b |\n" ++
            "> more (+children id=b9)\n" ++
            "[synthetic_thing]\n",
        b.l.items,
    );
}

test "notion_blocks expands nested children within depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    Mock.reset(&env_ro,
        \\{"results":[{"id":"aaaa","type":"toggle","has_children":true,"toggle":{"rich_text":[{"plain_text":"T"}]}}],"has_more":true,"next_cursor":"NX"}
    );
    defer Mock.reset(&.{}, "{}");
    var r = try handleBlocks(a, undefined, try parseArgs(a, "{\"block_id\":\"" ++ ID1 ++ "\",\"depth\":0,\"cursor\":\"k\"}"));
    try std.testing.expectEqual(@as(u32, 1), Mock.calls);
    try std.testing.expectEqualStrings("https://api.notion.com/v1/blocks/" ++ ID1 ++ "/children?page_size=100&start_cursor=k", Mock.last_url);
    try std.testing.expectEqualStrings("> T (+children id=aaaa)\nnext_cursor: NX\n", r.text);
    Mock.calls = 0;
    r = try handleBlocks(a, undefined, try parseArgs(a, "{\"block_id\":\"" ++ ID1 ++ "\",\"depth\":1}"));
    try std.testing.expectEqual(@as(u32, 2), Mock.calls);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "> T\n  > T (+children id=aaaa)") != null);
}

test "page retrieval formatting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    Mock.reset(&env_ro,
        \\{"id":"pg","url":"https://n/pg","parent":{"type":"page_id","page_id":"par"},"properties":{"title":{"type":"title","title":[{"plain_text":"My Page"}]},"Tag":{"type":"select","select":{"name":"t"}}}}
    );
    defer Mock.reset(&.{}, "{}");
    const r = try handlePage(a, undefined, try parseArgs(a, "{\"page_id\":\"" ++ ID1 ++ "\"}"));
    try std.testing.expectEqualStrings("id: pg\ntitle: My Page\nurl: https://n/pg\nparent: page_id par\nTag: t\n", r.text);
    try std.testing.expectEqualStrings("https://api.notion.com/v1/pages/" ++ ID1, Mock.last_url);
}

test "comments list and create" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    Mock.reset(&env_rw,
        \\{"results":[{"id":"c1","discussion_id":"d1","created_time":"T0","created_by":{"id":"u1"},"rich_text":[{"plain_text":"hey"}]}]}
    );
    defer Mock.reset(&.{}, "{}");
    var r = try handleComments(a, undefined, try parseArgs(a, "{\"block_id\":\"" ++ ID1 ++ "\"}"));
    try std.testing.expectEqualStrings("[T0] u1 (discussion d1): hey\n", r.text);
    try std.testing.expectEqualStrings("https://api.notion.com/v1/comments?block_id=" ++ ID1 ++ "&page_size=50", Mock.last_url);
    Mock.response = "{\"id\":\"c2\"}";
    r = try handleComments(a, undefined, try parseArgs(a, "{\"page_id\":\"" ++ ID1 ++ "\",\"text\":\"hi\"}"));
    try std.testing.expectEqualStrings("created comment c2", r.text);
    try std.testing.expectEqualStrings(
        "{\"parent\":{\"page_id\":\"" ++ ID1 ++ "\"},\"rich_text\":[{\"type\":\"text\",\"text\":{\"content\":\"hi\"}}]}",
        Mock.last_body.?,
    );
}

test "database and data source retrieval" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    Mock.reset(&env_ro,
        \\{"id":"db","title":[{"plain_text":"Tasks"}],"data_sources":[{"id":"ds1","name":"Main"}],"properties":{"Status":{"type":"status","status":{"options":[{"name":"Todo"},{"name":"Done"}]}},"Name":{"type":"title","title":{}}}}
    );
    defer Mock.reset(&.{}, "{}");
    var r = try handleDatabase(a, undefined, try parseArgs(a, "{\"id\":\"" ++ ID1 ++ "\"}"));
    try std.testing.expectEqualStrings("https://api.notion.com/v1/databases/" ++ ID1, Mock.last_url);
    try std.testing.expectEqualStrings(
        "id: db\ntitle: Tasks\ndata_source: ds1 Main\nproperties:\n  Status (status): Todo, Done\n  Name (title)\n",
        r.text,
    );
    r = try handleDatabase(a, undefined, try parseArgs(a, "{\"id\":\"" ++ ID1 ++ "\",\"data_source\":true}"));
    try std.testing.expectEqualStrings("https://api.notion.com/v1/data_sources/" ++ ID1, Mock.last_url);
}

test "error mapping never leaks the token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    Mock.reset(&env_ro, "{\"object\":\"error\",\"message\":\"Could not find page\"}");
    defer Mock.reset(&.{}, "{}");
    const codes = [_]struct { s: u16, needle: []const u8 }{
        .{ .s = 401, .needle = "unauthorized" },
        .{ .s = 403, .needle = "forbidden" },
        .{ .s = 404, .needle = "not shared" },
        .{ .s = 429, .needle = "rate limited" },
        .{ .s = 400, .needle = "Could not find page" },
        .{ .s = 502, .needle = "server error" },
    };
    for (codes) |c| {
        Mock.status = c.s;
        const r = try handleUsers(a, undefined, try parseArgs(a, "{}"));
        try std.testing.expect(r.is_error);
        try std.testing.expect(std.mem.indexOf(u8, r.text, c.needle) != null);
        try std.testing.expect(std.mem.indexOf(u8, r.text, "ntn_secret") == null);
    }
}

test "output is capped with a truncation note" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b = Buf{ .a = a };
    for (0..MAX_OUT / 4) |_| try b.add("h\xc3\xa9\xc3\xa9 ");
    const r = try finish(a, &b);
    try std.testing.expect(r.text.len < MAX_OUT + 200);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "[truncated") != null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(r.text));
}

test "id validation rejects path tricks" {
    try std.testing.expect(validId(ID1));
    try std.testing.expect(validId("01234567-89ab-cdef-0123-456789abcdef"));
    try std.testing.expect(!validId("../users"));
    try std.testing.expect(!validId(ID1 ++ "/x"));
}
