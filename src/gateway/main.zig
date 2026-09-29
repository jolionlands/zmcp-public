//! zmcp-gateway: one MCP endpoint that serves a named slice of the zmcp
//! servers while keeping context and memory tiny.
//!
//! The gateway does not link the servers. It spawns the real `zmcp-<name>`
//! binaries as stdio children on first use, keeps them warm, and reaps them
//! after an idle timeout. Tools are found through a static catalog, so
//! searching never starts anything. It reuses `mcp.run`, so it gets stdio,
//! ZMCP_HTTP hosting and ZMCP_MAX_RESULT_BYTES for free.
//!
//! Commands: serve (default), catalog, profiles, list, search, help.

const std = @import("std");
const mcp = @import("mcp");
const Io = std.Io;

const boot = @import("boot.zig");
const catalog = @import("catalog.zig");
const gateway = @import("gateway.zig");
const index_mod = @import("index.zig");
const pool_mod = @import("pool.zig");
const proc = @import("proc.zig");
const profile = @import("profile.zig");
const taxonomy = @import("taxonomy.zig");
const view_mod = @import("view.zig");

pub const version = "0.1.0";

test {
    _ = boot;
    _ = catalog;
    _ = gateway;
    _ = index_mod;
    _ = pool_mod;
    _ = proc;
    _ = profile;
    _ = taxonomy;
    _ = view_mod;
    _ = @import("e2e_test.zig");
}

const usage =
    \\zmcp-gateway - one MCP endpoint over a slice of the zmcp servers
    \\
    \\usage:
    \\  zmcp-gateway [serve] [--profile NAME] [--servers a,b,c] [--expose lazy|direct]
    \\  zmcp-gateway catalog [--out FILE]      (re)build the tool catalog
    \\  zmcp-gateway profiles                  list configured profiles
    \\  zmcp-gateway list [--profile NAME] [--servers a,b] [--tools]
    \\  zmcp-gateway search QUERY... [--profile NAME] [--servers a,b] [--category C] [--server S] [--limit N]
    \\
    \\environment: ZMCP_GATEWAY_PROFILE, _CONFIG, _CATALOG, _BIN_DIR, _EXPOSE,
    \\  _IDLE_SECS, _CALL_TIMEOUT_SECS, _MAX_CHILDREN; plus the usual ZMCP_HTTP*
    \\  and ZMCP_MAX_RESULT_BYTES. See the README.
    \\
;

const Command = enum { serve, catalog, profiles, list, search, help };

const Args = struct {
    cmd: Command = .serve,
    profile: ?[]const u8 = null,
    servers: ?[]const u8 = null,
    expose: ?[]const u8 = null,
    out: ?[]const u8 = null,
    tools: bool = false,
    category: ?[]const u8 = null,
    server: ?[]const u8 = null,
    limit: usize = 15,
    query: []const u8 = "",
};

const CliError = error{Usage};

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zmcp-gateway: error: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn parseArgs(a: std.mem.Allocator, argv: []const [:0]const u8) !Args {
    var out: Args = .{};
    var i: usize = 0;
    if (i < argv.len and !std.mem.startsWith(u8, argv[i], "-")) {
        out.cmd = std.meta.stringToEnum(Command, argv[i]) orelse {
            std.debug.print("zmcp-gateway: unknown command '{s}'\n\n{s}", .{ argv[i], usage });
            return error.Usage;
        };
        i += 1;
    }
    var query: std.ArrayList(u8) = .empty;
    while (i < argv.len) : (i += 1) {
        const arg: []const u8 = argv[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            out.cmd = .help;
            continue;
        }
        if (std.mem.eql(u8, arg, "--tools")) {
            out.tools = true;
            continue;
        }
        const takes_value = [_][]const u8{ "--profile", "--servers", "--expose", "--out", "--category", "--server", "--limit" };
        var is_opt = false;
        for (takes_value) |o| {
            if (std.mem.eql(u8, arg, o)) is_opt = true;
        }
        if (is_opt) {
            i += 1;
            if (i >= argv.len) {
                std.debug.print("zmcp-gateway: {s} needs a value\n", .{arg});
                return error.Usage;
            }
            const v: []const u8 = argv[i];
            if (std.mem.eql(u8, arg, "--profile")) out.profile = v;
            if (std.mem.eql(u8, arg, "--servers")) out.servers = v;
            if (std.mem.eql(u8, arg, "--expose")) out.expose = v;
            if (std.mem.eql(u8, arg, "--out")) out.out = v;
            if (std.mem.eql(u8, arg, "--category")) out.category = v;
            if (std.mem.eql(u8, arg, "--server")) out.server = v;
            if (std.mem.eql(u8, arg, "--limit")) {
                out.limit = std.fmt.parseInt(usize, v, 10) catch {
                    std.debug.print("zmcp-gateway: --limit must be a number\n", .{});
                    return error.Usage;
                };
            }
            continue;
        }
        if (out.cmd == .search and !std.mem.startsWith(u8, arg, "-")) {
            if (query.items.len > 0) try query.append(a, ' ');
            try query.appendSlice(a, arg);
            continue;
        }
        std.debug.print("zmcp-gateway: unknown argument '{s}'\n\n{s}", .{ arg, usage });
        return error.Usage;
    }
    out.query = query.items;
    return out;
}

