//! cron: parse a 5-field cron expression, explain it, list next fire times.
//! Time zones: UTC or a fixed offset (+HH:MM) only; IANA names/DST are not supported.
//! Day matching follows Vixie cron: if both day-of-month and day-of-week are
//! restricted (neither starts with '*'), a day matches when EITHER matches.

const std = @import("std");
const u = @import("util.zig");

pub const MAX_COUNT = 50;
const MAX_YEARS_AHEAD = 50;

const month_names = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
const dow_lower = [_][]const u8{ "sun", "mon", "tue", "wed", "thu", "fri", "sat" };

const Cron = struct {
    min: u64,
    hour: u64,
    dom: u64,
    mon: u64,
    dow: u64,
    dom_star: bool,
    dow_star: bool,
    text: [5][]const u8,
};

const FieldKind = enum { minute, hour, dom, month, dow };

fn nameVal(s: []const u8, names: []const []const u8, base: u8) ?u8 {
    if (s.len != 3) return null;
    for (names, 0..) |n, i| if (std.ascii.eqlIgnoreCase(n, s)) return @intCast(i + base);
    return null;
}

fn atom(s: []const u8, kind: FieldKind) u.Fail!u8 {
    if (s.len == 0) return u.fail("cron: empty value in {s} field", .{@tagName(kind)});
    if (std.ascii.isDigit(s[0])) {
        if (std.mem.indexOfAny(u8, s, "#LlWw") != null) return u.fail("cron: '{s}': Quartz extensions (L, W, #) are not supported (standard 5-field cron only)", .{s});
        const v = std.fmt.parseInt(u8, s, 10) catch return u.fail("cron: '{s}' out of range in {s} field", .{ s, @tagName(kind) });
        return v;
    }
    if (kind == .month) if (nameVal(s, &month_names, 1)) |v| return v;
    if (kind == .dow) if (nameVal(s, &dow_lower, 0)) |v| return v;
    if (std.mem.indexOfAny(u8, s, "LlWw#") != null and s.len <= 3)
        return u.fail("cron: '{s}': Quartz extensions (L, W, #) are not supported (standard 5-field cron only)", .{s});
    return u.fail("cron: invalid value '{s}' in {s} field", .{ s, @tagName(kind) });
}

fn parseField(text: []const u8, kind: FieldKind) u.Fail!u64 {
    const lo: u8, const hi: u8 = switch (kind) {
        .minute => .{ 0, 59 },
        .hour => .{ 0, 23 },
        .dom => .{ 1, 31 },
        .month => .{ 1, 12 },
        .dow => .{ 0, 7 },
    };
    var bits: u64 = 0;
    var items = std.mem.splitScalar(u8, text, ',');
    while (items.next()) |item| {
        var step: u32 = 1;
        var rng = item;
        var has_step = false;
        if (std.mem.indexOfScalar(u8, item, '/')) |sl| {
            rng = item[0..sl];
            step = std.fmt.parseInt(u32, item[sl + 1 ..], 10) catch return u.fail("cron: invalid step '{s}' in {s} field", .{ item[sl + 1 ..], @tagName(kind) });
            if (step == 0) return u.fail("cron: step must be >= 1 in {s} field", .{@tagName(kind)});
            has_step = true;
        }
        var a: u8 = lo;
        var b: u8 = hi;
        if (std.mem.eql(u8, rng, "*") or (std.mem.eql(u8, rng, "?") and (kind == .dom or kind == .dow))) {
            if (kind == .dow) b = 6; // '*' covers 0..6; 7 is only an alias for 0
        } else if (std.mem.indexOfScalar(u8, rng, '-')) |d| {
            a = try atom(rng[0..d], kind);
            b = try atom(rng[d + 1 ..], kind);
            if (a > b) return u.fail("cron: descending range '{s}' in {s} field is not supported; split it (e.g. 22-23,0-2)", .{ rng, @tagName(kind) });
        } else {
            a = try atom(rng, kind);
            b = if (has_step) hi else a; // "5/15" means 5-max/15
        }
        if (a < lo or a > hi or b < lo or b > hi) return u.fail("cron: value out of range in {s} field (allowed {d}-{d}{s})", .{ @tagName(kind), lo, hi, if (kind == .dow) ", 7=Sunday" else "" });
        var v: u32 = a;
        while (v <= b) : (v += step) {
            const vv: u6 = @intCast(if (kind == .dow and v == 7) 0 else v);
            bits |= @as(u64, 1) << vv;
        }
    }
    return bits;
}

