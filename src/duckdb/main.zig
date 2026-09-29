//! zmcp-duckdb - pure-Zig MCP server wrapping the local `duckdb` CLI.
//!
//! Mirrors src/sqlite/main.zig: the CLI is spawned with an argv array (never a
//! shell), results come back through `-json`, and reads are opened with
//! `-readonly` whenever a database file is given. Writes are opt-in via the
//! environment variable ZMCP_DUCKDB_ALLOW_WRITE=1.
//!
//! Notes on DuckDB specifics:
//!   * `duckdb -readonly` refuses to run without a database file ("Cannot launch
//!     in-memory database in read-only mode"), so with no `db` the query runs in
//!     a throwaway in-memory database and read-only-ness is enforced by the SQL
//!     gate below (single statement, allowlisted first keyword, denylisted
//!     write/side-effect keywords) instead of by the CLI flag.
//!   * The SQL is passed with `-c <sql>` as one argv element. No temp files.

const std = @import("std");
const mcp = @import("mcp");

const Io = std.Io;

const DEFAULT_MAX_ROWS: usize = 200;
const HARD_MAX_ROWS: usize = 10_000;
/// Max bytes read from the duckdb child's stdout / stderr.
const STDOUT_LIMIT_BYTES: usize = 16 * 1024 * 1024;
const STDERR_LIMIT_BYTES: usize = 1024 * 1024;
/// Max bytes of rendered text handed back to the model.
const MAX_OUTPUT_BYTES: usize = 256 * 1024;

const WRITE_ENV = "ZMCP_DUCKDB_ALLOW_WRITE";
const BIN_ENV = "DUCKDB_BIN";

/// Process environment, captured in main(). `std.process.Environ.Block` is empty
/// on POSIX unless taken from `Init`, so handlers read env through this map.
var g_env: ?*const std.process.Environ.Map = null;

fn envGet(key: []const u8) ?[]const u8 {
    const m = g_env orelse return null;
    return m.get(key);
}

pub fn main(init: std.process.Init) !void {
    g_env = init.environ_map;
    try mcp.run(init.gpa, init.io, .{ .name = "zmcp-duckdb", .version = "0.1.0" }, &tool_table);
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "duckdb_query",
        .description = "Run a read-only SQL query (SELECT / WITH / FROM / DESCRIBE / SUMMARIZE / SHOW / EXPLAIN / VALUES) with DuckDB. Optionally against a .duckdb/.db file (opened read-only); without `db` it runs in memory and can read csv/parquet/json files directly, e.g. SELECT * FROM '/data/x.parquet'. Single statement only. Returns JSON rows.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "sql": { "type": "string", "description": "One read-only SQL statement." },
        \\    "db": { "type": "string", "description": "Optional path to a DuckDB database file (opened read-only)." },
        \\    "max_rows": { "type": "integer", "description": "Cap rows returned (default 200, max 10000)." }
        \\  },
        \\  "required": ["sql"]
        \\}
        ,
        .handler = handleQuery,
        .read_only = true,
    },
    .{
        .name = "duckdb_schema",
        .description = "DESCRIBE a table (in `db`) or a csv/parquet/json file: column names, types and nullability.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "target": { "type": "string", "description": "Table name (optionally schema.table) or a file path / glob / URL (.csv, .parquet, .json, ...)." },
        \\    "db": { "type": "string", "description": "Path to a DuckDB database file; needed when target is a table." }
        \\  },
        \\  "required": ["target"]
        \\}
        ,
        .handler = handleSchema,
        .read_only = true,
    },
    .{
        .name = "duckdb_exec",
        .description = "Run a write statement (INSERT / UPDATE / CREATE / COPY ... TO / ...) with DuckDB. Disabled unless the server was started with ZMCP_DUCKDB_ALLOW_WRITE=1. Opens the database read-write.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "sql": { "type": "string", "description": "SQL to run." },
        \\    "db": { "type": "string", "description": "Optional path to a DuckDB database file (created if missing)." }
        \\  },
        \\  "required": ["sql"]
        \\}
        ,
        .handler = handleExec,
        .destructive = true,
    },
};

