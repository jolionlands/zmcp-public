//! zmcp-sqlite - pure-Zig port of the local `sqlite` MCP.
//! Uses the local sqlite3 CLI as a lightweight backend with per-call DB paths.

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


const Io = std.Io;
const DEFAULT_MAX_ROWS: usize = 200;

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    g_env_io = init.io;
    const io = init.io;
    try mcp.run(arena, io, .{ .name = "zmcp-sqlite", .version = "0.1.0" }, &tool_table);
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "sqlite_query",
        .description = "Run a read-only SQL query (SELECT, PRAGMA, EXPLAIN, WITH) against any .db/.sqlite file on disk. Returns JSON rows. The DB is opened read-only.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "db": { "type": "string", "description": "Absolute path to the SQLite file." },
        \\    "sql": { "type": "string", "description": "SQL to run. Must be a SELECT / PRAGMA / EXPLAIN / WITH - write statements are rejected." },
        \\    "params": { "type": "array", "description": "Optional bind params for ? placeholders." },
        \\    "max_rows": { "type": "integer", "description": "Cap rows returned (default 200)." }
        \\  },
        \\  "required": ["db", "sql"]
        \\}
        ,
        .handler = handleQuery,
    },
    .{
        .name = "sqlite_exec",
        .description = "Run a write statement (INSERT / UPDATE / DELETE / CREATE / DROP / PRAGMA write) against a .db file. Opens the DB read-write. Returns rowcount and lastInsertRowid.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "db": { "type": "string", "description": "Absolute path to the SQLite file." },
        \\    "sql": { "type": "string", "description": "SQL to run." },
        \\    "params": { "type": "array", "description": "Optional bind params for ? placeholders." }
        \\  },
        \\  "required": ["db", "sql"]
        \\}
        ,
        .handler = handleExec,
        .destructive = true,
    },
    .{
        .name = "sqlite_schema",
        .description = "Dump the schema of a SQLite database: tables with columns + types + PK/NN flags, plus indexes.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "db": { "type": "string", "description": "Absolute path to the SQLite file." }
        \\  },
        \\  "required": ["db"]
        \\}
        ,
        .handler = handleSchema,
    },
};

const RunResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
};

const TableInfoRow = struct {
    name: []const u8,
    typ: []const u8,
    notnull: i64,
    dflt_value: ?[]const u8,
    pk: i64,
};

const IndexListRow = struct {
    name: []const u8,
    unique: i64,
    origin: []const u8,
};

const IndexInfoRow = struct {
    name: []const u8,
};

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

fn getParams(args: std.json.Value) ?std.json.Array {
    if (args != .object) return null;
    const v = args.object.get("params") orelse return null;
    return if (v == .array) v.array else null;
}

fn isReadOnlySql(sql: []const u8) bool {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.heap.page_allocator);

    var i: usize = 0;
    while (i < sql.len) {
        if (i + 1 < sql.len and sql[i] == '-' and sql[i + 1] == '-') {
            i += 2;
            while (i < sql.len and sql[i] != '\n') : (i += 1) {}
            continue;
        }
        if (i + 1 < sql.len and sql[i] == '/' and sql[i + 1] == '*') {
            i += 2;
            while (i + 1 < sql.len and !(sql[i] == '*' and sql[i + 1] == '/')) : (i += 1) {}
            if (i + 1 < sql.len) i += 2;
            continue;
        }
        out.append(std.heap.page_allocator, sql[i]) catch return false;
        i += 1;
    }

    const stripped = std.mem.trim(u8, out.items, " \t\r\n");
    if (stripped.len == 0) return false;
    // The script is run through sqlite3's `.read`, which also executes dot-commands
    // (.shell, .system, .import ...) found at the start of any line. Reject them.
    var lines = std.mem.splitScalar(u8, out.items, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trimStart(u8, line, " \t\r");
        if (t.len > 0 and t[0] == '.') return false;
    }
    const first_end = std.mem.indexOfAny(u8, stripped, " \t\r\n") orelse stripped.len;
    const first = stripped[0..first_end];
    return std.ascii.eqlIgnoreCase(first, "SELECT") or
        std.ascii.eqlIgnoreCase(first, "PRAGMA") or
        std.ascii.eqlIgnoreCase(first, "EXPLAIN") or
        std.ascii.eqlIgnoreCase(first, "WITH");
}

