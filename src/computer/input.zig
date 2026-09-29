//! SendInput sequences.
//!
//! Every INPUT built here carries `NAVA_INPUT_TAG` in dwExtraInfo, and
//! `send` sets it again on every event before SendInput, so all input from
//! zmcp-computer and zmcp-desktop is recognisable as ours: Nava's auto-pause
//! hook (and zmcp-desktop's own) treats only injected events carrying the tag
//! as automation, and anything else as the user taking over.
//!
//! Builders are pure (they only fill `INPUT` structs) and are what the unit
//! tests exercise. The single function that injects (`send`) refuses to run
//! inside a test binary and when ZMCP_COMPUTER_DRY_RUN is set, so no test can
//! ever move the pointer or press a key on the machine running it.

const std = @import("std");
const builtin = @import("builtin");
const w = @import("win32.zig");
const keys = @import("keys.zig");

/// dwExtraInfo of every KEYBDINPUT and MOUSEINPUT we send: "NAVA".
pub const NAVA_INPUT_TAG: usize = 0x4E415641;

pub const Button = enum { left, right, middle };

pub fn parseButton(s: []const u8) ?Button {
    if (std.ascii.eqlIgnoreCase(s, "left") or std.ascii.eqlIgnoreCase(s, "primary")) return .left;
    if (std.ascii.eqlIgnoreCase(s, "right") or std.ascii.eqlIgnoreCase(s, "secondary")) return .right;
    if (std.ascii.eqlIgnoreCase(s, "middle")) return .middle;
    return null;
}

pub const VirtualScreen = struct { x: i32, y: i32, w: i32, h: i32 };

/// Pixel → SendInput normalized absolute coordinate over the virtual desktop.
/// Windows maps back with `pixel = floor(n * size / 65536)`; ceil here makes
/// that round-trip exact for every size up to 65536 px.
pub fn normalize(pixel: i32, origin: i32, size: i32) i32 {
    if (size <= 0) return 0;
    const rel: i64 = @as(i64, pixel) - origin;
    const n = @divFloor(rel * 65536 + size - 1, size);
    return @intCast(std.math.clamp(n, 0, 65535));
}

pub fn denormalize(n: i32, origin: i32, size: i32) i32 {
    return origin + @as(i32, @intCast(@divFloor(@as(i64, n) * size, 65536)));
}

pub fn mouseMove(x: i32, y: i32, vs: VirtualScreen) w.INPUT {
    return .{ .type = w.INPUT_MOUSE, .u = .{ .mi = .{
        .dx = normalize(x, vs.x, vs.w),
        .dy = normalize(y, vs.y, vs.h),
        .dwFlags = w.MOUSEEVENTF_MOVE | w.MOUSEEVENTF_ABSOLUTE | w.MOUSEEVENTF_VIRTUALDESK,
        .dwExtraInfo = NAVA_INPUT_TAG,
    } } };
}

pub fn mouseButton(button: Button, up: bool) w.INPUT {
    const flags: u32 = switch (button) {
        .left => if (up) w.MOUSEEVENTF_LEFTUP else w.MOUSEEVENTF_LEFTDOWN,
        .right => if (up) w.MOUSEEVENTF_RIGHTUP else w.MOUSEEVENTF_RIGHTDOWN,
        .middle => if (up) w.MOUSEEVENTF_MIDDLEUP else w.MOUSEEVENTF_MIDDLEDOWN,
    };
    return .{ .type = w.INPUT_MOUSE, .u = .{ .mi = .{ .dwFlags = flags, .dwExtraInfo = NAVA_INPUT_TAG } } };
}

/// Wheel ticks: positive = up (vertical) / right (horizontal), like Win32.
pub fn wheel(ticks: i32, horizontal: bool) w.INPUT {
    const delta: i32 = ticks * w.WHEEL_DELTA;
    return .{ .type = w.INPUT_MOUSE, .u = .{ .mi = .{
        .mouseData = @bitCast(delta),
        .dwFlags = if (horizontal) w.MOUSEEVENTF_HWHEEL else w.MOUSEEVENTF_WHEEL,
        .dwExtraInfo = NAVA_INPUT_TAG,
    } } };
}

