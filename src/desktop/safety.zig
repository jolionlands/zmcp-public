//! Runtime actuation safety for zmcp-desktop (Z3), the Win32 side:
//!
//!   - the kill event, watched by a thread that latches `killed` the moment
//!     the host signals it (acts also poll it between injected chunks);
//!   - the workstation lock state (WTS session flags), failing closed;
//!   - user input: every INPUT zmcp-desktop and zmcp-computer send carries
//!     NAVA_INPUT_TAG (0x4E415641, "NAVA") in dwExtraInfo (computer/input.zig).
//!     Low-level keyboard and mouse hooks on their own message-pumping thread
//!     record the time of the last event that is NOT tagged automation: real
//!     hardware input (no LLKHF_INJECTED / LLMHF_INJECTED) and input injected
//!     by any other program alike, so a remote-control tool or another
//!     automation also stops us. Nava's own hook applies the same rule.
//!
//!     The in-flight window (the one exception): UI Automation itself injects
//!     an untagged key event (dwExtraInfo 0) to win foreground rights during
//!     some pattern calls (measured on 245: Invoke on a UWP Calculator
//!     button, SetFocus on a background window). So an INJECTED event without
//!     the tag counts as ours when it arrives while one of our UIA pattern
//!     calls (invoke, focus, set_value, select, expand, scroll_into_view,
//!     scroll) is in flight, or within 100 ms after it returns. That window
//!     does NOT cover typing, key presses or clicks (those are tagged), and
//!     hardware input always counts as the user's. Caveat: the on-screen
//!     keyboard (osk.exe, touch keyboard) and other assistive tools inject
//!     untagged input too, so a user typing on one inside that window is
//!     taken for UIA and does not pause us; outside it, it pauses as usual.
//!     Nava's own hook uses a matching window (B4). Before the hooks exist (and
//!     if they can't be installed), GetLastInputInfo stands in, with our own
//!     injections' time windows excluded.
//!
//! The hooks are installed on the first act of a session (never for
//! observe-only use) and only record a timestamp: they never block, alter or
//! log any input. Test binaries install neither the hooks nor the watcher.

const std = @import("std");
const builtin = @import("builtin");
const shared = @import("computer_shared");
const w = shared.win32;

const SYNCHRONIZE: u32 = 0x00100000;
const INFINITE: u32 = 0xFFFFFFFF;
const WAIT_OBJECT_0: u32 = 0;

extern "kernel32" fn OpenEventW(access: u32, inherit: w.BOOL, name: [*:0]const u16) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn WaitForSingleObject(h: w.HANDLE, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn GetTickCount() callconv(.winapi) u32;

pub fn nowMs() u64 {
    return GetTickCount64();
}

// ── kill event ──────────────────────────────────────────────────────────────

var g_killed = std.atomic.Value(bool).init(false);

/// True once the kill event has been seen signalled (latched for the life of
/// the process), or when it is signalled right now.
pub fn killed(name: ?[*:0]const u16) bool {
    if (g_killed.load(.acquire)) return true;
    const n = name orelse return false;
    if (eventSet(n)) {
        g_killed.store(true, .release);
        return true;
    }
    return false;
}

/// Tests only: clear the latch after a kill test.
pub fn resetKillLatchForTest() void {
    if (builtin.is_test) g_killed.store(false, .release);
}

const EVENT_MODIFY_STATE: u32 = 0x0002;
extern "kernel32" fn ResetEvent(h: w.HANDLE) callconv(.winapi) w.BOOL;

/// If the named event is signalled, reset it and return true (one signal is
/// consumed once). Used for --resume-event.
pub fn consumeEvent(name: [*:0]const u16) bool {
    const h = OpenEventW(SYNCHRONIZE | EVENT_MODIFY_STATE, 0, name) orelse return false;
    defer _ = w.CloseHandle(h);
    if (WaitForSingleObject(h, 0) != WAIT_OBJECT_0) return false;
    _ = ResetEvent(h);
    return true;
}

pub fn eventSet(name: [*:0]const u16) bool {
    const h = OpenEventW(SYNCHRONIZE, 0, name) orelse return false;
    defer _ = w.CloseHandle(h);
    return WaitForSingleObject(h, 0) == WAIT_OBJECT_0;
}

/// Watch the event on a thread: wait on it when it exists, else re-open it
/// every 100 ms. `name` must live for the life of the process.
pub fn startKillWatcher(name: [:0]const u16) void {
    if (builtin.is_test) return;
    const th = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, watch, .{name}) catch return;
    th.detach();
}

