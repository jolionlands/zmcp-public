//! zmcp-package-registry — drop-in replacement for the Node `package_registry`
//! ext. Wraps the public JSON endpoints for npm, PyPI, crates.io.
//!
//! Tools:
//!   pkg_npm(name)        — registry.npmjs.org/<name>
//!   pkg_pypi(name)       — pypi.org/pypi/<name>/json
//!   pkg_crates(name)     — crates.io/api/v1/crates/<name>
//!   pkg_search(query)    — npm + crates.io multi-registry search.
//!                          PyPI has no JSON search API.

const std = @import("std");
const mcp = @import("mcp");

const UA_PRODUCT = "zmcp-package-registry/0.1.0";
const DEFAULT_SEARCH_LIMIT: i64 = 10;

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    const io = init.io;
    try mcp.run(arena, io, .{ .name = "zmcp-package-registry", .version = "0.1.0" }, &tool_table);
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "pkg_npm",
        .read_only = true,
        .description = "Lookup an npm package by name. Returns latest version, dist-tags, license, repo, homepage, and the 15 most-recent versions.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "name": { "type": "string", "description": "Package name (e.g. '@modelcontextprotocol/sdk')." }
        \\  },
        \\  "required": ["name"]
        \\}
        ,
        .handler = handleNpm,
    },
    .{
        .name = "pkg_pypi",
        .read_only = true,
        .description = "Lookup a PyPI project by name. Returns latest version, summary, license, project_urls, requires_python, and recent releases.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "name": { "type": "string", "description": "PyPI project name (e.g. 'mcp-server-time')." }
        \\  },
        \\  "required": ["name"]
        \\}
        ,
        .handler = handlePypi,
    },
    .{
        .name = "pkg_crates",
        .read_only = true,
        .description = "Lookup a crates.io crate by name. Returns latest version, description, repo, downloads, owners, recent versions.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "name": { "type": "string", "description": "Crate name (e.g. 'tokio')." }
        \\  },
        \\  "required": ["name"]
        \\}
        ,
        .handler = handleCrates,
    },
    .{
        .name = "pkg_search",
        .read_only = true,
        .description = "Search npm and crates.io for `query`. PyPI has no JSON search API. Returns top hits per ecosystem.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "query": { "type": "string" },
        \\    "limit": { "type": "integer", "description": "Per-ecosystem cap. Default 10." }
        \\  },
        \\  "required": ["query"]
        \\}
        ,
        .handler = handleSearch,
    },
};

// ---------------------------------------------------------------------------
// HTTPS helper (shared shape with zig_packages — uses decompress_buffer for
// gzip-encoded responses).
// ---------------------------------------------------------------------------

const HttpResp = struct {
    status: u16,
    body: []u8,
};

/// crates.io policy: at most 1 request per second per process.
const CRATES_MIN_GAP_MS: i64 = 1000;
const CRATES_PREFIX = "https://crates.io/";
var crates_last_ms: i64 = 0;

/// Milliseconds still to wait before the next crates.io request.
fn cratesWaitMs(now_ms: i64, last_ms: i64) i64 {
    if (last_ms == 0) return 0;
    const elapsed = now_ms - last_ms;
    if (elapsed < 0) return CRATES_MIN_GAP_MS;
    return if (elapsed < CRATES_MIN_GAP_MS) CRATES_MIN_GAP_MS - elapsed else 0;
}

fn throttleCrates(io: std.Io) void {
    const wait = cratesWaitMs(std.Io.Timestamp.now(io, .real).toMilliseconds(), crates_last_ms);
    if (wait > 0) std.Io.sleep(io, std.Io.Duration.fromMilliseconds(wait), .awake) catch {};
    crates_last_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
}

test "cratesWaitMs enforces a 1s gap" {
    try std.testing.expectEqual(@as(i64, 0), cratesWaitMs(5000, 0));
    try std.testing.expectEqual(@as(i64, 400), cratesWaitMs(5600, 5000));
    try std.testing.expectEqual(@as(i64, 0), cratesWaitMs(6000, 5000));
    try std.testing.expectEqual(@as(i64, 0), cratesWaitMs(9000, 5000));
}

