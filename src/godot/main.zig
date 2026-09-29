//! zmcp-godot: native Zig port of Coding-Solo/godot-mcp. Wraps the Godot CLI.
//!
//! Tools (names/args as in upstream): launch_editor, run_project,
//! get_debug_output, stop_project, get_godot_version, list_projects,
//! get_project_info, create_scene, add_node, load_sprite,
//! export_mesh_library, save_scene, get_uid, update_project_uids.
//!
//! Scene edits run an embedded GDScript (ops.gd) via
//! `godot --headless --path P --script <tmp>.gd -- <operation> <json>`.
//! Env: GODOT_PATH (binary, default `godot`), ZMCP_GODOT_ALLOW_RUN=1 (launch_editor/run_project execute project scripts), ZMCP_GODOT_ALLOW_WRITE=1
//! (enables the tools that modify project files).

const std = @import("std");
const builtin = @import("builtin");
const mcp = @import("mcp");

const Io = std.Io;

pub const ops_gd = @embedFile("ops.gd");

const RING_CAP: usize = 24 * 1024;
const EXEC_TIMEOUT_S: i64 = 300;
const EXEC_STDOUT_CAP: usize = 8 * 1024 * 1024;
const EXEC_STDERR_CAP: usize = 4 * 1024 * 1024;
const OUT_CAP: usize = 64 * 1024;
const LIST_DEPTH_RECURSIVE: usize = 4;
const LIST_MAX: usize = 200;
const INFO_DEPTH: usize = 10;
const INFO_MAX_FILES: usize = 50_000;
const RESULT_PREFIX = "ZMCP_RESULT ";

var g_environ: ?*const std.process.Environ.Map = null;
/// Test seams: replace the godot binary (and prepend args, e.g. a script for /bin/sh).
var g_bin_override: ?[]const u8 = null;
var g_bin_prefix: []const []const u8 = &.{};

pub fn main(init: std.process.Init) !void {
    g_environ = init.environ_map;
    defer shutdownSession(init.io);
    try mcp.run(init.gpa, init.io, .{ .name = "zmcp-godot", .version = "0.1.0" }, &tool_table);
}

fn envGet(key: []const u8) ?[]const u8 {
    const m = g_environ orelse return null;
    const v = m.get(key) orelse return null;
    return if (v.len == 0) null else v;
}

// ---------------------------------------------------------------------------
// Tool table
// ---------------------------------------------------------------------------

const PP = "\"projectPath\":{\"type\":\"string\"}";
const SP = "\"scenePath\":{\"type\":\"string\",\"description\":\"res:// or relative\"}";

const tool_table = [_]mcp.ToolDef{
    .{ .name = "launch_editor", .description = "Open the Godot editor for a project.", .input_schema_json = "{\"type\":\"object\",\"properties\":{" ++ PP ++ "},\"required\":[\"projectPath\"]}", .handler = handleLaunchEditor },
    .{ .name = "run_project", .description = "Run a project (one at a time); output via get_debug_output.", .input_schema_json = "{\"type\":\"object\",\"properties\":{" ++ PP ++ ",\"scene\":{\"type\":\"string\"}},\"required\":[\"projectPath\"]}", .handler = handleRunProject },
    .{ .name = "get_debug_output", .description = "Captured stdout/stderr of the running project.", .input_schema_json = "{\"type\":\"object\",\"properties\":{}}", .handler = handleDebugOutput, .read_only = true },
    .{ .name = "stop_project", .description = "Stop the running project.", .input_schema_json = "{\"type\":\"object\",\"properties\":{}}", .handler = handleStopProject, .destructive = true },
    .{ .name = "get_godot_version", .description = "Installed Godot version.", .input_schema_json = "{\"type\":\"object\",\"properties\":{}}", .handler = handleVersion, .read_only = true },
    .{ .name = "list_projects", .description = "Find Godot projects under a directory.", .input_schema_json = "{\"type\":\"object\",\"properties\":{\"directory\":{\"type\":\"string\"},\"recursive\":{\"type\":\"boolean\"}},\"required\":[\"directory\"]}", .handler = handleListProjects, .read_only = true },
    .{ .name = "get_project_info", .description = "Project name, Godot version, file counts.", .input_schema_json = "{\"type\":\"object\",\"properties\":{" ++ PP ++ "},\"required\":[\"projectPath\"]}", .handler = handleProjectInfo, .read_only = true },
    .{ .name = "create_scene", .description = "Create a scene [write].", .input_schema_json = "{\"type\":\"object\",\"properties\":{" ++ PP ++ "," ++ SP ++ ",\"rootNodeType\":{\"type\":\"string\"}},\"required\":[\"projectPath\",\"scenePath\"]}", .handler = handleCreateScene },
    .{ .name = "add_node", .description = "Add a node to a scene [write].", .input_schema_json = "{\"type\":\"object\",\"properties\":{" ++ PP ++ "," ++ SP ++ ",\"nodeType\":{\"type\":\"string\"},\"nodeName\":{\"type\":\"string\"},\"parentNodePath\":{\"type\":\"string\"},\"properties\":{\"type\":\"object\"}},\"required\":[\"projectPath\",\"scenePath\",\"nodeType\",\"nodeName\"]}", .handler = handleAddNode },
    .{ .name = "load_sprite", .description = "Set a sprite node's texture [write].", .input_schema_json = "{\"type\":\"object\",\"properties\":{" ++ PP ++ "," ++ SP ++ ",\"nodePath\":{\"type\":\"string\"},\"texturePath\":{\"type\":\"string\"}},\"required\":[\"projectPath\",\"scenePath\",\"nodePath\",\"texturePath\"]}", .handler = handleLoadSprite },
    .{ .name = "export_mesh_library", .description = "Export a 3D scene as MeshLibrary [write].", .input_schema_json = "{\"type\":\"object\",\"properties\":{" ++ PP ++ "," ++ SP ++ ",\"outputPath\":{\"type\":\"string\"},\"meshItemNames\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}},\"required\":[\"projectPath\",\"scenePath\",\"outputPath\"]}", .handler = handleExportMeshLibrary },
    .{ .name = "save_scene", .description = "Resave a scene, optionally to newPath [write].", .input_schema_json = "{\"type\":\"object\",\"properties\":{" ++ PP ++ "," ++ SP ++ ",\"newPath\":{\"type\":\"string\"}},\"required\":[\"projectPath\",\"scenePath\"]}", .handler = handleSaveScene, .destructive = true },
    .{ .name = "get_uid", .description = "UID of a project file (Godot 4.4+).", .input_schema_json = "{\"type\":\"object\",\"properties\":{" ++ PP ++ ",\"filePath\":{\"type\":\"string\"}},\"required\":[\"projectPath\",\"filePath\"]}", .handler = handleGetUid, .read_only = true },
    .{ .name = "update_project_uids", .description = "Resave resources to refresh UIDs [write].", .input_schema_json = "{\"type\":\"object\",\"properties\":{" ++ PP ++ "},\"required\":[\"projectPath\"]}", .handler = handleUpdateUids, .destructive = true },
};

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

