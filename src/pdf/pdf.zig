//! Pure-Zig PDF object layer: lexer, objects, xref tables/streams, object
//! streams, xref rebuild by scanning, stream filters, page tree.
//!
//! Everything parsed lives in the Doc's arena. Nothing here follows external
//! references, runs JavaScript or writes anywhere. All loops are bounded by
//! the data size or an explicit cap, and malformed input yields an error.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    OutOfMemory,
    Malformed,
    Unsupported,
    LimitExceeded,
    NotPdf,
};

pub const Limits = struct {
    /// Cap on one stream's inflated size.
    max_stream_bytes: usize = 32 << 20,
    /// Cap on the total inflated bytes of one document (work cap).
    max_total_bytes: usize = 256 << 20,
    max_objects: usize = 1_500_000,
    max_depth: u32 = 64,
};

pub const Ref = struct { num: u32, gen: u32 };
pub const Entry = struct { key: []const u8, val: Obj };
pub const Dict = []const Entry;
pub const Stream = struct { dict: Dict, raw: []const u8 };

pub const Obj = union(enum) {
    null,
    bool: bool,
    int: i64,
    real: f64,
    string: []const u8,
    name: []const u8,
    array: []const Obj,
    dict: Dict,
    stream: *const Stream,
    ref: Ref,
    /// Bare token (operators in content streams, `obj`, `stream`...).
    keyword: []const u8,

    pub fn asNum(self: Obj) ?f64 {
        return switch (self) {
            .int => |i| @floatFromInt(i),
            .real => |r| r,
            else => null,
        };
    }
    pub fn asInt(self: Obj) ?i64 {
        return switch (self) {
            .int => |i| i,
            .real => |r| if (std.math.isFinite(r) and @abs(r) < 1e15) @as(i64, @intFromFloat(r)) else null,
            else => null,
        };
    }
    pub fn nameIs(self: Obj, s: []const u8) bool {
        return self == .name and std.mem.eql(u8, self.name, s);
    }
    pub fn asDict(self: Obj) ?Dict {
        return switch (self) {
            .dict => |d| d,
            .stream => |s| s.dict,
            else => null,
        };
    }
};

pub const null_obj: Obj = .{ .null = {} };

pub fn dictGet(d: Dict, key: []const u8) ?Obj {
    for (d) |e| if (std.mem.eql(u8, e.key, key)) return e.val;
    return null;
}

pub fn isWs(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\r' or c == '\t' or c == 0x0c or c == 0;
}
pub fn isDelim(c: u8) bool {
    return switch (c) {
        '(', ')', '<', '>', '[', ']', '{', '}', '/', '%' => true,
        else => false,
    };
}
fn isRegular(c: u8) bool {
    return !isWs(c) and !isDelim(c);
}

// ---------------------------------------------------------------------------
// Lexer / object parser (also used for content streams and CMaps)
// ---------------------------------------------------------------------------

