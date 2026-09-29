//! zmcp-desktop: Windows UI Automation observe (Z2) and act (Z3) for allowlisted apps.
//!
//!   zmcp-desktop --allow "C:\Program Files\Signal\Signal.exe" [--allow PATH|PATH ...] [--kill-event NAME]
//!                [--max-steps N] [--step-timeout-ms N] [--session-timeout-s N] [--idle-ms N] [--allow-payments]
//!
//! The allowlist holds FULL image paths (see policy.zig `Policy`).
//!
//! Tools (stateless; element ids are UIA runtime ids `r<hex>-<hex>…`,
//! re-resolved on every call):
//!   desktop_list_windows {}                        visible top-level windows of allowlisted processes
//!   desktop_observe {hwnd, max_depth?, max_nodes?, root?}   compact ControlView tree
//!   desktop_find {hwnd, role?, name_contains?, limit?}      matching nodes
//!   desktop_focused {hwnd}                         the focused element, if hwnd is the foreground window
//!   desktop_act {hwnd, id, action, value?}         invoke|focus|set_value|select|expand|scroll_into_view
//!   desktop_type {hwnd, text}                      Unicode keystrokes into the focused element (foreground only)
//!   desktop_key {hwnd, keys}                       one allowlisted chord (policy.allowed_chords; foreground only)
//!   desktop_click {hwnd, x, y}                     a left click inside the window, only where UIA can't invoke
//!   desktop_scroll {hwnd, id, direction, amount?}  ScrollPattern on the element or its nearest scrollable ancestor
//!
//! Every act returns {ok, action, after: {focused_id, window_title}}.
//!
//! Safety:
//!   - no default allowlist: without --allow every call is refused; entries are
//!     full image paths matched case-insensitively, never bare names;
//!   - the kill event (`Local\zmcp-desktop-kill-<ppid>` unless --kill-event)
//!     is checked before every call; when set, calls return "stopped by the user";
//!   - UWP: ApplicationFrameHost.exe is never an entry; its windows are gated
//!     on the hosted CoreWindow's process;
//!   - windows of elevated processes, the secure desktop, LogonUI.exe,
//!     consent.exe and CredentialUIBroker.exe are always refused; nodes that
//!     belong to a process that is not allowlisted are dropped with their subtree;
//!   - password fields: the value is never requested and never returned;
//!   - no network code at all: private-app content never leaves this process
//!     except over stdio to the host (F43).
//!
//! Act safety (Z3), checked at the start of every act AND again right before
//! its side effect (and between every injected chunk of typing):
//!   - the kill event (latched: once set, nothing acts again);
//!   - the workstation is not locked and the input desktop is "Default";
//!   - before every keystroke: the focused element is still the one the act
//!     started on (runtime id, password flag, role), else "focus moved";
//!     before a click: the window and (for invoke-by-click) the element
//!     under the point are unchanged;
//!   - the window's process and image path pass the allowlist and the
//!     integrity check NOW (re-read, not cached from observe), and so does
//!     the element's own process;
//!   - password fields and payment-like buttons (unless --allow-payments) are
//!     refused; typed text has no control characters (Enter goes through
//!     desktop_key) and at most 4096 characters;
//!   - desktop_type/desktop_key/desktop_click need the window to be the
//!     foreground window; keys are a fixed chord allowlist, re-checked
//!     against the strict chord blocklist over the keys held at send time
//!     (shared with zmcp-computer: computer/keys.zig, guard.zig);
//!   - real (non-injected) user input: an act waits until the user has been
//!     idle for --idle-ms, and user input during an act stops it and pauses
//!     the session until the host signals --resume-event (Nava's Continue
//!     button; no tool can resume);
//!   - step and time limits (--max-steps, --step-timeout-ms, --session-timeout-s).

const std = @import("std");
const builtin = @import("builtin");
const mcp = @import("mcp");
const shared = @import("computer_shared");
const w = shared.win32;
const integrity = shared.integrity;
const uia_mod = @import("uia.zig");
const policy = @import("policy.zig");
const safety = @import("safety.zig");
const uia_com = @import("uia_com.zig");
const keys = shared.keys;
const input = shared.input;
const guard = shared.guard;

const Uia = uia_mod.Uia;
const Node = policy.Node;
const Policy = policy.Policy;

pub const version = "0.3.0";

// ── Win32 not in computer/win32.zig ─────────────────────────────────────────

const GA_ROOT: u32 = 2;
const SYNCHRONIZE: u32 = 0x00100000;
const DESKTOP_READOBJECTS: u32 = 0x0001;
const UOI_NAME: i32 = 2;
const WAIT_OBJECT_0: u32 = 0;

extern "user32" fn GetAncestor(hwnd: w.HWND, flags: u32) callconv(.winapi) ?w.HWND;
extern "user32" fn OpenInputDesktop(flags: u32, inherit: w.BOOL, access: u32) callconv(.winapi) ?w.HANDLE;
extern "user32" fn CloseDesktop(h: w.HANDLE) callconv(.winapi) w.BOOL;
extern "user32" fn GetUserObjectInformationW(h: w.HANDLE, index: i32, info: ?*anyopaque, len: u32, needed: ?*u32) callconv(.winapi) w.BOOL;
extern "user32" fn FindWindowExW(parent: ?w.HWND, after: ?w.HWND, class: ?[*:0]const u16, title: ?[*:0]const u16) callconv(.winapi) ?w.HWND;
extern "kernel32" fn GetLongPathNameW(short: [*:0]const u16, long: [*]u16, n: u32) callconv(.winapi) u32;
extern "user32" fn CharLowerBuffW(s: [*]u16, n: u32) callconv(.winapi) u32;
extern "kernel32" fn GetSystemDirectoryW(buf: [*]u16, n: u32) callconv(.winapi) u32;
extern "kernel32" fn OpenEventW(access: u32, inherit: w.BOOL, name: [*:0]const u16) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn WaitForSingleObject(h: w.HANDLE, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) w.HANDLE;
extern "kernel32" fn QueryPerformanceCounter(out: *i64) callconv(.winapi) w.BOOL;
extern "kernel32" fn QueryPerformanceFrequency(out: *i64) callconv(.winapi) w.BOOL;
extern "ntdll" fn NtQueryInformationProcess(h: w.HANDLE, class: u32, info: *anyopaque, len: u32, ret: ?*u32) callconv(.winapi) i32;

const PROCESS_BASIC_INFORMATION = extern struct {
    exit_status: isize,
    peb: ?*anyopaque,
    affinity: usize,
    base_priority: isize,
    pid: usize,
    ppid: usize,
};

// ── process state ───────────────────────────────────────────────────────────

var g_policy: ?Policy = null;
var g_kill_name: ?[:0]u16 = null;
var g_uia: ?Uia = null;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    var it = try init.minimal.args.iterateAllocator(gpa);
    defer it.deinit();
    _ = it.skip();
    while (it.next()) |a| try args.append(gpa, a);

    g_policy = try policyFromArgs(gpa, args.items);
    defer if (g_policy) |p| p.deinit();
    for (args.items) |a| if (std.mem.eql(u8, a, "--debug-input")) {
        safety.debug = true;
    };

    // `--bench HWND [RUNS]`: time each walk strategy on one allowlisted
    // window (stderr). The only way to reach `.levels`/`.subtree` outside tests.
    for (args.items, 0..) |a, i| if (std.mem.eql(u8, a, "--bench") and i + 1 < args.items.len) {
        const h = std.fmt.parseInt(usize, args.items[i + 1], 0) catch return error.BadHwnd;
        const runs = if (i + 2 < args.items.len) std.fmt.parseInt(usize, args.items[i + 2], 10) catch 30 else 30;
        return bench(gpa, h, runs);
    };

    var buf: [96]u8 = undefined;
    const kill_utf8 = g_policy.?.kill_event orelse try policy.defaultKillEventName(&buf, parentPid());
    // Never freed (page_allocator, so no leak report): the kill watcher
    // thread reads it for the life of the process.
    g_kill_name = try w.toW(std.heap.page_allocator, kill_utf8);
    safety.startKillWatcher(g_kill_name.?);
    if (g_policy.?.resume_event) |r| g_resume_name = try w.toW(std.heap.page_allocator, r);

    // UIA (and COM) start on the first tool call, so an idle session costs nothing.
    defer if (g_uia) |u| u.deinit();
    try mcp.run(gpa, init.io, .{ .name = "zmcp-desktop", .version = version }, &tool_table);
}

fn bench(gpa: std.mem.Allocator, h: usize, runs: usize) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const win = switch (try gate(a, g_policy.?, @ptrFromInt(h))) {
        .ok => |x| x,
        .refused => |m| {
            std.debug.print("{s}\n", .{m});
            return error.Refused;
        },
    };
    const u = try Uia.init();
    defer u.deinit();
    const times = try gpa.alloc(f64, runs);
    defer gpa.free(times);
    for ([_]uia_mod.Strategy{ .walker, .levels, .subtree }) |strategy| {
        var count: usize = 0;
        var trunc: ?uia_mod.TruncatedBy = null;
        for (0..runs + 3) |i| {
            _ = arena.reset(.retain_capacity);
            const t0 = nowTicks();
            const obs = try u.observe(arena.allocator(), @ptrFromInt(win.hwnd), null, .{ .max_depth = 32, .max_nodes = 500, .strategy = strategy });
            const ms = msSince(t0);
            if (i >= 3) times[i - 3] = ms;
            count = obs.nodes.len;
            trunc = obs.truncated_by;
        }
        std.mem.sort(f64, times, {}, std.sort.asc(f64));
        std.debug.print("{{\"strategy\":\"{s}\",\"runs\":{d},\"nodes\":{d},\"truncated_by\":\"{s}\",\"p50_ms\":{d:.2},\"p95_ms\":{d:.2}}}\n", .{
            @tagName(strategy), runs, count, if (trunc) |t| @tagName(t) else "none", pctl(times, 50), pctl(times, 95),
        });
    }
}

fn pctl(sorted: []const f64, p: usize) f64 {
    var rank = (p * sorted.len + 99) / 100;
    if (rank == 0) rank = 1;
    return sorted[rank - 1];
}

/// Win32 canonical form of a path for comparison: the long name
/// (GetLongPathNameW, so an 8.3 alias can't differ from the allowlist entry),
/// lower-cased with Unicode awareness (CharLowerBuffW). A path that does not
/// exist keeps its spelling and is still lower-cased.
fn canonicalPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const wide = try w.toW(allocator, path);
    defer allocator.free(wide);
    var buf: [1024]u16 = undefined;
    var src: []u16 = undefined;
    const n = GetLongPathNameW(wide.ptr, &buf, buf.len);
    if (n > 0 and n < buf.len) {
        src = buf[0..n];
    } else {
        if (wide.len > buf.len) return error.PathTooLong;
        @memcpy(buf[0..wide.len], wide);
        src = buf[0..wide.len];
    }
    _ = CharLowerBuffW(src.ptr, @intCast(src.len));
    return policy.utf16ToUtf8Capped(allocator, src, 1024);
}

fn canonicalFromW(allocator: std.mem.Allocator, wide: []const u16) ![]u8 {
    const utf8 = try policy.utf16ToUtf8Capped(allocator, wide, 1024);
    defer allocator.free(utf8);
    return canonicalPath(allocator, utf8);
}

/// Policy.fromArgs with every `--allow` path canonicalized first.
fn policyFromArgs(allocator: std.mem.Allocator, args: []const []const u8) !Policy {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try a.alloc([]const u8, args.len);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        out[i] = args[i];
        if (std.mem.eql(u8, args[i], "--allow") and i + 1 < args.len) {
            var parts: std.ArrayList(u8) = .empty;
            var it = std.mem.splitScalar(u8, args[i + 1], '|');
            var first = true;
            while (it.next()) |raw| {
                const t = std.mem.trim(u8, raw, " \t\"'");
                if (!first) try parts.append(a, '|');
                first = false;
                try parts.appendSlice(a, try canonicalPath(a, t));
            }
            i += 1;
            out[i] = parts.items;
        }
    }
    return Policy.fromArgs(allocator, out);
}

fn parentPid() u32 {
    var pbi = std.mem.zeroes(PROCESS_BASIC_INFORMATION);
    if (NtQueryInformationProcess(GetCurrentProcess(), 0, &pbi, @sizeOf(PROCESS_BASIC_INFORMATION), null) < 0) return 0;
    return @truncate(pbi.ppid);
}

fn uia() !Uia {
    if (g_uia == null) g_uia = try Uia.init();
    return g_uia.?;
}

fn killSet(name: [*:0]const u16) bool {
    const h = OpenEventW(SYNCHRONIZE, 0, name) orelse return false;
    defer _ = w.CloseHandle(h);
    return WaitForSingleObject(h, 0) == WAIT_OBJECT_0;
}

fn stopped() bool {
    return safety.killed(if (g_kill_name) |k| k.ptr else null);
}

/// True when the input desktop is the normal "Default" desktop (not the
/// secure desktop of UAC or the logon screen). Fails closed.
fn onDefaultDesktop() bool {
    const d = OpenInputDesktop(0, 0, DESKTOP_READOBJECTS) orelse return false;
    defer _ = CloseDesktop(d);
    var name: [64]u16 = undefined;
    var needed: u32 = 0;
    if (!w.ok(GetUserObjectInformationW(d, UOI_NAME, &name, @sizeOf(@TypeOf(name)), &needed))) return false;
    const n = std.mem.indexOfScalar(u16, &name, 0) orelse return false;
    return std.mem.eql(u16, name[0..n], std.unicode.utf8ToUtf16LeStringLiteral("Default"));
}

