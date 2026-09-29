//! Getting a DevTools endpoint: launch a private Chrome/Edge (default) or
//! attach to one the user already runs (explicit opt-in).
//!
//! Launch mode spawns the browser with an argv array (no shell) and a fresh
//! temp --user-data-dir, headless=new unless ZMCP_BROWSER_HEADED=1, port 0.
//! Chrome's stderr goes to a log file inside the profile (an un-drained pipe
//! would eventually block Chrome), and the endpoint is discovered from that
//! log ("DevTools listening on ws://...") or, equivalently, from the
//! DevToolsActivePort file Chrome writes into the profile.

const std = @import("std");
const builtin = @import("builtin");
const ws = @import("ws.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Config = struct {
    /// ZMCP_BROWSER_BIN
    bin: ?[]const u8 = null,
    /// ZMCP_BROWSER_HEADED=1
    headed: bool = false,
    /// ZMCP_BROWSER_NO_SANDBOX=1 (never default)
    no_sandbox: bool = false,
    window_width: u32 = 1280,
    window_height: u32 = 720,
};

pub const Endpoint = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
};

// ---------------------------------------------------------------- pure helpers

/// argv for launching the browser (all slices owned by `alloc`).
pub fn buildArgv(alloc: Allocator, bin: []const u8, user_data_dir: []const u8, cfg: Config) Allocator.Error![]const []const u8 {
    var a: std.ArrayList([]const u8) = .empty;
    errdefer a.deinit(alloc);
    try a.append(alloc, try alloc.dupe(u8, bin));
    try a.append(alloc, try alloc.dupe(u8, "--remote-debugging-port=0"));
    try a.append(alloc, try std.fmt.allocPrint(alloc, "--user-data-dir={s}", .{user_data_dir}));
    if (!cfg.headed) try a.append(alloc, try alloc.dupe(u8, "--headless=new"));
    try a.append(alloc, try alloc.dupe(u8, "--no-first-run"));
    try a.append(alloc, try alloc.dupe(u8, "--no-default-browser-check"));
    try a.append(alloc, try alloc.dupe(u8, "--disable-dev-shm-usage"));
    try a.append(alloc, try alloc.dupe(u8, "--disable-background-networking"));
    try a.append(alloc, try alloc.dupe(u8, "--disable-component-update"));
    try a.append(alloc, try std.fmt.allocPrint(alloc, "--window-size={d},{d}", .{ cfg.window_width, cfg.window_height }));
    if (cfg.no_sandbox) try a.append(alloc, try alloc.dupe(u8, "--no-sandbox"));
    try a.append(alloc, try alloc.dupe(u8, "about:blank"));
    return a.toOwnedSlice(alloc);
}

pub fn freeArgv(alloc: Allocator, argv: []const []const u8) void {
    for (argv) |s| alloc.free(s);
    alloc.free(argv);
}

/// Extract the ws:// URL from a Chrome stderr line "DevTools listening on ws://...".
pub fn parseDevToolsListening(text: []const u8) ?[]const u8 {
    const marker = "DevTools listening on ";
    const i = std.mem.indexOf(u8, text, marker) orelse return null;
    const rest = text[i + marker.len ..];
    const end = std.mem.indexOfAny(u8, rest, "\r\n") orelse rest.len;
    const u = std.mem.trim(u8, rest[0..end], " ");
    return if (std.mem.startsWith(u8, u, "ws://")) u else null;
}

/// DevToolsActivePort: line 1 = port, line 2 = browser ws path.
pub fn parseActivePort(text: []const u8) ?Endpoint {
    var it = std.mem.splitScalar(u8, text, '\n');
    const l1 = std.mem.trim(u8, it.next() orelse return null, " \r");
    const l2 = std.mem.trim(u8, it.next() orelse return null, " \r");
    const port = std.fmt.parseInt(u16, l1, 10) catch return null;
    if (port == 0 or l2.len == 0 or l2[0] != '/') return null;
    return .{ .host = "127.0.0.1", .port = port, .path = l2 };
}

