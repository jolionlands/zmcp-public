//! zmcp-context7 — Context7 documentation lookup.
//!
//! Zig-native port of @upstash/context7-mcp (v2.2.5, stdio mode). Tools:
//!   resolve-library-id(query, libraryName) — resolve a package/product name to
//!     a Context7-compatible library ID via GET {base}/v2/libs/search
//!   query-docs(libraryId, query)           — fetch reranked documentation via
//!     GET {base}/v2/context (plain-text response)
//!
//! Base URL: CONTEXT7_API_URL env, default https://context7.com/api.
//! Optional auth: CONTEXT7_API_KEY env -> "Authorization: Bearer <key>".
//!
//! HTTP lives behind pure inner functions so unit tests run offline with
//! canned responses.

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


const DEFAULT_API_BASE = "https://context7.com/api";
const SERVER_VERSION = "0.1.0";

const DOC_NOT_FOUND_MSG =
    "Documentation not found or not finalized for this library. This might have happened " ++
    "because you used an invalid Context7-compatible library ID. To get a valid " ++
    "Context7-compatible library ID, use the 'resolve-library-id' with the package name " ++
    "you wish to retrieve documentation for.";

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    g_env_io = init.io;
    const io = init.io;

    try mcp.run(
        arena,
        io,
        .{ .name = "zmcp-context7", .version = SERVER_VERSION },
        &tool_table,
    );
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "resolve-library-id",
        .description =
        \\Resolves a package/product name to a Context7-compatible library ID and returns matching libraries.
        \\
        \\You MUST call this function before 'Query Documentation' tool to obtain a valid Context7-compatible library ID UNLESS the user explicitly provides a library ID in the format '/org/project' or '/org/project/version' in their query.
        \\
        \\Each result includes:
        \\- Library ID: Context7-compatible identifier (format: /org/project)
        \\- Name: Library or package name
        \\- Description: Short summary
        \\- Code Snippets: Number of available code examples
        \\- Source Reputation: Authority indicator (High, Medium, Low, or Unknown)
        \\- Benchmark Score: Quality indicator (100 is the highest score)
        \\- Versions: List of versions if available. Use one of those versions if the user provides a version in their query. The format of the version is /org/project/version.
        \\
        \\For best results, select libraries based on name match, source reputation, snippet coverage, benchmark score, and relevance to your use case.
        \\
        \\Selection Process:
        \\1. Analyze the query to understand what library/package the user is looking for
        \\2. Return the most relevant match based on:
        \\- Name similarity to the query (exact matches prioritized)
        \\- Description relevance to the query's intent
        \\- Documentation coverage (prioritize libraries with higher Code Snippet counts)
        \\- Source reputation (consider libraries with High or Medium reputation more authoritative)
        \\- Benchmark Score: Quality indicator (100 is the highest score)
        \\
        \\Response Format:
        \\- Return the selected library ID in a clearly marked section
        \\- Provide a brief explanation for why this library was chosen
        \\- If multiple good matches exist, acknowledge this but proceed with the most relevant one
        \\- If no good matches exist, clearly state this and suggest query refinements
        \\
        \\For ambiguous queries, request clarification before proceeding with a best-guess match.
        \\
        \\IMPORTANT: Do not call this tool more than 3 times per question. If you cannot find what you need after 3 calls, use the best result you have.
        ,
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "query": { "type": "string", "description": "The question or task you need help with. This is used to rank library results by relevance to what the user is trying to accomplish. The query is sent to the Context7 API for processing. Do not include any sensitive or confidential information such as API keys, passwords, credentials, personal data, or proprietary code in your query." },
        \\    "libraryName": { "type": "string", "description": "Library name to search for and retrieve a Context7-compatible library ID. Use the official library name with proper punctuation — e.g., 'Next.js' instead of 'nextjs', 'Customer.io' instead of 'customerio', 'Three.js' instead of 'threejs'." }
        \\  },
        \\  "required": ["query", "libraryName"]
        \\}
        ,
        .handler = handleResolveLibraryId,
        .read_only = true,
    },
    .{
        .name = "query-docs",
        .description =
        \\Retrieves and queries up-to-date documentation and code examples from Context7 for any programming library or framework.
        \\
        \\You must call 'Resolve Context7 Library ID' tool first to obtain the exact Context7-compatible library ID required to use this tool, UNLESS the user explicitly provides a library ID in the format '/org/project' or '/org/project/version' in their query.
        \\
        \\Do not call this tool more than 3 times per question.
        ,
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "libraryId": { "type": "string", "description": "Exact Context7-compatible library ID (e.g., '/mongodb/docs', '/vercel/next.js', '/supabase/supabase', '/vercel/next.js/v14.3.0-canary.87') retrieved from 'resolve-library-id' or directly from user query in the format '/org/project' or '/org/project/version'." },
        \\    "query": { "type": "string", "description": "The question or task you need help with. Be specific and include relevant details. Good: 'How to set up authentication with JWT in Express.js' or 'React useEffect cleanup function examples'. Bad: 'auth' or 'hooks'. The query is sent to the Context7 API for processing. Do not include any sensitive or confidential information such as API keys, passwords, credentials, personal data, or proprietary code in your query." }
        \\  },
        \\  "required": ["libraryId", "query"]
        \\}
        ,
        .handler = handleQueryDocs,
        .read_only = true,
    },
};