/// Full image path of `pid` (Win32 form, as QueryFullProcessImageNameW
/// reports it), or "" when it can't be read.
fn imagePath(allocator: std.mem.Allocator, pid: u32) ![]u8 {
    if (pid == 0) return allocator.alloc(u8, 0);
    const h = w.OpenProcess(w.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return allocator.alloc(u8, 0);
    defer _ = w.CloseHandle(h);
    var buf: [1024]u16 = undefined;
    var len: u32 = buf.len;
    if (!w.ok(w.QueryFullProcessImageNameW(h, 0, &buf, &len))) return allocator.alloc(u8, 0);
    return canonicalFromW(allocator, buf[0..len]);
}

fn windowTitle(allocator: std.mem.Allocator, hwnd: w.HWND) ![]u8 {
    var buf: [512]u16 = undefined;
    const got = w.GetWindowTextW(hwnd, &buf, buf.len);
    if (got <= 0) return allocator.alloc(u8, 0);
    return policy.utf16ToUtf8Capped(allocator, buf[0..@intCast(got)], policy.max_text_chars);
}

/// `%SystemRoot%\System32\ApplicationFrameHost.exe`.
fn systemFrameHostPath(allocator: std.mem.Allocator) ![]u8 {
    var buf: [260]u16 = undefined;
    const n = GetSystemDirectoryW(&buf, buf.len);
    if (n == 0 or n >= buf.len) return allocator.alloc(u8, 0);
    const dir = try canonicalFromW(allocator, buf[0..n]);
    return std.fmt.allocPrint(allocator, "{s}\\ApplicationFrameHost.exe", .{dir});
}

fn samePath(a: []const u8, b: []const u8) bool {
    var ba: [1024]u8 = undefined;
    var bb: [1024]u8 = undefined;
    const na = policy.normalizePathBuf(&ba, a) orelse return false;
    const nb = policy.normalizePathBuf(&bb, b) orelse return false;
    return std.mem.eql(u8, na, nb);
}

// ── the gate ────────────────────────────────────────────────────────────────

const Target = struct {
    /// The process the window is gated on.
    pid: u32,
    path: []const u8,
    /// The UWP frame host's pid when the window is a UWP frame, else 0.
    frame_pid: u32 = 0,
};

const Resolved = union(enum) {
    ok: Target,
    refused: []const u8,
};

/// Which process decides for a top-level window: its own, or, for a genuine
/// UWP frame (System32\ApplicationFrameHost.exe), the process of the hosted
/// Windows.UI.Core.CoreWindow. The frame host itself is never allowlisted.
fn resolveTarget(allocator: std.mem.Allocator, hwnd: w.HWND) !Resolved {
    var pid: u32 = 0;
    _ = w.GetWindowThreadProcessId(hwnd, &pid);
    const path = try imagePath(allocator, pid);
    if (path.len == 0) return .{ .refused = "refused: the window's process can't be identified (elevated or protected)" };
    if (!std.ascii.eqlIgnoreCase(policy.baseName(path), policy.frame_host)) return .{ .ok = .{ .pid = pid, .path = path } };

    if (!samePath(path, try systemFrameHostPath(allocator))) return .{ .refused = "refused: ApplicationFrameHost.exe outside System32" };
    const core = FindWindowExW(hwnd, null, std.unicode.utf8ToUtf16LeStringLiteral("Windows.UI.Core.CoreWindow"), null) orelse
        return .{ .refused = "refused: this UWP frame hosts no app window (suspended or minimized)" };
    var app_pid: u32 = 0;
    _ = w.GetWindowThreadProcessId(core, &app_pid);
    if (app_pid == 0 or app_pid == pid) return .{ .refused = "refused: the hosted UWP app can't be identified" };
    const app_path = try imagePath(allocator, app_pid);
    if (app_path.len == 0) return .{ .refused = "refused: the hosted UWP app can't be identified (elevated or protected)" };
    return .{ .ok = .{ .pid = app_pid, .path = app_path, .frame_pid = pid } };
}

const Gate = union(enum) {
    ok: policy.Window,
    refused: []const u8,
};

/// Every hwnd-taking call goes through here, after the kill check.
fn gate(allocator: std.mem.Allocator, p: Policy, hwnd_in: w.HWND) !Gate {
    if (p.isEmpty()) return .{ .refused = "refused: the allowlist is empty" };
    if (!w.ok(w.IsWindow(hwnd_in))) return .{ .refused = "no such window" };
    const hwnd = GetAncestor(hwnd_in, GA_ROOT) orelse hwnd_in;
    if (!onDefaultDesktop()) return .{ .refused = "refused: the secure desktop (UAC or logon) is active" };
    const target = switch (try resolveTarget(allocator, hwnd)) {
        .ok => |x| x,
        .refused => |msg| return .{ .refused = msg },
    };
    const exe = policy.baseName(target.path);
    if (policy.isAlwaysRefused(exe)) return .{ .refused = "refused: system credential/consent UI" };
    if (!p.allows(target.path)) return .{ .refused = try std.fmt.allocPrint(allocator, "refused: {s} is not in the allowlist", .{target.path}) };
    integrity.checkPid(target.pid) catch return .{ .refused = "refused: the window belongs to an elevated process" };
    if (target.frame_pid != 0) integrity.checkPid(target.frame_pid) catch return .{ .refused = "refused: the window belongs to an elevated process" };
    return .{ .ok = .{
        .hwnd = @intFromPtr(hwnd),
        .exe = exe,
        .path = target.path,
        .title = try windowTitle(allocator, hwnd),
        .pid = target.pid,
        .frame_pid = target.frame_pid,
    } };
}

/// pid → allowed, cached for one call. Nodes of other processes (an embedded
/// window of a non-allowlisted app) are dropped with their subtree. A node
/// with no process id is accepted only as the root.
const PidFilter = struct {
    allocator: std.mem.Allocator,
    p: Policy,
    window_pid: u32,
    frame_pid: u32 = 0,
    seen: std.AutoHashMapUnmanaged(u32, bool) = .empty,

    fn forWindow(allocator: std.mem.Allocator, p: Policy, win: policy.Window) PidFilter {
        return .{ .allocator = allocator, .p = p, .window_pid = win.pid, .frame_pid = win.frame_pid };
    }

    fn allowed(self: *PidFilter, pid_i: i32, is_root: bool) !bool {
        const pid: u32 = @bitCast(pid_i);
        if (pid == 0) return is_root;
        if (pid == self.window_pid) return true;
        if (self.frame_pid != 0 and pid == self.frame_pid) return true;
        if (self.seen.get(pid)) |v| return v;
        const path = try imagePath(self.allocator, pid);
        var ok = path.len > 0 and self.p.allows(path);
        if (ok) integrity.checkPid(pid) catch {
            ok = false;
        };
        try self.seen.put(self.allocator, pid, ok);
        return ok;
    }
};

// ── helpers ─────────────────────────────────────────────────────────────────

fn nowTicks() i64 {
    var t: i64 = 0;
    _ = QueryPerformanceCounter(&t);
    return t;
}

fn msSince(t0: i64) f64 {
    var f: i64 = 1;
    _ = QueryPerformanceFrequency(&f);
    return @as(f64, @floatFromInt(nowTicks() - t0)) * 1000.0 / @as(f64, @floatFromInt(f));
}

fn errText(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !mcp.ToolResult {
    return .{ .text = try std.fmt.allocPrint(allocator, fmt, args), .is_error = true };
}

fn intArg(args: std.json.Value, key: []const u8, default: i64, lo: i64, hi: i64) i64 {
    if (args != .object) return default;
    const v = args.object.get(key) orelse return default;
    return switch (v) {
        .integer => |i| std.math.clamp(i, lo, hi),
        .float => |f| if (std.math.isFinite(f)) std.math.clamp(@as(i64, @intFromFloat(std.math.clamp(f, -1e15, 1e15))), lo, hi) else default,
        else => default,
    };
}

fn strArg(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// hwnd as a JSON integer, or a decimal / 0x-hex string.
pub fn parseHwnd(args: std.json.Value) ?usize {
    if (args != .object) return null;
    const v = args.object.get("hwnd") orelse return null;
    const n: usize = switch (v) {
        .integer => |i| if (i > 0) @intCast(i) else return null,
        .string => |s| blk: {
            const t = std.mem.trim(u8, s, " ");
            if (t.len > 2 and t[0] == '0' and (t[1] == 'x' or t[1] == 'X'))
                break :blk std.fmt.parseInt(usize, t[2..], 16) catch return null;
            break :blk std.fmt.parseInt(usize, t, 10) catch return null;
        },
        else => return null,
    };
    return if (n == 0) null else n;
}

/// Common prologue: kill check, policy, hwnd, gate. On refusal returns the
/// error result through `out`.
fn prologue(allocator: std.mem.Allocator, args: std.json.Value, out: *mcp.ToolResult) !?policy.Window {
    if (stopped()) {
        out.* = .{ .text = "stopped by the user", .is_error = true };
        return null;
    }
    const p = g_policy orelse {
        out.* = .{ .text = "refused: no allowlist", .is_error = true };
        return null;
    };
    const h = parseHwnd(args) orelse {
        out.* = .{ .text = "hwnd is required (an integer from desktop_list_windows)", .is_error = true };
        return null;
    };
    switch (try gate(allocator, p, @ptrFromInt(h))) {
        .ok => |win| return win,
        .refused => |msg| {
            out.* = .{ .text = msg, .is_error = true };
            return null;
        },
    }
}

/// RawNodes → policy.Nodes (ids encoded, rect as x,y,w,h), dropping any
/// subtree rooted at a node of a non-allowlisted process.
fn toNodes(allocator: std.mem.Allocator, raw: []const uia_mod.RawNode, filter: *PidFilter) ![]Node {
    const ids = try allocator.alloc(?[]const u8, raw.len);
    var out: std.ArrayList(Node) = .empty;
    for (raw, 0..) |r, i| {
        ids[i] = null;
        if (r.parent >= 0 and ids[@intCast(r.parent)] == null) continue; // parent dropped
        if (!try filter.allowed(r.pid, r.parent < 0)) continue;
        const id = try policy.encodeRuntimeId(allocator, r.rid);
        ids[i] = id;
        try out.append(allocator, .{
            .id = id,
            .parent = if (r.parent >= 0) ids[@intCast(r.parent)] else null,
            .role = policy.roleName(r.control_type),
            .name = r.name,
            .value = if (r.is_password) null else r.value,
            .rect = .{ r.rect.left, r.rect.top, r.rect.right - r.rect.left, r.rect.bottom - r.rect.top },
            .enabled = r.enabled,
            .focusable = r.focusable,
            .is_password = r.is_password,
            .automation_id = r.automation_id,
            .class_name = r.class_name,
            .value_pattern = r.has_value,
            .text = if (r.is_password) null else r.text,
            .text_pattern = r.has_text,
            .text_truncated = r.text_truncated,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn truncatedBy(t: ?uia_mod.TruncatedBy) std.json.Value {
    const v = t orelse return .null;
    return .{ .string = @tagName(v) };
}


// ── tools ───────────────────────────────────────────────────────────────────

const EnumCtx = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(w.HWND) = .empty,
    failed: bool = false,
};

fn enumProc(hwnd: w.HWND, lparam: w.LPARAM) callconv(.winapi) w.BOOL {
    const ctx: *EnumCtx = @ptrFromInt(@as(usize, @bitCast(lparam)));
    ctx.list.append(ctx.allocator, hwnd) catch {
        ctx.failed = true;
        return 0;
    };
    return 1;
}

fn isCloaked(hwnd: w.HWND) bool {
    var cloaked: u32 = 0;
    return w.DwmGetWindowAttribute(hwnd, w.DWMWA_CLOAKED, &cloaked, @sizeOf(u32)) == 0 and cloaked != 0;
}

fn handleListWindows(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    _ = io;
    _ = args;
    if (stopped()) return .{ .text = "stopped by the user", .is_error = true };
    const p = g_policy orelse return .{ .text = "refused: no allowlist", .is_error = true };
    // Nothing can match: refuse before opening any process.
    if (p.isEmpty()) return .{ .text = "refused: the allowlist is empty", .is_error = true };
    if (!onDefaultDesktop()) return .{ .text = "refused: the secure desktop (UAC or logon) is active", .is_error = true };
    var ctx: EnumCtx = .{ .allocator = allocator };
    _ = w.EnumWindows(enumProc, @bitCast(@intFromPtr(&ctx)));
    if (ctx.failed) return error.OutOfMemory;

    var sw: std.Io.Writer.Allocating = .init(allocator);
    var js = std.json.Stringify{ .writer = &sw.writer };
    try js.beginObject();
    try js.objectField("windows");
    try js.beginArray();
    for (ctx.list.items) |h| {
        if (!w.ok(w.IsWindowVisible(h)) or isCloaked(h)) continue;
        // The process decides first; a non-allowlisted window's title is never read.
        const target = switch (try resolveTarget(allocator, h)) {
            .ok => |x| x,
            .refused => continue,
        };
        if (!p.allows(target.path)) continue;
        integrity.checkPid(target.pid) catch continue;
        if (target.frame_pid != 0) integrity.checkPid(target.frame_pid) catch continue;
        const exe = policy.baseName(target.path);
        const pid = target.pid;
        const title = try windowTitle(allocator, h);
        if (title.len == 0) continue;
        try js.beginObject();
        try js.objectField("hwnd");
        try js.write(@intFromPtr(h));
        try js.objectField("exe");
        try js.write(exe);
        try js.objectField("path");
        try js.write(target.path);
        try js.objectField("title");
        try js.write(title);
        try js.objectField("pid");
        try js.write(pid);
        try js.endObject();
    }
    try js.endArray();
    try js.endObject();
    return .{ .text = try sw.toOwnedSlice() };
}

fn handleObserve(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    _ = io;
    var refused: mcp.ToolResult = undefined;
    const win = (try prologue(allocator, args, &refused)) orelse return refused;
    const opts: uia_mod.ObserveOptions = .{
        .max_depth = @intCast(intArg(args, "max_depth", 8, 0, 32)),
        .max_nodes = @intCast(intArg(args, "max_nodes", 400, 1, 2000)),
    };
    const rid: ?[]i32 = if (strArg(args, "root")) |s|
        policy.decodeRuntimeId(allocator, s) catch return .{ .text = "root: not an element id", .is_error = true }
    else
        null;
    const u = uia() catch |e| return errText(allocator, "UI Automation unavailable: {s}", .{@errorName(e)});
    const t0 = nowTicks();
    const obs = u.observe(allocator, @ptrFromInt(win.hwnd), rid, opts) catch |e|
        return errText(allocator, "observe failed: {s}", .{@errorName(e)});
    const ms = msSince(t0);
    var filter = PidFilter.forWindow(allocator, g_policy.?, win);
    const nodes = try toNodes(allocator, obs.nodes, &filter);
    const extra = [_]policy.Extra{
        .{ .key = "ms", .value = .{ .float = @round(ms * 100) / 100 } },
        .{ .key = "dropped", .value = .{ .integer = @intCast(obs.nodes.len - nodes.len) } },
        .{ .key = "truncated_by", .value = truncatedBy(obs.truncated_by) },
        .{ .key = "strategy", .value = .{ .string = @tagName(opts.strategy) } },
    };
    return .{ .text = try policy.writeNodes(allocator, win, nodes, obs.truncated, &extra, policy.max_output_bytes) };
}

fn handleFind(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    _ = io;
    var refused: mcp.ToolResult = undefined;
    const win = (try prologue(allocator, args, &refused)) orelse return refused;
    const role = strArg(args, "role");
    const role_id: ?i32 = if (role) |r| (policy.roleId(r) orelse return errText(allocator, "role: unknown role '{s}'", .{r})) else null;
    const needle = strArg(args, "name_contains") orelse "";
    const limit: usize = @intCast(intArg(args, "limit", 20, 1, 200));
    const u = uia() catch |e| return errText(allocator, "UI Automation unavailable: {s}", .{@errorName(e)});
    const t0 = nowTicks();
    // Values are not needed to match; the matches' values are read below.
    const obs = u.observe(allocator, @ptrFromInt(win.hwnd), null, .{ .max_depth = 32, .max_nodes = 3000, .values = false }) catch |e|
        return errText(allocator, "find failed: {s}", .{@errorName(e)});
    var filter = PidFilter.forWindow(allocator, g_policy.?, win);
    const all = try toNodes(allocator, obs.nodes, &filter);
    var hits: std.ArrayList(Node) = .empty;
    var more = false;
    for (all) |n| {
        if (role_id) |rid| if (!std.mem.eql(u8, n.role, policy.roleName(rid))) continue;
        if (!policy.containsIgnoreCase(n.name, needle)) continue;
        if (hits.items.len >= limit) {
            more = true;
            break;
        }
        try hits.append(allocator, n);
    }
    const ms = msSince(t0);
    const extra = [_]policy.Extra{
        .{ .key = "ms", .value = .{ .float = @round(ms * 100) / 100 } },
        .{ .key = "searched", .value = .{ .integer = @intCast(all.len) } },
        .{ .key = "truncated_by", .value = truncatedBy(obs.truncated_by) },
    };
    return .{ .text = try policy.writeNodes(allocator, win, hits.items, obs.truncated or more, &extra, policy.max_output_bytes) };
}

fn handleFocused(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    _ = io;
    var refused: mcp.ToolResult = undefined;
    const win = (try prologue(allocator, args, &refused)) orelse return refused;
    const is_fg = policy.isForeground(win.hwnd, foregroundRoot());
    var nodes: []Node = &.{};
    if (is_fg) {
        const u = uia() catch |e| return errText(allocator, "UI Automation unavailable: {s}", .{@errorName(e)});
        // Tests resolve g_test_focus_rid in the window instead of the real focus.
        const focused = if (builtin.is_test)
            (if (g_test_focus_rid) |rid| u.resolve(@ptrFromInt(win.hwnd), rid, u.req_el) else error.NoFocusedElement)
        else
            u.focusedCached();
        if (focused) |el| {
            defer el.release();
            var raw = try el.cachedNode(allocator, -1, 0);
            var filter = PidFilter.forWindow(allocator, g_policy.?, win);
            if (try filter.allowed(raw.pid, true)) {
                if (!raw.is_password and raw.has_value and policy.roleHasUsefulValue(raw.control_type))
                    raw.value = el.currentValue(allocator) catch null;
                // A contenteditable composer: its TextPattern text (never a password field's).
                el.fillText(allocator, &raw);
                nodes = try toNodes(allocator, &.{raw}, &filter);
            }
        } else |_| {}
    }
    const extra = [_]policy.Extra{.{ .key = "foreground", .value = .{ .bool = is_fg } }};
    return .{ .text = try policy.writeNodes(allocator, win, nodes, false, &extra, policy.max_output_bytes) };
}

// ── act (Z3) ────────────────────────────────────────────────────────────────

var g_session: policy.Session = .{};
/// --resume-event, as UTF-16.
var g_resume_name: ?[:0]const u16 = null;

/// Lift an auto-pause when the host signalled the resume event.
fn resumeIfSignalled() void {
    if (!g_session.paused) return;
    const n = g_resume_name orelse return;
    if (safety.consumeEvent(n.ptr)) g_session.paused = false;
}

/// On a new pause: drop a Continue signalled earlier, so only a Continue
/// pressed after this pause resumes.
fn dropStaleResume() void {
    if (!g_session.paused) return;
    const n = g_resume_name orelse return;
    _ = safety.consumeEvent(n.ptr);
}

/// Test seam: called after each group of INPUTs in a test binary.
var g_test_after_send: ?*const fn () void = null;
/// Strict chords, never allow_blocked. Tracks keys held across sends (none
/// are left held: every chord is pressed and released within one call).
var g_keys: guard.KeyGuard = .{ .chords = .strict };

/// Test seams: tests never make a real window the foreground window and
/// never move the real keyboard focus.
var g_test_foreground: ?usize = null;
var g_test_focus_rid: ?[]const i32 = null;
/// INPUT events that reached input.send in a test binary (where send refuses).
var g_test_sent: usize = 0;

fn foregroundRoot() ?usize {
    if (builtin.is_test) return g_test_foreground;
    const fg = w.GetForegroundWindow() orelse return null;
    return @intFromPtr(GetAncestor(fg, GA_ROOT) orelse fg);
}

fn limits() policy.Limits {
    return if (g_policy) |p| p.limits else .{};
}

fn allowPayments() bool {
    return if (g_policy) |p| p.allow_payments else false;
}

/// Kill, lock and secure desktop. Checked first and again right before
/// every side effect.
fn envRefusal() ?[]const u8 {
    if (stopped()) return "stopped by the user";
    if (safety.sessionLocked()) return "refused: the workstation is locked";
    if (!onDefaultDesktop()) return "refused: the secure desktop (UAC or logon) is active";
    return null;
}

const Act = struct {
    win: policy.Window,
    start_ms: u64,
};

fn refuse(msg: []const u8) mcp.ToolResult {
    return .{ .text = msg, .is_error = true };
}

/// Start of every act: environment, gate, input hooks, limits (counts a step).
fn actBegin(allocator: std.mem.Allocator, args: std.json.Value, out: *mcp.ToolResult) !?Act {
    if (envRefusal()) |m| {
        out.* = refuse(m);
        return null;
    }
    const win = (try prologue(allocator, args, out)) orelse return null;
    safety.ensureInputWatch();
    resumeIfSignalled();
    const now = safety.nowMs();
    if (g_session.admit(limits(), now, safety.lastRealInputMs())) |m| {
        out.* = refuse(m);
        return null;
    }
    return .{ .win = win, .start_ms = now };
}

/// Right before a side effect: everything again, re-read from the system.
/// The window must still belong to the same allowlisted process, and the
/// element's process (when it is not the window's) must pass the allowlist
/// and the integrity check with a fresh image-path read.
fn recheck(allocator: std.mem.Allocator, act: Act, element_pid: i32, budget_ms: u64) !?[]const u8 {
    if (envRefusal()) |m| return m;
    if (g_session.during(act.start_ms, safety.nowMs(), safety.lastRealInputMs(), budget_ms)) |m| {
        dropStaleResume();
        return m;
    }
    const p = g_policy orelse return "refused: no allowlist";
    switch (try gate(allocator, p, @ptrFromInt(act.win.hwnd))) {
        .ok => |now| if (now.pid != act.win.pid or !std.mem.eql(u8, now.path, act.win.path))
            return "refused: the window changed hands since the call began",
        .refused => |m| return m,
    }
    var fresh = PidFilter.forWindow(allocator, p, act.win);
    if (!try fresh.allowed(element_pid, false)) return "refused: the element belongs to a process that is not allowlisted";
    return null;
}

const ElTarget = struct {
    el: uia_mod.Element,
    node: uia_mod.RawNode,
};

/// Resolve an element id inside the window; its process must pass the filter.
fn resolveElement(allocator: std.mem.Allocator, u: Uia, act: Act, id: []const u8, out: *mcp.ToolResult) !?ElTarget {
    const rid = policy.decodeRuntimeId(allocator, id) catch {
        out.* = refuse("id: not an element id (r<hex>-...)");
        return null;
    };
    const el = u.resolve(@ptrFromInt(act.win.hwnd), rid, u.req_el) catch {
        out.* = refuse("no such element in this window (observe again)");
        return null;
    };
    errdefer el.release();
    const node = try el.cachedNode(allocator, -1, 0);
    var filter = PidFilter.forWindow(allocator, g_policy.?, act.win);
    if (!try filter.allowed(node.pid, false)) {
        el.release();
        out.* = refuse("refused: the element belongs to a process that is not allowlisted");
        return null;
    }
    return .{ .el = el, .node = node };
}

/// Refusals that depend on the element itself.
fn elementRefusal(el: uia_mod.Element, node: uia_mod.RawNode) ?[]const u8 {
    if (node.is_password or el.currentIsPassword()) return "refused: password field";
    if (policy.refusesPayment(policy.roleName(node.control_type), node.name, allowPayments()))
        return "refused: this looks like a payment control (T3); zmcp-desktop never presses it";
    return null;
}

/// The focused element, when the window is the foreground window and the
/// element's process passes the filter. Tests resolve `g_test_focus_rid`
/// in the window instead of reading the real focus.
fn focusedTarget(allocator: std.mem.Allocator, u: Uia, act: Act) !?ElTarget {
    const el = if (builtin.is_test) blk: {
        const rid = g_test_focus_rid orelse return null;
        break :blk u.resolve(@ptrFromInt(act.win.hwnd), rid, u.req_el) catch return null;
    } else u.focusedCached() catch return null;
    errdefer el.release();
    const node = try el.cachedNode(allocator, -1, 0);
    var filter = PidFilter.forWindow(allocator, g_policy.?, act.win);
    if (!try filter.allowed(node.pid, false)) {
        el.release();
        return null;
    }
    return .{ .el = el, .node = node };
}

/// `{ok:true, action, after:{focused_id, window_title}}`.
fn actReply(allocator: std.mem.Allocator, u: ?Uia, act: Act, action: []const u8) !mcp.ToolResult {
    var focused_id: ?[]const u8 = null;
    if (u) |uu| {
        if (try focusedTarget(allocator, uu, act)) |f| {
            defer f.el.release();
            if (f.node.rid.len > 0) focused_id = try policy.encodeRuntimeId(allocator, f.node.rid);
        }
    }
    var sw: std.Io.Writer.Allocating = .init(allocator);
    var js = std.json.Stringify{ .writer = &sw.writer };
    try js.beginObject();
    try js.objectField("ok");
    try js.write(true);
    try js.objectField("action");
    try js.write(action);
    try js.objectField("after");
    try js.beginObject();
    try js.objectField("focused_id");
    try js.write(focused_id);
    try js.objectField("window_title");
    try js.write(policy.capUtf8(try windowTitle(allocator, @ptrFromInt(act.win.hwnd)), policy.max_text_chars));
    try js.endObject();
    try js.endObject();
    return .{ .text = try sw.toOwnedSlice() };
}

fn patternFailure(allocator: std.mem.Allocator, e: anyerror) !mcp.ToolResult {
    return switch (e) {
        error.NoPattern => refuse("this element does not support that action"),
        error.ReadOnly => refuse("refused: the value is read-only"),
        error.PatternCallFailed, error.SetFocusFailed => refuse("the app did not confirm the action (it may be busy or showing a dialog); observe to check"),
        else => errText(allocator, "act failed: {s}", .{@errorName(e)}),
    };
}

/// During a long send, the full recheck (gate: image path, integrity, input
/// desktop, lock) runs at most this often; the cheap checks (kill latch,
/// user input, time budget, foreground) run before every group.
const full_recheck_ms: u64 = 250;

const Pacing = enum {
    /// Typed text: one keystroke (UTF-16 unit) per SendInput; after each,
    /// wait until the target's UI thread has drained its queue, then pause
    /// policy.type_pace_ms.
    per_keystroke,
    /// A chord or a click: one SendInput.
    whole,
};

const WM_NULL: u32 = 0;
const SMTO_ABORTIFHUNG: u32 = 0x0002;
const target_sync_timeout_ms: u32 = 1000;
extern "user32" fn SendMessageTimeoutW(hwnd: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM, flags: u32, timeout: u32, result: ?*usize) callconv(.winapi) w.LPARAM;

/// Wait until the window's UI thread has taken the keystroke we just sent:
/// a sent WM_NULL is handled on the thread's next GetMessage, so two in a
/// row return only after it went back to its queue once more (by then it
/// has read and translated the queued keystroke). False when the app does
/// not answer within target_sync_timeout_ms.
fn syncTarget(hwnd: usize) bool {
    if (builtin.is_test) return true;
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        if (SendMessageTimeoutW(@ptrFromInt(hwnd), WM_NULL, 0, 0, SMTO_ABORTIFHUNG, target_sync_timeout_ms, null) == 0) return false;
    }
    return true;
}

/// What must still hold right before each group goes out.
const SendOpts = struct {
    /// Keyboard: the focused element the act started on.
    focus: ?FocusExpect = null,
    /// Mouse: the click point (window under it re-checked) ...
    point: ?w.POINT = null,
    /// ... and the element id expected under it (invoke-by-click).
    point_rid: ?[]const i32 = null,
};

const FocusExpect = struct {
    rid: []const i32,
    is_password: bool,
    control_type: i32,

    fn of(el: uia_mod.Element, node: uia_mod.RawNode) FocusExpect {
        return .{ .rid = node.rid, .is_password = node.is_password or el.currentIsPassword(), .control_type = node.control_type };
    }

    /// Pure: same element (runtime id), same password flag, same role.
    fn matches(self: FocusExpect, rid: []const i32, is_password: bool, control_type: i32) bool {
        return rid.len > 0 and std.mem.eql(i32, self.rid, rid) and self.is_password == is_password and self.control_type == control_type;
    }
};

/// Re-read the focused element; refuse if it is not the one we started on.
fn focusRefusal(allocator: std.mem.Allocator, act: Act, fe: FocusExpect) !?[]const u8 {
    const u = uia() catch return "stopped: UI Automation unavailable";
    const f = (try focusedTarget(allocator, u, act)) orelse return "stopped: focus moved (it left this app)";
    defer f.el.release();
    if (!fe.matches(f.node.rid, f.node.is_password or f.el.currentIsPassword(), f.node.control_type))
        return "stopped: focus moved to another element";
    return null;
}

/// Right before a click: the window under the point is still ours, and the
/// element there (when one was expected) is still the same element.
fn clickPointRefusal(allocator: std.mem.Allocator, act: Act, pt: w.POINT, rid: ?[]const i32) !?[]const u8 {
    if (pointRefusal(act, pt.x, pt.y)) |m| return m;
    const want = rid orelse return null;
    const u = uia() catch return "stopped: UI Automation unavailable";
    return pointElementRefusal(allocator, u, pt, want);
}

fn pointElementRefusal(allocator: std.mem.Allocator, u: Uia, pt: w.POINT, want: []const i32) !?[]const u8 {
    const el = u.elementFromPoint(pt.x, pt.y) catch return "stopped: nothing under the point any more";
    defer el.release();
    const node = try el.cachedNode(allocator, -1, 0);
    if (!std.mem.eql(i32, node.rid, want)) return "stopped: the element under the point changed";
    return null;
}

/// Send INPUTs, re-checking before each group that everything still holds.
/// Our injections carry NAVA_INPUT_TAG (set by the shared input module; the
/// hooks ignore only those) and are bracketed in time so GetLastInputInfo
/// can tell them apart before the hooks run.
fn sendPaced(allocator: std.mem.Allocator, act: Act, element_pid: i32, list: []w.INPUT, keyboard: bool, pacing: Pacing, opts: SendOpts) !?[]const u8 {
    const groups = if (pacing == .per_keystroke) policy.countGroups(list) else 1;
    const budget = policy.actBudgetMs(limits(), groups);
    var last_full: ?u64 = null;
    var i: usize = 0;
    while (i < list.len) {
        const now = safety.nowMs();
        if (last_full == null or now -| last_full.? >= full_recheck_ms) {
            if (try recheck(allocator, act, element_pid, budget)) |m| return m;
            last_full = now;
        } else {
            if (stopped()) return "stopped by the user";
            if (g_session.during(act.start_ms, now, safety.lastRealInputMs(), budget)) |m| {
                dropStaleResume();
                return m;
            }
        }
        if (!policy.isForeground(act.win.hwnd, foregroundRoot())) return "stopped: the window is no longer the foreground window";
        if (opts.focus) |fe| if (try focusRefusal(allocator, act, fe)) |m| return m;
        if (opts.point) |pt| if (try clickPointRefusal(allocator, act, pt, opts.point_rid)) |m| return m;
        const end = if (pacing == .per_keystroke) policy.keystrokeGroupEnd(list, i) else list.len;
        safety.ownInputBegin();
        const r = if (keyboard) g_keys.send(list[i..end]) else input.send(list[i..end]);
        safety.ownInputEnd();
        r catch |e| switch (e) {
            error.InjectionDisabled => g_test_sent += end - i, // test binaries never inject
            error.BlockedCombo => return "refused: that chord is blocked",
            error.TargetElevated => return "refused: the foreground window belongs to an elevated process",
            else => return "stopped: SendInput was blocked (locked or secure desktop?)",
        };
        if (builtin.is_test) if (g_test_after_send) |cb| cb();
        i = end;
        if (pacing == .per_keystroke) {
            if (!syncTarget(act.win.hwnd)) return "stopped: the app stopped answering while text was typed";
            if (i < list.len and !builtin.is_test) w.sleepMs(policy.type_pace_ms);
        }
    }
    return null;
}

/// A click at (x, y) needs: the window is the foreground window, the point
/// is inside its rect and on the virtual desktop, and the window under the
/// point is this window. Pure Win32 checks, before UIA looks at the point.
fn pointRefusal(act: Act, x: i32, y: i32) ?[]const u8 {
    if (!policy.isForeground(act.win.hwnd, foregroundRoot())) return "refused: the window is not the foreground window; use desktop_act focus first";
    var r: w.RECT = undefined;
    if (!w.ok(w.GetWindowRect(@ptrFromInt(act.win.hwnd), &r))) return "no such window";
    if (!policy.rectContains(.{ r.left, r.top, r.right - r.left, r.bottom - r.top }, x, y)) return "refused: the point is outside the window";
    if (!input.contains(guard.virtualScreen(), x, y)) return "refused: the point is outside the virtual desktop";
    const hit = WindowFromPoint(.{ .x = x, .y = y }) orelse return "refused: nothing under the point";
    const root = GetAncestor(hit, GA_ROOT) orelse hit;
    if (@intFromPtr(root) != act.win.hwnd) return "refused: another window covers the point";
    return null;
}

/// Left click at (x, y). The window under the point (and `rid`, the element
/// expected there) is checked inside sendPaced, right before SendInput.
fn clickAt(allocator: std.mem.Allocator, act: Act, element_pid: i32, x: i32, y: i32, rid: ?[]const i32) !?[]const u8 {
    var list = [_]w.INPUT{ input.mouseMove(x, y, guard.virtualScreen()), input.mouseButton(.left, false), input.mouseButton(.left, true) };
    return sendPaced(allocator, act, element_pid, &list, false, .whole, .{ .point = .{ .x = x, .y = y }, .point_rid = rid });
}

extern "user32" fn WindowFromPoint(pt: w.POINT) callconv(.winapi) ?w.HWND;

fn handleAct(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    _ = io;
    var out: mcp.ToolResult = undefined;
    const action_s = strArg(args, "action") orelse return refuse("action is required: invoke, focus, set_value, select, expand or scroll_into_view");
    const action = policy.parseAction(action_s) orelse return refuse("action: one of invoke, focus, set_value, select, expand, scroll_into_view");
    const id = strArg(args, "id") orelse return refuse("id is required (a node id from desktop_observe/desktop_find)");
    const value = strArg(args, "value");
    if (action == .set_value) {
        const v = value orelse return refuse("value is required for set_value");
        if (policy.textRefusal(v)) |m| return refuse(m);
    }
    const act = (try actBegin(allocator, args, &out)) orelse return out;
    const u = uia() catch |e| return errText(allocator, "UI Automation unavailable: {s}", .{@errorName(e)});
    const tg = (try resolveElement(allocator, u, act, id, &out)) orelse return out;
    defer tg.el.release();
    if (elementRefusal(tg.el, tg.node)) |m| return refuse(m);
    if (!tg.node.enabled and action != .scroll_into_view) return refuse("the element is disabled");

    if (try recheck(allocator, act, tg.node.pid, limits().step_timeout_ms)) |m| return refuse(m);
    safety.ownUiaBegin();
    defer safety.ownUiaEnd();
    const r: anyerror!void = switch (action) {
        .invoke => tg.el.invoke(),
        .focus => tg.el.setFocus(),
        .set_value => tg.el.setValue(value.?),
        .select => tg.el.select(),
        .expand => tg.el.expand(),
        .scroll_into_view => tg.el.scrollIntoView(),
    };
    r catch |e| {
        // No InvokePattern: a click at the element's clickable point (or the
        // centre of its rect), under the same checks as desktop_click.
        if (action == .invoke and e == error.NoPattern) {
            const pt = tg.el.clickablePoint() orelse uia_com.POINT{
                .x = tg.node.rect.left + @divTrunc(tg.node.rect.right - tg.node.rect.left, 2),
                .y = tg.node.rect.top + @divTrunc(tg.node.rect.bottom - tg.node.rect.top, 2),
            };
            if (try clickAt(allocator, act, tg.node.pid, pt.x, pt.y, tg.node.rid)) |m| return refuse(m);
            return actReply(allocator, u, act, "invoke (click)");
        }
        return patternFailure(allocator, e);
    };
    return actReply(allocator, u, act, @tagName(action));
}

fn scanFn(ch: u16) i16 {
    return w.VkKeyScanW(ch);
}

fn handleType(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    _ = io;
    var out: mcp.ToolResult = undefined;
    const text = strArg(args, "text") orelse return refuse("text is required");
    if (policy.textRefusal(text)) |m| return refuse(m);
    const act = (try actBegin(allocator, args, &out)) orelse return out;
    if (!policy.isForeground(act.win.hwnd, foregroundRoot())) return refuse("refused: the window is not the foreground window; use desktop_act focus first");
    const u = uia() catch |e| return errText(allocator, "UI Automation unavailable: {s}", .{@errorName(e)});
    const f = (try focusedTarget(allocator, u, act)) orelse return refuse("refused: the keyboard focus is not in this app");
    defer f.el.release();
    if (elementRefusal(f.el, f.node)) |m| return refuse(m);
    if (policy.typeRefusedRole(policy.roleName(f.node.control_type))) return refuse("refused: the focus is on a control that typing would press; focus a text field first");
    if (policy.expectedIdRefusal(allocator, strArg(args, "expected_id"), f.node.rid)) |m| return refuse(m);
    var list: std.ArrayList(w.INPUT) = .empty;
    try input.appendText(&list, allocator, text);
    if (try sendPaced(allocator, act, f.node.pid, list.items, true, .per_keystroke, .{ .focus = FocusExpect.of(f.el, f.node) })) |m| return refuse(m);
    return actReply(allocator, u, act, "type");
}

fn handleKey(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    _ = io;
    var out: mcp.ToolResult = undefined;
    const keys_s = strArg(args, "keys") orelse return refuse("keys is required (e.g. \"enter\", \"tab\", \"ctrl+a\")");
    const scan: keys.ScanFn = if (builtin.is_test) keys.fakeUsScan else scanFn;
    const chord = policy.allowedChord(keys_s, scan, &policy.allowed_chords) orelse
        return refuse("refused: that key is not on the allowed list (enter, shift+enter, tab, shift+tab, escape, backspace, delete, space, arrows, home, end, pageup, pagedown, shift/ctrl+navigation, ctrl+a, ctrl+z, ctrl+y, ctrl+f, f2, f3, f5)");
    const act = (try actBegin(allocator, args, &out)) orelse return out;
    if (!policy.isForeground(act.win.hwnd, foregroundRoot())) return refuse("refused: the window is not the foreground window; use desktop_act focus first");
    const u = uia() catch |e| return errText(allocator, "UI Automation unavailable: {s}", .{@errorName(e)});
    const f = (try focusedTarget(allocator, u, act)) orelse return refuse("refused: the keyboard focus is not in this app");
    defer f.el.release();
    if (policy.expectedIdRefusal(allocator, strArg(args, "expected_id"), f.node.rid)) |m| return refuse(m);
    if (f.node.is_password or f.el.currentIsPassword()) {
        if (policy.allowedChord(chord, scan, &policy.password_field_chords) == null) return refuse("refused: password field (only tab, shift+tab and escape leave it)");
    }
    const presses = std.mem.eql(u8, chord, "enter") or std.mem.eql(u8, chord, "space") or std.mem.eql(u8, chord, "shift+enter");
    if (presses and policy.refusesPayment(policy.roleName(f.node.control_type), f.node.name, allowPayments()))
        return refuse("refused: the focus is on a payment control (T3); zmcp-desktop never presses it");
    const combo = try keys.parseCombo(chord, scan);
    var list: std.ArrayList(w.INPUT) = .empty;
    try input.appendCombo(&list, allocator, &combo);
    if (try sendPaced(allocator, act, f.node.pid, list.items, true, .whole, .{ .focus = FocusExpect.of(f.el, f.node) })) |m| return refuse(m);
    return actReply(allocator, u, act, chord);
}

fn handleClick(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    _ = io;
    var out: mcp.ToolResult = undefined;
    const xv = if (args == .object) args.object.get("x") else null;
    const yv = if (args == .object) args.object.get("y") else null;
    const x = guard.coordinate(xv orelse return refuse("x is required")) orelse return refuse("x: not a finite number in range");
    const y = guard.coordinate(yv orelse return refuse("y is required")) orelse return refuse("y: not a finite number in range");
    const act = (try actBegin(allocator, args, &out)) orelse return out;
    if (pointRefusal(act, x, y)) |m| return refuse(m);
    const u = uia() catch |e| return errText(allocator, "UI Automation unavailable: {s}", .{@errorName(e)});
    // What UIA sees at the point decides: nothing of another process, no
    // password field or payment control, and no invokable element (use
    // desktop_act invoke with its id instead).
    var pid: i32 = @bitCast(act.win.pid);
    var rid: ?[]const i32 = null;
    if (u.elementFromPoint(x, y)) |el| {
        defer el.release();
        const node = try el.cachedNode(allocator, -1, 0);
        var filter = PidFilter.forWindow(allocator, g_policy.?, act.win);
        if (!try filter.allowed(node.pid, false)) return refuse("refused: the point is over another app");
        if (elementRefusal(el, node)) |m| return refuse(m);
        if (el.hasPattern(uia_com.UIA_InvokePatternId)) {
            const id = try policy.encodeRuntimeId(allocator, node.rid);
            return errText(allocator, "refused: UI Automation can invoke this element; use desktop_act invoke with id {s}", .{id});
        }
        pid = node.pid;
        if (node.rid.len > 0) rid = node.rid;
    } else |_| {}
    if (try clickAt(allocator, act, pid, x, y, rid)) |m| return refuse(m);
    return actReply(allocator, u, act, "click");
}

fn handleScroll(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    _ = io;
    var out: mcp.ToolResult = undefined;
    const id = strArg(args, "id") orelse return refuse("id is required (the list or pane to scroll, or any element inside it)");
    const dir = strArg(args, "direction") orelse return refuse("direction: up, down, left or right");
    const S = uia_mod.ScrollAmount;
    const hv: [2]S = if (std.mem.eql(u8, dir, "up")) .{ .none, .small_decrement } else if (std.mem.eql(u8, dir, "down")) .{ .none, .small_increment } else if (std.mem.eql(u8, dir, "left")) .{ .small_decrement, .none } else if (std.mem.eql(u8, dir, "right")) .{ .small_increment, .none } else return refuse("direction: up, down, left or right");
    const amount: usize = @intCast(intArg(args, "amount", 1, 1, 10));
    const act = (try actBegin(allocator, args, &out)) orelse return out;
    const u = uia() catch |e| return errText(allocator, "UI Automation unavailable: {s}", .{@errorName(e)});
    const tg = (try resolveElement(allocator, u, act, id, &out)) orelse return out;
    // The element or its nearest ancestor (within the allowlisted processes) with ScrollPattern.
    var cur = tg.el;
    var cur_pid = tg.node.pid;
    var depth: usize = 0;
    var filter = PidFilter.forWindow(allocator, g_policy.?, act.win);
    while (!cur.hasPattern(uia_com.UIA_ScrollPatternId)) : (depth += 1) {
        const parent = if (depth < 10) u.parentOf(cur) else null;
        cur.release();
        const p = parent orelse return refuse("nothing scrollable at or above this element");
        cur = p;
        const n = try cur.cachedNode(allocator, -1, 0);
        cur_pid = n.pid;
        if (!try filter.allowed(n.pid, false)) {
            cur.release();
            return refuse("nothing scrollable at or above this element in this app");
        }
    }
    defer cur.release();
    var i: usize = 0;
    while (i < amount) : (i += 1) {
        if (try recheck(allocator, act, cur_pid, limits().step_timeout_ms)) |m| return refuse(m);
        safety.ownUiaBegin();
        defer safety.ownUiaEnd();
        cur.scroll(hv[0], hv[1]) catch |e| return patternFailure(allocator, e);
    }
    return actReply(allocator, u, act, "scroll");
}


const tool_table = [_]mcp.ToolDef{
    .{
        .name = "desktop_list_windows",
        .description = "List the visible top-level windows of allowlisted apps: {windows:[{hwnd, exe, path, title, pid}]}. Other apps' windows are never listed.",
        .input_schema_json =
        \\{"type":"object","properties":{}}
        ,
        .handler = handleListWindows,
    },
    .{
        .name = "desktop_observe",
        .description = "Read an allowlisted window's UI Automation tree (ControlView) as compact nodes: {window:{hwnd,exe,path,title,pid}, count, truncated, truncated_by, ms, nodes:[{id, parent, role, name, value?, text?, rect:[x,y,w,h], enabled, focusable, is_password, automation_id?, class_name?, value_pattern, text_pattern?}]}. Read-only. Password values and text are never returned. text: the TextPattern text of a focusable edit/group/custom field (a contenteditable message composer; at most 4 per observe). Text is capped at 500 chars per node and the reply at 256 KiB. Pass root (a node id) to read one subtree. The walk goes level by level and stops at max_nodes, 2 s or 4 MiB (truncated_by: nodes|time|bytes). A UWP window is gated on the hosted app's image path, never on ApplicationFrameHost.exe.",
        .input_schema_json =
        \\{"type":"object","properties":{
        \\  "hwnd":{"type":["integer","string"],"description":"Window handle from desktop_list_windows"},
        \\  "max_depth":{"type":"integer","description":"Tree depth below the root (default 8, max 32)"},
        \\  "max_nodes":{"type":"integer","description":"Node cap (default 400, max 2000)"},
        \\  "root":{"type":"string","description":"Optional node id (r<hex>-...) to observe only that subtree"}
        \\},"required":["hwnd"]}
        ,
        .handler = handleObserve,
    },
    .{
        .name = "desktop_find",
        .description = "Find nodes in an allowlisted window by role (button, edit, listitem, text, ...) and/or a case-insensitive name substring. Same node shape as desktop_observe.",
        .input_schema_json =
        \\{"type":"object","properties":{
        \\  "hwnd":{"type":["integer","string"]},
        \\  "role":{"type":"string","description":"button, edit, listitem, list, text, document, menuitem, tabitem, checkbox, combobox, hyperlink, ..."},
        \\  "name_contains":{"type":"string"},
        \\  "limit":{"type":"integer","description":"Max matches (default 20, max 200)"}
        \\},"required":["hwnd"]}
        ,
        .handler = handleFind,
    },
    .{
        .name = "desktop_focused",
        .description = "The element with keyboard focus in an allowlisted window, when that window is the foreground window: {window, foreground, nodes:[node] or []}. The node carries value (ValuePattern) and, for a contenteditable composer, text (TextPattern); never for a password field.",
        .input_schema_json =
        \\{"type":"object","properties":{"hwnd":{"type":["integer","string"]}},"required":["hwnd"]}
        ,
        .handler = handleFocused,
    },
    .{
        .name = "desktop_act",
        .description = "Act on one element of an allowlisted window by its id (from desktop_observe/desktop_find): invoke (InvokePattern; a click at the element when it has none, foreground only), focus, set_value (ValuePattern; value: at most 4096 chars, no control characters), select, expand, scroll_into_view. Refused: password fields, payment-like buttons (pay, purchase, buy now, checkout, send money, transfer), elements of other processes, elevated windows, a locked workstation or the secure desktop, and every call once the kill event is set. Waits for the user's keyboard/mouse to be idle; user input during an act pauses the session until the user presses Continue in the host. Returns {ok, action, after:{focused_id, window_title}}.",
        .input_schema_json =
        \\{"type":"object","properties":{
        \\  "hwnd":{"type":["integer","string"]},
        \\  "id":{"type":"string","description":"Element id r<hex>-..."},
        \\  "action":{"type":"string","enum":["invoke","focus","set_value","select","expand","scroll_into_view"]},
        \\  "value":{"type":"string","description":"For set_value"}
        \\},"required":["hwnd","id","action"]}
        ,
        .handler = handleAct,
    },
    .{
        .name = "desktop_type",
        .description = "Type text as Unicode keystrokes into the focused element of an allowlisted window, only when that window is the foreground window (desktop_act focus first). At most 4096 characters and no control characters: send Enter/Tab with desktop_key. Refused in password fields and on buttons/links/list items. Pass expected_id (a node id) to refuse unless the focused element is that element. Returns {ok, action, after}.",
        .input_schema_json =
        \\{"type":"object","properties":{"hwnd":{"type":["integer","string"]},"text":{"type":"string"},"expected_id":{"type":"string","description":"Optional: the node id that must have the keyboard focus"}},"required":["hwnd","text"]}
        ,
        .handler = handleType,
    },
    .{
        .name = "desktop_key",
        .description = "Press one allowlisted key or chord in an allowlisted foreground window: enter, shift+enter, tab, shift+tab, escape, backspace, delete, space, up/down/left/right, home, end, pageup, pagedown, shift+(arrows/home/end), ctrl+(left/right/home/end/backspace/delete), ctrl+a, ctrl+z, ctrl+y, ctrl+f, f2, f3, f5. Everything else is refused, always including any Windows-key chord, alt+f4, alt+tab, alt+esc, alt+space, ctrl+esc and ctrl+alt+anything. Pass expected_id (a node id) to refuse unless the focused element is that element. Returns {ok, action, after}.",
        .input_schema_json =
        \\{"type":"object","properties":{"hwnd":{"type":["integer","string"]},"keys":{"type":"string","description":"e.g. enter, tab, ctrl+a"},"expected_id":{"type":"string","description":"Optional: the node id that must have the keyboard focus"}},"required":["hwnd","keys"]}
        ,
        .handler = handleKey,
    },
    .{
        .name = "desktop_click",
        .description = "Left-click at screen pixel (x, y) inside an allowlisted foreground window, for apps without usable UI Automation: refused outside the window's rect, where another window covers the point, over a password field or payment control, and where UIA can invoke the element (use desktop_act). Returns {ok, action, after}.",
        .input_schema_json =
        \\{"type":"object","properties":{"hwnd":{"type":["integer","string"]},"x":{"type":"number"},"y":{"type":"number"}},"required":["hwnd","x","y"]}
        ,
        .handler = handleClick,
    },
    .{
        .name = "desktop_scroll",
        .description = "Scroll the element (or its nearest scrollable ancestor in the same app) with UIA ScrollPattern: direction up|down|left|right, amount 1-10 small steps (default 1). Returns {ok, action, after}.",
        .input_schema_json =
        \\{"type":"object","properties":{"hwnd":{"type":["integer","string"]},"id":{"type":"string"},"direction":{"type":"string","enum":["up","down","left","right"]},"amount":{"type":"integer"}},"required":["hwnd","id","direction"]}
        ,
        .handler = handleScroll,
    },
};

// ── tests ───────────────────────────────────────────────────────────────────

const tst = std.testing;
const testwin = @import("testwin.zig");

test {
    _ = policy;
    _ = uia_mod;
    _ = safety;
}

test "parseHwnd accepts integers and decimal/hex strings" {
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(tst.allocator);
    try obj.put(tst.allocator, "hwnd", .{ .integer = 1234 });
    try tst.expectEqual(@as(?usize, 1234), parseHwnd(.{ .object = obj }));
    try obj.put(tst.allocator, "hwnd", .{ .string = "0x4d2" });
    try tst.expectEqual(@as(?usize, 1234), parseHwnd(.{ .object = obj }));
    try obj.put(tst.allocator, "hwnd", .{ .string = "1234" });
    try tst.expectEqual(@as(?usize, 1234), parseHwnd(.{ .object = obj }));
    try obj.put(tst.allocator, "hwnd", .{ .integer = -5 });
    try tst.expectEqual(@as(?usize, null), parseHwnd(.{ .object = obj }));
    try obj.put(tst.allocator, "hwnd", .{ .string = "zz" });
    try tst.expectEqual(@as(?usize, null), parseHwnd(.{ .object = obj }));
}

test "kill event: unset, then set" {
    const CreateEventW = struct {
        extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual: w.BOOL, initial: w.BOOL, name: [*:0]const u16) callconv(.winapi) ?w.HANDLE;
        extern "kernel32" fn SetEvent(h: w.HANDLE) callconv(.winapi) w.BOOL;
    };
    const name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\zmcp-desktop-kill-test-z2");
    try tst.expect(!killSet(name));
    const h = CreateEventW.CreateEventW(null, 1, 0, name) orelse return error.CreateEventFailed;
    defer _ = w.CloseHandle(h);
    try tst.expect(!killSet(name));
    _ = CreateEventW.SetEvent(h);
    try tst.expect(killSet(name));
}

fn ownExe(allocator: std.mem.Allocator) ![]u8 {
    const GetCurrentProcessId = struct {
        extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    }.GetCurrentProcessId;
    return imagePath(allocator, GetCurrentProcessId());
}

fn testPolicy(allocator: std.mem.Allocator, allow: []const u8) !Policy {
    return policyFromArgs(allocator, &.{ "--allow", allow });
}

test "gate: not allowlisted, then allowlisted (own test window only)" {
    const tw = try testwin.TestWindow.start(.hidden, 0);
    defer tw.stop();
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const none = try testPolicy(tst.allocator, "C:\\Windows\\System32\\notepad.exe");
    defer none.deinit();
    const r1 = try gate(a, none, tw.hwnd);
    try tst.expect(r1 == .refused);
    try tst.expect(std.mem.indexOf(u8, r1.refused, "not in the allowlist") != null);

    const me = try ownExe(a);
    // Our own exe by bare name: the entry is dropped, so the allowlist is empty.
    const bare = try testPolicy(tst.allocator, policy.baseName(me));
    defer bare.deinit();
    const rb = try gate(a, bare, tw.hwnd);
    try tst.expect(rb == .refused);
    try tst.expect(std.mem.indexOf(u8, rb.refused, "allowlist is empty") != null);
    // The same path in another case still matches (case-insensitive).
    const upper = try std.ascii.allocUpperString(a, me);
    const pu = try testPolicy(tst.allocator, upper);
    defer pu.deinit();
    try tst.expect((try gate(a, pu, tw.hwnd)) == .ok);

    const p = try testPolicy(tst.allocator, me);
    defer p.deinit();
    const r2 = try gate(a, p, tw.hwnd);
    try tst.expect(r2 == .ok);
    try tst.expectEqualStrings("zmcp desktop test window", r2.ok.title);
    const r3 = try gate(a, p, @ptrFromInt(0x7ffffff0));
    try tst.expect(r3 == .refused);
}

fn findNode(nodes: []const Node, role: []const u8, name: []const u8) ?Node {
    for (nodes) |n| if (std.mem.eql(u8, n.role, role) and std.mem.eql(u8, n.name, name)) return n;
    return null;
}

test "observe the test window: tree, roles, password value never read, ids resolve" {
    const tw = try testwin.TestWindow.start(.offscreen, 0);
    defer tw.stop();
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = try Uia.init();
    defer u.deinit();

    const me = try ownExe(a);
    g_policy = try testPolicy(tst.allocator, me);
    defer {
        g_policy.?.deinit();
        g_policy = null;
    }

    for ([_]uia_mod.Strategy{ .walker, .levels, .subtree }) |strategy| {
        const obs = try u.observe(a, tw.hwnd, null, .{ .strategy = strategy });
        var filter: PidFilter = .{ .allocator = a, .p = g_policy.?, .window_pid = 0 };
        const nodes = try toNodes(a, obs.nodes, &filter);
        try tst.expect(nodes.len >= 5);
        try tst.expect(nodes[0].parent == null);
        const send = findNode(nodes, "button", "Send") orelse return error.NoSendButton;
        try tst.expect(send.parent != null);
        try tst.expect(findNode(nodes, "text", "Alex Smith") != null);
        var saw_password = false;
        var saw_edit_value = false;
        for (nodes, obs.nodes) |n, r| {
            if (n.is_password) {
                saw_password = true;
                try tst.expect(r.value == null);
                try tst.expect(n.value == null);
            }
            if (n.value) |v| if (std.mem.eql(u8, v, testwin.edit_text)) {
                saw_edit_value = true;
            };
        }
        try tst.expect(saw_password);
        try tst.expect(saw_edit_value);

        // Nothing anywhere in the serialized reply carries the password.
        const json = try policy.writeNodes(a, .{ .hwnd = @intFromPtr(tw.hwnd), .exe = me, .title = "t", .pid = 0 }, nodes, obs.truncated, &.{}, policy.max_output_bytes);
        try tst.expect(std.mem.indexOf(u8, json, testwin.password_text) == null);
        try tst.expect(std.mem.indexOf(u8, json, testwin.edit_text) != null);

        // The id resolves back to the same element (RuntimeId VARIANT by value).
        const rid = try policy.decodeRuntimeId(a, send.id);
        const el = try u.resolve(tw.hwnd, rid, u.req_el);
        defer el.release();
        const again = try el.cachedNode(a, -1, 0);
        try tst.expectEqualStrings("Send", again.name);
        try tst.expectEqualSlices(i32, rid, again.rid);

        // Structure: Win32 controls expose their window class as ClassName,
        // and the edit has a ValuePattern; both reach the reply.
        try tst.expectEqualStrings("Button", send.class_name);
        var edit_has_value = false;
        for (nodes) |n| if (std.mem.eql(u8, n.role, "edit") and !n.is_password and n.value_pattern) {
            edit_has_value = true;
        };
        try tst.expect(edit_has_value);
        try tst.expect(std.mem.indexOf(u8, json, "\"class_name\":\"Button\"") != null);
        try tst.expect(std.mem.indexOf(u8, json, "\"value_pattern\":true") != null);
    }
}

test "CreatePropertyCondition takes a VARIANT by value (VT_I4, VT_BOOL) on this target" {
    const tw = try testwin.TestWindow.start(.offscreen, 0);
    defer tw.stop();
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = try Uia.init();
    defer u.deinit();
    const root = try u.elementFromHandle(tw.hwnd);
    defer root.release();

    const c_button = try u.propertyCondition(@import("uia_com.zig").UIA_ControlTypePropertyId, uia_mod.i4Variant(50000));
    defer c_button.release();
    const b = root.findFirst(uia_mod.TreeScope.subtree, c_button, u.req_el) orelse return error.ButtonNotFound;
    defer b.release();
    try tst.expectEqualStrings("Send", (try b.cachedNode(a, -1, 0)).name);

    const c_pw = try u.propertyCondition(@import("uia_com.zig").UIA_IsPasswordPropertyId, uia_mod.boolVariant(true));
    defer c_pw.release();
    const pw = root.findFirst(uia_mod.TreeScope.subtree, c_pw, u.req_el) orelse return error.PasswordNotFound;
    defer pw.release();
    try tst.expect((try pw.cachedNode(a, -1, 0)).is_password);

    // A condition that matches nothing finds nothing (the match above is not vacuous).
    const c_none = try u.propertyCondition(@import("uia_com.zig").UIA_ControlTypePropertyId, uia_mod.i4Variant(50039));
    defer c_none.release();
    try tst.expect(root.findFirst(uia_mod.TreeScope.subtree, c_none, u.req_el) == null);
}

test "node and depth caps hold and set truncated" {
    const tw = try testwin.TestWindow.start(.offscreen, 120);
    defer tw.stop();
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = try Uia.init();
    defer u.deinit();
    const full = try u.observe(a, tw.hwnd, null, .{ .max_nodes = 2000 });
    try tst.expect(full.nodes.len >= 120);
    try tst.expect(!full.truncated);
    const capped = try u.observe(a, tw.hwnd, null, .{ .max_nodes = 50 });
    try tst.expectEqual(@as(usize, 50), capped.nodes.len);
    try tst.expect(capped.truncated);
    const shallow = try u.observe(a, tw.hwnd, null, .{ .max_depth = 0 });
    try tst.expectEqual(@as(usize, 1), shallow.nodes.len);
}

test "tool handlers: observe/find/list over MCP-shaped args; refusals" {
    const tw = try testwin.TestWindow.start(.offscreen, 0);
    defer tw.stop();
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    defer if (g_uia) |u| {
        u.deinit();
        g_uia = null;
    };

    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "hwnd", .{ .integer = @intCast(@intFromPtr(tw.hwnd)) });
    const args: std.json.Value = .{ .object = obj };

    // No allowlist entry for this process: refused.
    g_policy = try testPolicy(tst.allocator, "notepad.exe");
    const r0 = try handleObserve(a, undefined, args);
    try tst.expect(r0.is_error);
    g_policy.?.deinit();

    const me = try ownExe(a);
    g_policy = try testPolicy(tst.allocator, me);
    defer {
        g_policy.?.deinit();
        g_policy = null;
    }
    const r1 = try handleObserve(a, undefined, args);
    try tst.expect(!r1.is_error);
    try tst.expect(std.mem.indexOf(u8, r1.text, testwin.password_text) == null);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, r1.text, .{});
    try tst.expect(parsed.value.object.get("count").?.integer >= 5);
    try tst.expectEqualStrings(me, parsed.value.object.get("window").?.object.get("path").?.string);
    try tst.expectEqualStrings(policy.baseName(me), parsed.value.object.get("window").?.object.get("exe").?.string);
    try tst.expect(parsed.value.object.get("truncated_by").? == .null);

    var fobj: std.json.ObjectMap = .empty;
    try fobj.put(a, "hwnd", .{ .integer = @intCast(@intFromPtr(tw.hwnd)) });
    try fobj.put(a, "role", .{ .string = "button" });
    try fobj.put(a, "name_contains", .{ .string = "sEnD" });
    const r2 = try handleFind(a, undefined, .{ .object = fobj });
    try tst.expect(!r2.is_error);
    parsed = try std.json.parseFromSlice(std.json.Value, a, r2.text, .{});
    try tst.expectEqual(@as(i64, 1), parsed.value.object.get("count").?.integer);

    // Observe from a subtree root id.
    const send_id = parsed.value.object.get("nodes").?.array.items[0].object.get("id").?.string;
    try obj.put(a, "root", .{ .string = send_id });
    const r3 = try handleObserve(a, undefined, .{ .object = obj });
    try tst.expect(!r3.is_error);
    parsed = try std.json.parseFromSlice(std.json.Value, a, r3.text, .{});
    try tst.expectEqualStrings("Send", parsed.value.object.get("nodes").?.array.items[0].object.get("name").?.string);

    // The test window is not the foreground window: no focused node.
    const r4 = try handleFocused(a, undefined, args);
    try tst.expect(!r4.is_error);
    try tst.expect(std.mem.indexOf(u8, r4.text, "\"foreground\":false") != null);

    // list_windows only lists allowlisted processes (the tool window has a title, so it may be listed).
    const r5 = try handleListWindows(a, undefined, .null);
    try tst.expect(!r5.is_error);
    parsed = try std.json.parseFromSlice(std.json.Value, a, r5.text, .{});
    for (parsed.value.object.get("windows").?.array.items) |win| {
        try tst.expect(std.ascii.eqlIgnoreCase(me, win.object.get("path").?.string));
    }
}

test "list_windows with an empty allowlist refuses before opening any process" {
    g_policy = try Policy.fromArgs(tst.allocator, &.{ "--allow", "signal.exe" }); // bare name: dropped
    defer {
        g_policy.?.deinit();
        g_policy = null;
    }
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const r = try handleListWindows(arena.allocator(), undefined, .null);
    try tst.expect(r.is_error);
    try tst.expectEqualStrings("refused: the allowlist is empty", r.text);
}

test "a node without a process id is kept only as the root" {
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try Policy.fromArgs(tst.allocator, &.{ "--allow", "C:\\x\\y.exe" });
    defer p.deinit();
    const r0 = [_]i32{ 1, 1 };
    const r1 = [_]i32{ 1, 2 };
    const r2 = [_]i32{ 1, 3 };
    const zero: uia_mod.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    const raw = [_]uia_mod.RawNode{
        .{ .rid = @constCast(&r0), .parent = -1, .depth = 0, .control_type = 50032, .name = @constCast("root"), .rect = zero, .enabled = true, .focusable = false, .is_password = false, .has_value = false, .pid = 0 },
        .{ .rid = @constCast(&r1), .parent = 0, .depth = 1, .control_type = 50000, .name = @constCast("no pid"), .rect = zero, .enabled = true, .focusable = false, .is_password = false, .has_value = false, .pid = 0 },
        .{ .rid = @constCast(&r2), .parent = 1, .depth = 2, .control_type = 50000, .name = @constCast("under it"), .rect = zero, .enabled = true, .focusable = false, .is_password = false, .has_value = false, .pid = 77 },
    };
    var filter: PidFilter = .{ .allocator = a, .p = p, .window_pid = 77 };
    const nodes = try toNodes(a, &raw, &filter);
    try tst.expectEqual(@as(usize, 1), nodes.len);
    try tst.expectEqualStrings("root", nodes[0].name);
}

test "UIA runs with connection and transaction timeouts" {
    const u = try Uia.init();
    defer u.deinit();
    const to = u.timeouts();
    try tst.expectEqual(uia_mod.connection_timeout_ms, to[0]);
    try tst.expectEqual(uia_mod.transaction_timeout_ms, to[1]);
}

test "levels is the default; time and byte budgets truncate with a reason" {
    const tw = try testwin.TestWindow.start(.offscreen, 60);
    defer tw.stop();
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = try Uia.init();
    defer u.deinit();
    try tst.expectEqual(uia_mod.default_strategy, (uia_mod.ObserveOptions{}).strategy);
    try tst.expect(uia_mod.default_strategy != .subtree);

    const full = try u.observe(a, tw.hwnd, null, .{ .max_nodes = 2000 });
    try tst.expect(!full.truncated and full.truncated_by == null);
    try tst.expect(full.nodes.len >= 60);

    const by_nodes = try u.observe(a, tw.hwnd, null, .{ .max_nodes = 10 });
    try tst.expectEqual(uia_mod.TruncatedBy.nodes, by_nodes.truncated_by.?);

    const by_time = try u.observe(a, tw.hwnd, null, .{ .time_budget_ms = 0 });
    try tst.expect(by_time.truncated);
    try tst.expectEqual(uia_mod.TruncatedBy.time, by_time.truncated_by.?);
    try tst.expectEqual(@as(usize, 1), by_time.nodes.len);

    const by_bytes = try u.observe(a, tw.hwnd, null, .{ .byte_budget = 2048 });
    try tst.expectEqual(uia_mod.TruncatedBy.bytes, by_bytes.truncated_by.?);
    try tst.expect(by_bytes.nodes.len > 1 and by_bytes.nodes.len < full.nodes.len);
}

test "a tool call can't choose the walk strategy" {
    const tw = try testwin.TestWindow.start(.offscreen, 0);
    defer tw.stop();
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    defer if (g_uia) |u| {
        u.deinit();
        g_uia = null;
    };
    g_policy = try testPolicy(tst.allocator, try ownExe(a));
    defer {
        g_policy.?.deinit();
        g_policy = null;
    }
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "hwnd", .{ .integer = @intCast(@intFromPtr(tw.hwnd)) });
    try obj.put(a, "strategy", .{ .string = "subtree" });
    const r = try handleObserve(a, undefined, .{ .object = obj });
    try tst.expect(!r.is_error);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, r.text, .{});
    try tst.expectEqualStrings(@tagName(uia_mod.default_strategy), parsed.value.object.get("strategy").?.string);
}

