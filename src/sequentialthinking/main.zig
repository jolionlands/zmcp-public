//! zmcp-sequentialthinking - pure-Zig port of
//! @modelcontextprotocol/server-sequential-thinking (v0.2.0).
//!
//! One tool, `sequentialthinking`: an in-memory state machine that tracks a
//! thought history and named branches, revises totalThoughts upward when a
//! thought number exceeds it, and returns a JSON status summary.

const std = @import("std");
const builtin = @import("builtin");
const mcp = @import("mcp");

/// The `io` handed to `main`; environment lookups go through `mcp.envAlloc`,
/// which reads the real process environment behind it on every OS.
var g_env_io: ?std.Io = null;

/// Owned copy of environment variable `key` (caller frees), or null if unset.
fn envOwned(alloc: std.mem.Allocator, key: []const u8) ?[]u8 {
    const io = g_env_io orelse return null;
    return mcp.envAlloc(alloc, io, key);
}


pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    g_env_io = init.io;
    const io = init.io;
    try mcp.run(arena, io, .{ .name = "zmcp-sequentialthinking", .version = "0.2.0" }, &tool_table);
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "sequentialthinking",
        .description = tool_description,
        .input_schema_json = input_schema_json,
        .handler = handleSequentialThinking,
    },
};

const tool_description =
    \\A detailed tool for dynamic and reflective problem-solving through thoughts.
    \\This tool helps analyze problems through a flexible thinking process that can adapt and evolve.
    \\Each thought can build on, question, or revise previous insights as understanding deepens.
    \\
    \\When to use this tool:
    \\- Breaking down complex problems into steps
    \\- Planning and design with room for revision
    \\- Analysis that might need course correction
    \\- Problems where the full scope might not be clear initially
    \\- Problems that require a multi-step solution
    \\- Tasks that need to maintain context over multiple steps
    \\- Situations where irrelevant information needs to be filtered out
    \\
    \\Key features:
    \\- You can adjust total_thoughts up or down as you progress
    \\- You can question or revise previous thoughts
    \\- You can add more thoughts even after reaching what seemed like the end
    \\- You can express uncertainty and explore alternative approaches
    \\- Not every thought needs to build linearly - you can branch or backtrack
    \\- Generates a solution hypothesis
    \\- Verifies the hypothesis based on the Chain of Thought steps
    \\- Repeats the process until satisfied
    \\- Provides a correct answer
    \\
    \\Parameters explained:
    \\- thought: Your current thinking step, which can include:
    \\  * Regular analytical steps
    \\  * Revisions of previous thoughts
    \\  * Questions about previous decisions
    \\  * Realizations about needing more analysis
    \\  * Changes in approach
    \\  * Hypothesis generation
    \\  * Hypothesis verification
    \\- nextThoughtNeeded: True if you need more thinking, even if at what seemed like the end
    \\- thoughtNumber: Current number in sequence (can go beyond initial total if needed)
    \\- totalThoughts: Current estimate of thoughts needed (can be adjusted up/down)
    \\- isRevision: A boolean indicating if this thought revises previous thinking
    \\- revisesThought: If is_revision is true, which thought number is being reconsidered
    \\- branchFromThought: If branching, which thought number is the branching point
    \\- branchId: Identifier for the current branch (if any)
    \\- needsMoreThoughts: If reaching end but realizing more thoughts needed
    \\
    \\You should:
    \\1. Start with an initial estimate of needed thoughts, but be ready to adjust
    \\2. Feel free to question or revise previous thoughts
    \\3. Don't hesitate to add more thoughts if needed, even at the "end"
    \\4. Express uncertainty when present
    \\5. Mark thoughts that revise previous thinking or branch into new paths
    \\6. Ignore information that is irrelevant to the current step
    \\7. Generate a solution hypothesis when appropriate
    \\8. Verify the hypothesis based on the Chain of Thought steps
    \\9. Repeat the process until satisfied with the solution
    \\10. Provide a single, ideally correct answer as the final output
    \\11. Only set nextThoughtNeeded to false when truly done and a satisfactory answer is reached
;

