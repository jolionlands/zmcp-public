//! zmcp-llm - ask a second (often local/cheap) model through any
//! OpenAI-compatible endpoint: llama.cpp llama-server, Ollama /v1, LM Studio,
//! vLLM, OpenRouter, Groq, ...
//!
//! Env:
//!   OPENAI_BASE_URL          default http://127.0.0.1:11434/v1 (Ollama).
//!                            llama-server: http://127.0.0.1:8080/v1
//!                            LM Studio:    http://127.0.0.1:1234/v1
//!   OPENAI_API_KEY           optional; sent as a Bearer token, never echoed
//!   ZMCP_LLM_MODEL           optional default model id
//!   ZMCP_LLM_TIMEOUT_SECS    whole-request timeout (default 120, 1..900)
//!   ZMCP_LLM_MAX_PROMPT_BYTES  cap on prompt/messages/inputs (default 131072)
//!   ZMCP_LLM_MAX_TOKENS      cap (and default) for max_tokens (default 4096)
//!   ZMCP_LLM_OLLAMA          1/0: force the ollama_* tools on/off (default:
//!                            on when the base URL port is 11434)
//!
//! Only what the agent passes is sent; no file or env contents are ever added.

const std = @import("std");
const mcp = @import("mcp");

const DEFAULT_BASE = "http://127.0.0.1:11434/v1";
const UA_PRODUCT = "zmcp-llm/0.1.0";
const MAX_OUT: usize = 64 * 1024;
const MAX_RESPONSE: usize = 32 * 1024 * 1024;
const MAX_EMBED_FLOATS: usize = 2048;
const MAX_EMBED_INPUTS: usize = 256;

var g_environ: ?*const std.process.Environ.Map = null;

pub fn main(init: std.process.Init) !void {
    g_environ = init.environ_map;
    noteRemote();
    const tools: []const mcp.ToolDef = if (ollamaEnabled()) &tool_table else tool_table[0..3];
    try mcp.run(init.gpa, init.io, .{ .name = "zmcp-llm", .version = "0.1.0" }, tools);
}

// The three OpenAI-compatible tools come first; ollama_* only when enabled.
const tool_table = [_]mcp.ToolDef{
    .{
        .name = "llm_chat",
        .description = "Ask another model via an OpenAI-compatible endpoint (sends your prompt to OPENAI_BASE_URL). Returns text + usage line.",
        .input_schema_json =
        \\{"type":"object","properties":{"model":{"type":"string","description":"default ZMCP_LLM_MODEL"},"prompt":{"type":"string"},"messages":{"type":"array","items":{"type":"object","properties":{"role":{"type":"string"},"content":{"type":"string"}},"required":["role","content"]}},"system":{"type":"string"},"max_tokens":{"type":"integer"},"temperature":{"type":"number"},"json_mode":{"type":"boolean"}}}
        ,
        .handler = handleChat,
    },
    .{
        .name = "llm_models",
        .description = "List models on the endpoint as `id ctx price` (ctx/price when provided).",
        .input_schema_json =
        \\{"type":"object","properties":{"filter":{"type":"string"},"limit":{"type":"integer","description":"default 50, max 500"}}}
        ,
        .handler = handleModels,
        .read_only = true,
    },
    .{
        .name = "llm_embed",
        .description = "Embed text via /embeddings (sends input to OPENAI_BASE_URL). Default: dim, count, preview. compare_to: cosine similarities instead.",
        .input_schema_json =
        \\{"type":"object","properties":{"model":{"type":"string"},"input":{"type":["string","array"],"items":{"type":"string"}},"compare_to":{"type":["string","array"],"items":{"type":"string"}},"full":{"type":"boolean","description":"whole vectors (capped)"}},"required":["input"]}
        ,
        .handler = handleEmbed,
    },
    .{
        .name = "ollama_list",
        .description = "List local Ollama models (GET /api/tags).",
        .input_schema_json =
        \\{"type":"object","properties":{}}
        ,
        .handler = handleOllamaList,
        .read_only = true,
    },
    .{
        .name = "ollama_ps",
        .description = "List models loaded in Ollama memory (GET /api/ps).",
        .input_schema_json =
        \\{"type":"object","properties":{}}
        ,
        .handler = handleOllamaPs,
        .read_only = true,
    },
    .{
        .name = "ollama_show",
        .description = "Show an Ollama model's details (family, quant, context, capabilities).",
        .input_schema_json =
        \\{"type":"object","properties":{"model":{"type":"string"}},"required":["model"]}
        ,
        .handler = handleOllamaShow,
        .read_only = true,
    },
};

// ---------------------------------------------------------------------------
// Env + transport seam
// ---------------------------------------------------------------------------

/// Test hook replacing the process environment.
var test_env: ?[]const [2][]const u8 = null;

fn env(name: []const u8) ?[]const u8 {
    if (test_env) |te| {
        for (te) |kv| if (std.mem.eql(u8, kv[0], name)) return if (kv[1].len == 0) null else kv[1];
        return null;
    }
    const m = g_environ orelse return null;
    const v = m.get(name) orelse return null;
    return if (v.len == 0) null else v;
}

fn envInt(name: []const u8, default: u64, lo: u64, hi: u64) u64 {
    const v = env(name) orelse return default;
    const n = std.fmt.parseInt(u64, std.mem.trim(u8, v, " "), 10) catch return default;
    return std.math.clamp(n, lo, hi);
}

const HttpResp = struct { status: u16, body: []const u8 };

const FetchRequest = struct {
    method: std.http.Method,
    url: []const u8,
    bearer: ?[]const u8,
    body: ?[]const u8 = null,
    timeout_ms: u64,
};

const FetchFn = *const fn (alloc: std.mem.Allocator, io: std.Io, req: FetchRequest) anyerror!HttpResp;
var fetch_impl: FetchFn = httpsFetch;

fn fetchOnce(io: std.Io, req: FetchRequest) anyerror!HttpResp {
    const a = std.heap.smp_allocator;
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    const ua_owned = try mcp.userAgent(a, io, UA_PRODUCT);
    defer a.free(ua_owned);
    var resp_buf: std.Io.Writer.Allocating = .init(a);
    defer resp_buf.deinit();
    var decompress_buf: [64 * 1024]u8 = undefined;
    var bearer_buf: [1024]u8 = undefined;
    var headers: std.http.Client.Request.Headers = .{};
    if (req.bearer) |k| {
        const v = std.fmt.bufPrint(&bearer_buf, "Bearer {s}", .{k}) catch return error.ApiKeyTooLong;
        headers.authorization = .{ .override = v };
    }
    var extra: [3]std.http.Header = undefined;
    extra[0] = .{ .name = "User-Agent", .value = ua_owned };
    extra[1] = .{ .name = "Accept", .value = "application/json" };
    var ne: usize = 2;
    if (req.body != null) {
        extra[2] = .{ .name = "Content-Type", .value = "application/json" };
        ne = 3;
    }
    const res = try client.fetch(.{
        .location = .{ .url = req.url },
        .response_writer = &resp_buf.writer,
        .method = req.method,
        .payload = req.body,
        .extra_headers = extra[0..ne],
        .headers = headers,
        // std 0.16 never emits privileged_headers, and redirects would re-send the
        // key to another host: hand 3xx back as a status instead of following.
        .redirect_behavior = .unhandled,
        .decompress_buffer = &decompress_buf,
    });
    if (resp_buf.written().len > MAX_RESPONSE) return error.ResponseTooLarge;
    return .{ .status = @intFromEnum(res.status), .body = try a.dupe(u8, resp_buf.written()) };
}

const Race = union(enum) { done: anyerror!HttpResp, timer: void };

fn fetchTask(io: std.Io, req: FetchRequest) anyerror!HttpResp {
    return fetchOnce(io, req);
}

fn timerTask(io: std.Io, ms: u64) void {
    const t: std.Io.Timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(@intCast(ms)), .clock = .awake } };
    t.sleep(io) catch {};
}

/// Real transport: one request raced against a whole-request timeout.
fn httpsFetch(alloc: std.mem.Allocator, io: std.Io, req: FetchRequest) anyerror!HttpResp {
    var buf: [2]Race = undefined;
    var sel = std.Io.Select(Race).init(io, &buf);
    sel.concurrent(.done, fetchTask, .{ io, req }) catch {
        // No concurrency available: run inline without a timeout.
        const r = try fetchOnce(io, req);
        defer std.heap.smp_allocator.free(r.body);
        return .{ .status = r.status, .body = try alloc.dupe(u8, r.body) };
    };
    sel.concurrent(.timer, timerTask, .{ io, req.timeout_ms }) catch {};
    const first = sel.await() catch |e| {
        sel.cancelDiscard();
        return e;
    };
    sel.cancelDiscard();
    switch (first) {
        .timer => return error.Timeout,
        .done => |r| {
            const resp = try r;
            defer std.heap.smp_allocator.free(resp.body);
            return .{ .status = resp.status, .body = try alloc.dupe(u8, resp.body) };
        },
    }
}

