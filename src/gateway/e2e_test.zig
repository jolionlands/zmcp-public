//! End-to-end tests over real child processes: the `zmcp-fake` helper
//! (src/gateway/fakechild.zig, built by `zig build test`) is spawned through
//! the real spawner, pipes and JSON-RPC framing. No network involved.

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;
const boot = @import("boot.zig");
const catalog = @import("catalog.zig");
const gateway = @import("gateway.zig");
const pool_mod = @import("pool.zig");
const proc = @import("proc.zig");
const profile = @import("profile.zig");

const alloc = std.testing.allocator;

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

const Env = struct {
    base: std.process.Environ.Map,
    real: proc.RealSpawner,
    cat: catalog.Catalog,
    dir_storage: ?[]u8 = null,

    fn init(extra: []const [2][]const u8) !*Env {
        const e = try alloc.create(Env);
        errdefer alloc.destroy(e);
        e.dir_storage = null;
        e.base =try std.testing.environ.createMap(alloc);
        errdefer e.base.deinit();
        // Variables a real deployment sets on the gateway itself.
        try e.base.put("ZMCP_HTTP", "127.0.0.1:1");
        try e.base.put("ZMCP_HTTP_TOKEN", "tok");
        try e.base.put("ZMCP_GATEWAY_PROFILE", "dev");
        try e.base.put("ZMCP_TOOL_MODE", "lazy");
        try e.base.put("ZMCP_TOOLS", "outer_*");
        try e.base.put("MY_API_KEY", "k123");
        for (extra) |kv| try e.base.put(kv[0], kv[1]);
        // The build hands us a path that may be relative to the project root.
        var dir: []const u8 = std.fs.path.dirname(build_options.fake_child_path).?;
        if (!std.fs.path.isAbsolute(dir)) {
            const cwd = try std.process.currentPathAlloc(std.testing.io, alloc);
            defer alloc.free(cwd);
            e.dir_storage = try std.fs.path.join(alloc, &.{ cwd, dir });
            dir = e.dir_storage.?;
        }
        e.real = .{ .gpa = alloc, .locator = .{ .bin_dir = dir, .path_env = "" }, .base_env = &e.base };
        e.cat = try catalog.Catalog.init(alloc);
        return e;
    }

    fn deinit(self: *Env) void {
        self.real.plans.deinit(alloc);
        if (self.dir_storage) |d| alloc.free(d);
        self.cat.deinit();
        self.base.deinit();
        alloc.destroy(self);
    }
};

fn callJson(gw: *gateway.Gateway, a: std.mem.Allocator, name: []const u8, args_json: []const u8) !@import("mcp").ToolResult {
    const text = try std.fmt.allocPrint(a, "{{\"name\":\"{s}\",\"arguments\":{s}}}", .{ name, args_json });
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
    return gw.toolCall(a, std.testing.io, v);
}

fn instanceOf(text: []const u8) []const u8 {
    return text[std.mem.indexOfScalar(u8, text, ':').? + 1 ..];
}

test "catalog build over a real child: tools, marks and stripped env" {
    const env = try Env.init(&.{});
    defer env.deinit();
    const res = boot.refresh(std.testing.io, &env.cat, env.real.locator, &env.real, &.{"fake"}, true, 10_000);
    try std.testing.expect(res.changed);
    try std.testing.expectEqual(@as(usize, 0), res.failed);
    const s = env.cat.find("fake").?;
    // ZMCP_TOOL_MODE=lazy in the gateway env must not leak to the child: a
    // lazy child would list only three meta tools.
    try std.testing.expectEqual(@as(usize, 7), s.tools.len);
    try std.testing.expectEqualStrings("fake_echo", s.tools[0].name);
    try std.testing.expect(s.tools[0].read_only);
    try std.testing.expect(!s.tools[2].read_only); // fake_crash
    try std.testing.expect(s.size > 0 and s.mtime_ms > 0);
    // Fingerprint matches the binary; a stale one does not.
    const found = env.real.locator.locate(std.testing.io, alloc, "fake").?;
    defer alloc.free(found.path);
    try std.testing.expect(s.matches(found.size, found.mtime_ms));
    try std.testing.expect(!s.matches(found.size + 1, found.mtime_ms));
    // Not stale: a second non-forced refresh does nothing.
    const again = boot.refresh(std.testing.io, &env.cat, env.real.locator, &env.real, &.{"fake"}, false, 10_000);
    try std.testing.expect(!again.changed);
}

