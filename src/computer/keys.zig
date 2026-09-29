//! Key-name → virtual-key mapping and combo parsing.
//!
//! Accepts the union of both upstream vocabularies:
//!   - pyautogui names used by computer_control (`enter`, `pgdn`, `winleft`,
//!     `volumeup`, `num5`, `f13`, ...), and
//!   - clawdcursor names from src/platform/keys.ts (`Return`, `Control`,
//!     `Super`, `mod`, `page_up`, spelled-out symbols like `plus`/`asterisk`).
//!
//! Everything here is pure: printable characters that depend on the keyboard
//! layout are resolved through an injectable `ScanFn` (VkKeyScanW in
//! production, a fake US layout in tests).

const std = @import("std");

pub const VK_SHIFT: u16 = 0x10;
pub const VK_CONTROL: u16 = 0x11;
pub const VK_MENU: u16 = 0x12;
pub const VK_LWIN: u16 = 0x5B;
pub const VK_RETURN: u16 = 0x0D;
pub const VK_TAB: u16 = 0x09;

/// Modifier set. Left/right variants collapse onto the generic key when
/// comparing combos (blocklist), but keep their own VK when pressed.
pub const Mods = packed struct(u4) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    win: bool = false,

    pub fn eql(a: Mods, b: Mods) bool {
        return @as(u4, @bitCast(a)) == @as(u4, @bitCast(b));
    }
};

/// A resolved key. `vk == 0` means "no virtual key on this layout; type
/// `unicode` with KEYEVENTF_UNICODE instead".
pub const Key = struct {
    vk: u16 = 0,
    unicode: u16 = 0,
    /// Extra modifiers the layout needs to produce this character
    /// (e.g. `!` is Shift+1 on US).
    needs: Mods = .{},
};

/// `VkKeyScanW`-shaped lookup: low byte = VK, high byte = shift state
/// (1 shift, 2 ctrl, 4 alt); -1 when the layout has no key for `ch`.
pub const ScanFn = *const fn (ch: u16) i16;

pub const Error = error{ UnknownKey, EmptyKey, EmptyCombo };

const NamedKey = struct { []const u8, u16 };