/// Everything a command needs after startup: catalog (refreshed), the
/// resolved server list and the effective slice.
const Prepared = struct {
    settings: boot.Settings,
    paths: boot.Paths,
    loc: proc.Locator,
    cat: catalog.Catalog,
    servers: []const []const u8,
    slice: profile.Slice,
    label: []const u8,
    real: proc.RealSpawner,
};

/// Slice = profile rules, plus the gateway's own ZMCP_TOOLS_DENY /
/// ZMCP_READONLY (ZMCP_TOOLS only when the profile has no allowlist).
fn effectiveSlice(a: std.mem.Allocator, env: *const std.process.Environ.Map, base: profile.Slice) !profile.Slice {
    var sl = base;
    if (sl.allow.len == 0) sl.allow = try mcp.parseNameList(a, env.get("ZMCP_TOOLS"));
    if (env.get("ZMCP_TOOLS_DENY")) |d| {
        const extra = try mcp.parseNameList(a, d);
        if (extra.len > 0) {
            const merged = try a.alloc([]const u8, sl.deny.len + extra.len);
            @memcpy(merged[0..sl.deny.len], sl.deny);
            @memcpy(merged[sl.deny.len..], extra);
            sl.deny = merged;
        }
    }
    if (env.get("ZMCP_READONLY")) |r| {
        const t = std.mem.trim(u8, r, " \t\r\n");
        if (std.mem.eql(u8, t, "1") or std.ascii.eqlIgnoreCase(t, "true") or std.ascii.eqlIgnoreCase(t, "yes")) sl.readonly = true;
    }
    return sl;
}

