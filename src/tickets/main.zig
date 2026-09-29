//! zmcp-tickets — paperclip-lite local-only sprint/ticket store for pid.
//!
//! State persists at ~/.pi/agent/tickets/:
//!   tickets.jsonl  — append-only ticket events (open/update/close)
//!   sprints.jsonl  — append-only sprint events (start/progress/cancel)
//!   swarm.jsonl    — append-only swarm-run events
//!
//! "Append-only with last-write-wins" — listTickets folds the JSONL down to
//! current state per id. No SQLite, no HTTP, no daemon. Tools are stdio MCP.
//!
//! Tools:
//!   sprint_start(goal, verify?, schedule?, budget?, plan?) -> sprint_id
//!   sprint_status(sprint_id)
//!   sprint_cancel(sprint_id)
//!   ticket_open(title, body?, severity?, tags?)
//!   ticket_list(status?)
//!   ticket_close(id, resolution?)
//!   ticket_update(id, body?, severity?, status?, tags?)
//!   swarm_run(prompt, n?, profile?, strategy?)
//!   verify_run(recipe?)              — exec a verify command; defaults to env or "echo ok"
//!
//! Mission DAG (per pid/unified-cli-design §4):
//!   sprint_start.plan is a JSON array of step objects:
//!     { "id":"s1", "cmd":"...", "depends_on":["s0"],
//!       "required_artifacts":["a.txt"],
//!       "transitions": { "success":"s2", "failure":"s_recover" } }
//!   This server only PERSISTS the plan; pid's orchestrate command executes it.

const std = @import("std");
const mcp = @import("mcp");



// ---------------------------------------------------------------------------
// Global IO — set in main() before mcp.run.
// ---------------------------------------------------------------------------

var g_io: std.Io = undefined;

// ---------------------------------------------------------------------------
// Path resolution
// ---------------------------------------------------------------------------

const Paths = struct {
    base: []u8, // <home>/.pi/agent/tickets
    tickets: []u8, // <base>/tickets.jsonl
    sprints: []u8, // <base>/sprints.jsonl
    swarm: []u8, // <base>/swarm.jsonl

    pub fn deinit(self: *Paths, alloc: std.mem.Allocator) void {
        alloc.free(self.base);
        alloc.free(self.tickets);
        alloc.free(self.sprints);
        alloc.free(self.swarm);
    }
};

fn getEnv(alloc: std.mem.Allocator, key: []const u8) ?[]u8 {
    return mcp.envAlloc(alloc, g_io, key);
}

fn resolveHome(alloc: std.mem.Allocator) ![]u8 {
    if (getEnv(alloc, "USERPROFILE")) |h| return h;
    if (getEnv(alloc, "HOME")) |h| return h;
    // Last resort: cwd. Better than crashing — tests use overridden paths anyway.
    return alloc.dupe(u8, ".");
}

fn resolvePaths(alloc: std.mem.Allocator) !Paths {
    const home = try resolveHome(alloc);
    defer alloc.free(home);
    const base = try std.fmt.allocPrint(alloc, "{s}/.pi/agent/tickets", .{home});
    const tickets = try std.fmt.allocPrint(alloc, "{s}/tickets.jsonl", .{base});
    const sprints = try std.fmt.allocPrint(alloc, "{s}/sprints.jsonl", .{base});
    const swarm = try std.fmt.allocPrint(alloc, "{s}/swarm.jsonl", .{base});
    return .{ .base = base, .tickets = tickets, .sprints = sprints, .swarm = swarm };
}

/// Ensure ~/.pi/agent/tickets exists. createDirPath is mkdir -p semantics.
fn ensureBaseDir(io: std.Io, paths: Paths) !void {
    std.Io.Dir.cwd().createDirPath(io, paths.base) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

// ---------------------------------------------------------------------------
// JSONL append helpers
// ---------------------------------------------------------------------------

/// Append `line` (newline-terminated) to `path`. Creates file if missing.
///
/// Implementation: read-then-rewrite. JSONL files in this server are kept
/// small (<<1 MB in normal use) so the O(n) cost beats wrestling with
/// Windows append-mode + stat-on-write-only-handle quirks.
fn appendLine(io: std.Io, path: []const u8, line: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const existing = readAllOrEmpty(alloc, io, path) catch &[_]u8{};
    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    try sw.writer.writeAll(existing);
    try sw.writer.writeAll(line);
    try sw.writer.writeByte('\n');

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = sw.written(),
    });
}