test "walker strategy: max_nodes and the byte budget are exact per node" {
    const tw = try testwin.TestWindow.start(.offscreen, 40);
    defer tw.stop();
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = try Uia.init();
    defer u.deinit();
    for ([_]usize{ 1, 2, 7, 23 }) |cap| {
        const obs = try u.observe(a, tw.hwnd, null, .{ .max_nodes = cap, .strategy = .walker });
        try tst.expectEqual(cap, obs.nodes.len);
        try tst.expectEqual(uia_mod.TruncatedBy.nodes, obs.truncated_by.?);
    }
    // The byte budget stops at the first node that reaches it: the nodes before
    // the last one are under budget.
    const obs = try u.observe(a, tw.hwnd, null, .{ .byte_budget = 3000, .strategy = .walker, .values = false });
    try tst.expectEqual(uia_mod.TruncatedBy.bytes, obs.truncated_by.?);
    var bytes: usize = 0;
    for (obs.nodes[0 .. obs.nodes.len - 1]) |n| bytes += @sizeOf(uia_mod.RawNode) + n.name.len + n.rid.len * @sizeOf(i32);
    try tst.expect(bytes < 3000);
}

test "paths compare in canonical form: long name, Unicode lower case" {
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tst.expectEqualStrings("c:\\nope\\\u{e4}\u{f6}\u{3b1}\\x.exe", try canonicalPath(a, "C:\\NOPE\\\u{c4}\u{d6}\u{391}\\X.EXE"));

    const GetShortPathNameW = struct {
        extern "kernel32" fn GetShortPathNameW(long: [*:0]const u16, short: [*]u16, n: u32) callconv(.winapi) u32;
    }.GetShortPathNameW;
    const me = try ownExe(a);
    const wide = try w.toW(a, me);
    var buf: [1024]u16 = undefined;
    const n = GetShortPathNameW(wide.ptr, &buf, buf.len);
    if (n == 0) return error.SkipZigTest;
    const short = try policy.utf16ToUtf8Capped(a, buf[0..n], 1024);
    try tst.expectEqualStrings(me, try canonicalPath(a, short));
    // An allowlist entry spelled as the 8.3 alias in upper case still matches.
    const p = try testPolicy(tst.allocator, try std.ascii.allocUpperString(a, short));
    defer p.deinit();
    try tst.expect(p.allows(me));
}