const input_schema_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "thought": { "type": "string", "description": "Your current thinking step" },
    \\    "nextThoughtNeeded": { "type": "boolean", "description": "Whether another thought step is needed" },
    \\    "thoughtNumber": { "type": "integer", "minimum": 1, "description": "Current thought number (numeric value, e.g., 1, 2, 3)" },
    \\    "totalThoughts": { "type": "integer", "minimum": 1, "description": "Estimated total thoughts needed (numeric value, e.g., 5, 10)" },
    \\    "isRevision": { "type": "boolean", "description": "Whether this revises previous thinking" },
    \\    "revisesThought": { "type": "integer", "minimum": 1, "description": "Which thought is being reconsidered" },
    \\    "branchFromThought": { "type": "integer", "minimum": 1, "description": "Branching point thought number" },
    \\    "branchId": { "type": "string", "description": "Branch identifier" },
    \\    "needsMoreThoughts": { "type": "boolean", "description": "If more thoughts are needed" }
    \\  },
    \\  "required": ["thought", "nextThoughtNeeded", "thoughtNumber", "totalThoughts"]
    \\}
;

// ---------------------------------------------------------------------------
// State machine
// ---------------------------------------------------------------------------

pub const ThoughtData = struct {
    thought: []const u8,
    next_thought_needed: bool,
    thought_number: i64,
    total_thoughts: i64,
    is_revision: ?bool = null,
    revises_thought: ?i64 = null,
    branch_from_thought: ?i64 = null,
    branch_id: ?[]const u8 = null,
    needs_more_thoughts: ?bool = null,
};

pub const ThoughtStatus = struct {
    thought_number: i64,
    total_thoughts: i64,
    next_thought_needed: bool,
    /// Branch ids in first-seen (insertion) order, like JS Object.keys.
    branches: []const []const u8,
    thought_history_length: usize,
};

pub const SequentialThinkingServer = struct {
    allocator: std.mem.Allocator,
    thought_history: std.ArrayList(ThoughtData) = .empty,
    branches: std.StringHashMap(std.ArrayList(ThoughtData)),
    branch_order: std.ArrayList([]const u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) SequentialThinkingServer {
        return .{
            .allocator = allocator,
            .branches = std.StringHashMap(std.ArrayList(ThoughtData)).init(allocator),
        };
    }

    pub fn deinit(self: *SequentialThinkingServer) void {
        // String fields were duped once per thought; every branched thought is
        // also in the history, so free strings exactly once via the history.
        for (self.thought_history.items) |t| {
            self.allocator.free(t.thought);
            if (t.branch_id) |bid| self.allocator.free(bid);
        }
        self.thought_history.deinit(self.allocator);
        var it = self.branches.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.branches.deinit();
        self.branch_order.deinit(self.allocator);
    }

    /// Record one thought. String fields are duplicated, so the caller keeps
    /// ownership of `input`'s memory.
    pub fn processThought(self: *SequentialThinkingServer, input: ThoughtData) !ThoughtStatus {
        var data = input;
        // Adjust totalThoughts if thoughtNumber exceeds it.
        if (data.thought_number > data.total_thoughts) data.total_thoughts = data.thought_number;

        data.thought = try self.allocator.dupe(u8, data.thought);
        errdefer self.allocator.free(data.thought);
        if (data.branch_id) |bid| {
            data.branch_id = try self.allocator.dupe(u8, bid);
        }
        errdefer if (data.branch_id) |bid| self.allocator.free(bid);

        try self.thought_history.append(self.allocator, data);

        if (data.branch_from_thought != null and data.branch_id != null) {
            const bid = data.branch_id.?;
            if (self.branches.getPtr(bid)) |list| {
                try list.append(self.allocator, data);
            } else {
                const key = try self.allocator.dupe(u8, bid);
                try self.branches.put(key, .empty);
                try self.branches.getPtr(key).?.append(self.allocator, data);
                try self.branch_order.append(self.allocator, key);
            }
        }

        return .{
            .thought_number = data.thought_number,
            .total_thoughts = data.total_thoughts,
            .next_thought_needed = data.next_thought_needed,
            .branches = self.branch_order.items,
            .thought_history_length = self.thought_history.items.len,
        };
    }
};

/// Length as JavaScript's String.length would report it (UTF-16 code units),
/// so box widths match the reference even for emoji/astral characters.
fn utf16Len(s: []const u8) usize {
    const view = std.unicode.Utf8View.init(s) catch return s.len;
    var n: usize = 0;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        n += if (cp > 0xFFFF) 2 else 1;
    }
    return n;
}

