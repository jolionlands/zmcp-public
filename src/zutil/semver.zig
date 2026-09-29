//! semver: semver.org 2.0.0 precedence + npm-style ranges (^ ~ >= < x-ranges, hyphen, ||).
//! Range semantics follow node-semver: a bare "1.2.3" is exact, and a prerelease
//! version only satisfies a comparator set that contains a prerelease comparator
//! with the same major.minor.patch.

const std = @import("std");
const u = @import("util.zig");

pub const MAX_VERSIONS = 2000;

pub const Ver = struct {
    major: u64 = 0,
    minor: u64 = 0,
    patch: u64 = 0,
    pre: []const u8 = "",
    build: []const u8 = "",
};

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-';
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn checkIdents(s: []const u8, what: []const u8, numeric_no_lead0: bool, whole: []const u8) u.Fail!void {
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |id| {
        if (id.len == 0) return u.fail("semver: empty {s} identifier in '{s}'", .{ what, whole });
        for (id) |c| if (!isIdentChar(c)) return u.fail("semver: invalid character '{c}' in {s} of '{s}'", .{ c, what, whole });
        if (numeric_no_lead0 and allDigits(id) and id.len > 1 and id[0] == '0') return u.fail("semver: numeric {s} identifier '{s}' has a leading zero in '{s}'", .{ what, id, whole });
    }
}

fn parseNum(s: []const u8, what: []const u8, whole: []const u8) u.Fail!u64 {
    if (!allDigits(s)) return u.fail("semver: {s} '{s}' is not a number in '{s}' (expected MAJOR.MINOR.PATCH)", .{ what, s, whole });
    if (s.len > 1 and s[0] == '0') return u.fail("semver: {s} '{s}' has a leading zero in '{s}'", .{ what, s, whole });
    return std.fmt.parseInt(u64, s, 10) catch u.fail("semver: {s} '{s}' is too large", .{ what, s });
}

/// Strict semver 2.0.0 (a single leading 'v' or '=' is tolerated and dropped).
pub fn parseVersion(s_in: []const u8) u.Fail!Ver {
    var s = std.mem.trim(u8, s_in, " \t");
    const whole = s;
    if (s.len > 0 and s[0] == '=') s = std.mem.trimStart(u8, s[1..], " ");
    if (s.len > 0 and (s[0] == 'v' or s[0] == 'V')) s = s[1..];
    var v: Ver = .{};
    var core = s;
    if (std.mem.indexOfScalar(u8, core, '+')) |i| {
        v.build = core[i + 1 ..];
        core = core[0..i];
        try checkIdents(v.build, "build", false, whole);
    }
    if (std.mem.indexOfScalar(u8, core, '-')) |i| {
        v.pre = core[i + 1 ..];
        core = core[0..i];
        try checkIdents(v.pre, "prerelease", true, whole);
    }
    var it = std.mem.splitScalar(u8, core, '.');
    const a = it.next() orelse "";
    const b = it.next() orelse return u.fail("semver: '{s}' is not MAJOR.MINOR.PATCH", .{whole});
    const c = it.next() orelse return u.fail("semver: '{s}' is not MAJOR.MINOR.PATCH", .{whole});
    if (it.next() != null) return u.fail("semver: '{s}' has more than 3 numeric parts", .{whole});
    v.major = try parseNum(a, "major", whole);
    v.minor = try parseNum(b, "minor", whole);
    v.patch = try parseNum(c, "patch", whole);
    return v;
}

fn cmpNum(a: u64, b: u64) std.math.Order {
    return std.math.order(a, b);
}

fn cmpIdent(a: []const u8, b: []const u8) std.math.Order {
    const an = allDigits(a);
    const bn = allDigits(b);
    if (an and bn) {
        if (a.len != b.len) return std.math.order(a.len, b.len); // no leading zeros, so longer is bigger
        return std.mem.order(u8, a, b);
    }
    if (an) return .lt; // numeric identifiers sort below alphanumeric
    if (bn) return .gt;
    return std.mem.order(u8, a, b);
}

fn cmpPre(a: []const u8, b: []const u8) std.math.Order {
    if (a.len == 0 and b.len == 0) return .eq;
    if (a.len == 0) return .gt; // a release outranks its prereleases
    if (b.len == 0) return .lt;
    var ia = std.mem.splitScalar(u8, a, '.');
    var ib = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const x = ia.next();
        const y = ib.next();
        if (x == null and y == null) return .eq;
        if (x == null) return .lt; // fewer fields sorts first
        if (y == null) return .gt;
        const c = cmpIdent(x.?, y.?);
        if (c != .eq) return c;
    }
}