// ---------------------------------------------------------------------------
// URL helpers
// ---------------------------------------------------------------------------

const BaseUrl = struct {
    /// scheme://authority/path with no trailing slash
    base: []const u8,
    /// scheme://authority
    origin: []const u8,
    host: []const u8,
    port: ?u16,
};

fn parseBase(s0: []const u8) !BaseUrl {
    var s = std.mem.trim(u8, s0, " \t\r\n");
    while (s.len > 0 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    const scheme_len: usize = if (std.mem.startsWith(u8, s, "http://")) 7 else if (std.mem.startsWith(u8, s, "https://")) 8 else return error.BadScheme;
    const rest = s[scheme_len..];
    const auth_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..auth_end];
    if (authority.len == 0) return error.BadHost;
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return error.UserinfoNotAllowed;
    if (std.mem.indexOfAny(u8, s, " \t\r\n\"<>\\") != null) return error.BadChars;
    var host: []const u8 = authority;
    var port: ?u16 = null;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return error.BadHost;
        host = authority[0 .. close + 1];
        if (authority.len > close + 1) {
            if (authority[close + 1] != ':') return error.BadHost;
            port = std.fmt.parseInt(u16, authority[close + 2 ..], 10) catch return error.BadHost;
        }
    } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |c| {
        host = authority[0..c];
        port = std.fmt.parseInt(u16, authority[c + 1 ..], 10) catch return error.BadHost;
    }
    return .{ .base = s, .origin = s[0 .. scheme_len + auth_end], .host = host, .port = port };
}

fn isLoopback(host: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    if (std.mem.eql(u8, host, "[::1]")) return true;
    return std.mem.startsWith(u8, host, "127.");
}

fn currentBase() !BaseUrl {
    return parseBase(env("OPENAI_BASE_URL") orelse DEFAULT_BASE);
}

var noted_remote: bool = false;

/// One-time stderr note when the endpoint is not on this machine.
fn noteRemote() void {
    if (noted_remote) return;
    noted_remote = true;
    const b = currentBase() catch return;
    if (!isLoopback(b.host)) {
        std.debug.print("zmcp-llm: note: {s} is not loopback; prompts you pass are sent there\n", .{b.origin});
    }
}

fn ollamaEnabled() bool {
    if (env("ZMCP_LLM_OLLAMA")) |v| return !std.mem.eql(u8, v, "0");
    const b = currentBase() catch return false;
    return (b.port orelse 0) == 11434;
}

// ---------------------------------------------------------------------------
// Result helpers
// ---------------------------------------------------------------------------

fn text(s: []const u8) mcp.ToolResult {
    return .{ .text = s };
}
fn fail(s: []const u8) mcp.ToolResult {
    return .{ .text = s, .is_error = true };
}
fn failf(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !mcp.ToolResult {
    return fail(try std.fmt.allocPrint(alloc, fmt, args));
}

fn capOut(alloc: std.mem.Allocator, s: []const u8, hint: []const u8) !mcp.ToolResult {
    if (s.len <= MAX_OUT) return text(s);
    var cut: usize = MAX_OUT;
    while (cut > 0 and (s[cut] & 0xC0) == 0x80) cut -= 1;
    return text(try std.fmt.allocPrint(alloc, "{s}\n...[truncated {d} of {d} bytes; {s}]", .{ s[0..cut], cut, s.len, hint }));
}

fn getStr(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    if (v != .string or v.string.len == 0) return null;
    return v.string;
}
fn getInt(args: std.json.Value, key: []const u8) ?i64 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f)) @as(i64, @intFromFloat(@min(@max(f, -1e15), 1e15))) else null,
        else => null,
    };
}
fn getNum(args: std.json.Value, key: []const u8) ?f64 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| if (std.math.isFinite(f)) f else null,
        else => null,
    };
}
fn getBool(args: std.json.Value, key: []const u8) bool {
    if (args != .object) return false;
    const v = args.object.get(key) orelse return false;
    return v == .bool and v.bool;
}
fn field(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}
fn fstr(v: std.json.Value, key: []const u8) ?[]const u8 {
    const f = field(v, key) orelse return null;
    return if (f == .string) f.string else null;
}
fn fnum(v: std.json.Value, key: []const u8) ?f64 {
    const f = field(v, key) orelse return null;
    return switch (f) {
        .integer => |i| @floatFromInt(i),
        .float => |x| x,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        .string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn toJson(alloc: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    return std.json.Stringify.valueAlloc(alloc, v, .{});
}

// ---------------------------------------------------------------------------
// HTTP call + error mapping
// ---------------------------------------------------------------------------

const Api = union(enum) { ok: std.json.Value, fail: []const u8 };

/// Terse error text from an error body: OpenAI {"error":{"message"}},
/// Ollama-native {"error":"..."}, or {"message"}.
fn errorDetail(alloc: std.mem.Allocator, body: []const u8) []const u8 {
    if (std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{})) |v| {
        if (field(v, "error")) |e| {
            if (e == .string) return clip(e.string, 300);
            if (fstr(e, "message")) |m| return clip(m, 300);
        }
        if (fstr(v, "message")) |m| return clip(m, 300);
        if (field(v, "detail")) |d| if (d == .string) return clip(d.string, 300);
    } else |_| {}
    const t = std.mem.trim(u8, body, " \r\n\t");
    if (t.len > 0 and t[0] != '<') return clip(t, 200);
    return "";
}

/// Upstream error text sometimes echoes the API key ("Incorrect API key
/// provided: sk-..."); never pass that on to the model or the log.
fn redactKey(alloc: std.mem.Allocator, s: []const u8) []const u8 {
    const key = env("OPENAI_API_KEY") orelse return s;
    if (key.len < 4 or std.mem.indexOf(u8, s, key) == null) return s;
    return std.mem.replaceOwned(u8, alloc, s, key, "[redacted]") catch "[redacted]";
}

fn clip(s: []const u8, n: usize) []const u8 {
    if (s.len <= n) return s;
    var c = n;
    while (c > 0 and (s[c] & 0xC0) == 0x80) c -= 1;
    return s[0..c];
}

fn containsIgnoreCase(h: []const u8, n: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(h, n) != null;
}

fn mapError(alloc: std.mem.Allocator, status: u16, body: []const u8) ![]const u8 {
    const detail = redactKey(alloc, errorDetail(alloc, body));
    const model_missing = containsIgnoreCase(detail, "model") and
        (containsIgnoreCase(detail, "not found") or containsIgnoreCase(detail, "does not exist") or
            containsIgnoreCase(detail, "not exist") or containsIgnoreCase(detail, "no such") or containsIgnoreCase(detail, "unknown"));
    const hint: []const u8 = switch (status) {
        401 => "unauthorized: set/fix OPENAI_API_KEY",
        403 => "forbidden: key lacks access to this model/endpoint",
        404 => if (model_missing) "model not found: pick an id from llm_models (Ollama: it may need `ollama pull`)" else "not found: check OPENAI_BASE_URL (usually ends in /v1) and the model id",
        408 => "request timeout",
        413 => "request too large: shorten the prompt",
        422 => "invalid request",
        429 => "rate limited or out of quota: wait and retry",
        400 => if (model_missing) "model not found: pick an id from llm_models" else if (containsIgnoreCase(detail, "context")) "prompt too long for the model context: shorten it" else "bad request",
        300...399 => "redirect not followed (key is never re-sent): fix OPENAI_BASE_URL (http vs https, path)",
        else => if (status >= 500) "server error: retry later, or check that the model is loaded" else "request failed",
    };
    if (detail.len > 0) return std.fmt.allocPrint(alloc, "HTTP {d}: {s} ({s})", .{ status, hint, detail });
    return std.fmt.allocPrint(alloc, "HTTP {d}: {s}", .{ status, hint });
}

fn call(alloc: std.mem.Allocator, io: std.Io, method: std.http.Method, url: []const u8, body: ?[]const u8) !Api {
    const timeout_ms = envInt("ZMCP_LLM_TIMEOUT_SECS", 120, 1, 900) * 1000;
    const r = fetch_impl(alloc, io, .{
        .method = method,
        .url = url,
        .bearer = env("OPENAI_API_KEY"),
        .body = body,
        .timeout_ms = timeout_ms,
    }) catch |e| {
        const b = currentBase() catch return .{ .fail = "bad OPENAI_BASE_URL" };
        return .{ .fail = switch (e) {
            error.Timeout => try std.fmt.allocPrint(alloc, "timed out after {d}s waiting for {s} (raise ZMCP_LLM_TIMEOUT_SECS; local models may be loading)", .{ timeout_ms / 1000, b.origin }),
            error.ResponseTooLarge => "response too large",
            else => try std.fmt.allocPrint(alloc, "cannot reach {s} ({s}): is the server running? defaults: Ollama :11434, llama-server :8080, LM Studio :1234", .{ b.origin, @errorName(e) }),
        } };
    };
    if (r.status < 200 or r.status >= 300) return .{ .fail = try mapError(alloc, r.status, r.body) };
    const v = std.json.parseFromSliceLeaky(std.json.Value, alloc, r.body, .{}) catch
        return .{ .fail = try std.fmt.allocPrint(alloc, "endpoint returned non-JSON (HTTP {d}); is OPENAI_BASE_URL an API root (…/v1)? got: {s}", .{ r.status, clip(std.mem.trim(u8, r.body, " \r\n"), 120) }) };
    return .{ .ok = v };
}

fn apiUrl(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    const b = try currentBase();
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ b.base, path });
}

