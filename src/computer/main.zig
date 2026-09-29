//! zmcp-computer: native Windows desktop control over MCP.
//!
//! One binary, two upstream tool surfaces on a shared Win32 core:
//!   * computer_control_mcp 0.3.10 (Python/pyautogui): 15 flat tools, same
//!     names and argument schemas, physical screen pixels.
//!   * clawdcursor 0.9.3 `mcp --compact` (Node/libnut): the `computer`,
//!     `window` and `system` compound tools, same action names and argument
//!     names, image-space coordinates (primary monitor scaled to 1280 px).
//!
//! `--surface=all|computer-control|clawdcursor` picks which set tools/list
//! returns (default all). `--dry-run` (or ZMCP_COMPUTER_DRY_RUN=1) makes every
//! injecting, focusing, capturing or clipboard call report what it would do
//! instead of doing it, which is how this server is smoke-tested on a machine
//! someone is using.
//!
//! Not in this binary: clawdcursor's `accessibility` (UI Automation lives in
//! the separate zmcp-desktop process, spike Z0 on spike/desktop-uia),
//! `browser` (CDP) and `task` (needs the clawdcursor agent daemon). See
//! README.md.

const std = @import("std");
const builtin = @import("builtin");
const mcp = @import("mcp");
const w = @import("win32.zig");
const keys = @import("keys.zig");
const input = @import("input.zig");
const image = @import("image.zig");
const capture = @import("capture.zig");
const wins = @import("wins.zig");
const sys = @import("sys.zig");
const shortcuts = @import("shortcuts.zig");
const ocr = @import("ocr.zig");
const schemas = @import("schemas.zig");
const integrity = @import("integrity.zig");
const guard = @import("guard.zig");

const version = "0.1.0";

/// clawdcursor's LLM frame width: image-space = primary monitor scaled so it
/// is at most this wide.
const llm_width: u32 = 1280;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var surface: Surface = .all;
    var dry = false;

    var it = try init.minimal.args.iterateAllocator(gpa);
    defer it.deinit();
    _ = it.next();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry = true;
        } else if (std.mem.startsWith(u8, arg, "--surface=")) {
            surface = std.meta.stringToEnum(Surface, arg["--surface=".len..]) orelse {
                std.debug.print("zmcp-computer: unknown surface '{s}' (all, computer-control, clawdcursor)\n", .{arg});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\zmcp-computer {s}: Windows desktop control MCP server (stdio)
                \\  --surface=all|computer-control|clawdcursor   tool set to expose (default all)
                \\  --dry-run                                     never inject/focus/capture; report instead
                \\env: ZMCP_COMPUTER_DRY_RUN=1, ZMCP_COMPUTER_ALLOW_BLOCKED_KEYS=1, ZMCP_COMPUTER_ALLOW_SAVE=1,
                \\     COMPUTER_CONTROL_MCP_SCREENSHOT_DIR=<dir>
                \\
            , .{version});
            return;
        }
    }
    if (init.environ_map.get("ZMCP_COMPUTER_DRY_RUN")) |v| {
        if (v.len > 0 and !std.mem.eql(u8, v, "0")) dry = true;
    }
    if (init.environ_map.get("ZMCP_COMPUTER_ALLOW_BLOCKED_KEYS")) |v| {
        key_guard.allow_blocked = v.len > 0 and !std.mem.eql(u8, v, "0");
    }
    if (init.environ_map.get("ZMCP_COMPUTER_ALLOW_SAVE")) |v| {
        allow_save = v.len > 0 and !std.mem.eql(u8, v, "0");
    }
    setDryRun(dry);

    // Physical pixels everywhere: SendInput, GetWindowRect, BitBlt and the
    // monitor list then agree on one coordinate space on mixed-DPI setups.
    _ = w.SetProcessDpiAwarenessContext(w.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    const tools: []const mcp.ToolDef = switch (surface) {
        .all => &(cc_tools ++ clawd_tools),
        .@"computer-control" => &cc_tools,
        .clawdcursor => &clawd_tools,
    };
    try mcp.run(gpa, init.io, .{ .name = "zmcp-computer", .version = version }, tools);
}

const Surface = enum { all, @"computer-control", clawdcursor };

var dry_run = false;
/// save_to_downloads writes to disk only when ZMCP_COMPUTER_ALLOW_SAVE=1;
/// by default screenshots only travel in the MCP response.
var allow_save = false;

/// Longest text type_text / computer.type will send (code points).
const max_type_chars: usize = guard.max_type_chars;

fn setDryRun(on: bool) void {
    dry_run = on;
    input.dry_run = on;
    capture.disabled = on;
    wins.disabled = on;
    sys.disabled = on;
}

// ── tool tables ─────────────────────────────────────────────────────────────

const cc_tools = [_]mcp.ToolDef{
    .{ .name = "click_screen", .description = "Click at the specified screen coordinates (physical pixels on the virtual desktop; the primary monitor's top-left is 0,0).", .input_schema_json = schemas.cc_click_screen, .handler = ccClickScreen },
    .{ .name = "get_screen_size", .description = "Get the current screen resolution (primary monitor, physical pixels).", .input_schema_json = schemas.cc_get_screen_size, .handler = ccGetScreenSize },
    .{ .name = "type_text", .description = "Type the specified text at the current cursor position (at most 65536 characters). Sent as Unicode keystrokes, so any character works regardless of keyboard layout and the clipboard is untouched.", .input_schema_json = schemas.cc_type_text, .handler = ccTypeText },
    .{ .name = "take_screenshot", .description =
    \\Get a screenshot as an MCP image (PNG). If no title pattern is provided, capture the entire virtual desktop.
    \\Args:
    \\  title_pattern: pattern to match a window title; the matched window is rendered with PrintWindow, without activating it
    \\  use_regex: treat the pattern as a regex (case-insensitive search), otherwise best fuzzy match
    \\  threshold: minimum fuzzy score 0-100 (default 10)
    \\  save_to_downloads: also save the PNG to Downloads (or COMPUTER_CONTROL_MCP_SCREENSHOT_DIR); disabled unless the server runs with ZMCP_COMPUTER_ALLOW_SAVE=1
    \\  max_width: optional, downscale to at most this width
    \\  scale_percent_for_ocr, use_wgc: accepted for compatibility, ignored
    , .input_schema_json = schemas.cc_take_screenshot, .handler = ccTakeScreenshot },
    .{ .name = "take_screenshot_with_ocr", .description =
    \\OCR the screen (or one window) with Windows.Media.Ocr. Returns one line per text line:
    \\([[x1, y1], [x2, y1], [x2, y2], [x1, y2]], 'text', confidence) with ABSOLUTE screen coordinates (window offset and any scaling already applied), so clicking the middle of a box hits the text. Windows OCR reports no confidence; it is always 1.0.
    \\Args: title_pattern, use_regex, threshold (as take_screenshot); scale_percent_for_ocr: downscale before OCR (coordinates are mapped back); save_to_downloads.
    , .input_schema_json = schemas.cc_take_screenshot_with_ocr, .handler = ccTakeScreenshotWithOcr },
    .{ .name = "move_mouse", .description = "Move the mouse to the specified screen coordinates.", .input_schema_json = schemas.cc_move_mouse, .handler = ccMoveMouse },
    .{ .name = "mouse_down", .description = "Hold down a mouse button ('left', 'right', 'middle').", .input_schema_json = schemas.cc_mouse_down, .handler = ccMouseDown },
    .{ .name = "mouse_up", .description = "Release a mouse button ('left', 'right', 'middle').", .input_schema_json = schemas.cc_mouse_up, .handler = ccMouseUp },
    .{ .name = "drag_mouse", .description = "Drag the mouse from (from_x, from_y) to (to_x, to_y) with the left button held, moving smoothly over `duration` seconds (default 0.5).", .input_schema_json = schemas.cc_drag_mouse, .handler = ccDragMouse },
    .{ .name = "key_down", .description = "Hold down a specific keyboard key until released.", .input_schema_json = schemas.cc_key_down, .handler = ccKeyDown },
    .{ .name = "key_up", .description = "Release a specific keyboard key.", .input_schema_json = schemas.cc_key_up, .handler = ccKeyUp },
    .{ .name = "press_keys", .description =
    \\Press keyboard keys.
    \\  keys: a single key ("enter"), a sequence (["a", "b", "c"]), or combinations as nested lists ([["ctrl", "c"], ["alt", "tab"]]). A string with '+' such as "ctrl+c" is also accepted as a combination.
    \\Key names follow pyautogui (enter, esc, pgdn, winleft, f1-f24, volumeup, ...) and clawdcursor (Return, Control, Super, mod, ...). Destructive combos (alt+f4, ctrl+w, win+l, ...) are refused.
    , .input_schema_json = schemas.cc_press_keys, .handler = ccPressKeys },
    .{ .name = "list_windows", .description = "List all visible top-level windows (title, bounds, state).", .input_schema_json = schemas.cc_list_windows, .handler = ccListWindows },
    .{ .name = "wait_milliseconds", .description = "Wait for a specified number of milliseconds (capped at 10 minutes).", .input_schema_json = schemas.cc_wait_milliseconds, .handler = ccWaitMilliseconds },
    .{ .name = "activate_window", .description = "Activate a window (bring it to the foreground) by matching its title. Args: title_pattern; use_regex; threshold (fuzzy minimum 0-100, default 60).", .input_schema_json = schemas.cc_activate_window, .handler = ccActivateWindow },
};

const clawd_tools = [_]mcp.ToolDef{
    .{ .name = "computer", .description = "Direct mouse/keyboard/screenshot control (Anthropic Computer-Use style). Pick an action: screenshot, screenshot_region, click, double_click, right_click, middle_click, triple_click, hover, move, move_relative, scroll, scroll_horizontal, drag, drag_path, mouse_down, mouse_up, type, key, key_press, key_down, key_up, wait. Coordinates are image-space pixels from the most recent screenshot (primary monitor scaled to at most 1280 px wide).", .input_schema_json = schemas.computer, .handler = clawdComputer },
    .{ .name = "window", .description = "Window, app, and display management. Open/focus/maximize/minimize/restore/close/resize windows; enumerate displays; switch browser tabs at the OS level; open apps/files/URLs. Pick an action: list, active, focus, maximize, minimize, restore, close, resize, list_displays, screen_size, open_app, open_file, open_url, switch_tab, navigate. Window coordinates are physical pixels. close requires confirm=true.", .input_schema_json = schemas.window, .handler = clawdWindow },
    .{ .name = "system", .description = "System integration: clipboard read/write, system time, OCR screen-reading, undo shortcut, named keyboard-shortcut registry, WebView/Electron app detection. Pick an action: clipboard_read, clipboard_write, system_time, ocr, undo, shortcuts_list, shortcuts_run, detect_webview. (delegate, relaunch_with_cdp, app_guide, detect_app, classify_task, system_prompt need the clawdcursor agent and are not available here.)", .input_schema_json = schemas.system, .handler = clawdSystem },
};

// ── argument helpers ────────────────────────────────────────────────────────

