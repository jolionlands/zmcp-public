//! zmcp-minimax — pure-Zig port of ~/.pi/agent/extensions/minimax/server.mjs.
//!
//! The reference is a thin shim that shells out to the mmx CLI
//! (cli-tools/mmx-cli); this port calls the MiniMax REST API directly.
//!
//! Tools (same names/schemas as the reference):
//!   describe_image     vision via /v1/coding_plan/vlm (base64 data-URI upload)
//!   web_search         /v1/coding_plan/search organic results
//!   generate_image     image-01 via /v1/image_generation, saves JPG to %TEMP%
//!   synthesize_speech  speech-2.8-hd via /v1/t2a_v2 (hex audio), saves to %TEMP%
//!   generate_music     music-2.6 via /v1/music_generation (hex audio)
//!   generate_video     Hailuo-2.3 via /v1/video_generation + task polling
//!   quota              /v1/token_plan/remains weekly quota per model
//!
//! Auth mirrors mmx: MINIMAX_API_KEY env > ~/.mmx/config.json `api_key`.
//! Region: MINIMAX_REGION env > config `region` > "global"
//! (global = api.minimax.io, cn = api.minimaxi.com). A missing key is a clean
//! MCP error, never a crash.
//!
//! Network access goes through the FetchFn seam so tests inject canned HTTP.
//!
//! Parity deviations vs the reference:
//!   - mmx's OAuth flow (~/.mmx/credentials.json) is not ported; only the
//!     static api_key from config.json / MINIMAX_API_KEY is used.
//!   - Reference wrapped failures in JSON-RPC errors; this port returns MCP
//!     tool results with is_error=true (zmcp convention).
//!   - No retry/backoff, no --stream TTS/music modes, no subject-reference
//!     (S2V) video mode, no subtitles, no interactive prompts.

const std = @import("std");
const mcp = @import("mcp");

/// The `io` handed to `main`; environment lookups go through `mcp.envAlloc`,
/// which reads the real process environment behind it on every OS.
var g_env_io: ?std.Io = null;

/// Owned copy of environment variable `key` (caller frees), or null if unset.
fn envOwned(alloc: std.mem.Allocator, key: []const u8) ?[]u8 {
    const io = g_env_io orelse return null;
    return mcp.envAlloc(alloc, io, key);
}


const UA_PRODUCT = "zmcp-minimax/0.3.0";

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    g_env_io = init.io;
    try mcp.run(arena, init.io, .{ .name = "minimax", .version = "0.3.0" }, &tool_table);
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "describe_image",
        .read_only = true,
        .description = "Send a local image file to MiniMax vision-01 for description / OCR / Q&A. Use this when the active model is text-only or when you want a second opinion on what a screenshot or attached file actually depicts.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "path": { "type": "string", "description": "Absolute path to a local image (png/jpg/jpeg/gif/webp)." },
        \\    "prompt": { "type": "string", "description": "Optional: a specific question about the image." }
        \\  },
        \\  "required": ["path"]
        \\}
        ,
        .handler = handleDescribeImage,
    },
    .{
        .name = "web_search",
        .read_only = true,
        .description = "Web search powered by MiniMax. Returns up to N organic results with title, link, snippet. Use this to look up current events, docs, GitHub issues, anything outside the model's training data.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "query": { "type": "string", "description": "Search query." },
        \\    "limit": { "type": "integer", "description": "Max organic results (default 10)." }
        \\  },
        \\  "required": ["query"]
        \\}
        ,
        .handler = handleWebSearch,
    },
    .{
        .name = "generate_image",
        .description = "Generate an image with MiniMax image-01. Returns the local file path of the saved PNG. Use this when the user asks for an illustration / mockup / placeholder image.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "prompt": { "type": "string", "description": "Image description." },
        \\    "aspect_ratio": { "type": "string", "description": "e.g. '16:9', '1:1'. Ignored if width+height set." },
        \\    "width": { "type": "integer", "description": "Width in px [512-2048, mult of 8]. Overrides aspect_ratio." },
        \\    "height": { "type": "integer", "description": "Height in px [512-2048, mult of 8]." },
        \\    "seed": { "type": "integer", "description": "Reproducibility seed." },
        \\    "prompt_optimizer": { "type": "boolean", "description": "Auto-rewrite the prompt for better results." }
        \\  },
        \\  "required": ["prompt"]
        \\}
        ,
        .handler = handleGenerateImage,
    },
    .{
        .name = "synthesize_speech",
        .description = "Text-to-speech with MiniMax speech-2.8-hd. Returns the local path of the saved mp3 file.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "text": { "type": "string", "description": "Text to speak (up to 10k chars)." },
        \\    "voice": { "type": "string", "description": "Voice id (default: English_expressive_narrator)." },
        \\    "speed": { "type": "number", "description": "Speech speed multiplier (e.g. 0.8, 1.2)." },
        \\    "format": { "type": "string", "description": "Audio format (default mp3)." }
        \\  },
        \\  "required": ["text"]
        \\}
        ,
        .handler = handleSynthesizeSpeech,
    },
    .{
        .name = "generate_music",
        .description = "Generate a song with MiniMax music-2.6. Returns the local path of the saved audio file. Provide either `lyrics` (with structure tags like [Verse], [Chorus]) or set `instrumental=true`.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "prompt": { "type": "string", "description": "Music style description, e.g. 'cinematic orchestral'." },
        \\    "lyrics": { "type": "string", "description": "Song lyrics with [Verse]/[Chorus] tags. Mutually exclusive with instrumental." },
        \\    "instrumental": { "type": "boolean", "description": "Generate without vocals." },
        \\    "genre": { "type": "string", "description": "e.g. folk, pop, jazz." },
        \\    "mood": { "type": "string", "description": "e.g. warm, melancholic, uplifting." },
        \\    "bpm": { "type": "integer", "description": "Exact tempo in BPM." }
        \\  },
        \\  "required": ["prompt"]
        \\}
        ,
        .handler = handleGenerateMusic,
    },
    .{
        .name = "generate_video",
        .description = "Generate a short video with MiniMax Hailuo-2.3. Async — returns the local path of the saved MP4 after the task completes (polled server-side). Optionally provide a first/last frame image for image-to-video or start-end-frame interpolation.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "prompt": { "type": "string", "description": "Video description." },
        \\    "first_frame": { "type": "string", "description": "Path or URL to the first frame image (enables I2V)." },
        \\    "last_frame": { "type": "string", "description": "Path or URL to the last frame; enables SEF interp with Hailuo-02." }
        \\  },
        \\  "required": ["prompt"]
        \\}
        ,
        .handler = handleGenerateVideo,
    },
    .{
        .name = "quota",
        .read_only = true,
        .description = "Show remaining MiniMax quota for every model on the active key. Use this before spending a generation.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {}
        \\}
        ,
        .handler = handleQuota,
    },
};

// ---------------------------------------------------------------------------
// HTTP fetch seam (tests swap in a mock)
// ---------------------------------------------------------------------------

pub const HttpResp = struct {
    status: u16,
    body: []const u8,
};

pub const FetchRequest = struct {
    method: std.http.Method,
    url: []const u8,
    auth_token: ?[]const u8 = null,
    body: ?[]const u8 = null,
};

pub const FetchFn = *const fn (alloc: std.mem.Allocator, io: std.Io, req: FetchRequest) anyerror!HttpResp;

fn httpsFetch(alloc: std.mem.Allocator, io: std.Io, req: FetchRequest) !HttpResp {
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();
    const ua_owned = try mcp.userAgent(alloc, io, UA_PRODUCT);
    defer alloc.free(ua_owned);

    var resp_buf: std.Io.Writer.Allocating = .init(alloc);
    defer resp_buf.deinit();
    var decompress_buf: [128 * 1024]u8 = undefined;

    var header_buf: [4]std.http.Header = undefined;
    var n: usize = 0;
    header_buf[n] = .{ .name = "User-Agent", .value = ua_owned };
    n += 1;
    header_buf[n] = .{ .name = "Accept", .value = "application/json" };
    n += 1;
    if (req.body != null) {
        header_buf[n] = .{ .name = "Content-Type", .value = "application/json" };
        n += 1;
    }
    var auth_value: [520]u8 = undefined;
    if (req.auth_token) |t| {
        const v = std.fmt.bufPrint(&auth_value, "Bearer {s}", .{t}) catch return error.TokenTooLong;
        header_buf[n] = .{ .name = "Authorization", .value = v };
        n += 1;
    }

    const fetch_res = try client.fetch(.{
        .location = .{ .url = req.url },
        .response_writer = &resp_buf.writer,
        .method = req.method,
        .payload = req.body,
        .extra_headers = header_buf[0..n],
        .decompress_buffer = &decompress_buf,
    });

    return .{
        .status = @intFromEnum(fetch_res.status),
        .body = try alloc.dupe(u8, resp_buf.written()),
    };
}

// ---------------------------------------------------------------------------
// Config / credential resolution (mirrors mmx config/loader.ts + schema.ts)
// ---------------------------------------------------------------------------

pub const Region = enum { global, cn };

pub const Config = struct {
    api_key: ?[]const u8 = null,
    region: Region = .global,
    base_url: ?[]const u8 = null,
    timeout_s: u32 = 300,
};

pub const EnvOverrides = struct {
    api_key: ?[]const u8 = null, // MINIMAX_API_KEY
    region: ?[]const u8 = null, // MINIMAX_REGION
    base_url: ?[]const u8 = null, // MINIMAX_BASE_URL
};

fn parseRegion(s: []const u8) ?Region {
    if (std.mem.eql(u8, s, "global")) return .global;
    if (std.mem.eql(u8, s, "cn")) return .cn;
    return null;
}

/// Pure config resolution: parse ~/.mmx/config.json content (tolerantly, like
/// mmx parseConfigFile), then apply env overrides. Never fails on bad input.
/// String values are duped into `alloc` so they stay valid after the parsed
/// JSON tree is torn down.
pub fn resolveConfig(alloc: std.mem.Allocator, file_json: ?[]const u8, env: EnvOverrides) Config {
    var cfg = Config{};
    if (file_json) |fj| {
        if (std.json.parseFromSlice(std.json.Value, alloc, fj, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                const o = parsed.value.object;
                if (o.get("api_key")) |v| {
                    if (v == .string) cfg.api_key = alloc.dupe(u8, v.string) catch null;
                }
                if (o.get("region")) |v| {
                    if (v == .string) {
                        if (parseRegion(v.string)) |r| cfg.region = r;
                    }
                }
                if (o.get("base_url")) |v| {
                    if (v == .string and std.mem.startsWith(u8, v.string, "http")) cfg.base_url = alloc.dupe(u8, v.string) catch null;
                }
                if (o.get("timeout")) |v| {
                    const t: i64 = switch (v) {
                        .integer => |i| i,
                        .float => |f| if (f > 0 and f < 1e15) @as(i64, @intFromFloat(f)) else 0,
                        else => 0,
                    };
                    if (t > 0) cfg.timeout_s = std.math.cast(u32, t) orelse std.math.maxInt(u32);
                }
            }
        } else |_| {}
    }
    if (env.api_key) |k| cfg.api_key = k;
    if (env.region) |r| {
        if (parseRegion(r)) |reg| cfg.region = reg;
    }
    if (env.base_url) |b| cfg.base_url = b;
    return cfg;
}

