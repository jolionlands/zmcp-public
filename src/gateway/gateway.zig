//! The gateway proper: the exposed tool view, its search index, the child
//! pool, and the MCP-facing behaviour (tools_search / tool_schema /
//! tool_call in lazy mode, routed real tools in direct mode).

const std = @import("std");
const Io = std.Io;
const mcp = @import("mcp");
const catalog = @import("catalog.zig");
const profile = @import("profile.zig");
const view_mod = @import("view.zig");
const index_mod = @import("index.zig");
const pool_mod = @import("pool.zig");
const taxonomy = @import("taxonomy.zig");

pub const Expose = enum {
    lazy,
    direct,

    pub fn parse(text: ?[]const u8) Expose {
        const t = std.mem.trim(u8, text orelse return .lazy, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(t, "direct")) return .direct;
        return .lazy;
    }
};

pub const Gateway = struct {
    gpa: std.mem.Allocator,
    cat: *const catalog.Catalog,
    view: view_mod.View,
    index: index_mod.Index,
    pool: pool_mod.Pool,
    /// Guards `pool` (and so serializes every call through the gateway).
    mutex: Io.Mutex = .init,
    /// Profile name, or "" for an ad-hoc/all-servers slice.
    label: []const u8,
    call_timeout_ms: u64,
    readonly: bool = false,

    /// `cat` must outlive the gateway. `servers` are already resolved.
    pub fn init(
        gpa: std.mem.Allocator,
        cat: *const catalog.Catalog,
        servers: []const []const u8,
        slice: profile.Slice,
        label: []const u8,
        spawner: pool_mod.Spawner,
        clock: pool_mod.Clock,
        popts: pool_mod.Options,
    ) !*Gateway {
        const gw = try gpa.create(Gateway);
        errdefer gpa.destroy(gw);
        var v = try view_mod.View.build(gpa, cat, servers, slice);
        errdefer v.deinit();
        var ix = try index_mod.Index.build(gpa, &v);
        errdefer ix.deinit();
        gw.* = .{
            .gpa = gpa,
            .cat = cat,
            .view = v,
            .index = ix,
            .pool = pool_mod.Pool.init(gpa, spawner, clock, popts),
            .label = label,
            .call_timeout_ms = popts.call_timeout_ms,
            .readonly = slice.readonly,
        };
        return gw;
    }

    pub fn deinit(self: *Gateway, io: Io) void {
        self.pool.deinit(io);
        self.index.deinit();
        self.view.deinit();
        self.gpa.destroy(self);
    }

    /// Close every child (gateway exit, stdin EOF).
    pub fn shutdown(self: *Gateway, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.pool.shutdown(io);
    }

    /// Reap idle children (called by the timer thread).
    pub fn reapTick(self: *Gateway, io: Io) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.pool.reapIdle(io);
    }

    // -----------------------------------------------------------------
    // tools_search
    // -----------------------------------------------------------------

    pub fn toolSearch(self: *Gateway, arena: std.mem.Allocator, args: std.json.Value) !mcp.ToolResult {
        if (self.view.exposed.len == 0) {
            // An empty slice is reported, not failed: most tools are not yet
            // marked read-only, so a readonly profile can legitimately be empty.
            const why = if (self.readonly and self.view.read_only_marked == 0)
                "none of them is marked read-only (annotations.readOnlyHint), which a readonly profile requires"
            else
                "the profile's rules (tools_allow, tools_deny, readonly) hide all of them";
            return .{ .text = try std.fmt.allocPrint(arena, "this slice exposes no tools: {d} tools in {d} servers, but {s}", .{ self.view.total_before_slice, self.view.servers.len, why }) };
        }
        var q: index_mod.Query = .{};
        if (args == .object) {
            if (args.object.get("query")) |v| switch (v) {
                .string => |s| q.text = s,
                .null => {},
                else => return errResult(arena, "query must be a string", .{}),
            };
            if (args.object.get("server")) |v| switch (v) {
                .string => |s| {
                    if (s.len > 0) q.server = s;
                },
                .null => {},
                else => return errResult(arena, "server must be a string", .{}),
            };
            if (args.object.get("category")) |v| switch (v) {
                .string => |s| if (s.len > 0) {
                    q.category = taxonomy.Category.parse(s) orelse
                        return errResult(arena, "unknown category '{s}'; categories: {s}", .{ s, try categoryList(arena) });
                },
                .null => {},
                else => return errResult(arena, "category must be a string", .{}),
            };
            if (args.object.get("read_only")) |v| switch (v) {
                .bool => |b| q.read_only = b,
                .null => {},
                else => return errResult(arena, "read_only must be true or false", .{}),
            };
            if (args.object.get("limit")) |v| switch (v) {
                .integer => |n| q.limit = if (n < 1) 1 else @min(@as(usize, @intCast(n)), 50),
                .null => {},
                else => return errResult(arena, "limit must be an integer", .{}),
            };
        } else if (args != .null) return errResult(arena, "arguments must be an object", .{});

        if (q.server) |s| {
            var known = false;
            for (self.view.servers) |x| {
                if (std.ascii.eqlIgnoreCase(x, s)) known = true;
            }
            if (!known) return errResult(arena, "server '{s}' is not in this slice; servers: {s}", .{ s, try joinNames(arena, self.view.servers) });
        }

        const no_filters = q.server == null and q.category == null and q.read_only == null;
        if (std.mem.trim(u8, q.text, " \t\r\n").len == 0 and no_filters) {
            return .{ .text = try self.index.renderOverview(arena, self.label) };
        }
        const hits = try self.index.search(arena, q);
        if (hits.len == 0) return .{ .text = try self.index.renderNoMatch(arena, q) };
        return .{ .text = try self.index.renderHits(arena, hits, q) };
    }

    // -----------------------------------------------------------------
    // tool_schema
    // -----------------------------------------------------------------

    pub fn toolSchema(self: *Gateway, arena: std.mem.Allocator, args: std.json.Value) !mcp.ToolResult {
        if (args != .object) return errResult(arena, "arguments must be an object with name or names", .{});
        var wanted: std.ArrayList([]const u8) = .empty;
        if (args.object.get("name")) |n| {
            if (n != .string) return errResult(arena, "name must be a string", .{});
            var it = std.mem.tokenizeAny(u8, n.string, ", \t\r\n");
            while (it.next()) |tok| try wanted.append(arena, tok);
        }
        if (args.object.get("names")) |ns| {
            if (ns != .array) return errResult(arena, "names must be an array of strings", .{});
            for (ns.array.items) |item| {
                if (item != .string) return errResult(arena, "names must be an array of strings", .{});
                try wanted.append(arena, item.string);
            }
        }
        if (wanted.items.len == 0) return errResult(arena, "provide name (or names): the tool(s) to describe", .{});
        if (wanted.items.len > 20) return errResult(arena, "at most 20 names per call", .{});

        var aw: Io.Writer.Allocating = .init(arena);
        var js = std.json.Stringify{ .writer = &aw.writer };
        var errors: std.ArrayList(struct { name: []const u8, msg: []const u8 }) = .empty;
        var found: usize = 0;
        try js.beginObject();
        try js.objectField("tools");
        try js.beginArray();
        for (wanted.items) |name| {
            switch (self.view.lookup(name)) {
                .found => |i| {
                    const e = self.view.exposed[i];
                    found += 1;
                    try js.beginObject();
                    try js.objectField("name");
                    try js.write(e.name);
                    try js.objectField("server");
                    try js.write(e.server);
                    try js.objectField("description");
                    try js.write(mcp.firstSentence(e.tool.description, mcp.TOOL_DESC_CAP));
                    try js.objectField("inputSchema");
                    try js.beginWriteRaw();
                    try aw.writer.writeAll(if (e.tool.schema.len == 0) "{}" else e.tool.schema);
                    js.endWriteRaw();
                    if (e.tool.read_only) {
                        try js.objectField("readOnly");
                        try js.write(true);
                    }
                    if (e.tool.destructive) {
                        try js.objectField("destructive");
                        try js.write(true);
                    }
                    try js.endObject();
                },
                .ambiguous => |idx| {
                    try errors.append(arena, .{ .name = name, .msg = try ambiguousMessage(arena, self.view.exposed, idx) });
                },
                .hidden => |h| try errors.append(arena, .{ .name = name, .msg = try std.fmt.allocPrint(arena, "disabled: {s}", .{h.reason.message()}) }),
                .missing => try errors.append(arena, .{ .name = name, .msg = "unknown tool; use tools_search" }),
            }
        }
        try js.endArray();
        if (errors.items.len > 0) {
            try js.objectField("errors");
            try js.beginArray();
            for (errors.items) |e| {
                try js.beginObject();
                try js.objectField("name");
                try js.write(e.name);
                try js.objectField("error");
                try js.write(e.msg);
                try js.endObject();
            }
            try js.endArray();
        }
        try js.endObject();
        return .{ .text = aw.written(), .is_error = found == 0 };
    }

    // -----------------------------------------------------------------
    // tool_call / routed call
    // -----------------------------------------------------------------

    pub fn toolCall(self: *Gateway, arena: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
        if (args != .object) return errResult(arena, "arguments must be an object with name and arguments", .{});
        const n = args.object.get("name") orelse return errResult(arena, "missing name", .{});
        if (n != .string) return errResult(arena, "name must be a string", .{});
        var inner: std.json.Value = args.object.get("arguments") orelse .null;
        if (inner == .string) {
            inner = std.json.parseFromSliceLeaky(std.json.Value, arena, inner.string, .{}) catch
                return errResult(arena, "arguments is a string that is not valid JSON", .{});
        }
        return self.callByName(arena, io, n.string, inner);
    }

    pub fn callByName(self: *Gateway, arena: std.mem.Allocator, io: Io, name: []const u8, args: std.json.Value) !mcp.ToolResult {
        if (isMetaName(name)) return errResult(arena, "'{s}' is a meta tool; call it directly", .{name});
        switch (self.view.lookup(name)) {
            .found => |i| return self.callExposed(arena, io, self.view.exposed[i], args),
            .ambiguous => |idx| return .{ .text = try ambiguousMessage(arena, self.view.exposed, idx), .is_error = true },
            .hidden => |h| return errResult(arena, "tool '{s}' is disabled: {s}", .{ name, h.reason.message() }),
            .missing => return errResult(arena, "unknown tool '{s}'; use tools_search to find tool names", .{name}),
        }
    }

    fn callExposed(self: *Gateway, arena: std.mem.Allocator, io: Io, e: view_mod.Exposed, args: std.json.Value) !mcp.ToolResult {
        if (args != .object and args != .null) return errResult(arena, "arguments must be an object", .{});
        var aw: Io.Writer.Allocating = .init(arena);
        var js = std.json.Stringify{ .writer = &aw.writer };
        try js.beginObject();
        try js.objectField("name");
        try js.write(e.tool.name);
        try js.objectField("arguments");
        if (args == .null) {
            try js.beginObject();
            try js.endObject();
        } else try js.write(args);
        try js.endObject();

        self.mutex.lockUncancelable(io);
        const resp = self.pool.request(io, arena, e.server, "tools/call", aw.written());
        self.mutex.unlock(io);

        const line = resp catch |err| return self.requestFailure(arena, e.server, err);
        return convertResponse(arena, line);
    }

    fn requestFailure(self: *Gateway, arena: std.mem.Allocator, server: []const u8, err: pool_mod.RequestError) !mcp.ToolResult {
        return switch (err) {
            error.Timeout => errResult(arena, "server '{s}' did not answer within {d}s; it was stopped and restarts on the next call", .{ server, self.call_timeout_ms / 1000 }),
            error.ChildExited, error.ChildFailed => errResult(arena, "server '{s}' exited during the call; it restarts on the next call", .{server}),
            error.WriteFailed => errResult(arena, "server '{s}' is not responding (could not send the request)", .{server}),
            error.ResponseTooLarge => errResult(arena, "server '{s}' returned a response that is too large; it was stopped", .{server}),
            error.NotFound => errResult(arena, "server binary zmcp-{s} not found (looked next to the gateway and on PATH)", .{server}),
            error.SpawnFailed, error.HandshakeFailed => errResult(arena, "could not start server '{s}'", .{server}),
            error.OutOfMemory => error.OutOfMemory,
        };
    }
};

