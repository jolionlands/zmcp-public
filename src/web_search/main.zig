//! zmcp-web-search — multi-backend web search MCP server.
//!
//! Backends (default priority order, first configured wins):
//!   1. Brave Search API        — BRAVE_API_KEY env
//!   2. Tavily                  — TAVILY_API_KEY env
//!   3. SearXNG                 — SEARXNG_URL env
//!   4. DuckDuckGo HTML scrape  — OPT-IN only: ZMCP_WEB_SEARCH_ALLOW_DDG_SCRAPE=1
//!                                (scraping may violate DuckDuckGo's terms)
//!
//! With no backend configured the tool returns an isError result explaining
//! the options. All requests send the honest zmcp User-Agent.
//!
//! Tool:
//!   web_search(query, n?, backend?) → numbered list of title / url / snippet

const std = @import("std");
const mcp = @import("mcp");

/// The `io` handed to `main`; environment lookups go through `mcp.envAlloc`,
/// which reads the real process environment behind it on every OS.
var g_env_io: ?std.Io = null;

/// Owned copy of environment variable `key` (caller frees), or null if unset.
fn envOwned(alloc: std.mem.Allocator, key: []const u8) ?[]u8 {
    const io = g_env_io orelse return null;
    return mcp.envAlloc(alloc, io, key);
}


// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    g_env_io = init.io;
    const io = init.io;

    try mcp.run(
        arena,
        io,
        .{ .name = "zmcp-web-search", .version = "0.1.0" },
        &tool_table,
    );
}

// ---------------------------------------------------------------------------
// Tool table
// ---------------------------------------------------------------------------

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "web_search",
        .description =
        \\Search the web and return ranked results (title, URL, snippet).
        \\Backends in priority order: Brave (BRAVE_API_KEY), Tavily (TAVILY_API_KEY),
        \\SearXNG (SEARXNG_URL). DuckDuckGo HTML scraping is opt-in only
        \\(ZMCP_WEB_SEARCH_ALLOW_DDG_SCRAPE=1). Use `backend` to force one.
        ,
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "query":   { "type": "string",  "description": "Search query." },
        \\    "n":       { "type": "integer", "description": "Max results (default 10, max 25).", "minimum": 1, "maximum": 25 },
        \\    "backend": { "type": "string",  "description": "Force backend: brave | tavily | searxng | ddg (ddg needs ZMCP_WEB_SEARCH_ALLOW_DDG_SCRAPE=1). Default: first configured.", "enum": ["brave","tavily","searxng","ddg"] }
        \\  },
        \\  "required": ["query"],
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleSearch,
        .read_only = true,
    },
};

// ---------------------------------------------------------------------------
// Shared result type
// ---------------------------------------------------------------------------

const Hit = struct {
    title: []const u8,
    url: []const u8,
    snippet: []const u8,
};

// ---------------------------------------------------------------------------
// Arg helpers
// ---------------------------------------------------------------------------

fn requiredString(args: std.json.Value, key: []const u8) error{MissingArg}![]const u8 {
    if (args != .object) return error.MissingArg;
    const v = args.object.get(key) orelse return error.MissingArg;
    return switch (v) {
        .string => |s| s,
        else => error.MissingArg,
    };
}

fn optionalUint(args: std.json.Value, key: []const u8, default: usize) usize {
    if (args != .object) return default;
    const v = args.object.get(key) orelse return default;
    return switch (v) {
        .integer => |i| if (i > 0) @intCast(i) else default,
        .float => |f| if (f > 0) @intFromFloat(f) else default,
        else => default,
    };
}

