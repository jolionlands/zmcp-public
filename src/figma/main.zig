//! zmcp-figma - pure-Zig port of GLips/Figma-Context-MCP (Framelink).
//! Tools (names verified upstream): get_figma_data, download_figma_images.
//! Figma REST API v1; token from FIGMA_API_KEY (X-Figma-Token) or
//! FIGMA_OAUTH_TOKEN (Bearer), plus FIGMA_ACCESS_TOKEN as an extra alias.
//! get_figma_data returns a compact simplified tree with a global style table.

const std = @import("std");
const mcp = @import("mcp");

const API_BASE = "https://api.figma.com/v1";
const UA_PRODUCT = "zmcp-figma/0.1.0";
const MAX_OUTPUT: usize = 64 * 1024;
const MAX_NODES: u32 = 1500;
const DEFAULT_MAX_DEPTH: u32 = 12;
const MAX_IMAGES: usize = 50;
const MAX_IMAGE_BYTES: usize = 10 * 1024 * 1024;
const MAX_API_BYTES: usize = 64 * 1024 * 1024;

// ---------------------------------------------------------------- config

var api_key: ?[]const u8 = null;
var oauth_token: ?[]const u8 = null;
var out_dir: []const u8 = "./figma-assets";

pub fn main(init: std.process.Init) !void {
    const env = init.environ_map;
    api_key = nonEmpty(env.get("FIGMA_API_KEY")) orelse nonEmpty(env.get("FIGMA_ACCESS_TOKEN"));
    oauth_token = nonEmpty(env.get("FIGMA_OAUTH_TOKEN"));
    if (nonEmpty(env.get("ZMCP_FIGMA_OUT_DIR"))) |d| out_dir = d;
    try mcp.run(init.gpa, init.io, .{ .name = "zmcp-figma", .version = "0.1.0" }, &tool_table);
}

fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (v.len == 0) null else v;
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "get_figma_data",
        .description = "Get a compact simplified layout/style tree of a Figma file or node (styles deduped into a global table).",
        .input_schema_json =
        \\{"type":"object","properties":{
        \\"fileKey":{"type":"string","description":"Figma file key or full figma.com URL (node-id in URL is used if nodeId omitted)."},
        \\"nodeId":{"type":"string","description":"Node id, e.g. 1234:5678 (also 1234-5678)."},
        \\"depth":{"type":"integer","description":"Optional max tree depth."}},
        \\"required":["fileKey"]}
        ,
        .handler = handleGetData,
        .read_only = true,
    },
    .{
        .name = "download_figma_images",
        .description = "Download PNG/SVG/GIF images of Figma nodes or image fills into a directory under the allowed output base.",
        .input_schema_json =
        \\{"type":"object","properties":{
        \\"fileKey":{"type":"string","description":"Figma file key or URL."},
        \\"nodes":{"type":"array","description":"Max 50.","items":{"type":"object","properties":{
        \\"nodeId":{"type":"string"},
        \\"imageRef":{"type":"string","description":"For image fills; omit for vectors."},
        \\"gifRef":{"type":"string"},
        \\"fileName":{"type":"string","description":"name.png|svg|gif"}},
        \\"required":["nodeId","fileName"]}},
        \\"pngScale":{"type":"number","description":"Default 2."},
        \\"localPath":{"type":"string","description":"Subdirectory under the output base."}},
        \\"required":["fileKey","nodes","localPath"]}
        ,
        .handler = handleDownload,
    },
};

// ---------------------------------------------------------------- seams

const HttpResp = struct { status: u16, body: []u8 };
const Req = struct {
    url: []const u8,
    /// false = unauthenticated (image CDN downloads).
    auth: bool,
    max_bytes: usize,
};
const FetchFn = *const fn (std.mem.Allocator, std.Io, Req) anyerror!HttpResp;
const WriteFn = *const fn (std.Io, []const u8, []const u8) anyerror!void;

var fetch_impl: FetchFn = httpsFetch;
var write_impl: WriteFn = diskWrite;

fn httpsFetch(alloc: std.mem.Allocator, io: std.Io, req: Req) !HttpResp {
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();
    const ua_owned = try mcp.userAgent(alloc, io, UA_PRODUCT);
    defer alloc.free(ua_owned);
    var resp_buf: std.Io.Writer.Allocating = .init(alloc);
    defer resp_buf.deinit();
    var decompress_buf: [128 * 1024]u8 = undefined;

    var hdrs: [2]std.http.Header = undefined;
    var n: usize = 0;
    hdrs[n] = .{ .name = "User-Agent", .value = ua_owned };
    n += 1;
    if (req.auth) {
        if (api_key) |k| {
            hdrs[n] = .{ .name = "X-Figma-Token", .value = k };
            n += 1;
        } else if (oauth_token) |t| {
            hdrs[n] = .{ .name = "Authorization", .value = try std.fmt.allocPrint(alloc, "Bearer {s}", .{t}) };
            n += 1;
        }
    }
    const res = try client.fetch(.{
        .location = .{ .url = req.url },
        .response_writer = &resp_buf.writer,
        .method = .GET,
        .extra_headers = hdrs[0..n],
        .decompress_buffer = &decompress_buf,
    });
    if (resp_buf.written().len > req.max_bytes) return error.ResponseTooLarge;
    return .{ .status = @intFromEnum(res.status), .body = try alloc.dupe(u8, resp_buf.written()) };
}

fn diskWrite(io: std.Io, path: []const u8, data: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |d| try cwd.createDirPath(io, d);
    try cwd.writeFile(io, .{ .sub_path = path, .data = data });
}

// ---------------------------------------------------------------- helpers

fn errResult(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) mcp.ToolResult {
    return .{ .text = std.fmt.allocPrint(alloc, fmt, args) catch "error", .is_error = true };
}

