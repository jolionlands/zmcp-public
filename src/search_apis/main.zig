//! zmcp-websearch-apis - one binary, three hosted search/scrape providers
//! (Exa, Tavily, Firecrawl). Ports of exa-labs/exa-mcp-server,
//! tavily-ai/tavily-mcp and firecrawl/firecrawl-mcp-server, calling the
//! providers' REST APIs directly. A provider's tools are only listed when its
//! key env var is set (EXA_API_KEY, TAVILY_API_KEY, FIRECRAWL_API_KEY).
//! FIRECRAWL_API_URL optionally points at a self-hosted Firecrawl.

const std = @import("std");
const mcp = @import("mcp");

const MAX_OUTPUT: usize = 64 * 1024;
const MAX_RESPONSE: usize = 8 * 1024 * 1024;
const UA_PRODUCT = "zmcp-search-apis/0.1.0";

const Provider = enum {
    exa,
    tavily,
    firecrawl,

    fn envName(p: Provider) []const u8 {
        return switch (p) {
            .exa => "EXA_API_KEY",
            .tavily => "TAVILY_API_KEY",
            .firecrawl => "FIRECRAWL_API_KEY",
        };
    }
    fn label(p: Provider) []const u8 {
        return switch (p) {
            .exa => "Exa",
            .tavily => "Tavily",
            .firecrawl => "Firecrawl",
        };
    }
};

// ---------------------------------------------------------------- globals

var g_environ: ?*const std.process.Environ.Map = null;
/// Test seam: when set, consulted instead of the process environment.
var g_env_override: ?*const fn (name: []const u8) ?[]const u8 = null;
/// Test seam: swappable HTTP transport.
var g_transport: *const fn (std.mem.Allocator, std.Io, Request) anyerror!Response = realTransport;

fn getEnv(name: []const u8) ?[]const u8 {
    if (g_env_override) |f| return f(name);
    const m = g_environ orelse return null;
    const v = m.get(name) orelse return null;
    if (v.len == 0) return null;
    return v;
}

pub fn main(init: std.process.Init) !void {
    g_environ = init.environ_map;
    var list: std.ArrayList(mcp.ToolDef) = .empty;
    defer list.deinit(init.gpa);
    try collectTools(init.gpa, &list);
    if (list.items.len == 0) {
        std.debug.print("zmcp-websearch-apis: no provider keys set (EXA_API_KEY, TAVILY_API_KEY, FIRECRAWL_API_KEY); no tools registered\n", .{});
    }
    try mcp.run(init.gpa, init.io, .{ .name = "zmcp-websearch-apis", .version = "0.1.0" }, list.items);
}

fn collectTools(alloc: std.mem.Allocator, list: *std.ArrayList(mcp.ToolDef)) !void {
    if (getEnv("EXA_API_KEY") != null) try list.appendSlice(alloc, &exa_tools);
    if (getEnv("TAVILY_API_KEY") != null) try list.appendSlice(alloc, &tavily_tools);
    if (getEnv("FIRECRAWL_API_KEY") != null) try list.appendSlice(alloc, &firecrawl_tools);
}

// ---------------------------------------------------------------- tools

const exa_tools = [_]mcp.ToolDef{
    .{
        .name = "exa_search",
        .description = "Exa web search. Returns title, url, snippet per result.",
        .input_schema_json =
        \\{"type":"object","properties":{"query":{"type":"string"},"num_results":{"type":"integer","description":"1-10, default 5"},"include_domains":{"type":"array","items":{"type":"string"}},"max_chars":{"type":"integer","description":"snippet cap, default 800"}},"required":["query"]}
        ,
        .handler = handleExaSearch,
        .read_only = true,
    },
    .{
        .name = "exa_contents",
        .description = "Exa: fetch page text for URLs.",
        .input_schema_json =
        \\{"type":"object","properties":{"urls":{"type":"array","items":{"type":"string"}},"max_chars":{"type":"integer","description":"per page, default 5000"}},"required":["urls"]}
        ,
        .handler = handleExaContents,
        .read_only = true,
    },
};

const tavily_tools = [_]mcp.ToolDef{
    .{
        .name = "tavily_search",
        .description = "Tavily web search. Returns title, url, snippet per result.",
        .input_schema_json =
        \\{"type":"object","properties":{"query":{"type":"string"},"max_results":{"type":"integer","description":"1-10, default 5"},"search_depth":{"type":"string","enum":["basic","advanced"]},"topic":{"type":"string","enum":["general","news"]},"time_range":{"type":"string","enum":["day","week","month","year"]},"include_domains":{"type":"array","items":{"type":"string"}},"max_chars":{"type":"integer","description":"snippet cap, default 800"}},"required":["query"]}
        ,
        .handler = handleTavilySearch,
        .read_only = true,
    },
    .{
        .name = "tavily_extract",
        .description = "Tavily: extract page content for URLs.",
        .input_schema_json =
        \\{"type":"object","properties":{"urls":{"type":"array","items":{"type":"string"}},"extract_depth":{"type":"string","enum":["basic","advanced"]},"max_chars":{"type":"integer","description":"per page, default 5000"}},"required":["urls"]}
        ,
        .handler = handleTavilyExtract,
        .read_only = true,
    },
};

