//! zmcp-aws: a safe wrapper around the AWS CLI v2 (`aws`). READ-ONLY by default.
//!
//! Tools:
//!   aws_call    {service, operation, params?, args?, region?, query?, max_items?, confirm?}
//!   aws_suggest {query}   offline hint table of common commands
//!   aws_whoami  {}        sts get-caller-identity (account/arn/user id only)
//!
//! Safety model lives in policy.zig (allowlist by operation-name verb, hard deny
//! table, env-gated writes), redaction/compaction in redact.zig. The `aws`
//! binary is spawned with argv only (no shell); credentials come from the
//! inherited AWS environment/profile and are never printed.
//!
//! Env (server start): ZMCP_AWS_ALLOW_WRITE=1, ZMCP_AWS_ALLOW_DESTRUCTIVE=1,
//! ZMCP_AWS_ALLOW_PROFILES=a,b, ZMCP_AWS_DOWNLOAD_DIR=/abs/dir,
//! ZMCP_AWS_MAX_DOWNLOAD_BYTES=N.

const std = @import("std");
const mcp = @import("mcp");
const policy = @import("policy.zig");
const redact = @import("redact.zig");
const catalog = @import("catalog.zig");

const Io = std.Io;

const MAX_CAPTURE_BYTES: usize = 8 * 1024 * 1024;
pub const MAX_OUTPUT_BYTES: usize = redact.MAX_OUTPUT;
const MAX_ERR_BYTES: usize = 4 * 1024;

var cfg: policy.Config = .{};

pub fn main(init: std.process.Init) !void {
    const env = init.environ_map;
    cfg = try configFromEnv(init.gpa, .{
        .allow_write = env.get("ZMCP_AWS_ALLOW_WRITE"),
        .allow_destructive = env.get("ZMCP_AWS_ALLOW_DESTRUCTIVE"),
        .profiles = env.get("ZMCP_AWS_ALLOW_PROFILES"),
        .download_dir = env.get("ZMCP_AWS_DOWNLOAD_DIR"),
        .max_download = env.get("ZMCP_AWS_MAX_DOWNLOAD_BYTES"),
    });
    try mcp.run(init.gpa, init.io, .{ .name = "zmcp-aws", .version = "0.1.0" }, &tool_table);
}

pub const EnvValues = struct {
    allow_write: ?[]const u8 = null,
    allow_destructive: ?[]const u8 = null,
    profiles: ?[]const u8 = null,
    download_dir: ?[]const u8 = null,
    max_download: ?[]const u8 = null,
};

/// Only exactly "1" enables a flag.
fn flag(v: ?[]const u8) bool {
    return if (v) |s| std.mem.eql(u8, s, "1") else false;
}