fn errResult(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !mcp.ToolResult {
    return .{ .text = try std.fmt.allocPrint(arena, fmt, args), .is_error = true };
}

fn joinNames(a: std.mem.Allocator, names: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (names, 0..) |n, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, n);
    }
    return out.items;
}

fn categoryList(a: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (taxonomy.all_categories, 0..) |c, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, c.text());
    }
    return out.items;
}

fn ambiguousMessage(a: std.mem.Allocator, exposed: []const view_mod.Exposed, idx: []const u32) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "tool name exists in several servers; use one of: ");
    for (idx, 0..) |i, k| {
        if (k > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, exposed[i].name);
    }
    return out.items;
}

const META_SEARCH = "tools_search";
const META_SCHEMA = "tool_schema";
const META_CALL = "tool_call";

fn isMetaName(name: []const u8) bool {
    return std.mem.eql(u8, name, META_SEARCH) or std.mem.eql(u8, name, META_SCHEMA) or std.mem.eql(u8, name, META_CALL);
}

// ---------------------------------------------------------------------------
// Child response -> ToolResult
// ---------------------------------------------------------------------------

/// Turn a child's `tools/call` response line into a ToolResult: text items
/// joined by newlines, the first image passed through, isError preserved,
/// JSON-RPC errors reported as error results. All strings live in `arena`.
pub fn convertResponse(arena: std.mem.Allocator, line: []const u8) !mcp.ToolResult {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch
        return errResult(arena, "invalid JSON from server", .{});
    if (root != .object) return errResult(arena, "invalid response from server", .{});
    if (root.object.get("error")) |e| {
        var msg: []const u8 = "unknown error";
        var code: i64 = 0;
        if (e == .object) {
            if (e.object.get("message")) |m| if (m == .string) {
                msg = m.string;
            };
            if (e.object.get("data")) |d| if (d == .string) {
                msg = try std.fmt.allocPrint(arena, "{s}: {s}", .{ msg, d.string });
            };
            if (e.object.get("code")) |c| if (c == .integer) {
                code = c.integer;
            };
        }
        return errResult(arena, "server error {d}: {s}", .{ code, msg });
    }
    const result = root.object.get("result") orelse return errResult(arena, "response has no result", .{});
    if (result != .object) return errResult(arena, "invalid result from server", .{});
    const is_error = if (result.object.get("isError")) |v| (v == .bool and v.bool) else false;

    var text: std.ArrayList(u8) = .empty;
    var image: ?mcp.Image = null;
    var extra_images: usize = 0;
    if (result.object.get("content")) |c| {
        if (c == .array) for (c.array.items) |item| {
            if (item != .object) continue;
            const ty = if (item.object.get("type")) |t| (if (t == .string) t.string else "") else "";
            if (std.mem.eql(u8, ty, "text")) {
                if (item.object.get("text")) |t| if (t == .string) {
                    if (text.items.len > 0) try text.append(arena, '\n');
                    try text.appendSlice(arena, t.string);
                };
            } else if (std.mem.eql(u8, ty, "image")) {
                const data = item.object.get("data");
                const mime = item.object.get("mimeType");
                if (data != null and mime != null and data.? == .string and mime.? == .string) {
                    if (image == null) image = .{ .data_base64 = data.?.string, .mime_type = mime.?.string } else extra_images += 1;
                }
            } else {
                if (text.items.len > 0) try text.append(arena, '\n');
                try text.print(arena, "[{s} content omitted]", .{if (ty.len > 0) ty else "unknown"});
            }
        };
    }
    if (extra_images > 0) {
        if (text.items.len > 0) try text.append(arena, '\n');
        try text.print(arena, "[{d} more image(s) omitted]", .{extra_images});
    }
    return .{ .text = text.items, .is_error = is_error, .image = image };
}

