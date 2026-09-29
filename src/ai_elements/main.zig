//! zmcp-ai-elements - pure-Zig port of the local Node `ai_elements` MCP.
//! Fetches the Vercel AI Elements registry over HTTPS and exposes four tools:
//! list, get, source, install command generation.

const std = @import("std");
const mcp = @import("mcp");

const UA_PRODUCT = "zmcp-ai-elements/0.1.0";
const REG_BASE = "https://elements.ai-sdk.dev/api/registry";
const ALL_URL = REG_BASE ++ "/registry.json";

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    const io = init.io;
    try mcp.run(arena, io, .{ .name = "zmcp-ai-elements", .version = "0.1.0" }, &tool_table);
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "ai_elements_list",
        .description = "List components in the Vercel AI Elements registry. Returns name, type, description, dependencies, and registryDependencies. Optional substring filter and result limit.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "filter": { "type": "string", "description": "Optional case-insensitive substring filter on component name." },
        \\    "limit": { "type": "integer", "description": "Optional maximum number of results to return." }
        \\  }
        \\}
        ,
        .handler = handleList,
        .read_only = true,
    },
    .{
        .name = "ai_elements_get",
        .description = "Fetch one AI Elements component registry entry. Returns metadata and file paths, but omits full file contents to keep responses small.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "name": { "type": "string", "description": "Component name, e.g. 'message', 'tool', 'reasoning', 'conversation', 'code-block', 'artifact'." }
        \\  },
        \\  "required": ["name"]
        \\}
        ,
        .handler = handleGet,
        .read_only = true,
    },
    .{
        .name = "ai_elements_source",
        .description = "Fetch the full source files for one AI Elements component. Returns JSON array entries with path and content.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "name": { "type": "string", "description": "Component name." }
        \\  },
        \\  "required": ["name"]
        \\}
        ,
        .handler = handleSource,
        .read_only = true,
    },
    .{
        .name = "ai_elements_install_cmd",
        .description = "Generate shadcn and ai-elements CLI install commands for one or more AI Elements components. Does not execute anything.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "names": {
        \\      "type": "array",
        \\      "items": { "type": "string" },
        \\      "description": "Components to install. Use ['all'] for the full registry."
        \\    },
        \\    "package_manager": {
        \\      "type": "string",
        \\      "enum": ["npm", "pnpm", "yarn", "bun"],
        \\      "description": "Default: npm."
        \\    }
        \\  },
        \\  "required": ["names"]
        \\}
        ,
        .handler = handleInstallCmd,
        .read_only = true,
    },
};

const HttpResp = struct {
    status: u16,
    body: []u8,
};

fn httpsGet(alloc: std.mem.Allocator, io: std.Io, url: []const u8) !HttpResp {
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();
    const ua_owned = try mcp.userAgent(alloc, io, UA_PRODUCT);
    defer alloc.free(ua_owned);

    var resp_buf: std.Io.Writer.Allocating = .init(alloc);
    defer resp_buf.deinit();

    var decompress_buf: [64 * 1024]u8 = undefined;

    const fetch_res = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &resp_buf.writer,
        .method = .GET,
        .extra_headers = &.{
            .{ .name = "User-Agent", .value = ua_owned },
            .{ .name = "Accept", .value = "application/json" },
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

fn getNames(args: std.json.Value) ?std.json.Array {
    if (args != .object) return null;
    const v = args.object.get("names") orelse return null;
    return if (v == .array) v.array else null;
}

fn itemUrl(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll(REG_BASE);
    try out.writer.writeByte('/');
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.') {
            try out.writer.writeByte(c);
        } else if (c == ' ') {
            try out.writer.writeAll("%20");
        } else {
            try out.writer.print("%{X:0>2}", .{c});
        }
    }
    try out.writer.writeAll(".json");
    return alloc.dupe(u8, out.written());
}

fn jsonToText(alloc: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &out.writer);
    return alloc.dupe(u8, out.written());
}

fn handleList(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const filter = getStr(args, "filter");
    const limit_i = getInt(args, "limit", std.math.maxInt(i32));
    const limit: usize = if (limit_i > 0) @intCast(limit_i) else std.math.maxInt(usize);

    const resp = try httpsGet(alloc, io, ALL_URL);
    if (resp.status != 200) return .{ .text = try std.fmt.allocPrint(alloc, "error: HTTP {d} fetching registry", .{resp.status}), .is_error = true };

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{});
    defer parsed.deinit();

    const items_val = switch (parsed.value) {
        .object => parsed.value.object.get("items") orelse return .{ .text = "error: registry missing items", .is_error = true },
        .array => parsed.value,
        else => return .{ .text = "error: unexpected registry shape", .is_error = true },
    };
    if (items_val != .array) return .{ .text = "error: registry items not an array", .is_error = true };

    var rows: std.json.Array = .init(alloc);

    for (items_val.array.items) |item| {
        if (item != .object) continue;
        const name_v = item.object.get("name") orelse continue;
        if (name_v != .string) continue;
        if (filter) |f| {
            if (std.ascii.indexOfIgnoreCase(name_v.string, f) == null) continue;
        }
        var row_obj: std.json.ObjectMap = .{};
        try row_obj.put(alloc, "name", name_v);
        try row_obj.put(alloc, "type", item.object.get("type") orelse .null);
        try row_obj.put(alloc, "description", item.object.get("description") orelse .null);
        var empty_arr: std.json.Array = .init(alloc);
        try row_obj.put(alloc, "dependencies", item.object.get("dependencies") orelse std.json.Value{ .array = empty_arr });
        empty_arr = .init(alloc);
        try row_obj.put(alloc, "registryDependencies", item.object.get("registryDependencies") orelse std.json.Value{ .array = empty_arr });
        try rows.append(.{ .object = row_obj });
        if (rows.items.len >= limit) break;
    }

    var root: std.json.ObjectMap = .{};
    try root.put(alloc, "total_in_registry", .{ .integer = @intCast(items_val.array.items.len) });
    try root.put(alloc, "returned", .{ .integer = @intCast(rows.items.len) });
    try root.put(alloc, "items", .{ .array = rows });
    rows = .init(alloc);

    return .{ .text = try jsonToText(alloc, .{ .object = root }) };
}

