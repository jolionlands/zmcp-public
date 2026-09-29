//! Table-driven tests for the zmcp-aws allow/deny classifier, flag conversion
//! and argv builder. No aws binary, credentials or network needed.

const std = @import("std");
const policy = @import("policy.zig");

const testing = std.testing;
const Class = policy.Class;

fn expectClass(svc: []const u8, op: []const u8, want: Class) !void {
    switch (policy.classify(svc, op)) {
        .allow => |c| if (c != want) {
            std.debug.print("classify {s} {s}: got {s}, want {s}\n", .{ svc, op, @tagName(c), @tagName(want) });
            return error.TestExpectedEqual;
        },
        .deny => |why| {
            std.debug.print("classify {s} {s}: denied ({s}), want {s}\n", .{ svc, op, why, @tagName(want) });
            return error.TestExpectedEqual;
        },
    }
}

fn expectDenied(svc: []const u8, op: []const u8) !void {
    switch (policy.classify(svc, op)) {
        .allow => |c| {
            std.debug.print("classify {s} {s}: allowed as {s}, want deny\n", .{ svc, op, @tagName(c) });
            return error.TestExpectedEqual;
        },
        .deny => {},
    }
}

test "read verbs are read" {
    const rows = [_][2][]const u8{
        .{ "ec2", "describe-instances" },     .{ "iam", "list-users" },           .{ "iam", "get-role" },
        .{ "dynamodb", "batch-get-item" },    .{ "s3api", "head-object" },        .{ "cloudtrail", "lookup-events" },
        .{ "s3api", "list-objects-v2" },      .{ "resourcegroupstaggingapi", "get-resources" },
        .{ "kendra", "search-anything" },     .{ "codebuild", "batch-get-builds" },
        .{ "sts", "get-caller-identity" },    .{ "s3", "ls" },
        .{ "secretsmanager", "list-secrets" }, .{ "secretsmanager", "describe-secret" },
        .{ "secretsmanager", "get-random-password" }, .{ "iam", "get-account-password-policy" },
        .{ "ssm", "get-parameter" },          .{ "lambda", "get-function" },
        .{ "lambda", "get-function-configuration" }, .{ "kms", "get-public-key" },
        .{ "iam", "list-service-specific-credentials" }, // list-* metadata, not secrets
        .{ "dynamodb", "query" },             .{ "dynamodb", "scan" },
        .{ "logs", "tail" },                  .{ "logs", "filter-log-events" },
        .{ "iam", "simulate-principal-policy" }, .{ "cloudformation", "validate-template" },
    };
    for (rows) |r| try expectClass(r[0], r[1], .read);
}

test "non-read verbs are writes; destructive verbs escalate" {
    const writes = [_][2][]const u8{
        .{ "ec2", "run-instances" },   .{ "ec2", "start-instances" },  .{ "ec2", "create-tags" },
        .{ "s3api", "put-object" },    .{ "s3api", "create-bucket" },  .{ "s3", "cp" },
        .{ "s3", "mb" },               .{ "sqs", "send-message" },     .{ "sqs", "receive-message" },
        .{ "sns", "publish" },         .{ "logs", "start-query" },     .{ "lambda", "update-function-code" },
        .{ "dynamodb", "put-item" },   .{ "foo", "totally-unknown-op" }, .{ "s3", "unknown-subcommand" },
        .{ "s3api", "put-bucket-tagging" }, .{ "athena", "start-query-execution" },
    };
    for (writes) |r| try expectClass(r[0], r[1], .write);

    const destructive = [_][2][]const u8{
        .{ "ec2", "terminate-instances" }, .{ "ec2", "stop-instances" },      .{ "ec2", "reboot-instances" },
        .{ "s3api", "delete-object" },     .{ "s3api", "delete-bucket" },     .{ "s3", "rm" },
        .{ "s3", "rb" },                   .{ "s3", "mv" },                   .{ "s3", "sync" },
        .{ "ec2", "deregister-image" },    .{ "ec2", "detach-volume" },       .{ "ec2", "revoke-security-group-ingress" },
        .{ "ec2", "disable-vpc-classic-link" }, .{ "iam", "update-assume-role-policy" }, .{ "iam", "attach-role-policy" },
        .{ "iam", "create-role" },         .{ "iam", "put-role-policy" },     .{ "iam", "delete-user" },
        .{ "s3api", "put-bucket-policy" }, .{ "sns", "remove-permission" },   .{ "lambda", "invoke" },
        .{ "lambda", "delete-function" },  .{ "ssm", "send-command" },        .{ "ssm", "start-session" },
        .{ "ecs", "execute-command" },     .{ "rds-data", "execute-statement" }, .{ "kms", "schedule-key-deletion" },
        .{ "sqs", "purge-queue" },         .{ "ec2", "cancel-spot-instance-requests" },
        .{ "organizations", "put-resource-policy" },
    };
    for (destructive) |r| try expectClass(r[0], r[1], .destructive);
}