pub const Lexer = struct {
    data: []const u8,
    pos: usize = 0,
    arena: Allocator,
    max_depth: u32 = 64,

    pub fn skipWs(self: *Lexer) void {
        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if (isWs(c)) {
                self.pos += 1;
            } else if (c == '%') {
                while (self.pos < self.data.len and self.data[self.pos] != '\n' and self.data[self.pos] != '\r') self.pos += 1;
            } else break;
        }
    }

    fn startsWith(self: *const Lexer, s: []const u8) bool {
        return std.mem.startsWith(u8, self.data[self.pos..], s);
    }

    /// Next object, or null at end of data. Bare tokens come back as `.keyword`.
    pub fn next(self: *Lexer, depth: u32) Error!?Obj {
        self.skipWs();
        if (self.pos >= self.data.len) return null;
        if (depth > self.max_depth) return error.Malformed;
        const c = self.data[self.pos];
        switch (c) {
            '/' => {
                self.pos += 1;
                return .{ .name = try self.readName() };
            },
            '(' => return .{ .string = try self.readLiteralString() },
            '<' => {
                if (self.pos + 1 < self.data.len and self.data[self.pos + 1] == '<') {
                    self.pos += 2;
                    return .{ .dict = try self.readDictBody(depth) };
                }
                return .{ .string = try self.readHexString() };
            },
            '[' => {
                self.pos += 1;
                var items: std.ArrayList(Obj) = .empty;
                while (true) {
                    self.skipWs();
                    if (self.pos >= self.data.len) return error.Malformed;
                    if (self.data[self.pos] == ']') {
                        self.pos += 1;
                        break;
                    }
                    const v = (try self.next(depth + 1)) orelse return error.Malformed;
                    if (v == .keyword) {
                        // stray token inside an array: skip it
                        continue;
                    }
                    try items.append(self.arena, v);
                }
                return .{ .array = try items.toOwnedSlice(self.arena) };
            },
            ']', '>', ')', '{', '}' => {
                self.pos += 1;
                return .{ .keyword = self.data[self.pos - 1 .. self.pos] };
            },
            else => {},
        }
        // number or keyword token
        const start = self.pos;
        while (self.pos < self.data.len and isRegular(self.data[self.pos])) self.pos += 1;
        const tok = self.data[start..self.pos];
        if (tok.len == 0) {
            self.pos += 1;
            return .{ .keyword = self.data[start..self.pos] };
        }
        const c0 = tok[0];
        if ((c0 >= '0' and c0 <= '9') or c0 == '+' or c0 == '-' or c0 == '.') {
            if (std.fmt.parseInt(i64, tok, 10)) |iv| {
                if (iv >= 0 and iv <= std.math.maxInt(u32)) {
                    if (self.tryRef(iv)) |r| return .{ .ref = r };
                }
                return .{ .int = iv };
            } else |_| {}
            if (std.fmt.parseFloat(f64, tok)) |fv| {
                if (std.math.isFinite(fv)) return .{ .real = fv };
            } else |_| {}
            // things like "--5" or "4-3": best effort
            return .{ .int = 0 };
        }
        if (std.mem.eql(u8, tok, "true")) return .{ .bool = true };
        if (std.mem.eql(u8, tok, "false")) return .{ .bool = false };
        if (std.mem.eql(u8, tok, "null")) return .null;
        return .{ .keyword = tok };
    }

    /// After an integer: is this `gen R`?
    fn tryRef(self: *Lexer, n: i64) ?Ref {
        const save = self.pos;
        var p = self.pos;
        while (p < self.data.len and isWs(self.data[p])) p += 1;
        const gs = p;
        while (p < self.data.len and self.data[p] >= '0' and self.data[p] <= '9') p += 1;
        if (p == gs or p - gs > 6 or p >= self.data.len or !isWs(self.data[p])) return null;
        const gen = std.fmt.parseInt(u32, self.data[gs..p], 10) catch return null;
        while (p < self.data.len and isWs(self.data[p])) p += 1;
        if (p < self.data.len and self.data[p] == 'R' and (p + 1 >= self.data.len or !isRegular(self.data[p + 1]))) {
            self.pos = p + 1;
            return .{ .num = @intCast(n), .gen = gen };
        }
        self.pos = save;
        return null;
    }

    fn readName(self: *Lexer) Error![]const u8 {
        const start = self.pos;
        var has_hash = false;
        while (self.pos < self.data.len and isRegular(self.data[self.pos])) : (self.pos += 1) {
            if (self.data[self.pos] == '#') has_hash = true;
        }
        const raw = self.data[start..self.pos];
        if (!has_hash) return raw;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '#' and i + 2 < raw.len) {
                if (std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16)) |b| {
                    try out.append(self.arena, b);
                    i += 2;
                    continue;
                } else |_| {}
            }
            try out.append(self.arena, raw[i]);
        }
        return out.toOwnedSlice(self.arena);
    }

    fn readLiteralString(self: *Lexer) Error![]const u8 {
        self.pos += 1; // (
        var out: std.ArrayList(u8) = .empty;
        var nest: u32 = 1;
        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            self.pos += 1;
            switch (c) {
                '(' => {
                    nest += 1;
                    try out.append(self.arena, c);
                },
                ')' => {
                    nest -= 1;
                    if (nest == 0) return out.toOwnedSlice(self.arena);
                    try out.append(self.arena, c);
                },
                '\\' => {
                    if (self.pos >= self.data.len) break;
                    const e = self.data[self.pos];
                    self.pos += 1;
                    switch (e) {
                        'n' => try out.append(self.arena, '\n'),
                        'r' => try out.append(self.arena, '\r'),
                        't' => try out.append(self.arena, '\t'),
                        'b' => try out.append(self.arena, 8),
                        'f' => try out.append(self.arena, 12),
                        '\r' => {
                            if (self.pos < self.data.len and self.data[self.pos] == '\n') self.pos += 1;
                        },
                        '\n' => {},
                        '0'...'7' => {
                            var v: u32 = e - '0';
                            var k: u8 = 0;
                            while (k < 2 and self.pos < self.data.len and self.data[self.pos] >= '0' and self.data[self.pos] <= '7') : (k += 1) {
                                v = v * 8 + (self.data[self.pos] - '0');
                                self.pos += 1;
                            }
                            try out.append(self.arena, @truncate(v));
                        },
                        else => try out.append(self.arena, e),
                    }
                },
                else => try out.append(self.arena, c),
            }
        }
        return out.toOwnedSlice(self.arena); // unterminated: keep what we have
    }

    fn readHexString(self: *Lexer) Error![]const u8 {
        self.pos += 1; // <
        var out: std.ArrayList(u8) = .empty;
        var hi: ?u8 = null;
        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            self.pos += 1;
            if (c == '>') break;
            const v: u8 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => continue,
            };
            if (hi) |h| {
                try out.append(self.arena, (h << 4) | v);
                hi = null;
            } else hi = v;
        }
        if (hi) |h| try out.append(self.arena, h << 4);
        return out.toOwnedSlice(self.arena);
    }

    fn readDictBody(self: *Lexer, depth: u32) Error!Dict {
        var entries: std.ArrayList(Entry) = .empty;
        while (true) {
            self.skipWs();
            if (self.pos >= self.data.len) return error.Malformed;
            if (self.startsWith(">>")) {
                self.pos += 2;
                break;
            }
            const k = (try self.next(depth + 1)) orelse return error.Malformed;
            if (k != .name) {
                // Recover from junk (e.g. a stray keyword) by skipping it.
                continue;
            }
            self.skipWs();
            if (self.startsWith(">>")) {
                self.pos += 2;
                break;
            }
            const v = (try self.next(depth + 1)) orelse return error.Malformed;
            if (v == .keyword) continue;
            try entries.append(self.arena, .{ .key = k.name, .val = v });
        }
        return entries.toOwnedSlice(self.arena);
    }
};

// ---------------------------------------------------------------------------
// Document
// ---------------------------------------------------------------------------

const XEntry = union(enum) {
    free,
    offset: usize,
    compressed: struct { stm: u32, idx: u32 },
};

const ObjStm = struct {
    data: []const u8,
    first: usize,
    nums: []const u32,
    offs: []const usize,
};

pub const Page = struct {
    dict: Dict,
    resources: ?Obj,
};

