//! Screen and window capture via GDI.
//!
//! BitBlt(SRCCOPY | CAPTUREBLT) from the screen DC into a top-down 32bpp DIB
//! section. With per-monitor-v2 DPI awareness set at startup, rectangles
//! are physical pixels on the virtual desktop. Window captures use
//! PrintWindow(PW_RENDERFULLCONTENT), which renders GPU/DirectComposition
//! windows too and needs no activation, so the user's focus never moves
//! (computer_control activated the window and grabbed the screen region).
//!
//! Every function that reads real screen pixels refuses to run in a test
//! binary; tests render into offscreen memory DCs only.

const std = @import("std");
const builtin = @import("builtin");
const w = @import("win32.zig");
const image = @import("image.zig");

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn fromRECT(r: w.RECT) Rect {
        return .{ .x = r.left, .y = r.top, .w = r.right - r.left, .h = r.bottom - r.top };
    }
};

pub const CaptureError = error{ CaptureDisabled, EmptyRegion, CaptureFailed, OutOfMemory };

pub var disabled: bool = false;

pub fn virtualScreen() Rect {
    return .{
        .x = w.GetSystemMetrics(w.SM_XVIRTUALSCREEN),
        .y = w.GetSystemMetrics(w.SM_YVIRTUALSCREEN),
        .w = w.GetSystemMetrics(w.SM_CXVIRTUALSCREEN),
        .h = w.GetSystemMetrics(w.SM_CYVIRTUALSCREEN),
    };
}

/// Primary monitor; its top-left is (0, 0) in virtual-desktop coordinates.
pub fn primaryScreen() Rect {
    return .{ .x = 0, .y = 0, .w = w.GetSystemMetrics(w.SM_CXSCREEN), .h = w.GetSystemMetrics(w.SM_CYSCREEN) };
}

/// Intersect with the virtual desktop so a partly off-screen request still
/// returns the visible part.
pub fn clampToVirtual(r: Rect) ?Rect {
    const vs = virtualScreen();
    return intersect(r, vs);
}

/// Overlap of two rectangles. Edges are computed in i64 so huge or
/// negative inputs cannot overflow; the result lies inside both.
pub fn intersect(a: Rect, b: Rect) ?Rect {
    const x0: i64 = @max(a.x, b.x);
    const y0: i64 = @max(a.y, b.y);
    const x1: i64 = @min(@as(i64, a.x) + a.w, @as(i64, b.x) + b.w);
    const y1: i64 = @min(@as(i64, a.y) + a.h, @as(i64, b.y) + b.h);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = @intCast(x0), .y = @intCast(y0), .w = @intCast(x1 - x0), .h = @intCast(y1 - y0) };
}

/// True when `r` is non-empty and lies entirely on the virtual desktop.
pub fn insideVirtual(r: Rect) bool {
    if (r.w <= 0 or r.h <= 0) return false;
    const vs = virtualScreen();
    return r.x >= vs.x and r.y >= vs.y and @as(i64, r.x) + r.w <= @as(i64, vs.x) + vs.w and @as(i64, r.y) + r.h <= @as(i64, vs.y) + vs.h;
}

/// An offscreen 32bpp top-down DIB selected into a memory DC.
pub const Dib = struct {
    dc: w.HDC,
    bmp: w.HBITMAP,
    old: ?w.HGDIOBJ,
    bits: [*]u8,
    width: u32,
    height: u32,

    pub fn init(width: u32, height: u32) CaptureError!Dib {
        if (width == 0 or height == 0) return error.EmptyRegion;
        const dc = w.CreateCompatibleDC(null) orelse return error.CaptureFailed;
        errdefer _ = w.DeleteDC(dc);
        const bi: w.BITMAPINFO = .{ .bmiHeader = .{ .biWidth = @intCast(width), .biHeight = -@as(i32, @intCast(height)) } };
        var bits: ?*anyopaque = null;
        const bmp = w.CreateDIBSection(dc, &bi, w.DIB_RGB_COLORS, &bits, null, 0) orelse return error.CaptureFailed;
        const old = w.SelectObject(dc, bmp);
        return .{ .dc = dc, .bmp = bmp, .old = old, .bits = @ptrCast(bits.?), .width = width, .height = height };
    }

    pub fn deinit(self: Dib) void {
        if (self.old) |o| _ = w.SelectObject(self.dc, o);
        _ = w.DeleteObject(self.bmp);
        _ = w.DeleteDC(self.dc);
    }

    /// Copy the pixels out, forcing alpha to opaque (GDI leaves it 0).
    pub fn toBitmap(self: Dib, allocator: std.mem.Allocator) CaptureError!image.Bitmap {
        _ = w.GdiFlush();
        const out = try image.Bitmap.init(allocator, self.width, self.height);
        @memcpy(out.px, self.bits[0..out.px.len]);
        var i: usize = 3;
        while (i < out.px.len) : (i += 4) out.px[i] = 255;
        return out;
    }
};

fn guard() CaptureError!void {
    if (builtin.is_test or disabled) return error.CaptureDisabled;
}