/// ws://host:port/path -> parts (slices into `url`).
pub fn parseWsUrl(url: []const u8) ?Endpoint {
    if (!std.mem.startsWith(u8, url, "ws://")) return null;
    const rest = url[5..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const hp = rest[0..slash];
    const colon = std.mem.lastIndexOfScalar(u8, hp, ':') orelse return null;
    const port = std.fmt.parseInt(u16, hp[colon + 1 ..], 10) catch return null;
    return .{ .host = hp[0..colon], .port = port, .path = rest[slash..] };
}

/// http://host[:port] -> host and port (default 9222). Only loopback hosts
/// are accepted: a remote debugging port is full control of the browser.
pub fn parseAttachUrl(url: []const u8) error{ BadUrl, NotLoopback }!struct { host: []const u8, port: u16 } {
    if (!std.mem.startsWith(u8, url, "http://")) return error.BadUrl;
    var rest = url[7..];
    if (std.mem.indexOfScalar(u8, rest, '/')) |s| rest = rest[0..s];
    var host = rest;
    var port: u16 = 9222;
    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |c| {
        host = rest[0..c];
        port = std.fmt.parseInt(u16, rest[c + 1 ..], 10) catch return error.BadUrl;
    }
    if (std.mem.eql(u8, host, "localhost")) return .{ .host = "127.0.0.1", .port = port };
    if (std.mem.eql(u8, host, "127.0.0.1")) return .{ .host = "127.0.0.1", .port = port };
    if (std.mem.eql(u8, host, "[::1]")) return .{ .host = "::1", .port = port };
    return error.NotLoopback;
}

/// Pull webSocketDebuggerUrl out of a /json/version body.
pub fn parseVersionJson(arena: Allocator, body: []const u8) ?[]const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return null;
    if (v != .object) return null;
    const w = v.object.get("webSocketDebuggerUrl") orelse return null;
    return if (w == .string) w.string else null;
}

/// Substrings in Chrome's stderr that mean it is never going to come up.
pub fn fatalInLog(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "Running as root without --no-sandbox") != null or
        std.mem.indexOf(u8, text, "FATAL") != null or
        std.mem.indexOf(u8, text, "Failed to create") != null and std.mem.indexOf(u8, text, "sandbox") != null;
}

