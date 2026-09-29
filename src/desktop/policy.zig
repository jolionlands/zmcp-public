//! zmcp-desktop policy: the allowlist, the always-refused processes, the kill
//! event name, runtime-id encoding, the node shape and its redacted JSON.
//!
//! Pure (no Win32, no COM), so every rule here is unit-tested on any host.

const std = @import("std");
const shared = @import("computer_shared");
const keys = shared.keys;

/// Per-node text cap (Unicode scalar values) for `name` and `value`.
pub const max_text_chars: usize = 500;
/// AutomationId / ClassName cap.
pub const max_id_chars: usize = 200;
/// Cap on one observe/find reply. Past it the node list is cut and
/// `truncated` is set.
pub const max_output_bytes: usize = 256 * 1024;

/// Processes whose windows are refused even when the host allowlists them:
/// the logon UI, UAC and the credential prompt (matched on the image's base
/// name, wherever it lives).
pub const always_refused = [_][]const u8{ "logonui.exe", "consent.exe", "credentialuibroker.exe" };

/// The UWP frame host. It is never an allowlist entry: a UWP window is gated
/// on the hosted app's image path instead (see main.zig `gate`).
pub const frame_host = "applicationframehost.exe";

/// The allowlist is a list of FULL image paths, exactly as
/// QueryFullProcessImageNameW reports them (Win32 form), compared
/// case-insensitively:
///
///   zmcp-desktop --allow "C:\Program Files\Signal\Signal.exe"
///                --allow "C:\Windows\System32\notepad.exe|C:\Windows\System32\charmap.exe"
///                [--kill-event NAME]
///
/// `--allow` repeats; one value may hold several paths separated by `|`
/// (a character no Windows path can contain). An entry is dropped (never
/// trusted) unless it is an absolute drive path (`X:\...`) with no `.`/`..`
/// segment and no wildcard, and its base name is not always refused or the
/// UWP frame host. A bare name such as `signal.exe` matches nothing.
pub const Policy = struct {
    allocator: std.mem.Allocator,
    /// Normalized, lowercased full paths.
    allow: [][]u8,
    /// `--kill-event NAME`; null means the default `Local\zmcp-desktop-kill-<ppid>`.
    kill_event: ?[]u8,
    /// `--resume-event NAME`: the event the host (Nava's Continue button, and
    /// only that) signals to lift an auto-pause. Without it a pause lasts for
    /// the rest of the session. There is no tool that resumes.
    resume_event: ?[]u8 = null,
    /// `--allow-payments`: lets act tools press payment-like buttons. Nava never passes it.
    allow_payments: bool = false,
    limits: Limits = .{},

    pub fn fromArgs(allocator: std.mem.Allocator, args: []const []const u8) !Policy {
        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |x| allocator.free(x);
            list.deinit(allocator);
        }
        var kill: ?[]u8 = null;
        errdefer if (kill) |k| allocator.free(k);
        var limits: Limits = .{};
        var allow_payments = false;
        var resume_ev: ?[]u8 = null;
        errdefer if (resume_ev) |r| allocator.free(r);
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--allow") and i + 1 < args.len) {
                i += 1;
                var it = std.mem.splitScalar(u8, args[i], '|');
                while (it.next()) |raw| {
                    const norm = (try normalizePath(allocator, std.mem.trim(u8, raw, " \t\"'"))) orelse continue;
                    const base = baseName(norm);
                    if (isAlwaysRefused(base) or std.ascii.eqlIgnoreCase(base, frame_host)) {
                        allocator.free(norm);
                        continue;
                    }
                    try list.append(allocator, norm);
                }
            } else if (std.mem.eql(u8, a, "--kill-event") and i + 1 < args.len) {
                i += 1;
                if (kill) |k| allocator.free(k);
                kill = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, a, "--resume-event") and i + 1 < args.len) {
                i += 1;
                if (resume_ev) |r| allocator.free(r);
                resume_ev = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, a, "--allow-payments")) {
                allow_payments = true;
            } else if (i + 1 < args.len and limits.set(a, args[i + 1])) {
                i += 1;
            }
        }
        return .{ .allocator = allocator, .allow = try list.toOwnedSlice(allocator), .kill_event = kill, .resume_event = resume_ev, .allow_payments = allow_payments, .limits = limits };
    }

    pub fn deinit(self: Policy) void {
        for (self.allow) |x| self.allocator.free(x);
        self.allocator.free(self.allow);
        if (self.kill_event) |k| self.allocator.free(k);
        if (self.resume_event) |r| self.allocator.free(r);
    }

    pub fn isEmpty(self: Policy) bool {
        return self.allow.len == 0;
    }

    /// True when `image_path` (a process's full image path) equals an
    /// allowlist entry, case-insensitively, and its base name is not always
    /// refused. A bare name or a relative path never matches.
    pub fn allows(self: Policy, image_path: []const u8) bool {
        var buf: [1024]u8 = undefined;
        const norm = normalizePathBuf(&buf, image_path) orelse return false;
        const base = baseName(norm);
        if (isAlwaysRefused(base) or std.ascii.eqlIgnoreCase(base, frame_host)) return false;
        for (self.allow) |a| if (std.mem.eql(u8, a, norm)) return true;
        return false;
    }
};

/// `\\?\X:\a\b.exe`, `X:/a/b.exe` → `x:\a\b.exe` (ASCII-lowercased) into
/// `buf`, or null when the path is not an absolute drive path, has an empty,
/// `.` or `..` segment, a wildcard or a control character.
pub fn normalizePathBuf(buf: []u8, path_in: []const u8) ?[]const u8 {
    var path = path_in;
    if (std.mem.startsWith(u8, path, "\\\\?\\") or std.mem.startsWith(u8, path, "//?/")) path = path[4..];
    if (path.len < 4 or path.len > buf.len) return null;
    if (!std.ascii.isAlphabetic(path[0]) or path[1] != ':' or (path[2] != '\\' and path[2] != '/')) return null;
    for (path, 0..) |c, i| {
        buf[i] = switch (c) {
            '/' => '\\',
            '*', '?', '"', '<', '>', '|' => return null,
            else => if (c < 0x20) return null else std.ascii.toLower(c),
        };
    }
    const out = buf[0..path.len];
    if (std.mem.indexOfScalarPos(u8, out, 2, ':') != null) return null; // alternate data streams
    var it = std.mem.splitScalar(u8, out[3..], '\\');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return null;
    }
    return out;
}

