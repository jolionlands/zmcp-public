//! calc: safe Pratt-parser evaluator. Decimal literals are exact rationals over
//! i128, so 0.1+0.2 = 3/10 exactly; functions like sin/ln return f64. Integer
//! overflow past i128 degrades to f64 and is reported as approximate.

const std = @import("std");
const u = @import("util.zig");

pub const MAX_LEN = 1000;
pub const MAX_DEPTH = 64;
const I = i128;

const Rat = struct { n: I, d: I };
pub const Value = union(enum) { rat: Rat, float: f64 };

const Tk = enum { num, ident, plus, minus, star, slash, percent, caret, lparen, rparen, comma, eof };
const Token = struct { kind: Tk, pos: usize, val: Value = .{ .float = 0 }, text: []const u8 = "" };

fn gcdU(a: u128, b: u128) u128 {
    var x = a;
    var y = b;
    while (y != 0) {
        const t = x % y;
        x = y;
        y = t;
    }
    return x;
}

fn norm(n_in: I, d_in: I) ?Rat {
    if (n_in == std.math.minInt(I) or d_in == std.math.minInt(I)) return null;
    var n = n_in;
    var d = d_in;
    if (d < 0) {
        n = -n;
        d = -d;
    }
    const g = gcdU(@abs(n), @abs(d));
    if (g > 1) {
        n = @divExact(n, @as(I, @intCast(g)));
        d = @divExact(d, @as(I, @intCast(g)));
    }
    return .{ .n = n, .d = d };
}

fn mulC(a: I, b: I) ?I {
    return std.math.mul(I, a, b) catch null;
}
fn addC(a: I, b: I) ?I {
    return std.math.add(I, a, b) catch null;
}
fn subC(a: I, b: I) ?I {
    return std.math.sub(I, a, b) catch null;
}

fn ratAdd(a: Rat, b: Rat, sub: bool) ?Rat {
    const g: I = @intCast(gcdU(@intCast(a.d), @intCast(b.d)));
    const bd = @divExact(b.d, g);
    const ad = @divExact(a.d, g);
    const den = mulC(a.d, bd) orelse return null;
    const x = mulC(a.n, bd) orelse return null;
    const y = mulC(b.n, ad) orelse return null;
    const num = (if (sub) subC(x, y) else addC(x, y)) orelse return null;
    return norm(num, den);
}

fn ratMul(a: Rat, b: Rat) ?Rat {
    const g1: I = @intCast(gcdU(@abs(a.n), @intCast(b.d)));
    const g2: I = @intCast(gcdU(@abs(b.n), @intCast(a.d)));
    const g1n = if (g1 == 0) 1 else g1;
    const g2n = if (g2 == 0) 1 else g2;
    const n = mulC(@divExact(a.n, g1n), @divExact(b.n, g2n)) orelse return null;
    const d = mulC(@divExact(a.d, g2n), @divExact(b.d, g1n)) orelse return null;
    return norm(n, d);
}

fn ratCmp(a: Rat, b: Rat) ?std.math.Order {
    const x = mulC(a.n, b.d) orelse return null;
    const y = mulC(b.n, a.d) orelse return null;
    return std.math.order(x, y);
}

fn toF(v: Value) f64 {
    return switch (v) {
        .rat => |r| @as(f64, @floatFromInt(r.n)) / @as(f64, @floatFromInt(r.d)),
        .float => |f| f,
    };
}

fn pow10(e: usize) ?I {
    if (e > 38) return null;
    var r: I = 1;
    for (0..e) |_| r *= 10;
    return r;
}

const Fn = enum { sqrt, abs, ln, log10, log2, exp, sin, cos, tan, asin, acos, atan, floor, ceil, round, min, max, pow, gcd, lcm };

