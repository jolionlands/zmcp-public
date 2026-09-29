//! base_convert: arbitrary-size non-negative integers (<= 2048 bits) between bases 2..36.

const std = @import("std");
const u = @import("util.zig");

pub const MAX_BITS = 2048;
const LIMBS = MAX_BITS / 32;

const Big = struct {
    limbs: [LIMBS]u32 = [_]u32{0} ** LIMBS,
    len: usize = 0, // used limbs

    fn mulAdd(self: *Big, m: u32, add: u32) bool {
        var carry: u64 = add;
        for (self.limbs[0..self.len]) |*l| {
            const t = @as(u64, l.*) * m + carry;
            l.* = @truncate(t);
            carry = t >> 32;
        }
        if (carry != 0) {
            if (self.len == LIMBS) return false;
            self.limbs[self.len] = @intCast(carry);
            self.len += 1;
        }
        return true;
    }

    fn divSmall(self: *Big, d: u32) u32 {
        var rem: u64 = 0;
        var i = self.len;
        while (i > 0) {
            i -= 1;
            const cur = (rem << 32) | self.limbs[i];
            self.limbs[i] = @intCast(cur / d);
            rem = cur % d;
        }
        while (self.len > 0 and self.limbs[self.len - 1] == 0) self.len -= 1;
        return @intCast(rem);
    }

    fn bitLen(self: Big) usize {
        if (self.len == 0) return 0;
        return self.len * 32 - @clz(self.limbs[self.len - 1]);
    }
};

pub fn handle(a: std.mem.Allocator, args: std.json.Value) u.Err![]u8 {
    const o = try u.obj(args);
    const v = o.get("value") orelse return u.fail("missing 'value'", .{});
    var numbuf: [32]u8 = undefined;
    const text: []const u8 = switch (v) {
        .string => |s| s,
        .integer => |i| std.fmt.bufPrint(&numbuf, "{d}", .{i}) catch unreachable,
        else => return u.fail("'value' must be a string of digits (or an integer)", .{}),
    };
    const fb = (try u.optInt(args, "from_base")) orelse return u.fail("missing 'from_base'", .{});
    const tb = (try u.optInt(args, "to_base")) orelse return u.fail("missing 'to_base'", .{});
    if (fb < 2 or fb > 36 or tb < 2 or tb > 36) return u.fail("bases must be in 2..36", .{});
    return convert(a, text, @intCast(fb), @intCast(tb));
}

pub fn convert(a: std.mem.Allocator, text_in: []const u8, from: u8, to: u8) u.Err![]u8 {
    var text = std.mem.trim(u8, text_in, " \t\r\n");
    if (text.len == 0) return u.fail("empty value", .{});
    if (text[0] == '-') return u.fail("negative numbers are not supported (non-negative integers only)", .{});
    if (text[0] == '+') text = text[1..];
    if (text.len > 2 and text[0] == '0') {
        const want: ?u8 = switch (text[1]) {
            'x', 'X' => 16,
            'b', 'B' => 2,
            'o', 'O' => 8,
            else => null,
        };
        if (want) |wb| {
            if (from == wb) {
                text = text[2..];
            } else {
                // 'b'/'x'/'o' can be genuine digits in high bases ("0b1" in base 16)
                const pd: u8 = switch (text[1]) {
                    'a'...'z' => text[1] - 'a' + 10,
                    'A'...'Z' => text[1] - 'A' + 10,
                    else => 255,
                };
                if (pd >= from) return u.fail("prefix '{c}{c}' conflicts with from_base {d}", .{ text[0], text[1], from });
            }
        }
    }
    if (text.len == 0) return u.fail("no digits after prefix", .{});
    var big: Big = .{};
    for (text, 0..) |c, i| {
        const dv: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'z' => c - 'a' + 10,
            'A'...'Z' => c - 'A' + 10,
            '_', ' ', ',' => return u.fail("separator '{c}' at position {d} is not allowed; give bare digits", .{ c, i }),
            else => return u.fail("invalid character '{c}' at position {d}", .{ c, i }),
        };
        if (dv >= from) return u.fail("digit '{c}' at position {d} is not valid in base {d}", .{ c, i, from });
        if (!big.mulAdd(from, dv)) return u.fail("value exceeds {d} bits", .{MAX_BITS});
    }
    if (big.bitLen() > MAX_BITS) return u.fail("value exceeds {d} bits", .{MAX_BITS});
    const bits = big.bitLen();
    var digits: std.ArrayList(u8) = .empty;
    defer digits.deinit(a);
    if (big.len == 0) try digits.append(a, '0');
    var work = big;
    while (work.len > 0) {
        const r = work.divSmall(to);
        try digits.append(a, "0123456789abcdefghijklmnopqrstuvwxyz"[r]);
    }
    std.mem.reverse(u8, digits.items);
    return std.fmt.allocPrint(a, "{s} (base {d}, {d} bits) = {s} (base {d})", .{ std.mem.trimStart(u8, text, "0"), from, bits, digits.items, to }) catch return error.OutOfMemory;
}

