//! zmcp-freejobs — provider router + CLI worker bridge MCP server.
//!
//! Adapted from an earlier private bridge, task pipeline, CLI tool registry
//! and provider table (the author's own code) to Zig 0.16 and the
//! single-file zmcp tool layout. No vault dependency; API keys read from env.
//!
//! Concurrency note: zmcp's mcp.run is single-threaded (one stdin line at a
//! time), so all server-global state lives in plain globals without mutexes.
//! If the framework ever grows worker threads this needs revisiting.
//!
//! MCP tools exposed:
//!   route_free        — pick a free-tier provider, call its chat endpoint
//!   route_standard    — pick a standard-tier provider, may fall back to free
//!   route_premium     — pick a premium-tier provider, may fall back lower
//!   bridge_spawn      — spawn a CLI worker (kilo|kimi|qwen|opencode|gemini)
//!   bridge_list       — list running CLI workers
//!   bridge_kill       — kill a CLI worker by name
//!   worker_run        — one-shot run a CLI worker with a prompt
//!   providers_list    — show provider catalog (tier filter optional)
//!   providers_health  — show EWMA health + last error per provider
//!
//! State files (JSONL, append-only):
//!   ~/.pi/agent/freejobs/health.jsonl   per-event health observations
//!   ~/.pi/agent/freejobs/quotas.jsonl   per-tier daily counters
//!   ~/.pi/agent/freejobs/workers.jsonl  CLI worker spawn/exit events

const std = @import("std");
const mcp = @import("mcp");



// ===========================================================================
// Tier / provider tables (static — no allocations)
// ===========================================================================

pub const Tier = enum {
    free,
    standard,
    premium,

    pub fn fromString(s: []const u8) ?Tier {
        if (std.mem.eql(u8, s, "free")) return .free;
        if (std.mem.eql(u8, s, "standard")) return .standard;
        if (std.mem.eql(u8, s, "premium")) return .premium;
        return null;
    }

    pub fn toString(self: Tier) []const u8 {
        return switch (self) {
            .free => "free",
            .standard => "standard",
            .premium => "premium",
        };
    }
};

/// Catalog entry. Static — defined at comptime; no allocations needed.
pub const Provider = struct {
    name: []const u8,
    default_model: []const u8,
    api_base: []const u8,
    /// env-var holding the API key. Empty string means "no auth needed".
    api_key_env: []const u8,
    /// $ per 1K tokens (0.0 = free).
    cost_per_1k: f32,
    /// Approximate per-day quota — informational only.
    daily_quota_note: []const u8,
};