// ── act tests (Z3): only this test process's own offscreen window ──────────
//
// Nothing here injects input: input.send refuses inside a test binary, and
// the foreground window / keyboard focus are test seams (g_test_foreground,
// g_test_focus_rid), so no real window is activated or focused. Invoke and
// set_value go through UI Automation patterns to our own window only.

const ActFixture = struct {
    tw: testwin.TestWindow,
    arena: std.heap.ArenaAllocator,

    fn start() !*ActFixture {
        const f = try tst.allocator.create(ActFixture);
        f.* = .{ .tw = try testwin.TestWindow.start(.offscreen, 0), .arena = std.heap.ArenaAllocator.init(tst.allocator) };
        g_policy = try testPolicy(tst.allocator, try ownExe(f.arena.allocator()));
        g_session = .{};
        g_keys = .{ .chords = .strict };
        g_test_foreground = null;
        g_test_focus_rid = null;
        g_test_sent = 0;
        safety.test_last_real = null;
        return f;
    }

    fn stop(f: *ActFixture) void {
        if (g_uia) |u| {
            u.deinit();
            g_uia = null;
        }
        g_policy.?.deinit();
        g_policy = null;
        g_test_foreground = null;
        g_test_focus_rid = null;
        f.tw.stop();
        f.arena.deinit();
        tst.allocator.destroy(f);
    }

    fn a(f: *ActFixture) std.mem.Allocator {
        return f.arena.allocator();
    }

    fn hwnd(f: *ActFixture) usize {
        return @intFromPtr(f.tw.hwnd);
    }

    /// Call a handler with `{"hwnd": <ours>, ...extra}`.
    fn call(f: *ActFixture, h: mcp.ToolHandler, extra: []const u8) !mcp.ToolResult {
        const j = try std.fmt.allocPrint(f.a(), "{{\"hwnd\":{d}{s}{s}}}", .{ f.hwnd(), if (extra.len > 0) "," else "", extra });
        const v = try std.json.parseFromSliceLeaky(std.json.Value, f.a(), j, .{});
        return h(f.a(), undefined, v);
    }

    /// The id of the first node matching role + exact name (and password flag).
    fn id(f: *ActFixture, role: []const u8, name: ?[]const u8, password: bool) ![]const u8 {
        const r = try f.call(handleObserve, "");
        try tst.expect(!r.is_error);
        const v = try std.json.parseFromSliceLeaky(std.json.Value, f.a(), r.text, .{});
        for (v.object.get("nodes").?.array.items) |n| {
            const o = n.object;
            if (!std.mem.eql(u8, o.get("role").?.string, role)) continue;
            if (o.get("is_password").?.bool != password) continue;
            if (name) |nm| if (!std.mem.eql(u8, o.get("name").?.string, nm)) continue;
            return o.get("id").?.string;
        }
        return error.NodeNotFound;
    }

    fn focusOn(f: *ActFixture, node_id: []const u8) !void {
        g_test_focus_rid = try policy.decodeRuntimeId(f.a(), node_id);
    }
};