// ---------------------------------------------------------------------------
// Arg helpers (including the reference's transport arg aliasing)
// ---------------------------------------------------------------------------

fn getStr(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Fetch a string arg by canonical name, falling back to the reference
/// implementation's hallucination aliases (GLOBAL_ALIASES / TOOL_ALIASES).
pub fn aliasedString(args: std.json.Value, canonical: []const u8, aliases: []const []const u8) ?[]const u8 {
    if (getStr(args, canonical)) |s| return s;
    for (aliases) |alt| {
        if (getStr(args, alt)) |s| return s;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Environment helpers
// ---------------------------------------------------------------------------

fn getEnv(alloc: std.mem.Allocator, key: []const u8) ?[]u8 {
    return envOwned(alloc, key);
}

/// API base URL: CONTEXT7_API_URL env override, else the default.
/// Returned slice is owned by the caller.
fn apiBase(alloc: std.mem.Allocator) ![]u8 {
    if (getEnv(alloc, "CONTEXT7_API_URL")) |v| return v;
    return alloc.dupe(u8, DEFAULT_API_BASE);
}

// ---------------------------------------------------------------------------
// URL percent-encoding (application/x-www-form-urlencoded, like URLSearchParams)
// ---------------------------------------------------------------------------

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

/// Percent-encode `raw` for use as a query parameter value.
/// Spaces become '+'. Everything else outside the unreserved set becomes %XX.
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

// ---------------------------------------------------------------------------
// URL construction
// ---------------------------------------------------------------------------

/// GET {base}/v2/libs/search?query=<q>&libraryName=<ln>
pub fn buildSearchUrl(
    alloc: std.mem.Allocator,
    base: []const u8,
    query: []const u8,
    library_name: []const u8,
) ![]u8 {
    const q = try percentEncodeQuery(alloc, query);
    defer alloc.free(q);
    const ln = try percentEncodeQuery(alloc, library_name);
    defer alloc.free(ln);
    return std.fmt.allocPrint(
        alloc,
        "{s}/v2/libs/search?query={s}&libraryName={s}",
        .{ std.mem.trimEnd(u8, base, "/"), q, ln },
    );
}

/// GET {base}/v2/context?query=<q>&libraryId=<id>
pub fn buildContextUrl(
    alloc: std.mem.Allocator,
    base: []const u8,
    query: []const u8,
    library_id: []const u8,
) ![]u8 {
    const q = try percentEncodeQuery(alloc, query);
    defer alloc.free(q);
    const id = try percentEncodeQuery(alloc, library_id);
    defer alloc.free(id);
    return std.fmt.allocPrint(
        alloc,
        "{s}/v2/context?query={s}&libraryId={s}",
        .{ std.mem.trimEnd(u8, base, "/"), q, id },
    );
}

// ---------------------------------------------------------------------------
// HTTP seam
// ---------------------------------------------------------------------------

const HttpResponse = struct {
    status: u16,
    body: []u8,
};

fn httpGet(alloc: std.mem.Allocator, io: std.Io, url: []const u8, api_key: ?[]const u8) !HttpResponse {
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();

    var response_writer: std.Io.Writer.Allocating = .init(alloc);
    defer response_writer.deinit();

    // Headers per the reference's generateHeaders(): source marker + server
    // version always; Authorization only when CONTEXT7_API_KEY is set.
    // (The reference's encrypted client-IP / IDE telemetry headers are HTTP-mode
    // concerns and are not sent by this stdio port.)
    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(alloc);
    try headers.append(alloc, .{ .name = "X-Context7-Source", .value = "mcp-server" });
    try headers.append(alloc, .{ .name = "X-Context7-Server-Version", .value = SERVER_VERSION });

    var auth_value: ?[]u8 = null;
    defer if (auth_value) |v| alloc.free(v);
    if (api_key) |key| {
        auth_value = try std.fmt.allocPrint(alloc, "Bearer {s}", .{key});
        try headers.append(alloc, .{ .name = "Authorization", .value = auth_value.? });
    }

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .extra_headers = headers.items,
        // Never follow redirects: the request may carry the API key.
        .redirect_behavior = .unhandled,
        .response_writer = &response_writer.writer,
    });
    if (result.status.class() == .redirect) return error.UnexpectedRedirect;

    return .{
        .status = @intFromEnum(result.status),
        .body = try alloc.dupe(u8, response_writer.written()),
    };
}

// ---------------------------------------------------------------------------
// Error parsing (parity with the reference's parseErrorResponse)
// ---------------------------------------------------------------------------

/// Extract the server's error message from a non-2xx response body, falling
/// back to status-based messages. Result owned by caller.
pub fn parseErrorMessage(
    alloc: std.mem.Allocator,
    status: u16,
    body: []const u8,
    has_api_key: bool,
) ![]u8 {
    // The API's JSON error envelope wins when present (and non-empty, matching
    // the reference's truthiness check on `json.message`).
    if (std.json.parseFromSlice(std.json.Value, alloc, body, .{})) |parsed| {
        var p = parsed;
        defer p.deinit();
        if (p.value == .object) {
            if (p.value.object.get("message")) |mv| {
                if (mv == .string and mv.string.len > 0) {
                    return alloc.dupe(u8, mv.string);
                }
            }
        }
    } else |_| {}

    const msg: []const u8 = switch (status) {
        429 => if (has_api_key)
            "Rate limited or quota exceeded. Upgrade your plan at https://context7.com/plans for higher limits."
        else
            "Rate limited or quota exceeded. Create a free API key at https://context7.com/dashboard for higher limits.",
        404 => "The library you are trying to access does not exist. Please try with a different library ID.",
        401 => "Invalid API key. Please check your API key. API keys should start with 'ctx7sk' prefix.",
        else => return std.fmt.allocPrint(
            alloc,
            "Request failed with status {d}. Please try again later.",
            .{status},
        ),
    };
    return alloc.dupe(u8, msg);
}

// ---------------------------------------------------------------------------
// Search response parsing / formatting
// ---------------------------------------------------------------------------

/// Map a numeric trust score to the reference's reputation label.
pub fn reputationLabel(trust_score: ?f64) []const u8 {
    const s = trust_score orelse return "Unknown";
    if (s < 0) return "Unknown";
    if (s >= 7) return "High";
    if (s >= 4) return "Medium";
    return "Low";
}

fn jsonOptNum(v: std.json.Value, field: []const u8) ?f64 {
    if (v != .object) return null;
    const fv = v.object.get(field) orelse return null;
    return switch (fv) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

/// Print a JSON number the way JS template interpolation would: integers
/// without a decimal point, floats as decimals.
fn writeJsonNum(w: *std.Io.Writer, v: std.json.Value) !void {
    switch (v) {
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try w.print("{d}", .{f}),
        else => {},
    }
}

/// Render one search result exactly like the reference's formatSearchResult.
fn writeSearchResult(w: *std.Io.Writer, r: std.json.Value) !void {
    try w.print("- Title: {s}\n", .{getStr(r, "title") orelse ""});
    try w.print("- Context7-compatible library ID: {s}\n", .{getStr(r, "id") orelse ""});
    try w.print("- Description: {s}\n", .{getStr(r, "description") orelse ""});

    // Code Snippets: only when totalSnippets is present and != -1
    if (r == .object) {
        if (r.object.get("totalSnippets")) |sv| {
            const n: ?f64 = switch (sv) {
                .integer => |i| @floatFromInt(i),
                .float => |f| f,
                else => null,
            };
            if (n != null and n.? != -1) {
                try w.writeAll("- Code Snippets: ");
                try writeJsonNum(w, sv);
                try w.writeByte('\n');
            }
        }
    }

    try w.print("- Source Reputation: {s}\n", .{reputationLabel(jsonOptNum(r, "trustScore"))});

    // Benchmark Score: only when present and > 0
    if (r == .object) {
        if (r.object.get("benchmarkScore")) |bv| {
            const n: ?f64 = switch (bv) {
                .integer => |i| @floatFromInt(i),
                .float => |f| f,
                else => null,
            };
            if (n != null and n.? > 0) {
                try w.writeAll("- Benchmark Score: ");
                try writeJsonNum(w, bv);
                try w.writeByte('\n');
            }
        }

        // Versions: only when a non-empty string array
        if (r.object.get("versions")) |vv| {
            if (vv == .array and vv.array.items.len > 0) {
                try w.writeAll("- Versions: ");
                var first = true;
                for (vv.array.items) |item| {
                    if (item != .string) continue;
                    if (!first) try w.writeAll(", ");
                    try w.writeAll(item.string);
                    first = false;
                }
                try w.writeByte('\n');
            }
        }
    }

    if (getStr(r, "source")) |src| {
        if (src.len > 0) try w.print("- Source: {s}\n", .{src});
    }
}

/// Format a /v2/libs/search JSON body the way the reference's
/// formatSearchResults does, wrapped in the tool's "Available Libraries:" text.
pub fn formatSearchResponse(alloc: std.mem.Allocator, body: []const u8) !mcp.ToolResult {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "Error searching libraries: {}", .{err}) };
    };
    defer parsed.deinit();

    const root = parsed.value;
    const results: []const std.json.Value = blk: {
        if (root != .object) break :blk &.{};
        const rv = root.object.get("results") orelse break :blk &.{};
        if (rv != .array) break :blk &.{};
        break :blk rv.array.items;
    };

    if (results.len == 0) {
        return .{ .text = try alloc.dupe(u8, "No libraries found matching the provided name.") };
    }

    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    const w = &sw.writer;

    try w.writeAll("Available Libraries:\n\n");

    const filter_applied = root.object.get("searchFilterApplied") orelse std.json.Value{ .bool = false };
    if (filter_applied == .bool and filter_applied.bool) {
        try w.writeAll("**Note:** Your results only include libraries matching your teamspace's library filters. To adjust quality thresholds or blocked libraries, update your filters at https://context7.com/dashboard?tab=policies\n\n");
    }

    for (results, 0..) |r, i| {
        if (i > 0) try w.writeAll("\n----------\n");
        // Render each result into a scratch buffer and trim its trailing
        // newline so the join is exactly "\n----------\n", as in the reference.
        var tmp: std.Io.Writer.Allocating = .init(alloc);
        defer tmp.deinit();
        try writeSearchResult(&tmp.writer, r);
        try w.writeAll(std.mem.trimEnd(u8, tmp.written(), "\n"));
    }

    return .{ .text = try alloc.dupe(u8, sw.written()) };
}