pub fn normalizePath(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    var buf: [1024]u8 = undefined;
    const n = normalizePathBuf(&buf, path) orelse return null;
    return try allocator.dupe(u8, n);
}

/// The last path segment.
pub fn baseName(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfAny(u8, path, "\\/") orelse return path;
    return path[i + 1 ..];
}

pub fn isAlwaysRefused(exe: []const u8) bool {
    for (always_refused) |r| if (std.ascii.eqlIgnoreCase(r, exe)) return true;
    return false;
}

/// `Local\zmcp-desktop-kill-<ppid>`.
pub fn defaultKillEventName(buf: []u8, ppid: u32) ![]const u8 {
    return std.fmt.bufPrint(buf, "Local\\zmcp-desktop-kill-{d}", .{ppid});
}

// ── runtime ids ─────────────────────────────────────────────────────────────

/// UIA runtime id → `r<hex>-<hex>…` (each i32 as its u32 bit pattern).
pub fn encodeRuntimeId(allocator: std.mem.Allocator, ids: []const i32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, 'r');
    for (ids, 0..) |v, i| {
        if (i > 0) try out.append(allocator, '-');
        var buf: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{x}", .{@as(u32, @bitCast(v))}) catch unreachable;
        try out.appendSlice(allocator, s);
    }
    return out.toOwnedSlice(allocator);
}

pub const max_runtime_id_parts = 32;

pub fn decodeRuntimeId(allocator: std.mem.Allocator, s: []const u8) ![]i32 {
    if (s.len < 2 or s[0] != 'r') return error.BadElementId;
    var out: std.ArrayList(i32) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, s[1..], '-');
    while (it.next()) |part| {
        if (part.len == 0 or part.len > 8) return error.BadElementId;
        if (out.items.len >= max_runtime_id_parts) return error.BadElementId;
        const v = std.fmt.parseInt(u32, part, 16) catch return error.BadElementId;
        try out.append(allocator, @bitCast(v));
    }
    return out.toOwnedSlice(allocator);
}

/// A host's `expected_id` for desktop_type/desktop_key: null when none was
/// given or when the focused element (`rid`) is the one it names; else the
/// refusal. Pure.
pub fn expectedIdRefusal(allocator: std.mem.Allocator, expected: ?[]const u8, rid: []const i32) ?[]const u8 {
    const want_s = expected orelse return null;
    const want = decodeRuntimeId(allocator, want_s) catch return "refused: expected_id is not an element id (r<hex>-...)";
    defer allocator.free(want);
    if (rid.len == 0 or !std.mem.eql(i32, want, rid)) return "refused: the focus is not on the expected element (expected_id); nothing was typed or pressed";
    return null;
}

// ── roles ───────────────────────────────────────────────────────────────────

const role_names = [_][]const u8{
    "button",     "calendar", "checkbox",  "combobox",     "edit",       "hyperlink", "image",     "listitem",
    "list",       "menu",     "menubar",   "menuitem",     "progressbar", "radiobutton", "scrollbar", "slider",
    "spinner",    "statusbar", "tab",      "tabitem",      "text",       "toolbar",   "tooltip",   "tree",
    "treeitem",   "custom",   "group",     "thumb",        "datagrid",   "dataitem",  "document",  "splitbutton",
    "window",     "pane",     "header",    "headeritem",   "table",      "titlebar",  "separator", "semanticzoom",
    "appbar",
};

/// UIA_*ControlTypeId (50000..50040) → a short lowercase role.
pub fn roleName(control_type: i32) []const u8 {
    if (control_type < 50000) return "unknown";
    const i: usize = @intCast(control_type - 50000);
    return if (i < role_names.len) role_names[i] else "unknown";
}

pub fn roleId(role: []const u8) ?i32 {
    for (role_names, 0..) |r, i| if (std.ascii.eqlIgnoreCase(r, role)) return @intCast(50000 + i);
    return null;
}

/// Roles whose ValuePattern value is worth reading (and cheap): text inputs
/// and value controls. Never read when the element is a password field.
pub fn roleHasUsefulValue(control_type: i32) bool {
    return switch (control_type) {
        50003, 50004, 50015, 50016, 50030 => true, // combobox, edit, slider, spinner, document
        else => false,
    };
}

/// Elements whose TextPattern text is read (observe, focused): a focusable
/// edit, group or custom element with a TextPattern that is not a password
/// field. That is a field a ValuePattern cannot read, such as a Chromium
/// contenteditable composer (a focusable group) or a RichEdit. A document
/// (a whole web page or file) is never read, nor a list, item or button.
pub fn wantsText(control_type: i32, focusable: bool, is_password: bool, has_text: bool) bool {
    if (is_password or !has_text or !focusable) return false;
    return switch (control_type) {
        50004, 50025, 50026 => true, // edit, custom, group
        else => false,
    };
}

// ── text ────────────────────────────────────────────────────────────────────

/// UTF-16 → UTF-8, at most `max_chars` scalar values; lone surrogates become
/// U+FFFD so the result is always valid UTF-8 (JSON-safe).
pub fn utf16ToUtf8Capped(allocator: std.mem.Allocator, s: []const u16, max_chars: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, @min(s.len, max_chars) + 8);
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len and n < max_chars) : (n += 1) {
        const c = s[i];
        var cp: u21 = 0xFFFD;
        if (c >= 0xD800 and c <= 0xDBFF) {
            if (i + 1 < s.len and s[i + 1] >= 0xDC00 and s[i + 1] <= 0xDFFF) {
                cp = 0x10000 + ((@as(u21, c) - 0xD800) << 10) + (@as(u21, s[i + 1]) - 0xDC00);
                i += 2;
            } else i += 1;
        } else if (c >= 0xDC00 and c <= 0xDFFF) {
            i += 1;
        } else {
            cp = c;
            i += 1;
        }
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        try out.appendSlice(allocator, buf[0..len]);
    }
    return out.toOwnedSlice(allocator);
}

/// Unicode scalar values in UTF-16 (a lone surrogate counts as one).
pub fn utf16ScalarCount(s: []const u16) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) {
        const pair = s[i] >= 0xD800 and s[i] <= 0xDBFF and i + 1 < s.len and s[i + 1] >= 0xDC00 and s[i + 1] <= 0xDFFF;
        i += if (pair) 2 else 1;
    }
    return n;
}

