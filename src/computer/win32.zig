//! Hand-declared Win32 surface for zmcp-computer.
//!
//! Zig 0.16's std.os.windows no longer carries user32/gdi32/shell32, so every
//! function and struct used by the server is declared here. Struct layouts are
//! checked at comptime for 64-bit Windows (x86_64 and aarch64 share the LLP64
//! ABI, so the sizes are identical on both).

const std = @import("std");
const builtin = @import("builtin");

pub const BOOL = c_int;
pub const HANDLE = *anyopaque;
pub const HWND = *anyopaque;
pub const HDC = *anyopaque;
pub const HGDIOBJ = *anyopaque;
pub const HBITMAP = *anyopaque;
pub const HMONITOR = *anyopaque;
pub const HGLOBAL = *anyopaque;
pub const HINSTANCE = *anyopaque;
pub const HFONT = *anyopaque;
pub const LPARAM = isize;
pub const WPARAM = usize;

pub const POINT = extern struct { x: i32, y: i32 };
pub const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

// ── SendInput ───────────────────────────────────────────────────────────────

pub const INPUT_MOUSE: u32 = 0;
pub const INPUT_KEYBOARD: u32 = 1;

pub const MOUSEEVENTF_MOVE: u32 = 0x0001;
pub const MOUSEEVENTF_LEFTDOWN: u32 = 0x0002;
pub const MOUSEEVENTF_LEFTUP: u32 = 0x0004;
pub const MOUSEEVENTF_RIGHTDOWN: u32 = 0x0008;
pub const MOUSEEVENTF_RIGHTUP: u32 = 0x0010;
pub const MOUSEEVENTF_MIDDLEDOWN: u32 = 0x0020;
pub const MOUSEEVENTF_MIDDLEUP: u32 = 0x0040;
pub const MOUSEEVENTF_WHEEL: u32 = 0x0800;
pub const MOUSEEVENTF_HWHEEL: u32 = 0x1000;
pub const MOUSEEVENTF_VIRTUALDESK: u32 = 0x4000;
pub const MOUSEEVENTF_ABSOLUTE: u32 = 0x8000;
pub const WHEEL_DELTA: i32 = 120;

pub const KEYEVENTF_EXTENDEDKEY: u32 = 0x0001;
pub const KEYEVENTF_KEYUP: u32 = 0x0002;
pub const KEYEVENTF_UNICODE: u32 = 0x0004;

pub const MOUSEINPUT = extern struct {
    dx: i32 = 0,
    dy: i32 = 0,
    mouseData: u32 = 0,
    dwFlags: u32 = 0,
    time: u32 = 0,
    dwExtraInfo: usize = 0,
};

pub const KEYBDINPUT = extern struct {
    wVk: u16 = 0,
    wScan: u16 = 0,
    dwFlags: u32 = 0,
    time: u32 = 0,
    dwExtraInfo: usize = 0,
};

pub const HARDWAREINPUT = extern struct {
    uMsg: u32 = 0,
    wParamL: u16 = 0,
    wParamH: u16 = 0,
};

/// `INPUT` is `{ DWORD type; union { MOUSEINPUT; KEYBDINPUT; HARDWAREINPUT; } }`.
/// The union holds a ULONG_PTR, so on 64-bit it is 8-aligned and starts at
/// offset 8; the whole struct is 40 bytes. `SendInput` rejects any other
/// `cbSize`, so a wrong layout fails loudly rather than injecting garbage.
pub const INPUT = extern struct {
    type: u32,
    u: extern union {
        mi: MOUSEINPUT,
        ki: KEYBDINPUT,
        hi: HARDWAREINPUT,
    },
};

comptime {
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(MOUSEINPUT) == 32);
        std.debug.assert(@sizeOf(KEYBDINPUT) == 24);
        std.debug.assert(@sizeOf(HARDWAREINPUT) == 8);
        std.debug.assert(@sizeOf(INPUT) == 40);
        std.debug.assert(@offsetOf(INPUT, "u") == 8);
        std.debug.assert(@offsetOf(MOUSEINPUT, "dwExtraInfo") == 24);
        std.debug.assert(@offsetOf(KEYBDINPUT, "dwExtraInfo") == 16);
    } else {
        std.debug.assert(@sizeOf(INPUT) == 28);
    }
    std.debug.assert(@sizeOf(POINT) == 8);
    std.debug.assert(@sizeOf(RECT) == 16);
}

// ── GDI ─────────────────────────────────────────────────────────────────────

pub const BITMAPINFOHEADER = extern struct {
    biSize: u32 = @sizeOf(BITMAPINFOHEADER),
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: u32 = 0, // BI_RGB
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};