const firecrawl_tools = [_]mcp.ToolDef{
    .{
        .name = "firecrawl_scrape",
        .description = "Firecrawl: scrape one URL to markdown.",
        .input_schema_json =
        \\{"type":"object","properties":{"url":{"type":"string"},"only_main_content":{"type":"boolean","description":"default true"},"max_chars":{"type":"integer","description":"default 8000"}},"required":["url"]}
        ,
        .handler = handleFirecrawlScrape,
        .read_only = true,
    },
    .{
        .name = "firecrawl_search",
        .description = "Firecrawl web search. Returns title, url, snippet per result.",
        .input_schema_json =
        \\{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer","description":"1-10, default 5"}},"required":["query"]}
        ,
        .handler = handleFirecrawlSearch,
        .read_only = true,
    },
    .{
        .name = "firecrawl_map",
        .description = "Firecrawl: list URLs found on a site.",
        .input_schema_json =
        \\{"type":"object","properties":{"url":{"type":"string"},"search":{"type":"string","description":"rank/filter URLs by term"},"limit":{"type":"integer","description":"default 50, max 500"}},"required":["url"]}
        ,
        .handler = handleFirecrawlMap,
        .read_only = true,
    },
    .{
        .name = "firecrawl_crawl",
        .description = "Firecrawl: start an async crawl; returns a job id for firecrawl_crawl_status.",
        .input_schema_json =
        \\{"type":"object","properties":{"url":{"type":"string"},"limit":{"type":"integer","description":"max pages, default 10, max 100"},"max_depth":{"type":"integer","description":"default 2"}},"required":["url"]}
        ,
        .handler = handleFirecrawlCrawl,
    },
    .{
        .name = "firecrawl_crawl_status",
        .description = "Firecrawl: status and compact results of a crawl job.",
        .input_schema_json =
        \\{"type":"object","properties":{"id":{"type":"string"},"max_chars":{"type":"integer","description":"per page, default 500"}},"required":["id"]}
        ,
        .handler = handleFirecrawlCrawlStatus,
        .read_only = true,
    },
};

// ---------------------------------------------------------------- transport

pub const Request = struct {
    method: std.http.Method,
    url: []const u8,
    auth_name: []const u8,
    auth_value: []const u8,
    body: ?[]const u8 = null,
};

pub const Response = struct {
    status: u16,
    body: []const u8,
};

fn realTransport(alloc: std.mem.Allocator, io: std.Io, req: Request) anyerror!Response {
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();
    const ua_owned = try mcp.userAgent(alloc, io, UA_PRODUCT);
    defer alloc.free(ua_owned);

    var resp_buf: std.Io.Writer.Allocating = .init(alloc);
    defer resp_buf.deinit();
    var decompress_buf: [128 * 1024]u8 = undefined;

    var headers: [4]std.http.Header = undefined;
    var n: usize = 0;
    headers[n] = .{ .name = "User-Agent", .value = ua_owned };
    n += 1;
    headers[n] = .{ .name = "Accept", .value = "application/json" };
    n += 1;
    headers[n] = .{ .name = req.auth_name, .value = req.auth_value };
    n += 1;
    if (req.body != null) {
        headers[n] = .{ .name = "Content-Type", .value = "application/json" };
        n += 1;
    }

    const res = try client.fetch(.{
        .location = .{ .url = req.url },
        .response_writer = &resp_buf.writer,
        .method = req.method,
        .payload = req.body,
        .extra_headers = headers[0..n],
        .decompress_buffer = &decompress_buf,
    });
    if (resp_buf.written().len > MAX_RESPONSE) return error.ResponseTooLarge;
    return .{ .status = @intFromEnum(res.status), .body = try alloc.dupe(u8, resp_buf.written()) };
}

// ---------------------------------------------------------------- helpers

fn errResult(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) mcp.ToolResult {
    const t = std.fmt.allocPrint(alloc, fmt, args) catch "error";
    return .{ .text = t, .is_error = true };
}

fn getStr(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return if (v == .string and v.string.len > 0) v.string else null;
}

fn getInt(args: std.json.Value, key: []const u8, default: i64, lo: i64, hi: i64) i64 {
    var out = default;
    if (args == .object) {
        if (args.object.get(key)) |v| switch (v) {
            .integer => |i| out = i,
            .float => |f| out = @intFromFloat(f),
            else => {},
        };
    }
    return std.math.clamp(out, lo, hi);
}

fn getBool(args: std.json.Value, key: []const u8, default: bool) bool {
    if (args != .object) return default;
    const v = args.object.get(key) orelse return default;
    return if (v == .bool) v.bool else default;
}

fn getStrArray(args: std.json.Value, key: []const u8) ?[]const std.json.Value {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    if (v != .array or v.array.items.len == 0) return null;
    for (v.array.items) |it| if (it != .string) return null;
    return v.array.items;
}

const max_urls = 20;

/// Validate a urls array: all strings, http(s), max 20.
fn urlsArg(args: std.json.Value) ?[]const std.json.Value {
    const items = getStrArray(args, "urls") orelse return null;
    if (items.len > max_urls) return null;
    for (items) |it| {
        if (!isHttpUrl(it.string)) return null;
    }
    return items;
}

fn isHttpUrl(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "https://") or std.mem.startsWith(u8, s, "http://");
}

/// Missing-credential result naming the env var.
fn missingKey(alloc: std.mem.Allocator, p: Provider) mcp.ToolResult {
    return errResult(alloc, "{s} is not set; export it to use {s} tools", .{ p.envName(), p.label() });
}

const Jw = struct {
    sw: std.Io.Writer.Allocating,
    js: std.json.Stringify,

    fn init(alloc: std.mem.Allocator) *Jw {
        const self = alloc.create(Jw) catch @panic("oom");
        self.sw = .init(alloc);
        self.js = .{ .writer = &self.sw.writer };
        return self;
    }
    fn field(self: *Jw, name: []const u8) !void {
        try self.js.objectField(name);
    }
    fn done(self: *Jw) []const u8 {
        return self.sw.written();
    }
};

fn writeStrArray(js: *std.json.Stringify, items: []const std.json.Value) !void {
    try js.beginArray();
    for (items) |it| try js.write(it.string);
    try js.endArray();
}

/// Truncate to at most `max` bytes on a UTF-8 boundary, appending an ellipsis.
fn clip(alloc: std.mem.Allocator, s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return std.fmt.allocPrint(alloc, "{s}...", .{s[0..end]}) catch s[0..end];
}