fn expectRefused(r: mcp.ToolResult, needle: []const u8) !void {
    if (!r.is_error or std.mem.indexOf(u8, r.text, needle) == null) {
        std.debug.print("expected a refusal containing '{s}', got is_error={} text={s}\n", .{ needle, r.is_error, r.text });
        return error.TestUnexpectedResult;
    }
}

fn expectOk(r: mcp.ToolResult) !void {
    if (r.is_error or std.mem.indexOf(u8, r.text, "\"ok\":true") == null) {
        std.debug.print("expected ok, got is_error={} text={s}\n", .{ r.is_error, r.text });
        return error.TestUnexpectedResult;
    }
}

/// The RichEdit and the password RichEdit of the fixture window, from an
/// observe reply: {id, the node object}.
fn richNodes(f: *ActFixture, text: []const u8) !struct { rich: std.json.ObjectMap, pw: std.json.ObjectMap, long: std.json.ObjectMap } {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, f.a(), text, .{});
    var rich: ?std.json.ObjectMap = null;
    var pw: ?std.json.ObjectMap = null;
    var long: ?std.json.ObjectMap = null;
    for (v.object.get("nodes").?.array.items) |n| {
        const o = n.object;
        const cls = if (o.get("class_name")) |c| c.string else "";
        if (!std.ascii.eqlIgnoreCase(cls, testwin.rich_class)) continue;
        const t = if (o.get("text")) |x| x.string else "";
        if (o.get("is_password").?.bool) {
            pw = o;
        } else if (std.mem.startsWith(u8, t, "LLL")) {
            long = o;
        } else rich = o;
    }
    return .{ .rich = rich orelse return error.NoRichEdit, .pw = pw orelse return error.NoPasswordRichEdit, .long = long orelse return error.NoLongRichEdit };
}