// ---------------------------------------------------------------------------
// MCP tool tables
// ---------------------------------------------------------------------------

/// The one live gateway. mcp.ToolDef handlers carry no context pointer, so
/// the lazy meta tools reach the gateway through this (set once in main
/// before serving, never changed while serving).
var g_gateway: ?*Gateway = null;

pub fn setGlobal(gw: ?*Gateway) void {
    g_gateway = gw;
}

fn noGateway(arena: std.mem.Allocator) !mcp.ToolResult {
    return errResult(arena, "gateway is not initialized", .{});
}

fn handleSearch(arena: std.mem.Allocator, _: Io, args: std.json.Value) anyerror!mcp.ToolResult {
    const gw = g_gateway orelse return noGateway(arena);
    return gw.toolSearch(arena, args);
}

fn handleSchema(arena: std.mem.Allocator, _: Io, args: std.json.Value) anyerror!mcp.ToolResult {
    const gw = g_gateway orelse return noGateway(arena);
    return gw.toolSchema(arena, args);
}

fn handleCall(arena: std.mem.Allocator, io: Io, args: std.json.Value) anyerror!mcp.ToolResult {
    const gw = g_gateway orelse return noGateway(arena);
    return gw.toolCall(arena, io, args);
}

fn stubHandler(arena: std.mem.Allocator, _: Io, _: std.json.Value) anyerror!mcp.ToolResult {
    return errResult(arena, "direct tool called without the gateway hook", .{});
}