fn tempRoot(alloc: std.mem.Allocator) ![]u8 {
    for ([_][]const u8{ "TEMP", "TMP", "TMPDIR" }) |key| {
        if (envOwned(alloc, key)) |v| return v;
    }
    return alloc.dupe(u8, if (@import("builtin").os.tag == .windows) "." else "/tmp");
}

fn tempPath(alloc: std.mem.Allocator, io: Io, stem: []const u8, ext: []const u8) ![]u8 {
    const root = try tempRoot(alloc);
    defer alloc.free(root);
    const ts = Io.Timestamp.now(io, .real).toMilliseconds();
    return std.fmt.allocPrint(alloc, "{s}/zmcp-{s}-{d}.{s}", .{ root, stem, ts, ext });
}

fn writeTempFile(io: Io, path: []const u8, data: []const u8) !void {
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = data });
}

fn sqliteBin(alloc: std.mem.Allocator) ![]u8 {
    if (envOwned(alloc, "SQLITE3_BIN")) |v| return v;
    return alloc.dupe(u8, "sqlite3");
}

fn runCapture(
    alloc: std.mem.Allocator,
    io: Io,
    argv: []const []const u8,
) !RunResult {
    const result = try std.process.run(alloc, io, .{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024 * 16),
        .stderr_limit = .limited(1024 * 1024 * 8),
    });
    return .{ .term = result.term, .stdout = result.stdout, .stderr = result.stderr };
}

fn isExitedZero(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn trimLineEndings(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and (s[end - 1] == '\r' or s[end - 1] == '\n')) : (end -= 1) {}
    return s[0..end];
}

fn identifierLiteral(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '"');
    for (name) |c| {
        if (c == '"') {
            try out.appendSlice(alloc, "\"\"");
        } else {
            try out.append(alloc, c);
        }
    }
    try out.append(alloc, '"');
    return out.toOwnedSlice(alloc);
}

fn sqlLiteral(alloc: std.mem.Allocator, v: std.json.Value) ![]u8 {
    return switch (v) {
        .null => alloc.dupe(u8, "NULL"),
        .bool => |b| alloc.dupe(u8, if (b) "1" else "0"),
        .integer => |i| std.fmt.allocPrint(alloc, "{d}", .{i}),
        .float => |f| std.fmt.allocPrint(alloc, "{d}", .{f}),
        .string => |s| quotedTextLiteral(alloc, s),
        else => blk: {
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            try std.json.Stringify.value(v, .{}, &out.writer);
            break :blk try quotedTextLiteral(alloc, out.written());
        },
    };
}

fn quotedTextLiteral(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '\'');
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(alloc, "''");
        } else {
            try out.append(alloc, c);
        }
    }
    try out.append(alloc, '\'');
    return out.toOwnedSlice(alloc);
}

fn scriptWithParams(
    alloc: std.mem.Allocator,
    sql: []const u8,
    params_opt: ?std.json.Array,
    trailer: ?[]const u8,
) ![]u8 {
    const rendered_sql = try substituteParams(alloc, sql, params_opt);
    defer alloc.free(rendered_sql);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll(rendered_sql);
    if (!std.mem.endsWith(u8, sql, "\n")) try out.writer.writeByte('\n');
    if (trailer) |tail| {
        try out.writer.writeAll(tail);
        if (!std.mem.endsWith(u8, tail, "\n")) try out.writer.writeByte('\n');
    }
    return out.toOwnedSlice();
}