const Args = struct {
    obj: ?std.json.ObjectMap,

    fn of(v: std.json.Value) Args {
        return .{ .obj = if (v == .object) v.object else null };
    }

    fn get(self: Args, name: []const u8) ?std.json.Value {
        const o = self.obj orelse return null;
        const v = o.get(name) orelse return null;
        return if (v == .null) null else v;
    }

    /// A finite number with |v| <= 1e7, else null (1e300, NaN and inf are
    /// rejected here so no later @intFromFloat can trap).
    fn num(self: Args, name: []const u8) ?f64 {
        return guard.finiteNumber(self.get(name) orelse return null);
    }

    fn int(self: Args, name: []const u8) ?i64 {
        const f = self.num(name) orelse return null;
        return @intFromFloat(@round(f));
    }

    fn str(self: Args, name: []const u8) ?[]const u8 {
        const v = self.get(name) orelse return null;
        return if (v == .string) v.string else null;
    }

    fn boolean(self: Args, name: []const u8) ?bool {
        const v = self.get(name) orelse return null;
        return switch (v) {
            .bool => |b| b,
            .string => |s| std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1"),
            .integer => |i| i != 0,
            else => null,
        };
    }
};

fn errMsg(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !mcp.ToolResult {
    return .{ .text = try std.fmt.allocPrint(allocator, fmt, args), .is_error = true };
}

fn okMsg(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !mcp.ToolResult {
    return .{ .text = try std.fmt.allocPrint(allocator, fmt, args) };
}

fn requireInt(a: Args, name: []const u8) !i32 {
    const v = a.int(name) orelse return error.MissingArgument;
    return std.math.cast(i32, v) orelse error.ArgumentOutOfRange;
}

/// Float to integer that cannot trap: NaN -> 0, clamped to +-1e12.
fn f2i(v: f64) i64 {
    if (std.math.isNan(v)) return 0;
    return @intFromFloat(@round(std.math.clamp(v, -1e12, 1e12)));
}

fn clampI32(v: i64) i32 {
    return @intCast(std.math.clamp(v, std.math.minInt(i32), std.math.maxInt(i32)));
}

/// Map an action error to a tool result: dry-run refusals become a
/// successful "[dry-run] ..." report, everything else an isError result.
fn outcome(allocator: std.mem.Allocator, err: anyerror, what: []const u8) !mcp.ToolResult {
    return switch (err) {
        error.InjectionDisabled, error.CaptureDisabled, error.WindowActionsDisabled, error.SystemActionsDisabled => okMsg(allocator, "[dry-run] would {s}", .{what}),
        error.SendInputBlocked => errMsg(allocator, "Error: SendInput was blocked while trying to {s} (the foreground window may belong to an elevated process, or the desktop is locked / on the secure desktop).", .{what}),
        error.MissingArgument => errMsg(allocator, "Error: missing required argument for {s}", .{what}),
        error.ArgumentOutOfRange => errMsg(allocator, "Error: argument out of range for {s}", .{what}),
        error.UnknownKey => errMsg(allocator, "Error: unknown key while trying to {s}", .{what}),
        error.BlockedCombo => errMsg(allocator, "BLOCKED: {s} would hold down the destructive combo {s} (counting keys already held by key_down or physically). Set ZMCP_COMPUTER_ALLOW_BLOCKED_KEYS=1 to allow.", .{ what, key_guard.last_blocked }),
        error.TargetElevated => errMsg(allocator, "Refused to {s}: the target window belongs to a process at a higher integrity level (elevated app or UAC prompt), or its level could not be read. Windows would silently drop the input, so nothing was sent.", .{what}),
        error.PointOutsideDesktop => errMsg(allocator, "Refused to {s}: the point is outside the virtual desktop (see get_screen_size / window.list_displays).", .{what}),
        error.TextTooLong => errMsg(allocator, "Refused to {s}: text is longer than {d} characters.", .{ what, max_type_chars }),
        else => errMsg(allocator, "Error trying to {s}: {s}", .{ what, @errorName(err) }),
    };
}

// ── core actions (physical pixels) ──────────────────────────────────────────

fn virtualScreen() input.VirtualScreen {
    return guard.virtualScreen();
}

/// Keys our own key_down calls left held, the standard chord blocklist and
/// ZMCP_COMPUTER_ALLOW_BLOCKED_KEYS (shared with zmcp-desktop, guard.zig).
var key_guard: guard.KeyGuard = .{};
extern "user32" fn WindowFromPoint(pt: w.POINT) callconv(.winapi) ?w.HWND;
extern "user32" fn GetAncestor(hwnd: w.HWND, flags: u32) callconv(.winapi) ?w.HWND;
const GA_ROOT: u32 = 2;

/// True when calls will really reach SendInput / window APIs.
fn injecting() bool {
    return !(builtin.is_test or dry_run);
}

/// UIPI: refuse input whose receiver (window under the point, or the
/// foreground window for keys) runs at a higher integrity level.
fn checkWindowAt(x: i32, y: i32) !void {
    if (!injecting()) return;
    const hit = WindowFromPoint(.{ .x = x, .y = y }) orelse return;
    try integrity.checkHwnd(GetAncestor(hit, GA_ROOT) orelse hit);
}

fn checkCursorWindow() !void {
    if (!injecting()) return;
    var p: w.POINT = .{ .x = 0, .y = 0 };
    if (!w.ok(w.GetCursorPos(&p))) return;
    try checkWindowAt(p.x, p.y);
}

/// The one path every keyboard send goes through (guard.KeyGuard.send):
/// replays the sequence on top of the held keys (ours plus physical
/// modifiers) and refuses it if a blocked chord would be down at any
/// moment, then checks UIPI.
fn sendKeys(list: []w.INPUT) !void {
    return key_guard.send(list);
}

fn moveTo(x: i32, y: i32) !void {
    try input.moveTo(x, y, virtualScreen());
}

fn requireOnDesktop(x: i32, y: i32) !void {
    if (!input.contains(virtualScreen(), x, y)) return error.PointOutsideDesktop;
}

fn click(allocator: std.mem.Allocator, x: i32, y: i32, button: input.Button, count: u32) !void {
    try requireOnDesktop(x, y);
    try checkWindowAt(x, y);
    try moveTo(x, y);
    var list: std.ArrayList(w.INPUT) = .empty;
    defer list.deinit(allocator);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try list.append(allocator, input.mouseButton(button, false));
        try list.append(allocator, input.mouseButton(button, true));
    }
    try input.send(list.items);
}

fn buttonAction(button: input.Button, up: bool) !void {
    try checkCursorWindow();
    var one = [_]w.INPUT{input.mouseButton(button, up)};
    try input.send(&one);
}

fn scrollAt(x: i32, y: i32, ticks: i32, horizontal: bool) !void {
    try requireOnDesktop(x, y);
    try checkWindowAt(x, y);
    try moveTo(x, y);
    var one = [_]w.INPUT{input.wheel(ticks, horizontal)};
    try input.send(&one);
}

/// Press at `pts[0]`, glide through the rest over `duration_ms`, release.
/// Every point is validated before the button goes down, so a bad point
/// never leaves a half-finished drag.
fn dragThrough(pts: []const [2]i32, duration_ms: u32, button: input.Button) !void {
    if (pts.len < 2) return error.MissingArgument;
    for (pts) |p| try requireOnDesktop(p[0], p[1]);
    try checkWindowAt(pts[0][0], pts[0][1]);
    try checkWindowAt(pts[pts.len - 1][0], pts[pts.len - 1][1]);
    try moveTo(pts[0][0], pts[0][1]);
    try buttonAction(button, false);
    // The release is never refused: a stuck button is worse than a dropped one.
    errdefer releaseButton(button);
    const segs = pts.len - 1;
    const steps_total: u32 = @max(@as(u32, @intCast(segs)), duration_ms / 10);
    const steps_per_seg: u32 = @max(1, steps_total / @as(u32, @intCast(segs)));
    const pause: u32 = if (duration_ms == 0) 0 else @max(1, duration_ms / (steps_per_seg * @as(u32, @intCast(segs))));
    for (pts[0..segs], pts[1..]) |a, b| {
        var s: u32 = 1;
        while (s <= steps_per_seg) : (s += 1) {
            const fx = @as(f64, @floatFromInt(a[0])) + @as(f64, @floatFromInt(b[0] - a[0])) * @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(steps_per_seg));
            const fy = @as(f64, @floatFromInt(a[1])) + @as(f64, @floatFromInt(b[1] - a[1])) * @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(steps_per_seg));
            try moveTo(@intFromFloat(@round(fx)), @intFromFloat(@round(fy)));
            if (pause > 0) w.sleepMs(pause);
        }
    }
    releaseButton(button);
}

fn releaseButton(button: input.Button) void {
    var one = [_]w.INPUT{input.mouseButton(button, true)};
    input.send(&one) catch {};
}

fn scanFn(ch: u16) i16 {
    return w.VkKeyScanW(ch);
}

const ComboError = error{BlockedCombo};

fn parseComboChecked(s: []const u8, blocked_label: *?[]const u8) !keys.Combo {
    const combo = try keys.parseCombo(s, scanFn);
    if (!key_guard.allow_blocked) {
        if (keys.blockedLabel(&combo)) |label| {
            blocked_label.* = label;
            return error.BlockedCombo;
        }
    }
    return combo;
}

fn pressCombo(allocator: std.mem.Allocator, combo: *const keys.Combo) !void {
    var list: std.ArrayList(w.INPUT) = .empty;
    defer list.deinit(allocator);
    try input.appendCombo(&list, allocator, combo);
    try sendKeys(list.items);
}

/// key_down / key_up: every key of the combo goes down (or up) in order.
fn keyEdge(allocator: std.mem.Allocator, combo: *const keys.Combo, up: bool) !void {
    var list: std.ArrayList(w.INPUT) = .empty;
    defer list.deinit(allocator);
    if (up) {
        var i = combo.len;
        while (i > 0) {
            i -= 1;
            const k = combo.keys[i];
            try list.append(allocator, if (k.vk != 0) input.vkEvent(k.vk, true) else input.unicodeEvent(k.unicode, true));
        }
    } else {
        for (combo.slice()) |k| try list.append(allocator, if (k.vk != 0) input.vkEvent(k.vk, false) else input.unicodeEvent(k.unicode, false));
    }
    try sendKeys(list.items);
}

const charCount = guard.charCount;

fn typeText(allocator: std.mem.Allocator, text: []const u8) !void {
    try guard.checkTextLen(text, max_type_chars);
    var list: std.ArrayList(w.INPUT) = .empty;
    defer list.deinit(allocator);
    try input.appendText(&list, allocator, text);
    try sendKeys(list.items);
}

fn primarySize() struct { w: u32, h: u32 } {
    const r = capture.primaryScreen();
    return .{ .w = @intCast(@max(r.w, 1)), .h = @intCast(@max(r.h, 1)) };
}

/// image-space → physical scale factor (clawdcursor screenshotScaleFactor).
fn imageScale() f64 {
    const p = primarySize();
    return if (p.w > llm_width) @as(f64, @floatFromInt(p.w)) / @as(f64, @floatFromInt(llm_width)) else 1.0;
}

fn toPhys(v: f64) i32 {
    return clampI32(@intFromFloat(@round(v * imageScale())));
}

