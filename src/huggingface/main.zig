//! zmcp-huggingface - pure-Zig port of the local `huggingface` MCP.
//! Read-only Hub browser over keyless public HTTPS endpoints.

const std = @import("std");
const mcp = @import("mcp");

const UA_PRODUCT = "zmcp-huggingface/0.1.0";
const README_LIMIT: usize = 12000;

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    const io = init.io;
    try mcp.run(arena, io, .{ .name = "zmcp-huggingface", .version = "0.1.0" }, &tool_table);
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "hf_search_models",
        .read_only = true,
        .description = "Search Hugging Face Hub models. Filter by search substring, author, filter tag, sort, and limit. Returns id, downloads, likes, lastModified, pipeline_tag, and tags.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "search": { "type": "string" },
        \\    "author": { "type": "string" },
        \\    "filter": { "type": "string" },
        \\    "sort": { "type": "string", "description": "downloads | likes | lastModified | trending" },
        \\    "limit": { "type": "integer", "description": "Default 20, max 100." }
        \\  }
        \\}
        ,
        .handler = handleSearchModels,
    },
    .{
        .name = "hf_model_card",
        .read_only = true,
        .description = "Get a single model's metadata plus its README.md. Pass full repo id, e.g. 'LiquidAI/LFM2-1.2B'.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "repo": { "type": "string", "description": "Repo id, e.g. 'meta-llama/Llama-3.2-1B'." }
        \\  },
        \\  "required": ["repo"]
        \\}
        ,
        .handler = handleModelCard,
    },
    .{
        .name = "hf_search_datasets",
        .read_only = true,
        .description = "Search Hugging Face Hub datasets. Same params as hf_search_models.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "search": { "type": "string" },
        \\    "author": { "type": "string" },
        \\    "filter": { "type": "string" },
        \\    "sort": { "type": "string" },
        \\    "limit": { "type": "integer" }
        \\  }
        \\}
        ,
        .handler = handleSearchDatasets,
    },
    .{
        .name = "hf_search_papers",
        .read_only = true,
        .description = "Search the Hugging Face daily-papers feed. Returns id, title, summary, upvotes, num_comments, and arxiv link when available.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "query": { "type": "string" },
        \\    "limit": { "type": "integer", "description": "Default 20." }
        \\  },
        \\  "required": ["query"]
        \\}
        ,
        .handler = handleSearchPapers,
    },
};

const HttpResp = struct {
    status: u16,
    body: []u8,
};

fn httpsGet(alloc: std.mem.Allocator, io: std.Io, url: []const u8, accept: []const u8) !HttpResp {
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
            .{ .name = "Accept", .value = accept },
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

fn buildQuery(alloc: std.mem.Allocator, args: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeByte('?');
    var first = true;

    const search = getStr(args, "search");
    const author = getStr(args, "author");
    const filter = getStr(args, "filter");
    const sort = getStr(args, "sort");
    const limit_raw = getInt(args, "limit", 20);
    const limit: i64 = @min(@max(limit_raw, 1), 100);

    const addPair = struct {
        fn f(writer: *std.Io.Writer, allocator: std.mem.Allocator, first_ptr: *bool, key: []const u8, value: []const u8) !void {
            if (!first_ptr.*) try writer.writeByte('&');
            first_ptr.* = false;
            const enc = try urlEncodeComponent(allocator, value);
            defer allocator.free(enc);
            try writer.writeAll(key);
            try writer.writeByte('=');
            try writer.writeAll(enc);
        }
    }.f;

    if (search) |v| try addPair(&out.writer, alloc, &first, "search", v);
    if (author) |v| try addPair(&out.writer, alloc, &first, "author", v);
    if (filter) |v| try addPair(&out.writer, alloc, &first, "filter", v);
    if (sort) |v| try addPair(&out.writer, alloc, &first, "sort", v);

    if (!first) try out.writer.writeByte('&');
    try out.writer.print("limit={d}", .{limit});
    return alloc.dupe(u8, out.written());
}

fn jsonPretty(alloc: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &out.writer);
    return alloc.dupe(u8, out.written());
}