pub fn effectiveBaseUrl(cfg: Config) []const u8 {
    if (cfg.base_url) |b| return b;
    return switch (cfg.region) {
        .global => "https://api.minimax.io",
        .cn => "https://api.minimaxi.com",
    };
}

fn getEnv(alloc: std.mem.Allocator, key: []const u8) ?[]u8 {
    return envOwned(alloc, key);
}

fn configPath(alloc: std.mem.Allocator) ?[]const u8 {
    const home = getEnv(alloc, "USERPROFILE") orelse getEnv(alloc, "HOME") orelse return null;
    return std.fmt.allocPrint(alloc, "{s}/.mmx/config.json", .{home}) catch null;
}

fn loadConfig(alloc: std.mem.Allocator, io: std.Io) Config {
    var file_json: ?[]const u8 = null;
    if (configPath(alloc)) |p| {
        file_json = std.Io.Dir.cwd().readFileAlloc(io, p, alloc, .limited(64 * 1024)) catch null;
    }
    return resolveConfig(alloc, file_json, .{
        .api_key = getEnv(alloc, "MINIMAX_API_KEY"),
        .region = getEnv(alloc, "MINIMAX_REGION"),
        .base_url = getEnv(alloc, "MINIMAX_BASE_URL"),
    });
}

// ---------------------------------------------------------------------------
// Endpoint URL builders (port of mmx client/endpoints.ts)
// ---------------------------------------------------------------------------

pub fn vlmUrl(alloc: std.mem.Allocator, cfg: Config) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/v1/coding_plan/vlm", .{effectiveBaseUrl(cfg)});
}

pub fn searchUrl(alloc: std.mem.Allocator, cfg: Config) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/v1/coding_plan/search", .{effectiveBaseUrl(cfg)});
}

pub fn imageUrl(alloc: std.mem.Allocator, cfg: Config) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/v1/image_generation", .{effectiveBaseUrl(cfg)});
}

pub fn speechUrl(alloc: std.mem.Allocator, cfg: Config) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/v1/t2a_v2", .{effectiveBaseUrl(cfg)});
}

pub fn musicUrl(alloc: std.mem.Allocator, cfg: Config) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/v1/music_generation", .{effectiveBaseUrl(cfg)});
}

pub fn videoGenUrl(alloc: std.mem.Allocator, cfg: Config) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/v1/video_generation", .{effectiveBaseUrl(cfg)});
}

pub fn videoTaskUrl(alloc: std.mem.Allocator, cfg: Config, task_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/v1/query/video_generation?task_id={s}", .{ effectiveBaseUrl(cfg), task_id });
}

pub fn fileRetrieveUrl(alloc: std.mem.Allocator, cfg: Config, file_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/v1/files/retrieve?file_id={s}", .{ effectiveBaseUrl(cfg), file_id });
}

pub fn quotaUrl(alloc: std.mem.Allocator, cfg: Config) ![]const u8 {
    // Quota endpoint always uses the api subdomain for the region.
    const host = switch (cfg.region) {
        .global => "https://api.minimax.io",
        .cn => "https://api.minimaxi.com",
    };
    return std.fmt.allocPrint(alloc, "{s}/v1/token_plan/remains", .{host});
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

/// Port of the reference's extractJson: skip banner/progress lines and parse
/// from the first '{'. Returns null when no JSON object parses (JSON.parse is
/// strict about trailing junk; so is std.json).
pub fn extractJson(alloc: std.mem.Allocator, out: []const u8) ?std.json.Parsed(std.json.Value) {
    const start = std.mem.indexOfScalar(u8, out, '{') orelse return null;
    return std.json.parseFromSlice(std.json.Value, alloc, out[start..], .{}) catch return null;
}

fn jStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return if (f == .string) f.string else null;
}

fn jObj(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return if (f == .object) f else null;
}

fn jNum(v: std.json.Value, key: []const u8) ?f64 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return switch (f) {
        .integer => |i| @floatFromInt(i),
        .float => |x| x,
        else => null,
    };
}

fn baseRespCode(v: std.json.Value) ?i64 {
    const br = jObj(v, "base_resp") orelse return null;
    const n = jNum(br, "status_code") orelse return null;
    return @intFromFloat(n);
}

fn baseRespMsg(v: std.json.Value) ?[]const u8 {
    const br = jObj(v, "base_resp") orelse return null;
    return jStr(br, "status_msg");
}

fn argStr(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn argNum(args: std.json.Value, key: []const u8) ?f64 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn argBool(args: std.json.Value, key: []const u8, default: bool) bool {
    if (args != .object) return default;
    const v = args.object.get(key) orelse return default;
    return if (v == .bool) v.bool else default;
}

fn argInt(args: std.json.Value, key: []const u8) ?i64 {
    const n = argNum(args, key) orelse return null;
    return @intFromFloat(@trunc(n));
}

const Civil = struct { y: i32, m: u8, d: u8, hh: u8, mm: u8, ss: u8 };

fn unixToCivil(ts: i64) Civil {
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, ts)) };
    const day = epoch.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = epoch.getDaySeconds();
    return .{
        .y = @intCast(yd.year),
        .m = @intFromEnum(md.month),
        .d = md.day_index + 1,
        .hh = ds.getHoursIntoDay(),
        .mm = ds.getMinutesIntoHour(),
        .ss = ds.getSecondsIntoMinute(),
    };
}

fn nowSeconds(io: std.Io) i64 {
    const ts = std.Io.Timestamp.now(io, .real);
    return @divFloor(ts.toMilliseconds(), 1000);
}

/// 14-char basic-ISO UTC stamp, matching the reference's tsStamp()
/// (toISOString stripped of -:.TZ).
pub fn tsStamp(buf: []u8, now_secs: i64) []const u8 {
    const c = unixToCivil(now_secs);
    const yu: u32 = @intCast(@max(0, c.y));
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}", .{ yu, c.m, c.d, c.hh, c.mm, c.ss }) catch unreachable;
}

pub fn mimeForPath(path: []const u8) ?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return null;
    const ext = path[dot..];
    var lower_buf: [16]u8 = undefined;
    if (ext.len > lower_buf.len) return null;
    const lower = std.ascii.lowerString(&lower_buf, ext);
    if (std.mem.eql(u8, lower, ".jpg") or std.mem.eql(u8, lower, ".jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, lower, ".png")) return "image/png";
    if (std.mem.eql(u8, lower, ".webp")) return "image/webp";
    return null;
}

/// Read a local image file and build a data URI (mmx toDataUri, local branch).
pub fn imageDataUri(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const mime = mimeForPath(path) orelse return error.UnsupportedImageFormat;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(50 * 1024 * 1024)) catch return error.FileNotFound;
    const enc = std.base64.standard.Encoder;
    const out = try alloc.alloc(u8, enc.calcSize(bytes.len));
    _ = enc.encode(out, bytes);
    return std.fmt.allocPrint(alloc, "data:{s};base64,{s}", .{ mime, out });
}

/// mmx models.ts: sk-cp- keys (Token Plan) get paid models, others free tier.
pub fn musicModelForKey(key: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, key, "sk-cp-")) "music-2.6" else "music-2.6-free";
}

/// mmx video model auto-switch: last_frame => Hailuo-02 (SEF), else Hailuo-2.3.
pub fn videoModel(has_last_frame: bool) []const u8 {
    return if (has_last_frame) "MiniMax-Hailuo-02" else "MiniMax-Hailuo-2.3";
}

// ---------------------------------------------------------------------------
// Request body builders (ports of the mmx command payloads)
// ---------------------------------------------------------------------------

const JsonBody = struct {
    sw: std.Io.Writer.Allocating,
    js: std.json.Stringify,

    /// Out-pointer init: js.writer points into sw, so the struct must not be
    /// moved after this call.
    fn init(b: *JsonBody, alloc: std.mem.Allocator) void {
        b.sw = .init(alloc);
        b.js = .{ .writer = &b.sw.writer };
    }

    fn finish(self: *JsonBody) []const u8 {
        return self.sw.written();
    }
};

/// mmx structuredParts: genre/mood/bpm merged into the prompt text.
pub fn buildStructuredPrompt(alloc: std.mem.Allocator, prompt: []const u8, genre: ?[]const u8, mood: ?[]const u8, bpm: ?i64) ![]const u8 {
    var parts: std.ArrayList(u8) = .empty;
    try parts.appendSlice(alloc, prompt);
    var extra: std.ArrayList(u8) = .empty;
    if (genre) |g| try extra.appendSlice(alloc, try std.fmt.allocPrint(alloc, "Genre: {s}", .{g}));
    if (mood) |m| {
        if (extra.items.len > 0) try extra.appendSlice(alloc, ". ");
        try extra.appendSlice(alloc, try std.fmt.allocPrint(alloc, "Mood: {s}", .{m}));
    }
    if (bpm) |b| {
        if (extra.items.len > 0) try extra.appendSlice(alloc, ". ");
        try extra.appendSlice(alloc, try std.fmt.allocPrint(alloc, "BPM: {d}", .{b}));
    }
    if (extra.items.len > 0) {
        try parts.appendSlice(alloc, ". ");
        try parts.appendSlice(alloc, extra.items);
    }
    return parts.items;
}

pub fn buildSearchBody(alloc: std.mem.Allocator, query: []const u8) ![]const u8 {
    var b: JsonBody = undefined;
    JsonBody.init(&b, alloc);
    try b.js.beginObject();
    try b.js.objectField("q");
    try b.js.write(query);
    try b.js.endObject();
    return b.finish();
}

pub fn buildVlmBody(alloc: std.mem.Allocator, prompt: []const u8, image_url: []const u8) ![]const u8 {
    var b: JsonBody = undefined;
    JsonBody.init(&b, alloc);
    try b.js.beginObject();
    try b.js.objectField("prompt");
    try b.js.write(prompt);
    try b.js.objectField("image_url");
    try b.js.write(image_url);
    try b.js.endObject();
    return b.finish();
}

pub fn buildImageBody(
    alloc: std.mem.Allocator,
    prompt: []const u8,
    aspect_ratio: ?[]const u8,
    width: ?i64,
    height: ?i64,
    seed: ?i64,
    prompt_optimizer: bool,
) ![]const u8 {
    var b: JsonBody = undefined;
    JsonBody.init(&b, alloc);
    try b.js.beginObject();
    try b.js.objectField("model");
    try b.js.write("image-01");
    try b.js.objectField("prompt");
    try b.js.write(prompt);
    // mmx: explicit width+height override/ignore aspect_ratio.
    if (width != null and height != null) {
        try b.js.objectField("width");
        try b.js.write(width.?);
        try b.js.objectField("height");
        try b.js.write(height.?);
    } else if (aspect_ratio) |ar| {
        try b.js.objectField("aspect_ratio");
        try b.js.write(ar);
    }
    if (seed) |s| {
        try b.js.objectField("seed");
        try b.js.write(s);
    }
    if (prompt_optimizer) {
        try b.js.objectField("prompt_optimizer");
        try b.js.write(true);
    }
    try b.js.endObject();
    return b.finish();
}

