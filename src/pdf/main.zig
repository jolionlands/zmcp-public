//! zmcp-pdf - pure-Zig PDF text extraction (no external libraries or CLIs).
//!
//! Tools (all read-only): pdf_info, pdf_text, pdf_search.
//!
//! Safety: paths are confined to ZMCP_PDF_ROOT (default: cwd; symlinks
//! resolved), files above ZMCP_PDF_MAX_BYTES (default 64 MiB) are refused,
//! inflated stream sizes and total work are capped, and nothing is ever
//! written or executed. External references, JavaScript and launch actions
//! are never followed (the parser only reads objects).
//!
//! Out of scope, reported cleanly: encryption ("encrypted, not supported"),
//! scanned/image-only pages, table layout fidelity.

const std = @import("std");
const builtin = @import("builtin");
const mcp = @import("mcp");
const pdf = @import("pdf.zig");
const text = @import("text.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const DEFAULT_MAX_BYTES: usize = 64 << 20;
const OUTPUT_CAP: usize = 64 * 1024;
const DEFAULT_MAX_CHARS: usize = 30_000;
const MAX_QUERY: usize = 256;

pub const Config = struct {
    /// Unresolved root directory; null means the current directory.
    root: ?[]const u8 = null,
    max_bytes: usize = DEFAULT_MAX_BYTES,
};

var g_cfg: Config = .{};

pub fn main(init: std.process.Init) !void {
    if (init.environ_map.get("ZMCP_PDF_ROOT")) |r| {
        if (r.len > 0) g_cfg.root = r;
    }
    if (init.environ_map.get("ZMCP_PDF_MAX_BYTES")) |v| {
        if (std.fmt.parseInt(usize, std.mem.trim(u8, v, " \t"), 10)) |n| {
            if (n > 0) g_cfg.max_bytes = n;
        } else |_| {}
    }
    try mcp.run(init.gpa, init.io, .{ .name = "zmcp-pdf", .version = "0.1.0" }, &tool_table);
}

pub const tool_table = [_]mcp.ToolDef{
    .{
        .name = "pdf_info",
        .description = "PDF metadata: page count, title/author/dates, encryption, size, whether text is extractable.",
        .input_schema_json =
        \\{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}
        ,
        .handler = handleInfo,
        .read_only = true,
    },
    .{
        .name = "pdf_text",
        .description = "Extract plain text per page (--- page N --- separators). No OCR.",
        .input_schema_json =
        \\{"type":"object","properties":{"path":{"type":"string"},"pages":{"type":"string","description":"e.g. 1-3,7 (default all)"},"max_chars":{"type":"integer","description":"default 30000, max 65536"}},"required":["path"]}
        ,
        .handler = handleText,
        .read_only = true,
    },
    .{
        .name = "pdf_search",
        .description = "Case-insensitive text search; matches with page numbers and snippets.",
        .input_schema_json =
        \\{"type":"object","properties":{"path":{"type":"string"},"query":{"type":"string"},"context":{"type":"integer","description":"chars around match, default 60"},"limit":{"type":"integer","description":"default 20, max 200"}},"required":["path","query"]}
        ,
        .handler = handleSearch,
        .read_only = true,
    },
};

fn heap() Allocator {
    return if (builtin.is_test) std.testing.allocator else std.heap.smp_allocator;
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn fail(a: Allocator, comptime fmt: []const u8, args: anytype) !mcp.ToolResult {
    return .{ .text = try std.fmt.allocPrint(a, fmt, args), .is_error = true };
}

fn strArg(args: Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn intArg(args: Value, key: []const u8) ?i64 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f) and @abs(f) < 1e12) @as(i64, @intFromFloat(f)) else null,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// Resolve `path` inside the configured root. Returns a canonical path
/// (allocated from `a`) or an error message.
fn confine(a: Allocator, io: std.Io, cfg: Config, path: []const u8) union(enum) { ok: []const u8, err: []const u8 } {
    if (path.len == 0) return .{ .err = "empty path" };
    if (std.mem.indexOfScalar(u8, path, 0) != null) return .{ .err = "invalid path" };
    const cwd = std.Io.Dir.cwd();
    const root = cwd.realPathFileAlloc(io, cfg.root orelse ".", a) catch
        return .{ .err = "ZMCP_PDF_ROOT is not accessible" };
    const joined = if (std.fs.path.isAbsolute(path)) path else std.fs.path.join(a, &.{ root, path }) catch
        return .{ .err = "out of memory" };
    const real = cwd.realPathFileAlloc(io, joined, a) catch |e|
        return .{ .err = std.fmt.allocPrint(a, "cannot open {s}: {s}", .{ path, @errorName(e) }) catch "cannot open file" };
    const inside = std.mem.eql(u8, real, root) or
        (std.mem.startsWith(u8, real, root) and (root[root.len - 1] == std.fs.path.sep or real[root.len] == std.fs.path.sep));
    if (!inside) return .{ .err = "path is outside ZMCP_PDF_ROOT (default: the server's working directory)" };
    return .{ .ok = real };
}

const Opened = struct {
    data: []u8,
    doc: *pdf.Doc,
    encrypted: bool,

    fn deinit(self: *Opened) void {
        self.doc.close();
        heap().free(self.data);
    }
};

const OpenResult = union(enum) { ok: Opened, err: []const u8 };

fn openPdf(a: Allocator, io: std.Io, cfg: Config, path: []const u8) !OpenResult {
    const real = switch (confine(a, io, cfg, path)) {
        .ok => |p| p,
        .err => |m| return .{ .err = m },
    };
    const cwd = std.Io.Dir.cwd();
    const st = cwd.statFile(io, real, .{}) catch |e|
        return .{ .err = try std.fmt.allocPrint(a, "cannot stat {s}: {s}", .{ path, @errorName(e) }) };
    if (st.kind != .file) return .{ .err = "not a regular file" };
    if (st.size > cfg.max_bytes) {
        return .{ .err = try std.fmt.allocPrint(a, "file too large: {d} bytes (limit {d}; ZMCP_PDF_MAX_BYTES)", .{ st.size, cfg.max_bytes }) };
    }
    const data = cwd.readFileAlloc(io, real, heap(), .limited(cfg.max_bytes)) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.StreamTooLong => return .{ .err = "file too large" },
        else => return .{ .err = try std.fmt.allocPrint(a, "cannot read {s}: {s}", .{ path, @errorName(e) }) },
    };
    const doc = pdf.Doc.open(heap(), data, .{}) catch |e| {
        const encrypted_hint = std.mem.indexOf(u8, data, "/Encrypt") != null;
        heap().free(data);
        return switch (e) {
            error.OutOfMemory => e,
            error.NotPdf => .{ .err = "not a PDF file (no %PDF- header)" },
            error.LimitExceeded => .{ .err = "PDF exceeds internal safety limits" },
            else => .{ .err = if (encrypted_hint) "encrypted, not supported" else "malformed PDF: no usable page tree" },
        };
    };
    return .{ .ok = .{ .data = data, .doc = doc, .encrypted = doc.isEncrypted() } };
}

