//! zmcp-postgres - MCP server giving agents PostgreSQL access by wrapping the
//! `psql` CLI (argv only, no shell). READ-ONLY by default.
//!
//! Tools:
//!   pg_query   {sql, params?, max_rows?}  one read-only statement, in a
//!                                          BEGIN READ ONLY ... ROLLBACK
//!   pg_schema  {schema?, table?}          schemas / tables / columns / keys / indexes
//!   pg_explain {sql, analyze?}            EXPLAIN; ANALYZE executes, so it is gated
//!   pg_exec    {sql}                      writes; refused unless ZMCP_POSTGRES_ALLOW_WRITE=1
//!
//! Environment:
//!   DATABASE_URL                       postgresql:// URI or key=value DSN; translated to PG*
//!                                      env vars for psql (never put in argv). Plain PG* vars
//!                                      (PGHOST, PGPASSWORD, PGSERVICE, ...) work too.
//!   ZMCP_POSTGRES_ALLOW_WRITE=1        enables pg_exec (and analyze on DML in pg_explain)
//!   ZMCP_POSTGRES_STATEMENT_TIMEOUT_MS statement_timeout, default 30000
//!   ZMCP_POSTGRES_PSQL                 psql binary, default "psql" (PATH)
//!
//! Read-only is enforced by the database: every read runs as its own psql
//! session with PGOPTIONS default_transaction_read_only=on and inside
//! `BEGIN READ ONLY`, exactly one statement (checked by sqllex.zig), with
//! backslash meta-commands rejected. A first-keyword allowlist additionally
//! keeps out COPY ... TO PROGRAM (which a read-only transaction does NOT
//! block) and friends. The strongest boundary is still a DB role that
//! lacks write/execute privileges; use one for anything important.

const std = @import("std");
const mcp = @import("mcp");
const lex = @import("sqllex.zig");
const conn = @import("conn.zig");

const Io = std.Io;
const Environ = std.process.Environ;

pub const write_env = "ZMCP_POSTGRES_ALLOW_WRITE";
pub const timeout_env = "ZMCP_POSTGRES_STATEMENT_TIMEOUT_MS";
pub const psql_env = "ZMCP_POSTGRES_PSQL";

pub const MAX_OUTPUT_BYTES: usize = 64 * 1024;
const MAX_CAPTURE_BYTES: usize = 8 * 1024 * 1024;
pub const DEFAULT_MAX_ROWS: usize = 100;
pub const HARD_MAX_ROWS: usize = 5000;
const CELL_MAX: usize = 500;
const DEFAULT_TIMEOUT_MS: u32 = 30_000;
/// Marks NULL in psql's CSV output (a cell equal to exactly this is NULL).
const NULL_SENTINEL = "\x01N";
/// Extra wall-clock allowance on top of statement_timeout (connect, startup).
const WALL_SLACK_MS: u32 = 20_000;

/// Process environment (set once in main, or by tests).
var g_env: ?*const Environ.Map = null;

pub fn main(init: std.process.Init) !void {
    g_env = init.environ_map;
    try mcp.run(init.gpa, init.io, .{ .name = "zmcp-postgres", .version = "0.1.0" }, &tool_table);
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "pg_query",
        .description = "Run ONE read-only statement (SELECT/WITH/VALUES/TABLE/SHOW/EXPLAIN) in a READ ONLY transaction. Bind $1.. via params. Returns header + TSV rows, NULL as \\N.",
        .input_schema_json =
        \\{"type":"object","properties":{"sql":{"type":"string"},"params":{"type":"array","description":"values for $1.."},"max_rows":{"type":"integer","description":"default 100, max 5000"}},"required":["sql"]}
        ,
        .handler = handleQuery,
        .read_only = true,
    },
    .{
        .name = "pg_schema",
        .description = "Schema discovery. No args: schemas with tables and row estimates. schema: its tables with columns. table: columns, keys, indexes.",
        .input_schema_json =
        \\{"type":"object","properties":{"schema":{"type":"string"},"table":{"type":"string"}}}
        ,
        .handler = handleSchema,
        .read_only = true,
    },
    .{
        .name = "pg_explain",
        .description = "EXPLAIN one statement (not executed). analyze=true EXECUTES it: allowed for SELECT/WITH (read-only), for DML only with ZMCP_POSTGRES_ALLOW_WRITE=1 (rolled back).",
        .input_schema_json =
        \\{"type":"object","properties":{"sql":{"type":"string"},"analyze":{"type":"boolean"}},"required":["sql"]}
        ,
        .handler = handleExplain,
    },
    .{
        .name = "pg_exec",
        .description = "Run SQL that changes data or schema (multi-statement ok). Refused unless ZMCP_POSTGRES_ALLOW_WRITE=1. Returns command tags.",
        .input_schema_json =
        \\{"type":"object","properties":{"sql":{"type":"string"}},"required":["sql"]}
        ,
        .handler = handleExec,
        .destructive = true,
    },
};

// ---------------------------------------------------------------------------
// Config (read from the stored environment on every call)
// ---------------------------------------------------------------------------

fn envGet(key: []const u8) ?[]const u8 {
    const m = g_env orelse return null;
    return m.get(key);
}

fn writeEnabled() bool {
    const v = envGet(write_env) orelse return false;
    return std.mem.eql(u8, v, "1");
}

fn timeoutMs() u32 {
    const v = envGet(timeout_env) orelse return DEFAULT_TIMEOUT_MS;
    const n = std.fmt.parseInt(u32, std.mem.trim(u8, v, " \t"), 10) catch return DEFAULT_TIMEOUT_MS;
    return if (n == 0) DEFAULT_TIMEOUT_MS else @min(n, 3_600_000);
}

fn psqlBin() []const u8 {
    const v = envGet(psql_env) orelse return "psql";
    return if (v.len == 0) "psql" else v;
}

// ---------------------------------------------------------------------------
// Process-execution seam (injectable for offline unit tests)
// ---------------------------------------------------------------------------

pub const ExecResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    /// Capture stopped early because MAX_CAPTURE_BYTES was hit.
    truncated: bool = false,
    /// The wall-clock deadline passed and the child was killed.
    timed_out: bool = false,
};

pub const ExecFn = *const fn (
    alloc: std.mem.Allocator,
    io: Io,
    argv: []const []const u8,
    env: *const Environ.Map,
    wall_ms: u32,
) anyerror!ExecResult;

var exec_fn: ExecFn = execReal;

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

fn errResult(text: []const u8) mcp.ToolResult {
    return .{ .text = text, .is_error = true };
}

fn errFmt(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !mcp.ToolResult {
    return errResult(try std.fmt.allocPrint(alloc, fmt, args));
}

fn getStr(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn getBool(args: std.json.Value, key: []const u8) bool {
    if (args != .object) return false;
    const v = args.object.get(key) orelse return false;
    return v == .bool and v.bool;
}

fn getInt(args: std.json.Value, key: []const u8) ?i64 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f) and @abs(f) < 1e15) @as(i64, @intFromFloat(f)) else null,
        else => null,
    };
}

fn clampRows(raw: ?i64) usize {
    const v = raw orelse return DEFAULT_MAX_ROWS;
    if (v < 1) return DEFAULT_MAX_ROWS;
    return @min(@as(usize, @intCast(v)), HARD_MAX_ROWS);
}