// ---------------------------------------------------------------------------
// Pure helpers (unit-tested without duckdb)
// ---------------------------------------------------------------------------

/// Write gate: only the exact value "1" enables duckdb_exec.
fn writeAllowed(value: ?[]const u8) bool {
    const v = value orelse return false;
    return std.mem.eql(u8, v, "1");
}

const SqlVerdict = enum { ok, empty, multi_statement, not_read_only, forbidden_keyword };

const allowed_first = [_][]const u8{
    "SELECT", "WITH", "FROM", "DESCRIBE", "DESC", "SUMMARIZE", "SHOW", "EXPLAIN", "VALUES", "TABLE",
};

const denied_words = [_][]const u8{
    "COPY",    "ATTACH", "DETACH", "INSTALL", "LOAD",     "EXPORT",   "IMPORT", "PRAGMA", "CALL",
    "SET",     "RESET",  "INSERT", "UPDATE",  "DELETE",   "CREATE",   "DROP",   "ALTER",  "TRUNCATE",
    "VACUUM",  "CHECKPOINT", "USE", "MERGE",  "FORCE",    "COMMENT",  "GRANT",  "REVOKE",
};

fn inWordList(list: []const []const u8, word: []const u8) bool {
    for (list) |w| if (std.ascii.eqlIgnoreCase(w, word)) return true;
    return false;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Lexical gate for duckdb_query. Skips comments and quoted text, requires one
/// statement whose first word is on the allowlist, and rejects any unquoted
/// write / side-effect keyword anywhere (this also blocks `COPY (..) TO file`,
/// ATTACH, INSTALL/LOAD and CTE-embedded writes). Conservative on purpose: an
/// unquoted column literally named e.g. `set` must be double-quoted.
fn checkReadOnlySql(sql: []const u8) SqlVerdict {
    var i: usize = 0;
    var first_seen = false;
    var ended = false; // a ';' has been consumed; only whitespace/comments may follow
    while (i < sql.len) {
        const c = sql[i];
        if (c == '-' and i + 1 < sql.len and sql[i + 1] == '-') {
            i += 2;
            while (i < sql.len and sql[i] != '\n') : (i += 1) {}
            continue;
        }
        if (c == '/' and i + 1 < sql.len and sql[i + 1] == '*') {
            i += 2;
            while (i + 1 < sql.len and !(sql[i] == '*' and sql[i + 1] == '/')) : (i += 1) {}
            i = @min(sql.len, i + 2);
            continue;
        }
        if (std.ascii.isWhitespace(c)) {
            i += 1;
            continue;
        }
        if (ended) return .multi_statement;
        if (c == ';') {
            ended = true;
            i += 1;
            continue;
        }
        if (c == '\'' or c == '"') {
            if (!first_seen and c == '\'') return .not_read_only;
            i += 1;
            while (i < sql.len) {
                if (sql[i] == c) {
                    if (i + 1 < sql.len and sql[i + 1] == c) {
                        i += 2;
                        continue;
                    }
                    break;
                }
                i += 1;
            }
            i = @min(sql.len, i + 1);
            first_seen = true;
            continue;
        }
        if (isWordChar(c)) {
            const start = i;
            while (i < sql.len and isWordChar(sql[i])) : (i += 1) {}
            const word = sql[start..i];
            if (!first_seen) {
                if (!inWordList(&allowed_first, word)) return .not_read_only;
                first_seen = true;
            }
            if (inWordList(&denied_words, word)) return .forbidden_keyword;
            continue;
        }
        // '(' before any word, '.' (dot commands), '$' etc.
        if (!first_seen) return .not_read_only;
        i += 1;
    }
    if (!first_seen) return .empty;
    return .ok;
}

fn verdictMessage(v: SqlVerdict) []const u8 {
    return switch (v) {
        .ok => "ok",
        .empty => "sql is empty",
        .multi_statement => "duckdb_query accepts exactly one statement. Use duckdb_exec for scripts.",
        .not_read_only => "duckdb_query only accepts SELECT / WITH / FROM / DESCRIBE / SUMMARIZE / SHOW / EXPLAIN / VALUES. Use duckdb_exec for writes.",
        .forbidden_keyword => "duckdb_query rejected a write or side-effect keyword (COPY, ATTACH, INSERT, SET, PRAGMA, ...). Use duckdb_exec for writes (requires ZMCP_DUCKDB_ALLOW_WRITE=1).",
    };
}

/// A db path must not be mistaken for a CLI option or contain NUL.
fn validDbPath(db: []const u8) bool {
    if (db.len == 0) return false;
    if (db[0] == '-') return false;
    return std.mem.indexOfScalar(u8, db, 0) == null;
}

/// Build the duckdb argv. Returned list borrows all slices. -readonly is only
/// emitted with a db file (duckdb rejects it for in-memory).
fn buildArgv(
    alloc: std.mem.Allocator,
    bin: []const u8,
    db: ?[]const u8,
    readonly: bool,
    sql: []const u8,
) !std.ArrayList([]const u8) {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(alloc);
    try argv.append(alloc, bin);
    try argv.append(alloc, "-json");
    if (readonly and db != null) try argv.append(alloc, "-readonly");
    if (db) |d| try argv.append(alloc, d);
    try argv.append(alloc, "-c");
    try argv.append(alloc, sql);
    return argv;
}

fn quotedText(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    return quoteWith(alloc, s, '\'');
}

fn quotedIdent(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    return quoteWith(alloc, s, '"');
}

fn quoteWith(alloc: std.mem.Allocator, s: []const u8, q: u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, q);
    for (s) |c| {
        if (c == q) try out.append(alloc, q);
        try out.append(alloc, c);
    }
    try out.append(alloc, q);
    return out.toOwnedSlice(alloc);
}