pub const provider_catalog = [_]Provider{
    .{ .name = "groq", .default_model = "llama-3.3-70b-versatile", .api_base = "https://api.groq.com/openai/v1", .api_key_env = "GROQ_API_KEY", .cost_per_1k = 0.0, .daily_quota_note = "FREE ~70K TPM" },
    .{ .name = "cerebras", .default_model = "qwen-3-235b-a22b-instruct-2507", .api_base = "https://api.cerebras.ai/v1", .api_key_env = "CEREBRAS_API_KEY", .cost_per_1k = 0.0, .daily_quota_note = "FREE ~1M tokens/day" },
    .{ .name = "sambanova", .default_model = "Meta-Llama-3.1-70B-Instruct", .api_base = "https://api.sambanova.ai/v1", .api_key_env = "SAMBANOVA_API_KEY", .cost_per_1k = 0.0, .daily_quota_note = "FREE 10M tokens/day" },
    .{ .name = "together", .default_model = "meta-llama/Llama-3.3-70B-Instruct-Turbo", .api_base = "https://api.together.xyz/v1", .api_key_env = "TOGETHER_API_KEY", .cost_per_1k = 0.001, .daily_quota_note = "FREE 1K req/day" },
    .{ .name = "fireworks", .default_model = "accounts/fireworks/models/llama-v3p3-70b-instruct", .api_base = "https://api.fireworks.ai/inference/v1", .api_key_env = "FIREWORKS_API_KEY", .cost_per_1k = 0.001, .daily_quota_note = "FREE 100 RPM" },
    .{ .name = "cloudflare", .default_model = "@cf/meta/llama-3.1-70b-instruct", .api_base = "https://api.cloudflare.com/client/v4/ai", .api_key_env = "CLOUDFLARE_API_TOKEN", .cost_per_1k = 0.0, .daily_quota_note = "FREE 10K neurons/day" },
    .{ .name = "openrouter", .default_model = "deepseek-ai/deepseek-v3:free", .api_base = "https://openrouter.ai/api/v1", .api_key_env = "OPENROUTER_API_KEY", .cost_per_1k = 0.0, .daily_quota_note = "FREE 200 req/day" },
    .{ .name = "ai21", .default_model = "jamba-1.5-large", .api_base = "https://api.ai21.com/studio/v1", .api_key_env = "AI21_API_KEY", .cost_per_1k = 0.0, .daily_quota_note = "FREE 1K req/day, 256K ctx" },
    .{ .name = "hyperbolic", .default_model = "meta-llama/Meta-Llama-3.1-70B-Instruct", .api_base = "https://api.hyperbolic.xyz/v1", .api_key_env = "HYPERBOLIC_API_KEY", .cost_per_1k = 0.0005, .daily_quota_note = "FREE tier available" },
    .{ .name = "deepinfra", .default_model = "meta-llama/Meta-Llama-3.1-70B-Instruct", .api_base = "https://api.deepinfra.com/v1/openai", .api_key_env = "DEEPINFRA_API_KEY", .cost_per_1k = 0.0005, .daily_quota_note = "FREE tier limited" },
    .{ .name = "codestral", .default_model = "codestral-latest", .api_base = "https://codestral.mistral.ai/v1", .api_key_env = "CODESTRAL_API_KEY", .cost_per_1k = 0.002, .daily_quota_note = "FREE 50K TPM / 4M/month" },
    .{ .name = "mistral", .default_model = "mistral-small-latest", .api_base = "https://api.mistral.ai/v1", .api_key_env = "MISTRAL_API_KEY", .cost_per_1k = 0.003, .daily_quota_note = "Experiment tier free" },
    .{ .name = "nvidia_nim", .default_model = "moonshotai/kimi-k2.5", .api_base = "https://integrate.api.nvidia.com/v1", .api_key_env = "NVIDIA_NIM_API_KEY", .cost_per_1k = 0.005, .daily_quota_note = "FREE 1K credits on signup" },
    .{ .name = "xai", .default_model = "grok-4.20", .api_base = "https://api.x.ai/v1", .api_key_env = "XAI_API_KEY", .cost_per_1k = 0.005, .daily_quota_note = "$25 free credits on signup" },
    .{ .name = "openai", .default_model = "gpt-4o-mini", .api_base = "https://api.openai.com/v1", .api_key_env = "OPENAI_API_KEY", .cost_per_1k = 0.01, .daily_quota_note = "Paid" },
    .{ .name = "minimax", .default_model = "MiniMax-2.7", .api_base = "https://api.minimaxi.chat/v1", .api_key_env = "MINIMAX_API_KEY", .cost_per_1k = 0.002, .daily_quota_note = "Paid" },
    .{ .name = "perplexity", .default_model = "sonar", .api_base = "https://api.perplexity.ai", .api_key_env = "PERPLEXITY_API_KEY", .cost_per_1k = 0.005, .daily_quota_note = "$5 free credits on signup" },
    .{ .name = "cohere", .default_model = "command-a-reasoning-08-2025", .api_base = "https://api.cohere.ai/v2", .api_key_env = "COHERE_API_KEY", .cost_per_1k = 0.003, .daily_quota_note = "FREE 20 RPM" },
    .{ .name = "anyscale", .default_model = "meta-llama/Meta-Llama-3.1-70B-Instruct", .api_base = "https://api.endpoints.anyscale.com/v1", .api_key_env = "ANYSCALE_API_KEY", .cost_per_1k = 0.001, .daily_quota_note = "FREE 50 RPM" },
    .{ .name = "octoai", .default_model = "meta-llama-3.1-70b-instruct", .api_base = "https://text.octoai.run/v1", .api_key_env = "OCTOAI_API_TOKEN", .cost_per_1k = 0.001, .daily_quota_note = "FREE tier on signup" },
};

pub const TierConfig = struct {
    tier: Tier,
    max_cost_per_1k: f32,
    daily_request_cap: u32,
    daily_token_cap: u64,
    preferred: []const []const u8,
};

pub const tier_configs = [_]TierConfig{
    .{
        .tier = .free,
        // 0.001 allows Together + Fireworks (which offer free-tier rate
        // limits even though their default models are listed at $0.001/1K).
        // The free-tier discrimination still happens at the API level — if
        // a key isn't set or the daily quota is exhausted, we skip.
        .max_cost_per_1k = 0.001,
        .daily_request_cap = 5000,
        .daily_token_cap = 10_000_000,
        .preferred = &.{
            "groq",       "cerebras",   "sambanova", "together",
            "fireworks",  "cloudflare", "openrouter", "ai21",
        },
    },
    .{
        .tier = .standard,
        .max_cost_per_1k = 0.01,
        .daily_request_cap = 10000,
        .daily_token_cap = 50_000_000,
        .preferred = &.{
            "groq",      "together", "fireworks",  "openrouter",
            "deepinfra", "hyperbolic", "codestral",
        },
    },
    .{
        .tier = .premium,
        .max_cost_per_1k = 0.10,
        .daily_request_cap = 5000,
        .daily_token_cap = 20_000_000,
        .preferred = &.{
            "nvidia_nim", "mistral", "xai",       "openai",
            "perplexity", "ai21",    "minimax",
        },
    },
};