pub const Result = struct { value: Value, approx: bool };

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    tok: Token = undefined,
    depth: u32 = 0,
    approx: bool = false,
    paren_fn: u32 = 0, // >0 while parsing function arguments (commas legal)

    fn advance(self: *Parser) u.Fail!void {
        self.tok = try self.lex();
    }

    fn lex(self: *Parser) u.Fail!Token {
        const s = self.src;
        while (self.pos < s.len and (s[self.pos] == ' ' or s[self.pos] == '\t' or s[self.pos] == '\n' or s[self.pos] == '\r')) self.pos += 1;
        if (self.pos >= s.len) return .{ .kind = .eof, .pos = s.len };
        const start = self.pos;
        const c = s[start];
        self.pos += 1;
        switch (c) {
            '+' => return .{ .kind = .plus, .pos = start },
            '-' => return .{ .kind = .minus, .pos = start },
            '*' => {
                if (self.pos < s.len and s[self.pos] == '*') {
                    self.pos += 1;
                    return .{ .kind = .caret, .pos = start };
                }
                return .{ .kind = .star, .pos = start };
            },
            '/' => return .{ .kind = .slash, .pos = start },
            '%' => return .{ .kind = .percent, .pos = start },
            '^' => return .{ .kind = .caret, .pos = start },
            '(' => return .{ .kind = .lparen, .pos = start },
            ')' => return .{ .kind = .rparen, .pos = start },
            ',' => return .{ .kind = .comma, .pos = start },
            '0'...'9', '.' => {
                self.pos = start;
                return self.lexNumber();
            },
            'a'...'z', 'A'...'Z', '_' => {
                while (self.pos < s.len and (std.ascii.isAlphanumeric(s[self.pos]) or s[self.pos] == '_')) self.pos += 1;
                return .{ .kind = .ident, .pos = start, .text = s[start..self.pos] };
            },
            else => return u.fail("unexpected character '{c}' at position {d}", .{ c, start }),
        }
    }

    fn lexNumber(self: *Parser) u.Fail!Token {
        const s = self.src;
        const start = self.pos;
        if (s[start] == '0' and start + 1 < s.len) {
            switch (s[start + 1]) {
                'x', 'X', 'b', 'B', 'o', 'O' => return u.fail("hex/binary/octal literals (0x/0b/0o) are not supported; convert with base_convert first (position {d})", .{start}),
                else => {},
            }
        }
        var mant: I = 0;
        var big = false;
        var ndig: usize = 0;
        var frac_len: usize = 0;
        var p = start;
        while (p < s.len and std.ascii.isDigit(s[p])) : (p += 1) {
            ndig += 1;
            if (!big) {
                const m = mulC(mant, 10);
                const m2 = if (m) |x| addC(x, s[p] - '0') else null;
                if (m2) |x| mant = x else big = true;
            }
        }
        if (p < s.len and s[p] == '.') {
            if (p + 1 < s.len and std.ascii.isDigit(s[p + 1])) {
                p += 1;
                while (p < s.len and std.ascii.isDigit(s[p])) : (p += 1) {
                    ndig += 1;
                    frac_len += 1;
                    if (!big) {
                        const m = mulC(mant, 10);
                        const m2 = if (m) |x| addC(x, s[p] - '0') else null;
                        if (m2) |x| mant = x else big = true;
                    }
                }
            } else if (ndig == 0) {
                return u.fail("unexpected '.' at position {d}", .{start});
            }
        }
        if (ndig == 0) return u.fail("unexpected '.' at position {d}", .{start});
        var exp: i64 = 0;
        if (p < s.len and (s[p] == 'e' or s[p] == 'E')) {
            var q = p + 1;
            var eneg = false;
            if (q < s.len and (s[q] == '+' or s[q] == '-')) {
                eneg = s[q] == '-';
                q += 1;
            }
            if (q < s.len and std.ascii.isDigit(s[q])) {
                var e: i64 = 0;
                while (q < s.len and std.ascii.isDigit(s[q])) : (q += 1) {
                    if (e < 100000) e = e * 10 + (s[q] - '0');
                }
                exp = if (eneg) -e else e;
                p = q;
            }
        }
        if (p < s.len) {
            const c = s[p];
            if (c == '_') return u.fail("digit separators ('_') are not supported (position {d})", .{p});
            if (std.ascii.isAlphabetic(c)) return u.fail("unexpected '{c}' after number at position {d} (no unit suffixes or implicit multiplication; write 2*pi)", .{ c, p });
        }
        self.pos = p;
        const text = s[start..p];
        const e10: i64 = exp - @as(i64, @intCast(frac_len));
        var val: ?Value = null;
        if (!big) {
            if (e10 >= 0) {
                if (e10 <= 38) if (pow10(@intCast(e10))) |pw| if (mulC(mant, pw)) |n| {
                    val = .{ .rat = .{ .n = n, .d = 1 } };
                };
            } else if (-e10 <= 38) {
                if (pow10(@intCast(-e10))) |pw| if (norm(mant, pw)) |r| {
                    val = .{ .rat = r };
                };
            }
        }
        if (val == null) {
            const f = std.fmt.parseFloat(f64, text) catch return u.fail("cannot parse number '{s}'", .{text});
            if (!std.math.isFinite(f)) return u.fail("number '{s}' is too large (overflow)", .{text});
            val = .{ .float = f };
            if (text.len > 0 and mant != 0) self.approx = true; // exact literal did not fit i128
        }
        return .{ .kind = .num, .pos = start, .val = val.? };
    }

    fn finite(self: *Parser, x: f64, what: []const u8) u.Fail!Value {
        _ = self;
        if (std.math.isNan(x)) return u.fail("{s}: result is not a number", .{what});
        if (std.math.isInf(x)) return u.fail("{s}: overflow (result exceeds float range)", .{what});
        return .{ .float = x };
    }

    fn expr(self: *Parser, min_bp: u8) u.Fail!Value {
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > MAX_DEPTH) return u.fail("expression nested too deeply (max {d} levels)", .{MAX_DEPTH});
        var lhs = try self.nud();
        while (true) {
            const t = self.tok;
            const bp: [2]u8 = switch (t.kind) {
                .plus, .minus => .{ 1, 2 },
                .star, .slash, .percent => .{ 3, 4 },
                .caret => .{ 8, 7 }, // right associative
                else => break,
            };
            if (bp[0] < min_bp) break;
            try self.advance();
            const rhs = try self.expr(bp[1]);
            lhs = try self.binop(t.kind, lhs, rhs);
        }
        return lhs;
    }

    fn nud(self: *Parser) u.Fail!Value {
        const t = self.tok;
        switch (t.kind) {
            .num => {
                try self.advance();
                return t.val;
            },
            .minus => {
                try self.advance();
                const v = try self.expr(5); // binds looser than ^: -2^2 = -4
                return self.neg(v);
            },
            .plus => {
                try self.advance();
                return self.expr(5);
            },
            .lparen => {
                try self.advance();
                const saved = self.paren_fn;
                self.paren_fn = 0;
                defer self.paren_fn = saved;
                const v = try self.expr(0);
                if (self.tok.kind != .rparen) return u.fail("expected ')' at position {d}", .{self.tok.pos});
                try self.advance();
                return v;
            },
            .ident => {
                try self.advance();
                return self.identifier(t);
            },
            .eof => return u.fail("unexpected end of expression", .{}),
            .comma => return u.fail("unexpected ',' at position {d}: thousands separators are not supported (write 1000, not 1,000); commas only separate function arguments", .{t.pos}),
            .rparen => return u.fail("unexpected ')' at position {d}", .{t.pos}),
            else => return u.fail("unexpected operator at position {d}", .{t.pos}),
        }
    }

    fn identifier(self: *Parser, t: Token) u.Fail!Value {
        var buf: [16]u8 = undefined;
        if (t.text.len > buf.len) return u.fail("unknown name '{s}' (no variables; constants: pi, e)", .{t.text});
        const name = std.ascii.lowerString(&buf, t.text);
        if (self.tok.kind != .lparen) {
            if (std.mem.eql(u8, name, "pi")) return .{ .float = std.math.pi };
            if (std.mem.eql(u8, name, "e")) return .{ .float = std.math.e };
            if (std.meta.stringToEnum(Fn, name) != null) return u.fail("'{s}' is a function; call it like {s}(x)", .{ t.text, t.text });
            return u.fail("unknown name '{s}' at position {d} (no variables; constants: pi, e)", .{ t.text, t.pos });
        }
        const f = std.meta.stringToEnum(Fn, name) orelse return u.fail("unknown function '{s}' at position {d}", .{ t.text, t.pos });
        try self.advance(); // (
        var args: [32]Value = undefined;
        var n: usize = 0;
        const saved = self.paren_fn;
        self.paren_fn = 1;
        defer self.paren_fn = saved;
        if (self.tok.kind != .rparen) {
            while (true) {
                if (n == args.len) return u.fail("{s}: too many arguments (max 32)", .{t.text});
                args[n] = try self.expr(0);
                n += 1;
                if (self.tok.kind == .comma) {
                    try self.advance();
                    continue;
                }
                break;
            }
        }
        if (self.tok.kind != .rparen) return u.fail("expected ')' or ',' at position {d}", .{self.tok.pos});
        try self.advance();
        return self.call(f, t.text, args[0..n]);
    }

    fn neg(self: *Parser, v: Value) u.Fail!Value {
        switch (v) {
            .rat => |r| {
                if (r.n == std.math.minInt(I)) {
                    self.approx = true;
                    return .{ .float = -toF(v) };
                }
                return .{ .rat = .{ .n = -r.n, .d = r.d } };
            },
            .float => |f| return .{ .float = -f },
        }
    }

    fn binop(self: *Parser, k: Tk, x: Value, y: Value) u.Fail!Value {
        switch (k) {
            .plus, .minus => {
                if (x == .rat and y == .rat) {
                    if (ratAdd(x.rat, y.rat, k == .minus)) |r| return .{ .rat = r };
                    self.approx = true;
                }
                return self.finite(if (k == .plus) toF(x) + toF(y) else toF(x) - toF(y), "add/subtract");
            },
            .star => {
                if (x == .rat and y == .rat) {
                    if (ratMul(x.rat, y.rat)) |r| return .{ .rat = r };
                    self.approx = true;
                }
                return self.finite(toF(x) * toF(y), "multiply");
            },
            .slash => {
                if (isZero(y)) return u.fail("division by zero", .{});
                if (x == .rat and y == .rat) {
                    const inv = norm(y.rat.d, y.rat.n).?;
                    if (ratMul(x.rat, inv)) |r| return .{ .rat = r };
                    self.approx = true;
                }
                return self.finite(toF(x) / toF(y), "divide");
            },
            .percent => {
                if (isZero(y)) return u.fail("modulo by zero", .{});
                // remainder takes the sign of the dividend (truncated, like C/Rust/JS)
                if (x == .rat and y == .rat) {
                    const q = try self.binop(.slash, x, y);
                    if (q == .rat) {
                        const t: Value = .{ .rat = .{ .n = @divTrunc(q.rat.n, q.rat.d), .d = 1 } };
                        const prod = try self.binop(.star, y, t);
                        return self.binop(.minus, x, prod);
                    }
                }
                return self.finite(@rem(toF(x), toF(y)), "modulo");
            },
            .caret => return self.pow(x, y),
            else => unreachable,
        }
    }

    fn pow(self: *Parser, x: Value, y: Value) u.Fail!Value {
        if (x == .rat and y == .rat and y.rat.d == 1) {
            const e = y.rat.n;
            if (isZero(x) and e < 0) return u.fail("division by zero (0 raised to a negative power)", .{});
            if (e >= -100000 and e <= 100000) {
                var base = x.rat;
                if (e < 0) base = norm(base.d, base.n).?;
                var k: u64 = @intCast(if (e < 0) -e else e);
                var acc: Rat = .{ .n = 1, .d = 1 };
                var ok = true;
                while (k > 0) : (k >>= 1) {
                    if (k & 1 == 1) {
                        acc = ratMul(acc, base) orelse {
                            ok = false;
                            break;
                        };
                    }
                    if (k > 1) base = ratMul(base, base) orelse {
                        ok = false;
                        break;
                    };
                }
                if (ok) return .{ .rat = acc };
                self.approx = true;
            } else self.approx = true;
        }
        const fx = toF(x);
        const fy = toF(y);
        if (fx == 0 and fy < 0) return u.fail("division by zero (0 raised to a negative power)", .{});
        if (fx < 0 and @floor(fy) != fy) return u.fail("power of a negative number to a non-integer exponent is not real", .{});
        return self.finite(std.math.pow(f64, fx, fy), "power");
    }

    fn call(self: *Parser, f: Fn, name: []const u8, args: []const Value) u.Fail!Value {
        const n = args.len;
        switch (f) {
            .min, .max => {
                if (n < 1) return u.fail("{s}: needs at least 1 argument", .{name});
                var best = args[0];
                for (args[1..]) |a| {
                    const c = self.cmp(a, best);
                    if ((f == .min and c == .lt) or (f == .max and c == .gt)) best = a;
                }
                return best;
            },
            .gcd, .lcm => {
                if (n < 2) return u.fail("{s}: needs at least 2 arguments", .{name});
                var acc: u128 = 0;
                for (args, 0..) |a, i| {
                    if (a != .rat or a.rat.d != 1) return u.fail("{s}: arguments must be integers", .{name});
                    const m: u128 = @abs(a.rat.n);
                    if (i == 0) {
                        acc = m;
                    } else if (f == .gcd) {
                        acc = gcdU(acc, m);
                    } else {
                        if (acc == 0 or m == 0) {
                            acc = 0;
                        } else {
                            const g = gcdU(acc, m);
                            acc = std.math.mul(u128, acc / g, m) catch return u.fail("lcm: overflow (exceeds 128-bit integer range)", .{});
                        }
                    }
                }
                if (acc > std.math.maxInt(I)) return u.fail("{s}: overflow (exceeds 128-bit integer range)", .{name});
                return .{ .rat = .{ .n = @intCast(acc), .d = 1 } };
            },
            .pow => {
                if (n != 2) return u.fail("pow: needs exactly 2 arguments", .{});
                return self.pow(args[0], args[1]);
            },
            .round => {
                if (n < 1 or n > 2) return u.fail("round: takes 1 or 2 arguments (x[, digits])", .{});
                var digits: usize = 0;
                if (n == 2) {
                    if (args[1] != .rat or args[1].rat.d != 1 or args[1].rat.n < 0 or args[1].rat.n > 30) return u.fail("round: digits must be an integer 0..30", .{});
                    digits = @intCast(args[1].rat.n);
                }
                return self.roundTo(args[0], digits);
            },
            else => {},
        }
        if (n != 1) return u.fail("{s}: takes exactly 1 argument", .{name});
        const v = args[0];
        switch (f) {
            .abs => return switch (v) {
                .rat => |r| if (r.n < 0) self.neg(v) else v,
                .float => |x| .{ .float = @abs(x) },
            },
            .floor, .ceil => {
                if (v == .rat) {
                    const r = v.rat;
                    const q = if (f == .floor) @divFloor(r.n, r.d) else -@divFloor(-r.n, r.d);
                    return .{ .rat = .{ .n = q, .d = 1 } };
                }
                return self.finite(if (f == .floor) @floor(v.float) else @ceil(v.float), name);
            },
            .sqrt => {
                if (isNeg(v)) return u.fail("sqrt of a negative number is not real", .{});
                if (v == .rat) {
                    const r = v.rat;
                    const a: u128 = @intCast(r.n);
                    const b: u128 = @intCast(r.d);
                    const sa: u128 = std.math.sqrt(a);
                    const sb: u128 = std.math.sqrt(b);
                    if (sa * sa == a and sb * sb == b) return .{ .rat = .{ .n = @intCast(sa), .d = @intCast(sb) } };
                }
                return self.finite(@sqrt(toF(v)), name);
            },
            else => {},
        }
        const x = toF(v);
        const r: f64 = switch (f) {
            .ln, .log10, .log2 => blk: {
                if (x <= 0) return u.fail("{s}: argument must be positive", .{name});
                break :blk switch (f) {
                    .ln => @log(x),
                    .log10 => @log10(x),
                    else => @log2(x),
                };
            },
            .exp => @exp(x),
            .sin => @sin(x),
            .cos => @cos(x),
            .tan => @tan(x),
            .asin, .acos => blk: {
                if (x < -1 or x > 1) return u.fail("{s}: argument must be in [-1, 1]", .{name});
                break :blk if (f == .asin) std.math.asin(x) else std.math.acos(x);
            },
            .atan => std.math.atan(x),
            else => unreachable,
        };
        return self.finite(r, name);
    }

    fn cmp(self: *Parser, a: Value, b: Value) std.math.Order {
        _ = self;
        if (a == .rat and b == .rat) if (ratCmp(a.rat, b.rat)) |o| return o;
        return std.math.order(toF(a), toF(b));
    }

    /// Round half away from zero, exact for rationals.
    fn roundTo(self: *Parser, v: Value, digits: usize) u.Fail!Value {
        if (v == .rat) {
            if (pow10(digits)) |scale| {
                if (mulC(v.rat.n, scale)) |sn| {
                    const scaled = norm(sn, v.rat.d).?;
                    const neg_ = scaled.n < 0;
                    const an: I = if (neg_) -scaled.n else scaled.n;
                    var q = @divFloor(an, scaled.d);
                    const rem = an - q * scaled.d;
                    if (rem >= scaled.d - rem) q += 1;
                    if (neg_) q = -q;
                    if (norm(q, scale)) |r| return .{ .rat = r };
                }
            }
            self.approx = true;
        }
        const x = toF(v);
        const p = std.math.pow(f64, 10, @floatFromInt(digits));
        return self.finite(@round(x * p) / p, "round");
    }
};