test "deny table: every rule denies" {
    const rows = [_][2][]const u8{
        .{ "secretsmanager", "get-secret-value" },
        .{ "secretsmanager", "batch-get-secret-value" },
        .{ "kms", "decrypt" },
        .{ "kms", "generate-data-key" },
        .{ "kms", "generate-data-key-pair" },
        .{ "kms", "generate-random" },
        .{ "kms", "re-encrypt" },
        .{ "sts", "assume-role" },
        .{ "sts", "assume-role-with-web-identity" },
        .{ "sts", "assume-role-with-saml" },
        .{ "sts", "get-session-token" },
        .{ "sts", "get-federation-token" },
        .{ "sts", "assume-root" },
        .{ "iam", "create-access-key" },
        .{ "iam", "get-credential-report" },
        .{ "iam", "create-login-profile" },
        .{ "iam", "update-login-profile" },
        .{ "iam", "create-service-specific-credential" },
        .{ "iam", "reset-service-specific-credential" },
        .{ "ecr", "get-login-password" },
        .{ "ecr", "get-authorization-token" },
        .{ "ecr-public", "get-authorization-token" },
        .{ "codeartifact", "get-authorization-token" },
        .{ "eks", "get-token" },
        .{ "ec2", "get-password-data" },
        .{ "rds", "generate-db-auth-token" },
        .{ "redshift", "get-cluster-credentials" },
        .{ "redshift", "get-cluster-credentials-with-iam" },
        .{ "redshift-serverless", "get-credentials" },
        .{ "cognito-identity", "get-credentials-for-identity" },
        .{ "cognito-identity", "get-open-id-token" },
        .{ "cognito-identity", "get-open-id-token-for-developer-identity" },
        .{ "lakeformation", "get-temporary-glue-table-credentials" },
        .{ "lightsail", "get-instance-access-details" },
        .{ "lightsail", "get-key-pairs" },
        .{ "logs", "start-live-tail" },
        .{ "s3", "presign" },
        .{ "s3api", "presign" },
        .{ "configure", "get" },
        .{ "configure", "set" },
        .{ "configure", "list" },
        .{ "login", "anything" },
        .{ "logout", "anything" },
        .{ "sso", "login" },
        .{ "sso", "get-role-credentials" },
        .{ "sso-oidc", "create-token" },
        .{ "history", "show" },
        .{ "help", "x" },
        // generic secret-ish name safety net for read prefixes
        .{ "newsvc", "get-service-credentials" },
        .{ "newsvc", "get-db-password" },
        .{ "newsvc", "get-auth-token" },
        .{ "newsvc", "batch-get-secret-value" },
        .{ "cognito-idp", "get-tokens-from-refresh-token" },
    };
    for (rows) |r| try expectDenied(r[0], r[1]);
}

test "sts is an allowlist" {
    try expectClass("sts", "get-caller-identity", .read);
    try expectClass("sts", "decode-authorization-message", .read);
    try expectClass("sts", "get-access-key-info", .read);
    try expectDenied("sts", "anything-new");
    try expectDenied("sts", "describe-something");
}

// ---------------------------------------------------------------------------
// build(): name validation, injection, flag conversion
// ---------------------------------------------------------------------------

