//! zmcp-todo — per-project todo scratchpad.
//!
//! State persists at <cwd>/.pid/todo.json.
//! Each entry: { id, text, priority, status, created_ms, done_ms? }
//! Priorities: low | normal | high
//! Status:     open | done
//! ID:         8-char lowercase hex (random)
//!
//! Tools:
//!   todo_add(text, priority?)  — append a todo
//!   todo_list(filter?)         — list todos (all | open | done)
//!   todo_done(id)              — mark done
//!   todo_remove(id)            — delete by id
//!   todo_clear()               — remove all done entries

const std = @import("std");
const mcp = @import("mcp");

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

pub const Priority = enum {
    low,
    normal,
    high,

    pub fn fromString(s: []const u8) ?Priority {
        if (std.mem.eql(u8, s, "low")) return .low;
        if (std.mem.eql(u8, s, "normal")) return .normal;
        if (std.mem.eql(u8, s, "high")) return .high;
        return null;
    }

    pub fn toString(self: Priority) []const u8 {
        return switch (self) {
            .low => "low",
            .normal => "normal",
            .high => "high",
        };
    }
};

pub const Status = enum {
    open,
    done,
};

pub const Todo = struct {
    id: [8]u8, // 8 hex chars, lowercase
    text: []const u8,
    priority: Priority,
    status: Status,
    created_ms: i64,
    done_ms: ?i64,
};

// ---------------------------------------------------------------------------
// Global IO — set in main() so MCP handlers can use real file-system ops.
// Tests pass io explicitly to the public core functions.
// ---------------------------------------------------------------------------

var g_io: std.Io = undefined;

// ---------------------------------------------------------------------------
// Storage helpers
// ---------------------------------------------------------------------------

/// Open (creating if needed) the .pid subdirectory of `base`.
/// Caller must close the returned Dir.
fn openStoreDir(base: std.Io.Dir, io: std.Io) !std.Io.Dir {
    return base.createDirPathOpen(io, ".pid", .{});
}

// ---------------------------------------------------------------------------
// Load / save
// ---------------------------------------------------------------------------

pub fn loadTodos(allocator: std.mem.Allocator, base: std.Io.Dir, io: std.Io) !std.ArrayList(Todo) {
    var store = try openStoreDir(base, io);
    defer store.close(io);

    var list: std.ArrayList(Todo) = .empty;

    const content = store.readFileAlloc(io, "todo.json", allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return list,
        else => return err,
    };
    defer allocator.free(content);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return list,
    };

    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        const id_v = obj.get("id") orelse continue;
        const text_v = obj.get("text") orelse continue;
        const priority_v = obj.get("priority") orelse continue;
        const status_v = obj.get("status") orelse continue;
        const created_ms_v = obj.get("created_ms") orelse continue;

        const id_str = switch (id_v) {
            .string => |s| s,
            else => continue,
        };
        if (id_str.len != 8) continue;

        const text_str = switch (text_v) {
            .string => |s| s,
            else => continue,
        };

        const priority_str = switch (priority_v) {
            .string => |s| s,
            else => continue,
        };
        const priority = Priority.fromString(priority_str) orelse continue;

        const status_str = switch (status_v) {
            .string => |s| s,
            else => continue,
        };
        const status: Status = if (std.mem.eql(u8, status_str, "done")) .done else .open;

        const created_ms: i64 = switch (created_ms_v) {
            .integer => |n| n,
            else => continue,
        };

        var done_ms: ?i64 = null;
        if (obj.get("done_ms")) |dm_v| {
            done_ms = switch (dm_v) {
                .integer => |n| n,
                else => null,
            };
        }

        var id_arr: [8]u8 = undefined;
        @memcpy(&id_arr, id_str[0..8]);

        try list.append(allocator, .{
            .id = id_arr,
            .text = try allocator.dupe(u8, text_str),
            .priority = priority,
            .status = status,
            .created_ms = created_ms,
            .done_ms = done_ms,
        });
    }

    return list;
}

