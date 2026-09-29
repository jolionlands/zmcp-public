//! zmcp-kubernetes — Zig port (subset) of Flux159/mcp-server-kubernetes.
//! Thin wrapper over the local `kubectl` CLI (argv only, no shell).
//!
//! Read-only tools: kubectl_get, kubectl_describe, kubectl_logs, kubectl_top,
//! kubectl_events, list_api_resources, kubectl_context, kubectl_rollout (status/history).
//! Mutating tools (kubectl_apply, kubectl_delete, kubectl_scale, kubectl_rollout restart)
//! refuse unless env ZMCP_KUBERNETES_ALLOW_WRITE=1.
//! Never exposed: exec, port-forward, cp, proxy, generic kubectl, helm.

const std = @import("std");
const mcp = @import("mcp");

const Io = std.Io;

const OUTPUT_CAP: usize = 64 * 1024;
const MAX_TAIL: i64 = 1000;
const DEFAULT_TAIL: i64 = 200;
const MAX_MANIFEST: usize = 1024 * 1024;

var allow_write: bool = false;

pub fn main(init: std.process.Init) !void {
    if (init.environ_map.get("ZMCP_KUBERNETES_ALLOW_WRITE")) |v| {
        allow_write = std.mem.eql(u8, v, "1");
    }
    try mcp.run(init.gpa, init.io, .{ .name = "zmcp-kubernetes", .version = "0.1.0" }, &tool_table);
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "kubectl_get",
        .read_only = true,
        .description = "kubectl get (read-only). JSON output is compacted (managedFields stripped) and redacted: Secret data/stringData values, container env[].value whose NAME looks secret-like (password, secret, token, key, credential, passwd, auth) and ConfigMap values whose KEY looks secret-like. Redaction is name-based and best effort: secrets stored under innocuous names or in other fields (args, annotations, CRDs) are not detected. Output that is not valid JSON is refused rather than returned raw.",
        .input_schema_json =
        \\{"type":"object","properties":{"resourceType":{"type":"string"},"name":{"type":"string"},"namespace":{"type":"string"},"output":{"type":"string","enum":["json","name"],"default":"json"},"allNamespaces":{"type":"boolean"},"labelSelector":{"type":"string"},"fieldSelector":{"type":"string"},"sortBy":{"type":"string","description":"JSONPath e.g. .metadata.creationTimestamp"},"context":{"type":"string"}},"required":["resourceType"]}
        ,
        .handler = handleGet,
    },
    .{
        .name = "kubectl_describe",
        .read_only = true,
        .description = "kubectl describe a resource (read-only). Refuses resourceType secret (values are never returned; use kubectl_get, which redacts). Output is passed through a best-effort text scrubber that masks Data/Environment values under secret-like names, long base64-like values, private key blocks, Bearer tokens and URL passwords. This is a heuristic: secrets under innocuous names or free-form text can still appear.",
        .input_schema_json =
        \\{"type":"object","properties":{"resourceType":{"type":"string"},"name":{"type":"string"},"namespace":{"type":"string"},"allNamespaces":{"type":"boolean"},"context":{"type":"string"}},"required":["resourceType","name"]}
        ,
        .handler = handleDescribe,
    },
    .{
        .name = "kubectl_logs",
        .read_only = true,
        .description = "Container logs (tail capped at 1000, default 200; never follows). Output goes through the same best-effort secret scrubber as kubectl_describe (name=value pairs with secret-like names, Bearer tokens, URL passwords, private keys); logs are free-form, so this is a heuristic and not a guarantee.",
        .input_schema_json =
        \\{"type":"object","properties":{"resourceType":{"type":"string","enum":["pod","deployment","job","cronjob"],"default":"pod"},"name":{"type":"string"},"namespace":{"type":"string"},"container":{"type":"string"},"tail":{"type":"integer","minimum":1,"maximum":1000},"since":{"type":"string","description":"e.g. 10m, 2h"},"previous":{"type":"boolean"},"timestamps":{"type":"boolean"},"context":{"type":"string"}},"required":["name"]}
        ,
        .handler = handleLogs,
    },
    .{
        .name = "kubectl_top",
        .read_only = true,
        .description = "Resource usage for pods or nodes (needs metrics-server).",
        .input_schema_json =
        \\{"type":"object","properties":{"resourceType":{"type":"string","enum":["pods","nodes"]},"name":{"type":"string"},"namespace":{"type":"string"},"allNamespaces":{"type":"boolean"},"context":{"type":"string"}},"required":["resourceType"]}
        ,
        .handler = handleTop,
    },
    .{
        .name = "kubectl_events",
        .read_only = true,
        .description = "Recent events, one line each, newest last.",
        .input_schema_json =
        \\{"type":"object","properties":{"namespace":{"type":"string"},"allNamespaces":{"type":"boolean"},"involvedObject":{"type":"string","description":"object name"},"limit":{"type":"integer","minimum":1,"maximum":500,"default":50},"context":{"type":"string"}}}
        ,
        .handler = handleEvents,
    },
    .{
        .name = "list_api_resources",
        .read_only = true,
        .description = "List API resource kinds (names only).",
        .input_schema_json =
        \\{"type":"object","properties":{"namespaced":{"type":"boolean"},"apiGroup":{"type":"string"},"context":{"type":"string"}}}
        ,
        .handler = handleApiResources,
    },
    .{
        .name = "kubectl_context",
        .read_only = true,
        .description = "Read kubeconfig contexts: operation current or list (switching not supported).",
        .input_schema_json =
        \\{"type":"object","properties":{"operation":{"type":"string","enum":["current","list"],"default":"current"}}}
        ,
        .handler = handleContext,
    },
    .{
        .name = "kubectl_rollout",
        .description = "Rollout status/history (read-only); restart needs ZMCP_KUBERNETES_ALLOW_WRITE=1.",
        .input_schema_json =
        \\{"type":"object","properties":{"subCommand":{"type":"string","enum":["status","history","restart"],"default":"status"},"resourceType":{"type":"string","enum":["deployment","daemonset","statefulset"],"default":"deployment"},"name":{"type":"string"},"namespace":{"type":"string"},"timeout":{"type":"string","description":"e.g. 30s"},"context":{"type":"string"}},"required":["name"]}
        ,
        .handler = handleRollout,
    },
    .{
        .name = "kubectl_scale",
        .destructive = true,
        .description = "Scale a workload. Write: needs ZMCP_KUBERNETES_ALLOW_WRITE=1.",
        .input_schema_json =
        \\{"type":"object","properties":{"name":{"type":"string"},"replicas":{"type":"integer","minimum":0,"maximum":1000},"resourceType":{"type":"string","enum":["deployment","replicaset","statefulset"],"default":"deployment"},"namespace":{"type":"string"},"context":{"type":"string"}},"required":["name","replicas"]}
        ,
        .handler = handleScale,
    },
    .{
        .name = "kubectl_apply",
        .destructive = true,
        .description = "Apply a YAML/JSON manifest (inline). Write: needs ZMCP_KUBERNETES_ALLOW_WRITE=1.",
        .input_schema_json =
        \\{"type":"object","properties":{"manifest":{"type":"string"},"namespace":{"type":"string"},"dryRun":{"type":"boolean"},"context":{"type":"string"}},"required":["manifest"]}
        ,
        .handler = handleApply,
    },
    .{
        .name = "kubectl_delete",
        .destructive = true,
        .description = "Delete by resourceType + name or labelSelector. Write: needs ZMCP_KUBERNETES_ALLOW_WRITE=1.",
        .input_schema_json =
        \\{"type":"object","properties":{"resourceType":{"type":"string"},"name":{"type":"string"},"namespace":{"type":"string"},"labelSelector":{"type":"string"},"context":{"type":"string"}},"required":["resourceType"]}
        ,
        .handler = handleDelete,
    },
};

// ---------------------------------------------------------------------------
// Exec seam
// ---------------------------------------------------------------------------

pub const ExecResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
};

pub const ExecFn = *const fn (
    alloc: std.mem.Allocator,
    io: Io,
    argv: []const []const u8,
    stdin_text: ?[]const u8,
) anyerror!ExecResult;