pub fn vkEvent(vk: u16, up: bool) w.INPUT {
    var flags: u32 = if (up) w.KEYEVENTF_KEYUP else 0;
    if (keys.isExtended(vk)) flags |= w.KEYEVENTF_EXTENDEDKEY;
    return .{ .type = w.INPUT_KEYBOARD, .u = .{ .ki = .{ .wVk = vk, .dwFlags = flags, .dwExtraInfo = NAVA_INPUT_TAG } } };
}

pub fn unicodeEvent(unit: u16, up: bool) w.INPUT {
    const flags: u32 = w.KEYEVENTF_UNICODE | (if (up) w.KEYEVENTF_KEYUP else 0);
    return .{ .type = w.INPUT_KEYBOARD, .u = .{ .ki = .{ .wScan = unit, .dwFlags = flags, .dwExtraInfo = NAVA_INPUT_TAG } } };
}

fn keyEvent(k: keys.Key, up: bool) w.INPUT {
    return if (k.vk != 0) vkEvent(k.vk, up) else unicodeEvent(k.unicode, up);
}

const mod_vks = [_]struct { keys.Mods, u16 }{
    .{ .{ .ctrl = true }, keys.VK_CONTROL },
    .{ .{ .alt = true }, keys.VK_MENU },
    .{ .{ .shift = true }, keys.VK_SHIFT },
    .{ .{ .win = true }, keys.VK_LWIN },
};

fn hasMod(set: keys.Mods, one: keys.Mods) bool {
    return @as(u4, @bitCast(set)) & @as(u4, @bitCast(one)) != 0;
}

/// Press a combo: explicit keys down in order, then any modifiers the
/// layout needs for the final character (e.g. Shift for '!'), release all in
/// reverse. Layout modifiers already held explicitly are not doubled.
pub fn appendCombo(list: *std.ArrayList(w.INPUT), allocator: std.mem.Allocator, combo: *const keys.Combo) !void {
    var held: keys.Mods = .{};
    for (combo.slice()) |k| if (keys.modOf(k.vk)) |m| {
        held = keys.orMods(held, m);
    };
    var extra: [4]u16 = undefined;
    var n_extra: usize = 0;
    for (combo.slice()) |k| {
        for (mod_vks) |mv| {
            if (hasMod(k.needs, mv[0]) and !hasMod(held, mv[0])) {
                held = keys.orMods(held, mv[0]);
                extra[n_extra] = mv[1];
                n_extra += 1;
            }
        }
    }
    // Explicit modifiers first (in the order given), then layout extras,
    // then the non-modifier keys.
    for (combo.slice()) |k| if (keys.modOf(k.vk) != null) try list.append(allocator, keyEvent(k, false));
    for (extra[0..n_extra]) |vk| try list.append(allocator, vkEvent(vk, false));
    for (combo.slice()) |k| if (keys.modOf(k.vk) == null) try list.append(allocator, keyEvent(k, false));
    var i = combo.len;
    while (i > 0) {
        i -= 1;
        const k = combo.keys[i];
        if (keys.modOf(k.vk) == null) try list.append(allocator, keyEvent(k, true));
    }
    var j = n_extra;
    while (j > 0) {
        j -= 1;
        try list.append(allocator, vkEvent(extra[j], true));
    }
    i = combo.len;
    while (i > 0) {
        i -= 1;
        const k = combo.keys[i];
        if (keys.modOf(k.vk) != null) try list.append(allocator, keyEvent(k, true));
    }
}

