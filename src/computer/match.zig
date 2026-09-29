//! Window-title matching: fuzzywuzzy-compatible `partial_ratio` scoring and
//! a small linear-time regex (Pike VM) for `use_regex=true`.
//!
//! computer_control scored titles with `fuzzywuzzy.process.extractOne(...,
//! scorer=fuzz.partial_ratio)`; the scorer here reproduces that metric
//! (Levenshtein-backend `ratio` = 2*LCS/(len_a+len_b) over the best-aligned
//! window of the longer string, both sides run through `full_process`).
//!
//! Regex subset (case-insensitive search, like `re.search(p, t, re.I)`):
//! literals, `.`, `[...]`/`[^...]` with ranges, `\d \w \s \D \W \S`, escaped
//! metacharacters, `^ $`, groups `( )` incl. `(?: )`, alternation `|`, and
//! the greedy quantifiers `* + ?` plus `{m}`, `{m,}`, `{m,n}`. No
//! backreferences or lookaround. Matching cannot backtrack exponentially.

const std = @import("std");

// ── fuzzy ───────────────────────────────────────────────────────────────────

/// fuzzywuzzy `utils.full_process`: non-alphanumerics → space, lower-case,
/// trim. Non-ASCII bytes are kept (Python's \W keeps Unicode letters).
pub fn fullProcess(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        out[i] = if (c >= 0x80) c else if (std.ascii.isAlphanumeric(c)) std.ascii.toLower(c) else ' ';
    }
    const trimmed = std.mem.trim(u8, out, " ");
    std.mem.copyForwards(u8, out, trimmed);
    return allocator.realloc(out, trimmed.len) catch out[0..trimmed.len];
}

fn lcsLen(a: []const u8, b: []const u8, row: []u16) u32 {
    @memset(row[0 .. b.len + 1], 0);
    for (a) |ca| {
        var diag: u16 = 0;
        for (b, 0..) |cb, j| {
            const up = row[j + 1];
            row[j + 1] = if (ca == cb) diag + 1 else @max(up, row[j]);
            diag = up;
        }
    }
    return row[b.len];
}

/// Indel similarity in [0, 1]: 2*LCS / (len_a + len_b).
pub fn ratioF(a: []const u8, b: []const u8, row: []u16) f64 {
    const total = a.len + b.len;
    if (total == 0) return 1.0;
    return 2.0 * @as(f64, @floatFromInt(lcsLen(a, b, row))) / @as(f64, @floatFromInt(total));
}

/// `fuzz.partial_ratio` on already-processed strings, 0..100.
pub fn partialRatio(allocator: std.mem.Allocator, a: []const u8, b: []const u8) !u8 {
    const short = if (a.len <= b.len) a else b;
    const long = if (a.len <= b.len) b else a;
    if (short.len == 0) return 0;
    const row = try allocator.alloc(u16, short.len + 1);
    defer allocator.free(row);
    var best: f64 = 0;
    var start: usize = 0;
    while (start + short.len <= long.len) : (start += 1) {
        const r = ratioF(short, long[start..][0..short.len], row);
        if (r > best) best = r;
        if (best > 0.995) return 100;
    }
    return @intFromFloat(@round(best * 100.0));
}

/// Score `title` against `pattern` exactly like extractOne's scorer call.
pub fn score(allocator: std.mem.Allocator, pattern: []const u8, title: []const u8) !u8 {
    const p = try fullProcess(allocator, pattern);
    defer allocator.free(p);
    const tt = try fullProcess(allocator, title);
    defer allocator.free(tt);
    if (p.len == 0 or tt.len == 0) return 0;
    return partialRatio(allocator, p, tt);
}

// ── regex ───────────────────────────────────────────────────────────────────

const Range = struct { lo: u21, hi: u21 };

const Class = struct {
    ranges: []const Range,
    negated: bool,

    fn matches(self: Class, c: u21) bool {
        var hit = false;
        for (self.ranges) |r| {
            if (inRangeFolded(c, r)) {
                hit = true;
                break;
            }
        }
        return hit != self.negated;
    }
};

