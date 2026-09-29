//! Pure safety policy for zmcp-aws: name validation, the allow/deny/gating
//! classifier, flag conversion and argv construction. No I/O, no process spawn.
//!
//! Model (allowlist, not blocklist):
//!   1. service/operation must be plain lowercase [a-z0-9-] tokens.
//!   2. hard DENY table (secret-returning / credential-minting / config ops)
//!      wins over everything, even with every write flag set.
//!   3. read = operation name starts with describe-/list-/get-/batch-get-/
//!      head-/lookup-/search- or is in a small explicit exceptions table.
//!   4. anything else is a WRITE (fail closed), gated by env flags; a subset
//!      of verbs (and every mutating iam call) is DESTRUCTIVE and needs a
//!      second env flag plus confirm=true.

const std = @import("std");

pub const Class = enum { read, write, destructive };

pub const Config = struct {
    allow_write: bool = false,
    allow_destructive: bool = false,
    /// Values accepted for a `profile` param (ZMCP_AWS_ALLOW_PROFILES).
    profiles: []const []const u8 = &.{},
    /// Absolute dir that confines get-object downloads and local s3 paths.
    download_dir: ?[]const u8 = null,
    max_download: u64 = 10 * 1024 * 1024,
    connect_timeout: u32 = 10,
    read_timeout: u32 = 60,
};

pub const Decision = union(enum) { allow: Class, deny: []const u8 };

// ---------------------------------------------------------------------------
// Name validation
// ---------------------------------------------------------------------------

/// Returns an error message, or null when `s` is a plain lowercase CLI token.
pub fn checkName(what: []const u8, s: []const u8, buf: []u8) ?[]const u8 {
    if (s.len == 0) return fmt(buf, "{s} is required", .{what});
    if (s.len > 64) return fmt(buf, "{s} too long", .{what});
    for (s, 0..) |c, i| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or (c == '-' and i > 0);
        if (ok) continue;
        if (c >= 'A' and c <= 'Z') return fmt(buf, "{s} must be lowercase (e.g. describe-instances)", .{what});
        return fmt(buf, "{s} may only contain a-z, 0-9 and '-' (no spaces, leading '-', or other characters)", .{what});
    }
    return null;
}

fn fmt(buf: []u8, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, f, args) catch "invalid input";
}

// ---------------------------------------------------------------------------
// Classification tables
// ---------------------------------------------------------------------------

const read_prefixes = [_][]const u8{ "describe-", "list-", "get-", "batch-get-", "head-", "lookup-", "search-" };

/// Whole services that are never callable.
const denied_services = [_]struct { name: []const u8, why: []const u8 }{
    .{ .name = "configure", .why = "'aws configure' edits credentials/config" },
    .{ .name = "login", .why = "'aws login' starts an interactive credential flow" },
    .{ .name = "logout", .why = "'aws logout' changes stored credentials" },
    .{ .name = "sso", .why = "'aws sso' mints/stores credentials" },
    .{ .name = "sso-oidc", .why = "sso-oidc mints tokens" },
    .{ .name = "history", .why = "'aws history' replays local command history" },
    .{ .name = "help", .why = "help opens a pager" },
    .{ .name = "cli", .why = "not an AWS service" },
};

/// Only these sts calls are allowed; everything else on sts mints credentials.
const sts_allowed = [_][]const u8{ "get-caller-identity", "decode-authorization-message", "get-access-key-info" };

