//! zmcp-memory - pure-Zig port of the reference @modelcontextprotocol/server-memory.
//!
//! A persistent knowledge graph of entities, relations and observations.
//! Storage is JSONL at $ZMCP_MEMORY_FILE (default ./memory.jsonl), one record
//! per line, identical to the reference server:
//!   {"type":"entity","name":"...","entityType":"...","observations":["..."]}
//!   {"type":"relation","from":"...","to":"...","relationType":"..."}
//!
//! Tools: create_entities, create_relations, add_observations, delete_entities,
//! delete_observations, delete_relations, read_graph, search_nodes, open_nodes.
//!
//! The graph is loaded from disk on every call and saved after every mutation,
//! exactly like the reference; each call runs in the per-call arena from mcp.zig.

const std = @import("std");
const mcp = @import("mcp");

const Io = std.Io;

const DEFAULT_FILE = "./memory.jsonl";

/// Resolved once in main() from ZMCP_MEMORY_FILE.
var g_path: []const u8 = DEFAULT_FILE;

pub fn main(init: std.process.Init) !void {
    if (init.environ_map.get("ZMCP_MEMORY_FILE")) |p| {
        // environ_map outlives main(), so no copy is needed.
        if (p.len > 0) g_path = p;
    }
    try mcp.run(init.gpa, init.io, .{ .name = "zmcp-memory", .version = "0.1.0" }, &tool_table);
}

// ---------------------------------------------------------------------------
// Graph model
// ---------------------------------------------------------------------------

pub const Entity = struct {
    name: []const u8,
    entityType: []const u8,
    observations: []const []const u8,
};

pub const Relation = struct {
    from: []const u8,
    to: []const u8,
    relationType: []const u8,
};

pub const AddedObservations = struct {
    entityName: []const u8,
    addedObservations: []const []const u8,
};

