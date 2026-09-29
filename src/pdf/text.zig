//! Text extraction: fonts (simple encodings, Type0/CID with ToUnicode CMaps),
//! a content-stream interpreter for the text operators, and line/paragraph
//! reconstruction from text-matrix positions.

const std = @import("std");
const pdf = @import("pdf.zig");
const enc = @import("enc.zig");
const Allocator = std.mem.Allocator;
const Obj = pdf.Obj;
const Lexer = pdf.Lexer;

// ---------------------------------------------------------------------------
// Output normalisation
// ---------------------------------------------------------------------------

fn appendNorm(alloc: Allocator, out: *std.ArrayList(u8), cp: u21) Allocator.Error!void {
    switch (cp) {
        0xFB00 => try out.appendSlice(alloc, "ff"),
        0xFB01 => try out.appendSlice(alloc, "fi"),
        0xFB02 => try out.appendSlice(alloc, "fl"),
        0xFB03 => try out.appendSlice(alloc, "ffi"),
        0xFB04 => try out.appendSlice(alloc, "ffl"),
        0xFB05, 0xFB06 => try out.appendSlice(alloc, "st"),
        0xA0, 0x2002, 0x2003, 0x2009, 0x202F, '\t' => try out.append(alloc, ' '),
        0xAD, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0xFEFF => {},
        0x2011 => try out.append(alloc, '-'),
        0...8, 10...31, 0x7F => {},
        else => try pdf.appendCp(alloc, out, cp),
    }
}

fn appendNormUtf8(alloc: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    var it = (std.unicode.Utf8View.init(s) catch {
        try out.appendSlice(alloc, "\u{FFFD}");
        return;
    }).iterator();
    while (it.nextCodepoint()) |cp| try appendNorm(alloc, out, cp);
}

// ---------------------------------------------------------------------------
// CMaps (ToUnicode / embedded encodings)
// ---------------------------------------------------------------------------

pub const CMap = struct {
    chars: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    ranges: []const Range = &.{},
    code_bytes: u8 = 0,

    const Range = struct { lo: u32, hi: u32, base: u21 };

    /// Append the mapping for `code`; false when there is none.
    pub fn lookup(self: *const CMap, alloc: Allocator, code: u32, out: *std.ArrayList(u8)) Allocator.Error!bool {
        if (self.chars.get(code)) |s| {
            try appendNormUtf8(alloc, out, s);
            return true;
        }
        var lo: usize = 0;
        var hi: usize = self.ranges.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const r = self.ranges[mid];
            if (code < r.lo) {
                hi = mid;
            } else if (code > r.hi) {
                lo = mid + 1;
            } else {
                const cp = @as(u32, r.base) + (code - r.lo);
                if (cp <= 0x10FFFF) try appendNorm(alloc, out, @intCast(cp));
                return true;
            }
        }
        return false;
    }
};

fn beCode(b: []const u8) u32 {
    var v: u32 = 0;
    for (b[0..@min(b.len, 4)]) |c| v = (v << 8) | c;
    return v;
}

fn utf16ToUtf8(alloc: Allocator, b: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    if (b.len == 1) {
        try pdf.appendCp(alloc, &out, b[0]);
        return out.toOwnedSlice(alloc);
    }
    while (i + 1 < b.len) : (i += 2) {
        var u: u21 = std.mem.readInt(u16, b[i..][0..2], .big);
        if (u >= 0xD800 and u < 0xDC00 and i + 3 < b.len) {
            const lo: u21 = std.mem.readInt(u16, b[i + 2 ..][0..2], .big);
            if (lo >= 0xDC00 and lo < 0xE000) {
                u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00);
                i += 2;
            }
        }
        try pdf.appendCp(alloc, &out, u);
    }
    return out.toOwnedSlice(alloc);
}

fn firstCp(b: []const u8) u21 {
    if (b.len == 1) return b[0];
    if (b.len < 2) return 0;
    const u: u21 = std.mem.readInt(u16, b[0..2], .big);
    if (u >= 0xD800 and u < 0xDC00 and b.len >= 4) {
        const lo: u21 = std.mem.readInt(u16, b[2..4], .big);
        if (lo >= 0xDC00 and lo < 0xE000) return 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00);
    }
    return u;
}

fn rangeLess(_: void, a: CMap.Range, b: CMap.Range) bool {
    return a.lo < b.lo;
}