/// Lower-case name → VK. Covers pyautogui's KEYBOARD_KEYS (Windows subset)
/// plus clawdcursor's KEY_ALIASES.
const named = [_]NamedKey{
    // enter / whitespace / editing
    .{ "enter", 0x0D },         .{ "return", 0x0D },         .{ "\n", 0x0D },             .{ "\r", 0x0D },
    .{ "tab", 0x09 },           .{ "\t", 0x09 },             .{ "space", 0x20 },          .{ "spacebar", 0x20 },
    .{ " ", 0x20 },             .{ "backspace", 0x08 },      .{ "\x08", 0x08 },           .{ "esc", 0x1B },
    .{ "escape", 0x1B },        .{ "delete", 0x2E },         .{ "del", 0x2E },            .{ "insert", 0x2D },
    .{ "ins", 0x2D },           .{ "clear", 0x0C },
    // navigation
    .{ "home", 0x24 },          .{ "end", 0x23 },            .{ "pageup", 0x21 },         .{ "pgup", 0x21 },
    .{ "page_up", 0x21 },       .{ "prior", 0x21 },          .{ "pagedown", 0x22 },       .{ "pgdn", 0x22 },
    .{ "page_down", 0x22 },     .{ "next", 0x22 },           .{ "up", 0x26 },             .{ "down", 0x28 },
    .{ "left", 0x25 },          .{ "right", 0x27 },          .{ "arrowup", 0x26 },        .{ "arrowdown", 0x28 },
    .{ "arrowleft", 0x25 },     .{ "arrowright", 0x27 },
    // modifiers
    .{ "shift", 0x10 },         .{ "shiftleft", 0xA0 },      .{ "lshift", 0xA0 },         .{ "shiftright", 0xA1 },
    .{ "rshift", 0xA1 },        .{ "ctrl", 0x11 },           .{ "control", 0x11 },        .{ "ctrlleft", 0xA2 },
    .{ "lctrl", 0xA2 },         .{ "ctrlright", 0xA3 },      .{ "rctrl", 0xA3 },          .{ "mod", 0x11 },
    .{ "alt", 0x12 },           .{ "option", 0x12 },         .{ "opt", 0x12 },            .{ "menu", 0x12 },
    .{ "altleft", 0xA4 },       .{ "lalt", 0xA4 },           .{ "altright", 0xA5 },       .{ "ralt", 0xA5 },
    .{ "altgr", 0xA5 },         .{ "win", 0x5B },            .{ "windows", 0x5B },        .{ "winleft", 0x5B },
    .{ "lwin", 0x5B },          .{ "winright", 0x5C },       .{ "rwin", 0x5C },           .{ "super", 0x5B },
    .{ "super_l", 0x5B },       .{ "meta", 0x5B },           .{ "cmd", 0x5B },            .{ "command", 0x5B },
    .{ "command_l", 0x5B },
    // locks / system
    .{ "capslock", 0x14 },      .{ "numlock", 0x90 },        .{ "scrolllock", 0x91 },     .{ "printscreen", 0x2C },
    .{ "prtsc", 0x2C },         .{ "prtscr", 0x2C },         .{ "prntscrn", 0x2C },       .{ "print_screen", 0x2C },
    .{ "snapshot", 0x2C },      .{ "pause", 0x13 },          .{ "apps", 0x5D },           .{ "contextmenu", 0x5D },
    .{ "select", 0x29 },        .{ "print", 0x2A },          .{ "execute", 0x2B },        .{ "help", 0x2F },
    .{ "sleep", 0x5F },
    // IME
    .{ "kana", 0x15 },          .{ "hangul", 0x15 },         .{ "hanguel", 0x15 },        .{ "junja", 0x17 },
    .{ "final", 0x18 },         .{ "hanja", 0x19 },          .{ "kanji", 0x19 },          .{ "convert", 0x1C },
    .{ "nonconvert", 0x1D },    .{ "accept", 0x1E },         .{ "modechange", 0x1F },
    // numpad
    .{ "multiply", 0x6A },      .{ "add", 0x6B },            .{ "separator", 0x6C },      .{ "subtract", 0x6D },
    .{ "decimal", 0x6E },       .{ "divide", 0x6F },
    // media / browser
    .{ "volumemute", 0xAD },    .{ "volumedown", 0xAE },     .{ "volumeup", 0xAF },       .{ "nexttrack", 0xB0 },
    .{ "prevtrack", 0xB1 },     .{ "stop", 0xB2 },           .{ "playpause", 0xB3 },      .{ "browserback", 0xA6 },
    .{ "browserforward", 0xA7 }, .{ "browserrefresh", 0xA8 }, .{ "browserstop", 0xA9 },   .{ "browsersearch", 0xAA },
    .{ "browserfavorites", 0xAB }, .{ "browserhome", 0xAC },  .{ "launchmail", 0xB4 },    .{ "launchmediaselect", 0xB5 },
    .{ "launchapp1", 0xB6 },    .{ "launchapp2", 0xB7 },
};

const NamedChar = struct { []const u8, u8 };

/// clawdcursor spells symbols as words ("plus", "asterisk", ...).
const named_chars = [_]NamedChar{
    .{ "asterisk", '*' },     .{ "star", '*' },          .{ "plus", '+' },         .{ "minus", '-' },
    .{ "dash", '-' },         .{ "hyphen", '-' },        .{ "slash", '/' },        .{ "forwardslash", '/' },
    .{ "backslash", '\\' },   .{ "equals", '=' },        .{ "equal", '=' },        .{ "at", '@' },
    .{ "hash", '#' },         .{ "hashtag", '#' },       .{ "dollar", '$' },       .{ "percent", '%' },
    .{ "ampersand", '&' },    .{ "underscore", '_' },    .{ "period", '.' },       .{ "dot", '.' },
    .{ "comma", ',' },        .{ "colon", ':' },         .{ "semicolon", ';' },    .{ "exclamation", '!' },
    .{ "question", '?' },     .{ "tilde", '~' },         .{ "pipe", '|' },         .{ "caret", '^' },
    .{ "leftparen", '(' },    .{ "rightparen", ')' },    .{ "leftbracket", '[' },  .{ "rightbracket", ']' },
    .{ "leftbrace", '{' },    .{ "rightbrace", '}' },    .{ "lessthan", '<' },     .{ "greaterthan", '>' },
    .{ "quote", '\'' },       .{ "singlequote", '\'' },  .{ "doublequote", '"' },  .{ "backtick", '`' },
    .{ "grave", '`' },
};