pub fn saveTodos(allocator: std.mem.Allocator, base: std.Io.Dir, io: std.Io, todos: []const Todo) !void {
    var store = try openStoreDir(base, io);
    defer store.close(io);

    // Serialize to JSON in memory using Io.Writer.Allocating
    var sw: std.Io.Writer.Allocating = .init(allocator);
    defer sw.deinit();
    var js = std.json.Stringify{ .writer = &sw.writer };

    try js.beginArray();
    for (todos) |t| {
        try js.beginObject();

        try js.objectField("id");
        try js.write(t.id[0..]);

        try js.objectField("text");
        try js.write(t.text);

        try js.objectField("priority");
        try js.write(t.priority.toString());

        try js.objectField("status");
        try js.write(if (t.status == .done) "done" else "open");

        try js.objectField("created_ms");
        try js.write(t.created_ms);

        if (t.done_ms) |dm| {
            try js.objectField("done_ms");
            try js.write(dm);
        }

        try js.endObject();
    }
    try js.endArray();

    // Atomic write: write to .tmp then rename.
    // On Windows, rename fails if destination exists; delete dest first.
    try store.writeFile(io, .{
        .sub_path = "todo.json.tmp",
        .data = sw.written(),
    });

    store.deleteFile(io, "todo.json") catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    try std.Io.Dir.rename(store, "todo.json.tmp", store, "todo.json", io);
}

// ---------------------------------------------------------------------------
// ID generation
// ---------------------------------------------------------------------------

fn generateId(io: std.Io) [8]u8 {
    var raw: [4]u8 = undefined;
    io.random(&raw);
    var out: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ raw[0], raw[1], raw[2], raw[3] }) catch unreachable;
    return out;
}

// ---------------------------------------------------------------------------
// Now in ms
// ---------------------------------------------------------------------------

fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

// ---------------------------------------------------------------------------
// Cleanup helper — free per-item text allocations then the list backing.
// ---------------------------------------------------------------------------

fn freeTodos(allocator: std.mem.Allocator, todos: *std.ArrayList(Todo)) void {
    for (todos.items) |t| allocator.free(t.text);
    todos.deinit(allocator);
}

// ---------------------------------------------------------------------------
// Core handlers (accept explicit base dir + io for testability)
// ---------------------------------------------------------------------------

pub fn addTodo(
    allocator: std.mem.Allocator,
    base: std.Io.Dir,
    io: std.Io,
    text: []const u8,
    priority: Priority,
) !mcp.ToolResult {
    var todos = try loadTodos(allocator, base, io);
    defer freeTodos(allocator, &todos);

    const id = generateId(io);
    try todos.append(allocator, .{
        .id = id,
        .text = try allocator.dupe(u8, text),
        .priority = priority,
        .status = .open,
        .created_ms = nowMs(io),
        .done_ms = null,
    });

    try saveTodos(allocator, base, io, todos.items);

    const result = try std.fmt.allocPrint(
        allocator,
        "Added todo [{s}]: {s} (priority: {s})",
        .{ id[0..], text, priority.toString() },
    );
    return .{ .text = result };
}

pub fn listTodos(
    allocator: std.mem.Allocator,
    base: std.Io.Dir,
    io: std.Io,
    filter: []const u8,
) !mcp.ToolResult {
    var todos = try loadTodos(allocator, base, io);
    defer freeTodos(allocator, &todos);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var count: usize = 0;
    for (todos.items) |t| {
        const include = blk: {
            if (std.mem.eql(u8, filter, "open")) break :blk t.status == .open;
            if (std.mem.eql(u8, filter, "done")) break :blk t.status == .done;
            break :blk true; // "all" or anything else
        };
        if (!include) continue;

        count += 1;
        const status_str = if (t.status == .done) "[x]" else "[ ]";
        try out.writer.print("{s} [{s}] ({s}) {s}\n", .{
            status_str,
            t.id[0..],
            t.priority.toString(),
            t.text,
        });
    }

    if (count == 0) {
        out.deinit();
        out = .init(allocator); // reset to avoid double free
        return .{ .text = try allocator.dupe(u8, "(no todos)") };
    }

    const written = out.written();
    // Remove trailing newline
    const trimmed = if (written.len > 0 and written[written.len - 1] == '\n')
        written[0 .. written.len - 1]
    else
        written;

    return .{ .text = try allocator.dupe(u8, trimmed) };
}