/// Text as KEYEVENTF_UNICODE keystrokes (layout- and IME-independent, and
/// the clipboard is never touched). `\n`, `\r\n` and `\r` become Enter and
/// `\t` becomes Tab as real VK presses, because many controls ignore a
/// Unicode CR/TAB. Characters outside the BMP are sent as their surrogate
/// pair, each unit as its own down/up.
pub fn appendText(list: *std.ArrayList(w.INPUT), allocator: std.mem.Allocator, text: []const u8) !void {
    var view = std.unicode.Wtf8View.init(text) catch return error.InvalidUtf8;
    var it = view.iterator();
    var prev_cr = false;
    while (it.nextCodepoint()) |cp| {
        if (cp == '\n' and prev_cr) {
            prev_cr = false;
            continue;
        }
        prev_cr = cp == '\r';
        if (cp == '\n' or cp == '\r') {
            try list.append(allocator, vkEvent(keys.VK_RETURN, false));
            try list.append(allocator, vkEvent(keys.VK_RETURN, true));
            continue;
        }
        if (cp == '\t') {
            try list.append(allocator, vkEvent(keys.VK_TAB, false));
            try list.append(allocator, vkEvent(keys.VK_TAB, true));
            continue;
        }
        var units: [2]u16 = undefined;
        const n: usize = if (cp >= 0x10000) blk: {
            const v = cp - 0x10000;
            units[0] = @intCast(0xD800 + (v >> 10));
            units[1] = @intCast(0xDC00 + (v & 0x3FF));
            break :blk 2;
        } else blk: {
            units[0] = @intCast(cp);
            break :blk 1;
        };
        for (units[0..n]) |u| {
            try list.append(allocator, unicodeEvent(u, false));
            try list.append(allocator, unicodeEvent(u, true));
        }
    }
}

// ── key-state simulation (blocklist over the whole sequence) ───────────────

fn isVkKey(in: w.INPUT) bool {
    return in.type == w.INPUT_KEYBOARD and in.u.ki.dwFlags & w.KEYEVENTF_UNICODE == 0;
}

/// Replay `inputs` on top of `start` (keys already held: our own key_down
/// calls plus modifiers the user is physically holding) and return the
/// label of the first blocked chord that would be down at any moment.
pub fn firstBlocked(inputs: []const w.INPUT, start: keys.KeyState) ?[]const u8 {
    return firstBlockedWith(inputs, start, keys.blockedInState);
}

/// `firstBlocked` under a chosen chord policy (keys.blockedInState or
/// keys.strictBlockedInState).
pub fn firstBlockedWith(inputs: []const w.INPUT, start: keys.KeyState, blocked: *const fn (*const keys.KeyState) ?[]const u8) ?[]const u8 {
    var st = start;
    if (blocked(&st)) |l| return l;
    for (inputs) |in| {
        if (!isVkKey(in)) continue;
        if (in.u.ki.dwFlags & w.KEYEVENTF_KEYUP != 0) {
            st.remove(in.u.ki.wVk);
        } else {
            st.add(in.u.ki.wVk);
            if (blocked(&st)) |l| return l;
        }
    }
    return null;
}

/// Track which keys our injected input leaves held down.
pub fn applyToState(inputs: []const w.INPUT, st: *keys.KeyState) void {
    for (inputs) |in| {
        if (!isVkKey(in)) continue;
        if (in.u.ki.dwFlags & w.KEYEVENTF_KEYUP != 0) st.remove(in.u.ki.wVk) else st.add(in.u.ki.wVk);
    }
}

/// Whether (x, y) lies on the virtual desktop. Points outside are rejected
/// rather than clamped, so a bad coordinate never clicks an edge.
pub fn contains(vs: VirtualScreen, x: i32, y: i32) bool {
    const px: i64 = x;
    const py: i64 = y;
    return px >= vs.x and py >= vs.y and px < @as(i64, vs.x) + vs.w and py < @as(i64, vs.y) + vs.h;
}

// ── injection ───────────────────────────────────────────────────────────────

pub var dry_run: bool = false;

pub const InjectError = error{ InjectionDisabled, SendInputBlocked, PointOutsideDesktop };

/// Set NAVA_INPUT_TAG on every event (the builders already do; this is the
/// backstop for any INPUT built elsewhere).
pub fn tagAll(inputs: []w.INPUT) void {
    for (inputs) |*in| switch (in.type) {
        w.INPUT_KEYBOARD => in.u.ki.dwExtraInfo = NAVA_INPUT_TAG,
        w.INPUT_MOUSE => in.u.mi.dwExtraInfo = NAVA_INPUT_TAG,
        else => {},
    };
}