fn ollamaUrl(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    const b = try currentBase();
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ b.origin, path });
}

const bad_base = "invalid OPENAI_BASE_URL: expected http(s)://host[:port]/v1 without credentials";

// ---------------------------------------------------------------------------
// llm_chat
// ---------------------------------------------------------------------------

fn resolveModel(args: std.json.Value) ?[]const u8 {
    return getStr(args, "model") orelse env("ZMCP_LLM_MODEL");
}

const no_model = "no model: pass `model` or set ZMCP_LLM_MODEL (llm_models lists ids; llama-server accepts any name)";

fn maxPromptBytes() usize {
    return @intCast(envInt("ZMCP_LLM_MAX_PROMPT_BYTES", 128 * 1024, 256, 8 * 1024 * 1024));
}

fn addMsg(alloc: std.mem.Allocator, arr: *std.json.Array, role: []const u8, content: []const u8) !void {
    var o: std.json.ObjectMap = .empty;
    try o.put(alloc, "role", .{ .string = role });
    try o.put(alloc, "content", .{ .string = content });
    try arr.append(.{ .object = o });
}

const BuiltChat = union(enum) { body: []const u8, err: []const u8 };

fn buildChatBody(alloc: std.mem.Allocator, args: std.json.Value) !BuiltChat {
    const model = resolveModel(args) orelse return .{ .err = no_model };
    var msgs = std.json.Array.init(alloc);
    var bytes: usize = 0;
    if (getStr(args, "system")) |s| {
        try addMsg(alloc, &msgs, "system", s);
        bytes += s.len;
    }
    if (field(args, "messages")) |m| {
        if (m != .array) return .{ .err = "messages must be an array of {role, content}" };
        for (m.array.items) |it| {
            const role = fstr(it, "role") orelse return .{ .err = "each message needs string role and content" };
            const content = fstr(it, "content") orelse return .{ .err = "each message needs string role and content" };
            if (!validRole(role)) return .{ .err = "role must be system, user, assistant or tool" };
            try addMsg(alloc, &msgs, role, content);
            bytes += content.len;
        }
    }
    if (getStr(args, "prompt")) |p| {
        try addMsg(alloc, &msgs, "user", p);
        bytes += p.len;
    }
    if (msgs.items.len == 0 or (msgs.items.len == 1 and getStr(args, "system") != null)) return .{ .err = "pass `prompt` or `messages`" };
    const cap = maxPromptBytes();
    if (bytes > cap) return .{ .err = try std.fmt.allocPrint(alloc, "prompt is {d} bytes, over the {d} byte cap (ZMCP_LLM_MAX_PROMPT_BYTES); shorten it", .{ bytes, cap }) };

    const tok_cap: i64 = @intCast(envInt("ZMCP_LLM_MAX_TOKENS", 4096, 1, 1_000_000));
    const max_tokens = std.math.clamp(getInt(args, "max_tokens") orelse tok_cap, 1, tok_cap);

    var o: std.json.ObjectMap = .empty;
    try o.put(alloc, "model", .{ .string = model });
    try o.put(alloc, "messages", .{ .array = msgs });
    try o.put(alloc, "stream", .{ .bool = false });
    try o.put(alloc, "max_tokens", .{ .integer = max_tokens });
    if (getNum(args, "temperature")) |t| try o.put(alloc, "temperature", .{ .float = std.math.clamp(t, 0.0, 2.0) });
    if (getBool(args, "json_mode")) {
        var rf: std.json.ObjectMap = .empty;
        try rf.put(alloc, "type", .{ .string = "json_object" });
        try o.put(alloc, "response_format", .{ .object = rf });
    }
    return .{ .body = try toJson(alloc, .{ .object = o }) };
}

fn validRole(r: []const u8) bool {
    for ([_][]const u8{ "system", "user", "assistant", "tool" }) |ok| if (std.mem.eql(u8, r, ok)) return true;
    return false;
}

/// Assistant text: message.content as a string or an array of text parts.
fn messageText(alloc: std.mem.Allocator, msg: std.json.Value) ![]const u8 {
    const c = field(msg, "content") orelse return "";
    switch (c) {
        .string => |s| return s,
        .array => |arr| {
            var aw: std.Io.Writer.Allocating = .init(alloc);
            for (arr.items) |p| {
                if (fstr(p, "text")) |t| try aw.writer.writeAll(t);
            }
            return aw.written();
        },
        else => return "",
    }
}

fn handleChat(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const built = try buildChatBody(alloc, args);
    const body = switch (built) {
        .body => |b| b,
        .err => |e| return fail(e),
    };
    const url = apiUrl(alloc, "/chat/completions") catch return fail(bad_base);
    const res = try call(alloc, io, .POST, url, body);
    const v = switch (res) {
        .ok => |v| v,
        .fail => |m| return fail(m),
    };
    const choices = field(v, "choices") orelse return failf(alloc, "unexpected response (no choices): {s}", .{clip(try toJson(alloc, v), 200)});
    if (choices != .array or choices.array.items.len == 0) return fail("response had no choices");
    const ch = choices.array.items[0];
    const msg = field(ch, "message") orelse return fail("response choice had no message");
    var content = try messageText(alloc, msg);
    var note: []const u8 = "";
    if (content.len == 0) {
        const reasoning = fstr(msg, "reasoning_content") orelse fstr(msg, "reasoning") orelse "";
        if (reasoning.len > 0) {
            note = try std.fmt.allocPrint(alloc, "(no final answer: model spent its {d}-char reasoning on the token budget; raise max_tokens)", .{reasoning.len});
        } else if (field(msg, "tool_calls") != null) {
            note = "(model returned tool calls, not text)";
        } else note = "(empty reply)";
        content = note;
    }
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.writeAll(content);
    try w.writeAll("\n\n");
    try writeUsage(w, v, ch, resolveModel(args) orelse "?");
    return capOut(alloc, aw.written(), "ask for a shorter answer or lower max_tokens");
}

fn writeUsage(w: *std.Io.Writer, v: std.json.Value, choice: std.json.Value, req_model: []const u8) !void {
    try w.print("[{s}", .{fstr(v, "model") orelse req_model});
    if (field(v, "usage")) |u| {
        const p = fnum(u, "prompt_tokens");
        const c = fnum(u, "completion_tokens");
        if (p) |x| try w.print(" in={d}", .{@as(i64, @intFromFloat(x))});
        if (c) |x| try w.print(" out={d}", .{@as(i64, @intFromFloat(x))});
    }
    if (fstr(choice, "finish_reason")) |f| {
        try w.print(" finish={s}", .{f});
        if (std.mem.eql(u8, f, "length")) try w.writeAll(" (cut at max_tokens)");
    }
    try w.writeAll("]");
}

// ---------------------------------------------------------------------------
// llm_models
// ---------------------------------------------------------------------------

const ModelRow = struct {
    id: []const u8,
    ctx: ?u64 = null,
    price_in: ?f64 = null, // USD per token
    price_out: ?f64 = null,
};

fn rowLess(_: void, a: ModelRow, b: ModelRow) bool {
    return std.ascii.lessThanIgnoreCase(a.id, b.id);
}