fn getStr(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn getField(args: std.json.Value, key: []const u8) ?std.json.Value {
    if (args != .object) return null;
    return args.object.get(key);
}

fn numOf(v: ?std.json.Value) ?f64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn hasToken() bool {
    return api_key != null or oauth_token != null;
}

const missing_token_msg = "Figma token not set: export FIGMA_API_KEY (personal access token; FIGMA_ACCESS_TOKEN or FIGMA_OAUTH_TOKEN also accepted).";

/// Map a non-2xx Figma status to a short model-facing message.
fn statusMessage(status: u16) ?[]const u8 {
    if (status >= 200 and status < 300) return null;
    return switch (status) {
        400 => "Figma 400: bad request (check file key / node id / parameters).",
        401, 403 => "Figma 403: invalid token or no access to this file.",
        404 => "Figma 404: file or node not found (check fileKey and nodeId).",
        429 => "Figma 429: rate limited; retry later.",
        500...599 => "Figma server error; retry later.",
        else => "Figma request failed with an unexpected status.",
    };
}

const KeyRef = struct { key: []const u8, node_id: ?[]const u8 = null };

fn validKey(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return true;
}

/// Accepts a bare key or a figma.com URL (file|design|board|proto|make|slides,
/// optional /branch/<key>, optional node-id query). Slices point into `input`.
fn parseFileRef(input: []const u8) ?KeyRef {
    const s = std.mem.trim(u8, input, " \t\r\n");
    if (validKey(s)) return .{ .key = s };
    var rest: []const u8 = s;
    if (std.mem.startsWith(u8, rest, "https://")) {
        rest = rest[8..];
    } else if (std.mem.startsWith(u8, rest, "http://")) {
        rest = rest[7..];
    } else return null;
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const host = rest[0..slash];
    if (!(std.mem.eql(u8, host, "figma.com") or std.mem.endsWith(u8, host, ".figma.com"))) return null;
    const path_q = rest[slash + 1 ..];
    const qpos = std.mem.indexOfScalar(u8, path_q, '?');
    var path = if (qpos) |q| path_q[0..q] else path_q;
    if (std.mem.indexOfScalar(u8, path, '#')) |h| path = path[0..h];
    const query = if (qpos) |q| path_q[q + 1 ..] else "";

    var it = std.mem.splitScalar(u8, path, '/');
    const kind = it.next() orelse return null;
    const kinds = [_][]const u8{ "file", "design", "board", "proto", "make", "slides" };
    var ok = false;
    for (kinds) |k| {
        if (std.mem.eql(u8, k, kind)) ok = true;
    }
    if (!ok) return null;
    var key = it.next() orelse return null;
    if (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "branch")) {
            if (it.next()) |bk| key = bk;
        }
    }
    if (!validKey(key)) return null;
    var node: ?[]const u8 = null;
    var qi = std.mem.splitScalar(u8, query, '&');
    while (qi.next()) |kv| {
        if (std.mem.startsWith(u8, kv, "node-id=")) {
            var v = kv[8..];
            if (std.mem.indexOfScalar(u8, v, '#')) |h| v = v[0..h];
            node = v;
        }
    }
    return .{ .key = key, .node_id = node };
}

/// Validate and normalise a node id. "1234-5678" -> "1234:5678"; instance ids
/// like "I1:2;3-4" are handled; %3A / %3B escapes are decoded.
fn normalizeNodeId(alloc: std.mem.Allocator, raw: []const u8) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '%') {
            if (i + 3 > raw.len) return dropNull(alloc, &out);
            const h = raw[i + 1 .. i + 3];
            if (std.ascii.eqlIgnoreCase(h, "3A")) {
                try out.append(alloc, ':');
            } else if (std.ascii.eqlIgnoreCase(h, "3B")) {
                try out.append(alloc, ';');
            } else return dropNull(alloc, &out);
            i += 2;
        } else if (c == '-') {
            try out.append(alloc, ':');
        } else if (std.ascii.isDigit(c) or c == ':' or c == ';' or c == 'I') {
            try out.append(alloc, c);
        } else return dropNull(alloc, &out);
    }
    if (out.items.len == 0 or out.items.len > 128) return dropNull(alloc, &out);
    return try out.toOwnedSlice(alloc);
}

fn dropNull(alloc: std.mem.Allocator, out: *std.ArrayList(u8)) ?[]u8 {
    out.deinit(alloc);
    return null;
}

fn urlEncode(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try out.append(alloc, c);
        } else {
            try out.print(alloc, "%{X:0>2}", .{c});
        }
    }
}

const ApiResult = union(enum) { ok: std.json.Value, fail: mcp.ToolResult };

fn apiGet(alloc: std.mem.Allocator, io: std.Io, url: []const u8) !ApiResult {
    const resp = fetch_impl(alloc, io, .{ .url = url, .auth = true, .max_bytes = MAX_API_BYTES }) catch |err| {
        return .{ .fail = errResult(alloc, "Figma request failed: {s}", .{@errorName(err)}) };
    };
    if (statusMessage(resp.status)) |m| return .{ .fail = .{ .text = m, .is_error = true } };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, resp.body, .{}) catch {
        return .{ .fail = .{ .text = "Figma returned invalid JSON.", .is_error = true } };
    };
    return .{ .ok = parsed };
}

// ---------------------------------------------------------------- simplifier

const Obj = std.json.ObjectMap;
const Val = std.json.Value;

const Cat = enum { fill, stroke, effect, font, layout };

const Ctx = struct {
    a: std.mem.Allocator,
    styles: Obj = .empty,
    canon: std.StringHashMapUnmanaged([]const u8) = .empty,
    counters: [5]u32 = .{ 0, 0, 0, 0, 0 },
    emitted: u32 = 0,
    omitted: u32 = 0,
    max_depth: u32,
    max_nodes: u32,
    depth_cut: bool = false,

    /// Values with a short canonical form stay inline; others go to the table.
    fn intern(self: *Ctx, cat: Cat, v: Val) !Val {
        const s = try std.json.Stringify.valueAlloc(self.a, v, .{});
        if (s.len <= 18) return v;
        const key = try std.fmt.allocPrint(self.a, "{s}{s}", .{ @tagName(cat), s });
        if (self.canon.get(key)) |id| return .{ .string = id };
        const idx = @intFromEnum(cat);
        self.counters[idx] += 1;
        const id = try std.fmt.allocPrint(self.a, "{s}_{d}", .{ @tagName(cat), self.counters[idx] });
        try self.canon.put(self.a, key, id);
        try self.styles.put(self.a, id, v);
        return .{ .string = id };
    }
};

fn numVal(f: f64) Val {
    const r = @round(f * 100.0) / 100.0;
    if (@abs(r) < 1e15 and r == @round(r)) return .{ .integer = @intFromFloat(r) };
    return .{ .float = r };
}

fn strVal(s: []const u8) Val {
    return .{ .string = s };
}

fn newArr(a: std.mem.Allocator) std.json.Array {
    return std.json.Array.init(a);
}

fn byte255(f: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(f, 0.0, 1.0) * 255.0));
}

fn colorStr(a: std.mem.Allocator, c: Val, extra_opacity: f64) !?[]const u8 {
    if (c != .object) return null;
    const r = numOf(c.object.get("r")) orelse 0;
    const g = numOf(c.object.get("g")) orelse 0;
    const b = numOf(c.object.get("b")) orelse 0;
    const al = (numOf(c.object.get("a")) orelse 1.0) * extra_opacity;
    if (al >= 0.995) {
        return try std.fmt.allocPrint(a, "#{x:0>2}{x:0>2}{x:0>2}", .{ byte255(r), byte255(g), byte255(b) });
    }
    return try std.fmt.allocPrint(a, "rgba({d},{d},{d},{d})", .{ byte255(r), byte255(g), byte255(b), @round(al * 100.0) / 100.0 });
}

fn isHidden(v: Val) bool {
    if (v != .object) return false;
    const vis = v.object.get("visible") orelse return false;
    return vis == .bool and !vis.bool;
}