fn scanMsg(e: lex.ScanError) []const u8 {
    return switch (e) {
        error.Empty => "error: sql is empty",
        error.MultipleStatements => "error: exactly one statement per call (a second statement follows a ';'); split it into separate calls",
        error.MetaCommand => "error: psql meta-commands (a backslash outside quotes) are not allowed",
        error.Unterminated => "error: unterminated quote, comment or dollar-quote in sql",
        error.NulByte => "error: sql contains a NUL byte",
    };
}

/// `'...'` with quotes doubled. Safe because every session runs with
/// standard_conforming_strings=on (set in PGOPTIONS), so backslash is literal.
pub fn quoteLiteral(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(alloc, '\'');
    for (s) |c| {
        if (c == '\'') try out.append(alloc, '\'');
        try out.append(alloc, c);
    }
    try out.append(alloc, '\'');
    return out.toOwnedSlice(alloc);
}

fn isPlainIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!(std.ascii.isLower(s[0]) or s[0] == '_')) return false;
    for (s) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) return false;
    return true;
}

pub fn quoteIdent(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (isPlainIdent(s)) return s;
    var out: std.ArrayList(u8) = .empty;
    try out.append(alloc, '"');
    for (s) |c| {
        if (c == '"') try out.append(alloc, '"');
        try out.append(alloc, c);
    }
    try out.append(alloc, '"');
    return out.toOwnedSlice(alloc);
}

/// Cut at a UTF-8 boundary.
fn utf8Cut(s: []const u8, max: usize) usize {
    if (s.len <= max) return s.len;
    var cut = max;
    while (cut > 0 and (s[cut] & 0xC0) == 0x80) cut -= 1;
    return cut;
}

// ---------------------------------------------------------------------------
// CSV parsing (psql --csv) and result formatting
// ---------------------------------------------------------------------------

pub const Row = []const ?[]const u8;

/// Parse psql --csv output. A cell equal to NULL_SENTINEL is null. A blank
/// line is a row with one empty cell (single-column empty string).
pub fn parseCsv(alloc: std.mem.Allocator, text: []const u8) ![]const Row {
    var rows: std.ArrayList(Row) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        var cells: std.ArrayList(?[]const u8) = .empty;
        while (true) {
            if (i < text.len and text[i] == '"') {
                var buf: std.ArrayList(u8) = .empty;
                i += 1;
                while (i < text.len) {
                    if (text[i] == '"') {
                        if (i + 1 < text.len and text[i + 1] == '"') {
                            try buf.append(alloc, '"');
                            i += 2;
                            continue;
                        }
                        i += 1;
                        break;
                    }
                    try buf.append(alloc, text[i]);
                    i += 1;
                }
                try cells.append(alloc, try buf.toOwnedSlice(alloc));
            } else {
                const s = i;
                while (i < text.len and text[i] != ',' and text[i] != '\n') i += 1;
                const f = text[s..i];
                try cells.append(alloc, if (std.mem.eql(u8, f, NULL_SENTINEL)) null else f);
            }
            if (i >= text.len) break;
            if (text[i] == ',') {
                i += 1;
                continue;
            }
            if (text[i] == '\n') {
                i += 1;
                break;
            }
            // junk after a closing quote: resync at the next delimiter
            while (i < text.len and text[i] != ',' and text[i] != '\n') i += 1;
            if (i < text.len) {
                const d = text[i];
                i += 1;
                if (d == '\n') break;
            } else break;
        }
        try rows.append(alloc, try cells.toOwnedSlice(alloc));
    }
    return rows.toOwnedSlice(alloc);
}

/// COPY-text style: \N for NULL, backslash escapes for \\ \t \n \r; long
/// cells cut with a marker.
fn appendCell(alloc: std.mem.Allocator, out: *std.ArrayList(u8), cell: ?[]const u8, cap_cell: bool) !void {
    const raw = cell orelse {
        try out.appendSlice(alloc, "\\N");
        return;
    };
    var s = raw;
    var extra: usize = 0;
    if (cap_cell and s.len > CELL_MAX) {
        const cut = utf8Cut(s, CELL_MAX);
        extra = s.len - cut;
        s = s[0..cut];
    }
    for (s) |c| switch (c) {
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        else => try out.append(alloc, c),
    };
    if (extra > 0) try out.print(alloc, "...[+{d} bytes]", .{extra});
}

fn appendRow(alloc: std.mem.Allocator, out: *std.ArrayList(u8), row: Row, cap_cell: bool) !void {
    for (row, 0..) |c, i| {
        if (i > 0) try out.append(alloc, '\t');
        try appendCell(alloc, out, c, cap_cell);
    }
    try out.append(alloc, '\n');
}

/// Header + up to `max_rows` rows (capped at MAX_OUTPUT_BYTES) + a footer that
/// says what was cut and how to narrow.
pub fn formatTable(alloc: std.mem.Allocator, rows: []const Row, max_rows: usize, capture_truncated: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (rows.len == 0) return "(no result set)";
    try appendRow(alloc, &out, rows[0], false);
    const data = rows[1..];
    var shown: usize = 0;
    var byte_cut = false;
    for (data) |r| {
        if (shown >= max_rows) break;
        const before = out.items.len;
        try appendRow(alloc, &out, r, true);
        if (out.items.len > MAX_OUTPUT_BYTES and shown > 0) {
            out.shrinkRetainingCapacity(before);
            byte_cut = true;
            break;
        }
        shown += 1;
    }
    if (byte_cut) {
        try out.print(alloc, "({d} rows shown; 64 KiB output cap reached - select fewer columns/rows or add LIMIT)", .{shown});
    } else if (data.len > shown or capture_truncated) {
        try out.print(alloc, "({d} rows shown; more exist - add WHERE/LIMIT or raise max_rows, max {d})", .{ shown, HARD_MAX_ROWS });
    } else {
        try out.print(alloc, "({d} row{s})", .{ shown, if (shown == 1) "" else "s" });
    }
    return out.toOwnedSlice(alloc);
}

/// One-column result -> lines joined by \n, capped.
fn formatLines(alloc: std.mem.Allocator, rows: []const Row, capture_truncated: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (rows.len <= 1) return "";
    var cut = false;
    for (rows[1..]) |r| {
        const cell: []const u8 = if (r.len > 0) (r[0] orelse "") else "";
        if (out.items.len + cell.len + 1 > MAX_OUTPUT_BYTES and out.items.len > 0) {
            cut = true;
            break;
        }
        try out.appendSlice(alloc, cell);
        try out.append(alloc, '\n');
    }
    if (cut or capture_truncated) try out.appendSlice(alloc, "[output truncated at 64 KiB - narrow the request (e.g. pass schema=)]\n");
    if (out.items.len > 0 and out.items[out.items.len - 1] == '\n') _ = out.pop();
    return out.toOwnedSlice(alloc);
}

/// Generic raw-output cap (pg_exec).
fn capText(alloc: std.mem.Allocator, data: []const u8, force_note: bool) ![]const u8 {
    if (data.len <= MAX_OUTPUT_BYTES and !force_note) return data;
    const cut = utf8Cut(data, MAX_OUTPUT_BYTES);
    return std.fmt.allocPrint(alloc, "{s}\n[output truncated: showing first {d} of {d}+ bytes; narrow the statement (RETURNING fewer columns/rows)]", .{ data[0..cut], cut, data.len });
}