/// semver.org precedence (build metadata ignored).
pub fn compare(a: Ver, b: Ver) std.math.Order {
    var c = cmpNum(a.major, b.major);
    if (c != .eq) return c;
    c = cmpNum(a.minor, b.minor);
    if (c != .eq) return c;
    c = cmpNum(a.patch, b.patch);
    if (c != .eq) return c;
    return cmpPre(a.pre, b.pre);
}

fn writeVer(w: *std.Io.Writer, v: Ver) !void {
    try w.print("{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
    if (v.pre.len > 0) try w.print("-{s}", .{v.pre});
    if (v.build.len > 0) try w.print("+{s}", .{v.build});
}

// ------------------------------------------------------------------ ranges

const Op = enum { lt, le, gt, ge, eq };
const Comp = struct { op: Op, v: Ver };
const Set = std.ArrayList(Comp);

const Partial = struct { major: ?u64 = null, minor: ?u64 = null, patch: ?u64 = null, pre: []const u8 = "" };

fn isWild(s: []const u8) bool {
    return s.len == 0 or std.mem.eql(u8, s, "*") or std.mem.eql(u8, s, "x") or std.mem.eql(u8, s, "X");
}

fn parsePartial(s_in: []const u8) u.Fail!Partial {
    var s = s_in;
    if (s.len > 0 and (s[0] == 'v' or s[0] == 'V')) s = s[1..];
    var p: Partial = .{};
    if (std.mem.indexOfScalar(u8, s, '+')) |i| s = s[0..i]; // build metadata is irrelevant in ranges
    if (std.mem.indexOfScalar(u8, s, '-')) |i| {
        p.pre = s[i + 1 ..];
        s = s[0..i];
        try checkIdents(p.pre, "prerelease", true, s_in);
    }
    var it = std.mem.splitScalar(u8, s, '.');
    const a = it.next() orelse "";
    const b = it.next();
    const c = it.next();
    if (it.next() != null) return u.fail("range: '{s}' has more than 3 parts", .{s_in});
    if (isWild(a)) {
        return p;
    }
    p.major = try parseNum(a, "major", s_in);
    if (b) |bb| if (!isWild(bb)) {
        p.minor = try parseNum(bb, "minor", s_in);
        if (c) |cc| if (!isWild(cc)) {
            p.patch = try parseNum(cc, "patch", s_in);
        };
    };
    if (p.patch == null) p.pre = ""; // 1.2.x-beta makes no sense
    return p;
}

fn mkv(major: u64, minor: u64, patch: u64, pre: []const u8) Ver {
    return .{ .major = major, .minor = minor, .patch = patch, .pre = pre };
}

fn isOperatorOnly(t: []const u8) bool {
    if (t.len == 0) return false;
    for (t) |c| if (std.mem.indexOfScalar(u8, "^~<>=", c) == null) return false;
    return true;
}

fn push(a: std.mem.Allocator, set: *Set, op: Op, v: Ver) !void {
    try set.append(a, .{ .op = op, .v = v });
}

fn none(a: std.mem.Allocator, set: *Set) !void {
    try push(a, set, .lt, mkv(0, 0, 0, "0")); // matches nothing
}

fn desugar(a: std.mem.Allocator, set: *Set, tok_in: []const u8) u.Err!void {
    var tok = tok_in;
    var opstr: []const u8 = "";
    const ops = [_][]const u8{ ">=", "<=", "~>", "^", "~", ">", "<", "=" };
    for (ops) |o| if (std.mem.startsWith(u8, tok, o)) {
        opstr = o;
        tok = std.mem.trimStart(u8, tok[o.len..], " ");
        break;
    };
    const p = try parsePartial(tok);
    const kind: enum { caret, tilde, ge, le, gt, lt, eq } = if (std.mem.eql(u8, opstr, "^")) .caret else if (std.mem.eql(u8, opstr, "~") or std.mem.eql(u8, opstr, "~>")) .tilde else if (std.mem.eql(u8, opstr, ">=")) .ge else if (std.mem.eql(u8, opstr, "<=")) .le else if (std.mem.eql(u8, opstr, ">")) .gt else if (std.mem.eql(u8, opstr, "<")) .lt else .eq;
    if (p.major == null) {
        switch (kind) {
            .gt, .lt => try none(a, set),
            else => try push(a, set, .ge, mkv(0, 0, 0, "")),
        }
        return;
    }
    const M = p.major.?;
    switch (kind) {
        .eq => {
            if (p.minor == null) {
                try push(a, set, .ge, mkv(M, 0, 0, ""));
                try push(a, set, .lt, mkv(M + 1, 0, 0, "0"));
            } else if (p.patch == null) {
                try push(a, set, .ge, mkv(M, p.minor.?, 0, ""));
                try push(a, set, .lt, mkv(M, p.minor.? + 1, 0, "0"));
            } else try push(a, set, .eq, mkv(M, p.minor.?, p.patch.?, p.pre));
        },
        .caret => {
            const m = p.minor orelse 0;
            const pa = p.patch orelse 0;
            const lower = mkv(M, m, pa, p.pre);
            try push(a, set, .ge, lower);
            if (M > 0 or p.minor == null) {
                try push(a, set, .lt, mkv(M + 1, 0, 0, "0"));
            } else if (m > 0 or p.patch == null) {
                try push(a, set, .lt, mkv(0, m + 1, 0, "0"));
            } else try push(a, set, .lt, mkv(0, 0, pa + 1, "0"));
        },
        .tilde => {
            try push(a, set, .ge, mkv(M, p.minor orelse 0, p.patch orelse 0, p.pre));
            if (p.minor == null) {
                try push(a, set, .lt, mkv(M + 1, 0, 0, "0"));
            } else try push(a, set, .lt, mkv(M, p.minor.? + 1, 0, "0"));
        },
        .ge => try push(a, set, .ge, mkv(M, p.minor orelse 0, p.patch orelse 0, p.pre)),
        .gt => {
            if (p.minor == null) {
                try push(a, set, .ge, mkv(M + 1, 0, 0, ""));
            } else if (p.patch == null) {
                try push(a, set, .ge, mkv(M, p.minor.? + 1, 0, ""));
            } else try push(a, set, .gt, mkv(M, p.minor.?, p.patch.?, p.pre));
        },
        .lt => try push(a, set, .lt, mkv(M, p.minor orelse 0, p.patch orelse 0, if (p.patch == null) "0" else p.pre)),
        .le => {
            if (p.minor == null) {
                try push(a, set, .lt, mkv(M + 1, 0, 0, "0"));
            } else if (p.patch == null) {
                try push(a, set, .lt, mkv(M, p.minor.? + 1, 0, "0"));
            } else try push(a, set, .le, mkv(M, p.minor.?, p.patch.?, p.pre));
        },
    }
}

fn hyphen(a: std.mem.Allocator, set: *Set, lo_s: []const u8, hi_s: []const u8) u.Err!void {
    const lo = try parsePartial(lo_s);
    const hi = try parsePartial(hi_s);
    if (lo.major) |M| try push(a, set, .ge, mkv(M, lo.minor orelse 0, lo.patch orelse 0, lo.pre));
    if (hi.major) |M| {
        if (hi.minor == null) {
            try push(a, set, .lt, mkv(M + 1, 0, 0, "0"));
        } else if (hi.patch == null) {
            try push(a, set, .lt, mkv(M, hi.minor.? + 1, 0, "0"));
        } else try push(a, set, .le, mkv(M, hi.minor.?, hi.patch.?, hi.pre));
    }
    if (set.items.len == 0) try push(a, set, .ge, mkv(0, 0, 0, ""));
}

fn parseRange(a: std.mem.Allocator, text: []const u8) u.Err![]Set {
    var sets: std.ArrayList(Set) = .empty;
    var parts = std.mem.splitSequence(u8, text, "||");
    while (parts.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t");
        var set: Set = .empty;
        var toks: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, part, " \t,");
        while (it.next()) |t| try toks.append(a, t);
        var i: usize = 0;
        while (i < toks.items.len) {
            const t = toks.items[i];
            if (i + 2 < toks.items.len and std.mem.eql(u8, toks.items[i + 1], "-")) {
                try hyphen(a, &set, t, toks.items[i + 2]);
                i += 3;
                continue;
            }
            if (isOperatorOnly(t)) {
                if (i + 1 >= toks.items.len) return u.fail("range: dangling operator '{s}'", .{t});
                const joined = try std.fmt.allocPrint(a, "{s}{s}", .{ t, toks.items[i + 1] });
                try desugar(a, &set, joined);
                i += 2;
                continue;
            }
            try desugar(a, &set, t);
            i += 1;
        }
        if (set.items.len == 0) try push(a, &set, .ge, mkv(0, 0, 0, "")); // empty range = any
        try sets.append(a, set);
    }
    return sets.items;
}