/// The only call site of SendInput. Tags every event (NAVA_INPUT_TAG), fills
/// scan codes for VK events (some games and remote-desktop clients read
/// wScan, not wVk), then injects in chunks with a short pause so slow
/// message loops don't drop keystrokes.
pub fn send(inputs: []w.INPUT) InjectError!void {
    tagAll(inputs);
    if (builtin.is_test or dry_run) return error.InjectionDisabled;
    for (inputs) |*in| {
        if (in.type == w.INPUT_KEYBOARD and in.u.ki.dwFlags & w.KEYEVENTF_UNICODE == 0 and in.u.ki.wScan == 0) {
            in.u.ki.wScan = @truncate(w.MapVirtualKeyW(in.u.ki.wVk, w.MAPVK_VK_TO_VSC));
        }
    }
    const chunk = 64;
    var i: usize = 0;
    while (i < inputs.len) {
        const n = @min(chunk, inputs.len - i);
        const sent = w.SendInput(@intCast(n), inputs[i..].ptr, @sizeOf(w.INPUT));
        if (sent != n) return error.SendInputBlocked;
        i += n;
        if (i < inputs.len) w.sleepMs(5);
    }
}

/// Place the pointer exactly: an absolute SendInput move (so apps see a
/// real WM_MOUSEMOVE), then SetCursorPos if rounding left it a pixel off.
pub fn moveTo(x: i32, y: i32, vs: VirtualScreen) InjectError!void {
    if (!contains(vs, x, y)) return error.PointOutsideDesktop;
    var one = [_]w.INPUT{mouseMove(x, y, vs)};
    try send(&one);
    var p: w.POINT = undefined;
    if (w.ok(w.GetCursorPos(&p)) and (p.x != x or p.y != y)) _ = w.SetCursorPos(x, y);
}

// ── tests ───────────────────────────────────────────────────────────────────

const t = std.testing;

test "normalize round-trips every pixel for common desktop sizes" {
    const sizes = [_]i32{ 1, 800, 1366, 1920, 2560, 2880, 3840, 5760, 7680 };
    for (sizes) |size| {
        var px: i32 = 0;
        while (px < size) : (px += 1) {
            const n = normalize(px, 0, size);
            try t.expect(n >= 0 and n <= 65535);
            try t.expectEqual(px, denormalize(n, 0, size));
        }
    }
    // Negative virtual-desktop origin (monitor left of primary).
    try t.expectEqual(@as(i32, -1920), denormalize(normalize(-1920, -1920, 3840), -1920, 3840));
    try t.expectEqual(@as(i32, 100), denormalize(normalize(100, -1920, 3840), -1920, 3840));
    // Out-of-range clamps.
    try t.expectEqual(@as(i32, 0), normalize(-5, 0, 1920));
    try t.expectEqual(@as(i32, 65535), normalize(5000, 0, 1920));
}

test "mouse move/button/wheel structs" {
    const m = mouseMove(960, 540, .{ .x = 0, .y = 0, .w = 1920, .h = 1080 });
    try t.expectEqual(w.INPUT_MOUSE, m.type);
    try t.expectEqual(w.MOUSEEVENTF_MOVE | w.MOUSEEVENTF_ABSOLUTE | w.MOUSEEVENTF_VIRTUALDESK, m.u.mi.dwFlags);
    try t.expectEqual(@as(i32, 32768), m.u.mi.dx);
    try t.expectEqual(w.MOUSEEVENTF_RIGHTUP, mouseButton(.right, true).u.mi.dwFlags);
    try t.expectEqual(w.MOUSEEVENTF_MIDDLEDOWN, mouseButton(.middle, false).u.mi.dwFlags);
    const down = wheel(-3, false);
    try t.expectEqual(@as(i32, -360), @as(i32, @bitCast(down.u.mi.mouseData)));
    try t.expectEqual(w.MOUSEEVENTF_HWHEEL, wheel(2, true).u.mi.dwFlags);
}