fn ctxOf(m: std.json.Value) ?u64 {
    const keys = [_][]const u8{ "context_length", "max_model_len", "context_window", "max_context_length", "n_ctx" };
    for (keys) |k| if (fnum(m, k)) |x| if (x > 0) return @intFromFloat(x);
    if (field(m, "top_provider")) |tp| if (fnum(tp, "context_length")) |x| if (x > 0) return @intFromFloat(x);
    if (field(m, "meta")) |meta| {
        if (fnum(meta, "n_ctx_train")) |x| if (x > 0) return @intFromFloat(x);
    }
    return null;
}

fn parseModels(alloc: std.mem.Allocator, v: std.json.Value) ![]ModelRow {
    // OpenAI/OpenRouter/vLLM/LM Studio/llama-server: {"data":[{"id"...}]}
    // Ollama native (/api/tags) shape: {"models":[{"name"...}]}
    const list = field(v, "data") orelse field(v, "models") orelse if (v == .array) v else return error.BadShape;
    if (list != .array) return error.BadShape;
    var rows: std.ArrayList(ModelRow) = .empty;
    for (list.array.items) |m| {
        const id = fstr(m, "id") orelse fstr(m, "name") orelse fstr(m, "model") orelse continue;
        var row: ModelRow = .{ .id = id, .ctx = ctxOf(m) };
        if (field(m, "pricing")) |p| {
            row.price_in = fnum(p, "prompt");
            row.price_out = fnum(p, "completion");
        }
        try rows.append(alloc, row);
    }
    return rows.toOwnedSlice(alloc);
}

fn fmtCtx(w: *std.Io.Writer, c: u64) !void {
    if (c >= 1000 and c % 1000 == 0) return w.print("{d}k", .{c / 1000});
    try w.print("{d}", .{c});
}

/// USD per 1M tokens, up to 3 decimals, trailing zeros trimmed.
fn fmtPerM(w: *std.Io.Writer, per_token: f64) !void {
    const m = per_token * 1e6;
    if (m <= 0) return w.writeAll("$0");
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:.3}", .{m}) catch return w.writeAll("?");
    var t = s;
    if (std.mem.indexOfScalar(u8, t, '.') != null) {
        while (t.len > 0 and t[t.len - 1] == '0') t = t[0 .. t.len - 1];
        if (t.len > 0 and t[t.len - 1] == '.') t = t[0 .. t.len - 1];
    }
    try w.print("${s}", .{t});
}

fn formatModels(alloc: std.mem.Allocator, rows_in: []ModelRow, filter: ?[]const u8, limit: usize) ![]const u8 {
    var kept: std.ArrayList(ModelRow) = .empty;
    for (rows_in) |r| {
        if (filter) |f| if (!containsIgnoreCase(r.id, f)) continue;
        try kept.append(alloc, r);
    }
    std.mem.sort(ModelRow, kept.items, {}, rowLess);
    var any_ctx = false;
    var any_price = false;
    for (kept.items) |r| {
        if (r.ctx != null) any_ctx = true;
        if (r.price_in != null or r.price_out != null) any_price = true;
    }
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    if (kept.items.len == 0) return "no models match";
    const shown = @min(limit, kept.items.len);
    try w.writeAll("id");
    if (any_ctx) try w.writeAll("  ctx");
    if (any_price) try w.writeAll("  price(in/out per 1M tok)");
    try w.writeAll("\n");
    for (kept.items[0..shown]) |r| {
        try w.writeAll(r.id);
        if (any_ctx) {
            try w.writeAll("  ");
            if (r.ctx) |c| try fmtCtx(w, c) else try w.writeAll("-");
        }
        if (any_price) {
            try w.writeAll("  ");
            if (r.price_in == null and r.price_out == null) {
                try w.writeAll("-");
            } else {
                if (r.price_in) |p| try fmtPerM(w, p) else try w.writeAll("-");
                try w.writeAll("/");
                if (r.price_out) |p| try fmtPerM(w, p) else try w.writeAll("-");
            }
        }
        try w.writeAll("\n");
    }
    if (shown < kept.items.len) try w.print("... {d} more; narrow with filter or raise limit\n", .{kept.items.len - shown});
    return aw.written();
}

fn handleModels(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const url = apiUrl(alloc, "/models") catch return fail(bad_base);
    const res = try call(alloc, io, .GET, url, null);
    const v = switch (res) {
        .ok => |v| v,
        .fail => |m| return fail(m),
    };
    const rows = parseModels(alloc, v) catch return fail("unexpected /models response shape (no data[] list)");
    const limit: usize = @intCast(std.math.clamp(getInt(args, "limit") orelse 50, 1, 500));
    const out = try formatModels(alloc, rows, getStr(args, "filter"), limit);
    return capOut(alloc, out, "use filter/limit");
}

// ---------------------------------------------------------------------------
// llm_embed
// ---------------------------------------------------------------------------

fn cosine(a: []const f64, b: []const f64) ?f64 {
    if (a.len != b.len or a.len == 0) return null;
    var dot: f64 = 0;
    var na: f64 = 0;
    var nb: f64 = 0;
    for (a, b) |x, y| {
        dot += x * y;
        na += x * x;
        nb += y * y;
    }
    if (na == 0 or nb == 0) return null;
    return dot / (@sqrt(na) * @sqrt(nb));
}

/// A string or an array of strings -> list; null when malformed.
fn strList(alloc: std.mem.Allocator, v: ?std.json.Value) !?[]const []const u8 {
    const x = v orelse return null;
    switch (x) {
        .string => |s| {
            const out = try alloc.alloc([]const u8, 1);
            out[0] = s;
            return out;
        },
        .array => |arr| {
            const out = try alloc.alloc([]const u8, arr.items.len);
            for (arr.items, 0..) |it, i| {
                if (it != .string) return null;
                out[i] = it.string;
            }
            return out;
        },
        else => return null,
    }
}

fn parseVectors(alloc: std.mem.Allocator, v: std.json.Value, n: usize) ![][]f64 {
    const data = field(v, "data") orelse return error.BadShape;
    if (data != .array or data.array.items.len != n) return error.BadShape;
    const out = try alloc.alloc([]f64, n);
    for (data.array.items, 0..) |d, pos| {
        const idx: usize = if (fnum(d, "index")) |x| @intFromFloat(@max(x, 0)) else pos;
        if (idx >= n) return error.BadShape;
        const e = field(d, "embedding") orelse return error.BadShape;
        if (e != .array) return error.BadShape; // e.g. base64 encoding_format
        const vec = try alloc.alloc(f64, e.array.items.len);
        for (e.array.items, 0..) |x, i| vec[i] = switch (x) {
            .float => |f| f,
            .integer => |k| @floatFromInt(k),
            .number_string => |s| std.fmt.parseFloat(f64, s) catch return error.BadShape,
            else => return error.BadShape,
        };
        out[idx] = vec;
    }
    return out;
}