fn pngResult(allocator: std.mem.Allocator, bmp: image.Bitmap, text: []const u8) !mcp.ToolResult {
    const png = try image.encodePng(allocator, bmp);
    return .{ .text = text, .image = .{ .data_base64 = try image.base64Alloc(allocator, png), .mime_type = "image/png" } };
}

// ── computer_control handlers ───────────────────────────────────────────────

fn ccClickScreen(allocator: std.mem.Allocator, _: std.Io, args: std.json.Value) !mcp.ToolResult {
    const a = Args.of(args);
    const x = requireInt(a, "x") catch |e| return outcome(allocator, e, "click");
    const y = requireInt(a, "y") catch |e| return outcome(allocator, e, "click");
    click(allocator, x, y, .left, 1) catch |e| return outcome(allocator, e, try std.fmt.allocPrint(allocator, "click at ({d}, {d})", .{ x, y }));
    return okMsg(allocator, "Successfully clicked at coordinates ({d}, {d})", .{ x, y });
}

fn ccGetScreenSize(allocator: std.mem.Allocator, _: std.Io, _: std.json.Value) !mcp.ToolResult {
    const p = primarySize();
    return okMsg(allocator, "{{\"width\":{d},\"height\":{d},\"message\":\"Screen size: {d}x{d}\"}}", .{ p.w, p.h, p.w, p.h });
}

fn ccTypeText(allocator: std.mem.Allocator, _: std.Io, args: std.json.Value) !mcp.ToolResult {
    const text = Args.of(args).str("text") orelse return errMsg(allocator, "Error typing text: missing 'text'", .{});
    typeText(allocator, text) catch |e| return outcome(allocator, e, try std.fmt.allocPrint(allocator, "type {d} characters", .{charCount(text)}));
    return okMsg(allocator, "Successfully typed text ({d} characters)", .{charCount(text)});
}

const Target = struct {
    bmp: image.Bitmap,
    origin_x: i32,
    origin_y: i32,
    label: []const u8,
};

/// Window by title pattern (no activation), else the whole virtual desktop.
fn captureTarget(allocator: std.mem.Allocator, a: Args, default_threshold: i64) !Target {
    if (a.str("title_pattern")) |pat| if (pat.len > 0) {
        const all = try wins.list(allocator);
        const hit = try wins.findByTitle(allocator, all, pat, a.boolean("use_regex") orelse false, a.int("threshold") orelse default_threshold);
        if (hit) |win| {
            const got = try capture.captureWindow(allocator, win.hwnd);
            return .{ .bmp = got.bmp, .origin_x = got.rect.x, .origin_y = got.rect.y, .label = try std.fmt.allocPrint(allocator, "window '{s}'", .{win.title}) };
        }
    };
    const vs = capture.virtualScreen();
    return .{ .bmp = try capture.captureRect(allocator, vs), .origin_x = vs.x, .origin_y = vs.y, .label = "entire screen" };
}

fn timestampName(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    var st: w.SYSTEMTIME = undefined;
    w.GetLocalTime(&st);
    var rnd: [4]u8 = undefined;
    std.mem.writeInt(u32, &rnd, @truncate(w.GetTickCount64() *% 2654435761), .little);
    return std.fmt.allocPrint(allocator, "{s}_{d:0>4}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}{d:0>2}_{x}.png", .{
        prefix, st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, std.fmt.bytesToHex(rnd, .lower),
    });
}

/// Note returned instead of writing when save_to_downloads is not enabled.
const save_disabled_note = "Not saved to disk: save_to_downloads is disabled unless zmcp-computer runs with ZMCP_COMPUTER_ALLOW_SAVE=1; the image is in this response.";

fn saveToDownloads(allocator: std.mem.Allocator, png: []const u8) ![]u8 {
    if (!allow_save) return error.SaveDisabled;
    const dir = try sys.screenshotDir(allocator);
    const name = try timestampName(allocator, "screenshot");
    const path = try std.fmt.allocPrint(allocator, "{s}\\{s}", .{ dir, name });
    try sys.writeFile(allocator, path, png);
    return path;
}

fn ccTakeScreenshot(allocator: std.mem.Allocator, _: std.Io, args: std.json.Value) !mcp.ToolResult {
    const a = Args.of(args);
    var target = captureTarget(allocator, a, 10) catch |e| return outcome(allocator, e, "capture the screen");
    if (a.int("max_width")) |mw| if (mw > 0 and mw < target.bmp.w) {
        const f = image.fitWidth(target.bmp.w, target.bmp.h, @intCast(mw));
        target.bmp = try image.downscale(allocator, target.bmp, f.w, f.h);
    };
    const png = try image.encodePng(allocator, target.bmp);
    var text = try std.fmt.allocPrint(allocator, "Screenshot of {s}: {d}x{d} px, top-left at screen ({d}, {d}).", .{ target.label, target.bmp.w, target.bmp.h, target.origin_x, target.origin_y });
    if (a.boolean("save_to_downloads") orelse false) {
        if (saveToDownloads(allocator, png)) |path| {
            text = try std.fmt.allocPrint(allocator, "{s} Saved to {s}", .{ text, path });
        } else |e| switch (e) {
            error.SaveDisabled => text = try std.fmt.allocPrint(allocator, "{s} {s}", .{ text, save_disabled_note }),
            else => return outcome(allocator, e, "save the screenshot"),
        }
    }
    return .{ .text = text, .image = .{ .data_base64 = try image.base64Alloc(allocator, png), .mime_type = "image/png" } };
}

fn pyQuote(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try out.append(allocator, '\'');
    for (s) |c| switch (c) {
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\'' => try out.appendSlice(allocator, "\\'"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        else => try out.append(allocator, c),
    };
    try out.append(allocator, '\'');
}

fn ccTakeScreenshotWithOcr(allocator: std.mem.Allocator, _: std.Io, args: std.json.Value) !mcp.ToolResult {
    const a = Args.of(args);
    const target = captureTarget(allocator, a, 10) catch |e| return outcome(allocator, e, "capture the screen for OCR");
    var save_note: []const u8 = "";
    if (a.boolean("save_to_downloads") orelse false) {
        if (allow_save) {
            const png = try image.encodePng(allocator, target.bmp);
            _ = saveToDownloads(allocator, png) catch |e| return outcome(allocator, e, "save the screenshot");
        } else save_note = "\n# " ++ save_disabled_note;
    }
    var bmp = target.bmp;
    var scale: f64 = 1.0;
    if (a.int("scale_percent_for_ocr")) |pct| {
        if (pct <= 0) return errMsg(allocator, "Error: scale_percent_for_ocr must be greater than 0, got {d}", .{pct});
        if (pct < 100) {
            const nw: u32 = @max(1, @as(u32, @intCast(@divTrunc(@as(i64, bmp.w) * pct, 100))));
            const nh: u32 = @max(1, @as(u32, @intCast(@divTrunc(@as(i64, bmp.h) * pct, 100))));
            bmp = try image.downscale(allocator, bmp, nw, nh);
            scale = @as(f64, @floatFromInt(target.bmp.w)) / @as(f64, @floatFromInt(nw));
        }
    }
    const res = ocr.recognize(allocator, bmp) catch |e| return outcome(allocator, e, "run Windows OCR");
    if (res.lines.len == 0) return .{ .text = try std.fmt.allocPrint(allocator, "No text found{s}", .{save_note}) };
    var out: std.ArrayList(u8) = .empty;
    for (res.lines, 0..) |line, i| {
        const x1: i64 = target.origin_x + f2i(line.x * scale);
        const y1: i64 = target.origin_y + f2i(line.y * scale);
        const x2: i64 = target.origin_x + f2i((line.x + line.w) * scale);
        const y2: i64 = target.origin_y + f2i((line.y + line.h) * scale);
        if (i > 0) try out.appendSlice(allocator, ",\n");
        try out.print(allocator, "([[{d}, {d}], [{d}, {d}], [{d}, {d}], [{d}, {d}]], ", .{ x1, y1, x2, y1, x2, y2, x1, y2 });
        try pyQuote(&out, allocator, line.text);
        try out.appendSlice(allocator, ", 1.0)");
    }
    try out.appendSlice(allocator, save_note);
    return .{ .text = out.items };
}

fn ccMoveMouse(allocator: std.mem.Allocator, _: std.Io, args: std.json.Value) !mcp.ToolResult {
    const a = Args.of(args);
    const x = requireInt(a, "x") catch |e| return outcome(allocator, e, "move the mouse");
    const y = requireInt(a, "y") catch |e| return outcome(allocator, e, "move the mouse");
    moveTo(x, y) catch |e| return outcome(allocator, e, try std.fmt.allocPrint(allocator, "move the mouse to ({d}, {d})", .{ x, y }));
    return okMsg(allocator, "Successfully moved mouse to coordinates ({d}, {d})", .{ x, y });
}

fn buttonArg(a: Args) ?input.Button {
    return input.parseButton(a.str("button") orelse "left");
}

fn ccMouseDown(allocator: std.mem.Allocator, _: std.Io, args: std.json.Value) !mcp.ToolResult {
    const name = Args.of(args).str("button") orelse "left";
    const b = input.parseButton(name) orelse return errMsg(allocator, "Error holding {s} mouse button: unknown button", .{name});
    buttonAction(b, false) catch |e| return outcome(allocator, e, try std.fmt.allocPrint(allocator, "hold the {s} mouse button", .{name}));
    return okMsg(allocator, "Held down {s} mouse button", .{name});
}

fn ccMouseUp(allocator: std.mem.Allocator, _: std.Io, args: std.json.Value) !mcp.ToolResult {
    const name = Args.of(args).str("button") orelse "left";
    const b = input.parseButton(name) orelse return errMsg(allocator, "Error releasing {s} mouse button: unknown button", .{name});
    buttonAction(b, true) catch |e| return outcome(allocator, e, try std.fmt.allocPrint(allocator, "release the {s} mouse button", .{name}));
    return okMsg(allocator, "Released {s} mouse button", .{name});
}

fn ccDragMouse(allocator: std.mem.Allocator, _: std.Io, args: std.json.Value) !mcp.ToolResult {
    const a = Args.of(args);
    const fx = requireInt(a, "from_x") catch |e| return outcome(allocator, e, "drag");
    const fy = requireInt(a, "from_y") catch |e| return outcome(allocator, e, "drag");
    const tx = requireInt(a, "to_x") catch |e| return outcome(allocator, e, "drag");
    const ty = requireInt(a, "to_y") catch |e| return outcome(allocator, e, "drag");
    const dur = std.math.clamp(a.num("duration") orelse 0.5, 0.0, 60.0);
    const pts = [_][2]i32{ .{ fx, fy }, .{ tx, ty } };
    dragThrough(&pts, @intFromFloat(dur * 1000.0), .left) catch |e|
        return outcome(allocator, e, try std.fmt.allocPrint(allocator, "drag from ({d}, {d}) to ({d}, {d})", .{ fx, fy, tx, ty }));
    return okMsg(allocator, "Successfully dragged from ({d}, {d}) to ({d}, {d})", .{ fx, fy, tx, ty });
}

fn keyEdgeHandler(allocator: std.mem.Allocator, args: std.json.Value, up: bool) !mcp.ToolResult {
    const key = Args.of(args).str("key") orelse return errMsg(allocator, "Error: missing 'key'", .{});
    var label: ?[]const u8 = null;
    const combo = parseComboChecked(key, &label) catch |e| switch (e) {
        error.BlockedCombo => return errMsg(allocator, "BLOCKED: \"{s}\" matches the destructive combo {s}. Set ZMCP_COMPUTER_ALLOW_BLOCKED_KEYS=1 to allow.", .{ key, label.? }),
        else => return errMsg(allocator, "Error {s} key {s}: {s}", .{ if (up) "releasing" else "holding", key, @errorName(e) }),
    };
    keyEdge(allocator, &combo, up) catch |e| return outcome(allocator, e, try std.fmt.allocPrint(allocator, "{s} key {s}", .{ if (up) "release" else "hold", key }));
    return if (up) okMsg(allocator, "Released key: {s}", .{key}) else okMsg(allocator, "Held down key: {s}", .{key});
}

fn ccKeyDown(allocator: std.mem.Allocator, _: std.Io, args: std.json.Value) !mcp.ToolResult {
    return keyEdgeHandler(allocator, args, false);
}

fn ccKeyUp(allocator: std.mem.Allocator, _: std.Io, args: std.json.Value) !mcp.ToolResult {
    return keyEdgeHandler(allocator, args, true);
}

/// One press_keys item: a key/"a+b" string, or a list of keys held together.
fn comboFromItem(allocator: std.mem.Allocator, item: std.json.Value) ![]const u8 {
    return switch (item) {
        .string => |s| s,
        .array => |arr| blk: {
            var buf: std.ArrayList(u8) = .empty;
            for (arr.items, 0..) |k, i| {
                if (k != .string) return error.InvalidKeyFormat;
                if (i > 0) try buf.append(allocator, '+');
                // A literal '+' inside a list item must survive re-splitting.
                try buf.appendSlice(allocator, if (std.mem.eql(u8, k.string, "+")) "plus" else k.string);
            }
            break :blk buf.items;
        },
        else => error.InvalidKeyFormat,
    };
}

fn ccPressKeys(allocator: std.mem.Allocator, _: std.Io, args: std.json.Value) !mcp.ToolResult {
    const v = Args.of(args).get("keys") orelse return errMsg(allocator, "Invalid input: must be str or list", .{});
    var items: std.ArrayList(std.json.Value) = .empty;
    switch (v) {
        .string => try items.append(allocator, v),
        .array => |arr| try items.appendSlice(allocator, arr.items),
        else => return errMsg(allocator, "Invalid input: must be str or list", .{}),
    }
    // Validate everything first so a bad key doesn't leave half a sequence typed.
    var combos: std.ArrayList(keys.Combo) = .empty;
    for (items.items) |item| {
        const s = comboFromItem(allocator, item) catch return errMsg(allocator, "Invalid key format: {f}", .{std.json.fmt(item, .{})});
        var label: ?[]const u8 = null;
        const c = parseComboChecked(s, &label) catch |e| switch (e) {
            error.BlockedCombo => return errMsg(allocator, "BLOCKED: \"{s}\" matches the destructive combo {s}. Set ZMCP_COMPUTER_ALLOW_BLOCKED_KEYS=1 to allow.", .{ s, label.? }),
            else => return errMsg(allocator, "Error pressing keys {s}: {s}", .{ s, @errorName(e) }),
        };
        try combos.append(allocator, c);
    }
    var list: std.ArrayList(w.INPUT) = .empty;
    for (combos.items) |*c| try input.appendCombo(&list, allocator, c);
    const shown = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(v, .{})});
    sendKeys(list.items) catch |e| return outcome(allocator, e, try std.fmt.allocPrint(allocator, "press keys {s}", .{shown}));
    return if (v == .string) okMsg(allocator, "Pressed single key: {s}", .{v.string}) else okMsg(allocator, "Successfully pressed keys sequence: {s}", .{shown});
}

