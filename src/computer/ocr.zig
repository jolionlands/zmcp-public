//! OCR through Windows.Media.Ocr (WinRT), called directly from Zig.
//!
//! No projection library: activation factories come from
//! RoGetActivationFactory and every interface is a hand-declared vtable.
//! GUIDs and method order are taken from the Windows SDK 10.0.22621 headers
//! (windows.media.ocr.h, windows.graphics.imaging.h,
//! windows.security.cryptography.h, asyncinfo.h).
//!
//! Flow: BGRA pixels → IBuffer (CryptographicBuffer.CreateFromByteArray)
//! → SoftwareBitmap.CreateCopyFromBuffer(Bgra8) → OcrEngine
//! .TryCreateFromUserProfileLanguages().RecognizeAsync() → poll IAsyncInfo
//! until done (the process is MTA, so completion runs on the thread pool
//! and no delegate object is needed) → lines → words with bounding boxes.
//!
//! Every call passes pointers or 32-bit scalars; no struct is passed by
//! value, so there is no ARM64 by-value ABI question here (unlike UIA's
//! CreatePropertyCondition VARIANT).

const std = @import("std");
const w = @import("win32.zig");
const image = @import("image.zig");

const HRESULT = i32;
const HSTRING = ?*anyopaque;

fn failed(hr: HRESULT) bool {
    return hr < 0;
}

fn guid(comptime s: []const u8) w.GUID {
    // "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    const p = std.fmt.parseInt;
    var d4: [8]u8 = undefined;
    d4[0] = p(u8, s[19..21], 16) catch unreachable;
    d4[1] = p(u8, s[21..23], 16) catch unreachable;
    var i: usize = 0;
    while (i < 6) : (i += 1) d4[2 + i] = p(u8, s[24 + i * 2 ..][0..2], 16) catch unreachable;
    return .{
        .Data1 = p(u32, s[0..8], 16) catch unreachable,
        .Data2 = p(u16, s[9..13], 16) catch unreachable,
        .Data3 = p(u16, s[14..18], 16) catch unreachable,
        .Data4 = d4,
    };
}

const IID_IOcrEngineStatics = guid("5bffa85a-3384-3540-9940-699120d428a8");
const IID_ISoftwareBitmapStatics = guid("df0385db-672f-4a9d-806e-c2442f343e86");
const IID_ICryptographicBufferStatics = guid("320b7e22-3cb0-4cdf-8663-1d28910065eb");
const IID_IAsyncInfo = guid("00000036-0000-0000-c000-000000000046");

const BitmapPixelFormat_Bgra8: i32 = 87;
const AsyncStatus_Started: i32 = 0;
const AsyncStatus_Completed: i32 = 1;

/// Every WinRT interface starts with IUnknown (3) + IInspectable (3) slots.
fn Iface(comptime Methods: type) type {
    return extern struct {
        vtbl: *const extern struct {
            QueryInterface: *const fn (*anyopaque, *const w.GUID, *?*anyopaque) callconv(.winapi) HRESULT,
            AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
            Release: *const fn (*anyopaque) callconv(.winapi) u32,
            GetIids: *const anyopaque,
            GetRuntimeClassName: *const anyopaque,
            GetTrustLevel: *const anyopaque,
            m: Methods,
        },

        pub fn release(self: *@This()) void {
            _ = self.vtbl.Release(self);
        }
    };
}

const IOcrEngineStatics = Iface(extern struct {
    get_MaxImageDimension: *const fn (*anyopaque, *u32) callconv(.winapi) HRESULT,
    get_AvailableRecognizerLanguages: *const anyopaque,
    IsLanguageSupported: *const anyopaque,
    TryCreateFromLanguage: *const anyopaque,
    TryCreateFromUserProfileLanguages: *const fn (*anyopaque, *?*IOcrEngine) callconv(.winapi) HRESULT,
});

const IOcrEngine = Iface(extern struct {
    RecognizeAsync: *const fn (*anyopaque, *ISoftwareBitmap, *?*IAsyncOperationOcrResult) callconv(.winapi) HRESULT,
    get_RecognizerLanguage: *const anyopaque,
});

const ISoftwareBitmap = Iface(extern struct {});

const ISoftwareBitmapStatics = Iface(extern struct {
    Copy: *const anyopaque,
    Convert: *const anyopaque,
    ConvertWithAlpha: *const anyopaque,
    CreateCopyFromBuffer: *const fn (*anyopaque, *IBuffer, i32, i32, i32, *?*ISoftwareBitmap) callconv(.winapi) HRESULT,
});