fn watch(name: [:0]const u16) void {
    while (!g_killed.load(.acquire)) {
        if (OpenEventW(SYNCHRONIZE, 0, name.ptr)) |h| {
            defer _ = w.CloseHandle(h);
            if (WaitForSingleObject(h, INFINITE) == WAIT_OBJECT_0) g_killed.store(true, .release);
            return;
        }
        w.sleepMs(100);
    }
}

// ── lock state ──────────────────────────────────────────────────────────────

const WTS_CURRENT_SESSION: u32 = 0xFFFFFFFF;
const WTSSessionInfoEx: c_int = 25;
const WTS_SESSIONSTATE_UNLOCK: i32 = 1;

extern "wtsapi32" fn WTSQuerySessionInformationW(server: ?w.HANDLE, session: u32, class: c_int, buf: *?[*]u8, bytes: *u32) callconv(.winapi) w.BOOL;
extern "wtsapi32" fn WTSFreeMemory(p: ?*anyopaque) callconv(.winapi) void;

/// WTSINFOEXW: DWORD Level; then the WTSINFOEX_LEVEL1_W union member, which
/// holds a LARGE_INTEGER, so it starts at offset 8: SessionId @8,
/// SessionState @12, SessionFlags @16.
pub fn sessionFlagsFromInfo(buf: []const u8) ?i32 {
    if (buf.len < 20) return null;
    if (std.mem.readInt(u32, buf[0..4], .little) != 1) return null;
    return std.mem.readInt(i32, buf[16..20], .little);
}

/// True when the session is locked, or when its state can't be read
/// (fail closed).
pub fn sessionLocked() bool {
    var p: ?[*]u8 = null;
    var n: u32 = 0;
    if (!w.ok(WTSQuerySessionInformationW(null, WTS_CURRENT_SESSION, WTSSessionInfoEx, &p, &n)) or p == null) return true;
    defer WTSFreeMemory(p);
    const flags = sessionFlagsFromInfo(p.?[0..n]) orelse return true;
    return flags != WTS_SESSIONSTATE_UNLOCK;
}

// ── real user input ─────────────────────────────────────────────────────────

const WH_KEYBOARD_LL: c_int = 13;
const WH_MOUSE_LL: c_int = 14;
const LLKHF_INJECTED: u32 = 0x10;
const LLMHF_INJECTED: u32 = 0x01;

const KBDLLHOOKSTRUCT = extern struct { vk: u32, scan: u32, flags: u32, time: u32, extra: usize };
const MSLLHOOKSTRUCT = extern struct { x: i32, y: i32, data: u32, flags: u32, time: u32, extra: usize };
const HOOKPROC = *const fn (code: c_int, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) isize;
const MSG = extern struct { hwnd: ?w.HWND, message: u32, wParam: w.WPARAM, lParam: w.LPARAM, time: u32, pt_x: i32, pt_y: i32, lPrivate: u32 };
const LASTINPUTINFO = extern struct { cb: u32 = @sizeOf(LASTINPUTINFO), time: u32 = 0 };

extern "user32" fn SetWindowsHookExW(id: c_int, proc: HOOKPROC, mod: ?*anyopaque, thread: u32) callconv(.winapi) ?*anyopaque;
extern "user32" fn CallNextHookEx(h: ?*anyopaque, code: c_int, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) isize;
extern "user32" fn GetMessageW(msg: *MSG, hwnd: ?w.HWND, min: u32, max: u32) callconv(.winapi) i32;
extern "user32" fn GetLastInputInfo(lii: *LASTINPUTINFO) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;

/// GetTickCount64 of the last event the hooks saw that was not ours; 0 = none.
var g_last_real = std.atomic.Value(u64).init(0);
var g_hooks = std.atomic.Value(u8).init(0); // 0 not started, 1 starting, 2 running, 3 failed
/// GetTickCount64 when the hooks started (GetLastInputInfo covers the time before).
var g_hooks_since: u64 = 0;

const NAVA_INPUT_TAG = shared.input.NAVA_INPUT_TAG;

/// Pure: an event is automation (ours or another Nava tool's) only when it
/// was injected AND carries NAVA_INPUT_TAG, or was injected while one of our
/// own UIA calls was running (`in_own_uia_call`). Everything else is the user.
pub fn isOwnEvent(injected: bool, extra: usize, in_own_uia_call: bool) bool {
    return injected and (extra == NAVA_INPUT_TAG or in_own_uia_call);
}

/// GetTickCount64 bounds of our current / last UIA act call (0 = none).
var g_uia_start = std.atomic.Value(u64).init(0);
var g_uia_end = std.atomic.Value(u64).init(0);
const uia_call_slack_ms: u64 = 100;

/// Bracket a UIA pattern call that may make UIA inject input.
pub fn ownUiaBegin() void {
    g_uia_end.store(std.math.maxInt(u64), .release);
    g_uia_start.store(GetTickCount64(), .release);
}