test "lazy spawn, reuse, idle reap and respawn over real processes" {
    const env = try Env.init(&.{});
    defer env.deinit();
    _ = boot.refresh(std.testing.io, &env.cat, env.real.locator, &env.real, &.{"fake"}, true, 10_000);

    const gw = try gateway.Gateway.init(alloc, &env.cat, &.{"fake"}, .{}, "t", env.real.spawner(), .{}, .{
        .idle_ms = 400,
        .call_timeout_ms = 10_000,
    });
    defer gw.deinit(std.testing.io);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    // Nothing runs until the first tool_call (search and schema are free).
    _ = try gw.toolSearch(a, .null);
    _ = try gw.toolSchema(a, try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"name\":\"fake_echo\"}", .{}));
    try std.testing.expectEqual(@as(usize, 0), gw.pool.liveCount());
    try std.testing.expectEqual(@as(u32, 0), gw.pool.spawnCount("fake"));

    const r1 = try callJson(gw, a, "fake_echo", "{\"text\":\"hi\"}");
    try std.testing.expect(!r1.is_error);
    try std.testing.expectEqualStrings("echo:hi", r1.text);
    try std.testing.expectEqual(@as(usize, 1), gw.pool.liveCount());

    // Reuse: the same process answers again.
    const p1 = try callJson(gw, a, "fake_pid", "{}");
    const p2 = try callJson(gw, a, "fake_pid", "{}");
    try std.testing.expectEqualStrings(instanceOf(p1.text), instanceOf(p2.text));
    try std.testing.expectEqual(@as(u32, 1), gw.pool.spawnCount("fake"));

    // Reap after idle (the timer thread does this in production).
    try io.sleep(Io.Duration.fromMilliseconds(600), .awake);
    try std.testing.expectEqual(@as(usize, 1), gw.reapTick(io));
    try std.testing.expectEqual(@as(usize, 0), gw.pool.liveCount());

    // Respawn on the next call: a different process.
    const p3 = try callJson(gw, a, "fake_pid", "{}");
    try std.testing.expect(!std.mem.eql(u8, instanceOf(p1.text), instanceOf(p3.text)));
    try std.testing.expectEqual(@as(u32, 2), gw.pool.spawnCount("fake"));

    // Crash mid-call: error result, child dead, next call respawns.
    const c = try callJson(gw, a, "fake_crash", "{}");
    try std.testing.expect(c.is_error);
    try std.testing.expect(contains(c.text, "exited during the call"));
    try std.testing.expectEqual(@as(usize, 0), gw.pool.liveCount());
    const p4 = try callJson(gw, a, "fake_pid", "{}");
    try std.testing.expect(!p4.is_error);
    try std.testing.expect(!std.mem.eql(u8, instanceOf(p3.text), instanceOf(p4.text)));
    try std.testing.expectEqual(@as(u32, 3), gw.pool.spawnCount("fake"));

    // isError and images pass through unchanged.
    const f = try callJson(gw, a, "fake_fail", "{}");
    try std.testing.expect(f.is_error);
    try std.testing.expectEqualStrings("nope", f.text);
    const im = try callJson(gw, a, "fake_image", "{}");
    try std.testing.expect(!im.is_error);
    try std.testing.expectEqualStrings("pixel", im.text);
    try std.testing.expectEqualStrings("image/png", im.image.?.mime_type);
    try std.testing.expectEqualStrings("iVBORw0KGgo=", im.image.?.data_base64);

    gw.shutdown(io);
    try std.testing.expectEqual(@as(usize, 0), gw.pool.liveCount());
}