/// Read entire file as string. Returns empty slice if not found.
fn readAllOrEmpty(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return alloc.dupe(u8, ""),
        else => return err,
    };
}

// ---------------------------------------------------------------------------
// ID generation — 8-char hex
// ---------------------------------------------------------------------------

fn newId(io: std.Io) [8]u8 {
    var raw: [4]u8 = undefined;
    io.random(&raw);
    var out: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ raw[0], raw[1], raw[2], raw[3] }) catch unreachable;
    return out;
}

fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

fn jsonString(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn jsonInt(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |n| n,
        else => null,
    };
}

fn argString(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return jsonString(v);
}

fn argInt(args: std.json.Value, key: []const u8) ?i64 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return jsonInt(v);
}

fn argValue(args: std.json.Value, key: []const u8) ?std.json.Value {
    if (args != .object) return null;
    return args.object.get(key);
}

/// Stringify a JSON value to a freshly-allocated []u8. Used to persist
/// arbitrary `plan` / `tags` payloads verbatim.
fn jsonStringify(alloc: std.mem.Allocator, v: std.json.Value) ![]u8 {
    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = std.json.Stringify{ .writer = &sw.writer };
    try js.write(v);
    return alloc.dupe(u8, sw.written());
}

// ---------------------------------------------------------------------------
// Ticket state — folded from JSONL events
// ---------------------------------------------------------------------------

const Ticket = struct {
    id: []const u8,
    title: []const u8,
    body: []const u8,
    severity: []const u8, // "low"|"normal"|"high"
    status: []const u8, // "open"|"closed"
    tags_json: []const u8, // raw JSON (array literal) or "[]"
    created_ms: i64,
    updated_ms: i64,
    resolution: []const u8, // empty if not closed
};

/// Fold tickets.jsonl into a map: id → latest Ticket. Caller owns memory
/// (arena alloc recommended).
fn loadTickets(arena: std.mem.Allocator, io: std.Io, paths: Paths) !std.StringArrayHashMapUnmanaged(Ticket) {
    var out: std.StringArrayHashMapUnmanaged(Ticket) = .empty;
    const raw = try readAllOrEmpty(arena, io, paths.tickets);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, arena, line, .{}) catch continue;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };
        const id = jsonString(obj.get("id") orelse continue) orelse continue;
        const event = jsonString(obj.get("event") orelse continue) orelse continue;

        // Start from existing (if any) so updates are merges.
        const existing = out.get(id);
        var t: Ticket = existing orelse Ticket{
            .id = try arena.dupe(u8, id),
            .title = "",
            .body = "",
            .severity = "normal",
            .status = "open",
            .tags_json = "[]",
            .created_ms = 0,
            .updated_ms = 0,
            .resolution = "",
        };

        if (obj.get("title")) |v| if (jsonString(v)) |s| { t.title = try arena.dupe(u8, s); };
        if (obj.get("body")) |v| if (jsonString(v)) |s| { t.body = try arena.dupe(u8, s); };
        if (obj.get("severity")) |v| if (jsonString(v)) |s| { t.severity = try arena.dupe(u8, s); };
        if (obj.get("tags")) |v| { t.tags_json = try jsonStringify(arena, v); }
        if (obj.get("resolution")) |v| if (jsonString(v)) |s| { t.resolution = try arena.dupe(u8, s); };
        if (obj.get("ts_ms")) |v| if (jsonInt(v)) |n| { t.updated_ms = n; };
        if (existing == null) {
            t.created_ms = t.updated_ms;
        }

        if (std.mem.eql(u8, event, "open")) {
            t.status = "open";
        } else if (std.mem.eql(u8, event, "close")) {
            t.status = "closed";
        } else if (std.mem.eql(u8, event, "update")) {
            if (obj.get("status")) |v| if (jsonString(v)) |s| { t.status = try arena.dupe(u8, s); };
        }

        try out.put(arena, t.id, t);
    }
    return out;
}

// ---------------------------------------------------------------------------
// Sprint state — folded from sprints.jsonl
// ---------------------------------------------------------------------------

const Sprint = struct {
    id: []const u8,
    goal: []const u8,
    status: []const u8, // "running"|"completed"|"cancelled"
    verify_json: []const u8, // raw JSON array of verify commands or "[]"
    schedule: []const u8,
    budget: i64,
    plan_json: []const u8, // raw JSON Mission DAG
    created_ms: i64,
    updated_ms: i64,
    progress_count: u32, // number of progress events
    last_progress: []const u8,
};