pub fn buildSpeechBody(alloc: std.mem.Allocator, text: []const u8, voice: []const u8, speed: ?f64, format: []const u8) ![]const u8 {
    var b: JsonBody = undefined;
    JsonBody.init(&b, alloc);
    try b.js.beginObject();
    try b.js.objectField("model");
    try b.js.write("speech-2.8-hd");
    try b.js.objectField("text");
    try b.js.write(text);
    try b.js.objectField("voice_setting");
    try b.js.beginObject();
    try b.js.objectField("voice_id");
    try b.js.write(voice);
    if (speed) |s| {
        try b.js.objectField("speed");
        try b.js.write(s);
    }
    try b.js.endObject();
    try b.js.objectField("audio_setting");
    try b.js.beginObject();
    try b.js.objectField("format");
    try b.js.write(format);
    try b.js.objectField("sample_rate");
    try b.js.write(@as(i64, 32000));
    try b.js.objectField("bitrate");
    try b.js.write(@as(i64, 128000));
    try b.js.objectField("channel");
    try b.js.write(@as(i64, 1));
    try b.js.endObject();
    try b.js.objectField("output_format");
    try b.js.write("hex");
    try b.js.objectField("stream");
    try b.js.write(false);
    try b.js.endObject();
    return b.finish();
}

pub fn buildMusicBody(
    alloc: std.mem.Allocator,
    model: []const u8,
    prompt: []const u8,
    lyrics: ?[]const u8,
    is_instrumental: bool,
    lyrics_optimizer: bool,
) ![]const u8 {
    var b: JsonBody = undefined;
    JsonBody.init(&b, alloc);
    try b.js.beginObject();
    try b.js.objectField("model");
    try b.js.write(model);
    try b.js.objectField("prompt");
    try b.js.write(prompt);
    if (lyrics) |l| {
        try b.js.objectField("lyrics");
        try b.js.write(l);
    }
    if (is_instrumental) {
        try b.js.objectField("is_instrumental");
        try b.js.write(true);
    }
    if (lyrics_optimizer) {
        try b.js.objectField("lyrics_optimizer");
        try b.js.write(true);
    }
    try b.js.objectField("audio_setting");
    try b.js.beginObject();
    try b.js.objectField("format");
    try b.js.write("mp3");
    try b.js.objectField("sample_rate");
    try b.js.write(@as(i64, 44100));
    try b.js.objectField("bitrate");
    try b.js.write(@as(i64, 256000));
    try b.js.endObject();
    try b.js.objectField("output_format");
    try b.js.write("hex");
    try b.js.objectField("stream");
    try b.js.write(false);
    try b.js.endObject();
    return b.finish();
}

pub fn buildVideoBody(
    alloc: std.mem.Allocator,
    model: []const u8,
    prompt: []const u8,
    first_frame: ?[]const u8,
    last_frame: ?[]const u8,
) ![]const u8 {
    var b: JsonBody = undefined;
    JsonBody.init(&b, alloc);
    try b.js.beginObject();
    try b.js.objectField("model");
    try b.js.write(model);
    try b.js.objectField("prompt");
    try b.js.write(prompt);
    if (first_frame) |f| {
        try b.js.objectField("first_frame_image");
        try b.js.write(f);
    }
    if (last_frame) |f| {
        try b.js.objectField("last_frame_image");
        try b.js.write(f);
    }
    try b.js.endObject();
    return b.finish();
}

// ---------------------------------------------------------------------------
// Hex audio decoding (port of mmx output/audio.ts saveAudioOutput validation)
// ---------------------------------------------------------------------------

pub fn decodeHexAudio(alloc: std.mem.Allocator, hex: []const u8) ![]const u8 {
    if (hex.len == 0) return error.EmptyAudio;
    for (hex) |c| {
        if (!std.ascii.isHex(c)) return error.InvalidAudioHex;
    }
    if (hex.len % 2 != 0) return error.TruncatedAudioHex;
    const out = try alloc.alloc(u8, hex.len / 2);
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        out[i] = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch return error.InvalidAudioHex;
    }
    return out;
}

// ---------------------------------------------------------------------------
// Error mapping (port of mmx errors/api.ts mapApiError)
// ---------------------------------------------------------------------------

fn planHintForUrl(url: []const u8) []const u8 {
    if (std.mem.indexOf(u8, url, "/t2a") != null) return "\n\nSpeech models require the Plus plan or above.";
    if (std.mem.indexOf(u8, url, "/image_generation") != null) return "\n\nimage-01 requires the Plus plan or above.";
    if (std.mem.indexOf(u8, url, "/video_generation") != null) return "\n\nVideo models (Hailuo-2.3 / 2.3-Fast) require the Max plan or above.";
    if (std.mem.indexOf(u8, url, "/music_generation") != null) return "\n\nMusic-2.6 requires the Max plan or above.";
    return "";
}

fn upgradeUrl(url: []const u8) []const u8 {
    if (std.mem.indexOf(u8, url, "minimaxi.com") != null) return "https://platform.minimaxi.com/subscribe/token-plan";
    return "https://platform.minimax.io/subscribe/token-plan";
}

pub fn mapApiError(alloc: std.mem.Allocator, status: u16, body: []const u8, url: []const u8) ![]const u8 {
    var api_msg: ?[]const u8 = null;
    var api_code: ?i64 = null;
    var parse_buf: [256 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&parse_buf);
    if (std.json.parseFromSlice(std.json.Value, fba.allocator(), body, .{})) |parsed| {
        api_msg = baseRespMsg(parsed.value);
        api_code = baseRespCode(parsed.value);
        if (api_msg == null) {
            if (jObj(parsed.value, "error")) |e| api_msg = jStr(e, "message");
        }
        if (api_code == null) {
            if (jObj(parsed.value, "error")) |e| {
                if (jNum(e, "code")) |c| api_code = @intFromFloat(c);
            }
        }
    } else |_| {}
    const msg = api_msg orelse "";

    if (status == 401 or status == 403) {
        return std.fmt.allocPrint(alloc, "API key rejected (HTTP {d}). Check the api_key in ~/.mmx/config.json.", .{status});
    }
    if (status == 429) {
        return std.fmt.allocPrint(alloc, "Rate limit or quota exceeded. {s}", .{msg});
    }
    if (status == 408 or status == 504) {
        return std.fmt.allocPrint(alloc, "Request timed out (HTTP {d}). Retry later.", .{status});
    }
    if (api_code) |code| {
        if (code == 1002 or code == 1039) {
            return std.fmt.allocPrint(alloc, "Input content flagged by sensitivity filter ({s}).", .{msg});
        }
        if (code == 1028 or code == 1030) {
            return std.fmt.allocPrint(alloc, "Quota exhausted. {s}\nCheck usage with the quota tool.{s}\nUpgrade plan: {s}", .{ msg, planHintForUrl(url), upgradeUrl(url) });
        }
        if (code == 2061) {
            return std.fmt.allocPrint(alloc, "This model is not available on your current Token Plan. {s}{s}\nUpgrade plan: {s}", .{ msg, planHintForUrl(url), upgradeUrl(url) });
        }
    }
    if (api_msg != null) {
        return std.fmt.allocPrint(alloc, "API error: {s} (HTTP {d})", .{ msg, status });
    }
    return std.fmt.allocPrint(alloc, "API error: HTTP {d}", .{status});
}

// ---------------------------------------------------------------------------
// Response formatting (ports of the reference shim's text shaping)
// ---------------------------------------------------------------------------

pub fn formatSearchResults(alloc: std.mem.Allocator, organic: std.json.Value, limit: i64) ![]const u8 {
    if (organic != .array) return "(no results)";
    const items = organic.array.items;
    const n: usize = @intCast(@max(0, @min(limit, @as(i64, @intCast(items.len)))));
    if (n == 0) return "(no results)";
    var out: std.Io.Writer.Allocating = .init(alloc);
    for (items[0..n], 0..) |r, i| {
        if (i > 0) try out.writer.writeAll("\n\n");
        const title = jStr(r, "title") orelse "";
        const link = jStr(r, "link") orelse "";
        const snippet = jStr(r, "snippet") orelse "";
        try out.writer.print("{d}. {s}\n   {s}\n   {s}", .{ i + 1, title, link, snippet });
    }
    return out.written();
}

pub fn formatQuota(alloc: std.mem.Allocator, model_remains: std.json.Value) ![]const u8 {
    if (model_remains != .array) return "";
    var out: std.Io.Writer.Allocating = .init(alloc);
    for (model_remains.array.items, 0..) |m, i| {
        const used = jNum(m, "current_weekly_usage_count") orelse 0;
        const total = jNum(m, "current_weekly_total_count") orelse 0;
        const pct: i64 = if (total > 0) @intFromFloat(@round(used / total * 100.0)) else 0;
        if (i > 0) try out.writer.writeByte('\n');
        try out.writer.print("{s}: {d}/{d} weekly ({d}%)", .{
            jStr(m, "model_name") orelse "?",
            @as(i64, @intFromFloat(used)),
            @as(i64, @intFromFloat(total)),
            pct,
        });
    }
    return out.written();
}

// ---------------------------------------------------------------------------
// Media save / download
// ---------------------------------------------------------------------------

pub fn saveMedia(alloc: std.mem.Allocator, io: std.Io, out_dir: []const u8, filename: []const u8, bytes: []const u8) ![]const u8 {
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, out_dir, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = filename, .data = bytes });
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ out_dir, filename });
}

const SaveOutcome = union(enum) { ok: []const u8, err: mcp.ToolResult };

fn downloadToFile(alloc: std.mem.Allocator, io: std.Io, fetch: FetchFn, url: []const u8, out_dir: []const u8, filename: []const u8) !SaveOutcome {
    const resp = fetch(alloc, io, .{ .method = .GET, .url = url }) catch |err| {
        return .{ .err = .{ .text = try std.fmt.allocPrint(alloc, "Network error downloading media: {s}", .{@errorName(err)}), .is_error = true } };
    };
    if (resp.status < 200 or resp.status >= 300) {
        return .{ .err = .{ .text = try std.fmt.allocPrint(alloc, "Download failed: HTTP {d}", .{resp.status}), .is_error = true } };
    }
    const path = saveMedia(alloc, io, out_dir, filename, resp.body) catch |err| {
        return .{ .err = .{ .text = try std.fmt.allocPrint(alloc, "Failed to save file: {s}", .{@errorName(err)}), .is_error = true } };
    };
    return .{ .ok = path };
}

// ---------------------------------------------------------------------------
// Authenticated JSON API helper
// ---------------------------------------------------------------------------

const ApiOutcome = union(enum) { ok: std.json.Value, err: mcp.ToolResult };

const no_key_msg = "No MiniMax API key configured. Set api_key in ~/.mmx/config.json (or the MINIMAX_API_KEY environment variable).";

fn apiJson(alloc: std.mem.Allocator, io: std.Io, fetch: FetchFn, cfg: Config, method: std.http.Method, url: []const u8, body: ?[]const u8) !ApiOutcome {
    const key = cfg.api_key orelse return .{ .err = .{ .text = no_key_msg, .is_error = true } };
    const resp = fetch(alloc, io, .{ .method = method, .url = url, .auth_token = key, .body = body }) catch |err| {
        return .{ .err = .{ .text = try std.fmt.allocPrint(alloc, "Network error contacting MiniMax: {s}", .{@errorName(err)}), .is_error = true } };
    };
    if (resp.status < 200 or resp.status >= 300) {
        return .{ .err = .{ .text = try mapApiError(alloc, resp.status, resp.body, url), .is_error = true } };
    }
    const parsed = extractJson(alloc, resp.body) orelse {
        return .{ .err = .{ .text = "MiniMax API returned a non-JSON response. The server may be experiencing issues.", .is_error = true } };
    };
    if (baseRespCode(parsed.value)) |code| {
        if (code != 0) {
            return .{ .err = .{ .text = try mapApiError(alloc, 200, resp.body, url), .is_error = true } };
        }
    }
    return .{ .ok = parsed.value };
}