var exec_fn: ExecFn = execReal;

fn setExecForTesting(f: ExecFn) void {
    exec_fn = f;
}

fn execReal(
    alloc: std.mem.Allocator,
    io: Io,
    argv: []const []const u8,
    stdin_text: ?[]const u8,
) !ExecResult {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = if (stdin_text != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.ExecutableNotFound,
        else => return err,
    };
    defer child.kill(io);

    var stdin_thread: ?std.Thread = null;
    if (stdin_text) |input| {
        stdin_thread = std.Thread.spawn(.{}, writeChildStdin, .{ io, child.stdin.?, input }) catch null;
        if (stdin_thread == null) {
            writeChildStdin(io, child.stdin.?, input);
            child.stdin = null;
        }
    }
    defer {
        if (stdin_thread) |t| {
            t.join();
            child.stdin = null;
        }
    }

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(alloc, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    while (multi_reader.fill(64, .none)) |_| {
        if (stdout_reader.buffered().len > 32 * 1024 * 1024) return error.StreamTooLong;
        if (stderr_reader.buffered().len > 4 * 1024 * 1024) return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi_reader.checkAnyError();
    if (stdin_thread) |t| {
        t.join();
        child.stdin = null;
        stdin_thread = null;
    }

    const term = try child.wait(io);
    return .{
        .term = term,
        .stdout = try multi_reader.toOwnedSlice(0),
        .stderr = try multi_reader.toOwnedSlice(1),
    };
}

fn writeChildStdin(io: Io, file: Io.File, data: []const u8) void {
    var buf: [4096]u8 = undefined;
    var fw: Io.File.Writer = .init(file, io, &buf);
    fw.interface.writeAll(data) catch {};
    fw.interface.flush() catch {};
    file.close(io);
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

/// Token charset [A-Za-z0-9._:/-], non-empty, no leading '-', <= 253 bytes.
fn validToken(s: []const u8) bool {
    if (s.len == 0 or s.len > 253 or s[0] == '-') return false;
    for (s) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '.', '_', ':', '/', '-' => {},
            else => return false,
        }
    }
    return true;
}

/// Label/field selector: token charset plus `= , ! ( )` and space; no leading '-'.
/// Always passed as `--flag=value` so it can never be parsed as a separate flag.
fn validSelector(s: []const u8) bool {
    if (s.len == 0 or s.len > 512 or s[0] == '-' or s[0] == ' ') return false;
    for (s) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '.', '_', ':', '/', '-', '=', ',', '!', '(', ')', ' ' => {},
            else => return false,
        }
    }
    return true;
}

/// Duration like 30s, 10m, 2h, 1h30m.
fn validDuration(s: []const u8) bool {
    if (s.len == 0 or s.len > 16) return false;
    var digits: usize = 0;
    for (s) |c| {
        switch (c) {
            '0'...'9' => digits += 1,
            's', 'm', 'h' => {
                if (digits == 0) return false;
                digits = 0;
            },
            else => return false,
        }
    }
    return digits == 0;
}

/// JSONPath for --sort-by: `.a.b[0].c` style.
fn validSortBy(s: []const u8) bool {
    if (s.len == 0 or s.len > 128 or s[0] != '.') return false;
    for (s) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '-', '[', ']' => {},
            else => return false,
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// Argument helpers
// ---------------------------------------------------------------------------

fn getStr(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn getInt(args: std.json.Value, key: []const u8) ?i64 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (f == @trunc(f) and @abs(f) < 1e12) @as(i64, @intFromFloat(f)) else null,
        else => null,
    };
}