// ---------------------------------------------------------------------------
// Context (docs) response handling
// ---------------------------------------------------------------------------

/// /v2/context returns plain text; an empty body means the docs are missing.
pub fn contextResponseInner(alloc: std.mem.Allocator, body: []const u8) !mcp.ToolResult {
    if (body.len == 0) {
        return .{ .text = try alloc.dupe(u8, DOC_NOT_FOUND_MSG) };
    }
    return .{ .text = try alloc.dupe(u8, body) };
}

// ---------------------------------------------------------------------------
// Tool handlers
// ---------------------------------------------------------------------------

fn handleResolveLibraryId(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const query = aliasedString(args, "query", &.{ "userQuery", "question" }) orelse
        return .{ .text = "Missing required argument: query", .is_error = true };
    const library_name = getStr(args, "libraryName") orelse
        return .{ .text = "Missing required argument: libraryName", .is_error = true };

    const base = try apiBase(alloc);
    defer alloc.free(base);

    const url = try buildSearchUrl(alloc, base, query, library_name);
    defer alloc.free(url);

    const api_key = getEnv(alloc, "CONTEXT7_API_KEY");
    defer if (api_key) |k| alloc.free(k);

    // Like the reference, API failures are returned as plain text content
    // (no MCP isError flag) so the model can read and act on the message.
    const resp = httpGet(alloc, io, url, api_key) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "Error searching libraries: {}", .{err}) };
    };
    defer alloc.free(resp.body);

    if (resp.status >= 400) {
        return .{ .text = try parseErrorMessage(alloc, resp.status, resp.body, api_key != null) };
    }

    return formatSearchResponse(alloc, resp.body);
}

