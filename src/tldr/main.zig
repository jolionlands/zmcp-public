//! zmcp-tldr — drop-in replacement for the Node `tldr` extension.
//! Fetches tldr-pages from raw.githubusercontent.com, builds an in-process
//! index from the GitHub Tree API.
//!
//! Tools:
//!   tldr_get(command, platform?)
//!   tldr_search(query, max?)

const std = @import("std");
const mcp = @import("mcp");

const UA_PRODUCT = "zmcp-tldr/0.1.0";
const RAW = "https://raw.githubusercontent.com/tldr-pages/tldr/main/pages";
const TREE = "https://api.github.com/repos/tldr-pages/tldr/git/trees/main?recursive=1";

const PLATFORMS_ORDER = [_][]const u8{
    "common", "linux", "osx", "windows", "android", "freebsd", "netbsd", "openbsd", "sunos",
};

// 1h TTL — page set changes maybe weekly upstream.
const INDEX_TTL_MS: i64 = 60 * 60 * 1000;

// In-process cache, lazily populated on first call. The cache outlives any
// single tool call; we use the process-wide smp_allocator for it.
fn cacheAllocator() std.mem.Allocator {
    return std.heap.smp_allocator;
}
var index_arena: ?std.heap.ArenaAllocator = null;
var index_cmds: ?std.StringHashMap(PlatformSet) = null;
var index_loaded_ms: i64 = 0;

const PlatformSet = struct {
    /// Up to 9 platforms (PLATFORMS_ORDER size).
    bits: u16 = 0,
};

fn platformBit(name: []const u8) ?u16 {
    for (PLATFORMS_ORDER, 0..) |p, i| {
        if (std.mem.eql(u8, name, p)) return @as(u16, 1) << @intCast(i);
    }
    return null;
}

fn platformsFromSet(set: PlatformSet) []const []const u8 {
    var buf: [9][]const u8 = undefined;
    var n: usize = 0;
    for (PLATFORMS_ORDER, 0..) |p, i| {
        const bit = @as(u16, 1) << @intCast(i);
        if (set.bits & bit != 0) {
            buf[n] = p;
            n += 1;
        }
    }
    return buf[0..n];
}

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    const io = init.io;
    try mcp.run(arena, io, .{ .name = "zmcp-tldr", .version = "0.1.0" }, &tool_table);
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "tldr_get",
        .description = "Fetch the full tldr cheatsheet for a command from tldr-pages. Auto-picks the best platform (common > linux > osx > windows > ...) unless `platform` is given.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "command":  { "type": "string", "description": "Command name, e.g. 'curl', 'git-rebase', 'jq'." },
        \\    "platform": { "type": "string", "description": "Optional: common|linux|osx|windows|android|freebsd|netbsd|openbsd|sunos. Falls back to the first available." }
        \\  },
        \\  "required": ["command"]
        \\}
        ,
        .handler = handleGet,
        .read_only = true,
    },
    .{
        .name = "tldr_search",
        .description = "Search the tldr-pages index for commands whose name matches the query (exact > prefix > substring).",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "query": { "type": "string", "description": "Search query (case-insensitive substring)." },
        \\    "max":   { "type": "integer", "description": "Maximum hits to return (default 20)." }
        \\  },
        \\  "required": ["query"]
        \\}
        ,
        .handler = handleSearch,
        .read_only = true,
    },
};

// ---------------------------------------------------------------------------
// HTTPS helper
// ---------------------------------------------------------------------------

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

    var decompress_buf: [256 * 1024]u8 = undefined;

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

fn isValidCommand(s: []const u8) bool {
    if (s.len == 0 or s.len > 128) return false;
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '+')) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Index loading
// ---------------------------------------------------------------------------

fn nowMs(io: std.Io) i64 {
    const ts = std.Io.Timestamp.now(io, .real);
    return ts.toMilliseconds();
}