fn parseCron(expr_in: []const u8) u.Fail!Cron {
    var expr = std.mem.trim(u8, expr_in, " \t\r\n");
    if (expr.len > 0 and expr[0] == '@') {
        const al = [_]struct { []const u8, []const u8 }{
            .{ "@yearly", "0 0 1 1 *" },  .{ "@annually", "0 0 1 1 *" }, .{ "@monthly", "0 0 1 * *" },
            .{ "@weekly", "0 0 * * 0" }, .{ "@daily", "0 0 * * *" },     .{ "@midnight", "0 0 * * *" },
            .{ "@hourly", "0 * * * *" },
        };
        var found = false;
        for (al) |p| if (std.ascii.eqlIgnoreCase(p[0], expr)) {
            expr = p[1];
            found = true;
            break;
        };
        if (!found) return u.fail("cron: unsupported alias '{s}' (supported: @yearly @annually @monthly @weekly @daily @midnight @hourly; @reboot has no schedule)", .{expr});
    }
    var f: [5][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, expr, " \t");
    while (it.next()) |tok| {
        if (n == 5) return u.fail("cron: too many fields; expected 5 (minute hour day-of-month month day-of-week); seconds/year fields are not supported", .{});
        f[n] = tok;
        n += 1;
    }
    if (n != 5) return u.fail("cron: expected 5 fields (minute hour day-of-month month day-of-week), got {d}", .{n});
    return .{
        .min = try parseField(f[0], .minute),
        .hour = try parseField(f[1], .hour),
        .dom = try parseField(f[2], .dom),
        .mon = try parseField(f[3], .month),
        .dow = try parseField(f[4], .dow),
        .dom_star = f[2][0] == '*' or f[2][0] == '?',
        .dow_star = f[4][0] == '*' or f[4][0] == '?',
        .text = f,
    };
}

fn dayMatches(c: Cron, d: u8, wd: u8) bool {
    const dm = (c.dom >> @intCast(d)) & 1 == 1;
    const wm = (c.dow >> @intCast(wd)) & 1 == 1;
    if (!c.dom_star and !c.dow_star) return dm or wm;
    return dm and wm;
}

/// First fire time (local minutes since epoch) at or after `start`, or null within MAX_YEARS_AHEAD.
fn nextFire(c: Cron, start: i64) ?i64 {
    var t = start;
    const start_year = u.civilFromDays(@divFloor(start, 1440)).y;
    while (true) {
        const days = @divFloor(t, 1440);
        const mod = t - days * 1440;
        const civ = u.civilFromDays(days);
        if (civ.y > start_year + MAX_YEARS_AHEAD) return null;
        if ((c.mon >> @intCast(civ.m)) & 1 == 0) {
            const ny = if (civ.m == 12) civ.y + 1 else civ.y;
            const nm: i64 = if (civ.m == 12) 1 else civ.m + 1;
            t = u.daysFromCivil(ny, nm, 1) * 1440;
            continue;
        }
        if (!dayMatches(c, civ.d, u.weekday(days))) {
            t = (days + 1) * 1440;
            continue;
        }
        const h = @divFloor(mod, 60);
        const m = mod - h * 60;
        if ((c.hour >> @intCast(h)) & 1 == 0) {
            t = days * 1440 + (h + 1) * 60;
            continue;
        }
        if ((c.min >> @intCast(m)) & 1 == 0) {
            t += 1;
            continue;
        }
        return t;
    }
}

// ---------------------------------------------------------------- tz & from

