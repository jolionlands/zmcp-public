//! Tests for zmcp-pdf. PDFs are generated in-process by testpdf.zig.

const std = @import("std");
const testing = std.testing;
const pdf = @import("pdf.zig");
const text = @import("text.zig");
const tp = @import("testpdf.zig");
const main = @import("main.zig");
const mcp = @import("mcp");

const Value = std.json.Value;

/// Extract every page; results are owned by `a` (an arena).
fn pages(a: std.mem.Allocator, data: []const u8) ![][]const u8 {
    const doc = try pdf.Doc.open(testing.allocator, data, .{});
    defer doc.close();
    const pgs = try doc.getPages();
    var ex = text.Extractor.init(testing.allocator, doc);
    defer ex.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    for (pgs) |p| {
        const pt = try ex.page(p, 1 << 20);
        defer testing.allocator.free(pt.text);
        try out.append(a, try a.dupe(u8, pt.text));
    }
    return out.items;
}

fn one(a: std.mem.Allocator, content: []const u8, mode: tp.Mode) ![]const u8 {
    const data = try tp.simpleDoc(testing.allocator, &.{content}, mode);
    defer testing.allocator.free(data);
    const r = try pages(a, data);
    try testing.expectEqual(@as(usize, 1), r.len);
    return r[0];
}

test "simple text, all writer modes" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    inline for (.{ tp.Mode.classic, tp.Mode.flate, tp.Mode.objstm }) |m| {
        try testing.expectEqualStrings("Hello, World", try one(a, "BT /F1 12 Tf 72 700 Td (Hello, World) Tj ET", m));
    }
}

test "xref table and xref stream paths are used without rebuilding" {
    const d1 = try tp.simpleDoc(testing.allocator, &.{"BT /F1 12 Tf (x) Tj ET"}, .classic);
    defer testing.allocator.free(d1);
    const doc1 = try pdf.Doc.open(testing.allocator, d1, .{});
    defer doc1.close();
    try testing.expect(!doc1.rebuilt);
    const d2 = try tp.simpleDoc(testing.allocator, &.{"BT /F1 12 Tf (x) Tj ET"}, .objstm);
    defer testing.allocator.free(d2);
    const doc2 = try pdf.Doc.open(testing.allocator, d2, .{});
    defer doc2.close();
    try testing.expect(!doc2.rebuilt);
    try testing.expectEqualStrings("1.5", doc2.version);
    try testing.expectEqual(@as(usize, 1), (try doc2.getPages()).len);
}

test "lines, kerning gaps, paragraphs, escapes" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expectEqualStrings("Line one\nLine two", try one(a, "BT /F1 12 Tf 14 TL 72 700 Td (Line one) Tj T* (Line two) Tj ET", .classic));
    try testing.expectEqualStrings("Hello World", try one(a, "BT /F1 12 Tf 72 700 Td [(Hel) -20 (lo) -600 (World)] TJ ET", .classic));
    try testing.expectEqualStrings("A B", try one(a, "BT /F1 12 Tf 72 700 Td (A) Tj 100 0 Td (B) Tj ET", .classic));
    try testing.expectEqualStrings("P1\n\nP2", try one(a, "BT /F1 12 Tf 72 700 Td (P1) Tj 0 -40 Td (P2) Tj ET", .classic));
    try testing.expectEqualStrings("a(b)cA", try one(a, "BT /F1 12 Tf (a\\(b\\)c\\101) Tj ET", .classic));
    try testing.expectEqualStrings("one\ntwo", try one(a, "BT /F1 12 Tf 12 TL 72 700 Td (one) Tj (two) ' ET", .classic));
    try testing.expectEqualStrings("one\ntwo", try one(a, "BT /F1 12 Tf 12 TL 72 700 Td (one) Tj 1 2 (two) \" ET", .classic));
    // Tm placing text, cm scaling
    try testing.expectEqualStrings("x\ny", try one(a, "BT /F1 10 Tf 1 0 0 1 50 700 Tm (x) Tj 1 0 0 1 50 688 Tm (y) Tj ET", .classic));
    try testing.expectEqualStrings("sup", try one(a, "q 0.5 0 0 0.5 0 0 cm BT /F1 24 Tf 10 10 Td (sup) Tj ET Q", .classic));
    // superscript-style baseline shift stays on the line
    try testing.expectEqualStrings("x2", try one(a, "BT /F1 12 Tf 72 700 Td (x) Tj 5 Ts (2) Tj ET", .classic));
}