pub fn parseCMap(arena: Allocator, data: []const u8) Allocator.Error!*CMap {
    const cm = try arena.create(CMap);
    cm.* = .{};
    var ranges: std.ArrayList(CMap.Range) = .empty;
    var lx: Lexer = .{ .data = data, .arena = arena, .max_depth = 16 };
    while (true) {
        const o = (lx.next(0) catch break) orelse break;
        if (o != .keyword) continue;
        const kw = o.keyword;
        if (std.mem.eql(u8, kw, "beginbfchar")) {
            while (true) {
                const a = (lx.next(0) catch break) orelse break;
                if (a == .keyword) break;
                const b = (lx.next(0) catch break) orelse break;
                if (b == .keyword) break;
                if (a == .string and b == .string and cm.chars.count() < 300_000) {
                    try cm.chars.put(arena, beCode(a.string), try utf16ToUtf8(arena, b.string));
                }
            }
        } else if (std.mem.eql(u8, kw, "beginbfrange")) {
            while (true) {
                const a = (lx.next(0) catch break) orelse break;
                if (a == .keyword) break;
                const b = (lx.next(0) catch break) orelse break;
                if (b == .keyword) break;
                const c = (lx.next(0) catch break) orelse break;
                if (c == .keyword) break;
                if (a != .string or b != .string) continue;
                const lo = beCode(a.string);
                const hi = beCode(b.string);
                if (hi < lo) continue;
                switch (c) {
                    .string => |s| if (ranges.items.len < 100_000) try ranges.append(arena, .{ .lo = lo, .hi = hi, .base = firstCp(s) }),
                    .array => |arr| for (arr, 0..) |e, i| {
                        if (e != .string or lo + i > hi or cm.chars.count() > 300_000) break;
                        try cm.chars.put(arena, lo + @as(u32, @intCast(i)), try utf16ToUtf8(arena, e.string));
                    },
                    else => {},
                }
            }
        } else if (std.mem.eql(u8, kw, "begincodespacerange")) {
            while (true) {
                const a = (lx.next(0) catch break) orelse break;
                if (a == .keyword) break;
                const b = (lx.next(0) catch break) orelse break;
                if (b == .keyword) break;
                if (a == .string and cm.code_bytes == 0 and a.string.len >= 1 and a.string.len <= 4) cm.code_bytes = @intCast(a.string.len);
            }
        }
    }
    std.mem.sort(CMap.Range, ranges.items, {}, rangeLess);
    cm.ranges = ranges.items;
    return cm;
}

// ---------------------------------------------------------------------------
// Fonts
// ---------------------------------------------------------------------------

const helv_w = [95]u16{
    278, 278, 355, 556, 556, 889, 667, 222, 333, 333, 389, 584, 278, 333, 278, 278,
    556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
    1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
    667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
    333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
    556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584,
};
const times_w = [95]u16{
    250, 333, 408, 500, 500, 833, 778, 333, 333, 333, 500, 564, 250, 333, 250, 278,
    500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 278, 278, 564, 564, 564, 444,
    921, 722, 667, 667, 722, 611, 556, 722, 722, 333, 389, 722, 611, 889, 722, 722,
    556, 722, 667, 556, 611, 722, 722, 944, 722, 722, 611, 333, 278, 333, 469, 500,
    333, 444, 500, 444, 500, 444, 333, 500, 500, 278, 278, 500, 278, 778, 500, 500,
    500, 500, 333, 389, 278, 500, 500, 722, 500, 500, 444, 480, 200, 480, 541,
};

fn containsIgnoreCase(h: []const u8, n: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(h, n) != null;
}

pub const Font = struct {
    cid: bool = false,
    two_byte: bool = true,
    table: [256]u21 = [_]u21{0} ** 256,
    widths: [256]f32 = [_]f32{500} ** 256,
    w_scale: f32 = 1,
    tou: ?*CMap = null,
    dw: f32 = 1000,
    cid_w: std.AutoHashMapUnmanaged(u32, f32) = .empty,

    pub fn width(self: *const Font, code: u32) f32 {
        if (self.cid) return self.cid_w.get(code) orelse self.dw;
        return self.widths[code & 0xFF] * self.w_scale;
    }

    pub fn decode(self: *const Font, alloc: Allocator, code: u32, out: *std.ArrayList(u8), unmapped: *usize) Allocator.Error!void {
        if (self.tou) |m| {
            if (try m.lookup(alloc, code, out)) return;
        }
        if (!self.cid) {
            const cp = self.table[code & 0xFF];
            if (cp != 0) return appendNorm(alloc, out, cp);
            if (code >= 0x20 and code < 0x7F) return appendNorm(alloc, out, @intCast(code));
            unmapped.* += 1;
            return;
        }
        // Identity-H without ToUnicode: treat the code as Unicode (often wrong).
        unmapped.* += 1;
        if (code >= 0x20 and code < 0xFFFE and !(code >= 0xD800 and code < 0xE000)) try appendNorm(alloc, out, @intCast(code));
    }
};