/// `mcp.CallHook` for direct mode: `hook_ctx` is the `*Gateway`.
pub fn directHook(hook_ctx: ?*anyopaque, arena: std.mem.Allocator, io: Io, name: []const u8, args: std.json.Value) anyerror!mcp.ToolResult {
    const gw: *Gateway = @ptrCast(@alignCast(hook_ctx.?));
    return gw.callByName(arena, io, name, args);
}

fn categoryEnumJson(a: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '[');
    for (taxonomy.all_categories, 0..) |c, i| {
        if (i > 0) try out.append(a, ',');
        try out.print(a, "\"{s}\"", .{c.text()});
    }
    try out.append(a, ']');
    return out.items;
}

/// The three lazy-mode tools. Strings are allocated from `a` (kept for the
/// life of the process).
pub fn lazyTools(a: std.mem.Allocator, gw: *const Gateway) ![]const mcp.ToolDef {
    const defs = try a.alloc(mcp.ToolDef, 3);
    defs[0] = .{
        .name = META_SEARCH,
        .description = try std.fmt.allocPrint(a, "Find tools ({d} across {d} servers). No arguments: category overview. query: ranked keyword search; filters category, server, read_only.", .{ gw.view.exposed.len, gw.view.servers.len }),
        .input_schema_json = try std.fmt.allocPrint(a, "{{\"type\":\"object\",\"properties\":{{\"query\":{{\"type\":\"string\"}},\"category\":{{\"type\":\"string\",\"enum\":{s}}},\"server\":{{\"type\":\"string\"}},\"read_only\":{{\"type\":\"boolean\"}},\"limit\":{{\"type\":\"integer\"}}}}}}", .{try categoryEnumJson(a)}),
        .handler = handleSearch,
        .read_only = true,
    };
    defs[1] = .{
        .name = META_SCHEMA,
        .description = "Get the input schema of tools by name (comma-separated or names[]).",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"names\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}}}",
        .handler = handleSchema,
        .read_only = true,
    };
    defs[2] = .{
        .name = META_CALL,
        .description = "Run a tool by name with an arguments object (see tool_schema).",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"arguments\":{\"type\":\"object\"}},\"required\":[\"name\"]}",
        .handler = handleCall,
    };
    return defs;
}