/// Cut valid UTF-8 to at most `max_chars` scalar values.
pub fn capUtf8(s: []const u8, max_chars: usize) []const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len and n < max_chars) : (n += 1) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i = @min(s.len, i + len);
    }
    return s[0..i];
}

// ── nodes ───────────────────────────────────────────────────────────────────

pub const Node = struct {
    id: []const u8 = "",
    parent: ?[]const u8 = null,
    role: []const u8 = "unknown",
    name: []const u8 = "",
    /// Never serialized when `is_password` is set.
    value: ?[]const u8 = null,
    rect: [4]i32 = .{ 0, 0, 0, 0 },
    enabled: bool = false,
    focusable: bool = false,
    is_password: bool = false,
    /// UIA AutomationId / ClassName (omitted when empty) and whether the
    /// element has a ValuePattern (its value may still be withheld).
    automation_id: []const u8 = "",
    class_name: []const u8 = "",
    value_pattern: bool = false,
    /// TextPattern text (a contenteditable composer). Never serialized when
    /// `is_password` is set, capped like `value`.
    text: ?[]const u8 = null,
    /// The element has a TextPattern (serialized only when true).
    text_pattern: bool = false,
    /// `text` was cut at max_text_chars (serialized only when true).
    text_truncated: bool = false,

    pub fn write(self: Node, js: *std.json.Stringify) !void {
        try js.beginObject();
        try js.objectField("id");
        try js.write(self.id);
        try js.objectField("parent");
        try js.write(self.parent);
        try js.objectField("role");
        try js.write(self.role);
        try js.objectField("name");
        try js.write(capUtf8(self.name, max_text_chars));
        if (!self.is_password) if (self.value) |v| {
            try js.objectField("value");
            try js.write(capUtf8(v, max_text_chars));
        };
        if (!self.is_password) if (self.text) |v| {
            try js.objectField("text");
            try js.write(capUtf8(v, max_text_chars));
            if (self.text_truncated or std.unicode.utf8CountCodepoints(v) catch 0 > max_text_chars) {
                try js.objectField("text_truncated");
                try js.write(true);
            }
        };
        try js.objectField("rect");
        try js.write(self.rect);
        try js.objectField("enabled");
        try js.write(self.enabled);
        try js.objectField("focusable");
        try js.write(self.focusable);
        try js.objectField("is_password");
        try js.write(self.is_password);
        if (self.automation_id.len > 0) {
            try js.objectField("automation_id");
            try js.write(capUtf8(self.automation_id, max_id_chars));
        }
        if (self.class_name.len > 0) {
            try js.objectField("class_name");
            try js.write(capUtf8(self.class_name, max_id_chars));
        }
        try js.objectField("value_pattern");
        try js.write(self.value_pattern);
        if (self.text_pattern) {
            try js.objectField("text_pattern");
            try js.write(true);
        }
        try js.endObject();
    }

    pub fn toJson(self: Node, allocator: std.mem.Allocator) ![]u8 {
        var sw: std.Io.Writer.Allocating = .init(allocator);
        errdefer sw.deinit();
        var js = std.json.Stringify{ .writer = &sw.writer };
        try self.write(&js);
        return sw.toOwnedSlice();
    }
};

pub const Window = struct {
    hwnd: usize,
    /// Base name of the gated image (for UWP: the hosted app, not the frame host).
    exe: []const u8,
    /// Full image path that matched the allowlist.
    path: []const u8 = "",
    /// UWP frame host pid when the window is a UWP frame (not serialized).
    frame_pid: u32 = 0,
    title: []const u8,
    pid: u32,
};

pub const Extra = struct {
    key: []const u8,
    value: std.json.Value,
};

/// `{window:{hwnd,exe,title}, nodes:[…], count, truncated, …extra}` with the
/// node list cut so the whole reply stays under `max_bytes`.
pub fn writeNodes(
    allocator: std.mem.Allocator,
    window: Window,
    nodes: []const Node,
    truncated_in: bool,
    extra: []const Extra,
    max_bytes: usize,
) ![]u8 {
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    var kept: usize = 0;
    var truncated = truncated_in;
    const reserve: usize = 1024 + window.title.len * 6 + window.exe.len * 6;
    for (nodes) |n| {
        const one = try n.toJson(allocator);
        defer allocator.free(one);
        if (body.written().len + one.len + 1 + reserve > max_bytes) {
            truncated = true;
            break;
        }
        if (kept > 0) try body.writer.writeByte(',');
        try body.writer.writeAll(one);
        kept += 1;
    }

    var sw: std.Io.Writer.Allocating = .init(allocator);
    errdefer sw.deinit();
    var js = std.json.Stringify{ .writer = &sw.writer };
    try js.beginObject();
    try js.objectField("window");
    try js.beginObject();
    try js.objectField("hwnd");
    try js.write(window.hwnd);
    try js.objectField("exe");
    try js.write(window.exe);
    try js.objectField("path");
    try js.write(window.path);
    try js.objectField("title");
    try js.write(capUtf8(window.title, max_text_chars));
    try js.objectField("pid");
    try js.write(window.pid);
    try js.endObject();
    try js.objectField("count");
    try js.write(kept);
    try js.objectField("truncated");
    try js.write(truncated);
    for (extra) |e| {
        try js.objectField(e.key);
        try js.write(e.value);
    }
    try js.objectField("nodes");
    try js.beginWriteRaw();
    try sw.writer.writeByte('[');
    try sw.writer.writeAll(body.written());
    try sw.writer.writeByte(']');
    js.endWriteRaw();
    try js.endObject();
    return sw.toOwnedSlice();
}

/// Case-insensitive (ASCII) substring match.
pub fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// ── act policy (Z3) ─────────────────────────────────────────────────────────

/// The desktop_act actions.
pub const Action = enum { invoke, focus, set_value, select, expand, scroll_into_view };