fn prepare(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, env: *const std.process.Environ.Map, args: Args) !Prepared {
    const settings = boot.loadSettings(env);
    const paths = try boot.resolvePaths(io, arena, settings);
    const loc: proc.Locator = .{ .bin_dir = paths.bin_dir, .path_env = env.get("PATH") orelse "" };

    var diag: profile.Diag = .{};
    const profile_name = args.profile orelse settings.profile_name;
    var base_slice: profile.Slice = .{};
    var requested: []const []const u8 = &.{};
    var context: []const u8 = "--servers";
    var label: []const u8 = "";
    if (profile_name) |pn| {
        var cfg = boot.loadConfig(io, gpa, paths, &diag) catch fatal("{s}", .{diag.text()});
        if (cfg == null) fatal("profile '{s}' requested but there is no config file at {s} (set ZMCP_GATEWAY_CONFIG)", .{ pn, paths.config });
        // The profile's strings must outlive the config: copy what we keep.
        defer cfg.?.deinit();
        const p = cfg.?.find(pn) orelse {
            var names: std.ArrayList([]const u8) = .empty;
            for (cfg.?.profiles) |q| try names.append(arena, q.name);
            var near: [3][]const u8 = undefined;
            const n = profile.closest(pn, names.items, &near);
            if (n > 0) fatal("unknown profile '{s}'; closest: {s}", .{ pn, near[0] });
            fatal("unknown profile '{s}' (config: {s}; run `zmcp-gateway profiles`)", .{ pn, paths.config });
        };
        label = try arena.dupe(u8, p.name);
        requested = try dupeList(arena, p.servers);
        base_slice = .{ .allow = try dupeList(arena, p.slice.allow), .deny = try dupeList(arena, p.slice.deny), .readonly = p.slice.readonly };
        context = try std.fmt.allocPrint(arena, "profile '{s}'", .{p.name});
    }
    if (args.servers) |s| {
        requested = try mcp.parseNameList(arena, s);
        context = "--servers";
        if (requested.len == 0) fatal("--servers is empty", .{});
    }
    const slice = try effectiveSlice(arena, env, base_slice);

    var cat = boot.loadCatalog(io, gpa, paths.catalog) orelse try catalog.Catalog.init(gpa);
    errdefer cat.deinit();

    var known_list: std.ArrayList([]const u8) = .empty;
    for (try boot.availableServers(io, arena, loc, &cat)) |n| try known_list.append(arena, n);
    // Servers named explicitly may live on PATH without a catalog entry yet.
    for (requested) |r| {
        if (!profile.validServerName(r)) continue;
        var have = false;
        for (known_list.items) |k| {
            if (std.mem.eql(u8, k, r)) have = true;
        }
        if (!have) if (loc.locate(io, arena, r)) |f| {
            arena.free(f.path);
            try known_list.append(arena, try arena.dupe(u8, r));
        };
    }
    if (known_list.items.len == 0) {
        fatal("no zmcp-* server binaries found in {s} or on PATH (set ZMCP_GATEWAY_BIN_DIR)", .{paths.bin_dir});
    }
    const servers = profile.resolveServers(arena, requested, known_list.items, context, &diag) catch |e| switch (e) {
        error.UnknownServer, error.InvalidServerName => fatal("{s}", .{diag.text()}),
        else => return e,
    };

    var out_real: proc.RealSpawner = .{ .gpa = gpa, .locator = loc, .base_env = env };
    const rr = boot.refresh(io, &cat, loc, &out_real, servers, false, 30_000);
    if (rr.changed) _ = boot.saveCatalog(io, gpa, paths.catalog, &cat);

    // Per-child slicing envs (defense in depth).
    for (servers) |name| {
        const e = cat.find(name) orelse continue;
        try out_real.plans.put(gpa, try arena.dupe(u8, name), try proc.planFor(arena, slice, e.tools));
    }

    return .{
        .settings = settings,
        .paths = paths,
        .loc = loc,
        .cat = cat,
        .servers = servers,
        .slice = slice,
        .label = label,
        .real = out_real,
    };
}

fn dupeList(a: std.mem.Allocator, list: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, list.len);
    for (list, 0..) |s, i| out[i] = try a.dupe(u8, s);
    return out;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    const args = parseArgs(arena, argv[1..]) catch std.process.exit(2);

    switch (args.cmd) {
        .help => {
            std.debug.print("{s}", .{usage});
        },
        .profiles => try cmdProfiles(io, gpa, arena, init.environ_map),
        .catalog => try cmdCatalog(io, gpa, arena, init.environ_map, args),
        .list => try cmdList(io, gpa, arena, init.environ_map, args),
        .search => try cmdSearch(io, gpa, arena, init.environ_map, args),
        .serve => try cmdServe(io, gpa, arena, init.environ_map, args),
    }
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

fn stdoutWriter(io: Io, buf: []u8) Io.File.Writer {
    return .init(.stdout(), io, buf);
}

fn cmdProfiles(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, env: *const std.process.Environ.Map) !void {
    const settings = boot.loadSettings(env);
    const paths = try boot.resolvePaths(io, arena, settings);
    var diag: profile.Diag = .{};
    var cfg = (boot.loadConfig(io, gpa, paths, &diag) catch fatal("{s}", .{diag.text()})) orelse {
        std.debug.print("no profiles: no config file at {s} (set ZMCP_GATEWAY_CONFIG)\n", .{paths.config});
        return;
    };
    defer cfg.deinit();
    var buf: [4096]u8 = undefined;
    var w = stdoutWriter(io, &buf);
    const out = &w.interface;
    try out.print("config: {s}\n", .{paths.config});
    if (cfg.profiles.len == 0) try out.writeAll("(no profiles)\n");
    for (cfg.profiles) |p| {
        try out.print("{s}: ", .{p.name});
        if (p.servers.len == 0) try out.writeAll("all servers") else for (p.servers, 0..) |s, i| {
            if (i > 0) try out.writeAll(",");
            try out.writeAll(s);
        }
        if (p.slice.allow.len > 0) try out.print("  allow={d}", .{p.slice.allow.len});
        if (p.slice.deny.len > 0) try out.print("  deny={d}", .{p.slice.deny.len});
        if (p.slice.readonly) try out.writeAll("  readonly");
        try out.writeAll("\n");
    }
    try out.flush();
}