fn isZero(v: Value) bool {
    return switch (v) {
        .rat => |r| r.n == 0,
        .float => |f| f == 0,
    };
}

fn isNeg(v: Value) bool {
    return switch (v) {
        .rat => |r| r.n < 0,
        .float => |f| f < 0,
    };
}

pub fn eval(src: []const u8) u.Fail!Result {
    if (src.len == 0) return u.fail("empty expression", .{});
    if (src.len > MAX_LEN) return u.fail("expression too long ({d} chars, max {d})", .{ src.len, MAX_LEN });
    var p: Parser = .{ .src = src };
    try p.advance();
    const v = try p.expr(0);
    if (p.tok.kind != .eof) {
        return switch (p.tok.kind) {
            .comma => u.fail("unexpected ',' at position {d}: thousands separators are not supported (write 1000, not 1,000); commas only separate function arguments", .{p.tok.pos}),
            .num => u.fail("unexpected number at position {d} (missing operator? spaces are not thousands separators, and there is no implicit multiplication)", .{p.tok.pos}),
            .lparen => u.fail("unexpected '(' at position {d} (no implicit multiplication; write 2*(3))", .{p.tok.pos}),
            .ident => u.fail("unexpected name '{s}' at position {d} (no implicit multiplication)", .{ p.tok.text, p.tok.pos }),
            .rparen => u.fail("unmatched ')' at position {d}", .{p.tok.pos}),
            else => u.fail("unexpected token at position {d}", .{p.tok.pos}),
        };
    }
    return .{ .value = v, .approx = p.approx };
}