pub fn parseAction(s: []const u8) ?Action {
    inline for (@typeInfo(Action).@"enum".fields) |f| {
        if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

/// Step limits and timeouts for one server process (= one control session, F45).
/// `--max-steps N` (1..10000, default 100) counts act calls (act, type, key,
/// click, scroll); `--step-timeout-ms N` (100..120000, default 10000) bounds
/// one act, checked between injected chunks; `--session-timeout-s N`
/// (1..86400, default 900) counts from the first act; `--idle-ms N`
/// (0..10000, default 750) is how long the user's keyboard and mouse must
/// have been idle before an act starts.
pub const Limits = struct {
    max_steps: u32 = 100,
    step_timeout_ms: u32 = 10_000,
    session_timeout_s: u32 = 900,
    idle_ms: u32 = 750,

    fn set(self: *Limits, flag: []const u8, value: []const u8) bool {
        const v = std.fmt.parseInt(u32, value, 10) catch return false;
        if (std.mem.eql(u8, flag, "--max-steps")) {
            self.max_steps = std.math.clamp(v, 1, 10_000);
        } else if (std.mem.eql(u8, flag, "--step-timeout-ms")) {
            self.step_timeout_ms = std.math.clamp(v, 100, 120_000);
        } else if (std.mem.eql(u8, flag, "--session-timeout-s")) {
            self.session_timeout_s = std.math.clamp(v, 1, 86_400);
        } else if (std.mem.eql(u8, flag, "--idle-ms")) {
            self.idle_ms = @min(v, 10_000);
        } else return false;
        return true;
    }
};

/// Session state for the limits and the user-input pause. Pure: the caller
/// passes the clock and the time of the last real (non-injected) user input.
pub const Session = struct {
    steps: u32 = 0,
    started_ms: ?u64 = null,
    /// Latched when real user input arrived during an act; cleared only when
    /// the host signals the --resume-event (Nava's Continue button). No tool
    /// can clear it, so a model can never undo the user's takeover.
    paused: bool = false,

    /// Admit one act at `now_ms`, or return why not. Counts the step.
    pub fn admit(self: *Session, lim: Limits, now_ms: u64, last_real_input_ms: ?u64) ?[]const u8 {
        if (self.paused) return "paused: the user took over the keyboard or mouse; only the user's Continue resumes";
        if (self.steps >= lim.max_steps) return "stopped: the step limit for this session is reached";
        if (self.started_ms) |s| {
            if (now_ms -| s >= @as(u64, lim.session_timeout_s) * 1000) return "stopped: the session time limit is reached";
        }
        if (last_real_input_ms) |ts| {
            if (now_ms -| ts < lim.idle_ms) return "waiting: the user is using the keyboard or mouse; retry when they stop";
        }
        if (self.started_ms == null) self.started_ms = now_ms;
        self.steps += 1;
        return null;
    }

    /// Between injected groups: real input since the act began pauses the
    /// session; an overrun of the act's time budget (`actBudgetMs`) stops it.
    pub fn during(self: *Session, act_start_ms: u64, now_ms: u64, last_real_input_ms: ?u64, budget_ms: u64) ?[]const u8 {
        if (last_real_input_ms) |ts| if (ts >= act_start_ms) {
            self.paused = true;
            return "paused: the user used the keyboard or mouse, so the action stopped part-way";
        };
        if (now_ms -| act_start_ms > budget_ms) return "stopped: the action took longer than the step timeout";
        return null;
    }
};

/// Pause between typed UTF-16 units, after the target's UI thread has
/// drained its queue (main.zig `syncTarget`). Win11 Notepad reads a queued
/// VK_PACKET keystroke's character late, so when the next packet is already
/// queued it types that one instead: "hello from" -> "hello ooom", "z3" ->
/// "33", a surrogate pair sent in one SendInput -> two U+FFFD (measured on
/// 245; zmcp-computer's 64-event bursts are garbled the same way). It is
/// slowest right after a space (autocorrect). One unit per SendInput with
/// the target sync and a 5 ms pause still garbled a character now and then
/// ("line2" -> "iine2"); 30 ms or more between units was intact in every
/// run. So: one unit per SendInput, wait for the target, then 30 ms.
/// (4096 characters take about 2.5 minutes; set_value is the fast path.)
pub const type_pace_ms: u32 = 30;

/// The time an act may take: the step timeout, plus for each typed unit the
/// pace and slack for the target sync and the per-unit checks.
pub fn actBudgetMs(lim: Limits, groups: usize) u64 {
    return @as(u64, lim.step_timeout_ms) + @as(u64, groups) * (type_pace_ms + 45);
}

/// The end of the group of INPUTs starting at `start`: one keystroke (its
/// down and up events), so each UTF-16 unit of typed text is its own
/// SendInput. Surrogate halves are separate groups on purpose (see
/// `type_pace_ms`).
pub fn keystrokeGroupEnd(list: []const shared.win32.INPUT, start: usize) usize {
    var i = start + 1;
    while (i < list.len) : (i += 1) {
        const in = list[i];
        if (in.type != shared.win32.INPUT_KEYBOARD) return i;
        if (in.u.ki.dwFlags & shared.win32.KEYEVENTF_KEYUP == 0) return i;
    }
    return list.len;
}

pub fn countGroups(list: []const shared.win32.INPUT) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < list.len) : (n += 1) i = keystrokeGroupEnd(list, i);
    return n;
}


/// Roles whose name is checked for payment words.
fn isPressable(role: []const u8) bool {
    for ([_][]const u8{ "button", "splitbutton", "hyperlink", "menuitem" }) |r| if (std.mem.eql(u8, role, r)) return true;
    return false;
}

fn wordStartsWith(name: []const u8, prefix: []const u8) bool {
    var i: usize = 0;
    while (i + prefix.len <= name.len) : (i += 1) {
        const at_word = i == 0 or !std.ascii.isAlphanumeric(name[i - 1]);
        if (at_word and std.ascii.eqlIgnoreCase(name[i .. i + prefix.len], prefix)) return true;
    }
    return false;
}

/// A name that looks like it spends money: a word starting with `pay`,
/// `purchase`, `checkout` or `transfer`, or the phrases `buy now`,
/// `check out`, `send money`, `place order`. ("Display" and "Replay" do not match.)
pub fn isPaymentName(name: []const u8) bool {
    for ([_][]const u8{ "pay", "purchase", "checkout", "transfer", "buy now", "check out", "send money", "place order" }) |p| {
        if (wordStartsWith(name, p)) return true;
    }
    return false;
}

/// T3 unless the host passed --allow-payments.
pub fn refusesPayment(role: []const u8, name: []const u8, allow_payments: bool) bool {
    return !allow_payments and isPressable(role) and isPaymentName(name);
}