test "text: a RichEdit's TextPattern text in observe and focused; never a password field's (own window)" {
    const f = try ActFixture.start();
    defer f.stop();
    const r = try f.call(handleObserve, "");
    try tst.expect(!r.is_error);
    try tst.expect(std.mem.indexOf(u8, r.text, testwin.rich_password_text) == null);
    try tst.expect(std.mem.indexOf(u8, r.text, testwin.password_text) == null);
    const nodes = try richNodes(f, r.text);
    try tst.expect(nodes.rich.get("text_pattern").?.bool);
    // The provider may end the document range with a paragraph mark.
    try tst.expectEqualStrings(testwin.rich_text, std.mem.trimEnd(u8, nodes.rich.get("text").?.string, "\r\n"));
    try tst.expect(nodes.pw.get("text") == null and nodes.pw.get("value") == null);
    try tst.expect(nodes.rich.get("text_truncated") == null);
    // A text over the cap is cut at 500 chars and flagged.
    try tst.expectEqual(@as(usize, policy.max_text_chars), nodes.long.get("text").?.string.len);
    try tst.expect(nodes.long.get("text_truncated").?.bool);
    const rich_id = nodes.rich.get("id").?.string;
    const pw_id = nodes.pw.get("id").?.string;

    // desktop_focused (the foreground and the focus are test seams).
    try tst.expect(std.mem.indexOf(u8, (try f.call(handleFocused, "")).text, "\"foreground\":false") != null);
    g_test_foreground = f.hwnd();
    try f.focusOn(rich_id);
    const fr = try f.call(handleFocused, "");
    try tst.expect(!fr.is_error);
    const fv = try std.json.parseFromSliceLeaky(std.json.Value, f.a(), fr.text, .{});
    const fnode = fv.object.get("nodes").?.array.items[0].object;
    try tst.expectEqualStrings(rich_id, fnode.get("id").?.string);
    try tst.expectEqualStrings(testwin.rich_text, std.mem.trimEnd(u8, fnode.get("text").?.string, "\r\n"));

    try f.focusOn(pw_id);
    const fp = try f.call(handleFocused, "");
    try tst.expect(!fp.is_error);
    try tst.expect(std.mem.indexOf(u8, fp.text, testwin.rich_password_text) == null);
    try tst.expect(std.mem.indexOf(u8, fp.text, "\"text\"") == null);
    try tst.expect(std.mem.indexOf(u8, fp.text, "\"is_password\":true") != null);

    // A read-only observe with texts off reads none (desktop_find's path).
    const u = try uia();
    const obs = try u.observe(f.a(), f.tw.hwnd, null, .{ .texts = false });
    for (obs.nodes) |n| try tst.expect(n.text == null);
}