fn appendRepeat(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8, n: usize) !void {
    for (0..n) |_| try out.appendSlice(alloc, s);
}

/// Render the box-formatted thought written to stderr (chalk colors omitted).
pub fn formatThought(alloc: std.mem.Allocator, data: ThoughtData) ![]u8 {
    var prefix: []const u8 = undefined;
    var context: []const u8 = "";
    var ctx_buf: [128]u8 = undefined;
    if (data.is_revision orelse false) {
        prefix = "🔄 Revision";
        context = std.fmt.bufPrint(&ctx_buf, " (revising thought {d})", .{data.revises_thought orelse 0}) catch "";
    } else if (data.branch_from_thought) |from| {
        prefix = "🌿 Branch";
        context = std.fmt.bufPrint(&ctx_buf, " (from thought {d}, ID: {s})", .{ from, data.branch_id orelse "" }) catch "";
    } else {
        prefix = "💭 Thought";
    }

    const header = try std.fmt.allocPrint(alloc, "{s} {d}/{d}{s}", .{ prefix, data.thought_number, data.total_thoughts, context });
    defer alloc.free(header);

    const header_len = utf16Len(header);
    const thought_len = utf16Len(data.thought);
    const border_len = @max(header_len, thought_len) + 4;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "\n┌");
    try appendRepeat(&out, alloc, "─", border_len);
    try out.appendSlice(alloc, "┐\n│ ");
    try out.appendSlice(alloc, header);
    try out.appendSlice(alloc, " │\n├");
    try appendRepeat(&out, alloc, "─", border_len);
    try out.appendSlice(alloc, "┤\n│ ");
    try out.appendSlice(alloc, data.thought);
    // padEnd(border.length - 2): spaces, no truncation when longer.
    if (border_len >= 2 and thought_len < border_len - 2) {
        try appendRepeat(&out, alloc, " ", border_len - 2 - thought_len);
    }
    try out.appendSlice(alloc, " │\n└");
    try appendRepeat(&out, alloc, "─", border_len);
    try out.appendSlice(alloc, "┘");
    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Argument validation + handler plumbing
// ---------------------------------------------------------------------------

const ParseResult = union(enum) {
    ok: ThoughtData,
    err: []const u8,
};

fn intGe1(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |i| if (i >= 1) i else null,
        .float => |f| blk: {
            if (f != @trunc(f) or f < 1 or f > 9.0e15) break :blk null;
            break :blk @intFromFloat(f);
        },
        else => null,
    };
}

fn parseArgs(args: std.json.Value) ParseResult {
    if (args != .object) return .{ .err = "Invalid arguments: expected object" };

    const thought_v = args.object.get("thought") orelse return .{ .err = "Invalid thought: must be a string" };
    if (thought_v != .string) return .{ .err = "Invalid thought: must be a string" };

    const next_v = args.object.get("nextThoughtNeeded") orelse return .{ .err = "Invalid nextThoughtNeeded: must be a boolean" };
    if (next_v != .bool) return .{ .err = "Invalid nextThoughtNeeded: must be a boolean" };

    const num_v = args.object.get("thoughtNumber") orelse return .{ .err = "Invalid thoughtNumber: must be an integer >= 1" };
    const num = intGe1(num_v) orelse return .{ .err = "Invalid thoughtNumber: must be an integer >= 1" };

    const total_v = args.object.get("totalThoughts") orelse return .{ .err = "Invalid totalThoughts: must be an integer >= 1" };
    const total = intGe1(total_v) orelse return .{ .err = "Invalid totalThoughts: must be an integer >= 1" };

    var data = ThoughtData{
        .thought = thought_v.string,
        .next_thought_needed = next_v.bool,
        .thought_number = num,
        .total_thoughts = total,
    };

    if (args.object.get("isRevision")) |v| {
        if (v != .bool) return .{ .err = "Invalid isRevision: must be a boolean" };
        data.is_revision = v.bool;
    }
    if (args.object.get("revisesThought")) |v| {
        data.revises_thought = intGe1(v) orelse return .{ .err = "Invalid revisesThought: must be an integer >= 1" };
    }
    if (args.object.get("branchFromThought")) |v| {
        data.branch_from_thought = intGe1(v) orelse return .{ .err = "Invalid branchFromThought: must be an integer >= 1" };
    }
    if (args.object.get("branchId")) |v| {
        if (v != .string) return .{ .err = "Invalid branchId: must be a string" };
        data.branch_id = v.string;
    }
    if (args.object.get("needsMoreThoughts")) |v| {
        if (v != .bool) return .{ .err = "Invalid needsMoreThoughts: must be a boolean" };
        data.needs_more_thoughts = v.bool;
    }

    return .{ .ok = data };
}