fn loadSprints(arena: std.mem.Allocator, io: std.Io, paths: Paths) !std.StringArrayHashMapUnmanaged(Sprint) {
    var out: std.StringArrayHashMapUnmanaged(Sprint) = .empty;
    const raw = try readAllOrEmpty(arena, io, paths.sprints);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, arena, line, .{}) catch continue;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };
        const id = jsonString(obj.get("id") orelse continue) orelse continue;
        const event = jsonString(obj.get("event") orelse continue) orelse continue;

        const existing = out.get(id);
        var s: Sprint = existing orelse Sprint{
            .id = try arena.dupe(u8, id),
            .goal = "",
            .status = "running",
            .verify_json = "[]",
            .schedule = "",
            .budget = 0,
            .plan_json = "null",
            .created_ms = 0,
            .updated_ms = 0,
            .progress_count = 0,
            .last_progress = "",
        };

        if (obj.get("goal")) |v| if (jsonString(v)) |x| { s.goal = try arena.dupe(u8, x); };
        if (obj.get("verify")) |v| { s.verify_json = try jsonStringify(arena, v); }
        if (obj.get("schedule")) |v| if (jsonString(v)) |x| { s.schedule = try arena.dupe(u8, x); };
        if (obj.get("budget")) |v| if (jsonInt(v)) |n| { s.budget = n; };
        if (obj.get("plan")) |v| { s.plan_json = try jsonStringify(arena, v); }
        if (obj.get("ts_ms")) |v| if (jsonInt(v)) |n| { s.updated_ms = n; };
        if (existing == null) s.created_ms = s.updated_ms;

        if (std.mem.eql(u8, event, "start")) {
            s.status = "running";
        } else if (std.mem.eql(u8, event, "cancel")) {
            s.status = "cancelled";
        } else if (std.mem.eql(u8, event, "complete")) {
            s.status = "completed";
        } else if (std.mem.eql(u8, event, "progress")) {
            s.progress_count += 1;
            if (obj.get("note")) |v| if (jsonString(v)) |x| { s.last_progress = try arena.dupe(u8, x); };
        }

        try out.put(arena, s.id, s);
    }
    return out;
}

// ---------------------------------------------------------------------------
// Core: ticket_open
// ---------------------------------------------------------------------------

pub fn ticketOpen(
    alloc: std.mem.Allocator,
    io: std.Io,
    paths: Paths,
    title: []const u8,
    body: []const u8,
    severity: []const u8,
    tags_json: []const u8, // pass "[]" for none
) !mcp.ToolResult {
    try ensureBaseDir(io, paths);
    const id = newId(io);
    const ts = nowMs(io);

    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = std.json.Stringify{ .writer = &sw.writer };
    try js.beginObject();
    try js.objectField("event"); try js.write("open");
    try js.objectField("id"); try js.write(id[0..]);
    try js.objectField("ts_ms"); try js.write(ts);
    try js.objectField("title"); try js.write(title);
    try js.objectField("body"); try js.write(body);
    try js.objectField("severity"); try js.write(severity);
    try js.objectField("tags"); try js.beginWriteRaw(); try js.writer.writeAll(tags_json); js.endWriteRaw();
    try js.endObject();

    try appendLine(io, paths.tickets, sw.written());

    const out_text = try std.fmt.allocPrint(
        alloc,
        "{{\"id\":\"{s}\",\"status\":\"open\",\"ts_ms\":{d}}}",
        .{ id[0..], ts },
    );
    return .{ .text = out_text };
}

// ---------------------------------------------------------------------------
// Core: ticket_close
// ---------------------------------------------------------------------------

pub fn ticketClose(
    alloc: std.mem.Allocator,
    io: std.Io,
    paths: Paths,
    id: []const u8,
    resolution: []const u8,
) !mcp.ToolResult {
    try ensureBaseDir(io, paths);
    const ts = nowMs(io);
    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = std.json.Stringify{ .writer = &sw.writer };
    try js.beginObject();
    try js.objectField("event"); try js.write("close");
    try js.objectField("id"); try js.write(id);
    try js.objectField("ts_ms"); try js.write(ts);
    try js.objectField("resolution"); try js.write(resolution);
    try js.endObject();
    try appendLine(io, paths.tickets, sw.written());

    const out_text = try std.fmt.allocPrint(
        alloc,
        "{{\"id\":\"{s}\",\"status\":\"closed\"}}",
        .{id},
    );
    return .{ .text = out_text };
}

// ---------------------------------------------------------------------------
// Core: ticket_update
// ---------------------------------------------------------------------------