test "act: invoke the Send button and set_value the edit (own window, no input injected)" {
    const f = try ActFixture.start();
    defer f.stop();
    const send = try f.id("button", "Send", false);
    const clicks0 = testwin.send_clicks.load(.acquire);
    const r1 = try f.call(handleAct, try std.fmt.allocPrint(f.a(), "\"id\":\"{s}\",\"action\":\"invoke\"", .{send}));
    try expectOk(r1);
    try tst.expectEqual(clicks0 + 1, testwin.send_clicks.load(.acquire));
    const v1 = try std.json.parseFromSliceLeaky(std.json.Value, f.a(), r1.text, .{});
    try tst.expectEqualStrings("invoke", v1.object.get("action").?.string);
    try tst.expectEqualStrings("zmcp desktop test window", v1.object.get("after").?.object.get("window_title").?.string);

    const edit = try f.id("edit", null, false);
    const r2 = try f.call(handleAct, try std.fmt.allocPrint(f.a(), "\"id\":\"{s}\",\"action\":\"set_value\",\"value\":\"set by zmcp-desktop \u{e9}\"", .{edit}));
    try expectOk(r2);
    var buf: [256]u8 = undefined;
    try tst.expectEqualStrings("set by zmcp-desktop \u{e9}", f.tw.childText(testwin.id_edit, &buf));

    // Acting on our own offscreen window never activated it. (Not "the
    // foreground is unchanged": the user may switch windows meanwhile,
    // which made this test flaky.)
    if (w.GetForegroundWindow()) |fg| try tst.expect(@intFromPtr(GetAncestor(fg, GA_ROOT) orelse fg) != @intFromPtr(f.tw.hwnd));
    try tst.expectEqual(@as(usize, 0), g_test_sent);
    try tst.expectEqual(@as(u32, 2), g_session.steps);
}

test "act refusals: password field, payment button, bad input, other process" {
    const f = try ActFixture.start();
    defer f.stop();

    const pw = try f.id("edit", null, true);
    try expectRefused(try f.call(handleAct, try std.fmt.allocPrint(f.a(), "\"id\":\"{s}\",\"action\":\"set_value\",\"value\":\"x\"", .{pw})), "password field");
    try expectRefused(try f.call(handleAct, try std.fmt.allocPrint(f.a(), "\"id\":\"{s}\",\"action\":\"focus\"", .{pw})), "password field");
    var buf: [256]u8 = undefined;
    try tst.expectEqualStrings(testwin.password_text, f.tw.childText(testwin.id_password, &buf));

    const pay = try f.id("button", testwin.pay_button, false);
    const pay0 = testwin.pay_clicks.load(.acquire);
    try expectRefused(try f.call(handleAct, try std.fmt.allocPrint(f.a(), "\"id\":\"{s}\",\"action\":\"invoke\"", .{pay})), "payment");
    try tst.expectEqual(pay0, testwin.pay_clicks.load(.acquire));

    const edit = try f.id("edit", null, false);
    try expectRefused(try f.call(handleAct, try std.fmt.allocPrint(f.a(), "\"id\":\"{s}\",\"action\":\"set_value\",\"value\":\"a\\nb\"", .{edit})), "control character");
    try expectRefused(try f.call(handleAct, try std.fmt.allocPrint(f.a(), "\"id\":\"{s}\",\"action\":\"click\"", .{edit})), "action:");
    try expectRefused(try f.call(handleAct, "\"id\":\"r7-7-7\",\"action\":\"invoke\""), "no such element");
    try expectRefused(try f.call(handleAct, "\"id\":\"nope\",\"action\":\"invoke\""), "not an element id");
    try expectRefused(try f.call(handleAct, "\"action\":\"invoke\""), "id is required");
    try tst.expectEqualStrings(testwin.edit_text, f.tw.childText(testwin.id_edit, &buf));

    // Not allowlisted: this process is not in the allowlist any more.
    g_policy.?.deinit();
    g_policy = try testPolicy(tst.allocator, "C:\\Windows\\System32\\notepad.exe");
    const send = "r1-2"; // never resolved: the gate refuses first
    try expectRefused(try f.call(handleAct, "\"id\":\"" ++ send ++ "\",\"action\":\"invoke\""), "not in the allowlist");
}