test "pages are separate" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const data = try tp.simpleDoc(testing.allocator, &.{ "BT /F1 12 Tf (first) Tj ET", "BT /F1 12 Tf (second) Tj ET", "BT /F1 12 Tf (third) Tj ET" }, .flate);
    defer testing.allocator.free(data);
    const r = try pages(a, data);
    try testing.expectEqual(@as(usize, 3), r.len);
    try testing.expectEqualStrings("second", r[1]);
}

test "Differences, ligatures and WinAnsi" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var b = tp.Builder.init(testing.allocator);
    defer b.deinit();
    const cat = try b.reserve();
    const pg = try b.reserve();
    const font = try b.add("<< /Type /Font /Subtype /Type1 /BaseFont /Times-Roman /Encoding << /BaseEncoding /WinAnsiEncoding /Differences [1 /fi /Euro /uni0416 65 /eacute] >> >>");
    const cs = try b.addStream("", "BT /F1 12 Tf <010203> Tj ( ) Tj (A\\351) Tj ET");
    const pd = try std.fmt.allocPrint(a, "<< /Type /Page /Parent {d} 0 R /Resources << /Font << /F1 {d} 0 R >> >> /Contents {d} 0 R >>", .{ pg, font, cs });
    const pn = try b.add(pd);
    try b.set(pg, try std.fmt.allocPrint(a, "<< /Type /Pages /Kids [{d} 0 R] /Count 1 >>", .{pn}));
    try b.set(cat, try std.fmt.allocPrint(a, "<< /Type /Catalog /Pages {d} 0 R >>", .{pg}));
    const data = try b.writeClassic(cat, "");
    defer testing.allocator.free(data);
    const r = try pages(a, data);
    try testing.expectEqualStrings("fi\u{20AC}\u{0416} \u{E9}\u{E9}", r[0]);
}

test "Type0 font with ToUnicode CMap" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var b = tp.Builder.init(testing.allocator);
    defer b.deinit();
    const cat = try b.reserve();
    const pg = try b.reserve();
    const cmap =
        \\/CIDInit /ProcSet findresource begin 12 dict begin begincmap
        \\1 begincodespacerange <0000> <FFFF> endcodespacerange
        \\2 beginbfchar
        \\<0001> <0048>
        \\<0002> <0069>
        \\endbfchar
        \\1 beginbfrange
        \\<0003> <0005> <0041>
        \\endbfrange
        \\endcmap end end
    ;
    const tu = try b.addFlate("", cmap);
    const desc = try b.add("<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Foo /DW 500 /W [1 [600 600] 3 5 400] >>");
    const fontstr = try std.fmt.allocPrint(a, "<< /Type /Font /Subtype /Type0 /BaseFont /Foo /Encoding /Identity-H /DescendantFonts [{d} 0 R] /ToUnicode {d} 0 R >>", .{ desc, tu });
    const font = try b.add(fontstr);
    const cs = try b.addStream("", "BT /F1 12 Tf 72 700 Td <00010002000300040005> Tj ET");
    const pd = try std.fmt.allocPrint(a, "<< /Type /Page /Parent {d} 0 R /Resources << /Font << /F1 {d} 0 R >> >> /Contents {d} 0 R >>", .{ pg, font, cs });
    const pn = try b.add(pd);
    try b.set(pg, try std.fmt.allocPrint(a, "<< /Type /Pages /Kids [{d} 0 R] /Count 1 >>", .{pn}));
    try b.set(cat, try std.fmt.allocPrint(a, "<< /Type /Catalog /Pages {d} 0 R >>", .{pg}));
    const data = try b.writeClassic(cat, "");
    defer testing.allocator.free(data);
    const r = try pages(a, data);
    try testing.expectEqualStrings("HiABC", r[0]);
}