pub fn ticketUpdate(
    alloc: std.mem.Allocator,
    io: std.Io,
    paths: Paths,
    id: []const u8,
    body_opt: ?[]const u8,
    severity_opt: ?[]const u8,
    status_opt: ?[]const u8,
    tags_json_opt: ?[]const u8,
) !mcp.ToolResult {
    try ensureBaseDir(io, paths);
    const ts = nowMs(io);
    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = std.json.Stringify{ .writer = &sw.writer };
    try js.beginObject();
    try js.objectField("event"); try js.write("update");
    try js.objectField("id"); try js.write(id);
    try js.objectField("ts_ms"); try js.write(ts);
    if (body_opt) |b| { try js.objectField("body"); try js.write(b); }
    if (severity_opt) |s| { try js.objectField("severity"); try js.write(s); }
    if (status_opt) |s| { try js.objectField("status"); try js.write(s); }
    if (tags_json_opt) |t| {
        try js.objectField("tags");
        try js.beginWriteRaw();
        try js.writer.writeAll(t);
        js.endWriteRaw();
    }
    try js.endObject();
    try appendLine(io, paths.tickets, sw.written());

    const out_text = try std.fmt.allocPrint(alloc, "{{\"id\":\"{s}\",\"updated\":true}}", .{id});
    return .{ .text = out_text };
}

// ---------------------------------------------------------------------------
// Core: ticket_list
// ---------------------------------------------------------------------------

pub fn ticketList(
    alloc: std.mem.Allocator,
    io: std.Io,
    paths: Paths,
    status_filter: []const u8, // "all"|"open"|"closed"
) !mcp.ToolResult {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tickets = try loadTickets(arena, io, paths);

    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = std.json.Stringify{ .writer = &sw.writer };
    try js.beginArray();
    var it = tickets.iterator();
    while (it.next()) |entry| {
        const t = entry.value_ptr.*;
        if (!std.mem.eql(u8, status_filter, "all") and !std.mem.eql(u8, status_filter, t.status)) continue;
        try js.beginObject();
        try js.objectField("id"); try js.write(t.id);
        try js.objectField("title"); try js.write(t.title);
        try js.objectField("severity"); try js.write(t.severity);
        try js.objectField("status"); try js.write(t.status);
        try js.objectField("created_ms"); try js.write(t.created_ms);
        try js.objectField("updated_ms"); try js.write(t.updated_ms);
        try js.endObject();
    }
    try js.endArray();

    return .{ .text = try alloc.dupe(u8, sw.written()) };
}

// ---------------------------------------------------------------------------
// Core: sprint_start
// ---------------------------------------------------------------------------

pub fn sprintStart(
    alloc: std.mem.Allocator,
    io: std.Io,
    paths: Paths,
    goal: []const u8,
    verify_json: []const u8, // JSON array, e.g. ["pytest","ruff"]
    schedule: []const u8,
    budget: i64,
    plan_json: []const u8, // raw JSON Mission DAG (array of steps) or "null"
) !mcp.ToolResult {
    try ensureBaseDir(io, paths);
    const id = newId(io);
    const ts = nowMs(io);
    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = std.json.Stringify{ .writer = &sw.writer };
    try js.beginObject();
    try js.objectField("event"); try js.write("start");
    try js.objectField("id"); try js.write(id[0..]);
    try js.objectField("ts_ms"); try js.write(ts);
    try js.objectField("goal"); try js.write(goal);
    try js.objectField("verify"); try js.beginWriteRaw(); try js.writer.writeAll(verify_json); js.endWriteRaw();
    try js.objectField("schedule"); try js.write(schedule);
    try js.objectField("budget"); try js.write(budget);
    try js.objectField("plan"); try js.beginWriteRaw(); try js.writer.writeAll(plan_json); js.endWriteRaw();
    try js.endObject();
    try appendLine(io, paths.sprints, sw.written());

    const out_text = try std.fmt.allocPrint(
        alloc,
        "{{\"sprint_id\":\"{s}\",\"status\":\"running\",\"ts_ms\":{d}}}",
        .{ id[0..], ts },
    );
    return .{ .text = out_text };
}

pub fn sprintCancel(
    alloc: std.mem.Allocator,
    io: std.Io,
    paths: Paths,
    id: []const u8,
) !mcp.ToolResult {
    try ensureBaseDir(io, paths);
    const ts = nowMs(io);
    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = std.json.Stringify{ .writer = &sw.writer };
    try js.beginObject();
    try js.objectField("event"); try js.write("cancel");
    try js.objectField("id"); try js.write(id);
    try js.objectField("ts_ms"); try js.write(ts);
    try js.endObject();
    try appendLine(io, paths.sprints, sw.written());

    return .{ .text = try std.fmt.allocPrint(alloc, "{{\"id\":\"{s}\",\"status\":\"cancelled\"}}", .{id}) };
}