// ---------------------------------------------------------------------------
// psql invocation
// ---------------------------------------------------------------------------

pub const Fmt = enum { csv, raw };

/// argv for psql. Every statement is its own `-c`, so psql sends each to the
/// server verbatim (no backslash processing, no variable interpolation) and
/// they share one session, hence one transaction when we BEGIN. `-w` never
/// prompts for a password; `-X` skips ~/.psqlrc; ON_ERROR_STOP aborts at the
/// first error (closing the session, which rolls back).
pub fn buildArgv(alloc: std.mem.Allocator, psql: []const u8, stmts: []const []const u8, fmt: Fmt) ![]const []const u8 {
    var a: std.ArrayList([]const u8) = .empty;
    try a.append(alloc, psql);
    try a.append(alloc, "-X");
    if (fmt == .csv) try a.append(alloc, "-q");
    try a.appendSlice(alloc, &.{ "-w", "-v", "ON_ERROR_STOP=1", "--csv", "--pset=pager=off" });
    if (fmt == .csv) try a.append(alloc, "--pset=null=" ++ NULL_SENTINEL);
    for (stmts) |s| {
        try a.append(alloc, "-c");
        try a.append(alloc, s);
    }
    return a.toOwnedSlice(alloc);
}

pub const Outcome = union(enum) {
    ok: struct { stdout: []const u8, truncated: bool },
    err: []const u8,
};

/// Build the child environment: our environment minus DATABASE_URL, plus the
/// PG* variables derived from it, plus PGOPTIONS with the safety settings.
pub fn buildChildEnv(alloc: std.mem.Allocator, base: ?*const Environ.Map, dsn: ?[]const u8, rw: bool, timeout_ms: u32, secrets: *std.ArrayList([]const u8)) !union(enum) { ok: Environ.Map, err: []const u8 } {
    var env: Environ.Map = if (base) |b| try b.clone(alloc) else Environ.Map.init(alloc);
    _ = env.swapRemove("DATABASE_URL");
    var user_opts: ?[]const u8 = env.get("PGOPTIONS");
    if (env.get("PGPASSWORD")) |p| try secrets.append(alloc, try alloc.dupe(u8, p));
    if (dsn) |d| {
        switch (try conn.parseDsn(alloc, d)) {
            .err => |m| return .{ .err = m },
            .ok => |p| {
                for (p.pairs) |kv| try env.put(kv.key, kv.value);
                if (p.options) |o| {
                    user_opts = if (user_opts) |u| try std.fmt.allocPrint(alloc, "{s} {s}", .{ u, o }) else o;
                }
                if (p.password) |pw| try secrets.append(alloc, pw);
            },
        }
    }
    try env.put("PGOPTIONS", try conn.buildPgOptions(alloc, user_opts, !rw, timeout_ms));
    if (env.get("PGCONNECT_TIMEOUT") == null) try env.put("PGCONNECT_TIMEOUT", "10");
    return .{ .ok = env };
}

fn runPsql(alloc: std.mem.Allocator, io: Io, rw: bool, stmts: []const []const u8, fmt: Fmt) !Outcome {
    const tmo = timeoutMs();
    var secrets: std.ArrayList([]const u8) = .empty;
    const built = try buildChildEnv(alloc, g_env, envGet("DATABASE_URL"), rw, tmo, &secrets);
    var env = switch (built) {
        .err => |m| return .{ .err = try std.fmt.allocPrint(alloc, "error: {s}", .{m}) },
        .ok => |e| e,
    };
    defer env.deinit();
    const argv = try buildArgv(alloc, psqlBin(), stmts, fmt);

    const res = exec_fn(alloc, io, argv, &env, tmo +| WALL_SLACK_MS) catch |err| switch (err) {
        error.ExecutableNotFound => return .{ .err = "error: 'psql' not found. Install the PostgreSQL client (psql) and put it on PATH, or set ZMCP_POSTGRES_PSQL." },
        else => return .{ .err = try std.fmt.allocPrint(alloc, "error: psql execution failed: {s}", .{@errorName(err)}) },
    };
    if (res.timed_out) {
        return .{ .err = try std.fmt.allocPrint(alloc, "error: timed out (statement_timeout {d} ms, plus connect allowance); psql was killed. Narrow the query or raise {s}.", .{ tmo, timeout_env }) };
    }
    switch (res.term) {
        .exited => |code| if (code != 0) {
            var clean = try conn.redact(alloc, std.mem.trim(u8, res.stderr, " \t\r\n"), secrets.items);
            for ([_][]const u8{ "psql: error: ", "ERROR:  " }) |pre| {
                if (std.mem.startsWith(u8, clean, pre)) clean = clean[pre.len..];
            }
            const detail = if (clean.len > 0) clean[0..utf8Cut(clean, 4096)] else "(no error output)";
            const hint: []const u8 = if (std.mem.indexOf(u8, detail, "read-only transaction") != null)
                "\nhint: this session is read-only; changes need ZMCP_POSTGRES_ALLOW_WRITE=1 and pg_exec."
            else if (code == 2)
                "\nhint: check DATABASE_URL (or PGHOST/PGUSER/PGPASSWORD/PGDATABASE)."
            else
                "";
            return .{ .err = try std.fmt.allocPrint(alloc, "error: {s}{s}", .{ detail, hint }) };
        },
        else => return .{ .err = "error: psql terminated abnormally" },
    }
    return .{ .ok = .{ .stdout = res.stdout, .truncated = res.truncated } };
}

// ---------------------------------------------------------------------------
// Statement builders (pure)
// ---------------------------------------------------------------------------

const read_kw = [_][]const u8{ "select", "with", "values", "table", "show", "explain" };
const wrappable_kw = [_][]const u8{ "select", "with", "values", "table" };
const explain_kw = [_][]const u8{ "select", "with", "values", "table", "insert", "update", "delete", "merge" };
const dml_kw = [_][]const u8{ "insert", "update", "delete", "merge" };

pub const MAX_PARAMS: usize = 64;

/// `'a', 'b', NULL` for EXECUTE. Everything but null is sent as a quoted
/// literal of unknown type, which the server coerces to the parameter's type.
pub fn paramList(alloc: std.mem.Allocator, items: []const std.json.Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (items, 0..) |v, i| {
        if (i > 0) try out.appendSlice(alloc, ", ");
        switch (v) {
            .null => try out.appendSlice(alloc, "NULL"),
            .bool => |b| try out.appendSlice(alloc, if (b) "'true'" else "'false'"),
            .integer => |n| try out.print(alloc, "'{d}'", .{n}),
            .float => |f| try out.print(alloc, "'{d}'", .{f}),
            .number_string => |s| try out.appendSlice(alloc, try quoteLiteral(alloc, s)),
            .string => |s| try out.appendSlice(alloc, try quoteLiteral(alloc, s)),
            .array, .object => {
                const js = try std.json.Stringify.valueAlloc(alloc, v, .{});
                try out.appendSlice(alloc, try quoteLiteral(alloc, js));
            },
        }
    }
    return out.toOwnedSlice(alloc);
}

