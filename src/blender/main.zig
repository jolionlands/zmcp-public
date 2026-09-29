//! zmcp-blender: MCP client for the ahujasid/blender-mcp Blender addon.
//!
//! Wire protocol (verified against upstream server.py/addon.py): the addon
//! listens on TCP (default 127.0.0.1:9876). A request is one JSON object
//! `{"type": <cmd>, "params": {...}}` with NO delimiter; the reply is one JSON
//! object `{"status":"success","result":...}` or `{"status":"error","message":...}`,
//! also undelimited, so the reader accumulates chunks until the buffer parses.
//! A fresh connection is used per call.
//!
//! Tools (names match upstream): get_scene_info, get_object_info,
//! get_viewport_screenshot, execute_blender_code (gated by
//! ZMCP_BLENDER_ALLOW_EXEC=1).
//!
//! Env: BLENDER_HOST (127.0.0.1), BLENDER_PORT (9876),
//! ZMCP_BLENDER_ALLOW_REMOTE=1 (permit non-loopback IP literals),
//! ZMCP_BLENDER_ALLOW_EXEC=1, ZMCP_BLENDER_TIMEOUT_SECS (180, per read).

const std = @import("std");
const mcp = @import("mcp");

const Io = std.Io;
const net = std.Io.net;

const MAX_RESPONSE_BYTES: usize = 32 * 1024 * 1024;
const MAX_TEXT_BYTES: usize = 64 * 1024;
const MAX_PNG_BYTES: usize = 8 * 1024 * 1024;
const MAX_CODE_BYTES: usize = 256 * 1024;

var g_env: ?*const std.process.Environ.Map = null;
var g_cfg_override: ?Config = null;
var g_counter: std.atomic.Value(u32) = .init(0);

pub fn main(init: std.process.Init) !void {
    g_env = init.environ_map;
    try mcp.run(init.gpa, init.io, .{ .name = "zmcp-blender", .version = "0.1.0" }, &tool_table);
}

// ---------------------------------------------------------------- config

const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 9876,
    allow_remote: bool = false,
    allow_exec: bool = false,
    timeout_secs: u32 = 180,
};

fn envGet(name: []const u8) ?[]const u8 {
    const env = g_env orelse return null;
    return env.get(name);
}

fn envFlag(v: ?[]const u8) bool {
    const s = v orelse return false;
    return std.mem.eql(u8, s, "1");
}

/// Returns null and sets `err` on invalid settings.
fn loadConfig(err: *[]const u8) ?Config {
    if (g_cfg_override) |c| return c;
    var c: Config = .{};
    if (envGet("BLENDER_HOST")) |h| {
        if (h.len > 0) c.host = h;
    }
    if (envGet("BLENDER_PORT")) |p| {
        if (p.len > 0) c.port = std.fmt.parseInt(u16, p, 10) catch {
            err.* = "BLENDER_PORT must be an integer 1-65535";
            return null;
        };
    }
    c.allow_remote = envFlag(envGet("ZMCP_BLENDER_ALLOW_REMOTE"));
    c.allow_exec = envFlag(envGet("ZMCP_BLENDER_ALLOW_EXEC"));
    if (envGet("ZMCP_BLENDER_TIMEOUT_SECS")) |t| {
        if (std.fmt.parseInt(u32, t, 10)) |n| {
            c.timeout_secs = std.math.clamp(n, 1, 600);
        } else |_| {}
    }
    return c;
}

fn isLoopback(addr: net.IpAddress) bool {
    return switch (addr) {
        .ip4 => |a| a.bytes[0] == 127,
        .ip6 => |a| blk: {
            const lo = [_]u8{0} ** 15 ++ [_]u8{1};
            break :blk std.mem.eql(u8, &a.bytes, &lo);
        },
    };
}

const AddrError = error{ NotLoopback, BadHost };

/// Resolve the configured host to an IP literal, enforcing loopback unless
/// remote access was explicitly allowed. Hostnames other than "localhost" are
/// not resolved (avoids DNS-based bypass).
fn resolveAddress(host: []const u8, port: u16, allow_remote: bool) AddrError!net.IpAddress {
    const literal = if (std.ascii.eqlIgnoreCase(host, "localhost")) "127.0.0.1" else host;
    const addr = net.IpAddress.parse(literal, port) catch return error.BadHost;
    if (!allow_remote and !isLoopback(addr)) return error.NotLoopback;
    return addr;
}

