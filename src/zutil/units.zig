//! units: conversion over a compact table. base = (value + offset) * factor.

const std = @import("std");
const u = @import("util.zig");

const Dim = enum { length, mass, volume, temperature, time, data, speed, area, energy, pressure };

const Unit = struct { names: []const u8, dim: Dim, factor: f64, offset: f64 = 0 };

// First name is the canonical (displayed) one. Matching: exact case, then
// case-insensitive if unique, then a trailing "s"/"es" is stripped.
// Base units: m, kg, L, K, s, byte, m/s, m2, J, Pa.
const table = [_]Unit{
    // length
    .{ .names = "m|meter|metre", .dim = .length, .factor = 1 },
    .{ .names = "km|kilometer|kilometre", .dim = .length, .factor = 1000 },
    .{ .names = "cm|centimeter|centimetre", .dim = .length, .factor = 0.01 },
    .{ .names = "mm|millimeter|millimetre", .dim = .length, .factor = 0.001 },
    .{ .names = "um|µm|micron|micrometer", .dim = .length, .factor = 1e-6 },
    .{ .names = "nm|nanometer|nanometre", .dim = .length, .factor = 1e-9 },
    .{ .names = "in|inch|inche", .dim = .length, .factor = 0.0254 },
    .{ .names = "ft|foot|feet", .dim = .length, .factor = 0.3048 },
    .{ .names = "yd|yard", .dim = .length, .factor = 0.9144 },
    .{ .names = "mi|mile", .dim = .length, .factor = 1609.344 },
    .{ .names = "nmi|nauticalmile", .dim = .length, .factor = 1852 },
    .{ .names = "au", .dim = .length, .factor = 149597870700 },
    .{ .names = "ly|lightyear", .dim = .length, .factor = 9460730472580800 },
    // mass
    .{ .names = "kg|kilogram", .dim = .mass, .factor = 1 },
    .{ .names = "g|gram", .dim = .mass, .factor = 0.001 },
    .{ .names = "mg|milligram", .dim = .mass, .factor = 1e-6 },
    .{ .names = "ug|µg|microgram", .dim = .mass, .factor = 1e-9 },
    .{ .names = "t|tonne|metric_ton", .dim = .mass, .factor = 1000 },
    .{ .names = "lb|lbs|pound", .dim = .mass, .factor = 0.45359237 },
    .{ .names = "oz|ounce", .dim = .mass, .factor = 0.028349523125 },
    .{ .names = "st|stone", .dim = .mass, .factor = 6.35029318 },
    .{ .names = "short_ton|us_ton", .dim = .mass, .factor = 907.18474 },
    .{ .names = "long_ton|uk_ton", .dim = .mass, .factor = 1016.0469088 },
    // volume (US customary unless imp_ prefix)
    .{ .names = "l|L|liter|litre", .dim = .volume, .factor = 1 },
    .{ .names = "ml|mL|milliliter|millilitre", .dim = .volume, .factor = 0.001 },
    .{ .names = "cl|cL|centiliter", .dim = .volume, .factor = 0.01 },
    .{ .names = "dl|dL|deciliter", .dim = .volume, .factor = 0.1 },
    .{ .names = "m3|m^3|cubic_meter", .dim = .volume, .factor = 1000 },
    .{ .names = "cm3|cm^3|cc", .dim = .volume, .factor = 0.001 },
    .{ .names = "in3|in^3", .dim = .volume, .factor = 0.016387064 },
    .{ .names = "ft3|ft^3", .dim = .volume, .factor = 28.316846592 },
    .{ .names = "gal|gallon", .dim = .volume, .factor = 3.785411784 },
    .{ .names = "qt|quart", .dim = .volume, .factor = 0.946352946 },
    .{ .names = "pt|pint", .dim = .volume, .factor = 0.473176473 },
    .{ .names = "cup", .dim = .volume, .factor = 0.2365882365 },
    .{ .names = "floz|fl_oz", .dim = .volume, .factor = 0.0295735295625 },
    .{ .names = "tbsp|tablespoon", .dim = .volume, .factor = 0.01478676478125 },
    .{ .names = "tsp|teaspoon", .dim = .volume, .factor = 0.00492892159375 },
    .{ .names = "imp_gal", .dim = .volume, .factor = 4.54609 },
    .{ .names = "imp_pt", .dim = .volume, .factor = 0.56826125 },
    .{ .names = "imp_floz", .dim = .volume, .factor = 0.0284130625 },
    // temperature: base K
    .{ .names = "c|°c|degc|celsius", .dim = .temperature, .factor = 1, .offset = 273.15 },
    .{ .names = "f|°f|degf|fahrenheit", .dim = .temperature, .factor = 5.0 / 9.0, .offset = 459.67 },
    .{ .names = "k|kelvin", .dim = .temperature, .factor = 1 },
    .{ .names = "r|rankine", .dim = .temperature, .factor = 5.0 / 9.0 },
    // time
    .{ .names = "s|sec|second", .dim = .time, .factor = 1 },
    .{ .names = "ms|millisecond", .dim = .time, .factor = 1e-3 },
    .{ .names = "us|µs|microsecond", .dim = .time, .factor = 1e-6 },
    .{ .names = "ns|nanosecond", .dim = .time, .factor = 1e-9 },
    .{ .names = "min|minute", .dim = .time, .factor = 60 },
    .{ .names = "h|hr|hour", .dim = .time, .factor = 3600 },
    .{ .names = "d|day", .dim = .time, .factor = 86400 },
    .{ .names = "wk|week", .dim = .time, .factor = 604800 },
    .{ .names = "yr|year", .dim = .time, .factor = 31557600 }, // Julian year, 365.25 d
    // data: SI (1000) vs IEC (1024); B = byte, b = bit
    .{ .names = "B|byte", .dim = .data, .factor = 1 },
    .{ .names = "b|bit", .dim = .data, .factor = 0.125 },
    .{ .names = "kB|KB", .dim = .data, .factor = 1e3 },
    .{ .names = "MB", .dim = .data, .factor = 1e6 },
    .{ .names = "GB", .dim = .data, .factor = 1e9 },
    .{ .names = "TB", .dim = .data, .factor = 1e12 },
    .{ .names = "PB", .dim = .data, .factor = 1e15 },
    .{ .names = "EB", .dim = .data, .factor = 1e18 },
    .{ .names = "KiB|kibibyte", .dim = .data, .factor = 1024 },
    .{ .names = "MiB|mebibyte", .dim = .data, .factor = 1048576 },
    .{ .names = "GiB|gibibyte", .dim = .data, .factor = 1073741824 },
    .{ .names = "TiB|tebibyte", .dim = .data, .factor = 1099511627776 },
    .{ .names = "PiB|pebibyte", .dim = .data, .factor = 1125899906842624 },
    .{ .names = "EiB|exbibyte", .dim = .data, .factor = 1152921504606846976 },
    .{ .names = "kb|Kb|kbit", .dim = .data, .factor = 125 },
    .{ .names = "Mb|Mbit", .dim = .data, .factor = 125000 },
    .{ .names = "Gb|Gbit", .dim = .data, .factor = 125000000 },
    .{ .names = "Tb|Tbit", .dim = .data, .factor = 125000000000 },
    .{ .names = "Kibit", .dim = .data, .factor = 128 },
    .{ .names = "Mibit", .dim = .data, .factor = 131072 },
    .{ .names = "Gibit", .dim = .data, .factor = 134217728 },
    // speed
    .{ .names = "m/s|mps", .dim = .speed, .factor = 1 },
    .{ .names = "km/h|kph|kmh|kmph", .dim = .speed, .factor = 1.0 / 3.6 },
    .{ .names = "mph|mi/h", .dim = .speed, .factor = 0.44704 },
    .{ .names = "kn|kt|knot", .dim = .speed, .factor = 1852.0 / 3600.0 },
    .{ .names = "ft/s|fps", .dim = .speed, .factor = 0.3048 },
    // area
    .{ .names = "m2|m^2|sqm", .dim = .area, .factor = 1 },
    .{ .names = "km2|km^2|sqkm", .dim = .area, .factor = 1e6 },
    .{ .names = "cm2|cm^2|sqcm", .dim = .area, .factor = 1e-4 },
    .{ .names = "mm2|mm^2", .dim = .area, .factor = 1e-6 },
    .{ .names = "ha|hectare", .dim = .area, .factor = 1e4 },
    .{ .names = "acre", .dim = .area, .factor = 4046.8564224 },
    .{ .names = "ft2|ft^2|sqft", .dim = .area, .factor = 0.09290304 },
    .{ .names = "in2|in^2|sqin", .dim = .area, .factor = 0.00064516 },
    .{ .names = "yd2|yd^2|sqyd", .dim = .area, .factor = 0.83612736 },
    .{ .names = "mi2|mi^2|sqmi", .dim = .area, .factor = 2589988.110336 },
    // energy
    .{ .names = "J|joule", .dim = .energy, .factor = 1 },
    .{ .names = "kJ|kilojoule", .dim = .energy, .factor = 1e3 },
    .{ .names = "MJ|megajoule", .dim = .energy, .factor = 1e6 },
    .{ .names = "mJ|millijoule", .dim = .energy, .factor = 1e-3 },
    .{ .names = "cal|calorie", .dim = .energy, .factor = 4.184 }, // thermochemical
    .{ .names = "kcal|kilocalorie", .dim = .energy, .factor = 4184 },
    .{ .names = "Wh", .dim = .energy, .factor = 3600 },
    .{ .names = "kWh", .dim = .energy, .factor = 3.6e6 },
    .{ .names = "eV", .dim = .energy, .factor = 1.602176634e-19 },
    .{ .names = "BTU|btu", .dim = .energy, .factor = 1055.05585262 }, // IT
    .{ .names = "ftlbf|ft-lbf", .dim = .energy, .factor = 1.3558179483314004 },
    // pressure
    .{ .names = "Pa|pascal", .dim = .pressure, .factor = 1 },
    .{ .names = "hPa", .dim = .pressure, .factor = 100 },
    .{ .names = "kPa", .dim = .pressure, .factor = 1e3 },
    .{ .names = "MPa", .dim = .pressure, .factor = 1e6 },
    .{ .names = "bar", .dim = .pressure, .factor = 1e5 },
    .{ .names = "mbar", .dim = .pressure, .factor = 100 },
    .{ .names = "atm", .dim = .pressure, .factor = 101325 },
    .{ .names = "psi", .dim = .pressure, .factor = 6894.757293168361 },
    .{ .names = "mmHg", .dim = .pressure, .factor = 133.322387415 },
    .{ .names = "torr", .dim = .pressure, .factor = 101325.0 / 760.0 },
    .{ .names = "inHg", .dim = .pressure, .factor = 3386.389 },
};