fn handleQueryDocs(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const library_id = aliasedString(args, "libraryId", &.{ "context7CompatibleLibraryID", "libraryID", "libraryName" }) orelse
        return .{ .text = "Missing required argument: libraryId", .is_error = true };
    const query = aliasedString(args, "query", &.{ "userQuery", "question" }) orelse
        return .{ .text = "Missing required argument: query", .is_error = true };

    const base = try apiBase(alloc);
    defer alloc.free(base);

    const url = try buildContextUrl(alloc, base, query, library_id);
    defer alloc.free(url);

    const api_key = getEnv(alloc, "CONTEXT7_API_KEY");
    defer if (api_key) |k| alloc.free(k);

    const resp = httpGet(alloc, io, url, api_key) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "Error fetching library context. Please try again later. {}", .{err}) };
    };
    defer alloc.free(resp.body);

    if (resp.status >= 400) {
        return .{ .text = try parseErrorMessage(alloc, resp.status, resp.body, api_key != null) };
    }

    return contextResponseInner(alloc, resp.body);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "percentEncodeQuery: unreserved passthrough" {
    const alloc = std.testing.allocator;
    const out = try percentEncodeQuery(alloc, "abc-._~123");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("abc-._~123", out);
}

test "percentEncodeQuery: space becomes plus" {
    const alloc = std.testing.allocator;
    const out = try percentEncodeQuery(alloc, "hello world");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("hello+world", out);
}