fn lowerInto(buf: []u8, s: []const u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..s.len];
}

fn lookupNamed(lower: []const u8) ?u16 {
    for (named) |e| if (std.mem.eql(u8, e[0], lower)) return e[1];
    // f1..f24
    if (lower.len >= 2 and lower.len <= 3 and lower[0] == 'f') {
        const n = std.fmt.parseInt(u8, lower[1..], 10) catch return null;
        if (n >= 1 and n <= 24) return 0x70 + @as(u16, n) - 1;
    }
    // num0..num9 / numpad0..numpad9
    for ([_][]const u8{ "numpad", "num" }) |prefix| {
        if (lower.len == prefix.len + 1 and std.mem.startsWith(u8, lower, prefix)) {
            const d = lower[prefix.len];
            if (d >= '0' and d <= '9') return 0x60 + @as(u16, d - '0');
        }
    }
    return null;
}

/// True for keys that need KEYEVENTF_EXTENDEDKEY (arrows, nav cluster,
/// right-hand modifiers, Win, Apps, numpad divide, NumLock, PrintScreen,
/// media and browser keys).
pub fn isExtended(vk: u16) bool {
    return switch (vk) {
        0x21...0x28, 0x2C, 0x2D, 0x2E, 0x5B, 0x5C, 0x5D, 0x6F, 0x90, 0xA3, 0xA5, 0xA6...0xB7 => true,
        else => false,
    };
}

pub fn modsFromShiftState(state: u8) Mods {
    return .{ .shift = state & 1 != 0, .ctrl = state & 2 != 0, .alt = state & 4 != 0 };
}

/// Which modifier bit a VK represents, if any.
pub fn modOf(vk: u16) ?Mods {
    return switch (vk) {
        0x10, 0xA0, 0xA1 => .{ .shift = true },
        0x11, 0xA2, 0xA3 => .{ .ctrl = true },
        0x12, 0xA4, 0xA5 => .{ .alt = true },
        0x5B, 0x5C => .{ .win = true },
        else => null,
    };
}

/// Resolve one key token (already trimmed). `in_combo` suppresses the
/// implicit Shift for an upper-case letter (so "ctrl+A" is Ctrl+A, while a
/// lone "A" types a capital like pyautogui's `press("A")`).
pub fn resolve(token: []const u8, scan: ScanFn, in_combo: bool) Error!Key {
    if (token.len == 0) return error.EmptyKey;
    var buf: [32]u8 = undefined;
    if (lowerInto(&buf, token)) |lower| {
        if (lookupNamed(lower)) |vk| return .{ .vk = vk };
        for (named_chars) |e| if (std.mem.eql(u8, e[0], lower)) return resolveChar(e[1], scan);
    }
    // A single code point.
    const cp_len = std.unicode.utf8ByteSequenceLength(token[0]) catch return error.UnknownKey;
    if (cp_len != token.len) return error.UnknownKey;
    const cp = std.unicode.utf8Decode(token) catch return error.UnknownKey;
    if (cp >= 'a' and cp <= 'z') return .{ .vk = @intCast(cp - 'a' + 'A') };
    if (cp >= 'A' and cp <= 'Z') return .{ .vk = @intCast(cp), .needs = .{ .shift = !in_combo } };
    if (cp >= '0' and cp <= '9') return .{ .vk = @intCast(cp) };
    if (cp > 0xFFFF) return error.UnknownKey; // needs a surrogate pair; use type_text
    return resolveChar(@intCast(cp), scan);
}