const Harness = struct {
    arena: std.heap.ArenaAllocator,
    cfg: policy.Config = .{},

    fn init() Harness {
        return .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    }
    fn deinit(h: *Harness) void {
        h.arena.deinit();
    }
    fn params(h: *Harness, json: []const u8) !std.json.Value {
        return (try std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(), json, .{}));
    }
    fn build(h: *Harness, svc: []const u8, op: []const u8, params_json: ?[]const u8) !policy.Built {
        var req: policy.Request = .{ .service = svc, .operation = op };
        if (params_json) |j| req.params = try h.params(j);
        return policy.build(h.arena.allocator(), &h.cfg, req);
    }
    fn buildReq(h: *Harness, req: policy.Request) !policy.Built {
        return policy.build(h.arena.allocator(), &h.cfg, req);
    }
};

fn expectErr(b: policy.Built, needle: []const u8) !void {
    switch (b) {
        .ok => |p| {
            std.debug.print("expected error containing '{s}', got argv:", .{needle});
            for (p.argv) |a| std.debug.print(" {s}", .{a});
            std.debug.print("\n", .{});
            return error.TestExpectedError;
        },
        .err => |m| if (std.mem.indexOf(u8, m, needle) == null) {
            std.debug.print("error '{s}' lacks '{s}'\n", .{ m, needle });
            return error.TestExpectedError;
        },
    }
}

fn argvContains(b: policy.Built, want: []const u8) bool {
    switch (b) {
        .ok => |p| {
            for (p.argv) |a| if (std.mem.eql(u8, a, want)) return true;
            return false;
        },
        .err => return false,
    }
}

test "service/operation name tricks are rejected before classification" {
    var h = Harness.init();
    defer h.deinit();
    const bad_ops = [_][]const u8{
        "Get-Secret-Value",
        "GET-SECRET-VALUE",
        "get-secret-Value",
        " describe-instances",
        "describe-instances ",
        "describe-instances;rm",
        "describe-instances|cat",
        "describe-instances&&id",
        "describe instances",
        "describe-instances\n",
        "describe-instances\x00",
        "--help",
        "-describe",
        "get_secret_value",
        "describe-instances$(id)",
        "describe-instances`id`",
        "d\u{0435}scribe-instances", // cyrillic e
        "describe\u{2011}instances", // non-breaking hyphen
        "describe-ｉnstances", // fullwidth i
        "",
        "../describe",
        "describe/instances",
        "a" ** 65,
    };
    for (bad_ops) |op| try expectErr(try h.build("ec2", op, null), "error:");
    const bad_svcs = [_][]const u8{ "EC2", " ec2", "ec2 ", "ec2;ls", "ec2 --profile x", "--profile", "-ec2", "ｅc2", "", "s3 ls", "S3", "S3api" };
    for (bad_svcs) |s| try expectErr(try h.build(s, "describe-instances", null), "error:");
    // the case trick against the deny table specifically
    try expectErr(try h.build("secretsmanager", "Get-Secret-Value", null), "lowercase");
    try expectErr(try h.build("SecretsManager", "get-secret-value", null), "lowercase");
    try expectErr(try h.build("secretsmanager", "get-secret-value", null), "blocked");
}

test "s3 vs s3api are distinct namespaces" {
    var h = Harness.init();
    defer h.deinit();
    // s3api has no ls/cp/rm subcommands: they are writes by fail-closed default
    try expectClass("s3api", "ls", .write);
    try expectClass("s3api", "rm", .write);
    // s3 has no list-buckets: unknown s3 subcommands are writes
    try expectClass("s3", "list-buckets", .write);
    try expectClass("s3", "get-object", .write);
    // and are refused by default
    try expectErr(try h.build("s3", "list-buckets", null), "refused");
    try expectErr(try h.build("s3", "cp", null), "refused");
    try expectErr(try h.build("s3", "rm", null), "refused");
    try expectErr(try h.build("s3", "sync", null), "refused");
    try expectErr(try h.build("s3", "mv", null), "refused");
    try expectErr(try h.build("s3", "mb", null), "refused");
    try expectErr(try h.build("s3", "rb", null), "refused");
    try expectErr(try h.build("s3", "presign", null), "blocked");
    switch (try h.build("s3api", "list-buckets", null)) {
        .ok => {},
        .err => return error.TestUnexpectedResult,
    }
}