fn compOk(c: Comp, v: Ver) bool {
    const o = compare(v, c.v);
    return switch (c.op) {
        .lt => o == .lt,
        .le => o != .gt,
        .gt => o == .gt,
        .ge => o != .lt,
        .eq => o == .eq,
    };
}

fn setSatisfied(set: Set, v: Ver, honor_pre: bool) bool {
    for (set.items) |c| if (!compOk(c, v)) return false;
    if (v.pre.len > 0 and honor_pre) {
        for (set.items) |c| {
            if (c.v.pre.len > 0 and c.v.major == v.major and c.v.minor == v.minor and c.v.patch == v.patch) return true;
        }
        return false;
    }
    return true;
}

fn writeRange(w: *std.Io.Writer, sets: []const Set) !void {
    for (sets, 0..) |s, i| {
        if (i > 0) try w.writeAll(" || ");
        for (s.items, 0..) |c, j| {
            if (j > 0) try w.writeByte(' ');
            try w.writeAll(switch (c.op) {
                .lt => "<",
                .le => "<=",
                .gt => ">",
                .ge => ">=",
                .eq => "=",
            });
            try writeVer(w, c.v);
        }
    }
}

// --------------------------------------------------------------------- ops

fn bump(a: std.mem.Allocator, v_in: Ver, level: []const u8, pre_id: ?[]const u8) u.Err!Ver {
    var v = v_in;
    v.build = "";
    const L = std.meta.stringToEnum(enum { major, minor, patch, premajor, preminor, prepatch, prerelease }, level) orelse
        return u.fail("level must be major|minor|patch|premajor|preminor|prepatch|prerelease", .{});
    if (pre_id) |id| try checkIdents(id, "pre_id", true, id);
    const fresh: []const u8 = if (pre_id) |id| try std.fmt.allocPrint(a, "{s}.0", .{id}) else "0";
    switch (L) {
        .major => {
            if (v.minor != 0 or v.patch != 0 or v.pre.len == 0) v.major += 1;
            v.minor = 0;
            v.patch = 0;
            v.pre = "";
        },
        .minor => {
            if (v.patch != 0 or v.pre.len == 0) v.minor += 1;
            v.patch = 0;
            v.pre = "";
        },
        .patch => {
            if (v.pre.len == 0) v.patch += 1;
            v.pre = "";
        },
        .premajor => {
            v.major += 1;
            v.minor = 0;
            v.patch = 0;
            v.pre = fresh;
        },
        .preminor => {
            v.minor += 1;
            v.patch = 0;
            v.pre = fresh;
        },
        .prepatch => {
            v.patch += 1;
            v.pre = fresh;
        },
        .prerelease => {
            if (v.pre.len == 0) {
                v.patch += 1;
                v.pre = fresh;
            } else {
                var ids: std.ArrayList([]const u8) = .empty;
                var it = std.mem.splitScalar(u8, v.pre, '.');
                while (it.next()) |x| try ids.append(a, x);
                var k = ids.items.len;
                var done = false;
                while (k > 0) {
                    k -= 1;
                    if (allDigits(ids.items[k])) {
                        const n = std.fmt.parseInt(u64, ids.items[k], 10) catch return u.fail("prerelease number too large", .{});
                        ids.items[k] = try std.fmt.allocPrint(a, "{d}", .{n + 1});
                        done = true;
                        break;
                    }
                }
                if (!done) try ids.append(a, "0");
                if (pre_id) |id| {
                    if (std.mem.eql(u8, ids.items[0], id)) {
                        if (ids.items.len < 2 or !allDigits(ids.items[1])) {
                            ids.clearRetainingCapacity();
                            try ids.appendSlice(a, &.{ id, "0" });
                        }
                    } else {
                        ids.clearRetainingCapacity();
                        try ids.appendSlice(a, &.{ id, "0" });
                    }
                }
                v.pre = try std.mem.join(a, ".", ids.items);
            }
        },
    }
    return v;
}