pub const Doc = struct {
    gpa: Allocator,
    arena_state: std.heap.ArenaAllocator,
    data: []const u8,
    limits: Limits,
    xref: std.AutoHashMapUnmanaged(u32, XEntry) = .empty,
    cache: std.AutoHashMapUnmanaged(u32, Obj) = .empty,
    objstms: std.AutoHashMapUnmanaged(u32, ?*ObjStm) = .empty,
    trailer: std.ArrayList(Entry) = .empty,
    pages: ?[]const Page = null,
    rebuilt: bool = false,
    depth: u32 = 0,
    total_inflated: usize = 0,
    version: []const u8 = "",

    pub fn arena(self: *Doc) Allocator {
        return self.arena_state.allocator();
    }

    /// `data` must outlive the Doc. Fails with NotPdf / Malformed when no
    /// usable catalog can be found even after scanning.
    pub fn open(gpa: Allocator, data: []const u8, limits: Limits) Error!*Doc {
        const head = data[0..@min(data.len, 1024)];
        const hp = std.mem.indexOf(u8, head, "%PDF-") orelse return error.NotPdf;
        const self = try gpa.create(Doc);
        self.* = .{ .gpa = gpa, .arena_state = .init(gpa), .data = data, .limits = limits };
        errdefer self.close();
        var ve = hp + 5;
        while (ve < head.len and ve < hp + 12 and !isWs(head[ve])) ve += 1;
        self.version = head[hp + 5 .. ve];

        var ok = false;
        if (self.loadXrefChain()) |_| {
            ok = self.hasCatalog();
        } else |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        }
        if (!ok) {
            try self.rebuild();
            if (!self.hasCatalog()) return error.Malformed;
        }
        return self;
    }

    pub fn close(self: *Doc) void {
        const gpa = self.gpa;
        self.arena_state.deinit();
        gpa.destroy(self);
    }

    fn hasCatalog(self: *Doc) bool {
        const root = self.trailerGet("Root") orelse return false;
        const r = self.deref(root) catch return false;
        const d = r.asDict() orelse return false;
        return dictGet(d, "Pages") != null;
    }

    pub fn trailerGet(self: *Doc, key: []const u8) ?Obj {
        for (self.trailer.items) |e| if (std.mem.eql(u8, e.key, key)) return e.val;
        return null;
    }

    fn mergeTrailer(self: *Doc, d: Dict) Error!void {
        for (d) |e| {
            if (self.trailerGet(e.key) == null) try self.trailer.append(self.arena(), e);
        }
    }

    pub fn isEncrypted(self: *Doc) bool {
        const e = self.trailerGet("Encrypt") orelse return false;
        return e != .null;
    }

    // ---- xref loading --------------------------------------------------

    fn findStartXref(self: *Doc) ?usize {
        const tail_start = self.data.len -| 2048;
        const idx = std.mem.lastIndexOf(u8, self.data[tail_start..], "startxref") orelse return null;
        var lx: Lexer = .{ .data = self.data, .pos = tail_start + idx + 9, .arena = self.arena() };
        const v = (lx.next(0) catch return null) orelse return null;
        const n = v.asInt() orelse return null;
        if (n < 0 or n >= self.data.len) return null;
        return @intCast(n);
    }

    fn loadXrefChain(self: *Doc) Error!void {
        var off = self.findStartXref() orelse return error.Malformed;
        var seen: std.AutoHashMapUnmanaged(usize, void) = .empty;
        var hops: u32 = 0;
        while (true) {
            if (seen.contains(off)) break;
            try seen.put(self.arena(), off, {});
            hops += 1;
            if (hops > 512) break;
            const prev = try self.loadXrefSection(off);
            off = prev orelse break;
        }
    }

    /// Returns /Prev when present.
    fn loadXrefSection(self: *Doc, off: usize) Error!?usize {
        if (off >= self.data.len) return error.Malformed;
        var lx: Lexer = .{ .data = self.data, .pos = off, .arena = self.arena() };
        lx.skipWs();
        var trailer_dict: Dict = undefined;
        if (lx.startsWith("xref")) {
            lx.pos += 4;
            while (true) {
                lx.skipWs();
                if (lx.startsWith("trailer")) {
                    lx.pos += 7;
                    break;
                }
                const a = (try lx.next(0)) orelse return error.Malformed;
                const b = (try lx.next(0)) orelse return error.Malformed;
                const start = a.asInt() orelse return error.Malformed;
                const count = b.asInt() orelse return error.Malformed;
                if (start < 0 or count < 0 or count > 10_000_000 or start > 0xFFFFFFF) return error.Malformed;
                var i: i64 = 0;
                while (i < count) : (i += 1) {
                    const o = (try lx.next(0)) orelse return error.Malformed;
                    const g = (try lx.next(0)) orelse return error.Malformed;
                    const k = (try lx.next(0)) orelse return error.Malformed;
                    if (k != .keyword) return error.Malformed;
                    const onum: u32 = @intCast(start + i);
                    const gop = try self.xref.getOrPut(self.arena(), onum);
                    if (gop.found_existing) continue;
                    if (self.xref.count() > self.limits.max_objects) return error.LimitExceeded;
                    if (k.keyword.len == 1 and k.keyword[0] == 'n') {
                        const ov = o.asInt() orelse return error.Malformed;
                        _ = g;
                        if (ov < 0 or ov >= self.data.len) {
                            gop.value_ptr.* = .free;
                        } else gop.value_ptr.* = .{ .offset = @intCast(ov) };
                    } else gop.value_ptr.* = .free;
                }
            }
            const t = (try lx.next(0)) orelse return error.Malformed;
            trailer_dict = t.asDict() orelse return error.Malformed;
            try self.mergeTrailer(trailer_dict);
            if (dictGet(trailer_dict, "XRefStm")) |xs| {
                if (xs.asInt()) |xo| {
                    if (xo > 0 and xo < self.data.len) _ = self.loadXrefSection(@intCast(xo)) catch |e| switch (e) {
                        error.OutOfMemory => return e,
                        else => null,
                    };
                }
            }
        } else {
            const obj = try self.parseIndirectAt(off, null);
            if (obj != .stream) return error.Malformed;
            const st = obj.stream;
            if (!(dictGet(st.dict, "Type") orelse null_obj).nameIs("XRef")) return error.Malformed;
            trailer_dict = st.dict;
            try self.mergeTrailer(trailer_dict);
            const data = try self.decodeStream(self.arena(), st);
            try self.loadXrefStreamEntries(st.dict, data);
        }
        if (dictGet(trailer_dict, "Prev")) |p| {
            if (p.asInt()) |pv| {
                if (pv > 0 and pv < self.data.len) return @intCast(pv);
            }
        }
        return null;
    }

    fn loadXrefStreamEntries(self: *Doc, d: Dict, data: []const u8) Error!void {
        const wv = dictGet(d, "W") orelse return error.Malformed;
        if (wv != .array or wv.array.len < 3) return error.Malformed;
        var w: [3]usize = undefined;
        for (0..3) |i| {
            const n = wv.array[i].asInt() orelse return error.Malformed;
            if (n < 0 or n > 8) return error.Malformed;
            w[i] = @intCast(n);
        }
        const rec = w[0] + w[1] + w[2];
        if (rec == 0) return error.Malformed;
        var ranges: std.ArrayList([2]i64) = .empty;
        if (dictGet(d, "Index")) |iv| {
            if (iv == .array) {
                var i: usize = 0;
                while (i + 1 < iv.array.len) : (i += 2) {
                    const a = iv.array[i].asInt() orelse return error.Malformed;
                    const b = iv.array[i + 1].asInt() orelse return error.Malformed;
                    try ranges.append(self.arena(), .{ a, b });
                }
            }
        }
        if (ranges.items.len == 0) {
            const size = (dictGet(d, "Size") orelse null_obj).asInt() orelse return error.Malformed;
            try ranges.append(self.arena(), .{ 0, size });
        }
        var pos: usize = 0;
        for (ranges.items) |r| {
            if (r[0] < 0 or r[1] < 0 or r[0] > 0xFFFFFFF) return error.Malformed;
            var i: i64 = 0;
            while (i < r[1]) : (i += 1) {
                if (pos + rec > data.len) return;
                const t: u64 = if (w[0] == 0) 1 else readBE(data[pos .. pos + w[0]]);
                const f2 = readBE(data[pos + w[0] .. pos + w[0] + w[1]]);
                const f3 = readBE(data[pos + w[0] + w[1] .. pos + rec]);
                pos += rec;
                const onum: u32 = @intCast(r[0] + i);
                const gop = try self.xref.getOrPut(self.arena(), onum);
                if (gop.found_existing) continue;
                if (self.xref.count() > self.limits.max_objects) return error.LimitExceeded;
                gop.value_ptr.* = switch (t) {
                    0 => .free,
                    1 => if (f2 < self.data.len) XEntry{ .offset = @intCast(f2) } else .free,
                    2 => .{ .compressed = .{ .stm = @truncate(f2), .idx = @truncate(f3) } },
                    else => .free,
                };
            }
        }
    }

    fn readBE(b: []const u8) u64 {
        var v: u64 = 0;
        for (b) |c| v = (v << 8) | c;
        return v;
    }

    /// Rebuild the xref by scanning the file for `N G obj` headers.
    fn rebuild(self: *Doc) Error!void {
        self.rebuilt = true;
        self.xref = .empty;
        self.cache = .empty;
        self.objstms = .empty;
        self.trailer = .empty;
        self.pages = null;
        const data = self.data;
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, data, pos, "obj")) |i| {
            pos = i + 3;
            if (i >= 3 and std.mem.eql(u8, data[i - 3 .. i], "end")) continue;
            if (pos < data.len and isRegular(data[pos])) continue;
            var j = i;
            while (j > 0 and isWs(data[j - 1])) j -= 1;
            const gen_end = j;
            while (j > 0 and data[j - 1] >= '0' and data[j - 1] <= '9') j -= 1;
            if (j == gen_end) continue;
            const ws_end = j;
            while (j > 0 and isWs(data[j - 1])) j -= 1;
            if (j == ws_end) continue;
            const num_end = j;
            while (j > 0 and data[j - 1] >= '0' and data[j - 1] <= '9') j -= 1;
            if (j == num_end or num_end - j > 9) continue;
            const onum = std.fmt.parseInt(u32, data[j..num_end], 10) catch continue;
            try self.xref.put(self.arena(), onum, .{ .offset = j });
            if (self.xref.count() > self.limits.max_objects) return error.LimitExceeded;
        }
        // Trailers (later ones are newer, so scan from the end).
        var tpos: usize = data.len;
        while (std.mem.lastIndexOf(u8, data[0..tpos], "trailer")) |ti| {
            tpos = ti;
            var lx: Lexer = .{ .data = data, .pos = ti + 7, .arena = self.arena() };
            if (lx.next(0) catch null) |t| {
                if (t == .dict) try self.mergeTrailer(t.dict);
            }
        }
        // Classify objects cheaply, then look at the interesting ones.
        var keys: std.ArrayList(u32) = .empty;
        var it = self.xref.iterator();
        while (it.next()) |e| try keys.append(self.arena(), e.key_ptr.*);
        std.mem.sort(u32, keys.items, {}, std.sort.asc(u32));
        var catalog: ?u32 = null;
        for (keys.items) |k| {
            const off = self.xref.get(k).?.offset;
            const window = data[off..@min(data.len, off + 400)];
            const is_objstm = std.mem.indexOf(u8, window, "/ObjStm") != null;
            const is_xref = std.mem.indexOf(u8, window, "/XRef") != null;
            const is_cat = std.mem.indexOf(u8, window, "/Catalog") != null;
            if (!(is_objstm or is_xref or is_cat)) continue;
            const o = self.getObject(k) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => continue,
            };
            const d = o.asDict() orelse continue;
            if (is_xref and (dictGet(d, "Type") orelse null_obj).nameIs("XRef")) {
                try self.mergeTrailer(d);
            } else if (is_cat and (dictGet(d, "Type") orelse null_obj).nameIs("Catalog")) {
                catalog = k;
            } else if (is_objstm and o == .stream and (dictGet(d, "Type") orelse null_obj).nameIs("ObjStm")) {
                const os = (self.getObjStm(k) catch |e| switch (e) {
                    error.OutOfMemory => return e,
                    else => null,
                }) orelse continue;
                for (os.nums, 0..) |n, idx| {
                    if (self.xref.get(n)) |ex| if (ex == .offset) continue;
                    try self.xref.put(self.arena(), n, .{ .compressed = .{ .stm = k, .idx = @intCast(idx) } });
                }
            }
        }
        if (self.trailerGet("Root") == null or !self.hasCatalog()) {
            if (catalog == null) {
                // catalogs living inside object streams
                var it2 = self.xref.iterator();
                while (it2.next()) |e| {
                    if (e.value_ptr.* != .compressed) continue;
                    const o = self.getObject(e.key_ptr.*) catch continue;
                    if (o == .dict and (dictGet(o.dict, "Type") orelse null_obj).nameIs("Catalog")) {
                        catalog = e.key_ptr.*;
                        break;
                    }
                }
            }
            if (catalog) |c| {
                // Root must win over a stale trailer entry.
                var i: usize = 0;
                while (i < self.trailer.items.len) {
                    if (std.mem.eql(u8, self.trailer.items[i].key, "Root")) {
                        _ = self.trailer.orderedRemove(i);
                    } else i += 1;
                }
                try self.trailer.append(self.arena(), .{ .key = "Root", .val = .{ .ref = .{ .num = c, .gen = 0 } } });
            }
        }
    }

    // ---- object access ---------------------------------------------------

    pub fn deref(self: *Doc, o: Obj) Error!Obj {
        var cur = o;
        var hops: u8 = 0;
        while (cur == .ref) {
            hops += 1;
            if (hops > 16) return .null;
            cur = try self.getObject(cur.ref.num);
        }
        return cur;
    }

    /// dict[key], dereferenced.
    pub fn get(self: *Doc, d: Dict, key: []const u8) Error!Obj {
        const v = dictGet(d, key) orelse return .null;
        return self.deref(v);
    }

    pub fn getObject(self: *Doc, num: u32) Error!Obj {
        if (self.cache.get(num)) |o| return o;
        const e = self.xref.get(num) orelse return .null;
        if (self.depth > 24) return error.Malformed;
        self.depth += 1;
        defer self.depth -= 1;
        var result: Obj = .null;
        switch (e) {
            .free => {},
            .offset => |off| {
                if (self.parseIndirectAt(off, num)) |o| {
                    result = o;
                } else |err| switch (err) {
                    error.Malformed => {
                        if (self.rebuilt) {
                            result = .null;
                        } else {
                            try self.rebuild();
                            return self.getObject(num);
                        }
                    },
                    else => return err,
                }
            },
            .compressed => |c| {
                result = self.objFromStm(c.stm, c.idx, num) catch |err| switch (err) {
                    error.OutOfMemory, error.LimitExceeded => return err,
                    else => .null,
                };
            },
        }
        try self.cache.put(self.arena(), num, result);
        return result;
    }

    fn objFromStm(self: *Doc, stm: u32, idx: u32, want: u32) Error!Obj {
        const os = (try self.getObjStm(stm)) orelse return .null;
        var i: usize = idx;
        if (i >= os.nums.len or os.nums[i] != want) {
            i = std.mem.indexOfScalar(u32, os.nums, want) orelse return .null;
        }
        const off = os.first + os.offs[i];
        if (off >= os.data.len) return error.Malformed;
        var lx: Lexer = .{ .data = os.data, .pos = off, .arena = self.arena(), .max_depth = self.limits.max_depth };
        const o = (try lx.next(0)) orelse return .null;
        if (o == .keyword) return .null;
        return o;
    }

    fn getObjStm(self: *Doc, stm: u32) Error!?*ObjStm {
        if (self.objstms.get(stm)) |c| return c;
        // Guard against self-reference: mark as failed while loading.
        try self.objstms.put(self.arena(), stm, null);
        const e = self.xref.get(stm) orelse return null;
        if (e != .offset) return null; // object streams cannot live in object streams
        const o = self.getObject(stm) catch |err| switch (err) {
            error.OutOfMemory, error.LimitExceeded => return err,
            else => return null,
        };
        if (o != .stream) return null;
        const st = o.stream;
        const n_obj = (try self.get(st.dict, "N")).asInt() orelse return null;
        const first = (try self.get(st.dict, "First")).asInt() orelse return null;
        if (n_obj < 0 or first < 0 or n_obj > 1_000_000) return null;
        const data = self.decodeStream(self.arena(), st) catch |err| switch (err) {
            error.OutOfMemory, error.LimitExceeded => return err,
            else => return null,
        };
        if (@as(usize, @intCast(first)) > data.len) return null;
        var lx: Lexer = .{ .data = data, .pos = 0, .arena = self.arena() };
        var nums: std.ArrayList(u32) = .empty;
        var offs: std.ArrayList(usize) = .empty;
        var i: i64 = 0;
        while (i < n_obj) : (i += 1) {
            const a = (lx.next(0) catch null) orelse break;
            const b = (lx.next(0) catch null) orelse break;
            const an = a.asInt() orelse break;
            const bn = b.asInt() orelse break;
            if (an < 0 or bn < 0 or an > 0xFFFFFFFF) break;
            try nums.append(self.arena(), @intCast(an));
            try offs.append(self.arena(), @intCast(bn));
        }
        const os = try self.arena().create(ObjStm);
        os.* = .{ .data = data, .first = @intCast(first), .nums = nums.items, .offs = offs.items };
        try self.objstms.put(self.arena(), stm, os);
        return os;
    }

    /// Parse `N G obj ... endobj` at `off` (and a trailing stream).
    fn parseIndirectAt(self: *Doc, off: usize, want: ?u32) Error!Obj {
        var lx: Lexer = .{ .data = self.data, .pos = off, .arena = self.arena(), .max_depth = self.limits.max_depth };
        const a = (try lx.next(0)) orelse return error.Malformed;
        const b = (try lx.next(0)) orelse return error.Malformed;
        const k = (try lx.next(0)) orelse return error.Malformed;
        // "N G obj": the lexer may have folded "N G R"-looking pairs; here the
        // third token is the keyword `obj`.
        if (a != .int or b != .int or k != .keyword or !std.mem.eql(u8, k.keyword, "obj")) return error.Malformed;
        if (want) |w| {
            if (a.int != w) return error.Malformed;
        }
        const obj = (try lx.next(0)) orelse return error.Malformed;
        if (obj == .keyword) return error.Malformed;
        if (obj != .dict) return obj;
        lx.skipWs();
        if (!lx.startsWith("stream")) return obj;
        lx.pos += 6;
        if (lx.pos < self.data.len and self.data[lx.pos] == '\r') lx.pos += 1;
        if (lx.pos < self.data.len and self.data[lx.pos] == '\n') lx.pos += 1;
        const start = lx.pos;
        var raw: ?[]const u8 = null;
        if (dictGet(obj.dict, "Length")) |lv| {
            const l = self.deref(lv) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => null_obj,
            };
            if (l.asInt()) |n| {
                if (n >= 0 and start + @as(usize, @intCast(n)) <= self.data.len) {
                    const end = start + @as(usize, @intCast(n));
                    var p = end;
                    while (p < self.data.len and isWs(self.data[p])) p += 1;
                    if (std.mem.startsWith(u8, self.data[p..], "endstream")) raw = self.data[start..end];
                }
            }
        }
        if (raw == null) {
            var end = std.mem.indexOfPos(u8, self.data, start, "endstream") orelse self.data.len;
            if (end > start and self.data[end - 1] == '\n') end -= 1;
            if (end > start and self.data[end - 1] == '\r') end -= 1;
            raw = self.data[start..end];
        }
        const st = try self.arena().create(Stream);
        st.* = .{ .dict = obj.dict, .raw = raw.? };
        return .{ .stream = st };
    }

    // ---- stream decoding ---------------------------------------------------

    /// Decode all filters. Result is owned by `alloc`.
    pub fn decodeStream(self: *Doc, alloc: Allocator, st: *const Stream) Error![]u8 {
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(alloc);
        var parms: std.ArrayList(?Dict) = .empty;
        defer parms.deinit(alloc);
        const fv = try self.deref(dictGet(st.dict, "Filter") orelse dictGet(st.dict, "F") orelse null_obj);
        const pv = try self.deref(dictGet(st.dict, "DecodeParms") orelse dictGet(st.dict, "DP") orelse null_obj);
        switch (fv) {
            .name => |n| {
                try names.append(alloc, n);
                try parms.append(alloc, if ((try self.deref(pv)).asDict()) |d| d else null);
            },
            .array => |arr| for (arr, 0..) |e, i| {
                const en = try self.deref(e);
                if (en != .name) return error.Malformed;
                if (names.items.len >= 16) return error.Malformed;
                try names.append(alloc, en.name);
                var pd: ?Dict = null;
                if (pv == .array and i < pv.array.len) pd = (try self.deref(pv.array[i])).asDict() else if (pv == .dict and arr.len == 1) pd = pv.dict;
                try parms.append(alloc, pd);
            },
            else => {},
        }
        var cur = try alloc.dupe(u8, st.raw);
        errdefer alloc.free(cur);
        for (names.items, 0..) |n, i| {
            const nxt = try self.applyFilter(alloc, n, parms.items[i], cur);
            alloc.free(cur);
            cur = nxt;
        }
        return cur;
    }

    fn account(self: *Doc, n: usize) Error!void {
        self.total_inflated += n;
        if (self.total_inflated > self.limits.max_total_bytes) return error.LimitExceeded;
    }

    fn applyFilter(self: *Doc, alloc: Allocator, name: []const u8, parms: ?Dict, input: []const u8) Error![]u8 {
        const lim = self.limits.max_stream_bytes;
        const eql = std.mem.eql;
        if (eql(u8, name, "FlateDecode") or eql(u8, name, "Fl")) {
            const raw = try inflate(alloc, input, lim);
            errdefer alloc.free(raw);
            try self.account(raw.len);
            return try self.predictor(alloc, raw, parms);
        } else if (eql(u8, name, "LZWDecode") or eql(u8, name, "LZW")) {
            var early: i64 = 1;
            if (parms) |p| if (dictGet(p, "EarlyChange")) |e| {
                early = e.asInt() orelse 1;
            };
            const raw = try lzwDecode(alloc, input, early != 0, lim);
            errdefer alloc.free(raw);
            try self.account(raw.len);
            return try self.predictor(alloc, raw, parms);
        } else if (eql(u8, name, "ASCII85Decode") or eql(u8, name, "A85")) {
            return try a85Decode(alloc, input, lim);
        } else if (eql(u8, name, "ASCIIHexDecode") or eql(u8, name, "AHx")) {
            return try ahxDecode(alloc, input, lim);
        } else if (eql(u8, name, "RunLengthDecode") or eql(u8, name, "RL")) {
            return try rlDecode(alloc, input, lim);
        } else if (eql(u8, name, "Crypt")) {
            return try alloc.dupe(u8, input);
        }
        return error.Unsupported;
    }

    /// Takes ownership of `raw`.
    fn predictor(self: *Doc, alloc: Allocator, raw: []u8, parms: ?Dict) Error![]u8 {
        const p = parms orelse return raw;
        const pred = (try self.get(p, "Predictor")).asInt() orelse 1;
        if (pred <= 1) return raw;
        const colors = clampInt((try self.get(p, "Colors")).asInt() orelse 1, 1, 64);
        const bpc = clampInt((try self.get(p, "BitsPerComponent")).asInt() orelse 8, 1, 16);
        const cols = clampInt((try self.get(p, "Columns")).asInt() orelse 1, 1, 1 << 22);
        const row_bytes: usize = @intCast(@divTrunc(colors * bpc * cols + 7, 8));
        if (row_bytes > (1 << 24)) return error.Malformed;
        const bpp: usize = @intCast(@max(1, @divTrunc(colors * bpc + 7, 8)));
        if (pred >= 10) {
            const stride = row_bytes + 1;
            const rows = (raw.len + stride - 1) / stride;
            const out = try alloc.alloc(u8, rows * row_bytes);
            errdefer alloc.free(out);
            @memset(out, 0);
            var y: usize = 0;
            var out_len: usize = 0;
            while (y < rows) : (y += 1) {
                const src_start = y * stride;
                const tag = raw[src_start];
                const avail = @min(row_bytes, raw.len - src_start - 1);
                const cur = out[y * row_bytes ..][0..row_bytes];
                const prev: ?[]const u8 = if (y > 0) out[(y - 1) * row_bytes ..][0..row_bytes] else null;
                const src = raw[src_start + 1 ..][0..avail];
                for (src, 0..) |v, i| {
                    const a: u8 = if (i >= bpp) cur[i - bpp] else 0;
                    const b: u8 = if (prev) |pr| pr[i] else 0;
                    const c: u8 = if (prev != null and i >= bpp) prev.?[i - bpp] else 0;
                    cur[i] = switch (tag) {
                        0 => v,
                        1 => v +% a,
                        2 => v +% b,
                        3 => v +% @as(u8, @intCast((@as(u16, a) + b) / 2)),
                        4 => v +% paeth(a, b, c),
                        else => v,
                    };
                }
                out_len = y * row_bytes + avail;
            }
            alloc.free(raw);
            // shrink to the bytes actually produced
            return try alloc.realloc(out, out_len);
        } else if (pred == 2 and bpc == 8) {
            var y: usize = 0;
            const rb = row_bytes;
            const cn: usize = @intCast(colors);
            while (y * rb < raw.len) : (y += 1) {
                const row = raw[y * rb ..][0..@min(rb, raw.len - y * rb)];
                var i: usize = cn;
                while (i < row.len) : (i += 1) row[i] +%= row[i - cn];
            }
            return raw;
        }
        return raw;
    }

    // ---- pages -------------------------------------------------------------

    pub fn getPages(self: *Doc) Error![]const Page {
        if (self.pages) |p| return p;
        var out: std.ArrayList(Page) = .empty;
        var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
        const root = try self.deref(self.trailerGet("Root") orelse return error.Malformed);
        const rd = root.asDict() orelse return error.Malformed;
        const top = dictGet(rd, "Pages") orelse return error.Malformed;
        try self.walkPages(top, null, 0, &out, &seen);
        self.pages = out.items;
        return out.items;
    }

    fn walkPages(self: *Doc, node: Obj, inherited: ?Obj, depth: u32, out: *std.ArrayList(Page), seen: *std.AutoHashMapUnmanaged(u32, void)) Error!void {
        if (depth > 48 or out.items.len >= 100_000) return;
        if (node == .ref) {
            const gop = try seen.getOrPut(self.arena(), node.ref.num);
            if (gop.found_existing) return;
        }
        const o = try self.deref(node);
        const d = o.asDict() orelse return;
        var res = inherited;
        if (dictGet(d, "Resources")) |r| res = r;
        const kids = try self.get(d, "Kids");
        if (kids == .array) {
            for (kids.array) |k| try self.walkPages(k, res, depth + 1, out, seen);
        } else {
            try out.append(self.arena(), .{ .dict = d, .resources = res });
        }
    }
};