fn ccListWindows(allocator: std.mem.Allocator, _: std.Io, _: std.json.Value) !mcp.ToolResult {
    const all = try wins.list(allocator);
    var sw: std.Io.Writer.Allocating = .init(allocator);
    var js: std.json.Stringify = .{ .writer = &sw.writer };
    try js.beginArray();
    for (all) |win| {
        try js.beginObject();
        try js.objectField("title");
        try js.write(win.title);
        try js.objectField("left");
        try js.write(win.rect.left);
        try js.objectField("top");
        try js.write(win.rect.top);
        try js.objectField("width");
        try js.write(win.width());
        try js.objectField("height");
        try js.write(win.height());
        try js.objectField("is_active");
        try js.write(win.active);
        try js.objectField("is_visible");
        try js.write(win.visible);
        try js.objectField("is_minimized");
        try js.write(win.minimized);
        try js.objectField("is_maximized");
        try js.write(win.maximized);
        try js.objectField("process_name");
        try js.write(win.process);
        try js.objectField("pid");
        try js.write(win.pid);
        try js.endObject();
    }
    try js.endArray();
    return .{ .text = sw.written() };
}

fn ccWaitMilliseconds(allocator: std.mem.Allocator, _: std.Io, args: std.json.Value) !mcp.ToolResult {
    const ms = Args.of(args).int("milliseconds") orelse return errMsg(allocator, "Error: missing 'milliseconds'", .{});
    const capped: u32 = @intCast(std.math.clamp(ms, 0, 600_000));
    w.sleepMs(capped);
    return okMsg(allocator, "Successfully waited for {d} milliseconds", .{ms});
}

fn ccActivateWindow(allocator: std.mem.Allocator, _: std.Io, args: std.json.Value) !mcp.ToolResult {
    const a = Args.of(args);
    const pat = a.str("title_pattern") orelse return errMsg(allocator, "Error: missing 'title_pattern'", .{});
    const all = try wins.list(allocator);
    const hit = wins.findByTitle(allocator, all, pat, a.boolean("use_regex") orelse false, a.int("threshold") orelse 60) catch |e|
        return errMsg(allocator, "Error activating window: {s}", .{@errorName(e)});
    const win = hit orelse return errMsg(allocator, "Error: No window found matching pattern: {s}", .{pat});
    const ok = wins.activate(win.hwnd) catch |e| return outcome(allocator, e, try std.fmt.allocPrint(allocator, "activate window '{s}'", .{win.title}));
    if (!ok) return errMsg(allocator, "Error activating window: '{s}' did not come to the foreground (Windows focus-stealing rules)", .{win.title});
    return okMsg(allocator, "Successfully activated window: '{s}'", .{win.title});
}

// ── clawdcursor `computer` ──────────────────────────────────────────────────

