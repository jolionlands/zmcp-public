//! Clipboard, ShellExecute launches, time, file output.

const std = @import("std");
const builtin = @import("builtin");
const w = @import("win32.zig");

pub var disabled: bool = false;

pub const SysError = error{ SystemActionsDisabled, ClipboardBusy, ClipboardEmpty, ClipboardFailed, LaunchFailed, OutOfMemory, InvalidUtf8, InvalidWtf8 };

fn guard() SysError!void {
    if (builtin.is_test or disabled) return error.SystemActionsDisabled;
}

// ── clipboard ───────────────────────────────────────────────────────────────

fn openClipboard() SysError!void {
    var tries: u32 = 0;
    while (tries < 10) : (tries += 1) {
        if (w.ok(w.OpenClipboard(null))) return;
        w.sleepMs(20);
    }
    return error.ClipboardBusy;
}

pub fn readClipboard(allocator: std.mem.Allocator) SysError![]u8 {
    try guard();
    try openClipboard();
    defer _ = w.CloseClipboard();
    const h = w.GetClipboardData(w.CF_UNICODETEXT) orelse return error.ClipboardEmpty;
    const p = w.GlobalLock(h) orelse return error.ClipboardFailed;
    defer _ = w.GlobalUnlock(h);
    const units: [*]const u16 = @ptrCast(@alignCast(p));
    const max = w.GlobalSize(h) / 2;
    var n: usize = 0;
    while (n < max and units[n] != 0) n += 1;
    return w.fromW(allocator, units[0..n]) catch error.OutOfMemory;
}

pub fn writeClipboard(allocator: std.mem.Allocator, text: []const u8) SysError!void {
    try guard();
    const wide = w.toW(allocator, text) catch return error.InvalidUtf8;
    defer allocator.free(wide);
    const bytes = (wide.len + 1) * 2;
    const h = w.GlobalAlloc(w.GMEM_MOVEABLE, bytes) orelse return error.ClipboardFailed;
    var owned = true;
    defer if (owned) {
        _ = w.GlobalFree(h);
    };
    {
        const p = w.GlobalLock(h) orelse return error.ClipboardFailed;
        const dst: [*]u16 = @ptrCast(@alignCast(p));
        @memcpy(dst[0 .. wide.len + 1], wide[0 .. wide.len + 1]);
        _ = w.GlobalUnlock(h);
    }
    try openClipboard();
    defer _ = w.CloseClipboard();
    _ = w.EmptyClipboard();
    if (w.SetClipboardData(w.CF_UNICODETEXT, h) == null) return error.ClipboardFailed;
    owned = false; // the system owns it now
}

// ── launching ───────────────────────────────────────────────────────────────

/// ShellExecuteW("open", file, params). Returns an error when the shell
/// reports failure (HINSTANCE <= 32).
pub fn shellOpen(allocator: std.mem.Allocator, file: []const u8, params: ?[]const u8) SysError!void {
    try guard();
    const wfile = w.toW(allocator, file) catch return error.InvalidUtf8;
    defer allocator.free(wfile);
    const wparams: ?[:0]u16 = if (params) |p| (w.toW(allocator, p) catch return error.InvalidUtf8) else null;
    defer if (wparams) |p| allocator.free(p);
    const verb = std.unicode.utf8ToUtf16LeStringLiteral("open");
    const r = w.ShellExecuteW(null, verb, wfile.ptr, if (wparams) |p| p.ptr else null, null, w.SW_SHOWNORMAL);
    if (r <= 32) return error.LaunchFailed;
}

pub fn isHttpUrl(url: []const u8) bool {
    const lower_ok = std.ascii.startsWithIgnoreCase(url, "http://") or std.ascii.startsWithIgnoreCase(url, "https://");
    if (!lower_ok) return false;
    for (url) |c| if (c < 0x20 or c == '"') return false;
    return true;
}

/// Drive-absolute Windows path ("C:\..."). UNC, "\\?\" and "\\.\" forms are
/// deliberately not absolute here; see `openFileRefusal`.
pub fn isAbsolutePath(p: []const u8) bool {
    return p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and (p[2] == '\\' or p[2] == '/');
}