/// The slice's real tools for direct mode (descriptions/schemas from the
/// catalog; mcp renders them compact). Calls go through `directHook`.
pub fn directTools(a: std.mem.Allocator, gw: *const Gateway) ![]const mcp.ToolDef {
    const defs = try a.alloc(mcp.ToolDef, gw.view.exposed.len);
    for (gw.view.exposed, 0..) |e, i| {
        defs[i] = .{
            .name = e.name,
            .description = e.tool.description,
            .input_schema_json = if (e.tool.schema.len == 0) "{}" else e.tool.schema,
            .handler = stubHandler,
            .read_only = e.tool.read_only,
            .destructive = e.tool.destructive,
        };
    }
    return defs;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Fx = struct {
    cat: catalog.Catalog,
    world: pool_mod.FakeWorld,
    gw: *Gateway,

    fn init(alloc: std.mem.Allocator, servers: []const []const u8, slice: profile.Slice) !*Fx {
        const fx = try alloc.create(Fx);
        errdefer alloc.destroy(fx);
        fx.cat = try catalog.parse(alloc, view_mod.test_catalog_text);
        errdefer fx.cat.deinit();
        fx.world = .{ .gpa = alloc, .record = true };
        fx.gw = try Gateway.init(alloc, &fx.cat, servers, slice, "dev", fx.world.spawner(), fx.world.clock(), .{});
        return fx;
    }

    fn deinit(self: *Fx, alloc: std.mem.Allocator) void {
        self.gw.deinit(std.testing.io);
        self.world.reset();
        self.cat.deinit();
        alloc.destroy(self);
    }
};

fn parseArgs(a: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "tools_search: overview with no arguments, ranked query, filters, bad input" {
    const alloc = std.testing.allocator;
    const fx = try Fx.init(alloc, &.{ "git", "docker", "memory" }, .{});
    defer fx.deinit(alloc);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const ov = try fx.gw.toolSearch(a, .null);
    try std.testing.expect(!ov.is_error);
    try std.testing.expect(contains(ov.text, "7 tools in 3 servers of slice dev"));
    try std.testing.expect(contains(ov.text, "vcs (3, 1 ro): git"));
    try std.testing.expect(contains(ov.text, "infra (3, 2 ro): docker"));
    try std.testing.expect(contains(ov.text, "namespaced"));

    const r = try fx.gw.toolSearch(a, try parseArgs(a, "{\"query\":\"containers\",\"category\":\"infra\"}"));
    try std.testing.expect(contains(r.text, "docker_ps [docker/infra, ro] List containers"));
    const r2 = try fx.gw.toolSearch(a, try parseArgs(a, "{\"server\":\"git\",\"read_only\":true}"));
    try std.testing.expect(contains(r2.text, "git.status [git/vcs, ro]"));
    try std.testing.expect(!contains(r2.text, "docker"));

    const bad_cat = try fx.gw.toolSearch(a, try parseArgs(a, "{\"category\":\"nope\"}"));
    try std.testing.expect(bad_cat.is_error and contains(bad_cat.text, "web-search"));
    const bad_srv = try fx.gw.toolSearch(a, try parseArgs(a, "{\"server\":\"redis\"}"));
    try std.testing.expect(bad_srv.is_error and contains(bad_srv.text, "not in this slice"));
    const bad_lim = try fx.gw.toolSearch(a, try parseArgs(a, "{\"limit\":\"x\"}"));
    try std.testing.expect(bad_lim.is_error);
    const none = try fx.gw.toolSearch(a, try parseArgs(a, "{\"query\":\"zzzzqqqq\"}"));
    try std.testing.expect(!none.is_error and contains(none.text, "no tools match"));
    // Searching never spawns anything.
    try std.testing.expectEqual(@as(u32, 0), fx.world.spawns);
}

test "tool_schema returns compact schemas, and reports unknown, hidden and ambiguous names" {
    const alloc = std.testing.allocator;
    const fx = try Fx.init(alloc, &.{ "git", "docker" }, .{ .deny = &.{"git_reset"} });
    defer fx.deinit(alloc);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const r = try fx.gw.toolSchema(a, try parseArgs(a, "{\"name\":\"docker_ps, git_commit\"}"));
    try std.testing.expect(!r.is_error);
    var parsed = try parseArgs(a, r.text);
    try std.testing.expectEqual(@as(usize, 2), parsed.object.get("tools").?.array.items.len);
    try std.testing.expect(contains(r.text, "\"server\":\"docker\""));
    try std.testing.expect(contains(r.text, "\"readOnly\":true"));

    const bad = try fx.gw.toolSchema(a, try parseArgs(a, "{\"names\":[\"git_reset\",\"status\",\"nope\"]}"));
    try std.testing.expect(bad.is_error); // nothing found
    try std.testing.expect(contains(bad.text, "disabled: denied by the profile's tools_deny"));
    try std.testing.expect(contains(bad.text, "git.status, docker.status"));
    try std.testing.expect(contains(bad.text, "unknown tool"));
    try std.testing.expect(!contains(bad.text, "inputSchema"));

    try std.testing.expect((try fx.gw.toolSchema(a, .null)).is_error);
    try std.testing.expect((try fx.gw.toolSchema(a, try parseArgs(a, "{}"))).is_error);
    try std.testing.expectEqual(@as(u32, 0), fx.world.spawns);
}

test "tool_call: lazy spawn, forwards the real tool name and arguments, reuses the child" {
    const alloc = std.testing.allocator;
    const fx = try Fx.init(alloc, &.{ "git", "docker" }, .{});
    defer fx.deinit(alloc);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(u32, 0), fx.world.spawns);

    const r = try fx.gw.toolCall(a, std.testing.io, try parseArgs(a, "{\"name\":\"docker.status\",\"arguments\":{\"verbose\":true}}"));
    try std.testing.expect(!r.is_error);
    try std.testing.expectEqualStrings("child#1", r.text);
    try std.testing.expectEqual(@as(u32, 1), fx.world.spawns);
    // The child sees the bare tool name (not the namespaced one).
    try std.testing.expect(contains(fx.world.last_request.?, "\"params\":{\"name\":\"status\",\"arguments\":{\"verbose\":true}}"));
    try std.testing.expectEqualStrings("docker", fx.world.spawn_log[0]);

    // Arguments as a JSON string, and reuse.
    const r2 = try fx.gw.toolCall(a, std.testing.io, try parseArgs(a, "{\"name\":\"docker_ps\",\"arguments\":\"{\\\"all\\\":true}\"}"));
    try std.testing.expectEqualStrings("child#1", r2.text);
    try std.testing.expect(contains(fx.world.last_request.?, "\"arguments\":{\"all\":true}"));
    try std.testing.expectEqual(@as(u32, 1), fx.world.spawns);
    // Missing arguments become {}.
    _ = try fx.gw.toolCall(a, std.testing.io, try parseArgs(a, "{\"name\":\"docker_ps\"}"));
    try std.testing.expect(contains(fx.world.last_request.?, "\"arguments\":{}"));
}

test "tool_call enforcement: hidden, unknown, ambiguous, meta and bad arguments never reach a child" {
    const alloc = std.testing.allocator;
    const fx = try Fx.init(alloc, &.{ "git", "docker" }, .{ .deny = &.{"git_reset"} });
    defer fx.deinit(alloc);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const cases = [_]struct { args: []const u8, want: []const u8 }{
        .{ .args = "{\"name\":\"git_reset\"}", .want = "disabled: denied by the profile's tools_deny" },
        .{ .args = "{\"name\":\"memory_x\"}", .want = "unknown tool" },
        .{ .args = "{\"name\":\"status\"}", .want = "use one of: git.status, docker.status" },
        .{ .args = "{\"name\":\"tool_call\"}", .want = "meta tool" },
        .{ .args = "{\"name\":\"docker_ps\",\"arguments\":5}", .want = "arguments must be an object" },
        .{ .args = "{\"name\":\"docker_ps\",\"arguments\":\"{oops\"}", .want = "not valid JSON" },
        .{ .args = "{\"arguments\":{}}", .want = "missing name" },
        .{ .args = "{\"name\":3}", .want = "name must be a string" },
    };
    for (cases) |c| {
        const r = try fx.gw.toolCall(a, std.testing.io, try parseArgs(a, c.args));
        try std.testing.expect(r.is_error);
        if (!contains(r.text, c.want)) {
            std.debug.print("want '{s}' in '{s}'\n", .{ c.want, r.text });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(@as(u32, 0), fx.world.spawns);
}

test "readonly slice blocks unmarked tools at call time too" {
    const alloc = std.testing.allocator;
    const fx = try Fx.init(alloc, &.{"docker"}, .{ .readonly = true });
    defer fx.deinit(alloc);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const bad = try fx.gw.toolCall(a, std.testing.io, try parseArgs(a, "{\"name\":\"docker_rm\"}"));
    try std.testing.expect(bad.is_error and contains(bad.text, "not marked read-only"));
    const ok = try fx.gw.toolCall(a, std.testing.io, try parseArgs(a, "{\"name\":\"docker_ps\"}"));
    try std.testing.expect(!ok.is_error);
}

test "child crash becomes an error result and the next call respawns" {
    const alloc = std.testing.allocator;
    const fx = try Fx.init(alloc, &.{"docker"}, .{});
    defer fx.deinit(alloc);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    fx.world.call_errors[0] = error.ChildExited;
    fx.world.call_errors[1] = error.Timeout;
    const r = try fx.gw.toolCall(a, std.testing.io, try parseArgs(a, "{\"name\":\"docker_ps\"}"));
    try std.testing.expect(r.is_error and contains(r.text, "exited during the call"));
    const t = try fx.gw.toolCall(a, std.testing.io, try parseArgs(a, "{\"name\":\"docker_ps\"}"));
    try std.testing.expect(t.is_error and contains(t.text, "did not answer within 120s"));
    const ok = try fx.gw.toolCall(a, std.testing.io, try parseArgs(a, "{\"name\":\"docker_ps\"}"));
    try std.testing.expect(!ok.is_error);
    try std.testing.expectEqual(@as(u32, 3), fx.world.spawns);
    // Spawn failure and missing binary are reported without details.
    fx.world.spawn_not_found = true;
    fx.gw.pool.shutdown(std.testing.io);
    const nf = try fx.gw.toolCall(a, std.testing.io, try parseArgs(a, "{\"name\":\"docker_ps\"}"));
    try std.testing.expect(nf.is_error and contains(nf.text, "zmcp-docker not found"));
}

test "convertResponse: text, image, isError, protocol errors, omitted content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const t = try convertResponse(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"a\"},{\"type\":\"text\",\"text\":\"b\"}]}}");
    try std.testing.expectEqualStrings("a\nb", t.text);
    try std.testing.expect(!t.is_error and t.image == null);

    const img = try convertResponse(a, "{\"id\":1,\"result\":{\"content\":[{\"type\":\"image\",\"data\":\"AAAA\",\"mimeType\":\"image/png\"},{\"type\":\"image\",\"data\":\"BB\",\"mimeType\":\"image/png\"},{\"type\":\"text\",\"text\":\"cap\"}]}}");
    try std.testing.expectEqualStrings("AAAA", img.image.?.data_base64);
    try std.testing.expectEqualStrings("image/png", img.image.?.mime_type);
    try std.testing.expect(contains(img.text, "cap") and contains(img.text, "1 more image(s) omitted"));

    const e = try convertResponse(a, "{\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"boom\"}],\"isError\":true}}");
    try std.testing.expect(e.is_error);
    try std.testing.expectEqualStrings("boom", e.text);

    const rpc = try convertResponse(a, "{\"id\":1,\"error\":{\"code\":-32601,\"message\":\"tool not found\",\"data\":\"zzz\"}}");
    try std.testing.expect(rpc.is_error);
    try std.testing.expectEqualStrings("server error -32601: tool not found: zzz", rpc.text);

    const res = try convertResponse(a, "{\"id\":1,\"result\":{\"content\":[{\"type\":\"resource\",\"resource\":{}}]}}");
    try std.testing.expectEqualStrings("[resource content omitted]", res.text);

    for ([_][]const u8{ "garbage", "[]", "{\"id\":1}", "{\"id\":1,\"result\":3}" }) |bad| {
        try std.testing.expect((try convertResponse(a, bad)).is_error);
    }
}

test "isError and images pass through tool_call unchanged" {
    const alloc = std.testing.allocator;
    const fx = try Fx.init(alloc, &.{"docker"}, .{});
    defer fx.deinit(alloc);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    fx.world.result_json = "{\"content\":[{\"type\":\"image\",\"data\":\"QUJD\",\"mimeType\":\"image/jpeg\"},{\"type\":\"text\",\"text\":\"bad\"}],\"isError\":true}";
    const r = try fx.gw.toolCall(a, std.testing.io, try parseArgs(a, "{\"name\":\"docker_ps\"}"));
    try std.testing.expect(r.is_error);
    try std.testing.expectEqualStrings("bad", r.text);
    try std.testing.expectEqualStrings("QUJD", r.image.?.data_base64);
}

test "meta and direct tool tables" {
    const alloc = std.testing.allocator;
    const fx = try Fx.init(alloc, &.{ "git", "docker" }, .{ .deny = &.{"git_reset"} });
    defer fx.deinit(alloc);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const lazy = try lazyTools(a, fx.gw);
    try std.testing.expectEqual(@as(usize, 3), lazy.len);
    try std.testing.expectEqualStrings("tools_search", lazy[0].name);
    try std.testing.expect(contains(lazy[0].description, "5 across 2 servers"));
    for (lazy) |t| {
        const p = try parseArgs(a, t.input_schema_json); // valid JSON
        try std.testing.expect(p == .object);
    }

    const direct = try directTools(a, fx.gw);
    try std.testing.expectEqual(@as(usize, 5), direct.len);
    var saw_ns = false;
    for (direct) |t| {
        if (std.mem.eql(u8, t.name, "git.status")) saw_ns = true;
        try std.testing.expect(!std.mem.eql(u8, t.name, "git_reset"));
        const p = try parseArgs(a, t.input_schema_json);
        try std.testing.expect(p == .object);
    }
    try std.testing.expect(saw_ns);

    // The hook routes by exposed name.
    const r = try directHook(fx.gw, a, std.testing.io, "docker.status", .null);
    try std.testing.expect(!r.is_error);
    try std.testing.expectEqual(@as(u32, 1), fx.world.spawns);
}

test "Expose.parse" {
    try std.testing.expectEqual(Expose.lazy, Expose.parse(null));
    try std.testing.expectEqual(Expose.lazy, Expose.parse("weird"));
    try std.testing.expectEqual(Expose.direct, Expose.parse(" Direct "));
}
