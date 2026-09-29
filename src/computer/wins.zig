//! Top-level window enumeration, matching and state changes.

const std = @import("std");
const builtin = @import("builtin");
const w = @import("win32.zig");
const match = @import("match.zig");
const integrity = @import("integrity.zig");

pub const Info = struct {
    hwnd: w.HWND,
    title: []const u8,
    pid: u32,
    process: []const u8,
    rect: w.RECT,
    visible: bool,
    minimized: bool,
    maximized: bool,
    active: bool,

    pub fn width(self: Info) i32 {
        return self.rect.right - self.rect.left;
    }
    pub fn height(self: Info) i32 {
        return self.rect.bottom - self.rect.top;
    }
};

const EnumCtx = struct {
    list: *std.ArrayList(w.HWND),
    allocator: std.mem.Allocator,
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
    const hr = w.DwmGetWindowAttribute(hwnd, w.DWMWA_CLOAKED, &cloaked, @sizeOf(u32));
    return hr == 0 and cloaked != 0;
}

pub fn windowTitle(allocator: std.mem.Allocator, hwnd: w.HWND) ![]u8 {
    const n = w.GetWindowTextLengthW(hwnd);
    if (n <= 0) return allocator.alloc(u8, 0);
    const buf = try allocator.alloc(u16, @as(usize, @intCast(n)) + 1);
    defer allocator.free(buf);
    const got = w.GetWindowTextW(hwnd, buf.ptr, n + 1);
    if (got <= 0) return allocator.alloc(u8, 0);
    return w.fromW(allocator, buf[0..@intCast(got)]);
}