/// Names tried on PATH, in order.
pub const path_names = [_][]const u8{ "google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "chrome", "msedge", "microsoft-edge" };

pub const posix_absolute = [_][]const u8{
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    "/opt/google/chrome/chrome",
    "/snap/bin/chromium",
    "/usr/bin/microsoft-edge",
};

pub const windows_rel = [_][]const u8{
    "\\Google\\Chrome\\Application\\chrome.exe",
    "\\Microsoft\\Edge\\Application\\msedge.exe",
    "\\Chromium\\Application\\chrome.exe",
};
pub const windows_env = [_][]const u8{ "ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA" };

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

/// Locate a Chromium-family binary. `env` is the process environment map.
pub fn findBinary(alloc: Allocator, io: Io, env: *const std.process.Environ.Map, cfg_bin: ?[]const u8) ![]u8 {
    if (cfg_bin) |b| if (b.len > 0) return alloc.dupe(u8, b);
    const is_win = builtin.os.tag == .windows;
    if (env.get("PATH")) |path| {
        var dirs = std.mem.tokenizeScalar(u8, path, std.fs.path.delimiter);
        while (dirs.next()) |d| {
            for (path_names) |n| {
                const file = if (is_win) try std.fmt.allocPrint(alloc, "{s}.exe", .{n}) else try alloc.dupe(u8, n);
                defer alloc.free(file);
                const full = try std.fs.path.join(alloc, &.{ d, file });
                if (std.fs.path.isAbsolute(full) and exists(io, full)) return full;
                alloc.free(full);
            }
        }
    }
    if (is_win) {
        for (windows_env) |ev| {
            const base = env.get(ev) orelse continue;
            for (windows_rel) |rel| {
                const full = try std.fmt.allocPrint(alloc, "{s}{s}", .{ base, rel });
                if (exists(io, full)) return full;
                alloc.free(full);
            }
        }
    } else {
        for (posix_absolute) |p| if (exists(io, p)) return alloc.dupe(u8, p);
    }
    return error.BrowserNotFound;
}

// ---------------------------------------------------------------- launch

pub const Launched = struct {
    child: std.process.Child,
    profile_dir: []u8,
    endpoint: Endpoint,
    /// Owns endpoint.host/path.
    ep_buf: []u8,
};

fn tmpBase(env: *const std.process.Environ.Map) []const u8 {
    for ([_][]const u8{ "TMPDIR", "TEMP", "TMP" }) |k| {
        if (env.get(k)) |v| if (v.len > 0) return std.mem.trimEnd(u8, v, "/\\");
    }
    return if (builtin.os.tag == .windows) "C:\\Windows\\Temp" else "/tmp";
}

pub const LaunchError = error{ BrowserNotFound, StartTimeout, BrowserFailed, OutOfMemory, SpawnFailed };

/// Spawn the browser and wait for its DevTools endpoint. On failure `detail`
/// (if non-null) receives a short human-readable reason (owned by alloc).
pub fn launch(alloc: Allocator, io: Io, env: *const std.process.Environ.Map, cfg: Config, detail: *?[]u8, timeout_ms: i64) LaunchError!Launched {
    const bin = findBinary(alloc, io, env, cfg.bin) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            detail.* = alloc.dupe(u8, "no Chrome/Chromium/Edge found (tried PATH names google-chrome, chromium, chromium-browser, chrome, msedge and default install paths); set ZMCP_BROWSER_BIN") catch null;
            return error.BrowserNotFound;
        },
    };
    defer alloc.free(bin);

    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const profile = std.fmt.allocPrint(alloc, "{s}{c}zmcp-browser-{x}", .{ tmpBase(env), std.fs.path.sep, std.mem.readInt(u64, &rnd, .little) }) catch return error.OutOfMemory;
    errdefer alloc.free(profile);
    const perm: Io.Dir.Permissions = if (@hasDecl(Io.Dir.Permissions, "fromMode")) .fromMode(0o700) else .default_dir;
    Io.Dir.createDirAbsolute(io, profile, perm) catch |e| {
        detail.* = std.fmt.allocPrint(alloc, "cannot create profile dir {s}: {s}", .{ profile, @errorName(e) }) catch null;
        return error.SpawnFailed;
    };
    errdefer Io.Dir.cwd().deleteTree(io, profile) catch {};

    const log_path = std.fmt.allocPrint(alloc, "{s}{c}chrome.log", .{ profile, std.fs.path.sep }) catch return error.OutOfMemory;
    defer alloc.free(log_path);
    const log_file = Io.Dir.createFileAbsolute(io, log_path, .{}) catch |e| {
        detail.* = std.fmt.allocPrint(alloc, "cannot create {s}: {s}", .{ log_path, @errorName(e) }) catch null;
        return error.SpawnFailed;
    };
    defer log_file.close(io);

    const argv = buildArgv(alloc, bin, profile, cfg) catch return error.OutOfMemory;
    defer freeArgv(alloc, argv);

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .{ .file = log_file },
    }) catch |e| {
        detail.* = std.fmt.allocPrint(alloc, "cannot start {s}: {s}", .{ bin, @errorName(e) }) catch null;
        return error.SpawnFailed;
    };
    errdefer child.kill(io);

    const port_path = std.fmt.allocPrint(alloc, "{s}{c}DevToolsActivePort", .{ profile, std.fs.path.sep }) catch return error.OutOfMemory;
    defer alloc.free(port_path);

    const start = Io.Clock.awake.now(io).toMilliseconds();
    while (true) {
        // 1) DevToolsActivePort (port + browser path)
        if (Io.Dir.cwd().readFileAlloc(io, port_path, alloc, .limited(4096))) |txt| {
            defer alloc.free(txt);
            if (parseActivePort(txt)) |ep| {
                const buf = alloc.alloc(u8, ep.host.len + ep.path.len) catch return error.OutOfMemory;
                @memcpy(buf[0..ep.host.len], ep.host);
                @memcpy(buf[ep.host.len..], ep.path);
                return .{
                    .child = child,
                    .profile_dir = profile,
                    .endpoint = .{ .host = buf[0..ep.host.len], .port = ep.port, .path = buf[ep.host.len..] },
                    .ep_buf = buf,
                };
            }
        } else |_| {}
        // 2) stderr log: fail fast on fatal errors, or take the ws URL.
        if (Io.Dir.cwd().readFileAlloc(io, log_path, alloc, .limited(256 * 1024))) |log| {
            defer alloc.free(log);
            if (parseDevToolsListening(log)) |u| if (parseWsUrl(u)) |ep| {
                const buf = alloc.alloc(u8, ep.host.len + ep.path.len) catch return error.OutOfMemory;
                @memcpy(buf[0..ep.host.len], ep.host);
                @memcpy(buf[ep.host.len..], ep.path);
                return .{
                    .child = child,
                    .profile_dir = profile,
                    .endpoint = .{ .host = buf[0..ep.host.len], .port = ep.port, .path = buf[ep.host.len..] },
                    .ep_buf = buf,
                };
            };
            if (fatalInLog(log)) {
                detail.* = failDetail(alloc, log);
                return error.BrowserFailed;
            }
        } else |_| {}
        if (Io.Clock.awake.now(io).toMilliseconds() - start > timeout_ms) {
            var tail: ?[]u8 = null;
            if (Io.Dir.cwd().readFileAlloc(io, log_path, alloc, .limited(256 * 1024))) |log| {
                defer alloc.free(log);
                tail = failDetail(alloc, log);
            } else |_| {}
            detail.* = tail orelse alloc.dupe(u8, "browser did not report a DevTools endpoint in time") catch null;
            return error.StartTimeout;
        }
        io.sleep(Io.Duration.fromMilliseconds(50), .awake) catch {};
    }
}