pub fn defaultFont() Font {
    var f: Font = .{};
    f.table = enc.win_ansi;
    return f;
}

fn setStdWidths(f: *Font, base: []const u8) void {
    const tbl: ?*const [95]u16 = if (containsIgnoreCase(base, "courier") or containsIgnoreCase(base, "mono"))
        null
    else if (containsIgnoreCase(base, "times") or containsIgnoreCase(base, "serif") or containsIgnoreCase(base, "georgia") or containsIgnoreCase(base, "palatino") or containsIgnoreCase(base, "garamond") or containsIgnoreCase(base, "roman"))
        &times_w
    else
        &helv_w;
    for (0..256) |c| {
        if (tbl) |t| {
            f.widths[c] = if (c >= 32 and c <= 126) @floatFromInt(t[c - 32]) else 500;
        } else f.widths[c] = 600;
    }
}

pub fn loadFont(doc: *pdf.Doc, fd: pdf.Dict) pdf.Error!*Font {
    const arena = doc.arena();
    const f = try arena.create(Font);
    f.* = .{};
    const subtype = (try doc.get(fd, "Subtype"));
    const base_o = try doc.get(fd, "BaseFont");
    const base: []const u8 = if (base_o == .name) base_o.name else "";

    if (try doc.get(fd, "ToUnicode") == .stream) {
        const st = (try doc.get(fd, "ToUnicode")).stream;
        const data = doc.decodeStream(arena, st) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => null,
        };
        if (data) |d| f.tou = try parseCMap(arena, d);
    }

    if (subtype.nameIs("Type0")) {
        f.cid = true;
        f.two_byte = true;
        const e = try doc.get(fd, "Encoding");
        if (e == .stream) {
            const data = doc.decodeStream(arena, e.stream) catch null;
            if (data) |d| {
                const cm = try parseCMap(arena, d);
                if (cm.code_bytes == 1) f.two_byte = false;
            }
        }
        if (f.tou) |t| {
            if (t.code_bytes == 1) f.two_byte = false;
        }
        const desc = try doc.get(fd, "DescendantFonts");
        if (desc == .array and desc.array.len > 0) {
            const cf = (try doc.deref(desc.array[0])).asDict();
            if (cf) |cd| {
                if ((try doc.get(cd, "DW")).asNum()) |dw| f.dw = @floatCast(dw);
                const w = try doc.get(cd, "W");
                if (w == .array) try parseCidWidths(doc, arena, w.array, f);
            }
        }
        return f;
    }

    // simple font
    var have_widths = false;
    f.table = enc.win_ansi;
    const e = try doc.get(fd, "Encoding");
    var base_table: *const [256]u21 = &enc.win_ansi;
    switch (e) {
        .name => |n| base_table = baseTable(n, &enc.win_ansi),
        .dict => |ed| {
            const be = try doc.get(ed, "BaseEncoding");
            if (be == .name) base_table = baseTable(be.name, &enc.win_ansi) else if (subtype.nameIs("Type1") or subtype.nameIs("MMType1")) base_table = &enc.standard;
            f.table = base_table.*;
            const diffs = try doc.get(ed, "Differences");
            if (diffs == .array) {
                var code: i64 = 0;
                for (diffs.array) |item| {
                    const it = try doc.deref(item);
                    switch (it) {
                        .int => |i| code = i,
                        .real => |r| code = @intFromFloat(@max(-1, @min(255, r))),
                        .name => |gn| {
                            if (code >= 0 and code < 256) f.table[@intCast(code)] = enc.glyphToUnicode(gn);
                            code += 1;
                        },
                        else => {},
                    }
                }
            }
        },
        else => {
            if (subtype.nameIs("Type1") or subtype.nameIs("MMType1")) base_table = &enc.standard;
        },
    }
    if (e != .dict) f.table = base_table.*;

    const first = (try doc.get(fd, "FirstChar")).asInt() orelse 0;
    const wv = try doc.get(fd, "Widths");
    var missing: f32 = 500;
    if (try doc.get(fd, "FontDescriptor") == .dict) {
        const fdesc = (try doc.get(fd, "FontDescriptor")).dict;
        if ((try doc.get(fdesc, "MissingWidth")).asNum()) |mw| {
            if (mw > 0) missing = @floatCast(mw);
        }
    }
    if (wv == .array) {
        have_widths = true;
        @memset(&f.widths, missing);
        for (wv.array, 0..) |wo, i| {
            const idx = first + @as(i64, @intCast(i));
            if (idx < 0 or idx > 255) continue;
            const w = (try doc.deref(wo)).asNum() orelse continue;
            f.widths[@intCast(idx)] = @floatCast(w);
        }
    }
    if (!have_widths) setStdWidths(f, base);
    if (subtype.nameIs("Type3")) {
        const fm = try doc.get(fd, "FontMatrix");
        f.w_scale = 1;
        if (fm == .array and fm.array.len >= 1) {
            if (fm.array[0].asNum()) |s| f.w_scale = @floatCast(s * 1000);
        }
    }
    return f;
}