fn optionalString(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Environment variable helper
// ---------------------------------------------------------------------------

/// Returns the value of an environment variable, allocated from `alloc`.
/// Returns null if the variable is not set.
fn getEnv(alloc: std.mem.Allocator, key: []const u8) ?[]u8 {
    return envOwned(alloc, key);
}

// ---------------------------------------------------------------------------
// Backend selection
// ---------------------------------------------------------------------------

const Backend = enum { ddg, searxng, brave, tavily };

/// Pure selection: Brave, Tavily, SearXNG, then DDG scraping only if opted in.
pub fn chooseBackend(has_brave: bool, has_tavily: bool, has_searxng: bool, allow_ddg: bool) ?Backend {
    if (has_brave) return .brave;
    if (has_tavily) return .tavily;
    if (has_searxng) return .searxng;
    if (allow_ddg) return .ddg;
    return null;
}

fn envIsSet(alloc: std.mem.Allocator, key: []const u8) bool {
    if (getEnv(alloc, key)) |v| {
        defer alloc.free(v);
        return std.mem.trim(u8, v, " \t\r\n").len > 0;
    }
    return false;
}

fn ddgAllowed(alloc: std.mem.Allocator) bool {
    const v = getEnv(alloc, "ZMCP_WEB_SEARCH_ALLOW_DDG_SCRAPE") orelse return false;
    defer alloc.free(v);
    return std.mem.eql(u8, std.mem.trim(u8, v, " \t\r\n"), "1");
}

fn pickDefault(alloc: std.mem.Allocator) ?Backend {
    return chooseBackend(
        envIsSet(alloc, "BRAVE_API_KEY"),
        envIsSet(alloc, "TAVILY_API_KEY"),
        envIsSet(alloc, "SEARXNG_URL"),
        ddgAllowed(alloc),
    );
}

pub const NO_BACKEND_MESSAGE =
    "No web search backend is configured. Set one of: BRAVE_API_KEY (Brave Search API), " ++
    "TAVILY_API_KEY (Tavily), or SEARXNG_URL (a SearXNG instance). " ++
    "Alternatively set ZMCP_WEB_SEARCH_ALLOW_DDG_SCRAPE=1 to opt in to scraping DuckDuckGo's HTML " ++
    "results; note that scraping may violate DuckDuckGo's terms of service and is not recommended.";

pub const DDG_DISABLED_MESSAGE =
    "DuckDuckGo HTML scraping is disabled by default because it may violate DuckDuckGo's terms. " ++
    "Set ZMCP_WEB_SEARCH_ALLOW_DDG_SCRAPE=1 to opt in, or configure BRAVE_API_KEY, TAVILY_API_KEY or SEARXNG_URL.";

pub fn parseBackend(name: []const u8) ?Backend {
    if (std.mem.eql(u8, name, "ddg")) return .ddg;
    if (std.mem.eql(u8, name, "searxng")) return .searxng;
    if (std.mem.eql(u8, name, "brave")) return .brave;
    if (std.mem.eql(u8, name, "tavily")) return .tavily;
    return null;
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

fn handleSearch(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const q = try requiredString(args, "query");
    const n = @min(optionalUint(args, "n", 10), 25);
    const backend: Backend = if (optionalString(args, "backend")) |b|
        (parseBackend(b) orelse return .{ .text = "Unknown backend; use brave | tavily | searxng | ddg.", .is_error = true })
    else
        (pickDefault(alloc) orelse return .{ .text = NO_BACKEND_MESSAGE, .is_error = true });
    if (backend == .ddg and !ddgAllowed(alloc)) return .{ .text = DDG_DISABLED_MESSAGE, .is_error = true };

    const results = try searchByBackend(alloc, io, backend, q, n);
    const text = try formatResults(alloc, q, backend, results);
    return .{ .text = text };
}

fn searchByBackend(
    alloc: std.mem.Allocator,
    io: std.Io,
    backend: Backend,
    query: []const u8,
    n: usize,
) ![]Hit {
    return switch (backend) {
        .ddg => searchDdg(alloc, io, query, n),
        .searxng => searchSearxng(alloc, io, query, n),
        .brave => searchBrave(alloc, io, query, n),
        .tavily => searchTavily(alloc, io, query, n),
    };
}

// ---------------------------------------------------------------------------
// URL percent-encoding
// ---------------------------------------------------------------------------

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

/// Percent-encode `raw` for use as a query parameter value.
/// Spaces become '+'. Everything else outside unreserved set becomes %XX.
pub fn percentEncodeQuery(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (raw) |c| {
        if (isUnreserved(c)) {
            try out.append(alloc, c);
        } else if (c == ' ') {
            try out.append(alloc, '+');
        } else {
            var tmp: [3]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "%{X:0>2}", .{c}) catch unreachable;
            try out.appendSlice(alloc, s);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Percent-decode a %XX encoded string (also handles '+' → ' ').
pub fn percentDecode(alloc: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < encoded.len) {
        if (encoded[i] == '%' and i + 2 < encoded.len) {
            const hi = std.fmt.charToDigit(encoded[i + 1], 16) catch 255;
            const lo = std.fmt.charToDigit(encoded[i + 2], 16) catch 255;
            if (hi != 255 and lo != 255) {
                try out.append(alloc, (hi << 4) | lo);
                i += 3;
                continue;
            }
        } else if (encoded[i] == '+') {
            try out.append(alloc, ' ');
            i += 1;
            continue;
        }
        try out.append(alloc, encoded[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// HTTP helper
// ---------------------------------------------------------------------------

const UA_PRODUCT = "zmcp-web-search/0.1.0";

fn httpGet(
    alloc: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    extra_headers: []const std.http.Header,
) ![]u8 {
    var client = std.http.Client{ .allocator = alloc, .io = io };
    defer client.deinit();
    const ua = try mcp.userAgent(alloc, io, UA_PRODUCT);
    defer alloc.free(ua);

    var response_writer: std.Io.Writer.Allocating = .init(alloc);
    defer response_writer.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .headers = .{
            .user_agent = .{ .override = ua },
        },
        .extra_headers = extra_headers,
        .response_writer = &response_writer.writer,
    });

    if (@intFromEnum(result.status) >= 400) {
        return error.HttpError;
    }

    return alloc.dupe(u8, response_writer.written());
}

// ---------------------------------------------------------------------------
// DDG HTML scrape
// ---------------------------------------------------------------------------

fn searchDdg(alloc: std.mem.Allocator, io: std.Io, query: []const u8, n: usize) ![]Hit {
    const encoded_q = try percentEncodeQuery(alloc, query);
    defer alloc.free(encoded_q);

    const url = try std.fmt.allocPrint(
        alloc,
        "https://html.duckduckgo.com/html/?q={s}",
        .{encoded_q},
    );
    defer alloc.free(url);

    const extra_headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "text/html,application/xhtml+xml" },
        .{ .name = "Accept-Language", .value = "en-US,en;q=0.9" },
    };

    const html = try httpGet(alloc, io, url, &extra_headers);
    defer alloc.free(html);

    return parseDdgHtml(alloc, html, n);
}

/// Strip HTML tags, returning a new allocation.
fn stripTags(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '<') {
            while (i < s.len and s[i] != '>') i += 1;
            if (i < s.len) i += 1;
        } else {
            try out.append(alloc, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Decode common HTML entities.
fn decodeEntities(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const replacements = .{
        .{ "&amp;", "&" },
        .{ "&lt;", "<" },
        .{ "&gt;", ">" },
        .{ "&quot;", "\"" },
        .{ "&#39;", "'" },
        .{ "&apos;", "'" },
        .{ "&nbsp;", " " },
        .{ "&#x2F;", "/" },
        .{ "&#X2F;", "/" },
    };
    var cur = try alloc.dupe(u8, s);
    inline for (replacements) |pair| {
        const from = pair[0];
        const to = pair[1];
        if (std.mem.indexOf(u8, cur, from)) |_| {
            const replaced = try std.mem.replaceOwned(u8, alloc, cur, from, to);
            alloc.free(cur);
            cur = replaced;
        }
    }
    return cur;
}

/// Extract the real URL from a DDG /l/?uddg=... redirect href.
fn extractUddg(alloc: std.mem.Allocator, href: []const u8) !?[]u8 {
    const marker = "uddg=";
    const start_idx = std.mem.indexOf(u8, href, marker) orelse return null;
    const val_start = start_idx + marker.len;
    const val_end = std.mem.indexOfPos(u8, href, val_start, "&") orelse href.len;
    const encoded = href[val_start..val_end];
    return try percentDecode(alloc, encoded);
}

/// Extract the value of an attribute (e.g., "href") from an HTML tag string.
fn extractAttr(tag_text: []const u8, attr: []const u8) ?[]const u8 {
    // Try attr="..."
    var buf: [64]u8 = undefined;
    const dq_needle = std.fmt.bufPrint(&buf, "{s}=\"", .{attr}) catch return null;
    if (std.mem.indexOf(u8, tag_text, dq_needle)) |start| {
        const val_start = start + dq_needle.len;
        const val_end = std.mem.indexOfPos(u8, tag_text, val_start, "\"") orelse return null;
        return tag_text[val_start..val_end];
    }
    // Try attr='...'
    var buf2: [64]u8 = undefined;
    const sq_needle = std.fmt.bufPrint(&buf2, "{s}='", .{attr}) catch return null;
    if (std.mem.indexOf(u8, tag_text, sq_needle)) |start| {
        const val_start = start + sq_needle.len;
        const val_end = std.mem.indexOfPos(u8, tag_text, val_start, "'") orelse return null;
        return tag_text[val_start..val_end];
    }
    return null;
}

/// Parse up to `n` search hits from a DDG HTML page.
pub fn parseDdgHtml(alloc: std.mem.Allocator, html: []const u8, n: usize) ![]Hit {
    var hits: std.ArrayList(Hit) = .empty;
    errdefer hits.deinit(alloc);

    var pos: usize = 0;
    while (hits.items.len < n) {
        // Locate next result__a class
        const anchor_class = "class=\"result__a\"";
        const anchor_pos = std.mem.indexOfPos(u8, html, pos, anchor_class) orelse break;

        // Walk back to '<'
        var tag_start = anchor_pos;
        while (tag_start > 0 and html[tag_start] != '<') tag_start -= 1;

        // Find closing '>' of opening tag
        const tag_end = std.mem.indexOfPos(u8, html, tag_start, ">") orelse break;
        const tag_text = html[tag_start .. tag_end + 1];

        const href_raw = extractAttr(tag_text, "href") orelse {
            pos = tag_end + 1;
            continue;
        };

        // Decode entities in href then extract uddg param
        const href_decoded = try decodeEntities(alloc, href_raw);
        defer alloc.free(href_decoded);

        const url: []u8 = (try extractUddg(alloc, href_decoded)) orelse
            try alloc.dupe(u8, href_decoded);

        // Inner text between '>' and '</a>' is the title
        const title_start = tag_end + 1;
        const title_end = std.mem.indexOfPos(u8, html, title_start, "</a>") orelse break;
        const raw_title = html[title_start..title_end];
        const stripped = try stripTags(alloc, raw_title);
        defer alloc.free(stripped);
        const title = try decodeEntities(alloc, stripped);

        pos = title_end + 4;

        // Look for snippet anchor
        const snippet_class = "class=\"result__snippet\"";
        const snip_anchor = std.mem.indexOfPos(u8, html, pos, snippet_class) orelse {
            try hits.append(alloc, .{
                .title = std.mem.trim(u8, title, " \t\r\n"),
                .url = url,
                .snippet = try alloc.dupe(u8, ""),
            });
            continue;
        };

        const snip_tag_end = std.mem.indexOfPos(u8, html, snip_anchor, ">") orelse break;
        const snip_start = snip_tag_end + 1;
        const snip_end = std.mem.indexOfPos(u8, html, snip_start, "</a>") orelse break;
        const raw_snip = html[snip_start..snip_end];
        const stripped_snip = try stripTags(alloc, raw_snip);
        defer alloc.free(stripped_snip);
        const snippet = try decodeEntities(alloc, stripped_snip);

        pos = snip_end + 4;

        try hits.append(alloc, .{
            .title = std.mem.trim(u8, title, " \t\r\n"),
            .url = url,
            .snippet = std.mem.trim(u8, snippet, " \t\r\n"),
        });
    }

    return hits.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// SearXNG
// ---------------------------------------------------------------------------

fn searchSearxng(alloc: std.mem.Allocator, io: std.Io, query: []const u8, n: usize) ![]Hit {
    const base_url = getEnv(alloc, "SEARXNG_URL") orelse return error.MissingEnvVar;
    defer alloc.free(base_url);

    const encoded_q = try percentEncodeQuery(alloc, query);
    defer alloc.free(encoded_q);

    const url = try std.fmt.allocPrint(
        alloc,
        "{s}/search?q={s}&format=json&categories=general",
        .{ std.mem.trimEnd(u8, base_url, "/"), encoded_q },
    );
    defer alloc.free(url);

    const extra_headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/json" },
    };

    const body = try httpGet(alloc, io, url, &extra_headers);
    defer alloc.free(body);

    return parseSearxngJson(alloc, body, n);
}

fn parseSearxngJson(alloc: std.mem.Allocator, body: []const u8, n: usize) ![]Hit {
    var hits: std.ArrayList(Hit) = .empty;
    errdefer hits.deinit(alloc);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();

    const results = switch (parsed.value) {
        .object => |obj| obj.get("results") orelse return hits.toOwnedSlice(alloc),
        else => return hits.toOwnedSlice(alloc),
    };

    const arr = switch (results) {
        .array => |a| a,
        else => return hits.toOwnedSlice(alloc),
    };

    for (arr.items) |item| {
        if (hits.items.len >= n) break;
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const title = switch (obj.get("title") orelse continue) {
            .string => |s| try alloc.dupe(u8, s),
            else => continue,
        };
        const url = switch (obj.get("url") orelse continue) {
            .string => |s| try alloc.dupe(u8, s),
            else => continue,
        };
        const snippet_v = obj.get("content") orelse std.json.Value{ .string = "" };
        const snippet = switch (snippet_v) {
            .string => |s| try alloc.dupe(u8, s),
            else => try alloc.dupe(u8, ""),
        };
        try hits.append(alloc, .{ .title = title, .url = url, .snippet = snippet });
    }

    return hits.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Brave Search API
// ---------------------------------------------------------------------------

fn searchBrave(alloc: std.mem.Allocator, io: std.Io, query: []const u8, n: usize) ![]Hit {
    const api_key = getEnv(alloc, "BRAVE_API_KEY") orelse return error.MissingEnvVar;
    defer alloc.free(api_key);

    const encoded_q = try percentEncodeQuery(alloc, query);
    defer alloc.free(encoded_q);

    const url = try std.fmt.allocPrint(
        alloc,
        "https://api.search.brave.com/res/v1/web/search?q={s}&count={d}",
        .{ encoded_q, @min(n, 20) },
    );
    defer alloc.free(url);

    const extra_headers = [_]std.http.Header{
        .{ .name = "X-Subscription-Token", .value = api_key },
        .{ .name = "Accept", .value = "application/json" },
    };

    const body = try httpGet(alloc, io, url, &extra_headers);
    defer alloc.free(body);

    return parseBraveJson(alloc, body, n);
}

fn parseBraveJson(alloc: std.mem.Allocator, body: []const u8, n: usize) ![]Hit {
    var hits: std.ArrayList(Hit) = .empty;
    errdefer hits.deinit(alloc);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();

    const web_obj = switch (parsed.value) {
        .object => |obj| obj.get("web") orelse return hits.toOwnedSlice(alloc),
        else => return hits.toOwnedSlice(alloc),
    };

    const results = switch (web_obj) {
        .object => |obj| obj.get("results") orelse return hits.toOwnedSlice(alloc),
        else => return hits.toOwnedSlice(alloc),
    };

    const arr = switch (results) {
        .array => |a| a,
        else => return hits.toOwnedSlice(alloc),
    };

    for (arr.items) |item| {
        if (hits.items.len >= n) break;
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const title = switch (obj.get("title") orelse continue) {
            .string => |s| try alloc.dupe(u8, s),
            else => continue,
        };
        const url = switch (obj.get("url") orelse continue) {
            .string => |s| try alloc.dupe(u8, s),
            else => continue,
        };
        const snippet_v = obj.get("description") orelse std.json.Value{ .string = "" };
        const snippet = switch (snippet_v) {
            .string => |s| try alloc.dupe(u8, s),
            else => try alloc.dupe(u8, ""),
        };
        try hits.append(alloc, .{ .title = title, .url = url, .snippet = snippet });
    }

    return hits.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Tavily
// ---------------------------------------------------------------------------

fn searchTavily(alloc: std.mem.Allocator, io: std.Io, query: []const u8, n: usize) ![]Hit {
    const api_key = getEnv(alloc, "TAVILY_API_KEY") orelse return error.MissingEnvVar;
    defer alloc.free(api_key);

    // Simple JSON body — escape the query string for JSON
    const payload = try buildTavilyPayload(alloc, api_key, query, @min(n, 20));
    defer alloc.free(payload);

    var client = std.http.Client{ .allocator = alloc, .io = io };
    defer client.deinit();
    const ua = try mcp.userAgent(alloc, io, UA_PRODUCT);
    defer alloc.free(ua);

    const extra_headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };

    var response_writer: std.Io.Writer.Allocating = .init(alloc);
    defer response_writer.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = "https://api.tavily.com/search" },
        .method = .POST,
        .payload = payload,
        .headers = .{ .user_agent = .{ .override = ua } },
        .extra_headers = &extra_headers,
        .response_writer = &response_writer.writer,
    });

    if (@intFromEnum(result.status) >= 400) return error.HttpError;

    const body = try alloc.dupe(u8, response_writer.written());
    defer alloc.free(body);

    return parseTavilyJson(alloc, body, n);
}

fn buildTavilyPayload(alloc: std.mem.Allocator, api_key: []const u8, query: []const u8, max_results: usize) ![]u8 {
    // Use std.json.Stringify to properly escape strings
    var sw: std.Io.Writer.Allocating = .init(alloc);
    errdefer sw.deinit();
    var js = std.json.Stringify{ .writer = &sw.writer };
    try js.beginObject();
    try js.objectField("api_key");
    try js.write(api_key);
    try js.objectField("query");
    try js.write(query);
    try js.objectField("search_depth");
    try js.write("basic");
    try js.objectField("max_results");
    try js.write(max_results);
    try js.endObject();
    const result = try alloc.dupe(u8, sw.written());
    return result;
}

fn parseTavilyJson(alloc: std.mem.Allocator, body: []const u8, n: usize) ![]Hit {
    var hits: std.ArrayList(Hit) = .empty;
    errdefer hits.deinit(alloc);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();

    const results = switch (parsed.value) {
        .object => |obj| obj.get("results") orelse return hits.toOwnedSlice(alloc),
        else => return hits.toOwnedSlice(alloc),
    };

    const arr = switch (results) {
        .array => |a| a,
        else => return hits.toOwnedSlice(alloc),
    };

    for (arr.items) |item| {
        if (hits.items.len >= n) break;
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const title = switch (obj.get("title") orelse continue) {
            .string => |s| try alloc.dupe(u8, s),
            else => continue,
        };
        const url = switch (obj.get("url") orelse continue) {
            .string => |s| try alloc.dupe(u8, s),
            else => continue,
        };
        const snippet_v2 = obj.get("content") orelse std.json.Value{ .string = "" };
        const snippet = switch (snippet_v2) {
            .string => |s| try alloc.dupe(u8, s),
            else => try alloc.dupe(u8, ""),
        };
        try hits.append(alloc, .{ .title = title, .url = url, .snippet = snippet });
    }

    return hits.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Output formatting
// ---------------------------------------------------------------------------

fn truncate(s: []const u8, max_len: usize) []const u8 {
    if (s.len <= max_len) return s;
    return s[0..max_len];
}

fn formatResults(
    alloc: std.mem.Allocator,
    query: []const u8,
    backend: Backend,
    hits: []const Hit,
) ![]u8 {
    const backend_name = switch (backend) {
        .ddg => "DuckDuckGo",
        .searxng => "SearXNG",
        .brave => "Brave",
        .tavily => "Tavily",
    };

    var sw: std.Io.Writer.Allocating = .init(alloc);
    errdefer sw.deinit();
    const w = &sw.writer;

    try w.print("Query: {s}\nBackend: {s}\nResults: {d}\n", .{ query, backend_name, hits.len });

    if (hits.len == 0) {
        try w.writeAll("\nNo results found.");
        return alloc.dupe(u8, sw.written());
    }

    try w.writeByte('\n');
    for (hits, 1..) |hit, i| {
        try w.print("{d}. {s}\n   {s}\n", .{ i, hit.title, hit.url });
        if (hit.snippet.len > 0) {
            try w.print("   {s}\n", .{truncate(hit.snippet, 200)});
        }
        try w.writeByte('\n');
    }

    return alloc.dupe(u8, sw.written());
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "percentEncodeQuery: basic ASCII passthrough" {
    const alloc = std.testing.allocator;
    const out = try percentEncodeQuery(alloc, "hello");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("hello", out);
}

test "percentEncodeQuery: space becomes plus" {
    const alloc = std.testing.allocator;
    const out = try percentEncodeQuery(alloc, "hello world");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("hello+world", out);
}

test "percentEncodeQuery: special chars encoded" {
    const alloc = std.testing.allocator;
    const out = try percentEncodeQuery(alloc, "foo&bar=baz");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("foo%26bar%3Dbaz", out);
}

test "percentEncodeQuery: unreserved chars not encoded" {
    const alloc = std.testing.allocator;
    const out = try percentEncodeQuery(alloc, "abc-._~123");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("abc-._~123", out);
}

test "percentDecode: basic" {
    const alloc = std.testing.allocator;
    const out = try percentDecode(alloc, "hello+world%21");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("hello world!", out);
}

// Canned DDG HTML for parser tests
const canned_ddg_html =
    \\<html><body>
    \\<div class="result">
    \\  <a class="result__a" href="/l/?uddg=https%3A%2F%2Fexample.com%2Fpage1&amp;rut=x">Example Page One</a>
    \\  <p>some filler text</p>
    \\  <a class="result__snippet" href="#">First snippet text here</a>
    \\</div>
    \\<div class="result">
    \\  <a class="result__a" href="/l/?uddg=https%3A%2F%2Fexample.org%2Fpage2&amp;rut=y">Example Page Two</a>
    \\  <p>more filler</p>
    \\  <a class="result__snippet" href="#">Second snippet text here</a>
    \\</div>
    \\<div class="result">
    \\  <a class="result__a" href="/l/?uddg=https%3A%2F%2Fexample.net%2Fpage3&amp;rut=z">Example Page Three</a>
    \\  <p>yet more filler</p>
    \\  <a class="result__snippet" href="#">Third snippet text here</a>
    \\</div>
    \\</body></html>
;

test "parseDdgHtml: respects limit n" {
    const alloc = std.testing.allocator;
    const hits = try parseDdgHtml(alloc, canned_ddg_html, 2);
    defer {
        for (hits) |h| {
            alloc.free(h.title);
            alloc.free(h.url);
            alloc.free(h.snippet);
        }
        alloc.free(hits);
    }
    try std.testing.expectEqual(@as(usize, 2), hits.len);
}

test "parseDdgHtml: correct title, url, snippet" {
    const alloc = std.testing.allocator;
    const hits = try parseDdgHtml(alloc, canned_ddg_html, 10);
    defer {
        for (hits) |h| {
            alloc.free(h.title);
            alloc.free(h.url);
            alloc.free(h.snippet);
        }
        alloc.free(hits);
    }
    try std.testing.expectEqual(@as(usize, 3), hits.len);
    try std.testing.expectEqualStrings("Example Page One", hits[0].title);
    try std.testing.expectEqualStrings("https://example.com/page1", hits[0].url);
    try std.testing.expectEqualStrings("First snippet text here", hits[0].snippet);
    try std.testing.expectEqualStrings("Example Page Two", hits[1].title);
    try std.testing.expectEqualStrings("https://example.org/page2", hits[1].url);
    try std.testing.expectEqualStrings("Second snippet text here", hits[1].snippet);
}

test "backend dispatch: parseBackend covers all variants" {
    try std.testing.expectEqual(Backend.ddg, parseBackend("ddg").?);
    try std.testing.expectEqual(Backend.searxng, parseBackend("searxng").?);
    try std.testing.expectEqual(Backend.brave, parseBackend("brave").?);
    try std.testing.expectEqual(Backend.tavily, parseBackend("tavily").?);
    try std.testing.expectEqual(@as(?Backend, null), parseBackend("unknown"));
}

test "chooseBackend: Brave, Tavily, SearXNG order; DDG only when opted in" {
    try std.testing.expectEqual(@as(?Backend, .brave), chooseBackend(true, true, true, true));
    try std.testing.expectEqual(@as(?Backend, .tavily), chooseBackend(false, true, true, true));
    try std.testing.expectEqual(@as(?Backend, .searxng), chooseBackend(false, false, true, true));
    try std.testing.expectEqual(@as(?Backend, .ddg), chooseBackend(false, false, false, true));
    try std.testing.expectEqual(@as(?Backend, null), chooseBackend(false, false, false, false));
}

test "no-backend message names every option and the DDG caveat" {
    try std.testing.expect(std.mem.indexOf(u8, NO_BACKEND_MESSAGE, "BRAVE_API_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, NO_BACKEND_MESSAGE, "TAVILY_API_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, NO_BACKEND_MESSAGE, "SEARXNG_URL") != null);
    try std.testing.expect(std.mem.indexOf(u8, NO_BACKEND_MESSAGE, "ZMCP_WEB_SEARCH_ALLOW_DDG_SCRAPE=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, NO_BACKEND_MESSAGE, "terms") != null);
    try std.testing.expect(std.mem.indexOf(u8, DDG_DISABLED_MESSAGE, "ZMCP_WEB_SEARCH_ALLOW_DDG_SCRAPE=1") != null);
}

test "env lookup reads the real process environment (not an empty block)" {
    const alloc = std.testing.allocator;
    g_env_io = std.testing.io;
    defer g_env_io = null;
    const v = getEnv(alloc, "PATH") orelse return error.SkipZigTest;
    defer alloc.free(v);
    try std.testing.expect(v.len > 0);
    try std.testing.expect(getEnv(alloc, "ZMCP_SURELY_UNSET_ENV_VAR_12345") == null);
}