fn clampInt(v: i64, lo: i64, hi: i64) i64 {
    return @max(lo, @min(hi, v));
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i32 = @as(i32, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

// ---------------------------------------------------------------------------
// Filters
// ---------------------------------------------------------------------------

/// Inflate zlib (or raw) data; corrupt streams yield the decoded prefix.
/// See inflate.zig for why std's decoder is not used.
pub const inflate = @import("inflate.zig").inflate;

fn ahxDecode(alloc: Allocator, input: []const u8, limit: usize) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var hi: ?u8 = null;
    for (input) |c| {
        if (c == '>') break;
        const v: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => continue,
        };
        if (hi) |h| {
            if (out.items.len >= limit) return error.LimitExceeded;
            try out.append(alloc, (h << 4) | v);
            hi = null;
        } else hi = v;
    }
    if (hi) |h| try out.append(alloc, h << 4);
    return out.toOwnedSlice(alloc);
}

fn a85Decode(alloc: Allocator, input: []const u8, limit: usize) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var grp: [5]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    if (std.mem.startsWith(u8, input, "<~")) i = 2;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (isWs(c)) continue;
        if (c == '~') break;
        if (out.items.len > limit) return error.LimitExceeded;
        if (c == 'z' and n == 0) {
            try out.appendSlice(alloc, &.{ 0, 0, 0, 0 });
            continue;
        }
        if (c < '!' or c > 'u') continue;
        grp[n] = c - '!';
        n += 1;
        if (n == 5) {
            var v: u32 = 0;
            for (grp) |g| v = v *% 85 +% g;
            try out.appendSlice(alloc, &.{ @truncate(v >> 24), @truncate(v >> 16), @truncate(v >> 8), @truncate(v) });
            n = 0;
        }
    }
    if (n > 1) {
        var k = n;
        while (k < 5) : (k += 1) grp[k] = 84;
        var v: u32 = 0;
        for (grp) |g| v = v *% 85 +% g;
        const bytes = [4]u8{ @truncate(v >> 24), @truncate(v >> 16), @truncate(v >> 8), @truncate(v) };
        try out.appendSlice(alloc, bytes[0 .. n - 1]);
    }
    return out.toOwnedSlice(alloc);
}

