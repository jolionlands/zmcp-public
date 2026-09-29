//! Static tool catalog: per server, its tools (name, one-line description,
//! compact input schema, read-only/destructive marks, category, tags) so the
//! gateway can search and describe tools without spawning anything.
//!
//! File format (one JSON object, versioned):
//!   {"version":1,"servers":[{"name":"git","binary":"zmcp-git","size":N,
//!     "mtime_ms":N,"version":"0.1.0","tools":[{"name":..,"description":..,
//!     "inputSchema":{..},"readOnly":true,"destructive":false,
//!     "category":"vcs","tags":["commit",..]}]}]}
//! `size` + `mtime_ms` fingerprint the server binary: a rebuilt server no
//! longer matches and its entry is refreshed.

const std = @import("std");
const mcp = @import("mcp");
const taxonomy = @import("taxonomy.zig");

pub const Category = taxonomy.Category;
pub const format_version: i64 = 1;

/// Stored descriptions are whitespace-collapsed and cut here (UTF-8 safe).
pub const DESC_STORE_CAP: usize = 400;

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// Compact-rendered JSON schema text (see mcp.compactSchema).
    schema: []const u8,
    read_only: bool = false,
    destructive: bool = false,
    category: Category = .utility,
    tags: []const []const u8 = &.{},
};

pub const Server = struct {
    name: []const u8,
    binary: []const u8 = "",
    size: u64 = 0,
    mtime_ms: i64 = 0,
    version: []const u8 = "",
    tools: []const Tool = &.{},

    /// True when a binary with this size and mtime is what the entry was
    /// built from.
    pub fn matches(self: Server, size: u64, mtime_ms: i64) bool {
        return self.size == size and self.mtime_ms == mtime_ms;
    }
};

pub const Catalog = struct {
    gpa: std.mem.Allocator,
    /// Heap-allocated so entries stay valid when the Catalog is moved.
    arena: *std.heap.ArenaAllocator,
    servers: std.ArrayList(Server) = .empty,

    pub fn init(gpa: std.mem.Allocator) !Catalog {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(gpa);
        return .{ .gpa = gpa, .arena = arena };
    }

    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
        self.gpa.destroy(self.arena);
    }

    /// Allocator that owns every string in the catalog.
    pub fn alloc(self: *Catalog) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn find(self: *const Catalog, name: []const u8) ?*const Server {
        for (self.servers.items) |*s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    /// Insert or replace `server` (its strings must be allocated from
    /// `alloc()`); the list stays sorted by name.
    pub fn put(self: *Catalog, server: Server) !void {
        for (self.servers.items) |*s| {
            if (std.mem.eql(u8, s.name, server.name)) {
                s.* = server;
                return;
            }
        }
        try self.servers.append(self.alloc(), server);
        std.mem.sort(Server, self.servers.items, {}, lessByName);
    }

    pub fn remove(self: *Catalog, name: []const u8) void {
        for (self.servers.items, 0..) |s, i| {
            if (std.mem.eql(u8, s.name, name)) {
                _ = self.servers.orderedRemove(i);
                return;
            }
        }
    }

    pub fn toolCount(self: *const Catalog) usize {
        var n: usize = 0;
        for (self.servers.items) |s| n += s.tools.len;
        return n;
    }
};

fn lessByName(_: void, a: Server, b: Server) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Collapse whitespace runs to single spaces, trim, cap at `cap` bytes on a
/// UTF-8 boundary. Owned by `a`.
pub fn oneLine(a: std.mem.Allocator, text: []const u8, cap: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var prev_space = true;
    for (text) |c| {
        const sp = c == ' ' or c == '\n' or c == '\r' or c == '\t';
        if (sp) {
            if (!prev_space) try out.append(a, ' ');
        } else try out.append(a, c);
        prev_space = sp;
    }
    var end = out.items.len;
    while (end > 0 and out.items[end - 1] == ' ') end -= 1;
    end = mcp.utf8SafeLen(out.items[0..end], cap);
    return out.items[0..end];
}

// ---------------------------------------------------------------------------
// Serialization
// ---------------------------------------------------------------------------