pub fn writeResult(w: *std.Io.Writer, r: Result) !void {
    switch (r.value) {
        .rat => |q| {
            if (q.d == 1) {
                try w.print("= {d}", .{q.n});
            } else {
                try w.writeAll("= ");
                try u.fmtShortest(w, toF(r.value));
                try w.print(" (exact {d}/{d})", .{ q.n, q.d });
            }
        },
        .float => |f| {
            try w.writeAll("= ");
            try u.fmtShortest(w, f);
            const rounded = u.round12(f);
            if (rounded != f) {
                try w.writeAll(" (rounded 12 sig. digits: ");
                try u.fmtShortest(w, rounded);
                try w.writeAll(")");
            }
        },
    }
    if (r.approx) try w.writeAll(" [approximate: an exact integer intermediate exceeded 128 bits, float used]");
}

pub fn handle(a: std.mem.Allocator, args: std.json.Value) u.Err![]u8 {
    const expr = try u.reqStr(args, "expr");
    return run(a, expr);
}

pub fn run(a: std.mem.Allocator, expr: []const u8) u.Err![]u8 {
    const r = try eval(expr);
    var out: u.Out = .init(a);
    errdefer out.deinit();
    try writeResult(&out.writer, r);
    return out.toOwnedSlice();
}

// ------------------------------------------------------------------- tests