fn openErr(a: Allocator, msg: []const u8) !mcp.ToolResult {
    _ = a;
    return .{ .text = msg, .is_error = true };
}

/// "1-3,7,9-" (1-based) to a list of page numbers clamped to 1..n.
pub fn parsePageSpec(a: Allocator, spec: []const u8, n: usize) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(a);
    var it = std.mem.tokenizeAny(u8, spec, ", \t");
    while (it.next()) |tok| {
        if (std.ascii.eqlIgnoreCase(tok, "all")) {
            var p: u32 = 1;
            while (p <= n) : (p += 1) try out.append(a, p);
            continue;
        }
        var lo: usize = 1;
        var hi: usize = n;
        if (std.mem.indexOfScalar(u8, tok, '-')) |d| {
            if (d > 0) lo = std.fmt.parseInt(usize, tok[0..d], 10) catch return error.BadSpec;
            if (d + 1 < tok.len) hi = std.fmt.parseInt(usize, tok[d + 1 ..], 10) catch return error.BadSpec;
        } else {
            lo = std.fmt.parseInt(usize, tok, 10) catch return error.BadSpec;
            hi = lo;
        }
        if (lo == 0) lo = 1;
        if (hi > n) hi = n;
        var p = lo;
        while (p <= hi) : (p += 1) {
            if (out.items.len >= 100_000) return error.BadSpec;
            try out.append(a, @intCast(p));
        }
    }
    return out.toOwnedSlice(a);
}

fn utf8Floor(s: []const u8, len: usize) usize {
    var n = @min(len, s.len);
    while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
    return n;
}

const IMAGE_MSG = "(no extractable text; page appears to be an image)";
const EMPTY_MSG = "(no text on this page)";

fn garbledNote(pt: text.PageText) bool {
    return pt.unmapped > 0 and pt.unmapped * 5 >= @max(pt.text.len, 1);
}

// ---------------------------------------------------------------------------
// pdf_text
// ---------------------------------------------------------------------------