fn formDoc(a: std.mem.Allocator, page_content: []const u8, form_body: []const u8) ![]u8 {
    var b = tp.Builder.init(testing.allocator);
    defer b.deinit();
    const cat = try b.reserve();
    const pg = try b.reserve();
    const font = try b.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>");
    const fm = try b.reserve();
    const fm2 = try b.reserve();
    const fmstr = try std.fmt.allocPrint(a, "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Matrix [1 0 0 1 0 0] /Resources << /Font << /F1 {d} 0 R >> /XObject << /Fm1 {d} 0 R /Fm2 {d} 0 R >> >>", .{ font, fm, fm2 });
    const s1 = try std.fmt.allocPrint(a, "<< /Length {d} {s} >>\nstream\n{s}\nendstream", .{ form_body.len, fmstr, form_body });
    try b.set(fm, s1);
    const body2 = "BT /F1 12 Tf (second) Tj ET /Fm1 Do /Fm2 Do";
    const s2 = try std.fmt.allocPrint(a, "<< /Length {d} {s} >>\nstream\n{s}\nendstream", .{ body2.len, fmstr, body2 });
    try b.set(fm2, s2);
    const cs = try b.addStream("", page_content);
    const pd = try std.fmt.allocPrint(a, "<< /Type /Page /Parent {d} 0 R /Resources << /Font << /F1 {d} 0 R >> /XObject << /Fm1 {d} 0 R /Fm2 {d} 0 R >> >> /Contents {d} 0 R >>", .{ pg, font, fm, fm2, cs });
    const pn = try b.add(pd);
    try b.set(pg, try std.fmt.allocPrint(a, "<< /Type /Pages /Kids [{d} 0 R] /Count 1 >>", .{pn}));
    try b.set(cat, try std.fmt.allocPrint(a, "<< /Type /Catalog /Pages {d} 0 R >>", .{pg}));
    return b.writeClassic(cat, "");
}

test "form XObjects recurse; cycles and depth are bounded" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // Fm1 draws text and calls itself (cycle); the page also calls Fm2 which calls Fm1 and Fm2.
    const data = try formDoc(a, "BT /F1 12 Tf 72 700 Td (top) Tj ET /Fm2 Do", "BT /F1 12 Tf 0 -50 Td (in form) Tj ET /Fm1 Do");
    defer testing.allocator.free(data);
    const r = try pages(a, data);
    try testing.expect(std.mem.indexOf(u8, r[0], "top") != null);
    try testing.expect(std.mem.indexOf(u8, r[0], "in form") != null);
    try testing.expect(std.mem.indexOf(u8, r[0], "second") != null);
}

test "image-only page is reported" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var b = tp.Builder.init(testing.allocator);
    defer b.deinit();
    const cat = try b.reserve();
    const pg = try b.reserve();
    const img = try b.addStream("/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8", "\x00\x40\x80\xff");
    const cs = try b.addStream("", "q 100 0 0 100 0 0 cm /Im1 Do Q");
    const pd = try std.fmt.allocPrint(a, "<< /Type /Page /Parent {d} 0 R /Resources << /XObject << /Im1 {d} 0 R >> >> /Contents {d} 0 R >>", .{ pg, img, cs });
    const pn = try b.add(pd);
    try b.set(pg, try std.fmt.allocPrint(a, "<< /Type /Pages /Kids [{d} 0 R] /Count 1 >>", .{pn}));
    try b.set(cat, try std.fmt.allocPrint(a, "<< /Type /Catalog /Pages {d} 0 R >>", .{pg}));
    const data = try b.writeClassic(cat, "");
    defer testing.allocator.free(data);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "scan.pdf", .data = data });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const cfg: main.Config = .{ .root = root };
    const args = try std.json.parseFromSliceLeaky(Value, a, "{\"path\":\"scan.pdf\"}", .{});
    const r = try main.textImpl(a, testing.io, cfg, args);
    try testing.expect(!r.is_error);
    try testing.expect(std.mem.indexOf(u8, r.text, "--- page 1 ---\n(no extractable text; page appears to be an image)") != null);
    const ri = try main.infoImpl(a, testing.io, cfg, args);
    try testing.expect(std.mem.indexOf(u8, ri.text, "appear to be images") != null);
    try testing.expect(std.mem.indexOf(u8, ri.text, "pages: 1") != null);
}