pub fn sprintStatus(
    alloc: std.mem.Allocator,
    io: std.Io,
    paths: Paths,
    id: []const u8,
) !mcp.ToolResult {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sprints = try loadSprints(arena, io, paths);
    const s = sprints.get(id) orelse {
        return .{
            .text = try std.fmt.allocPrint(alloc, "{{\"error\":\"sprint not found\",\"id\":\"{s}\"}}", .{id}),
            .is_error = true,
        };
    };
    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = std.json.Stringify{ .writer = &sw.writer };
    try js.beginObject();
    try js.objectField("id"); try js.write(s.id);
    try js.objectField("status"); try js.write(s.status);
    try js.objectField("goal"); try js.write(s.goal);
    try js.objectField("schedule"); try js.write(s.schedule);
    try js.objectField("budget"); try js.write(s.budget);
    try js.objectField("created_ms"); try js.write(s.created_ms);
    try js.objectField("updated_ms"); try js.write(s.updated_ms);
    try js.objectField("progress_count"); try js.write(s.progress_count);
    try js.objectField("last_progress"); try js.write(s.last_progress);
    try js.objectField("verify"); try js.beginWriteRaw(); try js.writer.writeAll(s.verify_json); js.endWriteRaw();
    try js.objectField("plan"); try js.beginWriteRaw(); try js.writer.writeAll(s.plan_json); js.endWriteRaw();
    try js.endObject();
    return .{ .text = try alloc.dupe(u8, sw.written()) };
}

// ---------------------------------------------------------------------------
// Core: swarm_run — records the request; pid's `swarm_tool` does the actual
// fan-out via existing infrastructure. We log it so the user has a ledger.
// ---------------------------------------------------------------------------

pub fn swarmRun(
    alloc: std.mem.Allocator,
    io: std.Io,
    paths: Paths,
    prompt: []const u8,
    n: i64,
    profile: []const u8,
    strategy: []const u8,
) !mcp.ToolResult {
    try ensureBaseDir(io, paths);
    const id = newId(io);
    const ts = nowMs(io);
    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = std.json.Stringify{ .writer = &sw.writer };
    try js.beginObject();
    try js.objectField("event"); try js.write("run");
    try js.objectField("id"); try js.write(id[0..]);
    try js.objectField("ts_ms"); try js.write(ts);
    try js.objectField("prompt"); try js.write(prompt);
    try js.objectField("n"); try js.write(n);
    try js.objectField("profile"); try js.write(profile);
    try js.objectField("strategy"); try js.write(strategy);
    try js.endObject();
    try appendLine(io, paths.swarm, sw.written());

    // We return the recorded payload so pid's CLI can fan-out the actual
    // subagent calls. (Per design §4: swarm_run logs the request, the
    // `pid swarm` thin client then calls the in-process swarm_tool.)
    const out_text = try std.fmt.allocPrint(
        alloc,
        "{{\"swarm_id\":\"{s}\",\"prompt\":{},\"n\":{d},\"profile\":\"{s}\",\"strategy\":\"{s}\",\"ts_ms\":{d}}}",
        .{ id[0..], std.json.fmt(prompt, .{}), n, profile, strategy, ts },
    );
    return .{ .text = out_text };
}

// ---------------------------------------------------------------------------
// Core: verify_run — execute a verify recipe (single command string).
// Recipe lookup order: explicit arg → PID_VERIFY_CMD env → "echo ok".
// Output is captured (up to 64 KB) and returned in the tool result.
// ---------------------------------------------------------------------------