// ---------------------------------------------------------------------------
// Video polling (port of mmx polling/poll.ts)
// ---------------------------------------------------------------------------

const PollOutcome = union(enum) {
    success: []const u8, // file_id
    failed: []const u8, // error text
};

fn pollVideoTask(
    alloc: std.mem.Allocator,
    io: std.Io,
    fetch: FetchFn,
    cfg: Config,
    task_id: []const u8,
    interval_ms: u64,
    max_polls: u32,
) !PollOutcome {
    const url = try videoTaskUrl(alloc, cfg, task_id);
    var n: u32 = 0;
    while (n < max_polls) : (n += 1) {
        const v = switch (try apiJson(alloc, io, fetch, cfg, .GET, url, null)) {
            .err => |tr| return .{ .failed = tr.text },
            .ok => |v| v,
        };
        const status = jStr(v, "status") orelse "Unknown";
        if (std.mem.eql(u8, status, "Success")) {
            const fid = jStr(v, "file_id") orelse {
                return .{ .failed = "Task completed but no file_id returned." };
            };
            return .{ .success = fid };
        }
        if (std.mem.eql(u8, status, "Failed")) {
            const extra = baseRespMsg(v) orelse "";
            return .{ .failed = try std.fmt.allocPrint(alloc, "Task Failed. ({s})", .{extra}) };
        }
        if (interval_ms > 0) {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(interval_ms)), .awake) catch {};
        }
    }
    return .{ .failed = "Polling timed out. Check the task status manually or increase the timeout." };
}

// ---------------------------------------------------------------------------
// Tool implementations — each takes a FetchFn so tests inject canned HTTP.
// ---------------------------------------------------------------------------

pub const ImplOpts = struct {
    out_dir: []const u8 = ".",
    stamp: []const u8 = "00000000000000",
    poll_interval_ms: u64 = 5000,
    max_polls: u32 = 60,
};

fn errResult(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !mcp.ToolResult {
    return .{ .text = try std.fmt.allocPrint(alloc, fmt, args), .is_error = true };
}

fn describeImageImpl(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value, cfg: Config, fetch: FetchFn) !mcp.ToolResult {
    const path = argStr(args, "path") orelse {
        return .{ .text = "path is required", .is_error = true };
    };
    const prompt = argStr(args, "prompt") orelse "Describe the image.";

    const data_uri = imageDataUri(alloc, io, path) catch |err| switch (err) {
        error.FileNotFound => return errResult(alloc, "file not found: {s}", .{path}),
        error.UnsupportedImageFormat => return .{ .text = "Unsupported image format. Supported: jpg, jpeg, png, webp", .is_error = true },
        else => return err,
    };

    const body = try buildVlmBody(alloc, prompt, data_uri);
    const v = switch (try apiJson(alloc, io, fetch, cfg, .POST, try vlmUrl(alloc, cfg), body)) {
        .err => |tr| return tr,
        .ok => |v| v,
    };
    const content = jStr(v, "content") orelse {
        return .{ .text = "MiniMax vlm response missing content field.", .is_error = true };
    };
    return .{ .text = content };
}

fn webSearchImpl(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value, cfg: Config, fetch: FetchFn) !mcp.ToolResult {
    const query = argStr(args, "query") orelse {
        return .{ .text = "query is required", .is_error = true };
    };
    const limit: i64 = argInt(args, "limit") orelse 10;

    const body = try buildSearchBody(alloc, query);
    const v = switch (try apiJson(alloc, io, fetch, cfg, .POST, try searchUrl(alloc, cfg), body)) {
        .err => |tr| return tr,
        .ok => |v| v,
    };
    const organic = v.object.get("organic") orelse return .{ .text = "(no results)" };
    return .{ .text = try formatSearchResults(alloc, organic, limit) };
}

fn generateImageImpl(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value, cfg: Config, opts: ImplOpts, fetch: FetchFn) !mcp.ToolResult {
    const prompt = argStr(args, "prompt") orelse {
        return .{ .text = "prompt is required", .is_error = true };
    };
    const body = try buildImageBody(
        alloc,
        prompt,
        argStr(args, "aspect_ratio"),
        argInt(args, "width"),
        argInt(args, "height"),
        argInt(args, "seed"),
        argBool(args, "prompt_optimizer", false),
    );
    const v = switch (try apiJson(alloc, io, fetch, cfg, .POST, try imageUrl(alloc, cfg), body)) {
        .err => |tr| return tr,
        .ok => |v| v,
    };
    const data = jObj(v, "data") orelse {
        return .{ .text = "image_generation response missing data field.", .is_error = true };
    };
    const urls: []const std.json.Value = if (data.object.get("image_urls")) |u|
        (if (u == .array) u.array.items else &[_]std.json.Value{})
    else
        &[_]std.json.Value{};

    const prefix = try std.fmt.allocPrint(alloc, "pid_mmx_img_{s}", .{opts.stamp});
    var saved: std.ArrayList(u8) = .empty;
    for (urls, 0..) |u, i| {
        const url = if (u == .string) u.string else continue;
        const filename = try std.fmt.allocPrint(alloc, "{s}_{d:0>3}.jpg", .{ prefix, i + 1 });
        const path = switch (try downloadToFile(alloc, io, fetch, url, opts.out_dir, filename)) {
            .err => |tr| return tr,
            .ok => |p| p,
        };
        if (saved.items.len > 0) try saved.append(alloc, '\n');
        try saved.appendSlice(alloc, path);
    }
    if (urls.len == 0) {
        return .{ .text = "MiniMax returned no image URLs.", .is_error = true };
    }
    return .{ .text = try std.fmt.allocPrint(alloc, "Generated image(s) saved under {s} with prefix '{s}'.\n\n{s}", .{ opts.out_dir, prefix, saved.items }) };
}

fn saveHexAudio(alloc: std.mem.Allocator, io: std.Io, v: std.json.Value, out_dir: []const u8, filename: []const u8) !SaveOutcome {
    const data = jObj(v, "data") orelse {
        return .{ .err = .{ .text = "API response missing data field.", .is_error = true } };
    };
    const hex = jStr(data, "audio") orelse {
        return .{ .err = .{ .text = "API response missing audio data (audio field is empty).", .is_error = true } };
    };
    const bytes = decodeHexAudio(alloc, hex) catch |err| switch (err) {
        error.EmptyAudio => return .{ .err = .{ .text = "API response missing audio data (audio field is empty).", .is_error = true } },
        error.InvalidAudioHex => return .{ .err = .{ .text = "API returned invalid audio data (not valid hex).", .is_error = true } },
        error.TruncatedAudioHex => return .{ .err = .{ .text = "API returned truncated audio data (odd-length hex string).", .is_error = true } },
        else => return err,
    };
    const path = saveMedia(alloc, io, out_dir, filename, bytes) catch |err| {
        return .{ .err = .{ .text = try std.fmt.allocPrint(alloc, "Failed to save file: {s}", .{@errorName(err)}), .is_error = true } };
    };
    return .{ .ok = path };
}

fn synthesizeSpeechImpl(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value, cfg: Config, opts: ImplOpts, fetch: FetchFn) !mcp.ToolResult {
    const text = argStr(args, "text") orelse {
        return .{ .text = "text is required", .is_error = true };
    };
    const format = argStr(args, "format") orelse "mp3";
    const voice = argStr(args, "voice") orelse "English_expressive_narrator";
    const speed = argNum(args, "speed");

    const body = try buildSpeechBody(alloc, text, voice, speed, format);
    const v = switch (try apiJson(alloc, io, fetch, cfg, .POST, try speechUrl(alloc, cfg), body)) {
        .err => |tr| return tr,
        .ok => |v| v,
    };
    const filename = try std.fmt.allocPrint(alloc, "pid_mmx_speech_{s}.{s}", .{ opts.stamp, format });
    const path = switch (try saveHexAudio(alloc, io, v, opts.out_dir, filename)) {
        .err => |tr| return tr,
        .ok => |p| p,
    };
    return .{ .text = try std.fmt.allocPrint(alloc, "Audio saved: {s}", .{path}) };
}

fn generateMusicImpl(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value, cfg: Config, opts: ImplOpts, fetch: FetchFn) !mcp.ToolResult {
    const prompt = argStr(args, "prompt") orelse {
        return .{ .text = "prompt is required", .is_error = true };
    };
    const lyrics = argStr(args, "lyrics");
    const instrumental = argBool(args, "instrumental", false);
    if (lyrics != null and instrumental) {
        return .{ .text = "lyrics and instrumental are mutually exclusive", .is_error = true };
    }
    // mmx: auto-generate lyrics when neither lyrics nor instrumental given.
    const optimizer = lyrics == null and !instrumental;

    const merged = try buildStructuredPrompt(alloc, prompt, argStr(args, "genre"), argStr(args, "mood"), argInt(args, "bpm"));
    const key = cfg.api_key orelse return .{ .text = no_key_msg, .is_error = true };
    const body = try buildMusicBody(alloc, musicModelForKey(key), merged, lyrics, instrumental, optimizer);
    const v = switch (try apiJson(alloc, io, fetch, cfg, .POST, try musicUrl(alloc, cfg), body)) {
        .err => |tr| return tr,
        .ok => |v| v,
    };
    const filename = try std.fmt.allocPrint(alloc, "pid_mmx_music_{s}.mp3", .{opts.stamp});
    const path = switch (try saveHexAudio(alloc, io, v, opts.out_dir, filename)) {
        .err => |tr| return tr,
        .ok => |p| p,
    };
    return .{ .text = try std.fmt.allocPrint(alloc, "Music saved: {s}", .{path}) };
}

fn frameArg(alloc: std.mem.Allocator, io: std.Io, path_or_url: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, path_or_url, "http")) return path_or_url;
    return imageDataUri(alloc, io, path_or_url) catch |err| switch (err) {
        error.FileNotFound => return error.FrameFileNotFound,
        error.UnsupportedImageFormat => return error.UnsupportedImageFormat,
        else => return err,
    };
}