/// rect is [x, y, w, h].
pub fn rectContains(rect: [4]i32, x: i32, y: i32) bool {
    const px: i64 = x;
    const py: i64 = y;
    return rect[2] > 0 and rect[3] > 0 and px >= rect[0] and py >= rect[1] and
        px < @as(i64, rect[0]) + rect[2] and py < @as(i64, rect[1]) + rect[3];
}

/// desktop_type/desktop_key only send input when the target window is the
/// foreground window (compared at the top-level root).
pub fn isForeground(target_hwnd: usize, foreground_root: ?usize) bool {
    const fg = foreground_root orelse return false;
    return target_hwnd != 0 and fg == target_hwnd;
}

/// Longest text desktop_type / set_value will send (code points).
pub const max_act_text_chars: usize = 4096;

/// Why `text` may not be typed or set, or null. Control characters (C0, DEL,
/// C1) are refused so a line break can't act as Enter: Enter goes through
/// desktop_key, where the host can tier it.
pub fn textRefusal(text: []const u8) ?[]const u8 {
    if (!std.unicode.utf8ValidateSlice(text)) return "text is not valid UTF-8";
    shared.guard.checkTextLen(text, max_act_text_chars) catch return "text is longer than 4096 characters";
    var it = (std.unicode.Utf8View.init(text) catch return "text is not valid UTF-8").iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x20 or (cp >= 0x7F and cp <= 0x9F) or cp == 0x2028 or cp == 0x2029)
            return "text has a control character (line break, tab, ...); use desktop_key for enter/tab";
        if ((cp >= 0x202A and cp <= 0x202E) or (cp >= 0x2066 and cp <= 0x2069))
            return "text has a bidi control character (U+202A-202E, U+2066-2069)";
    }
    return null;
}

/// Roles a typed character would activate (space/enter press them).
pub fn typeRefusedRole(role: []const u8) bool {
    for ([_][]const u8{ "button", "splitbutton", "hyperlink", "menuitem", "checkbox", "radiobutton", "listitem", "tabitem", "treeitem" }) |r|
        if (std.mem.eql(u8, role, r)) return true;
    return false;
}

/// The only chords desktop_key sends. Everything else is refused, and the
/// strict chord blocklist (keys.strictBlockedInState: any win key,
/// ctrl+alt+*, alt+f4, alt+tab, alt+esc, alt+space, ctrl+esc, ...) is checked
/// again over the keys held at send time.
pub const allowed_chords = [_][]const u8{
    "enter",     "shift+enter", "tab",        "shift+tab", "escape",     "backspace",      "delete",
    "space",     "up",          "down",       "left",      "right",      "home",           "end",
    "pageup",    "pagedown",    "shift+up",   "shift+down", "shift+left", "shift+right",   "shift+home",
    "shift+end", "ctrl+left",   "ctrl+right", "ctrl+home", "ctrl+end",   "ctrl+backspace", "ctrl+delete",
    "ctrl+a",    "ctrl+z",      "ctrl+y",     "ctrl+f",    "f2",         "f3",             "f5",
};

/// Chords still allowed while focus is in a password field (leave it).
pub const password_field_chords = [_][]const u8{ "tab", "shift+tab", "escape" };

fn sameKeys(a: *const keys.KeyState, b: *const keys.KeyState) bool {
    if (a.len != b.len) return false;
    for (a.vks[0..a.len]) |v| if (!b.has(v)) return false;
    return true;
}

/// The canonical allowlist entry `combo` equals (order- and alias-insensitive:
/// "Shift + Tab", "tab+shift" and "shiftleft+tab" all match "shift+tab"),
/// or null when the chord is not allowlisted.
pub fn allowedChord(combo: []const u8, scan: keys.ScanFn, list: []const []const u8) ?[]const u8 {
    const c = keys.parseCombo(combo, scan) catch return null;
    for (c.slice()) |k| if (k.vk == 0) return null; // a Unicode keystroke is not a chord
    const st = keys.comboState(&c);
    if (keys.strictBlockedInState(&st) != null) return null;
    for (list) |entry| {
        const e = keys.parseCombo(entry, scan) catch continue;
        const es = keys.comboState(&e);
        if (sameKeys(&st, &es)) return entry;
    }
    return null;
}

// ── tests ───────────────────────────────────────────────────────────────────

const t = std.testing;

test "no --allow means nothing is allowed" {
    const p = try Policy.fromArgs(t.allocator, &.{});
    defer p.deinit();
    try t.expect(p.isEmpty());
    try t.expect(!p.allows("C:\\Program Files\\Signal\\Signal.exe"));
    try t.expect(!p.allows("signal.exe"));
}

test "allowlist matches full image paths case-insensitively; bare names never match" {
    const p = try Policy.fromArgs(t.allocator, &.{ "--allow", "C:\\Program Files\\Signal\\Signal.exe|c:/windows/system32/notepad.exe" });
    defer p.deinit();
    try t.expectEqual(@as(usize, 2), p.allow.len);
    try t.expect(p.allows("C:\\PROGRAM FILES\\SIGNAL\\SIGNAL.EXE"));
    try t.expect(p.allows("\\\\?\\C:\\Program Files\\Signal\\Signal.exe"));
    try t.expect(p.allows("C:\\Windows\\System32\\notepad.exe"));
    try t.expect(!p.allows("Signal.exe"));
    try t.expect(!p.allows("notepad.exe"));
    try t.expect(!p.allows("C:\\evil\\Signal.exe"));
    try t.expect(!p.allows("D:\\Program Files\\Signal\\Signal.exe"));
    try t.expect(!p.allows("C:\\Program Files\\Signal\\Signal.exe.bat"));
    try t.expect(!p.allows("C:\\Program Files\\Signal\\..\\Signal\\Signal.exe"));
    try t.expect(!p.allows(""));
}

test "bare-name, relative, UNC, dot-segment and wildcard entries are dropped" {
    const p = try Policy.fromArgs(t.allocator, &.{
        "--allow", "signal.exe|notepad.exe",
        "--allow", "Signal\\Signal.exe",
        "--allow", "\\\\server\\share\\x.exe",
        "--allow", "C:\\a\\..\\b.exe|C:\\a\\.\\b.exe|C:\\a\\\\b.exe|C:\\*.exe|C:\\a\\b.exe:ads",
        "--allow", "C:\\ok\\ok.exe",
    });
    defer p.deinit();
    try t.expectEqual(@as(usize, 1), p.allow.len);
    try t.expectEqualStrings("c:\\ok\\ok.exe", p.allow[0]);
    try t.expect(!p.allows("signal.exe"));
}