fn handleGet(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const name = getStr(args, "name") orelse return .{ .text = "error: name required", .is_error = true };
    const url = try itemUrl(alloc, name);
    const resp = try httpsGet(alloc, io, url);
    if (resp.status != 200) return .{ .text = try std.fmt.allocPrint(alloc, "error: HTTP {d} fetching {s}", .{ resp.status, name }), .is_error = true };

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .text = "error: unexpected component payload", .is_error = true };

    var trimmed: std.json.ObjectMap = .{};
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "files") and entry.value_ptr.* == .array) {
            var out_files: std.json.Array = .init(alloc);
            for (entry.value_ptr.*.array.items) |file_v| {
                if (file_v != .object) continue;
                var file_obj: std.json.ObjectMap = .{};
                try file_obj.put(alloc, "path", file_v.object.get("path") orelse .null);
                try file_obj.put(alloc, "type", file_v.object.get("type") orelse .null);
                try file_obj.put(alloc, "target", file_v.object.get("target") orelse .null);
                const size_bytes: i64 = if (file_v.object.get("content")) |c| switch (c) {
                    .string => @intCast(c.string.len),
                    else => 0,
                } else 0;
                try file_obj.put(alloc, "size_bytes", .{ .integer = size_bytes });
                try out_files.append(.{ .object = file_obj });
            }
            try trimmed.put(alloc, entry.key_ptr.*, .{ .array = out_files });
        } else {
            try trimmed.put(alloc, entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    return .{ .text = try jsonToText(alloc, .{ .object = trimmed }) };
}

fn handleSource(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const name = getStr(args, "name") orelse return .{ .text = "error: name required", .is_error = true };
    const url = try itemUrl(alloc, name);
    const resp = try httpsGet(alloc, io, url);
    if (resp.status != 200) return .{ .text = try std.fmt.allocPrint(alloc, "error: HTTP {d} fetching {s}", .{ resp.status, name }), .is_error = true };

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .text = "error: unexpected component payload", .is_error = true };
    const files_v = parsed.value.object.get("files") orelse return .{ .text = "error: component has no files", .is_error = true };
    if (files_v != .array) return .{ .text = "error: files is not an array", .is_error = true };

    var out_files: std.json.Array = .init(alloc);
    for (files_v.array.items) |file_v| {
        if (file_v != .object) continue;
        var file_obj: std.json.ObjectMap = .{};
        try file_obj.put(alloc, "path", file_v.object.get("path") orelse .null);
        try file_obj.put(alloc, "content", file_v.object.get("content") orelse .null);
        try out_files.append(.{ .object = file_obj });
    }
    return .{ .text = try jsonToText(alloc, .{ .array = out_files }) };
}

fn handleInstallCmd(alloc: std.mem.Allocator, _: std.Io, args: std.json.Value) !mcp.ToolResult {
    const names = getNames(args) orelse return .{ .text = "error: names (non-empty array) is required", .is_error = true };
    if (names.items.len == 0) return .{ .text = "error: names (non-empty array) is required", .is_error = true };
    const pm = getStr(args, "package_manager") orelse "npm";
    const dlx = if (std.mem.eql(u8, pm, "pnpm"))
        "pnpm dlx"
    else if (std.mem.eql(u8, pm, "yarn"))
        "yarn dlx"
    else if (std.mem.eql(u8, pm, "bun"))
        "bunx"
    else
        "npx";

    if (names.items.len == 1 and names.items[0] == .string and std.mem.eql(u8, names.items[0].string, "all")) {
        return .{ .text = try std.fmt.allocPrint(alloc, "{s} shadcn@latest add https://elements.ai-sdk.dev/api/registry/all.json", .{dlx}) };
    }

    var urls = std.ArrayList(u8).empty;
    defer urls.deinit(alloc);
    var names_text = std.ArrayList(u8).empty;
    defer names_text.deinit(alloc);
    for (names.items, 0..) |name_v, idx| {
        if (name_v != .string) continue;
        if (idx > 0) {
            try urls.append(alloc, ' ');
            try names_text.append(alloc, ' ');
        }
        const url = try itemUrl(alloc, name_v.string);
        try urls.appendSlice(alloc, url);
        try names_text.appendSlice(alloc, name_v.string);
    }
    const text = try std.fmt.allocPrint(
        alloc,
        "# shadcn CLI (canonical):\n{s} shadcn@latest add {s}\n\n# ai-elements CLI (auto-detects {s}):\n{s} ai-elements@latest add {s}",
        .{ dlx, urls.items, pm, dlx, names_text.items },
    );
    return .{ .text = text };
}