fn handleEmbed(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const model = resolveModel(args) orelse return fail(no_model);
    const inputs = (try strList(alloc, field(args, "input"))) orelse return fail("input must be a string or array of strings");
    if (inputs.len == 0) return fail("input is empty");
    const compare: ?[]const []const u8 = if (field(args, "compare_to") != null)
        ((try strList(alloc, field(args, "compare_to"))) orelse return fail("compare_to must be a string or array of strings"))
    else
        null;
    const n_cmp = if (compare) |c| c.len else 0;
    if (compare != null and n_cmp == 0) return fail("compare_to is empty");
    const total = inputs.len + n_cmp;
    if (total > MAX_EMBED_INPUTS) return failf(alloc, "too many texts ({d}; max {d})", .{ total, MAX_EMBED_INPUTS });
    var bytes: usize = 0;
    var all = try alloc.alloc([]const u8, total);
    for (inputs, 0..) |s, i| {
        all[i] = s;
        bytes += s.len;
    }
    if (compare) |c| for (c, 0..) |s, i| {
        all[inputs.len + i] = s;
        bytes += s.len;
    };
    if (bytes > maxPromptBytes()) return failf(alloc, "input is {d} bytes, over the {d} byte cap (ZMCP_LLM_MAX_PROMPT_BYTES)", .{ bytes, maxPromptBytes() });

    var arr = std.json.Array.init(alloc);
    for (all) |s| try arr.append(.{ .string = s });
    var o: std.json.ObjectMap = .empty;
    try o.put(alloc, "model", .{ .string = model });
    try o.put(alloc, "input", .{ .array = arr });
    const body = try toJson(alloc, .{ .object = o });

    const url = apiUrl(alloc, "/embeddings") catch return fail(bad_base);
    const res = try call(alloc, io, .POST, url, body);
    const v = switch (res) {
        .ok => |v| v,
        .fail => |m| return fail(m),
    };
    const vecs = parseVectors(alloc, v, total) catch return fail("unexpected /embeddings response (need data[].embedding float arrays, one per input)");
    const dim = vecs[0].len;
    for (vecs) |x| if (x.len != dim) return fail("embeddings have inconsistent dimensions");

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    if (compare) |cmp| {
        try w.print("cosine similarity (dim={d}, model={s})\n", .{ dim, fstr(v, "model") orelse model });
        var lines: usize = 0;
        for (inputs, 0..) |inp, i| {
            const Sc = struct { j: usize, s: f64 };
            var scores = try alloc.alloc(Sc, cmp.len);
            for (0..cmp.len) |j| scores[j] = .{ .j = j, .s = cosine(vecs[i], vecs[inputs.len + j]) orelse 0 };
            if (inputs.len == 1) std.mem.sort(Sc, scores, {}, struct {
                fn lt(_: void, a: Sc, b: Sc) bool {
                    return a.s > b.s;
                }
            }.lt);
            for (scores) |sc| {
                if (lines >= 100) break;
                lines += 1;
                try w.print("input[{d}] ~ compare_to[{d}]: {d:.4}  \"{s}\"\n", .{ i, sc.j, sc.s, preview(cmp[sc.j], 40) });
            }
            _ = inp;
        }
        if (inputs.len * cmp.len > lines) try w.print("... {d} more pairs omitted\n", .{inputs.len * cmp.len - lines});
        return text(aw.written());
    }

    try w.print("dim={d} count={d} model={s}\n", .{ dim, inputs.len, fstr(v, "model") orelse model });
    const full = getBool(args, "full");
    var floats_left: usize = MAX_EMBED_FLOATS;
    for (vecs[0..inputs.len], 0..) |vec, i| {
        const want: usize = if (full) vec.len else @min(vec.len, 6);
        const take = @min(want, floats_left);
        floats_left -= take;
        try w.print("[{d}]", .{i});
        for (vec[0..take]) |x| try w.print(" {d:.5}", .{x});
        if (take < vec.len) try w.print(" ... ({d} more)", .{vec.len - take});
        try w.writeAll("\n");
    }
    if (full and floats_left == 0) try w.print("(vectors capped at {d} values total; embed fewer texts or use compare_to)\n", .{MAX_EMBED_FLOATS});
    return text(aw.written());
}

fn preview(s: []const u8, n: usize) []const u8 {
    const c = clip(s, n);
    if (std.mem.indexOfScalar(u8, c, '\n')) |nl| return c[0..nl];
    return c;
}

// ---------------------------------------------------------------------------
// Ollama-native (read-only)
// ---------------------------------------------------------------------------

fn fmtBytes(w: *std.Io.Writer, n: f64) !void {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var x = n;
    var i: usize = 0;
    while (x >= 1000 and i < units.len - 1) : (i += 1) x /= 1000;
    if (i == 0) return w.print("{d}B", .{@as(u64, @intFromFloat(x))});
    try w.print("{d:.1}{s}", .{ x, units[i] });
}

fn ollamaGet(alloc: std.mem.Allocator, io: std.Io, method: std.http.Method, path: []const u8, body: ?[]const u8) !Api {
    const url = ollamaUrl(alloc, path) catch return .{ .fail = bad_base };
    const r = try call(alloc, io, method, url, body);
    if (r == .fail) {
        const b = currentBase() catch return r;
        return .{ .fail = try std.fmt.allocPrint(alloc, "{s} (ollama_* tools need an Ollama server at {s})", .{ r.fail, b.origin }) };
    }
    return r;
}

fn handleOllamaList(alloc: std.mem.Allocator, io: std.Io, _: std.json.Value) !mcp.ToolResult {
    const v = switch (try ollamaGet(alloc, io, .GET, "/api/tags", null)) {
        .ok => |v| v,
        .fail => |m| return fail(m),
    };
    const models = field(v, "models") orelse return fail("unexpected /api/tags response");
    if (models != .array) return fail("unexpected /api/tags response");
    if (models.array.items.len == 0) return text("no models installed (Ollama pull is not exposed here; run `ollama pull <name>` yourself)");
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.writeAll("name  size  params  quant\n");
    for (models.array.items) |m| {
        try w.print("{s}  ", .{fstr(m, "name") orelse fstr(m, "model") orelse "?"});
        if (fnum(m, "size")) |s| try fmtBytes(w, s) else try w.writeAll("-");
        const d = field(m, "details");
        try w.print("  {s}  {s}\n", .{ if (d) |x| fstr(x, "parameter_size") orelse "-" else "-", if (d) |x| fstr(x, "quantization_level") orelse "-" else "-" });
    }
    return capOut(alloc, aw.written(), "too many models");
}

fn handleOllamaPs(alloc: std.mem.Allocator, io: std.Io, _: std.json.Value) !mcp.ToolResult {
    const v = switch (try ollamaGet(alloc, io, .GET, "/api/ps", null)) {
        .ok => |v| v,
        .fail => |m| return fail(m),
    };
    const models = field(v, "models") orelse return fail("unexpected /api/ps response");
    if (models != .array) return fail("unexpected /api/ps response");
    if (models.array.items.len == 0) return text("no models loaded");
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.writeAll("name  size  vram  ctx  expires\n");
    for (models.array.items) |m| {
        try w.print("{s}  ", .{fstr(m, "name") orelse fstr(m, "model") orelse "?"});
        if (fnum(m, "size")) |s| try fmtBytes(w, s) else try w.writeAll("-");
        try w.writeAll("  ");
        if (fnum(m, "size_vram")) |s| try fmtBytes(w, s) else try w.writeAll("-");
        try w.writeAll("  ");
        if (fnum(m, "context_length")) |c| try w.print("{d}", .{@as(u64, @intFromFloat(c))}) else try w.writeAll("-");
        try w.print("  {s}\n", .{fstr(m, "expires_at") orelse "-"});
    }
    return capOut(alloc, aw.written(), "too many models");
}

fn handleOllamaShow(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const model = getStr(args, "model") orelse return fail("model is required");
    var o: std.json.ObjectMap = .empty;
    try o.put(alloc, "model", .{ .string = model });
    const body = try toJson(alloc, .{ .object = o });
    const v = switch (try ollamaGet(alloc, io, .POST, "/api/show", body)) {
        .ok => |v| v,
        .fail => |m| return fail(m),
    };
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.print("{s}\n", .{model});
    if (field(v, "details")) |d| {
        try w.print("family={s} params={s} quant={s} format={s}\n", .{ fstr(d, "family") orelse "-", fstr(d, "parameter_size") orelse "-", fstr(d, "quantization_level") orelse "-", fstr(d, "format") orelse "-" });
    }
    if (field(v, "model_info")) |mi| if (mi == .object) {
        var it = mi.object.iterator();
        while (it.next()) |e| {
            const k = e.key_ptr.*;
            if (std.mem.endsWith(u8, k, ".context_length")) {
                if (fnum(mi, k)) |c| try w.print("context_length={d}\n", .{@as(u64, @intFromFloat(c))});
            } else if (std.mem.eql(u8, k, "general.architecture")) {
                if (e.value_ptr.* == .string) try w.print("arch={s}\n", .{e.value_ptr.string});
            }
        }
    };
    if (field(v, "capabilities")) |c| if (c == .array and c.array.items.len > 0) {
        try w.writeAll("capabilities=");
        for (c.array.items, 0..) |x, i| if (x == .string) try w.print("{s}{s}", .{ if (i > 0) "," else "", x.string });
        try w.writeAll("\n");
    };
    if (fstr(v, "parameters")) |p| try w.print("parameters:\n{s}\n", .{clip(p, 1000)});
    if (fstr(v, "system")) |s| try w.print("system: {s}\n", .{clip(s, 300)});
    if (fstr(v, "template")) |t| try w.print("template: {d} bytes\n", .{t.len});
    return capOut(alloc, aw.written(), "output too large");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Mock = struct {
    var last_method: std.http.Method = .GET;
    var last_url: []const u8 = "";
    var last_bearer: ?[]const u8 = null;
    var last_body: ?[]const u8 = null;
    var calls: u32 = 0;
    var status: u16 = 200;
    var response: []const u8 = "{}";
    var fail_with: ?anyerror = null;

    fn freeLast() void {
        const a = std.testing.allocator;
        if (last_url.len > 0) a.free(last_url);
        if (last_bearer) |b| a.free(b);
        if (last_body) |b| a.free(b);
        last_url = "";
        last_bearer = null;
        last_body = null;
    }
    fn fetch(_: std.mem.Allocator, _: std.Io, req: FetchRequest) anyerror!HttpResp {
        const a = std.testing.allocator;
        freeLast();
        last_method = req.method;
        last_url = try a.dupe(u8, req.url);
        last_bearer = if (req.bearer) |b| try a.dupe(u8, b) else null;
        last_body = if (req.body) |b| try a.dupe(u8, b) else null;
        calls += 1;
        if (fail_with) |e| return e;
        return .{ .status = status, .body = response };
    }
    fn reset(env_pairs: []const [2][]const u8, resp: []const u8) void {
        freeLast();
        calls = 0;
        status = 200;
        response = resp;
        fail_with = null;
        fetch_impl = fetch;
        test_env = env_pairs;
    }
};

const env_default = [_][2][]const u8{};
const env_key = [_][2][]const u8{ .{ "OPENAI_BASE_URL", "http://127.0.0.1:8080/v1/" }, .{ "OPENAI_API_KEY", "sk-secret-123" }, .{ "ZMCP_LLM_MODEL", "qwen-default" } };

fn parseArgs(alloc: std.mem.Allocator, s: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, alloc, s, .{});
}