test "always-refused processes and the UWP frame host are refused even when allowlisted" {
    const p = try Policy.fromArgs(t.allocator, &.{ "--allow", "C:\\Windows\\System32\\consent.exe|C:\\Windows\\System32\\LogonUI.exe|C:\\Windows\\System32\\CredentialUIBroker.exe|C:\\Windows\\System32\\ApplicationFrameHost.exe|C:\\Windows\\System32\\notepad.exe" });
    defer p.deinit();
    try t.expectEqual(@as(usize, 1), p.allow.len);
    try t.expect(!p.allows("C:\\Windows\\System32\\consent.exe"));
    try t.expect(!p.allows("C:\\Windows\\System32\\ApplicationFrameHost.exe"));
    try t.expect(p.allows("C:\\Windows\\System32\\notepad.exe"));
}

test "--resume-event" {
    const p = try Policy.fromArgs(t.allocator, &.{ "--resume-event", "Local\\r1", "--kill-event", "Local\\k1" });
    defer p.deinit();
    try t.expectEqualStrings("Local\\r1", p.resume_event.?);
    const d = try Policy.fromArgs(t.allocator, &.{});
    defer d.deinit();
    try t.expect(d.resume_event == null);
}

test "--kill-event" {
    const p = try Policy.fromArgs(t.allocator, &.{ "--kill-event", "Local\\k1" });
    defer p.deinit();
    try t.expectEqualStrings("Local\\k1", p.kill_event.?);
}

test "kill event default name" {
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("Local\\zmcp-desktop-kill-4242", try defaultKillEventName(&buf, 4242));
}

test "password values are never serialized" {
    var n = Node{ .role = "edit", .name = "Password", .value = "hunter2", .is_password = true };
    const json = try n.toJson(t.allocator);
    defer t.allocator.free(json);
    try t.expect(std.mem.indexOf(u8, json, "hunter2") == null);
    try t.expect(std.mem.indexOf(u8, json, "\"value\"") == null);
    try t.expect(std.mem.indexOf(u8, json, "\"is_password\":true") != null);
    n.is_password = false;
    const json2 = try n.toJson(t.allocator);
    defer t.allocator.free(json2);
    try t.expect(std.mem.indexOf(u8, json2, "\"value\":\"hunter2\"") != null);
}

test "text is serialized like a value: never for a password field, capped, text_pattern only when set" {
    const a = std.testing.allocator;
    var n = Node{ .role = "group", .text = "draft to Alex", .text_pattern = true, .is_password = true };
    const j = try n.toJson(a);
    defer a.free(j);
    try t.expect(std.mem.indexOf(u8, j, "draft to Alex") == null);
    try t.expect(std.mem.indexOf(u8, j, "\"text\"") == null);
    n.is_password = false;
    const k = try n.toJson(a);
    defer a.free(k);
    try t.expect(std.mem.indexOf(u8, k, "\"text\":\"draft to Alex\"") != null);
    try t.expect(std.mem.indexOf(u8, k, "\"text_pattern\":true") != null);
    const long = "x" ** 700;
    const l = try (Node{ .text = long }).toJson(a);
    defer a.free(l);
    try t.expect(std.mem.indexOf(u8, l, "x" ** 501) == null and std.mem.indexOf(u8, l, "x" ** 500) != null);
    try t.expect(std.mem.indexOf(u8, l, "text_pattern") == null);
    try t.expect(std.mem.indexOf(u8, l, "\"text_truncated\":true") != null); // a text over the cap says so
    try t.expect(std.mem.indexOf(u8, k, "text_truncated") == null);
    const m = try (Node{ .text = "short", .text_truncated = true }).toJson(a);
    defer a.free(m);
    try t.expect(std.mem.indexOf(u8, m, "\"text_truncated\":true") != null);
}

test "utf16ScalarCount counts pairs once" {
    try t.expectEqual(@as(usize, 3), utf16ScalarCount(&[_]u16{ 'a', 0xD83D, 0xDE00, 'b' }));
    try t.expectEqual(@as(usize, 2), utf16ScalarCount(&[_]u16{ 0xDC00, 0xD800 }));
    try t.expectEqual(@as(usize, 0), utf16ScalarCount(&[_]u16{}));
}

test "wantsText: focusable edit/group/custom with a TextPattern, never a password field or a document" {
    try t.expect(wantsText(50026, true, false, true)); // contenteditable group
    try t.expect(wantsText(50004, true, false, true)); // edit / RichEdit
    try t.expect(wantsText(50025, true, false, true)); // custom
    try t.expect(!wantsText(50004, true, true, true)); // password
    try t.expect(!wantsText(50030, true, false, true)); // document (RootWebArea)
    try t.expect(!wantsText(50026, false, false, true)); // not focusable
    try t.expect(!wantsText(50026, true, false, false)); // no TextPattern
    try t.expect(!wantsText(50000, true, false, true)); // button
    try t.expect(!wantsText(50029, true, false, true)); // dataitem (a message)
}

test "expected_id: none passes, the same element passes, another or a malformed id refuses" {
    const a = std.testing.allocator;
    const rid = [_]i32{ 42, -7, 3 };
    try std.testing.expect(expectedIdRefusal(a, null, &rid) == null);
    const id = try encodeRuntimeId(a, &rid);
    defer a.free(id);
    try std.testing.expect(expectedIdRefusal(a, id, &rid) == null);
    try std.testing.expect(std.mem.indexOf(u8, expectedIdRefusal(a, id, &[_]i32{ 42, -7, 4 }).?, "expected element") != null);
    try std.testing.expect(std.mem.indexOf(u8, expectedIdRefusal(a, id, &[_]i32{}).?, "expected element") != null);
    try std.testing.expect(std.mem.indexOf(u8, expectedIdRefusal(a, "x1", &rid).?, "not an element id") != null);
}