fn httpsGet(alloc: std.mem.Allocator, io: std.Io, url: []const u8) !HttpResp {
    if (std.mem.startsWith(u8, url, CRATES_PREFIX)) throttleCrates(io);
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
            .{ .name = "Accept", .value = "application/json" },
        },
        .decompress_buffer = &decompress_buf,
    });

    return .{
        .status = @intFromEnum(fetch_res.status),
        .body = try alloc.dupe(u8, resp_buf.written()),
    };
}

// ---------------------------------------------------------------------------
// URL encoding (percent-encode for path components like "@scope/name")
// ---------------------------------------------------------------------------

fn isUnreserved(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or
        c == '-' or c == '_' or c == '.' or c == '~';
}

fn urlEncodeComponent(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    for (s) |c| {
        if (isUnreserved(c)) {
            try out.writer.writeByte(c);
        } else {
            try out.writer.print("%{X:0>2}", .{c});
        }
    }
    return alloc.dupe(u8, out.written());
}

// ---------------------------------------------------------------------------
// Arg helpers
// ---------------------------------------------------------------------------

fn getStr(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
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

fn jStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return switch (f) {
        .string => |s| s,
        else => null,
    };
}

fn jObj(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    if (f != .object) return null;
    return f;
}

fn jsonValueToString(alloc: std.mem.Allocator, v: std.json.Value) ![]u8 {
    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    try std.json.Stringify.value(v, .{ .whitespace = .indent_2 }, &sw.writer);
    return alloc.dupe(u8, sw.written());
}

// ---------------------------------------------------------------------------
// pkg_npm
// ---------------------------------------------------------------------------

fn handleNpm(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const name = getStr(args, "name") orelse return .{ .text = "error: name required", .is_error = true };
    const enc_name = try urlEncodeComponent(alloc, name);
    var url_buf: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://registry.npmjs.org/{s}", .{enc_name});

    const resp = httpsGet(alloc, io, url) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "pkg_npm failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    if (resp.status == 404) return .{ .text = "(not found on npm)" };
    if (resp.status != 200) return .{ .text = try std.fmt.allocPrint(alloc, "npm HTTP {d}", .{resp.status}), .is_error = true };

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{}) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "json parse: {s}", .{@errorName(err)}), .is_error = true };
    };
    defer parsed.deinit();

    const root = parsed.value;
    // Build output JSON.
    var out_obj: std.json.ObjectMap = .{};
    defer out_obj.deinit(alloc);

    try out_obj.put(alloc, "name", root.object.get("name") orelse .null);

    var latest_str: []const u8 = "";
    if (root.object.get("dist-tags")) |dt| {
        try out_obj.put(alloc, "dist_tags", dt);
        if (dt == .object) {
            if (dt.object.get("latest")) |latest_v| {
                try out_obj.put(alloc, "latest", latest_v);
                if (latest_v == .string) latest_str = latest_v.string;
            }
        }
    }

    try out_obj.put(alloc, "description", root.object.get("description") orelse .null);
    try out_obj.put(alloc, "homepage", root.object.get("homepage") orelse .null);

    // Find latest version object for license/deprecated.
    if (root.object.get("versions")) |versions| {
        if (versions == .object and latest_str.len > 0) {
            if (versions.object.get(latest_str)) |lv| {
                if (lv == .object) {
                    if (lv.object.get("license")) |li| try out_obj.put(alloc, "license", li);
                    if (lv.object.get("deprecated")) |dep| try out_obj.put(alloc, "deprecated", dep);
                }
            }
        }
    }

    if (jObj(root, "repository")) |rv| {
        if (rv.object.get("url")) |u| try out_obj.put(alloc, "repository", u);
    }
    if (jObj(root, "bugs")) |bv| {
        if (bv.object.get("url")) |u| try out_obj.put(alloc, "bugs", u);
    }

    // Recent versions (last 15 in declaration order). std.json.ObjectMap is an
    // insertion-ordered ArrayHashMap so iteration order is registry order.
    var recent_arr: std.json.Array = .init(alloc);
    defer recent_arr.deinit();
    if (root.object.get("versions")) |versions| {
        if (versions == .object) {
            const keys = versions.object.keys();
            const take_from: usize = if (keys.len > 15) keys.len - 15 else 0;
            // npm orders ascending; we want most recent first → iterate from end.
            var idx: usize = keys.len;
            var collected: usize = 0;
            while (idx > take_from and collected < 15) {
                idx -= 1;
                try recent_arr.append(.{ .string = keys[idx] });
                collected += 1;
            }
        }
    }
    try out_obj.put(alloc, "recent_versions", .{ .array = recent_arr });

    if (jObj(root, "time")) |tv| {
        if (tv.object.get("modified")) |modv| try out_obj.put(alloc, "time_modified", modv);
    }

    const final_text = try jsonValueToString(alloc, .{ .object = out_obj });
    return .{ .text = final_text };
}