pub const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]u32 = .{0},
};

comptime {
    std.debug.assert(@sizeOf(BITMAPINFOHEADER) == 40);
}

pub const SRCCOPY: u32 = 0x00CC0020;
pub const CAPTUREBLT: u32 = 0x40000000;
pub const DIB_RGB_COLORS: u32 = 0;
pub const PW_RENDERFULLCONTENT: u32 = 0x00000002;

// ── Monitors ────────────────────────────────────────────────────────────────

pub const MONITORINFOEXW = extern struct {
    cbSize: u32 = @sizeOf(MONITORINFOEXW),
    rcMonitor: RECT = std.mem.zeroes(RECT),
    rcWork: RECT = std.mem.zeroes(RECT),
    dwFlags: u32 = 0,
    szDevice: [32]u16 = std.mem.zeroes([32]u16),
};

comptime {
    std.debug.assert(@sizeOf(MONITORINFOEXW) == 104);
}

pub const MONITORINFOF_PRIMARY: u32 = 1;
pub const MDT_EFFECTIVE_DPI: u32 = 0;

// ── System metrics / DPI ────────────────────────────────────────────────────

pub const SM_CXSCREEN: c_int = 0;
pub const SM_CYSCREEN: c_int = 1;
pub const SM_XVIRTUALSCREEN: c_int = 76;
pub const SM_YVIRTUALSCREEN: c_int = 77;
pub const SM_CXVIRTUALSCREEN: c_int = 78;
pub const SM_CYVIRTUALSCREEN: c_int = 79;
pub const SM_CMONITORS: c_int = 80;

/// DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 is the pseudo-handle -4.
pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;

// ── Windows ─────────────────────────────────────────────────────────────────

pub const SW_SHOWNORMAL: c_int = 1;
pub const SW_MAXIMIZE: c_int = 3;
pub const SW_MINIMIZE: c_int = 6;
pub const SW_RESTORE: c_int = 9;

pub const WM_CLOSE: u32 = 0x0010;

pub const SWP_NOSIZE: u32 = 0x0001;
pub const SWP_NOMOVE: u32 = 0x0002;
pub const SWP_NOZORDER: u32 = 0x0004;
pub const SWP_NOACTIVATE: u32 = 0x0010;

pub const GWL_EXSTYLE: c_int = -20;
pub const WS_EX_TOOLWINDOW: isize = 0x00000080;
pub const GW_OWNER: u32 = 4;
pub const DWMWA_CLOAKED: u32 = 14;
pub const DWMWA_EXTENDED_FRAME_BOUNDS: u32 = 9;

pub const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;

pub const MAPVK_VK_TO_VSC: u32 = 0;

// ── Clipboard / memory ──────────────────────────────────────────────────────

pub const CF_UNICODETEXT: u32 = 13;
pub const GMEM_MOVEABLE: u32 = 0x0002;

// ── Files ───────────────────────────────────────────────────────────────────

pub const GENERIC_WRITE: u32 = 0x40000000;
pub const CREATE_ALWAYS: u32 = 2;
pub const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;

pub const SYSTEMTIME = extern struct {
    wYear: u16,
    wMonth: u16,
    wDayOfWeek: u16,
    wDay: u16,
    wHour: u16,
    wMinute: u16,
    wSecond: u16,
    wMilliseconds: u16,
};

pub const TIME_ZONE_INFORMATION = extern struct {
    Bias: i32,
    StandardName: [32]u16,
    StandardDate: SYSTEMTIME,
    StandardBias: i32,
    DaylightName: [32]u16,
    DaylightDate: SYSTEMTIME,
    DaylightBias: i32,
};

pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

/// FOLDERID_Downloads {374DE290-123F-4565-9164-39C4925E467B}
pub const FOLDERID_Downloads: GUID = .{
    .Data1 = 0x374DE290,
    .Data2 = 0x123F,
    .Data3 = 0x4565,
    .Data4 = .{ 0x91, 0x64, 0x39, 0xC4, 0x92, 0x5E, 0x46, 0x7B },
};

pub const WNDENUMPROC = *const fn (HWND, LPARAM) callconv(.winapi) BOOL;
pub const MONITORENUMPROC = *const fn (HMONITOR, ?HDC, *RECT, LPARAM) callconv(.winapi) BOOL;

// ── user32 ──────────────────────────────────────────────────────────────────