// -------------------------------------------------------------- protocol

fn buildRequest(a: std.mem.Allocator, cmd: []const u8, params: std.json.Value) ![]u8 {
    var sw: Io.Writer.Allocating = .init(a);
    var js = std.json.Stringify{ .writer = &sw.writer };
    try js.beginObject();
    try js.objectField("type");
    try js.write(cmd);
    try js.objectField("params");
    try js.write(params);
    try js.endObject();
    return sw.toOwnedSlice();
}

/// True once `buf` holds one complete JSON object (upstream's completeness
/// test: it simply retries json.loads after every chunk).
fn isCompleteJson(a: std.mem.Allocator, buf: []const u8) bool {
    const t = std.mem.trimEnd(u8, buf, " \t\r\n");
    if (t.len < 2) return false;
    if (t[t.len - 1] != '}') return false;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), t, .{}) catch return false;
    return v == .object;
}

const Reply = union(enum) {
    ok: std.json.Value,
    err: []const u8,
};

/// Decode a complete addon reply. Strings live in `a` (use an arena).
fn decodeReply(a: std.mem.Allocator, body: []const u8) Reply {
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch
        return .{ .err = "Blender addon sent an invalid JSON response" };
    if (v != .object) return .{ .err = "Blender addon sent a non-object response" };
    const status = v.object.get("status") orelse return .{ .err = "Blender addon response has no status field" };
    if (status == .string and std.mem.eql(u8, status.string, "error")) {
        if (v.object.get("message")) |m| {
            if (m == .string) return .{ .err = std.fmt.allocPrint(a, "Blender error: {s}", .{m.string}) catch "Blender error" };
        }
        return .{ .err = "Blender reported an unknown error" };
    }
    if (status == .string and std.mem.eql(u8, status.string, "success")) {
        return .{ .ok = v.object.get("result") orelse .null };
    }
    return .{ .err = "Blender addon response has an unknown status" };
}

/// Failure text or the raw reply body.
const Outcome = union(enum) {
    body: []u8,
    fail: []const u8,
};

/// Read from `read_fn` chunks until the accumulated bytes form one JSON object.
/// `src` must provide `read(buf: []u8) ReadError!usize` (0 = closed).
fn readUntilComplete(a: std.mem.Allocator, src: anytype, max_bytes: usize) Outcome {
    var acc: std.ArrayList(u8) = .empty;
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const n = src.read(&chunk) catch |e| {
            if (e == error.Timeout) return .{ .fail = "Timed out waiting for the Blender addon response" };
            return .{ .fail = "Connection to the Blender addon failed while reading" };
        };
        if (n == 0) return .{ .fail = "Blender addon closed the connection before sending a complete response" };
        if (acc.items.len + n > max_bytes) return .{ .fail = "Blender addon response exceeded the size limit" };
        acc.appendSlice(a, chunk[0..n]) catch return .{ .fail = "out of memory" };
        if (isCompleteJson(a, acc.items)) return .{ .body = acc.items };
    }
}

const SocketSource = struct {
    io: Io,
    stream: net.Stream,
    timeout_secs: u32,

    fn read(self: *SocketSource, buf: []u8) !usize {
        const msg = try self.stream.socket.receiveTimeout(self.io, buf, .{ .duration = .{
            .raw = Io.Duration.fromSeconds(self.timeout_secs),
            .clock = .awake,
        } });
        return msg.data.len;
    }
};