/// All graph memory is allocated from the arena passed in `a`; nothing is
/// freed individually.
pub const Graph = struct {
    entities: std.ArrayList(Entity) = .empty,
    relations: std.ArrayList(Relation) = .empty,

    fn findEntity(self: *const Graph, name: []const u8) ?usize {
        for (self.entities.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, name)) return i;
        }
        return null;
    }

    fn hasRelation(self: *const Graph, r: Relation) bool {
        for (self.relations.items) |x| {
            if (relEql(x, r)) return true;
        }
        return false;
    }

    /// Adds entities whose name is not yet present. Returns the ones added.
    pub fn createEntities(self: *Graph, a: std.mem.Allocator, input: []const Entity) ![]const Entity {
        var added: std.ArrayList(Entity) = .empty;
        for (input) |e| {
            if (self.findEntity(e.name) != null) continue;
            try self.entities.append(a, e);
            try added.append(a, e);
        }
        return added.items;
    }

    /// Adds relations not already present (same from/to/relationType).
    pub fn createRelations(self: *Graph, a: std.mem.Allocator, input: []const Relation) ![]const Relation {
        var added: std.ArrayList(Relation) = .empty;
        for (input) |r| {
            if (self.hasRelation(r)) continue;
            try self.relations.append(a, r);
            try added.append(a, r);
        }
        return added.items;
    }

    pub const AddError = error{EntityNotFound};

    /// Adds new observations per entity. Fails if an entity does not exist
    /// (like the reference); callers must not save the graph on error.
    pub fn addObservations(
        self: *Graph,
        a: std.mem.Allocator,
        input: []const AddedObservations,
        missing: *[]const u8,
    ) ![]const AddedObservations {
        var results: std.ArrayList(AddedObservations) = .empty;
        for (input) |item| {
            const idx = self.findEntity(item.entityName) orelse {
                missing.* = item.entityName;
                return error.EntityNotFound;
            };
            var obs: std.ArrayList([]const u8) = .empty;
            try obs.appendSlice(a, self.entities.items[idx].observations);
            var added: std.ArrayList([]const u8) = .empty;
            for (item.addedObservations) |c| {
                if (inList(obs.items, c)) continue;
                try obs.append(a, c);
                try added.append(a, c);
            }
            self.entities.items[idx].observations = obs.items;
            try results.append(a, .{ .entityName = item.entityName, .addedObservations = added.items });
        }
        return results.items;
    }

    /// Removes entities by name and every relation touching them.
    pub fn deleteEntities(self: *Graph, names: []const []const u8) void {
        var i: usize = 0;
        while (i < self.entities.items.len) {
            if (inList(names, self.entities.items[i].name)) {
                _ = self.entities.orderedRemove(i);
            } else i += 1;
        }
        var j: usize = 0;
        while (j < self.relations.items.len) {
            const r = self.relations.items[j];
            if (inList(names, r.from) or inList(names, r.to)) {
                _ = self.relations.orderedRemove(j);
            } else j += 1;
        }
    }

    /// Removes the listed observations from entities. Unknown entities are ignored.
    pub fn deleteObservations(self: *Graph, a: std.mem.Allocator, input: []const AddedObservations) !void {
        for (input) |item| {
            const idx = self.findEntity(item.entityName) orelse continue;
            var keep: std.ArrayList([]const u8) = .empty;
            for (self.entities.items[idx].observations) |o| {
                if (!inList(item.addedObservations, o)) try keep.append(a, o);
            }
            self.entities.items[idx].observations = keep.items;
        }
    }

    pub fn deleteRelations(self: *Graph, input: []const Relation) void {
        var i: usize = 0;
        while (i < self.relations.items.len) {
            var hit = false;
            for (input) |d| {
                if (relEql(self.relations.items[i], d)) {
                    hit = true;
                    break;
                }
            }
            if (hit) _ = self.relations.orderedRemove(i) else i += 1;
        }
    }

    /// Case-insensitive substring match over name, entityType and observations.
    /// Relations are kept only when both endpoints are in the result.
    pub fn search(self: *const Graph, a: std.mem.Allocator, query: []const u8) !Subgraph {
        var ents: std.ArrayList(Entity) = .empty;
        for (self.entities.items) |e| {
            var hit = containsIgnoreCase(e.name, query) or containsIgnoreCase(e.entityType, query);
            if (!hit) {
                for (e.observations) |o| {
                    if (containsIgnoreCase(o, query)) {
                        hit = true;
                        break;
                    }
                }
            }
            if (hit) try ents.append(a, e);
        }
        return self.withRelations(a, ents.items);
    }

    /// Entities with the given names plus relations between them.
    pub fn open(self: *const Graph, a: std.mem.Allocator, names: []const []const u8) !Subgraph {
        var ents: std.ArrayList(Entity) = .empty;
        for (self.entities.items) |e| {
            if (inList(names, e.name)) try ents.append(a, e);
        }
        return self.withRelations(a, ents.items);
    }

    fn withRelations(self: *const Graph, a: std.mem.Allocator, ents: []const Entity) !Subgraph {
        var rels: std.ArrayList(Relation) = .empty;
        for (self.relations.items) |r| {
            var from_in = false;
            var to_in = false;
            for (ents) |e| {
                if (std.mem.eql(u8, e.name, r.from)) from_in = true;
                if (std.mem.eql(u8, e.name, r.to)) to_in = true;
            }
            if (from_in and to_in) try rels.append(a, r);
        }
        return .{ .entities = ents, .relations = rels.items };
    }

    pub fn view(self: *const Graph) Subgraph {
        return .{ .entities = self.entities.items, .relations = self.relations.items };
    }
};

/// Serialisable {entities, relations} result shape (matches the reference output).
pub const Subgraph = struct {
    entities: []const Entity,
    relations: []const Relation,
};

fn relEql(x: Relation, y: Relation) bool {
    return std.mem.eql(u8, x.from, y.from) and
        std.mem.eql(u8, x.to, y.to) and
        std.mem.eql(u8, x.relationType, y.relationType);
}