fn lookupProvider(name: []const u8) ?Provider {
    for (provider_catalog) |p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

fn lookupTier(t: Tier) TierConfig {
    for (tier_configs) |tc| {
        if (tc.tier == t) return tc;
    }
    return tier_configs[0];
}

// ===========================================================================
// Globals (set in main; used by handlers)
// ===========================================================================

var g_io: std.Io = undefined;
/// Process-lifetime allocator. Worker map + health map must outlive per-call
/// arenas, so we hold a long-lived heap allocator here.
var g_alloc: std.mem.Allocator = undefined;

// ===========================================================================
// Worker registry
// ===========================================================================

pub const Worker = struct {
    name: []u8, // alloc-owned
    tool: []u8, // alloc-owned: "kilo" | "kimi" | "qwen" | "opencode" | "gemini"
    model: []u8, // alloc-owned (may be empty)
    spawned_ms: i64,
    child: *std.process.Child,
};

var g_workers: std.StringHashMapUnmanaged(*Worker) = .empty;

fn freeWorker(alloc: std.mem.Allocator, w: *Worker) void {
    alloc.free(w.name);
    alloc.free(w.tool);
    alloc.free(w.model);
    alloc.destroy(w.child);
    alloc.destroy(w);
}

// ===========================================================================
// Time helper
// ===========================================================================

fn nowMs() i64 {
    return std.Io.Timestamp.now(g_io, .real).toMilliseconds();
}

// ===========================================================================
// Env helpers
// ===========================================================================

fn getEnvOwned(alloc: std.mem.Allocator, key: []const u8) ?[]u8 {
    return mcp.envAlloc(alloc, g_io, key);
}

/// Runtime env-var check (containsConstant requires comptime key).
fn hasEnv(key: []const u8) bool {
    const tmp = getEnvOwned(g_alloc, key) orelse return false;
    g_alloc.free(tmp);
    return true;
}

// ===========================================================================
// Storage helpers — append-only JSONL under ~/.pi/agent/freejobs/
// ===========================================================================

fn getHomeDir(alloc: std.mem.Allocator) ![]u8 {
    if (getEnvOwned(alloc, "USERPROFILE")) |v| return v;
    if (getEnvOwned(alloc, "HOME")) |v| return v;
    return error.NoHomeDir;
}

/// Open (creating if necessary) the freejobs state directory.
fn openStateDir(io: std.Io, alloc: std.mem.Allocator) !std.Io.Dir {
    const home = try getHomeDir(alloc);
    defer alloc.free(home);

    var cwd = std.Io.Dir.cwd();
    const path = try std.fs.path.join(alloc, &.{ home, ".pi", "agent", "freejobs" });
    defer alloc.free(path);

    return cwd.createDirPathOpen(io, path, .{});
}

fn appendJsonl(io: std.Io, alloc: std.mem.Allocator, name: []const u8, line: []const u8) !void {
    var dir = openStateDir(io, alloc) catch return;
    defer dir.close(io);

    var file = dir.openFile(io, name, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => try dir.createFile(io, name, .{ .read = false }),
        else => return err,
    };
    defer file.close(io);

    // Locate end-of-file via stat; if stat fails (rare on a fresh handle),
    // fall back to pos=0 — worst case the freshly-created file gets a
    // first-line entry which is still useful.
    const end_pos: u64 = if (file.stat(io)) |st| st.size else |_| 0;
    var buf: [4096]u8 = undefined;
    var fw: std.Io.File.Writer = .init(file, io, &buf);
    fw.pos = end_pos;
    try fw.interface.writeAll(line);
    try fw.interface.writeAll("\n");
    try fw.interface.flush();
}

// ===========================================================================
// Health state (in-memory EWMA)
// ===========================================================================

pub const HealthEntry = struct {
    success_rate: f32 = 1.0, // EWMA
    avg_latency_ms: u64 = 0,
    consecutive_failures: u32 = 0,
    last_check_ms: i64 = 0,
    last_error: ?[]u8 = null, // alloc-owned (g_alloc)
};

var g_health: std.StringHashMapUnmanaged(HealthEntry) = .empty;

fn getHealth(name: []const u8) HealthEntry {
    return g_health.get(name) orelse .{};
}

fn isHealthy(name: []const u8) bool {
    const h = getHealth(name);
    if (h.consecutive_failures >= 3) return false;
    return h.success_rate >= 0.5;
}

fn observe(name: []const u8, success: bool, latency_ms: u64, err_msg: ?[]const u8) void {
    var entry = g_health.get(name) orelse HealthEntry{};

    if (success) {
        entry.consecutive_failures = 0;
        entry.success_rate = entry.success_rate * 0.9 + 0.1;
    } else {
        entry.consecutive_failures += 1;
        entry.success_rate = entry.success_rate * 0.9;
    }
    if (entry.avg_latency_ms == 0) {
        entry.avg_latency_ms = latency_ms;
    } else {
        entry.avg_latency_ms = (entry.avg_latency_ms * 9 + latency_ms) / 10;
    }
    entry.last_check_ms = nowMs();

    if (err_msg) |em| {
        if (entry.last_error) |old| g_alloc.free(old);
        entry.last_error = g_alloc.dupe(u8, em) catch null;
    }

    if (g_health.getKey(name)) |existing| {
        g_health.put(g_alloc, existing, entry) catch return;
    } else {
        const key = g_alloc.dupe(u8, name) catch return;
        g_health.put(g_alloc, key, entry) catch {
            g_alloc.free(key);
            return;
        };
    }
}

// ===========================================================================
// Quota state (in-memory per-tier daily counters)
// ===========================================================================

const TierUsage = struct {
    requests_today: u64 = 0,
    tokens_today: u64 = 0,
    last_reset_unix: i64 = 0,
};

var g_quotas: std.EnumArray(Tier, TierUsage) = .init(.{
    .free = .{},
    .standard = .{},
    .premium = .{},
});

fn checkAndResetDaily(tier: Tier) void {
    var u = g_quotas.get(tier);
    const now_unix = @divFloor(nowMs(), 1000);
    const day = 24 * 60 * 60;
    if (now_unix - u.last_reset_unix >= day) {
        u.requests_today = 0;
        u.tokens_today = 0;
        u.last_reset_unix = now_unix;
        g_quotas.set(tier, u);
    }
}

fn quotaOk(tier: Tier) bool {
    checkAndResetDaily(tier);
    const u = g_quotas.get(tier);
    const cfg = lookupTier(tier);
    if (u.requests_today >= cfg.daily_request_cap) return false;
    if (u.tokens_today >= cfg.daily_token_cap) return false;
    return true;
}

fn quotaCharge(tier: Tier, tokens: u64) void {
    var u = g_quotas.get(tier);
    u.requests_today += 1;
    u.tokens_today += tokens;
    g_quotas.set(tier, u);
}

// ===========================================================================
// Routing
// ===========================================================================

const RoutePick = struct {
    provider: Provider,
    tier_used: Tier,
    fell_back: bool,
};

fn route(tier_in: Tier) ?RoutePick {
    const tiers_to_try: []const Tier = switch (tier_in) {
        .free => &.{.free},
        .standard => &.{ .standard, .free },
        .premium => &.{ .premium, .standard, .free },
    };

    for (tiers_to_try, 0..) |tier, i| {
        if (!quotaOk(tier)) continue;
        const cfg = lookupTier(tier);
        for (cfg.preferred) |provider_name| {
            const p = lookupProvider(provider_name) orelse continue;

            if (p.cost_per_1k > cfg.max_cost_per_1k) continue;
            if (!isHealthy(p.name)) continue;

            if (p.api_key_env.len > 0 and !hasEnv(p.api_key_env)) continue;

            return .{
                .provider = p,
                .tier_used = tier,
                .fell_back = i > 0,
            };
        }
    }
    return null;
}

// ===========================================================================
// HTTP completion (OpenAI-compatible)
// ===========================================================================

const user_agent = "zmcp-freejobs/0.1.0";

const Completion = struct {
    content: []u8, // alloc-owned
    tokens_used: u32,
    latency_ms: u64,
};

/// Scratch for the last HTTP error body so handlers can surface a useful
/// message. Owned by g_alloc, replaced per error.
var g_last_err_body: ?[]u8 = null;

fn setLastErrBody(body_owned: []u8) void {
    if (g_last_err_body) |old| g_alloc.free(old);
    g_last_err_body = body_owned;
}

fn takeLastErrBody(alloc: std.mem.Allocator) ?[]u8 {
    const body = g_last_err_body orelse return null;
    g_last_err_body = null;
    const out = alloc.dupe(u8, body) catch {
        g_alloc.free(body);
        return null;
    };
    g_alloc.free(body);
    return out;
}

fn doCompletion(
    alloc: std.mem.Allocator,
    io: std.Io,
    provider: Provider,
    prompt: []const u8,
    model_override: ?[]const u8,
) !Completion {
    // Build OpenAI-compatible payload.
    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = std.json.Stringify{ .writer = &sw.writer };

    try js.beginObject();
    try js.objectField("model");
    try js.write(model_override orelse provider.default_model);
    try js.objectField("messages");
    try js.beginArray();
    try js.beginObject();
    try js.objectField("role");
    try js.write("user");
    try js.objectField("content");
    try js.write(prompt);
    try js.endObject();
    try js.endArray();
    try js.objectField("max_tokens");
    try js.write(1024);
    try js.objectField("temperature");
    try js.write(0.7);
    try js.objectField("stream");
    try js.write(false);
    try js.endObject();

    const payload = sw.written();

    // Resolve API key.
    var api_key_buf: ?[]u8 = null;
    defer if (api_key_buf) |b| alloc.free(b);
    if (provider.api_key_env.len > 0) {
        api_key_buf = getEnvOwned(alloc, provider.api_key_env);
    }

    const url = try std.fmt.allocPrint(alloc, "{s}/chat/completions", .{provider.api_base});
    defer alloc.free(url);

    var auth_buf: ?[]u8 = null;
    defer if (auth_buf) |b| alloc.free(b);

    var headers_buf: [3]std.http.Header = undefined;
    var headers_n: usize = 0;
    headers_buf[headers_n] = .{ .name = "Content-Type", .value = "application/json" };
    headers_n += 1;
    headers_buf[headers_n] = .{ .name = "Accept", .value = "application/json" };
    headers_n += 1;
    if (api_key_buf) |k| {
        auth_buf = try std.fmt.allocPrint(alloc, "Bearer {s}", .{k});
        headers_buf[headers_n] = .{ .name = "Authorization", .value = auth_buf.? };
        headers_n += 1;
    }
    const extra_headers = headers_buf[0..headers_n];

    var client = std.http.Client{ .allocator = alloc, .io = io };
    defer client.deinit();

    var resp_sink: std.Io.Writer.Allocating = .init(alloc);
    defer resp_sink.deinit();

    const start_ms = nowMs();

    var decompress_buf: [64 * 1024]u8 = undefined;

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .headers = .{ .user_agent = .{ .override = user_agent } },
        .extra_headers = extra_headers,
        .response_writer = &resp_sink.writer,
        .decompress_buffer = &decompress_buf,
    });

    const latency: u64 = @intCast(nowMs() - start_ms);

    const status_code = @intFromEnum(result.status);
    if (status_code >= 400) {
        // Stash body for handler to surface (best-effort; ignore OOM).
        if (g_alloc.dupe(u8, resp_sink.written())) |body_copy| {
            setLastErrBody(body_copy);
        } else |_| {}
        return error.HttpError;
    }

    // Parse OpenAI-compatible response.
    const body = resp_sink.written();
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidResponse;

    const choices = root.object.get("choices") orelse return error.InvalidResponse;
    if (choices != .array or choices.array.items.len == 0) return error.InvalidResponse;

    const first = choices.array.items[0];
    if (first != .object) return error.InvalidResponse;

    const msg_v = first.object.get("message") orelse first.object.get("delta") orelse
        return error.InvalidResponse;
    if (msg_v != .object) return error.InvalidResponse;

    const content_v = msg_v.object.get("content") orelse return error.InvalidResponse;
    if (content_v != .string) return error.InvalidResponse;

    var tokens_used: u32 = @intCast(content_v.string.len / 4); // rough
    if (root.object.get("usage")) |usage_v| {
        if (usage_v == .object) {
            if (usage_v.object.get("total_tokens")) |t| {
                if (t == .integer and t.integer > 0) tokens_used = @intCast(t.integer);
            }
        }
    }

    return .{
        .content = try alloc.dupe(u8, content_v.string),
        .tokens_used = tokens_used,
        .latency_ms = latency,
    };
}