pub fn configFromEnv(alloc: std.mem.Allocator, v: EnvValues) !policy.Config {
    var c: policy.Config = .{};
    c.allow_write = flag(v.allow_write);
    c.allow_destructive = flag(v.allow_destructive);
    if (v.profiles) |p| {
        var list: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, p, ',');
        while (it.next()) |raw| {
            const t = std.mem.trim(u8, raw, " \t");
            if (t.len > 0) try list.append(alloc, t);
        }
        c.profiles = try list.toOwnedSlice(alloc);
    }
    if (v.download_dir) |d| {
        // Must be absolute and free of '..' segments; otherwise downloads stay off.
        if (d.len > 1 and d[0] == '/' and std.mem.indexOf(u8, d, "..") == null) {
            c.download_dir = d;
        } else {
            std.debug.print("zmcp-aws: ignoring ZMCP_AWS_DOWNLOAD_DIR (must be an absolute path without '..')\n", .{});
        }
    }
    if (v.max_download) |m| {
        if (std.fmt.parseInt(u64, m, 10)) |n| {
            if (n >= 1024 and n <= 1024 * 1024 * 1024) c.max_download = n;
        } else |_| {}
    }
    return c;
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "aws_call",
        .description = "Run an AWS CLI v2 command (no shell). Read ops (describe-/list-/get-/head-/lookup-/search-) always work; writes need ZMCP_AWS_ALLOW_WRITE=1, destructive ones also ZMCP_AWS_ALLOW_DESTRUCTIVE=1 + confirm=true. Secret-returning ops are blocked, secrets in output redacted. Use query (JMESPath) to cut output.",
        .input_schema_json =
        \\{"type":"object","properties":{"service":{"type":"string","description":"e.g. ec2, s3api, iam"},"operation":{"type":"string","description":"e.g. describe-instances"},"params":{"type":"object","description":"CLI flags without --: {\"instance-ids\":[\"i-1\"],\"dry-run\":true}"},"args":{"type":"array","items":{"type":"string"},"description":"positionals (s3 URIs)"},"region":{"type":"string"},"query":{"type":"string","description":"JMESPath --query"},"max_items":{"type":"integer","description":"page size; result may carry NextToken"},"confirm":{"type":"boolean","description":"required for destructive ops"}},"required":["service","operation"]}
        ,
        .handler = handleCall,
    },
    .{
        .name = "aws_suggest",
        .description = "Offline fuzzy search of ~150 common AWS CLI service/operation names with example params. A hint table only.",
        .input_schema_json =
        \\{"type":"object","properties":{"query":{"type":"string","description":"e.g. list lambda functions"}},"required":["query"]}
        ,
        .handler = handleSuggest,
        .read_only = true,
    },
    .{
        .name = "aws_whoami",
        .description = "Current AWS identity (sts get-caller-identity): account, arn, user id.",
        .input_schema_json =
        \\{"type":"object","properties":{}}
        ,
        .handler = handleWhoami,
        .read_only = true,
    },
};

// ---------------------------------------------------------------------------
// Process-execution seam (injectable for offline unit tests)
// ---------------------------------------------------------------------------

pub const ExecResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    truncated: bool = false,
};

pub const ExecFn = *const fn (alloc: std.mem.Allocator, io: Io, argv: []const []const u8) anyerror!ExecResult;
pub const ExistsFn = *const fn (io: Io, path: []const u8) bool;

var exec_fn: ExecFn = execReal;
var exists_fn: ExistsFn = existsReal;

fn existsReal(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn execReal(alloc: std.mem.Allocator, io: Io, argv: []const []const u8) !ExecResult {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    }) catch |e| switch (e) {
        error.FileNotFound => return error.ExecutableNotFound,
        else => return e,
    };
    defer child.kill(io);

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(alloc, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    var truncated = false;
    while (multi_reader.fill(64, .none)) |_| {
        if (stdout_reader.buffered().len > MAX_CAPTURE_BYTES or stderr_reader.buffered().len > MAX_CAPTURE_BYTES) {
            truncated = true;
            break;
        }
    } else |e| switch (e) {
        error.EndOfStream => {},
        else => |x| return x,
    }

    if (truncated) {
        return .{
            .term = .{ .exited = 0 },
            .stdout = try multi_reader.toOwnedSlice(0),
            .stderr = try multi_reader.toOwnedSlice(1),
            .truncated = true,
        };
    }

    try multi_reader.checkAnyError();
    const term = try child.wait(io);
    return .{
        .term = term,
        .stdout = try multi_reader.toOwnedSlice(0),
        .stderr = try multi_reader.toOwnedSlice(1),
    };
}

// ---------------------------------------------------------------------------
// Argument helpers
// ---------------------------------------------------------------------------

fn errResult(text: []const u8) mcp.ToolResult {
    return .{ .text = text, .is_error = true };
}

fn errf(alloc: std.mem.Allocator, comptime f: []const u8, args: anytype) !mcp.ToolResult {
    return errResult(try std.fmt.allocPrint(alloc, f, args));
}

fn getField(args: std.json.Value, key: []const u8) ?std.json.Value {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    if (v == .null) return null;
    return v;
}