fn getBool(args: std.json.Value, key: []const u8) bool {
    if (args != .object) return false;
    const v = args.object.get(key) orelse return false;
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

fn fail(alloc: std.mem.Allocator, comptime fmt: []const u8, a: anytype) !mcp.ToolResult {
    return .{ .text = try std.fmt.allocPrint(alloc, fmt, a), .is_error = true };
}

/// Builder for the argv vector. Optional string args are validated; on the first
/// invalid one `bad` is set and later calls become no-ops.
const Argv = struct {
    alloc: std.mem.Allocator,
    list: std.ArrayList([]const u8) = .empty,
    bad: ?[]const u8 = null,

    fn init(alloc: std.mem.Allocator, args: std.json.Value) !Argv {
        var a: Argv = .{ .alloc = alloc };
        try a.list.append(alloc, "kubectl");
        try a.list.append(alloc, "--request-timeout=30s");
        try a.optFlag(args, "context", "--context=", validToken);
        return a;
    }

    fn push(a: *Argv, s: []const u8) !void {
        try a.list.append(a.alloc, s);
    }

    fn setBad(a: *Argv, key: []const u8) !void {
        if (a.bad == null) a.bad = try std.fmt.allocPrint(a.alloc, "invalid '{s}'", .{key});
    }

    /// Positional token (validated).
    fn tok(a: *Argv, key: []const u8, value: []const u8) !void {
        if (a.bad != null) return;
        if (!validToken(value)) return a.setBad(key);
        try a.push(value);
    }

    /// --flag=value from optional arg `key`, validated with `check`.
    fn optFlag(a: *Argv, args: std.json.Value, key: []const u8, prefix: []const u8, check: *const fn ([]const u8) bool) !void {
        if (a.bad != null) return;
        const v = getStr(args, key) orelse return;
        if (v.len == 0) return;
        if (!check(v)) return a.setBad(key);
        try a.push(try std.fmt.allocPrint(a.alloc, "{s}{s}", .{ prefix, v }));
    }

    fn optTok(a: *Argv, args: std.json.Value, key: []const u8) !void {
        if (a.bad != null) return;
        const v = getStr(args, key) orelse return;
        if (v.len == 0) return;
        try a.tok(key, v);
    }

    fn namespace(a: *Argv, args: std.json.Value, allow_all: bool) !void {
        if (allow_all and getBool(args, "allNamespaces")) {
            try a.push("--all-namespaces");
            return;
        }
        try a.optFlag(args, "namespace", "--namespace=", validToken);
    }
};

// ---------------------------------------------------------------------------
// Running + output shaping
// ---------------------------------------------------------------------------

fn capText(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (s.len <= OUTPUT_CAP) return s;
    return std.fmt.allocPrint(alloc, "{s}\n[truncated: showing {d} of {d} bytes]", .{ s[0..OUTPUT_CAP], OUTPUT_CAP, s.len });
}

const Ran = union(enum) { ok: []u8, err: mcp.ToolResult };

fn runKubectl(alloc: std.mem.Allocator, io: Io, argv: []const []const u8, stdin_text: ?[]const u8) !Ran {
    const res = exec_fn(alloc, io, argv, stdin_text) catch |err| switch (err) {
        error.ExecutableNotFound => return .{ .err = try fail(alloc, "kubectl not found on PATH", .{}) },
        else => return .{ .err = try fail(alloc, "failed to run kubectl: {s}", .{@errorName(err)}) },
    };
    switch (res.term) {
        .exited => |code| if (code == 0) return .{ .ok = res.stdout },
        else => {},
    }
    const e = std.mem.trim(u8, res.stderr, " \t\r\n");
    const detail = if (e.len == 0) "(no error output)" else if (e.len > 4096) e[0..4096] else e;
    return .{ .err = try fail(alloc, "kubectl failed: {s}", .{detail}) };
}

fn runText(alloc: std.mem.Allocator, io: Io, av: *Argv, stdin_text: ?[]const u8) !mcp.ToolResult {
    if (av.bad) |b| return .{ .text = b, .is_error = true };
    switch (try runKubectl(alloc, io, av.list.items, stdin_text)) {
        .err => |r| return r,
        .ok => |out| {
            const t = std.mem.trim(u8, out, "\r\n");
            return .{ .text = try capText(alloc, if (t.len == 0) "(no output)" else t) };
        },
    }
}

/// Like runText but passes stdout through `scrubOutput` before capping.
fn runScrubbed(alloc: std.mem.Allocator, io: Io, av: *Argv) !mcp.ToolResult {
    if (av.bad) |b| return .{ .text = b, .is_error = true };
    switch (try runKubectl(alloc, io, av.list.items, null)) {
        .err => |r| return r,
        .ok => |out| {
            const t = std.mem.trim(u8, out, "\r\n");
            if (t.len == 0) return .{ .text = "(no output)" };
            return .{ .text = try capText(alloc, try scrubOutput(alloc, t)) };
        },
    }
}

fn requireWrite(alloc: std.mem.Allocator, what: []const u8) !?mcp.ToolResult {
    if (allow_write) return null;
    return try fail(alloc, "refused: {s} modifies the cluster; set ZMCP_KUBERNETES_ALLOW_WRITE=1 in the server environment to enable write tools", .{what});
}

// ---------------------------------------------------------------------------
// JSON compaction
// ---------------------------------------------------------------------------

const LAST_APPLIED = "kubectl.kubernetes.io/last-applied-configuration";

/// Strip noise in place: metadata.managedFields, last-applied annotation,
/// and redact Secret data/stringData values.
fn compactValue(v: *std.json.Value) void {
    if (v.* != .object) return;
    const obj = &v.object;
    var is_secret = false;
    if (obj.get("kind")) |k| {
        if (k == .string and std.mem.eql(u8, k.string, "Secret")) is_secret = true;
    }
    if (obj.getPtr("metadata")) |m| {
        if (m.* == .object) {
            _ = m.object.orderedRemove("managedFields");
            if (m.object.getPtr("annotations")) |an| {
                if (an.* == .object) {
                    _ = an.object.orderedRemove(LAST_APPLIED);
                    if (an.object.count() == 0) _ = m.object.orderedRemove("annotations");
                }
            }
        }
    }
    if (is_secret) {
        inline for (.{ "data", "stringData" }) |field| {
            if (obj.getPtr(field)) |d| {
                if (d.* == .object) {
                    for (d.object.values()) |*val| val.* = .{ .string = "<redacted>" };
                }
            }
        }
    }
    if (obj.getPtr("items")) |items| {
        if (items.* == .array) {
            for (items.array.items) |*it| compactValue(it);
        }
    }
}

/// Env / config key names that look secret-like (case-insensitive substring).
const secret_words = [_][]const u8{ "password", "secret", "token", "key", "credential", "passwd", "auth" };

fn nameLooksSecret(name: []const u8) bool {
    for (secret_words) |w| if (std.ascii.indexOfIgnoreCase(name, w) != null) return true;
    return false;
}

/// Narrower list for free-form lines (logs), to keep false positives down.
const narrow_words = [_][]const u8{ "password", "passwd", "secret", "token", "credential", "apikey", "api_key", "api-key", "authorization", "private_key", "private-key", "access_key", "access-key" };

fn nameLooksSecretNarrow(name: []const u8) bool {
    for (narrow_words) |w| if (std.ascii.indexOfIgnoreCase(name, w) != null) return true;
    return false;
}

const REDACTED_VALUE = "<redacted>";

/// A value that is secret regardless of its name: PEM private key or URL with
/// user:pass@ userinfo.
fn valueLooksSecret(v: []const u8) bool {
    if (std.ascii.indexOfIgnoreCase(v, "PRIVATE KEY-----") != null) return true;
    if (std.mem.indexOf(u8, v, "://")) |i| {
        const rest = v[i + 3 ..];
        var e: usize = 0;
        while (e < rest.len and rest[e] != '/' and rest[e] != '?' and rest[e] != ' ') e += 1;
        if (std.mem.indexOfScalar(u8, rest[0..e], '@')) |at| {
            if (std.mem.indexOfScalar(u8, rest[0..at], ':') != null) return true;
        }
    }
    return false;
}

/// Redact, in place and at any depth: container env[].value with a secret-like
/// NAME (or a secret-looking value), and ConfigMap data/binaryData values whose
/// KEY is secret-like (or whose value looks secret).
fn redactWorkloadValues(v: *std.json.Value, depth: usize) void {
    if (depth > 64) return;
    switch (v.*) {
        .array => |*arr| for (arr.items) |*x| redactWorkloadValues(x, depth + 1),
        .object => |*obj| {
            var is_cm = false;
            if (obj.get("kind")) |k| {
                if (k == .string and std.mem.eql(u8, k.string, "ConfigMap")) is_cm = true;
            }
            var it = obj.iterator();
            while (it.next()) |e| {
                const key = e.key_ptr.*;
                const val = e.value_ptr;
                if (std.mem.eql(u8, key, "env") and val.* == .array) {
                    for (val.array.items) |*item| {
                        if (item.* != .object) continue;
                        const nm = item.object.get("name") orelse continue;
                        const vp = item.object.getPtr("value") orelse continue;
                        if (nm != .string or vp.* != .string) continue;
                        if (nameLooksSecret(nm.string) or valueLooksSecret(vp.string)) vp.* = .{ .string = REDACTED_VALUE };
                    }
                } else if (is_cm and (std.mem.eql(u8, key, "data") or std.mem.eql(u8, key, "binaryData")) and val.* == .object) {
                    var dit = val.object.iterator();
                    while (dit.next()) |de| {
                        if (de.value_ptr.* != .string) continue;
                        if (nameLooksSecret(de.key_ptr.*) or valueLooksSecret(de.value_ptr.string)) de.value_ptr.* = .{ .string = REDACTED_VALUE };
                    }
                }
                redactWorkloadValues(val, depth + 1);
            }
        },
        else => {},
    }
}

/// Compact + redact kubectl JSON. Errors (never raw output) when the input is
/// not valid JSON, since it could then carry unredacted secrets.
fn compactJson(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{});
    compactValue(&parsed);
    redactWorkloadValues(&parsed, 0);
    return std.json.Stringify.valueAlloc(alloc, parsed, .{});
}

// ---------------------------------------------------------------------------
// Best-effort text scrubber for describe / logs (heuristic; see tool docs)
// ---------------------------------------------------------------------------

const REDACTED_TEXT = "[redacted]";

/// True for `secret`, `secrets`, `secret/x`, `secrets.v1.`, `pods,secrets`.
fn isSecretType(rt: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, rt, ',');
    while (it.next()) |part| {
        var end: usize = 0;
        while (end < part.len and part[end] != '.' and part[end] != '/') end += 1;
        var w = part[0..end];
        if (w.len > 0 and (w[w.len - 1] == 's' or w[w.len - 1] == 'S')) w = w[0 .. w.len - 1];
        if (std.ascii.eqlIgnoreCase(w, "secret")) return true;
    }
    return false;
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
}

fn isValueEnd(c: u8) bool {
    return switch (c) {
        ' ', '\t', '"', '\'', ',', ';', '&', '}', ']', '\r' => true,
        else => false,
    };
}

fn isB64Char(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '+' or c == '/' or c == '=' or c == '_' or c == '-';
}

fn isLongB64(v: []const u8) bool {
    if (v.len < 32) return false;
    for (v) |c| if (!isB64Char(c)) return false;
    return true;
}

fn replaceRange(alloc: std.mem.Allocator, s: []const u8, a: usize, b: usize, with: []const u8) ![]const u8 {
    return std.mem.concat(alloc, u8, &.{ s[0..a], with, s[b..] });
}

/// Mask the token after `Bearer ` / `Basic `.
fn scrubBearer(alloc: std.mem.Allocator, line: []const u8) ![]const u8 {
    var cur = line;
    for ([_][]const u8{ "bearer ", "basic " }) |n| {
        var from: usize = 0;
        while (std.ascii.indexOfIgnoreCasePos(cur, from, n)) |i| {
            if (i > 0 and isNameChar(cur[i - 1])) {
                from = i + n.len;
                continue;
            }
            const vs = i + n.len;
            var ve = vs;
            while (ve < cur.len and !isValueEnd(cur[ve])) ve += 1;
            // "Basic" is common English: only mask when it looks like a credential.
            const is_basic = n[0] == 'b' and n[1] == 'a';
            if (ve == vs or std.mem.startsWith(u8, cur[vs..ve], REDACTED_TEXT) or (is_basic and !isLongB64(cur[vs..ve]))) {
                from = ve;
                continue;
            }
            cur = try replaceRange(alloc, cur, vs, ve, REDACTED_TEXT);
            from = vs + REDACTED_TEXT.len;
        }
    }
    return cur;
}