/// The read-only statement sequence for pg_query. Wrapped statements are
/// limited server-side to max_rows+1 so "more rows exist" is knowable.
pub fn buildReadStmts(alloc: std.mem.Allocator, sc: lex.Scan, params: ?[]const std.json.Value, max_rows: usize) ![]const []const u8 {
    var stmts: std.ArrayList([]const u8) = .empty;
    try stmts.append(alloc, "BEGIN READ ONLY");
    const inner = if (sc.firstIn(&wrappable_kw))
        try std.fmt.allocPrint(alloc, "SELECT * FROM (\n{s}\n) AS zmcp_q LIMIT {d}", .{ sc.sql, max_rows + 1 })
    else
        sc.sql;
    if (params) |p| if (p.len > 0) {
        try stmts.append(alloc, try std.fmt.allocPrint(alloc, "PREPARE zmcp_q AS {s}", .{inner}));
        try stmts.append(alloc, try std.fmt.allocPrint(alloc, "EXECUTE zmcp_q({s})", .{try paramList(alloc, p)}));
        try stmts.append(alloc, "ROLLBACK");
        return stmts.toOwnedSlice(alloc);
    };
    try stmts.append(alloc, inner);
    try stmts.append(alloc, "ROLLBACK");
    return stmts.toOwnedSlice(alloc);
}

const rel_kind_case =
    \\CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'partitioned table' WHEN 'v' THEN 'view' WHEN 'm' THEN 'materialized view' WHEN 'f' THEN 'foreign table' WHEN 'S' THEN 'sequence' WHEN 'i' THEN 'index' ELSE c.relkind::text END
;

const overview_sql =
    \\SELECT n.nspname || ' (' || count(*) || '): ' || string_agg(c.relname ||
    \\ CASE c.relkind WHEN 'v' THEN '[v]' WHEN 'f' THEN '[f]' WHEN 'p' THEN '[p]' WHEN 'm' THEN '[m]' ELSE '' END ||
    \\ CASE WHEN c.relkind IN ('r','p','m') THEN '~' || CASE WHEN c.reltuples < 0 THEN '?' ELSE c.reltuples::bigint::text END ELSE '' END,
    \\ ' ' ORDER BY c.relname)
    \\FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    \\WHERE c.relkind IN ('r','p','v','m','f') AND NOT c.relispartition
    \\ AND n.nspname <> 'information_schema' AND n.nspname NOT LIKE 'pg\_%'
    \\GROUP BY n.nspname ORDER BY n.nspname
;

pub fn buildSchemaSql(alloc: std.mem.Allocator, schema: ?[]const u8, table: ?[]const u8) ![]const u8 {
    if (table) |t| {
        var name: []const u8 = t;
        if (schema) |s| {
            if (std.mem.indexOfScalar(u8, t, '.') == null and std.mem.indexOfScalar(u8, t, '"') == null) {
                name = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ try quoteIdent(alloc, s), try quoteIdent(alloc, t) });
            }
        }
        const lit = try quoteLiteral(alloc, name);
        return std.fmt.allocPrint(alloc,
            \\WITH r AS (SELECT to_regclass({s}) AS oid)
            \\SELECT line FROM (
            \\ SELECT 0 AS ord, 0 AS n, {s} || ' ' || n.nspname || '.' || c.relname || ' (~' || CASE WHEN c.reltuples < 0 THEN '?' ELSE c.reltuples::bigint::text END || ' rows)' AS line
            \\  FROM r JOIN pg_class c ON c.oid = r.oid JOIN pg_namespace n ON n.oid = c.relnamespace
            \\ UNION ALL
            \\ SELECT 1, a.attnum::int, '  ' || a.attname || ' ' || format_type(a.atttypid, a.atttypmod) || CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END || COALESCE(' DEFAULT ' || pg_get_expr(d.adbin, d.adrelid), '')
            \\  FROM r JOIN pg_attribute a ON a.attrelid = r.oid AND a.attnum > 0 AND NOT a.attisdropped
            \\  LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            \\ UNION ALL
            \\ SELECT 2, COALESCE(array_position(ARRAY['p','u','f','c','x','t'], con.contype::text), 9), '  CONSTRAINT ' || quote_ident(con.conname) || ' ' || pg_get_constraintdef(con.oid)
            \\  FROM r JOIN pg_constraint con ON con.conrelid = r.oid WHERE con.contype <> 'n'
            \\ UNION ALL
            \\ SELECT 3, 0, '  ' || pg_get_indexdef(i.indexrelid)
            \\  FROM r JOIN pg_index i ON i.indrelid = r.oid
            \\  WHERE NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid = r.oid AND k.conindid = i.indexrelid)
            \\ UNION ALL
            \\ SELECT 4, 0, '  referenced by ' || con.conrelid::regclass::text || ' (' || quote_ident(con.conname) || ')'
            \\  FROM r JOIN pg_constraint con ON con.confrelid = r.oid AND con.contype = 'f'
            \\) t ORDER BY ord, n, line
        , .{ lit, rel_kind_case_table });
    }
    if (schema) |s| {
        return std.fmt.allocPrint(alloc,
            \\SELECT c.relname ||
            \\ CASE c.relkind WHEN 'v' THEN ' [view]' WHEN 'f' THEN ' [foreign]' WHEN 'p' THEN ' [partitioned]' WHEN 'm' THEN ' [matview]' ELSE '' END ||
            \\ CASE WHEN c.relkind IN ('r','p','m') THEN ' ~' || CASE WHEN c.reltuples < 0 THEN '?' ELSE c.reltuples::bigint::text END ELSE '' END ||
            \\ ': ' || COALESCE(k.cols, '') || CASE WHEN k.n > 12 THEN ', +' || (k.n - 12) ELSE '' END
            \\FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            \\ CROSS JOIN LATERAL (SELECT string_agg(x.attname, ', ' ORDER BY x.attnum) FILTER (WHERE x.rn <= 12) AS cols, count(*) AS n
            \\  FROM (SELECT a.attname, a.attnum, row_number() OVER (ORDER BY a.attnum) AS rn FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped) x) k
            \\WHERE n.nspname = {s} AND c.relkind IN ('r','p','v','m','f') AND NOT c.relispartition
            \\ORDER BY c.relname
        , .{try quoteLiteral(alloc, s)});
    }
    return overview_sql;
}

/// `table` DDL-like header label: same CASE as rel_kind_case, as a SQL string.
const rel_kind_case_table = rel_kind_case;