/// open_file ALLOWLIST: Nava's T0 set (documents, images, media and
/// archives that open in a viewer and never execute). csv and xml are
/// omitted because Nava asks before opening them (T1: formulas, stylesheets
/// and script). Everything else, including folders, is refused.
pub const allowed_ext = [_][]const u8{
    "pdf",  "txt",  "md",   "rtf",  "json", "log",  "ini", "toml", "yaml", "yml", "docx", "xlsx", "pptx",
    "odt",  "ods",  "odp",  "epub", "png",  "jpg",  "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic",
    "ico",  "mp3",  "wav",  "flac", "ogg",  "m4a",  "aac", "mp4",  "mkv",  "webm", "mov", "avi",  "zip",
    "7z",
};

const device_names = [_][]const u8{ "con", "prn", "aux", "nul", "conin$", "conout$", "clock$" };

/// Reserved DOS device names, which Windows matches on the part before the
/// first '.' with trailing spaces ignored ("nul.txt", "COM1 .log").
fn isDeviceName(component: []const u8) bool {
    const stem_end = std.mem.indexOfScalar(u8, component, '.') orelse component.len;
    const stem = std.mem.trimEnd(u8, component[0..stem_end], " ");
    for (device_names) |d| if (std.ascii.eqlIgnoreCase(stem, d)) return true;
    const com_lpt = stem.len >= 4 and (std.ascii.startsWithIgnoreCase(stem, "com") or std.ascii.startsWithIgnoreCase(stem, "lpt"));
    if (com_lpt and stem.len == 4 and stem[3] >= '0' and stem[3] <= '9') return true;
    // COM¹ COM² COM³ (superscript digits, U+00B9/U+00B2/U+00B3) are devices too.
    if (com_lpt and stem.len == 5 and stem[3] == 0xC2 and (stem[4] == 0xB9 or stem[4] == 0xB2 or stem[4] == 0xB3)) return true;
    return false;
}

/// Why open_file must not open `path`, or null when it may.
pub fn openFileRefusal(path: []const u8) ?[]const u8 {
    if (path.len == 0) return "path is empty";
    if (path[0] == '\\' or path[0] == '/') return "UNC, \\\\?\\ and device paths are not allowed; use a drive path like C:\\...";
    if (!isAbsolutePath(path)) return "path must be absolute (C:\\...)";
    for (path) |c| if (c < 0x20 or c == '"' or c == '<' or c == '>' or c == '|' or c == '*' or c == '?') return "path contains an illegal character";
    if (std.mem.indexOfScalarPos(u8, path, 2, ':') != null) return "alternate data streams (':' after the drive) are not allowed";
    var it = std.mem.tokenizeAny(u8, path[3..], "\\/");
    var last: []const u8 = "";
    while (it.next()) |comp| {
        if (isDeviceName(comp)) return "device names (CON, NUL, COM1, ...) are not allowed";
        last = comp;
    }
    // Windows strips trailing dots and spaces: "evil.bat. " opens evil.bat.
    const name = std.mem.trimEnd(u8, last, ". ");
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return not_allowed;
    const ext = name[dot + 1 ..];
    for (allowed_ext) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return null;
    return not_allowed;
}

// ── resolving the real target (8.3 names, junctions, symlinks) ─────────────

const FILE_READ_ATTRIBUTES: u32 = 0x80;
const FILE_SHARE_ALL: u32 = 0x7;
const OPEN_EXISTING: u32 = 3;
const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x02000000;
const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x00200000;
const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
const FileAttributeTagInfo: c_int = 9;
const FILE_NAME_NORMALIZED_VOLUME_DOS: u32 = 0;

const FileAttributeTagInformation = extern struct { attributes: u32, reparse_tag: u32 };

