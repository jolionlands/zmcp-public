//! zmcp-currency — drop-in replacement for the Node `currency` extension.
//! Keyless FX via Frankfurter (api.frankfurter.dev, ECB-backed).
//!
//! Tools:
//!   fx_convert(amount, from, to, date?)
//!   fx_rate(base?, symbols?)
//!   fx_currencies()
//!   fx_timeseries(start, end, base?, symbols?)

const std = @import("std");
const mcp = @import("mcp");

const UA_PRODUCT = "zmcp-currency/0.1.0";
const BASE_URL = "https://api.frankfurter.dev/v1";

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    const io = init.io;
    try mcp.run(arena, io, .{ .name = "zmcp-currency", .version = "0.1.0" }, &tool_table);
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "fx_convert",
        .description = "Convert an amount from one currency to another using ECB reference rates via Frankfurter. Optional `date` (YYYY-MM-DD) for historical conversion; default is the latest available rate (T-1 business day).",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "amount": { "type": "number", "description": "Amount in source currency." },
        \\    "from":   { "type": "string", "description": "ISO 4217 code (USD, EUR, AUD, ...)." },
        \\    "to":     { "type": "string", "description": "ISO 4217 code." },
        \\    "date":   { "type": "string", "description": "Optional YYYY-MM-DD for historical rate." }
        \\  },
        \\  "required": ["amount", "from", "to"]
        \\}
        ,
        .handler = handleConvert,
        .read_only = true,
    },
    .{
        .name = "fx_rate",
        .description = "Get the latest rate of a base currency against one or many target currencies.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "base":    { "type": "string", "description": "Base ISO code, default EUR." },
        \\    "symbols": { "type": "string", "description": "Comma-separated target codes, e.g. 'USD,AUD,JPY'. Omit for all." }
        \\  }
        \\}
        ,
        .handler = handleRate,
        .read_only = true,
    },
    .{
        .name = "fx_currencies",
        .description = "List supported ISO 4217 currency codes with their long names.",
        .input_schema_json =
        \\{ "type": "object", "properties": {} }
        ,
        .handler = handleCurrencies,
        .read_only = true,
    },
    .{
        .name = "fx_timeseries",
        .description = "Daily rates between two dates (max ~1y). Useful for charting or detecting big moves.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "start":   { "type": "string", "description": "YYYY-MM-DD start date." },
        \\    "end":     { "type": "string", "description": "YYYY-MM-DD end date." },
        \\    "base":    { "type": "string", "description": "Base ISO code, default EUR." },
        \\    "symbols": { "type": "string", "description": "Comma-separated target codes; omit for all." }
        \\  },
        \\  "required": ["start", "end"]
        \\}
        ,
        .handler = handleTimeseries,
        .read_only = true,
    },
};

// ---------------------------------------------------------------------------
// HTTPS helper
// ---------------------------------------------------------------------------

const HttpResp = struct {
    status: u16,
    body: []u8,
};

fn httpsGet(alloc: std.mem.Allocator, io: std.Io, url: []const u8) !HttpResp {
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();
    const ua_owned = try mcp.userAgent(alloc, io, UA_PRODUCT);
    defer alloc.free(ua_owned);

    var resp_buf: std.Io.Writer.Allocating = .init(alloc);
    defer resp_buf.deinit();

    var decompress_buf: [64 * 1024]u8 = undefined;

    const fetch_res = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &resp_buf.writer,
        .method = .GET,
        .extra_headers = &.{
            .{ .name = "User-Agent", .value = ua_owned },
            .{ .name = "Accept", .value = "application/json" },
        },
        .decompress_buffer = &decompress_buf,
    });

    return .{
        .status = @intFromEnum(fetch_res.status),
        .body = try alloc.dupe(u8, resp_buf.written()),
    };
}

// ---------------------------------------------------------------------------
// Arg helpers
// ---------------------------------------------------------------------------