fn jField(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn sliceTags(alloc: std.mem.Allocator, tags_v: std.json.Value, cap: usize) !std.json.Value {
    if (tags_v != .array) return .null;
    var arr: std.json.Array = .init(alloc);
    var i: usize = 0;
    while (i < tags_v.array.items.len and i < cap) : (i += 1) {
        try arr.append(tags_v.array.items[i]);
    }
    return .{ .array = arr };
}

fn mapSearchRows(alloc: std.mem.Allocator, arr_v: std.json.Value) !std.json.Value {
    if (arr_v != .array) return .{ .array = .init(alloc) };
    var out: std.json.Array = .init(alloc);
    for (arr_v.array.items) |item| {
        if (item != .object) continue;
        var row: std.json.ObjectMap = .{};
        try row.put(alloc, "id", jField(item, "id") orelse .null);
        try row.put(alloc, "downloads", jField(item, "downloads") orelse .null);
        try row.put(alloc, "likes", jField(item, "likes") orelse .null);
        try row.put(alloc, "lastModified", jField(item, "lastModified") orelse .null);
        try row.put(alloc, "pipeline_tag", jField(item, "pipeline_tag") orelse .null);
        if (jField(item, "tags")) |tags_v| {
            try row.put(alloc, "tags", try sliceTags(alloc, tags_v, 12));
        }
        try out.append(.{ .object = row });
    }
    return .{ .array = out };
}

fn handleSearchModels(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const query = try buildQuery(alloc, args);
    defer alloc.free(query);
    const url = try std.fmt.allocPrint(alloc, "https://huggingface.co/api/models{s}", .{query});
    defer alloc.free(url);
    const resp = httpsGet(alloc, io, url, "application/json") catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "hf_search_models failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    if (resp.status != 200) return .{ .text = try std.fmt.allocPrint(alloc, "HF models HTTP {d}", .{resp.status}), .is_error = true };
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{}) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "hf_search_models parse failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    defer parsed.deinit();
    const rows = try mapSearchRows(alloc, parsed.value);
    const text = try jsonPretty(alloc, rows);
    return .{ .text = try std.fmt.allocPrint(alloc, "{d} model(s):\n{s}", .{ if (rows == .array) rows.array.items.len else 0, text }) };
}

fn handleSearchDatasets(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const query = try buildQuery(alloc, args);
    defer alloc.free(query);
    const url = try std.fmt.allocPrint(alloc, "https://huggingface.co/api/datasets{s}", .{query});
    defer alloc.free(url);
    const resp = httpsGet(alloc, io, url, "application/json") catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "hf_search_datasets failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    if (resp.status != 200) return .{ .text = try std.fmt.allocPrint(alloc, "HF datasets HTTP {d}", .{resp.status}), .is_error = true };
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{}) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "hf_search_datasets parse failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    defer parsed.deinit();
    const rows = try mapSearchRows(alloc, parsed.value);
    const text = try jsonPretty(alloc, rows);
    return .{ .text = try std.fmt.allocPrint(alloc, "{d} dataset(s):\n{s}", .{ if (rows == .array) rows.array.items.len else 0, text }) };
}

fn encodeRepoPath(alloc: std.mem.Allocator, repo: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var it = std.mem.splitScalar(u8, repo, '/');
    var first = true;
    while (it.next()) |seg| {
        if (!first) try out.writer.writeByte('/');
        first = false;
        const enc = try urlEncodeComponent(alloc, seg);
        defer alloc.free(enc);
        try out.writer.writeAll(enc);
    }
    return alloc.dupe(u8, out.written());
}