extern "kernel32" fn GetFileInformationByHandleEx(h: w.HANDLE, class: c_int, info: *anyopaque, size: u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetFinalPathNameByHandleW(h: w.HANDLE, buf: [*]u16, len: u32, flags: u32) callconv(.winapi) u32;

pub const Resolved = union(enum) {
    /// Final, long-name, drive-letter path to hand to ShellExecute.
    ok: []u8,
    refused: []const u8,
};

/// Open `path` without following a reparse point in its last component,
/// refuse reparse points and directories, and resolve the final path with
/// GetFinalPathNameByHandleW (long names: EVILTH~1.APP becomes
/// evilthing.appxbundle; intermediate junctions are resolved). A final path
/// that is UNC or a device path is refused; otherwise the allowlist and
/// the static checks run again on the FINAL path.
pub fn resolveForOpen(allocator: std.mem.Allocator, path: []const u8) !Resolved {
    if (openFileRefusal(path)) |why| {
        // A short (8.3) or odd given name may still be fine once resolved,
        // but the structural checks (UNC, streams, devices) are final.
        if (!std.mem.eql(u8, why, not_allowed)) return .{ .refused = why };
    }
    const wp = try w.toW(allocator, path);
    defer allocator.free(wp);
    const h = w.CreateFileW(wp.ptr, FILE_READ_ATTRIBUTES, FILE_SHARE_ALL, null, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, null);
    if (@intFromPtr(h) == std.math.maxInt(usize)) return .{ .refused = "the file does not exist or cannot be opened" };
    defer _ = w.CloseHandle(h);

    var tag: FileAttributeTagInformation = undefined;
    if (!w.ok(GetFileInformationByHandleEx(h, FileAttributeTagInfo, &tag, @sizeOf(FileAttributeTagInformation))))
        return .{ .refused = "cannot read the file's attributes" };
    if (tag.attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0) return .{ .refused = "reparse points (symlinks, junctions, cloud placeholders) are refused" };
    if (tag.attributes & w.FILE_ATTRIBUTE_DIRECTORY != 0) return .{ .refused = not_allowed };

    var buf: [4096]u16 = undefined;
    const n = GetFinalPathNameByHandleW(h, &buf, buf.len, FILE_NAME_NORMALIZED_VOLUME_DOS);
    if (n == 0 or n >= buf.len) return .{ .refused = "cannot resolve the file's final path" };
    const final_w = buf[0..n];
    const final = try w.fromW(allocator, final_w);
    errdefer allocator.free(final);
    const dos = finalToDosPath(final) orelse {
        allocator.free(final);
        return .{ .refused = "the file resolves to a UNC or device path" };
    };
    if (openFileRefusal(dos)) |why| {
        allocator.free(final);
        return .{ .refused = why };
    }
    const out = try allocator.dupe(u8, dos);
    allocator.free(final);
    return .{ .ok = out };
}

/// "\\?\C:\x" → "C:\x"; UNC ("\\?\UNC\...") and anything that is not a
/// drive-letter path (volume GUIDs, devices) → null.
pub fn finalToDosPath(final: []const u8) ?[]const u8 {
    const p = if (std.mem.startsWith(u8, final, "\\\\?\\")) final[4..] else final;
    if (std.ascii.startsWithIgnoreCase(p, "UNC\\")) return null;
    if (!isAbsolutePath(p)) return null;
    return p;
}

const not_allowed ="only document, image and media types are opened (pdf, txt, docx, png, mp4, ...); programs, scripts, shortcuts, folders and other types are refused";

pub fn pathExists(allocator: std.mem.Allocator, p: []const u8) bool {
    const wp = w.toW(allocator, p) catch return false;
    defer allocator.free(wp);
    return w.GetFileAttributesW(wp.ptr) != w.INVALID_FILE_ATTRIBUTES;
}

pub fn isDirectory(allocator: std.mem.Allocator, p: []const u8) bool {
    const wp = w.toW(allocator, p) catch return false;
    defer allocator.free(wp);
    const a = w.GetFileAttributesW(wp.ptr);
    return a != w.INVALID_FILE_ATTRIBUTES and a & w.FILE_ATTRIBUTE_DIRECTORY != 0;
}

/// clawdcursor's Windows app aliases (src/core/router/aliases.ts).
pub const AppAlias = struct {
    keys: []const []const u8,
    process_names: []const []const u8,
    executable: ?[]const u8 = null,
    uwp_id: ?[]const u8 = null,
    always_new: bool = false,
};

pub const app_aliases = [_]AppAlias{
    .{ .keys = &.{ "paint", "mspaint" }, .process_names = &.{"mspaint"}, .executable = "mspaint.exe", .always_new = true },
    .{ .keys = &.{"notepad"}, .process_names = &.{ "Notepad", "notepad" }, .executable = "notepad.exe", .uwp_id = "Microsoft.WindowsNotepad_8wekyb3d8bbwe!App", .always_new = true },
    .{ .keys = &.{ "calculator", "calc" }, .process_names = &.{ "CalculatorApp", "Calculator", "calc" }, .uwp_id = "Microsoft.WindowsCalculator_8wekyb3d8bbwe!App" },
    .{ .keys = &.{ "chrome", "google chrome" }, .process_names = &.{"chrome"}, .executable = "chrome.exe" },
    .{ .keys = &.{"firefox"}, .process_names = &.{"firefox"}, .executable = "firefox.exe" },
    .{ .keys = &.{ "edge", "microsoft edge", "msedge" }, .process_names = &.{"msedge"}, .executable = "msedge.exe" },
    .{ .keys = &.{ "outlook", "microsoft outlook" }, .process_names = &.{ "OUTLOOK", "olk" }, .executable = "outlook.exe" },
    .{ .keys = &.{"word"}, .process_names = &.{"WINWORD"}, .executable = "winword.exe" },
    .{ .keys = &.{"excel"}, .process_names = &.{"EXCEL"}, .executable = "excel.exe" },
    .{ .keys = &.{ "explorer", "file explorer" }, .process_names = &.{"explorer"}, .executable = "explorer.exe", .always_new = true },
    .{ .keys = &.{"cmd"}, .process_names = &.{"cmd"}, .executable = "cmd.exe", .always_new = true },
    .{ .keys = &.{"terminal"}, .process_names = &.{ "WindowsTerminal", "cmd" }, .executable = "wt.exe" },
    .{ .keys = &.{"powershell"}, .process_names = &.{ "powershell", "pwsh" }, .executable = "powershell.exe", .always_new = true },
    .{ .keys = &.{ "vscode", "code" }, .process_names = &.{"Code"}, .executable = "code" },
    .{ .keys = &.{"cursor"}, .process_names = &.{"Cursor"}, .executable = "cursor" },
    .{ .keys = &.{"wezterm"}, .process_names = &.{ "wezterm-gui", "WezTerm" }, .executable = "wezterm-gui.exe" },
    .{ .keys = &.{"settings"}, .process_names = &.{"SystemSettings"}, .executable = "ms-settings:" },
    .{ .keys = &.{"task manager"}, .process_names = &.{"Taskmgr"}, .executable = "taskmgr.exe" },
    .{ .keys = &.{"slack"}, .process_names = &.{"slack"} },
    .{ .keys = &.{"teams"}, .process_names = &.{ "ms-teams", "Teams" }, .executable = "msteams:" },
    .{ .keys = &.{"discord"}, .process_names = &.{"Discord"} },
    .{ .keys = &.{"spotify"}, .process_names = &.{"Spotify"}, .executable = "spotify:" },
    .{ .keys = &.{"figma"}, .process_names = &.{"Figma"} },
};

pub fn resolveAlias(name: []const u8) ?AppAlias {
    const trimmed = std.mem.trim(u8, name, " \t");
    for (app_aliases) |a| {
        for (a.keys) |k| if (std.ascii.eqlIgnoreCase(k, trimmed)) return a;
    }
    return null;
}

/// Reject names that could smuggle arguments or shell syntax (same rule as
/// clawdcursor's launchApp: control chars, backticks, `$`).
pub fn isSafeAppName(name: []const u8) bool {
    if (name.len == 0 or name.len > 260) return false;
    for (name) |c| if (c < 0x20 or c == '`' or c == '$' or c == '"') return false;
    return true;
}

pub fn isValidUwpId(id: []const u8) bool {
    const bang = std.mem.indexOfScalar(u8, id, '!') orelse return false;
    if (bang == 0 or bang == id.len - 1) return false;
    for (id, 0..) |c, i| {
        if (i == bang) continue;
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return false;
    }
    return true;
}

// ── time / files ────────────────────────────────────────────────────────────

pub fn nowMs() u64 {
    return w.GetTickCount64();
}

/// Known Downloads folder, or COMPUTER_CONTROL_MCP_SCREENSHOT_DIR when it
/// names an existing directory (computer_control's override).
pub fn screenshotDir(allocator: std.mem.Allocator) ![]u8 {
    if (try w.getEnv(allocator, "COMPUTER_CONTROL_MCP_SCREENSHOT_DIR")) |d| {
        if (isDirectory(allocator, d)) return d;
        allocator.free(d);
    }
    var p: ?[*:0]u16 = null;
    if (w.SHGetKnownFolderPath(&w.FOLDERID_Downloads, 0, null, &p) != 0 or p == null) return error.NoDownloadsFolder;
    defer w.CoTaskMemFree(p);
    return w.fromW(allocator, std.mem.span(p.?));
}

pub fn writeFile(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    if (builtin.is_test) return error.SystemActionsDisabled;
    const wp = try w.toW(allocator, path);
    defer allocator.free(wp);
    const h = w.CreateFileW(wp.ptr, w.GENERIC_WRITE, 0, null, w.CREATE_ALWAYS, w.FILE_ATTRIBUTE_NORMAL, null);
    if (@intFromPtr(h) == std.math.maxInt(usize)) return error.CreateFileFailed;
    defer _ = w.CloseHandle(h);
    var off: usize = 0;
    while (off < bytes.len) {
        const n: u32 = @intCast(@min(bytes.len - off, 1 << 30));
        var wrote: u32 = 0;
        if (!w.ok(w.WriteFile(h, bytes[off..].ptr, n, &wrote, null)) or wrote == 0) return error.WriteFailed;
        off += wrote;
    }
}

const t = std.testing;

test "url, path and app-name validation" {
    try t.expect(isHttpUrl("https://example.com/a?b=c"));
    try t.expect(isHttpUrl("HTTP://x"));
    try t.expect(!isHttpUrl("file:///c:/windows"));
    try t.expect(!isHttpUrl("javascript:alert(1)"));
    try t.expect(!isHttpUrl("https://x\n.com"));
    try t.expect(isAbsolutePath("C:\\Users\\x.txt"));
    try t.expect(isAbsolutePath("d:/x"));
    try t.expect(!isAbsolutePath("\\\\server\\share\\f"));
    try t.expect(!isAbsolutePath("relative\\x"));
    try t.expect(isSafeAppName("notepad"));
    try t.expect(!isSafeAppName("calc$(evil)"));
    try t.expect(!isSafeAppName("a\"b"));
    try t.expect(isValidUwpId("Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"));
    try t.expect(!isValidUwpId("bad id!App"));
    try t.expect(!isValidUwpId("NoBang"));
}

test "aliases resolve case-insensitively" {
    try t.expectEqualStrings("mspaint.exe", resolveAlias("Paint").?.executable.?);
    try t.expect(resolveAlias("Calculator").?.uwp_id != null);
    try t.expect(resolveAlias("nonexistent app") == null);
}

test "clipboard and launch are refused inside tests" {
    try t.expectError(error.SystemActionsDisabled, readClipboard(t.allocator));
    try t.expectError(error.SystemActionsDisabled, writeClipboard(t.allocator, "x"));
    try t.expectError(error.SystemActionsDisabled, shellOpen(t.allocator, "notepad.exe", null));
}

test "open_file refuses programs, scripts, UNC, device and stream paths" {
    const refused = [_][]const u8{
        "C:\\x\\setup.exe",           "C:\\x\\run.BAT",         "C:\\x\\a.cmd",          "C:\\x\\s.ps1",
        "C:\\x\\x.vbs",               "C:\\x\\x.js",            "C:\\x\\x.msi",          "C:\\x\\t.lnk",
        "C:\\x\\x.scr",               "C:\\x\\x.hta",           "C:\\x\\x.appref-ms",    "C:\\x\\x.Ps1",
        "C:\\x\\evil.bat.",           "C:\\x\\evil.bat. . ",    "C:\\x\\a.url",          "C:\\x\\a.search-ms",
        "\\\\server\\share\\doc.pdf", "\\\\?\\C:\\x\\a.txt",    "\\\\.\\PhysicalDrive0", "//server/share/a.txt",
        "C:\\x\\CON",                 "C:\\x\\nul.txt",         "C:\\x\\COM1.log",       "C:\\x\\lpt9",
        "C:\\x\\a.txt:evil.exe",      "C:\\x\\a.txt:stream",    "relative\\a.txt",       "",
        "C:\\x\\a\"b.txt",            "C:\\x\\COM\u{B9}.txt",   "C:\\x\\nul \\a.txt",    "C:/x/y.EXE",
    };
    for (refused) |p| {
        if (openFileRefusal(p) == null) {
            std.debug.print("not refused: {s}\n", .{p});
            return error.TestExpectedRefusal;
        }
    }
    for ([_][]const u8{ "C:\\Users\\x\\report.pdf", "D:/photos/a.JPG", "C:\\x\\notes.txt", "C:\\x\\console.txt", "C:\\x\\com10.txt", "C:\\x\\a.7z", "C:\\x\\clip.MP4" }) |p| {
        try t.expect(openFileRefusal(p) == null);
    }
    // Allowlist: anything not a known document/media type is refused.
    for ([_][]const u8{ "C:\\x\\folder", "C:\\x\\a.tar.gz", "C:\\x\\a.csv", "C:\\x\\a.xml", "C:\\x\\a.svg", "C:\\x\\a.doc", "C:\\x\\a.html", "C:\\x\\EVILTH~1.APP", "C:\\x\\A3843~1.WEB", "C:\\x\\a.appxbundle", "C:\\x\\a.website" }) |p| {
        try t.expect(openFileRefusal(p) != null);
    }
}

test "finalToDosPath strips \\\\?\\ and refuses UNC / volume paths" {
    try t.expectEqualStrings("C:\\x\\a.pdf", finalToDosPath("\\\\?\\C:\\x\\a.pdf").?);
    try t.expect(finalToDosPath("\\\\?\\UNC\\server\\share\\a.pdf") == null);
    try t.expect(finalToDosPath("\\\\?\\Volume{0000}\\a.pdf") == null);
    try t.expect(finalToDosPath("\\\\.\\PhysicalDrive0") == null);
}

// ── filesystem tests (empty temp files only; nothing is launched) ──────────

extern "kernel32" fn CreateDirectoryW(path: [*:0]const u16, sa: ?*anyopaque) callconv(.winapi) w.BOOL;
extern "kernel32" fn RemoveDirectoryW(path: [*:0]const u16) callconv(.winapi) w.BOOL;
extern "kernel32" fn DeleteFileW(path: [*:0]const u16) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetShortPathNameW(long: [*:0]const u16, short: [*]u16, n: u32) callconv(.winapi) u32;
extern "kernel32" fn DeviceIoControl(h: w.HANDLE, code: u32, in: ?*const anyopaque, in_size: u32, out: ?*anyopaque, out_size: u32, ret: *u32, ov: ?*anyopaque) callconv(.winapi) w.BOOL;

const TestDir = struct {
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    created_files: std.ArrayList([]const u8) = .empty,
    created_dirs: std.ArrayList([]const u8) = .empty,

    fn init() !TestDir {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const tmp = (try w.getEnv(a, "TEMP")) orelse return error.SkipZigTest;
        const root = try std.fmt.allocPrint(a, "{s}\\zmcp-openfile-{d}", .{ tmp, w.GetTickCount64() });
        var td: TestDir = .{ .arena = arena, .root = root };
        try td.mkdir(root);
        return td;
    }

    fn path(self: *TestDir, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "{s}\\{s}", .{ self.root, name });
    }

    fn mkdir(self: *TestDir, p: []const u8) !void {
        const wp = try w.toW(self.arena.allocator(), p);
        if (!w.ok(CreateDirectoryW(wp.ptr, null))) return error.CreateDirFailed;
        try self.created_dirs.append(self.arena.allocator(), p);
    }

    fn touch(self: *TestDir, name: []const u8) ![]const u8 {
        const p = try self.path(name);
        const wp = try w.toW(self.arena.allocator(), p);
        const h = w.CreateFileW(wp.ptr, w.GENERIC_WRITE, 0, null, w.CREATE_ALWAYS, w.FILE_ATTRIBUTE_NORMAL, null);
        if (@intFromPtr(h) == std.math.maxInt(usize)) return error.CreateFileFailed;
        _ = w.CloseHandle(h);
        try self.created_files.append(self.arena.allocator(), p);
        return p;
    }

    fn short(self: *TestDir, long: []const u8) ![]const u8 {
        const wp = try w.toW(self.arena.allocator(), long);
        var buf: [1024]u16 = undefined;
        const n = GetShortPathNameW(wp.ptr, &buf, buf.len);
        if (n == 0 or n >= buf.len) return error.NoShortName;
        return w.fromW(self.arena.allocator(), buf[0..n]);
    }

    /// Mount-point (junction) at `link` whose target is `nt_target`
    /// (an NT path such as "\??\C:\x" or "\??\UNC\server\share").
    fn junction(self: *TestDir, link: []const u8, nt_target: []const u8, print: []const u8) !void {
        try self.mkdir(link);
        const a = self.arena.allocator();
        const sub = try w.toW(a, nt_target);
        const prn = try w.toW(a, print);
        const path_bytes = (sub.len + 1 + prn.len + 1) * 2;
        const data_len = 8 + path_bytes; // 4 x u16 offsets/lengths + PathBuffer
        const buf = try a.alignedAlloc(u8, .of(u32), 8 + data_len);
        @memset(buf, 0);
        std.mem.writeInt(u32, buf[0..4], 0xA0000003, .little); // IO_REPARSE_TAG_MOUNT_POINT
        std.mem.writeInt(u16, buf[4..6], @intCast(data_len), .little);
        std.mem.writeInt(u16, buf[8..10], 0, .little); // SubstituteNameOffset
        std.mem.writeInt(u16, buf[10..12], @intCast(sub.len * 2), .little);
        std.mem.writeInt(u16, buf[12..14], @intCast((sub.len + 1) * 2), .little); // PrintNameOffset
        std.mem.writeInt(u16, buf[14..16], @intCast(prn.len * 2), .little);
        @memcpy(std.mem.sliceAsBytes(@as([]u16, @ptrCast(@alignCast(buf[16..][0 .. sub.len * 2])))), std.mem.sliceAsBytes(sub[0..sub.len]));
        const poff = 16 + (sub.len + 1) * 2;
        @memcpy(buf[poff..][0 .. prn.len * 2], std.mem.sliceAsBytes(prn[0..prn.len]));
        const wl = try w.toW(a, link);
        const h = w.CreateFileW(wl.ptr, w.GENERIC_WRITE, 0, null, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, null);
        if (@intFromPtr(h) == std.math.maxInt(usize)) return error.OpenLinkFailed;
        defer _ = w.CloseHandle(h);
        var ret: u32 = 0;
        if (!w.ok(DeviceIoControl(h, 0x000900A4, buf.ptr, @intCast(buf.len), null, 0, &ret, null))) return error.SetReparseFailed;
    }

    fn deinit(self: *TestDir) void {
        const a = self.arena.allocator();
        for (self.created_files.items) |p| if (w.toW(a, p)) |wp| {
            _ = DeleteFileW(wp.ptr);
        } else |_| {};
        var i = self.created_dirs.items.len;
        while (i > 0) {
            i -= 1;
            if (w.toW(a, self.created_dirs.items[i])) |wp| {
                _ = RemoveDirectoryW(wp.ptr);
            } else |_| {}
        }
        self.arena.deinit();
    }
};