fn statusJson(alloc: std.mem.Allocator, status: ThoughtStatus) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var js = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try js.beginObject();
    try js.objectField("thoughtNumber");
    try js.write(status.thought_number);
    try js.objectField("totalThoughts");
    try js.write(status.total_thoughts);
    try js.objectField("nextThoughtNeeded");
    try js.write(status.next_thought_needed);
    try js.objectField("branches");
    try js.beginArray();
    for (status.branches) |b| try js.write(b);
    try js.endArray();
    try js.objectField("thoughtHistoryLength");
    try js.write(status.thought_history_length);
    try js.endObject();
    return out.toOwnedSlice();
}

fn errorJson(alloc: std.mem.Allocator, msg: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var js = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try js.beginObject();
    try js.objectField("error");
    try js.write(msg);
    try js.objectField("status");
    try js.write("failed");
    try js.endObject();
    return out.toOwnedSlice();
}

fn thoughtLoggingDisabled(alloc: std.mem.Allocator) bool {
    const v = envOwned(alloc, "DISABLE_THOUGHT_LOGGING") orelse return false;
    defer alloc.free(v);
    return std.ascii.eqlIgnoreCase(v, "true");
}

fn writeStderr(io: std.Io, text: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w: std.Io.File.Writer = .init(.stderr(), io, &buf);
    const stderr = &w.interface;
    stderr.writeAll(text) catch return;
    stderr.writeByte('\n') catch return;
    stderr.flush() catch return;
}

fn callTool(server: *SequentialThinkingServer, alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const input = switch (parseArgs(args)) {
        .ok => |d| d,
        .err => |msg| return .{ .text = try errorJson(alloc, msg), .is_error = true },
    };

    const status = try server.processThought(input);

    if (!builtin.is_test and !thoughtLoggingDisabled(alloc)) {
        // The reference formats the thought after the totalThoughts bump.
        var fmt_data = input;
        if (fmt_data.thought_number > fmt_data.total_thoughts) fmt_data.total_thoughts = fmt_data.thought_number;
        const formatted = try formatThought(alloc, fmt_data);
        defer alloc.free(formatted);
        writeStderr(io, formatted);
    }

    return .{ .text = try statusJson(alloc, status) };
}

fn handleSequentialThinking(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    return callTool(globalServer(), alloc, io, args);
}

// Session state lives for the whole process (the per-call arena the framework
// hands to handlers is torn down after each call), so it gets its own arena.
var g_state_arena: ?std.heap.ArenaAllocator = null;
var g_server: ?SequentialThinkingServer = null;

fn globalServer() *SequentialThinkingServer {
    if (g_server == null) {
        g_state_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        g_server = SequentialThinkingServer.init(g_state_arena.?.allocator());
    }
    return &g_server.?;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testServer() SequentialThinkingServer {
    return SequentialThinkingServer.init(std.testing.allocator);
}

fn parseJson(alloc: std.mem.Allocator, s: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, s, .{});
}

fn expectInvalid(args_json: []const u8, want_msg: []const u8) !void {
    const alloc = std.testing.allocator;
    var parsed = try parseJson(alloc, args_json);
    defer parsed.deinit();
    switch (parseArgs(parsed.value)) {
        .ok => return error.TestExpectedError,
        .err => |msg| try std.testing.expectEqualStrings(want_msg, msg),
    }
}

test "records a basic thought in history" {
    var srv = testServer();
    defer srv.deinit();

    const status = try srv.processThought(.{
        .thought = "first step",
        .next_thought_needed = true,
        .thought_number = 1,
        .total_thoughts = 3,
    });

    try std.testing.expectEqual(@as(i64, 1), status.thought_number);
    try std.testing.expectEqual(@as(i64, 3), status.total_thoughts);
    try std.testing.expect(status.next_thought_needed);
    try std.testing.expectEqual(@as(usize, 1), status.thought_history_length);
    try std.testing.expectEqual(@as(usize, 0), status.branches.len);

    try std.testing.expectEqual(@as(usize, 1), srv.thought_history.items.len);
    try std.testing.expectEqualStrings("first step", srv.thought_history.items[0].thought);
    try std.testing.expectEqual(@as(i64, 1), srv.thought_history.items[0].thought_number);
}