fn baseTable(name: []const u8, default: *const [256]u21) *const [256]u21 {
    if (std.mem.eql(u8, name, "WinAnsiEncoding")) return &enc.win_ansi;
    if (std.mem.eql(u8, name, "MacRomanEncoding")) return &enc.mac_roman;
    if (std.mem.eql(u8, name, "StandardEncoding")) return &enc.standard;
    return default;
}

fn parseCidWidths(doc: *pdf.Doc, arena: Allocator, arr: []const Obj, f: *Font) pdf.Error!void {
    var i: usize = 0;
    var budget: usize = 200_000;
    while (i < arr.len) {
        const c0 = (try doc.deref(arr[i])).asInt() orelse break;
        if (i + 1 >= arr.len) break;
        const nx = try doc.deref(arr[i + 1]);
        if (c0 < 0) break;
        if (nx == .array) {
            for (nx.array, 0..) |wo, k| {
                if (budget == 0) return;
                budget -= 1;
                const w = (try doc.deref(wo)).asNum() orelse continue;
                try f.cid_w.put(arena, @intCast(c0 + @as(i64, @intCast(k))), @floatCast(w));
            }
            i += 2;
        } else {
            const c1 = nx.asInt() orelse break;
            if (i + 2 >= arr.len) break;
            const w = (try doc.deref(arr[i + 2])).asNum() orelse break;
            var c = c0;
            while (c <= c1 and c - c0 < 65536) : (c += 1) {
                if (budget == 0) return;
                budget -= 1;
                try f.cid_w.put(arena, @intCast(c), @floatCast(w));
            }
            i += 3;
        }
    }
}

// ---------------------------------------------------------------------------
// Matrices
// ---------------------------------------------------------------------------

const Mat = struct {
    a: f64 = 1,
    b: f64 = 0,
    c: f64 = 0,
    d: f64 = 1,
    e: f64 = 0,
    f: f64 = 0,

    /// Apply `self` first, then `n`.
    fn mul(m: Mat, n: Mat) Mat {
        return .{
            .a = m.a * n.a + m.b * n.c,
            .b = m.a * n.b + m.b * n.d,
            .c = m.c * n.a + m.d * n.c,
            .d = m.c * n.b + m.d * n.d,
            .e = m.e * n.a + m.f * n.c + n.e,
            .f = m.e * n.b + m.f * n.d + n.f,
        };
    }
    fn trans(tx: f64, ty: f64) Mat {
        return .{ .e = tx, .f = ty };
    }
    fn fromOps(ops: []const Obj) ?Mat {
        if (ops.len < 6) return null;
        var v: [6]f64 = undefined;
        for (0..6) |i| v[i] = ops[ops.len - 6 + i].asNum() orelse return null;
        return .{ .a = v[0], .b = v[1], .c = v[2], .d = v[3], .e = v[4], .f = v[5] };
    }
};

// ---------------------------------------------------------------------------
// Extraction
// ---------------------------------------------------------------------------

pub const PageText = struct {
    /// Owned by the caller's allocator.
    text: []u8,
    has_images: bool = false,
    unmapped: usize = 0,
    truncated: bool = false,
    /// A content stream could not be decoded (unsupported filter etc).
    decode_error: bool = false,
};

const MAX_OPS: usize = 4_000_000;
const MAX_FORM_DEPTH: u32 = 8;
const MAX_FORM_CALLS: u32 = 4000;