/// Extract a request from tool arguments. Returns an error message on a type error.
fn parseRequest(alloc: std.mem.Allocator, args: std.json.Value) !union(enum) { req: policy.Request, err: []const u8 } {
    if (args != .object) return .{ .err = "error: arguments must be an object" };
    const svc = getField(args, "service") orelse return .{ .err = "error: service is required" };
    const op = getField(args, "operation") orelse return .{ .err = "error: operation is required" };
    if (svc != .string) return .{ .err = "error: service must be a string" };
    if (op != .string) return .{ .err = "error: operation must be a string" };
    var req: policy.Request = .{ .service = svc.string, .operation = op.string };
    req.params = getField(args, "params");
    if (getField(args, "region")) |r| {
        if (r != .string) return .{ .err = "error: region must be a string" };
        req.region = r.string;
    }
    if (getField(args, "query")) |q| {
        if (q != .string) return .{ .err = "error: query must be a string" };
        req.query = q.string;
    }
    if (getField(args, "max_items")) |m| {
        req.max_items = switch (m) {
            .integer => |i| i,
            .float => |f| if (std.math.isFinite(f) and @abs(f) < 1e9) @as(i64, @intFromFloat(f)) else return .{ .err = "error: max_items must be an integer" },
            else => return .{ .err = "error: max_items must be an integer" },
        };
    }
    if (getField(args, "confirm")) |c| {
        if (c != .bool) return .{ .err = "error: confirm must be a boolean" };
        req.confirm = c.bool;
    }
    if (getField(args, "args")) |a| {
        if (a != .array) return .{ .err = "error: args must be an array of strings" };
        var list: std.ArrayList([]const u8) = .empty;
        for (a.array.items) |x| {
            if (x != .string) return .{ .err = "error: args must be an array of strings" };
            try list.append(alloc, x.string);
        }
        req.args = try list.toOwnedSlice(alloc);
    }
    return .{ .req = req };
}

// ---------------------------------------------------------------------------
// Execution
// ---------------------------------------------------------------------------

fn hintFor(stderr: []const u8) ?[]const u8 {
    const has = struct {
        fn f(h: []const u8, n: []const u8) bool {
            return std.ascii.indexOfIgnoreCase(h, n) != null;
        }
    }.f;
    if (has(stderr, "Unable to locate credentials") or has(stderr, "NoCredentialProviders") or has(stderr, "Unable to load SSO") or has(stderr, "SSO session"))
        return "hint: no usable AWS credentials. Configure the standard environment/profile (AWS_PROFILE, AWS_ACCESS_KEY_ID, `aws sso login` outside this server).";
    if (has(stderr, "ExpiredToken") or has(stderr, "token has expired") or has(stderr, "security token included in the request is expired"))
        return "hint: credentials expired; refresh them outside this server.";
    if (has(stderr, "You must specify a region"))
        return "hint: pass region=... or set AWS_REGION / AWS_DEFAULT_REGION.";
    if (has(stderr, "Could not connect to the endpoint URL") or has(stderr, "Connect timeout"))
        return "hint: network/endpoint unreachable (check region and connectivity).";
    if (has(stderr, "Unknown options: --max-items") or has(stderr, "Unknown options: --starting-token"))
        return "hint: this operation is not paginated; omit max_items.";
    if (has(stderr, "AccessDenied") or has(stderr, "UnauthorizedOperation") or has(stderr, "not authorized to perform"))
        return "hint: IAM denied this call for the current identity (see aws_whoami).";
    return null;
}