fn getStr(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn getBool(args: std.json.Value, key: []const u8) bool {
    if (args != .object) return false;
    const v = args.object.get(key) orelse return false;
    return v == .bool and v.bool;
}

fn errRes(alloc: std.mem.Allocator, comptime fmt: []const u8, a: anytype) !mcp.ToolResult {
    return .{ .text = try std.fmt.allocPrint(alloc, fmt, a), .is_error = true };
}

fn staticErr(msg: []const u8) mcp.ToolResult {
    return .{ .text = msg, .is_error = true };
}

/// Cap to OUT_CAP bytes, keeping the head, with a truncation note.
fn capText(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (s.len <= OUT_CAP) return s;
    return std.fmt.allocPrint(alloc, "{s}\n[truncated, {d} bytes omitted]", .{ s[0..OUT_CAP], s.len - OUT_CAP });
}

fn tailOf(s: []const u8, n: usize) []const u8 {
    return if (s.len > n) s[s.len - n ..] else s;
}

pub const write_refused_msg = "refused: this tool modifies project files; set ZMCP_GODOT_ALLOW_WRITE=1 to enable";

pub const run_refused_msg = "refused: this tool executes the project's own scripts; set ZMCP_GODOT_ALLOW_RUN=1 to enable";

fn runAllowed() bool {
    const v = envGet("ZMCP_GODOT_ALLOW_RUN") orelse return false;
    return std.mem.eql(u8, v, "1");
}

fn writeAllowed() bool {
    const v = envGet("ZMCP_GODOT_ALLOW_WRITE") orelse return false;
    return std.mem.eql(u8, v, "1");
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

/// Reject empty values, NUL/control characters and a leading '-' (CLI flag).
pub fn argOk(s: []const u8) bool {
    if (s.len == 0 or s[0] == '-') return false;
    for (s) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

fn relPartOk(rest: []const u8) bool {
    if (rest.len == 0 or rest[0] == '/' or rest[rest.len - 1] == '/') return false;
    for (rest) |c| {
        if (c < 0x20 or c == 0x7f or c == '\\' or c == ':' or c == '"') return false;
    }
    var it = std.mem.splitScalar(u8, rest, '/');
    while (it.next()) |comp| {
        if (comp.len == 0 or std.mem.eql(u8, comp, ".") or std.mem.eql(u8, comp, "..")) return false;
    }
    return true;
}

fn hasExt(s: []const u8, exts: []const []const u8) bool {
    for (exts) |e| if (std.ascii.endsWithIgnoreCase(s, e)) return true;
    return false;
}

/// Accept "res://a/b.ext" or "a/b.ext"; return normalised "res://a/b.ext".
/// Rejects absolute paths, backslashes, "..", drive/URL colons, wrong extension.
pub fn resPath(alloc: std.mem.Allocator, input: []const u8, exts: []const []const u8) ![]const u8 {
    const rest = if (std.mem.startsWith(u8, input, "res://")) input["res://".len..] else input;
    if (!relPartOk(rest)) return error.BadPath;
    if (!hasExt(rest, exts)) return error.BadPath;
    return std.fmt.allocPrint(alloc, "res://{s}", .{rest});
}

const scene_exts = [_][]const u8{ ".tscn", ".scn" };
const lib_exts = [_][]const u8{ ".tres", ".res" };
const tex_exts = [_][]const u8{ ".png", ".jpg", ".jpeg", ".webp", ".svg", ".bmp", ".tga", ".exr", ".hdr", ".tres", ".res" };
const any_ext = [_][]const u8{""};

/// Node path inside a scene: "root", "root/A/B" or "A/B". No traversal.
pub fn nodePathOk(s: []const u8) bool {
    if (s.len == 0 or s.len > 256) return false;
    return relPartOk(s) and std.mem.indexOfScalar(u8, s, '@') == null;
}

/// Node type / name: [A-Za-z0-9_ -], no path or property syntax.
pub fn identOk(s: []const u8, allow_space: bool) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or (allow_space and c == ' ');
        if (!ok) return false;
    }
    return true;
}

fn propKeyOk(s: []const u8) bool {
    if (s.len == 0 or s.len > 96 or std.mem.eql(u8, s, "script")) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '/')) return false;
    return true;
}

const Val = union(enum) { ok: []const u8, err: []const u8 };

/// Canonicalize a directory; requires it to exist.
fn canonDir(alloc: std.mem.Allocator, io: Io, arg: []const u8) Val {
    if (!argOk(arg)) return .{ .err = "invalid path (empty, control chars or leading '-')" };
    const real = Io.Dir.cwd().realPathFileAlloc(io, arg, alloc) catch return .{ .err = "directory not found" };
    const st = Io.Dir.cwd().statFile(io, real, .{}) catch return .{ .err = "directory not found" };
    if (st.kind != .directory) return .{ .err = "not a directory" };
    return .{ .ok = real };
}

/// Canonical project directory that contains project.godot.
fn resolveProject(alloc: std.mem.Allocator, io: Io, arg: []const u8) Val {
    const dir = switch (canonDir(alloc, io, arg)) {
        .ok => |d| d,
        .err => |e| return .{ .err = e },
    };
    const pg = std.fs.path.join(alloc, &.{ dir, "project.godot" }) catch return .{ .err = "out of memory" };
    const st = Io.Dir.cwd().statFile(io, pg, .{}) catch return .{ .err = "no project.godot in that directory" };
    if (st.kind != .file) return .{ .err = "no project.godot in that directory" };
    return .{ .ok = dir };
}

// ---------------------------------------------------------------------------
// Godot invocation: argv builders + exec seam
// ---------------------------------------------------------------------------

const missing_msg = "godot binary not found: set GODOT_PATH or put `godot` on PATH";

fn godotBin() []const u8 {
    if (g_bin_override) |b| return b;
    return envGet("GODOT_PATH") orelse "godot";
}

fn argvStart(alloc: std.mem.Allocator, tail: []const []const u8) ![]const []const u8 {
    var l: std.ArrayList([]const u8) = .empty;
    try l.append(alloc, godotBin());
    try l.appendSlice(alloc, g_bin_prefix);
    try l.appendSlice(alloc, tail);
    return l.items;
}

pub fn versionArgv(alloc: std.mem.Allocator) ![]const []const u8 {
    return argvStart(alloc, &.{"--version"});
}

pub fn editorArgv(alloc: std.mem.Allocator, project: []const u8) ![]const []const u8 {
    return argvStart(alloc, &.{ "-e", "--path", project });
}

pub fn runArgv(alloc: std.mem.Allocator, project: []const u8, scene: ?[]const u8) ![]const []const u8 {
    if (scene) |s| return argvStart(alloc, &.{ "-d", "--path", project, s });
    return argvStart(alloc, &.{ "-d", "--path", project });
}

pub fn opsArgv(alloc: std.mem.Allocator, project: []const u8, script: []const u8, op: []const u8, params: []const u8) ![]const []const u8 {
    return argvStart(alloc, &.{ "--headless", "--path", project, "--script", script, "--", op, params });
}

pub const ExecResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
};

pub const ExecFn = *const fn (alloc: std.mem.Allocator, io: Io, argv: []const []const u8) anyerror!ExecResult;
var exec_fn: ExecFn = execReal;

fn execReal(alloc: std.mem.Allocator, io: Io, argv: []const []const u8) anyerror!ExecResult {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.ExecutableNotFound,
        else => return err,
    };
    defer child.kill(io);

    var mr_buf: Io.File.MultiReader.Buffer(2) = undefined;
    var mr: Io.File.MultiReader = undefined;
    mr.init(alloc, io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();

    const deadline = Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromSeconds(EXEC_TIMEOUT_S), .clock = .awake });
    const out_r = mr.reader(0);
    const err_r = mr.reader(1);
    while (mr.fill(64, .{ .deadline = deadline })) |_| {
        if (out_r.buffered().len > EXEC_STDOUT_CAP or err_r.buffered().len > EXEC_STDERR_CAP) return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try mr.checkAnyError();
    const term = try child.wait(io);
    return .{ .term = term, .stdout = try mr.toOwnedSlice(0), .stderr = try mr.toOwnedSlice(1) };
}

fn execErrText(alloc: std.mem.Allocator, err: anyerror) !mcp.ToolResult {
    return switch (err) {
        error.ExecutableNotFound, error.FileNotFound => staticErr(missing_msg),
        error.Timeout => errRes(alloc, "godot timed out after {d}s", .{EXEC_TIMEOUT_S}),
        error.StreamTooLong => staticErr("godot output too large"),
        else => errRes(alloc, "godot failed to run: {s}", .{@errorName(err)}),
    };
}