pub fn buildExplainStmts(alloc: std.mem.Allocator, sc: lex.Scan, analyze: bool, rw: bool) ![]const []const u8 {
    const head: []const u8 = if (analyze) "EXPLAIN (ANALYZE) " else "EXPLAIN ";
    const explain = try std.fmt.allocPrint(alloc, "{s}{s}", .{ head, sc.sql });
    return alloc.dupe([]const u8, &.{ if (rw) "BEGIN" else "BEGIN READ ONLY", explain, "ROLLBACK" });
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

fn handleQuery(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const sql = getStr(args, "sql") orelse return errResult("error: sql is required");
    const sc = lex.scan(sql, false) catch |e| return errResult(scanMsg(e));
    if (!sc.firstIn(&read_kw)) {
        return errFmt(alloc, "error: pg_query runs only SELECT/WITH/VALUES/TABLE/SHOW/EXPLAIN (got '{s}'). Writes and other commands go through pg_exec when ZMCP_POSTGRES_ALLOW_WRITE=1.", .{sc.first});
    }
    var params: ?[]const std.json.Value = null;
    if (args == .object) if (args.object.get("params")) |p| switch (p) {
        .array => |arr| {
            if (arr.items.len > MAX_PARAMS) return errFmt(alloc, "error: at most {d} params", .{MAX_PARAMS});
            params = arr.items;
        },
        .null => {},
        else => return errResult("error: params must be an array"),
    };
    if (params != null and params.?.len > 0 and !sc.firstIn(&wrappable_kw)) {
        return errResult("error: params work only with SELECT/WITH/VALUES/TABLE (SHOW/EXPLAIN cannot be prepared)");
    }
    const max_rows = clampRows(getInt(args, "max_rows"));
    const stmts = try buildReadStmts(alloc, sc, params, max_rows);
    const out = try runPsql(alloc, io, false, stmts, .csv);
    switch (out) {
        .err => |m| return errResult(m),
        .ok => |o| {
            const rows = try parseCsv(alloc, o.stdout);
            return .{ .text = try formatTable(alloc, rows, max_rows, o.truncated) };
        },
    }
}

fn validName(s: []const u8) bool {
    if (s.len == 0 or s.len > 256) return false;
    for (s) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

fn handleSchema(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const schema = getStr(args, "schema");
    const table = getStr(args, "table");
    if (schema) |s| if (!validName(s)) return errResult("error: invalid schema name");
    if (table) |t| if (!validName(t)) return errResult("error: invalid table name");
    const sql = try buildSchemaSql(alloc, schema, table);
    const stmts = [_][]const u8{ "BEGIN READ ONLY", sql, "ROLLBACK" };
    const out = try runPsql(alloc, io, false, &stmts, .csv);
    switch (out) {
        .err => |m| return errResult(m),
        .ok => |o| {
            const rows = try parseCsv(alloc, o.stdout);
            const text = try formatLines(alloc, rows, o.truncated);
            if (text.len == 0) {
                if (table) |t| return errFmt(alloc, "not found: {s}{s}{s} (check the name; pass schema= to qualify)", .{ if (schema) |s| s else "", if (schema != null) "." else "", t });
                if (schema) |s| return errFmt(alloc, "no tables or views in schema '{s}' (does it exist?)", .{s});
                return .{ .text = "(no user tables)" };
            }
            return .{ .text = text };
        },
    }
}

fn handleExplain(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const sql = getStr(args, "sql") orelse return errResult("error: sql is required");
    const sc = lex.scan(sql, false) catch |e| return errResult(scanMsg(e));
    if (!sc.firstIn(&explain_kw)) {
        return errFmt(alloc, "error: pg_explain takes a SELECT/WITH/VALUES/TABLE/INSERT/UPDATE/DELETE/MERGE statement without the EXPLAIN keyword (got '{s}')", .{sc.first});
    }
    const analyze = getBool(args, "analyze");
    var rw = false;
    if (analyze and sc.firstIn(&dml_kw)) {
        if (!writeEnabled()) {
            return errResult("error: EXPLAIN ANALYZE executes the statement, so for INSERT/UPDATE/DELETE/MERGE it needs ZMCP_POSTGRES_ALLOW_WRITE=1 (it then runs in a transaction that is rolled back). Use analyze=false for the estimated plan.");
        }
        rw = true;
    }
    const stmts = try buildExplainStmts(alloc, sc, analyze, rw);
    const out = try runPsql(alloc, io, rw, stmts, .csv);
    switch (out) {
        .err => |m| return errResult(m),
        .ok => |o| {
            const rows = try parseCsv(alloc, o.stdout);
            const text = try formatLines(alloc, rows, o.truncated);
            return .{ .text = if (text.len == 0) "(no plan returned)" else text };
        },
    }
}

fn handleExec(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    if (!writeEnabled()) {
        return errResult("error: pg_exec is disabled. Set ZMCP_POSTGRES_ALLOW_WRITE=1 in the server's environment to allow writes; pg_query stays read-only either way.");
    }
    const sql = getStr(args, "sql") orelse return errResult("error: sql is required");
    const sc = lex.scan(sql, true) catch |e| return errResult(scanMsg(e));
    if (sc.firstIs("copy") and sc.has_program) {
        return errResult("error: COPY ... PROGRAM runs a shell command on the database host and is refused");
    }
    const stmts = [_][]const u8{sc.sql};
    const out = try runPsql(alloc, io, true, &stmts, .raw);
    switch (out) {
        .err => |m| return errResult(m),
        .ok => |o| {
            const text = std.mem.trim(u8, o.stdout, "\r\n");
            if (text.len == 0 and !o.truncated) return .{ .text = "OK" };
            return .{ .text = try capText(alloc, text, o.truncated) };
        },
    }
}

// ---------------------------------------------------------------------------
// Real process execution
// ---------------------------------------------------------------------------

fn execReal(alloc: std.mem.Allocator, io: Io, argv: []const []const u8, env: *const Environ.Map, wall_ms: u32) !ExecResult {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.ExecutableNotFound,
        else => return err,
    };
    defer child.kill(io);

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(alloc, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    const limit: Io.Timeout = .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(wall_ms), .clock = .awake } };
    const deadline = limit.toDeadline(io);

    var truncated = false;
    var timed_out = false;
    while (multi_reader.fill(64, deadline)) |_| {
        if (stdout_reader.buffered().len > MAX_CAPTURE_BYTES or stderr_reader.buffered().len > MAX_CAPTURE_BYTES) {
            truncated = true;
            break;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => timed_out = true,
        else => |e| return e,
    }

    if (truncated or timed_out) {
        return .{
            .term = .{ .exited = 0 },
            .stdout = try multi_reader.toOwnedSlice(0),
            .stderr = try multi_reader.toOwnedSlice(1),
            .truncated = truncated,
            .timed_out = timed_out,
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
// Tests (no PostgreSQL required)
// ---------------------------------------------------------------------------

const testing = std.testing;

var fake_argv: []const []const u8 = &.{};
var fake_env: ?Environ.Map = null;
var fake_calls: usize = 0;
var fake_result: ExecResult = .{ .term = .{ .exited = 0 }, .stdout = @constCast(""), .stderr = @constCast("") };
var fake_error: ?anyerror = null;

fn fakeExec(alloc: std.mem.Allocator, io: Io, argv: []const []const u8, env: *const Environ.Map, wall_ms: u32) !ExecResult {
    _ = io;
    _ = wall_ms;
    fake_argv = argv;
    if (fake_env) |*e| e.deinit();
    fake_env = try env.clone(testing.allocator);
    _ = alloc;
    fake_calls += 1;
    if (fake_error) |e| return e;
    return fake_result;
}

const TestCtx = struct {
    arena_state: std.heap.ArenaAllocator,
    arena: std.mem.Allocator,
    env: Environ.Map,

    fn init(ctx: *TestCtx) void {
        ctx.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        ctx.arena = ctx.arena_state.allocator();
        ctx.env = Environ.Map.init(testing.allocator);
        g_env = &ctx.env;
        exec_fn = fakeExec;
        fake_argv = &.{};
        fake_calls = 0;
        fake_error = null;
        fake_result = .{ .term = .{ .exited = 0 }, .stdout = @constCast(""), .stderr = @constCast("") };
    }

    fn deinit(ctx: *TestCtx) void {
        exec_fn = execReal;
        g_env = null;
        if (fake_env) |*e| e.deinit();
        fake_env = null;
        ctx.env.deinit();
        ctx.arena_state.deinit();
    }

    fn args(ctx: *TestCtx, json: []const u8) !std.json.Value {
        const p = try std.json.parseFromSlice(std.json.Value, ctx.arena, json, .{});
        return p.value;
    }
};

fn expectContains(hay: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, hay, needle) == null) {
        std.debug.print("expected to find '{s}' in:\n{s}\n", .{ needle, hay });
        return error.TestExpectedContains;
    }
}

fn argAfter(flag: []const u8, n: usize) ?[]const u8 {
    var seen: usize = 0;
    for (fake_argv, 0..) |a, i| {
        if (std.mem.eql(u8, a, flag) and i + 1 < fake_argv.len) {
            if (seen == n) return fake_argv[i + 1];
            seen += 1;
        }
    }
    return null;
}

test "tool marks: pg_query/pg_schema read_only, pg_explain unmarked, pg_exec destructive" {
    for (tool_table) |t| {
        if (std.mem.eql(u8, t.name, "pg_query") or std.mem.eql(u8, t.name, "pg_schema")) {
            try testing.expect(t.read_only and !t.destructive);
        } else if (std.mem.eql(u8, t.name, "pg_explain")) {
            try testing.expect(!t.read_only and !t.destructive);
        } else if (std.mem.eql(u8, t.name, "pg_exec")) {
            try testing.expect(!t.read_only and t.destructive);
        } else return error.UnexpectedTool;
    }
}

test "tool schemas are valid JSON" {
    for (tool_table) |t| {
        const p = try std.json.parseFromSlice(std.json.Value, testing.allocator, t.input_schema_json, .{});
        p.deinit();
    }
}

test "buildArgv: argv only, one -c per statement, no dsn, -X first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const argv = try buildArgv(arena.allocator(), "psql", &.{ "BEGIN READ ONLY", "SELECT 1", "ROLLBACK" }, .csv);
    try testing.expectEqualStrings("psql", argv[0]);
    try testing.expectEqualStrings("-X", argv[1]);
    var c: usize = 0;
    for (argv) |a| {
        if (std.mem.eql(u8, a, "-c")) c += 1;
        try testing.expect(std.mem.indexOf(u8, a, "postgres://") == null);
        try testing.expect(!std.mem.eql(u8, a, "-d"));
        try testing.expect(!std.mem.eql(u8, a, "-f"));
    }
    try testing.expectEqual(@as(usize, 3), c);
    try testing.expectEqualStrings("-w", argv[3 + 0]); // -X -q -w
    try testing.expectEqualStrings("BEGIN READ ONLY", argv[argv.len - 5]);
    const raw = try buildArgv(arena.allocator(), "/x/psql", &.{"INSERT INTO t VALUES (1)"}, .raw);
    for (raw) |a| try testing.expect(!std.mem.eql(u8, a, "-q"));
}

test "buildChildEnv: DSN goes to env, password not in argv, options merged, DATABASE_URL removed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var base = Environ.Map.init(a);
    try base.put("PATH", "/usr/bin");
    try base.put("DATABASE_URL", "postgresql://x");
    try base.put("PGOPTIONS", "-c default_transaction_read_only=off");
    var secrets: std.ArrayList([]const u8) = .empty;
    const r = try buildChildEnv(a, &base, "postgresql://bob:hunter2@db:5433/app?sslmode=require", false, 1234, &secrets);
    const env = r.ok;
    try testing.expectEqualStrings("hunter2", env.get("PGPASSWORD").?);
    try testing.expectEqualStrings("bob", env.get("PGUSER").?);
    try testing.expectEqualStrings("db", env.get("PGHOST").?);
    try testing.expectEqualStrings("5433", env.get("PGPORT").?);
    try testing.expectEqualStrings("app", env.get("PGDATABASE").?);
    try testing.expectEqualStrings("require", env.get("PGSSLMODE").?);
    try testing.expect(env.get("DATABASE_URL") == null);
    try testing.expectEqualStrings("10", env.get("PGCONNECT_TIMEOUT").?);
    const po = env.get("PGOPTIONS").?;
    try testing.expect(std.mem.lastIndexOf(u8, po, "default_transaction_read_only=on").? > std.mem.indexOf(u8, po, "default_transaction_read_only=off").?);
    try expectContains(po, "statement_timeout=1234");
    try testing.expectEqualStrings("hunter2", secrets.items[0]);
    const bad = try buildChildEnv(a, &base, "postgresql://u:pw@h/d?nope=1", false, 1, &secrets);
    try testing.expect(bad == .err);
}

