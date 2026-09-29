//! stats: descriptive statistics with numerically stable algorithms
//! (Neumaier compensated sum, Welford mean/variance, R-7 interpolated percentiles).

const std = @import("std");
const u = @import("util.zig");

pub const MAX_N = 100_000;

pub fn handle(a: std.mem.Allocator, args: std.json.Value) u.Err![]u8 {
    const arr = (try u.optArr(args, "numbers")) orelse return u.fail("missing 'numbers' array", .{});
    if (arr.len == 0) return u.fail("'numbers' is empty", .{});
    if (arr.len > MAX_N) return u.fail("too many numbers ({d}; max {d})", .{ arr.len, MAX_N });
    const xs = try a.alloc(f64, arr.len);
    defer a.free(xs);
    for (arr, 0..) |v, i| {
        var wbuf: [32]u8 = undefined;
        const what = std.fmt.bufPrint(&wbuf, "numbers[{d}]", .{i}) catch "number";
        xs[i] = try u.numOf(v, what);
    }
    return compute(a, xs);
}

fn lt(_: void, x: f64, y: f64) bool {
    return x < y;
}

/// Linear interpolation between closest ranks (numpy default / Excel PERCENTILE.INC).
pub fn percentile(sorted: []const f64, p: f64) f64 {
    if (sorted.len == 1) return sorted[0];
    const rank = p / 100.0 * @as(f64, @floatFromInt(sorted.len - 1));
    const lo: usize = @intFromFloat(@floor(rank));
    const hi = @min(lo + 1, sorted.len - 1);
    const frac = rank - @as(f64, @floatFromInt(lo));
    return sorted[lo] + (sorted[hi] - sorted[lo]) * frac;
}

pub fn compute(a: std.mem.Allocator, xs: []const f64) u.Err![]u8 {
    const n = xs.len;
    // Neumaier sum
    var sum: f64 = 0;
    var comp: f64 = 0;
    // Welford
    var mean: f64 = 0;
    var m2: f64 = 0;
    for (xs, 0..) |x, i| {
        const t = sum + x;
        if (@abs(sum) >= @abs(x)) comp += (sum - t) + x else comp += (x - t) + sum;
        sum = t;
        const d = x - mean;
        mean += d / @as(f64, @floatFromInt(i + 1));
        m2 += d * (x - mean);
    }
    sum += comp;
    if (!std.math.isFinite(sum) or !std.math.isFinite(m2)) return u.fail("overflow: values too large for double precision", .{});
    const sorted = try a.dupe(f64, xs);
    defer a.free(sorted);
    std.mem.sort(f64, sorted, {}, lt);

    // mode: longest runs of equal values
    var best: usize = 1;
    var i: usize = 0;
    while (i < n) {
        var j = i + 1;
        while (j < n and sorted[j] == sorted[i]) j += 1;
        best = @max(best, j - i);
        i = j;
    }

    var out: u.Out = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    const nf: f64 = @floatFromInt(n);
    try w.print("count={d} sum=", .{n});
    try u.fmtFloat(w, sum);
    try w.writeAll(" mean=");
    try u.fmtFloat(w, mean);
    try w.writeAll(" median=");
    try u.fmtFloat(w, percentile(sorted, 50));
    try w.writeAll(" mode=");
    if (best == 1) {
        try w.writeAll("none(all unique)");
    } else {
        var shown: usize = 0;
        i = 0;
        while (i < n) {
            var j = i + 1;
            while (j < n and sorted[j] == sorted[i]) j += 1;
            if (j - i == best) {
                if (shown > 0) try w.writeByte(',');
                if (shown == 5) {
                    try w.writeAll("...");
                    break;
                }
                try u.fmtFloat(w, sorted[i]);
                shown += 1;
            }
            i = j;
        }
        try w.print("(x{d})", .{best});
    }
    try w.writeAll(" min=");
    try u.fmtFloat(w, sorted[0]);
    try w.writeAll(" max=");
    try u.fmtFloat(w, sorted[n - 1]);
    const pop_var = m2 / nf;
    try w.writeAll(" var_pop=");
    try u.fmtFloat(w, pop_var);
    try w.writeAll(" sd_pop=");
    try u.fmtFloat(w, @sqrt(pop_var));
    if (n > 1) {
        const sv = m2 / (nf - 1);
        try w.writeAll(" var_sample=");
        try u.fmtFloat(w, sv);
        try w.writeAll(" sd_sample=");
        try u.fmtFloat(w, @sqrt(sv));
    } else try w.writeAll(" var_sample=n/a sd_sample=n/a");
    inline for (.{ 50.0, 90.0, 99.0 }) |p| {
        try w.print(" p{d:.0}=", .{p});
        try u.fmtFloat(w, percentile(sorted, p));
    }
    return out.toOwnedSlice();
}