fn resolveChar(ch: u16, scan: ScanFn) Key {
    const r = scan(ch);
    if (r == -1) return .{ .unicode = ch };
    const bits: u16 = @bitCast(r);
    return .{ .vk = bits & 0xFF, .needs = modsFromShiftState(@intCast(bits >> 8)) };
}

pub const max_combo_keys = 8;

/// A parsed combo: keys pressed in order, released in reverse.
pub const Combo = struct {
    keys: [max_combo_keys]Key = undefined,
    len: usize = 0,

    pub fn slice(self: *const Combo) []const Key {
        return self.keys[0..self.len];
    }
};

pub fn orMods(a: Mods, b: Mods) Mods {
    return @bitCast(@as(u4, @bitCast(a)) | @as(u4, @bitCast(b)));
}

/// Parse "ctrl+shift+s", "Alt + Tab", "ctrl++" (Ctrl and '+'), "+" or a
/// single key. A combo is only split on '+' when it has more than one
/// character, so a literal "+" stays a key.
pub fn parseCombo(s_in: []const u8, scan: ScanFn) Error!Combo {
    const s = std.mem.trim(u8, s_in, " ");
    if (s.len == 0) return error.EmptyCombo;
    var combo: Combo = .{};
    if (s.len == 1 or std.mem.indexOfScalar(u8, s, '+') == null) {
        combo.keys[0] = try resolve(s, scan, false);
        combo.len = 1;
        return combo;
    }
    // A trailing "+" (e.g. "ctrl++") means the '+' key itself.
    var body = s;
    var trailing_plus = false;
    if (std.mem.endsWith(u8, body, "++")) {
        trailing_plus = true;
        body = body[0 .. body.len - 2];
    }
    var it = std.mem.splitScalar(u8, body, '+');
    while (it.next()) |raw| {
        const tok = std.mem.trim(u8, raw, " ");
        if (tok.len == 0) continue;
        if (combo.len == max_combo_keys) return error.UnknownKey;
        combo.keys[combo.len] = try resolve(tok, scan, true);
        combo.len += 1;
    }
    if (trailing_plus) {
        if (combo.len == max_combo_keys) return error.UnknownKey;
        combo.keys[combo.len] = try resolve("+", scan, true);
        combo.len += 1;
    }
    if (combo.len == 0) return error.EmptyCombo;
    return combo;
}

// ── Destructive-combo blocklist ─────────────────────────────────────────────

const Blocked = struct { mods: Mods, vk: u16, label: []const u8 };

/// Port of clawdcursor's playbooks/keys-blocklist.ts (Windows entries),
/// compared order-insensitively on (modifier set, key) instead of on the
/// normalized string, so "ctrl+alt+del" and "alt+ctrl+delete" both match.
const blocked = [_]Blocked{
    .{ .mods = .{ .alt = true }, .vk = 0x73, .label = "alt+f4" },
    .{ .mods = .{ .ctrl = true, .alt = true }, .vk = 0x2E, .label = "ctrl+alt+delete" },
    .{ .mods = .{ .win = true }, .vk = 'L', .label = "win+l" },
    .{ .mods = .{ .win = true }, .vk = 'R', .label = "win+r" },
    .{ .mods = .{ .win = true }, .vk = 'D', .label = "win+d" },
    .{ .mods = .{}, .vk = 0x7A, .label = "f11" },
    .{ .mods = .{ .ctrl = true, .shift = true }, .vk = 0x1B, .label = "ctrl+shift+esc" },
    .{ .mods = .{ .ctrl = true }, .vk = 'W', .label = "ctrl+w" },
};

/// Collapse left/right and alias modifier VKs onto the generic key
/// (LSHIFT/RSHIFT → SHIFT, LCONTROL/RCONTROL → CONTROL, LMENU/RMENU → MENU,
/// RWIN → LWIN). Name aliases (menu/alt/option, win/super/meta/cmd,
/// ctrl/control/mod) already resolve to these VKs in `resolve`.
pub fn normVk(vk: u16) u16 {
    return switch (vk) {
        0x10, 0xA0, 0xA1 => VK_SHIFT,
        0x11, 0xA2, 0xA3 => VK_CONTROL,
        0x12, 0xA4, 0xA5 => VK_MENU,
        0x5B, 0x5C => VK_LWIN,
        else => vk,
    };
}