fn canonical(un: *const Unit) []const u8 {
    const i = std.mem.indexOfScalar(u8, un.names, '|') orelse un.names.len;
    return un.names[0..i];
}

fn hasName(un: *const Unit, name: []const u8, ci: bool) bool {
    var it = std.mem.splitScalar(u8, un.names, '|');
    while (it.next()) |n| {
        if (ci) {
            if (std.ascii.eqlIgnoreCase(n, name)) return true;
        } else if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

const Lookup = union(enum) { found: *const Unit, ambiguous: [2]*const Unit, none };

fn lookupOne(name: []const u8) Lookup {
    for (&table) |*t| if (hasName(t, name, false)) return .{ .found = t };
    var first: ?*const Unit = null;
    for (&table) |*t| if (hasName(t, name, true)) {
        if (first) |f| {
            if (f != t) return .{ .ambiguous = .{ f, t } };
        } else first = t;
    };
    if (first) |f| return .{ .found = f };
    return .none;
}

fn lookup(name_in: []const u8) Lookup {
    const name = std.mem.trim(u8, name_in, " ");
    const r = lookupOne(name);
    if (r != .none) return r;
    if (name.len > 2 and (name[name.len - 1] == 's' or name[name.len - 1] == 'S')) {
        const r2 = lookupOne(name[0 .. name.len - 1]);
        if (r2 != .none) return r2;
    }
    if (name.len > 3 and std.ascii.endsWithIgnoreCase(name, "es")) return lookupOne(name[0 .. name.len - 2]);
    return .none;
}

fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len > 24 or b.len > 24) return 99;
    var prev: [25]usize = undefined;
    var cur: [25]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ca, i| {
        cur[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (std.ascii.toLower(ca) == std.ascii.toLower(cb)) 0 else 1;
            cur[j + 1] = @min(@min(cur[j] + 1, prev[j + 1] + 1), prev[j] + cost);
        }
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return prev[b.len];
}

fn unknownUnit(w: *std.Io.Writer, name: []const u8) !void {
    try w.print("unknown unit '{s}'. ", .{name});
    var found: usize = 0;
    var shown: [5]*const Unit = undefined;
    const maxd: usize = if (name.len <= 2) 1 else 2;
    var d: usize = 0;
    while (d <= maxd and found < 5) : (d += 1) {
        for (&table) |*t| {
            var it = std.mem.splitScalar(u8, t.names, '|');
            while (it.next()) |n| {
                const dist = editDistance(name, n);
                const sub = name.len >= 3 and n.len >= 3 and (std.ascii.startsWithIgnoreCase(n, name) or std.ascii.startsWithIgnoreCase(name, n));
                if ((dist == d) or (d == 0 and sub)) {
                    var dup = false;
                    for (shown[0..found]) |s| if (s == t) {
                        dup = true;
                    };
                    if (!dup and found < 5) {
                        shown[found] = t;
                        found += 1;
                    }
                    break;
                }
            }
        }
    }
    if (found > 0) {
        try w.writeAll("Did you mean: ");
        for (shown[0..found], 0..) |t, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("{s} ({s})", .{ canonical(t), @tagName(t.dim) });
        }
        try w.writeAll(".");
    } else {
        try w.writeAll("Dimensions: length mass volume temperature time data speed area energy pressure (e.g. km, lb, ml, c/f/k, min, MiB/GB, mph, ha, kWh, psi).");
    }
}