/// Run a validated plan through the exec seam and shape the result.
fn execute(alloc: std.mem.Allocator, io: Io, plan: policy.Plan) !mcp.ToolResult {
    if (plan.must_not_exist) |path| {
        if (exists_fn(io, path)) return errf(alloc, "error: {s} already exists; choose a new file name (downloads never overwrite).", .{path});
    }
    const res = exec_fn(alloc, io, plan.argv) catch |e| switch (e) {
        error.ExecutableNotFound => return errResult("error: 'aws' CLI v2 not found on PATH. Install it: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"),
        else => return errf(alloc, "error: aws execution failed: {s}", .{@errorName(e)}),
    };
    const stderr_trim = std.mem.trim(u8, res.stderr, " \t\r\n");
    switch (res.term) {
        .exited => |code| if (code != 0) {
            const scrubbed = try redact.scrubString(alloc, if (stderr_trim.len > 0) stderr_trim else "(no error output)");
            const shown = if (scrubbed.len > MAX_ERR_BYTES) scrubbed[scrubbed.len - MAX_ERR_BYTES ..] else scrubbed;
            const hint = hintFor(stderr_trim);
            return errf(alloc, "error: aws exited with code {d}: {s}{s}{s}", .{ code, shown, if (hint != null) "\n" else "", hint orelse "" });
        },
        else => return errResult("error: aws terminated abnormally"),
    }

    const c = try redact.compactOutput(alloc, res.stdout, MAX_OUTPUT_BYTES);
    var out: std.ArrayList(u8) = .empty;
    if (c.text.len == 0) {
        try out.appendSlice(alloc, "(no output)");
    } else try out.appendSlice(alloc, c.text);
    if (!plan.text_output) {
        if (try redact.pagingHint(alloc, c.text, plan.used_max_items)) |h| try out.print(alloc, "\n[{s}]", .{h});
    }
    if (c.truncated_lists > 0) try out.print(alloc, "\n[truncated: {d} list(s) shortened to fit {d} KiB; narrow with query (JMESPath) or max_items]", .{ c.truncated_lists, MAX_OUTPUT_BYTES / 1024 });
    if (c.hard_cut) try out.print(alloc, "\n[output cut at {d} KiB; narrow with query (JMESPath) or max_items]", .{MAX_OUTPUT_BYTES / 1024});
    if (res.truncated) try out.appendSlice(alloc, "\n[capture limit hit: output was cut early; narrow with query or max_items]");
    if (c.redactions > 0) try out.print(alloc, "\n[{d} secret-looking value(s) redacted]", .{c.redactions});
    if (plan.note) |n| try out.print(alloc, "\n[{s}]", .{n});
    return .{ .text = try out.toOwnedSlice(alloc) };
}

fn handleCall(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const parsed = try parseRequest(alloc, args);
    const req = switch (parsed) {
        .err => |m| return errResult(m),
        .req => |r| r,
    };
    const built = try policy.build(alloc, &cfg, req);
    return switch (built) {
        .err => |m| errResult(m),
        .ok => |plan| execute(alloc, io, plan),
    };
}

fn handleSuggest(alloc: std.mem.Allocator, _: Io, args: std.json.Value) !mcp.ToolResult {
    const q = getField(args, "query") orelse return errResult("error: query is required");
    if (q != .string or q.string.len == 0) return errResult("error: query must be a non-empty string");
    const clipped = q.string[0..@min(q.string.len, 256)];
    return .{ .text = try catalog.search(alloc, clipped, 10) };
}