fn substituteParams(alloc: std.mem.Allocator, sql: []const u8, params_opt: ?std.json.Array) ![]u8 {
    if (params_opt == null or params_opt.?.items.len == 0) return alloc.dupe(u8, sql);
    const params = params_opt.?;

    var rendered: std.ArrayList([]u8) = .empty;
    defer {
        for (rendered.items) |item| alloc.free(item);
        rendered.deinit(alloc);
    }
    for (params.items) |param| {
        try rendered.append(alloc, try sqlLiteral(alloc, param));
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    var bare_idx: usize = 0;
    while (i < sql.len) {
        if (sql[i] == '\'') {
            try out.append(alloc, sql[i]);
            i += 1;
            while (i < sql.len) {
                try out.append(alloc, sql[i]);
                if (sql[i] == '\'') {
                    if (i + 1 < sql.len and sql[i + 1] == '\'') {
                        try out.append(alloc, sql[i + 1]);
                        i += 2;
                        continue;
                    }
                    i += 1;
                    break;
                }
                i += 1;
            }
            continue;
        }
        if (i + 1 < sql.len and sql[i] == '-' and sql[i + 1] == '-') {
            try out.appendSlice(alloc, "--");
            i += 2;
            while (i < sql.len) {
                try out.append(alloc, sql[i]);
                if (sql[i] == '\n') {
                    i += 1;
                    break;
                }
                i += 1;
            }
            continue;
        }
        if (i + 1 < sql.len and sql[i] == '/' and sql[i + 1] == '*') {
            try out.appendSlice(alloc, "/*");
            i += 2;
            while (i < sql.len) {
                try out.append(alloc, sql[i]);
                if (i + 1 < sql.len and sql[i] == '*' and sql[i + 1] == '/') {
                    try out.append(alloc, sql[i + 1]);
                    i += 2;
                    break;
                }
                i += 1;
            }
            continue;
        }
        if (sql[i] == '?') {
            var j = i + 1;
            while (j < sql.len and std.ascii.isDigit(sql[j])) : (j += 1) {}
            if (j > i + 1) {
                const idx_1 = std.fmt.parseInt(usize, sql[i + 1 .. j], 10) catch 0;
                if (idx_1 >= 1 and idx_1 <= rendered.items.len) {
                    try out.appendSlice(alloc, rendered.items[idx_1 - 1]);
                    i = j;
                    continue;
                }
            } else if (bare_idx < rendered.items.len) {
                try out.appendSlice(alloc, rendered.items[bare_idx]);
                bare_idx += 1;
                i += 1;
                continue;
            }
        }
        try out.append(alloc, sql[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

fn runSqlScript(
    alloc: std.mem.Allocator,
    io: Io,
    db: []const u8,
    readonly: bool,
    script: []const u8,
    json_mode: bool,
) !RunResult {
    const sql_path = try tempPath(alloc, io, "sqlite", "sql");
    defer std.Io.Dir.deleteFile(.cwd(), io, sql_path) catch {};
    defer alloc.free(sql_path);
    try writeTempFile(io, sql_path, script);

    const sqlite = try sqliteBin(alloc);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, sqlite);
    try argv.append(alloc, "-batch");
    try argv.append(alloc, "-bail");
    if (json_mode) try argv.append(alloc, "-json");
    if (readonly) try argv.append(alloc, "-readonly");
    try argv.append(alloc, "--");
    try argv.append(alloc, db);
    const read_cmd = try std.fmt.allocPrint(alloc, ".read {s}", .{sql_path});
    defer alloc.free(read_cmd);
    try argv.append(alloc, read_cmd);

    return runCapture(alloc, io, argv.items);
}

fn prettyJson(alloc: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &out.writer);
    return out.toOwnedSlice();
}

fn parseJsonValue(alloc: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    const trimmed = trimLineEndings(bytes);
    if (trimmed.len == 0) return std.json.parseFromSlice(std.json.Value, alloc, "[]", .{});
    return std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{});
}

fn handleQuery(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const db = getStr(args, "db") orelse return .{ .text = "db and sql are required", .is_error = true };
    const sql = getStr(args, "sql") orelse return .{ .text = "db and sql are required", .is_error = true };
    if (!isReadOnlySql(sql)) {
        return .{ .text = "sqlite_query only accepts SELECT / PRAGMA / EXPLAIN / WITH. Use sqlite_exec for writes.", .is_error = true };
    }
    const max_rows_raw = getInt(args, "max_rows", DEFAULT_MAX_ROWS);
    const max_rows: usize = @intCast(@max(max_rows_raw, 0));
    const params = getParams(args);

    const script = try scriptWithParams(alloc, sql, params, null);
    defer alloc.free(script);
    const result = try runSqlScript(alloc, io, db, true, script, true);
    if (!isExitedZero(result.term)) {
        const msg = if (result.stderr.len > 0) trimLineEndings(result.stderr) else "sqlite_query failed";
        return .{ .text = try std.fmt.allocPrint(alloc, "sqlite_query failed: {s}", .{msg}), .is_error = true };
    }

    const parsed = parseJsonValue(alloc, result.stdout) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "sqlite_query failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    defer parsed.deinit();
    if (parsed.value != .array) {
        return .{ .text = "sqlite_query failed: unexpected sqlite3 JSON shape", .is_error = true };
    }

    const row_count = parsed.value.array.items.len;
    var render_arr: std.json.Array = .init(alloc);
    const keep = @min(row_count, max_rows);
    for (parsed.value.array.items[0..keep]) |item| try render_arr.append(item);
    const body = try prettyJson(alloc, .{ .array = render_arr });
    const truncated = if (row_count > keep)
        try std.fmt.allocPrint(alloc, "\n\n(+ {d} rows truncated)", .{row_count - keep})
    else
        try alloc.dupe(u8, "");
    return .{ .text = try std.fmt.allocPrint(alloc, "{d} row(s):\n{s}{s}", .{ row_count, body, truncated }) };
}

fn handleExec(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const db = getStr(args, "db") orelse return .{ .text = "db and sql are required", .is_error = true };
    const sql = getStr(args, "sql") orelse return .{ .text = "db and sql are required", .is_error = true };
    const params = getParams(args);

    const trailer =
        \\SELECT changes() AS changes, last_insert_rowid() AS lastInsertRowid;
    ;
    const script = try scriptWithParams(alloc, sql, params, trailer);
    defer alloc.free(script);
    const result = try runSqlScript(alloc, io, db, false, script, true);
    if (!isExitedZero(result.term)) {
        const msg = if (result.stderr.len > 0) trimLineEndings(result.stderr) else "sqlite_exec failed";
        return .{ .text = try std.fmt.allocPrint(alloc, "sqlite_exec failed: {s}", .{msg}), .is_error = true };
    }

    const parsed = parseJsonValue(alloc, result.stdout) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "sqlite_exec failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    defer parsed.deinit();
    if (parsed.value != .array or parsed.value.array.items.len == 0 or parsed.value.array.items[0] != .object) {
        return .{ .text = "sqlite_exec failed: unexpected sqlite3 JSON shape", .is_error = true };
    }
    const row = parsed.value.array.items[0].object;
    const changes = jInt(row, "changes");
    const last = jInt(row, "lastInsertRowid");
    return .{ .text = try std.fmt.allocPrint(alloc, "changes={d} lastInsertRowid={d}", .{ changes, last }) };
}

fn queryJsonRows(alloc: std.mem.Allocator, io: Io, db: []const u8, sql: []const u8) !std.json.Parsed(std.json.Value) {
    const result = try runSqlScript(alloc, io, db, true, sql, true);
    if (!isExitedZero(result.term)) return error.QueryFailed;
    return parseJsonValue(alloc, result.stdout);
}

fn jStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn jInt(obj: std.json.ObjectMap, key: []const u8) i64 {
    const v = obj.get(key) orelse return 0;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}

fn jNullableStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .null => null,
        .string => |s| s,
        else => null,
    };
}