fn getStr(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn getNum(args: std.json.Value, key: []const u8) ?f64 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

fn isAlphaUpper3(s: []const u8) bool {
    if (s.len != 3) return false;
    for (s) |c| if (!(c >= 'A' and c <= 'Z')) return false;
    return true;
}

fn isValidIsoCode(s: []const u8) bool {
    // Accept 3-letter codes (case-insensitive); we don't enforce ISO list here.
    if (s.len != 3) return false;
    for (s) |c| if (!std.ascii.isAlphabetic(c)) return false;
    return true;
}

fn isValidDate(s: []const u8) bool {
    // YYYY-MM-DD shape check only.
    if (s.len != 10) return false;
    if (s[4] != '-' or s[7] != '-') return false;
    for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9 }) |i| {
        if (!std.ascii.isDigit(s[i])) return false;
    }
    return true;
}

fn isValidSymbols(s: []const u8) bool {
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        if (!isValidIsoCode(part)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Pretty-print parsed JSON.
// ---------------------------------------------------------------------------

fn prettyPrint(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch {
        return alloc.dupe(u8, raw);
    };
    defer parsed.deinit();
    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    try std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, &sw.writer);
    return alloc.dupe(u8, sw.written());
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

fn handleConvert(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const amount = getNum(args, "amount") orelse return .{ .text = "error: amount must be a number", .is_error = true };
    const from = getStr(args, "from") orelse return .{ .text = "error: from required", .is_error = true };
    const to = getStr(args, "to") orelse return .{ .text = "error: to required", .is_error = true };
    if (!isValidIsoCode(from)) return .{ .text = "error: from must be a 3-letter ISO code", .is_error = true };
    if (!isValidIsoCode(to)) return .{ .text = "error: to must be a 3-letter ISO code", .is_error = true };

    const date_str: []const u8 = if (getStr(args, "date")) |d| blk: {
        if (!isValidDate(d)) return .{ .text = "error: date must be YYYY-MM-DD", .is_error = true };
        break :blk d;
    } else "latest";

    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "{s}/{s}?base={s}&symbols={s}", .{ BASE_URL, date_str, from, to });

    const resp = httpsGet(alloc, io, url) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "fx_convert failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    if (resp.status != 200) {
        const snip_len = @min(resp.body.len, 200);
        return .{
            .text = try std.fmt.allocPrint(alloc, "frankfurter http {d}: {s}", .{ resp.status, resp.body[0..snip_len] }),
            .is_error = true,
        };
    }

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{}) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "json parse: {s}", .{@errorName(err)}), .is_error = true };
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return .{ .text = "error: unexpected response", .is_error = true };

    const rates = root.object.get("rates") orelse return .{ .text = "error: no rates in response", .is_error = true };
    if (rates != .object) return .{ .text = "error: rates not an object", .is_error = true };
    const rate_v = rates.object.get(to) orelse return .{ .text = "error: target rate missing", .is_error = true };
    const rate: f64 = switch (rate_v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => return .{ .text = "error: rate not numeric", .is_error = true },
    };

    const converted = amount * rate;
    const ret_date_v = root.object.get("date") orelse .null;
    const ret_date: []const u8 = if (ret_date_v == .string) ret_date_v.string else "";

    return .{
        .text = try std.fmt.allocPrint(
            alloc,
            "{{\n  \"amount\": {d},\n  \"from\": \"{s}\",\n  \"to\": \"{s}\",\n  \"rate\": {d},\n  \"converted\": {d:.6},\n  \"date\": \"{s}\",\n  \"source\": \"frankfurter (ECB)\"\n}}",
            .{ amount, from, to, rate, converted, ret_date },
        ),
    };
}