const IBuffer = Iface(extern struct {});

const ICryptographicBufferStatics = Iface(extern struct {
    Compare: *const anyopaque,
    GenerateRandom: *const anyopaque,
    GenerateRandomNumber: *const anyopaque,
    CreateFromByteArray: *const fn (*anyopaque, u32, [*]const u8, *?*IBuffer) callconv(.winapi) HRESULT,
});

const IAsyncInfo = Iface(extern struct {
    get_Id: *const anyopaque,
    get_Status: *const fn (*anyopaque, *i32) callconv(.winapi) HRESULT,
    get_ErrorCode: *const fn (*anyopaque, *HRESULT) callconv(.winapi) HRESULT,
    Cancel: *const anyopaque,
    Close: *const fn (*anyopaque) callconv(.winapi) HRESULT,
});

const IAsyncOperationOcrResult = Iface(extern struct {
    put_Completed: *const anyopaque,
    get_Completed: *const anyopaque,
    GetResults: *const fn (*anyopaque, *?*IOcrResult) callconv(.winapi) HRESULT,
});

const IOcrResult = Iface(extern struct {
    get_Lines: *const fn (*anyopaque, *?*IVectorView) callconv(.winapi) HRESULT,
    get_TextAngle: *const anyopaque,
    get_Text: *const fn (*anyopaque, *HSTRING) callconv(.winapi) HRESULT,
});

/// IVectorView<T> for T = OcrLine / OcrWord (runtime-class elements are
/// returned as their default interface pointer).
const IVectorView = Iface(extern struct {
    GetAt: *const fn (*anyopaque, u32, *?*anyopaque) callconv(.winapi) HRESULT,
    get_Size: *const fn (*anyopaque, *u32) callconv(.winapi) HRESULT,
    IndexOf: *const anyopaque,
    GetMany: *const anyopaque,
});

const IOcrLine = Iface(extern struct {
    get_Words: *const fn (*anyopaque, *?*IVectorView) callconv(.winapi) HRESULT,
    get_Text: *const fn (*anyopaque, *HSTRING) callconv(.winapi) HRESULT,
});

const FRect = extern struct { x: f32, y: f32, width: f32, height: f32 };

const IOcrWord = Iface(extern struct {
    get_BoundingRect: *const fn (*anyopaque, *FRect) callconv(.winapi) HRESULT,
    get_Text: *const fn (*anyopaque, *HSTRING) callconv(.winapi) HRESULT,
});

extern "api-ms-win-core-winrt-l1-1-0" fn RoInitialize(initType: u32) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-l1-1-0" fn RoGetActivationFactory(activatableClassId: HSTRING, iid: *const w.GUID, factory: *?*anyopaque) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-string-l1-1-0" fn WindowsCreateString(src: [*]const u16, len: u32, out: *HSTRING) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-string-l1-1-0" fn WindowsDeleteString(s: HSTRING) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-string-l1-1-0" fn WindowsGetStringRawBuffer(s: HSTRING, len: ?*u32) callconv(.winapi) ?[*]const u16;

const RO_INIT_MULTITHREADED: u32 = 1;
const RPC_E_CHANGED_MODE: HRESULT = @bitCast(@as(u32, 0x80010106));

pub const Error = error{
    WinRtInitFailed,
    OcrUnavailable,
    NoOcrLanguage,
    ImageTooLarge,
    OcrFailed,
    OcrTimeout,
    OutOfMemory,
};

var ro_ready: bool = false;

/// Initialise the WinRT apartment (MTA). Safe to call repeatedly.
pub fn initApartment() Error!void {
    if (ro_ready) return;
    const hr = RoInitialize(RO_INIT_MULTITHREADED);
    if (failed(hr) and hr != RPC_E_CHANGED_MODE) return error.WinRtInitFailed;
    ro_ready = true;
}

fn factory(comptime T: type, comptime class: []const u8, iid: *const w.GUID) Error!*T {
    const wide = comptime std.unicode.utf8ToUtf16LeStringLiteral(class);
    var hs: HSTRING = null;
    if (failed(WindowsCreateString(wide, class.len, &hs))) return error.OcrUnavailable;
    defer _ = WindowsDeleteString(hs);
    var out: ?*anyopaque = null;
    if (failed(RoGetActivationFactory(hs, iid, &out)) or out == null) return error.OcrUnavailable;
    return @ptrCast(@alignCast(out.?));
}