fn generateVideoImpl(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value, cfg: Config, opts: ImplOpts, fetch: FetchFn) !mcp.ToolResult {
    const prompt = argStr(args, "prompt") orelse {
        return .{ .text = "prompt is required", .is_error = true };
    };
    const first_frame_arg = argStr(args, "first_frame");
    const last_frame_arg = argStr(args, "last_frame");
    if (last_frame_arg != null and first_frame_arg == null) {
        return .{ .text = "last_frame requires first_frame (SEF mode).", .is_error = true };
    }

    var first_frame: ?[]const u8 = null;
    var last_frame: ?[]const u8 = null;
    if (first_frame_arg) |f| {
        first_frame = frameArg(alloc, io, f) catch {
            return errResult(alloc, "file not found or unsupported image format: {s}", .{f});
        };
    }
    if (last_frame_arg) |f| {
        last_frame = frameArg(alloc, io, f) catch {
            return errResult(alloc, "file not found or unsupported image format: {s}", .{f});
        };
    }

    const body = try buildVideoBody(alloc, videoModel(last_frame != null), prompt, first_frame, last_frame);
    const v = switch (try apiJson(alloc, io, fetch, cfg, .POST, try videoGenUrl(alloc, cfg), body)) {
        .err => |tr| return tr,
        .ok => |v| v,
    };
    const task_id = jStr(v, "task_id") orelse {
        return .{ .text = "video_generation response missing task_id.", .is_error = true };
    };

    const file_id = switch (try pollVideoTask(alloc, io, fetch, cfg, task_id, opts.poll_interval_ms, opts.max_polls)) {
        .failed => |msg| return .{ .text = msg, .is_error = true },
        .success => |fid| fid,
    };

    const file_info = switch (try apiJson(alloc, io, fetch, cfg, .GET, try fileRetrieveUrl(alloc, cfg, file_id), null)) {
        .err => |tr| return tr,
        .ok => |fv| fv,
    };
    const file_obj = jObj(file_info, "file") orelse {
        return .{ .text = "files/retrieve response missing file field.", .is_error = true };
    };
    const download_url = jStr(file_obj, "download_url") orelse {
        return .{ .text = "No download URL available for this file.", .is_error = true };
    };

    const filename = try std.fmt.allocPrint(alloc, "pid_mmx_video_{s}.mp4", .{opts.stamp});
    const path = switch (try downloadToFile(alloc, io, fetch, download_url, opts.out_dir, filename)) {
        .err => |tr| return tr,
        .ok => |p| p,
    };
    return .{ .text = try std.fmt.allocPrint(alloc, "Video saved: {s}", .{path}) };
}

fn quotaImpl(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value, cfg: Config, fetch: FetchFn) !mcp.ToolResult {
    _ = args;
    const v = switch (try apiJson(alloc, io, fetch, cfg, .GET, try quotaUrl(alloc, cfg), null)) {
        .err => |tr| return tr,
        .ok => |v| v,
    };
    const models = v.object.get("model_remains") orelse return .{ .text = "" };
    return .{ .text = try formatQuota(alloc, models) };
}

// ---------------------------------------------------------------------------
// Tool handlers (thin wrappers binding the real HTTPS fetch)
// ---------------------------------------------------------------------------

fn tmpDirPath(alloc: std.mem.Allocator) ![]const u8 {
    if (getEnv(alloc, "TEMP")) |v| return v;
    if (getEnv(alloc, "TMP")) |v| return v;
    if (getEnv(alloc, "TMPDIR")) |v| return v;
    return alloc.dupe(u8, "/tmp");
}

fn mediaOpts(alloc: std.mem.Allocator, io: std.Io, cfg: Config) ImplOpts {
    var stamp_buf: [16]u8 = undefined;
    const stamp = alloc.dupe(u8, tsStamp(&stamp_buf, nowSeconds(io))) catch "00000000000000";
    const out_dir = tmpDirPath(alloc) catch ".";
    var max_polls: u32 = @intFromFloat(@ceil(@as(f64, @floatFromInt(cfg.timeout_s)) * 1000.0 / 5000.0));
    if (max_polls == 0) max_polls = 1;
    return .{ .out_dir = out_dir, .stamp = stamp, .poll_interval_ms = 5000, .max_polls = max_polls };
}

fn handleDescribeImage(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    return describeImageImpl(alloc, io, args, loadConfig(alloc, io), httpsFetch);
}

fn handleWebSearch(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    return webSearchImpl(alloc, io, args, loadConfig(alloc, io), httpsFetch);
}

fn handleGenerateImage(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const cfg = loadConfig(alloc, io);
    return generateImageImpl(alloc, io, args, cfg, mediaOpts(alloc, io, cfg), httpsFetch);
}

fn handleSynthesizeSpeech(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const cfg = loadConfig(alloc, io);
    return synthesizeSpeechImpl(alloc, io, args, cfg, mediaOpts(alloc, io, cfg), httpsFetch);
}

fn handleGenerateMusic(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const cfg = loadConfig(alloc, io);
    return generateMusicImpl(alloc, io, args, cfg, mediaOpts(alloc, io, cfg), httpsFetch);
}

fn handleGenerateVideo(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const cfg = loadConfig(alloc, io);
    return generateVideoImpl(alloc, io, args, cfg, mediaOpts(alloc, io, cfg), httpsFetch);
}

fn handleQuota(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    return quotaImpl(alloc, io, args, loadConfig(alloc, io), httpsFetch);
}

// ===========================================================================
// Tests (offline: scripted mock fetch, no network).
// ===========================================================================

const test_cfg = Config{ .api_key = "sk-cp-test" };

const no_key_cfg = Config{};

fn testAlloc(arena_state: *std.heap.ArenaAllocator) std.mem.Allocator {
    arena_state.* = std.heap.ArenaAllocator.init(std.testing.allocator);
    return arena_state.allocator();
}

fn parseArgs(alloc: std.mem.Allocator, s: []const u8) !std.json.Value {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, s, .{});
    return parsed.value;
}

// --- Scripted mock fetch -----------------------------------------------------

const MockStep = struct {
    url_part: []const u8,
    status: u16 = 200,
    body: []const u8,
};

var mock_steps: []const MockStep = &.{};
var mock_pos: usize = 0;

const MockCall = struct {
    url: [4096]u8 = undefined,
    url_len: usize = 0,
    body: [8192]u8 = undefined,
    body_len: usize = 0,
    auth: [256]u8 = undefined,
    auth_len: usize = 0,
    method: std.http.Method = .GET,
};

var mock_calls: [8]MockCall = .{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
var mock_call_count: usize = 0;

const MockCallView = struct {
    url: []const u8,
    body: []const u8,
    auth: []const u8,
    method: std.http.Method,
};

fn mockReset(steps: []const MockStep) void {
    mock_steps = steps;
    mock_pos = 0;
    mock_call_count = 0;
}

fn mockLast() MockCallView {
    return mockCall(mock_call_count - 1);
}

fn mockCall(i: usize) MockCallView {
    const c = &mock_calls[i];
    return .{
        .url = c.url[0..c.url_len],
        .body = c.body[0..c.body_len],
        .auth = c.auth[0..c.auth_len],
        .method = c.method,
    };
}

fn mockFetch(alloc: std.mem.Allocator, io: std.Io, req: FetchRequest) anyerror!HttpResp {
    _ = io;
    if (mock_call_count >= mock_calls.len) return error.TooManyMockCalls;
    const c = &mock_calls[mock_call_count];
    c.* = .{};
    @memcpy(c.url[0..req.url.len], req.url);
    c.url_len = req.url.len;
    if (req.body) |b| {
        @memcpy(c.body[0..b.len], b);
        c.body_len = b.len;
    }
    if (req.auth_token) |t| {
        @memcpy(c.auth[0..t.len], t);
        c.auth_len = t.len;
    }
    c.method = req.method;
    mock_call_count += 1;

    if (mock_pos >= mock_steps.len) return error.NoMoreMockSteps;
    const step = mock_steps[mock_pos];
    mock_pos += 1;
    if (std.mem.indexOf(u8, req.url, step.url_part) == null) return error.UnexpectedUrl;
    if (step.status == 0) return error.ConnectionRefused;
    return .{ .status = step.status, .body = try alloc.dupe(u8, step.body) };
}

fn tmpOutDir(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]const u8 {
    return std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{std.mem.sliceTo(&tmp.sub_path, 0)});
}

// --- Config / credential resolution ------------------------------------------

test "resolveConfig parses api_key, region, base_url, timeout" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    const cfg = resolveConfig(alloc,
        \\{"region":"cn","api_key":"sk-cp-abc","timeout":120,"base_url":"https://example.com","output":"json"}
    , .{});
    try std.testing.expectEqualStrings("sk-cp-abc", cfg.api_key.?);
    try std.testing.expect(cfg.region == .cn);
    try std.testing.expectEqualStrings("https://example.com", cfg.base_url.?);
    try std.testing.expectEqual(@as(u32, 120), cfg.timeout_s);
}

test "resolveConfig tolerates missing/corrupt/absent config file" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    const from_null = resolveConfig(alloc, null, .{});
    try std.testing.expect(from_null.api_key == null);
    try std.testing.expect(from_null.region == .global);
    try std.testing.expect(from_null.timeout_s == 300);

    const garbage = resolveConfig(alloc, "not json at all {{{", .{});
    try std.testing.expect(garbage.api_key == null);

    const wrong_types = resolveConfig(alloc,
        \\{"api_key":42,"region":"mars","timeout":-5}
    , .{});
    try std.testing.expect(wrong_types.api_key == null);
    try std.testing.expect(wrong_types.region == .global);
    try std.testing.expect(wrong_types.timeout_s == 300);
}

test "resolveConfig env overrides file" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    const cfg = resolveConfig(alloc,
        \\{"region":"global","api_key":"sk-file","base_url":"https://file.example.com"}
    , .{
        .api_key = "sk-env",
        .region = "cn",
        .base_url = "https://env.example.com",
    });
    try std.testing.expectEqualStrings("sk-env", cfg.api_key.?);
    try std.testing.expect(cfg.region == .cn);
    try std.testing.expectEqualStrings("https://env.example.com", cfg.base_url.?);
}

test "resolveConfig strings with escapes survive parse teardown" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    // Escaped strings are decoded into fresh allocations during parse; the
    // returned config must own dupes that outlive the parsed tree.
    const cfg = resolveConfig(alloc,
        \\{"api_key":"sk-cp-ab\"c\\d","base_url":"https://exa\tmple.com"}
    , .{});
    try std.testing.expectEqualStrings("sk-cp-ab\"c\\d", cfg.api_key.?);
    try std.testing.expectEqualStrings("https://exa\tmple.com", cfg.base_url.?);
}

test "resolveConfig clamps out-of-range timeout" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    const huge = resolveConfig(alloc, "{\"timeout\":9999999999999}", .{});
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), huge.timeout_s);

    const huge_float = resolveConfig(alloc, "{\"timeout\":1e300}", .{});
    try std.testing.expectEqual(@as(u32, 300), huge_float.timeout_s);
}

test "effectiveBaseUrl falls back to region host" {
    const global = effectiveBaseUrl(.{});
    try std.testing.expectEqualStrings("https://api.minimax.io", global);
    const cn = effectiveBaseUrl(.{ .region = .cn });
    try std.testing.expectEqualStrings("https://api.minimaxi.com", cn);
    const explicit = effectiveBaseUrl(.{ .base_url = "https://proxy.example.com" });
    try std.testing.expectEqualStrings("https://proxy.example.com", explicit);
}

// --- Endpoint URL builders ---------------------------------------------------

test "endpoint URLs match mmx endpoints.ts" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    try std.testing.expectEqualStrings("https://api.minimax.io/v1/coding_plan/vlm", try vlmUrl(alloc, test_cfg));
    try std.testing.expectEqualStrings("https://api.minimax.io/v1/coding_plan/search", try searchUrl(alloc, test_cfg));
    try std.testing.expectEqualStrings("https://api.minimax.io/v1/image_generation", try imageUrl(alloc, test_cfg));
    try std.testing.expectEqualStrings("https://api.minimax.io/v1/t2a_v2", try speechUrl(alloc, test_cfg));
    try std.testing.expectEqualStrings("https://api.minimax.io/v1/music_generation", try musicUrl(alloc, test_cfg));
    try std.testing.expectEqualStrings("https://api.minimax.io/v1/video_generation", try videoGenUrl(alloc, test_cfg));
    try std.testing.expectEqualStrings(
        "https://api.minimax.io/v1/query/video_generation?task_id=abc-123",
        try videoTaskUrl(alloc, test_cfg, "abc-123"),
    );
    try std.testing.expectEqualStrings(
        "https://api.minimax.io/v1/files/retrieve?file_id=file-9",
        try fileRetrieveUrl(alloc, test_cfg, "file-9"),
    );
    // quota always uses the api subdomain for the region
    try std.testing.expectEqualStrings("https://api.minimax.io/v1/token_plan/remains", try quotaUrl(alloc, test_cfg));
    const cn_cfg = Config{ .api_key = "k", .region = .cn };
    try std.testing.expectEqualStrings("https://api.minimaxi.com/v1/token_plan/remains", try quotaUrl(alloc, cn_cfg));
}