/// Collapse runs of whitespace to single spaces (snippets are one-liners).
fn squash(alloc: std.mem.Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var prev_space = true;
    for (s) |c| {
        if (std.ascii.isWhitespace(c)) {
            if (!prev_space) out.append(alloc, ' ') catch return s;
            prev_space = true;
        } else {
            out.append(alloc, c) catch return s;
            prev_space = false;
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
    return out.items;
}

fn jStr(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string and x.string.len > 0) x.string else null;
}

fn jGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

/// Cap combined output at MAX_OUTPUT with a note.
fn capOutput(alloc: std.mem.Allocator, s: []const u8) []const u8 {
    if (s.len <= MAX_OUTPUT) return s;
    var end: usize = MAX_OUTPUT;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return std.fmt.allocPrint(alloc, "{s}\n[output truncated at {d} bytes]", .{ s[0..end], MAX_OUTPUT }) catch s[0..end];
}

fn appendHit(alloc: std.mem.Allocator, out: *std.ArrayList(u8), n: usize, title: ?[]const u8, url: ?[]const u8, snippet: ?[]const u8, max_chars: usize) !void {
    try out.print(alloc, "{d}. {s}\n   {s}\n", .{ n, title orelse "(untitled)", url orelse "" });
    if (snippet) |sn| {
        const one = squash(alloc, sn);
        if (one.len > 0) try out.print(alloc, "   {s}\n", .{clip(alloc, one, max_chars)});
    }
}

// ---------------------------------------------------------------- HTTP + error mapping

/// Map an HTTP failure to a short, secret-free message.
fn mapHttpError(alloc: std.mem.Allocator, p: Provider, status: u16, body: []const u8) mcp.ToolResult {
    return switch (status) {
        401, 403 => errResult(alloc, "{s}: authentication failed (HTTP {d}); check {s}", .{ p.label(), status, p.envName() }),
        402, 432, 433 => errResult(alloc, "{s}: plan or credit limit reached (HTTP {d})", .{ p.label(), status }),
        429 => errResult(alloc, "{s}: rate limited (HTTP 429); retry later", .{p.label()}),
        else => errResult(alloc, "{s}: HTTP {d}: {s}", .{ p.label(), status, clip(alloc, squash(alloc, body), 200) }),
    };
}

/// Send a request; on non-2xx return the mapped error in `err_out`.
fn send(alloc: std.mem.Allocator, io: std.Io, p: Provider, req: Request, err_out: *?mcp.ToolResult) ?std.json.Value {
    const resp = g_transport(alloc, io, req) catch |e| {
        err_out.* = errResult(alloc, "{s}: request failed: {s}", .{ p.label(), @errorName(e) });
        return null;
    };
    if (resp.status < 200 or resp.status >= 300) {
        err_out.* = mapHttpError(alloc, p, resp.status, resp.body);
        return null;
    }
    return std.json.parseFromSliceLeaky(std.json.Value, alloc, resp.body, .{}) catch {
        err_out.* = errResult(alloc, "{s}: invalid JSON response", .{p.label()});
        return null;
    };
}

// ---------------------------------------------------------------- Exa

const EXA_BASE = "https://api.exa.ai";

fn exaSearchRequest(alloc: std.mem.Allocator, key: []const u8, args: std.json.Value) !Request {
    const query = getStr(args, "query") orelse return error.MissingQuery;
    const num = getInt(args, "num_results", 5, 1, 10);
    const chars = getInt(args, "max_chars", 800, 100, 5000);
    const jw = Jw.init(alloc);
    const js = &jw.js;
    try js.beginObject();
    try jw.field("query");
    try js.write(query);
    try jw.field("numResults");
    try js.write(num);
    if (getStrArray(args, "include_domains")) |d| {
        try jw.field("includeDomains");
        try writeStrArray(js, d);
    }
    try jw.field("contents");
    try js.beginObject();
    try jw.field("text");
    try js.beginObject();
    try jw.field("maxCharacters");
    try js.write(chars);
    try js.endObject();
    try js.endObject();
    try js.endObject();
    return .{
        .method = .POST,
        .url = EXA_BASE ++ "/search",
        .auth_name = "x-api-key",
        .auth_value = key,
        .body = jw.done(),
    };
}

fn exaContentsRequest(alloc: std.mem.Allocator, key: []const u8, args: std.json.Value) !Request {
    const urls = urlsArg(args) orelse return error.BadUrls;
    const chars = getInt(args, "max_chars", 5000, 200, 20000);
    const jw = Jw.init(alloc);
    const js = &jw.js;
    try js.beginObject();
    try jw.field("urls");
    try writeStrArray(js, urls);
    try jw.field("text");
    try js.beginObject();
    try jw.field("maxCharacters");
    try js.write(chars);
    try js.endObject();
    try js.endObject();
    return .{
        .method = .POST,
        .url = EXA_BASE ++ "/contents",
        .auth_name = "x-api-key",
        .auth_value = key,
        .body = jw.done(),
    };
}

/// Exa search/contents response -> compact text. Prefers highlights over text.
fn compactExa(alloc: std.mem.Allocator, root: std.json.Value, max_chars: usize, full_text: bool) ![]const u8 {
    const results = jGet(root, "results") orelse return "No results.";
    if (results != .array or results.array.items.len == 0) return "No results.";
    var out: std.ArrayList(u8) = .empty;
    for (results.array.items, 0..) |r, i| {
        var snippet: ?[]const u8 = null;
        if (!full_text) {
            if (jGet(r, "highlights")) |h| {
                if (h == .array and h.array.items.len > 0 and h.array.items[0] == .string) {
                    snippet = h.array.items[0].string;
                }
            }
        }
        if (snippet == null) snippet = jStr(jGet(r, "text"));
        if (full_text) {
            try out.print(alloc, "## {s}\n{s}\n", .{ jStr(jGet(r, "title")) orelse "(untitled)", jStr(jGet(r, "url")) orelse "" });
            if (snippet) |s| try out.print(alloc, "{s}\n", .{clip(alloc, s, max_chars)});
            try out.append(alloc, '\n');
        } else {
            try appendHit(alloc, &out, i + 1, jStr(jGet(r, "title")), jStr(jGet(r, "url")), snippet, max_chars);
        }
    }
    return capOutput(alloc, out.items);
}

fn handleExaSearch(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    const key = getEnv("EXA_API_KEY") orelse return missingKey(alloc, .exa);
    const req = exaSearchRequest(alloc, key, args) catch return errResult(alloc, "query is required", .{});
    var e: ?mcp.ToolResult = null;
    const root = send(alloc, io, .exa, req, &e) orelse return e.?;
    return .{ .text = try compactExa(alloc, root, @intCast(getInt(args, "max_chars", 800, 100, 5000)), false) };
}

fn handleExaContents(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    const key = getEnv("EXA_API_KEY") orelse return missingKey(alloc, .exa);
    const req = exaContentsRequest(alloc, key, args) catch return errResult(alloc, "urls: 1-{d} http(s) URLs required", .{max_urls});
    var e: ?mcp.ToolResult = null;
    const root = send(alloc, io, .exa, req, &e) orelse return e.?;
    return .{ .text = try compactExa(alloc, root, @intCast(getInt(args, "max_chars", 5000, 200, 20000)), true) };
}

// ---------------------------------------------------------------- Tavily

const TAVILY_BASE = "https://api.tavily.com";

fn bearer(alloc: std.mem.Allocator, key: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "Bearer {s}", .{key});
}