fn clawdComputer(allocator: std.mem.Allocator, _: std.Io, args: std.json.Value) !mcp.ToolResult {
    const a = Args.of(args);
    const action = a.str("action") orelse return errMsg(allocator, "computer: \"action\" is required.", .{});
    const Act = enum { screenshot, screenshot_region, click, double_click, right_click, middle_click, triple_click, hover, move, move_relative, scroll, scroll_horizontal, drag, drag_path, mouse_down, mouse_up, type, key, key_press, key_down, key_up, wait };
    const act = std.meta.stringToEnum(Act, action) orelse return errMsg(allocator, "computer: unknown action \"{s}\". Valid: screenshot, screenshot_region, click, double_click, right_click, middle_click, triple_click, hover, move, move_relative, scroll, scroll_horizontal, drag, drag_path, mouse_down, mouse_up, type, key, key_press, key_down, key_up, wait", .{action});

    switch (act) {
        .screenshot => {
            const p = capture.primaryScreen();
            const full = capture.captureRect(allocator, p) catch |e| return outcome(allocator, e, "take a screenshot");
            const f = image.fitWidth(full.w, full.h, llm_width);
            const small = try image.downscale(allocator, full, f.w, f.h);
            const text = try std.fmt.allocPrint(allocator, "Screenshot: {d}x{d}px (real: {d}x{d}, scale: {d:.2}x). Mouse tools accept these image-space coordinates.", .{ small.w, small.h, full.w, full.h, imageScale() });
            return pngResult(allocator, small, text);
        },
        .screenshot_region => {
            const x = a.num("x") orelse return errMsg(allocator, "screenshot_region: x, y, width, height are required (finite numbers, |v| <= 1e7)", .{});
            const y = a.num("y") orelse return errMsg(allocator, "screenshot_region: x, y, width, height are required (finite numbers, |v| <= 1e7)", .{});
            const rw = a.num("width") orelse return errMsg(allocator, "screenshot_region: x, y, width, height are required (finite numbers, |v| <= 1e7)", .{});
            const rh = a.num("height") orelse return errMsg(allocator, "screenshot_region: x, y, width, height are required (finite numbers, |v| <= 1e7)", .{});
            const r: capture.Rect = .{ .x = toPhys(x), .y = toPhys(y), .w = toPhys(rw), .h = toPhys(rh) };
            if (!capture.insideVirtual(r)) return errMsg(allocator, "screenshot_region: the region must be non-empty and lie entirely on the virtual desktop", .{});
            const bmp = capture.captureRect(allocator, r) catch |e| return outcome(allocator, e, "capture the region");
            const f = image.fitWidth(bmp.w, bmp.h, llm_width);
            const out = try image.downscale(allocator, bmp, f.w, f.h);
            return pngResult(allocator, out, try std.fmt.allocPrint(allocator, "Region: ({d},{d}) {d}x{d} image-space -> zoomed to {d}x{d}px.", .{ x, y, rw, rh, out.w, out.h }));
        },
        .click, .double_click, .right_click, .middle_click, .triple_click, .hover, .move => {
            const x = a.num("x") orelse return errMsg(allocator, "{s}: x and y are required (finite numbers, |v| <= 1e7)", .{action});
            const y = a.num("y") orelse return errMsg(allocator, "{s}: x and y are required (finite numbers, |v| <= 1e7)", .{action});
            const rx = toPhys(x);
            const ry = toPhys(y);
            const what = try std.fmt.allocPrint(allocator, "{s} at ({d}, {d}) -> screen ({d}, {d})", .{ action, x, y, rx, ry });
            const r = switch (act) {
                .click => click(allocator, rx, ry, .left, 1),
                .double_click => click(allocator, rx, ry, .left, 2),
                .triple_click => click(allocator, rx, ry, .left, 3),
                .right_click => click(allocator, rx, ry, .right, 1),
                .middle_click => click(allocator, rx, ry, .middle, 1),
                else => moveTo(rx, ry),
            };
            r catch |e| return outcome(allocator, e, what);
            return switch (act) {
                .click => okMsg(allocator, "Clicked at ({d}, {d}) -> logical ({d}, {d})", .{ x, y, rx, ry }),
                .double_click => okMsg(allocator, "Double-clicked at ({d}, {d})", .{ x, y }),
                .triple_click => okMsg(allocator, "Triple-clicked at ({d}, {d})", .{ x, y }),
                .right_click => okMsg(allocator, "Right-clicked at ({d}, {d})", .{ x, y }),
                .middle_click => okMsg(allocator, "Middle-clicked at ({d}, {d})", .{ x, y }),
                else => okMsg(allocator, "Mouse moved to ({d}, {d})", .{ x, y }),
            };
        },
        .move_relative => {
            const dx = a.num("dx") orelse return errMsg(allocator, "move_relative: dx and dy are required (finite numbers, |v| <= 1e7)", .{});
            const dy = a.num("dy") orelse return errMsg(allocator, "move_relative: dx and dy are required (finite numbers, |v| <= 1e7)", .{});
            var p: w.POINT = .{ .x = 0, .y = 0 };
            _ = w.GetCursorPos(&p);
            moveTo(p.x +| toPhys(dx), p.y +| toPhys(dy)) catch |e| return outcome(allocator, e, try std.fmt.allocPrint(allocator, "move the cursor by ({d}, {d})", .{ dx, dy }));
            return okMsg(allocator, "Cursor moved by ({d}, {d}) image-space", .{ dx, dy });
        },
        .scroll, .scroll_horizontal => {
            const horizontal = act == .scroll_horizontal;
            const x = a.num("x") orelse return errMsg(allocator, "{s}: x, y and direction are required (finite numbers, |v| <= 1e7)", .{action});
            const y = a.num("y") orelse return errMsg(allocator, "{s}: x, y and direction are required (finite numbers, |v| <= 1e7)", .{action});
            const dir = a.str("direction") orelse return errMsg(allocator, "{s}: x, y and direction are required (finite numbers, |v| <= 1e7)", .{action});
            const ticks: i32 = @intCast(std.math.clamp(a.int("amount") orelse 3, 1, 100));
            // Win32 wheel: positive = up / right.
            const sign: i32 = if (horizontal)
                (if (std.ascii.eqlIgnoreCase(dir, "right")) 1 else if (std.ascii.eqlIgnoreCase(dir, "left")) -1 else 0)
            else
                (if (std.ascii.eqlIgnoreCase(dir, "up")) 1 else if (std.ascii.eqlIgnoreCase(dir, "down")) -1 else 0);
            if (sign == 0) return errMsg(allocator, "{s}: direction must be {s}", .{ action, if (horizontal) "left or right" else "up or down" });
            scrollAt(toPhys(x), toPhys(y), sign * ticks, horizontal) catch |e| return outcome(allocator, e, try std.fmt.allocPrint(allocator, "scroll {s} {d} ticks at ({d}, {d})", .{ dir, ticks, x, y }));
            return okMsg(allocator, "Scrolled {s} {d} ticks at ({d}, {d})", .{ dir, ticks, x, y });
        },
        .drag => {
            const sx = a.num("startX") orelse a.num("x1") orelse return errMsg(allocator, "drag: startX, startY, endX, endY are required (finite numbers, |v| <= 1e7)", .{});
            const sy = a.num("startY") orelse a.num("y1") orelse return errMsg(allocator, "drag: startX, startY, endX, endY are required (finite numbers, |v| <= 1e7)", .{});
            const ex = a.num("endX") orelse a.num("x2") orelse return errMsg(allocator, "drag: startX, startY, endX, endY are required (finite numbers, |v| <= 1e7)", .{});
            const ey = a.num("endY") orelse a.num("y2") orelse return errMsg(allocator, "drag: startX, startY, endX, endY are required (finite numbers, |v| <= 1e7)", .{});
            const pts = [_][2]i32{ .{ toPhys(sx), toPhys(sy) }, .{ toPhys(ex), toPhys(ey) } };
            dragThrough(&pts, 250, .left) catch |e| return outcome(allocator, e, try std.fmt.allocPrint(allocator, "drag ({d},{d}) -> ({d},{d})", .{ sx, sy, ex, ey }));
            return okMsg(allocator, "Dragged ({d},{d}) -> ({d},{d})", .{ sx, sy, ex, ey });
        },
        .drag_path => {
            const pv = a.get("path") orelse return errMsg(allocator, "drag_path: path must be a JSON array of {{x,y}}", .{});
            const arr: std.json.Array = switch (pv) {
                .array => |arr| arr,
                .string => |s| blk: {
                    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, s, .{}) catch return errMsg(allocator, "drag_path: path must be a JSON array of {{x,y}}", .{});
                    if (parsed != .array) return errMsg(allocator, "drag_path: path must be a JSON array of {{x,y}}", .{});
                    break :blk parsed.array;
                },
                else => return errMsg(allocator, "drag_path: path must be a JSON array of {{x,y}}", .{}),
            };
            if (arr.items.len < 2) return errMsg(allocator, "drag_path: need at least 2 points", .{});
            const pts = try allocator.alloc([2]i32, arr.items.len);
            for (arr.items, pts) |p, *out| {
                const pa = Args.of(p);
                out.* = .{ toPhys(pa.num("x") orelse return errMsg(allocator, "drag_path: every point needs x and y", .{})), toPhys(pa.num("y") orelse return errMsg(allocator, "drag_path: every point needs x and y", .{})) };
            }
            dragThrough(pts, @intCast(16 * pts.len), .left) catch |e| return outcome(allocator, e, try std.fmt.allocPrint(allocator, "drag through {d} points", .{pts.len}));
            return okMsg(allocator, "Stepped-drag through {d} points", .{pts.len});
        },
        .mouse_down, .mouse_up => {
            const name = a.str("button") orelse "left";
            const b = input.parseButton(name) orelse return errMsg(allocator, "{s}: button must be left, right or middle", .{action});
            buttonAction(b, act == .mouse_up) catch |e| return outcome(allocator, e, try std.fmt.allocPrint(allocator, "{s} ({s})", .{ action, name }));
            return if (act == .mouse_up) okMsg(allocator, "Released {s} button", .{name}) else okMsg(allocator, "Pressed {s} button", .{name});
        },
        .type => {
            const text = a.str("text") orelse return errMsg(allocator, "type: text is required", .{});
            typeText(allocator, text) catch |e| return outcome(allocator, e, try std.fmt.allocPrint(allocator, "type {d} chars", .{charCount(text)}));
            const where = try activeDescription(allocator);
            return okMsg(allocator, "Typed {d} chars into {s}", .{ charCount(text), where });
        },
        .key, .key_press, .key_down, .key_up => {
            const combo_s = a.str("combo") orelse a.str("key") orelse return errMsg(allocator, "{s}: combo (or key) is required", .{action});
            var label: ?[]const u8 = null;
            const combo = parseComboChecked(combo_s, &label) catch |e| switch (e) {
                error.BlockedCombo => return errMsg(allocator, "BLOCKED: \"{s}\" is a dangerous key combo ({s}).", .{ combo_s, label.? }),
                else => return errMsg(allocator, "{s}: cannot parse \"{s}\": {s}", .{ action, combo_s, @errorName(e) }),
            };
            const r = switch (act) {
                .key_down => keyEdge(allocator, &combo, false),
                .key_up => keyEdge(allocator, &combo, true),
                else => pressCombo(allocator, &combo),
            };
            r catch |e| return outcome(allocator, e, try std.fmt.allocPrint(allocator, "{s} {s}", .{ action, combo_s }));
            return switch (act) {
                .key_down => okMsg(allocator, "Key down: {s}", .{combo_s}),
                .key_up => okMsg(allocator, "Key up: {s}", .{combo_s}),
                else => okMsg(allocator, "Key pressed: {s} in {s}", .{ combo_s, try activeDescription(allocator) }),
            };
        },
        .wait => {
            const s = std.math.clamp(a.num("seconds") orelse 1.0, 0.1, 30.0);
            w.sleepMs(@intFromFloat(s * 1000.0));
            return okMsg(allocator, "Waited {d}s", .{s});
        },
    }
}

fn activeDescription(allocator: std.mem.Allocator) ![]const u8 {
    const win = (try wins.active(allocator)) orelse return "(unknown)";
    return std.fmt.allocPrint(allocator, "[{s}] \"{s}\"", .{ win.process, win.title });
}

// ── clawdcursor `window` ────────────────────────────────────────────────────

fn queryOf(a: Args) wins.Query {
    return .{
        .process_name = a.str("processName"),
        .pid = if (a.int("processId")) |p| std.math.cast(u32, p) else null,
        .title = a.str("title"),
    };
}

/// Window named by the query, or the foreground window when no query given.
fn targetWindow(allocator: std.mem.Allocator, q: wins.Query) !?wins.Info {
    if (q.isEmpty()) return wins.active(allocator);
    const all = try wins.list(allocator);
    return wins.findByQuery(all, q);
}

fn writeBounds(js: *std.json.Stringify, r: w.RECT) !void {
    try js.beginObject();
    try js.objectField("x");
    try js.write(r.left);
    try js.objectField("y");
    try js.write(r.top);
    try js.objectField("width");
    try js.write(r.right - r.left);
    try js.objectField("height");
    try js.write(r.bottom - r.top);
    try js.endObject();
}

fn formatWindowLine(out: *std.ArrayList(u8), allocator: std.mem.Allocator, win: wins.Info) !void {
    try out.print(allocator, "{s} [{s}] \"{s}\" pid:{d}", .{ if (win.minimized) "[MIN]" else "[OK]", win.process, win.title, win.pid });
    if (win.minimized) {
        try out.appendSlice(allocator, " (minimized)");
    } else {
        try out.print(allocator, " at ({d},{d}) {d}x{d}", .{ win.rect.left, win.rect.top, win.width(), win.height() });
    }
}

const webview_apps = [_]struct { procs: []const []const u8, titles: []const []const u8, name: []const u8, kind: []const u8, flag: ?[]const u8 }{
    .{ .procs = &.{"olk"}, .titles = &.{"- outlook"}, .name = "New Outlook", .kind = "webview2", .flag = null },
    .{ .procs = &.{ "ms-teams", "teams" }, .titles = &.{"microsoft teams"}, .name = "Microsoft Teams", .kind = "webview2", .flag = null },
    .{ .procs = &.{"discord"}, .titles = &.{"discord"}, .name = "Discord", .kind = "electron", .flag = "--remote-debugging-port=9222" },
    .{ .procs = &.{"slack"}, .titles = &.{"slack"}, .name = "Slack", .kind = "electron", .flag = "--remote-debugging-port=9222" },
    .{ .procs = &.{ "code", "code - insiders" }, .titles = &.{"visual studio code"}, .name = "VS Code", .kind = "electron", .flag = "--inspect=9222" },
    .{ .procs = &.{ "github desktop", "githubdesktop" }, .titles = &.{"github desktop"}, .name = "GitHub Desktop", .kind = "electron", .flag = null },
    .{ .procs = &.{"notion"}, .titles = &.{"notion"}, .name = "Notion", .kind = "electron", .flag = null },
    .{ .procs = &.{"obsidian"}, .titles = &.{"obsidian"}, .name = "Obsidian", .kind = "electron", .flag = null },
    .{ .procs = &.{"spotify"}, .titles = &.{"spotify"}, .name = "Spotify", .kind = "chromium-shell", .flag = null },
};

fn edgePath(allocator: std.mem.Allocator) ?[]const u8 {
    const candidates = [_][]const u8{
        "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
        "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
    };
    for (candidates) |c| if (sys.pathExists(allocator, c)) return c;
    return null;
}