const GState = struct {
    ctm: Mat = .{},
    tc: f64 = 0,
    tw: f64 = 0,
    th: f64 = 1,
    tl: f64 = 0,
    font: ?*Font = null,
    size: f64 = 0,
    rise: f64 = 0,
};

pub const Extractor = struct {
    doc: *pdf.Doc,
    gpa: Allocator,
    fonts: std.AutoHashMapUnmanaged(u64, *Font) = .empty,
    fallback: Font,

    pub fn init(gpa: Allocator, doc: *pdf.Doc) Extractor {
        return .{ .doc = doc, .gpa = gpa, .fallback = defaultFont() };
    }

    pub fn deinit(self: *Extractor) void {
        _ = self;
    }

    /// Extract one page. Stops once `max_bytes` of text were produced.
    pub fn page(self: *Extractor, pg: pdf.Page, max_bytes: usize) pdf.Error!PageText {
        var run: Run = .{ .ex = self, .max_bytes = max_bytes };
        defer run.deinit();
        const contents = try self.doc.get(pg.dict, "Contents");
        var parts: std.ArrayList(u8) = .empty;
        defer parts.deinit(self.gpa);
        switch (contents) {
            .stream => |st| try self.appendStream(&parts, st, &run),
            .array => |arr| for (arr) |e| {
                const so = try self.doc.deref(e);
                if (so == .stream) {
                    try self.appendStream(&parts, so.stream, &run);
                    try parts.append(self.gpa, '\n');
                }
            },
            else => {},
        }
        try run.runContent(parts.items, pg.resources, 0);
        return run.finish();
    }

    fn appendStream(self: *Extractor, parts: *std.ArrayList(u8), st: *const pdf.Stream, run: *Run) pdf.Error!void {
        const d = self.doc.decodeStream(self.gpa, st) catch |e| switch (e) {
            error.OutOfMemory, error.LimitExceeded => return e,
            else => {
                run.decode_error = true;
                return;
            },
        };
        defer self.gpa.free(d);
        if (parts.items.len + d.len > 64 << 20) return error.LimitExceeded;
        try parts.appendSlice(self.gpa, d);
    }

    fn fontFor(self: *Extractor, resources: ?Obj, name: []const u8) pdf.Error!*Font {
        const res = resources orelse return &self.fallback;
        const rd = (try self.doc.deref(res)).asDict() orelse return &self.fallback;
        const fdict = (try self.doc.get(rd, "Font")).asDict() orelse return &self.fallback;
        const raw = pdf.dictGet(fdict, name) orelse return &self.fallback;
        const o = try self.doc.deref(raw);
        const d = o.asDict() orelse return &self.fallback;
        const key: u64 = if (raw == .ref) raw.ref.num else (@as(u64, 1) << 63) | @intFromPtr(d.ptr);
        if (self.fonts.get(key)) |f| return f;
        const f = try loadFont(self.doc, d);
        try self.fonts.put(self.doc.arena(), key, f);
        return f;
    }
};