const file_exts = [_][]const u8{
    ".csv", ".tsv", ".parquet", ".pq", ".json", ".jsonl", ".ndjson", ".gz", ".zst", ".txt", ".tsv.gz", ".csv.gz",
};

fn isFileTarget(t: []const u8) bool {
    if (std.mem.indexOfAny(u8, t, "/\\*") != null) return true;
    if (std.mem.indexOf(u8, t, "://") != null) return true;
    for (file_exts) |ext| {
        if (t.len > ext.len and std.ascii.endsWithIgnoreCase(t, ext)) return true;
    }
    return false;
}

/// SQL for duckdb_schema. Caller owns the result.
fn schemaSql(alloc: std.mem.Allocator, target: []const u8) ![]u8 {
    if (isFileTarget(target)) {
        const lit = try quotedText(alloc, target);
        defer alloc.free(lit);
        return std.fmt.allocPrint(alloc, "DESCRIBE SELECT * FROM {s}", .{lit});
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "DESCRIBE ");
    var it = std.mem.splitScalar(u8, target, '.');
    var n: usize = 0;
    while (it.next()) |part| : (n += 1) {
        if (n > 0) try out.append(alloc, '.');
        const q = try quotedIdent(alloc, part);
        defer alloc.free(q);
        try out.appendSlice(alloc, q);
    }
    return out.toOwnedSlice(alloc);
}

fn trimLineEndings(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and (s[end - 1] == '\r' or s[end - 1] == '\n')) : (end -= 1) {}
    return s[0..end];
}

/// Longest prefix of `s` that is <= max bytes and does not end mid UTF-8 char.
fn utf8Prefix(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) : (end -= 1) {}
    return s[0..end];
}

fn getStr(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn getInt(args: std.json.Value, key: []const u8, default: i64) i64 {
    if (args != .object) return default;
    const v = args.object.get(key) orelse return default;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => default,
    };
}

fn jStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

// ---------------------------------------------------------------------------
// Process running
// ---------------------------------------------------------------------------

const RunResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
};

fn duckdbBin() []const u8 {
    if (envGet(BIN_ENV)) |v| if (v.len > 0) return v;
    return "duckdb";
}