test "dash-leading and flag-shaped params cannot inject options" {
    var h = Harness.init();
    defer h.deinit();
    // string value that looks like a flag stays glued to its own flag via '='
    const b = try h.build("ec2", "describe-instances", "{\"filters\":\"--endpoint-url=http://evil\"}");
    // http:// inside a value that does not START with it is data, but the leading
    // dashes must be inert: exactly one argv element carries it, prefixed by --filters=
    try testing.expect(argvContains(b, "--filters=--endpoint-url=http://evil"));
    try testing.expect(!argvContains(b, "--endpoint-url=http://evil"));
    // list items may not start with '-'
    try expectErr(try h.build("ec2", "describe-instances", "{\"instance-ids\":[\"--endpoint-url\"]}"), "must not start with '-'");
    try expectErr(try h.build("ec2", "describe-instances", "{\"instance-ids\":[\"i-1\",\"-x\"]}"), "must not start with '-'");
    // keys cannot smuggle dashes/spaces/equals
    for ([_][]const u8{ "--endpoint-url", "-x", "a b", "a=b", "a;b", "", "a/b", "a\\u0000b" }) |k| {
        const js = try std.fmt.allocPrint(h.arena.allocator(), "{{\"{s}\":\"v\"}}", .{k});
        try expectErr(try h.build("ec2", "describe-instances", js), "invalid param name");
    }
    // positionals may not start with '-'
    try expectErr(try h.buildReq(.{ .service = "s3", .operation = "ls", .args = &.{"--recursive"} }), "must not start with '-'");
    try expectErr(try h.buildReq(.{ .service = "ec2", .operation = "describe-instances", .args = &.{"-x"} }), "must not start with '-'");
    try expectErr(try h.buildReq(.{ .service = "ec2", .operation = "describe-instances", .args = &.{""} }), "empty");
    // positionals precede every flag
    switch (try h.buildReq(.{ .service = "ec2", .operation = "describe-instances", .args = &.{"pos"}, .params = try h.params("{\"instance-ids\":[\"i-1\"]}") })) {
        .ok => |p| try testing.expectEqualStrings("pos", p.argv[3]),
        .err => return error.TestUnexpectedResult,
    }
}

test "denied flags: exact, abbreviated, cased, snake and camel forms" {
    var h = Harness.init();
    defer h.deinit();
    const keys = [_][]const u8{
        "endpoint-url", "endpoint_url", "endpointUrl", "EndpointUrl", "endpoint", "endpoint-ur", "e",
        "no-verify-ssl", "noVerifySsl", "no-verify", "no",
        "ca-bundle", "ca", "cabundle_", // last is not an abbreviation and simply unknown; handled below
        "debug", "deb", "d",
        "output", "out", "o",
        "query", "que", "q",
        "no-paginate", "max-items", "max", "m",
        "no-sign-request", "color", "col", "version", "help", "h", "region", "reg", "r",
        "profile", "prof", "pr", "p", "v2-debug", "generate-cli-skeleton", "gen",
        "cli-input-json", "cli-input-yaml", "cli-binary-format", "cli-read-timeout", "cli-connect-timeout", "cli-auto-prompt", "cli-anything",
        "no-cli-pager", "no-cli",
    };
    for (keys) |k| {
        if (std.mem.eql(u8, k, "cabundle_")) continue;
        const js = try std.fmt.allocPrint(h.arena.allocator(), "{{\"{s}\":\"x\"}}", .{k});
        const b = try h.build("ec2", "describe-instances", js);
        switch (b) {
            .ok => |p| {
                std.debug.print("key '{s}' was accepted: {s}\n", .{ k, p.argv[p.argv.len - 1] });
                return error.TestExpectedError;
            },
            .err => {},
        }
    }
    // a legitimate flag that merely shares a stem is fine
    const ok = try h.build("ec2", "describe-instances", "{\"max-results\":5,\"dry-run\":true,\"page-size\":10}");
    try testing.expect(argvContains(ok, "--max-results=5") and argvContains(ok, "--dry-run") and argvContains(ok, "--page-size=10"));
    // the server's own flags appear exactly once
    var outputs: usize = 0;
    for (ok.ok.argv) |a| {
        if (std.mem.startsWith(u8, a, "--output")) outputs += 1;
    }
    try testing.expectEqual(@as(usize, 1), outputs);
}