fn failDetail(alloc: Allocator, log: []const u8) ?[]u8 {
    var tail = std.mem.trim(u8, log, " \r\n");
    if (tail.len > 600) tail = tail[tail.len - 600 ..];
    const root_hint = if (std.mem.indexOf(u8, log, "as root") != null)
        " (running as root: set ZMCP_BROWSER_NO_SANDBOX=1 to pass --no-sandbox, only inside a container you trust)"
    else
        "";
    return std.fmt.allocPrint(alloc, "browser failed to start: {s}{s}", .{ tail, root_hint }) catch null;
}

// ---------------------------------------------------------------- signals

var g_kill_pid = std.atomic.Value(i32).init(0);

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    const pid = g_kill_pid.load(.acquire);
    if (pid > 0) std.posix.kill(pid, .KILL) catch {};
    std.process.exit(1);
}

/// POSIX: when this process is told to stop (TERM/INT/HUP) kill the private
/// browser instead of orphaning it. (The temp profile is left behind in that
/// case; it is only removed on a normal exit / stdin EOF.)
pub fn armSignalKill(pid: i32) void {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
    g_kill_pid.store(pid, .release);
    const act: std.posix.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = std.posix.sigemptyset(), .flags = 0 };
    for ([_]std.posix.SIG{ .TERM, .INT, .HUP }) |sg| std.posix.sigaction(sg, &act, null);
}