/// One connect / send / receive / close cycle.
fn roundTrip(a: std.mem.Allocator, io: Io, cfg: Config, cmd: []const u8, params: std.json.Value) Outcome {
    const addr = resolveAddress(cfg.host, cfg.port, cfg.allow_remote) catch |e| return switch (e) {
        error.NotLoopback => .{ .fail = "Refusing non-loopback BLENDER_HOST; set ZMCP_BLENDER_ALLOW_REMOTE=1 to allow" },
        error.BadHost => .{ .fail = "BLENDER_HOST must be an IP literal (or localhost)" },
    };
    const req = buildRequest(a, cmd, params) catch return .{ .fail = "out of memory" };

    const stream = addr.connect(io, .{ .mode = .stream }) catch |e| return switch (e) {
        else => .{ .fail = "Could not connect to Blender. Is the Blender addon running and connected? (Blender > sidebar > BlenderMCP > Connect)" },
    };
    defer stream.close(io);

    var wbuf: [4096]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    w.interface.writeAll(req) catch return .{ .fail = "Failed to send the command to the Blender addon" };
    w.interface.flush() catch return .{ .fail = "Failed to send the command to the Blender addon" };

    var src: SocketSource = .{ .io = io, .stream = stream, .timeout_secs = cfg.timeout_secs };
    return readUntilComplete(a, &src, MAX_RESPONSE_BYTES);
}

// ----------------------------------------------------------------- tools

fn errResult(text: []const u8) mcp.ToolResult {
    return .{ .text = text, .is_error = true };
}

fn cap(a: std.mem.Allocator, s: []const u8) mcp.ToolResult {
    if (s.len <= MAX_TEXT_BYTES) return .{ .text = s };
    const out = std.fmt.allocPrint(a, "{s}\n[truncated: {d} of {d} bytes shown]", .{ s[0..MAX_TEXT_BYTES], MAX_TEXT_BYTES, s.len }) catch return .{ .text = s[0..MAX_TEXT_BYTES] };
    return .{ .text = out };
}

fn jsonText(a: std.mem.Allocator, v: std.json.Value) ![]u8 {
    var sw: Io.Writer.Allocating = .init(a);
    var js = std.json.Stringify{ .writer = &sw.writer };
    try js.write(v);
    return sw.toOwnedSlice();
}

fn emptyParams(a: std.mem.Allocator) !std.json.Value {
    return .{ .object = try std.json.ObjectMap.init(a, &.{}, &.{}) };
}

/// Send a command and return the decoded reply, or an error ToolResult.
fn call(a: std.mem.Allocator, io: Io, cfg: Config, cmd: []const u8, params: std.json.Value) union(enum) { ok: std.json.Value, fail: mcp.ToolResult } {
    switch (roundTrip(a, io, cfg, cmd, params)) {
        .fail => |m| return .{ .fail = errResult(m) },
        .body => |b| switch (decodeReply(a, b)) {
            .err => |m| return .{ .fail = errResult(m) },
            .ok => |v| return .{ .ok = v },
        },
    }
}

fn withConfig(cfg_out: *Config) ?mcp.ToolResult {
    var msg: []const u8 = "";
    cfg_out.* = loadConfig(&msg) orelse return errResult(msg);
    return null;
}

fn sceneInfo(a: std.mem.Allocator, io: Io, _: std.json.Value) anyerror!mcp.ToolResult {
    var cfg: Config = undefined;
    if (withConfig(&cfg)) |e| return e;
    return switch (call(a, io, cfg, "get_scene_info", try emptyParams(a))) {
        .fail => |r| r,
        .ok => |v| cap(a, try jsonText(a, v)),
    };
}

fn objectInfo(a: std.mem.Allocator, io: Io, args: std.json.Value) anyerror!mcp.ToolResult {
    const name = strArg(args, "name") orelse return errResult("name (string) is required");
    if (name.len == 0 or name.len > 256) return errResult("name must be 1-256 characters");
    var cfg: Config = undefined;
    if (withConfig(&cfg)) |e| return e;
    var params = try emptyParams(a);
    try params.object.put(a, "name", .{ .string = name });
    return switch (call(a, io, cfg, "get_object_info", params)) {
        .fail => |r| r,
        .ok => |v| cap(a, try jsonText(a, v)),
    };
}