/// Image base name without ".exe" (e.g. "msedge"), or "" when the process
/// can't be opened (elevated or protected).
pub fn processName(allocator: std.mem.Allocator, pid: u32) ![]u8 {
    const h = w.OpenProcess(w.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return allocator.alloc(u8, 0);
    defer _ = w.CloseHandle(h);
    var buf: [1024]u16 = undefined;
    var len: u32 = buf.len;
    if (!w.ok(w.QueryFullProcessImageNameW(h, 0, &buf, &len))) return allocator.alloc(u8, 0);
    const full = buf[0..len];
    var start: usize = 0;
    for (full, 0..) |c, i| if (c == '\\' or c == '/') {
        start = i + 1;
    };
    var name = full[start..];
    if (name.len > 4) {
        const ext = name[name.len - 4 ..];
        if (ext[0] == '.' and (ext[1] | 0x20) == 'e' and (ext[2] | 0x20) == 'x' and (ext[3] | 0x20) == 'e') name = name[0 .. name.len - 4];
    }
    return w.fromW(allocator, name);
}

pub fn infoFor(allocator: std.mem.Allocator, hwnd: w.HWND, fg: ?w.HWND) !Info {
    var pid: u32 = 0;
    _ = w.GetWindowThreadProcessId(hwnd, &pid);
    var rc: w.RECT = std.mem.zeroes(w.RECT);
    _ = w.GetWindowRect(hwnd, &rc);
    return .{
        .hwnd = hwnd,
        .title = try windowTitle(allocator, hwnd),
        .pid = pid,
        .process = try processName(allocator, pid),
        .rect = rc,
        .visible = w.ok(w.IsWindowVisible(hwnd)),
        .minimized = w.ok(w.IsIconic(hwnd)),
        .maximized = w.ok(w.IsZoomed(hwnd)),
        .active = fg != null and fg.? == hwnd,
    };
}

/// Visible, titled, uncloaked top-level windows in Z-order (topmost first).
/// Cloaked windows are the invisible UWP frames and windows on other
/// virtual desktops; listing them only misleads the model.
pub fn list(allocator: std.mem.Allocator) ![]Info {
    var hwnds: std.ArrayList(w.HWND) = .empty;
    defer hwnds.deinit(allocator);
    var ctx: EnumCtx = .{ .list = &hwnds, .allocator = allocator };
    _ = w.EnumWindows(enumProc, @bitCast(@intFromPtr(&ctx)));
    if (ctx.failed) return error.OutOfMemory;
    const fg = w.GetForegroundWindow();
    var out: std.ArrayList(Info) = .empty;
    for (hwnds.items) |h| {
        if (!w.ok(w.IsWindowVisible(h))) continue;
        if (w.GetWindowTextLengthW(h) <= 0) continue;
        if (isCloaked(h)) continue;
        try out.append(allocator, try infoFor(allocator, h, fg));
    }
    return out.toOwnedSlice(allocator);
}

pub fn active(allocator: std.mem.Allocator) !?Info {
    const fg = w.GetForegroundWindow() orelse return null;
    return try infoFor(allocator, fg, fg);
}

// ── matching ────────────────────────────────────────────────────────────────

/// computer_control semantics: regex (first hit in Z-order) or the best
/// fuzzy partial_ratio at or above `threshold` (ties → first).
pub fn findByTitle(allocator: std.mem.Allocator, windows: []const Info, pattern: []const u8, use_regex: bool, threshold: i64) !?Info {
    if (pattern.len == 0) return null;
    if (use_regex) {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const re = try match.Regex.compile(arena, pattern);
        for (windows) |win| if (try re.search(arena, win.title)) return win;
        return null;
    }
    var best: ?Info = null;
    var best_score: i64 = -1;
    for (windows) |win| {
        const s: i64 = try match.score(allocator, pattern, win.title);
        if (s > best_score) {
            best_score = s;
            best = win;
        }
    }
    if (best != null and best_score >= threshold) return best;
    return null;
}

/// clawdcursor semantics: processName (case-insensitive, ".exe" optional),
/// processId, and/or title substring (case-insensitive); all given fields
/// must match. Topmost match wins.
pub const Query = struct {
    process_name: ?[]const u8 = null,
    pid: ?u32 = null,
    title: ?[]const u8 = null,

    pub fn isEmpty(self: Query) bool {
        return self.process_name == null and self.pid == null and self.title == null;
    }
};

fn stripExe(s: []const u8) []const u8 {
    if (s.len > 4 and std.ascii.eqlIgnoreCase(s[s.len - 4 ..], ".exe")) return s[0 .. s.len - 4];
    return s;
}

pub fn matchesQuery(win: Info, q: Query) bool {
    if (q.pid) |pid| if (win.pid != pid) return false;
    if (q.process_name) |pn| if (!std.ascii.eqlIgnoreCase(stripExe(pn), win.process)) return false;
    if (q.title) |tt| if (std.ascii.findIgnoreCase(win.title, tt) == null) return false;
    return true;
}

pub fn findByQuery(windows: []const Info, q: Query) ?Info {
    for (windows) |win| if (matchesQuery(win, q)) return win;
    return null;
}

// ── state changes (never from tests) ────────────────────────────────────────

pub var disabled: bool = false;

pub const ActionError = error{ WindowActionsDisabled, WindowGone, TargetElevated };

fn guard(hwnd: w.HWND) ActionError!void {
    if (builtin.is_test or disabled) return error.WindowActionsDisabled;
    if (!w.ok(w.IsWindow(hwnd))) return error.WindowGone;
    // UIPI: activate/move/close of a higher-integrity window fails or is
    // ignored; refuse up front instead of reporting a false success.
    try integrity.checkHwnd(hwnd);
}

/// Bring a window to the foreground. Windows only lets the foreground
/// thread's input queue hand over focus, so attach to it for the call.
/// Returns whether the window really ended up in front.
pub fn activate(hwnd: w.HWND) ActionError!bool {
    try guard(hwnd);
    if (w.ok(w.IsIconic(hwnd))) _ = w.ShowWindow(hwnd, w.SW_RESTORE);
    const me = w.GetCurrentThreadId();
    const fg = w.GetForegroundWindow();
    const fg_thread: u32 = if (fg) |f| w.GetWindowThreadProcessId(f, null) else 0;
    const attached = fg_thread != 0 and fg_thread != me and w.ok(w.AttachThreadInput(me, fg_thread, 1));
    defer if (attached) {
        _ = w.AttachThreadInput(me, fg_thread, 0);
    };
    _ = w.BringWindowToTop(hwnd);
    _ = w.SetForegroundWindow(hwnd);
    var tries: u32 = 0;
    while (tries < 10) : (tries += 1) {
        if (w.GetForegroundWindow() == hwnd) return true;
        w.sleepMs(20);
    }
    return w.GetForegroundWindow() == hwnd;
}

pub const ShowState = enum { maximize, minimize, restore };

pub fn setState(hwnd: w.HWND, s: ShowState) ActionError!void {
    try guard(hwnd);
    _ = w.ShowWindow(hwnd, switch (s) {
        .maximize => w.SW_MAXIMIZE,
        .minimize => w.SW_MINIMIZE,
        .restore => w.SW_RESTORE,
    });
}

/// Polite WM_CLOSE; the app may prompt or refuse.
pub fn close(hwnd: w.HWND) ActionError!bool {
    try guard(hwnd);
    return w.ok(w.PostMessageW(hwnd, w.WM_CLOSE, 0, 0));
}

/// Move/resize; null fields keep the current value. A maximized window is
/// restored first, otherwise the new bounds would be ignored.
pub fn setBounds(hwnd: w.HWND, x: ?i32, y: ?i32, width: ?i32, height: ?i32) ActionError!w.RECT {
    try guard(hwnd);
    if (w.ok(w.IsZoomed(hwnd)) or w.ok(w.IsIconic(hwnd))) _ = w.ShowWindow(hwnd, w.SW_RESTORE);
    var rc: w.RECT = std.mem.zeroes(w.RECT);
    _ = w.GetWindowRect(hwnd, &rc);
    const nx = x orelse rc.left;
    const ny = y orelse rc.top;
    const nw = width orelse (rc.right - rc.left);
    const nh = height orelse (rc.bottom - rc.top);
    _ = w.SetWindowPos(hwnd, null, nx, ny, nw, nh, w.SWP_NOZORDER | w.SWP_NOACTIVATE);
    _ = w.GetWindowRect(hwnd, &rc);
    return rc;
}

// ── monitors ────────────────────────────────────────────────────────────────

pub const Display = struct {
    index: usize,
    name: []const u8,
    primary: bool,
    bounds: w.RECT,
    work: w.RECT,
    dpi: u32,
};

const MonCtx = struct {
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Display),
    failed: bool = false,
};