fn fold(c: u21) u21 {
    return if (c < 128) std.ascii.toLower(@intCast(c)) else c;
}

fn inRangeFolded(c: u21, r: Range) bool {
    if (c >= r.lo and c <= r.hi) return true;
    if (c < 128) {
        const lc: u21 = std.ascii.toLower(@intCast(c));
        const uc: u21 = std.ascii.toUpper(@intCast(c));
        return (lc >= r.lo and lc <= r.hi) or (uc >= r.lo and uc <= r.hi);
    }
    return false;
}

const Inst = union(enum) {
    char: u21, // folded
    any,
    class: Class,
    split: [2]u32,
    jmp: u32,
    bol,
    eol,
    match,
};

const Node = union(enum) {
    empty,
    char: u21,
    any,
    class: Class,
    bol,
    eol,
    cat: []const *Node,
    alt: [2]*Node,
    repeat: struct { sub: *Node, min: u32, max: ?u32 },
};

pub const Regex = struct {
    prog: []const Inst,

    pub const Error = error{ BadRegex, OutOfMemory, RegexTooLarge };

    /// Parse and compile. All memory comes from `arena` (use an arena).
    pub fn compile(arena: std.mem.Allocator, pattern: []const u8) Error!Regex {
        var cps: std.ArrayList(u21) = .empty;
        var view = std.unicode.Utf8View.init(pattern) catch return error.BadRegex;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| try cps.append(arena, cp);
        var p: Parser = .{ .arena = arena, .s = cps.items };
        const root = try p.parseAlt();
        if (p.i != p.s.len) return error.BadRegex;
        var c: Compiler = .{ .arena = arena };
        try c.emit(root);
        try c.prog.append(arena, .match);
        return .{ .prog = c.prog.items };
    }

    /// Unanchored, case-insensitive search.
    pub fn search(self: Regex, allocator: std.mem.Allocator, text: []const u8) !bool {
        var cps: std.ArrayList(u21) = .empty;
        defer cps.deinit(allocator);
        var view = std.unicode.Wtf8View.init(text) catch return false;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| try cps.append(allocator, cp);

        const n = self.prog.len;
        const cur = try allocator.alloc(u32, n);
        defer allocator.free(cur);
        const nxt = try allocator.alloc(u32, n);
        defer allocator.free(nxt);
        const mark = try allocator.alloc(usize, n);
        defer allocator.free(mark);
        @memset(mark, std.math.maxInt(usize));
        const stack = try allocator.alloc(u32, n * 2 + 2);
        defer allocator.free(stack);

        var clist: []u32 = cur;
        var nlist: []u32 = nxt;
        var clen: usize = 0;
        var gen: usize = 0;
        var pos: usize = 0;
        while (true) : (pos += 1) {
            // Unanchored: start a thread at every position.
            if (self.addThread(clist, &clen, 0, pos, cps.items.len, mark, gen, stack)) return true;
            if (pos == cps.items.len) break;
            const ch = fold(cps.items[pos]);
            gen += 1;
            var nlen: usize = 0;
            for (clist[0..clen]) |pc| {
                const ok = switch (self.prog[pc]) {
                    .char => |c| c == ch,
                    .any => ch != '\n',
                    .class => |cl| cl.matches(cps.items[pos]),
                    else => false,
                };
                if (ok and self.addThread(nlist, &nlen, pc + 1, pos + 1, cps.items.len, mark, gen, stack)) return true;
            }
            std.mem.swap([]u32, &clist, &nlist);
            clen = nlen;
        }
        return false;
    }

    /// Follow epsilon edges from `start`; returns true on reaching `match`.
    fn addThread(self: Regex, list: []u32, len: *usize, start: u32, pos: usize, n: usize, mark: []usize, gen: usize, stack: []u32) bool {
        var sp: usize = 0;
        stack[sp] = start;
        sp += 1;
        while (sp > 0) {
            sp -= 1;
            const pc = stack[sp];
            if (mark[pc] == gen) continue;
            mark[pc] = gen;
            switch (self.prog[pc]) {
                .match => return true,
                .jmp => |to| {
                    stack[sp] = to;
                    sp += 1;
                },
                .split => |to| {
                    // Push the lower-priority branch first.
                    stack[sp] = to[1];
                    stack[sp + 1] = to[0];
                    sp += 2;
                },
                .bol => if (pos == 0) {
                    stack[sp] = pc + 1;
                    sp += 1;
                },
                .eol => if (pos == n) {
                    stack[sp] = pc + 1;
                    sp += 1;
                },
                else => {
                    list[len.*] = pc;
                    len.* += 1;
                },
            }
        }
        return false;
    }
};