test "nodes carry automation_id and class_name (capped, omitted when empty) and value_pattern" {
    const a = std.testing.allocator;
    const long = "i" ** 300;
    const j = try (Node{ .id = "r1", .automation_id = long, .class_name = "Button", .value_pattern = true }).toJson(a);
    defer a.free(j);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"class_name\":\"Button\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"value_pattern\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "i" ** 201) == null);
    try std.testing.expect(std.mem.indexOf(u8, j, "i" ** 200) != null);
    const k = try (Node{ .id = "r1" }).toJson(a);
    defer a.free(k);
    try std.testing.expect(std.mem.indexOf(u8, k, "automation_id") == null);
    try std.testing.expect(std.mem.indexOf(u8, k, "class_name") == null);
}

test "runtime ids round-trip" {
    const ids = [_]i32{ 42, 7, 99 };
    const s = try encodeRuntimeId(t.allocator, &ids);
    defer t.allocator.free(s);
    try t.expectEqualStrings("r2a-7-63", s);
    const back = try decodeRuntimeId(t.allocator, s);
    defer t.allocator.free(back);
    try t.expectEqualSlices(i32, &ids, back);

    const neg = [_]i32{ -1, std.math.minInt(i32), 0 };
    const s2 = try encodeRuntimeId(t.allocator, &neg);
    defer t.allocator.free(s2);
    const back2 = try decodeRuntimeId(t.allocator, s2);
    defer t.allocator.free(back2);
    try t.expectEqualSlices(i32, &neg, back2);
}

test "bad element ids are refused" {
    for ([_][]const u8{ "", "r", "x2a", "r2a--1", "r123456789", "rzz", "r2a-" }) |s| {
        try t.expectError(error.BadElementId, decodeRuntimeId(t.allocator, s));
    }
}

test "roles map both ways" {
    try t.expectEqualStrings("button", roleName(50000));
    try t.expectEqualStrings("edit", roleName(50004));
    try t.expectEqualStrings("listitem", roleName(50007));
    try t.expectEqualStrings("document", roleName(50030));
    try t.expectEqualStrings("pane", roleName(50033));
    try t.expectEqualStrings("appbar", roleName(50040));
    try t.expectEqualStrings("unknown", roleName(50041));
    try t.expectEqualStrings("unknown", roleName(12));
    try t.expectEqual(@as(?i32, 50020), roleId("Text"));
    try t.expectEqual(@as(?i32, null), roleId("nope"));
}

test "utf16 conversion caps chars and replaces lone surrogates" {
    const s = [_]u16{ 'a', 0xD83D, 0xDE00, 0xD800, 'b', 0xDC00 };
    const out = try utf16ToUtf8Capped(t.allocator, &s, 100);
    defer t.allocator.free(out);
    try t.expectEqualStrings("a\u{1F600}\u{FFFD}b\u{FFFD}", out);
    try t.expect(std.unicode.utf8ValidateSlice(out));
    const capped = try utf16ToUtf8Capped(t.allocator, &s, 2);
    defer t.allocator.free(capped);
    try t.expectEqualStrings("a\u{1F600}", capped);
}

test "names and values are capped at 500 chars" {
    const long = "é" ** 700;
    var n = Node{ .name = long, .value = long };
    const json = try n.toJson(t.allocator);
    defer t.allocator.free(json);
    try t.expectEqual(@as(usize, 1000), std.mem.count(u8, json, "é"));
}

test "output is bounded and flags truncation" {
    var nodes: [4000]Node = undefined;
    for (&nodes) |*n| n.* = .{ .id = "r2a-1234-5678", .role = "text", .name = "x" ** 200 };
    const out = try writeNodes(t.allocator, .{ .hwnd = 1, .exe = "a.exe", .title = "T", .pid = 1 }, &nodes, false, &.{}, max_output_bytes);
    defer t.allocator.free(out);
    try t.expect(out.len <= max_output_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, out, .{});
    defer parsed.deinit();
    try t.expect(parsed.value.object.get("truncated").?.bool);
    const count = parsed.value.object.get("count").?.integer;
    try t.expectEqual(count, @as(i64, @intCast(parsed.value.object.get("nodes").?.array.items.len)));
    try t.expect(count > 100 and count < 4000);

    const small = try writeNodes(t.allocator, .{ .hwnd = 1, .exe = "a.exe", .title = "T", .pid = 1 }, nodes[0..3], false, &.{}, max_output_bytes);
    defer t.allocator.free(small);
    var p2 = try std.json.parseFromSlice(std.json.Value, t.allocator, small, .{});
    defer p2.deinit();
    try t.expect(!p2.value.object.get("truncated").?.bool);
    try t.expectEqual(@as(i64, 3), p2.value.object.get("count").?.integer);
}

test "containsIgnoreCase" {
    try t.expect(containsIgnoreCase("Send message", "SEND"));
    try t.expect(containsIgnoreCase("abc", ""));
    try t.expect(!containsIgnoreCase("ab", "abc"));
}

test "refuses payment buttons" {
    for ([_][]const u8{ "Pay", "Pay now", "PayPal", "Payment", "Purchase", "Buy now", "BUY NOW", "Checkout", "Check out", "Send money", "Transfer", "Transfer funds", "Place order" }) |n| {
        try t.expect(refusesPayment("button", n, false));
    }
    try t.expect(refusesPayment("hyperlink", "Buy now", false));
    for ([_][]const u8{ "Display", "Replay", "Send", "Buy", "Search", "Settings", "Repay later" }) |n| {
        try t.expect(!refusesPayment("button", n, false));
    }
    // Not a button: text that mentions paying is fine to read and focus.
    try t.expect(!refusesPayment("text", "Pay now", false));
    try t.expect(!refusesPayment("button", "Pay now", true));
}

test "refuses dangerous chords" {
    for ([_][]const u8{ "win+r", "alt+f4", "ctrl+alt+del", "ctrl+alt+delete", "alt+tab", "win", "lwin", "rwin+d", "super+l", "ctrl+esc", "alt+space", "alt+esc", "ctrl+shift+esc", "ctrl+w", "ctrl+c", "ctrl+v", "alt+e", "f11", "a", "x", "ctrl+alt+a", "€" }) |s| {
        try t.expect(allowedChord(s, keys.fakeUsScan, &allowed_chords) == null);
    }
    for ([_]struct { []const u8, []const u8 }{
        .{ "enter", "enter" },         .{ "Return", "enter" },            .{ "ctrl+a", "ctrl+a" }, .{ "Control + A", "ctrl+a" },
        .{ "tab+shift", "shift+tab" }, .{ "shiftleft+tab", "shift+tab" }, .{ "esc", "escape" },  .{ "pgdn", "pagedown" },
    }) |c| {
        try t.expectEqualStrings(c[1], allowedChord(c[0], keys.fakeUsScan, &allowed_chords).?);
    }
    try t.expect(allowedChord("enter", keys.fakeUsScan, &password_field_chords) == null);
    try t.expect(allowedChord("shift+tab", keys.fakeUsScan, &password_field_chords) != null);
}