fn cmdCatalog(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, env: *const std.process.Environ.Map, args: Args) !void {
    const settings = boot.loadSettings(env);
    const paths = try boot.resolvePaths(io, arena, settings);
    const loc: proc.Locator = .{ .bin_dir = paths.bin_dir, .path_env = env.get("PATH") orelse "" };
    var cat = try catalog.Catalog.init(gpa);
    defer cat.deinit();
    var real: proc.RealSpawner = .{ .gpa = gpa, .locator = loc, .base_env = env };
    defer real.plans.deinit(gpa);
    const names = try loc.scan(io, arena);
    if (names.len == 0) fatal("no zmcp-* server binaries found in {s} (set ZMCP_GATEWAY_BIN_DIR)", .{paths.bin_dir});
    const res = boot.refresh(io, &cat, loc, &real, names, true, 30_000);
    const path = args.out orelse paths.catalog;
    if (!boot.saveCatalog(io, gpa, path, &cat)) std.process.exit(1);
    var buf: [512]u8 = undefined;
    var w = stdoutWriter(io, &buf);
    try w.interface.print("wrote {s}: {d} servers, {d} tools ({d} failed)\n", .{ path, cat.servers.items.len, cat.toolCount(), res.failed });
    try w.interface.flush();
}

fn approxCost(t: catalog.Tool) usize {
    return t.name.len + mcp.firstSentence(t.description, mcp.TOOL_DESC_CAP).len + t.schema.len + 45;
}

fn cmdList(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, env: *const std.process.Environ.Map, args: Args) !void {
    var prep = try prepare(io, gpa, arena, env, args);
    defer prep.cat.deinit();
    defer prep.real.plans.deinit(gpa);
    var view = try view_mod.View.build(gpa, &prep.cat, prep.servers, prep.slice);
    defer view.deinit();

    var buf: [4096]u8 = undefined;
    var w = stdoutWriter(io, &buf);
    const out = &w.interface;
    try out.print("slice: {s}  servers: {d}  tools: {d} of {d}\n", .{ if (prep.label.len > 0) prep.label else "(ad hoc / all)", view.servers.len, view.exposed.len, view.total_before_slice });
    var total_cost: usize = 0;
    for (view.servers) |sname| {
        var n: usize = 0;
        var cost: usize = 0;
        for (view.exposed) |e| {
            if (!std.mem.eql(u8, e.server, sname)) continue;
            n += 1;
            cost += approxCost(e.tool.*);
        }
        total_cost += cost;
        const cat_name = if (prep.cat.find(sname)) |s| (if (s.tools.len > 0) s.tools[0].category.text() else "-") else "-";
        try out.print("  {s} [{s}]: {d} tools, ~{d} bytes as direct tools/list\n", .{ sname, cat_name, n, cost });
        if (args.tools) for (view.exposed) |e| {
            if (!std.mem.eql(u8, e.server, sname)) continue;
            try out.print("      {s}{s} ~{d}\n", .{ e.name, if (e.tool.read_only) " (ro)" else "", approxCost(e.tool.*) });
        };
    }
    try out.print("total: ~{d} bytes if exposed directly (compact); lazy mode advertises 3 tools (~1 KB)\n", .{total_cost});
    if (prep.slice.readonly and view.exposed.len == 0) {
        try out.print("readonly slice is empty: none of the {d} tools in these servers is marked read-only (annotations.readOnlyHint)\n", .{view.total_before_slice});
    } else if (prep.slice.readonly) {
        try out.print("readonly: {d} of {d} tools are marked read-only\n", .{ view.read_only_marked, view.total_before_slice });
    }
    if (view.namespacedCount() > 0) try out.print("note: {d} tool names collide across servers and are namespaced as server.tool\n", .{view.namespacedCount()});
    try out.flush();
}