fn inList(list: []const []const u8, s: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, s)) return true;
    }
    return false;
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(hay, needle) != null;
}

// ---------------------------------------------------------------------------
// JSONL persistence
// ---------------------------------------------------------------------------

/// Parse JSONL text into a graph. Blank and malformed lines are skipped.
pub fn parseJsonl(a: std.mem.Allocator, text: []const u8) !Graph {
    var g: Graph = .{};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch continue;
        if (parsed != .object) continue;
        const t = getStr(parsed, "type") orelse continue;
        if (std.mem.eql(u8, t, "entity")) {
            const name = getStr(parsed, "name") orelse continue;
            const et = getStr(parsed, "entityType") orelse continue;
            const obs = strArray(a, parsed.object.get("observations")) catch continue;
            try g.entities.append(a, .{ .name = name, .entityType = et, .observations = obs });
        } else if (std.mem.eql(u8, t, "relation")) {
            const from = getStr(parsed, "from") orelse continue;
            const to = getStr(parsed, "to") orelse continue;
            const rt = getStr(parsed, "relationType") orelse continue;
            try g.relations.append(a, .{ .from = from, .to = to, .relationType = rt });
        }
    }
    return g;
}

const EntityLine = struct {
    type: []const u8 = "entity",
    name: []const u8,
    entityType: []const u8,
    observations: []const []const u8,
};

const RelationLine = struct {
    type: []const u8 = "relation",
    from: []const u8,
    to: []const u8,
    relationType: []const u8,
};

/// Serialise a graph as JSONL (entities first, then relations; no trailing
/// newline, like the reference's lines.join("\n")).
pub fn serializeJsonl(a: std.mem.Allocator, g: *const Graph) ![]u8 {
    var sw: Io.Writer.Allocating = .init(a);
    var first = true;
    for (g.entities.items) |e| {
        if (!first) try sw.writer.writeByte('\n');
        first = false;
        var js = std.json.Stringify{ .writer = &sw.writer };
        try js.write(EntityLine{ .name = e.name, .entityType = e.entityType, .observations = e.observations });
    }
    for (g.relations.items) |r| {
        if (!first) try sw.writer.writeByte('\n');
        first = false;
        var js = std.json.Stringify{ .writer = &sw.writer };
        try js.write(RelationLine{ .from = r.from, .to = r.to, .relationType = r.relationType });
    }
    return sw.written();
}

fn loadGraph(a: std.mem.Allocator, io: Io) !Graph {
    const text = Io.Dir.cwd().readFileAlloc(io, g_path, a, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return parseJsonl(a, text);
}

fn saveGraph(a: std.mem.Allocator, io: Io, g: *const Graph) !void {
    const data = try serializeJsonl(a, g);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = g_path, .data = data });
}

// ---------------------------------------------------------------------------
// Argument helpers
// ---------------------------------------------------------------------------

fn getStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}

fn strArray(a: std.mem.Allocator, v: ?std.json.Value) ![]const []const u8 {
    const val = v orelse return &.{};
    if (val != .array) return error.InvalidArgument;
    var out: std.ArrayList([]const u8) = .empty;
    for (val.array.items) |x| {
        if (x != .string) return error.InvalidArgument;
        try out.append(a, x.string);
    }
    return out.items;
}

fn arrayField(args: std.json.Value, key: []const u8) ?[]const std.json.Value {
    if (args != .object) return null;
    const x = args.object.get(key) orelse return null;
    return if (x == .array) x.array.items else null;
}

const ArgError = error{ InvalidArgument, OutOfMemory };

fn parseEntities(a: std.mem.Allocator, items: []const std.json.Value) ArgError![]const Entity {
    var out: std.ArrayList(Entity) = .empty;
    for (items) |it| {
        const name = getStr(it, "name") orelse return error.InvalidArgument;
        const et = getStr(it, "entityType") orelse return error.InvalidArgument;
        const obs = try strArray(a, if (it == .object) it.object.get("observations") else null);
        try out.append(a, .{ .name = name, .entityType = et, .observations = obs });
    }
    return out.items;
}

