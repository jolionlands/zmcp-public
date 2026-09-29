//! Accessibility-tree snapshot: turns the CDP `Accessibility.getFullAXTree`
//! node list into a compact, indented text outline the model can act on:
//!
//!   - heading "Example Domain" [ref=e3] level=1
//!     - link "More information..." [ref=e5] url="https://www.iana.org/..."
//!
//! Pruning: `ignored` nodes are skipped but their children are hoisted;
//! generic/none/presentation wrappers (and unnamed group/paragraph) are
//! collapsed; InlineTextBox / LineBreak / ListMarker are dropped; StaticText
//! that merely repeats its emitted parent's name is dropped.
//!
//! Refs (`eN`) are assigned in pre-order over the whole pruned tree BEFORE any
//! depth / subtree / max_chars limit is applied, so the same page state yields
//! the same refs regardless of how the snapshot was requested. `Result.refs[N-1]`
//! is the DOM backend node id for `eN`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Options = struct {
    /// Max nesting levels below the render root (null = unlimited).
    depth: ?usize = null,
    max_chars: usize = 30_000,
    /// Render only the subtree rooted at this DOM backend node id.
    root_backend_id: ?i64 = null,
};

pub const Result = struct {
    text: []const u8,
    /// refs[n-1] is the backendDOMNodeId for ref "e<n>".
    refs: []const i64,
    truncated: bool,
    /// Number of nodes in the pruned tree.
    node_count: usize,
};

pub const Error = error{ BadTree, RefNotFound } || Allocator.Error;

const MAX_RECURSION: usize = 400;
const MAX_NAME: usize = 200;

const PNode = struct {
    role: []const u8,
    name: []const u8,
    value: []const u8 = "",
    props: []const u8 = "",
    url: []const u8 = "",
    backend: i64 = -1,
    children: std.ArrayList(*PNode) = .empty,
    ref: u32 = 0,
};

const Ctx = struct {
    arena: Allocator,
    nodes: []const Value,
    index: std.StringHashMapUnmanaged(usize),
};

fn objGet(v: Value, key: []const u8) ?Value {
    if (v != .object) return null;
    return v.object.get(key);
}

/// AXValue.value as a string (numbers and bools are formatted).
fn axStr(arena: Allocator, v: ?Value) Allocator.Error![]const u8 {
    const ax = v orelse return "";
    const inner = objGet(ax, "value") orelse return "";
    return switch (inner) {
        .string => |s| s,
        .integer => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(arena, "{d}", .{f}),
        .bool => |b| if (b) "true" else "false",
        else => "",
    };
}

fn isSpace(s: []const u8, i: usize) usize {
    // returns byte length of the whitespace char at i, or 0
    const c = s[i];
    if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c) return 1;
    if (c == 0xC2 and i + 1 < s.len and s[i + 1] == 0xA0) return 2;
    return 0;
}

/// Collapse whitespace runs, trim, escape quotes, cap length (UTF-8 safe).
fn cleanText(arena: Allocator, s: []const u8, cap: usize) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var pending_space = false;
    var truncated = false;
    while (i < s.len) {
        const w = isSpace(s, i);
        if (w > 0) {
            pending_space = out.items.len > 0;
            i += w;
            continue;
        }
        const c = s[i];
        var clen: usize = 1;
        if (c >= 0xF0) clen = 4 else if (c >= 0xE0) clen = 3 else if (c >= 0xC0) clen = 2;
        if (i + clen > s.len) clen = s.len - i;
        if (out.items.len + clen + 2 > cap) {
            truncated = true;
            break;
        }
        if (pending_space) {
            try out.append(arena, ' ');
            pending_space = false;
        }
        if (c == '"' or c == '\\') try out.append(arena, '\\');
        try out.appendSlice(arena, s[i .. i + clen]);
        i += clen;
    }
    if (truncated) try out.appendSlice(arena, "...");
    return out.items;
}