fn termOk(t: std.process.Child.Term) bool {
    return switch (t) {
        .exited => |c| c == 0,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Operations script runner
// ---------------------------------------------------------------------------

var tmp_counter = std.atomic.Value(u32).init(0);

fn tempDir() []const u8 {
    return envGet("TMPDIR") orelse envGet("TEMP") orelse envGet("TMP") orelse "/tmp";
}

/// Write the embedded ops.gd to a fresh exclusive temp file; returns its path.
fn writeOpsFile(alloc: std.mem.Allocator, io: Io) ![]const u8 {
    const ns = Io.Timestamp.now(io, .real).nanoseconds;
    const n = tmp_counter.fetchAdd(1, .monotonic);
    const path = try std.fmt.allocPrint(alloc, "{s}{s}zmcp-godot-{x}-{d}.gd", .{ tempDir(), std.fs.path.sep_str, @as(u64, @truncate(@as(u96, @bitCast(ns)))), n });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = ops_gd, .flags = .{ .exclusive = true } });
    return path;
}

fn findResultLine(stdout: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, RESULT_PREFIX)) found = line[RESULT_PREFIX.len..];
    }
    return found;
}

fn runOp(alloc: std.mem.Allocator, io: Io, project: []const u8, op: []const u8, params: []const u8) !mcp.ToolResult {
    const script = writeOpsFile(alloc, io) catch |err| return errRes(alloc, "cannot write temp script: {s}", .{@errorName(err)});
    defer Io.Dir.cwd().deleteFile(io, script) catch {};
    const argv = try opsArgv(alloc, project, script, op, params);
    const r = exec_fn(alloc, io, argv) catch |err| return execErrText(alloc, err);
    if (findResultLine(r.stdout)) |line| {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch
            return errRes(alloc, "bad result from godot: {s}", .{tailOf(line, 300)});
        if (parsed.value == .object) {
            if (parsed.value.object.get("ok")) |ok| {
                if (ok == .bool and ok.bool) return .{ .text = line };
            }
            if (parsed.value.object.get("error")) |e| if (e == .string) return errRes(alloc, "{s}", .{e.string});
        }
        return errRes(alloc, "operation failed: {s}", .{tailOf(line, 300)});
    }
    return errRes(alloc, "godot gave no result ({s}); stderr: {s} stdout: {s}", .{
        if (termOk(r.term)) "exit 0" else "nonzero exit",
        tailOf(r.stderr, 1500),
        tailOf(r.stdout, 1500),
    });
}

fn jsonOf(alloc: std.mem.Allocator, v: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, v, .{ .emit_null_optional_fields = false });
}

// ---------------------------------------------------------------------------
// Tracked run_project process
// ---------------------------------------------------------------------------

/// Overwrite-oldest byte ring buffer.
pub const Ring = struct {
    buf: []u8,
    start: usize = 0,
    len: usize = 0,
    dropped: u64 = 0,

    pub fn init(alloc: std.mem.Allocator, cap: usize) !Ring {
        return .{ .buf = try alloc.alloc(u8, cap) };
    }

    pub fn deinit(self: *Ring, alloc: std.mem.Allocator) void {
        alloc.free(self.buf);
    }

    pub fn write(self: *Ring, data: []const u8) void {
        const cap = self.buf.len;
        if (cap == 0 or data.len == 0) return;
        if (data.len >= cap) {
            self.dropped += self.len + (data.len - cap);
            @memcpy(self.buf, data[data.len - cap ..]);
            self.start = 0;
            self.len = cap;
            return;
        }
        if (self.len + data.len > cap) {
            const over = self.len + data.len - cap;
            self.start = (self.start + over) % cap;
            self.len -= over;
            self.dropped += over;
        }
        const end = (self.start + self.len) % cap;
        const first = @min(data.len, cap - end);
        @memcpy(self.buf[end .. end + first], data[0..first]);
        if (first < data.len) @memcpy(self.buf[0 .. data.len - first], data[first..]);
        self.len += data.len;
    }

    /// Contents oldest to newest.
    pub fn snapshot(self: *const Ring, alloc: std.mem.Allocator) ![]u8 {
        const out = try alloc.alloc(u8, self.len);
        const first = @min(self.len, self.buf.len - self.start);
        @memcpy(out[0..first], self.buf[self.start .. self.start + first]);
        if (first < self.len) @memcpy(out[first..], self.buf[0 .. self.len - first]);
        return out;
    }
};

const Session = struct {
    mutex: Io.Mutex = .init,
    out: Ring,
    err: Ring,
    child: std.process.Child,
    refs: std.atomic.Value(u32) = .init(1),
    eof: std.atomic.Value(u32) = .init(0),
    reaped: bool = false,
    exit_buf: [40]u8 = undefined,
    exit_len: usize = 0,

    fn exitText(self: *const Session) ?[]const u8 {
        return if (self.exit_len == 0) null else self.exit_buf[0..self.exit_len];
    }

    fn setExit(self: *Session, text: []const u8) void {
        const n = @min(text.len, self.exit_buf.len);
        @memcpy(self.exit_buf[0..n], text[0..n]);
        self.exit_len = n;
    }
};

const page = std.heap.page_allocator;
var g_lock: Io.Mutex = .init;
var g_session: ?*Session = null;

fn release(s: *Session) void {
    if (s.refs.fetchSub(1, .acq_rel) == 1) {
        s.out.deinit(page);
        s.err.deinit(page);
        page.destroy(s);
    }
}

fn readerMain(s: *Session, io: Io, file: Io.File, is_err: bool) void {
    defer release(s);
    defer _ = s.eof.fetchAdd(1, .release);
    var buf: [4096]u8 = undefined;
    while (true) {
        var iov = [_][]u8{buf[0..]};
        const n = file.readStreaming(io, &iov) catch break;
        if (n == 0) break;
        s.mutex.lockUncancelable(io);
        if (is_err) s.err.write(buf[0..n]) else s.out.write(buf[0..n]);
        s.mutex.unlock(io);
    }
}

/// Reap the child if both pipes hit EOF. Caller holds g_lock.
fn refreshLocked(s: *Session, io: Io) void {
    if (s.reaped or s.eof.load(.acquire) < 2) return;
    const term = s.child.wait(io) catch {
        s.reaped = true;
        s.setExit("exited");
        return;
    };
    s.reaped = true;
    var b: [40]u8 = undefined;
    const txt = switch (term) {
        .exited => |c| std.fmt.bufPrint(&b, "exit {d}", .{c}) catch "exited",
        .signal => |sg| std.fmt.bufPrint(&b, "signal {d}", .{@intFromEnum(sg)}) catch "signal",
        else => "ended",
    };
    s.setExit(txt);
}

/// Kill if running. Caller holds g_lock. Returns true when a live process was killed.
fn stopLocked(s: *Session, io: Io) bool {
    refreshLocked(s, io);
    if (s.reaped) return false;
    s.child.kill(io);
    s.reaped = true;
    s.setExit("killed");
    return true;
}

fn shutdownSession(io: Io) void {
    g_lock.lockUncancelable(io);
    defer g_lock.unlock(io);
    if (g_session) |s| {
        _ = stopLocked(s, io);
        g_session = null;
        release(s);
    }
}

const StartResult = union(enum) { ok, err: []const u8 };