pub fn write(cat: *const Catalog, w: *std.Io.Writer) !void {
    var js = std.json.Stringify{ .writer = w };
    try js.beginObject();
    try js.objectField("version");
    try js.write(format_version);
    try js.objectField("servers");
    try js.beginArray();
    for (cat.servers.items) |s| {
        try w.writeAll("\n");
        try js.beginObject();
        try js.objectField("name");
        try js.write(s.name);
        try js.objectField("binary");
        try js.write(s.binary);
        try js.objectField("size");
        try js.write(s.size);
        try js.objectField("mtime_ms");
        try js.write(s.mtime_ms);
        try js.objectField("version");
        try js.write(s.version);
        try js.objectField("tools");
        try js.beginArray();
        for (s.tools) |t| {
            try w.writeAll("\n");
            try js.beginObject();
            try js.objectField("name");
            try js.write(t.name);
            try js.objectField("description");
            try js.write(t.description);
            try js.objectField("inputSchema");
            try js.beginWriteRaw();
            try w.writeAll(if (t.schema.len == 0) "{}" else t.schema);
            js.endWriteRaw();
            if (t.read_only) {
                try js.objectField("readOnly");
                try js.write(true);
            }
            if (t.destructive) {
                try js.objectField("destructive");
                try js.write(true);
            }
            try js.objectField("category");
            try js.write(t.category.text());
            try js.objectField("tags");
            try js.write(t.tags);
            try js.endObject();
        }
        try js.endArray();
        try js.endObject();
    }
    try js.endArray();
    try js.endObject();
    try w.writeAll("\n");
}

pub fn toOwnedText(gpa: std.mem.Allocator, cat: *const Catalog) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try write(cat, &aw.writer);
    return aw.toOwnedSlice();
}

pub const ParseError = error{InvalidCatalog} || std.mem.Allocator.Error;

fn str(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

fn boolOf(v: ?std.json.Value) bool {
    const x = v orelse return false;
    return x == .bool and x.bool;
}

fn intOf(v: ?std.json.Value) i64 {
    const x = v orelse return 0;
    return if (x == .integer) x.integer else 0;
}

fn stringify(a: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    var js = std.json.Stringify{ .writer = &aw.writer };
    js.write(v) catch return error.OutOfMemory;
    return aw.written();
}

/// Parse catalog text. Missing category/tags are filled from the taxonomy,
/// so an older or hand-written catalog still searches well.
pub fn parse(gpa: std.mem.Allocator, text: []const u8) ParseError!Catalog {
    var cat = try Catalog.init(gpa);
    errdefer cat.deinit();
    const a = cat.alloc();
    // Parse in a scratch arena and copy only what the catalog keeps, so the
    // resident catalog is much smaller than the JSON value tree.
    var tmp_state = std.heap.ArenaAllocator.init(gpa);
    defer tmp_state.deinit();
    const t = tmp_state.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, t, text, .{ .allocate = .alloc_always }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCatalog,
    };
    if (root != .object) return error.InvalidCatalog;
    if (intOf(root.object.get("version")) != format_version) return error.InvalidCatalog;
    const servers = root.object.get("servers") orelse return error.InvalidCatalog;
    if (servers != .array) return error.InvalidCatalog;
    for (servers.array.items) |sv| {
        if (sv != .object) return error.InvalidCatalog;
        const name = str(sv.object.get("name")) orelse return error.InvalidCatalog;
        const tools_v = sv.object.get("tools") orelse return error.InvalidCatalog;
        if (tools_v != .array) return error.InvalidCatalog;
        const asg = taxonomy.forServer(name);
        const tools = try a.alloc(Tool, tools_v.array.items.len);
        for (tools_v.array.items, 0..) |tv, ti| {
            if (tv != .object) return error.InvalidCatalog;
            const tname = str(tv.object.get("name")) orelse return error.InvalidCatalog;
            var tags: []const []const u8 = asg.tags;
            if (tv.object.get("tags")) |tg| {
                if (tg == .array) {
                    var list: std.ArrayList([]const u8) = .empty;
                    for (tg.array.items) |it| if (it == .string) try list.append(t, it.string);
                    const copy = try a.alloc([]const u8, list.items.len);
                    for (list.items, 0..) |s, k| copy[k] = try a.dupe(u8, s);
                    tags = copy;
                }
            }
            const schema_v = tv.object.get("inputSchema") orelse std.json.Value{ .object = .empty };
            tools[ti] = .{
                .name = try a.dupe(u8, tname),
                .description = try a.dupe(u8, str(tv.object.get("description")) orelse ""),
                .schema = try a.dupe(u8, try stringify(t, schema_v)),
                .read_only = boolOf(tv.object.get("readOnly")),
                .destructive = boolOf(tv.object.get("destructive")),
                .category = if (str(tv.object.get("category"))) |c| (Category.parse(c) orelse asg.category) else asg.category,
                .tags = tags,
            };
        }
        try cat.servers.append(a, .{
            .name = try a.dupe(u8, name),
            .binary = try a.dupe(u8, str(sv.object.get("binary")) orelse ""),
            .size = @intCast(@max(intOf(sv.object.get("size")), 0)),
            .mtime_ms = intOf(sv.object.get("mtime_ms")),
            .version = try a.dupe(u8, str(sv.object.get("version")) orelse ""),
            .tools = tools,
        });
    }
    std.mem.sort(Server, cat.servers.items, {}, lessByName);
    return cat;
}

