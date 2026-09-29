//! Test fixture: a window this test process creates itself, on its own
//! message-pumping thread, so UI Automation has something known to read
//! without touching any other app's window.
//!
//! The window is never shown on screen: `mode = .hidden` never sets
//! WS_VISIBLE; `mode = .offscreen` shows a no-activate tool window far
//! outside every monitor (UIA's Win32 proxy skips the children of hidden
//! windows, so the full-tree tests need it).

const std = @import("std");

const HWND = *anyopaque;
const HINSTANCE = *anyopaque;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const ATOM = u16;

const WNDPROC = *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?HINSTANCE,
    hIcon: ?*anyopaque = null,
    hCursor: ?*anyopaque = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?*anyopaque = null,
};
const MSG = extern struct { hwnd: ?HWND, message: u32, wParam: WPARAM, lParam: LPARAM, time: u32, pt_x: i32, pt_y: i32, lPrivate: u32 };

extern "user32" fn RegisterClassExW(wc: *const WNDCLASSEXW) callconv(.winapi) ATOM;
extern "user32" fn CreateWindowExW(ex: u32, class: [*:0]const u16, title: [*:0]const u16, style: u32, x: i32, y: i32, w: i32, h: i32, parent: ?HWND, menu: ?*anyopaque, inst: ?HINSTANCE, param: ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn DefWindowProcW(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn GetMessageW(msg: *MSG, hwnd: ?HWND, min: u32, max: u32) callconv(.winapi) i32;
extern "user32" fn TranslateMessage(msg: *const MSG) callconv(.winapi) i32;
extern "user32" fn DispatchMessageW(msg: *const MSG) callconv(.winapi) LRESULT;
extern "user32" fn PostMessageW(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) callconv(.winapi) i32;
extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) i32;
extern "user32" fn PostQuitMessage(code: i32) callconv(.winapi) void;
extern "user32" fn SetWindowPos(hwnd: HWND, after: ?HWND, x: i32, y: i32, cx: i32, cy: i32, flags: u32) callconv(.winapi) i32;
extern "user32" fn SetLayeredWindowAttributes(hwnd: HWND, key: u32, alpha: u8, flags: u32) callconv(.winapi) i32;
extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?HINSTANCE;
extern "user32" fn GetDlgItem(hwnd: HWND, id: i32) callconv(.winapi) ?HWND;
extern "user32" fn GetWindowTextW(hwnd: HWND, buf: [*]u16, n: i32) callconv(.winapi) i32;
extern "user32" fn SetWindowTextW(hwnd: HWND, text: [*:0]const u16) callconv(.winapi) i32;
extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;

const WS_OVERLAPPED: u32 = 0x00000000;
const WS_CAPTION: u32 = 0x00C00000;
const WS_CHILD: u32 = 0x40000000;
const WS_VISIBLE: u32 = 0x10000000;
const WS_POPUP: u32 = 0x80000000;
const WS_TABSTOP: u32 = 0x00010000;
const WS_EX_TOOLWINDOW: u32 = 0x00000080;
const WS_EX_NOACTIVATE: u32 = 0x08000000;
const WS_EX_LAYERED: u32 = 0x00080000;
const LWA_ALPHA: u32 = 0x2;
const ES_PASSWORD: u32 = 0x0020;
const ES_AUTOHSCROLL: u32 = 0x0080;
const BS_PUSHBUTTON: u32 = 0x0;
const WM_CLOSE: u32 = 0x0010;
const WM_DESTROY: u32 = 0x0002;
const WM_COMMAND: u32 = 0x0111;
const BN_CLICKED: u16 = 0;
const SWP_NOACTIVATE: u32 = 0x0010;
const SWP_NOZORDER: u32 = 0x0004;
const SWP_SHOWWINDOW: u32 = 0x0040;
const SWP_NOSIZE: u32 = 0x0001;

pub const Mode = enum { hidden, offscreen };

pub const password_text = "hunter2-zmcp-secret";
pub const pay_button = "Buy now";
pub const id_password = 101;
pub const id_edit = 102;
pub const id_send = 103;
pub const id_pay = 105;
/// A RichEdit (msftedit RICHEDIT50W): a text field with a TextPattern, the
/// stand-in for a contenteditable composer. And a password RichEdit.
pub const id_rich = 106;
pub const id_rich_password = 107;
pub const rich_class = "RICHEDIT50W";
pub const rich_text = "rich composer draft \u{e9}";
pub const rich_password_text = "rich-secret-zmcp-9731";
/// A RichEdit holding more than zmcp's 500-char text cap.
pub const id_rich_long = 108;
pub const rich_long_text = "L" ** 600;

/// BN_CLICKED counts for the Send and "Buy now" buttons (all test windows).
pub var send_clicks = std.atomic.Value(u32).init(0);
pub var pay_clicks = std.atomic.Value(u32).init(0);
pub const edit_text = "hello from the zmcp test";

fn L(comptime s: []const u8) [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

fn wndProc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
        WM_CLOSE => {
            _ = DestroyWindow(hwnd);
            return 0;
        },
        WM_DESTROY => {
            PostQuitMessage(0);
            return 0;
        },
        WM_COMMAND => {
            if (@as(u16, @truncate(wp >> 16)) == BN_CLICKED) switch (@as(u16, @truncate(wp))) {
                id_send => _ = send_clicks.fetchAdd(1, .acq_rel),
                id_pay => _ = pay_clicks.fetchAdd(1, .acq_rel),
                else => {},
            };
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wp, lp),
    }
}