fn errResult(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !mcp.ToolResult {
    return .{ .text = try std.fmt.allocPrint(alloc, fmt, args), .is_error = true };
}

/// Runs duckdb. On spawn failure returns a ready-made error ToolResult in `err`.
fn runDuckdb(
    alloc: std.mem.Allocator,
    io: Io,
    tool: []const u8,
    db: ?[]const u8,
    readonly: bool,
    sql: []const u8,
    err: *?mcp.ToolResult,
) !?RunResult {
    if (db) |d| if (!validDbPath(d)) {
        err.* = try errResult(alloc, "{s} failed: invalid db path (empty, starts with '-', or contains NUL)", .{tool});
        return null;
    };
    const bin = duckdbBin();
    var argv = try buildArgv(alloc, bin, db, readonly, sql);
    defer argv.deinit(alloc);

    const r = std.process.run(alloc, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(STDOUT_LIMIT_BYTES),
        .stderr_limit = .limited(STDERR_LIMIT_BYTES),
    }) catch |e| {
        err.* = switch (e) {
            error.FileNotFound => try errResult(alloc, "{s} failed: the `duckdb` CLI was not found (looked for '{s}'). Install DuckDB (https://duckdb.org/docs/installation) and put it on PATH, or set {s} to its full path.", .{ tool, bin, BIN_ENV }),
            error.StreamTooLong => try errResult(alloc, "{s} failed: duckdb output exceeded {d} bytes; add a LIMIT or select fewer columns.", .{ tool, STDOUT_LIMIT_BYTES }),
            else => try errResult(alloc, "{s} failed to run duckdb: {s}", .{ tool, @errorName(e) }),
        };
        return null;
    };
    return .{ .term = r.term, .stdout = r.stdout, .stderr = r.stderr };
}

fn isExitedZero(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn failureText(alloc: std.mem.Allocator, tool: []const u8, r: RunResult) !mcp.ToolResult {
    const msg = if (r.stderr.len > 0) trimLineEndings(r.stderr) else if (r.stdout.len > 0) trimLineEndings(r.stdout) else "unknown error";
    return errResult(alloc, "{s} failed: {s}", .{ tool, utf8Prefix(msg, 8 * 1024) });
}

fn prettyJson(alloc: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &out.writer);
    return out.toOwnedSlice();
}

fn parseRows(alloc: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return std.json.parseFromSlice(std.json.Value, alloc, "[]", .{});
    return std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{});
}