pub fn disarmSignalKill() void {
    g_kill_pid.store(0, .release);
}

/// Kill the browser and delete its temporary profile.
pub fn shutdown(alloc: Allocator, io: Io, l: *Launched) void {
    disarmSignalKill();
    l.child.kill(io);
    var tries: u8 = 0;
    while (tries < 5) : (tries += 1) {
        Io.Dir.cwd().deleteTree(io, l.profile_dir) catch {
            io.sleep(Io.Duration.fromMilliseconds(100), .awake) catch {};
            continue;
        };
        break;
    }
    alloc.free(l.profile_dir);
    alloc.free(l.ep_buf);
}

// ---------------------------------------------------------------- attach

/// Content-Length from an HTTP header block (case-insensitive, optional space).
pub fn contentLength(head: []const u8) ?usize {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    while (it.next()) |l| {
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, l[0..colon], " \t"), "content-length")) {
            return std.fmt.parseInt(usize, std.mem.trim(u8, l[colon + 1 ..], " \t"), 10) catch null;
        }
    }
    return null;
}

/// GET /json/version on a loopback DevTools port; returns the browser
/// websocket path (owned).
pub fn fetchBrowserPath(alloc: Allocator, io: Io, host: []const u8, port: u16) ![]u8 {
    const tcp = try ws.Tcp.connect(alloc, io, host, port);
    defer tcp.destroy(alloc);
    const bs = tcp.byteStream();
    var req_buf: [256]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "GET /json/version HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n", .{ host, port });
    try bs.write_fn(bs.ctx, req);
    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(alloc);
    var chunk: [4096]u8 = undefined;
    while (resp.items.len < 256 * 1024) {
        const n = bs.read_fn(bs.ctx, &chunk, 5000) catch |e| switch (e) {
            error.Timeout => return error.StartTimeout,
            else => return e,
        };
        if (n == 0) break;
        try resp.appendSlice(alloc, chunk[0..n]);
        // Chrome keeps the connection open: stop at Content-Length.
        if (std.mem.indexOf(u8, resp.items, "\r\n\r\n")) |he| {
            if (contentLength(resp.items[0..he])) |cl| {
                if (resp.items.len >= he + 4 + cl) break;
            }
        }
    }
    const sep_i = std.mem.indexOf(u8, resp.items, "\r\n\r\n") orelse return error.BadResponse;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const wsurl = parseVersionJson(arena_state.allocator(), resp.items[sep_i + 4 ..]) orelse return error.BadResponse;
    const ep = parseWsUrl(wsurl) orelse return error.BadResponse;
    return alloc.dupe(u8, ep.path);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "buildArgv: headless default, sandbox on, fresh profile, port 0" {
    const a = testing.allocator;
    const argv = try buildArgv(a, "/usr/bin/chromium", "/tmp/zmcp-browser-1", .{});
    defer freeArgv(a, argv);
    try testing.expectEqualStrings("/usr/bin/chromium", argv[0]);
    var have = std.StringHashMap(void).init(a);
    defer have.deinit();
    for (argv) |x| try have.put(x, {});
    try testing.expect(have.contains("--remote-debugging-port=0"));
    try testing.expect(have.contains("--user-data-dir=/tmp/zmcp-browser-1"));
    try testing.expect(have.contains("--headless=new"));
    try testing.expect(have.contains("--no-first-run"));
    try testing.expect(have.contains("--no-default-browser-check"));
    try testing.expect(!have.contains("--no-sandbox"));
    try testing.expectEqualStrings("about:blank", argv[argv.len - 1]);
    // nothing that exposes the port beyond loopback or loads extensions
    for (argv) |x| {
        try testing.expect(std.mem.indexOf(u8, x, "remote-debugging-address") == null);
        try testing.expect(std.mem.indexOf(u8, x, "load-extension") == null);
    }
}