test "damaged files are rebuilt by scanning" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const good = try tp.simpleDoc(testing.allocator, &.{ "BT /F1 12 Tf (alpha) Tj ET", "BT /F1 12 Tf (beta) Tj ET" }, .classic);
    defer testing.allocator.free(good);
    // 1. junk prepended: every offset is stale
    const shifted = try std.mem.concat(a, u8, &.{ "GARBAGE-LINE\n", good });
    const r1 = try pages(a, shifted);
    try testing.expectEqualStrings("beta", r1[1]);
    // 2. trailer and xref chopped off
    const cut = std.mem.lastIndexOf(u8, good, "xref\n").?;
    const r2 = try pages(a, good[0..cut]);
    try testing.expectEqualStrings("alpha", r2[0]);
    // 3. bad startxref
    const bad = try a.dupe(u8, good);
    const sx = std.mem.lastIndexOf(u8, bad, "startxref\n").?;
    @memset(bad[sx + 10 .. sx + 13], '9');
    const r3 = try pages(a, bad);
    try testing.expectEqual(@as(usize, 2), r3.len);
    // 4. object stream file with a chopped tail
    const os = try tp.simpleDoc(testing.allocator, &.{"BT /F1 12 Tf (packed) Tj ET"}, .objstm);
    defer testing.allocator.free(os);
    const r4 = try pages(a, os[0 .. os.len - 40]);
    try testing.expectEqualStrings("packed", r4[0]);
    // Not a PDF at all
    try testing.expectError(error.NotPdf, pdf.Doc.open(testing.allocator, "hello world", .{}));
    // Header but nothing usable
    try testing.expectError(error.Malformed, pdf.Doc.open(testing.allocator, "%PDF-1.4\nnothing here\n", .{}));
}

test "filter chains on content streams" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var b = tp.Builder.init(testing.allocator);
    defer b.deinit();
    const cat = try b.reserve();
    const pg = try b.reserve();
    const font = try b.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>");
    const z = try tp.zlib(a, "BT /F1 12 Tf 72 700 Td (chained) Tj ET");
    const hx = try tp.hex(a, z);
    const cs = try b.addStream("/Filter [/ASCIIHexDecode /FlateDecode]", hx);
    const pd = try std.fmt.allocPrint(a, "<< /Type /Page /Parent {d} 0 R /Resources << /Font << /F1 {d} 0 R >> >> /Contents [{d} 0 R] >>", .{ pg, font, cs });
    const pn = try b.add(pd);
    try b.set(pg, try std.fmt.allocPrint(a, "<< /Type /Pages /Kids [{d} 0 R] /Count 1 >>", .{pn}));
    try b.set(cat, try std.fmt.allocPrint(a, "<< /Type /Catalog /Pages {d} 0 R >>", .{pg}));
    const data = try b.writeClassic(cat, "");
    defer testing.allocator.free(data);
    const r = try pages(a, data);
    try testing.expectEqualStrings("chained", r[0]);
}

test "inflate is capped (zip bomb)" {
    const zeros = try testing.allocator.alloc(u8, 4 << 20);
    defer testing.allocator.free(zeros);
    @memset(zeros, 0);
    const z = try tp.zlib(testing.allocator, zeros);
    defer testing.allocator.free(z);
    try testing.expect(z.len < 64 * 1024);
    const out = try pdf.inflate(testing.allocator, z, 1 << 20);
    defer testing.allocator.free(out);
    try testing.expect(out.len <= (1 << 20) + 64 * 1024);
    try testing.expect(out.len > 0);

    // total work cap across a document
    const data = try tp.simpleDoc(testing.allocator, &.{"BT /F1 12 Tf (x) Tj ET"}, .flate);
    defer testing.allocator.free(data);
    const doc = try pdf.Doc.open(testing.allocator, data, .{ .max_total_bytes = 8 });
    defer doc.close();
    const pgs = try doc.getPages();
    var ex = text.Extractor.init(testing.allocator, doc);
    try testing.expectError(error.LimitExceeded, ex.page(pgs[0], 1000));
}