const Run = struct {
    ex: *Extractor,
    max_bytes: usize,
    out: std.ArrayList(u8) = .empty,
    shown: std.ArrayList(u8) = .empty,
    gs: GState = .{},
    stack: [32]GState = undefined,
    sp: usize = 0,
    tm: Mat = .{},
    tlm: Mat = .{},
    ops_done: usize = 0,
    form_calls: u32 = 0,
    form_stack: [MAX_FORM_DEPTH]u32 = undefined,
    stop: bool = false,
    truncated: bool = false,
    has_images: bool = false,
    decode_error: bool = false,
    unmapped: usize = 0,
    // last shown run, in device space
    have_last: bool = false,
    last_x: f64 = 0,
    last_y: f64 = 0,
    last_size: f64 = 0,

    fn deinit(self: *Run) void {
        self.out.deinit(self.ex.gpa);
        self.shown.deinit(self.ex.gpa);
    }

    fn finish(self: *Run) Allocator.Error!PageText {
        const gpa = self.ex.gpa;
        const text = try tidy(gpa, self.out.items);
        return .{ .text = text, .has_images = self.has_images, .unmapped = self.unmapped, .truncated = self.truncated, .decode_error = self.decode_error };
    }

    fn runContent(self: *Run, data: []const u8, resources: ?Obj, depth: u32) pdf.Error!void {
        var scratch = std.heap.ArenaAllocator.init(self.ex.gpa);
        defer scratch.deinit();
        var lx: Lexer = .{ .data = data, .arena = scratch.allocator(), .max_depth = 32 };
        var operands: [48]Obj = undefined;
        var n: usize = 0;
        while (!self.stop) {
            const o = (lx.next(0) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => return, // garbage: keep what we have
            }) orelse return;
            if (o != .keyword) {
                if (n < operands.len) {
                    operands[n] = o;
                    n += 1;
                }
                continue;
            }
            self.ops_done += 1;
            if (self.ops_done > MAX_OPS) {
                self.stop = true;
                return;
            }
            try self.op(o.keyword, operands[0..n], &lx, resources, depth);
            n = 0;
        }
    }

    fn op(self: *Run, kw: []const u8, ops: []const Obj, lx: *Lexer, resources: ?Obj, depth: u32) pdf.Error!void {
        const eql = std.mem.eql;
        const gs = &self.gs;
        if (kw.len == 1) {
            switch (kw[0]) {
                'q' => {
                    if (self.sp < self.stack.len) {
                        self.stack[self.sp] = gs.*;
                        self.sp += 1;
                    }
                },
                'Q' => {
                    if (self.sp > 0) {
                        self.sp -= 1;
                        gs.* = self.stack[self.sp];
                    }
                },
                '\'' => {
                    self.nextLine();
                    if (ops.len >= 1) try self.showObj(ops[ops.len - 1]);
                },
                '"' => {
                    if (ops.len >= 3) {
                        gs.tw = ops[0].asNum() orelse gs.tw;
                        gs.tc = ops[1].asNum() orelse gs.tc;
                        self.nextLine();
                        try self.showObj(ops[2]);
                    }
                },
                else => {},
            }
            return;
        }
        if (kw.len == 2) {
            if (eql(u8, kw, "cm")) {
                if (Mat.fromOps(ops)) |m| gs.ctm = m.mul(gs.ctm);
            } else if (eql(u8, kw, "BT")) {
                self.tm = .{};
                self.tlm = .{};
            } else if (eql(u8, kw, "Tj")) {
                if (ops.len >= 1) try self.showObj(ops[ops.len - 1]);
            } else if (eql(u8, kw, "TJ")) {
                if (ops.len >= 1 and ops[ops.len - 1] == .array) {
                    for (ops[ops.len - 1].array) |el| {
                        switch (el) {
                            .string => try self.showObj(el),
                            .int, .real => {
                                const v = el.asNum().?;
                                self.tm = Mat.trans(-v / 1000.0 * gs.size * gs.th, 0).mul(self.tm);
                            },
                            else => {},
                        }
                    }
                }
            } else if (eql(u8, kw, "Tc")) {
                if (ops.len >= 1) gs.tc = ops[ops.len - 1].asNum() orelse gs.tc;
            } else if (eql(u8, kw, "Tw")) {
                if (ops.len >= 1) gs.tw = ops[ops.len - 1].asNum() orelse gs.tw;
            } else if (eql(u8, kw, "Tz")) {
                if (ops.len >= 1) gs.th = (ops[ops.len - 1].asNum() orelse 100) / 100.0;
            } else if (eql(u8, kw, "TL")) {
                if (ops.len >= 1) gs.tl = ops[ops.len - 1].asNum() orelse gs.tl;
            } else if (eql(u8, kw, "Ts")) {
                if (ops.len >= 1) gs.rise = ops[ops.len - 1].asNum() orelse gs.rise;
            } else if (eql(u8, kw, "Tf")) {
                if (ops.len >= 2 and ops[ops.len - 2] == .name) {
                    gs.font = try self.ex.fontFor(resources, ops[ops.len - 2].name);
                    gs.size = ops[ops.len - 1].asNum() orelse 0;
                }
            } else if (eql(u8, kw, "Td")) {
                if (ops.len >= 2) self.moveLine(ops[ops.len - 2].asNum() orelse 0, ops[ops.len - 1].asNum() orelse 0);
            } else if (eql(u8, kw, "TD")) {
                if (ops.len >= 2) {
                    const ty = ops[ops.len - 1].asNum() orelse 0;
                    gs.tl = -ty;
                    self.moveLine(ops[ops.len - 2].asNum() orelse 0, ty);
                }
            } else if (eql(u8, kw, "Tm")) {
                if (Mat.fromOps(ops)) |m| {
                    self.tm = m;
                    self.tlm = m;
                }
            } else if (eql(u8, kw, "T*")) {
                self.nextLine();
            } else if (eql(u8, kw, "Do")) {
                if (ops.len >= 1 and ops[ops.len - 1] == .name) try self.doXObject(ops[ops.len - 1].name, resources, depth);
            } else if (eql(u8, kw, "BI")) {
                self.has_images = true;
                skipInlineImage(lx);
            }
        }
    }

    fn moveLine(self: *Run, tx: f64, ty: f64) void {
        self.tlm = Mat.trans(tx, ty).mul(self.tlm);
        self.tm = self.tlm;
    }

    fn nextLine(self: *Run) void {
        self.moveLine(0, -self.gs.tl);
    }

    fn showObj(self: *Run, o: Obj) pdf.Error!void {
        if (o == .string) try self.showString(o.string);
    }

    fn showString(self: *Run, bytes: []const u8) pdf.Error!void {
        const gpa = self.ex.gpa;
        const gs = &self.gs;
        const font: *const Font = gs.font orelse &self.ex.fallback;
        self.shown.clearRetainingCapacity();
        var adv: f64 = 0;
        var i: usize = 0;
        while (i < bytes.len) {
            var code: u32 = bytes[i];
            var step: usize = 1;
            if (font.cid and font.two_byte and i + 1 < bytes.len) {
                code = (@as(u32, bytes[i]) << 8) | bytes[i + 1];
                step = 2;
            }
            try font.decode(gpa, code, &self.shown, &self.unmapped);
            const w: f64 = font.width(code);
            adv += (w / 1000.0 * gs.size + gs.tc + (if (code == 32 and step == 1) gs.tw else 0)) * gs.th;
            i += step;
        }
        const m0 = self.tm.mul(gs.ctm);
        const sx = gs.rise * m0.c + m0.e;
        const sy = gs.rise * m0.d + m0.f;
        self.tm = Mat.trans(adv, 0).mul(self.tm);
        const m1 = self.tm.mul(gs.ctm);
        const ex_ = gs.rise * m1.c + m1.e;
        const ey_ = gs.rise * m1.d + m1.f;
        const size = @max(1e-3, @abs(gs.size) * std.math.hypot(m0.c, m0.d));
        const dl = std.math.hypot(m0.a, m0.b);
        const dirx = if (dl > 1e-9) m0.a / dl else 1;
        const diry = if (dl > 1e-9) m0.b / dl else 0;
        try self.emit(sx, sy, ex_, ey_, size, dirx, diry);
    }

    fn emit(self: *Run, sx: f64, sy: f64, ex_: f64, ey_: f64, size: f64, dirx: f64, diry: f64) Allocator.Error!void {
        const gpa = self.ex.gpa;
        const text = self.shown.items;
        if (text.len == 0) return;
        if (self.have_last) {
            const dx = sx - self.last_x;
            const dy = sy - self.last_y;
            const along = dx * dirx + dy * diry;
            const across = -dx * diry + dy * dirx;
            const ref = @max(size, self.last_size);
            const ac = @abs(across);
            if (ac > 0.5 * ref) {
                try self.trimSpaceAndNewline(if (ac > 2.2 * ref) 2 else 1);
            } else if (along > 0.18 * ref or along < -0.5 * ref) {
                try self.addSpace(text);
            }
        }
        try self.out.appendSlice(gpa, text);
        self.have_last = true;
        self.last_x = ex_;
        self.last_y = ey_;
        self.last_size = size;
        if (self.out.items.len >= self.max_bytes) {
            self.stop = true;
            self.truncated = true;
        }
    }

    fn addSpace(self: *Run, next_text: []const u8) Allocator.Error!void {
        const o = self.out.items;
        if (o.len == 0) return;
        const last = o[o.len - 1];
        if (last == ' ' or last == '\n') return;
        if (next_text[0] == ' ') return;
        try self.out.append(self.ex.gpa, ' ');
    }

    fn trimSpaceAndNewline(self: *Run, n: u8) Allocator.Error!void {
        while (self.out.items.len > 0 and self.out.items[self.out.items.len - 1] == ' ') _ = self.out.pop();
        if (self.out.items.len == 0) return;
        var have: u8 = 0;
        var k = self.out.items.len;
        while (k > 0 and self.out.items[k - 1] == '\n' and have < 2) : (k -= 1) have += 1;
        while (have < n) : (have += 1) try self.out.append(self.ex.gpa, '\n');
    }

    fn doXObject(self: *Run, name: []const u8, resources: ?Obj, depth: u32) pdf.Error!void {
        const doc = self.ex.doc;
        const res = resources orelse return;
        const rd = (try doc.deref(res)).asDict() orelse return;
        const xd = (try doc.get(rd, "XObject")).asDict() orelse return;
        const raw = pdf.dictGet(xd, name) orelse return;
        const xo = try doc.deref(raw);
        if (xo != .stream) return;
        const st = xo.stream;
        const sub = try doc.get(st.dict, "Subtype");
        if (sub.nameIs("Image")) {
            self.has_images = true;
            return;
        }
        if (!sub.nameIs("Form")) return;
        if (depth >= MAX_FORM_DEPTH or self.form_calls >= MAX_FORM_CALLS) return;
        if (raw == .ref) {
            for (self.form_stack[0..depth]) |n| if (n == raw.ref.num) return; // cycle
            self.form_stack[depth] = raw.ref.num;
        } else self.form_stack[depth] = 0;
        self.form_calls += 1;
        const data = doc.decodeStream(self.ex.gpa, st) catch |e| switch (e) {
            error.OutOfMemory, error.LimitExceeded => return e,
            else => {
                self.decode_error = true;
                return;
            },
        };
        defer self.ex.gpa.free(data);
        self.ops_done += data.len / 16;
        const saved = self.gs;
        const saved_tm = self.tm;
        const saved_tlm = self.tlm;
        const saved_sp = self.sp;
        const mo = try doc.get(st.dict, "Matrix");
        if (mo == .array) {
            if (Mat.fromOps(mo.array)) |m| self.gs.ctm = m.mul(self.gs.ctm);
        }
        const fres = try doc.get(st.dict, "Resources");
        try self.runContent(data, if (fres == .dict) fres else resources, depth + 1);
        self.gs = saved;
        self.tm = saved_tm;
        self.tlm = saved_tlm;
        self.sp = saved_sp;
    }
};