fn monProc(hmon: w.HMONITOR, _: ?w.HDC, _: *w.RECT, lparam: w.LPARAM) callconv(.winapi) w.BOOL {
    const ctx: *MonCtx = @ptrFromInt(@as(usize, @bitCast(lparam)));
    var mi: w.MONITORINFOEXW = .{};
    if (!w.ok(w.GetMonitorInfoW(hmon, &mi))) return 1;
    var dx: u32 = 96;
    var dy: u32 = 96;
    if (w.GetDpiForMonitor(hmon, w.MDT_EFFECTIVE_DPI, &dx, &dy) != 0) dx = 96;
    const nlen = std.mem.indexOfScalar(u16, &mi.szDevice, 0) orelse mi.szDevice.len;
    const name = w.fromW(ctx.allocator, mi.szDevice[0..nlen]) catch {
        ctx.failed = true;
        return 0;
    };
    ctx.list.append(ctx.allocator, .{
        .index = ctx.list.items.len,
        .name = name,
        .primary = mi.dwFlags & w.MONITORINFOF_PRIMARY != 0,
        .bounds = mi.rcMonitor,
        .work = mi.rcWork,
        .dpi = dx,
    }) catch {
        ctx.failed = true;
        return 0;
    };
    return 1;
}

pub fn displays(allocator: std.mem.Allocator) ![]Display {
    var out: std.ArrayList(Display) = .empty;
    var ctx: MonCtx = .{ .allocator = allocator, .list = &out };
    _ = w.EnumDisplayMonitors(null, null, monProc, @bitCast(@intFromPtr(&ctx)));
    if (ctx.failed) return error.OutOfMemory;
    return out.toOwnedSlice(allocator);
}

// ── tests (pure matching only; no real windows are touched) ─────────────────

const t = std.testing;

fn fakeWin(title: []const u8, process: []const u8, pid: u32) Info {
    return .{
        .hwnd = @ptrFromInt(0x1000 + @as(usize, pid)),
        .title = title,
        .pid = pid,
        .process = process,
        .rect = std.mem.zeroes(w.RECT),
        .visible = true,
        .minimized = false,
        .maximized = false,
        .active = false,
    };
}

test "title matching: fuzzy threshold and regex" {
    const wins = [_]Info{
        fakeWin("Untitled - Notepad", "Notepad", 1),
        fakeWin("GitHub - Google Chrome", "chrome", 2),
        fakeWin("Calculator", "CalculatorApp", 3),
    };
    const a = t.allocator;
    try t.expectEqual(@as(u32, 2), (try findByTitle(a, &wins, "chrome", false, 60)).?.pid);
    try t.expectEqual(@as(u32, 3), (try findByTitle(a, &wins, "calc", false, 60)).?.pid);
    try t.expect((try findByTitle(a, &wins, "qqqqqq", false, 60)) == null);
    try t.expectEqual(@as(u32, 1), (try findByTitle(a, &wins, "notepad$", true, 0)).?.pid);
    try t.expect((try findByTitle(a, &wins, "^notepad", true, 0)) == null);
}

test "query matching: process name, pid, title substring" {
    const wins = [_]Info{
        fakeWin("Inbox - Outlook", "olk", 10),
        fakeWin("Untitled - Notepad", "Notepad", 11),
    };
    try t.expectEqual(@as(u32, 11), findByQuery(&wins, .{ .process_name = "notepad.exe" }).?.pid);
    try t.expectEqual(@as(u32, 10), findByQuery(&wins, .{ .title = "OUTLOOK" }).?.pid);
    try t.expectEqual(@as(u32, 10), findByQuery(&wins, .{ .pid = 10 }).?.pid);
    try t.expect(findByQuery(&wins, .{ .pid = 10, .process_name = "notepad" }) == null);
}

test "window state changes are refused inside tests" {
    try t.expectError(error.WindowActionsDisabled, activate(@ptrFromInt(0x1234)));
    try t.expectError(error.WindowActionsDisabled, close(@ptrFromInt(0x1234)));
}
