//! Minimal PDF writer used only by tests (no binary fixtures).

const std = @import("std");
const flate = std.compress.flate;
const Allocator = std.mem.Allocator;

pub fn zlib(a: Allocator, data: []const u8) ![]u8 {
    var z: std.Io.Writer.Allocating = .init(a);
    defer z.deinit();
    try z.ensureUnusedCapacity(64 * 1024);
    const window = try a.alloc(u8, flate.max_window_len);
    defer a.free(window);
    const comp = try a.create(flate.Compress);
    defer a.destroy(comp);
    comp.* = try flate.Compress.init(&z.writer, window, .zlib, .level_4);
    try comp.writer.writeAll(data);
    try comp.finish();
    return a.dupe(u8, z.written());
}

pub fn hex(a: Allocator, data: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (data) |c| try out.print(a, "{x:0>2}", .{c});
    try out.append(a, '>');
    return out.toOwnedSlice(a);
}

pub const Builder = struct {
    a: Allocator,
    bodies: std.ArrayList([]u8) = .empty,

    pub fn init(a: Allocator) Builder {
        return .{ .a = a };
    }

    pub fn deinit(self: *Builder) void {
        for (self.bodies.items) |b| self.a.free(b);
        self.bodies.deinit(self.a);
    }

    pub fn reserve(self: *Builder) !u32 {
        try self.bodies.append(self.a, try self.a.alloc(u8, 0));
        return @intCast(self.bodies.items.len);
    }

    pub fn set(self: *Builder, n: u32, body: []const u8) !void {
        const d = try self.a.dupe(u8, body);
        self.a.free(self.bodies.items[n - 1]);
        self.bodies.items[n - 1] = d;
    }

    pub fn add(self: *Builder, body: []const u8) !u32 {
        const n = try self.reserve();
        try self.set(n, body);
        return n;
    }

    pub fn addStream(self: *Builder, dict_extra: []const u8, data: []const u8) !u32 {
        const s = try std.fmt.allocPrint(self.a, "<< /Length {d} {s} >>\nstream\n{s}\nendstream", .{ data.len, dict_extra, data });
        defer self.a.free(s);
        return self.add(s);
    }

    pub fn addFlate(self: *Builder, dict_extra: []const u8, data: []const u8) !u32 {
        const z = try zlib(self.a, data);
        defer self.a.free(z);
        const de = try std.fmt.allocPrint(self.a, "/Filter /FlateDecode {s}", .{dict_extra});
        defer self.a.free(de);
        return self.addStream(de, z);
    }

    /// Classic xref table.
    pub fn writeClassic(self: *Builder, root: u32, trailer_extra: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.a);
        try out.appendSlice(self.a, "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");
        const offs = try self.a.alloc(usize, self.bodies.items.len);
        defer self.a.free(offs);
        for (self.bodies.items, 0..) |b, i| {
            offs[i] = out.items.len;
            try out.print(self.a, "{d} 0 obj\n", .{i + 1});
            try out.appendSlice(self.a, b);
            try out.appendSlice(self.a, "\nendobj\n");
        }
        const xr = out.items.len;
        try out.print(self.a, "xref\n0 {d}\n0000000000 65535 f \n", .{self.bodies.items.len + 1});
        for (offs) |o| try out.print(self.a, "{d:0>10} 00000 n \n", .{o});
        try out.print(self.a, "trailer\n<< /Size {d} /Root {d} 0 R {s} >>\nstartxref\n{d}\n%%EOF\n", .{ self.bodies.items.len + 1, root, trailer_extra, xr });
        return out.toOwnedSlice(self.a);
    }

    /// PDF 1.5: objects listed in `packed_objs` (non-streams) go into an object
    /// stream; the xref is a Flate + PNG-Up compressed xref stream.
    pub fn writeXrefStream(self: *Builder, root: u32, packed_objs: []const u32, trailer_extra: []const u8) ![]u8 {
        const a = self.a;
        const n: u32 = @intCast(self.bodies.items.len);
        const stm_num = n + 1;
        const xr_num = n + 2;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        try out.appendSlice(a, "%PDF-1.5\n%\xE2\xE3\xCF\xD3\n");
        const offs = try a.alloc(usize, n + 3);
        defer a.free(offs);
        @memset(offs, 0);
        const is_packed = try a.alloc(bool, n + 1);
        defer a.free(is_packed);
        @memset(is_packed, false);
        for (packed_objs) |p| is_packed[p] = true;
        for (self.bodies.items, 0..) |b, i| {
            const num: u32 = @intCast(i + 1);
            if (is_packed[num]) continue;
            offs[num] = out.items.len;
            try out.print(a, "{d} 0 obj\n", .{num});
            try out.appendSlice(a, b);
            try out.appendSlice(a, "\nendobj\n");
        }
        // object stream
        var hdr: std.ArrayList(u8) = .empty;
        defer hdr.deinit(a);
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(a);
        for (packed_objs) |p| {
            try hdr.print(a, "{d} {d} ", .{ p, body.items.len });
            try body.appendSlice(a, self.bodies.items[p - 1]);
            try body.append(a, '\n');
        }
        var stm_data: std.ArrayList(u8) = .empty;
        defer stm_data.deinit(a);
        try stm_data.appendSlice(a, hdr.items);
        try stm_data.appendSlice(a, body.items);
        const z = try zlib(a, stm_data.items);
        defer a.free(z);
        offs[stm_num] = out.items.len;
        try out.print(a, "{d} 0 obj\n<< /Type /ObjStm /N {d} /First {d} /Filter /FlateDecode /Length {d} >>\nstream\n", .{ stm_num, packed_objs.len, hdr.items.len, z.len });
        try out.appendSlice(a, z);
        try out.appendSlice(a, "\nendstream\nendobj\n");
        // xref stream, 7 bytes/record, PNG Up predictor
        const xr_off = out.items.len;
        offs[xr_num] = xr_off;
        const total = n + 3;
        var raw: std.ArrayList(u8) = .empty;
        defer raw.deinit(a);
        var prev = [_]u8{0} ** 7;
        var num: u32 = 0;
        while (num < total) : (num += 1) {
            var rec = [_]u8{0} ** 7;
            if (num == 0) {
                rec[0] = 0;
            } else if (num <= n and is_packed[num]) {
                const idx = std.mem.indexOfScalar(u32, packed_objs, num).?;
                rec[0] = 2;
                std.mem.writeInt(u32, rec[1..5], stm_num, .big);
                std.mem.writeInt(u16, rec[5..7], @intCast(idx), .big);
            } else {
                rec[0] = 1;
                std.mem.writeInt(u32, rec[1..5], @intCast(offs[num]), .big);
            }
            try raw.append(a, 2);
            for (rec, 0..) |c, i| try raw.append(a, c -% prev[i]);
            prev = rec;
        }
        const zx = try zlib(a, raw.items);
        defer a.free(zx);
        try out.print(a, "{d} 0 obj\n<< /Type /XRef /Size {d} /W [1 4 2] /Root {d} 0 R {s} /Filter /FlateDecode /DecodeParms << /Predictor 12 /Columns 7 >> /Length {d} >>\nstream\n", .{ xr_num, total, root, trailer_extra, zx.len });
        try out.appendSlice(a, zx);
        try out.print(a, "\nendstream\nendobj\nstartxref\n{d}\n%%EOF\n", .{xr_off});
        return out.toOwnedSlice(a);
    }
};