/// Same as cleanText but without quote escaping (for comparisons).
fn plainText(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var pending_space = false;
    while (i < s.len) {
        const w = isSpace(s, i);
        if (w > 0) {
            pending_space = out.items.len > 0;
            i += w;
            continue;
        }
        if (pending_space) {
            try out.append(arena, ' ');
            pending_space = false;
        }
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.items;
}

fn inSet(role: []const u8, set: []const []const u8) bool {
    for (set) |s| if (std.mem.eql(u8, role, s)) return true;
    return false;
}

const always_collapse = [_][]const u8{ "generic", "none", "presentation", "Section", "GenericContainer" };
const collapse_if_unnamed = [_][]const u8{ "group", "paragraph", "LabelText", "Ignored" };
const drop_always = [_][]const u8{ "InlineTextBox", "LineBreak", "ListMarker" };
const drop_if_empty = [_][]const u8{ "image", "img", "separator", "paragraph", "group", "list", "listitem", "figure", "LabelText", "region", "article" };

fn buildProps(ctx: *Ctx, node: Value, pn: *PNode) Allocator.Error!void {
    const arena = ctx.arena;
    const is_doc = std.mem.eql(u8, pn.role, "document");
    var out: std.ArrayList(u8) = .empty;
    if (objGet(node, "properties")) |pv| if (pv == .array) {
        for (pv.array.items) |p| {
            const name_v = objGet(p, "name") orelse continue;
            if (name_v != .string) continue;
            const pname = name_v.string;
            const val_s = try axStr(arena, objGet(p, "value"));
            const is_true = std.mem.eql(u8, val_s, "true");
            if (std.mem.eql(u8, pname, "checked") or std.mem.eql(u8, pname, "expanded") or std.mem.eql(u8, pname, "pressed")) {
                if (val_s.len == 0) continue;
                try out.print(arena, " {s}={s}", .{ pname, val_s });
            } else if (std.mem.eql(u8, pname, "level")) {
                if (val_s.len > 0) try out.print(arena, " level={s}", .{val_s});
            } else if (is_doc and (std.mem.eql(u8, pname, "focused") or std.mem.eql(u8, pname, "url"))) {
                continue;
            } else if (std.mem.eql(u8, pname, "disabled") or std.mem.eql(u8, pname, "selected") or
                std.mem.eql(u8, pname, "required") or std.mem.eql(u8, pname, "readonly") or
                std.mem.eql(u8, pname, "focused") or std.mem.eql(u8, pname, "modal"))
            {
                if (is_true) try out.print(arena, " {s}", .{pname});
            } else if (std.mem.eql(u8, pname, "invalid")) {
                if (val_s.len > 0 and !std.mem.eql(u8, val_s, "false")) try out.appendSlice(arena, " invalid");
            } else if (std.mem.eql(u8, pname, "url")) {
                pn.url = try cleanText(arena, val_s, MAX_NAME);
            }
        }
    };
    pn.props = out.items;
}

fn visit(ctx: *Ctx, idx: usize, out: *std.ArrayList(*PNode), parent_name: []const u8, depth: usize) Error!void {
    if (depth > MAX_RECURSION) return;
    const node = ctx.nodes[idx];
    const arena = ctx.arena;

    const hoist = struct {
        fn go(c: *Ctx, n: Value, o: *std.ArrayList(*PNode), pn: []const u8, d: usize) Error!void {
            const ch = objGet(n, "childIds") orelse return;
            if (ch != .array) return;
            for (ch.array.items) |cid| {
                if (cid != .string) continue;
                const ci = c.index.get(cid.string) orelse continue;
                try visit(c, ci, o, pn, d + 1);
            }
        }
    }.go;

    if (objGet(node, "ignored")) |ig| if (ig == .bool and ig.bool) {
        try hoist(ctx, node, out, parent_name, depth);
        return;
    };

    const role_raw = try axStr(arena, objGet(node, "role"));
    const role = if (role_raw.len == 0) "generic" else role_raw;
    if (inSet(role, &drop_always)) return;
    const name = try plainText(arena, try axStr(arena, objGet(node, "name")));

    if (std.mem.eql(u8, role, "StaticText")) {
        if (name.len == 0) return;
        if (parent_name.len > 0 and std.mem.indexOf(u8, parent_name, name) != null) return;
        const pn = try arena.create(PNode);
        pn.* = .{ .role = "text", .name = try cleanText(arena, name, MAX_NAME) };
        try out.append(arena, pn);
        return;
    }
    if (inSet(role, &always_collapse) or (name.len == 0 and inSet(role, &collapse_if_unnamed))) {
        try hoist(ctx, node, out, parent_name, depth);
        return;
    }

    const pn = try arena.create(PNode);
    pn.* = .{
        .role = if (std.mem.eql(u8, role, "RootWebArea")) "document" else role,
        .name = try cleanText(arena, name, MAX_NAME),
    };
    if (objGet(node, "backendDOMNodeId")) |b| switch (b) {
        .integer => |i| pn.backend = i,
        else => {},
    };
    const val_s = try plainText(arena, try axStr(arena, objGet(node, "value")));
    if (val_s.len > 0 and !std.mem.eql(u8, val_s, name)) pn.value = try cleanText(arena, val_s, MAX_NAME);
    try buildProps(ctx, node, pn);

    // A document's name is the page title, which says nothing about its text.
    try hoist(ctx, node, &pn.children, if (std.mem.eql(u8, pn.role, "document")) "" else name, depth);

    if (pn.name.len == 0 and pn.value.len == 0 and pn.props.len == 0 and pn.url.len == 0 and
        pn.children.items.len == 0 and inSet(role, &drop_if_empty)) return;
    try out.append(arena, pn);
}

fn assignRefs(pn: *PNode, refs: *std.ArrayList(i64), arena: Allocator) Allocator.Error!void {
    if (pn.backend >= 0 and !std.mem.eql(u8, pn.role, "text")) {
        try refs.append(arena, pn.backend);
        pn.ref = @intCast(refs.items.len);
    }
    for (pn.children.items) |c| try assignRefs(c, refs, arena);
}

fn findByBackend(pn: *PNode, id: i64) ?*PNode {
    if (pn.backend == id and pn.ref != 0) return pn;
    for (pn.children.items) |c| if (findByBackend(c, id)) |f| return f;
    return null;
}

fn countNodes(pn: *const PNode) usize {
    var n: usize = 1;
    for (pn.children.items) |c| n += countNodes(c);
    return n;
}

const Render = struct {
    arena: Allocator,
    out: std.ArrayList(u8) = .empty,
    max_chars: usize,
    depth: ?usize,
    truncated: bool = false,

    fn line(self: *Render, indent: usize, pn: *const PNode) Allocator.Error!bool {
        var l: std.ArrayList(u8) = .empty;
        try l.appendNTimes(self.arena, ' ', indent * 2);
        try l.appendSlice(self.arena, "- ");
        try l.appendSlice(self.arena, pn.role);
        if (pn.name.len > 0) try l.print(self.arena, " \"{s}\"", .{pn.name});
        if (pn.ref != 0) try l.print(self.arena, " [ref=e{d}]", .{pn.ref});
        try l.appendSlice(self.arena, pn.props);
        if (pn.value.len > 0) try l.print(self.arena, " value=\"{s}\"", .{pn.value});
        if (pn.url.len > 0) try l.print(self.arena, " url=\"{s}\"", .{pn.url});
        try l.append(self.arena, '\n');
        if (self.out.items.len + l.items.len > self.max_chars) {
            self.truncated = true;
            return false;
        }
        try self.out.appendSlice(self.arena, l.items);
        return true;
    }

    fn walk(self: *Render, pn: *const PNode, indent: usize) Allocator.Error!void {
        if (self.truncated) return;
        if (!try self.line(indent, pn)) return;
        if (self.depth) |d| if (indent >= d) {
            if (pn.children.items.len > 0) {
                var m: std.ArrayList(u8) = .empty;
                try m.appendNTimes(self.arena, ' ', (indent + 1) * 2);
                try m.print(self.arena, "- ... ({d} nested nodes hidden by depth)\n", .{countNodes(pn) - 1});
                if (self.out.items.len + m.items.len > self.max_chars) {
                    self.truncated = true;
                    return;
                }
                try self.out.appendSlice(self.arena, m.items);
            }
            return;
        };
        for (pn.children.items) |c| try self.walk(c, indent + 1);
    }
};

/// Build the snapshot from the `nodes` array of Accessibility.getFullAXTree.
/// Everything is allocated in `arena`.
pub fn build(arena: Allocator, nodes_v: Value, opts: Options) Error!Result {
    if (nodes_v != .array or nodes_v.array.items.len == 0) return error.BadTree;
    const nodes = nodes_v.array.items;
    var ctx: Ctx = .{ .arena = arena, .nodes = nodes, .index = .empty };
    try ctx.index.ensureTotalCapacity(arena, @intCast(nodes.len));
    var root_idx: ?usize = null;
    for (nodes, 0..) |n, i| {
        const id = objGet(n, "nodeId") orelse continue;
        if (id != .string) continue;
        ctx.index.putAssumeCapacity(id.string, i);
        if (root_idx == null and objGet(n, "parentId") == null) root_idx = i;
    }
    const ri = root_idx orelse 0;

    var top: std.ArrayList(*PNode) = .empty;
    try visit(&ctx, ri, &top, "", 0);

    // Synthetic container when pruning produced several top-level nodes.
    var root: *PNode = undefined;
    if (top.items.len == 1) {
        root = top.items[0];
    } else {
        root = try arena.create(PNode);
        root.* = .{ .role = "document", .name = "", .children = top };
    }

    var refs: std.ArrayList(i64) = .empty;
    try assignRefs(root, &refs, arena);

    var start: *const PNode = root;
    if (opts.root_backend_id) |id| {
        start = findByBackend(root, id) orelse return error.RefNotFound;
    }

    var r: Render = .{ .arena = arena, .max_chars = opts.max_chars, .depth = opts.depth };
    try r.walk(start, 0);
    return .{
        .text = r.out.items,
        .refs = refs.items,
        .truncated = r.truncated,
        .node_count = countNodes(root),
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const fixture =
    \\{"nodes":[
    \\{"nodeId":"1","ignored":false,"role":{"type":"role","value":"RootWebArea"},"name":{"type":"computedString","value":"Demo Page"},"childIds":["2","3","10","20"],"backendDOMNodeId":1},
    \\{"nodeId":"2","ignored":true,"role":{"type":"role","value":"none"},"childIds":["4"],"parentId":"1","backendDOMNodeId":2},
    \\{"nodeId":"4","ignored":false,"role":{"type":"role","value":"generic"},"childIds":["5"],"parentId":"2","backendDOMNodeId":4},
    \\{"nodeId":"5","ignored":false,"role":{"type":"role","value":"heading"},"name":{"type":"computedString","value":"Hello   World"},"properties":[{"name":"level","value":{"type":"integer","value":1}}],"childIds":["6"],"parentId":"4","backendDOMNodeId":5},
    \\{"nodeId":"6","ignored":false,"role":{"type":"role","value":"StaticText"},"name":{"type":"computedString","value":"Hello World"},"childIds":["7"],"parentId":"5","backendDOMNodeId":6},
    \\{"nodeId":"7","ignored":false,"role":{"type":"internalRole","value":"InlineTextBox"},"name":{"type":"computedString","value":"Hello World"},"parentId":"6","backendDOMNodeId":7},
    \\{"nodeId":"3","ignored":false,"role":{"type":"role","value":"generic"},"childIds":["8","9"],"parentId":"1","backendDOMNodeId":3},
    \\{"nodeId":"8","ignored":false,"role":{"type":"role","value":"link"},"name":{"type":"computedString","value":"More info"},"properties":[{"name":"focusable","value":{"type":"booleanOrUndefined","value":true}},{"name":"url","value":{"type":"string","value":"https://example.com/more"}}],"childIds":["11"],"parentId":"3","backendDOMNodeId":8},
    \\{"nodeId":"11","ignored":false,"role":{"type":"role","value":"StaticText"},"name":{"type":"computedString","value":"More info"},"childIds":["12"],"parentId":"8","backendDOMNodeId":11},
    \\{"nodeId":"12","ignored":false,"role":{"type":"internalRole","value":"InlineTextBox"},"name":{"type":"computedString","value":"More info"},"parentId":"11","backendDOMNodeId":12},
    \\{"nodeId":"9","ignored":false,"role":{"type":"role","value":"paragraph"},"childIds":["13"],"parentId":"3","backendDOMNodeId":9},
    \\{"nodeId":"13","ignored":false,"role":{"type":"role","value":"StaticText"},"name":{"type":"computedString","value":"Some body text."},"childIds":["14"],"parentId":"9","backendDOMNodeId":13},
    \\{"nodeId":"14","ignored":false,"role":{"type":"internalRole","value":"InlineTextBox"},"name":{"type":"computedString","value":"Some body text."},"parentId":"13","backendDOMNodeId":14},
    \\{"nodeId":"10","ignored":false,"role":{"type":"role","value":"generic"},"childIds":["15","16","17","18"],"parentId":"1","backendDOMNodeId":10},
    \\{"nodeId":"15","ignored":false,"role":{"type":"role","value":"textbox"},"name":{"type":"computedString","value":"Email"},"value":{"type":"string","value":"me@x.org"},"properties":[{"name":"required","value":{"type":"boolean","value":true}},{"name":"focused","value":{"type":"boolean","value":false}}],"parentId":"10","backendDOMNodeId":15},
    \\{"nodeId":"16","ignored":false,"role":{"type":"role","value":"checkbox"},"name":{"type":"computedString","value":"Remember me"},"properties":[{"name":"checked","value":{"type":"tristate","value":"false"}}],"parentId":"10","backendDOMNodeId":16},
    \\{"nodeId":"17","ignored":false,"role":{"type":"role","value":"button"},"name":{"type":"computedString","value":"Save"},"properties":[{"name":"disabled","value":{"type":"boolean","value":true}},{"name":"expanded","value":{"type":"booleanOrUndefined","value":false}}],"parentId":"10","backendDOMNodeId":17},
    \\{"nodeId":"18","ignored":false,"role":{"type":"role","value":"image"},"parentId":"10","backendDOMNodeId":18},
    \\{"nodeId":"20","ignored":false,"role":{"type":"role","value":"list"},"childIds":["21","22"],"parentId":"1","backendDOMNodeId":20},
    \\{"nodeId":"21","ignored":false,"role":{"type":"role","value":"listitem"},"childIds":["23","24"],"parentId":"20","backendDOMNodeId":21},
    \\{"nodeId":"23","ignored":false,"role":{"type":"role","value":"ListMarker"},"name":{"type":"computedString","value":"1. "},"parentId":"21","backendDOMNodeId":23},
    \\{"nodeId":"24","ignored":false,"role":{"type":"role","value":"StaticText"},"name":{"type":"computedString","value":"first \"quoted\"\nitem"},"parentId":"21","backendDOMNodeId":24},
    \\{"nodeId":"22","ignored":false,"role":{"type":"role","value":"listitem"},"childIds":[],"parentId":"20","backendDOMNodeId":22}
    \\]}
;

fn parseFixture(arena: Allocator, s: []const u8) !Value {
    const v = try std.json.parseFromSliceLeaky(Value, arena, s, .{});
    return v.object.get("nodes").?;
}

test "pruning: hoists ignored, collapses generic, drops text duplicates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nodes = try parseFixture(arena, fixture);
    const r = try build(arena, nodes, .{});
    const expected =
        \\- document "Demo Page" [ref=e1]
        \\  - heading "Hello World" [ref=e2] level=1
        \\  - link "More info" [ref=e3] url="https://example.com/more"
        \\  - text "Some body text."
        \\  - textbox "Email" [ref=e4] required value="me@x.org"
        \\  - checkbox "Remember me" [ref=e5] checked=false
        \\  - button "Save" [ref=e6] disabled expanded=false
        \\  - list [ref=e7]
        \\    - listitem [ref=e8]
        \\      - text "first \"quoted\" item"
        \\
    ;
    try testing.expectEqualStrings(expected, r.text);
    try testing.expectEqual(@as(usize, 8), r.refs.len);
    try testing.expectEqual(@as(i64, 5), r.refs[1]); // e2 -> heading backend id 5
    try testing.expectEqual(@as(i64, 8), r.refs[2]);
    try testing.expect(!r.truncated);
    // Size reduction versus the raw JSON.
    try testing.expect(r.text.len * 3 < fixture.len);
}

test "refs are stable across option changes and repeated builds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nodes = try parseFixture(arena, fixture);
    const a = try build(arena, nodes, .{});
    const b = try build(arena, nodes, .{});
    try testing.expectEqualStrings(a.text, b.text);
    try testing.expectEqualSlices(i64, a.refs, b.refs);
    // depth / subtree / tiny max_chars do not renumber
    const shallow = try build(arena, nodes, .{ .depth = 1 });
    try testing.expectEqualSlices(i64, a.refs, shallow.refs);
    try testing.expect(std.mem.indexOf(u8, shallow.text, "[ref=e8]") == null); // hidden by depth
    try testing.expect(std.mem.indexOf(u8, shallow.text, "nested nodes hidden by depth") != null);
    const sub = try build(arena, nodes, .{ .root_backend_id = 17 });
    try testing.expectEqualStrings("- button \"Save\" [ref=e6] disabled expanded=false\n", sub.text);
    const sub2 = try build(arena, nodes, .{ .root_backend_id = 20 });
    try testing.expect(std.mem.startsWith(u8, sub2.text, "- list [ref=e7]\n"));
    try testing.expectError(error.RefNotFound, build(arena, nodes, .{ .root_backend_id = 999 }));
}

test "max_chars truncates on line boundaries" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nodes = try parseFixture(arena, fixture);
    const r = try build(arena, nodes, .{ .max_chars = 100 });
    try testing.expect(r.truncated);
    try testing.expect(r.text.len <= 100);
    try testing.expect(r.text.len == 0 or r.text[r.text.len - 1] == '\n');
    try testing.expectEqual(@as(usize, 8), r.refs.len);
}

