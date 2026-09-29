//! In-memory BGRA bitmaps, crop and box-filter downscale, and a pure-Zig PNG
//! encoder (8-bit RGB, adaptive per-row filters, zlib via std.compress.flate).

const std = @import("std");
const flate = std.compress.flate;

/// Top-down 32-bit BGRA pixels, `stride == w * 4`. This is what a GDI
/// 32bpp DIB section holds, so captures copy straight in.
pub const Bitmap = struct {
    w: u32,
    h: u32,
    px: []u8,

    pub fn init(allocator: std.mem.Allocator, w: u32, h: u32) !Bitmap {
        const px = try allocator.alloc(u8, @as(usize, w) * h * 4);
        return .{ .w = w, .h = h, .px = px };
    }

    pub fn deinit(self: Bitmap, allocator: std.mem.Allocator) void {
        allocator.free(self.px);
    }

    pub fn at(self: Bitmap, x: u32, y: u32) *[4]u8 {
        const i = (@as(usize, y) * self.w + x) * 4;
        return self.px[i..][0..4];
    }
};

/// Copy of the rectangle (x, y, w, h), clamped to the source bounds.
pub fn crop(allocator: std.mem.Allocator, src: Bitmap, x: u32, y: u32, w: u32, h: u32) !Bitmap {
    const x0 = @min(x, src.w);
    const y0 = @min(y, src.h);
    const cw = @min(w, src.w - x0);
    const ch = @min(h, src.h - y0);
    if (cw == 0 or ch == 0) return error.EmptyRegion;
    const out = try Bitmap.init(allocator, cw, ch);
    var row: u32 = 0;
    while (row < ch) : (row += 1) {
        const s = (@as(usize, y0 + row) * src.w + x0) * 4;
        const d = @as(usize, row) * cw * 4;
        @memcpy(out.px[d..][0 .. cw * 4], src.px[s..][0 .. cw * 4]);
    }
    return out;
}

/// Area-average downscale. Each destination pixel is the mean of the source
/// pixels it covers (integer box bounds), which keeps small UI text legible
/// far better than nearest-neighbour at the 1.5x-3x ratios screenshots use.
pub fn downscale(allocator: std.mem.Allocator, src: Bitmap, dw: u32, dh: u32) !Bitmap {
    if (dw == 0 or dh == 0) return error.EmptyRegion;
    if (dw >= src.w and dh >= src.h) {
        const out = try Bitmap.init(allocator, src.w, src.h);
        @memcpy(out.px, src.px);
        return out;
    }
    const out = try Bitmap.init(allocator, dw, dh);
    var dy: u32 = 0;
    while (dy < dh) : (dy += 1) {
        const sy0: u32 = @intCast(@as(u64, dy) * src.h / dh);
        var sy1: u32 = @intCast(@as(u64, dy + 1) * src.h / dh);
        if (sy1 <= sy0) sy1 = sy0 + 1;
        var dx: u32 = 0;
        while (dx < dw) : (dx += 1) {
            const sx0: u32 = @intCast(@as(u64, dx) * src.w / dw);
            var sx1: u32 = @intCast(@as(u64, dx + 1) * src.w / dw);
            if (sx1 <= sx0) sx1 = sx0 + 1;
            var acc = [4]u32{ 0, 0, 0, 0 };
            var sy = sy0;
            while (sy < sy1) : (sy += 1) {
                var sx = sx0;
                while (sx < sx1) : (sx += 1) {
                    const p = src.at(sx, sy);
                    inline for (0..4) |c| acc[c] += p[c];
                }
            }
            const n = (sy1 - sy0) * (sx1 - sx0);
            const d = out.at(dx, dy);
            inline for (0..4) |c| d[c] = @intCast((acc[c] + n / 2) / n);
        }
    }
    return out;
}