var class_registered = std.atomic.Value(bool).init(false);

pub const TestWindow = struct {
    thread: std.Thread,
    hwnd: HWND,

    pub fn start(mode: Mode, extra_buttons: usize) !TestWindow {
        var st: Start = .{ .mode = mode, .extra = extra_buttons };
        const th = try std.Thread.spawn(.{}, run, .{&st});
        while (!st.done.load(.acquire)) std.Thread.yield() catch {};
        const h = st.hwnd orelse {
            th.join();
            return error.CreateWindowFailed;
        };
        return .{ .thread = th, .hwnd = h };
    }

    /// The text of a child control (UTF-8 into `buf`).
    pub fn childText(self: TestWindow, id: i32, buf: []u8) []const u8 {
        const child = GetDlgItem(self.hwnd, id) orelse return "";
        var wbuf: [512]u16 = undefined;
        const n = GetWindowTextW(child, &wbuf, wbuf.len);
        if (n <= 0) return "";
        const len = std.unicode.utf16LeToUtf8(buf, wbuf[0..@intCast(n)]) catch return "";
        return buf[0..len];
    }

    pub fn stop(self: TestWindow) void {
        _ = PostMessageW(self.hwnd, WM_CLOSE, 0, 0);
        self.thread.join();
    }
};

const Start = struct {
    mode: Mode,
    extra: usize,
    hwnd: ?HWND = null,
    done: std.atomic.Value(bool) = .init(false),
};

fn run(st: *Start) void {
    const inst = GetModuleHandleW(null);
    const class = L("zmcp-desktop-test-window");
    if (!class_registered.swap(true, .acq_rel)) {
        const wc: WNDCLASSEXW = .{ .lpfnWndProc = wndProc, .hInstance = inst, .lpszClassName = class };
        _ = RegisterClassExW(&wc);
    }
    const ex: u32 = if (st.mode == .offscreen) WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED else 0;
    const style: u32 = if (st.mode == .offscreen) WS_POPUP | WS_CAPTION else WS_OVERLAPPED | WS_CAPTION;
    const top = CreateWindowExW(ex, class, L("zmcp desktop test window"), style, -20000, -20000, 640, 480, null, null, inst, null) orelse {
        st.done.store(true, .release);
        return;
    };
    const cs = WS_CHILD | WS_VISIBLE | WS_TABSTOP;
    _ = CreateWindowExW(0, L("EDIT"), L(password_text), cs | ES_PASSWORD | ES_AUTOHSCROLL, 10, 10, 200, 24, top, @ptrFromInt(101), inst, null);
    _ = CreateWindowExW(0, L("EDIT"), L(edit_text), cs | ES_AUTOHSCROLL, 10, 40, 200, 24, top, @ptrFromInt(102), inst, null);
    _ = CreateWindowExW(0, L("BUTTON"), L("Send"), cs | BS_PUSHBUTTON, 10, 70, 80, 24, top, @ptrFromInt(103), inst, null);
    _ = CreateWindowExW(0, L("STATIC"), L("Alex Smith"), WS_CHILD | WS_VISIBLE, 10, 100, 200, 20, top, @ptrFromInt(104), inst, null);
    _ = CreateWindowExW(0, L("BUTTON"), L(pay_button), cs | BS_PUSHBUTTON, 100, 70, 80, 24, top, @ptrFromInt(id_pay), inst, null);
    if (LoadLibraryW(L("msftedit.dll")) != null) {
        _ = CreateWindowExW(0, L(rich_class), L(rich_text), cs, 10, 130, 200, 24, top, @ptrFromInt(id_rich), inst, null);
        _ = CreateWindowExW(0, L(rich_class), L(rich_password_text), cs | ES_PASSWORD, 10, 160, 200, 24, top, @ptrFromInt(id_rich_password), inst, null);
        const long = CreateWindowExW(0, L(rich_class), L(""), cs, 10, 190, 200, 24, top, @ptrFromInt(id_rich_long), inst, null);
        if (long) |h| {
            var buf: [rich_long_text.len + 1]u16 = undefined;
            for (buf[0..rich_long_text.len], rich_long_text) |*d, c| d.* = c;
            buf[rich_long_text.len] = 0;
            _ = SetWindowTextW(h, buf[0..rich_long_text.len :0]);
        }
    }
    var i: usize = 0;
    while (i < st.extra) : (i += 1) {
        const x: i32 = 220 + @as(i32, @intCast(i % 10)) * 40;
        const y: i32 = 10 + @as(i32, @intCast(i / 10)) * 20;
        _ = CreateWindowExW(0, L("BUTTON"), L("b"), cs | BS_PUSHBUTTON, x, y, 38, 18, top, @ptrFromInt(200 + i), inst, null);
    }
    if (st.mode == .offscreen) {
        // Shown (so UIA exposes the children) but fully transparent, far off
        // every monitor, never activated, and a tool window (no taskbar/Alt+Tab entry).
        _ = SetLayeredWindowAttributes(top, 0, 0, LWA_ALPHA);
        _ = SetWindowPos(top, null, -20000, -20000, 0, 0, SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOSIZE | SWP_SHOWWINDOW);
    }
    st.hwnd = top;
    st.done.store(true, .release);

    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) > 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
}