fn lessThan(_: void, x: Ver, y: Ver) bool {
    return compare(x, y) == .lt;
}

pub fn handle(a: std.mem.Allocator, args: std.json.Value) u.Err![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const op = try u.reqStr(args, "op");
    var out: u.Out = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    if (std.mem.eql(u8, op, "parse")) {
        const v = try parseVersion(try u.reqStr(args, "version"));
        try w.print("major={d} minor={d} patch={d} prerelease=", .{ v.major, v.minor, v.patch });
        try w.writeAll(if (v.pre.len > 0) v.pre else "(none)");
        try w.writeAll(" build=");
        try w.writeAll(if (v.build.len > 0) v.build else "(none)");
        try w.writeAll(" normalized=");
        try writeVer(w, v);
    } else if (std.mem.eql(u8, op, "compare")) {
        const x = try parseVersion(try u.reqStr(args, "version"));
        const y = try parseVersion(try u.reqStr(args, "other"));
        try writeVer(w, x);
        try w.writeAll(switch (compare(x, y)) {
            .lt => " < ",
            .eq => " = ",
            .gt => " > ",
        });
        try writeVer(w, y);
        try w.writeAll(" (semver.org precedence; build metadata ignored)");
    } else if (std.mem.eql(u8, op, "satisfies")) {
        const rs = try u.reqStr(args, "range");
        const v = try parseVersion(try u.reqStr(args, "version"));
        const sets = try parseRange(ar, rs);
        var ok = false;
        var ok_ignoring_pre = false;
        for (sets) |s| {
            if (setSatisfied(s, v, true)) ok = true;
            if (setSatisfied(s, v, false)) ok_ignoring_pre = true;
        }
        try writeVer(w, v);
        try w.print(" {s} {s} (range: ", .{ if (ok) "satisfies" else "does NOT satisfy", std.mem.trim(u8, rs, " ") });
        try writeRange(w, sets);
        try w.writeAll(")");
        if (!ok and ok_ignoring_pre) try w.writeAll("; prerelease versions only match a set that has a prerelease comparator on the same major.minor.patch");
    } else if (std.mem.eql(u8, op, "bump")) {
        const v = try parseVersion(try u.reqStr(args, "version"));
        const nv = try bump(ar, v, try u.reqStr(args, "level"), try u.optStr(args, "pre_id"));
        try writeVer(w, v);
        try w.writeAll(" -> ");
        try writeVer(w, nv);
    } else if (std.mem.eql(u8, op, "sort")) {
        const arr = (try u.optArr(args, "versions")) orelse return u.fail("sort needs 'versions' array", .{});
        if (arr.len > MAX_VERSIONS) return u.fail("too many versions (max {d})", .{MAX_VERSIONS});
        const vs = try ar.alloc(Ver, arr.len);
        const orig = try ar.alloc([]const u8, arr.len);
        for (arr, 0..) |e, i| {
            if (e != .string) return u.fail("versions[{d}] must be a string", .{i});
            vs[i] = try parseVersion(e.string);
            orig[i] = std.mem.trim(u8, e.string, " \t");
        }
        const idx = try ar.alloc(usize, arr.len);
        for (idx, 0..) |*x, i| x.* = i;
        const desc = try u.optBool(args, "desc");
        // stable insertion sort on indices (equal precedence keeps input order)
        var i: usize = 1;
        while (i < idx.len) : (i += 1) {
            const cur = idx[i];
            var j = i;
            while (j > 0) : (j -= 1) {
                const c = compare(vs[idx[j - 1]], vs[cur]);
                const move = if (desc) c == .lt else c == .gt;
                if (!move) break;
                idx[j] = idx[j - 1];
            }
            idx[j] = cur;
        }
        for (idx, 0..) |k, n| {
            if (n > 0) try w.writeByte('\n');
            try w.writeAll(orig[k]);
        }
    } else return u.fail("unknown op '{s}' (compare|satisfies|bump|sort|parse)", .{op});
    return out.toOwnedSlice();
}