fn clawdWindow(allocator: std.mem.Allocator, _: std.Io, args: std.json.Value) !mcp.ToolResult {
    const a = Args.of(args);
    const action = a.str("action") orelse return errMsg(allocator, "window: \"action\" is required.", .{});
    const Act = enum { list, active, focus, maximize, minimize, restore, close, resize, list_displays, screen_size, open_app, open_file, open_url, switch_tab, navigate };
    const act = std.meta.stringToEnum(Act, action) orelse return errMsg(allocator, "window: unknown action \"{s}\". Valid: list, active, focus, maximize, minimize, restore, close, resize, list_displays, screen_size, open_app, open_file, open_url, switch_tab, navigate", .{action});

    switch (act) {
        .list => {
            const all = try wins.list(allocator);
            if (all.len == 0) return .{ .text = "(no windows found)" };
            var out: std.ArrayList(u8) = .empty;
            for (all, 0..) |win, i| {
                if (i > 0) try out.append(allocator, '\n');
                try formatWindowLine(&out, allocator, win);
            }
            return .{ .text = out.items };
        },
        .active => {
            const win = (try wins.active(allocator)) orelse return .{ .text = "(no active window)" };
            var sw: std.Io.Writer.Allocating = .init(allocator);
            var js: std.json.Stringify = .{ .writer = &sw.writer };
            try js.beginObject();
            try js.objectField("title");
            try js.write(win.title);
            try js.objectField("processName");
            try js.write(win.process);
            try js.objectField("processId");
            try js.write(win.pid);
            try js.objectField("bounds");
            try writeBounds(&js, win.rect);
            try js.endObject();
            return .{ .text = sw.written() };
        },
        .focus => {
            const q = queryOf(a);
            if (q.isEmpty()) return errMsg(allocator, "focus: pass processName, processId or title", .{});
            const win = (try targetWindow(allocator, q)) orelse return errMsg(allocator, "No window matched {f}", .{std.json.fmt(args, .{})});
            const ok = wins.activate(win.hwnd) catch |e| return outcome(allocator, e, try std.fmt.allocPrint(allocator, "focus [{s}] \"{s}\"", .{ win.process, win.title }));
            if (!ok) return errMsg(allocator, "Focus attempt on [{s}] \"{s}\" did not take (Windows focus-stealing rules).", .{ win.process, win.title });
            return okMsg(allocator, "Focused [{s}] \"{s}\" (pid {d})", .{ win.process, win.title, win.pid });
        },
        .maximize, .minimize, .restore => {
            const win = (try targetWindow(allocator, queryOf(a))) orelse return errMsg(allocator, "{s}: no matching window", .{action});
            const st: wins.ShowState = switch (act) {
                .maximize => .maximize,
                .minimize => .minimize,
                else => .restore,
            };
            wins.setState(win.hwnd, st) catch |e| return outcome(allocator, e, try std.fmt.allocPrint(allocator, "{s} [{s}] \"{s}\"", .{ action, win.process, win.title }));
            return okMsg(allocator, "{s}: [{s}] \"{s}\"", .{ action, win.process, win.title });
        },
        .close => {
            const q = queryOf(a);
            const win = (try targetWindow(allocator, q)) orelse return errMsg(allocator, "close: no matching window", .{});
            if (!(a.boolean("confirm") orelse false))
                return errMsg(allocator, "window: safety confirm - close would post WM_CLOSE to [{s}] \"{s}\" (unsaved work may prompt or be lost). Call again with confirm=true once the user has approved.", .{ win.process, win.title });
            const ok = wins.close(win.hwnd) catch |e| return outcome(allocator, e, try std.fmt.allocPrint(allocator, "close [{s}] \"{s}\"", .{ win.process, win.title }));
            return if (ok) okMsg(allocator, "Close request posted to [{s}] \"{s}\" (app may prompt or refuse).", .{ win.process, win.title }) else errMsg(allocator, "close request failed.", .{});
        },
        .resize => {
            const win = (try targetWindow(allocator, queryOf(a))) orelse return errMsg(allocator, "resize: no matching window", .{});
            const opt = struct {
                fn get(ar: Args, n: []const u8) ?i32 {
                    return if (ar.int(n)) |v| clampI32(v) else null;
                }
            };
            const rc = wins.setBounds(win.hwnd, opt.get(a, "x"), opt.get(a, "y"), opt.get(a, "width"), opt.get(a, "height")) catch |e|
                return outcome(allocator, e, try std.fmt.allocPrint(allocator, "resize [{s}] \"{s}\"", .{ win.process, win.title }));
            return okMsg(allocator, "Window bounds now ({d},{d}) {d}x{d}", .{ rc.left, rc.top, rc.right - rc.left, rc.bottom - rc.top });
        },
        .list_displays => {
            const ds = try wins.displays(allocator);
            var sw: std.Io.Writer.Allocating = .init(allocator);
            var js: std.json.Stringify = .{ .writer = &sw.writer, .options = .{ .whitespace = .indent_2 } };
            try js.beginArray();
            for (ds) |d| {
                try js.beginObject();
                try js.objectField("index");
                try js.write(d.index);
                try js.objectField("name");
                try js.write(d.name);
                try js.objectField("primary");
                try js.write(d.primary);
                try js.objectField("bounds");
                try writeBounds(&js, d.bounds);
                try js.objectField("workArea");
                try writeBounds(&js, d.work);
                try js.objectField("dpi");
                try js.write(d.dpi);
                try js.objectField("scaleFactor");
                try js.write(@as(f64, @floatFromInt(d.dpi)) / 96.0);
                try js.endObject();
            }
            try js.endArray();
            return .{ .text = sw.written() };
        },
        .screen_size => {
            const p = primarySize();
            const sf = imageScale();
            return okMsg(allocator, "{{\"physicalWidth\":{d},\"physicalHeight\":{d},\"screenshotScaleFactor\":{d},\"mouseScaleFactor\":{d},\"imageWidth\":{d},\"imageHeight\":{d}}}", .{
                p.w, p.h, sf, sf, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(p.w)) / sf))), @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(p.h)) / sf))),
            });
        },
        .open_app => return openApp(allocator, a),
        .open_file => {
            const path = a.str("path") orelse return errMsg(allocator, "open_file: path is required", .{});
            // Resolve the real file first (8.3 names, junctions), check the
            // FINAL name, and open that final path rather than the given one.
            const final = switch (try sys.resolveForOpen(allocator, path)) {
                .refused => |why| return errMsg(allocator, "open_file refused: {s}", .{why}),
                .ok => |f| f,
            };
            sys.shellOpen(allocator, final, null) catch |e| return outcome(allocator, e, try std.fmt.allocPrint(allocator, "open {s}", .{final}));
            return okMsg(allocator, "Opened {s}", .{final});
        },
        .open_url, .navigate => {
            const url = a.str("url") orelse return errMsg(allocator, "{s}: url is required", .{action});
            if (!sys.isHttpUrl(url)) return errMsg(allocator, "{s}: only http:// and https:// URLs are allowed", .{action});
            if (act == .navigate) {
                // clawdcursor launches Edge with CDP on 9223 and a private profile.
                if (edgePath(allocator)) |edge| {
                    const tmp = (try w.getEnv(allocator, "TEMP")) orelse "C:\\Windows\\Temp";
                    const params = try std.fmt.allocPrint(allocator, "--remote-debugging-port=9223 --user-data-dir=\"{s}\\clawdcursor-edge\" --no-first-run --disable-default-apps \"{s}\"", .{ tmp, url });
                    sys.shellOpen(allocator, edge, params) catch |e| return outcome(allocator, e, try std.fmt.allocPrint(allocator, "open {s} in Edge", .{url}));
                    return okMsg(allocator, "Opened {s} in Edge with CDP on port 9223 (the browser tool is not part of zmcp-computer).", .{url});
                }
            }
            sys.shellOpen(allocator, url, null) catch |e| return outcome(allocator, e, try std.fmt.allocPrint(allocator, "open {s}", .{url}));
            return okMsg(allocator, "Opened {s} in the default browser", .{url});
        },
        .switch_tab => {
            const combo_s: []const u8 = if (a.int("index")) |idx|
                try std.fmt.allocPrint(allocator, "ctrl+{d}", .{std.math.clamp(idx, 1, 9)})
            else if (std.mem.eql(u8, a.str("direction") orelse "next", "previous"))
                "ctrl+shift+tab"
            else
                "ctrl+tab";
            const combo = try keys.parseCombo(combo_s, scanFn);
            pressCombo(allocator, &combo) catch |e| return outcome(allocator, e, try std.fmt.allocPrint(allocator, "press {s}", .{combo_s}));
            return okMsg(allocator, "Sent {s}", .{combo_s});
        },
    }
}

fn openApp(allocator: std.mem.Allocator, a: Args) !mcp.ToolResult {
    const name = a.str("name") orelse return errMsg(allocator, "open_app: `name` is required", .{});
    if (!sys.isSafeAppName(name)) return errMsg(allocator, "open_app: illegal characters in app name", .{});
    const alias = sys.resolveAlias(name);
    const before = try wins.list(allocator);

    // Already running and a new instance isn't wanted: focus it instead.
    if (alias) |al| if (!al.always_new) {
        for (before) |win| for (al.process_names) |pn| {
            if (std.ascii.eqlIgnoreCase(pn, win.process)) {
                _ = wins.activate(win.hwnd) catch |e| return outcome(allocator, e, try std.fmt.allocPrint(allocator, "focus the running {s}", .{name}));
                return okMsg(allocator, "Opened \"{s}\" (already running; focused pid={d}, window=\"{s}\")", .{ name, win.pid, win.title });
            }
        };
    };

    if (alias != null and alias.?.uwp_id != null) {
        const id = alias.?.uwp_id.?;
        if (!sys.isValidUwpId(id)) return errMsg(allocator, "open_app: illegal uwpAppId", .{});
        const param = try std.fmt.allocPrint(allocator, "shell:AppsFolder\\{s}", .{id});
        sys.shellOpen(allocator, "explorer.exe", param) catch |e| return outcome(allocator, e, try std.fmt.allocPrint(allocator, "launch {s}", .{name}));
    } else {
        const exe = if (alias) |al| al.executable orelse name else name;
        sys.shellOpen(allocator, exe, null) catch |e| return outcome(allocator, e, try std.fmt.allocPrint(allocator, "launch {s}", .{name}));
    }

    // Poll up to 5 s for a new top-level window from the app.
    const deadline = sys.nowMs() + 5000;
    while (sys.nowMs() < deadline) {
        w.sleepMs(200);
        const now = try wins.list(allocator);
        for (now) |win| {
            var seen = false;
            for (before) |b| if (b.hwnd == win.hwnd) {
                seen = true;
                break;
            };
            if (seen) continue;
            const matches = if (alias) |al| blk: {
                for (al.process_names) |pn| if (std.ascii.eqlIgnoreCase(pn, win.process)) break :blk true;
                break :blk std.ascii.findIgnoreCase(win.title, name) != null;
            } else true;
            if (matches) return okMsg(allocator, "Opened \"{s}\" (pid={d}, window=\"{s}\")", .{ name, win.pid, win.title });
        }
    }
    return okMsg(allocator, "Launched \"{s}\" (no window surfaced yet)", .{name});
}