fn ensureIndex(io: std.Io) !void {
    const now = nowMs(io);
    if (index_cmds) |_| {
        if (now - index_loaded_ms < INDEX_TTL_MS) return;
        // Expired — free and rebuild.
        if (index_arena) |*a| a.deinit();
        index_arena = null;
        index_cmds = null;
    }

    var arena = std.heap.ArenaAllocator.init(cacheAllocator());
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    // Use a transient allocator for the HTTP body, then copy strings we want
    // to keep into the arena.
    var temp_arena = std.heap.ArenaAllocator.init(cacheAllocator());
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();

    const resp = try httpsGet(ta, io, TREE);
    if (resp.status != 200) return error.TreeFetchFailed;

    const parsed = try std.json.parseFromSlice(std.json.Value, ta, resp.body, .{});
    defer parsed.deinit();

    const root = parsed.value;
    const tree_v = if (root == .object) root.object.get("tree") orelse .null else .null;
    if (tree_v != .array) return error.UnexpectedTreeShape;

    var map = std.StringHashMap(PlatformSet).init(cacheAllocator());
    errdefer map.deinit();

    for (tree_v.array.items) |entry| {
        if (entry != .object) continue;
        const type_v = entry.object.get("type") orelse continue;
        if (type_v != .string or !std.mem.eql(u8, type_v.string, "blob")) continue;
        const path_v = entry.object.get("path") orelse continue;
        if (path_v != .string) continue;
        const path = path_v.string;

        // Expect pages/<platform>/<cmd>.md
        if (!std.mem.startsWith(u8, path, "pages/")) continue;
        if (!std.mem.endsWith(u8, path, ".md")) continue;
        const rest = path[6 .. path.len - 3]; // strip "pages/" + ".md"
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse continue;
        const platform = rest[0..slash];
        const cmd = rest[slash + 1 ..];
        // cmd must not contain another slash (single-level layout).
        if (std.mem.indexOfScalar(u8, cmd, '/') != null) continue;

        const bit = platformBit(platform) orelse continue;
        const cmd_owned = try arena_alloc.dupe(u8, cmd);
        const gop = try map.getOrPut(cmd_owned);
        if (gop.found_existing) {
            gop.value_ptr.bits |= bit;
        } else {
            gop.value_ptr.* = .{ .bits = bit };
        }
    }

    index_arena = arena;
    index_cmds = map;
    index_loaded_ms = now;
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

fn handleGet(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const command = getStr(args, "command") orelse return .{ .text = "error: command required", .is_error = true };
    if (!isValidCommand(command)) return .{ .text = "error: command contains invalid chars", .is_error = true };
    const requested_platform = getStr(args, "platform");

    ensureIndex(io) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "tldr index load failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    const map = index_cmds.?;

    const entry = map.get(command) orelse {
        return .{ .text = try std.fmt.allocPrint(alloc, "unknown command: {s}", .{command}), .is_error = true };
    };

    // Pick platform.
    var chosen: []const u8 = "";
    if (requested_platform) |rp| {
        if (platformBit(rp)) |b| {
            if (entry.bits & b != 0) chosen = rp;
        }
    }
    if (chosen.len == 0) {
        for (PLATFORMS_ORDER, 0..) |p, i| {
            const bit = @as(u16, 1) << @intCast(i);
            if (entry.bits & bit != 0) {
                chosen = p;
                break;
            }
        }
    }
    if (chosen.len == 0) return .{ .text = try std.fmt.allocPrint(alloc, "no platform for {s}", .{command}), .is_error = true };

    var url_buf: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "{s}/{s}/{s}.md", .{ RAW, chosen, command });

    const resp = httpsGet(alloc, io, url) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "page fetch failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    if (resp.status != 200) return .{ .text = try std.fmt.allocPrint(alloc, "page http {d} ({s})", .{ resp.status, url }), .is_error = true };

    // Build "available platforms" string.
    var avail_buf: std.Io.Writer.Allocating = .init(alloc);
    defer avail_buf.deinit();
    var first = true;
    for (PLATFORMS_ORDER, 0..) |p, i| {
        const bit = @as(u16, 1) << @intCast(i);
        if (entry.bits & bit != 0) {
            if (!first) try avail_buf.writer.writeAll(", ");
            try avail_buf.writer.writeAll(p);
            first = false;
        }
    }

    return .{
        .text = try std.fmt.allocPrint(
            alloc,
            "# tldr {s} ({s})\nsource: {s}\navailable platforms: {s}\n\n{s}\n\n{s}",
            .{ command, chosen, url, avail_buf.written(), std.mem.trimEnd(u8, resp.body, "\n"), ATTRIBUTION },
        ),
    };
}