// --- extractJson (banner stripping) -------------------------------------------

test "extractJson strips banner/progress prefix like the reference" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    const with_banner = extractJson(alloc, "[Model: image-01]\nPolling... Done.\n{\"content\":\"hello\"}").?;
    try std.testing.expectEqualStrings("hello", with_banner.value.object.get("content").?.string);

    try std.testing.expect(extractJson(alloc, "no json here") == null);
    try std.testing.expect(extractJson(alloc, "") == null);
    try std.testing.expect(extractJson(alloc, "banner {\"a\":1} trailing junk") == null);
}

// --- tsStamp -------------------------------------------------------------------

test "tsStamp renders 14-char basic ISO UTC" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("19700101000000", tsStamp(&buf, 0));
    // 2023-11-14T22:13:20Z
    try std.testing.expectEqualStrings("20231114221320", tsStamp(&buf, 1700000000));
}

// --- mime / data URI ------------------------------------------------------------

test "mimeForPath matches mmx MIME_TYPES (no gif)" {
    try std.testing.expectEqualStrings("image/jpeg", mimeForPath("a/b/photo.jpg").?);
    try std.testing.expectEqualStrings("image/jpeg", mimeForPath("photo.JPEG").?);
    try std.testing.expectEqualStrings("image/png", mimeForPath("x.png").?);
    try std.testing.expectEqualStrings("image/webp", mimeForPath("x.webp").?);
    try std.testing.expect(mimeForPath("x.gif") == null);
    try std.testing.expect(mimeForPath("noext") == null);
}

test "imageDataUri base64-encodes a local file" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "img.png", .data = "PNG_BYTES" });
    const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/img.png", .{std.mem.sliceTo(&tmp.sub_path, 0)});

    const uri = try imageDataUri(alloc, std.testing.io, path);
    try std.testing.expectEqualStrings("data:image/png;base64,UE5HX0JZVEVT", uri);

    try std.testing.expectError(error.FileNotFound, imageDataUri(alloc, std.testing.io, ".zig-cache/tmp/definitely-missing.png"));
    try std.testing.expectError(error.UnsupportedImageFormat, imageDataUri(alloc, std.testing.io, "pic.gif"));
}

// --- model selection ------------------------------------------------------------

test "musicModelForKey follows mmx key-type default" {
    try std.testing.expectEqualStrings("music-2.6", musicModelForKey("sk-cp-abc"));
    try std.testing.expectEqualStrings("music-2.6-free", musicModelForKey("sk-api-abc"));
}

test "videoModelForArgs switches to Hailuo-02 with last_frame" {
    try std.testing.expectEqualStrings("MiniMax-Hailuo-2.3", videoModel(false));
    try std.testing.expectEqualStrings("MiniMax-Hailuo-02", videoModel(true));
}

// --- request body builders -------------------------------------------------------

test "buildStructuredPrompt appends genre/mood/bpm like mmx structuredParts" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    const merged = try buildStructuredPrompt(alloc, "cinematic orchestral", "folk", "warm", 95);
    try std.testing.expectEqualStrings("cinematic orchestral. Genre: folk. Mood: warm. BPM: 95", merged);

    const plain = try buildStructuredPrompt(alloc, "upbeat pop", null, null, null);
    try std.testing.expectEqualStrings("upbeat pop", plain);
}

test "buildSearchBody" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    const body = try buildSearchBody(alloc, "zig language");
    try std.testing.expectEqualStrings(
        \\{"q":"zig language"}
    , body);
}

test "buildImageBody aspect_ratio vs explicit size" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    const with_ratio = try parseArgs(alloc, try buildImageBody(alloc, "a cat", "16:9", null, null, null, false));
    try std.testing.expectEqualStrings("image-01", with_ratio.object.get("model").?.string);
    try std.testing.expectEqualStrings("16:9", with_ratio.object.get("aspect_ratio").?.string);
    try std.testing.expect(with_ratio.object.get("width") == null);
    try std.testing.expect(with_ratio.object.get("prompt_optimizer") == null);

    const with_size = try parseArgs(alloc, try buildImageBody(alloc, "a cat", "16:9", 1024, 512, 42, true));
    // explicit width+height override/ignore aspect_ratio (mmx behavior)
    try std.testing.expect(with_size.object.get("aspect_ratio") == null);
    try std.testing.expectEqual(@as(i64, 1024), with_size.object.get("width").?.integer);
    try std.testing.expectEqual(@as(i64, 512), with_size.object.get("height").?.integer);
    try std.testing.expectEqual(@as(i64, 42), with_size.object.get("seed").?.integer);
    try std.testing.expect(with_size.object.get("prompt_optimizer").?.bool);
}

test "buildSpeechBody matches mmx SpeechRequest" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    const v = try parseArgs(alloc, try buildSpeechBody(alloc, "Hello", "English_expressive_narrator", 1.2, "mp3"));
    try std.testing.expectEqualStrings("speech-2.8-hd", v.object.get("model").?.string);
    try std.testing.expectEqualStrings("Hello", v.object.get("text").?.string);
    const vs = v.object.get("voice_setting").?;
    try std.testing.expectEqualStrings("English_expressive_narrator", vs.object.get("voice_id").?.string);
    try std.testing.expectApproxEqAbs(1.2, vs.object.get("speed").?.float, 0.001);
    const as = v.object.get("audio_setting").?;
    try std.testing.expectEqualStrings("mp3", as.object.get("format").?.string);
    try std.testing.expectEqual(@as(i64, 32000), as.object.get("sample_rate").?.integer);
    try std.testing.expectEqual(@as(i64, 128000), as.object.get("bitrate").?.integer);
    try std.testing.expectEqual(@as(i64, 1), as.object.get("channel").?.integer);
    try std.testing.expectEqualStrings("hex", v.object.get("output_format").?.string);
    try std.testing.expect(v.object.get("stream").?.bool == false);

    // no speed -> speed field omitted
    const no_speed = try parseArgs(alloc, try buildSpeechBody(alloc, "Hi", "v", null, "wav"));
    try std.testing.expect(no_speed.object.get("voice_setting").?.object.get("speed") == null);
    try std.testing.expectEqualStrings("wav", no_speed.object.get("audio_setting").?.object.get("format").?.string);
}

test "buildMusicBody lyrics / instrumental / optimizer variants" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    const with_lyrics = try parseArgs(alloc, try buildMusicBody(alloc, "music-2.6", "folk ballad", "[Verse]\nla la", false, false));
    try std.testing.expectEqualStrings("music-2.6", with_lyrics.object.get("model").?.string);
    try std.testing.expectEqualStrings("[Verse]\nla la", with_lyrics.object.get("lyrics").?.string);
    try std.testing.expect(with_lyrics.object.get("is_instrumental") == null);
    try std.testing.expect(with_lyrics.object.get("lyrics_optimizer") == null);
    const as = with_lyrics.object.get("audio_setting").?;
    try std.testing.expectEqual(@as(i64, 44100), as.object.get("sample_rate").?.integer);
    try std.testing.expectEqual(@as(i64, 256000), as.object.get("bitrate").?.integer);
    try std.testing.expectEqualStrings("hex", with_lyrics.object.get("output_format").?.string);

    const instrumental = try parseArgs(alloc, try buildMusicBody(alloc, "music-2.6-free", "bgm", null, true, false));
    try std.testing.expect(instrumental.object.get("is_instrumental").?.bool);
    try std.testing.expect(instrumental.object.get("lyrics") == null);

    const optimizer = try parseArgs(alloc, try buildMusicBody(alloc, "music-2.6", "pop", null, false, true));
    try std.testing.expect(optimizer.object.get("lyrics_optimizer").?.bool);
}

test "buildVideoBody model, prompt, frame passthrough" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    const t2v = try parseArgs(alloc, try buildVideoBody(alloc, "MiniMax-Hailuo-2.3", "ocean waves", null, null));
    try std.testing.expectEqualStrings("MiniMax-Hailuo-2.3", t2v.object.get("model").?.string);
    try std.testing.expectEqualStrings("ocean waves", t2v.object.get("prompt").?.string);
    try std.testing.expect(t2v.object.get("first_frame_image") == null);

    const i2v = try parseArgs(alloc, try buildVideoBody(alloc, "MiniMax-Hailuo-2.3", "walk", "https://x/f.jpg", null));
    try std.testing.expectEqualStrings("https://x/f.jpg", i2v.object.get("first_frame_image").?.string);

    const sef = try parseArgs(alloc, try buildVideoBody(alloc, "MiniMax-Hailuo-02", "walk", "data:image/png;base64,AA", "data:image/png;base64,BB"));
    try std.testing.expectEqualStrings("data:image/png;base64,AA", sef.object.get("first_frame_image").?.string);
    try std.testing.expectEqualStrings("data:image/png;base64,BB", sef.object.get("last_frame_image").?.string);
}

// --- hex audio decoding -----------------------------------------------------------

test "decodeHexAudio validates like mmx saveAudioOutput" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    const bytes = try decodeHexAudio(alloc, "ff00AA");
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0x00, 0xaa }, bytes);

    try std.testing.expectError(error.EmptyAudio, decodeHexAudio(alloc, ""));
    try std.testing.expectError(error.InvalidAudioHex, decodeHexAudio(alloc, "zz"));
    try std.testing.expectError(error.InvalidAudioHex, decodeHexAudio(alloc, "ff 00"));
    try std.testing.expectError(error.TruncatedAudioHex, decodeHexAudio(alloc, "abc"));
}

// --- error mapping ------------------------------------------------------------------

test "mapApiError mirrors mmx mapApiError" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    const auth = try mapApiError(alloc, 401, "{}", "https://api.minimax.io/v1/t2a_v2");
    try std.testing.expect(std.mem.indexOf(u8, auth, "API key rejected") != null);
    try std.testing.expect(std.mem.indexOf(u8, auth, "401") != null);

    const rate = try mapApiError(alloc, 429, "{}", "https://api.minimax.io/x");
    try std.testing.expect(std.mem.indexOf(u8, rate, "Rate limit or quota exceeded") != null);

    const quota = try mapApiError(alloc, 200,
        \\{"base_resp":{"status_code":1028,"status_msg":"insufficient balance"}}
    , "https://api.minimax.io/v1/t2a_v2");
    try std.testing.expect(std.mem.indexOf(u8, quota, "Quota exhausted") != null);
    try std.testing.expect(std.mem.indexOf(u8, quota, "insufficient balance") != null);
    try std.testing.expect(std.mem.indexOf(u8, quota, "Plus plan") != null); // plan hint for t2a
    try std.testing.expect(std.mem.indexOf(u8, quota, "platform.minimax.io/subscribe/token-plan") != null);

    const filter = try mapApiError(alloc, 200,
        \\{"base_resp":{"status_code":1002,"status_msg":"content sensitivity"}}
    , "https://api.minimax.io/x");
    try std.testing.expect(std.mem.indexOf(u8, filter, "sensitivity filter") != null);

    const plan = try mapApiError(alloc, 200,
        \\{"base_resp":{"status_code":2061,"status_msg":"model not in plan"}}
    , "https://api.minimax.io/v1/video_generation");
    try std.testing.expect(std.mem.indexOf(u8, plan, "not available on your current Token Plan") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "Max plan") != null); // plan hint for video

    const generic = try mapApiError(alloc, 500,
        \\{"error":{"message":"boom"}}
    , "https://api.minimax.io/x");
    try std.testing.expectEqualStrings("API error: boom (HTTP 500)", generic);
}