const Parser = struct {
    arena: std.mem.Allocator,
    s: []const u21,
    i: usize = 0,

    fn peek(self: *Parser) ?u21 {
        return if (self.i < self.s.len) self.s[self.i] else null;
    }

    fn node(self: *Parser, v: Node) !*Node {
        const n = try self.arena.create(Node);
        n.* = v;
        return n;
    }

    fn parseAlt(self: *Parser) Regex.Error!*Node {
        var left = try self.parseCat();
        while (self.peek() == '|') {
            self.i += 1;
            const right = try self.parseCat();
            left = try self.node(.{ .alt = .{ left, right } });
        }
        return left;
    }

    fn parseCat(self: *Parser) Regex.Error!*Node {
        var items: std.ArrayList(*Node) = .empty;
        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;
            try items.append(self.arena, try self.parseRepeat());
        }
        if (items.items.len == 0) return self.node(.empty);
        if (items.items.len == 1) return items.items[0];
        return self.node(.{ .cat = items.items });
    }

    fn parseRepeat(self: *Parser) Regex.Error!*Node {
        var atom = try self.parseAtom();
        while (self.peek()) |c| {
            var min: u32 = 0;
            var max: ?u32 = null;
            switch (c) {
                '*' => self.i += 1,
                '+' => {
                    self.i += 1;
                    min = 1;
                },
                '?' => {
                    self.i += 1;
                    max = 1;
                },
                '{' => {
                    const save = self.i;
                    if (self.parseBraces()) |b| {
                        min = b.min;
                        max = b.max;
                    } else {
                        self.i = save;
                        return atom; // literal '{' handled by parseAtom next round
                    }
                },
                else => return atom,
            }
            // Non-greedy suffix: accepted, treated as greedy (search only
            // cares whether a match exists).
            if (self.peek() == '?') self.i += 1;
            if (min > 1000 or (max != null and max.? > 1000)) return error.RegexTooLarge;
            atom = try self.node(.{ .repeat = .{ .sub = atom, .min = min, .max = max } });
        }
        return atom;
    }

    fn parseNumber(self: *Parser) ?u32 {
        var v: u32 = 0;
        var any = false;
        while (self.peek()) |c| {
            if (c < '0' or c > '9') break;
            v = v *| 10 +| @as(u32, @intCast(c - '0'));
            any = true;
            self.i += 1;
        }
        return if (any) v else null;
    }

    fn parseBraces(self: *Parser) ?struct { min: u32, max: ?u32 } {
        self.i += 1; // '{'
        const lo = self.parseNumber() orelse return null;
        var hi: ?u32 = lo;
        if (self.peek() == ',') {
            self.i += 1;
            hi = self.parseNumber();
        }
        if (self.peek() != '}') return null;
        self.i += 1;
        if (hi != null and hi.? < lo) return null;
        return .{ .min = lo, .max = hi };
    }

    fn parseAtom(self: *Parser) Regex.Error!*Node {
        const c = self.peek() orelse return error.BadRegex;
        self.i += 1;
        switch (c) {
            '.' => return self.node(.any),
            '^' => return self.node(.bol),
            '$' => return self.node(.eol),
            '(' => {
                if (self.peek() == '?') {
                    // Only the non-capturing form is supported.
                    if (self.i + 1 < self.s.len and self.s[self.i + 1] == ':') {
                        self.i += 2;
                    } else return error.BadRegex;
                }
                const inner = try self.parseAlt();
                if (self.peek() != ')') return error.BadRegex;
                self.i += 1;
                return inner;
            },
            ')', '*', '+', '?' => return error.BadRegex,
            '[' => return self.parseClass(),
            '\\' => {
                const e = self.peek() orelse return error.BadRegex;
                self.i += 1;
                if (shorthand(e)) |cls| return self.node(.{ .class = cls });
                return self.node(.{ .char = fold(escapeChar(e)) });
            },
            else => return self.node(.{ .char = fold(c) }),
        }
    }

    fn parseClass(self: *Parser) Regex.Error!*Node {
        var ranges: std.ArrayList(Range) = .empty;
        var negated = false;
        if (self.peek() == '^') {
            negated = true;
            self.i += 1;
        }
        var first = true;
        while (true) {
            const c = self.peek() orelse return error.BadRegex;
            if (c == ']' and !first) {
                self.i += 1;
                break;
            }
            first = false;
            self.i += 1;
            var lo: u21 = c;
            if (c == '\\') {
                const e = self.peek() orelse return error.BadRegex;
                self.i += 1;
                if (shorthand(e)) |cls| {
                    if (cls.negated) return error.BadRegex; // [\D] etc. unsupported
                    try ranges.appendSlice(self.arena, cls.ranges);
                    continue;
                }
                lo = escapeChar(e);
            }
            var hi = lo;
            if (self.peek() == '-' and self.i + 1 < self.s.len and self.s[self.i + 1] != ']') {
                self.i += 1;
                var h = self.peek().?;
                self.i += 1;
                if (h == '\\') {
                    h = escapeChar(self.peek() orelse return error.BadRegex);
                    self.i += 1;
                }
                hi = h;
                if (hi < lo) return error.BadRegex;
            }
            try ranges.append(self.arena, .{ .lo = lo, .hi = hi });
        }
        return self.node(.{ .class = .{ .ranges = ranges.items, .negated = negated } });
    }
};

