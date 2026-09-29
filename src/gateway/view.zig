//! The exposed tool set: a catalog restricted to a slice's servers, filtered
//! by its glob/readonly rules, with colliding names namespaced.
//!
//! Every lookup path (search, schema, call) goes through a View, so a tool
//! the slice hides can not be reached by any of them.

const std = @import("std");
const catalog = @import("catalog.zig");
const profile = @import("profile.zig");

pub const Exposed = struct {
    /// Name the model uses: the real tool name, or `server.tool` when two
    /// servers in the slice expose the same name.
    name: []const u8,
    server: []const u8,
    tool: *const catalog.Tool,
    namespaced: bool,
};

pub const Hidden = struct {
    /// Real tool name.
    name: []const u8,
    server: []const u8,
    reason: profile.Reason,
};

pub const Lookup = union(enum) {
    found: u32,
    /// A bare name that exists in several servers: the namespaced choices.
    ambiguous: []const u32,
    hidden: Hidden,
    missing,
};

pub const View = struct {
    gpa: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    exposed: []const Exposed = &.{},
    hidden: []const Hidden = &.{},
    /// Servers in slice order.
    servers: []const []const u8 = &.{},
    by_name: std.StringHashMapUnmanaged(u32) = .empty,
    /// Bare name -> indices (only for names that had to be namespaced).
    collisions: std.StringHashMapUnmanaged([]const u32) = .empty,
    /// Tools of the slice's servers before the glob/readonly rules.
    total_before_slice: usize = 0,
    /// Of those, how many carry annotations.readOnlyHint.
    read_only_marked: usize = 0,

    pub fn deinit(self: *View) void {
        self.arena.deinit();
        self.gpa.destroy(self.arena);
    }

    /// `servers` must all be in `cat` (callers resolve names first); an
    /// unknown one is skipped. `cat` must outlive the View.
    pub fn build(
        gpa: std.mem.Allocator,
        cat: *const catalog.Catalog,
        servers: []const []const u8,
        slice: profile.Slice,
    ) !View {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(gpa);
        var v: View = .{ .gpa = gpa, .arena = arena };
        errdefer v.deinit();
        const a = arena.allocator();

        var kept: std.ArrayList(Exposed) = .empty;
        var hid: std.ArrayList(Hidden) = .empty;
        var names: std.ArrayList([]const u8) = .empty;
        for (servers) |sname| {
            const s = cat.find(sname) orelse continue;
            try names.append(a, s.name);
            for (s.tools) |*t| {
                v.total_before_slice += 1;
                if (t.read_only) v.read_only_marked += 1;
                if (profile.hiddenByTool(slice, t.name, t.read_only, t.destructive)) |r| {
                    try hid.append(a, .{ .name = t.name, .server = s.name, .reason = r });
                    continue;
                }
                try kept.append(a, .{ .name = t.name, .server = s.name, .tool = t, .namespaced = false });
            }
        }

        // Collisions: the same bare name from more than one server.
        var counts: std.StringHashMapUnmanaged(u32) = .empty;
        for (kept.items) |e| {
            const g = try counts.getOrPut(a, e.name);
            if (g.found_existing) g.value_ptr.* += 1 else g.value_ptr.* = 1;
        }
        for (kept.items, 0..) |*e, i| {
            if (counts.get(e.name).? > 1) {
                const bare = e.name;
                e.name = try std.fmt.allocPrint(a, "{s}.{s}", .{ e.server, bare });
                e.namespaced = true;
                const g = try v.collisions.getOrPut(a, bare);
                if (!g.found_existing) g.value_ptr.* = &.{};
                const grown = try a.alloc(u32, g.value_ptr.len + 1);
                @memcpy(grown[0..g.value_ptr.len], g.value_ptr.*);
                grown[g.value_ptr.len] = @intCast(i);
                g.value_ptr.* = grown;
            }
        }
        for (kept.items, 0..) |e, i| try v.by_name.put(a, e.name, @intCast(i));

        v.exposed = kept.items;
        v.hidden = hid.items;
        v.servers = names.items;
        return v;
    }

    pub fn lookup(self: *const View, name: []const u8) Lookup {
        if (self.by_name.get(name)) |i| return .{ .found = i };
        if (self.collisions.get(name)) |idx| return .{ .ambiguous = idx };
        for (self.hidden) |h| {
            if (std.mem.eql(u8, h.name, name)) return .{ .hidden = h };
        }
        return .missing;
    }

    pub fn namespacedCount(self: *const View) usize {
        var n: usize = 0;
        for (self.exposed) |e| {
            if (e.namespaced) n += 1;
        }
        return n;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// A two-server catalog with one colliding name ("status").
pub const test_catalog_text =
    \\{"version":1,"servers":[
    \\{"name":"git","tools":[
    \\ {"name":"status","description":"Show working tree status of a git repository","readOnly":true,"category":"vcs"},
    \\ {"name":"git_commit","description":"Record changes to the repository","category":"vcs"},
    \\ {"name":"git_reset","description":"Reset current HEAD to the given state","destructive":true,"category":"vcs"}]},
    \\{"name":"docker","tools":[
    \\ {"name":"status","description":"Show docker daemon status","readOnly":true,"category":"infra"},
    \\ {"name":"docker_ps","description":"List containers","readOnly":true,"category":"infra"},
    \\ {"name":"docker_rm","description":"Remove a container","destructive":true,"category":"infra"}]},
    \\{"name":"memory","tools":[
    \\ {"name":"create_entities","description":"Create entities in the knowledge graph","category":"memory"}]}
    \\]}
;

test "build exposes every tool and namespaces collisions" {
    const alloc = std.testing.allocator;
    var cat = try catalog.parse(alloc, test_catalog_text);
    defer cat.deinit();
    var v = try View.build(alloc, &cat, &.{ "git", "docker", "memory" }, .{});
    defer v.deinit();
    try std.testing.expectEqual(@as(usize, 7), v.exposed.len);
    try std.testing.expectEqual(@as(usize, 2), v.namespacedCount());
    try std.testing.expect(v.by_name.contains("git.status"));
    try std.testing.expect(v.by_name.contains("docker.status"));
    try std.testing.expect(!v.by_name.contains("status"));
    try std.testing.expect(v.by_name.contains("git_commit"));
    switch (v.lookup("status")) {
        .ambiguous => |idx| try std.testing.expectEqual(@as(usize, 2), idx.len),
        else => return error.TestUnexpectedResult,
    }
    const i = v.lookup("docker.status").found;
    try std.testing.expectEqualStrings("status", v.exposed[i].tool.name); // real name kept for the child
    try std.testing.expectEqualStrings("docker", v.exposed[i].server);
}

test "a collision hidden by the slice is not namespaced" {
    const alloc = std.testing.allocator;
    var cat = try catalog.parse(alloc, test_catalog_text);
    defer cat.deinit();
    var v = try View.build(alloc, &cat, &.{ "git", "docker" }, .{ .deny = &.{"docker_*"} });
    defer v.deinit();
    // docker.status remains (deny only matches docker_*), so still a collision.
    try std.testing.expectEqual(@as(usize, 2), v.namespacedCount());
    var v2 = try View.build(alloc, &cat, &.{ "git", "docker" }, .{ .allow = &.{ "git_*", "status" } });
    defer v2.deinit();
    try std.testing.expectEqual(@as(usize, 2), v2.namespacedCount());
    var v3 = try View.build(alloc, &cat, &.{"git"}, .{});
    defer v3.deinit();
    try std.testing.expectEqual(@as(usize, 0), v3.namespacedCount());
    try std.testing.expect(v3.by_name.contains("status"));
}

test "slice rules hide tools from lookup and record why" {
    const alloc = std.testing.allocator;
    var cat = try catalog.parse(alloc, test_catalog_text);
    defer cat.deinit();
    var v = try View.build(alloc, &cat, &.{ "git", "memory" }, .{ .deny = &.{"git_reset"} });
    defer v.deinit();
    try std.testing.expectEqual(@as(usize, 3), v.exposed.len);
    switch (v.lookup("git_reset")) {
        .hidden => |h| {
            try std.testing.expectEqual(profile.Reason.deny, h.reason);
            try std.testing.expectEqualStrings("git", h.server);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(v.lookup("nope") == .missing);
    // A server outside the slice is simply missing.
    try std.testing.expect(v.lookup("docker_ps") == .missing);
}

test "no_destructive slice hides destructive tools and reports why" {
    const alloc = std.testing.allocator;
    var cat = try catalog.parse(alloc, test_catalog_text);
    defer cat.deinit();
    var v = try View.build(alloc, &cat, &.{ "git", "docker" }, .{ .no_destructive = true });
    defer v.deinit();
    for (v.exposed) |e| try std.testing.expect(!e.tool.destructive);
    var seen = false;
    for (v.hidden) |h| {
        if (std.mem.eql(u8, h.name, "git_reset")) {
            seen = true;
            try std.testing.expectEqual(profile.Reason.no_destructive, h.reason);
        }
    }
    try std.testing.expect(seen);
    try std.testing.expect(v.lookup("docker_rm") == .hidden);
    var all = try View.build(alloc, &cat, &.{ "git", "docker" }, .{});
    defer all.deinit();
    try std.testing.expect(all.exposed.len > v.exposed.len);
}

test "readonly slice keeps only marked tools; empty result is reported via counters" {
    const alloc = std.testing.allocator;
    var cat = try catalog.parse(alloc, test_catalog_text);
    defer cat.deinit();
    var v = try View.build(alloc, &cat, &.{ "git", "docker" }, .{ .readonly = true });
    defer v.deinit();
    try std.testing.expectEqual(@as(usize, 3), v.exposed.len);
    for (v.exposed) |e| try std.testing.expect(e.tool.read_only);
    try std.testing.expectEqual(@as(usize, 6), v.total_before_slice);
    try std.testing.expectEqual(@as(usize, 3), v.read_only_marked);

    // memory has no read-only marks: an empty (not failing) view.
    var m = try View.build(alloc, &cat, &.{"memory"}, .{ .readonly = true });
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 0), m.exposed.len);
    try std.testing.expectEqual(@as(usize, 1), m.total_before_slice);
    try std.testing.expectEqual(@as(usize, 0), m.read_only_marked);
}