fn cmdSearch(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, env: *const std.process.Environ.Map, args: Args) !void {
    var prep = try prepare(io, gpa, arena, env, args);
    defer prep.cat.deinit();
    defer prep.real.plans.deinit(gpa);
    var view = try view_mod.View.build(gpa, &prep.cat, prep.servers, prep.slice);
    defer view.deinit();
    var ix = try index_mod.Index.build(gpa, &view);
    defer ix.deinit();

    var q: index_mod.Query = .{ .text = args.query, .server = args.server, .limit = args.limit };
    if (args.category) |c| q.category = taxonomy.Category.parse(c) orelse fatal("unknown category '{s}'", .{c});
    var buf: [8192]u8 = undefined;
    var w = stdoutWriter(io, &buf);
    const out = &w.interface;
    const t0 = Io.Timestamp.now(io, .awake);
    var qa = std.heap.ArenaAllocator.init(gpa);
    defer qa.deinit();
    const text = if (args.query.len == 0 and q.server == null and q.category == null)
        try ix.renderOverview(qa.allocator(), prep.label)
    else blk: {
        const hits = try ix.search(qa.allocator(), q);
        break :blk if (hits.len == 0) try ix.renderNoMatch(qa.allocator(), q) else try ix.renderHits(qa.allocator(), hits, q);
    };
    const t1 = Io.Timestamp.now(io, .awake);
    try out.print("{s}\n", .{text});
    try out.flush();
    const us = @divTrunc(t1.nanoseconds - t0.nanoseconds, 1000);
    std.debug.print("({d} tools indexed, {d} bytes, {d} us)\n", .{ view.exposed.len, text.len, us });
}

fn reaperLoop(gw: *gateway.Gateway, io: Io, interval_ms: u64) void {
    while (true) {
        io.sleep(Io.Duration.fromMilliseconds(@intCast(interval_ms)), .awake) catch return;
        _ = gw.reapTick(io);
    }
}

fn cmdServe(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, env: *const std.process.Environ.Map, args: Args) !void {
    var prep = try prepare(io, gpa, arena, env, args);
    defer prep.cat.deinit();
    defer prep.real.plans.deinit(gpa);
    const expose = gateway.Expose.parse(args.expose orelse prep.settings.expose_text);

    const gw = try gateway.Gateway.init(gpa, &prep.cat, prep.servers, prep.slice, prep.label, prep.real.spawner(), .{}, boot.poolOptions(prep.settings));
    defer gw.deinit(io);
    gateway.setGlobal(gw);
    defer gateway.setGlobal(null);
    // Children die with the gateway: stdin EOF, normal exit, or (via their
    // own stdin closing) a crash of the gateway.
    defer gw.shutdown(io);

    std.debug.print("zmcp-gateway: serving {d} tools from {d} servers{s}{s} ({s} mode)\n", .{
        gw.view.exposed.len,
        gw.view.servers.len,
        if (prep.label.len > 0) " of profile " else "",
        prep.label,
        @tagName(expose),
    });
    if (prep.slice.readonly and gw.view.exposed.len == 0) {
        std.debug.print("zmcp-gateway: warning: readonly slice is empty: none of the {d} tools in these servers is marked read-only (annotations.readOnlyHint)\n", .{gw.view.total_before_slice});
    }

    if (prep.settings.idle_secs > 0) {
        const interval = @max(@as(u64, 250), @min(@as(u64, 5000), prep.settings.idle_secs * 1000 / 4));
        if (std.Thread.spawn(.{}, reaperLoop, .{ gw, io, interval })) |t| t.detach() else |_| {}
    }

    var tool_arena = std.heap.ArenaAllocator.init(gpa);
    defer tool_arena.deinit();
    const info: mcp.ServerInfo = .{ .name = "zmcp-gateway", .version = version };
    switch (expose) {
        .lazy => {
            const tools = try gateway.lazyTools(tool_arena.allocator(), gw);
            try mcp.runWithExtras(gpa, io, info, tools, .{ .mode = .full, .ignore_slice_env = true });
        },
        .direct => {
            const tools = try gateway.directTools(tool_arena.allocator(), gw);
            try mcp.runWithExtras(gpa, io, info, tools, .{
                .mode = .compact,
                .ignore_slice_env = true,
                .hook = gateway.directHook,
                .hook_ctx = gw,
            });
        },
    }
}