// --- response formatting --------------------------------------------------------------

test "formatSearchResults numbers results and honors limit" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    const organic = try parseArgs(alloc,
        \\[{"title":"Zig","link":"https://ziglang.org","snippet":"A language"},{"title":"Zag","link":"https://zag","snippet":null},{"title":"Third","link":"https://t","snippet":"s"}]
    );
    const text = try formatSearchResults(alloc, organic, 2);
    try std.testing.expectEqualStrings(
        "1. Zig\n   https://ziglang.org\n   A language\n\n2. Zag\n   https://zag\n   ",
        text,
    );

    const empty = try parseArgs(alloc, "[]");
    try std.testing.expectEqualStrings("(no results)", try formatSearchResults(alloc, empty, 10));
}

test "formatQuota renders weekly usage lines like the reference" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    const models = try parseArgs(alloc,
        \\[{"model_name":"MiniMax-M2.5","current_weekly_total_count":100,"current_weekly_usage_count":25},{"model_name":"music-2.6","current_weekly_total_count":0,"current_weekly_usage_count":0}]
    );
    const text = try formatQuota(alloc, models);
    try std.testing.expectEqualStrings(
        "MiniMax-M2.5: 25/100 weekly (25%)\nmusic-2.6: 0/0 weekly (0%)",
        text,
    );
}

// --- media save ------------------------------------------------------------------------

test "saveMedia writes bytes and returns joined path" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_dir = try tmpOutDir(alloc, &tmp);

    const path = try saveMedia(alloc, std.testing.io, out_dir, "pid_mmx_speech_x.mp3", &.{ 1, 2, 3 });
    try std.testing.expect(std.mem.endsWith(u8, path, "pid_mmx_speech_x.mp3"));
    const read_back = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, alloc, .limited(64));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, read_back);
}

// --- tool impls (mock fetch) ---------------------------------------------------------------

test "describeImageImpl posts data URI to vlm endpoint" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "cat.png", .data = "FAKE_PNG" });
    const img_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/cat.png", .{std.mem.sliceTo(&tmp.sub_path, 0)});

    mockReset(&.{.{ .url_part = "/v1/coding_plan/vlm", .body = "{\"content\":\"A tabby cat.\"}" }});
    const args = try std.fmt.allocPrint(alloc, "{{\"path\":\"{s}\",\"prompt\":\"What animal?\"}}", .{img_path});
    const result = try describeImageImpl(alloc, std.testing.io, try parseArgs(alloc, args), test_cfg, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("A tabby cat.", result.text);

    // request construction
    try std.testing.expect(mockLast().method == .POST);
    try std.testing.expectEqualStrings("sk-cp-test", mockLast().auth);
    const body = try parseArgs(alloc, mockLast().body);
    try std.testing.expectEqualStrings("What animal?", body.object.get("prompt").?.string);
    try std.testing.expectEqualStrings("data:image/png;base64,RkFLRV9QTkc=", body.object.get("image_url").?.string);
}

test "describeImageImpl default prompt and missing/invalid path" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "cat.jpg", .data = "JPG" });
    const img_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/cat.jpg", .{std.mem.sliceTo(&tmp.sub_path, 0)});

    mockReset(&.{.{ .url_part = "/v1/coding_plan/vlm", .body = "{\"content\":\"x\"}" }});
    const args = try std.fmt.allocPrint(alloc, "{{\"path\":\"{s}\"}}", .{img_path});
    _ = try describeImageImpl(alloc, std.testing.io, try parseArgs(alloc, args), test_cfg, mockFetch);
    try std.testing.expectEqualStrings("Describe the image.", (try parseArgs(alloc, mockLast().body)).object.get("prompt").?.string);

    mockReset(&.{});
    const missing = try describeImageImpl(alloc, std.testing.io, try parseArgs(alloc, "{\"path\":\".zig-cache/tmp/nope.png\"}"), test_cfg, mockFetch);
    try std.testing.expect(missing.is_error);
    try std.testing.expect(std.mem.indexOf(u8, missing.text, "file not found") != null);

    const no_path = try describeImageImpl(alloc, std.testing.io, try parseArgs(alloc, "{}"), test_cfg, mockFetch);
    try std.testing.expect(no_path.is_error);
    try std.testing.expect(std.mem.indexOf(u8, no_path.text, "path is required") != null);
}

test "webSearchImpl formats organic results and honors limit" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    mockReset(&.{.{ .url_part = "/v1/coding_plan/search", .body =
        \\{"organic":[{"title":"Zig","link":"https://ziglang.org","snippet":"A language"},{"title":"Zag","link":"https://zag","snippet":"other"}]}
    } });
    const result = try webSearchImpl(alloc, std.testing.io, try parseArgs(alloc, "{\"query\":\"zig\",\"limit\":1}"), test_cfg, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("1. Zig\n   https://ziglang.org\n   A language", result.text);
    try std.testing.expect(mockLast().method == .POST);
    try std.testing.expectEqualStrings("zig", (try parseArgs(alloc, mockLast().body)).object.get("q").?.string);
}

test "webSearchImpl maps HTTP errors to clean MCP errors" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    mockReset(&.{.{ .url_part = "/v1/coding_plan/search", .status = 401, .body = "{}" }});
    const result = try webSearchImpl(alloc, std.testing.io, try parseArgs(alloc, "{\"query\":\"x\"}"), test_cfg, mockFetch);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "API key rejected") != null);

    mockReset(&.{.{ .url_part = "/v1/coding_plan/search", .status = 0, .body = "" }});
    const net = try webSearchImpl(alloc, std.testing.io, try parseArgs(alloc, "{\"query\":\"x\"}"), test_cfg, mockFetch);
    try std.testing.expect(net.is_error);
    try std.testing.expect(std.mem.indexOf(u8, net.text, "Network error") != null);
}

test "webSearchImpl requires query" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    mockReset(&.{});
    const result = try webSearchImpl(alloc, std.testing.io, try parseArgs(alloc, "{}"), test_cfg, mockFetch);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "query is required") != null);
}

test "generateImageImpl downloads each image_url to out_dir" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_dir = try tmpOutDir(alloc, &tmp);

    mockReset(&.{
        .{ .url_part = "/v1/image_generation", .body = "{\"data\":{\"image_urls\":[\"https://cdn.example.com/a.jpg\",\"https://cdn.example.com/b.jpg\"],\"task_id\":\"t1\",\"success_count\":2,\"failed_count\":0},\"base_resp\":{\"status_code\":0,\"status_msg\":\"success\"}}" },
        .{ .url_part = "cdn.example.com/a.jpg", .body = "JPEG_A" },
        .{ .url_part = "cdn.example.com/b.jpg", .body = "JPEG_B" },
    });
    const result = try generateImageImpl(alloc, std.testing.io, try parseArgs(alloc, "{\"prompt\":\"a cat\",\"aspect_ratio\":\"1:1\"}"), test_cfg, .{ .out_dir = out_dir, .stamp = "20240101000000" }, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Generated image(s) saved under") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "pid_mmx_img_20240101000000") != null);

    const f1 = try std.fmt.allocPrint(alloc, "{s}/pid_mmx_img_20240101000000_001.jpg", .{out_dir});
    const f2 = try std.fmt.allocPrint(alloc, "{s}/pid_mmx_img_20240101000000_002.jpg", .{out_dir});
    try std.testing.expectEqualStrings("JPEG_A", try std.Io.Dir.cwd().readFileAlloc(std.testing.io, f1, alloc, .limited(64)));
    try std.testing.expectEqualStrings("JPEG_B", try std.Io.Dir.cwd().readFileAlloc(std.testing.io, f2, alloc, .limited(64)));

    // CDN download must not carry the API key
    try std.testing.expectEqual(@as(usize, 0), mockLast().auth.len);
}

test "synthesizeSpeechImpl decodes hex audio and saves mp3" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_dir = try tmpOutDir(alloc, &tmp);

    mockReset(&.{.{ .url_part = "/v1/t2a_v2", .body = "{\"data\":{\"audio\":\"ff00aa\",\"status\":2},\"base_resp\":{\"status_code\":0,\"status_msg\":\"success\"}}" }});
    const result = try synthesizeSpeechImpl(alloc, std.testing.io, try parseArgs(alloc, "{\"text\":\"Hello\"}"), test_cfg, .{ .out_dir = out_dir, .stamp = "20240101000000" }, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Audio saved: ") == 0);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "pid_mmx_speech_20240101000000.mp3") != null);

    const saved = try std.fmt.allocPrint(alloc, "{s}/pid_mmx_speech_20240101000000.mp3", .{out_dir});
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0x00, 0xaa }, try std.Io.Dir.cwd().readFileAlloc(std.testing.io, saved, alloc, .limited(64)));
}

test "synthesizeSpeechImpl invalid hex is a clean error" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    mockReset(&.{.{ .url_part = "/v1/t2a_v2", .body = "{\"data\":{\"audio\":\"xyz\",\"status\":2}}" }});
    const result = try synthesizeSpeechImpl(alloc, std.testing.io, try parseArgs(alloc, "{\"text\":\"Hello\"}"), test_cfg, .{ .out_dir = try tmpOutDir(alloc, &tmp), .stamp = "s" }, mockFetch);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "invalid audio data") != null);
}

test "generateMusicImpl rejects lyrics+instrumental, auto-optimizes when neither" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const opts = ImplOpts{ .out_dir = try tmpOutDir(alloc, &tmp), .stamp = "s" };

    mockReset(&.{});
    const conflict = try generateMusicImpl(alloc, std.testing.io, try parseArgs(alloc, "{\"prompt\":\"p\",\"lyrics\":\"la\",\"instrumental\":true}"), test_cfg, opts, mockFetch);
    try std.testing.expect(conflict.is_error);
    try std.testing.expect(std.mem.indexOf(u8, conflict.text, "mutually exclusive") != null);
    try std.testing.expectEqual(@as(usize, 0), mock_pos); // no API call made

    mockReset(&.{.{ .url_part = "/v1/music_generation", .body = "{\"data\":{\"audio\":\"00\",\"status\":2}}" }});
    const auto = try generateMusicImpl(alloc, std.testing.io, try parseArgs(alloc, "{\"prompt\":\"upbeat pop\",\"genre\":\"pop\",\"bpm\":120}"), test_cfg, opts, mockFetch);
    try std.testing.expect(!auto.is_error);
    const body = try parseArgs(alloc, mockLast().body);
    try std.testing.expect(body.object.get("lyrics_optimizer").?.bool);
    try std.testing.expectEqualStrings("upbeat pop. Genre: pop. BPM: 120", body.object.get("prompt").?.string);
    try std.testing.expectEqualStrings("music-2.6", body.object.get("model").?.string); // sk-cp- key
}