fn parseRelations(a: std.mem.Allocator, items: []const std.json.Value) ArgError![]const Relation {
    var out: std.ArrayList(Relation) = .empty;
    for (items) |it| {
        const from = getStr(it, "from") orelse return error.InvalidArgument;
        const to = getStr(it, "to") orelse return error.InvalidArgument;
        const rt = getStr(it, "relationType") orelse return error.InvalidArgument;
        try out.append(a, .{ .from = from, .to = to, .relationType = rt });
    }
    return out.items;
}

/// Parses [{entityName, <list_key>: [..]}] into AddedObservations.
fn parseObsItems(a: std.mem.Allocator, items: []const std.json.Value, list_key: []const u8) ArgError![]const AddedObservations {
    var out: std.ArrayList(AddedObservations) = .empty;
    for (items) |it| {
        const name = getStr(it, "entityName") orelse return error.InvalidArgument;
        const list = try strArray(a, if (it == .object) it.object.get(list_key) else null);
        try out.append(a, .{ .entityName = name, .addedObservations = list });
    }
    return out.items;
}

fn toJson(a: std.mem.Allocator, value: anytype) ![]u8 {
    var sw: Io.Writer.Allocating = .init(a);
    var js = std.json.Stringify{ .writer = &sw.writer, .options = .{ .whitespace = .indent_2 } };
    try js.write(value);
    return sw.written();
}

fn ok(text: []const u8) mcp.ToolResult {
    return .{ .text = text };
}