// ===========================================================================
// CLI bridge
// ===========================================================================

const CliSpec = struct {
    tool: []const u8,
    command: []const u8,
    extra_args: []const []const u8,
};

const cli_specs = [_]CliSpec{
    .{ .tool = "kilo", .command = "kilo-mcp-server", .extra_args = &.{} },
    .{ .tool = "kimi", .command = "kimi", .extra_args = &.{} },
    .{ .tool = "qwen", .command = "qwen", .extra_args = &.{} },
    .{ .tool = "opencode", .command = "opencode", .extra_args = &.{} },
    .{ .tool = "gemini", .command = "gemini", .extra_args = &.{} },
};

fn lookupCli(tool: []const u8) ?CliSpec {
    for (cli_specs) |s| {
        if (std.mem.eql(u8, s.tool, tool)) return s;
    }
    return null;
}

fn spawnWorker(
    alloc: std.mem.Allocator,
    name: []const u8,
    tool: []const u8,
    model: []const u8,
) !*Worker {
    const spec = lookupCli(tool) orelse return error.UnknownTool;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);

    try argv.append(alloc, spec.command);
    for (spec.extra_args) |a| try argv.append(alloc, a);
    if (model.len > 0) {
        try argv.append(alloc, "--model");
        try argv.append(alloc, model);
    }

    var child = try std.process.spawn(g_io, .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    errdefer child.kill(g_io);

    const child_heap = try alloc.create(std.process.Child);
    child_heap.* = child;

    const w = try alloc.create(Worker);
    w.* = .{
        .name = try alloc.dupe(u8, name),
        .tool = try alloc.dupe(u8, tool),
        .model = try alloc.dupe(u8, model),
        .spawned_ms = nowMs(),
        .child = child_heap,
    };
    return w;
}