test "generateVideoImpl polls to success, resolves file, downloads mp4" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_dir = try tmpOutDir(alloc, &tmp);

    mockReset(&.{
        .{ .url_part = "/v1/video_generation", .body = "{\"task_id\":\"vid-1\",\"status\":\"Queueing\",\"base_resp\":{\"status_code\":0,\"status_msg\":\"success\"}}" },
        .{ .url_part = "/v1/query/video_generation?task_id=vid-1", .body = "{\"task_id\":\"vid-1\",\"status\":\"Queueing\",\"base_resp\":{\"status_code\":0,\"status_msg\":\"success\"}}" },
        .{ .url_part = "/v1/query/video_generation?task_id=vid-1", .body = "{\"task_id\":\"vid-1\",\"status\":\"Processing\",\"base_resp\":{\"status_code\":0,\"status_msg\":\"success\"}}" },
        .{ .url_part = "/v1/query/video_generation?task_id=vid-1", .body = "{\"task_id\":\"vid-1\",\"status\":\"Success\",\"file_id\":\"file-9\",\"base_resp\":{\"status_code\":0,\"status_msg\":\"success\"}}" },
        .{ .url_part = "/v1/files/retrieve?file_id=file-9", .body = "{\"file\":{\"file_id\":\"file-9\",\"download_url\":\"https://cdn.example.com/v.mp4\"},\"base_resp\":{\"status_code\":0,\"status_msg\":\"success\"}}" },
        .{ .url_part = "cdn.example.com/v.mp4", .body = "MP4_BYTES" },
    });
    const result = try generateVideoImpl(alloc, std.testing.io, try parseArgs(alloc, "{\"prompt\":\"ocean waves\"}"), test_cfg, .{ .out_dir = out_dir, .stamp = "20240101000000", .poll_interval_ms = 0, .max_polls = 10 }, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Video saved: ") == 0);
    try std.testing.expectEqual(@as(usize, 6), mock_pos); // create + 3 polls + retrieve + download

    const saved = try std.fmt.allocPrint(alloc, "{s}/pid_mmx_video_20240101000000.mp4", .{out_dir});
    try std.testing.expectEqualStrings("MP4_BYTES", try std.Io.Dir.cwd().readFileAlloc(std.testing.io, saved, alloc, .limited(64)));
}

test "generateVideoImpl failed task reports status_msg" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    mockReset(&.{
        .{ .url_part = "/v1/video_generation", .body = "{\"task_id\":\"vid-2\",\"base_resp\":{\"status_code\":0,\"status_msg\":\"success\"}}" },
        .{ .url_part = "/v1/query/video_generation?task_id=vid-2", .body = "{\"task_id\":\"vid-2\",\"status\":\"Failed\",\"base_resp\":{\"status_code\":0,\"status_msg\":\"render failed\"}}" },
    });
    const result = try generateVideoImpl(alloc, std.testing.io, try parseArgs(alloc, "{\"prompt\":\"x\"}"), test_cfg, .{ .out_dir = try tmpOutDir(alloc, &tmp), .stamp = "s", .poll_interval_ms = 0, .max_polls = 10 }, mockFetch);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Task Failed.") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "render failed") != null);
}

test "generateVideoImpl base_resp error during poll maps to API error" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A non-zero base_resp.status_code on the poll response is intercepted by
    // apiJson (faithful to mmx requestJson) and mapped like any API error.
    mockReset(&.{
        .{ .url_part = "/v1/video_generation", .body = "{\"task_id\":\"vid-2b\",\"base_resp\":{\"status_code\":0,\"status_msg\":\"success\"}}" },
        .{ .url_part = "/v1/query/video_generation?task_id=vid-2b", .body = "{\"task_id\":\"vid-2b\",\"status\":\"Failed\",\"base_resp\":{\"status_code\":1002,\"status_msg\":\"content sensitivity\"}}" },
    });
    const result = try generateVideoImpl(alloc, std.testing.io, try parseArgs(alloc, "{\"prompt\":\"x\"}"), test_cfg, .{ .out_dir = try tmpOutDir(alloc, &tmp), .stamp = "s", .poll_interval_ms = 0, .max_polls = 10 }, mockFetch);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "sensitivity filter") != null);
}

test "generateVideoImpl success without file_id and exhausted polls" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_dir = try tmpOutDir(alloc, &tmp);

    mockReset(&.{
        .{ .url_part = "/v1/video_generation", .body = "{\"task_id\":\"vid-3\",\"base_resp\":{\"status_code\":0,\"status_msg\":\"success\"}}" },
        .{ .url_part = "/v1/query/video_generation?task_id=vid-3", .body = "{\"task_id\":\"vid-3\",\"status\":\"Success\",\"base_resp\":{\"status_code\":0,\"status_msg\":\"success\"}}" },
    });
    const no_fid = try generateVideoImpl(alloc, std.testing.io, try parseArgs(alloc, "{\"prompt\":\"x\"}"), test_cfg, .{ .out_dir = out_dir, .stamp = "s", .poll_interval_ms = 0, .max_polls = 10 }, mockFetch);
    try std.testing.expect(no_fid.is_error);
    try std.testing.expect(std.mem.indexOf(u8, no_fid.text, "no file_id") != null);

    mockReset(&.{
        .{ .url_part = "/v1/video_generation", .body = "{\"task_id\":\"vid-4\",\"base_resp\":{\"status_code\":0,\"status_msg\":\"success\"}}" },
        .{ .url_part = "/v1/query/video_generation?task_id=vid-4", .body = "{\"status\":\"Processing\",\"base_resp\":{\"status_code\":0,\"status_msg\":\"success\"}}" },
        .{ .url_part = "/v1/query/video_generation?task_id=vid-4", .body = "{\"status\":\"Processing\",\"base_resp\":{\"status_code\":0,\"status_msg\":\"success\"}}" },
    });
    const timed_out = try generateVideoImpl(alloc, std.testing.io, try parseArgs(alloc, "{\"prompt\":\"x\"}"), test_cfg, .{ .out_dir = out_dir, .stamp = "s", .poll_interval_ms = 0, .max_polls = 2 }, mockFetch);
    try std.testing.expect(timed_out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, timed_out.text, "timed out") != null);
}

test "generateVideoImpl last_frame requires first_frame" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    mockReset(&.{});
    const result = try generateVideoImpl(alloc, std.testing.io, try parseArgs(alloc, "{\"prompt\":\"x\",\"last_frame\":\"end.png\"}"), test_cfg, .{ .out_dir = try tmpOutDir(alloc, &tmp), .stamp = "s" }, mockFetch);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "requires first_frame") != null);
    try std.testing.expectEqual(@as(usize, 0), mock_pos);
}

test "generateVideoImpl last_frame switches model to Hailuo-02" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.png", .data = "A" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.png", .data = "B" });
    const sub = std.mem.sliceTo(&tmp.sub_path, 0);
    const a_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/a.png", .{sub});
    const b_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/b.png", .{sub});

    mockReset(&.{
        .{ .url_part = "/v1/video_generation", .body = "{\"task_id\":\"vid-5\",\"base_resp\":{\"status_code\":0,\"status_msg\":\"success\"}}" },
        .{ .url_part = "/v1/query/video_generation?task_id=vid-5", .body = "{\"status\":\"Success\",\"file_id\":\"f\",\"base_resp\":{\"status_code\":0,\"status_msg\":\"success\"}}" },
        .{ .url_part = "/v1/files/retrieve?file_id=f", .body = "{\"file\":{\"file_id\":\"f\",\"download_url\":\"https://cdn/v.mp4\"},\"base_resp\":{\"status_code\":0,\"status_msg\":\"success\"}}" },
        .{ .url_part = "cdn/v.mp4", .body = "V" },
    });
    const args = try std.fmt.allocPrint(alloc, "{{\"prompt\":\"x\",\"first_frame\":\"{s}\",\"last_frame\":\"{s}\"}}", .{ a_path, b_path });
    const result = try generateVideoImpl(alloc, std.testing.io, try parseArgs(alloc, args), test_cfg, .{ .out_dir = try tmpOutDir(alloc, &tmp), .stamp = "s", .poll_interval_ms = 0, .max_polls = 5 }, mockFetch);
    try std.testing.expect(!result.is_error);
    // first call is the video_generation POST
    const body = try parseArgs(alloc, mockCall(0).body);
    try std.testing.expectEqualStrings("MiniMax-Hailuo-02", body.object.get("model").?.string);
    try std.testing.expectEqualStrings("data:image/png;base64,QQ==", body.object.get("first_frame_image").?.string);
    try std.testing.expectEqualStrings("data:image/png;base64,Qg==", body.object.get("last_frame_image").?.string);
}

test "quotaImpl renders weekly usage per model" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    mockReset(&.{.{ .url_part = "api.minimax.io/v1/token_plan/remains", .body =
        \\{"model_remains":[{"model_name":"MiniMax-M2.5","current_weekly_total_count":100,"current_weekly_usage_count":10},{"model_name":"speech-2.8-hd","current_weekly_total_count":50,"current_weekly_usage_count":50}]}
    } });
    const result = try quotaImpl(alloc, std.testing.io, try parseArgs(alloc, "{}"), test_cfg, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings(
        "MiniMax-M2.5: 10/100 weekly (10%)\nspeech-2.8-hd: 50/50 weekly (100%)",
        result.text,
    );
    try std.testing.expect(mockLast().method == .GET);
    try std.testing.expectEqualStrings("sk-cp-test", mockLast().auth);
}

test "quotaImpl maps base_resp status_code on HTTP 200" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    mockReset(&.{.{ .url_part = "/v1/token_plan/remains", .body = "{\"base_resp\":{\"status_code\":1028,\"status_msg\":\"insufficient balance\"}}" }});
    const result = try quotaImpl(alloc, std.testing.io, try parseArgs(alloc, "{}"), test_cfg, mockFetch);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Quota exhausted") != null);
}

test "missing API key is a clean MCP error with no network call" {
    var arena_state: std.heap.ArenaAllocator = undefined;
    const alloc = testAlloc(&arena_state);
    defer arena_state.deinit();

    mockReset(&.{});
    const q = try quotaImpl(alloc, std.testing.io, try parseArgs(alloc, "{}"), no_key_cfg, mockFetch);
    try std.testing.expect(q.is_error);
    try std.testing.expect(std.mem.indexOf(u8, q.text, "No MiniMax API key") != null);
    try std.testing.expect(std.mem.indexOf(u8, q.text, "~/.mmx/config.json") != null);
    try std.testing.expectEqual(@as(usize, 0), mock_pos);

    const s = try webSearchImpl(alloc, std.testing.io, try parseArgs(alloc, "{\"query\":\"x\"}"), no_key_cfg, mockFetch);
    try std.testing.expect(s.is_error);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "No MiniMax API key") != null);
    try std.testing.expectEqual(@as(usize, 0), mock_pos);
}

test "env lookup reads the real process environment (not an empty block)" {
    const alloc = std.testing.allocator;
    g_env_io = std.testing.io;
    defer g_env_io = null;
    const v = getEnv(alloc, "PATH") orelse return error.SkipZigTest;
    defer alloc.free(v);
    try std.testing.expect(v.len > 0);
    try std.testing.expect(getEnv(alloc, "ZMCP_SURELY_UNSET_ENV_VAR_12345") == null);
}