fn handleWhoami(alloc: std.mem.Allocator, io: Io, _: std.json.Value) !mcp.ToolResult {
    const built = try policy.build(alloc, &cfg, .{
        .service = "sts",
        .operation = "get-caller-identity",
        .query = "{Account:Account,Arn:Arn,UserId:UserId}",
    });
    const plan = switch (built) {
        .err => |m| return errResult(m),
        .ok => |p| p,
    };
    return execute(alloc, io, plan);
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

var fake_argv: []const []const u8 = &.{};
var fake_calls: usize = 0;
var fake_error: ?anyerror = null;
var fake_result: ExecResult = .{ .term = .{ .exited = 0 }, .stdout = @constCast(""), .stderr = @constCast("") };
var fake_exists: bool = false;

fn fakeExec(alloc: std.mem.Allocator, _: Io, argv: []const []const u8) anyerror!ExecResult {
    fake_calls += 1;
    var copy = try alloc.alloc([]const u8, argv.len);
    for (argv, 0..) |a, i| copy[i] = try alloc.dupe(u8, a);
    fake_argv = copy;
    if (fake_error) |e| return e;
    return fake_result;
}

fn fakeExists(_: Io, _: []const u8) bool {
    return fake_exists;
}

const TestCtx = struct {
    arena_state: std.heap.ArenaAllocator,
    arena: std.mem.Allocator,

    fn init(ctx: *TestCtx) void {
        ctx.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        ctx.arena = ctx.arena_state.allocator();
        exec_fn = fakeExec;
        exists_fn = fakeExists;
        fake_argv = &.{};
        fake_calls = 0;
        fake_error = null;
        fake_exists = false;
        fake_result = .{ .term = .{ .exited = 0 }, .stdout = @constCast("{}"), .stderr = @constCast("") };
        cfg = .{};
    }

    fn deinit(ctx: *TestCtx) void {
        exec_fn = execReal;
        exists_fn = existsReal;
        cfg = .{};
        ctx.arena_state.deinit();
    }

    fn call(ctx: *TestCtx, json: []const u8) !mcp.ToolResult {
        const p = try std.json.parseFromSlice(std.json.Value, ctx.arena, json, .{});
        return handleCall(ctx.arena, testing.io, p.value);
    }
};

fn expectArgv(want: []const []const u8) !void {
    try testing.expectEqual(want.len, fake_argv.len);
    for (want, fake_argv) |w, g| try testing.expectEqualStrings(w, g);
}

fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

const base_flags = [_][]const u8{ "--output=json", "--no-cli-pager", "--cli-connect-timeout=10", "--cli-read-timeout=60", "--no-paginate" };

test "read call builds the exact argv and returns compact JSON" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fake_result.stdout = @constCast("{\"ResponseMetadata\":{\"RequestId\":\"x\"},\"Reservations\":[]}");
    const r = try ctx.call("{\"service\":\"ec2\",\"operation\":\"describe-instances\",\"region\":\"eu-west-1\",\"query\":\"Reservations[].Instances[].InstanceId\",\"params\":{\"instance_ids\":[\"i-1\",\"i-2\"],\"dry-run\":false,\"MaxResults\":5,\"filters\":\"Name=tag:Env,Values=prod\"}}");
    try testing.expect(!r.is_error);
    try testing.expectEqualStrings("{\"Reservations\":[]}", r.text);
    try expectArgv(&(.{ "aws", "ec2", "describe-instances" } ++ base_flags ++ .{
        "--region=eu-west-1",
        "--query=Reservations[].Instances[].InstanceId",
        "--instance-ids",
        "i-1",
        "i-2",
        "--no-dry-run",
        "--max-results=5",
        "--filters=Name=tag:Env,Values=prod",
    }));
}

test "max_items replaces --no-paginate and NextToken hint is appended" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fake_result.stdout = @constCast("{\"Functions\":[],\"NextToken\":\"tok+/=\"}");
    const r = try ctx.call("{\"service\":\"lambda\",\"operation\":\"list-functions\",\"max_items\":10}");
    try expectArgv(&.{ "aws", "lambda", "list-functions", "--output=json", "--no-cli-pager", "--cli-connect-timeout=10", "--cli-read-timeout=60", "--max-items=10" });
    try testing.expect(contains(r.text, "starting-token") and contains(r.text, "tok+/="));
}