/// Size that fits `max_w` wide keeping aspect ratio (clawdcursor's 1280 px
/// LLM frame). Returns the source size when it is already narrow enough.
pub fn fitWidth(w: u32, h: u32, max_w: u32) struct { w: u32, h: u32 } {
    if (w <= max_w or max_w == 0) return .{ .w = w, .h = h };
    const nh: u32 = @intCast((@as(u64, h) * max_w + w / 2) / w);
    return .{ .w = max_w, .h = @max(nh, 1) };
}

// ── PNG ─────────────────────────────────────────────────────────────────────

const png_signature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };

fn writeChunk(out: *std.ArrayList(u8), allocator: std.mem.Allocator, kind: *const [4]u8, data: []const u8) !void {
    var len_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_be, @intCast(data.len), .big);
    try out.appendSlice(allocator, &len_be);
    try out.appendSlice(allocator, kind);
    try out.appendSlice(allocator, data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var crc_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_be, crc.final(), .big);
    try out.appendSlice(allocator, &crc_be);
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i16 = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Filter one RGB scanline with filter `f` into `dst` (without filter byte).
fn filterRow(f: u8, cur: []const u8, prev: ?[]const u8, dst: []u8) void {
    const bpp = 3;
    for (cur, 0..) |x, i| {
        const a: u8 = if (i >= bpp) cur[i - bpp] else 0;
        const b: u8 = if (prev) |p| p[i] else 0;
        const c: u8 = if (prev != null and i >= bpp) prev.?[i - bpp] else 0;
        dst[i] = switch (f) {
            0 => x,
            1 => x -% a,
            2 => x -% b,
            3 => x -% @as(u8, @intCast((@as(u16, a) + b) / 2)),
            else => x -% paeth(a, b, c),
        };
    }
}

fn rowCost(row: []const u8) u64 {
    var s: u64 = 0;
    for (row) |v| s += if (v < 128) v else 256 - @as(u64, v);
    return s;
}

/// Encode a BGRA bitmap as an 8-bit RGB PNG. Alpha is dropped: screen
/// captures are opaque and RGB is 25% smaller.
pub fn encodePng(allocator: std.mem.Allocator, bmp: Bitmap) ![]u8 {
    if (bmp.w == 0 or bmp.h == 0) return error.EmptyRegion;
    const row_len = @as(usize, bmp.w) * 3;

    // Filtered scanlines (filter byte + row), chosen per row by the usual
    // minimum-sum-of-absolute-differences heuristic.
    const raw = try allocator.alloc(u8, (row_len + 1) * bmp.h);
    defer allocator.free(raw);
    const rgb_prev = try allocator.alloc(u8, row_len);
    defer allocator.free(rgb_prev);
    const rgb_cur = try allocator.alloc(u8, row_len);
    defer allocator.free(rgb_cur);
    const trial = try allocator.alloc(u8, row_len);
    defer allocator.free(trial);

    var y: u32 = 0;
    while (y < bmp.h) : (y += 1) {
        const src = bmp.px[@as(usize, y) * bmp.w * 4 ..][0 .. @as(usize, bmp.w) * 4];
        var x: usize = 0;
        while (x < bmp.w) : (x += 1) {
            rgb_cur[x * 3 + 0] = src[x * 4 + 2];
            rgb_cur[x * 3 + 1] = src[x * 4 + 1];
            rgb_cur[x * 3 + 2] = src[x * 4 + 0];
        }
        const prev: ?[]const u8 = if (y == 0) null else rgb_prev;
        const dst = raw[@as(usize, y) * (row_len + 1) ..][0 .. row_len + 1];
        var best_f: u8 = 0;
        var best_cost: u64 = std.math.maxInt(u64);
        var f: u8 = 0;
        while (f < 5) : (f += 1) {
            filterRow(f, rgb_cur, prev, trial);
            const cost = rowCost(trial);
            if (cost < best_cost) {
                best_cost = cost;
                best_f = f;
            }
        }
        dst[0] = best_f;
        filterRow(best_f, rgb_cur, prev, dst[1..]);
        @memcpy(rgb_prev, rgb_cur);
    }

    // zlib stream.
    var z: std.Io.Writer.Allocating = .init(allocator);
    defer z.deinit();
    try z.ensureUnusedCapacity(64 * 1024);
    const window = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window);
    const comp = try allocator.create(flate.Compress);
    defer allocator.destroy(comp);
    comp.* = try flate.Compress.init(&z.writer, window, .zlib, .level_4);
    try comp.writer.writeAll(raw);
    try comp.finish();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &png_signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], bmp.w, .big);
    std.mem.writeInt(u32, ihdr[4..8], bmp.h, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 2; // colour type: RGB
    ihdr[10] = 0; // deflate
    ihdr[11] = 0; // adaptive filtering
    ihdr[12] = 0; // no interlace
    try writeChunk(&out, allocator, "IHDR", &ihdr);
    try writeChunk(&out, allocator, "IDAT", z.written());
    try writeChunk(&out, allocator, "IEND", "");
    return out.toOwnedSlice(allocator);
}