fn strArg(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn tmpDir() []const u8 {
    for ([_][]const u8{ "TMPDIR", "TEMP", "TMP" }) |k| {
        if (envGet(k)) |v| if (v.len > 0) return std.mem.trimEnd(u8, v, "/\\");
    }
    return "/tmp";
}

const PNG_MAGIC = "\x89PNG\r\n\x1a\n";

fn screenshot(a: std.mem.Allocator, io: Io, args: std.json.Value) anyerror!mcp.ToolResult {
    var max_size: i64 = 1000;
    if (args == .object) {
        if (args.object.get("max_size")) |v| switch (v) {
            .integer => |n| max_size = n,
            else => return errResult("max_size must be an integer"),
        };
    }
    max_size = std.math.clamp(max_size, 100, 4096);
    var cfg: Config = undefined;
    if (withConfig(&cfg)) |e| return e;

    const ts = Io.Timestamp.now(io, .real).nanoseconds;
    const path = try std.fmt.allocPrint(a, "{s}/blender_mcp_shot_{x}_{d}.png", .{ tmpDir(), @as(u64, @truncate(@as(u96, @bitCast(ts)))), g_counter.fetchAdd(1, .monotonic) });

    var params = try emptyParams(a);
    try params.object.put(a, "max_size", .{ .integer = max_size });
    try params.object.put(a, "filepath", .{ .string = path });
    try params.object.put(a, "format", .{ .string = "png" });

    const cwd = Io.Dir.cwd();
    const v = switch (call(a, io, cfg, "get_viewport_screenshot", params)) {
        .fail => |r| return r,
        .ok => |v| v,
    };
    defer cwd.deleteFile(io, path) catch {};
    if (v == .object) {
        if (v.object.get("error")) |e| {
            if (e == .string) return errResult(try std.fmt.allocPrint(a, "Screenshot failed: {s}", .{e.string}));
        }
    }
    const png = cwd.readFileAlloc(io, path, a, .limited(MAX_PNG_BYTES)) catch |e| return switch (e) {
        error.StreamTooLong => errResult("Screenshot exceeds the 8 MiB limit; lower max_size"),
        else => errResult("Blender reported success but the screenshot file could not be read (is Blender on this machine?)"),
    };
    if (png.len < PNG_MAGIC.len or !std.mem.eql(u8, png[0..PNG_MAGIC.len], PNG_MAGIC)) {
        return errResult("Screenshot file is not a PNG");
    }
    const enc = std.base64.standard.Encoder;
    const b64 = try a.alloc(u8, enc.calcSize(png.len));
    _ = enc.encode(b64, png);

    var w: i64 = 0;
    var h: i64 = 0;
    if (v == .object) {
        if (v.object.get("width")) |x| if (x == .integer) {
            w = x.integer;
        };
        if (v.object.get("height")) |x| if (x == .integer) {
            h = x.integer;
        };
    }
    const text = try std.fmt.allocPrint(a, "Viewport screenshot {d}x{d}", .{ w, h });
    return .{ .text = text, .image = .{ .data_base64 = b64, .mime_type = "image/png" } };
}

const exec_disabled = "execute_blender_code is disabled: it runs arbitrary Python inside Blender. Set ZMCP_BLENDER_ALLOW_EXEC=1 in the server environment to enable.";

fn executeCode(a: std.mem.Allocator, io: Io, args: std.json.Value) anyerror!mcp.ToolResult {
    var cfg: Config = undefined;
    if (withConfig(&cfg)) |e| return e;
    if (!cfg.allow_exec) return errResult(exec_disabled);
    const code = strArg(args, "code") orelse return errResult("code (string) is required");
    if (code.len == 0) return errResult("code must not be empty");
    if (code.len > MAX_CODE_BYTES) return errResult("code exceeds 256 KiB");
    var params = try emptyParams(a);
    try params.object.put(a, "code", .{ .string = code });
    return switch (call(a, io, cfg, "execute_code", params)) {
        .fail => |r| r,
        .ok => |v| blk: {
            var out: []const u8 = "";
            if (v == .object) {
                if (v.object.get("result")) |r| {
                    if (r == .string) out = r.string else out = try jsonText(a, r);
                }
            }
            break :blk cap(a, try std.fmt.allocPrint(a, "Code executed successfully: {s}", .{out}));
        },
    };
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "get_scene_info",
        .description = "Current Blender scene: name, object count, first objects, materials count.",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{}}",
        .handler = sceneInfo,
        .read_only = true,
    },
    .{
        .name = "get_object_info",
        .description = "Details of one Blender object (transform, materials, bounds, mesh stats).",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}},\"required\":[\"name\"]}",
        .handler = objectInfo,
        .read_only = true,
    },
    .{
        .name = "get_viewport_screenshot",
        .description = "Screenshot of the 3D viewport as a PNG image (needs Blender on this machine).",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"max_size\":{\"type\":\"integer\",\"description\":\"max pixels, 100-4096, default 1000\"}}}",
        .handler = screenshot,
        .read_only = true,
    },
    .{
        .name = "execute_blender_code",
        .description = "Run Python in Blender (arbitrary code; needs ZMCP_BLENDER_ALLOW_EXEC=1).",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"code\":{\"type\":\"string\"}},\"required\":[\"code\"]}",
        .handler = executeCode,
        .destructive = true,
    },
};