pub fn doneTodo(
    allocator: std.mem.Allocator,
    base: std.Io.Dir,
    io: std.Io,
    id: []const u8,
) !mcp.ToolResult {
    var todos = try loadTodos(allocator, base, io);
    defer freeTodos(allocator, &todos);

    for (todos.items) |*t| {
        if (std.mem.eql(u8, t.id[0..], id)) {
            t.status = .done;
            t.done_ms = nowMs(io);
            try saveTodos(allocator, base, io, todos.items);
            const result = try std.fmt.allocPrint(
                allocator,
                "Marked done [{s}]: {s}",
                .{ id, t.text },
            );
            return .{ .text = result };
        }
    }

    return .{
        .text = try std.fmt.allocPrint(allocator, "todo not found: {s}", .{id}),
        .is_error = true,
    };
}

pub fn removeTodo(
    allocator: std.mem.Allocator,
    base: std.Io.Dir,
    io: std.Io,
    id: []const u8,
) !mcp.ToolResult {
    var todos = try loadTodos(allocator, base, io);
    defer freeTodos(allocator, &todos);

    var found = false;
    var i: usize = 0;
    while (i < todos.items.len) {
        if (std.mem.eql(u8, todos.items[i].id[0..], id)) {
            const removed_todo = todos.orderedRemove(i);
            allocator.free(removed_todo.text);
            found = true;
            break;
        }
        i += 1;
    }

    if (!found) {
        return .{
            .text = try std.fmt.allocPrint(allocator, "todo not found: {s}", .{id}),
            .is_error = true,
        };
    }

    try saveTodos(allocator, base, io, todos.items);

    return .{
        .text = try std.fmt.allocPrint(allocator, "Removed todo [{s}]", .{id}),
    };
}

pub fn clearDone(
    allocator: std.mem.Allocator,
    base: std.Io.Dir,
    io: std.Io,
) !mcp.ToolResult {
    var todos = try loadTodos(allocator, base, io);
    defer freeTodos(allocator, &todos);

    var removed: usize = 0;
    var i: usize = 0;
    while (i < todos.items.len) {
        if (todos.items[i].status == .done) {
            const removed_todo = todos.orderedRemove(i);
            allocator.free(removed_todo.text);
            removed += 1;
        } else {
            i += 1;
        }
    }

    try saveTodos(allocator, base, io, todos.items);

    return .{
        .text = try std.fmt.allocPrint(
            allocator,
            "Cleared {d} done todo(s). {d} open todo(s) remain.",
            .{ removed, todos.items.len },
        ),
    };
}

// ---------------------------------------------------------------------------
// MCP handlers — use g_io for file ops (set in main before mcp.run)
// ---------------------------------------------------------------------------

fn handleAdd(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    _ = io;
    const obj = switch (args) {
        .object => |o| o,
        else => return .{ .text = "expected object args", .is_error = true },
    };

    const text_v = obj.get("text") orelse return .{ .text = "missing required field: text", .is_error = true };
    const text = switch (text_v) {
        .string => |s| s,
        else => return .{ .text = "text must be a string", .is_error = true },
    };

    var priority: Priority = .normal;
    if (obj.get("priority")) |pv| {
        const ps = switch (pv) {
            .string => |s| s,
            else => return .{ .text = "priority must be a string", .is_error = true },
        };
        priority = Priority.fromString(ps) orelse return .{
            .text = try std.fmt.allocPrint(allocator, "invalid priority: {s}. Use low, normal, or high", .{ps}),
            .is_error = true,
        };
    }

    return addTodo(allocator, std.Io.Dir.cwd(), g_io, text, priority);
}