const chat_ok =
    \\{"model":"qwen-default","choices":[{"message":{"role":"assistant","content":"Hello there"},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":3,"total_tokens":15}}
;

test "tool table: schemas valid, marks, and compact size" {
    var total: usize = 0;
    for (tool_table) |t| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), t.input_schema_json, .{});
        try std.testing.expect(v == .object);
        try std.testing.expect(!(t.read_only and t.destructive));
        try std.testing.expect(!t.destructive);
        const expect_ro = !(std.mem.eql(u8, t.name, "llm_chat") or std.mem.eql(u8, t.name, "llm_embed"));
        try std.testing.expectEqual(expect_ro, t.read_only);
        total += t.description.len + t.input_schema_json.len + t.name.len;
    }
    try std.testing.expectEqual(@as(usize, 6), tool_table.len);
    try std.testing.expect(total < 3000);
}

test "chat: model default resolution, body shape, bearer auth, usage line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    Mock.reset(&env_key, chat_ok);
    defer Mock.reset(&.{}, "{}");
    const r = try handleChat(a, undefined, try parseArgs(a, "{\"prompt\":\"hi\",\"system\":\"be brief\",\"json_mode\":true,\"temperature\":0.2}"));
    try std.testing.expect(!r.is_error);
    try std.testing.expect(std.mem.startsWith(u8, r.text, "Hello there"));
    try std.testing.expect(std.mem.indexOf(u8, r.text, "[qwen-default in=12 out=3 finish=stop]") != null);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/v1/chat/completions", Mock.last_url);
    try std.testing.expectEqualStrings("sk-secret-123", Mock.last_bearer.?);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "sk-secret") == null);
    const sent = try parseArgs(a, Mock.last_body.?);
    try std.testing.expectEqualStrings("qwen-default", fstr(sent, "model").?);
    try std.testing.expect(!field(sent, "stream").?.bool);
    try std.testing.expectEqualStrings("json_object", fstr(field(sent, "response_format").?, "type").?);
    try std.testing.expectEqual(@as(i64, 4096), field(sent, "max_tokens").?.integer);
    const ms = field(sent, "messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), ms.len);
    try std.testing.expectEqualStrings("system", fstr(ms[0], "role").?);
    try std.testing.expectEqualStrings("hi", fstr(ms[1], "content").?);
}

test "chat: explicit model beats env, max_tokens capped, no json_mode key, no auth header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = [_][2][]const u8{.{ "ZMCP_LLM_MAX_TOKENS", "100" }};
    Mock.reset(&e, chat_ok);
    defer Mock.reset(&.{}, "{}");
    const r = try handleChat(a, undefined, try parseArgs(a, "{\"model\":\"m1\",\"messages\":[{\"role\":\"user\",\"content\":\"x\"}],\"max_tokens\":99999}"));
    try std.testing.expect(!r.is_error);
    try std.testing.expectEqualStrings("http://127.0.0.1:11434/v1/chat/completions", Mock.last_url);
    try std.testing.expect(Mock.last_bearer == null);
    const sent = try parseArgs(a, Mock.last_body.?);
    try std.testing.expectEqualStrings("m1", fstr(sent, "model").?);
    try std.testing.expectEqual(@as(i64, 100), field(sent, "max_tokens").?.integer);
    try std.testing.expect(field(sent, "response_format") == null);
    try std.testing.expect(field(sent, "temperature") == null);
}

test "chat: input validation, no request sent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = [_][2][]const u8{.{ "ZMCP_LLM_MAX_PROMPT_BYTES", "300" }};
    Mock.reset(&e, chat_ok);
    defer Mock.reset(&.{}, "{}");
    var r = try handleChat(a, undefined, try parseArgs(a, "{\"prompt\":\"hi\"}"));
    try std.testing.expect(r.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "no model") != null);
    r = try handleChat(a, undefined, try parseArgs(a, "{\"model\":\"m\"}"));
    try std.testing.expect(r.is_error);
    r = try handleChat(a, undefined, try parseArgs(a, "{\"model\":\"m\",\"system\":\"s\"}"));
    try std.testing.expect(r.is_error);
    r = try handleChat(a, undefined, try parseArgs(a, "{\"model\":\"m\",\"messages\":[{\"role\":\"wizard\",\"content\":\"x\"}]}"));
    try std.testing.expect(r.is_error);
    const big = try a.alloc(u8, 400);
    @memset(big, 'a');
    r = try handleChat(a, undefined, try parseArgs(a, try std.fmt.allocPrint(a, "{{\"model\":\"m\",\"prompt\":\"{s}\"}}", .{big})));
    try std.testing.expect(r.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "over the 300 byte cap") != null);
    try std.testing.expectEqual(@as(u32, 0), Mock.calls);
}

test "chat: output cap, reasoning-only reply, length finish" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long = try a.alloc(u8, MAX_OUT + 500);
    @memset(long, 'z');
    const resp = try std.fmt.allocPrint(a, "{{\"choices\":[{{\"message\":{{\"content\":\"{s}\"}},\"finish_reason\":\"length\"}}]}}", .{long});
    Mock.reset(&env_key, resp);
    defer Mock.reset(&.{}, "{}");
    var r = try handleChat(a, undefined, try parseArgs(a, "{\"prompt\":\"hi\"}"));
    try std.testing.expect(!r.is_error);
    try std.testing.expect(r.text.len < MAX_OUT + 200);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "truncated") != null);

    Mock.reset(&env_key, "{\"choices\":[{\"message\":{\"content\":null,\"reasoning_content\":\"thinking hard\"},\"finish_reason\":\"length\"}]}");
    r = try handleChat(a, undefined, try parseArgs(a, "{\"prompt\":\"hi\"}"));
    try std.testing.expect(std.mem.indexOf(u8, r.text, "raise max_tokens") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "(cut at max_tokens)") != null);
}

test "error mapping 401/404/429/500 and model-not-found hint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    Mock.reset(&env_key, "{}");
    defer Mock.reset(&.{}, "{}");
    const cases = [_]struct { st: u16, body: []const u8, want: []const u8 }{
        .{ .st = 401, .body = "{\"error\":{\"message\":\"Incorrect API key provided: sk-secret-123\"}}", .want = "set/fix OPENAI_API_KEY" },
        .{ .st = 404, .body = "{\"error\":{\"message\":\"The model `foo` does not exist\"}}", .want = "model not found: pick an id from llm_models" },
        .{ .st = 404, .body = "{\"error\":\"model 'foo' not found, try pulling it first\"}", .want = "ollama pull" },
        .{ .st = 404, .body = "<html>nope</html>", .want = "check OPENAI_BASE_URL" },
        .{ .st = 429, .body = "{\"error\":{\"message\":\"Rate limit reached\"}}", .want = "rate limited" },
        .{ .st = 500, .body = "{\"error\":{\"message\":\"boom\"}}", .want = "server error" },
        .{ .st = 400, .body = "{\"error\":{\"message\":\"maximum context length is 4096\"}}", .want = "context" },
    };
    for (cases) |c| {
        Mock.status = c.st;
        Mock.response = c.body;
        const r = try handleChat(a, undefined, try parseArgs(a, "{\"prompt\":\"hi\"}"));
        try std.testing.expect(r.is_error);
        try std.testing.expect(std.mem.indexOf(u8, r.text, c.want) != null);
        try std.testing.expect(std.mem.indexOf(u8, r.text, "sk-secret-123") == null);
    }
    // detail is clipped and the status is present
    Mock.status = 500;
    Mock.response = "{\"error\":{\"message\":\"boom\"}}";
    const r = try handleChat(a, undefined, try parseArgs(a, "{\"prompt\":\"hi\"}"));
    try std.testing.expect(std.mem.startsWith(u8, r.text, "HTTP 500:"));
    try std.testing.expect(std.mem.indexOf(u8, r.text, "(boom)") != null);
}