fn parseOffset(s_in: ?[]const u8) u.Fail!i64 {
    const s = std.mem.trim(u8, s_in orelse return 0, " ");
    if (s.len == 0 or std.ascii.eqlIgnoreCase(s, "utc") or std.ascii.eqlIgnoreCase(s, "z") or std.ascii.eqlIgnoreCase(s, "gmt")) return 0;
    if (s[0] != '+' and s[0] != '-') return u.fail("tz: only UTC or a fixed offset like +02:00 / -0530 is supported (no IANA names, no DST); got '{s}'", .{s});
    const sign: i64 = if (s[0] == '-') -1 else 1;
    var digits: [4]u8 = undefined;
    var nd: usize = 0;
    for (s[1..]) |c| {
        if (c == ':') continue;
        if (!std.ascii.isDigit(c) or nd == 4) return u.fail("tz: invalid offset '{s}' (use +HH:MM)", .{s});
        digits[nd] = c;
        nd += 1;
    }
    var hh: i64 = 0;
    var mm: i64 = 0;
    switch (nd) {
        1 => hh = digits[0] - '0',
        2 => hh = @as(i64, digits[0] - '0') * 10 + (digits[1] - '0'),
        3 => {
            hh = digits[0] - '0';
            mm = @as(i64, digits[1] - '0') * 10 + (digits[2] - '0');
        },
        4 => {
            hh = @as(i64, digits[0] - '0') * 10 + (digits[1] - '0');
            mm = @as(i64, digits[2] - '0') * 10 + (digits[3] - '0');
        },
        else => return u.fail("tz: invalid offset '{s}' (use +HH:MM)", .{s}),
    }
    if (mm > 59 or hh > 18) return u.fail("tz: offset '{s}' out of range (max +-18:00)", .{s});
    return sign * (hh * 60 + mm);
}