fn rlDecode(alloc: Allocator, input: []const u8, limit: usize) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < input.len) {
        const l = input[i];
        i += 1;
        if (l == 128) break;
        if (out.items.len > limit) return error.LimitExceeded;
        if (l < 128) {
            const n = @min(@as(usize, l) + 1, input.len - i);
            try out.appendSlice(alloc, input[i .. i + n]);
            i += n;
        } else {
            if (i >= input.len) break;
            const n = 257 - @as(usize, l);
            try out.appendNTimes(alloc, input[i], n);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

fn lzwDecode(alloc: Allocator, input: []const u8, early_change: bool, limit: usize) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var prefix: [4096]u16 = undefined;
    var suffix: [4096]u8 = undefined;
    var lens: [4096]u16 = undefined;
    for (0..256) |i| {
        suffix[i] = @intCast(i);
        lens[i] = 1;
        prefix[i] = 0;
    }
    const early: usize = if (early_change) 1 else 0;
    var next_code: usize = 258;
    var width: u5 = 9;
    var prev: ?usize = null;
    var bitbuf: u32 = 0;
    var nbits: u5 = 0;
    var ip: usize = 0;
    while (true) {
        while (nbits < width) {
            if (ip >= input.len) return out.toOwnedSlice(alloc);
            bitbuf = (bitbuf << 8) | input[ip];
            ip += 1;
            nbits += 8;
        }
        const code: usize = (bitbuf >> (nbits - width)) & ((@as(u32, 1) << width) - 1);
        nbits -= width;
        bitbuf &= (@as(u32, 1) << nbits) - 1;
        if (code == 256) {
            next_code = 258;
            width = 9;
            prev = null;
            continue;
        }
        if (code == 257) break;
        if (out.items.len > limit) return error.LimitExceeded;
        if (prev == null) {
            if (code >= 256) break;
            try out.append(alloc, @intCast(code));
            prev = code;
            continue;
        }
        const p = prev.?;
        var first: u8 = undefined;
        if (code < next_code) {
            const start = out.items.len;
            const len = lens[code];
            try out.resize(alloc, start + len);
            var c = code;
            var k: usize = len;
            while (k > 0) {
                k -= 1;
                out.items[start + k] = suffix[c];
                c = prefix[c];
            }
            first = out.items[start];
        } else if (code == next_code) {
            // KwKwK case
            var c = p;
            while (lens[c] > 1) c = prefix[c];
            first = suffix[c];
            const start = out.items.len;
            const len = @as(usize, lens[p]) + 1;
            try out.resize(alloc, start + len);
            var cc = p;
            var k: usize = len - 1;
            while (k > 0) {
                k -= 1;
                out.items[start + k] = suffix[cc];
                cc = prefix[cc];
            }
            out.items[start + len - 1] = first;
        } else break;
        if (next_code < 4096) {
            prefix[next_code] = @intCast(p);
            suffix[next_code] = first;
            lens[next_code] = lens[p] + 1;
            next_code += 1;
        }
        prev = code;
        width = if (next_code + early >= 2048) 12 else if (next_code + early >= 1024) 11 else if (next_code + early >= 512) 10 else 9;
    }
    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Metadata helpers shared by tools
// ---------------------------------------------------------------------------

/// PDF text string (PDFDocEncoding, UTF-16BE/LE with BOM, UTF-8 with BOM) to UTF-8.
pub fn textString(alloc: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    if (s.len >= 2 and ((s[0] == 0xFE and s[1] == 0xFF) or (s[0] == 0xFF and s[1] == 0xFE))) {
        const be = s[0] == 0xFE;
        var i: usize = 2;
        while (i + 1 < s.len) : (i += 2) {
            var u: u21 = if (be) std.mem.readInt(u16, s[i..][0..2], .big) else std.mem.readInt(u16, s[i..][0..2], .little);
            if (u >= 0xD800 and u < 0xDC00 and i + 3 < s.len) {
                const lo: u21 = if (be) std.mem.readInt(u16, s[i + 2 ..][0..2], .big) else std.mem.readInt(u16, s[i + 2 ..][0..2], .little);
                if (lo >= 0xDC00 and lo < 0xE000) {
                    u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00);
                    i += 2;
                }
            }
            try appendCp(alloc, &out, u);
        }
    } else if (s.len >= 3 and s[0] == 0xEF and s[1] == 0xBB and s[2] == 0xBF) {
        try out.appendSlice(alloc, s[3..]);
    } else {
        for (s) |c| try appendCp(alloc, &out, c);
    }
    return out.toOwnedSlice(alloc);
}

pub fn appendCp(alloc: Allocator, out: *std.ArrayList(u8), cp: u21) Allocator.Error!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch {
        try out.appendSlice(alloc, "\u{FFFD}");
        return;
    };
    try out.appendSlice(alloc, buf[0..n]);
}

