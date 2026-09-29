//! zmcp-fetch — HTTP fetcher with content-type-aware extraction.
//!
//! Tools:
//!   fetch       → GET URL; strip HTML / pretty-print JSON / return text as-is;
//!                 binary → "[binary content, N bytes, content-type=...]"
//!   fetch_raw   → GET URL, base64 for binary, UTF-8 text otherwise.
//!   fetch_head  → HEAD request, return status + headers.

const std = @import("std");
const mcp = @import("mcp");
const netpolicy = @import("netpolicy");

const default_max_bytes: usize = 1024 * 1024; // 1 MiB
const hard_max_bytes: usize = 64 * 1024 * 1024; // upper bound for any max_bytes argument
const UA_PRODUCT = "zmcp-fetch/0.1.0";

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    const io = init.io;
    try mcp.run(arena, io, .{ .name = "zmcp-fetch", .version = "0.1.0" }, &tool_table);
}

// ---------------------------------------------------------------------------
// Tool table
// ---------------------------------------------------------------------------

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "fetch",
        .description =
        \\Fetch a URL and return its content as text.
        \\HTML: strips <script>/<style> blocks, all other tags, decodes HTML entities.
        \\JSON: returns pretty-printed text (2-space indent).
        \\Other text types: returned as-is.
        \\Binary/image: returns "[binary content, N bytes, content-type=...]".
        \\Optional: headers object {"Name":"Value"}, max_bytes (default 1 MiB).
        ,
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "url":       { "type": "string", "description": "URL to fetch (http or https)" },
        \\    "headers":   { "type": "object", "description": "Extra request headers", "additionalProperties": { "type": "string" } },
        \\    "max_bytes": { "type": "number", "description": "Max body size in bytes (default 1 MiB)" }
        \\  },
        \\  "required": ["url"],
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleFetch,
        .read_only = true,
    },
    .{
        .name = "fetch_raw",
        .description =
        \\Fetch a URL and return raw content.
        \\Binary responses are returned as base64. Text responses are returned as UTF-8.
        \\Optional: headers object {"Name":"Value"}, max_bytes (default 1 MiB).
        ,
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "url":       { "type": "string", "description": "URL to fetch (http or https)" },
        \\    "headers":   { "type": "object", "description": "Extra request headers", "additionalProperties": { "type": "string" } },
        \\    "max_bytes": { "type": "number", "description": "Max body size in bytes (default 1 MiB)" }
        \\  },
        \\  "required": ["url"],
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleFetchRaw,
        .read_only = true,
    },
    .{
        .name = "fetch_head",
        .description =
        \\Issue a HEAD request to a URL and return HTTP status + response headers.
        \\Optional: headers object {"Name":"Value"}.
        ,
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "url":     { "type": "string", "description": "URL to request (http or https)" },
        \\    "headers": { "type": "object", "description": "Extra request headers", "additionalProperties": { "type": "string" } }
        \\  },
        \\  "required": ["url"],
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleFetchHead,
        .read_only = true,
    },
};

// ---------------------------------------------------------------------------
// Arg parsing
// ---------------------------------------------------------------------------

const ParsedArgs = struct {
    url: []const u8,
    max_bytes: usize,
    /// Extra headers; caller must free with alloc.free(args.extra).
    extra: []std.http.Header,
};

fn parseArgs(alloc: std.mem.Allocator, args: std.json.Value) !ParsedArgs {
    if (args != .object) return error.InvalidArgs;

    const url_v = args.object.get("url") orelse return error.MissingUrl;
    if (url_v != .string) return error.InvalidArgs;
    const url = url_v.string;

    const max_bytes: usize = if (args.object.get("max_bytes")) |mbv| switch (mbv) {
        .integer => |i| if (i > 0) @min(@as(usize, @intCast(i)), hard_max_bytes) else default_max_bytes,
        .float => |fv| if (std.math.isFinite(fv) and fv >= 1) @as(usize, @intFromFloat(@min(fv, @as(f64, @floatFromInt(hard_max_bytes))))) else default_max_bytes,
        else => default_max_bytes,
    } else default_max_bytes;

    var extra_list: std.ArrayList(std.http.Header) = .empty;
    if (args.object.get("headers")) |hv| {
        if (hv == .object) {
            var it = hv.object.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* == .string) {
                    try extra_list.append(alloc, .{
                        .name = entry.key_ptr.*,
                        .value = entry.value_ptr.*.string,
                    });
                }
            }
        }
    }

    return .{
        .url = url,
        .max_bytes = max_bytes,
        .extra = try extra_list.toOwnedSlice(alloc),
    };
}