fn num(s: []const u8, from: usize, len: usize) ?i64 {
    if (from + len > s.len) return null;
    var v: i64 = 0;
    for (s[from .. from + len]) |c| {
        if (!std.ascii.isDigit(c)) return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

/// Unix seconds from "YYYY-MM-DD[(T| )HH:MM[:SS][Z|+HH:MM]]" or epoch seconds.
fn parseFrom(s_in: []const u8, tz_min: i64) u.Fail!i64 {
    const s = std.mem.trim(u8, s_in, " ");
    const bad = "from: expected ISO-8601 like 2026-03-01T12:00:00Z, 2026-03-01 12:00 (in tz) or unix seconds";
    if (s.len >= 9 and std.mem.indexOfAny(u8, s, "-:T ") == null) {
        return std.fmt.parseInt(i64, s, 10) catch return u.fail(bad, .{});
    }
    const y = num(s, 0, 4) orelse return u.fail(bad, .{});
    if (s.len < 10 or s[4] != '-' or s[7] != '-') return u.fail(bad, .{});
    const mo = num(s, 5, 2) orelse return u.fail(bad, .{});
    const d = num(s, 8, 2) orelse return u.fail(bad, .{});
    if (mo < 1 or mo > 12 or d < 1 or d > u.daysInMonth(y, @intCast(mo))) return u.fail("from: invalid calendar date", .{});
    var h: i64 = 0;
    var mi: i64 = 0;
    var sec: i64 = 0;
    var off: i64 = tz_min;
    var p: usize = 10;
    if (p < s.len) {
        if (s[p] != 'T' and s[p] != ' ' and s[p] != 't') return u.fail(bad, .{});
        h = num(s, p + 1, 2) orelse return u.fail(bad, .{});
        if (p + 3 >= s.len or s[p + 3] != ':') return u.fail(bad, .{});
        mi = num(s, p + 4, 2) orelse return u.fail(bad, .{});
        p += 6;
        if (p < s.len and s[p] == ':') {
            sec = num(s, p + 1, 2) orelse return u.fail(bad, .{});
            p += 3;
        }
        if (p < s.len and s[p] == '.') {
            p += 1;
            while (p < s.len and std.ascii.isDigit(s[p])) p += 1;
        }
        if (p < s.len) off = try parseOffset(s[p..]);
        if (h > 23 or mi > 59 or sec > 60) return u.fail("from: invalid time of day", .{});
    }
    return u.daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + sec - off * 60;
}

// -------------------------------------------------------------- explanation

fn fullMask(kind: FieldKind) u64 {
    return switch (kind) {
        .minute => (@as(u64, 1) << 60) - 1,
        .hour => (@as(u64, 1) << 24) - 1,
        .dom => ((@as(u64, 1) << 32) - 1) & ~@as(u64, 1),
        .month => ((@as(u64, 1) << 13) - 1) & ~@as(u64, 1),
        .dow => (@as(u64, 1) << 7) - 1,
    };
}

fn popcount(x: u64) u32 {
    return @popCount(x);
}

fn writeSet(w: *std.Io.Writer, bits: u64, kind: FieldKind) !void {
    const maxv: u8 = switch (kind) {
        .minute => 59,
        .hour => 23,
        .dom => 31,
        .month => 12,
        .dow => 6,
    };
    var first = true;
    var v: u8 = 0;
    while (v <= maxv) {
        if ((bits >> @intCast(v)) & 1 == 0) {
            v += 1;
            continue;
        }
        var e = v;
        while (e < maxv and (bits >> @intCast(e + 1)) & 1 == 1) e += 1;
        if (!first) try w.writeAll(",");
        first = false;
        try writeVal(w, v, kind);
        if (e >= v + 2) {
            try w.writeAll("-");
            try writeVal(w, e, kind);
            v = e + 1;
        } else v += 1;
    }
}

fn writeVal(w: *std.Io.Writer, v: u8, kind: FieldKind) !void {
    switch (kind) {
        .month => try w.writeAll(&.{ std.ascii.toUpper(month_names[v - 1][0]), month_names[v - 1][1], month_names[v - 1][2] }),
        .dow => try w.writeAll(u.dow_names[v]),
        else => try w.print("{d}", .{v}),
    }
}

fn stepOf(text: []const u8) ?u32 {
    if (std.mem.startsWith(u8, text, "*/") and std.mem.indexOfScalar(u8, text, ',') == null) return std.fmt.parseInt(u32, text[2..], 10) catch null;
    return null;
}

pub fn explain(w: *std.Io.Writer, c: Cron) !void {
    const min_full = c.min == fullMask(.minute);
    const hour_full = c.hour == fullMask(.hour);
    if (popcount(c.min) == 1 and popcount(c.hour) == 1) {
        try w.print("At {d:0>2}:{d:0>2}", .{ @ctz(c.hour), @ctz(c.min) });
    } else {
        if (min_full) {
            try w.writeAll("Every minute");
        } else if (stepOf(c.text[0])) |s| {
            try w.print("Every {d} minutes", .{s});
        } else {
            try w.writeAll(if (popcount(c.min) == 1) "At minute " else "At minutes ");
            try writeSet(w, c.min, .minute);
        }
        if (!hour_full) {
            if (stepOf(c.text[1])) |s| {
                try w.print(", every {d} hours", .{s});
            } else {
                try w.writeAll(if (popcount(c.hour) == 1) ", past hour " else ", past hours ");
                try writeSet(w, c.hour, .hour);
            }
        } else if (!min_full and stepOf(c.text[0]) == null) try w.writeAll(" of every hour");
    }
    if (c.dom_star and c.dow_star) {
        try w.writeAll(", every day");
    } else if (!c.dom_star and !c.dow_star) {
        try w.writeAll(", on day-of-month ");
        try writeSet(w, c.dom, .dom);
        try w.writeAll(" OR on ");
        try writeSet(w, c.dow, .dow);
        try w.writeAll(" (standard cron: either matches)");
    } else if (!c.dom_star) {
        try w.writeAll(", on day-of-month ");
        try writeSet(w, c.dom, .dom);
    } else if (c.dow != fullMask(.dow)) {
        try w.writeAll(", on ");
        try writeSet(w, c.dow, .dow);
    } else try w.writeAll(", every day");
    if (c.mon != fullMask(.month)) {
        try w.writeAll(", in ");
        try writeSet(w, c.mon, .month);
    }
}

// ------------------------------------------------------------------- entry

pub fn handle(a: std.mem.Allocator, io: std.Io, args: std.json.Value) u.Err![]u8 {
    const expr = try u.reqStr(args, "expr");
    const count = (try u.optInt(args, "count")) orelse 5;
    if (count < 1 or count > MAX_COUNT) return u.fail("count must be 1..{d}", .{MAX_COUNT});
    const tz = try u.optStr(args, "tz");
    const from = try u.optStr(args, "from");
    const now = @divFloor(std.Io.Timestamp.now(io, .real).toMilliseconds(), 1000);
    return run(a, expr, @intCast(count), tz, from, now);
}

pub fn run(a: std.mem.Allocator, expr: []const u8, count: usize, tz: ?[]const u8, from: ?[]const u8, now_s: i64) u.Err![]u8 {
    const c = try parseCron(expr);
    const off = try parseOffset(tz);
    const from_s = if (from) |f| try parseFrom(f, off) else now_s;
    var out: u.Out = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("cron: {s}\nmeaning: ", .{std.mem.trim(u8, expr, " ")});
    try explain(w, c);
    try w.writeAll("\ntz: ");
    try writeOffset(w, off);
    try w.writeAll(" (fixed offset only; IANA zones/DST unsupported)\nafter: ");
    try writeLocal(w, @divFloor(from_s + off * 60, 60), off, false);
    try w.writeAll("\nnext:");
    var t = @divFloor(from_s + off * 60, 60) + 1; // strictly after `from`
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const nf = nextFire(c, t) orelse {
            if (i == 0) return u.fail("cron: no fire time within {d} years (schedule can never match, e.g. day 31 in February)", .{MAX_YEARS_AHEAD});
            try w.print("\n(no more fire times within {d} years)", .{MAX_YEARS_AHEAD});
            break;
        };
        try w.writeAll("\n");
        try writeLocal(w, nf, off, true);
        t = nf + 1;
    }
    return out.toOwnedSlice();
}

fn writeOffset(w: *std.Io.Writer, off: i64) !void {
    if (off == 0) return w.writeAll("UTC");
    const ao: u64 = @intCast(if (off < 0) -off else off);
    try w.print("{c}{d:0>2}:{d:0>2}", .{ @as(u8, if (off < 0) '-' else '+'), ao / 60, ao % 60 });
}

fn writeLocal(w: *std.Io.Writer, local_min: i64, off: i64, weekday: bool) !void {
    const days = @divFloor(local_min, 1440);
    const mod = local_min - days * 1440;
    const c = u.civilFromDays(days);
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(c.y)), c.m, c.d, @as(u64, @intCast(@divFloor(mod, 60))), @as(u64, @intCast(@mod(mod, 60))) });
    if (off == 0) try w.writeAll("Z") else try writeOffset(w, off);
    if (weekday) try w.print(" {s}", .{u.dow_names[u.weekday(days)]});
}