fn inEnum(v: []const u8, comptime opts: []const []const u8) bool {
    inline for (opts) |o| if (std.mem.eql(u8, v, o)) return true;
    return false;
}

fn tavilySearchRequest(alloc: std.mem.Allocator, key: []const u8, args: std.json.Value) !Request {
    const query = getStr(args, "query") orelse return error.MissingQuery;
    const jw = Jw.init(alloc);
    const js = &jw.js;
    try js.beginObject();
    try jw.field("query");
    try js.write(query);
    try jw.field("max_results");
    try js.write(getInt(args, "max_results", 5, 1, 10));
    if (getStr(args, "search_depth")) |v| if (inEnum(v, &.{ "basic", "advanced" })) {
        try jw.field("search_depth");
        try js.write(v);
    };
    if (getStr(args, "topic")) |v| if (inEnum(v, &.{ "general", "news" })) {
        try jw.field("topic");
        try js.write(v);
    };
    if (getStr(args, "time_range")) |v| if (inEnum(v, &.{ "day", "week", "month", "year" })) {
        try jw.field("time_range");
        try js.write(v);
    };
    if (getStrArray(args, "include_domains")) |d| {
        try jw.field("include_domains");
        try writeStrArray(js, d);
    }
    try js.endObject();
    return .{
        .method = .POST,
        .url = TAVILY_BASE ++ "/search",
        .auth_name = "Authorization",
        .auth_value = try bearer(alloc, key),
        .body = jw.done(),
    };
}

fn tavilyExtractRequest(alloc: std.mem.Allocator, key: []const u8, args: std.json.Value) !Request {
    const urls = urlsArg(args) orelse return error.BadUrls;
    const jw = Jw.init(alloc);
    const js = &jw.js;
    try js.beginObject();
    try jw.field("urls");
    try writeStrArray(js, urls);
    if (getStr(args, "extract_depth")) |v| if (inEnum(v, &.{ "basic", "advanced" })) {
        try jw.field("extract_depth");
        try js.write(v);
    };
    try jw.field("format");
    try js.write("markdown");
    try js.endObject();
    return .{
        .method = .POST,
        .url = TAVILY_BASE ++ "/extract",
        .auth_name = "Authorization",
        .auth_value = try bearer(alloc, key),
        .body = jw.done(),
    };
}

fn compactTavilySearch(alloc: std.mem.Allocator, root: std.json.Value, max_chars: usize) ![]const u8 {
    const results = jGet(root, "results") orelse return "No results.";
    if (results != .array or results.array.items.len == 0) return "No results.";
    var out: std.ArrayList(u8) = .empty;
    for (results.array.items, 0..) |r, i| {
        try appendHit(alloc, &out, i + 1, jStr(jGet(r, "title")), jStr(jGet(r, "url")), jStr(jGet(r, "content")), max_chars);
    }
    return capOutput(alloc, out.items);
}

fn compactTavilyExtract(alloc: std.mem.Allocator, root: std.json.Value, max_chars: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (jGet(root, "results")) |results| if (results == .array) {
        for (results.array.items) |r| {
            try out.print(alloc, "## {s}\n", .{jStr(jGet(r, "url")) orelse ""});
            if (jStr(jGet(r, "raw_content"))) |c| try out.print(alloc, "{s}\n", .{clip(alloc, c, max_chars)});
            try out.append(alloc, '\n');
        }
    };
    if (jGet(root, "failed_results")) |f| if (f == .array) {
        for (f.array.items) |r| {
            try out.print(alloc, "FAILED {s}: {s}\n", .{ jStr(jGet(r, "url")) orelse "", jStr(jGet(r, "error")) orelse "unknown" });
        }
    };
    if (out.items.len == 0) return "No results.";
    return capOutput(alloc, out.items);
}

fn handleTavilySearch(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    const key = getEnv("TAVILY_API_KEY") orelse return missingKey(alloc, .tavily);
    const req = tavilySearchRequest(alloc, key, args) catch return errResult(alloc, "query is required", .{});
    var e: ?mcp.ToolResult = null;
    const root = send(alloc, io, .tavily, req, &e) orelse return e.?;
    return .{ .text = try compactTavilySearch(alloc, root, @intCast(getInt(args, "max_chars", 800, 100, 5000))) };
}

fn handleTavilyExtract(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    const key = getEnv("TAVILY_API_KEY") orelse return missingKey(alloc, .tavily);
    const req = tavilyExtractRequest(alloc, key, args) catch return errResult(alloc, "urls: 1-{d} http(s) URLs required", .{max_urls});
    var e: ?mcp.ToolResult = null;
    const root = send(alloc, io, .tavily, req, &e) orelse return e.?;
    return .{ .text = try compactTavilyExtract(alloc, root, @intCast(getInt(args, "max_chars", 5000, 200, 20000))) };
}

// ---------------------------------------------------------------- Firecrawl

const FIRECRAWL_DEFAULT_BASE = "https://api.firecrawl.dev/v2";

fn fcUrl(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (getEnv("FIRECRAWL_API_URL")) |u| {
        // A custom base is the server root (as in the upstream server); add /v2.
        return std.fmt.allocPrint(alloc, "{s}/v2{s}", .{ std.mem.trimEnd(u8, u, "/"), path });
    }
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ FIRECRAWL_DEFAULT_BASE, path });
}

fn fcRequest(alloc: std.mem.Allocator, key: []const u8, method: std.http.Method, path: []const u8, body: ?[]const u8) !Request {
    return .{
        .method = method,
        .url = try fcUrl(alloc, path),
        .auth_name = "Authorization",
        .auth_value = try bearer(alloc, key),
        .body = body,
    };
}