fn simplifyPaint(a: std.mem.Allocator, p: Val) !?Val {
    if (p != .object or isHidden(p)) return null;
    const t = getStr(p, "type") orelse return null;
    const op = numOf(p.object.get("opacity")) orelse 1.0;
    if (std.mem.eql(u8, t, "SOLID")) {
        const c = p.object.get("color") orelse return null;
        const s = (try colorStr(a, c, op)) orelse return null;
        return strVal(s);
    }
    if (std.mem.startsWith(u8, t, "GRADIENT_")) {
        var o: Obj = .empty;
        const kind: []const u8 = if (std.mem.eql(u8, t, "GRADIENT_LINEAR")) "linear" else if (std.mem.eql(u8, t, "GRADIENT_RADIAL")) "radial" else if (std.mem.eql(u8, t, "GRADIENT_ANGULAR")) "angular" else "diamond";
        try o.put(a, "gradient", strVal(kind));
        var stops = newArr(a);
        if (p.object.get("gradientStops")) |gs| if (gs == .array) for (gs.array.items) |st| {
            if (st != .object) continue;
            const c = st.object.get("color") orelse continue;
            const cs = (try colorStr(a, c, op)) orelse continue;
            const pos = numOf(st.object.get("position")) orelse 0;
            try stops.append(strVal(try std.fmt.allocPrint(a, "{s} {d}", .{ cs, @round(pos * 100.0) / 100.0 })));
        };
        try o.put(a, "stops", .{ .array = stops });
        return .{ .object = o };
    }
    if (std.mem.eql(u8, t, "IMAGE")) {
        var o: Obj = .empty;
        if (getStr(p, "imageRef")) |r| try o.put(a, "img", strVal(r));
        if (getStr(p, "scaleMode")) |m| try o.put(a, "mode", strVal(m));
        return .{ .object = o };
    }
    return null;
}

fn simplifyPaints(ctx: *Ctx, list: Val) !?Val {
    if (list != .array) return null;
    var arr = newArr(ctx.a);
    for (list.array.items) |p| {
        if (try simplifyPaint(ctx.a, p)) |sp| try arr.append(sp);
    }
    if (arr.items.len == 0) return null;
    const v: Val = if (arr.items.len == 1) arr.items[0] else .{ .array = arr };
    return v;
}

fn simplifyEffects(ctx: *Ctx, list: Val) !?Val {
    if (list != .array) return null;
    var arr = newArr(ctx.a);
    for (list.array.items) |e| {
        if (e != .object or isHidden(e)) continue;
        const t = getStr(e, "type") orelse continue;
        var o: Obj = .empty;
        const short: []const u8 = if (std.mem.eql(u8, t, "DROP_SHADOW")) "shadow" else if (std.mem.eql(u8, t, "INNER_SHADOW")) "inner-shadow" else if (std.mem.eql(u8, t, "LAYER_BLUR")) "blur" else if (std.mem.eql(u8, t, "BACKGROUND_BLUR")) "bg-blur" else t;
        try o.put(ctx.a, "t", strVal(short));
        if (e.object.get("offset")) |off| if (off == .object) {
            try o.put(ctx.a, "x", numVal(numOf(off.object.get("x")) orelse 0));
            try o.put(ctx.a, "y", numVal(numOf(off.object.get("y")) orelse 0));
        };
        if (numOf(e.object.get("radius"))) |r| try o.put(ctx.a, "r", numVal(r));
        if (numOf(e.object.get("spread"))) |s| if (s != 0) try o.put(ctx.a, "s", numVal(s));
        if (e.object.get("color")) |c| if (try colorStr(ctx.a, c, 1.0)) |cs| try o.put(ctx.a, "c", strVal(cs));
        try arr.append(.{ .object = o });
    }
    if (arr.items.len == 0) return null;
    return .{ .array = arr };
}

fn axisWord(s: []const u8) []const u8 {
    if (std.mem.eql(u8, s, "MIN")) return "start";
    if (std.mem.eql(u8, s, "MAX")) return "end";
    if (std.mem.eql(u8, s, "CENTER")) return "center";
    if (std.mem.eql(u8, s, "SPACE_BETWEEN")) return "between";
    if (std.mem.eql(u8, s, "BASELINE")) return "baseline";
    return s;
}

fn simplifyLayout(ctx: *Ctx, n: Val) !?Val {
    const mode = getStr(n, "layoutMode") orelse return null;
    if (std.mem.eql(u8, mode, "NONE")) return null;
    var o: Obj = .empty;
    try o.put(ctx.a, "dir", strVal(if (std.mem.eql(u8, mode, "HORIZONTAL")) "row" else if (std.mem.eql(u8, mode, "VERTICAL")) "col" else "grid"));
    if (numOf(n.object.get("itemSpacing"))) |g| if (g != 0) try o.put(ctx.a, "gap", numVal(g));
    const pt = numOf(n.object.get("paddingTop")) orelse 0;
    const pr = numOf(n.object.get("paddingRight")) orelse 0;
    const pb = numOf(n.object.get("paddingBottom")) orelse 0;
    const pl = numOf(n.object.get("paddingLeft")) orelse 0;
    if (pt != 0 or pr != 0 or pb != 0 or pl != 0) {
        var pa = newArr(ctx.a);
        for ([_]f64{ pt, pr, pb, pl }) |x| try pa.append(numVal(x));
        try o.put(ctx.a, "pad", .{ .array = pa });
    }
    if (getStr(n, "primaryAxisAlignItems")) |m| if (!std.mem.eql(u8, m, "MIN")) try o.put(ctx.a, "main", strVal(axisWord(m)));
    if (getStr(n, "counterAxisAlignItems")) |m| if (!std.mem.eql(u8, m, "MIN")) try o.put(ctx.a, "cross", strVal(axisWord(m)));
    if (getStr(n, "layoutWrap")) |w| if (std.mem.eql(u8, w, "WRAP")) try o.put(ctx.a, "wrap", .{ .bool = true });
    return try ctx.intern(.layout, .{ .object = o });
}

fn textAlignWord(s: []const u8) []const u8 {
    if (std.mem.eql(u8, s, "CENTER")) return "center";
    if (std.mem.eql(u8, s, "RIGHT")) return "right";
    if (std.mem.eql(u8, s, "JUSTIFIED")) return "justify";
    return s;
}

fn simplifyFont(ctx: *Ctx, st: Val) !?Val {
    if (st != .object) return null;
    var o: Obj = .empty;
    if (getStr(st, "fontFamily")) |f| try o.put(ctx.a, "family", strVal(f));
    if (numOf(st.object.get("fontSize"))) |x| try o.put(ctx.a, "size", numVal(x));
    if (numOf(st.object.get("fontWeight"))) |x| try o.put(ctx.a, "weight", numVal(x));
    if (numOf(st.object.get("lineHeightPx"))) |x| try o.put(ctx.a, "lh", numVal(x));
    if (numOf(st.object.get("letterSpacing"))) |x| if (x != 0) try o.put(ctx.a, "ls", numVal(x));
    if (getStr(st, "textAlignHorizontal")) |x| if (!std.mem.eql(u8, x, "LEFT")) try o.put(ctx.a, "align", strVal(textAlignWord(x)));
    if (getStr(st, "textCase")) |x| try o.put(ctx.a, "case", strVal(x));
    return try ctx.intern(.font, .{ .object = o });
}

fn sizingWord(s: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, s, "FILL")) return "fill";
    if (std.mem.eql(u8, s, "HUG")) return "hug";
    return null;
}