fn handleList(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    _ = io;
    var filter: []const u8 = "all";
    switch (args) {
        .object => |obj| {
            if (obj.get("filter")) |fv| {
                filter = switch (fv) {
                    .string => |s| s,
                    else => return .{ .text = "filter must be a string", .is_error = true },
                };
            }
        },
        .null => {},
        else => return .{ .text = "expected object args", .is_error = true },
    }

    return listTodos(allocator, std.Io.Dir.cwd(), g_io, filter);
}

fn handleDone(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    _ = io;
    const obj = switch (args) {
        .object => |o| o,
        else => return .{ .text = "expected object args", .is_error = true },
    };

    const id_v = obj.get("id") orelse return .{ .text = "missing required field: id", .is_error = true };
    const id = switch (id_v) {
        .string => |s| s,
        else => return .{ .text = "id must be a string", .is_error = true },
    };

    if (id.len != 8) {
        return .{ .text = "id must be an 8-char hex string", .is_error = true };
    }

    return doneTodo(allocator, std.Io.Dir.cwd(), g_io, id);
}

fn handleRemove(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    _ = io;
    const obj = switch (args) {
        .object => |o| o,
        else => return .{ .text = "expected object args", .is_error = true },
    };

    const id_v = obj.get("id") orelse return .{ .text = "missing required field: id", .is_error = true };
    const id = switch (id_v) {
        .string => |s| s,
        else => return .{ .text = "id must be a string", .is_error = true },
    };

    if (id.len != 8) {
        return .{ .text = "id must be an 8-char hex string", .is_error = true };
    }

    return removeTodo(allocator, std.Io.Dir.cwd(), g_io, id);
}

fn handleClear(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    _ = io;
    _ = args;
    return clearDone(allocator, std.Io.Dir.cwd(), g_io);
}

// ---------------------------------------------------------------------------
// Tool table
// ---------------------------------------------------------------------------

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "todo_add",
        .description = "Add a new todo item to the per-project scratchpad. State persists in <cwd>/.pid/todo.json.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "text": {
        \\      "type": "string",
        \\      "description": "The todo item text."
        \\    },
        \\    "priority": {
        \\      "type": "string",
        \\      "enum": ["low", "normal", "high"],
        \\      "description": "Priority level. Defaults to normal."
        \\    }
        \\  },
        \\  "required": ["text"],
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleAdd,
    },
    .{
        .name = "todo_list",
        .description = "List todo items. Optionally filter by status.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "filter": {
        \\      "type": "string",
        \\      "enum": ["all", "open", "done"],
        \\      "description": "Which todos to show. Defaults to all."
        \\    }
        \\  },
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleList,
        .read_only = true,
    },
    .{
        .name = "todo_done",
        .description = "Mark a todo as done by its 8-char hex ID.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "id": {
        \\      "type": "string",
        \\      "description": "8-char hex ID of the todo to mark done."
        \\    }
        \\  },
        \\  "required": ["id"],
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleDone,
    },
    .{
        .name = "todo_remove",
        .description = "Delete a todo by its 8-char hex ID.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "id": {
        \\      "type": "string",
        \\      "description": "8-char hex ID of the todo to delete."
        \\    }
        \\  },
        \\  "required": ["id"],
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleRemove,
        .destructive = true,
    },
    .{
        .name = "todo_clear",
        .description = "Remove all done todos, keeping only open ones.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {},
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleClear,
        .destructive = true,
    },
};

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    g_io = init.io;

    try mcp.run(
        arena,
        init.io,
        .{ .name = "zmcp-todo", .version = "0.1.0" },
        &tool_table,
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "add then list returns the todo" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = try addTodo(alloc, tmp.dir, io, "buy milk", .normal);
    defer alloc.free(result.text);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "buy milk") != null);

    const list_result = try listTodos(alloc, tmp.dir, io, "all");
    defer alloc.free(list_result.text);
    try std.testing.expect(!list_result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, list_result.text, "buy milk") != null);
}

