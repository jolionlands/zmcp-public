//! zmcp-zutil: small pure utilities for things LLMs are unreliable at
//! (encoding, hashing, ids, arithmetic, units, base conversion, statistics,
//! cron, semver). Pure Zig std, stateless, no network or file I/O; the only
//! environment access is OS randomness (id) and the wall clock (id, jwt_decode, cron).

const std = @import("std");
const mcp = @import("mcp");
const u = @import("util.zig");
const codec = @import("codec.zig");
const hash = @import("hash.zig");
const id = @import("id.zig");
const jwt = @import("jwt.zig");
const calc = @import("calc.zig");
const units = @import("units.zig");
const baseconv = @import("baseconv.zig");
const stats = @import("stats.zig");
const cron = @import("cron.zig");
const semver = @import("semver.zig");

pub fn main(init: std.process.Init) !void {
    try mcp.run(init.gpa, init.io, .{ .name = "zmcp-zutil", .version = "0.1.0" }, &tool_table);
}

const MAX_OUT = 64 * 1024;

fn finish(a: std.mem.Allocator, res: u.Err![]u8) anyerror!mcp.ToolResult {
    const text = res catch |e| switch (e) {
        error.Fail => return .{ .text = try a.dupe(u8, u.lastError()), .is_error = true },
        else => return e,
    };
    if (text.len > MAX_OUT) {
        const cut = try std.fmt.allocPrint(a, "{s}\n... [truncated at {d} of {d} bytes; narrow the input]", .{ text[0..MAX_OUT], MAX_OUT, text.len });
        a.free(text);
        return .{ .text = cut };
    }
    return .{ .text = text };
}

fn hCodec(a: std.mem.Allocator, _: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    return finish(a, codec.handle(a, args));
}
fn hHash(a: std.mem.Allocator, _: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    return finish(a, hash.handle(a, args));
}
fn hId(a: std.mem.Allocator, io: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    return finish(a, id.handle(a, io, args));
}
fn hJwt(a: std.mem.Allocator, io: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    return finish(a, jwt.handle(a, io, args));
}
fn hCalc(a: std.mem.Allocator, _: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    return finish(a, calc.handle(a, args));
}
fn hUnits(a: std.mem.Allocator, _: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    return finish(a, units.handle(a, args));
}
fn hBase(a: std.mem.Allocator, _: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    return finish(a, baseconv.handle(a, args));
}
fn hStats(a: std.mem.Allocator, _: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    return finish(a, stats.handle(a, args));
}
fn hCron(a: std.mem.Allocator, io: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    return finish(a, cron.handle(a, io, args));
}
fn hSemver(a: std.mem.Allocator, _: std.Io, args: std.json.Value) anyerror!mcp.ToolResult {
    return finish(a, semver.handle(a, args));
}