fn simplifyNode(ctx: *Ctx, n: Val, depth: u32, parent_box: ?[2]f64, parent_auto: bool) !?Val {
    if (n != .object or isHidden(n)) return null;
    if (ctx.emitted >= ctx.max_nodes) {
        ctx.omitted += 1;
        return null;
    }
    ctx.emitted += 1;
    const a = ctx.a;
    var o: Obj = .empty;
    if (getStr(n, "id")) |id| try o.put(a, "id", strVal(id));
    if (getStr(n, "name")) |nm| try o.put(a, "name", strVal(nm));
    const ty = getStr(n, "type") orelse "UNKNOWN";
    try o.put(a, "type", strVal(ty));

    var my_origin: ?[2]f64 = null;
    if (n.object.get("absoluteBoundingBox")) |bb| if (bb == .object) {
        const x = numOf(bb.object.get("x")) orelse 0;
        const y = numOf(bb.object.get("y")) orelse 0;
        const w = numOf(bb.object.get("width")) orelse 0;
        const h = numOf(bb.object.get("height")) orelse 0;
        my_origin = .{ x, y };
        var ba = newArr(a);
        if (parent_auto) {
            try ba.append(numVal(w));
            try ba.append(numVal(h));
            try o.put(a, "size", .{ .array = ba });
        } else {
            const po = parent_box orelse [2]f64{ 0, 0 };
            try ba.append(numVal(x - po[0]));
            try ba.append(numVal(y - po[1]));
            try ba.append(numVal(w));
            try ba.append(numVal(h));
            try o.put(a, "box", .{ .array = ba });
        }
    };

    if (try simplifyLayout(ctx, n)) |l| try o.put(a, "layout", l);
    if (getStr(n, "layoutSizingHorizontal")) |s| if (sizingWord(s)) |w| try o.put(a, "sx", strVal(w));
    if (getStr(n, "layoutSizingVertical")) |s| if (sizingWord(s)) |w| try o.put(a, "sy", strVal(w));
    if (getStr(n, "layoutPositioning")) |s| if (std.mem.eql(u8, s, "ABSOLUTE")) try o.put(a, "abs", .{ .bool = true });

    if (n.object.get("fills")) |f| if (try simplifyPaints(ctx, f)) |v| try o.put(a, "fill", try ctx.intern(.fill, v));
    if (n.object.get("strokes")) |sk| if (try simplifyPaints(ctx, sk)) |v| {
        var so: Obj = .empty;
        try so.put(a, "c", v);
        if (numOf(n.object.get("strokeWeight"))) |w| try so.put(a, "w", numVal(w));
        if (getStr(n, "strokeAlign")) |sa| if (!std.mem.eql(u8, sa, "INSIDE")) try so.put(a, "align", strVal(if (std.mem.eql(u8, sa, "OUTSIDE")) "outside" else "center"));
        try o.put(a, "stroke", try ctx.intern(.stroke, .{ .object = so }));
    };
    if (n.object.get("effects")) |e| if (try simplifyEffects(ctx, e)) |v| try o.put(a, "fx", try ctx.intern(.effect, v));

    if (n.object.get("rectangleCornerRadii")) |rr| {
        if (rr == .array and rr.array.items.len == 4) {
            var ra = newArr(a);
            for (rr.array.items) |x| try ra.append(numVal(numOf(x) orelse 0));
            try o.put(a, "radius", .{ .array = ra });
        }
    } else if (numOf(n.object.get("cornerRadius"))) |r| {
        if (r != 0) try o.put(a, "radius", numVal(r));
    }
    if (numOf(n.object.get("opacity"))) |op| if (op < 0.995) try o.put(a, "opacity", numVal(op));
    if (n.object.get("clipsContent")) |c| if (c == .bool and c.bool and std.mem.eql(u8, ty, "FRAME")) try o.put(a, "clip", .{ .bool = true });
    if (getStr(n, "componentId")) |cid| try o.put(a, "comp", strVal(cid));

    if (getStr(n, "characters")) |t| {
        try o.put(a, "text", strVal(t));
        if (n.object.get("style")) |st| if (try simplifyFont(ctx, st)) |f| try o.put(a, "font", f);
    }

    const stop = std.mem.eql(u8, ty, "VECTOR") or std.mem.eql(u8, ty, "BOOLEAN_OPERATION") or std.mem.eql(u8, ty, "STAR") or std.mem.eql(u8, ty, "REGULAR_POLYGON");
    if (!stop) if (n.object.get("children")) |ch| if (ch == .array and ch.array.items.len > 0) {
        if (depth >= ctx.max_depth) {
            ctx.depth_cut = true;
            try o.put(a, "children_omitted", .{ .integer = @intCast(ch.array.items.len) });
        } else {
            var ca = newArr(a);
            const auto = if (getStr(n, "layoutMode")) |m| !std.mem.eql(u8, m, "NONE") else false;
            for (ch.array.items) |c| {
                if (try simplifyNode(ctx, c, depth + 1, my_origin, auto)) |sc| try ca.append(sc);
            }
            if (ca.items.len > 0) try o.put(a, "children", .{ .array = ca });
        }
    };
    return .{ .object = o };
}

/// Build the compact result JSON from a parsed Figma response (either the
/// /files/{key} shape with `document`, or /files/{key}/nodes with `nodes`).
fn simplifyResponse(a: std.mem.Allocator, root: Val, max_depth: u32) ![]u8 {
    var ctx: Ctx = .{ .a = a, .max_depth = max_depth, .max_nodes = MAX_NODES };
    var roots = newArr(a);
    if (root == .object) {
        if (root.object.get("document")) |d| {
            if (try simplifyNode(&ctx, d, 0, null, false)) |s| try roots.append(s);
        }
        if (root.object.get("nodes")) |ns| if (ns == .object) {
            var it = ns.object.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.* != .object) continue;
                const d = e.value_ptr.object.get("document") orelse continue;
                if (try simplifyNode(&ctx, d, 0, null, false)) |s| try roots.append(s);
            }
        };
    }
    var out: Obj = .empty;
    if (getStr(root, "name")) |nm| try out.put(a, "name", strVal(nm));
    try out.put(a, "nodes", .{ .array = roots });
    if (ctx.styles.count() > 0) try out.put(a, "styles", .{ .object = ctx.styles });
    if (ctx.omitted > 0 or ctx.depth_cut) {
        try out.put(a, "note", strVal(try std.fmt.allocPrint(a, "output limited: {d} nodes beyond the {d}-node cap omitted{s}; re-query a subtree with nodeId for detail.", .{ ctx.omitted, MAX_NODES, if (ctx.depth_cut) ", deeper levels cut (children_omitted)" else "" })));
    }
    return try std.json.Stringify.valueAlloc(a, Val{ .object = out }, .{});
}

fn capOutput(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (s.len <= MAX_OUTPUT) return s;
    return try std.fmt.allocPrint(a, "{s}\n[truncated at {d} bytes of {d}; request a smaller nodeId or depth]", .{ s[0..MAX_OUTPUT], MAX_OUTPUT, s.len });
}

// ---------------------------------------------------------------- get_figma_data

fn handleGetData(a: std.mem.Allocator, io: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    const raw = getStr(args, "fileKey") orelse return errResult(a, "fileKey is required.", .{});
    const ref = parseFileRef(raw) orelse return errResult(a, "fileKey is not a valid Figma file key or figma.com URL.", .{});
    if (!hasToken()) return .{ .text = missing_token_msg, .is_error = true };

    const node_raw = getStr(args, "nodeId") orelse ref.node_id;
    var depth: ?u32 = null;
    if (numOf(getField(args, "depth"))) |d| {
        if (d < 1 or d > 100) return errResult(a, "depth must be between 1 and 100.", .{});
        depth = @intFromFloat(d);
    }

    var url: std.ArrayList(u8) = .empty;
    try url.print(a, "{s}/files/{s}", .{ API_BASE, ref.key });
    if (node_raw) |nr| {
        const nid = (try normalizeNodeId(a, nr)) orelse return errResult(a, "nodeId is malformed (expected like 1234:5678).", .{});
        try url.appendSlice(a, "/nodes?ids=");
        try urlEncode(a, &url, nid);
        if (depth) |d| try url.print(a, "&depth={d}", .{d});
    } else if (depth) |d| try url.print(a, "?depth={d}", .{d});

    switch (try apiGet(a, io, url.items)) {
        .fail => |f| return f,
        .ok => |root| {
            const out = try simplifyResponse(a, root, depth orelse DEFAULT_MAX_DEPTH);
            return .{ .text = try capOutput(a, out) };
        },
    }
}