// ----------------------------------------------------------------- tests

const testing = std.testing;

test "buildRequest matches upstream shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("{\"type\":\"get_scene_info\",\"params\":{}}", try buildRequest(a, "get_scene_info", try emptyParams(a)));
    var p = try emptyParams(a);
    try p.object.put(a, "code", .{ .string = "print(\"x\")\n" });
    try testing.expectEqualStrings("{\"type\":\"execute_code\",\"params\":{\"code\":\"print(\\\"x\\\")\\n\"}}", try buildRequest(a, "execute_code", p));
}

test "decodeReply success, error and malformed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = decodeReply(a, "{\"status\":\"success\",\"result\":{\"name\":\"Scene\"}}");
    try testing.expect(ok == .ok);
    try testing.expectEqualStrings("Scene", ok.ok.object.get("name").?.string);
    const bad = decodeReply(a, "{\"status\":\"error\",\"message\":\"Object not found\"}");
    try testing.expectEqualStrings("Blender error: Object not found", bad.err);
    try testing.expect(decodeReply(a, "{\"status\":\"weird\"}") == .err);
    try testing.expect(decodeReply(a, "{\"result\":1}") == .err);
    try testing.expect(decodeReply(a, "[1]") == .err);
    try testing.expect(decodeReply(a, "{oops") == .err);
}

test "isCompleteJson needs a whole object" {
    const a = testing.allocator;
    try testing.expect(!isCompleteJson(a, ""));
    try testing.expect(!isCompleteJson(a, "{\"status\":\"succ"));
    try testing.expect(!isCompleteJson(a, "{\"a\":{\"b\":1}"));
    try testing.expect(isCompleteJson(a, "{\"a\":{\"b\":1}}"));
    try testing.expect(isCompleteJson(a, "{\"a\":\"}\"}\n"));
    try testing.expect(!isCompleteJson(a, "[1]"));
}

/// Canned-chunk source for framing tests.
const ChunkSrc = struct {
    chunks: []const []const u8,
    i: usize = 0,
    timeout_at_end: bool = false,
    fn read(self: *ChunkSrc, buf: []u8) !usize {
        if (self.i == self.chunks.len) {
            if (self.timeout_at_end) return error.Timeout;
            return 0;
        }
        const c = self.chunks[self.i];
        self.i += 1;
        @memcpy(buf[0..c.len], c);
        return c.len;
    }
};

test "readUntilComplete reassembles split reads" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var src: ChunkSrc = .{ .chunks = &.{ "{\"status\":\"succ", "ess\",\"resu", "lt\":{\"a\":[1,2]}", "}" } };
    const o = readUntilComplete(arena.allocator(), &src, 1024);
    try testing.expectEqualStrings("{\"status\":\"success\",\"result\":{\"a\":[1,2]}}", o.body);
    // Split inside a multi-byte UTF-8 character.
    var src2: ChunkSrc = .{ .chunks = &.{ "{\"result\":\"\xc3", "\xa9\"}" } };
    try testing.expectEqualStrings("{\"result\":\"\xc3\xa9\"}", readUntilComplete(arena.allocator(), &src2, 1024).body);
}

test "readUntilComplete failure modes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var closed: ChunkSrc = .{ .chunks = &.{"{\"status\":"} };
    try testing.expect(std.mem.indexOf(u8, readUntilComplete(arena.allocator(), &closed, 1024).fail, "closed") != null);
    var slow: ChunkSrc = .{ .chunks = &.{"{\"status\":"}, .timeout_at_end = true };
    try testing.expect(std.mem.indexOf(u8, readUntilComplete(arena.allocator(), &slow, 1024).fail, "Timed out") != null);
    var big: ChunkSrc = .{ .chunks = &.{ "{\"a\":\"xxxxxxxxxx", "xxxxxxxxxxxxxxxx" } };
    try testing.expect(std.mem.indexOf(u8, readUntilComplete(arena.allocator(), &big, 20).fail, "size limit") != null);
}