/// tldr-pages content is CC BY 4.0; every page result ends with this credit.
const ATTRIBUTION = "tldr-pages, CC BY 4.0";

fn handleSearch(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const query = getStr(args, "query") orelse return .{ .text = "error: query required", .is_error = true };
    if (query.len == 0) return .{ .text = "error: query required", .is_error = true };
    const max_raw = getInt(args, "max", 20);
    const max: usize = @intCast(@max(1, @min(@as(i64, 200), max_raw)));

    ensureIndex(io) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "tldr index load failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    const map = index_cmds.?;

    var query_lower_buf: [128]u8 = undefined;
    if (query.len > query_lower_buf.len) return .{ .text = "error: query too long", .is_error = true };
    for (query, 0..) |c, i| query_lower_buf[i] = std.ascii.toLower(c);
    const q = query_lower_buf[0..query.len];

    const Hit = struct { name: []const u8, set: PlatformSet, score: i32 };
    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(alloc);

    var it = map.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        const name_lower_buf = alloc.alloc(u8, name.len) catch continue;
        defer alloc.free(name_lower_buf);
        for (name, 0..) |c, i| name_lower_buf[i] = std.ascii.toLower(c);
        const nl = name_lower_buf;

        var score: i32 = -1;
        if (std.mem.eql(u8, nl, q)) {
            score = 1000;
        } else if (std.mem.startsWith(u8, nl, q)) {
            score = 500 - @as(i32, @intCast(name.len - q.len));
        } else if (std.mem.indexOf(u8, nl, q)) |idx| {
            score = 100 - @as(i32, @intCast(idx));
        }
        if (score >= 0) {
            try hits.append(alloc, .{ .name = name, .set = e.value_ptr.*, .score = score });
        }
    }

    std.mem.sort(Hit, hits.items, {}, struct {
        fn lt(_: void, a: Hit, b: Hit) bool {
            if (a.score != b.score) return a.score > b.score;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);

    const take = @min(hits.items.len, max);
    if (take == 0) return .{ .text = try std.fmt.allocPrint(alloc, "no tldr hits for: {s}", .{query}) };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("{d} tldr hits for {s}:\n", .{ take, query });
    for (hits.items[0..take]) |h| {
        try out.writer.print("{s}\t[", .{h.name});
        var first = true;
        for (PLATFORMS_ORDER, 0..) |p, i| {
            const bit = @as(u16, 1) << @intCast(i);
            if (h.set.bits & bit != 0) {
                if (!first) try out.writer.writeByte(',');
                try out.writer.writeAll(p);
                first = false;
            }
        }
        try out.writer.writeAll("]\n");
    }

    return .{ .text = try alloc.dupe(u8, out.written()) };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "page results end with the tldr-pages credit" {
    try std.testing.expectEqualStrings("tldr-pages, CC BY 4.0", ATTRIBUTION);
}

test "isValidCommand" {
    try std.testing.expect(isValidCommand("jq"));
    try std.testing.expect(isValidCommand("git-rebase"));
    try std.testing.expect(isValidCommand("python3.11"));
    try std.testing.expect(!isValidCommand(""));
    try std.testing.expect(!isValidCommand("rm -rf /"));
    try std.testing.expect(!isValidCommand("../etc/passwd"));
}

test "platformBit roundtrip" {
    try std.testing.expectEqual(@as(?u16, 1), platformBit("common"));
    try std.testing.expectEqual(@as(?u16, 2), platformBit("linux"));
    try std.testing.expect(platformBit("BadPlatform") == null);
}