// ---------------------------------------------------------------- download_figma_images

const PathError = error{ OutsideBase, BadPath, BadFileName, OutOfMemory };

fn stripTrailingSlash(s: []const u8) []const u8 {
    var e = s.len;
    while (e > 1 and s[e - 1] == '/') e -= 1;
    return s[0..e];
}

fn safeComponent(c: []const u8) bool {
    if (c.len == 0 or c.len > 100) return false;
    for (c) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.' or ch == ' ')) return false;
    }
    return true;
}

/// Lexically join base + localPath + fileName, guaranteeing the result stays
/// under `base`. localPath is relative to base; an absolute localPath must
/// itself lie inside base. `..`, backslashes, drive colons and odd chars are
/// rejected. (Symlinks inside the base are not resolved.)
fn resolveOutPath(a: std.mem.Allocator, base_in: []const u8, local_path: []const u8, file_name: []const u8) PathError![]u8 {
    const base = stripTrailingSlash(base_in);
    if (base.len == 0) return error.BadPath;
    if (std.mem.indexOfAny(u8, base, "\x00\\") != null) return error.BadPath;
    if (!validFileName(file_name)) return error.BadFileName;

    var rel = local_path;
    if (rel.len > 0 and rel[0] == '/') {
        if (base[0] != '/') return error.OutsideBase;
        if (std.mem.eql(u8, rel, base)) {
            rel = "";
        } else if (rel.len > base.len and std.mem.startsWith(u8, rel, base) and rel[base.len] == '/') {
            rel = rel[base.len + 1 ..];
        } else return error.OutsideBase;
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, base);
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |c| {
        if (c.len == 0 or std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, "..")) return error.OutsideBase;
        if (!safeComponent(c)) return error.BadPath;
        try out.append(a, '/');
        try out.appendSlice(a, c);
    }
    try out.append(a, '/');
    try out.appendSlice(a, file_name);
    return try out.toOwnedSlice(a);
}

const ImgKind = enum { png, svg, gif };

fn fileKind(name: []const u8) ?ImgKind {
    if (std.ascii.endsWithIgnoreCase(name, ".png")) return .png;
    if (std.ascii.endsWithIgnoreCase(name, ".svg")) return .svg;
    if (std.ascii.endsWithIgnoreCase(name, ".gif")) return .gif;
    return null;
}

fn validFileName(n: []const u8) bool {
    if (n.len == 0 or n.len > 100 or n[0] == '.') return false;
    for (n) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.')) return false;
    if (std.mem.indexOf(u8, n, "..") != null) return false;
    return fileKind(n) != null;
}

const NodeSpec = struct {
    node_id: []const u8,
    image_ref: ?[]const u8,
    file_name: []const u8,
    kind: ImgKind,
    path: []const u8,
    url: ?[]const u8 = null,
};

fn validRef(s: []const u8) bool {
    if (s.len == 0 or s.len > 128) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    return true;
}