fn firecrawlScrapeRequest(alloc: std.mem.Allocator, key: []const u8, args: std.json.Value) !Request {
    const url = getStr(args, "url") orelse return error.MissingUrl;
    if (!isHttpUrl(url)) return error.BadUrl;
    const jw = Jw.init(alloc);
    const js = &jw.js;
    try js.beginObject();
    try jw.field("url");
    try js.write(url);
    try jw.field("formats");
    try js.beginArray();
    try js.write("markdown");
    try js.endArray();
    try jw.field("onlyMainContent");
    try js.write(getBool(args, "only_main_content", true));
    try js.endObject();
    return fcRequest(alloc, key, .POST, "/scrape", jw.done());
}

fn firecrawlSearchRequest(alloc: std.mem.Allocator, key: []const u8, args: std.json.Value) !Request {
    const query = getStr(args, "query") orelse return error.MissingQuery;
    const jw = Jw.init(alloc);
    const js = &jw.js;
    try js.beginObject();
    try jw.field("query");
    try js.write(query);
    try jw.field("limit");
    try js.write(getInt(args, "limit", 5, 1, 10));
    try js.endObject();
    return fcRequest(alloc, key, .POST, "/search", jw.done());
}

fn firecrawlMapRequest(alloc: std.mem.Allocator, key: []const u8, args: std.json.Value) !Request {
    const url = getStr(args, "url") orelse return error.MissingUrl;
    if (!isHttpUrl(url)) return error.BadUrl;
    const jw = Jw.init(alloc);
    const js = &jw.js;
    try js.beginObject();
    try jw.field("url");
    try js.write(url);
    if (getStr(args, "search")) |s| {
        try jw.field("search");
        try js.write(s);
    }
    try jw.field("limit");
    try js.write(getInt(args, "limit", 50, 1, 500));
    try js.endObject();
    return fcRequest(alloc, key, .POST, "/map", jw.done());
}

fn firecrawlCrawlRequest(alloc: std.mem.Allocator, key: []const u8, args: std.json.Value) !Request {
    const url = getStr(args, "url") orelse return error.MissingUrl;
    if (!isHttpUrl(url)) return error.BadUrl;
    const jw = Jw.init(alloc);
    const js = &jw.js;
    try js.beginObject();
    try jw.field("url");
    try js.write(url);
    try jw.field("limit");
    try js.write(getInt(args, "limit", 10, 1, 100));
    try jw.field("maxDiscoveryDepth");
    try js.write(getInt(args, "max_depth", 2, 1, 10));
    try jw.field("scrapeOptions");
    try js.beginObject();
    try jw.field("formats");
    try js.beginArray();
    try js.write("markdown");
    try js.endArray();
    try js.endObject();
    try js.endObject();
    return fcRequest(alloc, key, .POST, "/crawl", jw.done());
}

fn validJobId(id: []const u8) bool {
    if (id.len == 0 or id.len > 100) return false;
    for (id) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    return true;
}

fn firecrawlStatusRequest(alloc: std.mem.Allocator, key: []const u8, args: std.json.Value) !Request {
    const id = getStr(args, "id") orelse return error.MissingId;
    if (!validJobId(id)) return error.BadId;
    const path = try std.fmt.allocPrint(alloc, "/crawl/{s}", .{id});
    return fcRequest(alloc, key, .GET, path, null);
}

fn fcFailure(alloc: std.mem.Allocator, root: std.json.Value) ?mcp.ToolResult {
    if (jGet(root, "success")) |s| if (s == .bool and !s.bool) {
        return errResult(alloc, "Firecrawl: {s}", .{jStr(jGet(root, "error")) orelse "request failed"});
    };
    return null;
}

fn compactFirecrawlScrape(alloc: std.mem.Allocator, root: std.json.Value, max_chars: usize) ![]const u8 {
    const data = jGet(root, "data") orelse return "No content.";
    const md = jStr(jGet(data, "markdown")) orelse return "No content.";
    var out: std.ArrayList(u8) = .empty;
    if (jGet(data, "metadata")) |m| {
        if (jStr(jGet(m, "title"))) |t| try out.print(alloc, "# {s}\n", .{t});
    }
    try out.print(alloc, "{s}", .{clip(alloc, md, max_chars)});
    return capOutput(alloc, out.items);
}

fn compactFirecrawlSearch(alloc: std.mem.Allocator, root: std.json.Value) ![]const u8 {
    var data = jGet(root, "data") orelse return "No results.";
    // v2: data.web[]; v1: data[]
    if (data == .object) data = jGet(data, "web") orelse return "No results.";
    if (data != .array or data.array.items.len == 0) return "No results.";
    var out: std.ArrayList(u8) = .empty;
    for (data.array.items, 0..) |r, i| {
        const snippet = jStr(jGet(r, "description")) orelse jStr(jGet(r, "markdown"));
        try appendHit(alloc, &out, i + 1, jStr(jGet(r, "title")), jStr(jGet(r, "url")), snippet, 500);
    }
    return capOutput(alloc, out.items);
}

fn compactFirecrawlMap(alloc: std.mem.Allocator, root: std.json.Value) ![]const u8 {
    const links = jGet(root, "links") orelse return "No URLs.";
    if (links != .array or links.array.items.len == 0) return "No URLs.";
    var out: std.ArrayList(u8) = .empty;
    for (links.array.items) |l| {
        if (l == .string) {
            try out.print(alloc, "{s}\n", .{l.string});
        } else if (jStr(jGet(l, "url"))) |u| {
            if (jStr(jGet(l, "title"))) |t| {
                try out.print(alloc, "{s} - {s}\n", .{ u, clip(alloc, squash(alloc, t), 100) });
            } else try out.print(alloc, "{s}\n", .{u});
        }
    }
    return capOutput(alloc, out.items);
}

