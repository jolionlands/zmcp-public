//! Shared helpers for zmcp-zutil: error reporting, argument access, number and
//! date formatting. Pure; no I/O.

const std = @import("std");

pub const Fail = error{Fail};
pub const Err = error{ Fail, OutOfMemory, WriteFailed };
pub const Out = std.Io.Writer.Allocating;

threadlocal var err_buf: [768]u8 = undefined;
threadlocal var err_len: usize = 0;

/// Record a user-facing error message and return error.Fail.
pub fn fail(comptime fmt: []const u8, args: anytype) error{Fail} {
    const s = std.fmt.bufPrint(&err_buf, fmt, args) catch err_buf[0..err_buf.len];
    err_len = s.len;
    return error.Fail;
}

pub fn lastError() []const u8 {
    return err_buf[0..err_len];
}

// ---------------------------------------------------------------- arguments

pub fn obj(args: std.json.Value) Fail!std.json.ObjectMap {
    return switch (args) {
        .object => |o| o,
        else => fail("arguments must be a JSON object", .{}),
    };
}

pub fn optStr(args: std.json.Value, key: []const u8) Fail!?[]const u8 {
    const o = try obj(args);
    const v = o.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        .null => null,
        else => fail("'{s}' must be a string", .{key}),
    };
}

pub fn reqStr(args: std.json.Value, key: []const u8) Fail![]const u8 {
    return (try optStr(args, key)) orelse fail("missing required string '{s}'", .{key});
}

pub fn optInt(args: std.json.Value, key: []const u8) Fail!?i64 {
    const o = try obj(args);
    const v = o.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (@floor(f) == f and @abs(f) < 9e18) @as(i64, @intFromFloat(f)) else fail("'{s}' must be an integer", .{key}),
        .string, .number_string => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " "), 10) catch fail("'{s}' must be an integer", .{key}),
        .null => null,
        else => fail("'{s}' must be an integer", .{key}),
    };
}

pub fn optBool(args: std.json.Value, key: []const u8) Fail!bool {
    const o = try obj(args);
    const v = o.get(key) orelse return false;
    return switch (v) {
        .bool => |b| b,
        .null => false,
        else => fail("'{s}' must be a boolean", .{key}),
    };
}

/// Numeric argument: JSON number or numeric string.
pub fn numOf(v: std.json.Value, what: []const u8) Fail!f64 {
    const x: f64 = switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .string, .number_string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " ")) catch return fail("{s}: '{s}' is not a number", .{ what, s }),
        else => return fail("{s} must be a number", .{what}),
    };
    if (!std.math.isFinite(x)) return fail("{s} must be finite", .{what});
    return x;
}

pub fn optArr(args: std.json.Value, key: []const u8) Fail!?[]const std.json.Value {
    const o = try obj(args);
    const v = o.get(key) orelse return null;
    return switch (v) {
        .array => |a| a.items,
        .null => null,
        else => fail("'{s}' must be an array", .{key}),
    };
}

// ------------------------------------------------------------------ hex etc

pub fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

pub fn writeHex(w: *std.Io.Writer, bytes: []const u8) !void {
    const digits = "0123456789abcdef";
    for (bytes) |b| {
        try w.writeByte(digits[b >> 4]);
        try w.writeByte(digits[b & 15]);
    }
}

/// Parse hex bytes, ignoring whitespace, ':' ',' and '0x' prefixes.
pub fn parseHexBytes(a: std.mem.Allocator, s: []const u8) Err![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var hi: ?u8 = null;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == ':' or c == ',') {
            if (hi != null) return fail("hex: odd number of digits before separator at position {d}", .{i});
            continue;
        }
        if (c == '0' and hi == null and i + 1 < s.len and (s[i + 1] == 'x' or s[i + 1] == 'X')) {
            i += 1;
            continue;
        }
        const n = hexNibble(c) orelse return fail("hex: invalid character '{c}' at position {d}", .{ c, i });
        if (hi) |h| {
            try out.append(a, (h << 4) | n);
            hi = null;
        } else hi = n;
    }
    if (hi != null) return fail("hex: odd number of digits", .{});
    return out.toOwnedSlice(a);
}

// -------------------------------------------------------------------- dates

/// Days since 1970-01-01 for a proleptic Gregorian civil date.
pub fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub const Civil = struct { y: i64, m: u8, d: u8 };

pub fn civilFromDays(z_in: i64) Civil {
    const z = z_in + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .y = if (m <= 2) y + 1 else y, .m = @intCast(m), .d = @intCast(d) };
}

pub fn isLeap(y: i64) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

pub fn daysInMonth(y: i64, m: u8) u8 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        else => if (isLeap(y)) 29 else 28,
    };
}

/// 0 = Sunday.
pub fn weekday(days: i64) u8 {
    return @intCast(@mod(days + 4, 7));
}

pub const dow_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

/// "2026-01-02T03:04:05Z" from unix seconds (UTC).
pub fn writeIsoUtc(w: *std.Io.Writer, secs: i64) !void {
    const days = @divFloor(secs, 86400);
    const sod = secs - days * 86400;
    const c = civilFromDays(days);
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u64, @intCast(c.y)), c.m, c.d, @as(u64, @intCast(@divFloor(sod, 3600))), @as(u64, @intCast(@divFloor(@mod(sod, 3600), 60))), @as(u64, @intCast(@mod(sod, 60))),
    });
}

/// "1h 2m" style span for a number of seconds (two largest non-zero units).
pub fn writeSpan(w: *std.Io.Writer, secs_in: i64) !void {
    var s: u64 = @intCast(if (secs_in < 0) -secs_in else secs_in);
    const units = [_]struct { n: u64, u: []const u8 }{ .{ .n = 365 * 86400, .u = "y" }, .{ .n = 86400, .u = "d" }, .{ .n = 3600, .u = "h" }, .{ .n = 60, .u = "m" }, .{ .n = 1, .u = "s" } };
    var shown: u8 = 0;
    for (units) |u| {
        if (s >= u.n or (u.n == 1 and shown == 0)) {
            if (shown > 0) try w.writeByte(' ');
            try w.print("{d}{s}", .{ s / u.n, u.u });
            s %= u.n;
            shown += 1;
            if (shown == 2) return;
        }
    }
}

// ------------------------------------------------------------------ numbers

/// Shortest round-trip form; scientific outside [1e-5, 1e15).
pub fn fmtShortest(w: *std.Io.Writer, x: f64) !void {
    const ax = @abs(x);
    if (ax != 0 and (ax >= 1e15 or ax < 1e-5)) {
        try w.print("{e}", .{x});
    } else {
        try w.print("{d}", .{x});
    }
}

/// x rounded to 12 significant digits (hides binary noise such as 0.30000000000000004).
pub fn round12(x: f64) f64 {
    if (x == 0 or !std.math.isFinite(x)) return x;
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{e:.11}", .{x}) catch return x;
    return std.fmt.parseFloat(f64, s) catch x;
}

/// Rounded (12 significant digits) form.
pub fn fmtFloat(w: *std.Io.Writer, x: f64) !void {
    try fmtShortest(w, round12(x));
}