test "profile: only allowlisted values, never abbreviated" {
    var h = Harness.init();
    defer h.deinit();
    try expectErr(try h.build("ec2", "describe-instances", "{\"profile\":\"prod\"}"), "ZMCP_AWS_ALLOW_PROFILES");
    try expectErr(try h.build("ec2", "describe-instances", "{\"profile\":1}"), "must be a string");
    h.cfg.profiles = &.{ "dev", "prod" };
    try testing.expect(argvContains(try h.build("ec2", "describe-instances", "{\"profile\":\"prod\"}"), "--profile=prod"));
    try expectErr(try h.build("ec2", "describe-instances", "{\"profile\":\"Prod\"}"), "not in ZMCP_AWS_ALLOW_PROFILES");
    try expectErr(try h.build("ec2", "describe-instances", "{\"profile\":\"prod --debug\"}"), "not in ZMCP_AWS_ALLOW_PROFILES");
    try expectErr(try h.build("ec2", "describe-instances", "{\"prof\":\"prod\"}"), "blocked");
}

test "file://, fileb://, http(s)://, expansion and control chars in values" {
    var h = Harness.init();
    defer h.deinit();
    const bad_vals = [_][]const u8{
        "file:///etc/passwd",      "FILE:///etc/passwd",   "fileb:///etc/passwd",
        " file://x",               "Name=file://x",         "prefix-file://x",
        "\\\\nfile://x",           "http://169.254.169.254/latest/meta-data",
        "https://evil.example/x",  "HTTPS://evil/x",       "  http://x",
        "$(id)",                   "a`id`b",               "x\\u0000y",
        "x\\u0007y",               "x\\u007fy",
    };
    for (bad_vals) |v| {
        const js = try std.fmt.allocPrint(h.arena.allocator(), "{{\"policy-document\":\"{s}\"}}", .{v});
        try expectErr(try h.build("iam", "get-role", js), "error:");
    }
    // nested places: list item, object value, object key
    try expectErr(try h.build("ec2", "describe-instances", "{\"instance-ids\":[\"file://x\"]}"), "file://");
    try expectErr(try h.build("ec2", "describe-instances", "{\"filters\":[{\"Name\":\"x\",\"Values\":[\"fileb://y\"]}]}"), "fileb://");
    try expectErr(try h.build("ec2", "describe-instances", "{\"filters\":{\"file://k\":\"v\"}}"), "file://");
    try expectErr(try h.buildReq(.{ .service = "ec2", .operation = "describe-instances", .args = &.{"file://x"} }), "file://");
    // an https:// that is not at the start (e.g. inside JSON) is data
    switch (try h.build("ec2", "describe-instances", "{\"filters\":\"Name=tag:url,Values=x https://ok\"}")) {
        .ok => {},
        .err => return error.TestUnexpectedResult,
    }
    // multi-line JSON/tab is allowed
    switch (try h.build("ec2", "describe-instances", "{\"filters\":\"a\\n\\tb\"}")) {
        .ok => {},
        .err => return error.TestUnexpectedResult,
    }
    // cli-input-* cannot be passed under any spelling
    for ([_][]const u8{ "cli-input-json", "cli_input_json", "CliInputJson", "cliInputYaml", "cli-input-yaml" }) |k| {
        const js = try std.fmt.allocPrint(h.arena.allocator(), "{{\"{s}\":\"x\"}}", .{k});
        try expectErr(try h.build("ec2", "describe-instances", js), "blocked");
    }
}