fn compactFirecrawlStatus(alloc: std.mem.Allocator, root: std.json.Value, max_chars: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const status = jStr(jGet(root, "status")) orelse "unknown";
    try out.print(alloc, "status: {s}", .{status});
    if (jGet(root, "completed")) |c| if (c == .integer) {
        try out.print(alloc, " ({d}", .{c.integer});
        if (jGet(root, "total")) |t| if (t == .integer) try out.print(alloc, "/{d}", .{t.integer});
        try out.appendSlice(alloc, " pages)");
    };
    try out.append(alloc, '\n');
    if (jGet(root, "data")) |d| if (d == .array) {
        for (d.array.items, 0..) |r, i| {
            const meta = jGet(r, "metadata");
            const url = if (meta) |m| (jStr(jGet(m, "sourceURL")) orelse jStr(jGet(m, "url"))) else null;
            const title = if (meta) |m| jStr(jGet(m, "title")) else null;
            try appendHit(alloc, &out, i + 1, title, url, jStr(jGet(r, "markdown")), max_chars);
        }
    };
    return capOutput(alloc, out.items);
}

fn handleFirecrawlScrape(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    const key = getEnv("FIRECRAWL_API_KEY") orelse return missingKey(alloc, .firecrawl);
    const req = firecrawlScrapeRequest(alloc, key, args) catch return errResult(alloc, "url: http(s) URL required", .{});
    var e: ?mcp.ToolResult = null;
    const root = send(alloc, io, .firecrawl, req, &e) orelse return e.?;
    if (fcFailure(alloc, root)) |f| return f;
    return .{ .text = try compactFirecrawlScrape(alloc, root, @intCast(getInt(args, "max_chars", 8000, 200, 40000))) };
}

fn handleFirecrawlSearch(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    const key = getEnv("FIRECRAWL_API_KEY") orelse return missingKey(alloc, .firecrawl);
    const req = firecrawlSearchRequest(alloc, key, args) catch return errResult(alloc, "query is required", .{});
    var e: ?mcp.ToolResult = null;
    const root = send(alloc, io, .firecrawl, req, &e) orelse return e.?;
    if (fcFailure(alloc, root)) |f| return f;
    return .{ .text = try compactFirecrawlSearch(alloc, root) };
}

fn handleFirecrawlMap(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    const key = getEnv("FIRECRAWL_API_KEY") orelse return missingKey(alloc, .firecrawl);
    const req = firecrawlMapRequest(alloc, key, args) catch return errResult(alloc, "url: http(s) URL required", .{});
    var e: ?mcp.ToolResult = null;
    const root = send(alloc, io, .firecrawl, req, &e) orelse return e.?;
    if (fcFailure(alloc, root)) |f| return f;
    return .{ .text = try compactFirecrawlMap(alloc, root) };
}

fn handleFirecrawlCrawl(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    const key = getEnv("FIRECRAWL_API_KEY") orelse return missingKey(alloc, .firecrawl);
    const req = firecrawlCrawlRequest(alloc, key, args) catch return errResult(alloc, "url: http(s) URL required", .{});
    var e: ?mcp.ToolResult = null;
    const root = send(alloc, io, .firecrawl, req, &e) orelse return e.?;
    if (fcFailure(alloc, root)) |f| return f;
    const id = jStr(jGet(root, "id")) orelse return errResult(alloc, "Firecrawl: no job id in response", .{});
    return .{ .text = try std.fmt.allocPrint(alloc, "Crawl started. id: {s}\nPoll with firecrawl_crawl_status.", .{id}) };
}

fn handleFirecrawlCrawlStatus(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    const key = getEnv("FIRECRAWL_API_KEY") orelse return missingKey(alloc, .firecrawl);
    const req = firecrawlStatusRequest(alloc, key, args) catch return errResult(alloc, "id: valid crawl job id required", .{});
    var e: ?mcp.ToolResult = null;
    const root = send(alloc, io, .firecrawl, req, &e) orelse return e.?;
    if (fcFailure(alloc, root)) |f| return f;
    return .{ .text = try compactFirecrawlStatus(alloc, root, @intCast(getInt(args, "max_chars", 500, 100, 5000))) };
}

// ================================================================ tests

const testing = std.testing;

var t_last: ?Request = null;
var t_status: u16 = 200;
var t_body: []const u8 = "{}";

fn fakeTransport(alloc: std.mem.Allocator, _: std.Io, req: Request) anyerror!Response {
    t_last = .{
        .method = req.method,
        .url = try alloc.dupe(u8, req.url),
        .auth_name = try alloc.dupe(u8, req.auth_name),
        .auth_value = try alloc.dupe(u8, req.auth_value),
        .body = if (req.body) |b| try alloc.dupe(u8, b) else null,
    };
    return .{ .status = t_status, .body = t_body };
}

var t_keys: [3]bool = .{ true, true, true };
fn fakeEnv(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "EXA_API_KEY")) return if (t_keys[0]) "exa-secret" else null;
    if (std.mem.eql(u8, name, "TAVILY_API_KEY")) return if (t_keys[1]) "tav-secret" else null;
    if (std.mem.eql(u8, name, "FIRECRAWL_API_KEY")) return if (t_keys[2]) "fc-secret" else null;
    return null;
}

fn setup(status: u16, body: []const u8) void {
    g_transport = fakeTransport;
    g_env_override = fakeEnv;
    t_keys = .{ true, true, true };
    t_last = null;
    t_status = status;
    t_body = body;
}

fn teardown() void {
    g_transport = realTransport;
    g_env_override = null;
}

fn parseArgs(alloc: std.mem.Allocator, s: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, alloc, s, .{});
}

fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn call(arena: std.mem.Allocator, h: mcp.ToolHandler, args: []const u8) !mcp.ToolResult {
    return h(arena, testIo(), try parseArgs(arena, args));
}

test "exa_search builds request and compacts response" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    setup(200,
        \\{"results":[{"title":"A","url":"https://a.com","score":0.9,"text":"full text a","highlights":["hl  one\nline"]},{"title":"B","url":"https://b.com","text":"only text"}]}
    );
    defer teardown();
    const r = try call(a, handleExaSearch, "{\"query\":\"zig\",\"num_results\":3,\"include_domains\":[\"a.com\"]}");
    try testing.expect(!r.is_error);
    try testing.expectEqualStrings("1. A\n   https://a.com\n   hl one line\n2. B\n   https://b.com\n   only text\n", r.text);
    const q = t_last.?;
    try testing.expectEqual(std.http.Method.POST, q.method);
    try testing.expectEqualStrings("https://api.exa.ai/search", q.url);
    try testing.expectEqualStrings("x-api-key", q.auth_name);
    try testing.expectEqualStrings("exa-secret", q.auth_value);
    try testing.expectEqualStrings("{\"query\":\"zig\",\"numResults\":3,\"includeDomains\":[\"a.com\"],\"contents\":{\"text\":{\"maxCharacters\":800}}}", q.body.?);
}