/// Mask userinfo passwords in scheme://user:pass@host.
fn scrubUserinfo(alloc: std.mem.Allocator, line: []const u8) ![]const u8 {
    var cur = line;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, cur, from, "://")) |i| {
        const as = i + 3;
        var ae = as;
        while (ae < cur.len and cur[ae] != '/' and cur[ae] != '?' and cur[ae] != '#' and cur[ae] != ' ' and cur[ae] != '"' and cur[ae] != '\'' and cur[ae] != '\t') ae += 1;
        from = as;
        const at = std.mem.lastIndexOfScalar(u8, cur[as..ae], '@') orelse continue;
        if (std.mem.eql(u8, cur[as .. as + at], REDACTED_TEXT)) continue;
        cur = try replaceRange(alloc, cur, as, as + at, REDACTED_TEXT);
        from = as + REDACTED_TEXT.len;
    }
    return cur;
}

/// Mask values of `name=value` / `name: value` / `"name":"value"` pairs whose
/// name looks secret-like. `strict` uses the broad word list (env/data sections).
fn scrubKeyValues(alloc: std.mem.Allocator, line: []const u8, strict: bool) ![]const u8 {
    var cur = line;
    var i: usize = 0;
    while (i < cur.len) : (i += 1) {
        const c = cur[i];
        if (c != ':' and c != '=') continue;
        var ne = i;
        while (ne > 0 and (cur[ne - 1] == '"' or cur[ne - 1] == '\'')) ne -= 1;
        var ns = ne;
        while (ns > 0 and isNameChar(cur[ns - 1])) ns -= 1;
        const name = cur[ns..ne];
        if (name.len == 0) continue;
        if (!(if (strict) nameLooksSecret(name) else nameLooksSecretNarrow(name))) continue;
        var vs = i + 1;
        while (vs < cur.len and (cur[vs] == ' ' or cur[vs] == '\t' or cur[vs] == '"' or cur[vs] == '\'')) vs += 1;
        if (std.mem.startsWith(u8, cur[vs..], "//")) continue; // scheme://
        var ve = vs;
        while (ve < cur.len and !isValueEnd(cur[ve])) ve += 1;
        if (ve == vs) continue;
        const val = cur[vs..ve];
        if (val[0] == '<' or std.mem.startsWith(u8, val, REDACTED_TEXT)) continue;
        cur = try replaceRange(alloc, cur, vs, ve, REDACTED_TEXT);
        i = vs + REDACTED_TEXT.len - 1;
    }
    return cur;
}

fn scrubLine(alloc: std.mem.Allocator, line: []const u8, strict: bool) ![]const u8 {
    var l = try scrubBearer(alloc, line);
    l = try scrubUserinfo(alloc, l);
    return scrubKeyValues(alloc, l, strict);
}

fn indentOf(l: []const u8) usize {
    var n: usize = 0;
    while (n < l.len and (l[n] == ' ' or l[n] == '\t')) n += 1;
    return n;
}

const Section = enum { none, data, env };

/// Heuristic scrubber for `kubectl describe` and `logs` text. Masks:
///   * PEM private key blocks;
///   * Data / String Data / BinaryData values (describe configmap layout) whose
///     key is secret-like, or that hold long base64-like or private-key text;
///   * `NAME:  value` lines under `Environment:` whose NAME is secret-like or
///     whose value is long base64-like;
///   * secret-named key=value pairs, Bearer tokens and URL passwords anywhere.
/// It cannot know what is secret: values under innocuous names get through.
pub fn scrubOutput(alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var sp = std.mem.splitScalar(u8, text, '\n');
    while (sp.next()) |l| try lines.append(alloc, std.mem.trimEnd(u8, l, "\r"));

    var out: std.ArrayList(u8) = .empty;
    var section: Section = .none;
    var sec_indent: usize = 0;
    var in_pem = false;
    var i: usize = 0;
    while (i < lines.items.len) {
        const line = lines.items[i];
        const trimmed = std.mem.trim(u8, line, " \t");
        // PEM blocks: hide from BEGIN..PRIVATE KEY through END.
        if (in_pem) {
            if (std.mem.indexOf(u8, line, "-----END") != null) in_pem = false;
            i += 1;
            continue;
        }
        if (std.ascii.indexOfIgnoreCase(line, "-----BEGIN") != null and std.ascii.indexOfIgnoreCase(line, "PRIVATE KEY") != null) {
            try out.appendSlice(alloc, "[redacted private key block]\n");
            in_pem = std.mem.indexOf(u8, line, "-----END") == null;
            i += 1;
            continue;
        }
        // Section tracking.
        if (section == .env and trimmed.len > 0 and indentOf(line) <= sec_indent) section = .none;
        if (section == .data and (std.mem.eql(u8, trimmed, "Events:") or std.mem.startsWith(u8, trimmed, "Events:"))) section = .none;
        const next_is_rule = i + 1 < lines.items.len and std.mem.startsWith(u8, lines.items[i + 1], "====");
        if (next_is_rule and (std.mem.eql(u8, trimmed, "Data") or std.mem.eql(u8, trimmed, "String Data") or std.mem.eql(u8, trimmed, "StringData") or std.mem.eql(u8, trimmed, "BinaryData"))) {
            section = .data;
            sec_indent = indentOf(line);
        } else if (std.mem.startsWith(u8, trimmed, "Environment:") and std.mem.trim(u8, trimmed["Environment:".len..], " \t").len == 0) {
            section = .env;
            sec_indent = indentOf(line);
            try out.appendSlice(alloc, line);
            try out.append(alloc, '\n');
            i += 1;
            continue;
        }

        if (section == .data) {
            // describe configmap: "key:" / "----" / value lines / blank.
            if (trimmed.len > 1 and trimmed[trimmed.len - 1] == ':' and i + 1 < lines.items.len and std.mem.eql(u8, std.mem.trim(u8, lines.items[i + 1], " \t"), "----")) {
                const key = trimmed[0 .. trimmed.len - 1];
                try out.appendSlice(alloc, line);
                try out.append(alloc, '\n');
                try out.appendSlice(alloc, lines.items[i + 1]);
                try out.append(alloc, '\n');
                var j = i + 2;
                var secretish = nameLooksSecret(key);
                while (j < lines.items.len and std.mem.trim(u8, lines.items[j], " \t").len > 0) : (j += 1) {
                    const vl = std.mem.trim(u8, lines.items[j], " \t");
                    if (isLongB64(vl) or valueLooksSecret(vl)) secretish = true;
                }
                if (j > i + 2) {
                    if (secretish) {
                        try out.appendSlice(alloc, REDACTED_TEXT);
                        try out.append(alloc, '\n');
                    } else for (lines.items[i + 2 .. j]) |vl| {
                        try out.appendSlice(alloc, try scrubLine(alloc, vl, false));
                        try out.append(alloc, '\n');
                    }
                }
                i = j;
                continue;
            }
            // one-line "key:  value" form
            if (try scrubPairLine(alloc, line, trimmed)) |masked| {
                try out.appendSlice(alloc, masked);
                try out.append(alloc, '\n');
                i += 1;
                continue;
            }
        } else if (section == .env) {
            if (try scrubPairLine(alloc, line, trimmed)) |masked| {
                try out.appendSlice(alloc, masked);
                try out.append(alloc, '\n');
                i += 1;
                continue;
            }
        }
        try out.appendSlice(alloc, try scrubLine(alloc, line, section != .none));
        try out.append(alloc, '\n');
        i += 1;
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == '\n') _ = out.pop();
    return out.items;
}

/// For a `NAME:  value` line inside an Environment/Data section: returns the
/// line with the value masked when NAME is secret-like or the value is long
/// base64-like; null when the line needs no whole-value masking.
fn scrubPairLine(alloc: std.mem.Allocator, line: []const u8, trimmed: []const u8) !?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return null;
    const name = trimmed[0..colon];
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, ' ') != null) return null;
    const val = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
    if (val.len == 0 or val[0] == '<' or std.mem.startsWith(u8, val, REDACTED_TEXT)) return null;
    if (nameLooksSecret(name) or isLongB64(val) or valueLooksSecret(val)) {
        return try std.fmt.allocPrint(alloc, "{s}{s}:  {s}", .{ line[0..indentOf(line)], name, REDACTED_TEXT });
    }
    return null;
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