test "adjusts totalThoughts upward when thoughtNumber exceeds it" {
    var srv = testServer();
    defer srv.deinit();

    const status = try srv.processThought(.{
        .thought = "need more room",
        .next_thought_needed = true,
        .thought_number = 5,
        .total_thoughts = 3,
    });

    try std.testing.expectEqual(@as(i64, 5), status.total_thoughts);
    try std.testing.expectEqual(@as(i64, 5), srv.thought_history.items[0].total_thoughts);
}

test "does not lower totalThoughts when thoughtNumber is smaller" {
    var srv = testServer();
    defer srv.deinit();

    const status = try srv.processThought(.{
        .thought = "still lots to do",
        .next_thought_needed = true,
        .thought_number = 2,
        .total_thoughts = 10,
    });

    try std.testing.expectEqual(@as(i64, 10), status.total_thoughts);
}

test "tracks history across sequential thoughts in order" {
    var srv = testServer();
    defer srv.deinit();

    _ = try srv.processThought(.{ .thought = "one", .next_thought_needed = true, .thought_number = 1, .total_thoughts = 3 });
    _ = try srv.processThought(.{ .thought = "two", .next_thought_needed = true, .thought_number = 2, .total_thoughts = 3 });
    const status = try srv.processThought(.{ .thought = "three", .next_thought_needed = false, .thought_number = 3, .total_thoughts = 3 });

    try std.testing.expectEqual(@as(usize, 3), status.thought_history_length);
    try std.testing.expect(!status.next_thought_needed);
    try std.testing.expectEqualStrings("one", srv.thought_history.items[0].thought);
    try std.testing.expectEqualStrings("two", srv.thought_history.items[1].thought);
    try std.testing.expectEqualStrings("three", srv.thought_history.items[2].thought);
}

test "records revision metadata in history" {
    var srv = testServer();
    defer srv.deinit();

    _ = try srv.processThought(.{ .thought = "initial", .next_thought_needed = true, .thought_number = 1, .total_thoughts = 2 });
    _ = try srv.processThought(.{
        .thought = "rethinking the first step",
        .next_thought_needed = false,
        .thought_number = 2,
        .total_thoughts = 2,
        .is_revision = true,
        .revises_thought = 1,
    });

    const revised = srv.thought_history.items[1];
    try std.testing.expectEqual(@as(?bool, true), revised.is_revision);
    try std.testing.expectEqual(@as(?i64, 1), revised.revises_thought);
}

test "creates a branch when branchFromThought and branchId are set" {
    var srv = testServer();
    defer srv.deinit();

    _ = try srv.processThought(.{ .thought = "main line", .next_thought_needed = true, .thought_number = 1, .total_thoughts = 3 });
    const status = try srv.processThought(.{
        .thought = "alternative path",
        .next_thought_needed = true,
        .thought_number = 2,
        .total_thoughts = 3,
        .branch_from_thought = 1,
        .branch_id = "alt-1",
    });

    try std.testing.expectEqual(@as(usize, 1), status.branches.len);
    try std.testing.expectEqualStrings("alt-1", status.branches[0]);

    const branch = srv.branches.get("alt-1") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), branch.items.len);
    try std.testing.expectEqualStrings("alternative path", branch.items[0].thought);
}

test "does not branch when branchId is missing" {
    var srv = testServer();
    defer srv.deinit();

    const status = try srv.processThought(.{
        .thought = "branch point without id",
        .next_thought_needed = true,
        .thought_number = 2,
        .total_thoughts = 3,
        .branch_from_thought = 1,
    });

    try std.testing.expectEqual(@as(usize, 0), status.branches.len);
    try std.testing.expectEqual(@as(usize, 0), srv.branches.count());
}

test "does not branch when branchFromThought is missing" {
    var srv = testServer();
    defer srv.deinit();

    const status = try srv.processThought(.{
        .thought = "id without branch point",
        .next_thought_needed = true,
        .thought_number = 2,
        .total_thoughts = 3,
        .branch_id = "dangling",
    });

    try std.testing.expectEqual(@as(usize, 0), status.branches.len);
    try std.testing.expectEqual(@as(usize, 0), srv.branches.count());
}