test "secret-returning flags blocked (ssm with-decryption, apigateway include-value, logs follow)" {
    var h = Harness.init();
    defer h.deinit();
    for ([_][]const u8{ "get-parameter", "get-parameters", "get-parameters-by-path", "get-parameter-history" }) |op| {
        try expectErr(try h.build("ssm", op, "{\"name\":\"/a\",\"with-decryption\":true}"), "secret");
        try expectErr(try h.build("ssm", op, "{\"name\":\"/a\",\"with_decryption\":true}"), "secret");
        try expectErr(try h.build("ssm", op, "{\"name\":\"/a\",\"WithDecryption\":true}"), "secret");
        try expectErr(try h.build("ssm", op, "{\"name\":\"/a\",\"with-decryption\":\"true\"}"), "secret");
        try expectErr(try h.build("ssm", op, "{\"name\":\"/a\",\"with-decr\":true}"), "secret");
        try expectErr(try h.build("ssm", op, "{\"name\":\"/a\",\"with\":true}"), "secret");
        try expectErr(try h.build("ssm", op, "{\"name\":\"/a\",\"with-decryption\":1}"), "secret");
        // explicit false is fine and becomes --no-with-decryption
        try testing.expect(argvContains(try h.build("ssm", op, "{\"name\":\"/a\",\"with-decryption\":false}"), "--no-with-decryption"));
        try testing.expect(argvContains(try h.build("ssm", op, "{\"name\":\"/a\"}"), "--name=/a"));
    }
    // abbreviations of false are not trusted
    try expectErr(try h.build("ssm", "get-parameter", "{\"name\":\"/a\",\"with-decr\":false}"), "secret");
    try expectErr(try h.build("apigateway", "get-api-key", "{\"api-key\":\"k\",\"include-value\":true}"), "secret");
    try expectErr(try h.build("apigateway", "get-api-keys", "{\"include-values\":true}"), "secret");
    try expectErr(try h.build("logs", "tail", "{\"follow\":true}"), "secret");
    try expectErr(try h.build("logs", "tail", "{\"fol\":true}"), "secret");
    // other services may use a flag with the same name freely
    switch (try h.build("ec2", "describe-instances", "{\"follow\":true}")) {
        .ok => {},
        .err => return error.TestUnexpectedResult,
    }
}

test "flag conversion: kebab, snake, camel, bool, numbers, arrays, objects, duplicates" {
    var h = Harness.init();
    defer h.deinit();
    const a = h.arena.allocator();
    try testing.expectEqualStrings("instance-ids", try policy.kebab(a, "InstanceIds"));
    try testing.expectEqualStrings("instance-ids", try policy.kebab(a, "instance_ids"));
    try testing.expectEqualStrings("instance-ids", try policy.kebab(a, "instance-ids"));
    try testing.expectEqualStrings("instance-ids", try policy.kebab(a, "instanceIds"));
    try testing.expectEqualStrings("db-instance-identifier", try policy.kebab(a, "DBInstanceIdentifier"));
    try testing.expectEqualStrings("max-results", try policy.kebab(a, "MaxResults"));
    try testing.expectEqualStrings("vpc-id", try policy.kebab(a, "VpcId"));

    const b = try h.build("ec2", "describe-instances", "{\"DBInstanceIdentifier\":\"x\",\"count\":3,\"ratio\":1.5,\"enabled\":true,\"disabled\":false,\"ids\":[\"a\",\"b\",7],\"filters\":[{\"Name\":\"k\",\"Values\":[\"v\"]}],\"opts\":{\"a\":1},\"zed\":null,\"empty\":[]}");
    try testing.expect(argvContains(b, "--db-instance-identifier=x"));
    try testing.expect(argvContains(b, "--count=3"));
    try testing.expect(argvContains(b, "--ratio=1.5"));
    try testing.expect(argvContains(b, "--enabled"));
    try testing.expect(argvContains(b, "--no-disabled"));
    try testing.expect(argvContains(b, "--ids"));
    try testing.expect(argvContains(b, "--filters=[{\"Name\":\"k\",\"Values\":[\"v\"]}]"));
    try testing.expect(argvContains(b, "--opts={\"a\":1}"));
    try testing.expect(argvContains(b, "--empty=[]"));
    try testing.expect(!argvContains(b, "--zed"));
    // duplicates after normalisation
    try expectErr(try h.build("ec2", "describe-instances", "{\"vpc_id\":\"a\",\"vpc-id\":\"b\"}"), "duplicate");
    try expectErr(try h.build("ec2", "describe-instances", "{\"VpcId\":\"a\",\"vpc-id\":\"b\"}"), "duplicate");
}