fn handleDownload(a: std.mem.Allocator, io: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    const raw = getStr(args, "fileKey") orelse return errResult(a, "fileKey is required.", .{});
    const ref = parseFileRef(raw) orelse return errResult(a, "fileKey is not a valid Figma file key or figma.com URL.", .{});
    const local = getStr(args, "localPath") orelse return errResult(a, "localPath is required.", .{});
    const nodes_v = getField(args, "nodes") orelse return errResult(a, "nodes is required.", .{});
    if (nodes_v != .array or nodes_v.array.items.len == 0) return errResult(a, "nodes must be a non-empty array.", .{});
    if (nodes_v.array.items.len > MAX_IMAGES) return errResult(a, "too many nodes (max {d}).", .{MAX_IMAGES});
    var scale: f64 = 2;
    if (numOf(getField(args, "pngScale"))) |s| {
        if (!(s >= 0.01 and s <= 4)) return errResult(a, "pngScale must be between 0.01 and 4.", .{});
        scale = s;
    }

    var specs: std.ArrayList(NodeSpec) = .empty;
    for (nodes_v.array.items, 0..) |nv, i| {
        const nid_raw = getStr(nv, "nodeId") orelse return errResult(a, "nodes[{d}].nodeId is required.", .{i});
        const fname = getStr(nv, "fileName") orelse return errResult(a, "nodes[{d}].fileName is required.", .{i});
        const nid = (try normalizeNodeId(a, nid_raw)) orelse return errResult(a, "nodes[{d}].nodeId is malformed.", .{i});
        const path = resolveOutPath(a, out_dir, local, fname) catch |e| return switch (e) {
            error.OutsideBase => errResult(a, "localPath must stay inside the output directory ({s}); no '..' or outside absolute paths.", .{out_dir}),
            error.BadFileName => errResult(a, "nodes[{d}].fileName invalid: use [A-Za-z0-9_.-] ending in .png, .svg or .gif.", .{i}),
            else => errResult(a, "localPath contains unsupported characters.", .{}),
        };
        var iref: ?[]const u8 = getStr(nv, "gifRef") orelse getStr(nv, "imageRef");
        if (iref != null and iref.?.len == 0) iref = null;
        if (iref) |r| if (!validRef(r)) return errResult(a, "nodes[{d}] imageRef/gifRef is malformed.", .{i});
        try specs.append(a, .{ .node_id = nid, .image_ref = iref, .file_name = fname, .kind = fileKind(fname).?, .path = path });
    }
    if (!hasToken()) return .{ .text = missing_token_msg, .is_error = true };

    // 1) image fills
    var any_fill = false;
    for (specs.items) |s| {
        if (s.image_ref != null) any_fill = true;
    }
    if (any_fill) {
        const url = try std.fmt.allocPrint(a, "{s}/files/{s}/images", .{ API_BASE, ref.key });
        switch (try apiGet(a, io, url)) {
            .fail => |f| return f,
            .ok => |root| {
                const imgs: ?Val = blk: {
                    const meta = getField(root, "meta") orelse break :blk null;
                    const im = getField(meta, "images") orelse break :blk null;
                    break :blk if (im == .object) im else null;
                };
                if (imgs) |im| for (specs.items) |*s| {
                    if (s.image_ref) |rf| {
                        if (getStr(im, rf)) |u| s.url = u;
                    }
                };
            },
        }
    }

    // 2) rendered nodes, one request per format
    for ([_]ImgKind{ .png, .svg }) |k| {
        var ids: std.ArrayList(u8) = .empty;
        var count: usize = 0;
        for (specs.items) |s| {
            if (s.image_ref == null and s.kind == k) {
                if (count > 0) try ids.append(a, ',');
                try urlEncode(a, &ids, s.node_id);
                count += 1;
            }
        }
        // a gif without a ref cannot be rendered; it reports "no image URL".
        if (count == 0) continue;
        var url: std.ArrayList(u8) = .empty;
        try url.print(a, "{s}/images/{s}?ids={s}", .{ API_BASE, ref.key, ids.items });
        if (k == .png) {
            try url.print(a, "&format=png&scale={d}", .{scale});
        } else {
            try url.appendSlice(a, "&format=svg&svg_outline_text=true&svg_include_id=false&svg_simplify_stroke=true");
        }
        switch (try apiGet(a, io, url.items)) {
            .fail => |f| return f,
            .ok => |root| {
                if (getField(root, "images")) |m| if (m == .object) for (specs.items) |*s| {
                    if (s.image_ref != null or s.kind != k) continue;
                    if (getStr(m, s.node_id)) |u| s.url = u;
                };
            },
        }
    }

    // 3) download + save
    var out: std.ArrayList(u8) = .empty;
    var ok_n: usize = 0;
    for (specs.items) |s| {
        const u = s.url orelse {
            try out.print(a, "FAIL {s}: no image URL from Figma (node not renderable or unknown ref)\n", .{s.file_name});
            continue;
        };
        if (!std.mem.startsWith(u8, u, "https://")) {
            try out.print(a, "FAIL {s}: refusing non-https image URL\n", .{s.file_name});
            continue;
        }
        const resp = fetch_impl(a, io, .{ .url = u, .auth = false, .max_bytes = MAX_IMAGE_BYTES }) catch |e| {
            try out.print(a, "FAIL {s}: download error {s}\n", .{ s.file_name, @errorName(e) });
            continue;
        };
        if (resp.status < 200 or resp.status >= 300) {
            try out.print(a, "FAIL {s}: download HTTP {d}\n", .{ s.file_name, resp.status });
            continue;
        }
        if (resp.body.len > MAX_IMAGE_BYTES) {
            try out.print(a, "FAIL {s}: larger than {d} bytes\n", .{ s.file_name, MAX_IMAGE_BYTES });
            continue;
        }
        write_impl(io, s.path, resp.body) catch |e| {
            try out.print(a, "FAIL {s}: write error {s}\n", .{ s.file_name, @errorName(e) });
            continue;
        };
        ok_n += 1;
        try out.print(a, "saved {s} ({d} bytes)\n", .{ s.path, resp.body.len });
    }
    try out.print(a, "{d}/{d} saved", .{ ok_n, specs.items.len });
    return .{ .text = out.items, .is_error = ok_n == 0 };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

test "parseFileRef: bare key, urls, branch, node-id" {
    try testing.expectEqualStrings("AbC123", parseFileRef("AbC123").?.key);
    const r = parseFileRef("https://www.figma.com/design/AbC123/My-File?node-id=12-34&t=x").?;
    try testing.expectEqualStrings("AbC123", r.key);
    try testing.expectEqualStrings("12-34", r.node_id.?);
    try testing.expectEqualStrings("K1", parseFileRef("https://figma.com/file/K1/x").?.key);
    try testing.expectEqualStrings("BR9", parseFileRef("https://www.figma.com/design/MAIN/branch/BR9/Name").?.key);
    try testing.expect(parseFileRef("https://evil.com/design/AbC/x") == null);
    try testing.expect(parseFileRef("https://figma.com.evil.com/design/AbC/x") == null);
    try testing.expect(parseFileRef("../etc") == null);
    try testing.expect(parseFileRef("") == null);
    try testing.expect(parseFileRef("a/b") == null);
}

test "normalizeNodeId" {
    const a = testing.allocator;
    const n1 = (try normalizeNodeId(a, "12-34")).?;
    defer a.free(n1);
    try testing.expectEqualStrings("12:34", n1);
    const n2 = (try normalizeNodeId(a, "I5:1;1:2")).?;
    defer a.free(n2);
    try testing.expectEqualStrings("I5:1;1:2", n2);
    const n3 = (try normalizeNodeId(a, "1%3A2")).?;
    defer a.free(n3);
    try testing.expectEqualStrings("1:2", n3);
    try testing.expect((try normalizeNodeId(a, "1:2&x=y")) == null);
    try testing.expect((try normalizeNodeId(a, "")) == null);
    try testing.expect((try normalizeNodeId(a, "1%")) == null);
}

test "statusMessage maps 403/404/429" {
    try testing.expect(statusMessage(200) == null);
    try testing.expect(std.mem.indexOf(u8, statusMessage(403).?, "403") != null);
    try testing.expect(std.mem.indexOf(u8, statusMessage(404).?, "not found") != null);
    try testing.expect(std.mem.indexOf(u8, statusMessage(429).?, "rate limited") != null);
    try testing.expect(std.mem.indexOf(u8, statusMessage(502).?, "server error") != null);
}

test "resolveOutPath: safe joins and rejections" {
    const a = testing.allocator;
    const p1 = try resolveOutPath(a, "./figma-assets", "icons/nav", "a.svg");
    defer a.free(p1);
    try testing.expectEqualStrings("./figma-assets/icons/nav/a.svg", p1);
    const p2 = try resolveOutPath(a, "/tmp/out/", "/tmp/out/x", "a.png");
    defer a.free(p2);
    try testing.expectEqualStrings("/tmp/out/x/a.png", p2);
    const p3 = try resolveOutPath(a, "/tmp/out", "", "a.png");
    defer a.free(p3);
    try testing.expectEqualStrings("/tmp/out/a.png", p3);

    try testing.expectError(error.OutsideBase, resolveOutPath(a, "/tmp/out", "../x", "a.png"));
    try testing.expectError(error.OutsideBase, resolveOutPath(a, "/tmp/out", "a/../../x", "a.png"));
    try testing.expectError(error.OutsideBase, resolveOutPath(a, "/tmp/out", "/etc", "a.png"));
    try testing.expectError(error.OutsideBase, resolveOutPath(a, "/tmp/out", "/tmp/outside", "a.png"));
    try testing.expectError(error.OutsideBase, resolveOutPath(a, "./figma-assets", "/abs", "a.png"));
    try testing.expectError(error.BadPath, resolveOutPath(a, "/tmp/out", "a\\b", "a.png"));
    try testing.expectError(error.BadPath, resolveOutPath(a, "/tmp/out", "C:x", "a.png"));
    try testing.expectError(error.BadFileName, resolveOutPath(a, "/tmp/out", "", "../a.png"));
    try testing.expectError(error.BadFileName, resolveOutPath(a, "/tmp/out", "", "a/b.png"));
    try testing.expectError(error.BadFileName, resolveOutPath(a, "/tmp/out", "", "a.exe"));
    try testing.expectError(error.BadFileName, resolveOutPath(a, "/tmp/out", "", ".png"));
}

// Verbose Figma-style card; "@@" is replaced by the card index.
const card_tmpl =
    \\{"id":"1:@@","name":"Card @@","type":"FRAME","scrollBehavior":"SCROLLS","blendMode":"PASS_THROUGH",
    \\"absoluteBoundingBox":{"x":@@.5,"y":100,"width":200,"height":120},
    \\"absoluteRenderBounds":{"x":0,"y":0,"width":200,"height":120},
    \\"constraints":{"vertical":"TOP","horizontal":"LEFT"},"clipsContent":true,
    \\"layoutMode":"VERTICAL","itemSpacing":8,"paddingLeft":16,"paddingRight":16,"paddingTop":12,"paddingBottom":12,
    \\"primaryAxisAlignItems":"MIN","counterAxisAlignItems":"CENTER","layoutSizingHorizontal":"FIXED","layoutSizingVertical":"HUG",
    \\"cornerRadius":8,"cornerSmoothing":0,"strokeWeight":1,"strokeAlign":"INSIDE","strokeJoin":"MITER","strokeCap":"NONE",
    \\"fills":[{"blendMode":"NORMAL","type":"SOLID","color":{"r":0.9803921568627451,"g":0.9803921568627451,"b":0.9803921568627451,"a":1}}],
    \\"strokes":[{"blendMode":"NORMAL","type":"SOLID","color":{"r":0.8,"g":0.8,"b":0.8,"a":1}}],
    \\"effects":[{"type":"DROP_SHADOW","visible":true,"blendMode":"NORMAL","color":{"r":0,"g":0,"b":0,"a":0.25},"offset":{"x":0,"y":4},"radius":8,"spread":0,"showShadowBehindNode":false}],
    \\"children":[
    \\{"id":"2:@@","name":"Title","type":"TEXT","characters":"Hello @@","blendMode":"PASS_THROUGH",
    \\"absoluteBoundingBox":{"x":10,"y":110,"width":100,"height":24},"absoluteRenderBounds":{"x":10,"y":110,"width":90,"height":20},
    \\"fills":[{"blendMode":"NORMAL","type":"SOLID","color":{"r":0.1,"g":0.1,"b":0.1,"a":1}}],
    \\"style":{"fontFamily":"Inter","fontPostScriptName":"Inter-Bold","fontStyle":"Bold","fontWeight":700,"textAutoResize":"WIDTH_AND_HEIGHT","fontSize":16,"textAlignHorizontal":"LEFT","textAlignVertical":"TOP","letterSpacing":0,"lineHeightPx":24,"lineHeightPercent":100,"lineHeightUnit":"INTRINSIC_%"},
    \\"characterStyleOverrides":[],"styleOverrideTable":{},"lineTypes":["NONE"],"lineIndentations":[0]},
    \\{"id":"3:@@","name":"hidden","type":"RECTANGLE","visible":false}
    \\]}
;

fn buildFixture(a: std.mem.Allocator, count: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "{\"name\":\"Demo\",\"document\":{\"id\":\"0:0\",\"name\":\"Doc\",\"type\":\"DOCUMENT\",\"children\":[{\"id\":\"0:1\",\"name\":\"Page\",\"type\":\"CANVAS\",\"children\":[");
    for (0..count) |i| {
        if (i > 0) try out.append(a, ',');
        var it = std.mem.splitSequence(u8, card_tmpl, "@@");
        var first = true;
        while (it.next()) |part| {
            if (!first) try out.print(a, "{d}", .{i});
            first = false;
            try out.appendSlice(a, part);
        }
    }
    try out.appendSlice(a, "]}]},\"components\":{},\"schemaVersion\":0}");
    return out.toOwnedSlice(a);
}