fn hstringToUtf8(allocator: std.mem.Allocator, hs: HSTRING) ![]u8 {
    defer _ = WindowsDeleteString(hs);
    var len: u32 = 0;
    const p = WindowsGetStringRawBuffer(hs, &len) orelse return allocator.alloc(u8, 0);
    return w.fromW(allocator, p[0..len]);
}

pub const Word = struct {
    text: []const u8,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const Line = struct {
    text: []const u8,
    words: []const Word,
    /// Union of the word boxes.
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const Result = struct {
    lines: []const Line,
    text: []const u8,
    duration_ms: u64,
};

fn vecSize(v: *IVectorView) u32 {
    var n: u32 = 0;
    if (failed(v.vtbl.m.get_Size(v, &n))) return 0;
    return n;
}

/// Recognise text in a BGRA bitmap. Coordinates are bitmap pixels.
/// Use an arena for `allocator`; the result borrows from it.
/// OcrEngine.MaxImageDimension as reported by this Windows build.
pub fn maxImageDimension() Error!u32 {
    try initApartment();
    const statics = try factory(IOcrEngineStatics, "Windows.Media.Ocr.OcrEngine", &IID_IOcrEngineStatics);
    defer statics.release();
    var max_dim: u32 = 0;
    if (failed(statics.vtbl.m.get_MaxImageDimension(statics, &max_dim)) or max_dim == 0) return error.OcrUnavailable;
    return max_dim;
}

/// Downscale factor so both sides fit `max_dim` (1.0 when they already do).
pub fn fitFactor(w_: u32, h_: u32, max_dim: u32) f64 {
    const big = @max(w_, h_);
    if (big <= max_dim or max_dim == 0) return 1.0;
    return @as(f64, @floatFromInt(big)) / @as(f64, @floatFromInt(max_dim));
}

pub fn recognize(allocator: std.mem.Allocator, src: image.Bitmap) Error!Result {
    const t0 = w.GetTickCount64();
    try initApartment();

    const statics = try factory(IOcrEngineStatics, "Windows.Media.Ocr.OcrEngine", &IID_IOcrEngineStatics);
    defer statics.release();
    var max_dim: u32 = 0;
    if (failed(statics.vtbl.m.get_MaxImageDimension(statics, &max_dim)) or max_dim == 0) return error.OcrUnavailable;
    // Large (multi-monitor / 8K) captures: shrink to the engine's limit and
    // map coordinates back afterwards.
    const f = fitFactor(src.w, src.h, max_dim);
    var bmp = src;
    var sx: f32 = 1.0;
    var sy: f32 = 1.0;
    if (f > 1.0) {
        const nw: u32 = @min(max_dim, @max(1, @as(u32, @intFromFloat(@floor(@as(f64, @floatFromInt(src.w)) / f)))));
        const nh: u32 = @min(max_dim, @max(1, @as(u32, @intFromFloat(@floor(@as(f64, @floatFromInt(src.h)) / f)))));
        bmp = image.downscale(allocator, src, nw, nh) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ImageTooLarge,
        };
        sx = @as(f32, @floatFromInt(src.w)) / @as(f32, @floatFromInt(nw));
        sy = @as(f32, @floatFromInt(src.h)) / @as(f32, @floatFromInt(nh));
    }

    var engine_opt: ?*IOcrEngine = null;
    if (failed(statics.vtbl.m.TryCreateFromUserProfileLanguages(statics, &engine_opt)) or engine_opt == null)
        return error.NoOcrLanguage;
    const engine = engine_opt.?;
    defer engine.release();

    const cbs = try factory(ICryptographicBufferStatics, "Windows.Security.Cryptography.CryptographicBuffer", &IID_ICryptographicBufferStatics);
    defer cbs.release();
    var buf_opt: ?*IBuffer = null;
    if (failed(cbs.vtbl.m.CreateFromByteArray(cbs, @intCast(bmp.px.len), bmp.px.ptr, &buf_opt)) or buf_opt == null)
        return error.OcrFailed;
    const buffer = buf_opt.?;
    defer buffer.release();

    const sbs = try factory(ISoftwareBitmapStatics, "Windows.Graphics.Imaging.SoftwareBitmap", &IID_ISoftwareBitmapStatics);
    defer sbs.release();
    var sb_opt: ?*ISoftwareBitmap = null;
    if (failed(sbs.vtbl.m.CreateCopyFromBuffer(sbs, buffer, BitmapPixelFormat_Bgra8, @intCast(bmp.w), @intCast(bmp.h), &sb_opt)) or sb_opt == null)
        return error.OcrFailed;
    const sb = sb_opt.?;
    defer sb.release();

    var op_opt: ?*IAsyncOperationOcrResult = null;
    if (failed(engine.vtbl.m.RecognizeAsync(engine, sb, &op_opt)) or op_opt == null) return error.OcrFailed;
    const op = op_opt.?;
    defer op.release();

    var info_opt: ?*anyopaque = null;
    if (failed(op.vtbl.QueryInterface(op, &IID_IAsyncInfo, &info_opt)) or info_opt == null) return error.OcrFailed;
    const info: *IAsyncInfo = @ptrCast(@alignCast(info_opt.?));
    defer info.release();

    const deadline = t0 + 60_000;
    var status: i32 = AsyncStatus_Started;
    while (true) {
        if (failed(info.vtbl.m.get_Status(info, &status))) return error.OcrFailed;
        if (status != AsyncStatus_Started) break;
        if (w.GetTickCount64() > deadline) return error.OcrTimeout;
        w.sleepMs(5);
    }
    if (status != AsyncStatus_Completed) return error.OcrFailed;

    var res_opt: ?*IOcrResult = null;
    if (failed(op.vtbl.m.GetResults(op, &res_opt)) or res_opt == null) return error.OcrFailed;
    const res = res_opt.?;
    defer res.release();
    _ = info.vtbl.m.Close(info);

    var full: HSTRING = null;
    const text = if (!failed(res.vtbl.m.get_Text(res, &full))) try hstringToUtf8(allocator, full) else try allocator.alloc(u8, 0);

    var lines_opt: ?*IVectorView = null;
    if (failed(res.vtbl.m.get_Lines(res, &lines_opt)) or lines_opt == null) return error.OcrFailed;
    const lines_v = lines_opt.?;
    defer lines_v.release();

    const n_lines = vecSize(lines_v);
    const lines = try allocator.alloc(Line, n_lines);
    var li: u32 = 0;
    while (li < n_lines) : (li += 1) {
        var lp: ?*anyopaque = null;
        if (failed(lines_v.vtbl.m.GetAt(lines_v, li, &lp)) or lp == null) return error.OcrFailed;
        const line: *IOcrLine = @ptrCast(@alignCast(lp.?));
        defer line.release();
        var lt: HSTRING = null;
        const ltext = if (!failed(line.vtbl.m.get_Text(line, &lt))) try hstringToUtf8(allocator, lt) else try allocator.alloc(u8, 0);

        var words_opt: ?*IVectorView = null;
        if (failed(line.vtbl.m.get_Words(line, &words_opt)) or words_opt == null) return error.OcrFailed;
        const words_v = words_opt.?;
        defer words_v.release();
        const n_words = vecSize(words_v);
        const words = try allocator.alloc(Word, n_words);
        var x0: f32 = std.math.floatMax(f32);
        var y0: f32 = std.math.floatMax(f32);
        var x1: f32 = 0;
        var y1: f32 = 0;
        var wi: u32 = 0;
        while (wi < n_words) : (wi += 1) {
            var wp: ?*anyopaque = null;
            if (failed(words_v.vtbl.m.GetAt(words_v, wi, &wp)) or wp == null) return error.OcrFailed;
            const word: *IOcrWord = @ptrCast(@alignCast(wp.?));
            defer word.release();
            var r: FRect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
            _ = word.vtbl.m.get_BoundingRect(word, &r);
            var wt: HSTRING = null;
            const wtext = if (!failed(word.vtbl.m.get_Text(word, &wt))) try hstringToUtf8(allocator, wt) else try allocator.alloc(u8, 0);
            r = .{ .x = r.x * sx, .y = r.y * sy, .width = r.width * sx, .height = r.height * sy };
            words[wi] = .{ .text = wtext, .x = r.x, .y = r.y, .w = r.width, .h = r.height };
            x0 = @min(x0, r.x);
            y0 = @min(y0, r.y);
            x1 = @max(x1, r.x + r.width);
            y1 = @max(y1, r.y + r.height);
        }
        if (n_words == 0) {
            x0 = 0;
            y0 = 0;
        }
        lines[li] = .{ .text = ltext, .words = words, .x = x0, .y = y0, .w = @max(x1 - x0, 0), .h = @max(y1 - y0, 0) };
    }
    return .{ .lines = lines, .text = text, .duration_ms = w.GetTickCount64() - t0 };
}

// ── test: OCR a bitmap rendered offscreen (no screen access) ───────────────

fn renderText(allocator: std.mem.Allocator, text: []const u8) !image.Bitmap {
    const capture = @import("capture.zig");
    const dib = try capture.Dib.init(640, 120);
    defer dib.deinit();
    _ = w.PatBlt(dib.dc, 0, 0, 640, 120, 0x00FF0062); // WHITENESS
    const face = std.unicode.utf8ToUtf16LeStringLiteral("Arial");
    const font = w.CreateFontW(64, 0, 0, 0, 400, 0, 0, 0, 0, 0, 0, 5, 0, face) orelse return error.NoFont;
    defer _ = w.DeleteObject(font);
    const old = w.SelectObject(dib.dc, font);
    defer if (old) |o| {
        _ = w.SelectObject(dib.dc, o);
    };
    _ = w.SetBkMode(dib.dc, 1);
    _ = w.SetTextColor(dib.dc, 0);
    const wide = try w.toW(allocator, text);
    defer allocator.free(wide);
    _ = w.TextOutW(dib.dc, 20, 25, wide.ptr, @intCast(wide.len));
    return dib.toBitmap(allocator);
}

test "GUID parsing matches the SDK layout" {
    const g = guid("5bffa85a-3384-3540-9940-699120d428a8");
    try std.testing.expectEqual(@as(u32, 0x5bffa85a), g.Data1);
    try std.testing.expectEqual(@as(u16, 0x3384), g.Data2);
    try std.testing.expectEqual(@as(u16, 0x3540), g.Data3);
    try std.testing.expectEqualSlices(u8, &.{ 0x99, 0x40, 0x69, 0x91, 0x20, 0xd4, 0x28, 0xa8 }, &g.Data4);
}

test "Windows.Media.Ocr reads text rendered into an offscreen bitmap" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bmp = try renderText(arena, "HELLO ZIG 42");
    const res = recognize(arena, bmp) catch |e| switch (e) {
        // No OCR language pack installed on this machine.
        error.NoOcrLanguage, error.OcrUnavailable => return error.SkipZigTest,
        else => return e,
    };
    try std.testing.expect(res.lines.len >= 1);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "HELLO") != null);
    const first = res.lines[0];
    try std.testing.expect(first.words.len >= 2);
    // Text was drawn at x=20, y=25 with a 64 px font.
    try std.testing.expect(first.x >= 10 and first.x <= 40);
    try std.testing.expect(first.y >= 20 and first.y <= 60);
}