pub fn verifyRun(
    alloc: std.mem.Allocator,
    io: std.Io,
    recipe_opt: ?[]const u8,
) !mcp.ToolResult {
    const cmd_owned: ?[]u8 = if (recipe_opt) |r| try alloc.dupe(u8, r) else getEnv(alloc, "PID_VERIFY_CMD");
    defer if (cmd_owned) |c| alloc.free(c);
    const cmd = cmd_owned orelse "echo ok";

    // On Windows, run via cmd /c; on Unix, /bin/sh -c.
    const is_windows = @import("builtin").os.tag == .windows;
    const argv: []const []const u8 = if (is_windows)
        &.{ "cmd", "/c", cmd }
    else
        &.{ "/bin/sh", "-c", cmd };

    const result = std.process.run(alloc, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| {
        return .{
            .text = try std.fmt.allocPrint(alloc, "{{\"cmd\":\"{s}\",\"error\":\"{s}\"}}", .{ cmd, @errorName(err) }),
            .is_error = true,
        };
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    const exit_code: u32 = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };

    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = std.json.Stringify{ .writer = &sw.writer };
    try js.beginObject();
    try js.objectField("cmd"); try js.write(cmd);
    try js.objectField("exit"); try js.write(exit_code);
    try js.objectField("stdout"); try js.write(result.stdout);
    try js.objectField("stderr"); try js.write(result.stderr);
    try js.endObject();
    return .{
        .text = try alloc.dupe(u8, sw.written()),
        .is_error = exit_code != 0,
    };
}

// ---------------------------------------------------------------------------
// MCP handlers
// ---------------------------------------------------------------------------

fn withPaths(alloc: std.mem.Allocator) !Paths {
    return resolvePaths(alloc);
}

fn handleTicketOpen(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    _ = io;
    var paths = try withPaths(allocator);
    defer paths.deinit(allocator);

    const title = argString(args, "title") orelse return .{ .text = "missing required field: title", .is_error = true };
    const body = argString(args, "body") orelse "";
    const severity = argString(args, "severity") orelse "normal";
    const tags_json = blk: {
        if (argValue(args, "tags")) |v| {
            break :blk try jsonStringify(allocator, v);
        }
        break :blk try allocator.dupe(u8, "[]");
    };
    defer allocator.free(tags_json);

    return ticketOpen(allocator, g_io, paths, title, body, severity, tags_json);
}

fn handleTicketClose(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    _ = io;
    var paths = try withPaths(allocator);
    defer paths.deinit(allocator);
    const id = argString(args, "id") orelse return .{ .text = "missing required field: id", .is_error = true };
    const resolution = argString(args, "resolution") orelse "";
    return ticketClose(allocator, g_io, paths, id, resolution);
}

fn handleTicketUpdate(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    _ = io;
    var paths = try withPaths(allocator);
    defer paths.deinit(allocator);
    const id = argString(args, "id") orelse return .{ .text = "missing required field: id", .is_error = true };
    const body = argString(args, "body");
    const severity = argString(args, "severity");
    const status = argString(args, "status");
    var tags_owned: ?[]u8 = null;
    defer if (tags_owned) |t| allocator.free(t);
    var tags_for_call: ?[]const u8 = null;
    if (argValue(args, "tags")) |v| {
        tags_owned = try jsonStringify(allocator, v);
        tags_for_call = tags_owned.?;
    }
    return ticketUpdate(allocator, g_io, paths, id, body, severity, status, tags_for_call);
}

fn handleTicketList(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    _ = io;
    var paths = try withPaths(allocator);
    defer paths.deinit(allocator);
    const status = argString(args, "status") orelse "all";
    return ticketList(allocator, g_io, paths, status);
}

fn handleSprintStart(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    _ = io;
    var paths = try withPaths(allocator);
    defer paths.deinit(allocator);
    const goal = argString(args, "goal") orelse return .{ .text = "missing required field: goal", .is_error = true };
    const verify_json = blk: {
        if (argValue(args, "verify")) |v| break :blk try jsonStringify(allocator, v);
        break :blk try allocator.dupe(u8, "[]");
    };
    defer allocator.free(verify_json);
    const schedule = argString(args, "schedule") orelse "";
    const budget = argInt(args, "budget") orelse 0;
    const plan_json = blk: {
        if (argValue(args, "plan")) |v| break :blk try jsonStringify(allocator, v);
        break :blk try allocator.dupe(u8, "null");
    };
    defer allocator.free(plan_json);
    return sprintStart(allocator, g_io, paths, goal, verify_json, schedule, budget, plan_json);
}

fn handleSprintCancel(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    _ = io;
    var paths = try withPaths(allocator);
    defer paths.deinit(allocator);
    const id = argString(args, "id") orelse return .{ .text = "missing required field: id", .is_error = true };
    return sprintCancel(allocator, g_io, paths, id);
}

fn handleSprintStatus(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    _ = io;
    var paths = try withPaths(allocator);
    defer paths.deinit(allocator);
    const id = argString(args, "id") orelse return .{ .text = "missing required field: id", .is_error = true };
    return sprintStatus(allocator, g_io, paths, id);
}

fn handleSwarmRun(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    _ = io;
    var paths = try withPaths(allocator);
    defer paths.deinit(allocator);
    const prompt = argString(args, "prompt") orelse return .{ .text = "missing required field: prompt", .is_error = true };
    const n = argInt(args, "n") orelse 3;
    const profile = argString(args, "profile") orelse "";
    const strategy = argString(args, "strategy") orelse "concat";
    return swarmRun(allocator, g_io, paths, prompt, n, profile, strategy);
}

fn handleVerifyRun(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    _ = io;
    const recipe = argString(args, "recipe");
    return verifyRun(allocator, g_io, recipe);
}

// ---------------------------------------------------------------------------
// Tool table — 9 tools per the design.
// ---------------------------------------------------------------------------

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "ticket_open",
        .description = "Open a new ticket. Persisted append-only to ~/.pi/agent/tickets/tickets.jsonl.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "title":    { "type": "string" },
        \\    "body":     { "type": "string" },
        \\    "severity": { "type": "string", "enum": ["low","normal","high"] },
        \\    "tags":     { "type": "array",  "items": { "type": "string" } }
        \\  },
        \\  "required": ["title"]
        \\}
        ,
        .handler = handleTicketOpen,
    },
    .{
        .name = "ticket_list",
        .description = "List tickets folded from tickets.jsonl. Optional status filter.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "status": { "type": "string", "enum": ["all","open","closed"] }
        \\  }
        \\}
        ,
        .handler = handleTicketList,
        .read_only = true,
    },
    .{
        .name = "ticket_close",
        .description = "Close a ticket by 8-char id; record optional resolution text.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "id":         { "type": "string" },
        \\    "resolution": { "type": "string" }
        \\  },
        \\  "required": ["id"]
        \\}
        ,
        .handler = handleTicketClose,
    },
    .{
        .name = "ticket_update",
        .description = "Append an update event for a ticket. Any subset of body/severity/status/tags.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "id":       { "type": "string" },
        \\    "body":     { "type": "string" },
        \\    "severity": { "type": "string" },
        \\    "status":   { "type": "string" },
        \\    "tags":     { "type": "array", "items": { "type": "string" } }
        \\  },
        \\  "required": ["id"]
        \\}
        ,
        .handler = handleTicketUpdate,
    },
    .{
        .name = "sprint_start",
        .description = "Start a sprint. `verify` is an array of shell commands; `plan` is an optional Mission DAG (array of step objects with id/cmd/depends_on/required_artifacts/transitions).",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "goal":     { "type": "string" },
        \\    "verify":   { "type": "array", "items": { "type": "string" } },
        \\    "schedule": { "type": "string" },
        \\    "budget":   { "type": "integer" },
        \\    "plan":     { "type": "array" }
        \\  },
        \\  "required": ["goal"]
        \\}
        ,
        .handler = handleSprintStart,
    },
    .{
        .name = "sprint_status",
        .description = "Return folded state for a sprint id.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": { "id": { "type": "string" } },
        \\  "required": ["id"]
        \\}
        ,
        .handler = handleSprintStatus,
        .read_only = true,
    },
    .{
        .name = "sprint_cancel",
        .description = "Cancel a sprint (records a `cancel` event; status folds to cancelled).",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": { "id": { "type": "string" } },
        \\  "required": ["id"]
        \\}
        ,
        .handler = handleSprintCancel,
        .destructive = true,
    },
    .{
        .name = "swarm_run",
        .description = "Record a swarm-run request to ~/.pi/agent/tickets/swarm.jsonl. The pid CLI then dispatches the actual fan-out via its in-process swarm_tool.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "prompt":   { "type": "string" },
        \\    "n":        { "type": "integer", "minimum": 1, "maximum": 16 },
        \\    "profile":  { "type": "string" },
        \\    "strategy": { "type": "string", "enum": ["concat","rerank","synthesize"] }
        \\  },
        \\  "required": ["prompt"]
        \\}
        ,
        .handler = handleSwarmRun,
    },
    .{
        .name = "verify_run",
        .description = "Run a verify recipe. Looks up: explicit `recipe` arg → PID_VERIFY_CMD env → `echo ok`. Returns {cmd,exit,stdout,stderr}.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": { "recipe": { "type": "string" } }
        \\}
        ,
        .handler = handleVerifyRun,
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
        .{ .name = "zmcp-tickets", .version = "0.1.0" },
        &tool_table,
    );
}