test "loopback enforcement" {
    _ = try resolveAddress("127.0.0.1", 9876, false);
    _ = try resolveAddress("localhost", 9876, false);
    _ = try resolveAddress("127.5.5.5", 1, false);
    _ = try resolveAddress("::1", 1, false);
    try testing.expectError(error.NotLoopback, resolveAddress("192.168.1.5", 9876, false));
    try testing.expectError(error.NotLoopback, resolveAddress("0.0.0.0", 9876, false));
    try testing.expectError(error.NotLoopback, resolveAddress("::ffff:10.0.0.1", 9876, false));
    try testing.expectError(error.BadHost, resolveAddress("example.com", 9876, true));
    _ = try resolveAddress("192.168.1.5", 9876, true);
}

test "envFlag only accepts 1" {
    try testing.expect(envFlag("1"));
    try testing.expect(!envFlag("0"));
    try testing.expect(!envFlag("true"));
    try testing.expect(!envFlag(null));
}

fn testIo() Io {
    const t = std.Io.Threaded.global_single_threaded;
    return t.io();
}

test "execute_blender_code is refused without ALLOW_EXEC and never connects" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    g_cfg_override = .{ .port = 1, .allow_exec = false };
    defer g_cfg_override = null;
    var args = try emptyParams(arena.allocator());
    try args.object.put(arena.allocator(), "code", .{ .string = "print(1)" });
    const r = try executeCode(arena.allocator(), testIo(), args);
    try testing.expect(r.is_error);
    try testing.expect(std.mem.indexOf(u8, r.text, "ZMCP_BLENDER_ALLOW_EXEC=1") != null);
}

test "non-loopback host is refused by tools" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    g_cfg_override = .{ .host = "10.1.2.3" };
    defer g_cfg_override = null;
    const r = try sceneInfo(arena.allocator(), testIo(), .null);
    try testing.expect(r.is_error);
    try testing.expect(std.mem.indexOf(u8, r.text, "ZMCP_BLENDER_ALLOW_REMOTE=1") != null);
}

test "connection refused gives a clear message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Bind an ephemeral port, then close it so nothing listens there.
    var addr = try net.IpAddress.parse("127.0.0.1", 0);
    var srv = try addr.listen(testIo(), .{});
    const port = srv.socket.address.getPort();
    srv.deinit(testIo());
    g_cfg_override = .{ .port = port };
    defer g_cfg_override = null;
    const r = try sceneInfo(arena.allocator(), testIo(), .null);
    try testing.expect(r.is_error);
    try testing.expect(std.mem.indexOf(u8, r.text, "Is the Blender addon running") != null);
}

test "arg validation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    g_cfg_override = .{ .port = 1, .allow_exec = true };
    defer g_cfg_override = null;
    try testing.expect((try objectInfo(arena.allocator(), testIo(), .null)).is_error);
    try testing.expect((try executeCode(arena.allocator(), testIo(), .null)).is_error);
}

// ---- in-process fake addon

const Fake = struct {
    server: net.Server,
    reply_chunks: []const []const u8,
    request: [4096]u8 = undefined,
    request_len: usize = 0,
    hold_ms: i64 = 0,

    fn run(self: *Fake, io: Io) void {
        var stream = self.server.accept(io) catch return;
        defer stream.close(io);
        var acc: [4096]u8 = undefined;
        var n: usize = 0;
        while (true) {
            const m = stream.socket.receive(io, acc[n..]) catch return;
            if (m.data.len == 0) return;
            n += m.data.len;
            if (isCompleteJson(testing.allocator, acc[0..n])) break;
        }
        @memcpy(self.request[0..n], acc[0..n]);
        self.request_len = n;
        var wbuf: [64]u8 = undefined;
        var w = stream.writer(io, &wbuf);
        for (self.reply_chunks) |c| {
            w.interface.writeAll(c) catch return;
            w.interface.flush() catch return;
            io.sleep(.fromMilliseconds(20), .awake) catch return;
        }
        if (self.hold_ms > 0) io.sleep(.fromMilliseconds(self.hold_ms), .awake) catch return;
    }
};