fn expectRefused(r: Resolved) !void {
    switch (r) {
        .refused => {},
        .ok => |p| {
            std.debug.print("unexpectedly allowed: {s}\n", .{p});
            return error.TestExpectedRefusal;
        },
    }
}

test "8.3 short names cannot hide a refused extension" {
    var td = try TestDir.init();
    defer td.deinit();
    const a = td.arena.allocator();
    const evil = try td.touch("evilthing.appxbundle");
    const web = try td.touch("a.website");
    const sneaky = try td.touch("report.pdfexe"); // short name REPORT~1.PDF
    const fine = try td.touch("fine document.pdf");

    const s_sneaky = td.short(sneaky) catch return error.SkipZigTest;
    if (std.mem.eql(u8, s_sneaky, sneaky)) return error.SkipZigTest; // 8.3 names disabled on this volume
    // The given (short) name alone would pass the allowlist...
    try t.expect(std.ascii.endsWithIgnoreCase(s_sneaky, ".PDF"));
    try t.expect(openFileRefusal(s_sneaky) == null);
    // ...but the resolved final name is report.pdfexe.
    try expectRefused(try resolveForOpen(a, s_sneaky));
    try expectRefused(try resolveForOpen(a, try td.short(evil)));
    try expectRefused(try resolveForOpen(a, try td.short(web)));
    try expectRefused(try resolveForOpen(a, evil));

    // A legitimate short name resolves to its long final path and is allowed.
    switch (try resolveForOpen(a, try td.short(fine))) {
        .ok => |p| try t.expect(std.mem.endsWith(u8, p, "\\fine document.pdf")),
        .refused => |why| {
            std.debug.print("refused: {s}\n", .{why});
            return error.TestUnexpectedRefusal;
        },
    }
    try expectRefused(try resolveForOpen(a, td.root)); // folders are not on the allowlist
    try expectRefused(try resolveForOpen(a, try td.path("missing.pdf")));
}