test "exa_contents request and output" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    setup(200, "{\"results\":[{\"title\":\"T\",\"url\":\"https://x.io\",\"text\":\"abcdefghij\"}]}");
    defer teardown();
    const r = try call(a, handleExaContents, "{\"urls\":[\"https://x.io\"],\"max_chars\":200}");
    try testing.expectEqualStrings("## T\nhttps://x.io\nabcdefghij\n\n", r.text);
    try testing.expectEqualStrings("https://api.exa.ai/contents", t_last.?.url);
    try testing.expectEqualStrings("{\"urls\":[\"https://x.io\"],\"text\":{\"maxCharacters\":200}}", t_last.?.body.?);
    // non-http url rejected without a request
    t_last = null;
    const bad = try call(a, handleExaContents, "{\"urls\":[\"file:///etc/passwd\"]}");
    try testing.expect(bad.is_error);
    try testing.expect(t_last == null);
}

test "tavily_search request and compaction" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    setup(200, "{\"answer\":null,\"results\":[{\"title\":\"Z\",\"url\":\"https://z.org\",\"content\":\"snip\",\"score\":0.5}]}");
    defer teardown();
    const r = try call(a, handleTavilySearch, "{\"query\":\"q\",\"search_depth\":\"advanced\",\"topic\":\"bogus\",\"time_range\":\"week\",\"max_results\":99}");
    try testing.expectEqualStrings("1. Z\n   https://z.org\n   snip\n", r.text);
    const q = t_last.?;
    try testing.expectEqualStrings("https://api.tavily.com/search", q.url);
    try testing.expectEqualStrings("Authorization", q.auth_name);
    try testing.expectEqualStrings("Bearer tav-secret", q.auth_value);
    try testing.expectEqualStrings("{\"query\":\"q\",\"max_results\":10,\"search_depth\":\"advanced\",\"time_range\":\"week\"}", q.body.?);
}

test "tavily_extract request and compaction incl. failures" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    setup(200, "{\"results\":[{\"url\":\"https://a.com\",\"raw_content\":\"hello world\"}],\"failed_results\":[{\"url\":\"https://b.com\",\"error\":\"timeout\"}]}");
    defer teardown();
    const r = try call(a, handleTavilyExtract, "{\"urls\":[\"https://a.com\",\"https://b.com\"],\"extract_depth\":\"advanced\"}");
    try testing.expectEqualStrings("## https://a.com\nhello world\n\nFAILED https://b.com: timeout\n", r.text);
    try testing.expectEqualStrings("https://api.tavily.com/extract", t_last.?.url);
    try testing.expectEqualStrings("{\"urls\":[\"https://a.com\",\"https://b.com\"],\"extract_depth\":\"advanced\",\"format\":\"markdown\"}", t_last.?.body.?);
}

test "firecrawl scrape/search/map/crawl requests" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    defer teardown();

    setup(200, "{\"success\":true,\"data\":{\"markdown\":\"# Hi\\nbody\",\"metadata\":{\"title\":\"Page\"}}}");
    var r = try call(a, handleFirecrawlScrape, "{\"url\":\"https://e.com\"}");
    try testing.expectEqualStrings("# Page\n# Hi\nbody", r.text);
    try testing.expectEqualStrings("https://api.firecrawl.dev/v2/scrape", t_last.?.url);
    try testing.expectEqualStrings("Bearer fc-secret", t_last.?.auth_value);
    try testing.expectEqualStrings("{\"url\":\"https://e.com\",\"formats\":[\"markdown\"],\"onlyMainContent\":true}", t_last.?.body.?);

    setup(200, "{\"success\":true,\"data\":{\"web\":[{\"title\":\"W\",\"url\":\"https://w.com\",\"description\":\"desc\"}]}}");
    r = try call(a, handleFirecrawlSearch, "{\"query\":\"x\",\"limit\":2}");
    try testing.expectEqualStrings("1. W\n   https://w.com\n   desc\n", r.text);
    try testing.expectEqualStrings("{\"query\":\"x\",\"limit\":2}", t_last.?.body.?);
    // v1 shape
    setup(200, "{\"success\":true,\"data\":[{\"title\":\"V\",\"url\":\"https://v.com\"}]}");
    r = try call(a, handleFirecrawlSearch, "{\"query\":\"x\"}");
    try testing.expectEqualStrings("1. V\n   https://v.com\n", r.text);

    setup(200, "{\"success\":true,\"links\":[\"https://e.com/a\",{\"url\":\"https://e.com/b\",\"title\":\"B\"}]}");
    r = try call(a, handleFirecrawlMap, "{\"url\":\"https://e.com\",\"search\":\"docs\"}");
    try testing.expectEqualStrings("https://e.com/a\nhttps://e.com/b - B\n", r.text);
    try testing.expectEqualStrings("https://api.firecrawl.dev/v2/map", t_last.?.url);
    try testing.expectEqualStrings("{\"url\":\"https://e.com\",\"search\":\"docs\",\"limit\":50}", t_last.?.body.?);

    setup(200, "{\"success\":true,\"id\":\"abc-123\",\"url\":\"https://api.firecrawl.dev/v2/crawl/abc-123\"}");
    r = try call(a, handleFirecrawlCrawl, "{\"url\":\"https://e.com\",\"limit\":500}");
    try testing.expect(std.mem.indexOf(u8, r.text, "id: abc-123") != null);
    try testing.expectEqualStrings("https://api.firecrawl.dev/v2/crawl", t_last.?.url);
    try testing.expectEqualStrings("{\"url\":\"https://e.com\",\"limit\":100,\"maxDiscoveryDepth\":2,\"scrapeOptions\":{\"formats\":[\"markdown\"]}}", t_last.?.body.?);
}