pub const Mode = enum { classic, flate, objstm };

/// Catalog=1, Pages=2, Helvetica font=3, then (page, content) pairs.
pub fn simpleDoc(a: Allocator, contents: []const []const u8, mode: Mode) ![]u8 {
    var b = Builder.init(a);
    defer b.deinit();
    const cat = try b.reserve();
    const pages = try b.reserve();
    const font = try b.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>");
    var kids: std.ArrayList(u8) = .empty;
    defer kids.deinit(a);
    var packed_list: std.ArrayList(u32) = .empty;
    defer packed_list.deinit(a);
    try packed_list.appendSlice(a, &.{ cat, pages, font });
    for (contents) |c| {
        const cs = if (mode == .classic) try b.addStream("", c) else try b.addFlate("", c);
        const pg = try std.fmt.allocPrint(a, "<< /Type /Page /Parent {d} 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 {d} 0 R >> >> /Contents {d} 0 R >>", .{ pages, font, cs });
        defer a.free(pg);
        const pn = try b.add(pg);
        try packed_list.append(a, pn);
        try kids.print(a, "{d} 0 R ", .{pn});
    }
    const pd = try std.fmt.allocPrint(a, "<< /Type /Pages /Kids [{s}] /Count {d} >>", .{ kids.items, contents.len });
    defer a.free(pd);
    try b.set(pages, pd);
    const cd = try std.fmt.allocPrint(a, "<< /Type /Catalog /Pages {d} 0 R >>", .{pages});
    defer a.free(cd);
    try b.set(cat, cd);
    return if (mode == .objstm) b.writeXrefStream(cat, packed_list.items, "") else b.writeClassic(cat, "");
}