fn handleGet(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const rt = getStr(args, "resourceType") orelse return fail(alloc, "resourceType is required", .{});
    var av = try Argv.init(alloc, args);
    try av.push("get");
    try av.tok("resourceType", rt);
    try av.optTok(args, "name");
    try av.namespace(args, true);
    try av.optFlag(args, "labelSelector", "--selector=", validSelector);
    try av.optFlag(args, "fieldSelector", "--field-selector=", validSelector);
    try av.optFlag(args, "sortBy", "--sort-by=", validSortBy);
    const out_mode = getStr(args, "output") orelse "json";
    const as_json = std.mem.eql(u8, out_mode, "json");
    if (!as_json and !std.mem.eql(u8, out_mode, "name")) return fail(alloc, "output must be json or name", .{});
    try av.push(if (as_json) "--output=json" else "--output=name");
    if (av.bad) |b| return .{ .text = b, .is_error = true };
    switch (try runKubectl(alloc, io, av.list.items, null)) {
        .err => |r| return r,
        .ok => |out| {
            const t = std.mem.trim(u8, out, "\r\n");
            if (t.len == 0) return .{ .text = "(no resources)" };
            if (!as_json) return .{ .text = try capText(alloc, t) };
            const compact = compactJson(alloc, t) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => return fail(alloc, "error: kubectl output was not valid JSON; refusing to return it unredacted", .{}),
            };
            return .{ .text = try capText(alloc, compact) };
        },
    }
}

fn handleDescribe(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const rt = getStr(args, "resourceType") orelse return fail(alloc, "resourceType is required", .{});
    const name = getStr(args, "name") orelse return fail(alloc, "name is required", .{});
    if (isSecretType(rt) or isSecretType(name)) return fail(alloc, "refused: describe of Secrets is not supported because its output can include secret values, which this server never returns. Use kubectl_get (resourceType secret), which returns the object with data values redacted.", .{});
    var av = try Argv.init(alloc, args);
    try av.push("describe");
    try av.tok("resourceType", rt);
    try av.tok("name", name);
    try av.namespace(args, true);
    return runScrubbed(alloc, io, &av);
}

fn handleLogs(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const name = getStr(args, "name") orelse return fail(alloc, "name is required", .{});
    const rt = getStr(args, "resourceType") orelse "pod";
    const allowed = [_][]const u8{ "pod", "deployment", "job", "cronjob" };
    var ok = false;
    for (allowed) |a| {
        if (std.mem.eql(u8, a, rt)) ok = true;
    }
    if (!ok) return fail(alloc, "resourceType must be pod, deployment, job or cronjob", .{});
    if (!validToken(name)) return fail(alloc, "invalid 'name'", .{});
    var av = try Argv.init(alloc, args);
    try av.push("logs");
    try av.push(try std.fmt.allocPrint(alloc, "{s}/{s}", .{ rt, name }));
    try av.namespace(args, false);
    try av.optFlag(args, "container", "--container=", validToken);
    var tail = getInt(args, "tail") orelse DEFAULT_TAIL;
    if (tail < 1) tail = 1;
    if (tail > MAX_TAIL) tail = MAX_TAIL;
    try av.push(try std.fmt.allocPrint(alloc, "--tail={d}", .{tail}));
    try av.optFlag(args, "since", "--since=", validDuration);
    if (getBool(args, "previous")) try av.push("--previous");
    if (getBool(args, "timestamps")) try av.push("--timestamps");
    try av.push("--limit-bytes=65536");
    return runScrubbed(alloc, io, &av);
}

fn handleTop(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const rt = getStr(args, "resourceType") orelse return fail(alloc, "resourceType is required", .{});
    const is_pods = std.mem.eql(u8, rt, "pods") or std.mem.eql(u8, rt, "pod");
    const is_nodes = std.mem.eql(u8, rt, "nodes") or std.mem.eql(u8, rt, "node");
    if (!is_pods and !is_nodes) return fail(alloc, "resourceType must be pods or nodes", .{});
    var av = try Argv.init(alloc, args);
    try av.push("top");
    try av.push(if (is_pods) "pods" else "nodes");
    try av.optTok(args, "name");
    if (is_pods) try av.namespace(args, true);
    return runText(alloc, io, &av, null);
}

fn handleEvents(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    var av = try Argv.init(alloc, args);
    try av.push("get");
    try av.push("events");
    try av.namespace(args, true);
    if (getStr(args, "involvedObject")) |o| {
        if (o.len > 0) {
            if (!validToken(o)) try av.setBad("involvedObject") else try av.push(try std.fmt.allocPrint(alloc, "--field-selector=involvedObject.name={s}", .{o}));
        }
    }
    try av.push("--sort-by=.lastTimestamp");
    try av.push("--output=json");
    if (av.bad) |b| return .{ .text = b, .is_error = true };
    var limit = getInt(args, "limit") orelse 50;
    if (limit < 1) limit = 1;
    if (limit > 500) limit = 500;
    switch (try runKubectl(alloc, io, av.list.items, null)) {
        .err => |r| return r,
        .ok => |out| return formatEvents(alloc, out, @intCast(limit)),
    }
}

fn str(obj: std.json.Value, key: []const u8) []const u8 {
    if (obj != .object) return "";
    const v = obj.object.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

fn formatEvents(alloc: std.mem.Allocator, raw: []const u8, limit: usize) !mcp.ToolResult {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{}) catch
        return fail(alloc, "could not parse kubectl output", .{});
    const items_v = if (parsed == .object) parsed.object.get("items") else null;
    if (items_v == null or items_v.? != .array or items_v.?.array.items.len == 0) return .{ .text = "(no events)" };
    const items = items_v.?.array.items;
    const start = if (items.len > limit) items.len - limit else 0;
    var out: std.Io.Writer.Allocating = .init(alloc);
    for (items[start..]) |ev| {
        const io_obj = if (ev == .object) (ev.object.get("involvedObject") orelse .null) else .null;
        var ts = str(ev, "lastTimestamp");
        if (ts.len == 0) ts = str(ev, "eventTime");
        if (ts.len == 0) ts = str(ev, "firstTimestamp");
        var ns = str(io_obj, "namespace");
        if (ns.len == 0) ns = str(if (ev == .object) (ev.object.get("metadata") orelse .null) else .null, "namespace");
        const count: i64 = if (ev == .object) (if (ev.object.get("count")) |c| (if (c == .integer) c.integer else 1) else 1) else 1;
        try out.writer.print("{s} {s} {s} {s}/{s}", .{ ts, str(ev, "type"), str(ev, "reason"), str(io_obj, "kind"), str(io_obj, "name") });
        if (ns.len > 0) try out.writer.print(" ns={s}", .{ns});
        if (count > 1) try out.writer.print(" x{d}", .{count});
        try out.writer.print(": {s}\n", .{str(ev, "message")});
    }
    const text = try out.toOwnedSlice();
    if (text.len <= OUTPUT_CAP) return .{ .text = std.mem.trimEnd(u8, text, "\n") };
    // Keep the newest events when over the cap.
    const cut = text.len - OUTPUT_CAP;
    const nl = std.mem.indexOfScalarPos(u8, text, cut, '\n') orelse cut;
    return .{ .text = try std.fmt.allocPrint(alloc, "[truncated: older events omitted]\n{s}", .{std.mem.trimEnd(u8, text[nl + 1 ..], "\n")}) };
}

fn handleApiResources(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    var av = try Argv.init(alloc, args);
    try av.push("api-resources");
    try av.push("--output=name");
    if (args == .object and args.object.get("namespaced") != null) {
        try av.push(if (getBool(args, "namespaced")) "--namespaced=true" else "--namespaced=false");
    }
    try av.optFlag(args, "apiGroup", "--api-group=", validToken);
    return runText(alloc, io, &av, null);
}