fn fail(a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !mcp.ToolResult {
    return .{ .text = try std.fmt.allocPrint(a, fmt, args), .is_error = true };
}

fn badArg(a: std.mem.Allocator, key: []const u8) !mcp.ToolResult {
    return fail(a, "invalid or missing argument: {s}", .{key});
}

// ---------------------------------------------------------------------------
// Tool handlers
// ---------------------------------------------------------------------------

fn handleCreateEntities(a: std.mem.Allocator, io: Io, args: std.json.Value) anyerror!mcp.ToolResult {
    const items = arrayField(args, "entities") orelse return badArg(a, "entities");
    const input = parseEntities(a, items) catch |e| switch (e) {
        error.InvalidArgument => return badArg(a, "entities"),
        else => return e,
    };
    var g = try loadGraph(a, io);
    const added = try g.createEntities(a, input);
    try saveGraph(a, io, &g);
    return ok(try toJson(a, added));
}

fn handleCreateRelations(a: std.mem.Allocator, io: Io, args: std.json.Value) anyerror!mcp.ToolResult {
    const items = arrayField(args, "relations") orelse return badArg(a, "relations");
    const input = parseRelations(a, items) catch |e| switch (e) {
        error.InvalidArgument => return badArg(a, "relations"),
        else => return e,
    };
    var g = try loadGraph(a, io);
    const added = try g.createRelations(a, input);
    try saveGraph(a, io, &g);
    return ok(try toJson(a, added));
}

fn handleAddObservations(a: std.mem.Allocator, io: Io, args: std.json.Value) anyerror!mcp.ToolResult {
    const items = arrayField(args, "observations") orelse return badArg(a, "observations");
    const input = parseObsItems(a, items, "contents") catch |e| switch (e) {
        error.InvalidArgument => return badArg(a, "observations"),
        else => return e,
    };
    var g = try loadGraph(a, io);
    var missing: []const u8 = "";
    const res = g.addObservations(a, input, &missing) catch |e| switch (e) {
        error.EntityNotFound => return fail(a, "Entity with name {s} not found", .{missing}),
        else => return e,
    };
    try saveGraph(a, io, &g);
    return ok(try toJson(a, res));
}

fn handleDeleteEntities(a: std.mem.Allocator, io: Io, args: std.json.Value) anyerror!mcp.ToolResult {
    if (arrayField(args, "entityNames") == null) return badArg(a, "entityNames");
    const names = strArray(a, args.object.get("entityNames")) catch return badArg(a, "entityNames");
    var g = try loadGraph(a, io);
    g.deleteEntities(names);
    try saveGraph(a, io, &g);
    return ok("Entities deleted successfully");
}

fn handleDeleteObservations(a: std.mem.Allocator, io: Io, args: std.json.Value) anyerror!mcp.ToolResult {
    const items = arrayField(args, "deletions") orelse return badArg(a, "deletions");
    const input = parseObsItems(a, items, "observations") catch |e| switch (e) {
        error.InvalidArgument => return badArg(a, "deletions"),
        else => return e,
    };
    var g = try loadGraph(a, io);
    try g.deleteObservations(a, input);
    try saveGraph(a, io, &g);
    return ok("Observations deleted successfully");
}

fn handleDeleteRelations(a: std.mem.Allocator, io: Io, args: std.json.Value) anyerror!mcp.ToolResult {
    const items = arrayField(args, "relations") orelse return badArg(a, "relations");
    const input = parseRelations(a, items) catch |e| switch (e) {
        error.InvalidArgument => return badArg(a, "relations"),
        else => return e,
    };
    var g = try loadGraph(a, io);
    g.deleteRelations(input);
    try saveGraph(a, io, &g);
    return ok("Relations deleted successfully");
}

fn handleReadGraph(a: std.mem.Allocator, io: Io, _: std.json.Value) anyerror!mcp.ToolResult {
    const g = try loadGraph(a, io);
    return ok(try toJson(a, g.view()));
}

fn handleSearchNodes(a: std.mem.Allocator, io: Io, args: std.json.Value) anyerror!mcp.ToolResult {
    const query = getStr(args, "query") orelse return badArg(a, "query");
    const g = try loadGraph(a, io);
    return ok(try toJson(a, try g.search(a, query)));
}

fn handleOpenNodes(a: std.mem.Allocator, io: Io, args: std.json.Value) anyerror!mcp.ToolResult {
    if (arrayField(args, "names") == null) return badArg(a, "names");
    const names = strArray(a, args.object.get("names")) catch return badArg(a, "names");
    const g = try loadGraph(a, io);
    return ok(try toJson(a, try g.open(a, names)));
}

// ---------------------------------------------------------------------------
// Tool table
// ---------------------------------------------------------------------------

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "create_entities",
        .description = "Create multiple new entities in the knowledge graph. Entities whose name already exists are ignored. Returns the entities actually created.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "entities": {
        \\      "type": "array",
        \\      "items": {
        \\        "type": "object",
        \\        "properties": {
        \\          "name": { "type": "string", "description": "The name of the entity" },
        \\          "entityType": { "type": "string", "description": "The type of the entity" },
        \\          "observations": { "type": "array", "items": { "type": "string" }, "description": "An array of observation contents associated with the entity" }
        \\        },
        \\        "required": ["name", "entityType", "observations"]
        \\      }
        \\    }
        \\  },
        \\  "required": ["entities"]
        \\}
        ,
        .handler = handleCreateEntities,
    },
    .{
        .name = "create_relations",
        .description = "Create multiple new relations between entities in the knowledge graph. Relations should be in active voice. Duplicate relations are ignored.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "relations": {
        \\      "type": "array",
        \\      "items": {
        \\        "type": "object",
        \\        "properties": {
        \\          "from": { "type": "string", "description": "The name of the entity where the relation starts" },
        \\          "to": { "type": "string", "description": "The name of the entity where the relation ends" },
        \\          "relationType": { "type": "string", "description": "The type of the relation" }
        \\        },
        \\        "required": ["from", "to", "relationType"]
        \\      }
        \\    }
        \\  },
        \\  "required": ["relations"]
        \\}
        ,
        .handler = handleCreateRelations,
    },
    .{
        .name = "add_observations",
        .description = "Add new observations to existing entities in the knowledge graph. Errors if an entity does not exist.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "observations": {
        \\      "type": "array",
        \\      "items": {
        \\        "type": "object",
        \\        "properties": {
        \\          "entityName": { "type": "string", "description": "The name of the entity to add the observations to" },
        \\          "contents": { "type": "array", "items": { "type": "string" }, "description": "An array of observation contents to add" }
        \\        },
        \\        "required": ["entityName", "contents"]
        \\      }
        \\    }
        \\  },
        \\  "required": ["observations"]
        \\}
        ,
        .handler = handleAddObservations,
    },
    .{
        .name = "delete_entities",
        .destructive = true,
        .description = "Delete multiple entities and their associated relations from the knowledge graph.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "entityNames": { "type": "array", "items": { "type": "string" }, "description": "An array of entity names to delete" }
        \\  },
        \\  "required": ["entityNames"]
        \\}
        ,
        .handler = handleDeleteEntities,
    },
    .{
        .name = "delete_observations",
        .destructive = true,
        .description = "Delete specific observations from entities in the knowledge graph.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "deletions": {
        \\      "type": "array",
        \\      "items": {
        \\        "type": "object",
        \\        "properties": {
        \\          "entityName": { "type": "string", "description": "The name of the entity containing the observations" },
        \\          "observations": { "type": "array", "items": { "type": "string" }, "description": "An array of observations to delete" }
        \\        },
        \\        "required": ["entityName", "observations"]
        \\      }
        \\    }
        \\  },
        \\  "required": ["deletions"]
        \\}
        ,
        .handler = handleDeleteObservations,
    },
    .{
        .name = "delete_relations",
        .destructive = true,
        .description = "Delete multiple relations from the knowledge graph.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "relations": {
        \\      "type": "array",
        \\      "items": {
        \\        "type": "object",
        \\        "properties": {
        \\          "from": { "type": "string", "description": "The name of the entity where the relation starts" },
        \\          "to": { "type": "string", "description": "The name of the entity where the relation ends" },
        \\          "relationType": { "type": "string", "description": "The type of the relation" }
        \\        },
        \\        "required": ["from", "to", "relationType"]
        \\      },
        \\      "description": "An array of relations to delete"
        \\    }
        \\  },
        \\  "required": ["relations"]
        \\}
        ,
        .handler = handleDeleteRelations,
    },
    .{
        .name = "read_graph",
        .read_only = true,
        .description = "Read the entire knowledge graph (all entities and relations).",
        .input_schema_json =
        \\{ "type": "object", "properties": {} }
        ,
        .handler = handleReadGraph,
    },
    .{
        .name = "search_nodes",
        .read_only = true,
        .description = "Search for nodes in the knowledge graph. Case-insensitive substring match against entity names, entity types and observation contents.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "query": { "type": "string", "description": "The search query to match against entity names, types, and observation content" }
        \\  },
        \\  "required": ["query"]
        \\}
        ,
        .handler = handleSearchNodes,
    },
    .{
        .name = "open_nodes",
        .read_only = true,
        .description = "Open specific nodes in the knowledge graph by their names. Returns those entities and the relations between them.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "names": { "type": "array", "items": { "type": "string" }, "description": "An array of entity names to retrieve" }
        \\  },
        \\  "required": ["names"]
        \\}
        ,
        .handler = handleOpenNodes,
    },
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn ent(name: []const u8, t: []const u8, obs: []const []const u8) Entity {
    return .{ .name = name, .entityType = t, .observations = obs };
}