test "percentEncodeQuery: slash and specials encoded" {
    const alloc = std.testing.allocator;
    const out = try percentEncodeQuery(alloc, "/vercel/next.js");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("%2Fvercel%2Fnext.js", out);
}

test "buildSearchUrl: encodes query and libraryName" {
    const alloc = std.testing.allocator;
    const url = try buildSearchUrl(alloc, "https://context7.com/api", "how to route", "Next.js");
    defer alloc.free(url);
    try std.testing.expectEqualStrings(
        "https://context7.com/api/v2/libs/search?query=how+to+route&libraryName=Next.js",
        url,
    );
}

test "buildSearchUrl: trailing slash on base trimmed" {
    const alloc = std.testing.allocator;
    const url = try buildSearchUrl(alloc, "https://example.com/api/", "q", "lib");
    defer alloc.free(url);
    try std.testing.expectEqualStrings(
        "https://example.com/api/v2/libs/search?query=q&libraryName=lib",
        url,
    );
}

test "buildContextUrl: encodes libraryId slashes" {
    const alloc = std.testing.allocator;
    const url = try buildContextUrl(alloc, "https://context7.com/api", "auth with JWT", "/vercel/next.js/v14.3.0-canary.87");
    defer alloc.free(url);
    try std.testing.expectEqualStrings(
        "https://context7.com/api/v2/context?query=auth+with+JWT&libraryId=%2Fvercel%2Fnext.js%2Fv14.3.0-canary.87",
        url,
    );
}