pub fn base64Alloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, enc.calcSize(bytes.len));
    _ = enc.encode(out, bytes);
    return out;
}

// ── tests ───────────────────────────────────────────────────────────────────

const t = std.testing;

fn syntheticBitmap(allocator: std.mem.Allocator, w: u32, h: u32) !Bitmap {
    const b = try Bitmap.init(allocator, w, h);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const p = b.at(x, y);
            p[0] = @truncate(x * 7 + y); // B
            p[1] = @truncate(y * 13); // G
            p[2] = @truncate(x ^ y); // R
            p[3] = 255;
        }
    }
    return b;
}

/// Minimal PNG reader for the round-trip test: walks chunks, checks CRCs,
/// inflates IDAT and undoes the filters.
fn decodeRgbForTest(allocator: std.mem.Allocator, png: []const u8) !struct { w: u32, h: u32, rgb: []u8 } {
    try t.expectEqualSlices(u8, &png_signature, png[0..8]);
    var pos: usize = 8;
    var w: u32 = 0;
    var h: u32 = 0;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(allocator);
    var saw_end = false;
    while (pos < png.len) {
        const len = std.mem.readInt(u32, png[pos..][0..4], .big);
        const kind = png[pos + 4 ..][0..4];
        const data = png[pos + 8 ..][0..len];
        const crc = std.mem.readInt(u32, png[pos + 8 + len ..][0..4], .big);
        var c = std.hash.Crc32.init();
        c.update(kind);
        c.update(data);
        try t.expectEqual(c.final(), crc);
        if (std.mem.eql(u8, kind, "IHDR")) {
            w = std.mem.readInt(u32, data[0..4], .big);
            h = std.mem.readInt(u32, data[4..8], .big);
            try t.expectEqual(@as(u8, 8), data[8]);
            try t.expectEqual(@as(u8, 2), data[9]);
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(allocator, data);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            saw_end = true;
        }
        pos += 12 + len;
    }
    try t.expect(saw_end);

    var in: std.Io.Reader = .fixed(idat.items);
    var dbuf: [flate.max_window_len]u8 = undefined;
    var dec: flate.Decompress = .init(&in, .zlib, &dbuf);
    var inflated: std.Io.Writer.Allocating = .init(allocator);
    defer inflated.deinit();
    _ = try dec.reader.streamRemaining(&inflated.writer);
    const raw = inflated.written();
    const row_len = @as(usize, w) * 3;
    try t.expectEqual((row_len + 1) * h, raw.len);

    const rgb = try allocator.alloc(u8, row_len * h);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const f = raw[y * (row_len + 1)];
        const line = raw[y * (row_len + 1) + 1 ..][0..row_len];
        const cur = rgb[y * row_len ..][0..row_len];
        for (line, 0..) |v, i| {
            const a: u8 = if (i >= 3) cur[i - 3] else 0;
            const b: u8 = if (y > 0) rgb[(y - 1) * row_len + i] else 0;
            const c: u8 = if (y > 0 and i >= 3) rgb[(y - 1) * row_len + i - 3] else 0;
            cur[i] = switch (f) {
                0 => v,
                1 => v +% a,
                2 => v +% b,
                3 => v +% @as(u8, @intCast((@as(u16, a) + b) / 2)),
                4 => v +% paeth(a, b, c),
                else => return error.BadFilter,
            };
        }
    }
    return .{ .w = w, .h = h, .rgb = rgb };
}