test "done changes status and sets done_ms" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const add_result = try addTodo(alloc, tmp.dir, io, "write tests", .high);
    defer alloc.free(add_result.text);

    // Extract id from result text "[xxxxxxxx]"
    const text = add_result.text;
    const id_start = std.mem.indexOf(u8, text, "[") orelse unreachable;
    const id = text[id_start + 1 .. id_start + 9];

    const done_result = try doneTodo(alloc, tmp.dir, io, id);
    defer alloc.free(done_result.text);
    try std.testing.expect(!done_result.is_error);

    // List only open — should be empty
    const open_result = try listTodos(alloc, tmp.dir, io, "open");
    defer alloc.free(open_result.text);
    try std.testing.expectEqualStrings("(no todos)", open_result.text);

    // List done — should contain the todo
    const done_list = try listTodos(alloc, tmp.dir, io, "done");
    defer alloc.free(done_list.text);
    try std.testing.expect(std.mem.indexOf(u8, done_list.text, "write tests") != null);

    // Verify done_ms was set
    var todos = try loadTodos(alloc, tmp.dir, io);
    defer {
        for (todos.items) |t| alloc.free(t.text);
        todos.deinit(alloc);
    }
    try std.testing.expect(todos.items[0].done_ms != null);
}

test "remove drops the todo" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const add_result = try addTodo(alloc, tmp.dir, io, "task to remove", .low);
    defer alloc.free(add_result.text);

    const text = add_result.text;
    const id_start = std.mem.indexOf(u8, text, "[") orelse unreachable;
    const id = text[id_start + 1 .. id_start + 9];

    const remove_result = try removeTodo(alloc, tmp.dir, io, id);
    defer alloc.free(remove_result.text);
    try std.testing.expect(!remove_result.is_error);

    const list_result = try listTodos(alloc, tmp.dir, io, "all");
    defer alloc.free(list_result.text);
    try std.testing.expectEqualStrings("(no todos)", list_result.text);
}

test "clear leaves only open todos" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Add two todos
    const a1 = try addTodo(alloc, tmp.dir, io, "open task", .normal);
    defer alloc.free(a1.text);
    const a2 = try addTodo(alloc, tmp.dir, io, "done task", .normal);
    defer alloc.free(a2.text);

    // Mark second done
    const t2 = a2.text;
    const id2_start = std.mem.indexOf(u8, t2, "[") orelse unreachable;
    const id2 = t2[id2_start + 1 .. id2_start + 9];

    const done_r = try doneTodo(alloc, tmp.dir, io, id2);
    defer alloc.free(done_r.text);

    // Clear done
    const clear_r = try clearDone(alloc, tmp.dir, io);
    defer alloc.free(clear_r.text);
    try std.testing.expect(!clear_r.is_error);

    // List all — only open remains
    const list_r = try listTodos(alloc, tmp.dir, io, "all");
    defer alloc.free(list_r.text);
    try std.testing.expect(std.mem.indexOf(u8, list_r.text, "open task") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_r.text, "done task") == null);
}

test "persistence: write then re-read all entries present" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const r1 = try addTodo(alloc, tmp.dir, io, "persistent task one", .high);
    defer alloc.free(r1.text);
    const r2 = try addTodo(alloc, tmp.dir, io, "persistent task two", .low);
    defer alloc.free(r2.text);

    // Load fresh from disk
    var todos = try loadTodos(alloc, tmp.dir, io);
    defer {
        for (todos.items) |t| alloc.free(t.text);
        todos.deinit(alloc);
    }

    try std.testing.expectEqual(@as(usize, 2), todos.items.len);
    try std.testing.expectEqualStrings("persistent task one", todos.items[0].text);
    try std.testing.expectEqualStrings("persistent task two", todos.items[1].text);
    try std.testing.expectEqual(Priority.high, todos.items[0].priority);
    try std.testing.expectEqual(Priority.low, todos.items[1].priority);
}