// ------------------------------------------------------------------- tests

fn pv(s: []const u8) Ver {
    return parseVersion(s) catch unreachable;
}

test "semver.org precedence chain (spec item 11)" {
    const chain = [_][]const u8{ "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0" };
    for (0..chain.len - 1) |i| {
        try std.testing.expectEqual(std.math.Order.lt, compare(pv(chain[i]), pv(chain[i + 1])));
        try std.testing.expectEqual(std.math.Order.gt, compare(pv(chain[i + 1]), pv(chain[i])));
    }
    // 1.0.0 < 2.0.0 < 2.1.0 < 2.1.1
    const core = [_][]const u8{ "1.0.0", "2.0.0", "2.1.0", "2.1.1" };
    for (0..core.len - 1) |i| try std.testing.expectEqual(std.math.Order.lt, compare(pv(core[i]), pv(core[i + 1])));
    // numeric compare, not lexical
    try std.testing.expectEqual(std.math.Order.lt, compare(pv("1.2.9"), pv("1.10.0")));
    try std.testing.expectEqual(std.math.Order.lt, compare(pv("1.0.0-9"), pv("1.0.0-10")));
    try std.testing.expectEqual(std.math.Order.lt, compare(pv("1.0.0-1"), pv("1.0.0-a"))); // numeric < alnum
    try std.testing.expectEqual(std.math.Order.lt, compare(pv("1.0.0-a"), pv("1.0.0-b")));
    try std.testing.expectEqual(std.math.Order.lt, compare(pv("1.0.0-Z"), pv("1.0.0-a"))); // ASCII order
    // build metadata ignored
    try std.testing.expectEqual(std.math.Order.eq, compare(pv("1.0.0+a"), pv("1.0.0+b")));
    try std.testing.expectEqual(std.math.Order.eq, compare(pv("v1.0.0"), pv("1.0.0")));
}