// All tools are pure functions of their arguments (plus OS randomness / the
// clock for id, jwt_decode and cron): read_only, never destructive.
const tool_table = [_]mcp.ToolDef{
    .{
        .name = "codec",
        .description = "Exact encode/decode: base64, base64url, hex, url (percent), html entities, utf8-bytes.",
        .input_schema_json =
        \\{"type":"object","properties":{"op":{"type":"string","enum":["base64","base64url","hex","url","html","utf8-bytes"]},"mode":{"type":"string","enum":["encode","decode"]},"text":{"type":"string"}},"required":["op","mode","text"]}
        ,
        .handler = hCodec,
        .read_only = true,
    },
    .{
        .name = "hash",
        .description = "Digest of text or hex bytes; optional HMAC (sha256/sha512/sha1/md5). md5/sha1 are not secure.",
        .input_schema_json =
        \\{"type":"object","properties":{"alg":{"type":"string","enum":["sha256","sha512","sha1","md5","blake3","crc32","xxh64"]},"text":{"type":"string"},"hex_bytes":{"type":"string"},"hmac_key":{"type":"string","description":"Never echoed."}},"required":["alg"]}
        ,
        .handler = hHash,
        .read_only = true,
    },
    .{
        .name = "id",
        .description = "Generate random ids (OS randomness): uuid4, uuid7, ulid, nanoid, random_hex, random_token.",
        .input_schema_json =
        \\{"type":"object","properties":{"kind":{"type":"string","enum":["uuid4","uuid7","ulid","nanoid","random_hex","random_token"]},"count":{"type":"integer","description":"1-100"},"bytes":{"type":"integer","description":"random_hex/random_token bytes (16/32), nanoid chars (21)"}},"required":["kind"]}
        ,
        .handler = hId,
        .read_only = true,
    },
    .{
        .name = "jwt_decode",
        .description = "Decode a JWT header/payload with exp/nbf/iat as dates and expired-or-not. Never verifies the signature.",
        .input_schema_json =
        \\{"type":"object","properties":{"token":{"type":"string"}},"required":["token"]}
        ,
        .handler = hJwt,
        .read_only = true,
    },
    .{
        .name = "calc",
        .description = "Exact arithmetic: + - * / % ^ ** ( ), sqrt abs ln log10 log2 exp sin cos tan asin acos atan floor ceil round min max pow gcd lcm, pi e. No variables.",
        .input_schema_json =
        \\{"type":"object","properties":{"expr":{"type":"string"}},"required":["expr"]}
        ,
        .handler = hCalc,
        .read_only = true,
    },
    .{
        .name = "units",
        .description = "Convert length, mass, volume, temperature, time, data (SI vs IEC), speed, area, energy, pressure.",
        .input_schema_json =
        \\{"type":"object","properties":{"value":{"type":"number"},"from":{"type":"string"},"to":{"type":"string"}},"required":["value","from","to"]}
        ,
        .handler = hUnits,
        .read_only = true,
    },
    .{
        .name = "base_convert",
        .description = "Convert a non-negative integer (up to 2048 bits) between bases 2-36.",
        .input_schema_json =
        \\{"type":"object","properties":{"value":{"type":"string"},"from_base":{"type":"integer"},"to_base":{"type":"integer"}},"required":["value","from_base","to_base"]}
        ,
        .handler = hBase,
        .read_only = true,
    },
    .{
        .name = "stats",
        .description = "count, sum, mean, median, mode, stdev, variance, min, max, p50/p90/p99 of a list of numbers.",
        .input_schema_json =
        \\{"type":"object","properties":{"numbers":{"type":"array","items":{"type":"number"}}},"required":["numbers"]}
        ,
        .handler = hStats,
        .read_only = true,
    },
    .{
        .name = "cron",
        .description = "Explain a 5-field cron expr and list next fire times. tz is UTC or a fixed offset like +02:00 (no IANA/DST).",
        .input_schema_json =
        \\{"type":"object","properties":{"expr":{"type":"string"},"count":{"type":"integer","description":"1-50, default 5"},"from":{"type":"string","description":"ISO-8601 or unix seconds; default now"},"tz":{"type":"string","description":"UTC or +HH:MM"}},"required":["expr"]}
        ,
        .handler = hCron,
        .read_only = true,
    },
    .{
        .name = "semver",
        .description = "semver.org 2.0 ops: compare, satisfies (npm ^ ~ >= x-ranges, hyphen, ||), bump, sort, parse.",
        .input_schema_json =
        \\{"type":"object","properties":{"op":{"type":"string","enum":["compare","satisfies","bump","sort","parse"]},"version":{"type":"string"},"other":{"type":"string","description":"compare"},"range":{"type":"string","description":"satisfies"},"level":{"type":"string","description":"bump: major|minor|patch|premajor|preminor|prepatch|prerelease"},"pre_id":{"type":"string"},"versions":{"type":"array","items":{"type":"string"},"description":"sort"},"desc":{"type":"boolean"}},"required":["op"]}
        ,
        .handler = hSemver,
        .read_only = true,
    },
};

test {
    _ = u;
    _ = codec;
    _ = hash;
    _ = id;
    _ = jwt;
    _ = calc;
    _ = units;
    _ = baseconv;
    _ = stats;
    _ = cron;
    _ = semver;
}


test "tool table: every tool is read_only, not destructive, schemas are valid JSON" {
    for (tool_table) |t| {
        try std.testing.expect(t.read_only and !t.destructive);
        const p = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, t.input_schema_json, .{});
        p.deinit();
    }
    try std.testing.expectEqual(@as(usize, 10), tool_table.len);
}

test "handlers surface errors as is_error results, not Zig errors" {
    const a = std.testing.allocator;
    var thr: std.Io.Threaded = .init_single_threaded;
    const io = thr.io();
    const p = try std.json.parseFromSlice(std.json.Value, a, "{\"expr\":\"1/0\"}", .{});
    defer p.deinit();
    const r = try hCalc(a, io, p.value);
    defer a.free(r.text);
    try std.testing.expect(r.is_error);
    try std.testing.expectEqualStrings("division by zero", r.text);
    const p2 = try std.json.parseFromSlice(std.json.Value, a, "{\"expr\":\"2^3^2\"}", .{});
    defer p2.deinit();
    const r2 = try hCalc(a, io, p2.value);
    defer a.free(r2.text);
    try std.testing.expect(!r2.is_error);
    try std.testing.expectEqualStrings("= 512", r2.text);
    const p3 = try std.json.parseFromSlice(std.json.Value, a, "{\"kind\":\"uuid7\",\"count\":3}", .{});
    defer p3.deinit();
    const r3 = try hId(a, io, p3.value);
    defer a.free(r3.text);
    try std.testing.expectEqual(@as(usize, 36 * 3 + 2), r3.text.len);
    const p4 = try std.json.parseFromSlice(std.json.Value, a, "{\"kind\":\"uuid4\",\"count\":101}", .{});
    defer p4.deinit();
    const r4 = try hId(a, io, p4.value);
    defer a.free(r4.text);
    try std.testing.expect(r4.is_error);
}