test "transport failures: unreachable and timeout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    Mock.reset(&env_key, "{}");
    defer Mock.reset(&.{}, "{}");
    Mock.fail_with = error.ConnectionRefused;
    var r = try handleChat(a, undefined, try parseArgs(a, "{\"prompt\":\"hi\"}"));
    try std.testing.expect(r.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "cannot reach http://127.0.0.1:8080") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "sk-secret") == null);
    Mock.fail_with = error.Timeout;
    r = try handleChat(a, undefined, try parseArgs(a, "{\"prompt\":\"hi\"}"));
    try std.testing.expect(std.mem.indexOf(u8, r.text, "timed out after 120s") != null);
    Mock.response = "<html>";
    Mock.fail_with = null;
    r = try handleChat(a, undefined, try parseArgs(a, "{\"prompt\":\"hi\"}"));
    try std.testing.expect(std.mem.indexOf(u8, r.text, "non-JSON") != null);
}

test "base url parsing and loopback" {
    const b = try parseBase("http://localhost:1234/v1//");
    try std.testing.expectEqualStrings("http://localhost:1234/v1", b.base);
    try std.testing.expectEqualStrings("http://localhost:1234", b.origin);
    try std.testing.expectEqual(@as(?u16, 1234), b.port);
    try std.testing.expect(isLoopback(b.host));
    const o = try parseBase("https://openrouter.ai/api/v1");
    try std.testing.expectEqualStrings("https://openrouter.ai", o.origin);
    try std.testing.expect(!isLoopback(o.host));
    try std.testing.expect(o.port == null);
    try std.testing.expect(isLoopback((try parseBase("http://[::1]:8080/v1")).host));
    try std.testing.expectError(error.UserinfoNotAllowed, parseBase("http://user:pw@host/v1"));
    try std.testing.expectError(error.BadScheme, parseBase("file:///etc/passwd"));
    try std.testing.expectError(error.BadScheme, parseBase("host:8080/v1"));
}

test "ollama tools enabled only for the Ollama port unless forced" {
    test_env = &.{};
    defer test_env = null;
    try std.testing.expect(ollamaEnabled());
    test_env = &[_][2][]const u8{.{ "OPENAI_BASE_URL", "http://127.0.0.1:8080/v1" }};
    try std.testing.expect(!ollamaEnabled());
    test_env = &[_][2][]const u8{ .{ "OPENAI_BASE_URL", "http://127.0.0.1:8080/v1" }, .{ "ZMCP_LLM_OLLAMA", "1" } };
    try std.testing.expect(ollamaEnabled());
    test_env = &[_][2][]const u8{.{ "ZMCP_LLM_OLLAMA", "0" }};
    try std.testing.expect(!ollamaEnabled());
}

const models_openai =
    \\{"object":"list","data":[{"id":"gpt-4o","object":"model","owned_by":"openai"},{"id":"Gpt-3.5","object":"model"}]}
;
const models_openrouter =
    \\{"data":[{"id":"openai/gpt-4o","context_length":128000,"pricing":{"prompt":"0.0000025","completion":"0.00001"}},{"id":"meta/llama-free","context_length":8192,"pricing":{"prompt":"0","completion":"0"}},{"id":"anthropic/x","top_provider":{"context_length":200000},"pricing":{"prompt":"0.000003","completion":"0.000015"}}]}
;
const models_ollama_native =
    \\{"models":[{"name":"llama3:8b","size":4661224676},{"name":"qwen2.5:7b"}]}
;

test "models compaction: OpenAI, OpenRouter, Ollama shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    Mock.reset(&env_default, models_openai);
    defer Mock.reset(&.{}, "{}");
    var r = try handleModels(a, undefined, try parseArgs(a, "{}"));
    try std.testing.expectEqualStrings("id\nGpt-3.5\ngpt-4o\n", r.text);
    try std.testing.expectEqualStrings("http://127.0.0.1:11434/v1/models", Mock.last_url);

    Mock.response = models_openrouter;
    r = try handleModels(a, undefined, try parseArgs(a, "{}"));
    try std.testing.expect(std.mem.indexOf(u8, r.text, "id  ctx  price(in/out per 1M tok)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "anthropic/x  200k  $3/$15\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "meta/llama-free  8192  $0/$0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "openai/gpt-4o  128k  $2.5/$10\n") != null);
    // sorted
    try std.testing.expect(std.mem.indexOf(u8, r.text, "anthropic").? < std.mem.indexOf(u8, r.text, "openai").?);

    r = try handleModels(a, undefined, try parseArgs(a, "{\"filter\":\"GPT\"}"));
    try std.testing.expect(std.mem.indexOf(u8, r.text, "anthropic") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "openai/gpt-4o") != null);

    r = try handleModels(a, undefined, try parseArgs(a, "{\"limit\":1}"));
    try std.testing.expect(std.mem.indexOf(u8, r.text, "... 2 more") != null);

    Mock.response = models_ollama_native;
    r = try handleModels(a, undefined, try parseArgs(a, "{}"));
    try std.testing.expectEqualStrings("id\nllama3:8b\nqwen2.5:7b\n", r.text);

    r = try handleModels(a, undefined, try parseArgs(a, "{\"filter\":\"zzz\"}"));
    try std.testing.expectEqualStrings("no models match", r.text);

    Mock.response = "{\"nope\":1}";
    r = try handleModels(a, undefined, try parseArgs(a, "{}"));
    try std.testing.expect(r.is_error);
}

test "models: llama-server meta.n_ctx_train and vLLM max_model_len" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    Mock.reset(&env_default, "{\"data\":[{\"id\":\"a.gguf\",\"meta\":{\"n_ctx_train\":32768}},{\"id\":\"b\",\"max_model_len\":4096}]}");
    defer Mock.reset(&.{}, "{}");
    const r = try handleModels(a, undefined, try parseArgs(a, "{}"));
    try std.testing.expectEqualStrings("id  ctx\na.gguf  32768\nb  4096\n", r.text);
}

test "cosine math on known vectors" {
    const a = [_]f64{ 1, 0 };
    const b = [_]f64{ 0, 1 };
    const c = [_]f64{ 2, 0 };
    const d = [_]f64{ 1, 1 };
    try std.testing.expectApproxEqAbs(@as(f64, 0), cosine(&a, &b).?, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1), cosine(&a, &c).?, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7071067811865475), cosine(&a, &d).?, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -1), cosine(&a, &[_]f64{ -3, 0 }).?, 1e-12);
    try std.testing.expect(cosine(&a, &[_]f64{ 0, 0 }) == null);
    try std.testing.expect(cosine(&a, &[_]f64{ 1, 0, 0 }) == null);
}

const embed_resp =
    \\{"model":"emb","data":[{"index":1,"embedding":[0,1,0]},{"index":0,"embedding":[1,0,0]},{"index":2,"embedding":[1,1,0]}]}
;