fn handleText(a: Allocator, io: std.Io, args: Value) anyerror!mcp.ToolResult {
    return textImpl(a, io, g_cfg, args);
}

pub fn textImpl(a: Allocator, io: std.Io, cfg: Config, args: Value) anyerror!mcp.ToolResult {
    const path = strArg(args, "path") orelse return fail(a, "missing `path`", .{});
    const op = try openPdf(a, io, cfg, path);
    switch (op) {
        .err => |m| return openErr(a, m),
        .ok => {},
    }
    var f = op.ok;
    defer f.deinit();
    if (f.encrypted) return openErr(a, "encrypted, not supported");

    const pages = f.doc.getPages() catch return fail(a, "malformed PDF: cannot read page tree", .{});
    if (pages.len == 0) return fail(a, "PDF has no pages", .{});
    const spec = strArg(args, "pages");
    const wanted: []u32 = if (spec) |s|
        parsePageSpec(a, s, pages.len) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => return fail(a, "bad `pages` (use e.g. \"1-3,7\")", .{}),
        }
    else
        try parsePageSpec(a, "all", pages.len);
    if (wanted.len == 0) return fail(a, "no pages in range (document has {d} pages)", .{pages.len});

    var max_chars: usize = DEFAULT_MAX_CHARS;
    if (intArg(args, "max_chars")) |m| {
        if (m > 0) max_chars = @intCast(@min(m, OUTPUT_CAP));
    }

    var ex = text.Extractor.init(heap(), f.doc);
    defer ex.deinit();
    var out: std.ArrayList(u8) = .empty;
    var resume_page: ?u32 = null;
    for (wanted) |pn| {
        if (out.items.len >= max_chars) {
            resume_page = pn;
            break;
        }
        const header = try std.fmt.allocPrint(a, "--- page {d} ---\n", .{pn});
        const remaining = max_chars - out.items.len;
        if (header.len >= remaining and out.items.len > 0) {
            resume_page = pn;
            break;
        }
        const budget = remaining -| header.len;
        const pt = ex.page(pages[pn - 1], budget + 64) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => {
                try out.appendSlice(a, header);
                try out.appendSlice(a, try std.fmt.allocPrint(a, "(error reading page: {s})\n", .{@errorName(e)}));
                continue;
            },
        };
        defer heap().free(pt.text);
        try out.appendSlice(a, header);
        if (pt.text.len == 0) {
            const msg: []const u8 = if (pt.has_images) IMAGE_MSG else if (pt.decode_error) "(page content uses an unsupported stream filter)" else EMPTY_MSG;
            try out.appendSlice(a, msg);
            try out.append(a, '\n');
            continue;
        }
        if (pt.text.len > budget) {
            const cut = utf8Floor(pt.text, budget);
            try out.appendSlice(a, pt.text[0..cut]);
            try out.append(a, '\n');
            resume_page = pn;
            break;
        }
        try out.appendSlice(a, pt.text);
        try out.append(a, '\n');
        if (garbledNote(pt)) try out.appendSlice(a, "[note: some fonts have no Unicode mapping; text may be garbled]\n");
    }
    if (resume_page) |rp| {
        try out.appendSlice(a, try std.fmt.allocPrint(a, "[truncated at {d} chars; continue with pages=\"{d}-\" or raise max_chars (max {d})]\n", .{ max_chars, rp, OUTPUT_CAP }));
    }
    return .{ .text = out.items };
}

// ---------------------------------------------------------------------------
// pdf_search
// ---------------------------------------------------------------------------