fn handleModelCard(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const repo = getStr(args, "repo") orelse return .{ .text = "repo is required", .is_error = true };
    const repo_path = try encodeRepoPath(alloc, repo);
    defer alloc.free(repo_path);

    const meta_url = try std.fmt.allocPrint(alloc, "https://huggingface.co/api/models/{s}", .{repo_path});
    defer alloc.free(meta_url);
    const meta = httpsGet(alloc, io, meta_url, "application/json") catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "hf_model_card failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    if (meta.status != 200) return .{ .text = try std.fmt.allocPrint(alloc, "HF model HTTP {d}", .{meta.status}), .is_error = true };

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, meta.body, .{}) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "hf_model_card parse failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    defer parsed.deinit();
    const data = parsed.value;
    if (data != .object) return .{ .text = "hf_model_card: unexpected response shape", .is_error = true };

    var summary: std.json.ObjectMap = .{};
    try summary.put(alloc, "id", jField(data, "id") orelse .null);
    try summary.put(alloc, "sha", jField(data, "sha") orelse .null);
    try summary.put(alloc, "downloads", jField(data, "downloads") orelse .null);
    try summary.put(alloc, "likes", jField(data, "likes") orelse .null);
    try summary.put(alloc, "gated", jField(data, "gated") orelse .null);
    try summary.put(alloc, "library_name", jField(data, "library_name") orelse .null);
    try summary.put(alloc, "pipeline_tag", jField(data, "pipeline_tag") orelse .null);
    try summary.put(alloc, "tags", jField(data, "tags") orelse .null);
    try summary.put(alloc, "lastModified", jField(data, "lastModified") orelse .null);
    if (jField(data, "siblings")) |siblings_v| {
        if (siblings_v == .array) {
            var arr: std.json.Array = .init(alloc);
            var i: usize = 0;
            while (i < siblings_v.array.items.len and i < 30) : (i += 1) {
                try arr.append(jField(siblings_v.array.items[i], "rfilename") orelse .null);
            }
            try summary.put(alloc, "siblings", .{ .array = arr });
        }
    }

    const summary_text = try jsonPretty(alloc, .{ .object = summary });

    const readme_url = try std.fmt.allocPrint(alloc, "https://huggingface.co/{s}/raw/main/README.md", .{repo_path});
    defer alloc.free(readme_url);
    const readme = httpsGet(alloc, io, readme_url, "text/plain") catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "hf_model_card readme failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    const readme_body = if (readme.status == 200)
        if (readme.body.len > README_LIMIT)
            try std.fmt.allocPrint(alloc, "{s}\n... (README truncated)", .{readme.body[0..README_LIMIT]})
        else
            readme.body
    else
        try std.fmt.allocPrint(alloc, "(README HTTP {d})", .{readme.status});

    const model_id = if (jField(data, "id")) |idv| if (idv == .string) idv.string else repo else repo;
    return .{ .text = try std.fmt.allocPrint(alloc, "=== {s} ===\n{s}\n\n=== README ===\n{s}", .{ model_id, summary_text, readme_body }) };
}

fn handleSearchPapers(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const query = getStr(args, "query") orelse return .{ .text = "query is required", .is_error = true };
    const limit_raw = getInt(args, "limit", 20);
    const limit: usize = @intCast(@max(limit_raw, 1));
    const enc_q = try urlEncodeComponent(alloc, query);
    defer alloc.free(enc_q);
    const url = try std.fmt.allocPrint(alloc, "https://huggingface.co/api/papers/search?q={s}", .{enc_q});
    defer alloc.free(url);

    const resp = httpsGet(alloc, io, url, "application/json") catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "hf_search_papers failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    if (resp.status != 200) return .{ .text = try std.fmt.allocPrint(alloc, "HF papers HTTP {d}", .{resp.status}), .is_error = true };
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{}) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "hf_search_papers parse failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    defer parsed.deinit();
    if (parsed.value != .array) return .{ .text = "hf_search_papers: unexpected response shape", .is_error = true };

    var rows: std.json.Array = .init(alloc);
    var i: usize = 0;
    while (i < parsed.value.array.items.len and i < limit) : (i += 1) {
        const item = parsed.value.array.items[i];
        if (item != .object) continue;
        const paper = jField(item, "paper");
        var row: std.json.ObjectMap = .{};
        try row.put(alloc, "id", if (paper) |p| jField(p, "id") orelse (jField(item, "id") orelse .null) else (jField(item, "id") orelse .null));
        try row.put(alloc, "title", if (paper) |p| jField(p, "title") orelse (jField(item, "title") orelse .null) else (jField(item, "title") orelse .null));
        try row.put(alloc, "upvotes", if (paper) |p| jField(p, "upvotes") orelse (jField(item, "upvotes") orelse .null) else (jField(item, "upvotes") orelse .null));
        try row.put(alloc, "num_comments", jField(item, "numComments") orelse .null);
        if (paper) |p| {
            if (jField(p, "id")) |pidv| {
                if (pidv == .string) {
                    try row.put(alloc, "arxiv", .{ .string = try std.fmt.allocPrint(alloc, "https://arxiv.org/abs/{s}", .{pidv.string}) });
                }
            }
        }
        const summary_v = if (paper) |p| jField(p, "summary") orelse (jField(item, "summary") orelse .null) else (jField(item, "summary") orelse .null);
        if (summary_v == .string) {
            const s = summary_v.string;
            const clipped = if (s.len > 400) s[0..400] else s;
            try row.put(alloc, "summary", .{ .string = clipped });
        } else {
            try row.put(alloc, "summary", .null);
        }
        try rows.append(.{ .object = row });
    }
    const body = try jsonPretty(alloc, .{ .array = rows });
    return .{ .text = try std.fmt.allocPrint(alloc, "{d} paper(s):\n{s}", .{ rows.items.len, body }) };
}