test "a call that outlives the timeout kills the child and the next call recovers" {
    const env = try Env.init(&.{});
    defer env.deinit();
    _ = boot.refresh(std.testing.io, &env.cat, env.real.locator, &env.real, &.{"fake"}, true, 10_000);
    const gw = try gateway.Gateway.init(alloc, &env.cat, &.{"fake"}, .{}, "", env.real.spawner(), .{}, .{
        .idle_ms = 0,
        .call_timeout_ms = 400,
    });
    defer gw.deinit(std.testing.io);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const t0 = Io.Timestamp.now(std.testing.io, .awake);
    const slow = try callJson(gw, a, "fake_slow", "{\"ms\":5000}");
    const t1 = Io.Timestamp.now(std.testing.io, .awake);
    try std.testing.expect(slow.is_error);
    try std.testing.expect(contains(slow.text, "did not answer within"));
    // Returned near the 400 ms timeout, not after the 5 s sleep.
    try std.testing.expect(t1.toMilliseconds() - t0.toMilliseconds() < 3000);
    try std.testing.expectEqual(@as(usize, 0), gw.pool.liveCount());
    const ok = try callJson(gw, a, "fake_echo", "{\"text\":\"again\"}");
    try std.testing.expectEqualStrings("echo:again", ok.text);
}

test "children inherit the environment minus gateway-only variables, plus their slice envs" {
    const env = try Env.init(&.{});
    defer env.deinit();
    _ = boot.refresh(std.testing.io, &env.cat, env.real.locator, &env.real, &.{"fake"}, true, 10_000);
    try env.real.plans.put(alloc, "fake", .{ .deny = "fake_crash", .readonly = true });
    const gw = try gateway.Gateway.init(alloc, &env.cat, &.{"fake"}, .{ .deny = &.{"fake_crash"}, .readonly = true }, "", env.real.spawner(), .{}, .{ .idle_ms = 0 });
    defer gw.deinit(std.testing.io);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const want = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "MY_API_KEY", .value = "k123" }, // inherited
        .{ .name = "ZMCP_HTTP_TOKEN", .value = "<unset>" },
        .{ .name = "ZMCP_HTTP", .value = "<unset>" },
        .{ .name = "ZMCP_GATEWAY_PROFILE", .value = "<unset>" },
        .{ .name = "ZMCP_TOOL_MODE", .value = "<unset>" },
        .{ .name = "ZMCP_TOOLS", .value = "<unset>" }, // outer value must not leak
        .{ .name = "ZMCP_TOOLS_DENY", .value = "fake_crash" }, // per-child slice env
        .{ .name = "ZMCP_READONLY", .value = "1" },
    };
    for (want) |w| {
        const args = try std.fmt.allocPrint(a, "{{\"name\":\"{s}\"}}", .{w.name});
        const r = try callJson(gw, a, "fake_env", args);
        try std.testing.expectEqualStrings(w.value, r.text);
    }
    // Read-only slice: unmarked tools are refused by the gateway.
    const blocked = try callJson(gw, a, "fake_fail", "{}");
    try std.testing.expect(blocked.is_error and contains(blocked.text, "not marked read-only"));
    const denied = try callJson(gw, a, "fake_crash", "{}");
    try std.testing.expect(denied.is_error and contains(denied.text, "disabled"));
}

test "a missing server binary is reported without crashing the gateway" {
    const env = try Env.init(&.{});
    defer env.deinit();
    _ = boot.refresh(std.testing.io, &env.cat, env.real.locator, &env.real, &.{"fake"}, true, 10_000);
    // Pretend the catalog knows a server whose binary is not installed.
    const entry = try catalog.entryFromToolsList(&env.cat, "ghost", "zmcp-ghost", 1, 1, "", "{\"result\":{\"tools\":[{\"name\":\"ghost_do\",\"description\":\"x\"}]}}");
    try env.cat.put(entry);
    const gw = try gateway.Gateway.init(alloc, &env.cat, &.{ "fake", "ghost" }, .{}, "", env.real.spawner(), .{}, .{ .idle_ms = 0 });
    defer gw.deinit(std.testing.io);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try callJson(gw, a, "ghost_do", "{}");
    try std.testing.expect(r.is_error and contains(r.text, "zmcp-ghost not found"));
    const ok = try callJson(gw, a, "fake_echo", "{\"text\":\"x\"}");
    try std.testing.expect(!ok.is_error);
}