test "encrypted documents are reported, not parsed" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var b = tp.Builder.init(testing.allocator);
    defer b.deinit();
    const cat = try b.reserve();
    const pg = try b.reserve();
    const enc = try b.add("<< /Filter /Standard /V 1 /R 2 /O (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa) /U (bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb) /P -4 >>");
    const pn = try b.add(try std.fmt.allocPrint(a, "<< /Type /Page /Parent {d} 0 R >>", .{pg}));
    try b.set(pg, try std.fmt.allocPrint(a, "<< /Type /Pages /Kids [{d} 0 R] /Count 1 >>", .{pn}));
    try b.set(cat, try std.fmt.allocPrint(a, "<< /Type /Catalog /Pages {d} 0 R >>", .{pg}));
    const data = try b.writeClassic(cat, try std.fmt.allocPrint(a, "/Encrypt {d} 0 R", .{enc}));
    defer testing.allocator.free(data);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "e.pdf", .data = data });
    const cfg: main.Config = .{ .root = try tmp.dir.realPathFileAlloc(testing.io, ".", a) };
    const args = try std.json.parseFromSliceLeaky(Value, a, "{\"path\":\"e.pdf\"}", .{});
    const r = try main.textImpl(a, testing.io, cfg, args);
    try testing.expect(r.is_error);
    try testing.expectEqualStrings("encrypted, not supported", r.text);
    const ri = try main.infoImpl(a, testing.io, cfg, args);
    try testing.expect(std.mem.indexOf(u8, ri.text, "encrypted: yes") != null);
}