/// "D:20240102030405+01'00'" to "2024-01-02 03:04:05"; anything else unchanged.
pub fn formatDate(alloc: Allocator, s: []const u8) Allocator.Error![]u8 {
    var t = s;
    if (std.mem.startsWith(u8, t, "D:")) t = t[2..];
    const digits = blk: {
        var n: usize = 0;
        while (n < t.len and n < 14 and t[n] >= '0' and t[n] <= '9') n += 1;
        break :blk n;
    };
    if (digits == 4 and t.len >= 10 and t[4] == '-') {
        // ISO 8601 (XMP): 2020-05-06T07:08:09Z
        const out = try alloc.dupe(u8, t[0..@min(t.len, 19)]);
        for (out) |*c| {
            if (c.* == 'T') c.* = ' ';
        }
        return out;
    }
    if (digits < 4) return alloc.dupe(u8, s);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, t[0..4]);
    if (digits >= 6) {
        try out.append(alloc, '-');
        try out.appendSlice(alloc, t[4..6]);
    }
    if (digits >= 8) {
        try out.append(alloc, '-');
        try out.appendSlice(alloc, t[6..8]);
    }
    if (digits >= 10) {
        try out.append(alloc, ' ');
        try out.appendSlice(alloc, t[8..10]);
    }
    if (digits >= 12) {
        try out.append(alloc, ':');
        try out.appendSlice(alloc, t[10..12]);
    }
    if (digits >= 14) {
        try out.append(alloc, ':');
        try out.appendSlice(alloc, t[12..14]);
    }
    return out.toOwnedSlice(alloc);
}