// ===========================================================================
// MCP tool handlers
// ===========================================================================

fn handleRouteFree(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    return routeImpl(.free, alloc, io, args);
}

fn handleRouteStandard(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    return routeImpl(.standard, alloc, io, args);
}

fn handleRoutePremium(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    return routeImpl(.premium, alloc, io, args);
}

fn routeImpl(
    tier: Tier,
    alloc: std.mem.Allocator,
    io: std.Io,
    args: std.json.Value,
) !mcp.ToolResult {
    // Args: { prompt: string, model?: string, dry_run?: bool }
    var prompt: []const u8 = "";
    var model_override: ?[]const u8 = null;
    var dry_run = false;
    switch (args) {
        .object => |obj| {
            if (obj.get("prompt")) |v| {
                if (v == .string) prompt = v.string;
            }
            if (obj.get("model")) |v| {
                if (v == .string and v.string.len > 0) model_override = v.string;
            }
            if (obj.get("dry_run")) |v| {
                if (v == .bool) dry_run = v.bool;
            }
        },
        .null => {},
        else => return .{ .text = "expected object args", .is_error = true },
    }

    const pick = route(tier) orelse {
        return .{
            .text = try std.fmt.allocPrint(
                alloc,
                "no provider available for tier {s}: all rate-limited, unhealthy, or missing API keys",
                .{tier.toString()},
            ),
            .is_error = true,
        };
    };

    const chosen_model = model_override orelse pick.provider.default_model;

    quotaCharge(pick.tier_used, @intCast(prompt.len / 4 + 256));

    if (dry_run or prompt.len == 0) {
        return .{
            .text = try std.fmt.allocPrint(
                alloc,
                "[dry_run] tier={s} provider={s} model={s} fell_back={any}",
                .{ pick.tier_used.toString(), pick.provider.name, chosen_model, pick.fell_back },
            ),
        };
    }

    const completion = doCompletion(alloc, io, pick.provider, prompt, model_override) catch |err| {
        const err_body = takeLastErrBody(alloc);
        defer if (err_body) |b| alloc.free(b);

        observe(pick.provider.name, false, 0, if (err_body) |b| b else @errorName(err));

        const event = std.fmt.allocPrint(
            alloc,
            "{{\"ts\":{d},\"provider\":\"{s}\",\"tier\":\"{s}\",\"success\":false,\"err\":\"{s}\"}}",
            .{ nowMs(), pick.provider.name, pick.tier_used.toString(), @errorName(err) },
        ) catch null;
        if (event) |e| {
            defer alloc.free(e);
            appendJsonl(io, alloc, "health.jsonl", e) catch {};
        }

        return .{
            .text = try std.fmt.allocPrint(
                alloc,
                "provider={s} model={s} error={s}{s}{s}",
                .{
                    pick.provider.name,
                    chosen_model,
                    @errorName(err),
                    if (err_body != null) ": " else "",
                    if (err_body) |b| b else "",
                },
            ),
            .is_error = true,
        };
    };

    observe(pick.provider.name, true, completion.latency_ms, null);

    const event = std.fmt.allocPrint(
        alloc,
        "{{\"ts\":{d},\"provider\":\"{s}\",\"tier\":\"{s}\",\"success\":true,\"latency_ms\":{d},\"tokens\":{d}}}",
        .{
            nowMs(),
            pick.provider.name,
            pick.tier_used.toString(),
            completion.latency_ms,
            completion.tokens_used,
        },
    ) catch null;
    if (event) |e| {
        defer alloc.free(e);
        appendJsonl(io, alloc, "health.jsonl", e) catch {};
    }

    return .{
        .text = try std.fmt.allocPrint(
            alloc,
            "[provider={s} tier={s} model={s} tokens={d} latency_ms={d}{s}]\n{s}",
            .{
                pick.provider.name,
                pick.tier_used.toString(),
                chosen_model,
                completion.tokens_used,
                completion.latency_ms,
                if (pick.fell_back) " (fell-back)" else "",
                completion.content,
            },
        ),
    };
}

