//! Actuation guards shared by zmcp-computer and zmcp-desktop (through the
//! "computer_shared" module): the Unicode typing cap, coordinate validation,
//! and the key guard that replays every keyboard sequence over the keys
//! already held (ours from key_down, plus modifiers the user is physically
//! holding) and refuses it when a blocked chord would be down at any moment.
//!
//! Two chord policies:
//!   - `.standard` (zmcp-computer): clawdcursor's destructive-combo blocklist
//!     (alt+f4, ctrl+alt+del, win+l/r/d, ctrl+w, f11, ctrl+shift+esc).
//!   - `.strict` (zmcp-desktop): the standard list plus any Windows key
//!     (alone or in a chord), ctrl+alt+anything, alt+tab, alt+esc, alt+space,
//!     ctrl+esc (keys.strictBlockedInState).

const std = @import("std");
const builtin = @import("builtin");
const w = @import("win32.zig");
const keys = @import("keys.zig");
const input = @import("input.zig");
const integrity = @import("integrity.zig");

/// Longest text a type call may send (code points).
pub const max_type_chars: usize = 65536;
/// Largest coordinate / size magnitude accepted from tool arguments.
pub const max_arg_magnitude: f64 = 1e7;

pub fn charCount(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

pub fn checkTextLen(text: []const u8, max_chars: usize) error{TextTooLong}!void {
    if (charCount(text) > max_chars) return error.TextTooLong;
}

/// A finite JSON number (or numeric string) with |v| <= 1e7, else null.
/// 1e300, NaN and inf are rejected here so no later @intFromFloat can trap.
pub fn finiteNumber(v: std.json.Value) ?f64 {
    const f: f64 = switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string, .string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " ")) catch return null,
        else => return null,
    };
    if (!std.math.isFinite(f) or @abs(f) > max_arg_magnitude) return null;
    return f;
}

/// A pixel coordinate: finiteNumber rounded to i32, else null.
pub fn coordinate(v: std.json.Value) ?i32 {
    const f = finiteNumber(v) orelse return null;
    return std.math.cast(i32, @as(i64, @intFromFloat(@round(f))));
}

/// The virtual desktop (all monitors) in physical pixels.
pub fn virtualScreen() input.VirtualScreen {
    return .{
        .x = w.GetSystemMetrics(w.SM_XVIRTUALSCREEN),
        .y = w.GetSystemMetrics(w.SM_YVIRTUALSCREEN),
        .w = w.GetSystemMetrics(w.SM_CXVIRTUALSCREEN),
        .h = w.GetSystemMetrics(w.SM_CYVIRTUALSCREEN),
    };
}

extern "user32" fn GetAsyncKeyState(vKey: c_int) callconv(.winapi) i16;

/// Modifiers currently down on the real keyboard (user or earlier input).
/// Empty in test binaries, so tests don't depend on the keyboard.
pub fn physicallyHeld() keys.KeyState {
    var st: keys.KeyState = .{};
    if (builtin.is_test) return st;
    for ([_]u16{ 0x10, 0x11, 0x12, 0x5B, 0x5C }) |vk| {
        if (GetAsyncKeyState(vk) < 0) st.add(vk);
    }
    return st;
}

/// True when calls will really reach SendInput.
pub fn injecting() bool {
    return !(builtin.is_test or input.dry_run);
}

pub const Chords = enum { standard, strict };

pub fn blockedFn(chords: Chords) *const fn (*const keys.KeyState) ?[]const u8 {
    return switch (chords) {
        .standard => keys.blockedInState,
        .strict => keys.strictBlockedInState,
    };
}

pub const KeyGuard = struct {
    /// Keys our own key_down calls left held (normalized VKs). Updated after
    /// every keyboard send, and also in dry-run so the blocklist sees the
    /// same sequence a real run would.
    held: keys.KeyState = .{},
    chords: Chords = .standard,
    /// zmcp-computer's ZMCP_COMPUTER_ALLOW_BLOCKED_KEYS. Never set by zmcp-desktop.
    allow_blocked: bool = false,
    last_blocked: []const u8 = "",

    /// The label of the first blocked chord `list` would hold down, replayed
    /// over our held keys plus the physically held modifiers.
    pub fn firstRefused(self: *KeyGuard, list: []const w.INPUT) ?[]const u8 {
        if (self.allow_blocked) return null;
        var st = self.held;
        const phys = physicallyHeld();
        st.merge(&phys);
        return input.firstBlockedWith(list, st, blockedFn(self.chords));
    }

    /// The one path every keyboard send goes through: chord check, then UIPI
    /// (the foreground window's integrity level), then SendInput.
    pub fn send(self: *KeyGuard, list: []w.INPUT) !void {
        if (self.firstRefused(list)) |label| {
            self.last_blocked = label;
            return error.BlockedCombo;
        }
        if (injecting()) try integrity.checkHwnd(w.GetForegroundWindow());
        input.send(list) catch |e| {
            if (e == error.InjectionDisabled) input.applyToState(list, &self.held);
            return e;
        };
        input.applyToState(list, &self.held);
    }
};

// ── tests ───────────────────────────────────────────────────────────────────

const t = std.testing;

test "text cap counts code points, not bytes" {
    try checkTextLen("é" ** 10, 10);
    try t.expectError(error.TextTooLong, checkTextLen("é" ** 11, 10));
    try t.expectEqual(@as(usize, 3), charCount("a😀b"));
}

test "numbers: finite, bounded, never trapping" {
    try t.expectEqual(@as(?f64, 12.5), finiteNumber(.{ .float = 12.5 }));
    try t.expectEqual(@as(?f64, 7), finiteNumber(.{ .string = " 7 " }));
    try t.expectEqual(@as(?f64, null), finiteNumber(.{ .float = 1e300 }));
    try t.expectEqual(@as(?f64, null), finiteNumber(.{ .string = "NaN" }));
    try t.expectEqual(@as(?f64, null), finiteNumber(.{ .string = "inf" }));
    try t.expectEqual(@as(?f64, null), finiteNumber(.{ .bool = true }));
    try t.expectEqual(@as(?i32, -3), coordinate(.{ .float = -2.6 }));
    try t.expectEqual(@as(?i32, null), coordinate(.{ .integer = 20_000_000 }));
}

test "strict key guard refuses what standard allows" {
    var list: std.ArrayList(w.INPUT) = .empty;
    defer list.deinit(t.allocator);
    const c = try keys.parseCombo("alt+tab", keys.fakeUsScan);
    try input.appendCombo(&list, t.allocator, &c);
    var std_guard: KeyGuard = .{};
    try t.expect(std_guard.firstRefused(list.items) == null);
    var strict: KeyGuard = .{ .chords = .strict };
    try t.expectEqualStrings("alt+tab", strict.firstRefused(list.items).?);
    try t.expectError(error.BlockedCombo, strict.send(list.items));
    // Nothing was sent, so nothing is recorded as held.
    try t.expectEqual(@as(usize, 0), strict.held.len);
}