test "junctions: reparse points refused, UNC targets refused, local ones resolved" {
    var td = try TestDir.init();
    defer td.deinit();
    const a = td.arena.allocator();

    // Junction pointing at a UNC path (never reachable; nothing is fetched).
    const unc_link = try td.path("to-unc");
    try td.junction(unc_link, "\\??\\UNC\\127.0.0.1\\zmcp-no-such-share", "\\\\127.0.0.1\\zmcp-no-such-share");
    try expectRefused(try resolveForOpen(a, unc_link));
    const via_unc = try std.fmt.allocPrint(a, "{s}\\doc.pdf", .{unc_link});
    try expectRefused(try resolveForOpen(a, via_unc));

    // Local junction: the link itself is refused; a file behind it resolves
    // to its real location, which is then checked.
    const real = try td.path("real");
    try td.mkdir(real);
    const doc_real = try std.fmt.allocPrint(a, "{s}\\doc.pdf", .{real});
    {
        const wp = try w.toW(a, doc_real);
        const h = w.CreateFileW(wp.ptr, w.GENERIC_WRITE, 0, null, w.CREATE_ALWAYS, w.FILE_ATTRIBUTE_NORMAL, null);
        if (@intFromPtr(h) == std.math.maxInt(usize)) return error.CreateFileFailed;
        _ = w.CloseHandle(h);
        try td.created_files.append(a, doc_real);
    }
    const local_link = try td.path("local");
    const nt_real = try std.fmt.allocPrint(a, "\\??\\{s}", .{real});
    try td.junction(local_link, nt_real, real);
    try expectRefused(try resolveForOpen(a, local_link));
    const via_local = try std.fmt.allocPrint(a, "{s}\\doc.pdf", .{local_link});
    switch (try resolveForOpen(a, via_local)) {
        .ok => |p| try t.expect(std.ascii.endsWithIgnoreCase(p, "\\real\\doc.pdf")),
        .refused => |why| {
            std.debug.print("refused: {s}\n", .{why});
            return error.TestUnexpectedRefusal;
        },
    }
}