fn handleContext(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const op = getStr(args, "operation") orelse "current";
    var av: Argv = .{ .alloc = alloc };
    try av.push("kubectl");
    if (std.mem.eql(u8, op, "current")) {
        try av.push("config");
        try av.push("current-context");
    } else if (std.mem.eql(u8, op, "list")) {
        try av.push("config");
        try av.push("get-contexts");
        try av.push("--output=name");
    } else return fail(alloc, "operation must be current or list", .{});
    return runText(alloc, io, &av, null);
}

fn handleRollout(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const name = getStr(args, "name") orelse return fail(alloc, "name is required", .{});
    const sub = getStr(args, "subCommand") orelse "status";
    const rt = getStr(args, "resourceType") orelse "deployment";
    const is_status = std.mem.eql(u8, sub, "status");
    const is_history = std.mem.eql(u8, sub, "history");
    const is_restart = std.mem.eql(u8, sub, "restart");
    if (!is_status and !is_history and !is_restart) return fail(alloc, "subCommand must be status, history or restart", .{});
    const kinds = [_][]const u8{ "deployment", "daemonset", "statefulset" };
    var ok = false;
    for (kinds) |k| {
        if (std.mem.eql(u8, k, rt)) ok = true;
    }
    if (!ok) return fail(alloc, "resourceType must be deployment, daemonset or statefulset", .{});
    if (is_restart) {
        if (try requireWrite(alloc, "rollout restart")) |r| return r;
    }
    var av = try Argv.init(alloc, args);
    try av.push("rollout");
    try av.push(sub);
    if (!validToken(name)) return fail(alloc, "invalid 'name'", .{});
    try av.push(try std.fmt.allocPrint(alloc, "{s}/{s}", .{ rt, name }));
    try av.namespace(args, false);
    if (is_status) {
        try av.push("--watch=false");
        try av.optFlag(args, "timeout", "--timeout=", validDuration);
    }
    return runText(alloc, io, &av, null);
}

fn handleScale(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    if (try requireWrite(alloc, "scale")) |r| return r;
    const name = getStr(args, "name") orelse return fail(alloc, "name is required", .{});
    const replicas = getInt(args, "replicas") orelse return fail(alloc, "replicas is required (integer)", .{});
    if (replicas < 0 or replicas > 1000) return fail(alloc, "replicas must be 0..1000", .{});
    const rt = getStr(args, "resourceType") orelse "deployment";
    const kinds = [_][]const u8{ "deployment", "replicaset", "statefulset" };
    var ok = false;
    for (kinds) |k| {
        if (std.mem.eql(u8, k, rt)) ok = true;
    }
    if (!ok) return fail(alloc, "resourceType must be deployment, replicaset or statefulset", .{});
    var av = try Argv.init(alloc, args);
    try av.push("scale");
    try av.push(rt);
    try av.tok("name", name);
    try av.push(try std.fmt.allocPrint(alloc, "--replicas={d}", .{replicas}));
    try av.namespace(args, false);
    return runText(alloc, io, &av, null);
}

fn handleApply(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    if (try requireWrite(alloc, "apply")) |r| return r;
    const manifest = getStr(args, "manifest") orelse return fail(alloc, "manifest is required", .{});
    if (manifest.len == 0 or manifest.len > MAX_MANIFEST) return fail(alloc, "manifest must be 1..{d} bytes", .{MAX_MANIFEST});
    var av = try Argv.init(alloc, args);
    try av.push("apply");
    try av.push("--filename=-");
    try av.namespace(args, false);
    if (getBool(args, "dryRun")) try av.push("--dry-run=server");
    return runText(alloc, io, &av, manifest);
}

fn handleDelete(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    if (try requireWrite(alloc, "delete")) |r| return r;
    const rt = getStr(args, "resourceType") orelse return fail(alloc, "resourceType is required", .{});
    const name = getStr(args, "name");
    const sel = getStr(args, "labelSelector");
    const has_name = name != null and name.?.len > 0;
    const has_sel = sel != null and sel.?.len > 0;
    if (has_name == has_sel) return fail(alloc, "provide exactly one of name or labelSelector", .{});
    if (std.mem.eql(u8, rt, "all") or std.mem.indexOfScalar(u8, rt, ',') != null) return fail(alloc, "invalid 'resourceType'", .{});
    var av = try Argv.init(alloc, args);
    try av.push("delete");
    try av.tok("resourceType", rt);
    if (has_name) try av.tok("name", name.?);
    try av.optFlag(args, "labelSelector", "--selector=", validSelector);
    try av.optFlag(args, "namespace", "--namespace=", validToken);
    return runText(alloc, io, &av, null);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

var fake_argv: []const []const u8 = &.{};
var fake_stdin: ?[]const u8 = null;
var fake_result: ExecResult = .{ .term = .{ .exited = 0 }, .stdout = @constCast(""), .stderr = @constCast("") };
var fake_error: ?anyerror = null;
var fake_calls: usize = 0;

fn fakeExec(alloc: std.mem.Allocator, io: Io, argv: []const []const u8, stdin_text: ?[]const u8) !ExecResult {
    _ = io;
    fake_calls += 1;
    fake_argv = try alloc.dupe([]const u8, argv);
    fake_stdin = stdin_text;
    if (fake_error) |e| return e;
    return fake_result;
}

fn fakeOk(stdout: []const u8) void {
    fake_result = .{ .term = .{ .exited = 0 }, .stdout = @constCast(stdout), .stderr = @constCast("") };
    fake_error = null;
}

const TestCtx = struct {
    arena_state: std.heap.ArenaAllocator,
    arena: std.mem.Allocator,

    fn init(ctx: *TestCtx) void {
        ctx.arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        ctx.arena = ctx.arena_state.allocator();
        setExecForTesting(fakeExec);
        fake_argv = &.{};
        fake_stdin = null;
        fake_calls = 0;
        allow_write = false;
        fakeOk("");
    }

    fn deinit(ctx: *TestCtx) void {
        setExecForTesting(execReal);
        allow_write = false;
        ctx.arena_state.deinit();
    }

    fn args(ctx: *TestCtx, json: []const u8) !std.json.Value {
        return std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, json, .{});
    }
};

fn expectArgv(want: []const []const u8) !void {
    try std.testing.expectEqual(want.len, fake_argv.len);
    for (want, fake_argv) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "token validation" {
    try std.testing.expect(validToken("my-pod.v1_2:x/y"));
    try std.testing.expect(!validToken(""));
    try std.testing.expect(!validToken("-n"));
    try std.testing.expect(!validToken("a b"));
    try std.testing.expect(!validToken("a;b"));
    try std.testing.expect(!validToken("a=b"));
    try std.testing.expect(!validToken("$(x)"));
    try std.testing.expect(validSelector("app=nginx,tier!=db"));
    try std.testing.expect(!validSelector("--all"));
    try std.testing.expect(!validSelector("a;b"));
    try std.testing.expect(validDuration("10m"));
    try std.testing.expect(validDuration("1h30m"));
    try std.testing.expect(!validDuration("10"));
    try std.testing.expect(!validDuration("m"));
    try std.testing.expect(!validDuration("-5m"));
    try std.testing.expect(validSortBy(".metadata.creationTimestamp"));
    try std.testing.expect(!validSortBy("metadata"));
}

test "get: argv and compaction" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fakeOk(
        \\{"kind":"List","items":[{"kind":"Pod","metadata":{"name":"a","managedFields":[{"x":1}],"annotations":{"kubectl.kubernetes.io/last-applied-configuration":"{}"}}},{"kind":"Secret","metadata":{"name":"s"},"data":{"pw":"c2VjcmV0"}}]}
    );
    const a = try ctx.args(
        \\{"resourceType":"pods","namespace":"kube-system","labelSelector":"app=x","context":"prod"}
    );
    const res = try handleGet(ctx.arena, std.testing.io, a);
    try std.testing.expect(!res.is_error);
    try expectArgv(&.{ "kubectl", "--request-timeout=30s", "--context=prod", "get", "pods", "--namespace=kube-system", "--selector=app=x", "--output=json" });
    try std.testing.expect(std.mem.indexOf(u8, res.text, "managedFields") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "last-applied") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "c2VjcmV0") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "<redacted>") != null);
}

