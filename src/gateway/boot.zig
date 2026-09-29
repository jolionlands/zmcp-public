//! Startup plumbing: settings from the environment, catalog file load /
//! refresh / save, config file load, and turning a profile or --servers list
//! into a resolved slice. All diagnostics go to stderr.

const std = @import("std");
const Io = std.Io;
const catalog = @import("catalog.zig");
const profile = @import("profile.zig");
const pool_mod = @import("pool.zig");
const proc = @import("proc.zig");

pub const Settings = struct {
    idle_secs: u64 = 300,
    call_timeout_secs: u64 = 120,
    max_children: usize = 8,
    profile_name: ?[]const u8 = null,
    config_path: ?[]const u8 = null,
    catalog_path: ?[]const u8 = null,
    bin_dir: ?[]const u8 = null,
    expose_text: ?[]const u8 = null,
};

fn envInt(env: *const std.process.Environ.Map, key: []const u8, default: u64) u64 {
    const v = env.get(key) orelse return default;
    return std.fmt.parseInt(u64, std.mem.trim(u8, v, " \t\r\n"), 10) catch default;
}

fn envStr(env: *const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const v = env.get(key) orelse return null;
    const t = std.mem.trim(u8, v, " \t\r\n");
    return if (t.len == 0) null else t;
}

/// ZMCP_GATEWAY_* settings. Slices point into `env`.
pub fn loadSettings(env: *const std.process.Environ.Map) Settings {
    return .{
        .idle_secs = envInt(env, "ZMCP_GATEWAY_IDLE_SECS", 300),
        .call_timeout_secs = @max(envInt(env, "ZMCP_GATEWAY_CALL_TIMEOUT_SECS", 120), 1),
        .max_children = @intCast(@max(envInt(env, "ZMCP_GATEWAY_MAX_CHILDREN", 8), 1)),
        .profile_name = envStr(env, "ZMCP_GATEWAY_PROFILE"),
        .config_path = envStr(env, "ZMCP_GATEWAY_CONFIG"),
        .catalog_path = envStr(env, "ZMCP_GATEWAY_CATALOG"),
        .bin_dir = envStr(env, "ZMCP_GATEWAY_BIN_DIR"),
        .expose_text = envStr(env, "ZMCP_GATEWAY_EXPOSE"),
    };
}

pub fn poolOptions(s: Settings) pool_mod.Options {
    return .{
        .idle_ms = s.idle_secs * 1000,
        .max_live = s.max_children,
        .call_timeout_ms = s.call_timeout_secs * 1000,
    };
}

pub const Paths = struct {
    exe_dir: []const u8,
    bin_dir: []const u8,
    catalog: []const u8,
    config: []const u8,
    config_explicit: bool,
};

/// Resolve directories and file locations. Strings are owned by `a`.
pub fn resolvePaths(io: Io, a: std.mem.Allocator, s: Settings) !Paths {
    const exe_dir = std.process.executableDirPathAlloc(io, a) catch try a.dupe(u8, "");
    return .{
        .exe_dir = exe_dir,
        .bin_dir = if (s.bin_dir) |d| d else exe_dir,
        .catalog = if (s.catalog_path) |p| p else try std.fs.path.join(a, &.{ exe_dir, "catalog.json" }),
        .config = if (s.config_path) |p| p else try std.fs.path.join(a, &.{ exe_dir, "gateway.json" }),
        .config_explicit = s.config_path != null,
    };
}

fn logf(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("zmcp-gateway: " ++ fmt ++ "\n", args);
}

// ---------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------

const MAX_FILE_BYTES = 32 * 1024 * 1024;

/// The catalog at `path`, or null when the file is missing or unusable.
pub fn loadCatalog(io: Io, gpa: std.mem.Allocator, path: []const u8) ?catalog.Catalog {
    const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(MAX_FILE_BYTES)) catch |e| {
        if (e != error.FileNotFound) logf("cannot read catalog {s}: {s}", .{ path, @errorName(e) });
        return null;
    };
    defer gpa.free(text);
    return catalog.parse(gpa, text) catch |e| {
        logf("catalog {s} is not usable ({s}); rebuilding", .{ path, @errorName(e) });
        return null;
    };
}

/// Best effort: a read-only install dir just means the catalog is rebuilt in
/// memory on every start.
pub fn saveCatalog(io: Io, gpa: std.mem.Allocator, path: []const u8, cat: *const catalog.Catalog) bool {
    const text = catalog.toOwnedText(gpa, cat) catch return false;
    defer gpa.free(text);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch |e| {
        logf("cannot write catalog {s}: {s}", .{ path, @errorName(e) });
        return false;
    };
    return true;
}

/// Parsed config, or null when there is no config file (an error only when
/// the path was given explicitly).
pub fn loadConfig(io: Io, gpa: std.mem.Allocator, paths: Paths, diag: *profile.Diag) !?profile.Config {
    const text = Io.Dir.cwd().readFileAlloc(io, paths.config, gpa, .limited(MAX_FILE_BYTES)) catch |e| switch (e) {
        error.FileNotFound => {
            if (paths.config_explicit) {
                diag.set("config file {s} not found (ZMCP_GATEWAY_CONFIG)", .{paths.config});
                return error.InvalidConfig;
            }
            return null;
        },
        else => {
            diag.set("cannot read config {s}: {s}", .{ paths.config, @errorName(e) });
            return error.InvalidConfig;
        },
    };
    defer gpa.free(text);
    return profile.parseConfig(gpa, text, diag) catch |e| switch (e) {
        error.InvalidConfig => return error.InvalidConfig,
        else => return e,
    };
}