test "buildArgv: headed and no-sandbox opt-ins" {
    const a = testing.allocator;
    const argv = try buildArgv(a, "chrome", "/p", .{ .headed = true, .no_sandbox = true });
    defer freeArgv(a, argv);
    var headless = false;
    var nosb = false;
    for (argv) |x| {
        if (std.mem.startsWith(u8, x, "--headless")) headless = true;
        if (std.mem.eql(u8, x, "--no-sandbox")) nosb = true;
    }
    try testing.expect(!headless);
    try testing.expect(nosb);
}

test "parse DevTools listening line, DevToolsActivePort, ws url" {
    const log = "[0101/000000.000:WARNING:foo] x\r\nDevTools listening on ws://127.0.0.1:41235/devtools/browser/abc-def\r\nmore\n";
    const u = parseDevToolsListening(log).?;
    try testing.expectEqualStrings("ws://127.0.0.1:41235/devtools/browser/abc-def", u);
    const ep = parseWsUrl(u).?;
    try testing.expectEqualStrings("127.0.0.1", ep.host);
    try testing.expectEqual(@as(u16, 41235), ep.port);
    try testing.expectEqualStrings("/devtools/browser/abc-def", ep.path);
    try testing.expect(parseDevToolsListening("nothing here") == null);
    const ap = parseActivePort("41235\n/devtools/browser/abc-def").?;
    try testing.expectEqual(@as(u16, 41235), ap.port);
    try testing.expectEqualStrings("/devtools/browser/abc-def", ap.path);
    try testing.expect(parseActivePort("0\n/x") == null);
    try testing.expect(parseActivePort("41235") == null);
    try testing.expect(parseWsUrl("http://x/y") == null);
}

test "attach URL: loopback only" {
    const d = try parseAttachUrl("http://127.0.0.1:9333");
    try testing.expectEqual(@as(u16, 9333), d.port);
    const d2 = try parseAttachUrl("http://localhost");
    try testing.expectEqualStrings("127.0.0.1", d2.host);
    try testing.expectEqual(@as(u16, 9222), d2.port);
    try testing.expectError(error.NotLoopback, parseAttachUrl("http://192.168.1.5:9222"));
    try testing.expectError(error.NotLoopback, parseAttachUrl("http://evil.example:9222"));
    try testing.expectError(error.BadUrl, parseAttachUrl("https://127.0.0.1:9222"));
}

test "parseVersionJson" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const j = "{\"Browser\":\"Chrome/1\",\"webSocketDebuggerUrl\":\"ws://127.0.0.1:9222/devtools/browser/zz\"}";
    try testing.expectEqualStrings("ws://127.0.0.1:9222/devtools/browser/zz", parseVersionJson(arena_state.allocator(), j).?);
    try testing.expect(parseVersionJson(arena_state.allocator(), "{}") == null);
    try testing.expect(parseVersionJson(arena_state.allocator(), "junk") == null);
}

test "contentLength parses Chrome's header spelling" {
    try testing.expectEqual(@as(?usize, 412), contentLength("HTTP/1.1 200 OK\r\nContent-Security-Policy:frame-ancestors 'none'\r\nContent-Length:412\r\nContent-Type:application/json"));
    try testing.expectEqual(@as(?usize, 7), contentLength("HTTP/1.1 200 OK\r\ncontent-length: 7"));
    try testing.expectEqual(@as(?usize, null), contentLength("HTTP/1.1 200 OK\r\nX: 1"));
}

test "fatalInLog detects the root-without-sandbox failure" {
    try testing.expect(fatalInLog("[1:1:0101/1:ERROR:zygote_host_impl_linux.cc(1)] Running as root without --no-sandbox is not supported."));
    try testing.expect(!fatalInLog("[warning] something harmless"));
}

test "findBinary honours an explicit override without touching the disk" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    const b = try findBinary(testing.allocator, testing.io, &env, "/nonexistent/chrome");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("/nonexistent/chrome", b);
}