fn collapseWs(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_ws = true;
    for (s) |c| {
        if (c == ' ' or c == '\n' or c == '\t' or c == '\r') {
            if (!in_ws) try out.append(a, ' ');
            in_ws = true;
        } else {
            try out.append(a, c);
            in_ws = false;
        }
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
    return out.items;
}

fn handleSearch(a: Allocator, io: std.Io, args: Value) anyerror!mcp.ToolResult {
    return searchImpl(a, io, g_cfg, args);
}

pub fn searchImpl(a: Allocator, io: std.Io, cfg: Config, args: Value) anyerror!mcp.ToolResult {
    const path = strArg(args, "path") orelse return fail(a, "missing `path`", .{});
    const q_raw = strArg(args, "query") orelse return fail(a, "missing `query`", .{});
    const query = try collapseWs(a, q_raw);
    if (query.len == 0) return fail(a, "`query` is empty", .{});
    if (query.len > MAX_QUERY) return fail(a, "`query` too long (max {d} bytes)", .{MAX_QUERY});
    var ctx: usize = 60;
    if (intArg(args, "context")) |c| ctx = @intCast(std.math.clamp(c, 0, 300));
    var limit: usize = 20;
    if (intArg(args, "limit")) |l| limit = @intCast(std.math.clamp(l, 1, 200));

    const op = try openPdf(a, io, cfg, path);
    switch (op) {
        .err => |m| return openErr(a, m),
        .ok => {},
    }
    var f = op.ok;
    defer f.deinit();
    if (f.encrypted) return openErr(a, "encrypted, not supported");
    const pages = f.doc.getPages() catch return fail(a, "malformed PDF: cannot read page tree", .{});

    var ex = text.Extractor.init(heap(), f.doc);
    defer ex.deinit();
    var lines: std.ArrayList(u8) = .empty;
    var shown: usize = 0;
    var empty_pages: usize = 0;
    var hit_limit = false;
    var page_no: usize = 0;
    while (page_no < pages.len and !hit_limit) : (page_no += 1) {
        const pt = ex.page(pages[page_no], 4 << 20) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => continue,
        };
        defer heap().free(pt.text);
        if (pt.text.len == 0) {
            empty_pages += 1;
            continue;
        }
        const norm = try collapseWs(a, pt.text);
        var from: usize = 0;
        while (std.ascii.indexOfIgnoreCasePos(norm, from, query)) |i| {
            if (shown >= limit) {
                hit_limit = true;
                break;
            }
            var s = i -| ctx;
            var e = @min(norm.len, i + query.len + ctx);
            while (s > 0 and (norm[s] & 0xC0) == 0x80) s -= 1;
            while (e < norm.len and (norm[e] & 0xC0) == 0x80) e += 1;
            try lines.appendSlice(a, try std.fmt.allocPrint(a, "p{d}: {s}{s}{s}\n", .{
                page_no + 1,
                if (s > 0) "..." else "",
                norm[s..e],
                if (e < norm.len) "..." else "",
            }));
            shown += 1;
            from = i + query.len;
        }
        if (lines.items.len > OUTPUT_CAP) {
            hit_limit = true;
            break;
        }
    }
    var out: std.ArrayList(u8) = .empty;
    if (shown == 0) {
        try out.appendSlice(a, try std.fmt.allocPrint(a, "no matches for \"{s}\" in {d} pages", .{ query, pages.len }));
        if (empty_pages > 0) try out.appendSlice(a, try std.fmt.allocPrint(a, " ({d} pages have no extractable text)", .{empty_pages}));
        try out.append(a, '\n');
        return .{ .text = out.items };
    }
    try out.appendSlice(a, lines.items);
    if (hit_limit) try out.appendSlice(a, "[limit reached; more matches may exist. Raise limit or use a more specific query]\n");
    return .{ .text = out.items };
}

// ---------------------------------------------------------------------------
// pdf_info
// ---------------------------------------------------------------------------

fn handleInfo(a: Allocator, io: std.Io, args: Value) anyerror!mcp.ToolResult {
    return infoImpl(a, io, g_cfg, args);
}

fn oneLine(a: Allocator, s: []const u8) ![]u8 {
    const t = try pdf.textString(a, s);
    for (t) |*c| {
        if (c.* == '\n' or c.* == '\r' or c.* == '\t') c.* = ' ';
    }
    const cut = utf8Floor(t, 300);
    return t[0..cut];
}

/// First text content of `<tag ...>...</tag>`, stripping nested tags; or an
/// attribute `tag="..."`. Enough for the flat XMP most producers write.
fn xmpField(a: Allocator, xml: []const u8, tag: []const u8) !?[]const u8 {
    const open = try std.fmt.allocPrint(a, "<{s}", .{tag});
    if (std.mem.indexOf(u8, xml, open)) |i| {
        const gt = std.mem.indexOfScalarPos(u8, xml, i, '>') orelse return null;
        const close = try std.fmt.allocPrint(a, "</{s}>", .{tag});
        const end = std.mem.indexOfPos(u8, xml, gt, close) orelse return null;
        var out: std.ArrayList(u8) = .empty;
        var in_tag = false;
        for (xml[gt + 1 .. end]) |c| {
            if (c == '<') in_tag = true else if (c == '>') in_tag = false else if (!in_tag) try out.append(a, c);
        }
        const t = std.mem.trim(u8, out.items, " \t\r\n");
        return if (t.len == 0) null else t;
    }
    const attr = try std.fmt.allocPrint(a, "{s}=\"", .{tag});
    if (std.mem.indexOf(u8, xml, attr)) |i| {
        const s = i + attr.len;
        const e = std.mem.indexOfScalarPos(u8, xml, s, '"') orelse return null;
        return if (e > s) xml[s..e] else null;
    }
    return null;
}