// ── clawdcursor `system` ────────────────────────────────────────────────────

extern "kernel32" fn GetSystemTimeAsFileTime(ft: *u64) callconv(.winapi) void;

fn clawdSystem(allocator: std.mem.Allocator, _: std.Io, args: std.json.Value) !mcp.ToolResult {
    const a = Args.of(args);
    const action = a.str("action") orelse return errMsg(allocator, "system: \"action\" is required.", .{});
    const Act = enum { clipboard_read, clipboard_write, system_time, ocr, undo, shortcuts_list, shortcuts_run, delegate, detect_webview, relaunch_with_cdp, app_guide, detect_app, classify_task, system_prompt };
    const act = std.meta.stringToEnum(Act, action) orelse return errMsg(allocator, "system: unknown action \"{s}\". Valid: clipboard_read, clipboard_write, system_time, ocr, undo, shortcuts_list, shortcuts_run, detect_webview", .{action});

    switch (act) {
        .clipboard_read => {
            const text = sys.readClipboard(allocator) catch |e| switch (e) {
                error.ClipboardEmpty => return .{ .text = "(clipboard is empty or holds no text)" },
                else => return outcome(allocator, e, "read the clipboard"),
            };
            return .{ .text = text };
        },
        .clipboard_write => {
            const text = a.str("text") orelse return errMsg(allocator, "clipboard_write: text is required", .{});
            sys.writeClipboard(allocator, text) catch |e| return outcome(allocator, e, try std.fmt.allocPrint(allocator, "write {d} bytes to the clipboard", .{text.len}));
            return okMsg(allocator, "Wrote {d} chars to clipboard", .{std.unicode.utf8CountCodepoints(text) catch text.len});
        },
        .system_time => {
            var ft: u64 = 0;
            GetSystemTimeAsFileTime(&ft);
            const epoch_ms: u64 = (ft -| 116444736000000000) / 10_000;
            var utc: w.SYSTEMTIME = undefined;
            w.GetSystemTime(&utc);
            var lt: w.SYSTEMTIME = undefined;
            w.GetLocalTime(&lt);
            var tzi: w.TIME_ZONE_INFORMATION = undefined;
            const tzr = w.GetTimeZoneInformation(&tzi);
            const tzname_w = if (tzr == 2) &tzi.DaylightName else &tzi.StandardName;
            const nlen = std.mem.indexOfScalar(u16, tzname_w, 0) orelse tzname_w.len;
            const tzname = try w.fromW(allocator, tzname_w[0..nlen]);
            const bias: i32 = tzi.Bias + (if (tzr == 2) tzi.DaylightBias else if (tzr == 1) tzi.StandardBias else 0);
            const off = -bias;
            const iso = try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{ utc.wYear, utc.wMonth, utc.wDay, utc.wHour, utc.wMinute, utc.wSecond, utc.wMilliseconds });
            const local = try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{c}{d:0>2}:{d:0>2}", .{
                lt.wYear, lt.wMonth, lt.wDay, lt.wHour, lt.wMinute, lt.wSecond, @as(u8, if (off < 0) '-' else '+'), @as(u32, @intCast(@divTrunc(@abs(off), 60))), @as(u32, @intCast(@mod(@abs(off), 60))),
            });
            return .{ .text = try std.json.Stringify.valueAlloc(allocator, .{ .iso = iso, .localString = local, .epochMs = epoch_ms, .timezone = tzname }, .{}) };
        },
        .ocr => {
            const p = capture.primaryScreen();
            const bmp = capture.captureRect(allocator, p) catch |e| return outcome(allocator, e, "capture the screen for OCR");
            const res = ocr.recognize(allocator, bmp) catch |e| return outcome(allocator, e, "run Windows OCR");
            const sf = imageScale();
            var sw: std.Io.Writer.Allocating = .init(allocator);
            var js: std.json.Stringify = .{ .writer = &sw.writer, .options = .{ .whitespace = .indent_2 } };
            var count: usize = 0;
            for (res.lines) |l| count += l.words.len;
            try js.beginObject();
            try js.objectField("elementCount");
            try js.write(count);
            try js.objectField("elements");
            try js.beginArray();
            for (res.lines, 0..) |l, li| for (l.words) |wd| {
                try js.beginObject();
                try js.objectField("text");
                try js.write(wd.text);
                try js.objectField("x");
                try js.write(f2i(wd.x));
                try js.objectField("y");
                try js.write(f2i(wd.y));
                try js.objectField("width");
                try js.write(f2i(wd.w));
                try js.objectField("height");
                try js.write(f2i(wd.h));
                try js.objectField("confidence");
                try js.write(1.0);
                try js.objectField("line");
                try js.write(li);
                try js.endObject();
            };
            try js.endArray();
            try js.objectField("fullText");
            try js.write(res.text);
            try js.objectField("durationMs");
            try js.write(res.duration_ms);
            try js.objectField("coordinateSystem");
            try js.write("real_screen_pixels");
            try js.objectField("toMouseClick");
            try js.write(try std.fmt.allocPrint(allocator, "Divide coordinates by {d:.4} to convert to computer.click image-space.", .{sf}));
            try js.endObject();
            return .{ .text = sw.written() };
        },
        .undo => {
            const combo = try keys.parseCombo("ctrl+z", scanFn);
            pressCombo(allocator, &combo) catch |e| return outcome(allocator, e, "send ctrl+z");
            return .{ .text = "Sent undo keystroke." };
        },
        .shortcuts_list => {
            const cat = a.str("category");
            const ctx = a.str("context");
            var sw: std.Io.Writer.Allocating = .init(allocator);
            var js: std.json.Stringify = .{ .writer = &sw.writer, .options = .{ .whitespace = .indent_2 } };
            var n: usize = 0;
            for (&shortcuts.data.all) |*s| {
                if (shortcuts.listed(s, cat, ctx)) n += 1;
            }
            if (n == 0) return okMsg(allocator, "No shortcuts found{s}{s}. Available categories: navigation, browser, editing, social, window, file, view, quick", .{
                if (cat) |c| try std.fmt.allocPrint(allocator, " in category \"{s}\"", .{c}) else "",
                if (ctx) |c| try std.fmt.allocPrint(allocator, " for context \"{s}\"", .{c}) else "",
            });
            try js.beginObject();
            try js.objectField("platform");
            try js.write("win32");
            try js.objectField("count");
            try js.write(n);
            try js.objectField("shortcuts");
            try js.beginArray();
            for (&shortcuts.data.all) |*s| {
                if (!shortcuts.listed(s, cat, ctx)) continue;
                try js.beginObject();
                try js.objectField("id");
                try js.write(s.id);
                try js.objectField("category");
                try js.write(s.category);
                try js.objectField("description");
                try js.write(s.description);
                try js.objectField("intent");
                try js.write(s.intent);
                try js.objectField("key");
                try js.write(s.key);
                if (s.context.len > 0) {
                    try js.objectField("context");
                    try js.write(s.context);
                }
                try js.endObject();
            }
            try js.endArray();
            try js.objectField("hint");
            try js.write("Use system.shortcuts_run with the intent string to run a shortcut, or computer.key with the key combo directly.");
            try js.endObject();
            return .{ .text = sw.written() };
        },
        .shortcuts_run => {
            const intent = a.str("intent") orelse return errMsg(allocator, "shortcuts_run: intent is required", .{});
            var ctx_hint: []const u8 = a.str("context") orelse "";
            if (ctx_hint.len == 0) {
                if (wins.active(allocator) catch null) |win| ctx_hint = try std.fmt.allocPrint(allocator, "{s} {s}", .{ win.process, win.title });
            }
            const m = shortcuts.find(intent, ctx_hint) orelse {
                var out: std.ArrayList(u8) = .empty;
                try out.print(allocator, "No shortcut matched intent \"{s}\". Try one of these:\n", .{intent});
                var shown: usize = 0;
                for (&shortcuts.data.all) |*s| {
                    if (shown == 10) break;
                    if (!shortcuts.contextAllows(s, "", ctx_hint)) continue;
                    try out.print(allocator, "  - \"{s}\" -> {s} ({s})\n", .{ s.intent, s.key, s.description });
                    shown += 1;
                }
                try out.appendSlice(allocator, "\nOr use computer.key directly with a specific key combo.");
                return .{ .text = out.items, .is_error = true };
            };
            var label: ?[]const u8 = null;
            const combo = parseComboChecked(m.shortcut.key, &label) catch |e| switch (e) {
                error.BlockedCombo => return errMsg(allocator, "BLOCKED: shortcut \"{s}\" is {s}, a destructive combo.", .{ m.shortcut.intent, m.shortcut.key }),
                else => return errMsg(allocator, "shortcuts_run: cannot parse {s}: {s}", .{ m.shortcut.key, @errorName(e) }),
            };
            pressCombo(allocator, &combo) catch |e| return outcome(allocator, e, try std.fmt.allocPrint(allocator, "press {s} ({s})", .{ m.shortcut.key, m.shortcut.intent }));
            return .{ .text = try std.json.Stringify.valueAlloc(allocator, .{
                .executed = m.shortcut.key,
                .intent = m.shortcut.intent,
                .matched = m.matched_intent,
                .matchType = if (m.exact) "exact" else "fuzzy",
                .description = m.shortcut.description,
                .window = try activeDescription(allocator),
            }, .{}) };
        },
        .detect_webview => {
            const all = try wins.list(allocator);
            var sw: std.Io.Writer.Allocating = .init(allocator);
            var js: std.json.Stringify = .{ .writer = &sw.writer, .options = .{ .whitespace = .indent_2 } };
            try js.beginObject();
            try js.objectField("candidates");
            try js.beginArray();
            for (all) |win| {
                for (webview_apps) |app| {
                    var hit = false;
                    for (app.procs) |p| if (std.ascii.startsWithIgnoreCase(win.process, p)) {
                        hit = true;
                    };
                    for (app.titles) |tt| if (std.ascii.findIgnoreCase(win.title, tt) != null) {
                        hit = true;
                    };
                    if (!hit) continue;
                    try js.beginObject();
                    try js.objectField("processName");
                    try js.write(win.process);
                    try js.objectField("processId");
                    try js.write(win.pid);
                    try js.objectField("title");
                    try js.write(win.title);
                    try js.objectField("displayName");
                    try js.write(app.name);
                    try js.objectField("kind");
                    try js.write(app.kind);
                    try js.objectField("cdpPort");
                    try js.write(null);
                    try js.objectField("hint");
                    try js.write(if (app.flag) |f|
                        try std.fmt.allocPrint(allocator, "Accessibility trees of {s} apps are sparse. Relaunch with {s} to drive its web view over CDP.", .{ app.kind, f })
                    else
                        try std.fmt.allocPrint(allocator, "Accessibility trees of {s} apps are sparse; prefer OCR (system.ocr) or screenshots.", .{app.kind}));
                    try js.endObject();
                    break;
                }
            }
            try js.endArray();
            try js.objectField("note");
            try js.write("CDP port probing is not implemented in zmcp-computer; cdpPort is always null.");
            try js.endObject();
            return .{ .text = sw.written() };
        },
        .delegate, .relaunch_with_cdp, .app_guide, .detect_app, .classify_task, .system_prompt => return errMsg(allocator, "system.{s} is not available in zmcp-computer: it needs clawdcursor's agent pipeline (LLM router, app-knowledge guides or the CDP bridge). Run clawdcursor for it.", .{action}),
    }
}