// ------------------------------------------------------------------- tests

fn fires(expr: []const u8, count: usize, tz: ?[]const u8, from: []const u8) ![]u8 {
    return run(std.testing.allocator, expr, count, tz, from, 0);
}

fn expectContains(hay: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, hay, needle) == null) {
        std.debug.print("missing '{s}' in:\n{s}\n", .{ needle, hay });
        return error.Missing;
    }
}

fn expectNextLines(expr: []const u8, tz: ?[]const u8, from: []const u8, want: []const []const u8) !void {
    const got = try fires(expr, want.len, tz, from);
    defer std.testing.allocator.free(got);
    const idx = std.mem.indexOf(u8, got, "\nnext:\n").? + 7;
    var it = std.mem.splitScalar(u8, got[idx..], '\n');
    for (want) |wl| {
        const line = it.next() orelse return error.TooFew;
        if (!std.mem.eql(u8, wl, line)) {
            std.debug.print("want '{s}' got '{s}'\n", .{ wl, line });
            return error.Mismatch;
        }
    }
    try std.testing.expect(it.next() == null);
}

fn expectFail(expr: []const u8, tz: ?[]const u8, from: ?[]const u8, needle: []const u8) !void {
    if (run(std.testing.allocator, expr, 3, tz, from, 0)) |got| {
        std.testing.allocator.free(got);
        std.debug.print("expected error for '{s}'\n", .{expr});
        return error.ExpectedFailure;
    } else |e| {
        try std.testing.expect(e == error.Fail);
        try expectContains(u.lastError(), needle);
    }
}