/// Render a row array with row and byte caps.
fn renderRows(alloc: std.mem.Allocator, rows: []const std.json.Value, max_rows: usize) ![]u8 {
    const keep = @min(rows.len, max_rows);
    var arr: std.json.Array = .init(alloc);
    defer arr.deinit();
    for (rows[0..keep]) |item| try arr.append(item);
    const body = try prettyJson(alloc, .{ .array = arr });
    defer alloc.free(body);

    const shown = utf8Prefix(body, MAX_OUTPUT_BYTES);
    const byte_cut = shown.len < body.len;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("{d} row(s):\n{s}", .{ rows.len, shown });
    if (byte_cut) try out.writer.print("\n\n(output cut at {d} bytes; add a LIMIT or select fewer columns)", .{MAX_OUTPUT_BYTES});
    if (rows.len > keep) try out.writer.print("\n\n(+ {d} rows truncated)", .{rows.len - keep});
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

fn handleQuery(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const sql = getStr(args, "sql") orelse return .{ .text = "sql is required", .is_error = true };
    const db = getStr(args, "db");
    const verdict = checkReadOnlySql(sql);
    if (verdict != .ok) return .{ .text = verdictMessage(verdict), .is_error = true };
    const max_rows: usize = @min(@as(usize, @intCast(@max(getInt(args, "max_rows", DEFAULT_MAX_ROWS), 0))), HARD_MAX_ROWS);

    return runRows(alloc, io, "duckdb_query", db, sql, max_rows);
}

fn runRows(alloc: std.mem.Allocator, io: Io, tool: []const u8, db: ?[]const u8, sql: []const u8, max_rows: usize) !mcp.ToolResult {
    var err: ?mcp.ToolResult = null;
    const result = (try runDuckdb(alloc, io, tool, db, true, sql, &err)) orelse return err.?;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (!isExitedZero(result.term)) return failureText(alloc, tool, result);

    const parsed = parseRows(alloc, result.stdout) catch {
        // e.g. NaN/Infinity, which duckdb emits unquoted. Return raw, capped.
        const raw = utf8Prefix(trimLineEndings(result.stdout), MAX_OUTPUT_BYTES);
        return .{ .text = try std.fmt.allocPrint(alloc, "(duckdb output was not strict JSON; raw follows)\n{s}", .{raw}) };
    };
    defer parsed.deinit();
    if (parsed.value != .array) return errResult(alloc, "{s} failed: unexpected duckdb JSON shape", .{tool});
    return .{ .text = try renderRows(alloc, parsed.value.array.items, max_rows) };
}

fn handleSchema(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const target = getStr(args, "target") orelse return .{ .text = "target is required", .is_error = true };
    if (std.mem.trim(u8, target, " \t\r\n").len == 0) return .{ .text = "target is required", .is_error = true };
    const db = getStr(args, "db");
    const sql = try schemaSql(alloc, target);
    defer alloc.free(sql);

    var err: ?mcp.ToolResult = null;
    const result = (try runDuckdb(alloc, io, "duckdb_schema", db, true, sql, &err)) orelse return err.?;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (!isExitedZero(result.term)) return failureText(alloc, "duckdb_schema", result);

    const parsed = parseRows(alloc, result.stdout) catch return errResult(alloc, "duckdb_schema failed: could not parse duckdb JSON", .{});
    defer parsed.deinit();
    if (parsed.value != .array) return errResult(alloc, "duckdb_schema failed: unexpected duckdb JSON shape", .{});
    if (parsed.value.array.items.len == 0) return .{ .text = "(no columns)" };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("{s} {s}\n", .{ if (isFileTarget(target)) "FILE" else "TABLE", target });
    for (parsed.value.array.items) |row_v| {
        if (row_v != .object) continue;
        const o = row_v.object;
        const name = jStr(o, "column_name") orelse "?";
        const typ = jStr(o, "column_type") orelse "?";
        try out.writer.print("  {s} {s}", .{ name, typ });
        if (jStr(o, "null")) |n| {
            if (std.mem.eql(u8, n, "NO")) try out.writer.writeAll(" [NN]");
        }
        if (jStr(o, "key")) |k| {
            if (std.mem.eql(u8, k, "PRI")) try out.writer.writeAll(" [PK]");
        }
        if (o.get("default")) |d| if (d == .string) try out.writer.print(" DEFAULT {s}", .{d.string});
        try out.writer.writeByte('\n');
    }
    return .{ .text = try alloc.dupe(u8, trimLineEndings(out.written())) };
}

fn handleExec(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    if (!writeAllowed(envGet(WRITE_ENV))) {
        return .{
            .text = "duckdb_exec is disabled. Start the server with environment variable " ++ WRITE_ENV ++ "=1 to allow writes.",
            .is_error = true,
        };
    }
    const sql = getStr(args, "sql") orelse return .{ .text = "sql is required", .is_error = true };
    if (std.mem.trim(u8, sql, " \t\r\n").len == 0) return .{ .text = "sql is empty", .is_error = true };
    const db = getStr(args, "db");

    var err: ?mcp.ToolResult = null;
    const result = (try runDuckdb(alloc, io, "duckdb_exec", db, false, sql, &err)) orelse return err.?;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (!isExitedZero(result.term)) return failureText(alloc, "duckdb_exec", result);

    const out = trimLineEndings(result.stdout);
    if (out.len == 0) return .{ .text = try alloc.dupe(u8, "OK") };
    return .{ .text = try std.fmt.allocPrint(alloc, "OK\n{s}", .{utf8Prefix(out, MAX_OUTPUT_BYTES)}) };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "write gate requires exactly 1" {
    try testing.expect(!writeAllowed(null));
    try testing.expect(!writeAllowed(""));
    try testing.expect(!writeAllowed("0"));
    try testing.expect(!writeAllowed("true"));
    try testing.expect(writeAllowed("1"));
}

test "duckdb_exec is refused when the gate is closed" {
    g_env = null;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var obj = std.json.ObjectMap.empty;
    try obj.put(arena.allocator(), "sql", .{ .string = "CREATE TABLE t(i int)" });
    const r = try handleExec(arena.allocator(), testing.io, .{ .object = obj });
    try testing.expect(r.is_error);
    try testing.expect(std.mem.indexOf(u8, r.text, WRITE_ENV) != null);
}

test "sql gate accepts reads" {
    try testing.expectEqual(SqlVerdict.ok, checkReadOnlySql("SELECT 1"));
    try testing.expectEqual(SqlVerdict.ok, checkReadOnlySql("  select * from 'a.parquet' limit 5;  "));
    try testing.expectEqual(SqlVerdict.ok, checkReadOnlySql("-- hi\nWITH x AS (SELECT 1) SELECT * FROM x"));
    try testing.expectEqual(SqlVerdict.ok, checkReadOnlySql("FROM 'a.csv'"));
    try testing.expectEqual(SqlVerdict.ok, checkReadOnlySql("DESCRIBE t"));
    try testing.expectEqual(SqlVerdict.ok, checkReadOnlySql("SELECT 'a;b; DROP TABLE x' AS s, \"set\" FROM t"));
    try testing.expectEqual(SqlVerdict.ok, checkReadOnlySql("SELECT replace(a,'x','y') FROM t /* COPY */"));
}

test "sql gate rejects writes and tricks" {
    try testing.expectEqual(SqlVerdict.empty, checkReadOnlySql("  -- nothing\n"));
    try testing.expectEqual(SqlVerdict.not_read_only, checkReadOnlySql("INSERT INTO t VALUES (1)"));
    try testing.expectEqual(SqlVerdict.not_read_only, checkReadOnlySql("COPY t TO 'x.csv'"));
    try testing.expectEqual(SqlVerdict.not_read_only, checkReadOnlySql(".shell rm -rf /"));
    try testing.expectEqual(SqlVerdict.not_read_only, checkReadOnlySql("(SELECT 1)"));
    try testing.expectEqual(SqlVerdict.not_read_only, checkReadOnlySql("PRAGMA version"));
    try testing.expectEqual(SqlVerdict.multi_statement, checkReadOnlySql("SELECT 1; SELECT 2"));
    try testing.expectEqual(SqlVerdict.multi_statement, checkReadOnlySql("SELECT 1; -- c\n DROP TABLE t"));
    try testing.expectEqual(SqlVerdict.forbidden_keyword, checkReadOnlySql("WITH x AS (SELECT 1) INSERT INTO t SELECT * FROM x"));
    try testing.expectEqual(SqlVerdict.multi_statement, checkReadOnlySql("SELECT * FROM t; ATTACH 'x.db'"));
    try testing.expectEqual(SqlVerdict.forbidden_keyword, checkReadOnlySql("SELECT * FROM (COPY t TO 'x')"));
    try testing.expectEqual(SqlVerdict.forbidden_keyword, checkReadOnlySql("SELECT 1 /* x */ UNION SELECT load FROM t"));
}

test "argv building: readonly only with db, no shell, sql is one element" {
    const alloc = testing.allocator;
    var a = try buildArgv(alloc, "duckdb", "/tmp/x.duckdb", true, "SELECT 1; --");
    defer a.deinit(alloc);
    try testing.expectEqual(@as(usize, 6), a.items.len);
    try testing.expectEqualStrings("duckdb", a.items[0]);
    try testing.expectEqualStrings("-json", a.items[1]);
    try testing.expectEqualStrings("-readonly", a.items[2]);
    try testing.expectEqualStrings("/tmp/x.duckdb", a.items[3]);
    try testing.expectEqualStrings("-c", a.items[4]);
    try testing.expectEqualStrings("SELECT 1; --", a.items[5]);

    var b = try buildArgv(alloc, "duckdb", null, true, "SELECT 1");
    defer b.deinit(alloc);
    try testing.expectEqual(@as(usize, 4), b.items.len);
    for (b.items) |s| try testing.expect(!std.mem.eql(u8, s, "-readonly"));

    var c = try buildArgv(alloc, "duckdb", "w.db", false, "CREATE TABLE t(i int)");
    defer c.deinit(alloc);
    for (c.items) |s| try testing.expect(!std.mem.eql(u8, s, "-readonly"));
}

test "db path validation" {
    try testing.expect(validDbPath("/tmp/a.duckdb"));
    try testing.expect(!validDbPath(""));
    try testing.expect(!validDbPath("-init"));
    try testing.expect(!validDbPath("a\x00b"));
}

test "schema target classification and sql" {
    const alloc = testing.allocator;
    try testing.expect(isFileTarget("/data/x.parquet"));
    try testing.expect(isFileTarget("data.CSV"));
    try testing.expect(isFileTarget("s3://b/k"));
    try testing.expect(isFileTarget("logs/*"));
    try testing.expect(!isFileTarget("users"));
    try testing.expect(!isFileTarget("main.users"));

    const f = try schemaSql(alloc, "/d/it's.csv");
    defer alloc.free(f);
    try testing.expectEqualStrings("DESCRIBE SELECT * FROM '/d/it''s.csv'", f);

    const t = try schemaSql(alloc, "main.us\"ers");
    defer alloc.free(t);
    try testing.expectEqualStrings("DESCRIBE \"main\".\"us\"\"ers\"", t);
}

test "row and byte caps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rows: std.ArrayList(std.json.Value) = .empty;
    for (0..5) |i| {
        var o = std.json.ObjectMap.empty;
        try o.put(a, "n", .{ .integer = @intCast(i) });
        try rows.append(a, .{ .object = o });
    }
    const txt = try renderRows(a, rows.items, 2);
    try testing.expect(std.mem.startsWith(u8, txt, "5 row(s):"));
    try testing.expect(std.mem.indexOf(u8, txt, "(+ 3 rows truncated)") != null);

    try testing.expectEqualStrings("ab", utf8Prefix("abé", 3)); // é is 2 bytes at 2..4
}

fn haveDuckdb(alloc: std.mem.Allocator) bool {
    const r = std.process.run(alloc, testing.io, .{
        .argv = &.{ "duckdb", "-version" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return false;
    alloc.free(r.stdout);
    alloc.free(r.stderr);
    return isExitedZero(r.term);
}

test "integration: query, schema, exec gate (skipped without duckdb)" {
    if (!haveDuckdb(testing.allocator)) return error.SkipZigTest;
    g_env = null;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var q = std.json.ObjectMap.empty;
    try q.put(a, "sql", .{ .string = "SELECT 42 AS answer, 'hi' AS s UNION ALL SELECT 7, 'yo'" });
    const r = try handleQuery(a, testing.io, .{ .object = q });
    try testing.expect(!r.is_error);
    try testing.expect(std.mem.indexOf(u8, r.text, "\"answer\": 42") != null);
    try testing.expect(std.mem.startsWith(u8, r.text, "2 row(s):"));

    var q2 = std.json.ObjectMap.empty;
    try q2.put(a, "sql", .{ .string = "SELECT * FROM range(10)" });
    try q2.put(a, "max_rows", .{ .integer = 3 });
    const r2 = try handleQuery(a, testing.io, .{ .object = q2 });
    try testing.expect(std.mem.indexOf(u8, r2.text, "(+ 7 rows truncated)") != null);

    var bad = std.json.ObjectMap.empty;
    try bad.put(a, "sql", .{ .string = "SELECT * FROM no_such_table" });
    const r3 = try handleQuery(a, testing.io, .{ .object = bad });
    try testing.expect(r3.is_error);

    var s = std.json.ObjectMap.empty;
    try s.put(a, "target", .{ .string = "/nonexistent/zmcp-none.csv" });
    const r4 = try handleSchema(a, testing.io, .{ .object = s });
    try testing.expect(r4.is_error);

    var e = std.json.ObjectMap.empty;
    try e.put(a, "sql", .{ .string = "SELECT 1" });
    const r5 = try handleExec(a, testing.io, .{ .object = e });
    try testing.expect(r5.is_error);
}