fn rel(f: []const u8, t: []const u8, ty: []const u8) Relation {
    return .{ .from = f, .to = t, .relationType = ty };
}

test "createEntities skips duplicate names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g: Graph = .{};
    const first = try g.createEntities(a, &.{ ent("A", "person", &.{"x"}), ent("B", "person", &.{}) });
    try testing.expectEqual(@as(usize, 2), first.len);
    const second = try g.createEntities(a, &.{ ent("A", "other", &.{}), ent("C", "thing", &.{}) });
    try testing.expectEqual(@as(usize, 1), second.len);
    try testing.expectEqualStrings("C", second[0].name);
    try testing.expectEqual(@as(usize, 3), g.entities.items.len);
    try testing.expectEqualStrings("person", g.entities.items[0].entityType);
}

test "createRelations dedups on from/to/type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g: Graph = .{};
    _ = try g.createRelations(a, &.{rel("A", "B", "knows")});
    const added = try g.createRelations(a, &.{ rel("A", "B", "knows"), rel("A", "B", "likes"), rel("B", "A", "knows") });
    try testing.expectEqual(@as(usize, 2), added.len);
    try testing.expectEqual(@as(usize, 3), g.relations.items.len);
}

test "addObservations dedups and reports missing entity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g: Graph = .{};
    _ = try g.createEntities(a, &.{ent("A", "t", &.{"one"})});
    var missing: []const u8 = "";
    const res = try g.addObservations(a, &.{.{ .entityName = "A", .addedObservations = &.{ "one", "two", "two" } }}, &missing);
    try testing.expectEqual(@as(usize, 1), res[0].addedObservations.len);
    try testing.expectEqualStrings("two", res[0].addedObservations[0]);
    try testing.expectEqual(@as(usize, 2), g.entities.items[0].observations.len);
    try testing.expectError(error.EntityNotFound, g.addObservations(a, &.{.{ .entityName = "Z", .addedObservations = &.{"q"} }}, &missing));
    try testing.expectEqualStrings("Z", missing);
}