test "CSV parser: quotes, embedded newlines, NULL sentinel, blank line, trailing empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = try parseCsv(a, "a,b,c\n\x01N,,\"x,\"\"y\"\"\nl2\"\n1,2,\n");
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expect(rows[1][0] == null);
    try testing.expectEqualStrings("", rows[1][1].?);
    try testing.expectEqualStrings("x,\"y\"\nl2", rows[1][2].?);
    try testing.expectEqual(@as(usize, 3), rows[2].len);
    try testing.expectEqualStrings("", rows[2][2].?);
    const one = try parseCsv(a, "a\n\n\x01N\nz\n");
    try testing.expectEqual(@as(usize, 4), one.len);
    try testing.expectEqualStrings("", one[1][0].?);
    try testing.expect(one[2][0] == null);
    try testing.expectEqual(@as(usize, 1), (try parseCsv(a, "a\n")).len);
    try testing.expectEqual(@as(usize, 0), (try parseCsv(a, "")).len);
}

test "formatTable: NULL vs empty, escapes, cell truncation, row cap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long = try a.alloc(u8, 900);
    @memset(long, 'x');
    const csv = try std.fmt.allocPrint(a, "id,v\n1,\x01N\n2,\n3,\"a\tb\\c\"\n4,{s}\n", .{long});
    const rows = try parseCsv(a, csv);
    const t = try formatTable(a, rows, 100, false);
    try expectContains(t, "id\tv\n1\t\\N\n2\t\n");
    try expectContains(t, "3\ta\\tb\\\\c\n");
    try expectContains(t, "...[+400 bytes]");
    try expectContains(t, "(4 rows)");
    const capped = try formatTable(a, rows, 2, false);
    try expectContains(capped, "(2 rows shown; more exist");
    const one = try formatTable(a, try parseCsv(a, "a\n1\n"), 100, false);
    try expectContains(one, "(1 row)");
    const empty = try formatTable(a, try parseCsv(a, "a,b\n"), 100, false);
    try testing.expectEqualStrings("a\tb\n(0 rows)", empty);
    try testing.expectEqualStrings("(no result set)", try formatTable(a, &.{}, 100, false));
}