test "handlers: text, pages, truncation, search, info" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var b = tp.Builder.init(testing.allocator);
    defer b.deinit();
    const cat = try b.reserve();
    const pg = try b.reserve();
    const font = try b.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>");
    var kids: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    while (i <= 5) : (i += 1) {
        const c = try std.fmt.allocPrint(a, "BT /F1 12 Tf 72 700 Td (Page {d} mentions the Needle once) Tj 0 -14 Td (and more filler text {d}) Tj ET", .{ i, i });
        const cs = try b.addStream("", c);
        const p = try b.add(try std.fmt.allocPrint(a, "<< /Type /Page /Parent {d} 0 R /Resources << /Font << /F1 {d} 0 R >> >> /Contents {d} 0 R >>", .{ pg, font, cs }));
        try kids.print(a, "{d} 0 R ", .{p});
    }
    try b.set(pg, try std.fmt.allocPrint(a, "<< /Type /Pages /Kids [{s}] /Count 5 >>", .{kids.items}));
    try b.set(cat, try std.fmt.allocPrint(a, "<< /Type /Catalog /Pages {d} 0 R >>", .{pg}));
    // Info: UTF-16BE title with BOM, PDFDoc author, date
    const info = try b.add("<< /Title <FEFF00480069002000E9> /Author (Jane \\(Q\\) Doe) /CreationDate (D:20240102030405+01'00') /Producer (zmcp test) >>");
    const data = try b.writeClassic(cat, try std.fmt.allocPrint(a, "/Info {d} 0 R", .{info}));
    defer testing.allocator.free(data);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "doc.pdf", .data = data });
    const cfg: main.Config = .{ .root = try tmp.dir.realPathFileAlloc(testing.io, ".", a) };

    const p = struct {
        fn args(al: std.mem.Allocator, s: []const u8) !Value {
            return std.json.parseFromSliceLeaky(Value, al, s, .{});
        }
    };

    const t1 = try main.textImpl(a, testing.io, cfg, try p.args(a, "{\"path\":\"doc.pdf\",\"pages\":\"2-3\"}"));
    try testing.expect(!t1.is_error);
    try testing.expectEqualStrings(
        "--- page 2 ---\nPage 2 mentions the Needle once\nand more filler text 2\n--- page 3 ---\nPage 3 mentions the Needle once\nand more filler text 3\n",
        t1.text,
    );

    const t2 = try main.textImpl(a, testing.io, cfg, try p.args(a, "{\"path\":\"doc.pdf\",\"max_chars\":120}"));
    try testing.expect(std.mem.indexOf(u8, t2.text, "[truncated at 120 chars; continue with pages=\"") != null);
    try testing.expect(std.mem.indexOf(u8, t2.text, "--- page 1 ---") != null);
    try testing.expect(std.mem.indexOf(u8, t2.text, "--- page 5 ---") == null);

    const t3 = try main.textImpl(a, testing.io, cfg, try p.args(a, "{\"path\":\"doc.pdf\",\"pages\":\"9\"}"));
    try testing.expect(t3.is_error);
    const t4 = try main.textImpl(a, testing.io, cfg, try p.args(a, "{\"path\":\"doc.pdf\",\"pages\":\"x\"}"));
    try testing.expect(t4.is_error);

    const s1 = try main.searchImpl(a, testing.io, cfg, try p.args(a, "{\"path\":\"doc.pdf\",\"query\":\"the needle\",\"context\":10,\"limit\":3}"));
    try testing.expect(!s1.is_error);
    try testing.expect(std.mem.startsWith(u8, s1.text, "p1: ..."));
    try testing.expect(std.mem.indexOf(u8, s1.text, "mentions the Needle once") != null);
    try testing.expect(std.mem.indexOf(u8, s1.text, "p3:") != null);
    try testing.expect(std.mem.indexOf(u8, s1.text, "p4:") == null);
    try testing.expect(std.mem.indexOf(u8, s1.text, "[limit reached") != null);
    const s2 = try main.searchImpl(a, testing.io, cfg, try p.args(a, "{\"path\":\"doc.pdf\",\"query\":\"nothing-like-this\"}"));
    try testing.expect(std.mem.startsWith(u8, s2.text, "no matches"));
    // match spanning a line break
    const s3 = try main.searchImpl(a, testing.io, cfg, try p.args(a, "{\"path\":\"doc.pdf\",\"query\":\"once and more\",\"limit\":1}"));
    try testing.expect(std.mem.startsWith(u8, s3.text, "p1:"));

    const inf = try main.infoImpl(a, testing.io, cfg, try p.args(a, "{\"path\":\"doc.pdf\"}"));
    try testing.expect(!inf.is_error);
    try testing.expect(std.mem.indexOf(u8, inf.text, "pages: 5\n") != null);
    try testing.expect(std.mem.indexOf(u8, inf.text, "title: Hi \u{E9}\n") != null);
    try testing.expect(std.mem.indexOf(u8, inf.text, "author: Jane (Q) Doe\n") != null);
    try testing.expect(std.mem.indexOf(u8, inf.text, "created: 2024-01-02 03:04:05\n") != null);
    try testing.expect(std.mem.indexOf(u8, inf.text, "encrypted: no") != null);
    try testing.expect(std.mem.indexOf(u8, inf.text, "text: extractable") != null);
}