fn handleBridgeSpawn(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    _ = io;
    if (args != .object) return .{ .text = "expected object args", .is_error = true };

    const tool_v = args.object.get("tool") orelse
        return .{ .text = "missing required field: tool", .is_error = true };
    if (tool_v != .string) return .{ .text = "tool must be a string", .is_error = true };
    const tool = tool_v.string;

    if (lookupCli(tool) == null) {
        return .{
            .text = try std.fmt.allocPrint(
                alloc,
                "unknown tool: {s} (known: kilo, kimi, qwen, opencode, gemini)",
                .{tool},
            ),
            .is_error = true,
        };
    }

    var model: []const u8 = "";
    if (args.object.get("model")) |v| {
        if (v == .string) model = v.string;
    }

    var name: []const u8 = tool;
    if (args.object.get("name")) |v| {
        if (v == .string and v.string.len > 0) name = v.string;
    }

    if (g_workers.get(name) != null) {
        return .{
            .text = try std.fmt.allocPrint(alloc, "worker '{s}' already running", .{name}),
            .is_error = true,
        };
    }

    const w = spawnWorker(g_alloc, name, tool, model) catch |err| {
        return .{
            .text = try std.fmt.allocPrint(
                alloc,
                "spawn failed: {s} (is '{s}' on your PATH?)",
                .{ @errorName(err), tool },
            ),
            .is_error = true,
        };
    };

    g_workers.put(g_alloc, w.name, w) catch {
        freeWorker(g_alloc, w);
        return .{ .text = "OOM tracking worker", .is_error = true };
    };

    const ev = std.fmt.allocPrint(
        alloc,
        "{{\"ts\":{d},\"event\":\"spawn\",\"name\":\"{s}\",\"tool\":\"{s}\",\"model\":\"{s}\"}}",
        .{ nowMs(), w.name, w.tool, w.model },
    ) catch null;
    if (ev) |e| {
        defer alloc.free(e);
        appendJsonl(g_io, alloc, "workers.jsonl", e) catch {};
    }

    return .{
        .text = try std.fmt.allocPrint(
            alloc,
            "spawned worker name={s} tool={s} model={s}",
            .{ w.name, w.tool, w.model },
        ),
    };
}

fn handleBridgeList(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    _ = io;
    _ = args;

    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();

    if (g_workers.count() == 0) {
        return .{ .text = try alloc.dupe(u8, "(no workers running)") };
    }

    try sw.writer.print("name\ttool\tmodel\tuptime_s\n", .{});
    var it = g_workers.iterator();
    const now_ms = nowMs();
    while (it.next()) |entry| {
        const w = entry.value_ptr.*;
        const uptime_s = @divFloor(now_ms - w.spawned_ms, 1000);
        try sw.writer.print("{s}\t{s}\t{s}\t{d}\n", .{ w.name, w.tool, w.model, uptime_s });
    }

    const text = sw.written();
    const trimmed = if (text.len > 0 and text[text.len - 1] == '\n') text[0 .. text.len - 1] else text;
    return .{ .text = try alloc.dupe(u8, trimmed) };
}