test "parse validation" {
    const bad = [_][]const u8{ "01.2.3", "1.02.3", "1.2", "1.2.3.4", "1.2.3-", "1.2.3-01", "1.2.3-a..b", "1.2.3+", "a.b.c", "", "1.2.3-α", "1.2.x", "99999999999999999999.0.0" };
    for (bad) |b| try std.testing.expectError(error.Fail, parseVersion(b));
    const v = try parseVersion("1.2.3-alpha.1+build.5");
    try std.testing.expectEqualStrings("alpha.1", v.pre);
    try std.testing.expectEqualStrings("build.5", v.build);
    _ = try parseVersion("1.0.0-0.3.7");
    _ = try parseVersion("1.0.0-x-y-z.--");
    _ = try parseVersion("1.0.0+20130313144700");
}

fn sat(ver: []const u8, range: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sets = try parseRange(arena.allocator(), range);
    const v = try parseVersion(ver);
    for (sets) |s| if (setSatisfied(s, v, true)) return true;
    return false;
}

fn expectSat(range: []const u8, yes: []const []const u8, no: []const []const u8) !void {
    for (yes) |v| if (!(try sat(v, range))) {
        std.debug.print("expected {s} to satisfy {s}\n", .{ v, range });
        return error.ShouldSatisfy;
    };
    for (no) |v| if (try sat(v, range)) {
        std.debug.print("expected {s} NOT to satisfy {s}\n", .{ v, range });
        return error.ShouldNotSatisfy;
    };
}

test "caret ranges" {
    try expectSat("^1.2.3", &.{ "1.2.3", "1.2.4", "1.9.9" }, &.{ "1.2.2", "2.0.0", "0.9.0", "2.0.0-alpha", "1.3.0-beta" });
    try expectSat("^0.2.3", &.{ "0.2.3", "0.2.9" }, &.{ "0.3.0", "0.2.2", "1.0.0" });
    try expectSat("^0.0.3", &.{"0.0.3"}, &.{ "0.0.4", "0.0.2", "0.1.0" });
    try expectSat("^0.0", &.{ "0.0.0", "0.0.9" }, &.{ "0.1.0", "1.0.0" });
    try expectSat("^0", &.{ "0.0.0", "0.9.9" }, &.{ "1.0.0" });
    try expectSat("^1.2.x", &.{ "1.2.0", "1.9.0" }, &.{ "1.1.9", "2.0.0" });
    try expectSat("^1", &.{ "1.0.0", "1.9.9" }, &.{ "0.9.9", "2.0.0" });
    try expectSat("^1.2.3-beta.2", &.{ "1.2.3-beta.2", "1.2.3-beta.4", "1.2.3", "1.9.0" }, &.{ "1.2.3-beta.1", "1.2.4-beta.1", "2.0.0" });
}

test "tilde ranges" {
    try expectSat("~1.2.3", &.{ "1.2.3", "1.2.9" }, &.{ "1.3.0", "1.2.2" });
    try expectSat("~1.2", &.{ "1.2.0", "1.2.9" }, &.{ "1.3.0", "1.1.9" });
    try expectSat("~1", &.{ "1.0.0", "1.9.9" }, &.{ "2.0.0", "0.9.9" });
    try expectSat("~0.2.3", &.{ "0.2.3", "0.2.9" }, &.{ "0.3.0" });
    try expectSat("~> 1.2.3", &.{"1.2.5"}, &.{"1.3.0"});
}