fn startRun(io: Io, argv: []const []const u8) StartResult {
    g_lock.lockUncancelable(io);
    defer g_lock.unlock(io);
    if (g_session) |old| {
        refreshLocked(old, io);
        if (!old.reaped) return .{ .err = "a project is already running; call stop_project first" };
        g_session = null;
        release(old);
    }
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return .{ .err = missing_msg },
        else => return .{ .err = "failed to start godot" },
    };
    const s = page.create(Session) catch {
        child.kill(io);
        return .{ .err = "out of memory" };
    };
    const out = Ring.init(page, RING_CAP) catch {
        child.kill(io);
        page.destroy(s);
        return .{ .err = "out of memory" };
    };
    const er = Ring.init(page, RING_CAP) catch {
        child.kill(io);
        page.free(out.buf);
        page.destroy(s);
        return .{ .err = "out of memory" };
    };
    s.* = .{ .out = out, .err = er, .child = child };
    const files = [2]Io.File{ child.stdout.?, child.stderr.? };
    var failed = false;
    for (files, 0..) |f, i| {
        _ = s.refs.fetchAdd(1, .monotonic);
        const t = std.Thread.spawn(.{}, readerMain, .{ s, io, f, i == 1 }) catch {
            _ = s.refs.fetchSub(1, .monotonic);
            _ = s.eof.fetchAdd(1, .monotonic);
            failed = true;
            continue;
        };
        t.detach();
    }
    if (failed) {
        s.child.kill(io);
        s.reaped = true;
        release(s);
        return .{ .err = "failed to start reader threads" };
    }
    g_session = s;
    return .ok;
}

const Reap = struct { io: Io, child: std.process.Child };

fn reapMain(p: *Reap) void {
    _ = p.child.wait(p.io) catch {};
    page.destroy(p);
}

fn spawnDetached(io: Io, argv: []const []const u8) StartResult {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return .{ .err = missing_msg },
        else => return .{ .err = "failed to start godot" },
    };
    const p = page.create(Reap) catch {
        child.kill(io);
        return .{ .err = "out of memory" };
    };
    p.* = .{ .io = io, .child = child };
    const t = std.Thread.spawn(.{}, reapMain, .{p}) catch {
        p.child.kill(io);
        page.destroy(p);
        return .{ .err = "failed to start reaper thread" };
    };
    t.detach();
    return .ok;
}

// ---------------------------------------------------------------------------
// Handlers: process / read-only
// ---------------------------------------------------------------------------

fn projectArg(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !union(enum) { ok: []const u8, err: mcp.ToolResult } {
    const p = getStr(args, "projectPath") orelse return .{ .err = staticErr("projectPath is required") };
    return switch (resolveProject(alloc, io, p)) {
        .ok => |d| .{ .ok = d },
        .err => |e| .{ .err = try errRes(alloc, "projectPath: {s}", .{e}) },
    };
}

fn handleLaunchEditor(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    if (!runAllowed()) return staticErr(run_refused_msg);
    const proj = switch (try projectArg(alloc, io, args)) {
        .ok => |d| d,
        .err => |e| return e,
    };
    switch (spawnDetached(io, try editorArgv(alloc, proj))) {
        .ok => return .{ .text = "editor launched" },
        .err => |m| return staticErr(m),
    }
}

fn handleRunProject(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    if (!runAllowed()) return staticErr(run_refused_msg);
    const proj = switch (try projectArg(alloc, io, args)) {
        .ok => |d| d,
        .err => |e| return e,
    };
    var scene: ?[]const u8 = null;
    if (getStr(args, "scene")) |s| {
        scene = resPath(alloc, s, &scene_exts) catch return staticErr("scene: invalid path (need .tscn/.scn, no traversal)");
    }
    switch (startRun(io, try runArgv(alloc, proj, scene))) {
        .ok => return .{ .text = "started; use get_debug_output / stop_project" },
        .err => |m| return staticErr(m),
    }
}

const DebugOut = struct {
    running: bool,
    exit: ?[]const u8 = null,
    output: []const u8,
    errors: []const u8,
    dropped: u64 = 0,
};

fn debugJson(alloc: std.mem.Allocator, running: bool, exit: ?[]const u8, out: []const u8, errs: []const u8, dropped: u64) ![]u8 {
    return jsonOf(alloc, DebugOut{ .running = running, .exit = exit, .output = out, .errors = errs, .dropped = dropped });
}

fn handleDebugOutput(alloc: std.mem.Allocator, io: Io, _: std.json.Value) !mcp.ToolResult {
    g_lock.lockUncancelable(io);
    defer g_lock.unlock(io);
    const s = g_session orelse return .{ .text = try debugJson(alloc, false, null, "", "", 0) };
    refreshLocked(s, io);
    s.mutex.lockUncancelable(io);
    defer s.mutex.unlock(io);
    const out = try s.out.snapshot(alloc);
    const er = try s.err.snapshot(alloc);
    return .{ .text = try debugJson(alloc, !s.reaped, s.exitText(), out, er, s.out.dropped + s.err.dropped) };
}

fn handleStopProject(alloc: std.mem.Allocator, io: Io, _: std.json.Value) !mcp.ToolResult {
    _ = alloc;
    g_lock.lockUncancelable(io);
    defer g_lock.unlock(io);
    const s = g_session orelse return .{ .text = "no project running" };
    if (stopLocked(s, io)) return .{ .text = "stopped" };
    return .{ .text = "project was not running" };
}

fn handleVersion(alloc: std.mem.Allocator, io: Io, _: std.json.Value) !mcp.ToolResult {
    const r = exec_fn(alloc, io, try versionArgv(alloc)) catch |err| return execErrText(alloc, err);
    const v = std.mem.trim(u8, r.stdout, " \r\n\t");
    if (!termOk(r.term) or v.len == 0) return errRes(alloc, "godot --version failed: {s}", .{tailOf(r.stderr, 500)});
    return .{ .text = v };
}

fn readProjectName(alloc: std.mem.Allocator, io: Io, dir: []const u8) ?[]const u8 {
    const pg = std.fs.path.join(alloc, &.{ dir, "project.godot" }) catch return null;
    const data = Io.Dir.cwd().readFileAlloc(io, pg, alloc, .limited(256 * 1024)) catch return null;
    return parseProjectName(data);
}

pub fn parseProjectName(data: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "config/name")) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const v = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') return v[1 .. v.len - 1];
    }
    return null;
}

fn skipDir(name: []const u8) bool {
    return name.len == 0 or name[0] == '.' or std.mem.eql(u8, name, "node_modules");
}

const ProjItem = struct { path: []const u8, name: []const u8 };

fn scanProjects(alloc: std.mem.Allocator, io: Io, dir: []const u8, depth: usize, out: *std.ArrayList(ProjItem)) void {
    if (out.items.len >= LIST_MAX) return;
    var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer d.close(io);
    if (d.statFile(io, "project.godot", .{})) |st| {
        if (st.kind == .file) {
            const name = readProjectName(alloc, io, dir) orelse std.fs.path.basename(dir);
            out.append(alloc, .{ .path = dir, .name = name }) catch return;
        }
    } else |_| {}
    if (depth == 0) return;
    var names: std.ArrayList([]const u8) = .empty;
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory or skipDir(e.name)) continue;
        names.append(alloc, alloc.dupe(u8, e.name) catch return) catch return;
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    for (names.items) |n| {
        const sub = std.fs.path.join(alloc, &.{ dir, n }) catch return;
        // A found project is not descended into further (nested projects are rare).
        scanProjects(alloc, io, sub, depth - 1, out);
    }
}

fn handleListProjects(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const d = getStr(args, "directory") orelse return staticErr("directory is required");
    const dir = switch (canonDir(alloc, io, d)) {
        .ok => |x| x,
        .err => |e| return errRes(alloc, "directory: {s}", .{e}),
    };
    var items: std.ArrayList(ProjItem) = .empty;
    scanProjects(alloc, io, dir, if (getBool(args, "recursive")) LIST_DEPTH_RECURSIVE else 1, &items);
    const capped = items.items.len >= LIST_MAX;
    const json = try jsonOf(alloc, items.items);
    if (capped) return .{ .text = try std.fmt.allocPrint(alloc, "{s}\n[capped at {d} projects]", .{ json, LIST_MAX }) };
    return .{ .text = json };
}