test "deleteEntities cascades to relations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g: Graph = .{};
    _ = try g.createEntities(a, &.{ ent("A", "t", &.{}), ent("B", "t", &.{}), ent("C", "t", &.{}) });
    _ = try g.createRelations(a, &.{ rel("A", "B", "r"), rel("B", "C", "r"), rel("A", "C", "r") });
    g.deleteEntities(&.{"B"});
    try testing.expectEqual(@as(usize, 2), g.entities.items.len);
    try testing.expectEqual(@as(usize, 1), g.relations.items.len);
    try testing.expectEqualStrings("C", g.relations.items[0].to);
}

test "deleteObservations and deleteRelations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g: Graph = .{};
    _ = try g.createEntities(a, &.{ent("A", "t", &.{ "x", "y", "z" })});
    try g.deleteObservations(a, &.{
        .{ .entityName = "A", .addedObservations = &.{ "y", "nope" } },
        .{ .entityName = "ghost", .addedObservations = &.{"x"} },
    });
    try testing.expectEqual(@as(usize, 2), g.entities.items[0].observations.len);
    try testing.expectEqualStrings("z", g.entities.items[0].observations[1]);

    _ = try g.createRelations(a, &.{ rel("A", "B", "r1"), rel("A", "B", "r2") });
    g.deleteRelations(&.{ rel("A", "B", "r1"), rel("X", "Y", "r") });
    try testing.expectEqual(@as(usize, 1), g.relations.items.len);
    try testing.expectEqualStrings("r2", g.relations.items[0].relationType);
}

test "search is case-insensitive over name, type, observations; filters relations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g: Graph = .{};
    _ = try g.createEntities(a, &.{
        ent("Alice", "Person", &.{"Likes Zig"}),
        ent("Bob", "Person", &.{"Likes Rust"}),
        ent("Zigland", "Place", &.{}),
    });
    _ = try g.createRelations(a, &.{ rel("Alice", "Zigland", "lives in"), rel("Alice", "Bob", "knows") });

    const by_obs = try g.search(a, "zig");
    try testing.expectEqual(@as(usize, 2), by_obs.entities.len); // Alice (obs) + Zigland (name)
    try testing.expectEqual(@as(usize, 1), by_obs.relations.len);
    try testing.expectEqualStrings("lives in", by_obs.relations[0].relationType);

    const by_type = try g.search(a, "PERSON");
    try testing.expectEqual(@as(usize, 2), by_type.entities.len);
    try testing.expectEqual(@as(usize, 1), by_type.relations.len);

    const none = try g.search(a, "nothing-here");
    try testing.expectEqual(@as(usize, 0), none.entities.len);
}