test "gating: read ok, write refused by default, destructive needs both flags and confirm" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    const w = "{\"service\":\"ec2\",\"operation\":\"start-instances\",\"params\":{\"instance-ids\":[\"i-1\"]}}";
    const d = "{\"service\":\"ec2\",\"operation\":\"terminate-instances\",\"params\":{\"instance-ids\":[\"i-1\"]}}";
    const dc = "{\"service\":\"ec2\",\"operation\":\"terminate-instances\",\"confirm\":true,\"params\":{\"instance-ids\":[\"i-1\"]}}";

    // default: both refused, nothing spawned
    var r = try ctx.call(w);
    try testing.expect(r.is_error and contains(r.text, "ZMCP_AWS_ALLOW_WRITE=1"));
    r = try ctx.call(dc);
    try testing.expect(r.is_error and contains(r.text, "ZMCP_AWS_ALLOW_DESTRUCTIVE=1"));
    try testing.expectEqual(@as(usize, 0), fake_calls);

    // write only
    cfg.allow_write = true;
    r = try ctx.call(w);
    try testing.expect(!r.is_error);
    try testing.expectEqual(@as(usize, 1), fake_calls);
    r = try ctx.call(dc);
    try testing.expect(r.is_error and contains(r.text, "ZMCP_AWS_ALLOW_DESTRUCTIVE=1"));
    try testing.expectEqual(@as(usize, 1), fake_calls);

    // destructive flag without write flag is still refused
    cfg.allow_write = false;
    cfg.allow_destructive = true;
    r = try ctx.call(dc);
    try testing.expect(r.is_error);
    try testing.expectEqual(@as(usize, 1), fake_calls);

    // both flags, no confirm
    cfg.allow_write = true;
    r = try ctx.call(d);
    try testing.expect(r.is_error and contains(r.text, "confirm=true"));
    try testing.expectEqual(@as(usize, 1), fake_calls);
    // confirm=false explicit
    r = try ctx.call("{\"service\":\"ec2\",\"operation\":\"terminate-instances\",\"confirm\":false}");
    try testing.expect(r.is_error);
    try testing.expectEqual(@as(usize, 1), fake_calls);

    // everything set
    r = try ctx.call(dc);
    try testing.expect(!r.is_error);
    try testing.expectEqual(@as(usize, 2), fake_calls);
    try testing.expectEqualStrings("terminate-instances", fake_argv[2]);
}

test "hard-denied ops stay denied even with every flag and confirm" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    cfg.allow_write = true;
    cfg.allow_destructive = true;
    const bad = [_][]const u8{
        "{\"service\":\"secretsmanager\",\"operation\":\"get-secret-value\",\"confirm\":true}",
        "{\"service\":\"kms\",\"operation\":\"decrypt\",\"confirm\":true}",
        "{\"service\":\"sts\",\"operation\":\"assume-role\",\"confirm\":true}",
        "{\"service\":\"iam\",\"operation\":\"create-access-key\",\"confirm\":true}",
        "{\"service\":\"configure\",\"operation\":\"set\",\"confirm\":true}",
    };
    for (bad) |b| {
        const r = try ctx.call(b);
        try testing.expect(r.is_error and contains(r.text, "blocked"));
    }
    try testing.expectEqual(@as(usize, 0), fake_calls);
}

test "type and shape errors do not spawn" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    const bad = [_][]const u8{
        "{}",
        "{\"service\":1,\"operation\":\"x\"}",
        "{\"service\":\"ec2\"}",
        "{\"service\":\"ec2\",\"operation\":\"describe-instances\",\"args\":[1]}",
        "{\"service\":\"ec2\",\"operation\":\"describe-instances\",\"params\":[1]}",
        "{\"service\":\"ec2\",\"operation\":\"describe-instances\",\"max_items\":\"5\"}",
        "{\"service\":\"ec2\",\"operation\":\"describe-instances\",\"max_items\":0}",
        "{\"service\":\"ec2\",\"operation\":\"describe-instances\",\"region\":\"us-east-1; rm\"}",
        "{\"service\":\"ec2\",\"operation\":\"describe-instances\",\"query\":\"a\\nb\"}",
        "{\"service\":\"ec2\",\"operation\":\"describe-instances\",\"confirm\":\"yes\"}",
    };
    for (bad) |b| {
        const r = try ctx.call(b);
        try testing.expect(r.is_error);
    }
    try testing.expectEqual(@as(usize, 0), fake_calls);
}