// ---------------------------------------------------------------------------
// Catalog refresh
// ---------------------------------------------------------------------------

/// Spawn `name` once, run tools/list and return the catalog entry. `pl` is a
/// scratch pool over the real spawner; the child is closed afterwards.
fn fetchEntry(io: Io, cat: *catalog.Catalog, pl: *pool_mod.Pool, loc: proc.Locator, name: []const u8) !catalog.Server {
    const found = loc.locate(io, cat.gpa, name) orelse return error.NotFound;
    defer cat.gpa.free(found.path);
    var arena = std.heap.ArenaAllocator.init(cat.gpa);
    defer arena.deinit();
    const line = try pl.request(io, arena.allocator(), name, "tools/list", "{}");
    const bin = try proc.Locator.fileName(arena.allocator(), name);
    return catalog.entryFromToolsList(cat, name, bin, found.size, found.mtime_ms, "", line);
}

pub const RefreshResult = struct { changed: bool = false, failed: usize = 0 };

/// Bring the entries for `names` up to date: missing or fingerprint-stale
/// ones (or all of them when `force`) are rebuilt by spawning the binary
/// once. A server that fails to answer is skipped with a warning.
pub fn refresh(
    io: Io,
    cat: *catalog.Catalog,
    loc: proc.Locator,
    real: *proc.RealSpawner,
    names: []const []const u8,
    force: bool,
    timeout_ms: u64,
) RefreshResult {
    var res: RefreshResult = .{};
    var pl = pool_mod.Pool.init(cat.gpa, real.spawner(), .{}, .{
        .idle_ms = 0,
        .max_live = 1,
        .call_timeout_ms = timeout_ms,
        .handshake_timeout_ms = timeout_ms,
        .max_spawn_attempts = 1,
    });
    defer pl.deinit(io);
    for (names) |name| {
        const found = loc.locate(io, cat.gpa, name) orelse continue;
        cat.gpa.free(found.path);
        if (!force) {
            if (cat.find(name)) |e| if (e.matches(found.size, found.mtime_ms)) continue;
        }
        logf("cataloging {s}", .{name});
        const entry = fetchEntry(io, cat, &pl, loc, name) catch |e| {
            logf("warning: could not catalog {s}: {s}", .{ name, @errorName(e) });
            res.failed += 1;
            continue;
        };
        cat.put(entry) catch {
            res.failed += 1;
            continue;
        };
        res.changed = true;
        pl.shutdown(io);
    }
    return res;
}

/// Server names that can be served now: `zmcp-*` binaries in the bin dir
/// plus catalog entries whose binary is found on PATH. Sorted, unique.
pub fn availableServers(io: Io, a: std.mem.Allocator, loc: proc.Locator, cat: *const catalog.Catalog) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try loc.scan(io, a)) |n| try out.append(a, n);
    for (cat.servers.items) |s| {
        var have = false;
        for (out.items) |o| {
            if (std.mem.eql(u8, o, s.name)) have = true;
        }
        if (have) continue;
        if (loc.locate(io, a, s.name)) |f| {
            a.free(f.path);
            try out.append(a, s.name);
        }
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return out.items;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "loadSettings defaults and overrides" {
    const alloc = std.testing.allocator;
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    const d = loadSettings(&env);
    try std.testing.expectEqual(@as(u64, 300), d.idle_secs);
    try std.testing.expectEqual(@as(u64, 120), d.call_timeout_secs);
    try std.testing.expectEqual(@as(usize, 8), d.max_children);
    try std.testing.expect(d.profile_name == null);

    try env.put("ZMCP_GATEWAY_IDLE_SECS", "7");
    try env.put("ZMCP_GATEWAY_CALL_TIMEOUT_SECS", "0"); // clamped to >= 1
    try env.put("ZMCP_GATEWAY_MAX_CHILDREN", "3");
    try env.put("ZMCP_GATEWAY_PROFILE", " dev ");
    try env.put("ZMCP_GATEWAY_EXPOSE", "direct");
    try env.put("ZMCP_GATEWAY_BIN_DIR", "");
    const s = loadSettings(&env);
    try std.testing.expectEqual(@as(u64, 7), s.idle_secs);
    try std.testing.expectEqual(@as(u64, 1), s.call_timeout_secs);
    try std.testing.expectEqual(@as(usize, 3), s.max_children);
    try std.testing.expectEqualStrings("dev", s.profile_name.?);
    try std.testing.expect(s.bin_dir == null); // empty = unset
    const po = poolOptions(s);
    try std.testing.expectEqual(@as(u64, 7000), po.idle_ms);
    try std.testing.expectEqual(@as(usize, 3), po.max_live);
    try env.put("ZMCP_GATEWAY_IDLE_SECS", "junk");
    try std.testing.expectEqual(@as(u64, 300), loadSettings(&env).idle_secs);
}