test "parseErrorMessage: JSON message field wins" {
    const alloc = std.testing.allocator;
    const msg = try parseErrorMessage(alloc, 400, "{\"message\":\"libraryId is invalid\"}", false);
    defer alloc.free(msg);
    try std.testing.expectEqualStrings("libraryId is invalid", msg);
}

test "parseErrorMessage: 429 without api key" {
    const alloc = std.testing.allocator;
    const msg = try parseErrorMessage(alloc, 429, "not json", false);
    defer alloc.free(msg);
    try std.testing.expectEqualStrings(
        "Rate limited or quota exceeded. Create a free API key at https://context7.com/dashboard for higher limits.",
        msg,
    );
}

test "parseErrorMessage: 429 with api key" {
    const alloc = std.testing.allocator;
    const msg = try parseErrorMessage(alloc, 429, "{}", true);
    defer alloc.free(msg);
    try std.testing.expectEqualStrings(
        "Rate limited or quota exceeded. Upgrade your plan at https://context7.com/plans for higher limits.",
        msg,
    );
}

test "parseErrorMessage: 404" {
    const alloc = std.testing.allocator;
    const msg = try parseErrorMessage(alloc, 404, "", false);
    defer alloc.free(msg);
    try std.testing.expectEqualStrings(
        "The library you are trying to access does not exist. Please try with a different library ID.",
        msg,
    );
}

test "parseErrorMessage: 401" {
    const alloc = std.testing.allocator;
    const msg = try parseErrorMessage(alloc, 401, "", true);
    defer alloc.free(msg);
    try std.testing.expectEqualStrings(
        "Invalid API key. Please check your API key. API keys should start with 'ctx7sk' prefix.",
        msg,
    );
}

test "parseErrorMessage: generic status" {
    const alloc = std.testing.allocator;
    const msg = try parseErrorMessage(alloc, 503, "", false);
    defer alloc.free(msg);
    try std.testing.expectEqualStrings(
        "Request failed with status 503. Please try again later.",
        msg,
    );
}

test "parseErrorMessage: empty JSON message falls through to status text" {
    const alloc = std.testing.allocator;
    const msg = try parseErrorMessage(alloc, 404, "{\"message\":\"\"}", false);
    defer alloc.free(msg);
    try std.testing.expectEqualStrings(
        "The library you are trying to access does not exist. Please try with a different library ID.",
        msg,
    );
}

test "reputationLabel: mapping" {
    try std.testing.expectEqualStrings("Unknown", reputationLabel(null));
    try std.testing.expectEqualStrings("Unknown", reputationLabel(-1));
    try std.testing.expectEqualStrings("High", reputationLabel(7));
    try std.testing.expectEqualStrings("High", reputationLabel(10));
    try std.testing.expectEqualStrings("Medium", reputationLabel(4));
    try std.testing.expectEqualStrings("Medium", reputationLabel(6.9));
    try std.testing.expectEqualStrings("Low", reputationLabel(0));
    try std.testing.expectEqualStrings("Low", reputationLabel(3.9));
}

const canned_search_body =
    \\{
    \\  "results": [
    \\    {
    \\      "id": "/vercel/next.js",
    \\      "title": "Next.js",
    \\      "description": "The React Framework",
    \\      "totalSnippets": 3829,
    \\      "trustScore": 10,
    \\      "benchmarkScore": 95,
    \\      "versions": ["v14.3.0-canary.87", "v15.1.8"],
    \\      "source": "https://github.com/vercel/next.js"
    \\    },
    \\    {
    \\      "id": "/mongodb/docs",
    \\      "title": "MongoDB",
    \\      "description": "MongoDB documentation",
    \\      "totalSnippets": -1,
    \\      "trustScore": 5,
    \\      "benchmarkScore": 0
    \\    },
    \\    {
    \\      "id": "/unknown/lib",
    \\      "title": "Mystery",
    \\      "description": "No scores",
    \\      "totalSnippets": 3
    \\    }
    \\  ]
    \\}
;