test "get: rejects flag-like and bad tokens without exec" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    const cases = [_][]const u8{
        \\{"resourceType":"--kubeconfig=/etc/x"}
        ,
        \\{"resourceType":"pods","name":"-o"}
        ,
        \\{"resourceType":"pods","namespace":"a b"}
        ,
        \\{"resourceType":"pods","context":"x;y"}
        ,
        \\{"resourceType":"pods","labelSelector":"--all"}
        ,
        \\{"resourceType":"pods","output":"yaml"}
        ,
        \\{}
    };
    for (cases) |c| {
        const res = try handleGet(ctx.arena, std.testing.io, try ctx.args(c));
        try std.testing.expect(res.is_error);
    }
    try std.testing.expectEqual(@as(usize, 0), fake_calls);
}

test "get: allNamespaces and name output" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fakeOk("pod/a\npod/b\n");
    const res = try handleGet(ctx.arena, std.testing.io, try ctx.args(
        \\{"resourceType":"pods","allNamespaces":true,"output":"name","sortBy":".metadata.name"}
    ));
    try std.testing.expectEqualStrings("pod/a\npod/b", res.text);
    try expectArgv(&.{ "kubectl", "--request-timeout=30s", "get", "pods", "--all-namespaces", "--sort-by=.metadata.name", "--output=name" });
}

test "logs: tail capped, since validated" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fakeOk("line1\n");
    const res = try handleLogs(ctx.arena, std.testing.io, try ctx.args(
        \\{"name":"web-1","namespace":"prod","tail":99999,"since":"5m","container":"app","previous":true}
    ));
    try std.testing.expect(!res.is_error);
    try expectArgv(&.{ "kubectl", "--request-timeout=30s", "logs", "pod/web-1", "--namespace=prod", "--container=app", "--tail=1000", "--since=5m", "--previous", "--limit-bytes=65536" });
    const bad = try handleLogs(ctx.arena, std.testing.io, try ctx.args(
        \\{"name":"web-1","since":"--follow"}
    ));
    try std.testing.expect(bad.is_error);
    const bad2 = try handleLogs(ctx.arena, std.testing.io, try ctx.args(
        \\{"name":"web-1","resourceType":"node"}
    ));
    try std.testing.expect(bad2.is_error);
    try std.testing.expectEqual(@as(usize, 1), fake_calls);
}

test "describe and top argv" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fakeOk("Name: x\n");
    _ = try handleDescribe(ctx.arena, std.testing.io, try ctx.args(
        \\{"resourceType":"deployment","name":"web","namespace":"prod"}
    ));
    try expectArgv(&.{ "kubectl", "--request-timeout=30s", "describe", "deployment", "web", "--namespace=prod" });
    _ = try handleTop(ctx.arena, std.testing.io, try ctx.args(
        \\{"resourceType":"nodes"}
    ));
    try expectArgv(&.{ "kubectl", "--request-timeout=30s", "top", "nodes" });
    const bad = try handleTop(ctx.arena, std.testing.io, try ctx.args(
        \\{"resourceType":"secrets"}
    ));
    try std.testing.expect(bad.is_error);
}

test "events: formatted, limited to newest" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fakeOk(
        \\{"items":[{"type":"Normal","reason":"Old","message":"m0","lastTimestamp":"t0","involvedObject":{"kind":"Pod","name":"p0","namespace":"d"}},{"type":"Warning","reason":"BackOff","message":"restarting","count":3,"lastTimestamp":"t1","involvedObject":{"kind":"Pod","name":"p1","namespace":"d"}}]}
    );
    const res = try handleEvents(ctx.arena, std.testing.io, try ctx.args(
        \\{"namespace":"d","involvedObject":"p1","limit":1}
    ));
    try expectArgv(&.{ "kubectl", "--request-timeout=30s", "get", "events", "--namespace=d", "--field-selector=involvedObject.name=p1", "--sort-by=.lastTimestamp", "--output=json" });
    try std.testing.expectEqualStrings("t1 Warning BackOff Pod/p1 ns=d x3: restarting", res.text);
}

test "api resources and context" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fakeOk("pods\n");
    _ = try handleApiResources(ctx.arena, std.testing.io, try ctx.args(
        \\{"namespaced":true,"apiGroup":"apps"}
    ));
    try expectArgv(&.{ "kubectl", "--request-timeout=30s", "api-resources", "--output=name", "--namespaced=true", "--api-group=apps" });
    _ = try handleContext(ctx.arena, std.testing.io, try ctx.args("{}"));
    try expectArgv(&.{ "kubectl", "config", "current-context" });
    _ = try handleContext(ctx.arena, std.testing.io, try ctx.args(
        \\{"operation":"list"}
    ));
    try expectArgv(&.{ "kubectl", "config", "get-contexts", "--output=name" });
    const bad = try handleContext(ctx.arena, std.testing.io, try ctx.args(
        \\{"operation":"use"}
    ));
    try std.testing.expect(bad.is_error);
}

test "rollout: status is read-only, restart gated" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fakeOk("deployment \"web\" successfully rolled out\n");
    const res = try handleRollout(ctx.arena, std.testing.io, try ctx.args(
        \\{"name":"web","namespace":"prod","timeout":"30s"}
    ));
    try std.testing.expect(!res.is_error);
    try expectArgv(&.{ "kubectl", "--request-timeout=30s", "rollout", "status", "deployment/web", "--namespace=prod", "--watch=false", "--timeout=30s" });

    const calls = fake_calls;
    const denied = try handleRollout(ctx.arena, std.testing.io, try ctx.args(
        \\{"name":"web","subCommand":"restart"}
    ));
    try std.testing.expect(denied.is_error);
    try std.testing.expect(std.mem.indexOf(u8, denied.text, "ZMCP_KUBERNETES_ALLOW_WRITE=1") != null);
    try std.testing.expectEqual(calls, fake_calls);

    const undo = try handleRollout(ctx.arena, std.testing.io, try ctx.args(
        \\{"name":"web","subCommand":"undo"}
    ));
    try std.testing.expect(undo.is_error);

    allow_write = true;
    const ok = try handleRollout(ctx.arena, std.testing.io, try ctx.args(
        \\{"name":"web","subCommand":"restart","resourceType":"statefulset"}
    ));
    try std.testing.expect(!ok.is_error);
    try expectArgv(&.{ "kubectl", "--request-timeout=30s", "rollout", "restart", "statefulset/web" });
}

test "write tools refuse without env, run with it" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    const scale = try ctx.args(
        \\{"name":"web","replicas":3,"namespace":"prod"}
    );
    const apply = try ctx.args(
        \\{"manifest":"kind: Pod"}
    );
    const del = try ctx.args(
        \\{"resourceType":"pod","name":"x"}
    );
    inline for (.{ handleScale, handleApply, handleDelete }, .{ scale, apply, del }) |h, a| {
        const r = try h(ctx.arena, std.testing.io, a);
        try std.testing.expect(r.is_error);
        try std.testing.expect(std.mem.indexOf(u8, r.text, "ZMCP_KUBERNETES_ALLOW_WRITE=1") != null);
    }
    try std.testing.expectEqual(@as(usize, 0), fake_calls);

    allow_write = true;
    fakeOk("ok\n");
    _ = try handleScale(ctx.arena, std.testing.io, scale);
    try expectArgv(&.{ "kubectl", "--request-timeout=30s", "scale", "deployment", "web", "--replicas=3", "--namespace=prod" });
    _ = try handleApply(ctx.arena, std.testing.io, try ctx.args(
        \\{"manifest":"kind: Pod","dryRun":true,"namespace":"d"}
    ));
    try expectArgv(&.{ "kubectl", "--request-timeout=30s", "apply", "--filename=-", "--namespace=d", "--dry-run=server" });
    try std.testing.expectEqualStrings("kind: Pod", fake_stdin.?);
    _ = try handleDelete(ctx.arena, std.testing.io, del);
    try expectArgv(&.{ "kubectl", "--request-timeout=30s", "delete", "pod", "x" });
    const n = fake_calls;
    // ambiguous / dangerous deletes rejected
    for ([_][]const u8{
        \\{"resourceType":"pod"}
        ,
        \\{"resourceType":"pod","name":"x","labelSelector":"a=b"}
        ,
        \\{"resourceType":"all","name":"x"}
        ,
        \\{"resourceType":"pod,svc","name":"x"}
        ,
    }) |c| {
        const r = try handleDelete(ctx.arena, std.testing.io, try ctx.args(c));
        try std.testing.expect(r.is_error);
    }
    const bad_scale = try handleScale(ctx.arena, std.testing.io, try ctx.args(
        \\{"name":"web","replicas":-1}
    ));
    try std.testing.expect(bad_scale.is_error);
    try std.testing.expectEqual(n, fake_calls);
}