// ---------------------------------------------------------------------------
// pkg_pypi
// ---------------------------------------------------------------------------

fn handlePypi(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const name = getStr(args, "name") orelse return .{ .text = "error: name required", .is_error = true };
    const enc_name = try urlEncodeComponent(alloc, name);
    var url_buf: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://pypi.org/pypi/{s}/json", .{enc_name});

    const resp = httpsGet(alloc, io, url) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "pkg_pypi failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    if (resp.status == 404) return .{ .text = "(not found on PyPI)" };
    if (resp.status != 200) return .{ .text = try std.fmt.allocPrint(alloc, "pypi HTTP {d}", .{resp.status}), .is_error = true };

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{}) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "json parse: {s}", .{@errorName(err)}), .is_error = true };
    };
    defer parsed.deinit();

    const root = parsed.value;

    var out_obj: std.json.ObjectMap = .{};
    defer out_obj.deinit(alloc);

    if (jObj(root, "info")) |info| {
        if (info.object.get("name")) |v| try out_obj.put(alloc, "name", v);
        if (info.object.get("version")) |v| try out_obj.put(alloc, "version", v);
        if (info.object.get("summary")) |v| try out_obj.put(alloc, "summary", v);
        if (info.object.get("license")) |v| try out_obj.put(alloc, "license", v);
        if (info.object.get("author")) |v| try out_obj.put(alloc, "author", v);
        if (info.object.get("requires_python")) |v| try out_obj.put(alloc, "requires_python", v);
        if (info.object.get("project_urls")) |v| try out_obj.put(alloc, "project_urls", v);
        if (info.object.get("home_page")) |v| try out_obj.put(alloc, "homepage", v);
        if (info.object.get("yanked")) |v| try out_obj.put(alloc, "yanked", v);
    }

    var recent_arr: std.json.Array = .init(alloc);
    defer recent_arr.deinit();
    if (root.object.get("releases")) |rels| {
        if (rels == .object) {
            const keys = rels.object.keys();
            const take = @min(keys.len, @as(usize, 15));
            const start = if (keys.len > take) keys.len - take else 0;
            for (keys[start..]) |k| {
                try recent_arr.append(.{ .string = k });
            }
        }
    }
    try out_obj.put(alloc, "recent_versions", .{ .array = recent_arr });

    const final_text = try jsonValueToString(alloc, .{ .object = out_obj });
    return .{ .text = final_text };
}

// ---------------------------------------------------------------------------
// pkg_crates
// ---------------------------------------------------------------------------