const Counts = struct { scenes: u32 = 0, scripts: u32 = 0, assets: u32 = 0, other: u32 = 0 };

pub fn classify(name: []const u8) enum { scene, script, asset, other } {
    const ext = std.fs.path.extension(name);
    const sc = [_][]const u8{ ".tscn", ".scn" };
    const sr = [_][]const u8{ ".gd", ".cs", ".gdshader" };
    const as = [_][]const u8{ ".png", ".jpg", ".jpeg", ".webp", ".svg", ".wav", ".ogg", ".mp3", ".glb", ".gltf", ".obj", ".fbx", ".ttf", ".otf", ".tres", ".res", ".exr", ".hdr" };
    for (sc) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return .scene;
    for (sr) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return .script;
    for (as) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return .asset;
    return .other;
}

fn countFiles(alloc: std.mem.Allocator, io: Io, dir: []const u8, depth: usize, c: *Counts, total: *usize) void {
    if (depth == 0 or total.* >= INFO_MAX_FILES) return;
    var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        switch (e.kind) {
            .file => {
                total.* += 1;
                switch (classify(e.name)) {
                    .scene => c.scenes += 1,
                    .script => c.scripts += 1,
                    .asset => c.assets += 1,
                    .other => c.other += 1,
                }
            },
            .directory => {
                if (skipDir(e.name)) continue;
                const sub = std.fs.path.join(alloc, &.{ dir, e.name }) catch return;
                countFiles(alloc, io, sub, depth - 1, c, total);
            },
            else => {},
        }
        if (total.* >= INFO_MAX_FILES) return;
    }
}

const ProjInfo = struct { name: []const u8, path: []const u8, godotVersion: ?[]const u8, structure: Counts };

fn handleProjectInfo(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const proj = switch (try projectArg(alloc, io, args)) {
        .ok => |d| d,
        .err => |e| return e,
    };
    var counts: Counts = .{};
    var total: usize = 0;
    countFiles(alloc, io, proj, INFO_DEPTH, &counts, &total);
    var ver: ?[]const u8 = null;
    if (exec_fn(alloc, io, try versionArgv(alloc))) |r| {
        if (termOk(r.term)) ver = std.mem.trim(u8, r.stdout, " \r\n\t");
    } else |_| {}
    return .{ .text = try jsonOf(alloc, ProjInfo{
        .name = readProjectName(alloc, io, proj) orelse std.fs.path.basename(proj),
        .path = proj,
        .godotVersion = ver,
        .structure = counts,
    }) };
}

// ---------------------------------------------------------------------------
// Handlers: scene operations (gated)
// ---------------------------------------------------------------------------

const scene_err = "scenePath: need .tscn/.scn, res:// or relative, no traversal";

fn handleCreateScene(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    if (!writeAllowed()) return staticErr(write_refused_msg);
    const proj = switch (try projectArg(alloc, io, args)) {
        .ok => |d| d,
        .err => |e| return e,
    };
    const sp = resPath(alloc, getStr(args, "scenePath") orelse "", &scene_exts) catch return staticErr(scene_err);
    const rt = getStr(args, "rootNodeType") orelse "Node2D";
    if (!identOk(rt, false)) return staticErr("rootNodeType: invalid");
    return runOp(alloc, io, proj, "create_scene", try jsonOf(alloc, .{ .scene_path = sp, .root_type = rt }));
}

fn handleAddNode(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    if (!writeAllowed()) return staticErr(write_refused_msg);
    const proj = switch (try projectArg(alloc, io, args)) {
        .ok => |d| d,
        .err => |e| return e,
    };
    const sp = resPath(alloc, getStr(args, "scenePath") orelse "", &scene_exts) catch return staticErr(scene_err);
    const nt = getStr(args, "nodeType") orelse "";
    if (!identOk(nt, false)) return staticErr("nodeType: invalid");
    const nn = getStr(args, "nodeName") orelse "";
    if (!identOk(nn, true)) return staticErr("nodeName: invalid (letters, digits, _ - space)");
    const parent = getStr(args, "parentNodePath") orelse "root";
    if (!nodePathOk(parent)) return staticErr("parentNodePath: invalid");
    var props: std.json.Value = .{ .object = .empty };
    if (args == .object) if (args.object.get("properties")) |pv| {
        if (pv != .object) return staticErr("properties must be an object");
        var it = pv.object.iterator();
        while (it.next()) |e| if (!propKeyOk(e.key_ptr.*)) return errRes(alloc, "property name not allowed: {s}", .{e.key_ptr.*});
        props = pv;
    };
    return runOp(alloc, io, proj, "add_node", try jsonOf(alloc, .{
        .scene_path = sp,
        .node_type = nt,
        .node_name = nn,
        .parent_path = parent,
        .properties = props,
    }));
}

fn handleLoadSprite(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    if (!writeAllowed()) return staticErr(write_refused_msg);
    const proj = switch (try projectArg(alloc, io, args)) {
        .ok => |d| d,
        .err => |e| return e,
    };
    const sp = resPath(alloc, getStr(args, "scenePath") orelse "", &scene_exts) catch return staticErr(scene_err);
    const np = getStr(args, "nodePath") orelse "";
    if (!nodePathOk(np)) return staticErr("nodePath: invalid");
    const tp = resPath(alloc, getStr(args, "texturePath") orelse "", &tex_exts) catch return staticErr("texturePath: need an image/resource path, no traversal");
    return runOp(alloc, io, proj, "load_sprite", try jsonOf(alloc, .{ .scene_path = sp, .node_path = np, .texture_path = tp }));
}

fn handleExportMeshLibrary(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    if (!writeAllowed()) return staticErr(write_refused_msg);
    const proj = switch (try projectArg(alloc, io, args)) {
        .ok => |d| d,
        .err => |e| return e,
    };
    const sp = resPath(alloc, getStr(args, "scenePath") orelse "", &scene_exts) catch return staticErr(scene_err);
    const op = resPath(alloc, getStr(args, "outputPath") orelse "", &lib_exts) catch return staticErr("outputPath: need .tres/.res, no traversal");
    var names: std.ArrayList([]const u8) = .empty;
    if (args == .object) if (args.object.get("meshItemNames")) |nv| {
        if (nv != .array) return staticErr("meshItemNames must be an array");
        for (nv.array.items) |it| {
            if (it != .string or !identOk(it.string, true)) return staticErr("meshItemNames: invalid entry");
            try names.append(alloc, it.string);
        }
    };
    return runOp(alloc, io, proj, "export_mesh_library", try jsonOf(alloc, .{ .scene_path = sp, .output_path = op, .mesh_item_names = names.items }));
}

fn handleSaveScene(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    if (!writeAllowed()) return staticErr(write_refused_msg);
    const proj = switch (try projectArg(alloc, io, args)) {
        .ok => |d| d,
        .err => |e| return e,
    };
    const sp = resPath(alloc, getStr(args, "scenePath") orelse "", &scene_exts) catch return staticErr(scene_err);
    var np: ?[]const u8 = null;
    if (getStr(args, "newPath")) |n| np = resPath(alloc, n, &scene_exts) catch return staticErr("newPath: need .tscn/.scn, no traversal");
    return runOp(alloc, io, proj, "save_scene", try jsonOf(alloc, .{ .scene_path = sp, .new_path = np }));
}

fn handleGetUid(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const proj = switch (try projectArg(alloc, io, args)) {
        .ok => |d| d,
        .err => |e| return e,
    };
    const fp = resPath(alloc, getStr(args, "filePath") orelse "", &any_ext) catch return staticErr("filePath: invalid, no traversal");
    return runOp(alloc, io, proj, "get_uid", try jsonOf(alloc, .{ .file_path = fp }));
}

