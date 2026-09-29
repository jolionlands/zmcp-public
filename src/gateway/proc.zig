//! Real child processes: locating `zmcp-<name>` binaries, building the child
//! environment, and the stdio JSON-RPC connection (`pool.Conn`).
//!
//! Safety: a child is only ever started from an argv of one element, the
//! path of a binary found by `Locator` for a *validated* server name
//! (`profile.validServerName`). No shell is involved and no user-supplied
//! string reaches the command line.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const pool = @import("pool.zig");
const profile = @import("profile.zig");
const catalog = @import("catalog.zig");

pub const binary_prefix = "zmcp-";
pub const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
pub const path_sep: u8 = if (builtin.os.tag == .windows) ';' else ':';

/// Largest single JSON-RPC line accepted from a child.
pub const MAX_LINE_BYTES: usize = 64 * 1024 * 1024;

// ---------------------------------------------------------------------------
// Child environment
// ---------------------------------------------------------------------------

/// Variables the gateway consumes (or replaces) and children must not see:
/// hosting (ZMCP_HTTP*), gateway config (ZMCP_GATEWAY_*), the exposure mode
/// (children stay in full mode) and the slicing envs (re-derived per child).
pub fn isGatewayVar(key: []const u8) bool {
    if (std.mem.startsWith(u8, key, "ZMCP_HTTP")) return true;
    if (std.mem.startsWith(u8, key, "ZMCP_GATEWAY_")) return true;
    const exact = [_][]const u8{ "ZMCP_TOOL_MODE", "ZMCP_TOOLS", "ZMCP_TOOLS_DENY", "ZMCP_READONLY" };
    for (exact) |e| {
        if (std.mem.eql(u8, key, e)) return true;
    }
    return false;
}

/// Slicing env values for one child (comma-joined globs).
pub const EnvPlan = struct {
    allow: []const u8 = "",
    deny: []const u8 = "",
    readonly: bool = false,
};

/// A copy of `base` without gateway-only variables, plus the child's slicing
/// envs from `plan`. Everything else (API keys, ZMCP_DOCKER_ALLOW_WRITE,
/// ZMCP_MAX_RESULT_BYTES, PATH, ...) is inherited unchanged.
pub fn buildChildEnv(gpa: std.mem.Allocator, base: *const std.process.Environ.Map, plan: EnvPlan) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(gpa);
    errdefer env.deinit();
    var it = base.iterator();
    while (it.next()) |kv| {
        if (isGatewayVar(kv.key_ptr.*)) continue;
        try env.put(kv.key_ptr.*, kv.value_ptr.*);
    }
    if (plan.allow.len > 0) try env.put("ZMCP_TOOLS", plan.allow);
    if (plan.deny.len > 0) try env.put("ZMCP_TOOLS_DENY", plan.deny);
    if (plan.readonly) try env.put("ZMCP_READONLY", "1");
    return env;
}

fn anyToolMatches(pattern: []const u8, tools: []const catalog.Tool) bool {
    for (tools) |t| {
        if (@import("mcp").globMatch(pattern, t.name)) return true;
    }
    return false;
}

fn joinPatterns(a: std.mem.Allocator, pats: []const []const u8, tools: []const catalog.Tool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (pats) |p| {
        if (!anyToolMatches(p, tools)) continue;
        if (out.items.len > 0) try out.append(a, ',');
        try out.appendSlice(a, p);
    }
    return out.items;
}

/// Per-child slicing envs (defense in depth; the gateway enforces the slice
/// itself). Patterns that match none of the child's tools are left out so
/// children do not warn about them; if a profile allowlist matches nothing in
/// this child, the child is told to expose nothing (`ZMCP_TOOLS_DENY=*`).
pub fn planFor(a: std.mem.Allocator, sl: profile.Slice, tools: []const catalog.Tool) !EnvPlan {
    var plan: EnvPlan = .{ .readonly = sl.readonly };
    plan.deny = try joinPatterns(a, sl.deny, tools);
    if (sl.allow.len > 0) {
        plan.allow = try joinPatterns(a, sl.allow, tools);
        if (plan.allow.len == 0) plan.deny = "*";
    }
    return plan;
}

// ---------------------------------------------------------------------------
// Locating binaries
// ---------------------------------------------------------------------------

pub const Found = struct {
    /// Absolute path (owned by the allocator passed to `locate`).
    path: []const u8,
    size: u64,
    mtime_ms: i64,
};