pub fn ownUiaEnd() void {
    g_uia_end.store(GetTickCount64(), .release);
}

/// Pure: is `now` inside [start, end + slack]?
pub fn inUiaWindow(now: u64, start: u64, end: u64) bool {
    return start != 0 and now >= start and now <= end +| uia_call_slack_ms;
}

fn inOwnUiaCall() bool {
    return inUiaWindow(GetTickCount64(), g_uia_start.load(.acquire), g_uia_end.load(.acquire));
}

/// Our own injections: [start, end] tick windows (GetTickCount), so
/// GetLastInputInfo's time can be told apart from ours.
var g_own_start: u32 = 0;
var g_own_end: u32 = 0;
var g_own_any = false;

/// Test seam: tests set the "last real input" directly.
pub var test_last_real: ?u64 = null;

/// `--debug-input`: the hooks print the first events they count as not ours
/// to stderr (kind, message, flags, extra; never key codes or positions).
pub var debug = false;
var g_debug_lines = std.atomic.Value(u32).init(0);

fn debugEvent(kind: []const u8, msg: w.WPARAM, flags: u32, extra: usize) void {
    if (!debug or g_debug_lines.fetchAdd(1, .monotonic) >= 40) return;
    std.debug.print("zmcp-desktop debug: other input {s} msg=0x{x} flags=0x{x} extra=0x{x} t={d}\n", .{ kind, msg, flags, extra, GetTickCount64() });
}

fn kbProc(code: c_int, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) isize {
    if (code >= 0) {
        const k: *const KBDLLHOOKSTRUCT = @ptrFromInt(@as(usize, @bitCast(lp)));
        if (!isOwnEvent(k.flags & LLKHF_INJECTED != 0, k.extra, inOwnUiaCall())) {
            g_last_real.store(GetTickCount64(), .release);
            debugEvent("key", wp, k.flags, k.extra);
        }
    }
    return CallNextHookEx(null, code, wp, lp);
}

fn msProc(code: c_int, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) isize {
    if (code >= 0) {
        const m: *const MSLLHOOKSTRUCT = @ptrFromInt(@as(usize, @bitCast(lp)));
        if (!isOwnEvent(m.flags & LLMHF_INJECTED != 0, m.extra, inOwnUiaCall())) {
            g_last_real.store(GetTickCount64(), .release);
            debugEvent("mouse", wp, m.flags, m.extra);
        }
    }
    return CallNextHookEx(null, code, wp, lp);
}

fn hookThread() void {
    const inst = GetModuleHandleW(null);
    const kb = SetWindowsHookExW(WH_KEYBOARD_LL, kbProc, inst, 0);
    const ms = SetWindowsHookExW(WH_MOUSE_LL, msProc, inst, 0);
    if (kb == null or ms == null) {
        g_hooks.store(3, .release);
        if (debug) std.debug.print("zmcp-desktop debug: input hooks failed; GetLastInputInfo only\n", .{});
        return; // GetLastInputInfo stays the only source
    }
    if (debug) std.debug.print("zmcp-desktop debug: input hooks running\n", .{});
    g_hooks_since = GetTickCount64();
    g_hooks.store(2, .release);
    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) > 0) {}
}

/// Install the input hooks once (first act of the session).
pub fn ensureInputWatch() void {
    if (builtin.is_test) return;
    if (g_hooks.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return;
    const th = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, hookThread, .{}) catch {
        g_hooks.store(3, .release);
        return;
    };
    th.detach();
    // Give the hooks a moment so the first act is already covered.
    var i: usize = 0;
    while (i < 50 and g_hooks.load(.acquire) == 1) : (i += 1) w.sleepMs(2);
}

pub fn hooksRunning() bool {
    return g_hooks.load(.acquire) == 2;
}

/// Bracket our own SendInput calls.
pub fn ownInputBegin() void {
    g_own_start = GetTickCount();
}

pub fn ownInputEnd() void {
    g_own_end = GetTickCount();
    g_own_any = true;
}

/// Slack after our last injected event during which GetLastInputInfo is
/// still attributed to us.
const own_slack_ms: u32 = 150;

/// Pure: is a GetLastInputInfo tick explained by our own injection window?
pub fn tickIsOwn(tick: u32, own_any: bool, own_start: u32, own_end: u32) bool {
    if (!own_any) return false;
    // Wrap-safe: tick within [own_start, own_end + slack].
    return tick -% own_start <= (own_end -% own_start) +% own_slack_ms;
}