test "act: kill event, pause latch, idle wait and step limit" {
    const f = try ActFixture.start();
    defer f.stop();
    const send = try f.id("button", "Send", false);
    const args = try std.fmt.allocPrint(f.a(), "\"id\":\"{s}\",\"action\":\"invoke\"", .{send});

    // The user typed 100 ms ago: wait (no step counted).
    safety.test_last_real = safety.nowMs() - 100;
    try expectRefused(try f.call(handleAct, args), "waiting");
    try tst.expectEqual(@as(u32, 0), g_session.steps);
    safety.test_last_real = null;

    // Paused by input during an earlier act: no tool resumes; only the host's
    // --resume-event does, and only a signal given after the pause.
    const R = struct {
        extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual: w.BOOL, initial: w.BOOL, name: [*:0]const u16) callconv(.winapi) ?w.HANDLE;
        extern "kernel32" fn SetEvent(h: w.HANDLE) callconv(.winapi) w.BOOL;
        extern "kernel32" fn WaitForSingleObject(h: w.HANDLE, ms: u32) callconv(.winapi) u32;
    };
    g_session.paused = true;
    try expectRefused(try f.call(handleAct, args), "paused"); // no resume event configured
    const rname = std.unicode.utf8ToUtf16LeStringLiteral("Local\\zmcp-desktop-resume-test-z3");
    const rh = R.CreateEventW(null, 1, 0, rname) orelse return error.CreateEventFailed;
    defer _ = w.CloseHandle(rh);
    g_resume_name = rname;
    defer g_resume_name = null;
    try expectRefused(try f.call(handleAct, args), "paused"); // not signalled
    // A Continue signalled BEFORE this pause is stale and dropped at pause time.
    _ = R.SetEvent(rh);
    dropStaleResume();
    try tst.expectEqual(@as(u32, 0x102), R.WaitForSingleObject(rh, 0)); // WAIT_TIMEOUT: reset
    try expectRefused(try f.call(handleAct, args), "paused");
    // The user's Continue after the pause resumes, and the signal is consumed.
    _ = R.SetEvent(rh);
    try expectOk(try f.call(handleAct, args));
    try tst.expect(!g_session.paused);
    try tst.expectEqual(@as(u32, 0x102), R.WaitForSingleObject(rh, 0));
    // A model cannot resume: there is no resume tool.
    for (tool_table) |td| try tst.expect(std.mem.indexOf(u8, td.name, "resume") == null);

    // Step limit.
    g_session.steps = g_policy.?.limits.max_steps;
    try expectRefused(try f.call(handleAct, args), "step limit");
    g_session = .{};

    // Kill event: every act and observe call stops, and it stays stopped.
    const K = struct {
        extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual: w.BOOL, initial: w.BOOL, name: [*:0]const u16) callconv(.winapi) ?w.HANDLE;
        extern "kernel32" fn SetEvent(h: w.HANDLE) callconv(.winapi) w.BOOL;
        extern "kernel32" fn ResetEvent(h: w.HANDLE) callconv(.winapi) w.BOOL;
    };
    const name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\zmcp-desktop-kill-test-z3-act");
    const h = K.CreateEventW(null, 1, 0, name) orelse return error.CreateEventFailed;
    defer _ = w.CloseHandle(h);
    const kill_name = try f.a().dupeZ(u16, name[0..name.len]);
    g_kill_name = kill_name;
    defer {
        g_kill_name = null;
        safety.resetKillLatchForTest();
    }
    try expectOk(try f.call(handleAct, args));
    _ = K.SetEvent(h);
    const clicks = testwin.send_clicks.load(.acquire);
    for ([_]mcp.ToolHandler{ handleAct, handleType, handleKey, handleObserve }) |hd| {
        const r = try f.call(hd, "\"id\":\"r1\",\"action\":\"invoke\",\"text\":\"x\",\"keys\":\"enter\"");
        try tst.expect(r.is_error);
        try tst.expectEqualStrings("stopped by the user", r.text);
    }
    _ = K.ResetEvent(h);
    try expectRefused(try f.call(handleAct, args), "stopped by the user");
    try tst.expectEqual(clicks, testwin.send_clicks.load(.acquire));
}

test "type: foreground only, focused text field only, then through the strict key guard" {
    const f = try ActFixture.start();
    defer f.stop();
    const edit = try f.id("edit", null, false);
    const pw = try f.id("edit", null, true);
    const send = try f.id("button", "Send", false);

    try expectRefused(try f.call(handleType, "\"text\":\"hello\""), "not the foreground window");
    g_test_foreground = 0x7ffffff0; // some other window is in front
    try expectRefused(try f.call(handleType, "\"text\":\"hello\""), "not the foreground window");
    g_test_foreground = f.hwnd();
    try expectRefused(try f.call(handleType, "\"text\":\"hello\""), "focus is not in this app");
    try f.focusOn(pw);
    try expectRefused(try f.call(handleType, "\"text\":\"hello\""), "password field");
    try f.focusOn(send);
    try expectRefused(try f.call(handleType, "\"text\":\"hello\""), "typing would press");
    try f.focusOn(edit);
    try expectRefused(try f.call(handleType, "\"text\":\"hi\\n\""), "control character");
    try tst.expectEqual(@as(usize, 0), g_test_sent);

    const r = try f.call(handleType, "\"text\":\"h\u{e9}llo \u{1F600}\"");
    try expectOk(r);
    // 6 BMP chars + one surrogate pair = 8 UTF-16 units, each down + up.
    try tst.expectEqual(@as(usize, 16), g_test_sent);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, f.a(), r.text, .{});
    try tst.expectEqualStrings(edit, v.object.get("after").?.object.get("focused_id").?.string);

    const long = try f.a().alloc(u8, policy.max_act_text_chars + 1);
    @memset(long, 'a');
    try expectRefused(try f.call(handleType, try std.fmt.allocPrint(f.a(), "\"text\":\"{s}\"", .{long})), "4096");
}

test "key: allowlisted chords only, strict blocklist, password and payment focus" {
    const f = try ActFixture.start();
    defer f.stop();
    const edit = try f.id("edit", null, false);
    const pw = try f.id("edit", null, true);
    const pay = try f.id("button", testwin.pay_button, false);
    g_test_foreground = f.hwnd();
    try f.focusOn(edit);

    for ([_][]const u8{ "win+r", "alt+f4", "ctrl+alt+del", "alt+tab", "lwin", "ctrl+esc", "alt+space", "ctrl+v", "ctrl+w", "a" }) |k| {
        try expectRefused(try f.call(handleKey, try std.fmt.allocPrint(f.a(), "\"keys\":\"{s}\"", .{k})), "not on the allowed list");
    }
    try tst.expectEqual(@as(usize, 0), g_test_sent);
    try expectOk(try f.call(handleKey, "\"keys\":\"enter\""));
    try tst.expectEqual(@as(usize, 2), g_test_sent);
    try expectOk(try f.call(handleKey, "\"keys\":\"ctrl+a\""));
    try tst.expectEqual(@as(usize, 6), g_test_sent);

    // A modifier left held by an earlier send would make alt+... a blocked chord.
    g_keys.held.add(0x12);
    try expectRefused(try f.call(handleKey, "\"keys\":\"space\""), "blocked");
    g_keys.held = .{};

    try f.focusOn(pw);
    try expectRefused(try f.call(handleKey, "\"keys\":\"enter\""), "password field");
    try expectOk(try f.call(handleKey, "\"keys\":\"tab\""));
    try f.focusOn(pay);
    try expectRefused(try f.call(handleKey, "\"keys\":\"enter\""), "payment");
    try expectRefused(try f.call(handleKey, "\"keys\":\"space\""), "payment");

    g_test_foreground = null;
    try expectRefused(try f.call(handleKey, "\"keys\":\"enter\""), "not the foreground window");
}

test "type/key with expected_id: refused (nothing sent) unless the focus is that element" {
    const f = try ActFixture.start();
    defer f.stop();
    const edit = try f.id("edit", null, false);
    const send = try f.id("button", "Send", false);
    g_test_foreground = f.hwnd();
    try f.focusOn(edit);

    const other = try std.fmt.allocPrint(f.a(), "\"expected_id\":\"{s}\"", .{send});
    const same = try std.fmt.allocPrint(f.a(), "\"expected_id\":\"{s}\"", .{edit});
    try expectRefused(try f.call(handleType, try std.fmt.allocPrint(f.a(), "\"text\":\"hi\",{s}", .{other})), "expected element");
    try expectRefused(try f.call(handleKey, try std.fmt.allocPrint(f.a(), "\"keys\":\"enter\",{s}", .{other})), "expected element");
    try expectRefused(try f.call(handleKey, "\"keys\":\"enter\",\"expected_id\":\"nope\""), "not an element id");
    try tst.expectEqual(@as(usize, 0), g_test_sent);

    try expectOk(try f.call(handleType, try std.fmt.allocPrint(f.a(), "\"text\":\"hi\",{s}", .{same})));
    try tst.expectEqual(@as(usize, 4), g_test_sent);
    try expectOk(try f.call(handleKey, try std.fmt.allocPrint(f.a(), "\"keys\":\"tab\",{s}", .{same})));
    try tst.expectEqual(@as(usize, 6), g_test_sent);
    // Without expected_id nothing changes.
    try expectOk(try f.call(handleKey, "\"keys\":\"tab\""));
}

test "click: numbers validated, foreground, inside the window, never where UIA can invoke" {
    const f = try ActFixture.start();
    defer f.stop();
    try expectRefused(try f.call(handleClick, "\"x\":1e300,\"y\":5"), "x:");
    try expectRefused(try f.call(handleClick, "\"x\":\"NaN\",\"y\":5"), "x:");
    try expectRefused(try f.call(handleClick, "\"y\":5"), "x is required");
    // Our window sits at (-20000, -20000), off every monitor.
    try expectRefused(try f.call(handleClick, "\"x\":-19990,\"y\":-19990"), "not the foreground window");
    g_test_foreground = f.hwnd();
    try expectRefused(try f.call(handleClick, "\"x\":5,\"y\":5"), "outside the window");
    try expectRefused(try f.call(handleClick, "\"x\":-19990,\"y\":-19990"), "outside the virtual desktop");
    try tst.expectEqual(@as(usize, 0), g_test_sent);
}

test "scroll: nothing scrollable in the test window is refused cleanly" {
    const f = try ActFixture.start();
    defer f.stop();
    const edit = try f.id("edit", null, false);
    try expectRefused(try f.call(handleScroll, try std.fmt.allocPrint(f.a(), "\"id\":\"{s}\",\"direction\":\"down\"", .{edit})), "scrollable");
    try expectRefused(try f.call(handleScroll, try std.fmt.allocPrint(f.a(), "\"id\":\"{s}\",\"direction\":\"sideways\"", .{edit})), "direction");
}

test "the act tools are in the tool table with their schemas" {
    var arena = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena.deinit();
    var names: [tool_table.len][]const u8 = undefined;
    for (tool_table, 0..) |td, i| {
        names[i] = td.name;
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), td.input_schema_json, .{});
        try tst.expect(v == .object);
    }
    for ([_][]const u8{ "desktop_act", "desktop_type", "desktop_key", "desktop_click", "desktop_scroll" }) |n| {
        var found = false;
        for (names) |m| found = found or std.mem.eql(u8, m, n);
        try tst.expect(found);
    }
}

// ── review fixes (Z3 r2) ───────────────────────────────────────────────────

var g_moved_focus_to: ?[]const i32 = null;

fn moveFocusAfterFirstKey() void {
    if (g_moved_focus_to) |r| {
        g_test_focus_rid = r;
        g_moved_focus_to = null;
    }
}

test "type/key stop with \"focus moved\" when the focus changes between keystrokes" {
    const f = try ActFixture.start();
    defer f.stop();
    defer g_test_after_send = null;
    const edit = try f.id("edit", null, false);
    const pw = try f.id("edit", null, true);
    const send = try f.id("button", "Send", false);
    g_test_foreground = f.hwnd();

    // Control: focus stays put, all 5 keystrokes go.
    try f.focusOn(edit);
    try expectOk(try f.call(handleType, "\"text\":\"hello\""));
    try tst.expectEqual(@as(usize, 10), g_test_sent);

    // After the first keystroke the focus moves to the password field (id,
    // password flag and role... the role is the same, the rest differs).
    for ([_][]const u8{ pw, send }) |target| {
        g_test_sent = 0;
        try f.focusOn(edit);
        g_moved_focus_to = try policy.decodeRuntimeId(f.a(), target);
        g_test_after_send = moveFocusAfterFirstKey;
        try expectRefused(try f.call(handleType, "\"text\":\"hello\""), "focus moved");
        try tst.expectEqual(@as(usize, 2), g_test_sent); // only the first keystroke went out
    }
}

test "focus expectation compares id, password flag and role separately" {
    const rid = [_]i32{ 42, 1, 2 };
    const other = [_]i32{ 42, 1, 3 };
    const fe: FocusExpect = .{ .rid = &rid, .is_password = false, .control_type = 50004 };
    try tst.expect(fe.matches(&rid, false, 50004));
    try tst.expect(!fe.matches(&other, false, 50004)); // another element
    try tst.expect(!fe.matches(&rid, true, 50004)); // became a password field
    try tst.expect(!fe.matches(&rid, false, 50000)); // role changed
    try tst.expect(!fe.matches(&.{}, false, 50004)); // no id
}

test "invoke-by-click re-reads the element under the point" {
    const f = try ActFixture.start();
    defer f.stop();
    const send = try f.id("button", "Send", false);
    const rid = try policy.decodeRuntimeId(f.a(), send);
    const u = try uia();
    // Our window is off every monitor: whatever UIA finds at a point in it
    // is not the Send button, so the click would be refused.
    try expectRefusedText(try pointElementRefusal(f.a(), u, .{ .x = -19985, .y = -19945 }, rid), "stopped:");
    // And clickPointRefusal checks the window under the point before that.
    g_test_foreground = f.hwnd();
    const act: Act = .{ .win = .{ .hwnd = f.hwnd(), .exe = "x", .title = "t", .pid = 0 }, .start_ms = safety.nowMs() };
    try expectRefusedText(try clickPointRefusal(f.a(), act, .{ .x = -19985, .y = -19945 }, rid), "refused");
}

fn expectRefusedText(m: ?[]const u8, needle: []const u8) !void {
    const t = m orelse return error.ExpectedRefusal;
    if (std.mem.indexOf(u8, t, needle) == null) {
        std.debug.print("got: {s}\n", .{t});
        return error.TestUnexpectedResult;
    }
}