// ---------------------------------------------------------------------------
// Tests — use temp HOME directory by injecting via env override.
// ---------------------------------------------------------------------------

fn pathsForTmp(alloc: std.mem.Allocator, tmp_root: []const u8) !Paths {
    const base = try std.fmt.allocPrint(alloc, "{s}/.pi/agent/tickets", .{tmp_root});
    const tickets = try std.fmt.allocPrint(alloc, "{s}/tickets.jsonl", .{base});
    const sprints = try std.fmt.allocPrint(alloc, "{s}/sprints.jsonl", .{base});
    const swarm = try std.fmt.allocPrint(alloc, "{s}/swarm.jsonl", .{base});
    return .{ .base = base, .tickets = tickets, .sprints = sprints, .swarm = swarm };
}

test "ticket_open then list returns the ticket" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Resolve the tmp dir's absolute path for the Paths struct.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(io, &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    var paths = try pathsForTmp(alloc, tmp_path);
    defer paths.deinit(alloc);

    const r = try ticketOpen(alloc, io, paths, "test ticket", "details", "normal", "[]");
    defer alloc.free(r.text);
    try std.testing.expect(!r.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "\"status\":\"open\"") != null);

    const list = try ticketList(alloc, io, paths, "all");
    defer alloc.free(list.text);
    try std.testing.expect(std.mem.indexOf(u8, list.text, "test ticket") != null);
}