/// Where `zmcp-<name>` binaries live: `bin_dir` (ZMCP_GATEWAY_BIN_DIR, or the
/// gateway executable's directory), then each absolute entry of PATH.
pub const Locator = struct {
    bin_dir: []const u8 = "",
    path_env: []const u8 = "",

    pub fn fileName(a: std.mem.Allocator, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(a, "{s}{s}{s}", .{ binary_prefix, name, exe_suffix });
    }

    fn statIn(io: Io, a: std.mem.Allocator, dir: []const u8, fname: []const u8) ?Found {
        if (dir.len == 0 or !std.fs.path.isAbsolute(dir)) return null;
        const full = std.fs.path.join(a, &.{ dir, fname }) catch return null;
        const st = Io.Dir.cwd().statFile(io, full, .{}) catch {
            a.free(full);
            return null;
        };
        if (st.kind != .file and st.kind != .sym_link) {
            a.free(full);
            return null;
        }
        return .{ .path = full, .size = st.size, .mtime_ms = st.mtime.toMilliseconds() };
    }

    /// The binary for `name`, or null. `name` must already be validated.
    pub fn locate(self: Locator, io: Io, a: std.mem.Allocator, name: []const u8) ?Found {
        if (!profile.validServerName(name)) return null;
        const fname = fileName(a, name) catch return null;
        defer a.free(fname);
        if (statIn(io, a, self.bin_dir, fname)) |f| return f;
        var it = std.mem.tokenizeScalar(u8, self.path_env, path_sep);
        while (it.next()) |dir| {
            if (statIn(io, a, dir, fname)) |f| return f;
        }
        return null;
    }

    /// Names of every `zmcp-*` binary directly in `bin_dir` (gateway itself
    /// excluded), sorted. Owned by `a`.
    pub fn scan(self: Locator, io: Io, a: std.mem.Allocator) ![]const []const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        if (self.bin_dir.len == 0 or !std.fs.path.isAbsolute(self.bin_dir)) return names.items;
        var dir = Io.Dir.openDirAbsolute(io, self.bin_dir, .{ .iterate = true }) catch return names.items;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |e| {
            if (e.kind != .file and e.kind != .sym_link) continue;
            var n = e.name;
            if (!std.mem.startsWith(u8, n, binary_prefix)) continue;
            n = n[binary_prefix.len..];
            if (exe_suffix.len > 0) {
                if (!std.mem.endsWith(u8, n, exe_suffix)) continue;
                n = n[0 .. n.len - exe_suffix.len];
            }
            if (std.mem.eql(u8, n, "gateway")) continue;
            if (!profile.validServerName(n)) continue;
            try names.append(a, try a.dupe(u8, n));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        return names.items;
    }
};

// ---------------------------------------------------------------------------
// Connection
// ---------------------------------------------------------------------------

const ProcConn = struct {
    gpa: std.mem.Allocator,
    child: std.process.Child,
    buf: Io.File.MultiReader.Buffer(1) = undefined,
    mr: Io.File.MultiReader = undefined,
};

const proc_vtable: pool.Conn.VTable = .{ .exchange = exchange, .notify = notify, .close = closeConn };

fn writeLine(pc: *ProcConn, io: Io, line: []const u8) pool.ExchangeError!void {
    const stdin = pc.child.stdin orelse return error.WriteFailed;
    stdin.writeStreamingAll(io, line) catch return error.WriteFailed;
    stdin.writeStreamingAll(io, "\n") catch return error.WriteFailed;
}

fn notify(ctx: *anyopaque, io: Io, line: []const u8) pool.ExchangeError!void {
    const pc: *ProcConn = @ptrCast(@alignCast(ctx));
    return writeLine(pc, io, line);
}

/// Numeric `id` of a response line. Fast path for the exact prefix the zmcp
/// servers emit; anything else is parsed properly.
pub fn responseId(gpa: std.mem.Allocator, line: []const u8) ?u64 {
    const prefix = "{\"jsonrpc\":\"2.0\",\"id\":";
    if (std.mem.startsWith(u8, line, prefix)) {
        var i: usize = prefix.len;
        var v: u64 = 0;
        var digits: usize = 0;
        while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {
            v = std.math.mul(u64, v, 10) catch return null;
            v = std.math.add(u64, v, line[i] - '0') catch return null;
            digits += 1;
        }
        // Only a real response: id followed by "result" or "error" (a server
        // request carries "method" instead).
        const rest = line[i..];
        if (digits > 0 and (std.mem.startsWith(u8, rest, ",\"result\"") or std.mem.startsWith(u8, rest, ",\"error\""))) return v;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const idv = parsed.value.object.get("id") orelse return null;
    // A request from the child (has "method") is not our response.
    if (parsed.value.object.get("method") != null) return null;
    return switch (idv) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        else => null,
    };
}