test "XMP-lite metadata fallback" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var b = tp.Builder.init(testing.allocator);
    defer b.deinit();
    const cat = try b.reserve();
    const pg = try b.reserve();
    const xmp = try b.addStream("/Type /Metadata /Subtype /XML",
        \\<x:xmpmeta><rdf:RDF><rdf:Description xmp:CreateDate="2020-05-06T07:08:09Z"><dc:title><rdf:Alt><rdf:li xml:lang="x-default">XMP Title</rdf:li></rdf:Alt></dc:title><dc:creator><rdf:Seq><rdf:li>XMP Author</rdf:li></rdf:Seq></dc:creator></rdf:Description></rdf:RDF></x:xmpmeta>
    );
    const pn = try b.add(try std.fmt.allocPrint(a, "<< /Type /Page /Parent {d} 0 R >>", .{pg}));
    try b.set(pg, try std.fmt.allocPrint(a, "<< /Type /Pages /Kids [{d} 0 R] /Count 1 >>", .{pn}));
    try b.set(cat, try std.fmt.allocPrint(a, "<< /Type /Catalog /Pages {d} 0 R /Metadata {d} 0 R >>", .{ pg, xmp }));
    const data = try b.writeClassic(cat, "");
    defer testing.allocator.free(data);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "x.pdf", .data = data });
    const cfg: main.Config = .{ .root = try tmp.dir.realPathFileAlloc(testing.io, ".", a) };
    const inf = try main.infoImpl(a, testing.io, cfg, try std.json.parseFromSliceLeaky(Value, a, "{\"path\":\"x.pdf\"}", .{}));
    try testing.expect(std.mem.indexOf(u8, inf.text, "title: XMP Title\n") != null);
    try testing.expect(std.mem.indexOf(u8, inf.text, "author: XMP Author\n") != null);
    try testing.expect(std.mem.indexOf(u8, inf.text, "created: 2020-05-06 07:08:09\n") != null);
}

test "path confinement and size cap" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const data = try tp.simpleDoc(testing.allocator, &.{"BT /F1 12 Tf (ok) Tj ET"}, .classic);
    defer testing.allocator.free(data);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "root", .default_dir);
    try tmp.dir.createDir(testing.io, "root/sub", .default_dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "root/sub/in.pdf", .data = data });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside.pdf", .data = data });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "rootevil.pdf", .data = data });
    const root = try tmp.dir.realPathFileAlloc(testing.io, "root", a);
    const outside = try tmp.dir.realPathFileAlloc(testing.io, "outside.pdf", a);
    const evil = try tmp.dir.realPathFileAlloc(testing.io, "rootevil.pdf", a);
    const cfg: main.Config = .{ .root = root };
    const call = struct {
        fn f(al: std.mem.Allocator, c: main.Config, path: []const u8) !mcp.ToolResult {
            const j = try std.fmt.allocPrint(al, "{{\"path\":\"{s}\"}}", .{path});
            return main.textImpl(al, testing.io, c, try std.json.parseFromSliceLeaky(Value, al, j, .{}));
        }
    }.f;
    try testing.expect(!(try call(a, cfg, "sub/in.pdf")).is_error);
    try testing.expect(!(try call(a, cfg, try std.fs.path.join(a, &.{ root, "sub/in.pdf" }))).is_error);
    try testing.expect((try call(a, cfg, "../outside.pdf")).is_error);
    try testing.expect((try call(a, cfg, "sub/../../outside.pdf")).is_error);
    try testing.expect((try call(a, cfg, outside)).is_error);
    // sibling directory sharing the root's name as a prefix
    const r_evil = try call(a, cfg, evil);
    try testing.expect(r_evil.is_error);
    try testing.expect(std.mem.indexOf(u8, r_evil.text, "outside") != null);
    // symlink inside the root pointing outside
    if (tmp.dir.symLink(testing.io, outside, "root/link.pdf", .{})) |_| {
        const r = try call(a, cfg, "link.pdf");
        try testing.expect(r.is_error);
    } else |_| {}
    try testing.expect((try call(a, cfg, "missing.pdf")).is_error);
    try testing.expect((try call(a, cfg, "sub")).is_error);
    // size cap
    const small: main.Config = .{ .root = root, .max_bytes = 100 };
    const r_big = try call(a, small, "sub/in.pdf");
    try testing.expect(r_big.is_error);
    try testing.expect(std.mem.indexOf(u8, r_big.text, "too large") != null);
    // not a pdf
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "root/notpdf.txt", .data = "plain text" });
    const r_np = try call(a, cfg, "notpdf.txt");
    try testing.expect(r_np.is_error);
    try testing.expect(std.mem.indexOf(u8, r_np.text, "not a PDF") != null);
}

test "page spec parsing" {
    const a = testing.allocator;
    const r = try main.parsePageSpec(a, "1-3, 7,9-", 10);
    defer a.free(r);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3, 7, 9, 10 }, r);
    const r2 = try main.parsePageSpec(a, "5-99,0", 6);
    defer a.free(r2);
    try testing.expectEqualSlices(u32, &.{ 5, 6 }, r2);
    try testing.expectError(error.BadSpec, main.parsePageSpec(a, "a-b", 6));
}