test "comparators, x-ranges, wildcards" {
    try expectSat(">=1.2.7 <1.3.0", &.{ "1.2.7", "1.2.8" }, &.{ "1.2.6", "1.3.0" });
    try expectSat(">= 1.2.7  <  1.3.0", &.{"1.2.8"}, &.{"1.3.0"});
    try expectSat(">=1.2.7, <1.3.0", &.{"1.2.8"}, &.{"1.3.0"}); // cargo-style comma
    try expectSat("1.2.x", &.{ "1.2.0", "1.2.99" }, &.{ "1.3.0", "1.1.0" });
    try expectSat("1.2.*", &.{"1.2.5"}, &.{"1.3.0"});
    try expectSat("1.x", &.{ "1.0.0", "1.9.9" }, &.{ "2.0.0", "0.9.9" });
    try expectSat("1", &.{ "1.5.0" }, &.{"2.0.0"});
    try expectSat("*", &.{ "0.0.0", "99.0.0" }, &.{"1.0.0-alpha"});
    try expectSat("x", &.{"3.2.1"}, &.{});
    try expectSat("", &.{"3.2.1"}, &.{});
    try expectSat("1.2.3", &.{ "1.2.3", "1.2.3+meta" }, &.{ "1.2.4", "1.2.3-rc.1" }); // bare version is exact (npm)
    try expectSat("=1.2.3", &.{"1.2.3"}, &.{"1.2.4"});
    try expectSat("v1.2.3", &.{"1.2.3"}, &.{"1.2.4"});
    try expectSat(">1.2.3", &.{ "1.2.4", "2.0.0" }, &.{ "1.2.3", "1.2.3+b" });
    try expectSat("<=1.2.3", &.{ "1.2.3", "0.0.1" }, &.{"1.2.4"});
    try expectSat("<1.2.3", &.{ "1.2.2" }, &.{ "1.2.3" });
    try expectSat(">1.2", &.{ "1.3.0", "2.0.0" }, &.{ "1.2.9", "1.2.0" });
    try expectSat(">1", &.{ "2.0.0" }, &.{ "1.9.9" });
    try expectSat("<=1.2", &.{ "1.2.9", "1.0.0" }, &.{"1.3.0"});
    try expectSat("<=1", &.{ "1.9.9" }, &.{"2.0.0"});
    try expectSat("<1.2", &.{ "1.1.9" }, &.{ "1.2.0", "1.2.0-rc.1" });
    try expectSat(">=1.2", &.{ "1.2.0", "3.0.0" }, &.{"1.1.9"});
    try expectSat(">*", &.{}, &.{ "1.0.0", "0.0.1" });
}

test "hyphen ranges" {
    try expectSat("1.2.3 - 2.3.4", &.{ "1.2.3", "2.0.0", "2.3.4" }, &.{ "1.2.2", "2.3.5" });
    try expectSat("1.2 - 2.3.4", &.{ "1.2.0", "2.3.4" }, &.{ "1.1.9", "2.3.5" });
    try expectSat("1.2.3 - 2.3", &.{ "2.3.9", "1.2.3" }, &.{ "2.4.0" });
    try expectSat("1.2.3 - 2", &.{ "2.9.9" }, &.{ "3.0.0", "1.2.2" });
}

test "or ranges and prerelease rule" {
    try expectSat("^1.0.0 || ^3.0.0", &.{ "1.5.0", "3.1.0" }, &.{ "2.0.0", "0.9.0", "4.0.0" });
    try expectSat("<1.0.0 || >=2.0.0", &.{ "0.5.0", "2.0.0" }, &.{ "1.5.0" });
    try expectSat(">=1.0.0-alpha.1", &.{ "1.0.0-alpha.2", "1.0.0", "2.0.0" }, &.{ "1.0.0-alpha", "2.0.0-alpha" });
    try expectSat(">=1.0.0", &.{ "1.0.0" }, &.{ "1.0.1-beta", "2.0.0-rc.1" });
}

fn runOp(json: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    return handle(std.testing.allocator, parsed.value);
}