test "open returns named entities and only inner relations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g: Graph = .{};
    _ = try g.createEntities(a, &.{ ent("A", "t", &.{}), ent("B", "t", &.{}), ent("C", "t", &.{}) });
    _ = try g.createRelations(a, &.{ rel("A", "B", "r"), rel("B", "C", "r") });
    const sub = try g.open(a, &.{ "A", "B", "missing" });
    try testing.expectEqual(@as(usize, 2), sub.entities.len);
    try testing.expectEqual(@as(usize, 1), sub.relations.len);
    try testing.expectEqualStrings("B", sub.relations[0].to);
}

test "JSONL serialise/parse round trip matches reference line format" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g: Graph = .{};
    _ = try g.createEntities(a, &.{ent("A \"q\"", "person", &.{ "x", "line\nbreak" })});
    _ = try g.createRelations(a, &.{rel("A \"q\"", "B", "knows")});
    const text = try serializeJsonl(a, &g);
    try testing.expect(std.mem.startsWith(u8, text, "{\"type\":\"entity\",\"name\":\"A \\\"q\\\"\",\"entityType\":\"person\",\"observations\":["));
    try testing.expect(std.mem.indexOf(u8, text, "\n{\"type\":\"relation\",\"from\":") != null);
    // Exactly one record separator: the embedded observation newline is escaped.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\n"));

    const g2 = try parseJsonl(a, text);
    try testing.expectEqual(@as(usize, 1), g2.entities.items.len);
    try testing.expectEqualStrings("A \"q\"", g2.entities.items[0].name);
    try testing.expectEqualStrings("line\nbreak", g2.entities.items[0].observations[1]);
    try testing.expectEqual(@as(usize, 1), g2.relations.items.len);
    try testing.expectEqualStrings("knows", g2.relations.items[0].relationType);
}

test "parseJsonl skips blank, malformed and unknown lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\{"type":"entity","name":"A","entityType":"t","observations":["o"]}
        \\
        \\not json
        \\{"type":"mystery","x":1}
        \\{"type":"entity","name":"missing-type-field"}
        \\{"type":"relation","from":"A","to":"B","relationType":"r"}
    ;
    const g = try parseJsonl(a, text);
    try testing.expectEqual(@as(usize, 1), g.entities.items.len);
    try testing.expectEqual(@as(usize, 1), g.relations.items.len);
}

test "argument parsing rejects wrong shapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, "[{\"name\":\"A\"}]", .{});
    try testing.expectError(error.InvalidArgument, parseEntities(a, v.array.items));
    const ok_v = try std.json.parseFromSliceLeaky(std.json.Value, a, "[{\"name\":\"A\",\"entityType\":\"t\",\"observations\":[\"o\"]}]", .{});
    const ents = try parseEntities(a, ok_v.array.items);
    try testing.expectEqual(@as(usize, 1), ents[0].observations.len);
}

test "toJson emits reference read_graph shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g: Graph = .{};
    _ = try g.createEntities(a, &.{ent("A", "t", &.{})});
    const out = try toJson(a, g.view());
    try testing.expect(std.mem.indexOf(u8, out, "\"entities\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"relations\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"entityType\": \"t\"") != null);
}

test "annotations: reads read_only, deletes destructive, creates neither" {
    for (tool_table) |t| {
        try testing.expect(!(t.read_only and t.destructive));
        const del = std.mem.startsWith(u8, t.name, "delete_");
        const create = std.mem.startsWith(u8, t.name, "create_") or std.mem.eql(u8, t.name, "add_observations");
        try testing.expectEqual(del, t.destructive);
        try testing.expectEqual(!del and !create, t.read_only);
    }
}