pub fn handle(a: std.mem.Allocator, args: std.json.Value) u.Err![]u8 {
    const o = try u.obj(args);
    const v = o.get("value") orelse return u.fail("missing 'value'", .{});
    const x = try u.numOf(v, "value");
    return convert(a, x, try u.reqStr(args, "from"), try u.reqStr(args, "to"));
}

fn resolve(a: std.mem.Allocator, name: []const u8) u.Err!*const Unit {
    switch (lookup(name)) {
        .found => |t| return t,
        .ambiguous => |p| return u.fail("ambiguous unit '{s}': could be {s} or {s}; use exact case (e.g. MB megabyte vs Mb megabit)", .{ name, canonical(p[0]), canonical(p[1]) }),
        .none => {
            var out: u.Out = .init(a);
            defer out.deinit();
            try unknownUnit(&out.writer, name);
            return u.fail("{s}", .{out.written()});
        },
    }
}

pub fn convert(a: std.mem.Allocator, value: f64, from: []const u8, to: []const u8) u.Err![]u8 {
    const f = try resolve(a, from);
    const t = try resolve(a, to);
    if (f.dim != t.dim) return u.fail("cannot convert {s} ({s}) to {s} ({s}): different dimensions", .{ canonical(f), @tagName(f.dim), canonical(t), @tagName(t.dim) });
    const base = (value + f.offset) * f.factor;
    if (f.dim == .temperature and base < -1e-9) return u.fail("{d} {s} is below absolute zero", .{ value, canonical(f) });
    const result = base / t.factor - t.offset;
    var out: u.Out = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    try u.fmtFloat(w, value);
    try w.print(" {s} = ", .{canonical(f)});
    // avoid "-0"
    const r = if (@abs(result) < 1e-12 * @max(1.0, @abs(value))) 0.0 else result;
    try u.fmtFloat(w, r);
    try w.print(" {s}", .{canonical(t)});
    return out.toOwnedSlice();
}