const DenyRule = struct { svc: []const u8, op: []const u8, why: []const u8 };
/// `op` may end in `*` (prefix glob); `svc` may be "*".
const deny_rules = [_]DenyRule{
    .{ .svc = "secretsmanager", .op = "get-secret-value", .why = "returns secret values" },
    .{ .svc = "secretsmanager", .op = "batch-get-secret-value", .why = "returns secret values" },
    .{ .svc = "kms", .op = "decrypt", .why = "returns decrypted plaintext" },
    .{ .svc = "kms", .op = "generate-*", .why = "returns key material/plaintext" },
    .{ .svc = "kms", .op = "re-encrypt", .why = "handles plaintext key material" },
    .{ .svc = "iam", .op = "create-access-key", .why = "returns a secret access key" },
    .{ .svc = "iam", .op = "get-credential-report", .why = "returns a credential report (all users' credential metadata)" },
    .{ .svc = "iam", .op = "create-login-profile", .why = "sets a console password" },
    .{ .svc = "iam", .op = "update-login-profile", .why = "sets a console password" },
    .{ .svc = "iam", .op = "create-service-specific-credential", .why = "returns a service password" },
    .{ .svc = "iam", .op = "reset-service-specific-credential", .why = "returns a service password" },
    .{ .svc = "ecr", .op = "get-login-password", .why = "returns a registry password" },
    .{ .svc = "ecr", .op = "get-authorization-token", .why = "returns a registry token" },
    .{ .svc = "ecr-public", .op = "get-*", .why = "returns registry tokens" },
    .{ .svc = "codeartifact", .op = "get-authorization-token", .why = "returns a bearer token" },
    .{ .svc = "eks", .op = "get-token", .why = "returns a cluster bearer token" },
    .{ .svc = "ec2", .op = "get-password-data", .why = "returns instance password data" },
    .{ .svc = "rds", .op = "generate-db-auth-token", .why = "returns a database auth token" },
    .{ .svc = "redshift", .op = "get-cluster-credentials*", .why = "returns database credentials" },
    .{ .svc = "redshift-serverless", .op = "get-credentials", .why = "returns database credentials" },
    .{ .svc = "cognito-identity", .op = "get-credentials-for-identity", .why = "returns AWS credentials" },
    .{ .svc = "cognito-identity", .op = "get-open-id-token*", .why = "returns identity tokens" },
    .{ .svc = "lakeformation", .op = "get-temporary-*", .why = "returns temporary credentials" },
    .{ .svc = "lightsail", .op = "get-instance-access-details", .why = "returns SSH credentials" },
    .{ .svc = "lightsail", .op = "get-key-pair*", .why = "may return key material" },
    .{ .svc = "logs", .op = "start-live-tail", .why = "streams indefinitely" },
    .{ .svc = "*", .op = "presign", .why = "presigned URLs are bearer credentials" },
    .{ .svc = "*", .op = "generate-cli-skeleton", .why = "not a service call" },
};

/// Read-prefixed (get-/batch-get-/head-/lookup-/search-) ops whose names look
/// secret-bearing are denied unless listed as an exception.
const secretish_needles = [_][]const u8{ "credentials", "password", "-token", "secret-value", "authorization" };
const secretish_exceptions = [_][]const u8{ "get-random-password", "get-account-password-policy" };

const ReadException = struct { svc: []const u8, op: []const u8 };
const read_exceptions = [_]ReadException{
    .{ .svc = "dynamodb", .op = "query" },
    .{ .svc = "dynamodb", .op = "scan" },
    .{ .svc = "logs", .op = "tail" },
    .{ .svc = "logs", .op = "filter-log-events" },
    .{ .svc = "iam", .op = "simulate-principal-policy" },
    .{ .svc = "iam", .op = "simulate-custom-policy" },
    .{ .svc = "cloudformation", .op = "validate-template" },
    .{ .svc = "cloudformation", .op = "estimate-template-cost" },
    .{ .svc = "route53", .op = "test-dns-answer" },
};

const destructive_prefixes = [_][]const u8{
    "delete-",      "terminate-",    "remove-",     "deregister-", "detach-", "revoke-",
    "disable-",     "stop-",         "reboot-",     "purge-",      "cancel-", "disassociate-",
    "release-",     "reset-",        "deactivate-", "execute-",    "empty-",  "schedule-key-deletion",
    "send-command", "start-session", "invoke",
};

/// s3 high-level commands. Returns null for unknown subcommands.
fn s3Class(op: []const u8) ?Decision {
    const eq = std.mem.eql;
    if (eq(u8, op, "ls")) return .{ .allow = .read };
    if (eq(u8, op, "cp") or eq(u8, op, "mb") or eq(u8, op, "website")) return .{ .allow = .write };
    // mv deletes its source, sync may --delete, rm/rb delete outright.
    if (eq(u8, op, "mv") or eq(u8, op, "rm") or eq(u8, op, "rb") or eq(u8, op, "sync")) return .{ .allow = .destructive };
    if (eq(u8, op, "presign")) return .{ .deny = "s3 presign creates bearer-credential URLs" };
    return null;
}