// ------------------------------------------------------------------- tests

fn expectStats(xs: []const f64, want: []const u8) !void {
    const got = try compute(std.testing.allocator, xs);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "basic set" {
    try expectStats(&.{ 1, 2, 3, 4, 5 }, "count=5 sum=15 mean=3 median=3 mode=none(all unique) min=1 max=5 var_pop=2 sd_pop=1.41421356237 var_sample=2.5 sd_sample=1.58113883008 p50=3 p90=4.6 p99=4.96");
}

test "even count median, modes, unsorted input" {
    try expectStats(&.{ 4, 1, 3, 2 }, "count=4 sum=10 mean=2.5 median=2.5 mode=none(all unique) min=1 max=4 var_pop=1.25 sd_pop=1.11803398875 var_sample=1.66666666667 sd_sample=1.29099444874 p50=2.5 p90=3.7 p99=3.97");
    const got = try compute(std.testing.allocator, &.{ 2, 7, 2, 7, 9 });
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "mode=2,7(x2)") != null);
}

test "single value and constants" {
    try expectStats(&.{42}, "count=1 sum=42 mean=42 median=42 mode=none(all unique) min=42 max=42 var_pop=0 sd_pop=0 var_sample=n/a sd_sample=n/a p50=42 p90=42 p99=42");
}

test "numerical stability: large offset and cancelling sums" {
    // naive sum of squares would lose everything here; Welford keeps variance = 2.5 exactly enough
    const base: f64 = 1e9;
    const got = try compute(std.testing.allocator, &.{ base + 1, base + 2, base + 3, base + 4, base + 5 });
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "var_sample=2.5 ") != null);
    // Neumaier: 1e16 + 1 + -1e16 = 1 (naive summation gives 0)
    const s = try compute(std.testing.allocator, &.{ 1e16, 1, -1e16 });
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "sum=1 ") != null);
    // 0.1 ten times sums to 1 (naive gives 0.9999999999999999)
    const ten = try compute(std.testing.allocator, &(.{0.1} ** 10));
    defer std.testing.allocator.free(ten);
    try std.testing.expect(std.mem.indexOf(u8, ten, "sum=1 ") != null);
}

test "percentile interpolation matches numpy" {
    const xs = [_]f64{ 15, 20, 35, 40, 50 };
    try std.testing.expectApproxEqAbs(@as(f64, 29), percentile(&xs, 40), 1e-12); // numpy.percentile([15,20,35,40,50],40)=29.0
    try std.testing.expectApproxEqAbs(@as(f64, 50), percentile(&xs, 100), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 15), percentile(&xs, 0), 1e-12);
}

test "handle validates input" {
    const a = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"numbers\":[1,\"2\",3.5]}", .{});
    defer parsed.deinit();
    const got = try handle(a, parsed.value);
    defer a.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "count=3 sum=6.5"));
    const bad = try std.json.parseFromSlice(std.json.Value, a, "{\"numbers\":[1,\"x\"]}", .{});
    defer bad.deinit();
    try std.testing.expectError(error.Fail, handle(a, bad.value));
    const empty = try std.json.parseFromSlice(std.json.Value, a, "{\"numbers\":[]}", .{});
    defer empty.deinit();
    try std.testing.expectError(error.Fail, handle(a, empty.value));
}