/// A set of keys currently down (normalized VKs). Used both for a combo
/// on its own and for the keys held across key_down/key_up calls.
pub const KeyState = struct {
    vks: [24]u16 = undefined,
    len: usize = 0,

    pub fn has(self: *const KeyState, vk: u16) bool {
        const n = normVk(vk);
        for (self.vks[0..self.len]) |v| if (v == n) return true;
        return false;
    }

    pub fn add(self: *KeyState, vk: u16) void {
        if (vk == 0 or self.has(vk)) return;
        if (self.len == self.vks.len) return;
        self.vks[self.len] = normVk(vk);
        self.len += 1;
    }

    pub fn remove(self: *KeyState, vk: u16) void {
        const n = normVk(vk);
        var i: usize = 0;
        while (i < self.len) {
            if (self.vks[i] == n) {
                self.vks[i] = self.vks[self.len - 1];
                self.len -= 1;
            } else i += 1;
        }
    }

    pub fn merge(self: *KeyState, other: *const KeyState) void {
        for (other.vks[0..other.len]) |v| self.add(v);
    }

    pub fn mods(self: *const KeyState) Mods {
        var m: Mods = .{};
        for (self.vks[0..self.len]) |v| if (modOf(v)) |mm| {
            m = orMods(m, mm);
        };
        return m;
    }

    pub fn addMods(self: *KeyState, m: Mods) void {
        if (m.shift) self.add(VK_SHIFT);
        if (m.ctrl) self.add(VK_CONTROL);
        if (m.alt) self.add(VK_MENU);
        if (m.win) self.add(VK_LWIN);
    }
};

fn subset(small: Mods, big: Mods) bool {
    const a: u4 = @bitCast(small);
    const b: u4 = @bitCast(big);
    return a & b == a;
}

/// Label of a blocked chord CONTAINED in `st`: its modifiers are a subset
/// of the held modifiers and its key is among the held keys. So
/// "shift+alt+f4", "alt+f4+x" and "alt" held then "f4" are all refused.
pub fn blockedInState(st: *const KeyState) ?[]const u8 {
    const m = st.mods();
    for (blocked) |b| {
        if (subset(b.mods, m) and st.has(b.vk)) return b.label;
    }
    return null;
}

/// Chords the strict policy (zmcp-desktop) refuses on top of `blocked`.
const strict_extra = [_]Blocked{
    .{ .mods = .{ .alt = true }, .vk = 0x09, .label = "alt+tab" },
    .{ .mods = .{ .alt = true }, .vk = 0x1B, .label = "alt+esc" },
    .{ .mods = .{ .alt = true }, .vk = 0x20, .label = "alt+space" },
    .{ .mods = .{ .ctrl = true }, .vk = 0x1B, .label = "ctrl+esc" },
};

/// The strict policy: everything `blockedInState` refuses, plus the Windows
/// key held at all (alone or in any chord; lwin/rwin/super/meta/cmd are
/// aliases), ctrl+alt held together (with anything), and alt+tab, alt+esc,
/// alt+space, ctrl+esc (with any extra modifiers).
pub fn strictBlockedInState(st: *const KeyState) ?[]const u8 {
    if (blockedInState(st)) |l| return l;
    const m = st.mods();
    if (m.win) return "win+*";
    if (m.ctrl and m.alt) return "ctrl+alt+*";
    for (strict_extra) |b| {
        if (subset(b.mods, m) and st.has(b.vk)) return b.label;
    }
    return null;
}

/// Every key of the combo plus the modifiers the layout needs, as a state.
pub fn comboState(combo: *const Combo) KeyState {
    var st: KeyState = .{};
    for (combo.slice()) |k| {
        st.addMods(k.needs);
        st.add(if (k.vk != 0) k.vk else 0);
    }
    return st;
}