// ---------------------------------------------------------------------------
// HTTP request
// ---------------------------------------------------------------------------

const HttpResult = struct {
    status: std.http.Status,
    content_type: []const u8, // duped into alloc
    head_bytes: []const u8, // duped into alloc (raw response head)
    body: []u8, // duped into alloc; empty slice for HEAD
    /// Redirect target when the status is 3xx and a Location header was sent.
    location: ?[]const u8 = null, // duped into alloc
};

/// URL policy for outbound requests: http(s) only, and loopback, private,
/// link-local and intranet hosts are refused (SSRF). ZMCP_FETCH_ALLOW_PRIVATE=1
/// lifts the host restriction. Redirects are re-checked at every hop. DNS
/// rebinding (a public name resolving to a private address) is not detected.
fn urlBlocked(alloc: std.mem.Allocator, io: std.Io, url: []const u8) ?[]const u8 {
    var allow_local = false;
    if (mcp.envAlloc(alloc, io, "ZMCP_FETCH_ALLOW_PRIVATE")) |v| {
        defer alloc.free(v);
        allow_local = std.mem.eql(u8, v, "1");
    }
    return netpolicy.check(.{ .allow_local = allow_local }, url);
}

const max_redirects: u8 = 5;

fn fetchErrText(alloc: std.mem.Allocator, err: anyerror) ![]u8 {
    if (err == error.BlockedByPolicy) {
        // The shared policy text names the browser's override; fetch has its own.
        const why = g_block_reason[0 .. std.mem.indexOf(u8, g_block_reason, " (set ZMCP_BROWSER") orelse g_block_reason.len];
        return std.fmt.allocPrint(alloc, "fetch blocked: {s} (set ZMCP_FETCH_ALLOW_PRIVATE=1 to allow private hosts)", .{why});
    }
    return std.fmt.allocPrint(alloc, "fetch error: {s}", .{@errorName(err)});
}

/// GET/HEAD with manual redirect following so every hop passes urlBlocked.
fn httpFetch(
    alloc: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    extra_headers: []const std.http.Header,
    max_bytes: usize,
    method: std.http.Method,
) !HttpResult {
    var cur: []const u8 = url;
    var owned: ?[]u8 = null;
    defer if (owned) |o| alloc.free(o);
    var hops: u8 = 0;
    while (true) {
        if (urlBlocked(alloc, io, cur)) |why| {
            g_block_reason = why;
            return error.BlockedByPolicy;
        }
        const res = try httpFetchHop(alloc, io, cur, extra_headers, max_bytes, method);
        const code = @intFromEnum(res.status);
        const loc = res.location orelse return res;
        if (code < 300 or code > 399 or code == 304) {
            alloc.free(loc);
            return res;
        }
        if (hops >= max_redirects) return error.TooManyRedirects;
        hops += 1;
        const next: []u8 = blk: {
            defer alloc.free(loc);
            if (std.mem.indexOf(u8, loc, "://") != null) break :blk try alloc.dupe(u8, loc);
            if (loc.len > 0 and loc[0] == '/') {
                const se = std.mem.indexOf(u8, cur, "://") orelse return error.InvalidRedirect;
                const ae = std.mem.indexOfAnyPos(u8, cur, se + 3, "/?#") orelse cur.len;
                break :blk try std.fmt.allocPrint(alloc, "{s}{s}", .{ cur[0..ae], loc });
            }
            return error.InvalidRedirect;
        };
        alloc.free(res.content_type);
        alloc.free(res.head_bytes);
        alloc.free(res.body);
        if (owned) |o| alloc.free(o);
        owned = next;
        cur = next;
    }
}

threadlocal var g_block_reason: []const u8 = "";