test "errors: nonzero exit, missing binary, output cap" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fake_result = .{ .term = .{ .exited = 1 }, .stdout = @constCast(""), .stderr = @constCast("Error from server (NotFound): pods \"x\" not found\n") };
    const r = try handleDescribe(ctx.arena, std.testing.io, try ctx.args(
        \\{"resourceType":"pod","name":"x"}
    ));
    try std.testing.expect(r.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "NotFound") != null);

    fake_error = error.ExecutableNotFound;
    const r2 = try handleDescribe(ctx.arena, std.testing.io, try ctx.args(
        \\{"resourceType":"pod","name":"x"}
    ));
    try std.testing.expect(r2.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r2.text, "not found on PATH") != null);

    const big = try ctx.arena.alloc(u8, OUTPUT_CAP + 500);
    @memset(big, 'a');
    fakeOk(big);
    const r3 = try handleDescribe(ctx.arena, std.testing.io, try ctx.args(
        \\{"resourceType":"pod","name":"x"}
    ));
    try std.testing.expect(!r3.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r3.text, "[truncated") != null);
}

test "annotations: reads are read_only, writes destructive, rollout neither" {
    for (tool_table) |t| {
        try std.testing.expect(!(t.read_only and t.destructive));
        const writes = std.mem.eql(u8, t.name, "kubectl_scale") or std.mem.eql(u8, t.name, "kubectl_apply") or std.mem.eql(u8, t.name, "kubectl_delete");
        const mixed = std.mem.eql(u8, t.name, "kubectl_rollout");
        try std.testing.expectEqual(writes, t.destructive);
        try std.testing.expectEqual(!writes and !mixed, t.read_only);
    }
}

test "get: env values and configmap keys with secret-like names are redacted" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fakeOk(
        \\{"kind":"List","items":[{"kind":"Pod","metadata":{"name":"p"},"spec":{"containers":[{"name":"c","env":[{"name":"DB_PASSWORD","value":"hunter2"},{"name":"REGION","value":"eu"},{"name":"API_KEY","valueFrom":{"secretKeyRef":{"name":"s","key":"k"}}},{"name":"DSN","value":"postgres://u:pw@h/db"}]}]}},
        \\{"kind":"Deployment","spec":{"template":{"spec":{"initContainers":[{"env":[{"name":"AUTH_TOKEN","value":"tok123"}]}]}}}},
        \\{"kind":"ConfigMap","metadata":{"name":"cm"},"data":{"app.conf":"x=1","db_password":"pw999","tls.key":"kkk"}}]}
    );
    const res = try handleGet(ctx.arena, std.testing.io, try ctx.args("{\"resourceType\":\"all\"}"));
    try std.testing.expect(!res.is_error);
    for ([_][]const u8{ "hunter2", "tok123", "pw999", "kkk", "u:pw" }) |bad|
        try std.testing.expect(std.mem.indexOf(u8, res.text, bad) == null);
    for ([_][]const u8{ "\"eu\"", "x=1", "secretKeyRef" }) |good|
        try std.testing.expect(std.mem.indexOf(u8, res.text, good) != null);
}

test "get: non-JSON output is refused, not returned raw" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fakeOk("password: hunter2 (not json)");
    const res = try handleGet(ctx.arena, std.testing.io, try ctx.args("{\"resourceType\":\"pods\"}"));
    try std.testing.expect(res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "hunter2") == null);
}

test "describe: secret types refused without exec" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    for ([_][]const u8{ "secret", "secrets", "Secret", "secrets.v1.", "secret/foo", "pods,secrets" }) |rt| {
        const js = try std.fmt.allocPrint(ctx.arena, "{{\"resourceType\":\"{s}\",\"name\":\"x\"}}", .{rt});
        const r = try handleDescribe(ctx.arena, std.testing.io, try ctx.args(js));
        try std.testing.expect(r.is_error);
        try std.testing.expect(std.mem.indexOf(u8, r.text, "kubectl_get") != null);
    }
    try std.testing.expectEqual(@as(usize, 0), fake_calls);
    try std.testing.expect(!isSecretType("serviceaccount"));
    try std.testing.expect(!isSecretType("pod"));
}

test "describe: pod environment section is scrubbed" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fakeOk(
        \\Name:         web
        \\Containers:
        \\  app:
        \\    Image:  nginx
        \\    Environment:
        \\      DB_PASSWORD:  hunter2
        \\      REGION:       eu-west-1
        \\      API_KEY:      <set to the key 'k' in secret 's'>  Optional: false
        \\      BLOB:         QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzNDU2Nzg5
        \\    Mounts:
        \\      /data from vol (rw)
        \\Events:  <none>
    );
    const r = try handleDescribe(ctx.arena, std.testing.io, try ctx.args("{\"resourceType\":\"pod\",\"name\":\"web\"}"));
    try std.testing.expect(!r.is_error);
    for ([_][]const u8{ "hunter2", "QUJDREVG" }) |bad| try std.testing.expect(std.mem.indexOf(u8, r.text, bad) == null);
    for ([_][]const u8{ "DB_PASSWORD:  [redacted]", "REGION:       eu-west-1", "<set to the key 'k' in secret 's'>", "/data from vol (rw)", "Image:  nginx" }) |good|
        try std.testing.expect(std.mem.indexOf(u8, r.text, good) != null);
}

test "scrubOutput: configmap data blocks, PEM, bearer, url passwords, log pairs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cm =
        \\Name:         cm
        \\Data
        \\====
        \\app.conf:
        \\----
        \\level=debug
        \\
        \\db_password:
        \\----
        \\pw999
        \\
        \\cert:
        \\----
        \\-----BEGIN PRIVATE KEY-----
        \\MIIEvQIBADANBg
        \\-----END PRIVATE KEY-----
        \\
        \\
        \\BinaryData
        \\====
        \\
        \\Events:  <none>
    ;
    const o = try scrubOutput(a, cm);
    for ([_][]const u8{ "pw999", "MIIEvQ", "BEGIN PRIVATE" }) |bad| try std.testing.expect(std.mem.indexOf(u8, o, bad) == null);
    try std.testing.expect(std.mem.indexOf(u8, o, "level=debug") != null);
    try std.testing.expect(std.mem.indexOf(u8, o, "Events:  <none>") != null);

    const logs =
        \\2024 connect postgres://admin:s3cr3t@db:5432/x ok
        \\Authorization: Bearer abc.def.ghi
        \\{"password":"hunter2","user":"bob"}
        \\login token=xyz789 done
        \\-----BEGIN RSA PRIVATE KEY-----
        \\AAAA
        \\-----END RSA PRIVATE KEY-----
        \\plain line stays
    ;
    const l = try scrubOutput(a, logs);
    for ([_][]const u8{ "s3cr3t", "abc.def.ghi", "hunter2", "xyz789", "AAAA" }) |bad| try std.testing.expect(std.mem.indexOf(u8, l, bad) == null);
    for ([_][]const u8{ "admin:", "@db:5432", "\"user\":\"bob\"", "plain line stays", "connect", "done" }) |good| {
        if (std.mem.eql(u8, good, "admin:")) continue; // userinfo is masked whole
        try std.testing.expect(std.mem.indexOf(u8, l, good) != null);
    }
}

test "logs: output is scrubbed" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fakeOk("start password=hunter2 end\nok\n");
    const r = try handleLogs(ctx.arena, std.testing.io, try ctx.args("{\"name\":\"web\"}"));
    try std.testing.expect(std.mem.indexOf(u8, r.text, "hunter2") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "start password=[redacted] end") != null);
}