fn handleCrates(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const name = getStr(args, "name") orelse return .{ .text = "error: name required", .is_error = true };
    const enc_name = try urlEncodeComponent(alloc, name);
    var url_buf: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://crates.io/api/v1/crates/{s}", .{enc_name});

    const resp = httpsGet(alloc, io, url) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "pkg_crates failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    if (resp.status == 404) return .{ .text = "(not found on crates.io)" };
    if (resp.status != 200) return .{ .text = try std.fmt.allocPrint(alloc, "crates HTTP {d}", .{resp.status}), .is_error = true };

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{}) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "json parse: {s}", .{@errorName(err)}), .is_error = true };
    };
    defer parsed.deinit();

    const root = parsed.value;

    var out_obj: std.json.ObjectMap = .{};
    defer out_obj.deinit(alloc);

    if (jObj(root, "crate")) |crate| {
        if (crate.object.get("name")) |v| try out_obj.put(alloc, "name", v);
        if (crate.object.get("max_version")) |v| try out_obj.put(alloc, "max_version", v);
        if (crate.object.get("max_stable_version")) |v| try out_obj.put(alloc, "max_stable_version", v);
        if (crate.object.get("description")) |v| try out_obj.put(alloc, "description", v);
        if (crate.object.get("downloads")) |v| try out_obj.put(alloc, "downloads", v);
        if (crate.object.get("recent_downloads")) |v| try out_obj.put(alloc, "recent_downloads", v);
        if (crate.object.get("homepage")) |v| try out_obj.put(alloc, "homepage", v);
        if (crate.object.get("repository")) |v| try out_obj.put(alloc, "repository", v);
        if (crate.object.get("documentation")) |v| try out_obj.put(alloc, "documentation", v);
        if (crate.object.get("keywords")) |v| try out_obj.put(alloc, "keywords", v);
        if (crate.object.get("categories")) |v| try out_obj.put(alloc, "categories", v);
    }

    var recent_arr: std.json.Array = .init(alloc);
    defer recent_arr.deinit();
    if (root.object.get("versions")) |versions| {
        if (versions == .array) {
            const items = versions.array.items;
            const take = @min(items.len, @as(usize, 15));
            for (items[0..take]) |it| {
                if (it != .object) continue;
                var v_obj: std.json.ObjectMap = .{};
                if (it.object.get("num")) |v| try v_obj.put(alloc, "num", v);
                if (it.object.get("downloads")) |v| try v_obj.put(alloc, "downloads", v);
                if (it.object.get("created_at")) |v| try v_obj.put(alloc, "created_at", v);
                if (it.object.get("yanked")) |v| try v_obj.put(alloc, "yanked", v);
                if (it.object.get("license")) |v| try v_obj.put(alloc, "license", v);
                try recent_arr.append(.{ .object = v_obj });
            }
        }
    }
    try out_obj.put(alloc, "recent_versions", .{ .array = recent_arr });

    const final_text = try jsonValueToString(alloc, .{ .object = out_obj });
    return .{ .text = final_text };
}

// ---------------------------------------------------------------------------
// pkg_search
// ---------------------------------------------------------------------------