test "text repeating the parent's name is dropped; distinct text kept; whitespace normalised" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const j =
        \\{"nodes":[
        \\{"nodeId":"1","ignored":false,"role":{"value":"RootWebArea"},"name":{"value":"T"},"childIds":["2"],"backendDOMNodeId":1},
        \\{"nodeId":"2","ignored":false,"role":{"value":"button"},"name":{"value":"Add\u00a0to   cart"},"childIds":["3","4"],"parentId":"1","backendDOMNodeId":2},
        \\{"nodeId":"3","ignored":false,"role":{"value":"StaticText"},"name":{"value":"Add to cart"},"parentId":"2","backendDOMNodeId":3},
        \\{"nodeId":"4","ignored":false,"role":{"value":"StaticText"},"name":{"value":"(3 left)"},"parentId":"2","backendDOMNodeId":4}
        \\]}
    ;
    const r = try build(arena, try parseFixture(arena, j), .{});
    try testing.expectEqualStrings(
        "- document \"T\" [ref=e1]\n  - button \"Add to cart\" [ref=e2]\n    - text \"(3 left)\"\n",
        r.text,
    );
}

test "document node drops url and focused noise; links keep url" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const j =
        \\{"nodes":[
        \\{"nodeId":"1","ignored":false,"role":{"value":"RootWebArea"},"name":{"value":"T"},"properties":[{"name":"focused","value":{"type":"boolean","value":true}},{"name":"url","value":{"type":"string","value":"http://x/"}}],"childIds":["2"],"backendDOMNodeId":1},
        \\{"nodeId":"2","ignored":false,"role":{"value":"link"},"name":{"value":"L"},"properties":[{"name":"focused","value":{"type":"boolean","value":true}},{"name":"url","value":{"type":"string","value":"http://x/l"}}],"parentId":"1","backendDOMNodeId":2}
        \\]}
    ;
    const r = try build(arena, try parseFixture(arena, j), .{});
    try testing.expectEqualStrings("- document \"T\" [ref=e1]\n  - link \"L\" [ref=e2] focused url=\"http://x/l\"\n", r.text);
}

test "bad input" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.BadTree, build(arena, .{ .null = {} }, .{}));
    const empty = try std.json.parseFromSliceLeaky(Value, arena, "[]", .{});
    try testing.expectError(error.BadTree, build(arena, empty, .{}));
}