test "steps and strictly-after semantics" {
    try expectNextLines("*/15 * * * *", null, "2026-01-01T00:00:00Z", &.{ "2026-01-01T00:15Z Thu", "2026-01-01T00:30Z Thu", "2026-01-01T00:45Z Thu", "2026-01-01T01:00Z Thu" });
    try expectNextLines("*/15 * * * *", null, "2026-01-01T00:07:30Z", &.{ "2026-01-01T00:15Z Thu" });
    try expectNextLines("5-59/20 * * * *", null, "2026-01-01T00:00Z", &.{ "2026-01-01T00:05Z Thu", "2026-01-01T00:25Z Thu", "2026-01-01T00:45Z Thu", "2026-01-01T01:05Z Thu" });
    try expectNextLines("5/30 * * * *", null, "2026-01-01T00:00Z", &.{ "2026-01-01T00:05Z Thu", "2026-01-01T00:35Z Thu" });
}

test "weekday ranges and names" {
    // 2026-01-02 is a Friday
    try expectNextLines("0 9 * * 1-5", null, "2026-01-02T10:00:00Z", &.{ "2026-01-05T09:00Z Mon", "2026-01-06T09:00Z Tue", "2026-01-07T09:00Z Wed", "2026-01-08T09:00Z Thu", "2026-01-09T09:00Z Fri", "2026-01-12T09:00Z Mon" });
    try expectNextLines("0 9 * * mon-fri", null, "2026-01-02T10:00:00Z", &.{"2026-01-05T09:00Z Mon"});
    try expectNextLines("0 0 * * 7", null, "2026-01-01T00:00Z", &.{ "2026-01-04T00:00Z Sun", "2026-01-11T00:00Z Sun" }); // 7 = Sunday
    try expectNextLines("0 0 * * SUN,sat", null, "2026-01-01T00:00Z", &.{ "2026-01-03T00:00Z Sat", "2026-01-04T00:00Z Sun" });
}

test "day-of-month and day-of-week interplay (Vixie OR rule)" {
    // both restricted: either matches -> every Friday plus every 13th
    try expectNextLines("0 0 13 * 5", null, "2026-01-01T00:00Z", &.{ "2026-01-02T00:00Z Fri", "2026-01-09T00:00Z Fri", "2026-01-13T00:00Z Tue", "2026-01-16T00:00Z Fri" });
    // '*' in one of them: AND (i.e. only the restricted one matters)
    try expectNextLines("0 0 13 * *", null, "2026-01-01T00:00Z", &.{ "2026-01-13T00:00Z Tue", "2026-02-13T00:00Z Fri", "2026-03-13T00:00Z Fri" });
    // "*/2" counts as star (Vixie): dom step AND dow
    try expectNextLines("0 0 */10 * 1", null, "2026-01-01T00:00Z", &.{"2026-05-11T00:00Z Mon"});
}

test "months, leap day, impossible dates, year rollover" {
    try expectNextLines("0 0 1 */2 *", null, "2026-01-01T00:00Z", &.{ "2026-03-01T00:00Z Sun", "2026-05-01T00:00Z Fri", "2026-07-01T00:00Z Wed" });
    try expectNextLines("0 0 * jan-mar mon", null, "2026-01-01T00:00Z", &.{ "2026-01-05T00:00Z Mon", "2026-01-12T00:00Z Mon" });
    try expectNextLines("0 0 29 2 *", null, "2026-01-01T00:00Z", &.{ "2028-02-29T00:00Z Tue", "2032-02-29T00:00Z Sun" });
    try expectNextLines("0 0 29 2 *", null, "2097-01-01T00:00Z", &.{ "2104-02-29T00:00Z Fri" }); // 2100 is not a leap year
    try expectNextLines("59 23 31 12 *", null, "2026-12-31T23:59:00Z", &.{ "2027-12-31T23:59Z Fri" });
    try expectNextLines("30 2 31 * *", null, "2026-01-31T02:30:00Z", &.{ "2026-03-31T02:30Z Tue", "2026-05-31T02:30Z Sun" });
    try expectFail("0 0 31 2 *", null, "2026-01-01T00:00Z", "no fire time");
    try expectFail("0 0 30 feb *", null, "2026-01-01T00:00Z", "no fire time");
}