test "output: secrets redacted, note added" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fake_result.stdout = @constCast("{\"AccessKeyMetadata\":[{\"UserName\":\"u\",\"AccessKeyId\":\"AKIAIOSFODNN7EXAMPLE\"}]}");
    const r = try ctx.call("{\"service\":\"iam\",\"operation\":\"list-access-keys\"}");
    try testing.expect(!r.is_error);
    try testing.expect(!contains(r.text, "AKIAIOSFODNN7EXAMPLE"));
    try testing.expect(contains(r.text, "[REDACTED]") and contains(r.text, "1 secret-looking"));
}

test "errors: missing binary, credentials hint, secret scrub in stderr" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fake_error = error.ExecutableNotFound;
    var r = try ctx.call("{\"service\":\"ec2\",\"operation\":\"describe-vpcs\"}");
    try testing.expect(r.is_error and contains(r.text, "'aws' CLI v2 not found"));

    fake_error = null;
    fake_result = .{ .term = .{ .exited = 253 }, .stdout = @constCast(""), .stderr = @constCast("Unable to locate credentials. You can configure credentials by running \"aws configure\".\n") };
    r = try ctx.call("{\"service\":\"ec2\",\"operation\":\"describe-vpcs\"}");
    try testing.expect(r.is_error and contains(r.text, "code 253") and contains(r.text, "hint: no usable AWS credentials"));

    fake_result = .{ .term = .{ .exited = 254 }, .stdout = @constCast(""), .stderr = @constCast("An error occurred: https://h/p?X-Amz-Signature=SECRETSIG&a=1\n") };
    r = try ctx.call("{\"service\":\"ec2\",\"operation\":\"describe-vpcs\"}");
    try testing.expect(!contains(r.text, "SECRETSIG"));
}

test "s3 ls: text output, no json/paginate flags, s3:// args only" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fake_result.stdout = @constCast("2024-01-01 00:00:00 my-bucket\n");
    const r = try ctx.call("{\"service\":\"s3\",\"operation\":\"ls\",\"args\":[\"s3://my-bucket/p/\"],\"params\":{\"recursive\":true,\"human-readable\":true}}");
    try testing.expect(!r.is_error);
    try testing.expectEqualStrings("2024-01-01 00:00:00 my-bucket", r.text);
    try expectArgv(&.{ "aws", "s3", "ls", "s3://my-bucket/p/", "--no-cli-pager", "--cli-connect-timeout=10", "--cli-read-timeout=60", "--recursive", "--human-readable" });
    const bad = try ctx.call("{\"service\":\"s3\",\"operation\":\"ls\",\"args\":[\"/etc\"]}");
    try testing.expect(bad.is_error);
}

test "get-object: disabled without download dir; confined, capped, no overwrite with one" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    const q = "{\"service\":\"s3api\",\"operation\":\"get-object\",\"args\":[\"a.bin\"],\"params\":{\"bucket\":\"b\",\"key\":\"k\"}}";
    var r = try ctx.call(q);
    try testing.expect(r.is_error and contains(r.text, "ZMCP_AWS_DOWNLOAD_DIR"));
    try testing.expectEqual(@as(usize, 0), fake_calls);

    cfg.download_dir = "/srv/dl";
    cfg.max_download = 2048;
    r = try ctx.call(q);
    try testing.expect(!r.is_error and contains(r.text, "saved to /srv/dl/a.bin"));
    try expectArgv(&.{ "aws", "s3api", "get-object", "/srv/dl/a.bin", "--output=json", "--no-cli-pager", "--cli-connect-timeout=10", "--cli-read-timeout=60", "--no-paginate", "--range=bytes=0-2047", "--bucket=b", "--key=k" });

    for ([_][]const u8{ "../x", "/etc/passwd", "a/b", ".hidden", "-rf", "" }) |name| {
        const js = try std.fmt.allocPrint(ctx.arena, "{{\"service\":\"s3api\",\"operation\":\"get-object\",\"args\":[\"{s}\"],\"params\":{{\"bucket\":\"b\",\"key\":\"k\"}}}}", .{name});
        const e = try ctx.call(js);
        try testing.expect(e.is_error);
    }
    // range is server-managed
    r = try ctx.call("{\"service\":\"s3api\",\"operation\":\"get-object\",\"args\":[\"a.bin\"],\"params\":{\"bucket\":\"b\",\"key\":\"k\",\"range\":\"bytes=0-999999999\"}}");
    try testing.expect(r.is_error);

    const before = fake_calls;
    fake_exists = true;
    r = try ctx.call(q);
    try testing.expect(r.is_error and contains(r.text, "already exists"));
    try testing.expectEqual(before, fake_calls);
}