test "simplifier shrinks output and dedupes styles" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = try buildFixture(a, 20);
    const root = try std.json.parseFromSliceLeaky(Val, a, raw, .{});
    const out = try simplifyResponse(a, root, 12);
    try testing.expect(out.len * 4 < raw.len);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\"layout_1\":{"));
    try testing.expectEqual(@as(usize, 20), std.mem.count(u8, out, "\"layout\":\"layout_1\""));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\"font_1\":{"));
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, "layout_2"));
    try testing.expect(std.mem.indexOf(u8, out, "hidden") == null);
    try testing.expect(std.mem.indexOf(u8, out, "absoluteRenderBounds") == null);
    try testing.expect(std.mem.indexOf(u8, out, "#fafafa") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Hello 7") != null);
    _ = try std.json.parseFromSliceLeaky(Val, a, out, .{});
}

test "simplifier depth cap and node cap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = try buildFixture(a, 3);
    const root = try std.json.parseFromSliceLeaky(Val, a, raw, .{});
    const out = try simplifyResponse(a, root, 2);
    try testing.expect(std.mem.indexOf(u8, out, "children_omitted") != null);
    try testing.expect(std.mem.indexOf(u8, out, "deeper levels cut") != null);
    var ctx: Ctx = .{ .a = a, .max_depth = 12, .max_nodes = 3 };
    _ = try simplifyNode(&ctx, root.object.get("document").?, 0, null, false);
    try testing.expectEqual(@as(u32, 3), ctx.emitted);
    try testing.expect(ctx.omitted > 0);
}

test "colors and gradients" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try std.json.parseFromSliceLeaky(Val, a, "{\"type\":\"SOLID\",\"opacity\":0.5,\"color\":{\"r\":1,\"g\":0,\"b\":0,\"a\":1}}", .{});
    const v = (try simplifyPaint(a, p)).?;
    try testing.expectEqualStrings("rgba(255,0,0,0.5)", v.string);
    const g = try std.json.parseFromSliceLeaky(Val, a, "{\"type\":\"GRADIENT_LINEAR\",\"gradientStops\":[{\"position\":0,\"color\":{\"r\":0,\"g\":0,\"b\":0,\"a\":1}},{\"position\":1,\"color\":{\"r\":1,\"g\":1,\"b\":1,\"a\":1}}]}", .{});
    const gv = (try simplifyPaint(a, g)).?;
    try testing.expectEqualStrings("#000000 0", gv.object.get("stops").?.array.items[0].string);
}

const Fake = struct {
    var urls: std.ArrayList([]const u8) = .empty;
    var auth_flags: std.ArrayList(bool) = .empty;
    var status: u16 = 200;
    var written: std.ArrayList([]const u8) = .empty;
    var tree_json: []const u8 = "{}";

    fn reset() void {
        urls = .empty;
        auth_flags = .empty;
        written = .empty;
        status = 200;
        api_key = "sekret123";
        oauth_token = null;
        out_dir = "./figma-assets";
        fetch_impl = fetch;
        write_impl = write;
    }
    fn fetch(alloc: std.mem.Allocator, _: std.Io, req: Req) anyerror!HttpResp {
        try urls.append(alloc, try alloc.dupe(u8, req.url));
        try auth_flags.append(alloc, req.auth);
        const body: []const u8 = if (std.mem.indexOf(u8, req.url, "cdn.example/") != null)
            "IMGDATA"
        else if (std.mem.indexOf(u8, req.url, "/files/K/images") != null)
            "{\"meta\":{\"images\":{\"refabc\":\"https://cdn.example/fill.png\"}}}"
        else if (std.mem.indexOf(u8, req.url, "/images/K") != null)
            "{\"images\":{\"1:2\":\"https://cdn.example/n.svg\",\"3:4\":null}}"
        else
            tree_json;
        return .{ .status = status, .body = try alloc.dupe(u8, body) };
    }
    fn write(_: std.Io, path: []const u8, _: []const u8) anyerror!void {
        const s = try std.heap.page_allocator.dupe(u8, path);
        try written.append(std.heap.page_allocator, s);
    }
};

fn callJson(comptime h: mcp.ToolHandler, a: std.mem.Allocator, json: []const u8) !mcp.ToolResult {
    const v = try std.json.parseFromSliceLeaky(Val, a, json, .{});
    return h(a, testIo(), v);
}