test "query, region and max_items validation" {
    var h = Harness.init();
    defer h.deinit();
    const long = "a" ** 1025;
    const mk = struct {
        fn f(hh: *Harness, q: ?[]const u8, r: ?[]const u8, m: ?i64) !policy.Built {
            return hh.buildReq(.{ .service = "ec2", .operation = "describe-vpcs", .query = q, .region = r, .max_items = m });
        }
    }.f;
    try testing.expect(argvContains(try mk(&h, "Vpcs[?State=='available'].{Id:VpcId}|[0]", null, null), "--query=Vpcs[?State=='available'].{Id:VpcId}|[0]"));
    try testing.expect(argvContains(try mk(&h, "Vpcs[?Tag==`x`]", null, null), "--query=Vpcs[?Tag==`x`]"));
    try testing.expect(argvContains(try mk(&h, "--endpoint-url=x", null, null), "--query=--endpoint-url=x")); // '=' glued: inert
    try expectErr(try mk(&h, "", null, null), "query");
    try expectErr(try mk(&h, long, null, null), "too long");
    try expectErr(try mk(&h, "a\nb", null, null), "printable");
    try expectErr(try mk(&h, "a\x00b", null, null), "printable");
    try expectErr(try mk(&h, "caf\u{e9}", null, null), "printable");
    for ([_][]const u8{ "us-east-1", "eu-west-2", "ap-southeast-1", "us-gov-west-1", "cn-north-1", "me-central-1" }) |r|
        try testing.expect(argvContains(try mk(&h, null, r, null), try std.fmt.allocPrint(h.arena.allocator(), "--region={s}", .{r})));
    for ([_][]const u8{ "US-EAST-1", "us east 1", "-us-east-1", "us-east-1;", "useast1", "us-east-1\n", "", "x", "us--east-", "http://x" }) |r| {
        switch (try mk(&h, null, r, null)) {
            .ok => {
                // "us--east-" ends with '-', "useast1" has no dash, etc.
                std.debug.print("region '{s}' accepted\n", .{r});
                return error.TestExpectedError;
            },
            .err => {},
        }
    }
    try testing.expect(argvContains(try mk(&h, null, null, 25), "--max-items=25"));
    try testing.expect(!argvContains(try mk(&h, null, null, 25), "--no-paginate"));
    try testing.expect(argvContains(try mk(&h, null, null, null), "--no-paginate"));
    try expectErr(try mk(&h, null, null, 0), "max_items");
    try expectErr(try mk(&h, null, null, -3), "max_items");
    try expectErr(try mk(&h, null, null, 10001), "max_items");
}

test "argv shape: argv[0] is aws, service/op verbatim, timeouts and pager flags present" {
    var h = Harness.init();
    defer h.deinit();
    h.cfg.connect_timeout = 5;
    h.cfg.read_timeout = 30;
    switch (try h.build("iam", "list-users", null)) {
        .ok => |p| {
            try testing.expectEqualStrings("aws", p.argv[0]);
            try testing.expectEqualStrings("iam", p.argv[1]);
            try testing.expectEqualStrings("list-users", p.argv[2]);
            try testing.expect(argvContains(.{ .ok = p }, "--cli-connect-timeout=5"));
            try testing.expect(argvContains(.{ .ok = p }, "--cli-read-timeout=30"));
            try testing.expect(argvContains(.{ .ok = p }, "--no-cli-pager"));
            try testing.expect(argvContains(.{ .ok = p }, "--output=json"));
            try testing.expectEqual(Class.read, p.class);
        },
        .err => return error.TestUnexpectedResult,
    }
}