test "aws_whoami argv and read-only tool marks" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fake_result.stdout = @constCast("{\"Account\":\"123456789012\",\"Arn\":\"arn:aws:iam::123456789012:user/u\",\"UserId\":\"AIDA\"}");
    const r = try handleWhoami(ctx.arena, testing.io, .{ .null = {} });
    try testing.expect(!r.is_error and contains(r.text, "123456789012"));
    try expectArgv(&(.{ "aws", "sts", "get-caller-identity" } ++ base_flags ++ .{"--query={Account:Account,Arn:Arn,UserId:UserId}"}));

    for (tool_table) |t| {
        if (std.mem.eql(u8, t.name, "aws_call")) {
            try testing.expect(!t.read_only and !t.destructive);
        } else {
            try testing.expect(t.read_only and !t.destructive);
        }
    }
}

test "aws_suggest handler" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    const p = try std.json.parseFromSlice(std.json.Value, ctx.arena, "{\"query\":\"cloudwatch alarms\"}", .{});
    const r = try handleSuggest(ctx.arena, testing.io, p.value);
    try testing.expect(!r.is_error and contains(r.text, "cloudwatch describe-alarms"));
    try testing.expectEqual(@as(usize, 0), fake_calls);
    const e = try handleSuggest(ctx.arena, testing.io, .{ .object = std.json.ObjectMap.empty });
    try testing.expect(e.is_error);
}

test "config from env: only exactly 1 enables; profiles/dir/cap parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try configFromEnv(a, .{});
    try testing.expect(!c.allow_write and !c.allow_destructive and c.download_dir == null and c.profiles.len == 0);
    c = try configFromEnv(a, .{ .allow_write = "true", .allow_destructive = "yes" });
    try testing.expect(!c.allow_write and !c.allow_destructive);
    c = try configFromEnv(a, .{ .allow_write = "1", .allow_destructive = "1", .profiles = " dev, prod ,,", .download_dir = "/tmp/dl", .max_download = "4096" });
    try testing.expect(c.allow_write and c.allow_destructive);
    try testing.expectEqual(@as(usize, 2), c.profiles.len);
    try testing.expectEqualStrings("prod", c.profiles[1]);
    try testing.expectEqualStrings("/tmp/dl", c.download_dir.?);
    try testing.expectEqual(@as(u64, 4096), c.max_download);
    c = try configFromEnv(a, .{ .download_dir = "relative/dir", .max_download = "5" });
    try testing.expect(c.download_dir == null);
    try testing.expectEqual(@as(u64, 10 * 1024 * 1024), c.max_download);
    c = try configFromEnv(a, .{ .download_dir = "/tmp/../etc" });
    try testing.expect(c.download_dir == null);
}

test "tool table: unique names, valid schemas" {
    for (tool_table, 0..) |t, i| {
        for (tool_table[i + 1 ..]) |u| try testing.expect(!std.mem.eql(u8, t.name, u.name));
        var p = try std.json.parseFromSlice(std.json.Value, testing.allocator, t.input_schema_json, .{});
        p.deinit();
    }
    try testing.expectEqual(@as(usize, 3), tool_table.len);
}

test {
    _ = @import("policy_test.zig");
    _ = redact;
    _ = catalog;
}