test "filters: ascii85, hex, run length, LZW" {
    const a = std.testing.allocator;
    const t = std.testing;
    const r1 = try a85Decode(a, "<~9jqo^~>", 1000);
    defer a.free(r1);
    try t.expectEqualStrings("Man ", r1);
    const r1b = try a85Decode(a, "9jqo^z", 1000);
    defer a.free(r1b);
    try t.expectEqualSlices(u8, "Man \x00\x00\x00\x00", r1b);
    const r2 = try ahxDecode(a, "48 65 6C6c 6F7>", 1000);
    defer a.free(r2);
    try t.expectEqualStrings("Hello\x70", r2);
    const r3 = try rlDecode(a, "\x02abc\xfex\x00z\x80junk", 1000);
    defer a.free(r3);
    try t.expectEqualStrings("abcxxxz", r3[0..7]);
    // PDF reference example: -----A---B
    const r4 = try lzwDecode(a, "\x80\x0b\x60\x50\x22\x0c\x0c\x85\x01", true, 1000);
    defer a.free(r4);
    try t.expectEqualStrings("-----A---B", r4);
}

test "PNG and TIFF predictors" {
    const a = std.testing.allocator;
    var ar = std.heap.ArenaAllocator.init(a);
    defer ar.deinit();
    var doc: Doc = .{ .gpa = a, .arena_state = ar, .data = "", .limits = .{} };
    const parms = [_]Entry{
        .{ .key = "Predictor", .val = .{ .int = 12 } },
        .{ .key = "Columns", .val = .{ .int = 3 } },
    };
    // Up filter: row1 = 1 2 3, row2 = +1 +1 +1 -> 2 3 4
    const raw = try a.dupe(u8, &[_]u8{ 2, 1, 2, 3, 2, 1, 1, 1 });
    const out = try doc.predictor(a, raw, &parms);
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 2, 3, 4 }, out);
    const tparms = [_]Entry{
        .{ .key = "Predictor", .val = .{ .int = 2 } },
        .{ .key = "Columns", .val = .{ .int = 4 } },
    };
    const raw2 = try a.dupe(u8, &[_]u8{ 1, 1, 1, 1 });
    const out2 = try doc.predictor(a, raw2, &tparms);
    defer a.free(out2);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, out2);
}