fn expectOp(json: []const u8, want: []const u8) !void {
    const got = try runOp(json);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "bump table (node-semver inc semantics)" {
    const cases = [_][3][]const u8{
        .{ "1.2.3", "major", "2.0.0" },
        .{ "1.2.3", "minor", "1.3.0" },
        .{ "1.2.3", "patch", "1.2.4" },
        .{ "1.2.3-beta.1", "patch", "1.2.3" },
        .{ "1.2.0-beta.1", "minor", "1.2.0" },
        .{ "1.0.0-beta.1", "major", "1.0.0" },
        .{ "1.2.3-beta.1", "major", "2.0.0" },
        .{ "1.2.3", "premajor", "2.0.0-0" },
        .{ "1.2.3", "preminor", "1.3.0-0" },
        .{ "1.2.3", "prepatch", "1.2.4-0" },
        .{ "1.2.3", "prerelease", "1.2.4-0" },
        .{ "1.2.4-0", "prerelease", "1.2.4-1" },
        .{ "1.2.4-beta.9", "prerelease", "1.2.4-beta.10" },
        .{ "1.2.4-beta", "prerelease", "1.2.4-beta.0" },
        .{ "1.2.3+build", "patch", "1.2.4" },
    };
    for (cases) |c| {
        const json = try std.fmt.allocPrint(std.testing.allocator, "{{\"op\":\"bump\",\"version\":\"{s}\",\"level\":\"{s}\"}}", .{ c[0], c[1] });
        defer std.testing.allocator.free(json);
        const got = try runOp(json);
        defer std.testing.allocator.free(got);
        const arrow = std.mem.indexOf(u8, got, " -> ").? + 4;
        if (!std.mem.eql(u8, c[2], got[arrow..])) {
            std.debug.print("bump {s} {s}: want {s} got {s}\n", .{ c[0], c[1], c[2], got[arrow..] });
            return error.Mismatch;
        }
    }
    try expectOp("{\"op\":\"bump\",\"version\":\"1.2.3\",\"level\":\"prerelease\",\"pre_id\":\"beta\"}", "1.2.3 -> 1.2.4-beta.0");
    try expectOp("{\"op\":\"bump\",\"version\":\"1.2.4-beta.0\",\"level\":\"prerelease\",\"pre_id\":\"beta\"}", "1.2.4-beta.0 -> 1.2.4-beta.1");
    try expectOp("{\"op\":\"bump\",\"version\":\"1.2.4-alpha.3\",\"level\":\"prerelease\",\"pre_id\":\"beta\"}", "1.2.4-alpha.3 -> 1.2.4-beta.0");
    try expectOp("{\"op\":\"bump\",\"version\":\"1.2.3\",\"level\":\"premajor\",\"pre_id\":\"rc\"}", "1.2.3 -> 2.0.0-rc.0");
    try std.testing.expectError(error.Fail, runOp("{\"op\":\"bump\",\"version\":\"1.2.3\",\"level\":\"huge\"}"));
}

test "ops: compare, satisfies, sort, parse" {
    try expectOp("{\"op\":\"compare\",\"version\":\"1.0.0-beta.2\",\"other\":\"1.0.0-beta.11\"}", "1.0.0-beta.2 < 1.0.0-beta.11 (semver.org precedence; build metadata ignored)");
    try expectOp("{\"op\":\"compare\",\"version\":\"1.0.0+a\",\"other\":\"1.0.0+b\"}", "1.0.0+a = 1.0.0+b (semver.org precedence; build metadata ignored)");
    try expectOp("{\"op\":\"satisfies\",\"version\":\"1.4.0\",\"range\":\"^1.2.3\"}", "1.4.0 satisfies ^1.2.3 (range: >=1.2.3 <2.0.0-0)");
    try expectOp("{\"op\":\"satisfies\",\"version\":\"2.0.0\",\"range\":\"~1.2 || >=3\"}", "2.0.0 does NOT satisfy ~1.2 || >=3 (range: >=1.2.0 <1.3.0-0 || >=3.0.0)");
    const g = try runOp("{\"op\":\"satisfies\",\"version\":\"1.3.0-beta\",\"range\":\"^1.2.3\"}");
    defer std.testing.allocator.free(g);
    try std.testing.expect(std.mem.indexOf(u8, g, "does NOT satisfy") != null and std.mem.indexOf(u8, g, "prerelease versions only match") != null);
    try expectOp("{\"op\":\"sort\",\"versions\":[\"1.0.0\",\"1.0.0-rc.1\",\"0.9.0\",\"1.10.0\",\"1.2.0\",\"1.0.0-alpha\"]}", "0.9.0\n1.0.0-alpha\n1.0.0-rc.1\n1.0.0\n1.2.0\n1.10.0");
    try expectOp("{\"op\":\"sort\",\"desc\":true,\"versions\":[\"1.0.0+b\",\"1.0.0+a\",\"2.0.0\"]}", "2.0.0\n1.0.0+b\n1.0.0+a"); // stable for equal precedence
    try expectOp("{\"op\":\"parse\",\"version\":\"v1.2.3-alpha.1+b.5\"}", "major=1 minor=2 patch=3 prerelease=alpha.1 build=b.5 normalized=1.2.3-alpha.1+b.5");
    try std.testing.expectError(error.Fail, runOp("{\"op\":\"sort\",\"versions\":[\"1.0.0\",\"nope\"]}"));
    try std.testing.expectError(error.Fail, runOp("{\"op\":\"frobnicate\"}"));
    try std.testing.expectError(error.Fail, runOp("{\"op\":\"satisfies\",\"version\":\"1.0.0\",\"range\":\">=\"}"));
}