test "get_figma_data: url, headers, node request, error mapping, missing token" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    Fake.reset();
    Fake.tree_json = "{\"name\":\"F\",\"nodes\":{\"1:2\":{\"document\":{\"id\":\"1:2\",\"name\":\"N\",\"type\":\"FRAME\"}}}}";
    const r = try callJson(handleGetData, a, "{\"fileKey\":\"https://www.figma.com/design/K/x?node-id=1-2\",\"depth\":3}");
    try testing.expect(!r.is_error);
    try testing.expectEqualStrings("https://api.figma.com/v1/files/K/nodes?ids=1%3A2&depth=3", Fake.urls.items[0]);
    try testing.expect(Fake.auth_flags.items[0]);
    try testing.expect(std.mem.indexOf(u8, r.text, "\"name\":\"N\"") != null);

    Fake.reset();
    Fake.tree_json = "{\"name\":\"F\",\"document\":{\"id\":\"0:0\",\"type\":\"DOCUMENT\"}}";
    const r2 = try callJson(handleGetData, a, "{\"fileKey\":\"K\"}");
    try testing.expect(!r2.is_error);
    try testing.expectEqualStrings("https://api.figma.com/v1/files/K", Fake.urls.items[0]);

    for ([_]u16{ 403, 404, 429 }) |st| {
        Fake.reset();
        Fake.status = st;
        const e = try callJson(handleGetData, a, "{\"fileKey\":\"K\"}");
        try testing.expect(e.is_error);
        try testing.expect(std.mem.indexOf(u8, e.text, "sekret123") == null);
    }
    Fake.reset();
    Fake.status = 404;
    const e404 = try callJson(handleGetData, a, "{\"fileKey\":\"K\"}");
    try testing.expect(std.mem.indexOf(u8, e404.text, "not found") != null);

    Fake.reset();
    api_key = null;
    const m = try callJson(handleGetData, a, "{\"fileKey\":\"K\"}");
    try testing.expect(m.is_error);
    try testing.expect(std.mem.indexOf(u8, m.text, "FIGMA_API_KEY") != null);
    try testing.expectEqual(@as(usize, 0), Fake.urls.items.len);

    Fake.reset();
    const bad = try callJson(handleGetData, a, "{\"fileKey\":\"https://evil.com/design/K/x\"}");
    try testing.expect(bad.is_error);
    const badn = try callJson(handleGetData, a, "{\"fileKey\":\"K\",\"nodeId\":\"1:2/../x\"}");
    try testing.expect(badn.is_error);
}

test "output cap adds truncation note" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const big = try a.alloc(u8, MAX_OUTPUT + 500);
    @memset(big, 'x');
    const capped = try capOutput(a, big);
    try testing.expect(capped.len < MAX_OUTPUT + 200);
    try testing.expect(std.mem.indexOf(u8, capped, "[truncated") != null);
}

test "download_figma_images: flow, urls, writes, path safety" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    Fake.reset();
    const r = try callJson(handleDownload, a,
        \\{"fileKey":"K","localPath":"icons","pngScale":3,"nodes":[
        \\{"nodeId":"1:2","fileName":"a.svg"},
        \\{"nodeId":"3:4","fileName":"b.svg"},
        \\{"nodeId":"5:6","imageRef":"refabc","fileName":"c.png"}]}
    );
    try testing.expect(!r.is_error);
    // fill c.png and svg a.svg saved; b.svg has null URL
    try testing.expectEqual(@as(usize, 2), Fake.written.items.len);
    try testing.expectEqualStrings("./figma-assets/icons/a.svg", Fake.written.items[0]);
    try testing.expectEqualStrings("./figma-assets/icons/c.png", Fake.written.items[1]);
    try testing.expect(std.mem.indexOf(u8, r.text, "FAIL b.svg") != null);
    try testing.expect(std.mem.indexOf(u8, r.text, "2/3 saved") != null);
    try testing.expectEqualStrings("https://api.figma.com/v1/files/K/images", Fake.urls.items[0]);
    try testing.expectEqualStrings("https://api.figma.com/v1/images/K?ids=1%3A2,3%3A4&format=svg&svg_outline_text=true&svg_include_id=false&svg_simplify_stroke=true", Fake.urls.items[1]);
    for (Fake.urls.items, Fake.auth_flags.items) |u, af| {
        if (std.mem.indexOf(u8, u, "cdn.example") != null) try testing.expect(!af);
    }

    Fake.reset();
    const t = try callJson(handleDownload, a, "{\"fileKey\":\"K\",\"localPath\":\"../../etc\",\"nodes\":[{\"nodeId\":\"1:2\",\"fileName\":\"a.png\"}]}");
    try testing.expect(t.is_error);
    try testing.expect(std.mem.indexOf(u8, t.text, "inside the output directory") != null);
    try testing.expectEqual(@as(usize, 0), Fake.urls.items.len);
    const t2 = try callJson(handleDownload, a, "{\"fileKey\":\"K\",\"localPath\":\"x\",\"nodes\":[{\"nodeId\":\"1:2\",\"fileName\":\"../a.png\"}]}");
    try testing.expect(t2.is_error);
    const t3 = try callJson(handleDownload, a, "{\"fileKey\":\"K\",\"localPath\":\"/etc\",\"nodes\":[{\"nodeId\":\"1:2\",\"fileName\":\"a.png\"}]}");
    try testing.expect(t3.is_error);
    try testing.expectEqual(@as(usize, 0), Fake.written.items.len);
}

test "download_figma_images: caps, auth error, missing token" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    Fake.reset();
    var js: std.ArrayList(u8) = .empty;
    try js.appendSlice(a, "{\"fileKey\":\"K\",\"localPath\":\"\",\"nodes\":[");
    for (0..MAX_IMAGES + 1) |i| {
        if (i > 0) try js.append(a, ',');
        try js.print(a, "{{\"nodeId\":\"1:{d}\",\"fileName\":\"f{d}.png\"}}", .{ i, i });
    }
    try js.appendSlice(a, "]}");
    const r = try callJson(handleDownload, a, js.items);
    try testing.expect(r.is_error);
    try testing.expect(std.mem.indexOf(u8, r.text, "too many") != null);

    const s = try callJson(handleDownload, a, "{\"fileKey\":\"K\",\"localPath\":\"\",\"pngScale\":99,\"nodes\":[{\"nodeId\":\"1:2\",\"fileName\":\"a.png\"}]}");
    try testing.expect(s.is_error);

    Fake.reset();
    Fake.status = 403;
    const f = try callJson(handleDownload, a, "{\"fileKey\":\"K\",\"localPath\":\"\",\"nodes\":[{\"nodeId\":\"1:2\",\"fileName\":\"a.png\"}]}");
    try testing.expect(f.is_error);
    try testing.expect(std.mem.indexOf(u8, f.text, "403") != null);

    Fake.reset();
    api_key = null;
    const m = try callJson(handleDownload, a, "{\"fileKey\":\"K\",\"localPath\":\"\",\"nodes\":[{\"nodeId\":\"1:2\",\"fileName\":\"a.png\"}]}");
    try testing.expect(m.is_error);
    try testing.expect(std.mem.indexOf(u8, m.text, "FIGMA_API_KEY") != null);
}