test "fitFactor" {
    try std.testing.expectEqual(@as(f64, 1.0), fitFactor(1920, 1080, 10000));
    try std.testing.expectEqual(@as(f64, 2.0), fitFactor(20000, 100, 10000));
    try std.testing.expectEqual(@as(f64, 1.5), fitFactor(100, 15000, 10000));
}

test "OCR downscales images wider than MaxImageDimension and maps coordinates back" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const max_dim = maxImageDimension() catch return error.SkipZigTest;
    const text = try renderText(arena, "HELLO ZIG 42"); // 640x120, text at x=20
    const wide_w: u32 = max_dim + 800;
    const wide = try image.Bitmap.init(arena, wide_w, 120);
    @memset(wide.px, 255);
    const x0: u32 = wide_w - 700;
    var y: u32 = 0;
    while (y < 120) : (y += 1) {
        const d = (@as(usize, y) * wide_w + x0) * 4;
        const sidx = @as(usize, y) * 640 * 4;
        @memcpy(wide.px[d..][0 .. 640 * 4], text.px[sidx..][0 .. 640 * 4]);
    }
    const res = recognize(arena, wide) catch |e| switch (e) {
        error.NoOcrLanguage, error.OcrUnavailable => return error.SkipZigTest,
        else => return e,
    };
    try std.testing.expect(std.mem.indexOf(u8, res.text, "HELLO") != null);
    const first = res.lines[0];
    // Text starts at x0 + 20 in the ORIGINAL bitmap's coordinates.
    const want: f32 = @floatFromInt(x0 + 20);
    try std.testing.expect(@abs(first.x - want) < 40);
}