const digit_ranges = [_]Range{.{ .lo = '0', .hi = '9' }};
const word_ranges = [_]Range{ .{ .lo = '0', .hi = '9' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = 'a', .hi = 'z' }, .{ .lo = '_', .hi = '_' }, .{ .lo = 0x80, .hi = 0x10FFFF } };
const space_ranges = [_]Range{ .{ .lo = ' ', .hi = ' ' }, .{ .lo = '\t', .hi = '\r' }, .{ .lo = 0xA0, .hi = 0xA0 } };

fn shorthand(e: u21) ?Class {
    return switch (e) {
        'd' => .{ .ranges = &digit_ranges, .negated = false },
        'D' => .{ .ranges = &digit_ranges, .negated = true },
        'w' => .{ .ranges = &word_ranges, .negated = false },
        'W' => .{ .ranges = &word_ranges, .negated = true },
        's' => .{ .ranges = &space_ranges, .negated = false },
        'S' => .{ .ranges = &space_ranges, .negated = true },
        else => null,
    };
}

fn escapeChar(e: u21) u21 {
    return switch (e) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        else => e,
    };
}

const Compiler = struct {
    arena: std.mem.Allocator,
    prog: std.ArrayList(Inst) = .empty,

    fn pc(self: *Compiler) u32 {
        return @intCast(self.prog.items.len);
    }

    fn emit(self: *Compiler, n: *const Node) Regex.Error!void {
        if (self.prog.items.len > 20_000) return error.RegexTooLarge;
        switch (n.*) {
            .empty => {},
            .char => |c| try self.prog.append(self.arena, .{ .char = c }),
            .any => try self.prog.append(self.arena, .any),
            .class => |c| try self.prog.append(self.arena, .{ .class = c }),
            .bol => try self.prog.append(self.arena, .bol),
            .eol => try self.prog.append(self.arena, .eol),
            .cat => |items| for (items) |it| try self.emit(it),
            .alt => |ab| {
                const split = self.pc();
                try self.prog.append(self.arena, .{ .split = .{ 0, 0 } });
                try self.emit(ab[0]);
                const jmp = self.pc();
                try self.prog.append(self.arena, .{ .jmp = 0 });
                const second = self.pc();
                try self.emit(ab[1]);
                self.prog.items[split] = .{ .split = .{ split + 1, second } };
                self.prog.items[jmp] = .{ .jmp = self.pc() };
            },
            .repeat => |r| {
                var k: u32 = 0;
                while (k < r.min) : (k += 1) try self.emit(r.sub);
                if (r.max) |max| {
                    // (max - min) optional copies: split next, end
                    var fixups: std.ArrayList(u32) = .empty;
                    var j: u32 = r.min;
                    while (j < max) : (j += 1) {
                        try fixups.append(self.arena, self.pc());
                        try self.prog.append(self.arena, .{ .split = .{ 0, 0 } });
                        try self.emit(r.sub);
                    }
                    const end = self.pc();
                    for (fixups.items) |f| self.prog.items[f] = .{ .split = .{ f + 1, end } };
                } else {
                    // star: L: split body, end; body; jmp L
                    const l = self.pc();
                    try self.prog.append(self.arena, .{ .split = .{ 0, 0 } });
                    try self.emit(r.sub);
                    try self.prog.append(self.arena, .{ .jmp = l });
                    self.prog.items[l] = .{ .split = .{ l + 1, self.pc() } };
                }
            },
        }
    }
};