fn globMatch(pat: []const u8, s: []const u8) bool {
    if (pat.len > 0 and pat[pat.len - 1] == '*') return std.mem.startsWith(u8, s, pat[0 .. pat.len - 1]);
    return std.mem.eql(u8, pat, s);
}

fn hasPrefixIn(list: []const []const u8, s: []const u8) bool {
    for (list) |p| if (std.mem.startsWith(u8, s, p)) return true;
    return false;
}

/// Classify a (service, operation) pair. Both must already pass checkName.
pub fn classify(service: []const u8, op: []const u8) Decision {
    const eq = std.mem.eql;
    for (denied_services) |d| {
        if (eq(u8, d.name, service)) return .{ .deny = d.why };
    }
    if (eq(u8, service, "sts")) {
        for (sts_allowed) |a| if (eq(u8, a, op)) return .{ .allow = .read };
        return .{ .deny = "sts is limited to get-caller-identity/decode-authorization-message/get-access-key-info (others mint credentials)" };
    }
    for (deny_rules) |r| {
        if ((eq(u8, r.svc, "*") or eq(u8, r.svc, service)) and globMatch(r.op, op)) return .{ .deny = r.why };
    }
    if (eq(u8, service, "s3")) return s3Class(op) orelse .{ .allow = .write };

    if (hasPrefixIn(&read_prefixes, op)) {
        var exempt = false;
        for (secretish_exceptions) |e| {
            if (eq(u8, e, op)) exempt = true;
        }
        const listing = std.mem.startsWith(u8, op, "list-") or std.mem.startsWith(u8, op, "describe-");
        if (!exempt and !listing) {
            for (secretish_needles) |n| {
                if (std.mem.indexOf(u8, op, n) != null)
                    return .{ .deny = "name suggests it returns credentials/tokens/passwords" };
            }
        }
        return .{ .allow = .read };
    }
    for (read_exceptions) |e| if (eq(u8, e.svc, service) and eq(u8, e.op, op)) return .{ .allow = .read };

    // Not a read: a write. Destructive verbs (and any iam mutation) escalate.
    if (eq(u8, service, "iam")) return .{ .allow = .destructive };
    if (hasPrefixIn(&destructive_prefixes, op)) return .{ .allow = .destructive };
    if (std.mem.startsWith(u8, op, "put-") and std.mem.indexOf(u8, op, "policy") != null) return .{ .allow = .destructive };
    return .{ .allow = .write };
}

/// Env-flag gate. Returns a refusal message (allocated) or null when allowed.
pub fn gate(alloc: std.mem.Allocator, cfg: *const Config, class: Class, confirm: bool, service: []const u8, op: []const u8) !?[]const u8 {
    switch (class) {
        .read => return null,
        .write => {
            if (cfg.allow_write) return null;
            return try std.fmt.allocPrint(alloc, "refused: 'aws {s} {s}' is not a read operation and this server is read-only. Start zmcp-aws with ZMCP_AWS_ALLOW_WRITE=1 to allow writes.", .{ service, op });
        },
        .destructive => {
            if (!cfg.allow_write or !cfg.allow_destructive) {
                return try std.fmt.allocPrint(alloc, "refused: 'aws {s} {s}' is destructive. Requires server env ZMCP_AWS_ALLOW_WRITE=1 and ZMCP_AWS_ALLOW_DESTRUCTIVE=1, plus confirm=true.", .{ service, op });
            }
            if (!confirm) return try std.fmt.allocPrint(alloc, "refused: 'aws {s} {s}' is destructive; pass confirm=true to proceed.", .{ service, op });
            return null;
        },
    }
}

// ---------------------------------------------------------------------------
// Value / flag validation
// ---------------------------------------------------------------------------

/// Flags callers may never set (also matched by any prefix, because the CLI
/// argument parser accepts unambiguous abbreviations such as `--endpoint`).
const denied_flags = [_][]const u8{
    "endpoint-url", "profile", "no-verify-ssl", "ca-bundle",    "debug",                 "v2-debug",
    "output",       "query",   "no-paginate",   "max-items",    "no-sign-request",       "color",
    "version",      "help",    "region",        "no-cli-pager", "generate-cli-skeleton",
};