fn expectCalc(src: []const u8, want: []const u8) !void {
    const got = try run(std.testing.allocator, src);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}

fn expectCalcErr(src: []const u8, needle: []const u8) !void {
    if (run(std.testing.allocator, src)) |got| {
        std.testing.allocator.free(got);
        std.debug.print("expected error for '{s}'\n", .{src});
        return error.ExpectedFailure;
    } else |e| {
        try std.testing.expect(e == error.Fail);
        if (std.mem.indexOf(u8, u.lastError(), needle) == null) {
            std.debug.print("error '{s}' lacks '{s}'\n", .{ u.lastError(), needle });
            return error.WrongError;
        }
    }
}

test "precedence and associativity" {
    try expectCalc("1+2*3", "= 7");
    try expectCalc("(1+2)*3", "= 9");
    try expectCalc("2^3^2", "= 512"); // right associative
    try expectCalc("2**3**2", "= 512");
    try expectCalc("-2^2", "= -4"); // unary minus binds looser than ^
    try expectCalc("(-2)^2", "= 4");
    try expectCalc("2^-1", "= 0.5 (exact 1/2)");
    try expectCalc("2^-2^2", "= 0.0625 (exact 1/16)"); // 2^(-(2^2))
    try expectCalc("10-3-2", "= 5"); // left associative
    try expectCalc("100/10/5", "= 2");
    try expectCalc("--3", "= 3");
    try expectCalc("2*-3", "= -6");
    try expectCalc("+5", "= 5");
    try expectCalc("-3^2+1", "= -8");
    try expectCalc("2*3%4", "= 2"); // * and % same level, left to right: (2*3)%4
}