fn handleSchema(alloc: std.mem.Allocator, io: Io, args: std.json.Value) !mcp.ToolResult {
    const db = getStr(args, "db") orelse return .{ .text = "db is required", .is_error = true };

    var tables_parsed = queryJsonRows(
        alloc,
        io,
        db,
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;\n",
    ) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "sqlite_schema failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    defer tables_parsed.deinit();
    if (tables_parsed.value != .array) return .{ .text = "sqlite_schema failed: unexpected sqlite3 JSON shape", .is_error = true };
    if (tables_parsed.value.array.items.len == 0) return .{ .text = "(no user tables)" };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    for (tables_parsed.value.array.items) |table_v| {
        if (table_v != .object) continue;
        const table_name = jStr(table_v.object, "name") orelse continue;
        try out.writer.print("TABLE {s}\n", .{table_name});

        const quoted_table = try identifierLiteral(alloc, table_name);
        defer alloc.free(quoted_table);

        const pragma_sql = try std.fmt.allocPrint(alloc, "PRAGMA table_info({s});\n", .{quoted_table});
        defer alloc.free(pragma_sql);
        var cols_parsed = queryJsonRows(alloc, io, db, pragma_sql) catch |err| {
            return .{ .text = try std.fmt.allocPrint(alloc, "sqlite_schema failed: {s}", .{@errorName(err)}), .is_error = true };
        };
        defer cols_parsed.deinit();
        if (cols_parsed.value == .array) {
            for (cols_parsed.value.array.items) |col_v| {
                if (col_v != .object) continue;
                const row = TableInfoRow{
                    .name = jStr(col_v.object, "name") orelse "",
                    .typ = jStr(col_v.object, "type") orelse "",
                    .notnull = jInt(col_v.object, "notnull"),
                    .dflt_value = jNullableStr(col_v.object, "dflt_value"),
                    .pk = jInt(col_v.object, "pk"),
                };
                try out.writer.print("  {s} {s}", .{ row.name, row.typ });
                var any_flag = false;
                if (row.pk != 0 or row.notnull != 0) {
                    try out.writer.writeAll(" [");
                    if (row.pk != 0) {
                        try out.writer.writeAll("PK");
                        any_flag = true;
                    }
                    if (row.notnull != 0) {
                        if (any_flag) try out.writer.writeAll(",");
                        try out.writer.writeAll("NN");
                    }
                    try out.writer.writeAll("]");
                }
                if (row.dflt_value) |dflt| try out.writer.print(" DEFAULT {s}", .{dflt});
                try out.writer.writeByte('\n');
            }
        }

        const idx_sql = try std.fmt.allocPrint(alloc, "PRAGMA index_list({s});\n", .{quoted_table});
        defer alloc.free(idx_sql);
        var idx_parsed = queryJsonRows(alloc, io, db, idx_sql) catch |err| {
            return .{ .text = try std.fmt.allocPrint(alloc, "sqlite_schema failed: {s}", .{@errorName(err)}), .is_error = true };
        };
        defer idx_parsed.deinit();
        if (idx_parsed.value == .array) {
            for (idx_parsed.value.array.items) |idx_v| {
                if (idx_v != .object) continue;
                const idx_row = IndexListRow{
                    .name = jStr(idx_v.object, "name") orelse "",
                    .unique = jInt(idx_v.object, "unique"),
                    .origin = jStr(idx_v.object, "origin") orelse "",
                };
                if (std.mem.eql(u8, idx_row.origin, "pk")) continue;

                const quoted_idx = try identifierLiteral(alloc, idx_row.name);
                defer alloc.free(quoted_idx);
                const idx_info_sql = try std.fmt.allocPrint(alloc, "PRAGMA index_info({s});\n", .{quoted_idx});
                defer alloc.free(idx_info_sql);
                var idx_info_parsed = queryJsonRows(alloc, io, db, idx_info_sql) catch |err| {
                    return .{ .text = try std.fmt.allocPrint(alloc, "sqlite_schema failed: {s}", .{@errorName(err)}), .is_error = true };
                };
                defer idx_info_parsed.deinit();

                try out.writer.print("  INDEX {s}", .{idx_row.name});
                if (idx_row.unique != 0) try out.writer.writeAll(" UNIQUE");
                try out.writer.writeAll(" (");
                if (idx_info_parsed.value == .array) {
                    for (idx_info_parsed.value.array.items, 0..) |idx_col_v, col_idx| {
                        if (idx_col_v != .object) continue;
                        const idx_col = IndexInfoRow{ .name = jStr(idx_col_v.object, "name") orelse "" };
                        if (col_idx > 0) try out.writer.writeAll(", ");
                        try out.writer.writeAll(idx_col.name);
                    }
                }
                try out.writer.writeAll(")\n");
            }
        }
        try out.writer.writeByte('\n');
    }

    return .{ .text = trimLineEndings(out.written()) };
}

test "isReadOnlySql rejects dot-commands hidden on later lines" {
    try std.testing.expect(isReadOnlySql("SELECT 1"));
    try std.testing.expect(isReadOnlySql("select 1.5 as x -- comment"));
    try std.testing.expect(!isReadOnlySql("SELECT 1;\n.shell id"));
    try std.testing.expect(!isReadOnlySql("SELECT 1;\n  .system id"));
    try std.testing.expect(!isReadOnlySql("SELECT 1;\r\n\t.import /etc/passwd t"));
}

test "env lookup reads the real process environment (not an empty block)" {
    const alloc = std.testing.allocator;
    g_env_io = std.testing.io;
    defer g_env_io = null;
    const v = envOwned(alloc, "PATH") orelse return error.SkipZigTest;
    defer alloc.free(v);
    try std.testing.expect(v.len > 0);
    try std.testing.expect(envOwned(alloc, "ZMCP_SURELY_UNSET_ENV_VAR_12345") == null);
}