test "s3 local paths are confined to the download dir" {
    var h = Harness.init();
    defer h.deinit();
    h.cfg.allow_write = true;
    h.cfg.allow_destructive = true;
    // no dir configured: local paths refused
    try expectErr(try h.buildReq(.{ .service = "s3", .operation = "cp", .args = &.{ "s3://b/k", "out.txt" } }), "ZMCP_AWS_DOWNLOAD_DIR");
    h.cfg.download_dir = "/srv/dl";
    switch (try h.buildReq(.{ .service = "s3", .operation = "cp", .args = &.{ "s3://b/k", "sub/out.txt" } })) {
        .ok => |p| try testing.expectEqualStrings("/srv/dl/sub/out.txt", p.argv[4]),
        .err => |m| {
            std.debug.print("{s}\n", .{m});
            return error.TestUnexpectedResult;
        },
    }
    for ([_][]const u8{ "../x", "a/../../x", "/etc/passwd", "~/x", "C:\\x", "a\\b", "x:y" }) |p| {
        try expectErr(try h.buildReq(.{ .service = "s3", .operation = "cp", .args = &.{ "s3://b/k", p } }), "relative");
    }
    // stdin/stdout marker is a dash-leading positional
    try expectErr(try h.buildReq(.{ .service = "s3", .operation = "cp", .args = &.{ "-", "s3://b/k" } }), "must not start with '-'");
    // rm/rb accept only s3:// URIs
    try expectErr(try h.buildReq(.{ .service = "s3", .operation = "rm", .args = &.{"local"}, .confirm = true }), "s3:// URIs");
    switch (try h.buildReq(.{ .service = "s3", .operation = "rm", .args = &.{"s3://b/k"}, .confirm = true })) {
        .ok => |p| try testing.expectEqual(Class.destructive, p.class),
        .err => return error.TestUnexpectedResult,
    }
}

test "gate matrix" {
    const a = testing.allocator;
    const Row = struct { w: bool, d: bool, class: Class, confirm: bool, ok: bool };
    const rows = [_]Row{
        .{ .w = false, .d = false, .class = .read, .confirm = false, .ok = true },
        .{ .w = true, .d = true, .class = .read, .confirm = false, .ok = true },
        .{ .w = false, .d = false, .class = .write, .confirm = true, .ok = false },
        .{ .w = false, .d = true, .class = .write, .confirm = true, .ok = false },
        .{ .w = true, .d = false, .class = .write, .confirm = false, .ok = true },
        .{ .w = true, .d = true, .class = .write, .confirm = false, .ok = true },
        .{ .w = false, .d = false, .class = .destructive, .confirm = true, .ok = false },
        .{ .w = true, .d = false, .class = .destructive, .confirm = true, .ok = false },
        .{ .w = false, .d = true, .class = .destructive, .confirm = true, .ok = false },
        .{ .w = true, .d = true, .class = .destructive, .confirm = false, .ok = false },
        .{ .w = true, .d = true, .class = .destructive, .confirm = true, .ok = true },
    };
    for (rows) |r| {
        const cfg: policy.Config = .{ .allow_write = r.w, .allow_destructive = r.d };
        const m = try policy.gate(a, &cfg, r.class, r.confirm, "svc", "op");
        defer if (m) |x| a.free(x);
        try testing.expectEqual(r.ok, m == null);
    }
}

test "defaults refuse writes end-to-end via build (read-only server)" {
    var h = Harness.init();
    defer h.deinit();
    const writes = [_][2][]const u8{
        .{ "ec2", "run-instances" },     .{ "s3api", "put-object" },   .{ "iam", "create-role" },
        .{ "ec2", "terminate-instances" }, .{ "s3api", "delete-bucket" }, .{ "lambda", "invoke" },
        .{ "ssm", "send-command" },       .{ "sns", "publish" },        .{ "unknown", "frobnicate" },
    };
    for (writes) |w| try expectErr(try h.build(w[0], w[1], null), "refused");
    const reads = [_][2][]const u8{
        .{ "ec2", "describe-instances" }, .{ "iam", "list-roles" }, .{ "s3api", "head-bucket" }, .{ "sts", "get-caller-identity" },
    };
    for (reads) |r| switch (try h.build(r[0], r[1], null)) {
        .ok => {},
        .err => return error.TestUnexpectedResult,
    };
}