fn handleBridgeKill(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    _ = io;
    if (args != .object) return .{ .text = "expected object args", .is_error = true };

    const name_v = args.object.get("name") orelse
        return .{ .text = "missing required field: name", .is_error = true };
    if (name_v != .string) return .{ .text = "name must be a string", .is_error = true };
    const name = name_v.string;

    const w = g_workers.get(name) orelse {
        return .{
            .text = try std.fmt.allocPrint(alloc, "worker not found: {s}", .{name}),
            .is_error = true,
        };
    };

    w.child.kill(g_io);

    const ev = std.fmt.allocPrint(
        alloc,
        "{{\"ts\":{d},\"event\":\"kill\",\"name\":\"{s}\"}}",
        .{ nowMs(), w.name },
    ) catch null;
    if (ev) |e| {
        defer alloc.free(e);
        appendJsonl(g_io, alloc, "workers.jsonl", e) catch {};
    }

    _ = g_workers.remove(name);
    freeWorker(g_alloc, w);

    return .{ .text = try std.fmt.allocPrint(alloc, "killed worker: {s}", .{name}) };
}

fn handleWorkerRun(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    if (args != .object) return .{ .text = "expected object args", .is_error = true };

    const tool_v = args.object.get("tool") orelse
        return .{ .text = "missing required field: tool", .is_error = true };
    if (tool_v != .string) return .{ .text = "tool must be a string", .is_error = true };
    const tool = tool_v.string;

    const prompt_v = args.object.get("prompt") orelse
        return .{ .text = "missing required field: prompt", .is_error = true };
    if (prompt_v != .string) return .{ .text = "prompt must be a string", .is_error = true };
    const prompt = prompt_v.string;

    const spec = lookupCli(tool) orelse {
        return .{
            .text = try std.fmt.allocPrint(alloc, "unknown tool: {s}", .{tool}),
            .is_error = true,
        };
    };

    // Build argv: command [extra_args...] -p <prompt>
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, spec.command);
    for (spec.extra_args) |a| try argv.append(alloc, a);
    try argv.append(alloc, "-p");
    try argv.append(alloc, prompt);

    const result = std.process.run(alloc, io, .{ .argv = argv.items }) catch |err| {
        return .{
            .text = try std.fmt.allocPrint(
                alloc,
                "spawn failed: {s} (is '{s}' on PATH?)",
                .{ @errorName(err), spec.command },
            ),
            .is_error = true,
        };
    };

    const exit_code: i32 = switch (result.term) {
        .exited => |c| @intCast(c),
        else => -1,
    };

    return .{
        .text = try std.fmt.allocPrint(
            alloc,
            "[tool={s} exit={d}]\n--- stdout ---\n{s}\n--- stderr ---\n{s}",
            .{ tool, exit_code, result.stdout, result.stderr },
        ),
        .is_error = exit_code != 0,
    };
}

fn handleProvidersList(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    _ = io;
    var tier_filter: ?Tier = null;
    if (args == .object) {
        if (args.object.get("tier")) |v| {
            if (v == .string) tier_filter = Tier.fromString(v.string);
        }
    }

    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();

    try sw.writer.print("provider\tdefault_model\tcost_per_1k\tkey_env\tnotes\n", .{});

    if (tier_filter) |t| {
        const cfg = lookupTier(t);
        for (cfg.preferred) |name| {
            const p = lookupProvider(name) orelse continue;
            try sw.writer.print("{s}\t{s}\t${d:.4}\t{s}\t{s}\n", .{
                p.name, p.default_model, p.cost_per_1k, p.api_key_env, p.daily_quota_note,
            });
        }
    } else {
        for (provider_catalog) |p| {
            try sw.writer.print("{s}\t{s}\t${d:.4}\t{s}\t{s}\n", .{
                p.name, p.default_model, p.cost_per_1k, p.api_key_env, p.daily_quota_note,
            });
        }
    }

    const t = sw.written();
    const trimmed = if (t.len > 0 and t[t.len - 1] == '\n') t[0 .. t.len - 1] else t;
    return .{ .text = try alloc.dupe(u8, trimmed) };
}

fn handleProvidersHealth(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    _ = io;
    _ = args;

    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();

    try sw.writer.print(
        "provider\thealthy\tsuccess_rate\tavg_latency_ms\tcons_fail\tkey_present\tlast_error\n",
        .{},
    );

    for (provider_catalog) |p| {
        const h: HealthEntry = g_health.get(p.name) orelse .{};
        const healthy = h.consecutive_failures < 3 and h.success_rate >= 0.5;
        const key_present = if (p.api_key_env.len == 0) true else hasEnv(p.api_key_env);
        try sw.writer.print("{s}\t{any}\t{d:.2}\t{d}\t{d}\t{any}\t{s}\n", .{
            p.name,
            healthy,
            h.success_rate,
            h.avg_latency_ms,
            h.consecutive_failures,
            key_present,
            h.last_error orelse "",
        });
    }

    const t = sw.written();
    const trimmed = if (t.len > 0 and t[t.len - 1] == '\n') t[0 .. t.len - 1] else t;
    return .{ .text = try alloc.dupe(u8, trimmed) };
}