// ------------------------------------------------------------------- tests

fn expectConv(v: f64, from: []const u8, to: []const u8, want: []const u8) !void {
    const got = try convert(std.testing.allocator, v, from, to);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}

fn expectConvErr(v: f64, from: []const u8, to: []const u8, needle: []const u8) !void {
    if (convert(std.testing.allocator, v, from, to)) |got| {
        std.testing.allocator.free(got);
        return error.ExpectedFailure;
    } else |e| {
        try std.testing.expect(e == error.Fail);
        if (std.mem.indexOf(u8, u.lastError(), needle) == null) {
            std.debug.print("error '{s}' lacks '{s}'\n", .{ u.lastError(), needle });
            return error.WrongError;
        }
    }
}

test "length mass volume" {
    try expectConv(1.5, "km", "m", "1.5 km = 1500 m");
    try expectConv(1, "mi", "km", "1 mi = 1.609344 km");
    try expectConv(12, "inches", "ft", "12 in = 1 ft");
    try expectConv(6, "feet", "in", "6 ft = 72 in");
    try expectConv(1, "lb", "oz", "1 lb = 16 oz");
    try expectConv(1, "kg", "lb", "1 kg = 2.20462262185 lb");
    try expectConv(1, "gal", "L", "1 gal = 3.785411784 l");
    try expectConv(1, "cup", "tbsp", "1 cup = 16 tbsp");
    try expectConv(1, "m3", "l", "1 m3 = 1000 l");
}