test "formatTable: byte cap keeps whole rows and says why" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var csv: std.ArrayList(u8) = .empty;
    try csv.appendSlice(a, "v\n");
    for (0..400) |_| {
        try csv.appendNTimes(a, 'y', 400);
        try csv.append(a, '\n');
    }
    const t = try formatTable(a, try parseCsv(a, csv.items), 5000, false);
    try testing.expect(t.len <= MAX_OUTPUT_BYTES + 200);
    try expectContains(t, "64 KiB output cap reached");
}

test "buildReadStmts: wrapped in READ ONLY, limit n+1, params via PREPARE" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sc = try lex.scan("select * from t where a = $1 and b = $2;", false);
    const p = try std.json.parseFromSlice(std.json.Value, a, "[\"o'r\\\\\", null, 5, true, {\"k\":1}]", .{});
    const stmts = try buildReadStmts(a, sc, p.value.array.items, 100);
    try testing.expectEqual(@as(usize, 4), stmts.len);
    try testing.expectEqualStrings("BEGIN READ ONLY", stmts[0]);
    try testing.expectEqualStrings("PREPARE zmcp_q AS SELECT * FROM (\nselect * from t where a = $1 and b = $2\n) AS zmcp_q LIMIT 101", stmts[1]);
    try testing.expectEqualStrings("EXECUTE zmcp_q('o''r\\', NULL, '5', 'true', '{\"k\":1}')", stmts[2]);
    try testing.expectEqualStrings("ROLLBACK", stmts[3]);
    const show = try buildReadStmts(a, try lex.scan("SHOW server_version", false), null, 10);
    try testing.expectEqual(@as(usize, 3), show.len);
    try testing.expectEqualStrings("SHOW server_version", show[1]);
}

test "handleQuery: SQL never reaches psql unless it is one allowed statement" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    const bad = [_][]const u8{
        "INSERT INTO t VALUES (1)",
        "CREATE TABLE x(a int)",
        "SELECT 1; DROP TABLE x",
        "\\! id",
        "SELECT 1\n\\! id",
        "BEGIN READ WRITE; INSERT INTO t VALUES (1)",
        "SET default_transaction_read_only=off; INSERT INTO t VALUES (1)",
        "COPY (SELECT 1) TO PROGRAM 'id'",
        "COPY t FROM PROGRAM 'id'",
        "COMMIT",
        "COMMIT AND CHAIN",
        "DO $$ BEGIN PERFORM 1; END $$",
        "CALL p()",
        "SET ROLE postgres",
        "DROP TABLE x",
        "   ",
        "SELECT 'unterminated",
    };
    for (bad) |sql| {
        const js = try std.json.Stringify.valueAlloc(ctx.arena, .{ .sql = sql }, .{});
        const r = try handleQuery(ctx.arena, testing.io, try ctx.args(js));
        try testing.expect(r.is_error);
    }
    try testing.expectEqual(@as(usize, 0), fake_calls);
}

test "handleQuery end-to-end with fake psql: argv, env, formatting" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    try ctx.env.put("DATABASE_URL", "postgresql://u:s3cret@h/d");
    try ctx.env.put("PATH", "/usr/bin");
    fake_result.stdout = @constCast("id,name\n1,ann\n2,\x01N\n");
    const r = try handleQuery(ctx.arena, testing.io, try ctx.args("{\"sql\":\"select id, name from users\",\"max_rows\":50}"));
    try testing.expect(!r.is_error);
    try testing.expectEqualStrings("id\tname\n1\tann\n2\t\\N\n(2 rows)", r.text);
    try testing.expectEqual(@as(usize, 1), fake_calls);
    try testing.expectEqualStrings("BEGIN READ ONLY", argAfter("-c", 0).?);
    try testing.expectEqualStrings("SELECT * FROM (\nselect id, name from users\n) AS zmcp_q LIMIT 51", argAfter("-c", 1).?);
    try testing.expectEqualStrings("ROLLBACK", argAfter("-c", 2).?);
    for (fake_argv) |a| {
        try testing.expect(std.mem.indexOf(u8, a, "s3cret") == null);
        try testing.expect(std.mem.indexOf(u8, a, "postgresql://") == null);
    }
    try testing.expectEqualStrings("s3cret", fake_env.?.get("PGPASSWORD").?);
    try expectContains(fake_env.?.get("PGOPTIONS").?, "default_transaction_read_only=on");
    try expectContains(fake_env.?.get("PGOPTIONS").?, "statement_timeout=30000");
}

test "timeout env is honoured" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    try ctx.env.put(timeout_env, "1500");
    fake_result.stdout = @constCast("a\n1\n");
    _ = try handleQuery(ctx.arena, testing.io, try ctx.args("{\"sql\":\"select 1\"}"));
    try expectContains(fake_env.?.get("PGOPTIONS").?, "statement_timeout=1500");
}

test "errors: password scrubbed, read-only hint, connection hint, missing psql, timeout" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    try ctx.env.put("DATABASE_URL", "postgresql://bob:hunter2@h/d");
    fake_result = .{
        .term = .{ .exited = 2 },
        .stdout = @constCast(""),
        .stderr = @constCast("psql: error: connection to server failed: FATAL:  password authentication failed for user \"bob\" (postgresql://bob:hunter2@h/d) hunter2\n"),
    };
    var r = try handleQuery(ctx.arena, testing.io, try ctx.args("{\"sql\":\"select 1\"}"));
    try testing.expect(r.is_error);
    try testing.expect(std.mem.indexOf(u8, r.text, "hunter2") == null);
    try expectContains(r.text, "check DATABASE_URL");

    fake_result.term = .{ .exited = 3 };
    fake_result.stderr = @constCast("ERROR:  cannot execute INSERT in a read-only transaction\n");
    r = try handleQuery(ctx.arena, testing.io, try ctx.args("{\"sql\":\"with x as (insert into t values (1) returning 1) select * from x\"}"));
    try testing.expect(r.is_error);
    try expectContains(r.text, "read-only");
    try expectContains(r.text, "pg_exec");

    fake_error = error.ExecutableNotFound;
    r = try handleQuery(ctx.arena, testing.io, try ctx.args("{\"sql\":\"select 1\"}"));
    try expectContains(r.text, "'psql' not found");

    fake_error = null;
    fake_result = .{ .term = .{ .exited = 0 }, .stdout = @constCast(""), .stderr = @constCast(""), .timed_out = true };
    r = try handleQuery(ctx.arena, testing.io, try ctx.args("{\"sql\":\"select pg_sleep(99)\"}"));
    try testing.expect(r.is_error);
    try expectContains(r.text, "timed out");
}

test "handleQuery params: bad shapes refused before psql" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    var r = try handleQuery(ctx.arena, testing.io, try ctx.args("{\"sql\":\"select $1\",\"params\":\"x\"}"));
    try testing.expect(r.is_error);
    r = try handleQuery(ctx.arena, testing.io, try ctx.args("{\"sql\":\"show all\",\"params\":[1]}"));
    try testing.expect(r.is_error);
    try testing.expectEqual(@as(usize, 0), fake_calls);
}