fn exchange(ctx: *anyopaque, io: Io, gpa: std.mem.Allocator, line: []const u8, id: u64, timeout_ms: u64) pool.ExchangeError![]u8 {
    const pc: *ProcConn = @ptrCast(@alignCast(ctx));
    try writeLine(pc, io, line);
    const timeout: Io.Timeout = (Io.Timeout{ .duration = .{
        .raw = Io.Duration.fromMilliseconds(@intCast(@min(timeout_ms, std.math.maxInt(i64) / 2))),
        .clock = .awake,
    } }).toDeadline(io);
    const r = pc.mr.reader(0);
    while (true) {
        while (std.mem.indexOfScalar(u8, r.buffered(), '\n')) |nl| {
            const raw = r.buffered()[0..nl];
            const trimmed = std.mem.trimEnd(u8, raw, "\r");
            const matched = trimmed.len > 0 and responseId(gpa, trimmed) == id;
            const out: ?[]u8 = if (matched) (gpa.dupe(u8, trimmed) catch return error.OutOfMemory) else null;
            r.toss(nl + 1);
            if (out) |o| return o;
        }
        if (r.buffered().len > MAX_LINE_BYTES) return error.ResponseTooLarge;
        pc.mr.fill(4096, timeout) catch |e| switch (e) {
            error.Timeout => return error.Timeout,
            error.EndOfStream => return error.ChildExited,
            else => return error.ChildFailed,
        };
    }
}

fn closeConn(ctx: *anyopaque, io: Io) void {
    const pc: *ProcConn = @ptrCast(@alignCast(ctx));
    pc.mr.deinit();
    pc.child.kill(io);
    pc.gpa.destroy(pc);
}

// ---------------------------------------------------------------------------
// Real spawner
// ---------------------------------------------------------------------------

pub const RealSpawner = struct {
    gpa: std.mem.Allocator,
    locator: Locator,
    /// Environment children derive from (the gateway's own).
    base_env: *const std.process.Environ.Map,
    /// Per-server slicing envs; servers not listed get none.
    plans: std.StringHashMapUnmanaged(EnvPlan) = .empty,

    pub fn spawner(self: *RealSpawner) pool.Spawner {
        return .{ .ctx = self, .spawnFn = spawn };
    }
};