fn handleRate(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const base = getStr(args, "base") orelse "EUR";
    if (!isValidIsoCode(base)) return .{ .text = "error: base must be a 3-letter ISO code", .is_error = true };
    const symbols = getStr(args, "symbols");
    if (symbols) |s| {
        if (!isValidSymbols(s)) return .{ .text = "error: symbols must be comma-separated 3-letter ISO codes", .is_error = true };
    }

    var url_buf: [256]u8 = undefined;
    const url = if (symbols) |s|
        try std.fmt.bufPrint(&url_buf, "{s}/latest?base={s}&symbols={s}", .{ BASE_URL, base, s })
    else
        try std.fmt.bufPrint(&url_buf, "{s}/latest?base={s}", .{ BASE_URL, base });

    const resp = httpsGet(alloc, io, url) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "fx_rate failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    if (resp.status != 200) {
        const snip_len = @min(resp.body.len, 200);
        return .{
            .text = try std.fmt.allocPrint(alloc, "frankfurter http {d}: {s}", .{ resp.status, resp.body[0..snip_len] }),
            .is_error = true,
        };
    }

    return .{ .text = try prettyPrint(alloc, resp.body) };
}

fn handleCurrencies(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    _ = args;
    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "{s}/currencies", .{BASE_URL});

    const resp = httpsGet(alloc, io, url) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "fx_currencies failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    if (resp.status != 200) {
        return .{
            .text = try std.fmt.allocPrint(alloc, "frankfurter http {d}", .{resp.status}),
            .is_error = true,
        };
    }
    return .{ .text = try prettyPrint(alloc, resp.body) };
}

fn handleTimeseries(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const start = getStr(args, "start") orelse return .{ .text = "error: start required (YYYY-MM-DD)", .is_error = true };
    const end = getStr(args, "end") orelse return .{ .text = "error: end required (YYYY-MM-DD)", .is_error = true };
    if (!isValidDate(start)) return .{ .text = "error: start must be YYYY-MM-DD", .is_error = true };
    if (!isValidDate(end)) return .{ .text = "error: end must be YYYY-MM-DD", .is_error = true };
    const base = getStr(args, "base") orelse "EUR";
    if (!isValidIsoCode(base)) return .{ .text = "error: base must be a 3-letter ISO code", .is_error = true };
    const symbols = getStr(args, "symbols");
    if (symbols) |s| {
        if (!isValidSymbols(s)) return .{ .text = "error: symbols must be comma-separated 3-letter ISO codes", .is_error = true };
    }

    var url_buf: [256]u8 = undefined;
    const url = if (symbols) |s|
        try std.fmt.bufPrint(&url_buf, "{s}/{s}..{s}?base={s}&symbols={s}", .{ BASE_URL, start, end, base, s })
    else
        try std.fmt.bufPrint(&url_buf, "{s}/{s}..{s}?base={s}", .{ BASE_URL, start, end, base });

    const resp = httpsGet(alloc, io, url) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "fx_timeseries failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    if (resp.status != 200) {
        const snip_len = @min(resp.body.len, 200);
        return .{
            .text = try std.fmt.allocPrint(alloc, "frankfurter http {d}: {s}", .{ resp.status, resp.body[0..snip_len] }),
            .is_error = true,
        };
    }
    return .{ .text = try prettyPrint(alloc, resp.body) };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "isValidIsoCode" {
    try std.testing.expect(isValidIsoCode("USD"));
    try std.testing.expect(isValidIsoCode("eur"));
    try std.testing.expect(!isValidIsoCode("US"));
    try std.testing.expect(!isValidIsoCode("USDD"));
    try std.testing.expect(!isValidIsoCode("U5D"));
}

test "isValidDate" {
    try std.testing.expect(isValidDate("2024-01-01"));
    try std.testing.expect(isValidDate("1999-12-31"));
    try std.testing.expect(!isValidDate("2024/01/01"));
    try std.testing.expect(!isValidDate("24-01-01"));
    try std.testing.expect(!isValidDate("2024-1-1"));
}

test "isValidSymbols" {
    try std.testing.expect(isValidSymbols("USD"));
    try std.testing.expect(isValidSymbols("USD,EUR,AUD"));
    try std.testing.expect(!isValidSymbols("USD,USDD"));
    try std.testing.expect(!isValidSymbols(""));
}

test "prettyPrint indents JSON" {
    const alloc = std.testing.allocator;
    const out = try prettyPrint(alloc, "{\"a\":1,\"b\":2}");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\n") != null);
}