pub extern "user32" fn SendInput(cInputs: u32, pInputs: [*]const INPUT, cbSize: c_int) callconv(.winapi) u32;
pub extern "user32" fn GetSystemMetrics(nIndex: c_int) callconv(.winapi) c_int;
pub extern "user32" fn SetProcessDpiAwarenessContext(value: isize) callconv(.winapi) BOOL;
pub extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn SetCursorPos(x: c_int, y: c_int) callconv(.winapi) BOOL;
pub extern "user32" fn MapVirtualKeyW(uCode: u32, uMapType: u32) callconv(.winapi) u32;
pub extern "user32" fn VkKeyScanW(ch: u16) callconv(.winapi) i16;

pub extern "user32" fn EnumWindows(lpEnumFunc: WNDENUMPROC, lParam: LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowTextW(hWnd: HWND, lpString: [*]u16, nMaxCount: c_int) callconv(.winapi) c_int;
pub extern "user32" fn GetWindowTextLengthW(hWnd: HWND) callconv(.winapi) c_int;
pub extern "user32" fn IsWindow(hWnd: ?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsWindowVisible(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsIconic(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsZoomed(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
pub extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn BringWindowToTop(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: c_int) callconv(.winapi) BOOL;
pub extern "user32" fn PostMessageW(hWnd: HWND, Msg: u32, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPos(hWnd: HWND, hWndInsertAfter: ?HWND, X: c_int, Y: c_int, cx: c_int, cy: c_int, uFlags: u32) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowThreadProcessId(hWnd: HWND, lpdwProcessId: ?*u32) callconv(.winapi) u32;
pub extern "user32" fn AttachThreadInput(idAttach: u32, idAttachTo: u32, fAttach: BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: c_int) callconv(.winapi) isize;
pub extern "user32" fn GetWindow(hWnd: HWND, uCmd: u32) callconv(.winapi) ?HWND;

pub extern "user32" fn EnumDisplayMonitors(hdc: ?HDC, lprcClip: ?*const RECT, lpfnEnum: MONITORENUMPROC, dwData: LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn GetMonitorInfoW(hMonitor: HMONITOR, lpmi: *MONITORINFOEXW) callconv(.winapi) BOOL;

pub extern "user32" fn GetDC(hWnd: ?HWND) callconv(.winapi) ?HDC;
pub extern "user32" fn ReleaseDC(hWnd: ?HWND, hDC: HDC) callconv(.winapi) c_int;
pub extern "user32" fn PrintWindow(hwnd: HWND, hdcBlt: HDC, nFlags: u32) callconv(.winapi) BOOL;

pub extern "user32" fn OpenClipboard(hWndNewOwner: ?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn GetClipboardData(uFormat: u32) callconv(.winapi) ?HANDLE;
pub extern "user32" fn SetClipboardData(uFormat: u32, hMem: ?HANDLE) callconv(.winapi) ?HANDLE;

// ── gdi32 ───────────────────────────────────────────────────────────────────

pub extern "gdi32" fn CreateCompatibleDC(hdc: ?HDC) callconv(.winapi) ?HDC;
pub extern "gdi32" fn DeleteDC(hdc: HDC) callconv(.winapi) BOOL;
pub extern "gdi32" fn CreateDIBSection(hdc: ?HDC, pbmi: *const BITMAPINFO, usage: u32, ppvBits: *?*anyopaque, hSection: ?HANDLE, offset: u32) callconv(.winapi) ?HBITMAP;
pub extern "gdi32" fn SelectObject(hdc: HDC, h: HGDIOBJ) callconv(.winapi) ?HGDIOBJ;
pub extern "gdi32" fn DeleteObject(ho: HGDIOBJ) callconv(.winapi) BOOL;
pub extern "gdi32" fn BitBlt(hdc: HDC, x: c_int, y: c_int, cx: c_int, cy: c_int, hdcSrc: HDC, x1: c_int, y1: c_int, rop: u32) callconv(.winapi) BOOL;
pub extern "gdi32" fn GdiFlush() callconv(.winapi) BOOL;
pub extern "gdi32" fn PatBlt(hdc: HDC, x: c_int, y: c_int, w: c_int, h: c_int, rop: u32) callconv(.winapi) BOOL;
pub extern "gdi32" fn TextOutW(hdc: HDC, x: c_int, y: c_int, lpString: [*]const u16, c: c_int) callconv(.winapi) BOOL;
pub extern "gdi32" fn SetBkMode(hdc: HDC, mode: c_int) callconv(.winapi) c_int;
pub extern "gdi32" fn SetTextColor(hdc: HDC, color: u32) callconv(.winapi) u32;
pub extern "gdi32" fn CreateFontW(
    cHeight: c_int,
    cWidth: c_int,
    cEscapement: c_int,
    cOrientation: c_int,
    cWeight: c_int,
    bItalic: u32,
    bUnderline: u32,
    bStrikeOut: u32,
    iCharSet: u32,
    iOutPrecision: u32,
    iClipPrecision: u32,
    iQuality: u32,
    iPitchAndFamily: u32,
    pszFaceName: ?[*:0]const u16,
) callconv(.winapi) ?HFONT;

// ── shcore / dwmapi ─────────────────────────────────────────────────────────

pub extern "shcore" fn GetDpiForMonitor(hmonitor: HMONITOR, dpiType: u32, dpiX: *u32, dpiY: *u32) callconv(.winapi) i32;
pub extern "dwmapi" fn DwmGetWindowAttribute(hwnd: HWND, dwAttribute: u32, pvAttribute: *anyopaque, cbAttribute: u32) callconv(.winapi) i32;

// ── kernel32 ────────────────────────────────────────────────────────────────

pub extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
pub extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;
pub extern "kernel32" fn OpenProcess(dwDesiredAccess: u32, bInheritHandle: BOOL, dwProcessId: u32) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn QueryFullProcessImageNameW(hProcess: HANDLE, dwFlags: u32, lpExeName: [*]u16, lpdwSize: *u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GlobalAlloc(uFlags: u32, dwBytes: usize) callconv(.winapi) ?HGLOBAL;
pub extern "kernel32" fn GlobalLock(hMem: HGLOBAL) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(hMem: HGLOBAL) callconv(.winapi) BOOL;
pub extern "kernel32" fn GlobalFree(hMem: HGLOBAL) callconv(.winapi) ?HGLOBAL;
pub extern "kernel32" fn GlobalSize(hMem: HGLOBAL) callconv(.winapi) usize;
pub extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) HANDLE;
pub extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, n: u32, written: ?*u32, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetLocalTime(lpSystemTime: *SYSTEMTIME) callconv(.winapi) void;
pub extern "kernel32" fn GetSystemTime(lpSystemTime: *SYSTEMTIME) callconv(.winapi) void;
pub extern "kernel32" fn GetTimeZoneInformation(tzi: *TIME_ZONE_INFORMATION) callconv(.winapi) u32;
pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
pub extern "kernel32" fn GetFileAttributesW(lpFileName: [*:0]const u16) callconv(.winapi) u32;
pub extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: ?[*]u16, nSize: u32) callconv(.winapi) u32;

pub const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;
pub const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;

// ── shell32 / ole32 ─────────────────────────────────────────────────────────

pub extern "shell32" fn ShellExecuteW(
    hwnd: ?HWND,
    lpOperation: ?[*:0]const u16,
    lpFile: [*:0]const u16,
    lpParameters: ?[*:0]const u16,
    lpDirectory: ?[*:0]const u16,
    nShowCmd: c_int,
) callconv(.winapi) isize;
pub extern "shell32" fn SHGetKnownFolderPath(rfid: *const GUID, dwFlags: u32, hToken: ?HANDLE, ppszPath: *?[*:0]u16) callconv(.winapi) i32;
pub extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;

// ── helpers ─────────────────────────────────────────────────────────────────

pub fn ok(b: BOOL) bool {
    return b != 0;
}

/// UTF-8 → NUL-terminated UTF-16 (WTF-16 tolerant).
pub fn toW(allocator: std.mem.Allocator, s: []const u8) ![:0]u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(allocator, s);
}

/// UTF-16 → UTF-8 (lone surrogates become WTF-8, never an error).
pub fn fromW(allocator: std.mem.Allocator, s: []const u16) ![]u8 {
    return std.unicode.wtf16LeToWtf8Alloc(allocator, s);
}

/// Read an environment variable without the std.Io Environ machinery.
pub fn getEnv(allocator: std.mem.Allocator, comptime name: []const u8) !?[]u8 {
    const wname = comptime std.unicode.utf8ToUtf16LeStringLiteral(name);
    const n = GetEnvironmentVariableW(wname, null, 0);
    if (n == 0) return null;
    const buf = try allocator.alloc(u16, n);
    defer allocator.free(buf);
    const got = GetEnvironmentVariableW(wname, buf.ptr, n);
    if (got == 0 or got >= n) return null;
    return try fromW(allocator, buf[0..got]);
}

pub fn sleepMs(ms: u32) void {
    if (builtin.os.tag == .windows) Sleep(ms);
}

test "INPUT layout matches the Win32 ABI on 64-bit" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(INPUT));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(INPUT));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(INPUT, "u"));
}