test "multiple branches are reported in insertion order" {
    var srv = testServer();
    defer srv.deinit();

    _ = try srv.processThought(.{ .thought = "root", .next_thought_needed = true, .thought_number = 1, .total_thoughts = 4 });
    _ = try srv.processThought(.{ .thought = "b1", .next_thought_needed = true, .thought_number = 2, .total_thoughts = 4, .branch_from_thought = 1, .branch_id = "beta" });
    _ = try srv.processThought(.{ .thought = "b2", .next_thought_needed = true, .thought_number = 3, .total_thoughts = 4, .branch_from_thought = 1, .branch_id = "alpha" });
    const status = try srv.processThought(.{ .thought = "b1 again", .next_thought_needed = true, .thought_number = 4, .total_thoughts = 4, .branch_from_thought = 1, .branch_id = "beta" });

    try std.testing.expectEqual(@as(usize, 2), status.branches.len);
    try std.testing.expectEqualStrings("beta", status.branches[0]);
    try std.testing.expectEqualStrings("alpha", status.branches[1]);

    const beta = srv.branches.get("beta").?;
    try std.testing.expectEqual(@as(usize, 2), beta.items.len);
    try std.testing.expectEqualStrings("b1 again", beta.items[1].thought);
}

test "validation: missing thought" {
    try expectInvalid(
        \\{"nextThoughtNeeded": true, "thoughtNumber": 1, "totalThoughts": 3}
    , "Invalid thought: must be a string");
}

test "validation: thought wrong type" {
    try expectInvalid(
        \\{"thought": 42, "nextThoughtNeeded": true, "thoughtNumber": 1, "totalThoughts": 3}
    , "Invalid thought: must be a string");
}

test "validation: missing nextThoughtNeeded" {
    try expectInvalid(
        \\{"thought": "x", "thoughtNumber": 1, "totalThoughts": 3}
    , "Invalid nextThoughtNeeded: must be a boolean");
}

test "validation: thoughtNumber below 1" {
    try expectInvalid(
        \\{"thought": "x", "nextThoughtNeeded": true, "thoughtNumber": 0, "totalThoughts": 3}
    , "Invalid thoughtNumber: must be an integer >= 1");
}

test "validation: thoughtNumber non-integer" {
    try expectInvalid(
        \\{"thought": "x", "nextThoughtNeeded": true, "thoughtNumber": 1.5, "totalThoughts": 3}
    , "Invalid thoughtNumber: must be an integer >= 1");
}

test "validation: integral float thoughtNumber accepted" {
    const alloc = std.testing.allocator;
    var parsed = try parseJson(alloc,
        \\{"thought": "x", "nextThoughtNeeded": true, "thoughtNumber": 2.0, "totalThoughts": 3}
    );
    defer parsed.deinit();
    switch (parseArgs(parsed.value)) {
        .ok => |d| try std.testing.expectEqual(@as(i64, 2), d.thought_number),
        .err => return error.TestExpectedEqual,
    }
}

test "validation: totalThoughts below 1" {
    try expectInvalid(
        \\{"thought": "x", "nextThoughtNeeded": true, "thoughtNumber": 1, "totalThoughts": 0}
    , "Invalid totalThoughts: must be an integer >= 1");
}

test "validation: isRevision wrong type" {
    try expectInvalid(
        \\{"thought": "x", "nextThoughtNeeded": true, "thoughtNumber": 1, "totalThoughts": 3, "isRevision": "yes"}
    , "Invalid isRevision: must be a boolean");
}

test "validation: revisesThought below 1" {
    try expectInvalid(
        \\{"thought": "x", "nextThoughtNeeded": true, "thoughtNumber": 2, "totalThoughts": 3, "isRevision": true, "revisesThought": 0}
    , "Invalid revisesThought: must be an integer >= 1");
}

test "validation: branchId wrong type" {
    try expectInvalid(
        \\{"thought": "x", "nextThoughtNeeded": true, "thoughtNumber": 2, "totalThoughts": 3, "branchId": 7}
    , "Invalid branchId: must be a string");
}

test "validation: non-object arguments" {
    try expectInvalid(
        \\[1, 2, 3]
    , "Invalid arguments: expected object");
}