test "tool table: all read only" {
    // The three tools exist and are marked read_only (checked via ToolDef).
    try testing.expectEqual(@as(usize, 3), main.tool_table.len);
    for (main.tool_table) |t| try testing.expect(t.read_only and !t.destructive);
}

// ---------------------------------------------------------------------------
// fuzz-ish robustness: mutated PDFs must yield errors, never crash or hang.
// ---------------------------------------------------------------------------

fn exercise(data: []const u8) void {
    const doc = pdf.Doc.open(testing.allocator, data, .{ .max_total_bytes = 8 << 20, .max_stream_bytes = 1 << 20 }) catch return;
    defer doc.close();
    const pgs = doc.getPages() catch return;
    var ex = text.Extractor.init(testing.allocator, doc);
    defer ex.deinit();
    for (pgs[0..@min(pgs.len, 8)]) |p| {
        const pt = ex.page(p, 1 << 16) catch continue;
        testing.allocator.free(pt.text);
    }
}

fn fuzzOne(seed: u64, base: []const u8, iterations: usize) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    const buf = try testing.allocator.alloc(u8, base.len);
    defer testing.allocator.free(buf);
    var it: usize = 0;
    while (it < iterations) : (it += 1) {
        @memcpy(buf, base);
        var len = base.len;
        const nmut = 1 + rnd.uintLessThan(usize, 8);
        var k: usize = 0;
        while (k < nmut) : (k += 1) {
            const pos = rnd.uintLessThan(usize, len);
            switch (rnd.uintLessThan(u8, 4)) {
                0 => buf[pos] = rnd.int(u8),
                1 => buf[pos] ^= @as(u8, 1) << @intCast(rnd.uintLessThan(u8, 8)),
                2 => buf[pos] = "0123456789 <>[]()/RobjstreamxEndFilter"[rnd.uintLessThan(usize, 38)],
                else => len = @max(64, pos),
            }
        }
        exercise(buf[0..len]);
    }
}

test "fuzz: mutated PDFs never crash or hang" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const classic = try tp.simpleDoc(testing.allocator, &.{ "BT /F1 12 Tf 72 700 Td (Hello) Tj 0 -14 Td [(Wor) -300 (ld)] TJ ET", "BT /F1 12 Tf (two) Tj ET" }, .classic);
    defer testing.allocator.free(classic);
    const flate_doc = try tp.simpleDoc(testing.allocator, &.{"BT /F1 12 Tf 72 700 Td (Hello) Tj ET"}, .flate);
    defer testing.allocator.free(flate_doc);
    const objstm = try tp.simpleDoc(testing.allocator, &.{"BT /F1 12 Tf 72 700 Td (Hello) Tj ET"}, .objstm);
    defer testing.allocator.free(objstm);
    const forms = try formDoc(a, "/Fm2 Do BT /F1 12 Tf (x) Tj ET", "BT /F1 12 Tf (y) Tj ET /Fm1 Do");
    defer testing.allocator.free(forms);
    try fuzzOne(1, classic, 1500);
    try fuzzOne(2, flate_doc, 1500);
    try fuzzOne(3, objstm, 1500);
    try fuzzOne(4, forms, 1500);
}

test "garbage inputs" {
    exercise("");
    exercise("%PDF-");
    exercise("%PDF-1.7\nstartxref\n0\n%%EOF");
    exercise("%PDF-1.7\n1 0 obj\n<< /Type /Catalog /Pages 1 0 R >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n");
    // self-referencing page tree and Length
    exercise("%PDF-1.7\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [2 0 R 2 0 R] >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n");
    exercise("%PDF-1.7\n1 0 obj\n<< /Length 1 0 R >>\nstream\nabc\nendstream\nendobj\ntrailer\n<< /Root 1 0 R >>\n");
    // deep nesting
    var deep: [4096]u8 = undefined;
    @memset(&deep, '[');
    exercise(&deep);
}