test "combo sequence: modifiers wrap the key and release in reverse" {
    var list: std.ArrayList(w.INPUT) = .empty;
    defer list.deinit(t.allocator);
    const c = try keys.parseCombo("ctrl+shift+Left", keys.fakeUsScan);
    try appendCombo(&list, t.allocator, &c);
    const want = [_]struct { u16, bool }{
        .{ 0x11, false }, .{ 0x10, false }, .{ 0x25, false },
        .{ 0x25, true },  .{ 0x10, true },  .{ 0x11, true },
    };
    try t.expectEqual(want.len, list.items.len);
    for (want, list.items) |wnt, got| {
        try t.expectEqual(w.INPUT_KEYBOARD, got.type);
        try t.expectEqual(wnt[0], got.u.ki.wVk);
        try t.expectEqual(wnt[1], got.u.ki.dwFlags & w.KEYEVENTF_KEYUP != 0);
    }
    // Left arrow is an extended key; Ctrl is not.
    try t.expect(list.items[2].u.ki.dwFlags & w.KEYEVENTF_EXTENDEDKEY != 0);
    try t.expect(list.items[0].u.ki.dwFlags & w.KEYEVENTF_EXTENDEDKEY == 0);
}

test "layout-implied shift is added once and not doubled" {
    var list: std.ArrayList(w.INPUT) = .empty;
    defer list.deinit(t.allocator);
    const bang = try keys.parseCombo("!", keys.fakeUsScan);
    try appendCombo(&list, t.allocator, &bang);
    try t.expectEqual(@as(usize, 4), list.items.len);
    try t.expectEqual(@as(u16, 0x10), list.items[0].u.ki.wVk);
    try t.expectEqual(@as(u16, '1'), list.items[1].u.ki.wVk);

    list.clearRetainingCapacity();
    const zoom = try keys.parseCombo("ctrl+shift++", keys.fakeUsScan);
    try appendCombo(&list, t.allocator, &zoom);
    try t.expectEqual(@as(usize, 6), list.items.len); // ctrl, shift, '+' (no second shift)
}

test "text becomes unicode keystrokes; newlines and tabs become VK presses" {
    var list: std.ArrayList(w.INPUT) = .empty;
    defer list.deinit(t.allocator);
    try appendText(&list, t.allocator, "hé\r\n\t😀");
    // h, é: 2 units x down/up; CRLF -> one Enter; tab; emoji -> 2 surrogates x down/up
    try t.expectEqual(@as(usize, 4 + 2 + 2 + 4), list.items.len);
    try t.expectEqual(w.KEYEVENTF_UNICODE, list.items[0].u.ki.dwFlags);
    try t.expectEqual(@as(u16, 'h'), list.items[0].u.ki.wScan);
    try t.expectEqual(@as(u16, 0), list.items[0].u.ki.wVk);
    try t.expectEqual(w.KEYEVENTF_UNICODE | w.KEYEVENTF_KEYUP, list.items[1].u.ki.dwFlags);
    try t.expectEqual(@as(u16, 0xE9), list.items[2].u.ki.wScan);
    try t.expectEqual(keys.VK_RETURN, list.items[4].u.ki.wVk);
    try t.expectEqual(keys.VK_TAB, list.items[6].u.ki.wVk);
    try t.expectEqual(@as(u16, 0xD83D), list.items[8].u.ki.wScan);
    try t.expectEqual(@as(u16, 0xDE00), list.items[10].u.ki.wScan);
}

test "send refuses to inject from a test binary" {
    var one = [_]w.INPUT{mouseButton(.left, false)};
    try t.expectError(error.InjectionDisabled, send(&one));
}