test "fake addon: scene info over TCP with split reply" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var addr = try net.IpAddress.parse("127.0.0.1", 0);
    var fake: Fake = .{
        .server = try addr.listen(io, .{}),
        .reply_chunks = &.{ "{\"status\":\"success\",\"res", "ult\":{\"name\":\"Scene\",\"object_count\":3}", "}" },
    };
    defer fake.server.deinit(io);
    const port = fake.server.socket.address.getPort();
    const th = try std.Thread.spawn(.{}, Fake.run, .{ &fake, io });

    g_cfg_override = .{ .port = port, .timeout_secs = 5 };
    defer g_cfg_override = null;
    const r = try sceneInfo(a, io, .null);
    th.join();
    try testing.expect(!r.is_error);
    try testing.expectEqualStrings("{\"name\":\"Scene\",\"object_count\":3}", r.text);
    try testing.expectEqualStrings("{\"type\":\"get_scene_info\",\"params\":{}}", fake.request[0..fake.request_len]);
}

test "fake addon: execute code and error status" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var addr = try net.IpAddress.parse("127.0.0.1", 0);
    var fake: Fake = .{
        .server = try addr.listen(io, .{}),
        .reply_chunks = &.{"{\"status\":\"success\",\"result\":{\"executed\":true,\"result\":\"hi\\n\"}}"},
    };
    defer fake.server.deinit(io);
    const th = try std.Thread.spawn(.{}, Fake.run, .{ &fake, io });
    g_cfg_override = .{ .port = fake.server.socket.address.getPort(), .allow_exec = true, .timeout_secs = 5 };
    defer g_cfg_override = null;
    var args = try emptyParams(a);
    try args.object.put(a, "code", .{ .string = "print('hi')" });
    const r = try executeCode(a, io, args);
    th.join();
    try testing.expect(!r.is_error);
    try testing.expectEqualStrings("Code executed successfully: hi\n", r.text);
    try testing.expectEqualStrings("{\"type\":\"execute_code\",\"params\":{\"code\":\"print('hi')\"}}", fake.request[0..fake.request_len]);

    // Error status from the addon.
    var fake2: Fake = .{
        .server = try addr.listen(io, .{}),
        .reply_chunks = &.{"{\"status\":\"error\",\"message\":\"Object not found: Foo\"}"},
    };
    defer fake2.server.deinit(io);
    const th2 = try std.Thread.spawn(.{}, Fake.run, .{ &fake2, io });
    g_cfg_override = .{ .port = fake2.server.socket.address.getPort(), .timeout_secs = 5 };
    var oargs = try emptyParams(a);
    try oargs.object.put(a, "name", .{ .string = "Foo" });
    const r2 = try objectInfo(a, io, oargs);
    th2.join();
    try testing.expect(r2.is_error);
    try testing.expectEqualStrings("Blender error: Object not found: Foo", r2.text);
}

test "truncated reply then close is an error" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var addr = try net.IpAddress.parse("127.0.0.1", 0);
    var fake: Fake = .{ .server = try addr.listen(io, .{}), .reply_chunks = &.{"{\"status\":\"succ"} };
    defer fake.server.deinit(io);
    const th = try std.Thread.spawn(.{}, Fake.run, .{ &fake, io });
    g_cfg_override = .{ .port = fake.server.socket.address.getPort(), .timeout_secs = 1 };
    defer g_cfg_override = null;
    const r = try sceneInfo(arena.allocator(), io, .null);
    th.join();
    try testing.expect(r.is_error);
}

test "read timeout when addon stays silent" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var addr = try net.IpAddress.parse("127.0.0.1", 0);
    var fake: Fake = .{ .server = try addr.listen(io, .{}), .reply_chunks = &.{}, .hold_ms = 2500 };
    defer fake.server.deinit(io);
    const th = try std.Thread.spawn(.{}, Fake.run, .{ &fake, io });
    g_cfg_override = .{ .port = fake.server.socket.address.getPort(), .timeout_secs = 1 };
    defer g_cfg_override = null;
    const r = try sceneInfo(arena.allocator(), io, .null);
    th.join();
    try testing.expect(r.is_error);
    try testing.expect(std.mem.indexOf(u8, r.text, "Timed out") != null);
}