test "pg_exec is gated and refuses COPY PROGRAM and meta-commands" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    var r = try handleExec(ctx.arena, testing.io, try ctx.args("{\"sql\":\"insert into t values (1)\"}"));
    try testing.expect(r.is_error);
    try expectContains(r.text, "ZMCP_POSTGRES_ALLOW_WRITE=1");
    try testing.expectEqual(@as(usize, 0), fake_calls);

    try ctx.env.put(write_env, "true"); // only exactly "1" enables
    r = try handleExec(ctx.arena, testing.io, try ctx.args("{\"sql\":\"insert into t values (1)\"}"));
    try testing.expect(r.is_error);
    try ctx.env.put(write_env, "1");

    r = try handleExec(ctx.arena, testing.io, try ctx.args("{\"sql\":\"copy t to program 'id'\"}"));
    try testing.expect(r.is_error);
    r = try handleExec(ctx.arena, testing.io, try ctx.args("{\"sql\":\"\\\\! id\"}"));
    try testing.expect(r.is_error);
    try testing.expectEqual(@as(usize, 0), fake_calls);

    fake_result.stdout = @constCast("INSERT 0 1\n");
    r = try handleExec(ctx.arena, testing.io, try ctx.args("{\"sql\":\"insert into t values (1);\"}"));
    try testing.expect(!r.is_error);
    try testing.expectEqualStrings("INSERT 0 1", r.text);
    try testing.expectEqualStrings("insert into t values (1);", argAfter("-c", 0).?);
    try expectContains(fake_env.?.get("PGOPTIONS").?, "default_transaction_read_only=off");
    fake_result.stdout = @constCast("");
    r = try handleExec(ctx.arena, testing.io, try ctx.args("{\"sql\":\"create table a(x int); create table b(y int)\"}"));
    try testing.expectEqualStrings("OK", r.text);
    try testing.expectEqualStrings("create table a(x int); create table b(y int)", argAfter("-c", 0).?);
}

test "pg_explain: analyze gating" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fake_result.stdout = @constCast("QUERY PLAN\n\"Seq Scan on t  (cost=0.00..1.00 rows=1 width=4)\"\n\"  Filter: (a = 1)\"\n");
    // plain EXPLAIN of DML: fine, read-only session
    var r = try handleExplain(ctx.arena, testing.io, try ctx.args("{\"sql\":\"delete from t where a = 1\"}"));
    try testing.expect(!r.is_error);
    try expectContains(r.text, "Seq Scan on t");
    try testing.expectEqualStrings("EXPLAIN delete from t where a = 1", argAfter("-c", 1).?);
    try testing.expectEqualStrings("BEGIN READ ONLY", argAfter("-c", 0).?);
    // analyze on SELECT: read-only session even without the flag
    r = try handleExplain(ctx.arena, testing.io, try ctx.args("{\"sql\":\"select * from t\",\"analyze\":true}"));
    try testing.expect(!r.is_error);
    try testing.expectEqualStrings("EXPLAIN (ANALYZE) select * from t", argAfter("-c", 1).?);
    try testing.expectEqualStrings("BEGIN READ ONLY", argAfter("-c", 0).?);
    try expectContains(fake_env.?.get("PGOPTIONS").?, "default_transaction_read_only=on");
    // analyze on DML: refused without the flag
    const calls = fake_calls;
    r = try handleExplain(ctx.arena, testing.io, try ctx.args("{\"sql\":\"update t set a=1\",\"analyze\":true}"));
    try testing.expect(r.is_error);
    try expectContains(r.text, "executes the statement");
    try testing.expectEqual(calls, fake_calls);
    // ...and with the flag it runs in a rolled-back read-write transaction
    try ctx.env.put(write_env, "1");
    r = try handleExplain(ctx.arena, testing.io, try ctx.args("{\"sql\":\"update t set a=1\",\"analyze\":true}"));
    try testing.expect(!r.is_error);
    try testing.expectEqualStrings("BEGIN", argAfter("-c", 0).?);
    try testing.expectEqualStrings("ROLLBACK", argAfter("-c", 2).?);
    try expectContains(fake_env.?.get("PGOPTIONS").?, "default_transaction_read_only=off");
    // EXPLAIN keyword / multi statement / DDL refused
    r = try handleExplain(ctx.arena, testing.io, try ctx.args("{\"sql\":\"explain select 1\"}"));
    try testing.expect(r.is_error);
    r = try handleExplain(ctx.arena, testing.io, try ctx.args("{\"sql\":\"select 1; select 2\"}"));
    try testing.expect(r.is_error);
    r = try handleExplain(ctx.arena, testing.io, try ctx.args("{\"sql\":\"drop table t\",\"analyze\":true}"));
    try testing.expect(r.is_error);
}

test "pg_schema: SQL construction, quoting and messages" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectContains(try buildSchemaSql(a, null, null), "GROUP BY n.nspname");
    try expectContains(try buildSchemaSql(a, "we'ird", null), "n.nspname = 'we''ird'");
    const t1 = try buildSchemaSql(a, "public", "Users");
    try expectContains(t1, "to_regclass('public.\"Users\"')");
    const t2 = try buildSchemaSql(a, "public", "app.users");
    try expectContains(t2, "to_regclass('app.users')");
    const t3 = try buildSchemaSql(a, null, "o'x");
    try expectContains(t3, "to_regclass('o''x')");

    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fake_result.stdout = @constCast("line\ntable public.users (~10 rows)\n\"  id integer NOT NULL DEFAULT nextval('users_id_seq'::regclass)\"\n");
    var r = try handleSchema(ctx.arena, testing.io, try ctx.args("{\"table\":\"users\"}"));
    try testing.expect(!r.is_error);
    try testing.expectEqualStrings("table public.users (~10 rows)\n  id integer NOT NULL DEFAULT nextval('users_id_seq'::regclass)", r.text);
    try testing.expectEqualStrings("BEGIN READ ONLY", argAfter("-c", 0).?);
    fake_result.stdout = @constCast("line\n");
    r = try handleSchema(ctx.arena, testing.io, try ctx.args("{\"table\":\"nope\"}"));
    try testing.expect(r.is_error);
    try expectContains(r.text, "not found: nope");
    r = try handleSchema(ctx.arena, testing.io, try ctx.args("{\"schema\":\"x\"}"));
    try expectContains(r.text, "no tables or views in schema 'x'");
    r = try handleSchema(ctx.arena, testing.io, try ctx.args("{\"schema\":\"\"}"));
    try testing.expect(r.is_error);
}

test "quoteLiteral and quoteIdent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("'a''b\\'", try quoteLiteral(a, "a'b\\"));
    try testing.expectEqualStrings("users", try quoteIdent(a, "users"));
    try testing.expectEqualStrings("\"Users\"", try quoteIdent(a, "Users"));
    try testing.expectEqualStrings("\"a\"\"b\"", try quoteIdent(a, "a\"b"));
    try testing.expectEqualStrings("\"1a\"", try quoteIdent(a, "1a"));
}

test "clampRows" {
    try testing.expectEqual(@as(usize, 100), clampRows(null));
    try testing.expectEqual(@as(usize, 100), clampRows(0));
    try testing.expectEqual(@as(usize, 100), clampRows(-5));
    try testing.expectEqual(@as(usize, 7), clampRows(7));
    try testing.expectEqual(@as(usize, 5000), clampRows(1_000_000));
}

test "sub-modules" {
    _ = lex;
    _ = conn;
}