/// GetTickCount64 of the last input that was not ours, or null when none
/// is known. With the hooks running, GetLastInputInfo only counts for the
/// time before they started (it can't tell whose input it saw).
pub fn lastRealInputMs() ?u64 {
    if (builtin.is_test) return test_last_real;
    const now64 = GetTickCount64();
    const hooked = hooksRunning();
    var best: u64 = if (hooked) g_last_real.load(.acquire) else 0;
    var lii: LASTINPUTINFO = .{};
    if (w.ok(GetLastInputInfo(&lii)) and !tickIsOwn(lii.time, g_own_any, g_own_start, g_own_end)) {
        const now32: u32 = @truncate(now64);
        const age: u64 = now32 -% lii.time;
        if (age <= now64) {
            const at = now64 - age;
            if (!hooked or at < g_hooks_since) best = @max(best, at);
        }
    }
    if (debug and best != 0 and now64 -| best < 2000)
        std.debug.print("zmcp-desktop debug: other input {d} ms ago (hooked={}, hook={d}, lii={d}, own=[{d},{d}])\n", .{ now64 -| best, hooked, g_last_real.load(.acquire), lii.time, g_own_start, g_own_end });
    return if (best == 0) null else best;
}

// ── tests ───────────────────────────────────────────────────────────────────

const t = std.testing;

test "session flags are read from WTSINFOEXW level 1 at offset 16" {
    var buf = [_]u8{0} ** 32;
    std.mem.writeInt(u32, buf[0..4], 1, .little);
    std.mem.writeInt(i32, buf[16..20], 1, .little);
    try t.expectEqual(@as(?i32, 1), sessionFlagsFromInfo(&buf));
    std.mem.writeInt(i32, buf[16..20], 0, .little);
    try t.expectEqual(@as(?i32, 0), sessionFlagsFromInfo(&buf));
    std.mem.writeInt(u32, buf[0..4], 2, .little);
    try t.expectEqual(@as(?i32, null), sessionFlagsFromInfo(&buf));
    try t.expectEqual(@as(?i32, null), sessionFlagsFromInfo(buf[0..8]));
}

test "this session is unlocked while the tests run" {
    try t.expect(!sessionLocked());
}

test "only injected events tagged NAVA_INPUT_TAG (or during our UIA call) are automation" {
    try t.expect(isOwnEvent(true, 0x4E415641, false));
    try t.expect(!isOwnEvent(false, 0x4E415641, false)); // hardware input can't carry the injected flag
    try t.expect(!isOwnEvent(true, 0, false)); // another program's SendInput
    try t.expect(!isOwnEvent(true, 0x4E415642, false));
    // UIA's own foreground-rights key during our Invoke/SetFocus: ours.
    try t.expect(isOwnEvent(true, 0, true));
    // The user's hardware input during our UIA call: still the user's.
    try t.expect(!isOwnEvent(false, 0, true));
    try t.expect(inUiaWindow(1000, 1000, 1200));
    try t.expect(inUiaWindow(1300, 1000, 1200));
    try t.expect(!inUiaWindow(1301, 1000, 1200));
    try t.expect(!inUiaWindow(999, 1000, 1200));
    try t.expect(inUiaWindow(5000, 1000, std.math.maxInt(u64))); // call still running
    try t.expect(!inUiaWindow(5000, 0, 0)); // no call yet
}

test "own-injection window attribution, wrap-safe" {
    try t.expect(!tickIsOwn(1000, false, 900, 1100));
    try t.expect(tickIsOwn(1000, true, 900, 1100));
    try t.expect(tickIsOwn(1200, true, 900, 1100)); // within the slack
    try t.expect(!tickIsOwn(1300, true, 900, 1100));
    try t.expect(!tickIsOwn(800, true, 900, 1100));
    // Across the 32-bit wrap.
    try t.expect(tickIsOwn(5, true, 0xFFFF_FFF0, 10));
    try t.expect(!tickIsOwn(0xFFFF_FF00, true, 0xFFFF_FFF0, 10));
}

test "the kill latch: unset, then set, stays set" {
    const CreateEventW = struct {
        extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual: w.BOOL, initial: w.BOOL, name: [*:0]const u16) callconv(.winapi) ?w.HANDLE;
        extern "kernel32" fn SetEvent(h: w.HANDLE) callconv(.winapi) w.BOOL;
        extern "kernel32" fn ResetEvent(h: w.HANDLE) callconv(.winapi) w.BOOL;
    };
    defer g_killed.store(false, .release);
    const name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\zmcp-desktop-kill-test-z3-latch");
    try t.expect(!killed(name));
    const h = CreateEventW.CreateEventW(null, 1, 0, name) orelse return error.CreateEventFailed;
    defer _ = w.CloseHandle(h);
    try t.expect(!killed(name));
    _ = CreateEventW.SetEvent(h);
    try t.expect(killed(name));
    _ = CreateEventW.ResetEvent(h);
    try t.expect(killed(name)); // latched
    try t.expect(killed(null));
}