/// Capture a rectangle of the virtual desktop (physical pixels).
pub fn captureRect(allocator: std.mem.Allocator, r_in: Rect) CaptureError!image.Bitmap {
    try guard();
    const r = clampToVirtual(r_in) orelse return error.EmptyRegion;
    const screen = w.GetDC(null) orelse return error.CaptureFailed;
    defer _ = w.ReleaseDC(null, screen);
    const dib = try Dib.init(@intCast(r.w), @intCast(r.h));
    defer dib.deinit();
    if (!w.ok(w.BitBlt(dib.dc, 0, 0, r.w, r.h, screen, r.x, r.y, w.SRCCOPY | w.CAPTUREBLT)))
        return error.CaptureFailed;
    return dib.toBitmap(allocator);
}

/// Render one window into a bitmap without activating it. Falls back to
/// the on-screen rectangle if PrintWindow fails (some legacy apps).
pub fn captureWindow(allocator: std.mem.Allocator, hwnd: w.HWND) CaptureError!struct { bmp: image.Bitmap, rect: Rect } {
    try guard();
    var rc: w.RECT = undefined;
    if (!w.ok(w.GetWindowRect(hwnd, &rc))) return error.CaptureFailed;
    const r = Rect.fromRECT(rc);
    if (r.w <= 0 or r.h <= 0) return error.EmptyRegion;
    const dib = try Dib.init(@intCast(r.w), @intCast(r.h));
    defer dib.deinit();
    // Visible frame: GetWindowRect includes the invisible resize borders,
    // which PrintWindow renders as black. Crop to DWM's extended frame.
    const vis = visibleFrame(hwnd, r);
    if (w.ok(w.PrintWindow(hwnd, dib.dc, w.PW_RENDERFULLCONTENT))) {
        const full = try dib.toBitmap(allocator);
        if (vis.x == r.x and vis.y == r.y and vis.w == r.w and vis.h == r.h) return .{ .bmp = full, .rect = r };
        defer full.deinit(allocator);
        const cropped = image.crop(allocator, full, @intCast(vis.x - r.x), @intCast(vis.y - r.y), @intCast(vis.w), @intCast(vis.h)) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.CaptureFailed,
        };
        return .{ .bmp = cropped, .rect = vis };
    }
    return .{ .bmp = try captureRect(allocator, vis), .rect = vis };
}

/// DWMWA_EXTENDED_FRAME_BOUNDS clipped to the window rect; the window rect
/// itself when DWM has no answer (minimized, non-composited).
pub fn visibleFrame(hwnd: w.HWND, r: Rect) Rect {
    var fr: w.RECT = undefined;
    if (w.DwmGetWindowAttribute(hwnd, w.DWMWA_EXTENDED_FRAME_BOUNDS, &fr, @sizeOf(w.RECT)) != 0) return r;
    return intersect(Rect.fromRECT(fr), r) orelse r;
}

test "Dib renders offscreen and copies out opaque pixels" {
    const dib = try Dib.init(16, 8);
    defer dib.deinit();
    // WHITENESS fills the offscreen bitmap only; no screen DC involved.
    _ = w.PatBlt(dib.dc, 0, 0, 16, 8, 0x00FF0062);
    const bmp = try dib.toBitmap(std.testing.allocator);
    defer bmp.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 16), bmp.w);
    for (bmp.px) |b| try std.testing.expectEqual(@as(u8, 255), b);
}

test "screen capture is refused inside tests" {
    try std.testing.expectError(error.CaptureDisabled, captureRect(std.testing.allocator, .{ .x = 0, .y = 0, .w = 10, .h = 10 }));
}

test "rect intersection" {
    const r = intersect(.{ .x = -10, .y = -10, .w = 30, .h = 30 }, .{ .x = 0, .y = 0, .w = 100, .h = 100 }).?;
    try std.testing.expectEqual(@as(i32, 0), r.x);
    try std.testing.expectEqual(@as(i32, 20), r.w);
    try std.testing.expect(intersect(.{ .x = 200, .y = 0, .w = 5, .h = 5 }, .{ .x = 0, .y = 0, .w = 100, .h = 100 }) == null);
}

test "intersect does not overflow on extreme rectangles" {
    const max = std.math.maxInt(i32);
    const min = std.math.minInt(i32);
    const scr: Rect = .{ .x = 0, .y = 0, .w = 1920, .h = 1080 };
    const r = intersect(.{ .x = max - 5, .y = max - 5, .w = max, .h = max }, scr);
    try std.testing.expect(r == null);
    const big = intersect(.{ .x = min, .y = min, .w = max, .h = max }, scr);
    try std.testing.expect(big == null); // ends at -1
    const cover = intersect(.{ .x = -1000, .y = -1000, .w = max, .h = max }, scr).?;
    try std.testing.expectEqual(@as(i32, 1920), cover.w);
    try std.testing.expect(intersect(.{ .x = 10, .y = 10, .w = -50, .h = 5 }, scr) == null);
}