/// (service, op glob, flag): secret-returning flags. Denied when a key is an
/// abbreviation of the flag, unless it is exactly the flag with a false value.
const SensitiveFlag = struct { svc: []const u8, op: []const u8, flag: []const u8 };
const sensitive_flags = [_]SensitiveFlag{
    .{ .svc = "ssm", .op = "get-parameter*", .flag = "with-decryption" },
    .{ .svc = "apigateway", .op = "get-api-key*", .flag = "include-value" },
    .{ .svc = "apigateway", .op = "get-api-key*", .flag = "include-values" },
    .{ .svc = "logs", .op = "tail", .flag = "follow" },
};

/// Flags whose VALUE is a secret being written. Params become argv entries,
/// which any local user can read via /proc/<pid>/cmdline, and `file://` values
/// are (deliberately) rejected, so these are refused rather than passed.
const secret_input_flags = [_][]const u8{
    "secret-string",        "secret-binary",     "plaintext",      "password",     "private-key",
    "secret-access-key",    "client-secret",     "shared-secret",  "auth-token",   "secret-key",
    "master-user-password", "master-password",   "admin-password", "new-password", "old-password",
    "previous-password",    "proposed-password", "user-password",
};

/// True when `name` (kebab-case) is a secret-input flag for this call. Booleans
/// are never secrets; `*-length` is metadata (get-random-password).
pub fn isSecretInputFlag(service: []const u8, op: []const u8, name: []const u8, val: std.json.Value) bool {
    if (val == .bool or val == .null) return false;
    for (secret_input_flags) |f| if (isAbbrev(name, f)) return true;
    if (std.mem.indexOf(u8, name, "password") != null and !std.mem.endsWith(u8, name, "-length")) return true;
    // ssm put-parameter --value carries the (possibly SecureString) parameter.
    if (std.mem.eql(u8, service, "ssm") and std.mem.eql(u8, op, "put-parameter") and isAbbrev(name, "value")) return true;
    return false;
}

pub fn isAbbrev(key: []const u8, full: []const u8) bool {
    return key.len >= 1 and key.len <= full.len and std.mem.startsWith(u8, full, key);
}

/// Validate one string value bound for the CLI. Returns a message or null.
pub fn checkValue(s: []const u8) ?[]const u8 {
    if (s.len > 64 * 1024) return "value too long";
    for (s) |c| {
        if (c == 0 or c == 0x7f or (c < 0x20 and c != '\n' and c != '\t' and c != '\r')) return "value contains control characters";
    }
    if (std.ascii.indexOfIgnoreCase(s, "file://") != null or std.ascii.indexOfIgnoreCase(s, "fileb://") != null)
        return "file:// and fileb:// values are not allowed (the CLI would read local files)";
    const t = std.mem.trimStart(u8, s, " \t\r\n");
    if (std.ascii.startsWithIgnoreCase(t, "http://") or std.ascii.startsWithIgnoreCase(t, "https://"))
        return "http(s):// values are not allowed (the CLI would fetch the URL)";
    if (std.mem.indexOf(u8, s, "$(") != null or std.mem.indexOfScalar(u8, s, '`') != null)
        return "shell-expansion syntax ($( or backtick) is not allowed in values";
    return null;
}

fn checkPositional(s: []const u8) ?[]const u8 {
    if (s.len == 0) return "empty positional argument";
    if (s.len > 2048) return "positional argument too long";
    if (s[0] == '-') return "positional arguments must not start with '-'";
    for (s) |c| if (c < 0x20 or c == 0x7f) return "positional argument contains control characters";
    return checkValue(s);
}

/// Convert a param key (kebab, snake or camel) to a kebab-case flag name.
pub fn kebab(alloc: std.mem.Allocator, key: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (key, 0..) |c, i| {
        if (c == '_') {
            try out.append(alloc, '-');
        } else if (c >= 'A' and c <= 'Z') {
            const prev: u8 = if (i > 0) key[i - 1] else 0;
            const next: u8 = if (i + 1 < key.len) key[i + 1] else 0;
            const prev_lower = (prev >= 'a' and prev <= 'z') or (prev >= '0' and prev <= '9');
            const prev_upper = prev >= 'A' and prev <= 'Z';
            const next_lower = next >= 'a' and next <= 'z';
            if (i > 0 and (prev_lower or (prev_upper and next_lower))) try out.append(alloc, '-');
            try out.append(alloc, c + 32);
        } else try out.append(alloc, c);
    }
    return out.toOwnedSlice(alloc);
}