fn skipInlineImage(lx: *Lexer) void {
    // BI <dict tokens> ID <data> EI
    const data = lx.data;
    var p = lx.pos;
    // find "ID" followed by whitespace
    while (std.mem.indexOfPos(u8, data, p, "ID")) |i| {
        if (i > 0 and pdf.isWs(data[i - 1]) and (i + 2 >= data.len or pdf.isWs(data[i + 2]))) {
            p = i + 3;
            break;
        }
        p = i + 2;
    } else {
        lx.pos = data.len;
        return;
    }
    // find "EI" surrounded by whitespace
    while (std.mem.indexOfPos(u8, data, p, "EI")) |i| {
        const before = i == 0 or pdf.isWs(data[i - 1]);
        const after = i + 2 >= data.len or pdf.isWs(data[i + 2]);
        if (before and after) {
            lx.pos = i + 2;
            return;
        }
        p = i + 2;
    }
    lx.pos = data.len;
}

/// Trim trailing blanks per line, cap blank lines at one, trim the ends.
fn tidy(alloc: Allocator, raw: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var blank: u32 = 0;
    var it = std.mem.splitScalar(u8, raw, '\n');
    var first = true;
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) {
            blank += 1;
            continue;
        }
        if (!first) {
            try out.append(alloc, '\n');
            if (blank > 0) try out.append(alloc, '\n');
        }
        first = false;
        blank = 0;
        try out.appendSlice(alloc, t);
    }
    return out.toOwnedSlice(alloc);
}

test "tidy" {
    const a = std.testing.allocator;
    const r = try tidy(a, "\n\nHello  \n\n\n\nWorld\n \nx\n");
    defer a.free(r);
    try std.testing.expectEqualStrings("Hello\n\nWorld\n\nx", r);
}

test "cmap parse" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const cm = try parseCMap(ar.allocator(),
        \\/CIDInit /ProcSet findresource begin
        \\1 begincodespacerange <0000> <FFFF> endcodespacerange
        \\2 beginbfchar
        \\<0003> <0020>
        \\<0004> <00660069>
        \\endbfchar
        \\2 beginbfrange
        \\<0010> <0012> <0041>
        \\<0020> <0021> [<0058> <0059>]
        \\endbfrange
    );
    try std.testing.expectEqual(@as(u8, 2), cm.code_bytes);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    try std.testing.expect(try cm.lookup(a, 3, &out));
    try std.testing.expect(try cm.lookup(a, 4, &out));
    try std.testing.expect(try cm.lookup(a, 0x11, &out));
    try std.testing.expect(try cm.lookup(a, 0x21, &out));
    try std.testing.expect(!(try cm.lookup(a, 0x99, &out)));
    try std.testing.expectEqualStrings(" fiBY", out.items);
}