fn handleUpdateUids(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    if (!writeAllowed()) return staticErr(write_refused_msg);
    const proj = switch (try projectArg(alloc, io, args)) {
        .ok => |d| d,
        .err => |e| return e,
    };
    return runOp(alloc, io, proj, "update_uids", "{}");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

var t_argv: []const []const u8 = &.{};
var t_calls: usize = 0;
var t_stdout: []const u8 = "";
var t_stderr: []const u8 = "";
var t_code: u8 = 0;
var t_err: ?anyerror = null;
var t_script_ok = false;
var t_params: []const u8 = "";

fn fakeExec(alloc: std.mem.Allocator, io: Io, argv: []const []const u8) anyerror!ExecResult {
    t_calls += 1;
    t_argv = try alloc.dupe([]const u8, argv);
    // ops script path is argv[len-4] when run with the ops shape.
    for (argv, 0..) |a, i| {
        if (std.mem.eql(u8, a, "--script") and i + 1 < argv.len) {
            const data = try Io.Dir.cwd().readFileAlloc(io, argv[i + 1], alloc, .limited(1 << 20));
            t_script_ok = std.mem.eql(u8, data, ops_gd);
        }
        if (std.mem.eql(u8, a, "--") and i + 2 < argv.len) t_params = try alloc.dupe(u8, argv[i + 2]);
    }
    if (t_err) |e| return e;
    return .{ .term = .{ .exited = t_code }, .stdout = try alloc.dupe(u8, t_stdout), .stderr = try alloc.dupe(u8, t_stderr) };
}

const T = struct {
    arena_state: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,

    fn init(t: *T, allow_write: bool) !void {
        t.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        t.env = std.process.Environ.Map.init(testing.allocator);
        if (allow_write) try t.env.put("ZMCP_GODOT_ALLOW_WRITE", "1");
        try t.env.put("ZMCP_GODOT_ALLOW_RUN", "1");
        g_environ = &t.env;
        exec_fn = fakeExec;
        t_argv = &.{};
        t_calls = 0;
        t_stdout = "";
        t_stderr = "";
        t_code = 0;
        t_err = null;
        t_script_ok = false;
        t_params = "";
        g_bin_override = "godot-test";
        g_bin_prefix = &.{};
    }

    fn deinit(t: *T) void {
        exec_fn = execReal;
        g_environ = null;
        g_bin_override = null;
        g_bin_prefix = &.{};
        t.env.deinit();
        t.arena_state.deinit();
    }

    fn alloc(t: *T) std.mem.Allocator {
        return t.arena_state.allocator();
    }

    fn args(t: *T, json: []const u8) !std.json.Value {
        return (try std.json.parseFromSlice(std.json.Value, t.alloc(), json, .{})).value;
    }
};

fn makeProject(tmp: anytype, alloc: std.mem.Allocator) ![]const u8 {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "project.godot", .data = "config_version=5\n[application]\nconfig/name=\"Demo Game\"\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    return alloc.dupe(u8, buf[0..n]);
}

test "argOk rejects flags and control chars" {
    try testing.expect(argOk("/home/u/game"));
    try testing.expect(!argOk("-e"));
    try testing.expect(!argOk(""));
    try testing.expect(!argOk("a\x00b"));
    try testing.expect(!argOk("a\nb"));
}

test "resPath validation and traversal rejection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("res://scenes/main.tscn", try resPath(a, "scenes/main.tscn", &scene_exts));
    try testing.expectEqualStrings("res://main.tscn", try resPath(a, "res://main.tscn", &scene_exts));
    const bad = [_][]const u8{ "../x.tscn", "res://../x.tscn", "a/../../x.tscn", "/etc/x.tscn", "a\\b.tscn", "a//b.tscn", "C:/x.tscn", "a/./b.tscn", "x.txt", "", "res://", "user://x.tscn", "a/b.tscn/" };
    for (bad) |b| try testing.expectError(error.BadPath, resPath(a, b, &scene_exts));
}

test "node paths, identifiers, property keys" {
    try testing.expect(nodePathOk("root"));
    try testing.expect(nodePathOk("root/Player/Sprite"));
    try testing.expect(!nodePathOk("../x"));
    try testing.expect(!nodePathOk("/root"));
    try testing.expect(!nodePathOk("a/../b"));
    try testing.expect(!nodePathOk(""));
    try testing.expect(identOk("Sprite2D", false));
    try testing.expect(!identOk("A/B", false));
    try testing.expect(!identOk("A B", false));
    try testing.expect(identOk("A B", true));
    try testing.expect(!identOk("x;y", true));
    try testing.expect(propKeyOk("position"));
    try testing.expect(propKeyOk("theme_override_colors/font_color"));
    try testing.expect(!propKeyOk("script"));
    try testing.expect(!propKeyOk("a b"));
}

test "resolveProject canonicalizes and validates" {
    var t: T = undefined;
    try t.init(false);
    defer t.deinit();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const a = t.alloc();
    // no project.godot yet
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const root = buf[0..n];
    try testing.expect(resolveProject(a, testing.io, root) == .err);
    const proj = try makeProject(&tmp, a);
    const r = resolveProject(a, testing.io, proj);
    try testing.expectEqualStrings(proj, r.ok);
    // non-canonical spelling resolves to the same canonical path
    const dotted = try std.fmt.allocPrint(a, "{s}/./", .{proj});
    try testing.expectEqualStrings(proj, resolveProject(a, testing.io, dotted).ok);
    try testing.expect(resolveProject(a, testing.io, "-e") == .err);
    try testing.expect(resolveProject(a, testing.io, "/no/such/dir/xyz") == .err);
    const pg = try std.fmt.allocPrint(a, "{s}/project.godot", .{proj});
    try testing.expect(resolveProject(a, testing.io, pg) == .err);
}

test "argv builders" {
    var t: T = undefined;
    try t.init(false);
    defer t.deinit();
    const a = t.alloc();
    try testing.expectEqualSlices([]const u8, &.{ "godot-test", "--version" }, try versionArgv(a));
    try testing.expectEqualSlices([]const u8, &.{ "godot-test", "-e", "--path", "/p" }, try editorArgv(a, "/p"));
    try testing.expectEqualSlices([]const u8, &.{ "godot-test", "-d", "--path", "/p" }, try runArgv(a, "/p", null));
    try testing.expectEqualSlices([]const u8, &.{ "godot-test", "-d", "--path", "/p", "res://a.tscn" }, try runArgv(a, "/p", "res://a.tscn"));
    try testing.expectEqualSlices([]const u8, &.{ "godot-test", "--headless", "--path", "/p", "--script", "/t/o.gd", "--", "add_node", "{}" }, try opsArgv(a, "/p", "/t/o.gd", "add_node", "{}"));
}

test "GODOT_PATH selects binary" {
    var t: T = undefined;
    try t.init(false);
    defer t.deinit();
    g_bin_override = null;
    try testing.expectEqualStrings("godot", godotBin());
    try t.env.put("GODOT_PATH", "/opt/godot4");
    try testing.expectEqualStrings("/opt/godot4", godotBin());
}

test "ring buffer wraps, overwrites oldest, counts dropped" {
    var r = try Ring.init(testing.allocator, 8);
    defer r.deinit(testing.allocator);
    r.write("abc");
    r.write("def");
    var s = try r.snapshot(testing.allocator);
    try testing.expectEqualStrings("abcdef", s);
    testing.allocator.free(s);
    r.write("ghij"); // 10 total, drops 2
    s = try r.snapshot(testing.allocator);
    try testing.expectEqualStrings("cdefghij", s);
    testing.allocator.free(s);
    try testing.expectEqual(@as(u64, 2), r.dropped);
    r.write("0123456789XYZ"); // larger than cap keeps last 8
    s = try r.snapshot(testing.allocator);
    try testing.expectEqualStrings("56789XYZ", s);
    testing.allocator.free(s);
    r.write("q");
    s = try r.snapshot(testing.allocator);
    try testing.expectEqualStrings("6789XYZq", s);
    testing.allocator.free(s);
    try testing.expectEqual(@as(usize, 8), r.len);
}