fn keyOk(key: []const u8) bool {
    if (key.len == 0 or key.len > 64) return false;
    if (!std.ascii.isAlphanumeric(key[0])) return false;
    for (key) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Request -> argv
// ---------------------------------------------------------------------------

pub const Request = struct {
    service: []const u8,
    operation: []const u8,
    params: ?std.json.Value = null,
    args: []const []const u8 = &.{},
    region: ?[]const u8 = null,
    query: ?[]const u8 = null,
    max_items: ?i64 = null,
    confirm: bool = false,
};

pub const Plan = struct {
    argv: []const []const u8,
    class: Class,
    /// Appended to the tool result on success.
    note: ?[]const u8 = null,
    /// A file that must not exist yet (get-object destination).
    must_not_exist: ?[]const u8 = null,
    /// s3 high-level commands print text, not JSON.
    text_output: bool = false,
    /// True when --max-items was used (NextToken resumes with starting-token).
    used_max_items: bool = false,
};

pub const Built = union(enum) { ok: Plan, err: []const u8 };

pub const MAX_QUERY: usize = 1024;

pub fn checkQuery(q: []const u8) ?[]const u8 {
    if (q.len == 0) return "query is empty";
    if (q.len > MAX_QUERY) return "query too long (max 1024 bytes)";
    for (q) |c| if (c < 0x20 or c > 0x7e) return "query must be printable ASCII";
    return null;
}

pub fn checkRegion(r: []const u8) bool {
    if (r.len < 4 or r.len > 32) return false;
    if (r[0] < 'a' or r[0] > 'z') return false;
    var dashes: usize = 0;
    for (r) |c| {
        if (c == '-') {
            dashes += 1;
        } else if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9'))) return false;
    }
    return dashes >= 1 and r[r.len - 1] != '-';
}

const Argv = std.ArrayList([]const u8);

fn err(alloc: std.mem.Allocator, comptime f: []const u8, args: anytype) !Built {
    return .{ .err = try std.fmt.allocPrint(alloc, "error: " ++ f, args) };
}

fn isScalar(v: std.json.Value) bool {
    return switch (v) {
        .string, .integer, .float, .number_string, .bool => true,
        else => false,
    };
}

fn scalarText(alloc: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    return switch (v) {
        .string => |s| s,
        .integer => |i| try std.fmt.allocPrint(alloc, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(alloc, "{d}", .{f}),
        .number_string => |s| s,
        .bool => |b| if (b) "true" else "false",
        else => "",
    };
}

/// Recursively vet every string leaf and object key of a JSON value.
fn checkLeaves(v: std.json.Value, depth: usize) ?[]const u8 {
    if (depth > 32) return "params nested too deeply";
    switch (v) {
        .string => |s| return checkValue(s),
        .array => |a| for (a.items) |x| {
            if (checkLeaves(x, depth + 1)) |m| return m;
        },
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| {
                if (checkValue(e.key_ptr.*)) |m| return m;
                if (checkLeaves(e.value_ptr.*, depth + 1)) |m| return m;
            }
        },
        else => {},
    }
    return null;
}

fn truthy(v: std.json.Value) bool {
    return switch (v) {
        .bool => |b| b,
        .string => |s| !(std.ascii.eqlIgnoreCase(s, "false") or s.len == 0),
        .null => false,
        else => true,
    };
}

fn validRelPath(p: []const u8) bool {
    if (p.len == 0 or p.len > 1024) return false;
    if (p[0] == '/' or p[0] == '\\' or p[0] == '~' or p[0] == '-') return false;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return false;
    }
    for (p) |c| if (c == '\\' or c == ':' or c < 0x20 or c == 0x7f) return false;
    return true;
}

fn isGetObject(service: []const u8, op: []const u8) bool {
    return std.mem.eql(u8, service, "s3api") and (std.mem.eql(u8, op, "get-object") or std.mem.eql(u8, op, "get-object-torrent"));
}

fn validFileName(n: []const u8) bool {
    if (n.len == 0 or n.len > 128) return false;
    if (n[0] == '.' or n[0] == '-') return false;
    for (n) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return false;
    return true;
}

fn joinPath(alloc: std.mem.Allocator, dir: []const u8, rel: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, dir, "/")) return std.fmt.allocPrint(alloc, "{s}{s}", .{ dir, rel });
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, rel });
}