test "firecrawl crawl status compaction and id validation" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    defer teardown();
    setup(200, "{\"status\":\"scraping\",\"total\":5,\"completed\":2,\"data\":[{\"markdown\":\"page md\",\"metadata\":{\"title\":\"P\",\"sourceURL\":\"https://e.com/p\"}}]}");
    const r = try call(a, handleFirecrawlCrawlStatus, "{\"id\":\"abc-123\"}");
    try testing.expectEqualStrings("status: scraping (2/5 pages)\n1. P\n   https://e.com/p\n   page md\n", r.text);
    try testing.expectEqual(std.http.Method.GET, t_last.?.method);
    try testing.expectEqualStrings("https://api.firecrawl.dev/v2/crawl/abc-123", t_last.?.url);
    try testing.expect(t_last.?.body == null);

    t_last = null;
    const bad = try call(a, handleFirecrawlCrawlStatus, "{\"id\":\"../scrape?x=1\"}");
    try testing.expect(bad.is_error);
    try testing.expect(t_last == null);
}

test "firecrawl custom API url" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    defer teardown();
    const S = struct {
        fn env(name: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, name, "FIRECRAWL_API_URL")) return "http://localhost:3002/";
            return fakeEnv(name);
        }
    };
    setup(200, "{\"success\":true,\"data\":{\"markdown\":\"x\"}}");
    g_env_override = S.env;
    _ = try call(a, handleFirecrawlScrape, "{\"url\":\"https://e.com\"}");
    try testing.expectEqualStrings("http://localhost:3002/v2/scrape", t_last.?.url);
}

test "conditional registration by env" {
    const alloc = testing.allocator;
    defer teardown();
    g_env_override = fakeEnv;
    var list: std.ArrayList(mcp.ToolDef) = .empty;
    defer list.deinit(alloc);

    t_keys = .{ false, false, false };
    try collectTools(alloc, &list);
    try testing.expectEqual(@as(usize, 0), list.items.len);

    t_keys = .{ true, false, false };
    try collectTools(alloc, &list);
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqualStrings("exa_search", list.items[0].name);

    list.clearRetainingCapacity();
    t_keys = .{ false, true, true };
    try collectTools(alloc, &list);
    try testing.expectEqual(@as(usize, 7), list.items.len);
    for (list.items) |t| try testing.expect(!std.mem.startsWith(u8, t.name, "exa_"));

    // schemas are valid JSON
    for ([_][]const mcp.ToolDef{ &exa_tools, &tavily_tools, &firecrawl_tools }) |set| {
        for (set) |t| {
            var p = try std.json.parseFromSlice(std.json.Value, alloc, t.input_schema_json, .{});
            p.deinit();
        }
    }
}

test "missing key gives isError naming the env var" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    setup(200, "{}");
    defer teardown();
    t_keys = .{ false, false, false };
    const r1 = try call(a, handleExaSearch, "{\"query\":\"x\"}");
    try testing.expect(r1.is_error);
    try testing.expect(std.mem.indexOf(u8, r1.text, "EXA_API_KEY") != null);
    const r2 = try call(a, handleTavilySearch, "{\"query\":\"x\"}");
    try testing.expect(std.mem.indexOf(u8, r2.text, "TAVILY_API_KEY") != null);
    const r3 = try call(a, handleFirecrawlScrape, "{\"url\":\"https://x.com\"}");
    try testing.expect(std.mem.indexOf(u8, r3.text, "FIRECRAWL_API_KEY") != null);
    try testing.expect(t_last == null);
}

test "HTTP error mapping 401/402/429/other, no secrets" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    defer teardown();
    const cases = [_]struct { status: u16, needle: []const u8 }{
        .{ .status = 401, .needle = "authentication failed" },
        .{ .status = 402, .needle = "credit limit" },
        .{ .status = 432, .needle = "credit limit" },
        .{ .status = 429, .needle = "rate limited" },
        .{ .status = 500, .needle = "HTTP 500: boom" },
    };
    for (cases) |c| {
        setup(c.status, "boom");
        const r = try call(a, handleTavilySearch, "{\"query\":\"x\"}");
        try testing.expect(r.is_error);
        try testing.expect(std.mem.indexOf(u8, r.text, c.needle) != null);
        try testing.expect(std.mem.indexOf(u8, r.text, "tav-secret") == null);
    }
    setup(401, "{}");
    const r = try call(a, handleExaSearch, "{\"query\":\"x\"}");
    try testing.expect(std.mem.indexOf(u8, r.text, "EXA_API_KEY") != null);
    setup(200, "{\"success\":false,\"error\":\"bad url\"}");
    const f = try call(a, handleFirecrawlMap, "{\"url\":\"https://e.com\"}");
    try testing.expect(f.is_error);
    try testing.expectEqualStrings("Firecrawl: bad url", f.text);
    setup(200, "not json");
    const j = try call(a, handleExaSearch, "{\"query\":\"x\"}");
    try testing.expect(j.is_error);
}

test "caps: snippet clipping on utf8 boundary and total output" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expectEqualStrings("abc...", clip(a, "abc\xc3\xa9d", 4)); // cut inside 2-byte char backs up
    const big = try a.alloc(u8, MAX_OUTPUT + 100);
    @memset(big, 'x');
    const capped = capOutput(a, big);
    try testing.expect(std.mem.endsWith(u8, capped, "truncated at 65536 bytes]"));
    try testing.expect(capped.len < MAX_OUTPUT + 64);
    const md = try compactFirecrawlScrape(a, try parseArgs(a, "{\"data\":{\"markdown\":\"0123456789\"}}"), 5);
    try testing.expectEqualStrings("01234...", md);
}

test "missing/invalid args" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    setup(200, "{}");
    defer teardown();
    try testing.expect((try call(a, handleExaSearch, "{}")).is_error);
    try testing.expect((try call(a, handleTavilyExtract, "{\"urls\":[]}")).is_error);
    try testing.expect((try call(a, handleFirecrawlScrape, "{\"url\":\"ftp://x\"}")).is_error);
    try testing.expect(t_last == null);
}