test "aliases" {
    try expectNextLines("@daily", null, "2026-01-01T12:00Z", &.{ "2026-01-02T00:00Z Fri", "2026-01-03T00:00Z Sat" });
    try expectNextLines("@midnight", null, "2026-01-01T12:00Z", &.{"2026-01-02T00:00Z Fri"});
    try expectNextLines("@hourly", null, "2026-01-01T12:30Z", &.{ "2026-01-01T13:00Z Thu", "2026-01-01T14:00Z Thu" });
    try expectNextLines("@weekly", null, "2026-01-01T12:30Z", &.{"2026-01-04T00:00Z Sun"});
    try expectNextLines("@monthly", null, "2026-01-01T12:30Z", &.{"2026-02-01T00:00Z Sun"});
    try expectNextLines("@yearly", null, "2026-01-01T12:30Z", &.{"2027-01-01T00:00Z Fri"});
    try expectNextLines("@annually", null, "2026-01-01T12:30Z", &.{"2027-01-01T00:00Z Fri"});
}

test "fixed offsets (no DST)" {
    // 2026-03-01T00:00Z is 02:00 at +02:00, so 09:00 local is the same calendar day
    try expectNextLines("0 9 * * *", "+02:00", "2026-03-01T00:00:00Z", &.{ "2026-03-01T09:00+02:00 Sun", "2026-03-02T09:00+02:00 Mon" });
    // 'from' without offset is read in tz
    try expectNextLines("0 9 * * *", "+02:00", "2026-03-01 10:00", &.{"2026-03-02T09:00+02:00 Mon"});
    // 'from' with its own offset wins
    try expectNextLines("0 9 * * *", "-05:30", "2026-03-01T12:00:00+02:00", &.{"2026-03-01T09:00-05:30 Sun"});
    // day rolls over between UTC and local: 23:30Z is already the next day at +02:00
    try expectNextLines("0 0 * * *", "+0200", "2026-03-01T23:30:00Z", &.{"2026-03-03T00:00+02:00 Tue"});
    try expectNextLines("0 0 * * *", "Z", "2026-03-01T23:30:00Z", &.{"2026-03-02T00:00Z Mon"});
    try expectNextLines("0 12 * * *", "+5", "1700000000", &.{"2023-11-15T12:00+05:00 Wed"}); // epoch seconds input
}

test "explanations" {
    const g = try fires("*/15 9-17 * * 1-5", 1, null, "2026-01-01T00:00Z");
    defer std.testing.allocator.free(g);
    try expectContains(g, "meaning: Every 15 minutes, past hours 9-17, on Mon-Fri");
    const h = try fires("30 4 1,15 * *", 1, null, "2026-01-01T00:00Z");
    defer std.testing.allocator.free(h);
    try expectContains(h, "meaning: At 04:30, on day-of-month 1,15");
    const i = try fires("0 0 13 * 5", 1, null, "2026-01-01T00:00Z");
    defer std.testing.allocator.free(i);
    try expectContains(i, "on day-of-month 13 OR on Fri (standard cron: either matches)");
    const j = try fires("* * * * *", 1, null, "2026-01-01T00:00Z");
    defer std.testing.allocator.free(j);
    try expectContains(j, "meaning: Every minute, every day");
    const k = try fires("0 8 * mar,jun-aug *", 1, null, "2026-01-01T00:00Z");
    defer std.testing.allocator.free(k);
    try expectContains(k, "At 08:00, every day, in Mar,Jun-Aug");
    try expectContains(k, "fixed offset only");
}

test "errors" {
    try expectFail("* * * *", null, null, "expected 5 fields");
    try expectFail("0 0 * * * *", null, null, "too many fields");
    try expectFail("60 * * * *", null, null, "out of range");
    try expectFail("* 24 * * *", null, null, "out of range");
    try expectFail("* * 0 * *", null, null, "out of range");
    try expectFail("* * * 13 *", null, null, "out of range");
    try expectFail("* * * * 8", null, null, "out of range");
    try expectFail("*/0 * * * *", null, null, "step");
    try expectFail("5-1 * * * *", null, null, "descending");
    try expectFail("@reboot", null, null, "unsupported alias");
    try expectFail("0 0 L * *", null, null, "Quartz");
    try expectFail("0 0 * * 5#2", null, null, "Quartz");
    try expectFail("abc * * * *", null, null, "invalid value");
    try expectFail("* * * * *", "America/New_York", null, "no IANA");
    try expectFail("* * * * *", "+25:00", null, "out of range");
    try expectFail("* * * * *", null, "yesterday", "from:");
    try expectFail("* * * * *", null, "2026-02-30", "invalid calendar date");
}