test "PNG encoder round-trips a synthetic bitmap exactly" {
    const alloc = t.allocator;
    for ([_][2]u32{ .{ 1, 1 }, .{ 7, 5 }, .{ 64, 33 }, .{ 301, 97 } }) |dims| {
        const bmp = try syntheticBitmap(alloc, dims[0], dims[1]);
        defer bmp.deinit(alloc);
        const png = try encodePng(alloc, bmp);
        defer alloc.free(png);
        const dec = try decodeRgbForTest(alloc, png);
        defer alloc.free(dec.rgb);
        try t.expectEqual(dims[0], dec.w);
        try t.expectEqual(dims[1], dec.h);
        var y: u32 = 0;
        while (y < bmp.h) : (y += 1) {
            var x: u32 = 0;
            while (x < bmp.w) : (x += 1) {
                const p = bmp.at(x, y);
                const i = (@as(usize, y) * bmp.w + x) * 3;
                try t.expectEqual(p[2], dec.rgb[i]);
                try t.expectEqual(p[1], dec.rgb[i + 1]);
                try t.expectEqual(p[0], dec.rgb[i + 2]);
            }
        }
    }
}

test "flat colour compresses well" {
    const alloc = t.allocator;
    const bmp = try Bitmap.init(alloc, 1280, 720);
    defer bmp.deinit(alloc);
    @memset(bmp.px, 0xEE);
    const png = try encodePng(alloc, bmp);
    defer alloc.free(png);
    try t.expect(png.len < 20 * 1024);
}

test "downscale averages boxes and fitWidth keeps aspect" {
    const alloc = t.allocator;
    const src = try Bitmap.init(alloc, 4, 2);
    defer src.deinit(alloc);
    // left half black, right half white
    var y: u32 = 0;
    while (y < 2) : (y += 1) {
        var x: u32 = 0;
        while (x < 4) : (x += 1) @memset(src.at(x, y), if (x < 2) 0 else 255);
    }
    const half = try downscale(alloc, src, 2, 1);
    defer half.deinit(alloc);
    try t.expectEqual(@as(u8, 0), half.at(0, 0)[0]);
    try t.expectEqual(@as(u8, 255), half.at(1, 0)[0]);
    const one = try downscale(alloc, src, 1, 1);
    defer one.deinit(alloc);
    try t.expectEqual(@as(u8, 128), one.at(0, 0)[1]);

    const f = fitWidth(2560, 1440, 1280);
    try t.expectEqual(@as(u32, 1280), f.w);
    try t.expectEqual(@as(u32, 720), f.h);
    const same = fitWidth(1024, 768, 1280);
    try t.expectEqual(@as(u32, 1024), same.w);
}

test "crop clamps to bounds" {
    const alloc = t.allocator;
    const src = try syntheticBitmap(alloc, 10, 10);
    defer src.deinit(alloc);
    const c = try crop(alloc, src, 8, 8, 5, 5);
    defer c.deinit(alloc);
    try t.expectEqual(@as(u32, 2), c.w);
    try t.expectEqualSlices(u8, src.at(8, 8), c.at(0, 0));
    try t.expectError(error.EmptyRegion, crop(alloc, src, 10, 0, 5, 5));
}