test "formatSearchResponse: full formatting" {
    const alloc = std.testing.allocator;
    const result = try formatSearchResponse(alloc, canned_search_body);
    defer alloc.free(result.text);

    try std.testing.expect(!result.is_error);
    // Header
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Available Libraries:\n\n") != null);
    // First result: all fields
    try std.testing.expect(std.mem.indexOf(u8, result.text, "- Title: Next.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "- Context7-compatible library ID: /vercel/next.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "- Description: The React Framework") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "- Code Snippets: 3829") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "- Source Reputation: High") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "- Benchmark Score: 95") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "- Versions: v14.3.0-canary.87, v15.1.8") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "- Source: https://github.com/vercel/next.js") != null);
    // Separator between results
    try std.testing.expect(std.mem.indexOf(u8, result.text, "\n----------\n") != null);
    // Second result: totalSnippets -1 and benchmarkScore 0 omitted, Medium reputation
    try std.testing.expect(std.mem.indexOf(u8, result.text, "- Title: MongoDB\n- Context7-compatible library ID: /mongodb/docs\n- Description: MongoDB documentation\n- Source Reputation: Medium") != null);
    // Third result: missing trustScore -> Unknown
    try std.testing.expect(std.mem.indexOf(u8, result.text, "- Title: Mystery") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "- Code Snippets: 3\n- Source Reputation: Unknown") != null);
}

test "formatSearchResponse: empty results" {
    const alloc = std.testing.allocator;
    const result = try formatSearchResponse(alloc, "{\"results\": []}");
    defer alloc.free(result.text);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("No libraries found matching the provided name.", result.text);
}

test "formatSearchResponse: searchFilterApplied note" {
    const alloc = std.testing.allocator;
    const body =
        \\{"results": [{"id": "/a/b", "title": "T", "description": "D"}], "searchFilterApplied": true}
    ;
    const result = try formatSearchResponse(alloc, body);
    defer alloc.free(result.text);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Your results only include libraries matching your teamspace's library filters") != null);
}

test "formatSearchResponse: invalid JSON returns error text" {
    const alloc = std.testing.allocator;
    const result = try formatSearchResponse(alloc, "this is not json");
    defer alloc.free(result.text);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Error searching libraries:") != null);
}

test "contextResponseInner: empty body means docs not found" {
    const alloc = std.testing.allocator;
    const result = try contextResponseInner(alloc, "");
    defer alloc.free(result.text);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Documentation not found or not finalized") != null);
}

test "contextResponseInner: text passthrough" {
    const alloc = std.testing.allocator;
    const result = try contextResponseInner(alloc, "# Next.js routing\n\nUse the App Router.");
    defer alloc.free(result.text);
    try std.testing.expectEqualStrings("# Next.js routing\n\nUse the App Router.", result.text);
}

test "aliasedString: canonical wins, aliases fall back" {
    const alloc = std.testing.allocator;
    const canonical_aliases = [_][]const u8{ "userQuery", "question" };

    var parsed1 = try std.json.parseFromSlice(std.json.Value, alloc, "{\"query\":\"real\"}", .{});
    defer parsed1.deinit();
    try std.testing.expectEqualStrings("real", aliasedString(parsed1.value, "query", &canonical_aliases).?);

    var parsed2 = try std.json.parseFromSlice(std.json.Value, alloc, "{\"userQuery\":\"aliased\"}", .{});
    defer parsed2.deinit();
    try std.testing.expectEqualStrings("aliased", aliasedString(parsed2.value, "query", &canonical_aliases).?);

    const lib_aliases = [_][]const u8{ "context7CompatibleLibraryID", "libraryID", "libraryName" };
    var parsed3 = try std.json.parseFromSlice(std.json.Value, alloc, "{\"libraryName\":\"/vercel/next.js\"}", .{});
    defer parsed3.deinit();
    try std.testing.expectEqualStrings("/vercel/next.js", aliasedString(parsed3.value, "libraryId", &lib_aliases).?);

    var parsed4 = try std.json.parseFromSlice(std.json.Value, alloc, "{}", .{});
    defer parsed4.deinit();
    try std.testing.expect(aliasedString(parsed4.value, "query", &canonical_aliases) == null);
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