test "embed: summary by default, full capped, similarity mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = [_][2][]const u8{.{ "ZMCP_LLM_MODEL", "emb" }};
    Mock.reset(&e, embed_resp);
    defer Mock.reset(&.{}, "{}");

    // two inputs; response given out of order is re-sorted by index (3 items returned, expect count mismatch -> error)
    var r = try handleEmbed(a, undefined, try parseArgs(a, "{\"input\":[\"a\",\"b\"]}"));
    try std.testing.expect(r.is_error);

    Mock.response = "{\"model\":\"emb\",\"data\":[{\"index\":1,\"embedding\":[0,1,0]},{\"index\":0,\"embedding\":[1,0,0]}]}";
    r = try handleEmbed(a, undefined, try parseArgs(a, "{\"input\":[\"a\",\"b\"]}"));
    try std.testing.expect(!r.is_error);
    try std.testing.expect(std.mem.startsWith(u8, r.text, "dim=3 count=2 model=emb\n"));
    try std.testing.expect(std.mem.indexOf(u8, r.text, "[0] 1.00000 0.00000 0.00000\n") != null);
    try std.testing.expectEqualStrings("http://127.0.0.1:11434/v1/embeddings", Mock.last_url);
    const sent = try parseArgs(a, Mock.last_body.?);
    try std.testing.expectEqual(@as(usize, 2), field(sent, "input").?.array.items.len);

    // preview truncation for wide vectors
    Mock.response = "{\"data\":[{\"embedding\":[1,2,3,4,5,6,7,8]}]}";
    r = try handleEmbed(a, undefined, try parseArgs(a, "{\"input\":\"a\"}"));
    try std.testing.expect(std.mem.indexOf(u8, r.text, "... (2 more)") != null);
    r = try handleEmbed(a, undefined, try parseArgs(a, "{\"input\":\"a\",\"full\":true}"));
    try std.testing.expect(std.mem.indexOf(u8, r.text, "8.00000") != null);

    // full cap
    var big: std.Io.Writer.Allocating = .init(a);
    try big.writer.writeAll("{\"data\":[{\"embedding\":[");
    for (0..3000) |i| try big.writer.print("{s}0.5", .{if (i > 0) "," else ""});
    try big.writer.writeAll("]}]}");
    Mock.response = big.written();
    r = try handleEmbed(a, undefined, try parseArgs(a, "{\"input\":\"a\",\"full\":true}"));
    try std.testing.expect(std.mem.indexOf(u8, r.text, "capped at 2048") != null);
    try std.testing.expect(r.text.len < 2048 * 9 + 300);

    // similarity: input a vs compare_to [b, c]; vectors a=[1,0,0], b=[0,1,0], c=[1,1,0]
    Mock.response = "{\"model\":\"emb\",\"data\":[{\"index\":0,\"embedding\":[1,0,0]},{\"index\":1,\"embedding\":[0,1,0]},{\"index\":2,\"embedding\":[1,1,0]}]}";
    r = try handleEmbed(a, undefined, try parseArgs(a, "{\"input\":\"a\",\"compare_to\":[\"bee\",\"cee\"]}"));
    try std.testing.expect(!r.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "input[0] ~ compare_to[1]: 0.7071  \"cee\"\ninput[0] ~ compare_to[0]: 0.0000  \"bee\"") != null);
    const sent2 = try parseArgs(a, Mock.last_body.?);
    try std.testing.expectEqual(@as(usize, 3), field(sent2, "input").?.array.items.len);

    // bad input types
    r = try handleEmbed(a, undefined, try parseArgs(a, "{\"input\":[1,2]}"));
    try std.testing.expect(r.is_error);
}

test "ollama tools: list, ps, show request shape and formatting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    Mock.reset(&env_key, "{\"models\":[{\"name\":\"llama3:8b\",\"size\":4661224676,\"details\":{\"parameter_size\":\"8.0B\",\"quantization_level\":\"Q4_0\"}}]}");
    defer Mock.reset(&.{}, "{}");
    var r = try handleOllamaList(a, undefined, try parseArgs(a, "{}"));
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/api/tags", Mock.last_url);
    try std.testing.expect(Mock.last_method == .GET);
    try std.testing.expectEqualStrings("name  size  params  quant\nllama3:8b  4.7GB  8.0B  Q4_0\n", r.text);

    Mock.response = "{\"models\":[{\"name\":\"llama3:8b\",\"size\":5000000000,\"size_vram\":5000000000,\"expires_at\":\"2026-01-01T00:00:00Z\"}]}";
    r = try handleOllamaPs(a, undefined, try parseArgs(a, "{}"));
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/api/ps", Mock.last_url);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "llama3:8b  5.0GB  5.0GB  -  2026-01-01T00:00:00Z") != null);

    Mock.response = "{\"details\":{\"family\":\"llama\",\"parameter_size\":\"8.0B\",\"quantization_level\":\"Q4_0\",\"format\":\"gguf\"},\"model_info\":{\"general.architecture\":\"llama\",\"llama.context_length\":8192},\"capabilities\":[\"completion\",\"tools\"],\"template\":\"{{ .Prompt }}\",\"parameters\":\"stop \\\"<|eot|>\\\"\"}";
    r = try handleOllamaShow(a, undefined, try parseArgs(a, "{\"model\":\"llama3:8b\"}"));
    try std.testing.expect(Mock.last_method == .POST);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/api/show", Mock.last_url);
    try std.testing.expect(std.mem.indexOf(u8, Mock.last_body.?, "\"model\":\"llama3:8b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "family=llama params=8.0B quant=Q4_0 format=gguf") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "context_length=8192") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "capabilities=completion,tools") != null);

    Mock.fail_with = error.ConnectionRefused;
    r = try handleOllamaPs(a, undefined, try parseArgs(a, "{}"));
    try std.testing.expect(r.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "need an Ollama server") != null);
}

// End-to-end against a tiny in-process HTTP server using the real transport.
// Skipped when sockets are unavailable in the sandbox.
const E2e = struct {
    fn serve(io: std.Io, server: *std.Io.net.Server, seen: *[2048]u8, seen_len: *usize) void {
        var stream = server.accept(io) catch return;
        defer stream.close(io);
        var rbuf: [4096]u8 = undefined;
        var rd = stream.reader(io, &rbuf);
        var acc: [8192]u8 = undefined;
        var n: usize = 0;
        var need: usize = 0;
        while (n < acc.len) {
            var slice: [1][]u8 = .{acc[n..]};
            const got = rd.interface.readVec(&slice) catch break;
            if (got == 0) break;
            n += got;
            if (std.mem.indexOf(u8, acc[0..n], "\r\n\r\n")) |he| {
                if (need == 0) {
                    need = he + 4;
                    if (std.ascii.indexOfIgnoreCase(acc[0..he], "content-length: ")) |ci| {
                        const rest = acc[ci + 16 .. he];
                        const e = std.mem.indexOfScalar(u8, rest, '\r') orelse rest.len;
                        need += std.fmt.parseInt(usize, rest[0..e], 10) catch 0;
                    }
                }
                if (n >= need) break;
            }
        }
        const m = @min(n, seen.len);
        @memcpy(seen[0..m], acc[0..m]);
        seen_len.* = m;
        const body = chat_ok;
        var wbuf: [512]u8 = undefined;
        var wr = stream.writer(io, &wbuf);
        wr.interface.print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch return;
        wr.interface.flush() catch {};
    }
};

test "end-to-end: real transport against an in-process HTTP server" {
    const io = std.testing.io;
    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = addr.listen(io, .{ .reuse_address = true }) catch return error.SkipZigTest;
    defer server.deinit(io);
    const port = server.socket.address.getPort();
    var seen: [2048]u8 = undefined;
    var seen_len: usize = 0;
    var fut = io.concurrent(E2e.serve, .{ io, &server, &seen, &seen_len }) catch return error.SkipZigTest;
    defer fut.cancel(io);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1", .{port});
    const e = [_][2][]const u8{ .{ "OPENAI_BASE_URL", base }, .{ "OPENAI_API_KEY", "sk-e2e-secret" }, .{ "ZMCP_LLM_MODEL", "tiny" }, .{ "ZMCP_LLM_TIMEOUT_SECS", "10" } };
    test_env = &e;
    fetch_impl = httpsFetch;
    defer {
        test_env = null;
        fetch_impl = httpsFetch;
    }
    const r = try handleChat(a, io, try parseArgs(a, "{\"prompt\":\"ping\"}"));
    try std.testing.expect(!r.is_error);
    try std.testing.expect(std.mem.startsWith(u8, r.text, "Hello there"));
    fut.await(io);
    const req = seen[0..seen_len];
    try std.testing.expect(std.mem.startsWith(u8, req, "POST /v1/chat/completions HTTP/1.1"));
    try std.testing.expect(std.ascii.indexOfIgnoreCase(req, "authorization: Bearer sk-e2e-secret") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"model\":\"tiny\"") != null);
}

const Stall = struct {
    fn serve(io: std.Io, server: *std.Io.net.Server) void {
        var stream = server.accept(io) catch return;
        defer stream.close(io);
        // Never answer; hold the connection until canceled.
        const t: std.Io.Timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(30), .clock = .awake } };
        t.sleep(io) catch {};
    }
};

test "end-to-end: whole-request timeout fires against a stalled server" {
    const io = std.testing.io;
    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = addr.listen(io, .{ .reuse_address = true }) catch return error.SkipZigTest;
    defer server.deinit(io);
    const port = server.socket.address.getPort();
    var fut = io.concurrent(Stall.serve, .{ io, &server }) catch return error.SkipZigTest;
    defer fut.cancel(io);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1", .{port});
    const e = [_][2][]const u8{ .{ "OPENAI_BASE_URL", base }, .{ "ZMCP_LLM_MODEL", "tiny" }, .{ "ZMCP_LLM_TIMEOUT_SECS", "1" } };
    test_env = &e;
    fetch_impl = httpsFetch;
    defer test_env = null;
    const r = try handleChat(a, io, try parseArgs(a, "{\"prompt\":\"ping\"}"));
    try std.testing.expect(r.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "timed out after 1s") != null);
}