test "click must be inside the window rect" {
    const r = [4]i32{ 100, 200, 300, 400 }; // x 100..399, y 200..599
    try t.expect(rectContains(r, 100, 200));
    try t.expect(rectContains(r, 399, 599));
    try t.expect(!rectContains(r, 400, 300));
    try t.expect(!rectContains(r, 99, 300));
    try t.expect(!rectContains(r, 150, 600));
    try t.expect(!rectContains(r, 150, 199));
    try t.expect(!rectContains(.{ 0, 0, 0, 10 }, 0, 0));
    // No i32 overflow at the edge.
    try t.expect(rectContains(.{ 2147483600, 0, 100, 100 }, 2147483647, 5));
}

test "type refuses when the target window is not the foreground" {
    try t.expect(isForeground(0x1234, 0x1234));
    try t.expect(!isForeground(0x1234, 0x9999));
    try t.expect(!isForeground(0x1234, null));
    try t.expect(!isForeground(0, 0));
}

test "typed text: no control characters, capped" {
    try t.expect(textRefusal("hello é 😀") == null);
    try t.expect(textRefusal("hi\n") != null);
    try t.expect(textRefusal("a\rb") != null);
    try t.expect(textRefusal("a\tb") != null);
    try t.expect(textRefusal("a\x7fb") != null);
    try t.expect(textRefusal("a\u{85}b") != null);
    try t.expect(textRefusal("\xff") != null);
    try t.expect(textRefusal("a\u{2028}b") != null); // line separator
    try t.expect(textRefusal("a\u{2029}b") != null); // paragraph separator
    for ([_][]const u8{ "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}" }) |c| {
        try t.expect(textRefusal(c) != null);
    }
    try t.expect(textRefusal("\u{2027}\u{202F}\u{2065}\u{206A} \u{5D0}\u{5D1}") == null); // neighbours and Hebrew are fine
    try t.expect(textRefusal("x" ** 4096) == null);
    try t.expect(textRefusal("x" ** 4097) != null);
}

test "limits: steps, session time, idle wait, pause latch" {
    const lim: Limits = .{ .max_steps = 2, .session_timeout_s = 10, .idle_ms = 500, .step_timeout_ms = 1000 };
    var s: Session = .{};
    try t.expect(s.admit(lim, 1000, 100) == null); // input 900 ms ago
    try t.expect(s.admit(lim, 1100, 900) != null); // input 200 ms ago: wait, not counted
    try t.expectEqual(@as(u32, 1), s.steps);
    try t.expect(s.admit(lim, 2000, null) == null);
    try t.expect(std.mem.startsWith(u8, s.admit(lim, 2100, null).?, "stopped: the step limit"));

    var s2: Session = .{};
    try t.expect(s2.admit(lim, 0, null) == null);
    try t.expect(std.mem.startsWith(u8, s2.admit(lim, 10_000, null).?, "stopped: the session time"));

    var s3: Session = .{};
    try t.expect(s3.during(5000, 5100, 4999, 1000) == null); // input before the act began
    try t.expect(s3.during(5000, 6100, null, 1000) != null); // over the budget
    try t.expect(s3.during(5000, 6100, null, 2000) == null); // a longer typing budget
    try t.expect(!s3.paused);
    try t.expect(s3.during(5000, 5200, 5150, 1000) != null); // real input mid-act
    try t.expect(s3.paused);
    try t.expect(std.mem.startsWith(u8, s3.admit(lim, 9000, null).?, "paused"));
}

test "typing is paced one keystroke (UTF-16 unit) per group; the budget grows with the text" {
    var list: std.ArrayList(shared.win32.INPUT) = .empty;
    defer list.deinit(t.allocator);
    try shared.input.appendText(&list, t.allocator, "a\u{e9}\u{1F600}b");
    // a, é: 2 events each; the emoji: 2 + 2 (its surrogate halves); b: 2.
    try t.expectEqual(@as(usize, 10), list.items.len);
    for ([_]usize{ 0, 2, 4, 6, 8 }) |s| try t.expectEqual(s + 2, keystrokeGroupEnd(list.items, s));
    try t.expectEqual(@as(usize, 5), countGroups(list.items));
    const lim: Limits = .{ .step_timeout_ms = 10_000 };
    try t.expectEqual(@as(u64, 10_000 + 5 * (type_pace_ms + 45)), actBudgetMs(lim, 5));
    // 4096 characters (up to 8192 units) always fit the budget at the pace.
    try t.expect(actBudgetMs(lim, 2 * max_act_text_chars) > 2 * max_act_text_chars * @as(u64, type_pace_ms) + 10_000);
}

test "limit flags parse and clamp; payments flag" {
    const p = try Policy.fromArgs(t.allocator, &.{ "--max-steps", "0", "--step-timeout-ms", "5", "--session-timeout-s", "60", "--idle-ms", "99999", "--allow-payments", "--allow", "C:\\a\\b.exe" });
    defer p.deinit();
    try t.expectEqual(@as(u32, 1), p.limits.max_steps);
    try t.expectEqual(@as(u32, 100), p.limits.step_timeout_ms);
    try t.expectEqual(@as(u32, 60), p.limits.session_timeout_s);
    try t.expectEqual(@as(u32, 10_000), p.limits.idle_ms);
    try t.expect(p.allow_payments);
    try t.expectEqual(@as(usize, 1), p.allow.len);
    const d = try Policy.fromArgs(t.allocator, &.{});
    defer d.deinit();
    try t.expect(!d.allow_payments);
    try t.expectEqual(@as(u32, 100), d.limits.max_steps);
}

test "actions parse" {
    try t.expectEqual(Action.set_value, parseAction("set_value").?);
    try t.expectEqual(Action.scroll_into_view, parseAction("scroll_into_view").?);
    try t.expect(parseAction("click") == null);
    try t.expect(parseAction("Invoke") == null);
}