fn httpFetchHop(
    alloc: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    extra_headers: []const std.http.Header,
    max_bytes: usize,
    method: std.http.Method,
) !HttpResult {
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();
    const ua_owned = try mcp.userAgent(alloc, io, UA_PRODUCT);
    defer alloc.free(ua_owned);

    // Prepend our User-Agent to caller-supplied headers
    var all_headers = try alloc.alloc(std.http.Header, extra_headers.len + 1);
    defer alloc.free(all_headers);
    all_headers[0] = .{ .name = "User-Agent", .value = ua_owned };
    @memcpy(all_headers[1..], extra_headers);

    const uri = try std.Uri.parse(url);

    var req = try client.request(method, uri, .{
        .extra_headers = all_headers,
        .redirect_behavior = .unhandled,
        .headers = .{ .user_agent = .omit },
    });
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    // Copy head data before bodyReader invalidates pointers
    const head_bytes = try alloc.dupe(u8, response.head.bytes);
    const content_type = try alloc.dupe(u8, response.head.content_type orelse "");
    const status = response.head.status;
    const location: ?[]u8 = if (response.head.location) |l| try alloc.dupe(u8, l) else null;

    if (method == .HEAD or (location != null and @intFromEnum(status) >= 300 and @intFromEnum(status) < 400)) {
        return .{
            .status = status,
            .content_type = content_type,
            .head_bytes = head_bytes,
            .body = try alloc.alloc(u8, 0),
            .location = location,
        };
    }

    // Read at most max_bytes + 1 bytes so an oversized body is never buffered whole.
    var transfer_buf: [4096]u8 = undefined;
    const body_reader = response.reader(&transfer_buf);
    const body = body_reader.allocRemaining(alloc, .limited(max_bytes + 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.ResponseTooLarge,
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadFailed => try alloc.alloc(u8, 0),
    };
    errdefer alloc.free(body);
    if (body.len > max_bytes) {
        alloc.free(body);
        return error.ResponseTooLarge;
    }

    return .{
        .status = status,
        .content_type = content_type,
        .head_bytes = head_bytes,
        .body = body,
    };
}

// ---------------------------------------------------------------------------
// HTML stripping
// ---------------------------------------------------------------------------

/// State-machine HTML stripper (~150 LOC).
/// Skips <script>…</script> and <style>…</style> entirely.
/// Strips all other tags, decodes common HTML entities,
/// collapses whitespace runs to a single space, and trims.
pub fn stripHtml(alloc: std.mem.Allocator, html: []const u8) ![]u8 {
    const State = enum { text, tag, script, style, entity };

    // First pass: strip tags/scripts/styles and decode entities
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();

    var state: State = .text;
    var i: usize = 0;

    var entity_scratch: [16]u8 = undefined;
    var entity_len: usize = 0;

    while (i < html.len) {
        const c = html[i];
        switch (state) {
            .text => {
                if (c == '<') {
                    const rest = html[i..];
                    if (asciiStartsWith(rest, "<script") and
                        rest.len > 7 and isTagBoundary(rest[7]))
                    {
                        state = .script;
                        i += 1;
                        continue;
                    } else if (asciiStartsWith(rest, "<style") and
                        rest.len > 6 and isTagBoundary(rest[6]))
                    {
                        state = .style;
                        i += 1;
                        continue;
                    } else if (std.mem.startsWith(u8, rest, "<!--")) {
                        const end_rel = std.mem.indexOf(u8, rest[4..], "-->");
                        if (end_rel) |rel| {
                            i += 4 + rel + 3;
                        } else {
                            i = html.len;
                        }
                        continue;
                    } else {
                        // Replace tag with space for word separation
                        try buf.writer.writeByte(' ');
                        state = .tag;
                        i += 1;
                        continue;
                    }
                } else if (c == '&') {
                    state = .entity;
                    entity_len = 0;
                    i += 1;
                    continue;
                } else {
                    try buf.writer.writeByte(c);
                }
            },

            .tag => {
                if (c == '>') state = .text;
                // discard tag contents
            },

            .script => {
                if (c == '<' and
                    asciiStartsWith(html[i..], "</script") and
                    html.len > i + 8 and isTagEndBoundary(html[i + 8]))
                {
                    const gt = std.mem.indexOfScalarPos(u8, html, i, '>') orelse (html.len - 1);
                    i = gt + 1;
                    state = .text;
                    continue;
                }
                // discard
            },

            .style => {
                if (c == '<' and
                    asciiStartsWith(html[i..], "</style") and
                    html.len > i + 7 and isTagEndBoundary(html[i + 7]))
                {
                    const gt = std.mem.indexOfScalarPos(u8, html, i, '>') orelse (html.len - 1);
                    i = gt + 1;
                    state = .text;
                    continue;
                }
                // discard
            },

            .entity => {
                if (c == ';') {
                    const name = entity_scratch[0..entity_len];
                    if (decodeEntity(name)) |d| {
                        try buf.writer.writeAll(d);
                    } else {
                        try buf.writer.writeByte('&');
                        try buf.writer.writeAll(name);
                        try buf.writer.writeByte(';');
                    }
                    state = .text;
                    entity_len = 0;
                } else if (entity_len < entity_scratch.len) {
                    entity_scratch[entity_len] = c;
                    entity_len += 1;
                    if (entity_len == entity_scratch.len) {
                        // Too long — flush raw and return to text
                        try buf.writer.writeByte('&');
                        try buf.writer.writeAll(entity_scratch[0..entity_len]);
                        state = .text;
                        entity_len = 0;
                    }
                }
            },
        }
        i += 1;
    }

    // Second pass: collapse whitespace runs and trim
    const raw = buf.written();
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    var prev_space = true; // true at start so leading whitespace is trimmed
    for (raw) |ch| {
        const is_ws = (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r');
        if (is_ws) {
            if (!prev_space) {
                try out.writer.writeByte(' ');
                prev_space = true;
            }
        } else {
            try out.writer.writeByte(ch);
            prev_space = false;
        }
    }

    // Trim trailing space
    const written = out.written();
    var end = written.len;
    while (end > 0 and written[end - 1] == ' ') end -= 1;

    return alloc.dupe(u8, written[0..end]);
}

fn isTagBoundary(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '>' or c == '/';
}

fn isTagEndBoundary(c: u8) bool {
    return c == '>' or c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Case-insensitive startsWith for ASCII.
fn asciiStartsWith(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

fn decodeEntity(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "amp")) return "&";
    if (std.mem.eql(u8, name, "lt")) return "<";
    if (std.mem.eql(u8, name, "gt")) return ">";
    if (std.mem.eql(u8, name, "quot")) return "\"";
    if (std.mem.eql(u8, name, "apos")) return "'";
    if (std.mem.eql(u8, name, "nbsp")) return " ";
    return null;
}

// ---------------------------------------------------------------------------
// JSON pretty-print
// ---------------------------------------------------------------------------

fn prettyPrintJson(alloc: std.mem.Allocator, body: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();

    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();

    try std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, &sw.writer);

    return alloc.dupe(u8, sw.written());
}

// ---------------------------------------------------------------------------
// Content-type classification
// ---------------------------------------------------------------------------

fn isHtmlContentType(ct: []const u8) bool {
    return std.mem.indexOf(u8, ct, "text/html") != null or
        std.mem.indexOf(u8, ct, "application/xhtml") != null;
}

fn isJsonContentType(ct: []const u8) bool {
    return std.mem.indexOf(u8, ct, "application/json") != null;
}

fn isTextContentType(ct: []const u8) bool {
    return std.mem.startsWith(u8, ct, "text/") or
        std.mem.indexOf(u8, ct, "application/json") != null or
        std.mem.indexOf(u8, ct, "application/xml") != null or
        std.mem.indexOf(u8, ct, "application/javascript") != null or
        std.mem.indexOf(u8, ct, "+xml") != null or
        std.mem.indexOf(u8, ct, "+json") != null;
}

fn looksLikeHtml(body: []const u8) bool {
    const t = std.mem.trimStart(u8, body, " \t\r\n");
    if (t.len < 5) return false;
    return asciiStartsWith(t, "<!doctype") or asciiStartsWith(t, "<html");
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

fn handleFetch(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const parsed = parseArgs(alloc, args) catch |err| {
        return .{
            .text = try std.fmt.allocPrint(alloc, "error: {s}", .{@errorName(err)}),
            .is_error = true,
        };
    };
    defer alloc.free(parsed.extra);

    const res = httpFetch(alloc, io, parsed.url, parsed.extra, parsed.max_bytes, .GET) catch |err| {
        return .{
            .text = try fetchErrText(alloc, err),
            .is_error = true,
        };
    };

    const status_code = @intFromEnum(res.status);
    const ct = res.content_type;

    const body_text: []const u8 = if (isHtmlContentType(ct) or (ct.len == 0 and looksLikeHtml(res.body)))
        stripHtml(alloc, res.body) catch res.body
    else if (isJsonContentType(ct))
        prettyPrintJson(alloc, res.body) catch res.body
    else if (isTextContentType(ct))
        res.body
    else
        try std.fmt.allocPrint(
            alloc,
            "[binary content, {d} bytes, content-type={s}]",
            .{ res.body.len, ct },
        );

    return .{
        .text = try std.fmt.allocPrint(alloc, "Status: {d}\nContent-Type: {s}\n\n{s}", .{
            status_code,
            ct,
            body_text,
        }),
    };
}

fn handleFetchRaw(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const parsed = parseArgs(alloc, args) catch |err| {
        return .{
            .text = try std.fmt.allocPrint(alloc, "error: {s}", .{@errorName(err)}),
            .is_error = true,
        };
    };
    defer alloc.free(parsed.extra);

    const res = httpFetch(alloc, io, parsed.url, parsed.extra, parsed.max_bytes, .GET) catch |err| {
        return .{
            .text = try fetchErrText(alloc, err),
            .is_error = true,
        };
    };

    const status_code = @intFromEnum(res.status);
    const ct = res.content_type;

    const content: []const u8 = if (isTextContentType(ct))
        res.body
    else blk: {
        const enc_len = std.base64.standard.Encoder.calcSize(res.body.len);
        const enc_buf = try alloc.alloc(u8, enc_len);
        break :blk std.base64.standard.Encoder.encode(enc_buf, res.body);
    };

    return .{
        .text = try std.fmt.allocPrint(alloc, "Status: {d}\nContent-Type: {s}\n\n{s}", .{
            status_code,
            ct,
            content,
        }),
    };
}

fn handleFetchHead(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const parsed = parseArgs(alloc, args) catch |err| {
        return .{
            .text = try std.fmt.allocPrint(alloc, "error: {s}", .{@errorName(err)}),
            .is_error = true,
        };
    };
    defer alloc.free(parsed.extra);

    const res = httpFetch(alloc, io, parsed.url, parsed.extra, default_max_bytes, .HEAD) catch |err| {
        return .{
            .text = try fetchErrText(alloc, err),
            .is_error = true,
        };
    };

    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();

    try sw.writer.print("Status: {d}\n", .{@intFromEnum(res.status)});

    var hit = std.http.HeaderIterator.init(res.head_bytes);
    while (hit.next()) |h| {
        try sw.writer.print("{s}: {s}\n", .{ h.name, h.value });
    }

    return .{ .text = try alloc.dupe(u8, sw.written()) };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "stripHtml basic" {
    const alloc = std.testing.allocator;
    const input = "<html><body><h1>Hi</h1><script>x=1</script><p>There</p></body></html>";
    const result = try stripHtml(alloc, input);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("Hi There", result);
}

test "stripHtml entities" {
    const alloc = std.testing.allocator;
    const input = "&amp; &lt; Tom &amp; Jerry";
    const result = try stripHtml(alloc, input);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("& < Tom & Jerry", result);
}

test "json pretty-print round-trip" {
    const alloc = std.testing.allocator;
    const input = "{\"a\":1,\"b\":[2,3]}";
    const pretty = try prettyPrintJson(alloc, input);
    defer alloc.free(pretty);
    // Re-parse to confirm validity
    const reparsed = try std.json.parseFromSlice(std.json.Value, alloc, pretty, .{});
    defer reparsed.deinit();
    const a = reparsed.value.object.get("a") orelse return error.MissingField;
    try std.testing.expectEqual(@as(i64, 1), a.integer);
    // Confirm indentation is present
    try std.testing.expect(std.mem.indexOf(u8, pretty, "\n") != null);
}

test "parseArgs max_bytes" {
    const alloc = std.testing.allocator;
    const json_str = "{\"url\":\"http://example.com\",\"max_bytes\":5}";
    const pj = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    defer pj.deinit();
    const args = try parseArgs(alloc, pj.value);
    defer alloc.free(args.extra);
    try std.testing.expectEqual(@as(usize, 5), args.max_bytes);
    try std.testing.expectEqualStrings("http://example.com", args.url);
}

test "url policy blocks loopback, private and non-http URLs" {
    const p: netpolicy.Policy = .{};
    try std.testing.expect(netpolicy.check(p, "http://127.0.0.1/x") != null);
    try std.testing.expect(netpolicy.check(p, "http://localhost:8080/") != null);
    try std.testing.expect(netpolicy.check(p, "http://169.254.169.254/latest/meta-data") != null);
    try std.testing.expect(netpolicy.check(p, "http://2130706433/") != null);
    try std.testing.expect(netpolicy.check(p, "file:///etc/passwd") != null);
    try std.testing.expect(netpolicy.check(p, "https://example.com/a") == null);
}

test "parseArgs clamps huge and non-finite max_bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"url\":\"https://example.com\",\"max_bytes\":1e30}", .{});
    const parsed = try parseArgs(a, v);
    try std.testing.expectEqual(hard_max_bytes, parsed.max_bytes);
}