test "temperature with offsets" {
    try expectConv(100, "c", "f", "100 c = 212 f");
    try expectConv(-40, "C", "F", "-40 c = -40 f");
    try expectConv(32, "f", "c", "32 f = 0 c");
    try expectConv(0, "k", "c", "0 k = -273.15 c");
    try expectConv(0, "c", "k", "0 c = 273.15 k");
    try expectConv(98.6, "f", "c", "98.6 f = 37 c");
    try expectConv(0, "c", "r", "0 c = 491.67 r");
    try expectConvErr(-300, "c", "f", "below absolute zero");
    try expectConvErr(-1, "k", "c", "below absolute zero");
}

test "time data speed area energy pressure" {
    try expectConv(2, "h", "min", "2 h = 120 min");
    try expectConv(1, "yr", "d", "1 yr = 365.25 d");
    try expectConv(1, "GiB", "MiB", "1 GiB = 1024 MiB");
    try expectConv(1, "GB", "GiB", "1 GB = 0.931322574615 GiB");
    try expectConv(1, "MB", "Mb", "1 MB = 8 Mb");
    try expectConv(1, "TB", "TiB", "1 TB = 0.909494701773 TiB");
    try expectConv(8, "b", "B", "8 b = 1 B");
    try expectConv(60, "mph", "km/h", "60 mph = 96.56064 km/h");
    try expectConv(1, "kn", "km/h", "1 kn = 1.852 km/h");
    try expectConv(1, "ha", "m2", "1 ha = 10000 m2");
    try expectConv(1, "acre", "m2", "1 acre = 4046.8564224 m2");
    try expectConv(1, "kWh", "MJ", "1 kWh = 3.6 MJ");
    try expectConv(1, "kcal", "kJ", "1 kcal = 4.184 kJ");
    try expectConv(1, "atm", "kPa", "1 atm = 101.325 kPa");
    try expectConv(1, "bar", "psi", "1 bar = 14.503773773 psi");
    try expectConv(1, "atm", "torr", "1 atm = 760 torr");
}

test "round trips" {
    const pairs = [_][2][]const u8{ .{ "mi", "km" }, .{ "lb", "kg" }, .{ "f", "c" }, .{ "GiB", "GB" }, .{ "psi", "Pa" }, .{ "kn", "mph" }, .{ "acre", "ha" }, .{ "imp_gal", "gal" } };
    for (pairs) |p| {
        const there = try convert(std.testing.allocator, 123.456, p[0], p[1]);
        defer std.testing.allocator.free(there);
        // parse "<v> a = <r> b"
        const eq = std.mem.indexOf(u8, there, " = ").?;
        const rest = there[eq + 3 ..];
        const sp = std.mem.indexOfScalar(u8, rest, ' ').?;
        const mid = try std.fmt.parseFloat(f64, rest[0..sp]);
        const back = try convert(std.testing.allocator, mid, p[1], p[0]);
        defer std.testing.allocator.free(back);
        const eq2 = std.mem.indexOf(u8, back, " = ").?;
        const sp2 = std.mem.lastIndexOfScalar(u8, back, ' ').?;
        const r = try std.fmt.parseFloat(f64, back[eq2 + 3 .. sp2]);
        try std.testing.expectApproxEqRel(@as(f64, 123.456), r, 1e-9);
    }
}

test "errors: unknown, ambiguous, dimension mismatch" {
    try expectConvErr(1, "metrs", "ft", "Did you mean: m (length)");
    try expectConvErr(1, "kilomter", "ft", "km (length)");
    try expectConvErr(1, "m", "zzzzzz", "Dimensions:");
    try expectConvErr(1, "mb", "kb", "ambiguous unit 'mb'");
    try expectConvErr(1, "kg", "m", "different dimensions");
    try expectConvErr(1, "c", "kb", "different dimensions");
}

test "case-insensitive fallback and exact-case priority" {
    try expectConv(1, "KM", "M", "1 km = 1000 m");
    try expectConv(1, "GIB", "mib", "1 GiB = 1024 MiB");
    try expectConv(1, "Mb", "kb", "1 Mb = 1000 kb"); // exact case: megabit vs kilobit
    try expectConv(1, "MB", "kB", "1 MB = 1000 kB");
}