/// Returns the blocklist label when `combo` contains a blocked chord.
pub fn blockedLabel(combo: *const Combo) ?[]const u8 {
    const st = comboState(combo);
    return blockedInState(&st);
}

// ── tests ───────────────────────────────────────────────────────────────────

/// US-layout stand-in for VkKeyScanW.
pub fn fakeUsScan(ch: u16) i16 {
    const shifted = "!@#$%^&*()";
    return switch (ch) {
        '+' => 0x01BB, // Shift + VK_OEM_PLUS
        '=' => 0x00BB,
        '-' => 0x00BD,
        '_' => 0x01BD,
        '/' => 0x00BF,
        '?' => 0x01BF,
        '.' => 0x00BE,
        ',' => 0x00BC,
        ';' => 0x00BA,
        '\'' => 0x00DE,
        '`' => 0x00C0,
        '[' => 0x00DB,
        ']' => 0x00DD,
        '\\' => 0x00DC,
        else => blk: {
            if (ch < 128) {
                if (std.mem.indexOfScalar(u8, shifted, @intCast(ch))) |i| {
                    const digit: u16 = if (i == 9) '0' else '1' + @as(u16, @intCast(i));
                    break :blk @bitCast(@as(u16, 0x0100) | digit);
                }
            }
            break :blk -1;
        },
    };
}

const t = std.testing;

test "pyautogui and clawdcursor names resolve to the same VKs" {
    const pairs = [_]struct { []const u8, u16 }{
        .{ "enter", 0x0D },    .{ "Return", 0x0D },  .{ "esc", 0x1B },     .{ "Escape", 0x1B },
        .{ "pgdn", 0x22 },     .{ "PageDown", 0x22 }, .{ "page_up", 0x21 }, .{ "ctrl", 0x11 },
        .{ "Control", 0x11 },  .{ "mod", 0x11 },     .{ "win", 0x5B },     .{ "Super", 0x5B },
        .{ "cmd", 0x5B },      .{ "F5", 0x74 },      .{ "f24", 0x87 },     .{ "num7", 0x67 },
        .{ "volumeup", 0xAF }, .{ "Tab", 0x09 },     .{ "space", 0x20 },   .{ "winright", 0x5C },
    };
    for (pairs) |p| {
        const k = try resolve(p[0], fakeUsScan, false);
        try t.expectEqual(p[1], k.vk);
    }
    try t.expectError(error.UnknownKey, resolve("f25", fakeUsScan, false));
    try t.expectError(error.UnknownKey, resolve("notakey", fakeUsScan, false));
}

test "letters, digits and shifted punctuation" {
    try t.expectEqual(@as(u16, 'A'), (try resolve("a", fakeUsScan, false)).vk);
    const cap = try resolve("A", fakeUsScan, false);
    try t.expect(cap.needs.shift);
    const cap_combo = try resolve("A", fakeUsScan, true);
    try t.expect(!cap_combo.needs.shift);
    const bang = try resolve("!", fakeUsScan, false);
    try t.expectEqual(@as(u16, '1'), bang.vk);
    try t.expect(bang.needs.shift);
    const plus = try resolve("plus", fakeUsScan, false);
    try t.expectEqual(@as(u16, 0xBB), plus.vk);
    try t.expect(plus.needs.shift);
    // Not on the layout: falls back to a Unicode keystroke.
    const euro = try resolve("€", fakeUsScan, false);
    try t.expectEqual(@as(u16, 0), euro.vk);
    try t.expectEqual(@as(u16, 0x20AC), euro.unicode);
}