/// Validate a request against the policy and build the argv.
pub fn build(alloc: std.mem.Allocator, cfg: *const Config, req: Request) !Built {
    var nb: [160]u8 = undefined;
    if (checkName("service", req.service, &nb)) |m| return err(alloc, "{s}", .{m});
    if (checkName("operation", req.operation, &nb)) |m| return err(alloc, "{s}", .{m});
    const service = req.service;
    const op = req.operation;

    const class: Class = switch (classify(service, op)) {
        .deny => |why| return err(alloc, "blocked: 'aws {s} {s}' is never allowed here ({s}).", .{ service, op, why }),
        .allow => |c| c,
    };
    if (try gate(alloc, cfg, class, req.confirm, service, op)) |m| return .{ .err = m };

    const is_s3 = std.mem.eql(u8, service, "s3");
    var a: Argv = .empty;
    try a.appendSlice(alloc, &.{ "aws", service, op });

    var plan_note: ?[]const u8 = null;
    var must_not_exist: ?[]const u8 = null;
    const get_obj = isGetObject(service, op);

    // Positionals first, so a multi-value flag can never swallow them.
    if (get_obj) {
        const dir = cfg.download_dir orelse return err(alloc, "s3api {s} downloads are disabled: set ZMCP_AWS_DOWNLOAD_DIR to an absolute directory to enable (size-capped, confined there).", .{op});
        if (req.args.len != 1 or !validFileName(req.args[0]))
            return err(alloc, "s3api {s} needs args=[\"<file name>\"] (plain name, saved under ZMCP_AWS_DOWNLOAD_DIR)", .{op});
        const dest = try joinPath(alloc, dir, req.args[0]);
        try a.append(alloc, dest);
        must_not_exist = dest;
        plan_note = try std.fmt.allocPrint(alloc, "saved to {s} (download capped at {d} bytes via --range)", .{ dest, cfg.max_download });
    } else for (req.args) |p| {
        if (checkPositional(p)) |m| return err(alloc, "args: {s}", .{m});
        if (is_s3) {
            if (std.mem.startsWith(u8, p, "s3://")) {
                try a.append(alloc, p);
            } else if (std.mem.eql(u8, op, "cp") or std.mem.eql(u8, op, "mv") or std.mem.eql(u8, op, "sync")) {
                const dir = cfg.download_dir orelse return err(alloc, "local paths for s3 {s} need ZMCP_AWS_DOWNLOAD_DIR (local files are confined to that directory)", .{op});
                if (!validRelPath(p)) return err(alloc, "local path must be relative to ZMCP_AWS_DOWNLOAD_DIR without '..' (got '{s}')", .{p});
                try a.append(alloc, try joinPath(alloc, dir, p));
            } else return err(alloc, "s3 {s} arguments must be s3:// URIs", .{op});
        } else try a.append(alloc, p);
    }

    // Standard flags.
    if (!is_s3) try a.append(alloc, "--output=json");
    try a.append(alloc, "--no-cli-pager");
    try a.append(alloc, try std.fmt.allocPrint(alloc, "--cli-connect-timeout={d}", .{cfg.connect_timeout}));
    try a.append(alloc, try std.fmt.allocPrint(alloc, "--cli-read-timeout={d}", .{cfg.read_timeout}));
    var used_max = false;
    if (!is_s3) {
        if (req.max_items) |n| {
            if (n < 1 or n > 10000) return err(alloc, "max_items must be 1..10000", .{});
            try a.append(alloc, try std.fmt.allocPrint(alloc, "--max-items={d}", .{n}));
            used_max = true;
        } else try a.append(alloc, "--no-paginate");
    }
    if (req.region) |r| {
        if (!checkRegion(r)) return err(alloc, "invalid region '{s}'", .{r});
        try a.append(alloc, try std.fmt.allocPrint(alloc, "--region={s}", .{r}));
    }
    if (req.query) |q| {
        if (checkQuery(q)) |m| return err(alloc, "query: {s}", .{m});
        try a.append(alloc, try std.fmt.allocPrint(alloc, "--query={s}", .{q}));
    }
    if (get_obj) try a.append(alloc, try std.fmt.allocPrint(alloc, "--range=bytes=0-{d}", .{cfg.max_download - 1}));

    // Caller params -> flags.
    if (req.params) |pv| {
        if (pv == .null) {
            // treated as no params
        } else if (pv != .object) return err(alloc, "params must be an object", .{}) else {
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            var it = pv.object.iterator();
            while (it.next()) |e| {
                const raw = e.key_ptr.*;
                const val = e.value_ptr.*;
                if (!keyOk(raw)) return err(alloc, "invalid param name '{s}' (use letters, digits, '-' or '_')", .{raw});
                const name = try kebab(alloc, raw);
                if ((try seen.fetchPut(alloc, name, {})) != null) return err(alloc, "duplicate param '{s}'", .{name});

                if (std.mem.eql(u8, name, "profile")) {
                    // Only an exact, allowlisted profile.
                    if (val != .string) return err(alloc, "profile must be a string", .{});
                    var ok = false;
                    for (cfg.profiles) |p| {
                        if (std.mem.eql(u8, p, val.string)) ok = true;
                    }
                    if (!ok) return err(alloc, "blocked: profile '{s}' is not in ZMCP_AWS_ALLOW_PROFILES (the inherited AWS_PROFILE is used otherwise)", .{val.string});
                    try a.append(alloc, try std.fmt.allocPrint(alloc, "--profile={s}", .{val.string}));
                    continue;
                }
                for (denied_flags) |d| {
                    if (isAbbrev(name, d)) return err(alloc, "blocked: param '{s}' (--{s}) is not allowed; the server controls it", .{ raw, d });
                }
                if (std.mem.startsWith(u8, name, "cli-")) return err(alloc, "blocked: --{s} (cli-* options) are not allowed", .{name});
                if (isSecretInputFlag(service, op, name, val)) return err(alloc, "blocked: param '{s}' (--{s}) would place a secret value on the aws command line, where other local users can read it (process listing). Secret-carrying inputs are refused; set the secret outside this tool (console, or a shell with file://).", .{ raw, name });
                if (get_obj and isAbbrev(name, "range")) return err(alloc, "param 'range' is managed by the server for downloads", .{});
                for (sensitive_flags) |sf| {
                    if (!(std.mem.eql(u8, sf.svc, service) and globMatch(sf.op, op))) continue;
                    if (!isAbbrev(name, sf.flag)) continue;
                    if (std.mem.eql(u8, name, sf.flag) and !truthy(val)) continue;
                    return err(alloc, "blocked: --{s} on 'aws {s} {s}' returns secret values", .{ sf.flag, service, op });
                }

                if (checkLeaves(val, 0)) |m| return err(alloc, "param '{s}': {s}", .{ raw, m });
                switch (val) {
                    .null => {},
                    .bool => |b| try a.append(alloc, try std.fmt.allocPrint(alloc, "--{s}{s}", .{ if (b) "" else "no-", name })),
                    .string, .integer, .float, .number_string => try a.append(alloc, try std.fmt.allocPrint(alloc, "--{s}={s}", .{ name, try scalarText(alloc, val) })),
                    .array => |arr| {
                        var all_scalar = arr.items.len > 0;
                        for (arr.items) |x| {
                            if (!isScalar(x) or x == .bool) all_scalar = false;
                        }
                        if (all_scalar) {
                            try a.append(alloc, try std.fmt.allocPrint(alloc, "--{s}", .{name}));
                            for (arr.items) |x| {
                                const t = try scalarText(alloc, x);
                                if (t.len > 0 and t[0] == '-') return err(alloc, "param '{s}': list items must not start with '-'", .{raw});
                                try a.append(alloc, t);
                            }
                        } else {
                            const js = try std.json.Stringify.valueAlloc(alloc, val, .{});
                            try a.append(alloc, try std.fmt.allocPrint(alloc, "--{s}={s}", .{ name, js }));
                        }
                    },
                    .object => {
                        const js = try std.json.Stringify.valueAlloc(alloc, val, .{});
                        try a.append(alloc, try std.fmt.allocPrint(alloc, "--{s}={s}", .{ name, js }));
                    },
                }
            }
        }
    }

    return .{ .ok = .{
        .argv = try a.toOwnedSlice(alloc),
        .class = class,
        .note = plan_note,
        .must_not_exist = must_not_exist,
        .text_output = is_s3,
        .used_max_items = used_max,
    } };
}