test "sequence blocklist: held alt then f4, and chords inside longer sequences" {
    var list: std.ArrayList(w.INPUT) = .empty;
    defer list.deinit(t.allocator);
    const f4 = try keys.parseCombo("f4", keys.fakeUsScan);
    try appendCombo(&list, t.allocator, &f4);
    var held: keys.KeyState = .{};
    try t.expect(firstBlocked(list.items, held) == null);
    held.add(0x12); // key_down alt earlier
    try t.expectEqualStrings("alt+f4", firstBlocked(list.items, held).?);

    // key_down alt, then key_down f4 as one list
    list.clearRetainingCapacity();
    try list.append(t.allocator, vkEvent(0xA4, false));
    try list.append(t.allocator, vkEvent(0x73, false));
    try t.expect(firstBlocked(list.items, .{}) != null);

    // alt released before f4: fine
    list.clearRetainingCapacity();
    try list.append(t.allocator, vkEvent(0x12, false));
    try list.append(t.allocator, vkEvent(0x12, true));
    try list.append(t.allocator, vkEvent(0x73, false));
    try list.append(t.allocator, vkEvent(0x73, true));
    try t.expect(firstBlocked(list.items, .{}) == null);

    // typed text is Unicode, never a VK chord, but a Tab with held win+... is VK
    list.clearRetainingCapacity();
    try appendText(&list, t.allocator, "w");
    var ctrl: keys.KeyState = .{};
    ctrl.add(0x11);
    try t.expect(firstBlocked(list.items, ctrl) == null);
}

test "applyToState tracks held keys" {
    var st: keys.KeyState = .{};
    const down = [_]w.INPUT{ vkEvent(0xA4, false), vkEvent('X', false), vkEvent('X', true) };
    applyToState(&down, &st);
    try t.expect(st.has(0x12));
    try t.expect(!st.has('X'));
    const up = [_]w.INPUT{vkEvent(0x12, true)};
    applyToState(&up, &st);
    try t.expectEqual(@as(usize, 0), st.len);
}

test "every INPUT we build carries NAVA_INPUT_TAG, and send tags any other" {
    try t.expectEqual(@as(usize, 0x4E415641), NAVA_INPUT_TAG);
    var list: std.ArrayList(w.INPUT) = .empty;
    defer list.deinit(t.allocator);
    try list.append(t.allocator, mouseMove(10, 10, .{ .x = 0, .y = 0, .w = 100, .h = 100 }));
    try list.append(t.allocator, mouseButton(.left, false));
    try list.append(t.allocator, mouseButton(.right, true));
    try list.append(t.allocator, wheel(-2, false));
    try list.append(t.allocator, wheel(1, true));
    try list.append(t.allocator, vkEvent(0x41, false));
    try list.append(t.allocator, unicodeEvent(0xE9, true));
    const c = try keys.parseCombo("ctrl+shift+!", keys.fakeUsScan);
    try appendCombo(&list, t.allocator, &c);
    try appendText(&list, t.allocator, "h\u{e9}\n\t\u{1F600}");
    try t.expect(list.items.len > 12);
    for (list.items) |in| switch (in.type) {
        w.INPUT_KEYBOARD => try t.expectEqual(NAVA_INPUT_TAG, in.u.ki.dwExtraInfo),
        w.INPUT_MOUSE => try t.expectEqual(NAVA_INPUT_TAG, in.u.mi.dwExtraInfo),
        else => return error.UnexpectedInputType,
    };
    // An INPUT built by hand gets the tag in send (which then refuses in tests).
    var raw = [_]w.INPUT{
        .{ .type = w.INPUT_KEYBOARD, .u = .{ .ki = .{ .wVk = 0x42 } } },
        .{ .type = w.INPUT_MOUSE, .u = .{ .mi = .{ .dwFlags = w.MOUSEEVENTF_LEFTDOWN } } },
    };
    try t.expectError(error.InjectionDisabled, send(&raw));
    try t.expectEqual(NAVA_INPUT_TAG, raw[0].u.ki.dwExtraInfo);
    try t.expectEqual(NAVA_INPUT_TAG, raw[1].u.mi.dwExtraInfo);
}

test "points outside the virtual desktop are rejected" {
    const vs: VirtualScreen = .{ .x = -1920, .y = 0, .w = 3840, .h = 1080 };
    try t.expect(contains(vs, -1920, 0));
    try t.expect(contains(vs, 1919, 1079));
    try t.expect(!contains(vs, 1920, 5));
    try t.expect(!contains(vs, -1921, 5));
    try t.expect(!contains(vs, 0, -1));
    try t.expectError(error.PointOutsideDesktop, moveTo(5000, 5, vs));
}