test "combo parsing: spacing, case, literal plus" {
    const c = try parseCombo(" Ctrl + Shift + s ", fakeUsScan);
    try t.expectEqual(@as(usize, 3), c.len);
    try t.expectEqual(@as(u16, 0x11), c.keys[0].vk);
    try t.expectEqual(@as(u16, 0x10), c.keys[1].vk);
    try t.expectEqual(@as(u16, 'S'), c.keys[2].vk);

    const zoom = try parseCombo("ctrl++", fakeUsScan);
    try t.expectEqual(@as(usize, 2), zoom.len);
    try t.expectEqual(@as(u16, 0xBB), zoom.keys[1].vk);

    const lone = try parseCombo("+", fakeUsScan);
    try t.expectEqual(@as(usize, 1), lone.len);

    const minus = try parseCombo("ctrl+-", fakeUsScan);
    try t.expectEqual(@as(u16, 0xBD), minus.keys[1].vk);

    try t.expectError(error.EmptyCombo, parseCombo("  ", fakeUsScan));
    try t.expectError(error.UnknownKey, parseCombo("ctrl+bogus", fakeUsScan));
}

test "blocklist is order- and alias-insensitive" {
    const cases_blocked = [_][]const u8{ "alt+f4", "F4+Alt", "Alt + F4", "ctrl+alt+del", "alt+control+delete", "win+l", "Super+L", "ctrl+w", "f11", "ctrl+shift+esc", "altleft+f4" };
    for (cases_blocked) |s| {
        const c = try parseCombo(s, fakeUsScan);
        try t.expect(blockedLabel(&c) != null);
    }
    const cases_ok = [_][]const u8{ "ctrl+s", "alt+tab", "f4", "shift+w", "win+e", "ctrl+alt+t", "alt+f5" };
    for (cases_ok) |s| {
        const c = try parseCombo(s, fakeUsScan);
        try t.expect(blockedLabel(&c) == null);
    }
}

test "extended-key flags" {
    try t.expect(isExtended(0x25)); // left arrow
    try t.expect(isExtended(0x2E)); // delete
    try t.expect(isExtended(0x5B)); // win
    try t.expect(!isExtended('A'));
    try t.expect(!isExtended(0x0D));
}

test "blocklist refuses combos that contain a blocked chord" {
    for ([_][]const u8{ "alt+f4+x", "shift+alt+f4", "ctrl+alt+f4", "ctrl+shift+w", "ctrl+alt+shift+del", "win+shift+l", "menu+f4", "altright+f4", "rwin+r", "lwin+d", "control+w", "meta+l", "super+r", "ctrl+f11", "rctrl+rshift+esc" }) |s| {
        const c = try parseCombo(s, fakeUsScan);
        try t.expect(blockedLabel(&c) != null);
    }
}

test "strict policy: any win key, ctrl+alt+*, alt+tab/esc/space, ctrl+esc" {
    for ([_][]const u8{ "win", "lwin", "rwin", "super", "meta", "cmd", "win+e", "winright+x", "ctrl+alt+t", "rctrl+ralt+a", "alt+tab", "shift+alt+tab", "alt+esc", "alt+escape", "alt+space", "altleft+spacebar", "ctrl+esc", "control+escape", "ctrl+shift+esc", "alt+f4", "ctrl+alt+del", "win+r" }) |s| {
        const c = try parseCombo(s, fakeUsScan);
        const st = comboState(&c);
        try t.expect(strictBlockedInState(&st) != null);
    }
    for ([_][]const u8{ "enter", "tab", "shift+tab", "esc", "escape", "space", "ctrl+a", "ctrl+z", "shift+left", "ctrl+end", "backspace", "f2" }) |s| {
        const c = try parseCombo(s, fakeUsScan);
        const st = comboState(&c);
        try t.expect(strictBlockedInState(&st) == null);
    }
    // Held across calls: alt held, then space.
    var st: KeyState = .{};
    st.add(0xA4);
    st.add(0x20);
    try t.expectEqualStrings("alt+space", strictBlockedInState(&st).?);
}

test "held-key state: alt held then f4 is blocked, released alt is not" {
    var st: KeyState = .{};
    st.add(0xA4); // left alt held via key_down
    try t.expect(blockedInState(&st) == null);
    var next = st;
    next.add(0x73);
    try t.expectEqualStrings("alt+f4", blockedInState(&next).?);
    st.remove(VK_MENU); // key_up alt (generic) releases the left-alt entry
    st.add(0x73);
    try t.expect(blockedInState(&st) == null);
}