test "ticket_close folds to closed" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(io, &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    var paths = try pathsForTmp(alloc, tmp_path);
    defer paths.deinit(alloc);

    const r = try ticketOpen(alloc, io, paths, "to close", "", "low", "[]");
    defer alloc.free(r.text);
    // extract id from "{"id":"xxxxxxxx",...}"
    const id_start = std.mem.indexOf(u8, r.text, "\"id\":\"").? + 6;
    const id = r.text[id_start .. id_start + 8];

    const c = try ticketClose(alloc, io, paths, id, "fixed");
    defer alloc.free(c.text);
    try std.testing.expect(std.mem.indexOf(u8, c.text, "\"status\":\"closed\"") != null);

    const open_only = try ticketList(alloc, io, paths, "open");
    defer alloc.free(open_only.text);
    try std.testing.expect(std.mem.indexOf(u8, open_only.text, id) == null);

    const closed_only = try ticketList(alloc, io, paths, "closed");
    defer alloc.free(closed_only.text);
    try std.testing.expect(std.mem.indexOf(u8, closed_only.text, id) != null);
}

test "sprint_start then status" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(io, &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    var paths = try pathsForTmp(alloc, tmp_path);
    defer paths.deinit(alloc);

    const r = try sprintStart(alloc, io, paths, "research X", "[\"echo ok\"]", "", 0, "null");
    defer alloc.free(r.text);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "\"status\":\"running\"") != null);
    const id_start = std.mem.indexOf(u8, r.text, "\"sprint_id\":\"").? + 13;
    const id = r.text[id_start .. id_start + 8];

    const s = try sprintStatus(alloc, io, paths, id);
    defer alloc.free(s.text);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "\"goal\":\"research X\"") != null);
}

test "sprint_cancel folds to cancelled" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(io, &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    var paths = try pathsForTmp(alloc, tmp_path);
    defer paths.deinit(alloc);

    const r = try sprintStart(alloc, io, paths, "g", "[]", "", 0, "null");
    defer alloc.free(r.text);
    const id_start = std.mem.indexOf(u8, r.text, "\"sprint_id\":\"").? + 13;
    const id = r.text[id_start .. id_start + 8];

    const c = try sprintCancel(alloc, io, paths, id);
    defer alloc.free(c.text);

    const s = try sprintStatus(alloc, io, paths, id);
    defer alloc.free(s.text);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "\"status\":\"cancelled\"") != null);
}

test "swarm_run appends to swarm.jsonl" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(io, &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    var paths = try pathsForTmp(alloc, tmp_path);
    defer paths.deinit(alloc);

    const r = try swarmRun(alloc, io, paths, "find foo", 3, "", "concat");
    defer alloc.free(r.text);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "\"swarm_id\":") != null);

    const contents = try std.Io.Dir.cwd().readFileAlloc(io, paths.swarm, alloc, .unlimited);
    defer alloc.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "find foo") != null);
}

test "env lookup reads the real process environment (not an empty block)" {
    const alloc = std.testing.allocator;
    const saved = g_io;
    defer g_io = saved;
    g_io = std.testing.io;
    const v = getEnv(alloc, "PATH") orelse return error.SkipZigTest;
    defer alloc.free(v);
    try std.testing.expect(v.len > 0);
    try std.testing.expect(getEnv(alloc, "ZMCP_SURELY_UNSET_ENV_VAR_12345") == null);
}