test "callTool returns failed-status error JSON on invalid input" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var srv = testServer();
    defer srv.deinit();

    var parsed = try parseJson(alloc,
        \\{"thought": "x"}
    );
    defer parsed.deinit();

    const result = try callTool(&srv, alloc, io, parsed.value);
    defer alloc.free(result.text);
    try std.testing.expect(result.is_error);

    var out = try parseJson(alloc, result.text);
    defer out.deinit();
    try std.testing.expectEqualStrings("failed", out.value.object.get("status").?.string);
    try std.testing.expect(out.value.object.get("error") != null);
}

test "callTool success returns status JSON" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var srv = testServer();
    defer srv.deinit();

    var parsed = try parseJson(alloc,
        \\{"thought": "step one", "nextThoughtNeeded": true, "thoughtNumber": 2, "totalThoughts": 1, "branchFromThought": 1, "branchId": "b"}
    );
    defer parsed.deinit();

    const result = try callTool(&srv, alloc, io, parsed.value);
    defer alloc.free(result.text);
    try std.testing.expect(!result.is_error);

    var out = try parseJson(alloc, result.text);
    defer out.deinit();
    const obj = out.value.object;
    try std.testing.expectEqual(@as(i64, 2), obj.get("thoughtNumber").?.integer);
    // adjusted upward from 1 to 2
    try std.testing.expectEqual(@as(i64, 2), obj.get("totalThoughts").?.integer);
    try std.testing.expect(obj.get("nextThoughtNeeded").?.bool);
    try std.testing.expectEqual(@as(i64, 1), obj.get("thoughtHistoryLength").?.integer);
    const branches = obj.get("branches").?.array;
    try std.testing.expectEqual(@as(usize, 1), branches.items.len);
    try std.testing.expectEqualStrings("b", branches.items[0].string);
}

test "formatThought renders a default thought box" {
    const alloc = std.testing.allocator;
    const s = try formatThought(alloc, .{
        .thought = "hello",
        .next_thought_needed = true,
        .thought_number = 1,
        .total_thoughts = 3,
    });
    defer alloc.free(s);

    try std.testing.expect(std.mem.indexOf(u8, s, "💭 Thought 1/3") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "┘") != null);
}

test "formatThought renders a revision" {
    const alloc = std.testing.allocator;
    const s = try formatThought(alloc, .{
        .thought = "changed my mind",
        .next_thought_needed = true,
        .thought_number = 2,
        .total_thoughts = 5,
        .is_revision = true,
        .revises_thought = 1,
    });
    defer alloc.free(s);

    try std.testing.expect(std.mem.indexOf(u8, s, "🔄 Revision 2/5 (revising thought 1)") != null);
}

test "formatThought renders a branch" {
    const alloc = std.testing.allocator;
    const s = try formatThought(alloc, .{
        .thought = "other way",
        .next_thought_needed = true,
        .thought_number = 3,
        .total_thoughts = 4,
        .branch_from_thought = 2,
        .branch_id = "alt",
    });
    defer alloc.free(s);

    try std.testing.expect(std.mem.indexOf(u8, s, "🌿 Branch 3/4 (from thought 2, ID: alt)") != null);
}

test "formatThought border grows with the longest line" {
    const alloc = std.testing.allocator;
    const thought = "a thought that is much longer than the header line itself";
    const s = try formatThought(alloc, .{
        .thought = thought,
        .next_thought_needed = true,
        .thought_number = 1,
        .total_thoughts = 2,
    });
    defer alloc.free(s);

    // The ASCII thought drives the border: thought.len + 4 dashes.
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(alloc);
    try expected.appendSlice(alloc, "┌");
    try appendRepeat(&expected, alloc, "─", thought.len + 4);
    try expected.appendSlice(alloc, "┐");
    try std.testing.expect(std.mem.indexOf(u8, s, expected.items) != null);
}

test "env lookup reads the real process environment (not an empty block)" {
    const alloc = std.testing.allocator;
    g_env_io = std.testing.io;
    defer g_env_io = null;
    const v = envOwned(alloc, "PATH") orelse return error.SkipZigTest;
    defer alloc.free(v);
    try std.testing.expect(v.len > 0);
    try std.testing.expect(envOwned(alloc, "ZMCP_SURELY_UNSET_ENV_VAR_12345") == null);
}