test "exact arithmetic and rationals" {
    try expectCalc("0.1+0.2", "= 0.3 (exact 3/10)");
    try expectCalc("1/3+1/6", "= 0.5 (exact 1/2)");
    try expectCalc("10/4", "= 2.5 (exact 5/2)");
    try expectCalc("1/3", "= 0.3333333333333333 (exact 1/3)");
    try expectCalc("1e3", "= 1000");
    try expectCalc("1.5e-3", "= 0.0015 (exact 3/2000)");
    try expectCalc("123456789012345678901234567890*10", "= 1234567890123456789012345678900");
    try expectCalc("2^126", "= 85070591730234615865843651857942052864");
    try expectCalc("7%3", "= 1");
    try expectCalc("-7%3", "= -1"); // sign of dividend
    try expectCalc("7%-3", "= 1");
    try expectCalc("5.5%2", "= 1.5 (exact 3/2)");
}

test "overflow degrades to float and is reported" {
    const got = try run(std.testing.allocator, "2^127");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "1.7014118346046923e38") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "approximate") != null);
    try expectCalcErr("1e999", "too large");
    try expectCalcErr("10^400", "overflow");
}

test "functions" {
    try expectCalc("sqrt(16)", "= 4");
    try expectCalc("sqrt(1/4)", "= 0.5 (exact 1/2)");
    try expectCalc("sqrt(2)", "= 1.4142135623730951 (rounded 12 sig. digits: 1.41421356237)");
    try expectCalc("abs(-3.5)", "= 3.5 (exact 7/2)");
    try expectCalc("floor(-1.5)", "= -2");
    try expectCalc("ceil(1.2)", "= 2");
    try expectCalc("ceil(-1.2)", "= -1");
    try expectCalc("round(2.5)", "= 3");
    try expectCalc("round(-2.5)", "= -3");
    try expectCalc("round(3.14159, 2)", "= 3.14 (exact 157/50)");
    try expectCalc("min(3,1,2)", "= 1");
    try expectCalc("max(3, 1.5, 2)", "= 3");
    try expectCalc("gcd(12,18)", "= 6");
    try expectCalc("lcm(4,6)", "= 12");
    try expectCalc("pow(2,10)", "= 1024");
    try expectCalc("log10(1000)", "= 3");
    try expectCalc("log2(8)", "= 3");
    try expectCalc("ln(e)", "= 1");
    try expectCalc("exp(0)", "= 1");
    try expectCalc("cos(0)", "= 1");
    try expectCalc("atan(1)*4", "= 3.141592653589793 (rounded 12 sig. digits: 3.14159265359)");
    try expectCalc("PI", "= 3.141592653589793 (rounded 12 sig. digits: 3.14159265359)");
    try expectCalc("SQRT(9)", "= 3");
}