test "ring buffer wrap-around write across the end" {
    var r = try Ring.init(testing.allocator, 5);
    defer r.deinit(testing.allocator);
    r.write("abcd");
    r.write("ef"); // start moves to 1, write wraps
    const s = try r.snapshot(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("bcdef", s);
}

test "ops.gd is embedded and covers every operation" {
    try testing.expect(std.mem.startsWith(u8, ops_gd, "extends SceneTree"));
    const ops = [_][]const u8{ "create_scene", "add_node", "load_sprite", "save_scene", "export_mesh_library", "get_uid", "update_uids" };
    for (ops) |o| {
        const needle = try std.fmt.allocPrint(testing.allocator, "\"{s}\":", .{o});
        defer testing.allocator.free(needle);
        try testing.expect(std.mem.indexOf(u8, ops_gd, needle) != null);
    }
    try testing.expect(std.mem.indexOf(u8, ops_gd, RESULT_PREFIX) != null);
}

test "write tools are refused without ZMCP_GODOT_ALLOW_WRITE=1 and never exec" {
    var t: T = undefined;
    try t.init(false);
    defer t.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const proj = try makeProject(&tmp, t.alloc());
    const a = t.alloc();
    const body = try std.fmt.allocPrint(a, "{{\"projectPath\":\"{s}\",\"scenePath\":\"a.tscn\",\"nodeType\":\"Node\",\"nodeName\":\"N\",\"nodePath\":\"root\",\"texturePath\":\"t.png\",\"outputPath\":\"l.tres\"}}", .{proj});
    const v = try t.args(body);
    const handlers = [_]mcp.ToolHandler{ handleCreateScene, handleAddNode, handleLoadSprite, handleSaveScene, handleExportMeshLibrary, handleUpdateUids };
    for (handlers) |h| {
        const r = try h(a, testing.io, v);
        try testing.expect(r.is_error);
        try testing.expectEqualStrings(write_refused_msg, r.text);
    }
    try testing.expectEqual(@as(usize, 0), t_calls);
    // "0" or other values are not enough
    try t.env.put("ZMCP_GODOT_ALLOW_WRITE", "true");
    try testing.expect(!writeAllowed());
    try t.env.put("ZMCP_GODOT_ALLOW_WRITE", "1");
    try testing.expect(writeAllowed());
}

test "launch_editor and run_project are refused without ZMCP_GODOT_ALLOW_RUN=1 and never exec" {
    var t: T = undefined;
    try t.init(false);
    defer t.deinit();
    _ = t.env.swapRemove("ZMCP_GODOT_ALLOW_RUN");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const proj = try makeProject(&tmp, t.alloc());
    const a = t.alloc();
    const v = try t.args(try std.fmt.allocPrint(a, "{{\"projectPath\":\"{s}\"}}", .{proj}));
    for ([_]mcp.ToolHandler{ handleLaunchEditor, handleRunProject }) |h| {
        const r = try h(a, testing.io, v);
        try testing.expect(r.is_error);
        try testing.expectEqualStrings(run_refused_msg, r.text);
    }
    try testing.expectEqual(@as(usize, 0), t_calls);
    try t.env.put("ZMCP_GODOT_ALLOW_RUN", "true");
    try testing.expect(!runAllowed());
}

test "add_node runs ops.gd through exec seam with exact argv and params" {
    var t: T = undefined;
    try t.init(true);
    defer t.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = t.alloc();
    const proj = try makeProject(&tmp, a);
    t_stdout = "Godot Engine v4.3\nZMCP_RESULT {\"node\":\"Player\",\"ok\":true}\n";
    const body = try std.fmt.allocPrint(a, "{{\"projectPath\":\"{s}\",\"scenePath\":\"scenes/main.tscn\",\"nodeType\":\"Sprite2D\",\"nodeName\":\"Player\",\"properties\":{{\"position\":\"Vector2(1, 2)\"}}}}", .{proj});
    const r = try handleAddNode(a, testing.io, try t.args(body));
    try testing.expect(!r.is_error);
    try testing.expectEqualStrings("{\"node\":\"Player\",\"ok\":true}", r.text);
    try testing.expectEqual(@as(usize, 1), t_calls);
    const av = t_argv;
    try testing.expectEqualStrings("godot-test", av[0]);
    try testing.expectEqualStrings("--headless", av[1]);
    try testing.expectEqualStrings("--path", av[2]);
    try testing.expectEqualStrings(proj, av[3]);
    try testing.expectEqualStrings("--script", av[4]);
    try testing.expect(std.mem.indexOf(u8, av[5], "zmcp-godot-") != null);
    try testing.expectEqualStrings("--", av[6]);
    try testing.expectEqualStrings("add_node", av[7]);
    try testing.expectEqualStrings(
        "{\"scene_path\":\"res://scenes/main.tscn\",\"node_type\":\"Sprite2D\",\"node_name\":\"Player\",\"parent_path\":\"root\",\"properties\":{\"position\":\"Vector2(1, 2)\"}}",
        av[8],
    );
    try testing.expectEqual(@as(usize, 9), av.len);
    try testing.expect(t_script_ok);
    // temp script removed afterwards
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(testing.io, av[5], .{}));
}

test "operation errors, missing result, missing binary" {
    var t: T = undefined;
    try t.init(true);
    defer t.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = t.alloc();
    const proj = try makeProject(&tmp, a);
    const body = try std.fmt.allocPrint(a, "{{\"projectPath\":\"{s}\",\"scenePath\":\"m.tscn\"}}", .{proj});
    const v = try t.args(body);

    t_stdout = "ZMCP_RESULT {\"ok\":false,\"error\":\"invalid root node type: Foo\"}\n";
    t_code = 1;
    var r = try handleCreateScene(a, testing.io, v);
    try testing.expect(r.is_error);
    try testing.expectEqualStrings("invalid root node type: Foo", r.text);

    t_stdout = "some noise\n";
    t_stderr = "SCRIPT ERROR: boom";
    r = try handleCreateScene(a, testing.io, v);
    try testing.expect(r.is_error);
    try testing.expect(std.mem.indexOf(u8, r.text, "no result") != null);
    try testing.expect(std.mem.indexOf(u8, r.text, "boom") != null);

    t_err = error.ExecutableNotFound;
    r = try handleCreateScene(a, testing.io, v);
    try testing.expect(r.is_error);
    try testing.expectEqualStrings(missing_msg, r.text);
    r = try handleVersion(a, testing.io, v);
    try testing.expectEqualStrings(missing_msg, r.text);
}