// ------------------------------------------------------------------- tests

fn expectConv(v: []const u8, from: u8, to: u8, want: []const u8) !void {
    const got = try convert(std.testing.allocator, v, from, to);
    defer std.testing.allocator.free(got);
    const idx = std.mem.lastIndexOf(u8, got, " = ").?;
    const end = std.mem.lastIndexOf(u8, got, " (base").?;
    try std.testing.expectEqualStrings(want, got[idx + 3 .. end]);
}

fn expectErr(v: []const u8, from: u8, to: u8, needle: []const u8) !void {
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

test "small conversions" {
    try expectConv("255", 10, 16, "ff");
    try expectConv("ff", 16, 2, "11111111");
    try expectConv("FF", 16, 10, "255");
    try expectConv("0", 10, 2, "0");
    try expectConv("000", 10, 16, "0");
    try expectConv("zz", 36, 10, "1295");
    try expectConv("1295", 10, 36, "zz");
    try expectConv("777", 8, 10, "511");
    try expectConv("0xff", 16, 10, "255");
    try expectConv("0b101", 2, 10, "5");
    try expectConv("0o17", 8, 10, "15");
    try expectConv("4294967296", 10, 16, "100000000"); // 2^32 limb boundary
    try expectConv("18446744073709551615", 10, 16, "ffffffffffffffff");
}

test "big numbers" {
    try expectConv("1606938044258990275541962092341162602522202993782792835301376", 10, 16, "1" ++ "0" ** 50); // 2^200
    try expectConv("1" ++ "0" ** 50, 16, 10, "1606938044258990275541962092341162602522202993782792835301376");
    try expectConv("1" ++ "0" ** 2047, 2, 16, "8" ++ "0" ** 511); // 2^2047
    try expectConv("f" ** 512, 16, 2, "1" ** 2048); // 2^2048 - 1 is the max
    // 2^2048 - 1 in decimal round trips
    const dec = try convert(std.testing.allocator, "f" ** 512, 16, 10);
    defer std.testing.allocator.free(dec);
    const s = std.mem.indexOf(u8, dec, " = ").? + 3;
    const e = std.mem.lastIndexOf(u8, dec, " (base").?;
    try expectConv(dec[s..e], 10, 16, "f" ** 512);
    try expectConv("123456789012345678901234567890123456789", 10, 36, "5hy8cqpp6qj5vz0m8iov0uej9");
}

test "limits and errors" {
    try expectErr("1" ++ "0" ** 2048, 2, 16, "exceeds 2048 bits"); // 2^2048
    try expectErr("1" ++ "0" ** 512, 16, 10, "exceeds 2048 bits");
    try expectErr("-5", 10, 2, "negative");
    try expectErr("9", 8, 2, "not valid in base 8");
    try expectErr("1_000", 10, 2, "separator");
    try expectErr("1,000", 10, 2, "separator");
    try expectErr("", 10, 2, "empty");
    try expectErr("0xff", 10, 2, "conflicts");
    try expectErr("1.5", 10, 2, "invalid character");
}