pub fn infoImpl(a: Allocator, io: std.Io, cfg: Config, args: Value) anyerror!mcp.ToolResult {
    const path = strArg(args, "path") orelse return fail(a, "missing `path`", .{});
    const op = try openPdf(a, io, cfg, path);
    switch (op) {
        .err => |m| {
            // Still tell the caller about encryption in the info shape.
            return openErr(a, m);
        },
        .ok => {},
    }
    var f = op.ok;
    defer f.deinit();
    const doc = f.doc;
    var out: std.ArrayList(u8) = .empty;

    const pages = doc.getPages() catch &[_]pdf.Page{};
    try out.appendSlice(a, try std.fmt.allocPrint(a, "pages: {d}\nsize: {d} bytes\nversion: {s}\n", .{ pages.len, f.data.len, doc.version }));
    if (f.encrypted) {
        try out.appendSlice(a, "encrypted: yes (encrypted, not supported)\n");
        return .{ .text = out.items };
    }
    try out.appendSlice(a, "encrypted: no\n");

    const Field = struct { key: []const u8, label: []const u8, xmp: []const u8, date: bool };
    const fields = [_]Field{
        .{ .key = "Title", .label = "title", .xmp = "dc:title", .date = false },
        .{ .key = "Author", .label = "author", .xmp = "dc:creator", .date = false },
        .{ .key = "Subject", .label = "subject", .xmp = "dc:description", .date = false },
        .{ .key = "Keywords", .label = "keywords", .xmp = "pdf:Keywords", .date = false },
        .{ .key = "Creator", .label = "creator", .xmp = "xmp:CreatorTool", .date = false },
        .{ .key = "Producer", .label = "producer", .xmp = "pdf:Producer", .date = false },
        .{ .key = "CreationDate", .label = "created", .xmp = "xmp:CreateDate", .date = true },
        .{ .key = "ModDate", .label = "modified", .xmp = "xmp:ModifyDate", .date = true },
    };
    var info: ?pdf.Dict = null;
    if (doc.trailerGet("Info")) |io_| {
        info = ((doc.deref(io_) catch pdf.null_obj)).asDict();
    }
    var xmp: ?[]const u8 = null;
    if (doc.trailerGet("Root")) |r| {
        if (((doc.deref(r) catch pdf.null_obj)).asDict()) |rd| {
            const m = doc.get(rd, "Metadata") catch pdf.null_obj;
            if (m == .stream) {
                xmp = doc.decodeStream(a, m.stream) catch null;
            }
        }
    }
    for (fields) |fl| {
        var val: ?[]const u8 = null;
        if (info) |d| {
            const v = doc.get(d, fl.key) catch pdf.null_obj;
            if (v == .string and v.string.len > 0) val = try oneLine(a, v.string);
        }
        if (val == null) {
            if (xmp) |x| {
                if (try xmpField(a, x, fl.xmp)) |xv| val = try oneLine(a, xv);
            }
        }
        if (val) |v| {
            const shown = if (fl.date) try pdf.formatDate(a, v) else v;
            try out.appendSlice(a, try std.fmt.allocPrint(a, "{s}: {s}\n", .{ fl.label, shown }));
        }
    }

    // Is text extractable? Look at the first few pages.
    var ex = text.Extractor.init(heap(), doc);
    defer ex.deinit();
    var checked: usize = 0;
    var any_text = false;
    var any_images = false;
    var garbled = false;
    while (checked < @min(pages.len, 4)) : (checked += 1) {
        const pt = ex.page(pages[checked], 2000) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => continue,
        };
        defer heap().free(pt.text);
        if (pt.text.len > 0) any_text = true;
        if (pt.has_images) any_images = true;
        if (garbledNote(pt)) garbled = true;
        if (any_text) break;
    }
    if (pages.len == 0) {
        try out.appendSlice(a, "text: unknown (no pages)\n");
    } else if (any_text) {
        try out.appendSlice(a, if (garbled) "text: extractable (some fonts lack Unicode mapping; may be garbled)\n" else "text: extractable\n");
    } else if (any_images) {
        try out.appendSlice(a, "text: none found; pages appear to be images (scanned, needs OCR)\n");
    } else {
        try out.appendSlice(a, "text: none found in first pages\n");
    }
    return .{ .text = out.items };
}

test {
    _ = @import("pdf.zig");
    _ = @import("inflate.zig");
    _ = @import("enc.zig");
    _ = @import("text.zig");
    _ = @import("tests.zig");
}