/// Convenience: compile + search with a throwaway arena.
pub fn regexSearch(allocator: std.mem.Allocator, pattern: []const u8, text: []const u8) !bool {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const re = try Regex.compile(arena_state.allocator(), pattern);
    return re.search(arena_state.allocator(), text);
}

// ── tests ───────────────────────────────────────────────────────────────────

const t = std.testing;

test "fullProcess mirrors fuzzywuzzy" {
    const out = try fullProcess(t.allocator, "  Untitled - Notepad!! ");
    defer t.allocator.free(out);
    try t.expectEqualStrings("untitled   notepad", out);
}

test "partial_ratio reference values" {
    // fuzz.partial_ratio values from fuzzywuzzy 0.18 + python-Levenshtein.
    try t.expectEqual(@as(u8, 100), try score(t.allocator, "notepad", "Untitled - Notepad"));
    try t.expectEqual(@as(u8, 100), try score(t.allocator, "Chrome", "GitHub - Google Chrome"));
    try t.expectEqual(@as(u8, 0), try score(t.allocator, "", "anything"));
    const s = try score(t.allocator, "notpad", "Untitled - Notepad");
    try t.expect(s >= 83 and s < 100); // one deletion away
    const low = try score(t.allocator, "zzzz", "Untitled - Notepad");
    try t.expect(low < 30);
}

test "regex search: anchors, classes, alternation, repeats, case-insensitive" {
    const a = t.allocator;
    try t.expect(try regexSearch(a, "notepad$", "Untitled - Notepad"));
    try t.expect(!try regexSearch(a, "^notepad", "Untitled - Notepad"));
    try t.expect(try regexSearch(a, "^untitled", "Untitled - Notepad"));
    try t.expect(try regexSearch(a, "chrome|firefox", "Mozilla Firefox"));
    try t.expect(try regexSearch(a, "v\\d+\\.\\d+", "App v12.3 beta"));
    try t.expect(!try regexSearch(a, "v\\d+\\.\\d+", "App v12 beta"));
    try t.expect(try regexSearch(a, "[a-c]{3}", "xxABCxx"));
    try t.expect(!try regexSearch(a, "^[a-c]{3}$", "abcd"));
    try t.expect(try regexSearch(a, "(?:foo|bar)+baz", "barfoobaz"));
    try t.expect(try regexSearch(a, "colou?r", "Color picker"));
    try t.expect(try regexSearch(a, ".*", ""));
    try t.expect(try regexSearch(a, "[^0-9]x", "ax"));
    try t.expect(!try regexSearch(a, "[^0-9]x", "1x"));
    try t.expect(try regexSearch(a, "\\s-\\s", "a - b"));
    try t.expectError(error.BadRegex, regexSearch(a, "(unclosed", "x"));
    try t.expectError(error.BadRegex, regexSearch(a, "*x", "x"));
}

test "regex is linear on the classic pathological pattern" {
    const a = t.allocator;
    const text = "a" ** 64;
    try t.expect(!try regexSearch(a, "(a*)*b", text));
}