// ---------------------------------------------------------------------------
// Building an entry from a live tools/list response
// ---------------------------------------------------------------------------

pub const BuildError = error{ BadToolsList } || std.mem.Allocator.Error;

/// Build a server entry (strings allocated from `cat.alloc()`) from the raw
/// JSON-RPC response line of `tools/list`.
pub fn entryFromToolsList(
    cat: *Catalog,
    name: []const u8,
    binary: []const u8,
    size: u64,
    mtime_ms: i64,
    version: []const u8,
    response_line: []const u8,
) BuildError!Server {
    const a = cat.alloc();
    var tmp = std.heap.ArenaAllocator.init(cat.gpa);
    defer tmp.deinit();
    const t = tmp.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, t, response_line, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadToolsList,
    };
    if (root != .object) return error.BadToolsList;
    const result = root.object.get("result") orelse return error.BadToolsList;
    if (result != .object) return error.BadToolsList;
    const list = result.object.get("tools") orelse return error.BadToolsList;
    if (list != .array) return error.BadToolsList;

    const asg = taxonomy.forServer(name);
    var tools: std.ArrayList(Tool) = .empty;
    for (list.array.items) |tv| {
        if (tv != .object) continue;
        const tname = str(tv.object.get("name")) orelse continue;
        var schema: []const u8 = "{}";
        if (tv.object.get("inputSchema")) |sv| {
            const raw = try stringify(t, sv);
            schema = mcp.compactSchema(a, raw) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => try a.dupe(u8, raw),
            };
        }
        var ro = false;
        var destructive = false;
        if (tv.object.get("annotations")) |an| {
            if (an == .object) {
                ro = boolOf(an.object.get("readOnlyHint"));
                destructive = boolOf(an.object.get("destructiveHint"));
            }
        }
        try tools.append(a, .{
            .name = try a.dupe(u8, tname),
            .description = try oneLine(a, str(tv.object.get("description")) orelse "", DESC_STORE_CAP),
            .schema = schema,
            .read_only = ro,
            .destructive = destructive,
            .category = asg.category,
            .tags = asg.tags,
        });
    }
    return .{
        .name = try a.dupe(u8, name),
        .binary = try a.dupe(u8, binary),
        .size = size,
        .mtime_ms = mtime_ms,
        .version = try a.dupe(u8, version),
        .tools = tools.items,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const sample_list =
    \\{"jsonrpc":"2.0","id":2,"result":{"tools":[
    \\{"name":"git_status","description":"Show the working tree status.\n  Second   line.","inputSchema":{"type":"object","title":"X","properties":{"repo":{"type":"string"}},"required":[],"additionalProperties":false},"annotations":{"readOnlyHint":true}},
    \\{"name":"git_reset","description":"Reset HEAD.","inputSchema":{"type":"object"},"annotations":{"destructiveHint":true}},
    \\{"name":"git_plain","description":"No marks."}
    \\]}}
;

test "entryFromToolsList compacts schemas, keeps marks, assigns taxonomy" {
    const alloc = std.testing.allocator;
    var cat = try Catalog.init(alloc);
    defer cat.deinit();
    const s = try entryFromToolsList(&cat, "git", "zmcp-git", 10, 20, "0.1.0", sample_list);
    try std.testing.expectEqual(@as(usize, 3), s.tools.len);
    try std.testing.expectEqualStrings("git_status", s.tools[0].name);
    try std.testing.expectEqualStrings("Show the working tree status. Second line.", s.tools[0].description);
    try std.testing.expectEqualStrings("{\"type\":\"object\",\"properties\":{\"repo\":{\"type\":\"string\"}}}", s.tools[0].schema);
    try std.testing.expect(s.tools[0].read_only and !s.tools[0].destructive);
    try std.testing.expect(s.tools[1].destructive and !s.tools[1].read_only);
    try std.testing.expect(!s.tools[2].read_only);
    try std.testing.expectEqualStrings("{}", s.tools[2].schema);
    try std.testing.expectEqual(Category.vcs, s.tools[0].category);
    try std.testing.expect(s.tools[0].tags.len > 0);
}

test "entryFromToolsList rejects malformed responses" {
    const alloc = std.testing.allocator;
    var cat = try Catalog.init(alloc);
    defer cat.deinit();
    for ([_][]const u8{ "nope", "[]", "{\"result\":1}", "{\"result\":{}}", "{\"error\":{\"code\":1}}" }) |bad| {
        try std.testing.expectError(error.BadToolsList, entryFromToolsList(&cat, "x", "b", 0, 0, "", bad));
    }
}

test "catalog round-trips through write and parse" {
    const alloc = std.testing.allocator;
    var cat = try Catalog.init(alloc);
    defer cat.deinit();
    try cat.put(try entryFromToolsList(&cat, "git", "zmcp-git", 10, 20, "0.1.0", sample_list));
    try cat.put(try entryFromToolsList(&cat, "aaa", "zmcp-aaa", 1, 2, "", sample_list));
    try std.testing.expectEqualStrings("aaa", cat.servers.items[0].name); // sorted
    const text = try toOwnedText(alloc, &cat);
    defer alloc.free(text);

    var back = try parse(alloc, text);
    defer back.deinit();
    try std.testing.expectEqual(@as(usize, 2), back.servers.items.len);
    try std.testing.expectEqual(cat.toolCount(), back.toolCount());
    const g = back.find("git").?;
    try std.testing.expectEqual(@as(u64, 10), g.size);
    try std.testing.expectEqual(@as(i64, 20), g.mtime_ms);
    try std.testing.expect(g.matches(10, 20));
    try std.testing.expect(!g.matches(10, 21));
    try std.testing.expectEqualStrings("git_reset", g.tools[1].name);
    try std.testing.expect(g.tools[1].destructive);
    try std.testing.expect(g.tools[0].read_only);
    try std.testing.expectEqualStrings(cat.find("git").?.tools[0].schema, g.tools[0].schema);
    // The file is valid JSON and human-scannable (one tool per line).
    try std.testing.expect(std.mem.count(u8, text, "\n") >= 6);
}

test "parse fills category and tags from the taxonomy when absent" {
    const alloc = std.testing.allocator;
    const text = "{\"version\":1,\"servers\":[{\"name\":\"docker\",\"tools\":[{\"name\":\"docker_ps\",\"description\":\"List containers\"}]}]}";
    var cat = try parse(alloc, text);
    defer cat.deinit();
    const t = cat.find("docker").?.tools[0];
    try std.testing.expectEqual(Category.infra, t.category);
    try std.testing.expect(t.tags.len > 0);
    try std.testing.expectEqualStrings("{}", t.schema);
}

test "parse rejects wrong versions and shapes" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{
        "",
        "[]",
        "{\"version\":2,\"servers\":[]}",
        "{\"version\":1}",
        "{\"version\":1,\"servers\":[1]}",
        "{\"version\":1,\"servers\":[{\"name\":\"x\"}]}",
        "{\"version\":1,\"servers\":[{\"name\":\"x\",\"tools\":[{}]}]}",
    }) |bad| {
        try std.testing.expectError(error.InvalidCatalog, parse(alloc, bad));
    }
}

test "put replaces an entry with the same name" {
    const alloc = std.testing.allocator;
    var cat = try Catalog.init(alloc);
    defer cat.deinit();
    try cat.put(try entryFromToolsList(&cat, "git", "zmcp-git", 1, 1, "", sample_list));
    try cat.put(try entryFromToolsList(&cat, "git", "zmcp-git", 2, 2, "", sample_list));
    try std.testing.expectEqual(@as(usize, 1), cat.servers.items.len);
    try std.testing.expectEqual(@as(u64, 2), cat.find("git").?.size);
    cat.remove("git");
    try std.testing.expect(cat.find("git") == null);
}

test "oneLine collapses whitespace and caps on a UTF-8 boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a b c", try oneLine(arena.allocator(), "  a\n\n b\t c  ", 100));
    try std.testing.expectEqualStrings("é", try oneLine(arena.allocator(), "éé", 3));
}