test "float formatting shows shortest and rounded" {
    try expectCalc("sin(pi)", "= 1.2246467991473532e-16 (rounded 12 sig. digits: 1.22464679915e-16)");
    try expectCalc("pi*1e10", "= 31415926535.89793 (rounded 12 sig. digits: 31415926535.9)");
    try expectCalc("exp(50)", "= 5.184705528587072e21 (rounded 12 sig. digits: 5.18470552859e21)");
}

test "errors are clear" {
    try expectCalcErr("1/0", "division by zero");
    try expectCalcErr("5%0", "modulo by zero");
    try expectCalcErr("0^-1", "division by zero");
    try expectCalcErr("1/(2-2)", "division by zero");
    try expectCalcErr("0x1F+1", "base_convert");
    try expectCalcErr("0b101", "base_convert");
    try expectCalcErr("0o17", "base_convert");
    try expectCalcErr("1,000+1", "thousands separators");
    try expectCalcErr("1 000", "unexpected number");
    try expectCalcErr("1_000", "digit separators");
    try expectCalcErr("x+1", "no variables");
    try expectCalcErr("foo(1)", "unknown function");
    try expectCalcErr("2(3)", "no implicit multiplication");
    try expectCalcErr("2pi", "unexpected 'p'");
    try expectCalcErr("sqrt(-1)", "negative");
    try expectCalcErr("ln(0)", "positive");
    try expectCalcErr("asin(2)", "[-1, 1]");
    try expectCalcErr("(-8)^0.5", "not real");
    try expectCalcErr("(1+2", "expected ')'");
    try expectCalcErr("1+2)", "unmatched");
    try expectCalcErr("", "empty");
    try expectCalcErr("1+", "end of expression");
    try expectCalcErr("sqrt", "function");
    try expectCalcErr("sqrt(1,2)", "exactly 1 argument");
    try expectCalcErr("gcd(1.5,2)", "integers");
    try expectCalcErr("1 $ 2", "unexpected character");
    try expectCalcErr("eval(1)", "unknown function");
}

test "depth and length caps" {
    const a = std.testing.allocator;
    const deep = try a.alloc(u8, 200);
    defer a.free(deep);
    @memset(deep[0..100], '(');
    @memset(deep[100..101], '1');
    @memset(deep[101..201 - 1], ')');
    try expectCalcErr(deep[0..200], "nested too deeply");
    const minus = try a.alloc(u8, 500);
    defer a.free(minus);
    @memset(minus, '-');
    minus[499] = '1';
    try expectCalcErr(minus, "nested too deeply");
    const long = try a.alloc(u8, 1001);
    defer a.free(long);
    @memset(long, '1');
    try expectCalcErr(long, "too long");
}