// ===========================================================================
// Tool table
// ===========================================================================

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "route_free",
        .description =
        \\Route a prompt through the FREE-tier provider rotation.
        \\Tries: groq, cerebras, sambanova, together, fireworks, cloudflare,
        \\openrouter, ai21 — skipping any rate-limited, unhealthy, or missing
        \\its *_API_KEY env var. Returns chosen provider + model + completion.
        \\Pass dry_run=true (or omit prompt) to see who *would* be picked.
        ,
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "prompt":  { "type": "string", "description": "User prompt." },
        \\    "model":   { "type": "string", "description": "Override the provider's default model." },
        \\    "dry_run": { "type": "boolean", "description": "If true, return chosen provider without making the call." }
        \\  },
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleRouteFree,
    },
    .{
        .name = "route_standard",
        .description = "Route through STANDARD-tier providers (max $0.01/1K tokens). Falls back to free if standard exhausted.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "prompt":  { "type": "string" },
        \\    "model":   { "type": "string" },
        \\    "dry_run": { "type": "boolean" }
        \\  },
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleRouteStandard,
    },
    .{
        .name = "route_premium",
        .description = "Route through PREMIUM-tier providers (max $0.10/1K). Falls back to standard then free if exhausted.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "prompt":  { "type": "string" },
        \\    "model":   { "type": "string" },
        \\    "dry_run": { "type": "boolean" }
        \\  },
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleRoutePremium,
    },
    .{
        .name = "bridge_spawn",
        .description =
        \\Spawn a long-running CLI worker (kilo|kimi|qwen|opencode|gemini).
        \\The process inherits stdio pipes; survives across MCP tool calls
        \\until killed via bridge_kill or the server exits. Requires the named
        \\binary on PATH.
        ,
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "tool":  { "type": "string", "enum": ["kilo","kimi","qwen","opencode","gemini"] },
        \\    "name":  { "type": "string", "description": "Worker handle (defaults to tool name)." },
        \\    "model": { "type": "string", "description": "Optional --model arg." }
        \\  },
        \\  "required": ["tool"],
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleBridgeSpawn,
    },
    .{
        .name = "bridge_list",
        .description = "List currently-running CLI workers with uptime.",
        .input_schema_json =
        \\{ "type": "object", "properties": {}, "additionalProperties": false }
        ,
        .handler = handleBridgeList,
        .read_only = true,
    },
    .{
        .name = "bridge_kill",
        .description = "Kill a CLI worker by its name.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": { "name": { "type": "string" } },
        \\  "required": ["name"],
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleBridgeKill,
        .destructive = true,
    },
    .{
        .name = "worker_run",
        .description =
        \\One-shot run a CLI tool (kilo|kimi|qwen|opencode|gemini) with a prompt.
        \\Spawns `<tool> -p <prompt>`, captures stdout+stderr, returns both
        \\plus exit code. Tool must accept the `-p <prompt>` CLI form.
        ,
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "tool":   { "type": "string", "enum": ["kilo","kimi","qwen","opencode","gemini"] },
        \\    "prompt": { "type": "string" }
        \\  },
        \\  "required": ["tool", "prompt"],
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleWorkerRun,
        .destructive = true,
    },
    .{
        .name = "providers_list",
        .description = "List provider catalog: name, default model, $/1K tokens, env-var for API key, daily-quota note. Optional `tier` filter restricts to that tier's preferred list.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "tier": { "type": "string", "enum": ["free","standard","premium"] }
        \\  },
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleProvidersList,
        .read_only = true,
    },
    .{
        .name = "providers_health",
        .description = "Per-provider EWMA health: success_rate, avg_latency_ms, consecutive failures, last error, key-present flag.",
        .input_schema_json =
        \\{ "type": "object", "properties": {}, "additionalProperties": false }
        ,
        .handler = handleProvidersHealth,
        .read_only = true,
    },
};

// ===========================================================================
// main
// ===========================================================================

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    g_io = init.io;
    g_alloc = std.heap.smp_allocator;

    try mcp.run(
        arena,
        init.io,
        .{ .name = "zmcp-freejobs", .version = "0.1.0" },
        &tool_table,
    );
}

// ===========================================================================
// Tests
// ===========================================================================

test "Tier round-trip" {
    try std.testing.expectEqual(Tier.free, Tier.fromString("free").?);
    try std.testing.expectEqual(Tier.standard, Tier.fromString("standard").?);
    try std.testing.expectEqual(Tier.premium, Tier.fromString("premium").?);
    try std.testing.expectEqualStrings("free", Tier.free.toString());
}

test "provider catalog has every tier-preferred entry" {
    for (tier_configs) |tc| {
        for (tc.preferred) |name| {
            try std.testing.expect(lookupProvider(name) != null);
        }
    }
}

test "free-tier providers are zero-cost" {
    const cfg = lookupTier(.free);
    for (cfg.preferred) |name| {
        const p = lookupProvider(name).?;
        try std.testing.expect(p.cost_per_1k <= cfg.max_cost_per_1k);
    }
}

test "cli specs cover all 5 supported tools" {
    try std.testing.expect(lookupCli("kilo") != null);
    try std.testing.expect(lookupCli("kimi") != null);
    try std.testing.expect(lookupCli("qwen") != null);
    try std.testing.expect(lookupCli("opencode") != null);
    try std.testing.expect(lookupCli("gemini") != null);
    try std.testing.expect(lookupCli("nope") == null);
}

test "env lookup reads the real process environment (not an empty block)" {
    const alloc = std.testing.allocator;
    const saved = g_io;
    defer g_io = saved;
    g_io = std.testing.io;
    const v = getEnvOwned(alloc, "PATH") orelse return error.SkipZigTest;
    defer alloc.free(v);
    try std.testing.expect(v.len > 0);
    try std.testing.expect(getEnvOwned(alloc, "ZMCP_SURELY_UNSET_ENV_VAR_12345") == null);
}