fn handleSearch(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const query = getStr(args, "query") orelse return .{ .text = "error: query required", .is_error = true };
    const limit = @max(1, @min(@as(i64, 50), getInt(args, "limit", DEFAULT_SEARCH_LIMIT)));
    const enc_q = try urlEncodeComponent(alloc, query);

    var out_obj: std.json.ObjectMap = .{};
    defer out_obj.deinit(alloc);

    // npm
    {
        var url_buf: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "https://registry.npmjs.org/-/v1/search?text={s}&size={d}", .{ enc_q, limit });
        const r = httpsGet(alloc, io, url) catch |err| blk: {
            const e = try std.fmt.allocPrint(alloc, "(error: {s})", .{@errorName(err)});
            try out_obj.put(alloc, "npm", .{ .string = e });
            break :blk null;
        };
        if (r) |resp| {
            if (resp.status == 200) {
                const parsed = std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{}) catch null;
                if (parsed) |*p| {
                    defer p.deinit();
                    var arr: std.json.Array = .init(alloc);
                    if (p.value.object.get("objects")) |objs| {
                        if (objs == .array) {
                            for (objs.array.items) |o| {
                                if (o != .object) continue;
                                if (o.object.get("package")) |pkg| {
                                    if (pkg != .object) continue;
                                    var row: std.json.ObjectMap = .{};
                                    if (pkg.object.get("name")) |v| try row.put(alloc, "name", v);
                                    if (pkg.object.get("version")) |v| try row.put(alloc, "version", v);
                                    if (pkg.object.get("description")) |v| try row.put(alloc, "description", v);
                                    if (o.object.get("score")) |sc| {
                                        if (sc == .object) {
                                            if (sc.object.get("final")) |fv| try row.put(alloc, "score", fv);
                                        }
                                    }
                                    try arr.append(.{ .object = row });
                                }
                            }
                        }
                    }
                    try out_obj.put(alloc, "npm", .{ .array = arr });
                } else {
                    try out_obj.put(alloc, "npm", .{ .string = "(npm json parse failed)" });
                }
            } else {
                try out_obj.put(alloc, "npm", .{ .string = try std.fmt.allocPrint(alloc, "(HTTP {d})", .{resp.status}) });
            }
        }
    }

    // crates.io
    {
        var url_buf: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "https://crates.io/api/v1/crates?q={s}&per_page={d}", .{ enc_q, limit });
        const r = httpsGet(alloc, io, url) catch |err| blk: {
            const e = try std.fmt.allocPrint(alloc, "(error: {s})", .{@errorName(err)});
            try out_obj.put(alloc, "crates", .{ .string = e });
            break :blk null;
        };
        if (r) |resp| {
            if (resp.status == 200) {
                const parsed = std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{}) catch null;
                if (parsed) |*p| {
                    defer p.deinit();
                    var arr: std.json.Array = .init(alloc);
                    if (p.value.object.get("crates")) |cs| {
                        if (cs == .array) {
                            for (cs.array.items) |c| {
                                if (c != .object) continue;
                                var row: std.json.ObjectMap = .{};
                                if (c.object.get("name")) |v| try row.put(alloc, "name", v);
                                if (c.object.get("max_version")) |v| try row.put(alloc, "max_version", v);
                                if (c.object.get("description")) |v| try row.put(alloc, "description", v);
                                if (c.object.get("downloads")) |v| try row.put(alloc, "downloads", v);
                                try arr.append(.{ .object = row });
                            }
                        }
                    }
                    try out_obj.put(alloc, "crates", .{ .array = arr });
                } else {
                    try out_obj.put(alloc, "crates", .{ .string = "(crates json parse failed)" });
                }
            } else {
                try out_obj.put(alloc, "crates", .{ .string = try std.fmt.allocPrint(alloc, "(HTTP {d})", .{resp.status}) });
            }
        }
    }

    try out_obj.put(alloc, "pypi", .{ .string = "(no JSON search API)" });

    return .{ .text = try jsonValueToString(alloc, .{ .object = out_obj }) };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "urlEncodeComponent handles @scope/name" {
    const alloc = std.testing.allocator;
    const e = try urlEncodeComponent(alloc, "@modelcontextprotocol/sdk");
    defer alloc.free(e);
    try std.testing.expectEqualStrings("%40modelcontextprotocol%2Fsdk", e);
}

test "urlEncodeComponent passes unreserved bytes" {
    const alloc = std.testing.allocator;
    const e = try urlEncodeComponent(alloc, "tokio-util");
    defer alloc.free(e);
    try std.testing.expectEqualStrings("tokio-util", e);
}

test "getInt and getStr fallbacks" {
    const alloc = std.testing.allocator;
    var p = try std.json.parseFromSlice(std.json.Value, alloc, "{\"limit\":5,\"name\":\"x\"}", .{});
    defer p.deinit();
    try std.testing.expectEqual(@as(i64, 5), getInt(p.value, "limit", 10));
    try std.testing.expectEqual(@as(i64, 99), getInt(p.value, "missing", 99));
    try std.testing.expectEqualStrings("x", getStr(p.value, "name").?);
    try std.testing.expect(getStr(p.value, "missing") == null);
}