// ── tests ───────────────────────────────────────────────────────────────────

const t = std.testing;

fn callForTest(handler: mcp.ToolHandler, json: []const u8) !struct { arena: std.heap.ArenaAllocator, res: mcp.ToolResult } {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    errdefer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
    const res = try handler(arena.allocator(), undefined, v);
    return .{ .arena = arena, .res = res };
}

test "every tool schema is valid JSON with an object type" {
    for (cc_tools ++ clawd_tools) |tool| {
        var parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, tool.input_schema_json, .{});
        defer parsed.deinit();
        try t.expectEqualStrings("object", parsed.value.object.get("type").?.string);
    }
    try t.expectEqual(@as(usize, 15), cc_tools.len);
    try t.expectEqual(@as(usize, 3), clawd_tools.len);
}

test "argument coercion accepts ints, floats and numeric strings" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"a\":3,\"b\":2.6,\"c\":\"7\",\"d\":null,\"e\":true}", .{});
    const a = Args.of(v);
    try t.expectEqual(@as(i64, 3), a.int("a").?);
    try t.expectEqual(@as(i64, 3), a.int("b").?);
    try t.expectEqual(@as(i64, 7), a.int("c").?);
    try t.expect(a.int("d") == null);
    try t.expect(a.int("missing") == null);
    try t.expect(a.boolean("e").?);
}

test "handlers refuse to inject from tests and report it as a dry run" {
    var r = try callForTest(ccClickScreen, "{\"x\":10,\"y\":20}");
    defer r.arena.deinit();
    try t.expect(!r.res.is_error);
    try t.expect(std.mem.startsWith(u8, r.res.text, "[dry-run]"));

    var r2 = try callForTest(clawdComputer, "{\"action\":\"type\",\"text\":\"hi\"}");
    defer r2.arena.deinit();
    try t.expect(std.mem.startsWith(u8, r2.res.text, "[dry-run]"));
}

test "blocked combos are refused before any input is built" {
    var r = try callForTest(ccPressKeys, "{\"keys\":[[\"alt\",\"f4\"]]}");
    defer r.arena.deinit();
    try t.expect(r.res.is_error);
    try t.expect(std.mem.startsWith(u8, r.res.text, "BLOCKED"));

    var r2 = try callForTest(clawdComputer, "{\"action\":\"key\",\"combo\":\"ctrl+w\"}");
    defer r2.arena.deinit();
    try t.expect(r2.res.is_error);
}

test "press_keys validates the whole sequence up front" {
    var r = try callForTest(ccPressKeys, "{\"keys\":[\"a\",\"notakey\"]}");
    defer r.arena.deinit();
    try t.expect(r.res.is_error);
    var r2 = try callForTest(ccPressKeys, "{\"keys\":42}");
    defer r2.arena.deinit();
    try t.expect(r2.res.is_error);
}

test "compound tools reject unknown actions and report stubs clearly" {
    var r = try callForTest(clawdComputer, "{\"action\":\"fly\"}");
    defer r.arena.deinit();
    try t.expect(r.res.is_error);
    var r2 = try callForTest(clawdSystem, "{\"action\":\"delegate\",\"task\":\"x\"}");
    defer r2.arena.deinit();
    try t.expect(r2.res.is_error);
    try t.expect(std.mem.indexOf(u8, r2.res.text, "not available") != null);
    var r3 = try callForTest(clawdWindow, "{\"action\":\"open_url\",\"url\":\"file:///c:/x\"}");
    defer r3.arena.deinit();
    try t.expect(r3.res.is_error);
}

fn resetHeldForTest() void {
    key_guard.held = .{};
}

test "huge, NaN and infinite numbers are rejected without panicking" {
    for ([_][]const u8{
        "{\"x\":1e300,\"y\":5}", "{\"x\":\"NaN\",\"y\":5}", "{\"x\":\"inf\",\"y\":5}", "{\"x\":-1e8,\"y\":5}",
    }) |j| {
        var r = try callForTest(ccClickScreen, j);
        defer r.arena.deinit();
        try t.expect(r.res.is_error);
    }
    var r2 = try callForTest(clawdComputer, "{\"action\":\"click\",\"x\":1e300,\"y\":1}");
    defer r2.arena.deinit();
    try t.expect(r2.res.is_error);
    var r3 = try callForTest(clawdComputer, "{\"action\":\"screenshot_region\",\"x\":0,\"y\":0,\"width\":9999999,\"height\":9999999}");
    defer r3.arena.deinit();
    try t.expect(r3.res.is_error);
    try t.expect(std.mem.indexOf(u8, r3.res.text, "virtual desktop") != null);
    var r4 = try callForTest(clawdComputer, "{\"action\":\"move_relative\",\"dx\":1e30,\"dy\":0}");
    defer r4.arena.deinit();
    try t.expect(r4.res.is_error);
}

test "points outside the virtual desktop are rejected, not clamped" {
    var r = try callForTest(ccClickScreen, "{\"x\":-5000000,\"y\":5}");
    defer r.arena.deinit();
    try t.expect(r.res.is_error);
    try t.expect(std.mem.indexOf(u8, r.res.text, "outside the virtual desktop") != null);
    var r2 = try callForTest(ccDragMouse, "{\"from_x\":1,\"from_y\":1,\"to_x\":9000000,\"to_y\":1}");
    defer r2.arena.deinit();
    try t.expect(r2.res.is_error);
    var r3 = try callForTest(clawdComputer, "{\"action\":\"scroll\",\"x\":-4000000,\"y\":1,\"direction\":\"up\"}");
    defer r3.arena.deinit();
    try t.expect(r3.res.is_error);
}

test "blocklist: contained chords and held keys across calls" {
    resetHeldForTest();
    defer resetHeldForTest();
    for ([_][]const u8{ "{\"keys\":\"alt+f4+x\"}", "{\"keys\":\"shift+alt+f4\"}", "{\"keys\":[[\"menu\",\"f4\"]]}", "{\"keys\":[[\"rwin\",\"l\"]]}", "{\"keys\":[[\"control\",\"shift\",\"w\"]]}" }) |j| {
        var r = try callForTest(ccPressKeys, j);
        defer r.arena.deinit();
        try t.expect(r.res.is_error);
        try t.expect(std.mem.startsWith(u8, r.res.text, "BLOCKED"));
    }
    // key_down alt, then f4 on any path is refused
    var d = try callForTest(ccKeyDown, "{\"key\":\"alt\"}");
    defer d.arena.deinit();
    try t.expect(!d.res.is_error);
    try t.expect(key_guard.held.has(0x12));
    for ([_]struct { mcp.ToolHandler, []const u8 }{
        .{ clawdComputer, "{\"action\":\"key\",\"combo\":\"f4\"}" },
        .{ ccPressKeys, "{\"keys\":\"f4\"}" },
        .{ ccKeyDown, "{\"key\":\"f4\"}" },
        .{ clawdComputer, "{\"action\":\"key_down\",\"combo\":\"f4\"}" },
    }) |c| {
        var r = try callForTest(c[0], c[1]);
        defer r.arena.deinit();
        try t.expect(r.res.is_error);
        try t.expect(std.mem.startsWith(u8, r.res.text, "BLOCKED"));
    }
    // releasing alt (via a different alias) clears it
    var u = try callForTest(clawdComputer, "{\"action\":\"key_up\",\"combo\":\"altleft\"}");
    defer u.arena.deinit();
    try t.expect(!key_guard.held.has(0x12));
    var ok = try callForTest(ccPressKeys, "{\"keys\":\"f4\"}");
    defer ok.arena.deinit();
    try t.expect(!ok.res.is_error);
    // win held, then l
    var wd = try callForTest(clawdComputer, "{\"action\":\"key_down\",\"combo\":\"super\"}");
    defer wd.arena.deinit();
    var wl = try callForTest(clawdComputer, "{\"action\":\"key\",\"combo\":\"l\"}");
    defer wl.arena.deinit();
    try t.expect(wl.res.is_error);
    // ctrl held: typed text is Unicode, not a VK chord, so it is allowed
    resetHeldForTest();
    var cd = try callForTest(ccKeyDown, "{\"key\":\"ctrl\"}");
    defer cd.arena.deinit();
    var ty = try callForTest(ccTypeText, "{\"text\":\"w\"}");
    defer ty.arena.deinit();
    try t.expect(!ty.res.is_error);
    var cw = try callForTest(ccPressKeys, "{\"keys\":\"w\"}");
    defer cw.arena.deinit();
    try t.expect(cw.res.is_error);
}

test "type_text is capped at 64k characters and never echoes the text" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long = try a.alloc(u8, max_type_chars + 1);
    @memset(long, 'a');
    const j = try std.fmt.allocPrint(a, "{{\"text\":\"{s}\"}}", .{long});
    var r = try callForTest(ccTypeText, j);
    defer r.arena.deinit();
    try t.expect(r.res.is_error);
    try t.expect(std.mem.indexOf(u8, r.res.text, "65536") != null);
    try t.expect(r.res.text.len < 300);
    var r2 = try callForTest(clawdComputer, try std.fmt.allocPrint(a, "{{\"action\":\"type\",\"text\":\"{s}\"}}", .{long}));
    defer r2.arena.deinit();
    try t.expect(r2.res.is_error);
    var r3 = try callForTest(ccTypeText, "{\"text\":\"secret-password-123\"}");
    defer r3.arena.deinit();
    try t.expect(std.mem.indexOf(u8, r3.res.text, "secret") == null);
}

test "save_to_downloads is off by default" {
    try t.expect(!allow_save);
    try t.expectError(error.SaveDisabled, saveToDownloads(t.allocator, "x"));
}

test "open_file refuses scripts and UNC paths through the handler" {
    for ([_][]const u8{ "{\"action\":\"open_file\",\"path\":\"C:\\\\x\\\\a.ps1\"}", "{\"action\":\"open_file\",\"path\":\"\\\\\\\\srv\\\\s\\\\a.pdf\"}" }) |j| {
        var r = try callForTest(clawdWindow, j);
        defer r.arena.deinit();
        try t.expect(r.res.is_error);
        try t.expect(std.mem.indexOf(u8, r.res.text, "refused") != null);
    }
}

test "pyQuote escapes like Python repr" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try pyQuote(&out, t.allocator, "it's a\\b");
    try t.expectEqualStrings("'it\\'s a\\\\b'", out.items);
}

test {
    _ = @import("win32.zig");
    _ = @import("keys.zig");
    _ = @import("input.zig");
    _ = @import("image.zig");
    _ = @import("capture.zig");
    _ = @import("match.zig");
    _ = @import("wins.zig");
    _ = @import("sys.zig");
    _ = @import("shortcuts.zig");
    _ = @import("ocr.zig");
    _ = @import("integrity.zig");
    _ = @import("guard.zig");
}