test "traversal and bad args rejected before exec" {
    var t: T = undefined;
    try t.init(true);
    defer t.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = t.alloc();
    const proj = try makeProject(&tmp, a);
    const bad = [_][]const u8{
        "\"scenePath\":\"../evil.tscn\"",
        "\"scenePath\":\"res://../../evil.tscn\"",
        "\"scenePath\":\"/tmp/evil.tscn\"",
        "\"scenePath\":\"a.tscn\",\"rootNodeType\":\"Node;rm\"",
    };
    for (bad) |b| {
        const body = try std.fmt.allocPrint(a, "{{\"projectPath\":\"{s}\",{s}}}", .{ proj, b });
        const r = try handleCreateScene(a, testing.io, try t.args(body));
        try testing.expect(r.is_error);
    }
    const r1 = try handleAddNode(a, testing.io, try t.args(try std.fmt.allocPrint(a, "{{\"projectPath\":\"{s}\",\"scenePath\":\"a.tscn\",\"nodeType\":\"Node\",\"nodeName\":\"N\",\"parentNodePath\":\"../x\"}}", .{proj})));
    try testing.expect(r1.is_error);
    const r2 = try handleAddNode(a, testing.io, try t.args(try std.fmt.allocPrint(a, "{{\"projectPath\":\"{s}\",\"scenePath\":\"a.tscn\",\"nodeType\":\"Node\",\"nodeName\":\"N\",\"properties\":{{\"script\":\"x\"}}}}", .{proj})));
    try testing.expect(r2.is_error);
    const r3 = try handleCreateScene(a, testing.io, try t.args("{\"projectPath\":\"-e\",\"scenePath\":\"a.tscn\"}"));
    try testing.expect(r3.is_error);
    const r4 = try handleGetUid(a, testing.io, try t.args(try std.fmt.allocPrint(a, "{{\"projectPath\":\"{s}\",\"filePath\":\"../../etc/passwd\"}}", .{proj})));
    try testing.expect(r4.is_error);
    try testing.expectEqual(@as(usize, 0), t_calls);
}

test "get_godot_version and project info via fake exec" {
    var t: T = undefined;
    try t.init(false);
    defer t.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = t.alloc();
    const proj = try makeProject(&tmp, a);
    try tmp.dir.createDir(testing.io, "sub", .default_dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "main.tscn", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "sub/a.gd", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "sub/b.gd", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "sub/i.png", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.txt", .data = "" });
    t_stdout = "4.3.stable.official.abc\n";
    var r = try handleVersion(a, testing.io, try t.args("{}"));
    try testing.expectEqualStrings("4.3.stable.official.abc", r.text);
    try testing.expectEqualSlices([]const u8, &.{ "godot-test", "--version" }, t_argv);
    r = try handleProjectInfo(a, testing.io, try t.args(try std.fmt.allocPrint(a, "{{\"projectPath\":\"{s}\"}}", .{proj})));
    const want = try std.fmt.allocPrint(a, "{{\"name\":\"Demo Game\",\"path\":\"{s}\",\"godotVersion\":\"4.3.stable.official.abc\",\"structure\":{{\"scenes\":1,\"scripts\":2,\"assets\":1,\"other\":2}}}}", .{proj});
    try testing.expectEqualStrings(want, r.text);
}

test "list_projects scans with depth cap" {
    var t: T = undefined;
    try t.init(false);
    defer t.deinit();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const a = t.alloc();
    const pg = "config/name=\"P\"\n";
    try tmp.dir.createDirPath(testing.io, "a");
    try tmp.dir.createDirPath(testing.io, "b/deep/deeper/deepest/x");
    try tmp.dir.createDirPath(testing.io, ".hidden");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a/project.godot", .data = pg });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".hidden/project.godot", .data = pg });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b/deep/project.godot", .data = pg });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b/deep/deeper/deepest/x/project.godot", .data = pg });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const root = try a.dupe(u8, buf[0..n]);
    var r = try handleListProjects(a, testing.io, try t.args(try std.fmt.allocPrint(a, "{{\"directory\":\"{s}\"}}", .{root})));
    try testing.expect(!r.is_error);
    try testing.expect(std.mem.indexOf(u8, r.text, "/a\"") != null);
    try testing.expect(std.mem.indexOf(u8, r.text, "deep") == null);
    try testing.expect(std.mem.indexOf(u8, r.text, ".hidden") == null);
    r = try handleListProjects(a, testing.io, try t.args(try std.fmt.allocPrint(a, "{{\"directory\":\"{s}\",\"recursive\":true}}", .{root})));
    try testing.expect(std.mem.indexOf(u8, r.text, "/b/deep\"") != null);
    try testing.expect(std.mem.indexOf(u8, r.text, "deepest") == null); // beyond depth cap
    try testing.expect((try handleListProjects(a, testing.io, try t.args("{\"directory\":\"-x\"}"))).is_error);
}

test "parseProjectName" {
    try testing.expectEqualStrings("Hi There", parseProjectName("[application]\nconfig/name=\"Hi There\"\n").?);
    try testing.expect(parseProjectName("[x]\n") == null);
}

test "run_project tracks a real child: capture, single instance, stop" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var t: T = undefined;
    try t.init(false);
    defer t.deinit();
    exec_fn = execReal;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = t.alloc();
    const proj = try makeProject(&tmp, a);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "fake.sh", .data = "echo hello-out; echo oops-err >&2; exec sleep 30\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const script = try std.fmt.allocPrint(a, "{s}/fake.sh", .{buf[0..n]});
    g_bin_override = "/bin/sh";
    g_bin_prefix = &.{script};
    defer shutdownSession(testing.io);

    const body = try std.fmt.allocPrint(a, "{{\"projectPath\":\"{s}\"}}", .{proj});
    const v = try t.args(body);
    var r = try handleRunProject(a, testing.io, v);
    try testing.expect(!r.is_error);
    // second run is refused while the first is alive
    r = try handleRunProject(a, testing.io, v);
    try testing.expect(r.is_error);

    var got = false;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        r = try handleDebugOutput(a, testing.io, try t.args("{}"));
        if (std.mem.indexOf(u8, r.text, "hello-out") != null and std.mem.indexOf(u8, r.text, "oops-err") != null) {
            got = true;
            break;
        }
        try testing.io.sleep(.fromMilliseconds(20), .awake);
    }
    try testing.expect(got);
    try testing.expect(std.mem.indexOf(u8, r.text, "\"running\":true") != null);

    r = try handleStopProject(a, testing.io, try t.args("{}"));
    try testing.expectEqualStrings("stopped", r.text);
    r = try handleDebugOutput(a, testing.io, try t.args("{}"));
    try testing.expect(std.mem.indexOf(u8, r.text, "\"running\":false") != null);
    try testing.expect(std.mem.indexOf(u8, r.text, "killed") != null);
    try testing.expect(std.mem.indexOf(u8, r.text, "hello-out") != null);
    r = try handleStopProject(a, testing.io, try t.args("{}"));
    try testing.expectEqualStrings("project was not running", r.text);
}

test "run_project reports natural exit and allows restart; missing binary is clear" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var t: T = undefined;
    try t.init(false);
    defer t.deinit();
    exec_fn = execReal;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = t.alloc();
    const proj = try makeProject(&tmp, a);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "quick.sh", .data = "echo done; exit 3\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const script = try std.fmt.allocPrint(a, "{s}/quick.sh", .{buf[0..n]});
    g_bin_override = "/bin/sh";
    g_bin_prefix = &.{script};
    defer shutdownSession(testing.io);
    const v = try t.args(try std.fmt.allocPrint(a, "{{\"projectPath\":\"{s}\"}}", .{proj}));
    _ = try handleRunProject(a, testing.io, v);
    var r: mcp.ToolResult = undefined;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        r = try handleDebugOutput(a, testing.io, try t.args("{}"));
        if (std.mem.indexOf(u8, r.text, "\"running\":false") != null) break;
        try testing.io.sleep(.fromMilliseconds(20), .awake);
    }
    try testing.expect(std.mem.indexOf(u8, r.text, "exit 3") != null);
    try testing.expect(std.mem.indexOf(u8, r.text, "done") != null);
    r = try handleRunProject(a, testing.io, v); // restart allowed
    try testing.expect(!r.is_error);
    shutdownSession(testing.io);

    g_bin_override = "/nonexistent/godot-binary";
    g_bin_prefix = &.{};
    r = try handleRunProject(a, testing.io, v);
    try testing.expect(r.is_error);
    try testing.expectEqualStrings(missing_msg, r.text);
}