fn spawn(ctx: *anyopaque, io: Io, server: []const u8) pool.SpawnError!pool.Conn {
    const self: *RealSpawner = @ptrCast(@alignCast(ctx));
    const gpa = self.gpa;
    const found = self.locator.locate(io, gpa, server) orelse return error.NotFound;
    defer gpa.free(found.path);

    var env = buildChildEnv(gpa, self.base_env, self.plans.get(server) orelse .{}) catch return error.OutOfMemory;
    defer env.deinit();

    const pc = gpa.create(ProcConn) catch return error.OutOfMemory;
    errdefer gpa.destroy(pc);
    const child = std.process.spawn(io, .{
        .argv = &.{found.path},
        .environ_map = &env,
        .stdin = .pipe,
        .stdout = .pipe,
        // Child diagnostics go to the gateway's stderr (never stdout).
        .stderr = .inherit,
        .create_no_window = true,
    }) catch |e| switch (e) {
        error.FileNotFound => return error.NotFound,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SpawnFailed,
    };
    pc.* = .{ .gpa = gpa, .child = child };
    pc.mr.init(gpa, io, pc.buf.toStreams(), &.{pc.child.stdout.?});
    return .{ .ctx = pc, .vtable = &proc_vtable };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "isGatewayVar strips hosting, gateway and slicing variables only" {
    for ([_][]const u8{ "ZMCP_HTTP", "ZMCP_HTTP_TOKEN", "ZMCP_HTTP_ORIGINS", "ZMCP_GATEWAY_PROFILE", "ZMCP_GATEWAY_IDLE_SECS", "ZMCP_TOOL_MODE", "ZMCP_TOOLS", "ZMCP_TOOLS_DENY", "ZMCP_READONLY" }) |k| {
        try std.testing.expect(isGatewayVar(k));
    }
    for ([_][]const u8{ "ZMCP_MAX_RESULT_BYTES", "ZMCP_DOCKER_ALLOW_WRITE", "GITHUB_TOKEN", "PATH", "HOME", "ZMCP_TOOLSET", "MY_ZMCP_HTTP" }) |k| {
        // ZMCP_TOOLSET is not ZMCP_TOOLS; only exact matches count.
        try std.testing.expect(!isGatewayVar(k));
    }
}

test "buildChildEnv strips gateway vars, keeps the rest, applies the plan" {
    const alloc = std.testing.allocator;
    var base = std.process.Environ.Map.init(alloc);
    defer base.deinit();
    try base.put("PATH", "/usr/bin");
    try base.put("GITHUB_TOKEN", "secret");
    try base.put("ZMCP_DOCKER_ALLOW_WRITE", "1");
    try base.put("ZMCP_MAX_RESULT_BYTES", "1000");
    try base.put("ZMCP_HTTP", "127.0.0.1:9");
    try base.put("ZMCP_HTTP_TOKEN", "tok");
    try base.put("ZMCP_GATEWAY_PROFILE", "dev");
    try base.put("ZMCP_GATEWAY_EXPOSE", "direct");
    try base.put("ZMCP_TOOL_MODE", "lazy");
    try base.put("ZMCP_TOOLS", "outer_*");
    try base.put("ZMCP_READONLY", "1");

    var env = try buildChildEnv(alloc, &base, .{});
    defer env.deinit();
    try std.testing.expectEqualStrings("/usr/bin", env.get("PATH").?);
    try std.testing.expectEqualStrings("secret", env.get("GITHUB_TOKEN").?);
    try std.testing.expectEqualStrings("1", env.get("ZMCP_DOCKER_ALLOW_WRITE").?);
    try std.testing.expectEqualStrings("1000", env.get("ZMCP_MAX_RESULT_BYTES").?);
    for ([_][]const u8{ "ZMCP_HTTP", "ZMCP_HTTP_TOKEN", "ZMCP_GATEWAY_PROFILE", "ZMCP_GATEWAY_EXPOSE", "ZMCP_TOOL_MODE", "ZMCP_TOOLS", "ZMCP_READONLY", "ZMCP_TOOLS_DENY" }) |k| {
        try std.testing.expect(env.get(k) == null);
    }

    var env2 = try buildChildEnv(alloc, &base, .{ .allow = "git_*", .deny = "git_reset", .readonly = true });
    defer env2.deinit();
    try std.testing.expectEqualStrings("git_*", env2.get("ZMCP_TOOLS").?);
    try std.testing.expectEqualStrings("git_reset", env2.get("ZMCP_TOOLS_DENY").?);
    try std.testing.expectEqualStrings("1", env2.get("ZMCP_READONLY").?);
    try std.testing.expect(env2.get("ZMCP_TOOL_MODE") == null);
}

test "planFor keeps only patterns that match the child's tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tools = [_]catalog.Tool{
        .{ .name = "git_status", .description = "", .schema = "{}" },
        .{ .name = "git_reset", .description = "", .schema = "{}" },
    };
    const p1 = try planFor(a, .{ .allow = &.{ "git_*", "docker_*" }, .deny = &.{ "git_reset", "nope" }, .readonly = true }, &tools);
    try std.testing.expectEqualStrings("git_*", p1.allow);
    try std.testing.expectEqualStrings("git_reset", p1.deny);
    try std.testing.expect(p1.readonly);
    // Allowlist matches nothing here: the child exposes nothing.
    const p2 = try planFor(a, .{ .allow = &.{"docker_*"} }, &tools);
    try std.testing.expectEqualStrings("", p2.allow);
    try std.testing.expectEqualStrings("*", p2.deny);
    // No slice: no envs.
    const p3 = try planFor(a, .{}, &tools);
    try std.testing.expectEqualStrings("", p3.allow);
    try std.testing.expectEqualStrings("", p3.deny);
    try std.testing.expect(!p3.readonly);
}

test "responseId: fast path, reordered keys, notifications and requests" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(?u64, 7), responseId(alloc, "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}"));
    try std.testing.expectEqual(@as(?u64, 12), responseId(alloc, "{\"jsonrpc\":\"2.0\",\"result\":{\"id\":3},\"id\":12}"));
    try std.testing.expectEqual(@as(?u64, null), responseId(alloc, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{}}"));
    try std.testing.expectEqual(@as(?u64, null), responseId(alloc, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"sampling/createMessage\"}"));
    try std.testing.expectEqual(@as(?u64, null), responseId(alloc, "not json"));
    try std.testing.expectEqual(@as(?u64, null), responseId(alloc, "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"result\":{}}"));
}

test "Locator refuses invalid names and non-absolute directories" {
    const alloc = std.testing.allocator;
    const loc: Locator = .{ .bin_dir = "relative/dir", .path_env = "also/relative" };
    try std.testing.expect(loc.locate(std.testing.io, alloc, "git") == null);
    const loc2: Locator = .{ .bin_dir = "/usr/bin", .path_env = "/bin" };
    try std.testing.expect(loc2.locate(std.testing.io, alloc, "../sh") == null);
    try std.testing.expect(loc2.locate(std.testing.io, alloc, "a/b") == null);
    try std.testing.expect(loc2.locate(std.testing.io, alloc, "") == null);
}
