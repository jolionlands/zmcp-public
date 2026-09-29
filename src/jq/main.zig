//! zmcp-jq - native JSON query / validate / format / summarize tools.
//!
//! No dependency on the `jq` binary: a small jq-style filter language is
//! parsed and evaluated in Zig on top of std.json.
//!
//! Tools: json_query, json_validate, json_format, json_keys, json_schema_infer.
//! Every tool takes either `json` (JSON text) or `path` (a file to read);
//! files are only read when `path` is given.
//!
//! Supported jq subset (anything else is rejected with an error, never guessed):
//!   .                identity
//!   .a  .a.b  ."a b" field access (missing key or null input gives null)
//!   .[n]  .[-1]      array index (negative counts from the end)
//!   .[]  .a[]        iterate array elements / object values
//!   .[m:n]           slice of an array or string; m and n optional, may be negative
//!   f | g            pipe
//!   select(.x OP v)  keep input when the condition holds; OP is == != < <= > >=
//!                    and v is a JSON literal or another simple path such as .y.
//!                    `select(.x)` alone keeps inputs where .x is not null/false.
//!   keys  length     sorted keys (or array indices); size of string/array/object
//!   map(f)           apply the pipeline f to every element, collect into an array
//!   has("k")  has(n) key present in object / index in range for array
//! Not supported: `,` `..` `?` `//` arithmetic and/or/not, variables, object or
//! array construction, functions other than the ones above, `(` grouping.

const std = @import("std");
const mcp = @import("mcp");

const Value = std.json.Value;

/// Cap on JSON text accepted from `json` or read from `path`.
const MAX_INPUT_BYTES: usize = 8 * 1024 * 1024;
/// Cap on the text returned by any tool.
const MAX_OUTPUT_BYTES: usize = 512 * 1024;
/// Deepest container nesting accepted in an input document.
const MAX_JSON_DEPTH: usize = 256;
/// Deepest filter nesting (map(...) inside map(...)).
const MAX_FILTER_DEPTH: usize = 16;
/// Cap on any intermediate result list while evaluating a filter.
const MAX_INTERMEDIATE_RESULTS: usize = 200_000;
/// Cap on evaluation work (iterated elements) for one query.
const MAX_EVAL_STEPS: usize = 20_000_000;
const DEFAULT_MAX_RESULTS: i64 = 200;
const HARD_MAX_RESULTS: i64 = 10_000;
const MAX_KEYS_PER_OBJECT: usize = 100;
const MAX_SUMMARY_LINES: usize = 500;
const MAX_SCHEMA_PROPS: usize = 500;
const MAX_SCHEMA_ARRAY_SAMPLE: usize = 500;

pub fn main(init: std.process.Init) !void {
    try mcp.run(init.gpa, init.io, .{ .name = "zmcp-jq", .version = "0.1.0" }, &tool_table);
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "json_query",
        .read_only = true,
        .description = "Run a jq-style filter over JSON given as text (`json`) or a file (`path`). Supported subset: `.`, `.a.b`, `.[n]`, `.[]`, `.a[]`, slices `.[m:n]`, pipes `|`, select(.x == v) with == != < <= > >=, keys, length, map(...), has(\"k\"). Unsupported syntax is rejected with an error. Prints one result per line.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "json": { "type": "string", "description": "JSON text. Give either json or path." },
        \\    "path": { "type": "string", "description": "File to read the JSON from (only read when given)." },
        \\    "query": { "type": "string", "description": "jq-style filter, e.g. '.items[] | select(.n > 2) | .name'." },
        \\    "pretty": { "type": "boolean", "description": "Pretty-print each result. Default false (compact)." },
        \\    "max_results": { "type": "integer", "description": "Default 200, cap 10000." }
        \\  },
        \\  "required": ["query"]
        \\}
        ,
        .handler = handleQuery,
    },
    .{
        .name = "json_validate",
        .read_only = true,
        .description = "Check whether JSON text (`json`) or a file (`path`) is valid JSON. Reports the top-level type, size and nesting depth, or the parse error with line and column.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "json": { "type": "string", "description": "JSON text. Give either json or path." },
        \\    "path": { "type": "string", "description": "File to read the JSON from (only read when given)." }
        \\  }
        \\}
        ,
        .handler = handleValidate,
    },
    .{
        .name = "json_format",
        .read_only = true,
        .description = "Re-emit JSON (`json` or `path`) as pretty or compact text, optionally sorting object keys.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "json": { "type": "string", "description": "JSON text. Give either json or path." },
        \\    "path": { "type": "string", "description": "File to read the JSON from (only read when given)." },
        \\    "mode": { "type": "string", "description": "pretty | compact. Default pretty." },
        \\    "sort_keys": { "type": "boolean", "description": "Sort object keys recursively. Default false." },
        \\    "indent": { "type": "integer", "description": "Spaces per level in pretty mode: 1, 2, 3, 4 or 8. Default 2." }
        \\  }
        \\}
        ,
        .handler = handleFormat,
    },
    .{
        .name = "json_keys",
        .read_only = true,
        .description = "Summarize the structure of a large JSON document: key names with value types and sizes, array length and element type histogram, down to `depth` levels. Optional `query` (same filter language as json_query) picks the sub-document; it must yield exactly one value.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "json": { "type": "string", "description": "JSON text. Give either json or path." },
        \\    "path": { "type": "string", "description": "File to read the JSON from (only read when given)." },
        \\    "query": { "type": "string", "description": "Optional filter selecting one sub-document, e.g. '.data.users'." },
        \\    "depth": { "type": "integer", "description": "Levels to descend. Default 1, max 6." }
        \\  }
        \\}
        ,
        .handler = handleKeys,
    },
    .{
        .name = "json_schema_infer",
        .read_only = true,
        .description = "Infer a JSON-Schema-like description of a JSON document: types per position, object properties with `required` (present in every sampled object), array `items` merged across elements. Large arrays are sampled. Optional `query` picks a sub-document.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "json": { "type": "string", "description": "JSON text. Give either json or path." },
        \\    "path": { "type": "string", "description": "File to read the JSON from (only read when given)." },
        \\    "query": { "type": "string", "description": "Optional filter selecting one sub-document." },
        \\    "max_depth": { "type": "integer", "description": "Nesting levels to describe. Default 6, max 20." }
        \\  }
        \\}
        ,
        .handler = handleSchemaInfer,
    },
};

// ---------------------------------------------------------------------------
// Errors and context
// ---------------------------------------------------------------------------

/// `Failed` carries a user-facing message in `Ctx.msg`.
const Err = error{ Failed, OutOfMemory };

const Ctx = struct {
    alloc: std.mem.Allocator,
    msg: ?[]const u8 = null,
    steps: usize = 0,
};

fn fail(ctx: *Ctx, comptime fmt: []const u8, args: anytype) Err {
    ctx.msg = std.fmt.allocPrint(ctx.alloc, fmt, args) catch return error.OutOfMemory;
    return error.Failed;
}

fn tick(ctx: *Ctx) Err!void {
    ctx.steps += 1;
    if (ctx.steps > MAX_EVAL_STEPS) return fail(ctx, "query aborted: evaluation work limit ({d} steps) exceeded", .{MAX_EVAL_STEPS});
}

/// Convert an implementation result into a ToolResult: Failed becomes an
/// is_error result carrying the message, OutOfMemory propagates.
fn finish(ctx: *Ctx, r: Err!mcp.ToolResult) anyerror!mcp.ToolResult {
    return r catch |e| switch (e) {
        error.Failed => .{ .text = ctx.msg orelse "error", .is_error = true },
        error.OutOfMemory => e,
    };
}

// ---------------------------------------------------------------------------
// Argument helpers
// ---------------------------------------------------------------------------

fn getArg(args: Value, key: []const u8) ?Value {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    if (v == .null) return null;
    return v;
}

fn getStr(args: Value, key: []const u8) ?[]const u8 {
    const v = getArg(args, key) orelse return null;
    return if (v == .string) v.string else null;
}

fn getBool(args: Value, key: []const u8, default: bool) bool {
    const v = getArg(args, key) orelse return default;
    return if (v == .bool) v.bool else default;
}

fn getInt(args: Value, key: []const u8, default: i64) i64 {
    const v = getArg(args, key) orelse return default;
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f) and @abs(f) < 1e15) @intFromFloat(f) else default,
        else => default,
    };
}

/// Return the JSON text from `json` or `path` (exactly one must be given).
fn loadInput(ctx: *Ctx, io: std.Io, args: Value) Err![]const u8 {
    if (args != .object) return fail(ctx, "arguments must be an object with `json` or `path`", .{});
    const json_v = getArg(args, "json");
    const path_v = getArg(args, "path");
    if (json_v != null and path_v != null) return fail(ctx, "give either `json` or `path`, not both", .{});
    if (json_v == null and path_v == null) return fail(ctx, "missing input: give `json` (JSON text) or `path` (file to read)", .{});

    if (json_v) |jv| {
        const text = switch (jv) {
            .string => |s| s,
            // Tolerate callers that pass the document inline as JSON.
            .array, .object => std.json.Stringify.valueAlloc(ctx.alloc, jv, .{}) catch return error.OutOfMemory,
            else => return fail(ctx, "`json` must be a string containing JSON text", .{}),
        };
        if (text.len > MAX_INPUT_BYTES) return fail(ctx, "input too large: {d} bytes (limit {d})", .{ text.len, MAX_INPUT_BYTES });
        return text;
    }

    const p = path_v.?;
    if (p != .string or p.string.len == 0) return fail(ctx, "`path` must be a non-empty string", .{});
    const data = std.Io.Dir.cwd().readFileAlloc(io, p.string, ctx.alloc, .limited(MAX_INPUT_BYTES)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return fail(ctx, "file too large: {s} exceeds {d} bytes", .{ p.string, MAX_INPUT_BYTES }),
        else => return fail(ctx, "cannot read file '{s}': {s}", .{ p.string, @errorName(err) }),
    };
    return data;
}

// ---------------------------------------------------------------------------
// JSON document parsing
// ---------------------------------------------------------------------------

const ParseResult = union(enum) {
    ok: Value,
    err: []const u8,
};

/// Deepest container nesting in `text`, string-aware; stops early past `limit`.
fn nestingDepth(text: []const u8, limit: usize) usize {
    var depth: usize = 0;
    var max: usize = 0;
    var in_str = false;
    var esc = false;
    for (text) |c| {
        if (in_str) {
            if (esc) {
                esc = false;
            } else if (c == '\\') {
                esc = true;
            } else if (c == '"') {
                in_str = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '[', '{' => {
                depth += 1;
                if (depth > max) max = depth;
                if (max > limit) return max;
            },
            ']', '}' => {
                if (depth > 0) depth -= 1;
            },
            else => {},
        }
    }
    return max;
}

fn parseDoc(alloc: std.mem.Allocator, text_in: []const u8) std.mem.Allocator.Error!ParseResult {
    var text = text_in;
    if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text = text[3..];

    const depth = nestingDepth(text, MAX_JSON_DEPTH);
    if (depth > MAX_JSON_DEPTH) {
        return .{ .err = try std.fmt.allocPrint(alloc, "nesting too deep (limit {d} levels)", .{MAX_JSON_DEPTH}) };
    }

    var scanner = std.json.Scanner.initCompleteInput(alloc, text);
    defer scanner.deinit();
    var diag: std.json.Scanner.Diagnostics = .{};
    scanner.enableDiagnostics(&diag);
    const v = std.json.parseFromTokenSourceLeaky(Value, alloc, &scanner, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .err = try std.fmt.allocPrint(
            alloc,
            "{s} at line {d}, column {d} (byte {d})",
            .{ @errorName(e), diag.getLine(), diag.getColumn(), diag.getByteOffset() },
        ) },
    };
    return .{ .ok = v };
}

/// Parse or fail with a "invalid JSON: ..." message.
fn parseOrFail(ctx: *Ctx, text: []const u8) Err!Value {
    const r = try parseDoc(ctx.alloc, text);
    return switch (r) {
        .ok => |v| v,
        .err => |m| fail(ctx, "invalid JSON: {s}", .{m}),
    };
}

fn typeName(v: Value) []const u8 {
    return switch (v) {
        .null => "null",
        .bool => "boolean",
        .integer => "integer",
        .float, .number_string => "number",
        .string => "string",
        .array => "array",
        .object => "object",
    };
}

/// jq-style error wording uses "number" for both numeric kinds.
fn jqTypeName(v: Value) []const u8 {
    return switch (v) {
        .integer, .float, .number_string => "number",
        else => typeName(v),
    };
}

// ---------------------------------------------------------------------------
// Filter AST and parser
// ---------------------------------------------------------------------------

const Slice = struct { from: ?i64, to: ?i64 };

const Step = union(enum) {
    field: []const u8,
    index: i64,
    iterate,
    slice: Slice,
};

const CmpOp = enum { eq, ne, lt, le, gt, ge };

const Operand = union(enum) {
    path: []const Step,
    literal: Value,
};

const Cond = struct {
    lhs: []const Step,
    cmp: ?struct { op: CmpOp, rhs: Operand },
};

const HasArg = union(enum) {
    key: []const u8,
    index: i64,
};

const Stage = union(enum) {
    path: []const Step,
    select: Cond,
    keys,
    length,
    has: HasArg,
    map: []const Stage,
};

const SUPPORTED_HINT = "supported: . .a.b .[n] .[] .[m:n] | select(.x OP v) keys length map(...) has(\"k\")";

const Parser = struct {
    ctx: *Ctx,
    src: []const u8,
    pos: usize = 0,
    depth: usize = 0,

    fn alloc(self: *Parser) std.mem.Allocator {
        return self.ctx.alloc;
    }

    fn skipWs(self: *Parser) void {
        while (self.pos < self.src.len and std.ascii.isWhitespace(self.src[self.pos])) self.pos += 1;
    }

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn bad(self: *Parser, comptime what: []const u8, args: anytype) Err {
        return fail(self.ctx, "unsupported or invalid filter syntax at position {d}: " ++ what ++ " (" ++ SUPPORTED_HINT ++ ")", .{self.pos} ++ args);
    }

    fn expect(self: *Parser, c: u8) Err!void {
        self.skipWs();
        if (self.peek() == c) {
            self.pos += 1;
            return;
        }
        return self.bad("expected '{c}'", .{c});
    }

    fn isIdentStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_';
    }

    fn isIdentChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    fn parsePipeline(self: *Parser, closing: bool) Err![]const Stage {
        var list: std.ArrayList(Stage) = .empty;
        while (true) {
            self.skipWs();
            try list.append(self.alloc(), try self.parseStage());
            self.skipWs();
            const c = self.peek() orelse {
                if (closing) return self.bad("missing ')'", .{});
                break;
            };
            if (c == '|') {
                self.pos += 1;
                continue;
            }
            if (c == ')' and closing) break;
            return self.bad("unexpected '{c}'", .{c});
        }
        return list.items;
    }

    fn parseStage(self: *Parser) Err!Stage {
        const c = self.peek() orelse return self.bad("empty filter or dangling '|'", .{});
        if (c == '.') return .{ .path = try self.parsePath() };
        if (!isIdentStart(c)) return self.bad("unexpected '{c}'", .{c});

        const start = self.pos;
        while (self.pos < self.src.len and isIdentChar(self.src[self.pos])) self.pos += 1;
        const name = self.src[start..self.pos];

        if (std.mem.eql(u8, name, "keys")) return try self.noArgs(.keys, name);
        if (std.mem.eql(u8, name, "length")) return try self.noArgs(.length, name);
        if (std.mem.eql(u8, name, "select")) {
            try self.expect('(');
            const cond = try self.parseCond();
            try self.expect(')');
            return .{ .select = cond };
        }
        if (std.mem.eql(u8, name, "map")) {
            try self.expect('(');
            if (self.depth >= MAX_FILTER_DEPTH) return self.bad("map() nested too deeply", .{});
            self.depth += 1;
            const inner = try self.parsePipeline(true);
            self.depth -= 1;
            try self.expect(')');
            return .{ .map = inner };
        }
        if (std.mem.eql(u8, name, "has")) {
            try self.expect('(');
            self.skipWs();
            const lit = try self.parseLiteral();
            try self.expect(')');
            return switch (lit) {
                .string => |s| .{ .has = .{ .key = s } },
                .integer => |i| .{ .has = .{ .index = i } },
                else => self.bad("has() takes a string key or integer index", .{}),
            };
        }
        self.pos = start;
        return self.bad("unsupported function or keyword '{s}'", .{name});
    }

    fn noArgs(self: *Parser, stage: Stage, name: []const u8) Err!Stage {
        if (self.peek() == '(') return self.bad("'{s}' takes no arguments", .{name});
        return stage;
    }

    fn parsePath(self: *Parser) Err![]const Step {
        std.debug.assert(self.src[self.pos] == '.');
        self.pos += 1;
        if (self.peek() == '.') return self.bad("recursive descent '..' is not supported", .{});
        var steps: std.ArrayList(Step) = .empty;
        var field_ok = true; // just consumed a '.'
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (field_ok and (isIdentStart(c) or c == '"')) {
                try steps.append(self.alloc(), .{ .field = try self.parseFieldName() });
                field_ok = false;
            } else if (c == '[') {
                try steps.append(self.alloc(), try self.parseBracket());
                field_ok = false;
            } else if (c == '.' and !field_ok) {
                self.pos += 1;
                field_ok = true;
                if (self.peek() == '.') return self.bad("recursive descent '..' is not supported", .{});
            } else break;
        }
        if (field_ok and steps.items.len > 0) return self.bad("dangling '.' at end of path", .{});
        return steps.items;
    }

    fn parseFieldName(self: *Parser) Err![]const u8 {
        if (self.src[self.pos] == '"') return self.parseStringLiteral();
        const start = self.pos;
        while (self.pos < self.src.len and isIdentChar(self.src[self.pos])) self.pos += 1;
        return self.src[start..self.pos];
    }

    fn parseStringLiteral(self: *Parser) Err![]const u8 {
        const start = self.pos;
        std.debug.assert(self.src[start] == '"');
        var i = start + 1;
        while (i < self.src.len) : (i += 1) {
            if (self.src[i] == '\\') {
                i += 1;
                continue;
            }
            if (self.src[i] == '"') {
                const raw = self.src[start .. i + 1];
                const s = std.json.parseFromSliceLeaky([]const u8, self.alloc(), raw, .{}) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return self.bad("invalid string literal", .{}),
                };
                self.pos = i + 1;
                return s;
            }
        }
        return self.bad("unterminated string literal", .{});
    }

    fn parseOptInt(self: *Parser) Err!?i64 {
        self.skipWs();
        const start = self.pos;
        if (self.peek() == '-') self.pos += 1;
        const digits = self.pos;
        while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) self.pos += 1;
        if (self.pos == digits) {
            self.pos = start;
            return null;
        }
        return std.fmt.parseInt(i64, self.src[start..self.pos], 10) catch self.bad("integer out of range", .{});
    }

    fn parseBracket(self: *Parser) Err!Step {
        self.pos += 1; // '['
        self.skipWs();
        if (self.peek() == ']') {
            self.pos += 1;
            return .iterate;
        }
        if (self.peek() == '"') {
            const name = try self.parseStringLiteral();
            try self.expect(']');
            return .{ .field = name };
        }
        const from = try self.parseOptInt();
        self.skipWs();
        if (self.peek() == ':') {
            self.pos += 1;
            const to = try self.parseOptInt();
            try self.expect(']');
            return .{ .slice = .{ .from = from, .to = to } };
        }
        const idx = from orelse return self.bad("expected index, slice, string key or ']' inside []", .{});
        try self.expect(']');
        return .{ .index = idx };
    }

    fn parseLiteral(self: *Parser) Err!Value {
        self.skipWs();
        const c = self.peek() orelse return self.bad("expected a value", .{});
        if (c == '"') return .{ .string = try self.parseStringLiteral() };
        if (c == '-' or std.ascii.isDigit(c)) {
            const start = self.pos;
            while (self.pos < self.src.len and std.mem.indexOfScalar(u8, "0123456789+-.eE", self.src[self.pos]) != null) self.pos += 1;
            const tok = self.src[start..self.pos];
            if (std.fmt.parseInt(i64, tok, 10)) |i| return .{ .integer = i } else |_| {}
            const f = std.fmt.parseFloat(f64, tok) catch {
                self.pos = start;
                return self.bad("invalid number '{s}'", .{tok});
            };
            if (!std.math.isFinite(f)) {
                self.pos = start;
                return self.bad("number out of range '{s}'", .{tok});
            }
            return .{ .float = f };
        }
        if (isIdentStart(c)) {
            const start = self.pos;
            while (self.pos < self.src.len and isIdentChar(self.src[self.pos])) self.pos += 1;
            const word = self.src[start..self.pos];
            if (std.mem.eql(u8, word, "true")) return .{ .bool = true };
            if (std.mem.eql(u8, word, "false")) return .{ .bool = false };
            if (std.mem.eql(u8, word, "null")) return .null;
            self.pos = start;
            return self.bad("unsupported bare word '{s}' (strings need double quotes)", .{word});
        }
        return self.bad("unexpected '{c}' where a value was expected", .{c});
    }

    fn checkOperandPath(self: *Parser, steps: []const Step) Err!void {
        for (steps) |s| {
            if (s == .iterate) return self.bad("`.[]` is not allowed inside a select() condition", .{});
        }
    }

    fn parseCond(self: *Parser) Err!Cond {
        self.skipWs();
        if (self.peek() != '.') return self.bad("select() expects a path like .field on the left", .{});
        const lhs = try self.parsePath();
        try self.checkOperandPath(lhs);
        self.skipWs();
        if (self.peek() == ')') return .{ .lhs = lhs, .cmp = null };

        const rest = self.src[self.pos..];
        var op: CmpOp = undefined;
        var oplen: usize = 2;
        if (std.mem.startsWith(u8, rest, "==")) {
            op = .eq;
        } else if (std.mem.startsWith(u8, rest, "!=")) {
            op = .ne;
        } else if (std.mem.startsWith(u8, rest, "<=")) {
            op = .le;
        } else if (std.mem.startsWith(u8, rest, ">=")) {
            op = .ge;
        } else if (std.mem.startsWith(u8, rest, "<")) {
            op = .lt;
            oplen = 1;
        } else if (std.mem.startsWith(u8, rest, ">")) {
            op = .gt;
            oplen = 1;
        } else {
            return self.bad("unsupported operator in select() (only == != < <= > >= are allowed; no and/or/not/pipes)", .{});
        }
        self.pos += oplen;
        self.skipWs();
        if (self.peek() == '.') {
            const rhs = try self.parsePath();
            try self.checkOperandPath(rhs);
            return .{ .lhs = lhs, .cmp = .{ .op = op, .rhs = .{ .path = rhs } } };
        }
        const lit = try self.parseLiteral();
        return .{ .lhs = lhs, .cmp = .{ .op = op, .rhs = .{ .literal = lit } } };
    }
};

fn parseFilter(ctx: *Ctx, src: []const u8) Err![]const Stage {
    var p: Parser = .{ .ctx = ctx, .src = src };
    p.skipWs();
    if (p.pos >= src.len) return fail(ctx, "empty query (use `.` for the whole document)", .{});
    return p.parsePipeline(false);
}

// ---------------------------------------------------------------------------
// Evaluation
// ---------------------------------------------------------------------------

const ValueList = std.ArrayList(Value);

fn pushResult(ctx: *Ctx, list: *ValueList, v: Value) Err!void {
    if (list.items.len >= MAX_INTERMEDIATE_RESULTS) {
        return fail(ctx, "too many results (limit {d} per stage); narrow the query", .{MAX_INTERMEDIATE_RESULTS});
    }
    try list.append(ctx.alloc, v);
}

fn rank(v: Value) u8 {
    return switch (v) {
        .null => 0,
        .bool => |b| if (b) 2 else 1,
        .integer, .float, .number_string => 3,
        .string => 4,
        .array => 5,
        .object => 6,
    };
}

fn numToF64(v: Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch std.math.inf(f64),
        else => unreachable,
    };
}

fn numOrder(a: Value, b: Value) std.math.Order {
    if (a == .integer and b == .integer) return std.math.order(a.integer, b.integer);
    return std.math.order(numToF64(a), numToF64(b));
}

fn valuesEqual(a: Value, b: Value) bool {
    if (rank(a) != rank(b)) return false;
    switch (a) {
        .null, .bool => return true,
        .integer, .float, .number_string => return numOrder(a, b) == .eq,
        .string => |s| return std.mem.eql(u8, s, b.string),
        .array => |arr| {
            if (arr.items.len != b.array.items.len) return false;
            for (arr.items, b.array.items) |x, y| if (!valuesEqual(x, y)) return false;
            return true;
        },
        .object => |o| {
            if (o.count() != b.object.count()) return false;
            var it = o.iterator();
            while (it.next()) |e| {
                const other = b.object.get(e.key_ptr.*) orelse return false;
                if (!valuesEqual(e.value_ptr.*, other)) return false;
            }
            return true;
        },
    }
}

/// jq's cross-type ordering (null < false < true < numbers < strings); arrays
/// and objects are only comparable with `==`/`!=` here.
fn orderValues(ctx: *Ctx, a: Value, b: Value) Err!std.math.Order {
    const ra = rank(a);
    const rb = rank(b);
    if (ra != rb) return std.math.order(ra, rb);
    return switch (a) {
        .null, .bool => .eq,
        .integer, .float, .number_string => numOrder(a, b),
        .string => |s| std.mem.order(u8, s, b.string),
        .array, .object => fail(ctx, "ordering comparison (<, <=, >, >=) of arrays/objects is not supported; use == or !=", .{}),
    };
}

fn truthy(v: Value) bool {
    return switch (v) {
        .null => false,
        .bool => |b| b,
        else => true,
    };
}

fn cpCount(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if ((c & 0xC0) != 0x80) n += 1;
    }
    return n;
}

fn cpOffset(s: []const u8, idx: usize) usize {
    var cp: usize = 0;
    for (s, 0..) |c, i| {
        if ((c & 0xC0) != 0x80) {
            if (cp == idx) return i;
            cp += 1;
        }
    }
    return s.len;
}

fn resolveBound(b: ?i64, len: usize, default: usize) usize {
    const bv = b orelse return default;
    const l: i64 = @intCast(len);
    var x = bv;
    if (x < 0) x = std.math.add(i64, x, l) catch 0;
    if (x < 0) x = 0;
    if (x > l) x = l;
    return @intCast(x);
}

fn applySteps(ctx: *Ctx, steps: []const Step, idx: usize, input: Value, out: *ValueList) Err!void {
    if (idx == steps.len) return pushResult(ctx, out, input);
    try tick(ctx);
    switch (steps[idx]) {
        .field => |name| switch (input) {
            .object => |o| try applySteps(ctx, steps, idx + 1, o.get(name) orelse .null, out),
            .null => try applySteps(ctx, steps, idx + 1, .null, out),
            else => return fail(ctx, "Cannot index {s} with \"{s}\"", .{ jqTypeName(input), name }),
        },
        .index => |n| switch (input) {
            .array => |a| {
                const len: i64 = @intCast(a.items.len);
                const i = if (n < 0) std.math.add(i64, n, len) catch -1 else n;
                const v: Value = if (i >= 0 and i < len) a.items[@intCast(i)] else .null;
                try applySteps(ctx, steps, idx + 1, v, out);
            },
            .null => try applySteps(ctx, steps, idx + 1, .null, out),
            else => return fail(ctx, "Cannot index {s} with number", .{jqTypeName(input)}),
        },
        .iterate => switch (input) {
            .array => |a| for (a.items) |el| {
                try tick(ctx);
                try applySteps(ctx, steps, idx + 1, el, out);
            },
            .object => |o| for (o.values()) |el| {
                try tick(ctx);
                try applySteps(ctx, steps, idx + 1, el, out);
            },
            else => return fail(ctx, "Cannot iterate over {s}", .{jqTypeName(input)}),
        },
        .slice => |sl| switch (input) {
            .array => |a| {
                const from = resolveBound(sl.from, a.items.len, 0);
                const to = resolveBound(sl.to, a.items.len, a.items.len);
                var arr = std.json.Array.init(ctx.alloc);
                if (to > from) try arr.appendSlice(a.items[from..to]);
                try applySteps(ctx, steps, idx + 1, .{ .array = arr }, out);
            },
            .string => |s| {
                const n = cpCount(s);
                const from = resolveBound(sl.from, n, 0);
                const to = resolveBound(sl.to, n, n);
                const sub: []const u8 = if (to > from) s[cpOffset(s, from)..cpOffset(s, to)] else "";
                try applySteps(ctx, steps, idx + 1, .{ .string = sub }, out);
            },
            .null => try applySteps(ctx, steps, idx + 1, .null, out),
            else => return fail(ctx, "Cannot slice {s}", .{jqTypeName(input)}),
        },
    }
}

/// Evaluate a condition operand path; it has no iteration so it yields one value.
fn evalOperand(ctx: *Ctx, steps: []const Step, input: Value) Err!Value {
    var tmp: ValueList = .empty;
    defer tmp.deinit(ctx.alloc);
    try applySteps(ctx, steps, 0, input, &tmp);
    std.debug.assert(tmp.items.len == 1);
    return tmp.items[0];
}

fn evalCond(ctx: *Ctx, cond: Cond, input: Value) Err!bool {
    const lhs = try evalOperand(ctx, cond.lhs, input);
    const c = cond.cmp orelse return truthy(lhs);
    const rhs: Value = switch (c.rhs) {
        .path => |p| try evalOperand(ctx, p, input),
        .literal => |l| l,
    };
    return switch (c.op) {
        .eq => valuesEqual(lhs, rhs),
        .ne => !valuesEqual(lhs, rhs),
        .lt => (try orderValues(ctx, lhs, rhs)) == .lt,
        .le => (try orderValues(ctx, lhs, rhs)) != .gt,
        .gt => (try orderValues(ctx, lhs, rhs)) == .gt,
        .ge => (try orderValues(ctx, lhs, rhs)) != .lt,
    };
}

fn lessBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn applyStage(ctx: *Ctx, stage: Stage, input: Value, out: *ValueList) Err!void {
    switch (stage) {
        .path => |steps| try applySteps(ctx, steps, 0, input, out),
        .select => |cond| if (try evalCond(ctx, cond, input)) try pushResult(ctx, out, input),
        .keys => switch (input) {
            .object => |o| {
                const sorted = try ctx.alloc.dupe([]const u8, o.keys());
                std.mem.sort([]const u8, sorted, {}, lessBytes);
                var arr = std.json.Array.init(ctx.alloc);
                for (sorted) |k| try arr.append(.{ .string = k });
                try pushResult(ctx, out, .{ .array = arr });
            },
            .array => |a| {
                var arr = std.json.Array.init(ctx.alloc);
                for (0..a.items.len) |i| try arr.append(.{ .integer = @intCast(i) });
                try pushResult(ctx, out, .{ .array = arr });
            },
            else => return fail(ctx, "{s} has no keys", .{jqTypeName(input)}),
        },
        .length => {
            const n: Value = switch (input) {
                .null => .{ .integer = 0 },
                .string => |s| .{ .integer = @intCast(cpCount(s)) },
                .array => |a| .{ .integer = @intCast(a.items.len) },
                .object => |o| .{ .integer = @intCast(o.count()) },
                .integer => |i| if (i == std.math.minInt(i64)) Value{ .float = -@as(f64, @floatFromInt(i)) } else Value{ .integer = if (i < 0) -i else i },
                .float => |f| .{ .float = @abs(f) },
                .number_string => |s| if (s.len > 0 and s[0] == '-') Value{ .number_string = s[1..] } else input,
                .bool => return fail(ctx, "boolean has no length", .{}),
            };
            try pushResult(ctx, out, n);
        },
        .has => |arg| {
            const r: bool = switch (arg) {
                .key => |k| switch (input) {
                    .object => |o| o.contains(k),
                    else => return fail(ctx, "Cannot check whether {s} has a string key", .{jqTypeName(input)}),
                },
                .index => |i| switch (input) {
                    .array => |a| i >= 0 and i < a.items.len,
                    else => return fail(ctx, "Cannot check whether {s} has a number key", .{jqTypeName(input)}),
                },
            };
            try pushResult(ctx, out, .{ .bool = r });
        },
        .map => |inner| {
            var res: ValueList = .empty;
            defer res.deinit(ctx.alloc);
            switch (input) {
                .array => |a| for (a.items) |el| {
                    try tick(ctx);
                    try evalFrom(ctx, inner, 0, el, &res);
                },
                .object => |o| for (o.values()) |el| {
                    try tick(ctx);
                    try evalFrom(ctx, inner, 0, el, &res);
                },
                else => return fail(ctx, "Cannot iterate over {s} in map()", .{jqTypeName(input)}),
            }
            var arr = std.json.Array.init(ctx.alloc);
            try arr.appendSlice(res.items);
            try pushResult(ctx, out, .{ .array = arr });
        },
    }
}

fn evalFrom(ctx: *Ctx, stages: []const Stage, idx: usize, input: Value, out: *ValueList) Err!void {
    if (idx == stages.len) return pushResult(ctx, out, input);
    var tmp: ValueList = .empty;
    defer tmp.deinit(ctx.alloc);
    try applyStage(ctx, stages[idx], input, &tmp);
    for (tmp.items) |v| try evalFrom(ctx, stages, idx + 1, v, out);
}

fn runFilter(ctx: *Ctx, src: []const u8, doc: Value) Err!ValueList {
    const stages = try parseFilter(ctx, src);
    var out: ValueList = .empty;
    try evalFrom(ctx, stages, 0, doc, &out);
    return out;
}

/// Run `query` (or identity when null) and require exactly one result.
fn selectOne(ctx: *Ctx, query: ?[]const u8, doc: Value) Err!Value {
    const q = query orelse return doc;
    const res = try runFilter(ctx, q, doc);
    if (res.items.len != 1) return fail(ctx, "query must select exactly one value (got {d})", .{res.items.len});
    return res.items[0];
}

// ---------------------------------------------------------------------------
// Serialization
// ---------------------------------------------------------------------------

const Whitespace = @FieldType(std.json.Stringify.Options, "whitespace");
const WriteErr = std.json.Stringify.Error || std.mem.Allocator.Error;

const Fmt = struct {
    ws: Whitespace = .minified,
    sort_keys: bool = false,
};

const SortCtx = struct {
    keys: []const []const u8,
    fn less(self: SortCtx, a: usize, b: usize) bool {
        return std.mem.lessThan(u8, self.keys[a], self.keys[b]);
    }
};

fn writeValue(alloc: std.mem.Allocator, js: *std.json.Stringify, v: Value, sort_keys: bool) WriteErr!void {
    switch (v) {
        .array => |a| {
            try js.beginArray();
            for (a.items) |el| try writeValue(alloc, js, el, sort_keys);
            try js.endArray();
        },
        .object => |o| {
            try js.beginObject();
            const keys = o.keys();
            const vals = o.values();
            if (sort_keys) {
                const order = try alloc.alloc(usize, keys.len);
                defer alloc.free(order);
                for (order, 0..) |*x, i| x.* = i;
                std.mem.sort(usize, order, SortCtx{ .keys = keys }, SortCtx.less);
                for (order) |i| {
                    try js.objectField(keys[i]);
                    try writeValue(alloc, js, vals[i], sort_keys);
                }
            } else {
                for (keys, vals) |k, x| {
                    try js.objectField(k);
                    try writeValue(alloc, js, x, sort_keys);
                }
            }
            try js.endObject();
        },
        else => try js.write(v),
    }
}

fn renderValue(alloc: std.mem.Allocator, v: Value, f: Fmt) Err![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    var js: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = f.ws } };
    writeValue(alloc, &js, v, f.sort_keys) catch return error.OutOfMemory;
    return aw.written();
}

// ---------------------------------------------------------------------------
// json_query
// ---------------------------------------------------------------------------

fn queryText(ctx: *Ctx, doc_text: []const u8, query: []const u8, pretty: bool, max_results: usize) Err![]const u8 {
    const doc = try parseOrFail(ctx, doc_text);
    const results = try runFilter(ctx, query, doc);
    if (results.items.len == 0) return "(no results)";

    var out: std.ArrayList(u8) = .empty;
    const f: Fmt = .{ .ws = if (pretty) .indent_2 else .minified };
    var shown: usize = 0;
    var cut = false;
    var partial = false;
    for (results.items) |r| {
        if (shown >= max_results) break;
        const line = try renderValue(ctx.alloc, r, f);
        if (out.items.len + line.len + 1 > MAX_OUTPUT_BYTES) {
            if (shown == 0) {
                try out.appendSlice(ctx.alloc, line[0..MAX_OUTPUT_BYTES]);
                try out.append(ctx.alloc, '\n');
                shown = 1;
                partial = true;
            }
            cut = true;
            break;
        }
        try out.appendSlice(ctx.alloc, line);
        try out.append(ctx.alloc, '\n');
        shown += 1;
    }
    if (shown < results.items.len or partial) {
        const reason = if (cut) "output size cap" else "max_results";
        const note = try std.fmt.allocPrint(ctx.alloc, "[truncated by {s}: showing {d} of {d} results; narrow the query]\n", .{ reason, shown, results.items.len });
        try out.appendSlice(ctx.alloc, note);
    }
    return out.items;
}

fn handleQuery(alloc: std.mem.Allocator, io: std.Io, args: Value) anyerror!mcp.ToolResult {
    var ctx: Ctx = .{ .alloc = alloc };
    return finish(&ctx, queryImpl(&ctx, io, args));
}

fn queryImpl(ctx: *Ctx, io: std.Io, args: Value) Err!mcp.ToolResult {
    const query = getStr(args, "query") orelse return fail(ctx, "missing required string argument `query`", .{});
    const text = try loadInput(ctx, io, args);
    const max = std.math.clamp(getInt(args, "max_results", DEFAULT_MAX_RESULTS), 1, HARD_MAX_RESULTS);
    return .{ .text = try queryText(ctx, text, query, getBool(args, "pretty", false), @intCast(max)) };
}

// ---------------------------------------------------------------------------
// json_validate
// ---------------------------------------------------------------------------

fn validateText(ctx: *Ctx, text: []const u8) Err![]const u8 {
    const r = try parseDoc(ctx.alloc, text);
    switch (r) {
        .err => |m| return std.fmt.allocPrint(ctx.alloc, "valid: false\nerror: {s}", .{m}),
        .ok => |v| {
            const extra: []const u8 = switch (v) {
                .array => |a| try std.fmt.allocPrint(ctx.alloc, ", {d} items", .{a.items.len}),
                .object => |o| try std.fmt.allocPrint(ctx.alloc, ", {d} keys", .{o.count()}),
                else => "",
            };
            return std.fmt.allocPrint(ctx.alloc, "valid: true\ntype: {s}{s}\nsize: {d} bytes\nmax nesting depth: {d}", .{
                typeName(v), extra, text.len, nestingDepth(text, MAX_JSON_DEPTH),
            });
        },
    }
}

fn handleValidate(alloc: std.mem.Allocator, io: std.Io, args: Value) anyerror!mcp.ToolResult {
    var ctx: Ctx = .{ .alloc = alloc };
    return finish(&ctx, validateImpl(&ctx, io, args));
}

fn validateImpl(ctx: *Ctx, io: std.Io, args: Value) Err!mcp.ToolResult {
    const text = try loadInput(ctx, io, args);
    return .{ .text = try validateText(ctx, text) };
}

// ---------------------------------------------------------------------------
// json_format
// ---------------------------------------------------------------------------

fn formatText(ctx: *Ctx, text: []const u8, pretty: bool, indent: i64, sort_keys: bool) Err![]const u8 {
    const doc = try parseOrFail(ctx, text);
    const ws: Whitespace = if (!pretty) .minified else switch (indent) {
        1 => .indent_1,
        2 => .indent_2,
        3 => .indent_3,
        4 => .indent_4,
        8 => .indent_8,
        else => return fail(ctx, "indent must be one of 1, 2, 3, 4, 8", .{}),
    };
    const out = try renderValue(ctx.alloc, doc, .{ .ws = ws, .sort_keys = sort_keys });
    if (out.len > MAX_OUTPUT_BYTES) {
        return fail(ctx, "formatted output is {d} bytes, over the {d} byte cap; use json_query to extract a subset", .{ out.len, MAX_OUTPUT_BYTES });
    }
    return out;
}

fn handleFormat(alloc: std.mem.Allocator, io: std.Io, args: Value) anyerror!mcp.ToolResult {
    var ctx: Ctx = .{ .alloc = alloc };
    return finish(&ctx, formatImpl(&ctx, io, args));
}

fn formatImpl(ctx: *Ctx, io: std.Io, args: Value) Err!mcp.ToolResult {
    const text = try loadInput(ctx, io, args);
    const mode = getStr(args, "mode") orelse "pretty";
    const pretty = if (std.mem.eql(u8, mode, "pretty"))
        true
    else if (std.mem.eql(u8, mode, "compact"))
        false
    else
        return fail(ctx, "mode must be \"pretty\" or \"compact\"", .{});
    return .{ .text = try formatText(ctx, text, pretty, getInt(args, "indent", 2), getBool(args, "sort_keys", false)) };
}

// ---------------------------------------------------------------------------
// json_keys
// ---------------------------------------------------------------------------

fn isContainer(v: Value) bool {
    return v == .array or v == .object;
}

fn describe(w: *std.Io.Writer, v: Value) std.Io.Writer.Error!void {
    switch (v) {
        .string => |s| try w.print("string ({d} chars)", .{cpCount(s)}),
        .array => |a| try w.print("array ({d} items)", .{a.items.len}),
        .object => |o| try w.print("object ({d} keys)", .{o.count()}),
        else => try w.writeAll(typeName(v)),
    }
}

fn indentBy(w: *std.Io.Writer, n: usize) std.Io.Writer.Error!void {
    for (0..n) |_| try w.writeByte(' ');
}

fn summarizeChildren(w: *std.Io.Writer, v: Value, depth_left: usize, indent: usize, budget: *usize) std.Io.Writer.Error!void {
    switch (v) {
        .object => |o| {
            const keys = o.keys();
            const vals = o.values();
            for (keys, vals, 0..) |k, x, i| {
                if (i >= MAX_KEYS_PER_OBJECT) {
                    try indentBy(w, indent);
                    try w.print("... {d} more keys\n", .{keys.len - i});
                    break;
                }
                if (budget.* == 0) return;
                budget.* -= 1;
                try indentBy(w, indent);
                try w.print("{s}: ", .{k});
                try describe(w, x);
                try w.writeByte('\n');
                if (depth_left > 1 and isContainer(x)) try summarizeChildren(w, x, depth_left - 1, indent + 2, budget);
            }
        },
        .array => |a| {
            if (budget.* == 0) return;
            budget.* -= 1;
            var counts = [_]usize{0} ** 7;
            const names = [_][]const u8{ "null", "boolean", "integer", "number", "string", "array", "object" };
            for (a.items) |el| counts[kindIndex(el)] += 1;
            try indentBy(w, indent);
            try w.writeAll("element types:");
            var first = true;
            for (counts, names) |c, n| {
                if (c == 0) continue;
                try w.print("{s} {s} x{d}", .{ if (first) "" else ",", n, c });
                first = false;
            }
            if (first) try w.writeAll(" (empty)");
            try w.writeByte('\n');
            if (depth_left > 1 and a.items.len > 0 and isContainer(a.items[0])) {
                try indentBy(w, indent);
                try w.writeAll("first item:\n");
                try summarizeChildren(w, a.items[0], depth_left - 1, indent + 2, budget);
            }
        },
        else => {},
    }
}

fn kindIndex(v: Value) usize {
    return switch (v) {
        .null => 0,
        .bool => 1,
        .integer => 2,
        .float, .number_string => 3,
        .string => 4,
        .array => 5,
        .object => 6,
    };
}

fn keysText(ctx: *Ctx, text: []const u8, query: ?[]const u8, depth: i64) Err![]const u8 {
    const root = try selectOne(ctx, query, try parseOrFail(ctx, text));
    var aw: std.Io.Writer.Allocating = .init(ctx.alloc);
    const w = &aw.writer;
    var budget: usize = MAX_SUMMARY_LINES;
    const d: usize = @intCast(std.math.clamp(depth, 1, 6));
    describe(w, root) catch return error.OutOfMemory;
    w.writeByte('\n') catch return error.OutOfMemory;
    summarizeChildren(w, root, d, 2, &budget) catch return error.OutOfMemory;
    if (budget == 0) w.print("[summary truncated at {d} lines; lower depth or pass a query]\n", .{MAX_SUMMARY_LINES}) catch return error.OutOfMemory;
    return aw.written();
}

fn handleKeys(alloc: std.mem.Allocator, io: std.Io, args: Value) anyerror!mcp.ToolResult {
    var ctx: Ctx = .{ .alloc = alloc };
    return finish(&ctx, keysImpl(&ctx, io, args));
}

fn keysImpl(ctx: *Ctx, io: std.Io, args: Value) Err!mcp.ToolResult {
    const text = try loadInput(ctx, io, args);
    return .{ .text = try keysText(ctx, text, getStr(args, "query"), getInt(args, "depth", 1)) };
}

// ---------------------------------------------------------------------------
// json_schema_infer
// ---------------------------------------------------------------------------

const Prop = struct { node: *Node, count: usize };

const Node = struct {
    /// Bitmask indexed by kindIndex().
    kinds: u8 = 0,
    obj_count: usize = 0,
    props: std.array_hash_map.String(Prop) = .empty,
    omitted_props: usize = 0,
    items: ?*Node = null,
    min_len: usize = std.math.maxInt(usize),
    max_len: usize = 0,
    sampled_only: bool = false,
};

fn newNode(alloc: std.mem.Allocator) std.mem.Allocator.Error!*Node {
    const n = try alloc.create(Node);
    n.* = .{};
    return n;
}

fn visit(alloc: std.mem.Allocator, node: *Node, v: Value, depth_left: usize) std.mem.Allocator.Error!void {
    node.kinds |= @as(u8, 1) << @intCast(kindIndex(v));
    if (depth_left == 0) return;
    switch (v) {
        .object => |o| {
            node.obj_count += 1;
            for (o.keys(), o.values()) |k, x| {
                const gop = try node.props.getOrPut(alloc, k);
                if (!gop.found_existing) {
                    if (node.props.count() > MAX_SCHEMA_PROPS) {
                        _ = node.props.pop();
                        node.omitted_props += 1;
                        continue;
                    }
                    gop.value_ptr.* = .{ .node = try newNode(alloc), .count = 0 };
                }
                gop.value_ptr.count += 1;
                try visit(alloc, gop.value_ptr.node, x, depth_left - 1);
            }
        },
        .array => |a| {
            node.min_len = @min(node.min_len, a.items.len);
            node.max_len = @max(node.max_len, a.items.len);
            if (node.items == null) node.items = try newNode(alloc);
            const n = @min(a.items.len, MAX_SCHEMA_ARRAY_SAMPLE);
            if (a.items.len > n) node.sampled_only = true;
            for (a.items[0..n]) |el| try visit(alloc, node.items.?, el, depth_left - 1);
        },
        else => {},
    }
}

fn renderNode(js: *std.json.Stringify, n: *const Node) WriteErr!void {
    const names = [_][]const u8{ "null", "boolean", "integer", "number", "string", "array", "object" };
    var kinds = n.kinds;
    // integer + number collapse to number.
    if (kinds & (1 << 2) != 0 and kinds & (1 << 3) != 0) kinds &= ~@as(u8, 1 << 2);
    try js.beginObject();
    try js.objectField("type");
    if (@popCount(kinds) == 1) {
        try js.write(names[@ctz(kinds)]);
    } else {
        try js.beginArray();
        for (names, 0..) |name, i| {
            if (kinds & (@as(u8, 1) << @intCast(i)) != 0) try js.write(name);
        }
        try js.endArray();
    }
    if (n.obj_count > 0) {
        try js.objectField("properties");
        try js.beginObject();
        for (n.props.keys(), n.props.values()) |k, p| {
            try js.objectField(k);
            try renderNode(js, p.node);
        }
        try js.endObject();
        var any_required = false;
        for (n.props.values()) |p| {
            if (p.count == n.obj_count) any_required = true;
        }
        if (any_required) {
            try js.objectField("required");
            try js.beginArray();
            for (n.props.keys(), n.props.values()) |k, p| {
                if (p.count == n.obj_count) try js.write(k);
            }
            try js.endArray();
        }
        if (n.omitted_props > 0) {
            try js.objectField("omittedProperties");
            try js.write(n.omitted_props);
        }
    }
    if (n.items) |items| {
        if (items.kinds != 0) {
            try js.objectField("items");
            try renderNode(js, items);
        }
        try js.objectField("minItems");
        try js.write(n.min_len);
        try js.objectField("maxItems");
        try js.write(n.max_len);
        if (n.sampled_only) {
            try js.objectField("sampledItemsPerArray");
            try js.write(MAX_SCHEMA_ARRAY_SAMPLE);
        }
    }
    try js.endObject();
}

fn schemaText(ctx: *Ctx, text: []const u8, query: ?[]const u8, max_depth: i64) Err![]const u8 {
    const root = try selectOne(ctx, query, try parseOrFail(ctx, text));
    const node = try newNode(ctx.alloc);
    try visit(ctx.alloc, node, root, @intCast(std.math.clamp(max_depth, 1, 20)));
    var aw: std.Io.Writer.Allocating = .init(ctx.alloc);
    var js: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    renderNode(&js, node) catch return error.OutOfMemory;
    const out = aw.written();
    if (out.len > MAX_OUTPUT_BYTES) {
        return fail(ctx, "inferred schema is {d} bytes, over the {d} byte cap; lower max_depth or pass a query", .{ out.len, MAX_OUTPUT_BYTES });
    }
    return out;
}

fn handleSchemaInfer(alloc: std.mem.Allocator, io: std.Io, args: Value) anyerror!mcp.ToolResult {
    var ctx: Ctx = .{ .alloc = alloc };
    return finish(&ctx, schemaImpl(&ctx, io, args));
}

fn schemaImpl(ctx: *Ctx, io: std.Io, args: Value) Err!mcp.ToolResult {
    const text = try loadInput(ctx, io, args);
    return .{ .text = try schemaText(ctx, text, getStr(args, "query"), getInt(args, "max_depth", 6)) };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Run a query; on a filter/JSON failure return "ERR: <message>". Trailing
/// newline is trimmed for readability.
fn tq(arena: std.mem.Allocator, doc: []const u8, query: []const u8) ![]const u8 {
    var ctx: Ctx = .{ .alloc = arena };
    const r = queryText(&ctx, doc, query, false, 10_000) catch |e| switch (e) {
        error.Failed => return std.fmt.allocPrint(arena, "ERR: {s}", .{ctx.msg.?}),
        error.OutOfMemory => return e,
    };
    return std.mem.trimEnd(u8, r, "\n");
}

fn expectQ(doc: []const u8, query: []const u8, expected: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings(expected, try tq(arena_state.allocator(), doc, query));
}

fn expectQErr(doc: []const u8, query: []const u8, needle: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const out = try tq(arena_state.allocator(), doc, query);
    if (!std.mem.startsWith(u8, out, "ERR: ") or std.mem.indexOf(u8, out, needle) == null) {
        std.debug.print("expected error containing '{s}' for query '{s}', got: {s}\n", .{ needle, query, out });
        return error.TestExpectedEqual;
    }
}

const sample =
    \\{"name":"acme","n":3,"tags":["a","b","c"],"items":[
    \\{"id":1,"name":"x","price":9.5,"ok":true},
    \\{"id":2,"name":"y","price":20,"ok":false},
    \\{"id":3,"name":"z","price":5,"ok":true}],
    \\"nested":{"a":{"b":[10,20,30]}},"nothing":null,"a b":7}
;

test "identity and simple fields" {
    try expectQ("{\"a\":1}", ".", "{\"a\":1}");
    try expectQ(sample, ".name", "\"acme\"");
    try expectQ(sample, ".nested.a.b", "[10,20,30]");
    try expectQ(sample, ".missing", "null");
    try expectQ(sample, ".nothing.deeper", "null");
    try expectQ(sample, ".\"a b\"", "7");
    try expectQ(sample, ".[\"a b\"]", "7");
    try expectQ(sample, ".nested.a[\"b\"][0]", "10");
}

test "array index, negative index, out of range" {
    try expectQ(sample, ".tags[0]", "\"a\"");
    try expectQ(sample, ".tags[-1]", "\"c\"");
    try expectQ(sample, ".tags[5]", "null");
    try expectQ(sample, ".tags[-9]", "null");
    try expectQ("[1,2,3]", ".[1]", "2");
    try expectQ(sample, ".nested.a.b[1]", "20");
    try expectQ("null", ".[0]", "null");
}

test "iteration over arrays and objects" {
    try expectQ("[1,2,3]", ".[]", "1\n2\n3");
    try expectQ(sample, ".tags[]", "\"a\"\n\"b\"\n\"c\"");
    try expectQ("{\"a\":1,\"b\":2}", ".[]", "1\n2");
    try expectQ(sample, ".items[].id", "1\n2\n3");
    try expectQ("[]", ".[]", "(no results)");
}

test "slices" {
    try expectQ("[0,1,2,3,4]", ".[1:3]", "[1,2]");
    try expectQ("[0,1,2,3,4]", ".[:2]", "[0,1]");
    try expectQ("[0,1,2,3,4]", ".[3:]", "[3,4]");
    try expectQ("[0,1,2,3,4]", ".[-2:]", "[3,4]");
    try expectQ("[0,1,2,3,4]", ".[:-1]", "[0,1,2,3]");
    try expectQ("[0,1,2,3,4]", ".[3:1]", "[]");
    try expectQ("[0,1,2,3,4]", ".[2:99]", "[2,3,4]");
    try expectQ("[0,1,2,3,4]", ".[-99:2]", "[0,1]");
    try expectQ("[0,1,2,3,4]", ".[ 1 : 2 ]", "[1]");
    try expectQ("\"hello\"", ".[1:3]", "\"el\"");
    try expectQ("\"h\\u00e9llo\"", ".[1:3]", "\"\xc3\xa9l\"");
    try expectQ("null", ".[1:3]", "null");
    try expectQErr("5", ".[1:3]", "Cannot slice number");
}

test "pipes and paths" {
    try expectQ(sample, ".nested | .a | .b | .[0]", "10");
    try expectQ(sample, ".items | .[1] | .name", "\"y\"");
    try expectQ(sample, ".items[] | .name", "\"x\"\n\"y\"\n\"z\"");
    try expectQ(sample, ". | .n", "3");
    try expectQ("[[1,2],[3]]", ".[] | .[]", "1\n2\n3");
    try expectQ("[[1,2],[3]]", ".[][]", "1\n2\n3");
    try expectQ("{\"a\":[{\"b\":1},{\"b\":2}]}", ".a[].b", "1\n2");
    try expectQ("{\"a\":{\"b\":1}}", ".a.[\"b\"]", "1");
}

test "select with comparison operators" {
    try expectQ(sample, ".items[] | select(.id == 2) | .name", "\"y\"");
    try expectQ(sample, ".items[] | select(.id != 2) | .id", "1\n3");
    try expectQ(sample, ".items[] | select(.price > 9) | .id", "1\n2");
    try expectQ(sample, ".items[] | select(.price < 9.5) | .id", "3");
    try expectQ(sample, ".items[] | select(.price >= 9.5) | .id", "1\n2");
    try expectQ(sample, ".items[] | select(.price <= 9.5) | .id", "1\n3");
    try expectQ(sample, ".items[] | select(.name == \"z\") | .id", "3");
    try expectQ(sample, ".items[] | select(.ok == true) | .id", "1\n3");
    try expectQ(sample, ".items[] | select(.ok == false) | .id", "2");
    try expectQ(sample, ".items[] | select(.nope == null) | .id", "1\n2\n3");
    try expectQ(sample, ".items[] | select(.ok) | .id", "1\n3");
    try expectQ(sample, ".items[] | select(.nope) | .id", "(no results)");
    try expectQ("[{\"a\":1,\"b\":1},{\"a\":1,\"b\":2}]", ".[] | select(.a == .b) | .b", "1");
    try expectQ("[{\"a\":{\"x\":5}}]", ".[] | select(.a.x == 5) | .a", "{\"x\":5}");
    // integer and float compare as numbers
    try expectQ("[{\"v\":1.0},{\"v\":2}]", ".[] | select(.v == 1) | .v", "1");
    // select passes the input through unchanged
    try expectQ("[1,2,3]", ".[] | select(. == 2)", "2");
}

test "select on scalars and mixed types" {
    try expectQ("[1,\"a\",null,true]", ".[] | select(. == \"a\")", "\"a\"");
    try expectQ("[1,\"a\",null,true]", ".[] | select(. != null)", "1\n\"a\"\ntrue");
    // jq ordering: numbers sort below strings
    try expectQ("[1,\"a\"]", ".[] | select(. < \"a\")", "1");
    try expectQ("[\"apple\",\"pear\"]", ".[] | select(. > \"b\")", "\"pear\"");
    try expectQ("[{\"a\":[1,2],\"b\":[1,2]},{\"a\":[1],\"b\":[2]}]", ".[] | select(.a == .b) | .a", "[1,2]");
}

test "keys, length, has" {
    try expectQ("{\"b\":1,\"a\":2}", "keys", "[\"a\",\"b\"]");
    try expectQ("[7,8,9]", "keys", "[0,1,2]");
    try expectQ(sample, ".items | length", "3");
    try expectQ(sample, ".name | length", "4");
    try expectQ("\"h\\u00e9\"", "length", "2");
    try expectQ("null", "length", "0");
    try expectQ("{\"a\":1,\"b\":2}", "length", "2");
    try expectQ("-5", "length", "5");
    try expectQ("[]", "length", "0");
    try expectQ(sample, ".items[0] | has(\"price\")", "true");
    try expectQ(sample, ".items[0] | has(\"zzz\")", "false");
    try expectQ("[1,2]", "has(1)", "true");
    try expectQ("[1,2]", "has(2)", "false");
    try expectQ("[1,2]", "has(-1)", "false");
    try expectQErr(sample, ".items[] | select(has(\"id\"))", "select() expects a path");
}

test "map" {
    try expectQ(sample, ".items | map(.id)", "[1,2,3]");
    try expectQ(sample, ".items | map(select(.ok)) | length", "2");
    try expectQ(sample, ".items | map(select(.price > 6) | .name)", "[\"x\",\"y\"]");
    try expectQ("[1,2,3]", "map(.)", "[1,2,3]");
    try expectQ("[[1,2],[3]]", "map(length)", "[2,1]");
    try expectQ("[[1,2],[3]]", "map(.[])", "[1,2,3]");
    try expectQ("{\"a\":1,\"b\":2}", "map(.)", "[1,2]");
    try expectQ("[]", "map(.a)", "[]");
    try expectQErr("[1]", "map(frobnicate)", "unsupported function or keyword 'frobnicate'");
    try expectQ("[[{\"v\":1},{\"v\":2}]]", "map(map(.v))", "[[1,2]]");
    try expectQErr("5", "map(.)", "Cannot iterate over number");
}

test "runtime type errors are clear" {
    try expectQErr("[1]", ".a", "Cannot index array with \"a\"");
    try expectQErr("{\"a\":1}", ".[0]", "Cannot index object with number");
    try expectQErr("5", ".[]", "Cannot iterate over number");
    try expectQErr("\"s\"", ".[]", "Cannot iterate over string");
    try expectQErr("5", "keys", "number has no keys");
    try expectQErr("true", "length", "boolean has no length");
    try expectQErr("[1]", "has(\"a\")", "Cannot check whether array has a string key");
    try expectQErr("{\"a\":1}", "has(0)", "Cannot check whether object has a number key");
    try expectQErr("[{\"a\":[1],\"b\":[2]}]", ".[] | select(.a < .b)", "not supported");
}

test "unsupported syntax is rejected, not guessed" {
    const bad = [_][]const u8{
        "..",
        ".a..b",
        ".a?",
        ".a, .b",
        ".a + 1",
        ".a // 1",
        "to_entries",
        "sort_by(.a)",
        "if . then 1 else 2 end",
        "$x",
        "(.a)",
        "{a: .a}",
        "[.a]",
        "\"literal\"",
        "42",
        ".a |",
        "| .a",
        ".a | | .b",
        ".a.",
        ".[1,2]",
        ".[",
        ".[abc]",
        ".[\"a\"",
        "map(.a",
        "map .a",
        "map()",
        "select(.a and .b)",
        "select(.a == 1 or .b == 2)",
        "select(.a | length > 1)",
        "select(1 == .a)",
        "select(.a ~ 1)",
        "select(.a == foo)",
        "select(.[] == 1)",
        "select(.a == \"unterminated)",
        "keys(.)",
        "length()",
        "has(true)",
        "has(1.5)",
        "has(.a)",
        ".a as $x | $x",
        "reduce .[] as $i (0; . + $i)",
        "@base64",
        "",
        "   ",
    };
    for (bad) |q| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const out = try tq(arena_state.allocator(), "{\"a\":[1,2]}", q);
        if (!std.mem.startsWith(u8, out, "ERR: ")) {
            std.debug.print("query '{s}' should have been rejected, got: {s}\n", .{ q, out });
            return error.TestUnexpectedResult;
        }
    }
}

test "unsupported-syntax messages name the problem" {
    try expectQErr("{}", "..", "recursive descent");
    try expectQErr("{}", "to_entries", "unsupported function or keyword 'to_entries'");
    try expectQErr("{}", ".a, .b", "unexpected ','");
    try expectQErr("{}", "select(.a and .b)", "unsupported operator");
    try expectQErr("{}", "select(.[] == 1)", "not allowed inside a select()");
    try expectQErr("{}", "", "empty query");
    try expectQErr("{}", ".a |", "empty filter or dangling '|'");
    try expectQErr("{}", "map(.a", "missing ')'");
    try expectQErr("{}", "select(.a == foo)", "bare word 'foo'");
    // position is reported
    try expectQErr("{}", ".a | to_entries", "position 5");
}

test "parser handles whitespace and escapes" {
    try expectQ("{\"a\":{\"b\":2}}", "  .a   |   .b  ", "2");
    try expectQ("{\"q\\\"x\":1}", ".\"q\\\"x\"", "1");
    try expectQ("[{\"k\":\"a\\nb\"}]", ".[] | select(.k == \"a\\nb\") | .k", "\"a\\nb\"");
    try expectQ("[{\"k\":-1.5}]", ".[] | select(.k < -1) | .k", "-1.5");
}

test "deeply nested map filters are capped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var q: std.ArrayList(u8) = .empty;
    for (0..40) |_| try q.appendSlice(a, "map(");
    try q.append(a, '.');
    for (0..40) |_| try q.append(a, ')');
    const out = try tq(a, "[]", q.items);
    try testing.expect(std.mem.indexOf(u8, out, "nested too deeply") != null);
}

test "invalid documents" {
    try expectQErr("{\"a\":", ".", "invalid JSON");
    try expectQErr("", ".", "invalid JSON");
    try expectQErr("{} extra", ".", "invalid JSON");
    try expectQErr("{'a':1}", ".", "invalid JSON");
}

test "max_results and output truncation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ctx: Ctx = .{ .alloc = a };
    const out = try queryText(&ctx, "[1,2,3,4,5]", ".[]", false, 2);
    try testing.expectEqualStrings("1\n2\n[truncated by max_results: showing 2 of 5 results; narrow the query]\n", out);

    // One huge value is cut at the output cap.
    var big: std.ArrayList(u8) = .empty;
    try big.appendSlice(a, "[\"");
    try big.appendNTimes(a, 'x', MAX_OUTPUT_BYTES + 100);
    try big.appendSlice(a, "\"]");
    const out2 = try queryText(&ctx, big.items, ".[0]", false, 10);
    try testing.expect(out2.len < MAX_OUTPUT_BYTES + 200);
    try testing.expect(std.mem.indexOf(u8, out2, "truncated by output size cap") != null);

    // Many results stop at the output cap on a result boundary.
    var many: std.ArrayList(u8) = .empty;
    try many.append(a, '[');
    for (0..3) |i| {
        if (i > 0) try many.append(a, ',');
        try many.append(a, '"');
        try many.appendNTimes(a, 'y', MAX_OUTPUT_BYTES / 2);
        try many.append(a, '"');
    }
    try many.append(a, ']');
    const out3 = try queryText(&ctx, many.items, ".[]", false, 10);
    try testing.expect(std.mem.indexOf(u8, out3, "showing 1 of 3") != null);
}

test "pretty output" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ctx: Ctx = .{ .alloc = arena_state.allocator() };
    const out = try queryText(&ctx, "{\"a\":[1,2]}", ".", true, 10);
    try testing.expectEqualStrings("{\n  \"a\": [\n    1,\n    2\n  ]\n}\n", out);
}

test "evaluation work is bounded" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ctx: Ctx = .{ .alloc = a, .steps = MAX_EVAL_STEPS - 1 };
    try testing.expectError(error.Failed, queryText(&ctx, "[1,2,3]", ".[]", false, 10));
    try testing.expect(std.mem.indexOf(u8, ctx.msg.?, "work limit") != null);
}

test "intermediate result cap" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ctx: Ctx = .{ .alloc = a };
    var list: ValueList = .empty;
    var i: usize = 0;
    while (i < MAX_INTERMEDIATE_RESULTS) : (i += 1) try list.append(a, .null);
    try testing.expectError(error.Failed, pushResult(&ctx, &list, .null));
}

// ---- validate ----

test "json_validate reports validity" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ctx: Ctx = .{ .alloc = arena_state.allocator() };
    const ok = try validateText(&ctx, "{\"a\":[1,{\"b\":2}]}");
    try testing.expect(std.mem.indexOf(u8, ok, "valid: true") != null);
    try testing.expect(std.mem.indexOf(u8, ok, "type: object, 1 keys") != null);
    try testing.expect(std.mem.indexOf(u8, ok, "max nesting depth: 3") != null);

    const arr = try validateText(&ctx, "[1,2,3]");
    try testing.expect(std.mem.indexOf(u8, arr, "type: array, 3 items") != null);

    const scalar = try validateText(&ctx, "42");
    try testing.expect(std.mem.indexOf(u8, scalar, "type: integer") != null);

    const bad = try validateText(&ctx, "{\n  \"a\": 1,\n  \"b\": }");
    try testing.expect(std.mem.indexOf(u8, bad, "valid: false") != null);
    try testing.expect(std.mem.indexOf(u8, bad, "line 3") != null);

    const trailing = try validateText(&ctx, "[1] x");
    try testing.expect(std.mem.indexOf(u8, trailing, "valid: false") != null);

    const empty = try validateText(&ctx, "   ");
    try testing.expect(std.mem.indexOf(u8, empty, "valid: false") != null);

    const bom = try validateText(&ctx, "\xEF\xBB\xBF{}");
    try testing.expect(std.mem.indexOf(u8, bom, "valid: true") != null);
}

test "nesting depth limit" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ctx: Ctx = .{ .alloc = a };
    var deep: std.ArrayList(u8) = .empty;
    try deep.appendNTimes(a, '[', MAX_JSON_DEPTH + 1);
    try deep.appendNTimes(a, ']', MAX_JSON_DEPTH + 1);
    const out = try validateText(&ctx, deep.items);
    try testing.expect(std.mem.indexOf(u8, out, "nesting too deep") != null);

    var ok: std.ArrayList(u8) = .empty;
    try ok.appendNTimes(a, '[', MAX_JSON_DEPTH);
    try ok.appendNTimes(a, ']', MAX_JSON_DEPTH);
    const out2 = try validateText(&ctx, ok.items);
    try testing.expect(std.mem.indexOf(u8, out2, "valid: true") != null);

    // Brackets inside strings don't count.
    try testing.expectEqual(@as(usize, 1), nestingDepth("[\"[[[[\\\"[[\"]", 100));
}

// ---- format ----

test "json_format modes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ctx: Ctx = .{ .alloc = arena_state.allocator() };
    const src = "{ \"b\" : 1, \"a\" : [ true, null, \"x\" ], \"c\": {\"z\":1,\"y\":2} }";

    try testing.expectEqualStrings("{\"b\":1,\"a\":[true,null,\"x\"],\"c\":{\"z\":1,\"y\":2}}", try formatText(&ctx, src, false, 2, false));
    try testing.expectEqualStrings("{\"a\":[true,null,\"x\"],\"b\":1,\"c\":{\"y\":2,\"z\":1}}", try formatText(&ctx, src, false, 2, true));
    try testing.expectEqualStrings("{\n  \"b\": 1,\n  \"a\": [\n    true,\n    null,\n    \"x\"\n  ],\n  \"c\": {\n    \"z\": 1,\n    \"y\": 2\n  }\n}", try formatText(&ctx, src, true, 2, false));
    try testing.expectEqualStrings("{\n    \"a\": 1\n}", try formatText(&ctx, "{\"a\":1}", true, 4, false));
    try testing.expectEqualStrings("[]", try formatText(&ctx, "[ ]", true, 2, false));
    try testing.expectEqualStrings("{}", try formatText(&ctx, "{ }", true, 2, true));
    try testing.expectEqualStrings("\"\\u0001\\n\"", try formatText(&ctx, "\"\\u0001\\n\"", false, 2, false));
    try testing.expectError(error.Failed, formatText(&ctx, "{}", true, 5, false));
    try testing.expectError(error.Failed, formatText(&ctx, "{", true, 2, false));
}

test "json_format preserves big integers and floats" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ctx: Ctx = .{ .alloc = arena_state.allocator() };
    const out = try formatText(&ctx, "[12345678901234567890, 1.5, -0, 1e3]", false, 2, false);
    try testing.expect(std.mem.startsWith(u8, out, "[12345678901234567890,1.5,"));
}

test "json_format sorted keys are recursive and stable for duplicates of prefix" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ctx: Ctx = .{ .alloc = arena_state.allocator() };
    const out = try formatText(&ctx, "[{\"b\":{\"y\":1,\"x\":2},\"a\":1,\"ab\":2}]", false, 2, true);
    try testing.expectEqualStrings("[{\"a\":1,\"ab\":2,\"b\":{\"x\":2,\"y\":1}}]", out);
}

// ---- keys ----

test "json_keys summary" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ctx: Ctx = .{ .alloc = arena_state.allocator() };
    const d1 = try keysText(&ctx, sample, null, 1);
    try testing.expectEqualStrings(
        "object (7 keys)\n" ++
            "  name: string (4 chars)\n" ++
            "  n: integer\n" ++
            "  tags: array (3 items)\n" ++
            "  items: array (3 items)\n" ++
            "  nested: object (1 keys)\n" ++
            "  nothing: null\n" ++
            "  a b: integer\n",
        d1,
    );
    const d2 = try keysText(&ctx, sample, ".nested", 3);
    try testing.expectEqualStrings(
        "object (1 keys)\n  a: object (1 keys)\n    b: array (3 items)\n      element types: integer x3\n",
        d2,
    );
    const arr = try keysText(&ctx, sample, ".items", 2);
    try testing.expect(std.mem.indexOf(u8, arr, "array (3 items)") != null);
    try testing.expect(std.mem.indexOf(u8, arr, "element types: object x3") != null);
    try testing.expect(std.mem.indexOf(u8, arr, "first item:") != null);
    try testing.expect(std.mem.indexOf(u8, arr, "price: number") != null);
    try testing.expect(std.mem.indexOf(u8, arr, "ok: boolean") != null);

    const scalar = try keysText(&ctx, "42", null, 1);
    try testing.expectEqualStrings("integer\n", scalar);

    const mixed = try keysText(&ctx, "[1,1.5,\"a\",null,true,[],{}]", null, 1);
    try testing.expect(std.mem.indexOf(u8, mixed, "null x1, boolean x1, integer x1, number x1, string x1, array x1, object x1") != null);

    const empty = try keysText(&ctx, "[]", null, 1);
    try testing.expect(std.mem.indexOf(u8, empty, "(empty)") != null);
}

test "json_keys caps keys and requires single subdocument" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ctx: Ctx = .{ .alloc = a };
    var doc: std.ArrayList(u8) = .empty;
    try doc.append(a, '{');
    for (0..150) |i| {
        if (i > 0) try doc.append(a, ',');
        try doc.print(a, "\"k{d}\":{d}", .{ i, i });
    }
    try doc.append(a, '}');
    const out = try keysText(&ctx, doc.items, null, 1);
    try testing.expect(std.mem.indexOf(u8, out, "... 50 more keys") != null);

    try testing.expectError(error.Failed, keysText(&ctx, "[1,2]", ".[]", 1));
    try testing.expect(std.mem.indexOf(u8, ctx.msg.?, "exactly one value (got 2)") != null);
    try testing.expectError(error.Failed, keysText(&ctx, "[1,2]", ".[5] | .x | .[]", 1));
}

test "json_keys total lines are capped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ctx: Ctx = .{ .alloc = a };
    var doc: std.ArrayList(u8) = .empty;
    try doc.append(a, '{');
    for (0..60) |i| {
        if (i > 0) try doc.append(a, ',');
        try doc.print(a, "\"g{d}\":{{", .{i});
        for (0..20) |j| {
            if (j > 0) try doc.append(a, ',');
            try doc.print(a, "\"h{d}\":1", .{j});
        }
        try doc.append(a, '}');
    }
    try doc.append(a, '}');
    const out = try keysText(&ctx, doc.items, null, 2);
    try testing.expect(std.mem.indexOf(u8, out, "summary truncated") != null);
}

// ---- schema ----

test "json_schema_infer objects and required" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ctx: Ctx = .{ .alloc = arena_state.allocator() };
    const out = try schemaText(&ctx, "[{\"id\":1,\"tag\":\"a\"},{\"id\":2.5},{\"id\":3,\"tag\":null}]", null, 6);
    const expected =
        \\{
        \\  "type": "array",
        \\  "items": {
        \\    "type": "object",
        \\    "properties": {
        \\      "id": {
        \\        "type": "number"
        \\      },
        \\      "tag": {
        \\        "type": [
        \\          "null",
        \\          "string"
        \\        ]
        \\      }
        \\    },
        \\    "required": [
        \\      "id"
        \\    ]
        \\  },
        \\  "minItems": 3,
        \\  "maxItems": 3
        \\}
    ;
    try testing.expectEqualStrings(expected, out);
}

test "json_schema_infer scalars, empty containers, query, depth" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ctx: Ctx = .{ .alloc = arena_state.allocator() };
    try testing.expectEqualStrings("{\n  \"type\": \"string\"\n}", try schemaText(&ctx, "\"x\"", null, 6));
    try testing.expectEqualStrings("{\n  \"type\": \"null\"\n}", try schemaText(&ctx, "null", null, 6));

    const empty = try schemaText(&ctx, "[]", null, 6);
    try testing.expect(std.mem.indexOf(u8, empty, "\"minItems\": 0") != null);
    try testing.expect(std.mem.indexOf(u8, empty, "\"items\"") == null);

    const sub = try schemaText(&ctx, sample, ".nested.a.b", 6);
    try testing.expect(std.mem.indexOf(u8, sub, "\"type\": \"array\"") != null);
    try testing.expect(std.mem.indexOf(u8, sub, "\"integer\"") != null);

    // max_depth 1: object's properties get types but are not expanded.
    const shallow = try schemaText(&ctx, "{\"a\":{\"b\":1}}", null, 1);
    try testing.expect(std.mem.indexOf(u8, shallow, "\"a\"") != null);
    try testing.expect(std.mem.indexOf(u8, shallow, "\"b\"") == null);
    const deeper = try schemaText(&ctx, "{\"a\":{\"b\":1}}", null, 2);
    try testing.expect(std.mem.indexOf(u8, deeper, "\"b\"") != null);
}

test "json_schema_infer samples big arrays and caps properties" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ctx: Ctx = .{ .alloc = a };
    var doc: std.ArrayList(u8) = .empty;
    try doc.append(a, '[');
    for (0..(MAX_SCHEMA_ARRAY_SAMPLE + 5)) |i| {
        if (i > 0) try doc.append(a, ',');
        try doc.print(a, "{d}", .{i});
    }
    try doc.append(a, ']');
    const out = try schemaText(&ctx, doc.items, null, 6);
    try testing.expect(std.mem.indexOf(u8, out, "sampledItemsPerArray") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"maxItems\": 505") != null);

    var obj: std.ArrayList(u8) = .empty;
    try obj.append(a, '{');
    for (0..(MAX_SCHEMA_PROPS + 3)) |i| {
        if (i > 0) try obj.append(a, ',');
        try obj.print(a, "\"p{d}\":1", .{i});
    }
    try obj.append(a, '}');
    const out2 = try schemaText(&ctx, obj.items, null, 6);
    try testing.expect(std.mem.indexOf(u8, out2, "\"omittedProperties\": 3") != null);
}

// ---- handlers / input loading ----

fn callTool(arena: std.mem.Allocator, handler: mcp.ToolHandler, args_json: []const u8) !mcp.ToolResult {
    const args = try std.json.parseFromSliceLeaky(Value, arena, args_json, .{});
    return handler(arena, testing.io, args);
}

test "handlers: json text input" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const r = try callTool(a, handleQuery, "{\"json\":\"{\\\"a\\\":[1,2,3]}\",\"query\":\".a | length\"}");
    try testing.expect(!r.is_error);
    try testing.expectEqualStrings("3\n", r.text);

    // Inline (non-string) documents are tolerated.
    const r2 = try callTool(a, handleQuery, "{\"json\":{\"a\":5},\"query\":\".a\"}");
    try testing.expectEqualStrings("5\n", r2.text);

    const r3 = try callTool(a, handleQuery, "{\"json\":\"[1,2,3]\",\"query\":\".[]\",\"max_results\":1}");
    try testing.expect(std.mem.indexOf(u8, r3.text, "showing 1 of 3") != null);

    const r4 = try callTool(a, handleQuery, "{\"json\":\"{\\\"a\\\":1}\",\"query\":\".\",\"pretty\":true}");
    try testing.expectEqualStrings("{\n  \"a\": 1\n}\n", r4.text);

    const v = try callTool(a, handleValidate, "{\"json\":\"{\\\"a\\\":\"}");
    try testing.expect(!v.is_error);
    try testing.expect(std.mem.indexOf(u8, v.text, "valid: false") != null);

    const f = try callTool(a, handleFormat, "{\"json\":\"{\\\"b\\\":1,\\\"a\\\":2}\",\"mode\":\"compact\",\"sort_keys\":true}");
    try testing.expectEqualStrings("{\"a\":2,\"b\":1}", f.text);

    const k = try callTool(a, handleKeys, "{\"json\":\"{\\\"a\\\":1}\"}");
    try testing.expect(std.mem.startsWith(u8, k.text, "object (1 keys)"));

    const s = try callTool(a, handleSchemaInfer, "{\"json\":\"{\\\"a\\\":1}\"}");
    try testing.expect(std.mem.indexOf(u8, s.text, "\"properties\"") != null);
}

test "handlers: argument errors are is_error results" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const both = try callTool(a, handleQuery, "{\"json\":\"1\",\"path\":\"/x\",\"query\":\".\"}");
    try testing.expect(both.is_error);
    try testing.expect(std.mem.indexOf(u8, both.text, "not both") != null);

    const neither = try callTool(a, handleValidate, "{}");
    try testing.expect(neither.is_error);
    try testing.expect(std.mem.indexOf(u8, neither.text, "missing input") != null);

    const noq = try callTool(a, handleQuery, "{\"json\":\"1\"}");
    try testing.expect(noq.is_error);
    try testing.expect(std.mem.indexOf(u8, noq.text, "`query`") != null);

    const badq = try callTool(a, handleQuery, "{\"json\":\"1\",\"query\":\"to_entries\"}");
    try testing.expect(badq.is_error);
    try testing.expect(std.mem.indexOf(u8, badq.text, "unsupported") != null);

    const badjson = try callTool(a, handleQuery, "{\"json\":\"{\",\"query\":\".\"}");
    try testing.expect(badjson.is_error);
    try testing.expect(std.mem.indexOf(u8, badjson.text, "invalid JSON") != null);

    const badnum = try callTool(a, handleValidate, "{\"json\":5}");
    try testing.expect(badnum.is_error);

    const badpath = try callTool(a, handleValidate, "{\"path\":\"\"}");
    try testing.expect(badpath.is_error);

    const nonobj = try handleValidate(a, testing.io, .null);
    try testing.expect(nonobj.is_error);

    const badmode = try callTool(a, handleFormat, "{\"json\":\"1\",\"mode\":\"fancy\"}");
    try testing.expect(badmode.is_error);

    const missing = try callTool(a, handleValidate, "{\"path\":\"/definitely/not/here.json\"}");
    try testing.expect(missing.is_error);
    try testing.expect(std.mem.indexOf(u8, missing.text, "cannot read file") != null);
}

test "input size cap on json text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ctx: Ctx = .{ .alloc = a };
    const big = try a.alloc(u8, MAX_INPUT_BYTES + 1);
    @memset(big, ' ');
    const args: Value = blk: {
        var o: std.json.ObjectMap = .empty;
        try o.put(a, "json", .{ .string = big });
        break :blk .{ .object = o };
    };
    try testing.expectError(error.Failed, loadInput(&ctx, testing.io, args));
    try testing.expect(std.mem.indexOf(u8, ctx.msg.?, "input too large") != null);
}

test "file input: read only when path given, size capped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "doc.json", .data = "{\"k\":[1,2,3]}" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bad.json", .data = "{\"k\":" });

    const good_path = try tmp.dir.realPathFileAlloc(testing.io, "doc.json", a);
    const bad_path = try tmp.dir.realPathFileAlloc(testing.io, "bad.json", a);

    const q_args = try std.fmt.allocPrint(a, "{{\"path\":\"{s}\",\"query\":\".k[1]\"}}", .{good_path});
    const r = try callTool(a, handleQuery, q_args);
    try testing.expect(!r.is_error);
    try testing.expectEqualStrings("2\n", r.text);

    const v_args = try std.fmt.allocPrint(a, "{{\"path\":\"{s}\"}}", .{bad_path});
    const v = try callTool(a, handleValidate, v_args);
    try testing.expect(std.mem.indexOf(u8, v.text, "valid: false") != null);

    // A file over the cap is refused.
    {
        var f = try tmp.dir.createFile(testing.io, "huge.json", .{});
        defer f.close(testing.io);
        var buf: [4096]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        @memset(&buf, ' ');
        var fw = f.writer(testing.io, &wbuf);
        var left: usize = MAX_INPUT_BYTES + 1;
        while (left > 0) {
            const n = @min(left, 4096);
            try fw.interface.writeAll(buf[0..n]);
            left -= n;
        }
        try fw.interface.flush();
    }
    const huge_path = try tmp.dir.realPathFileAlloc(testing.io, "huge.json", a);
    const h_args = try std.fmt.allocPrint(a, "{{\"path\":\"{s}\"}}", .{huge_path});
    const h = try callTool(a, handleValidate, h_args);
    try testing.expect(h.is_error);
    try testing.expect(std.mem.indexOf(u8, h.text, "too large") != null);
}

test "tool table: schemas are valid JSON objects with unique names" {
    const alloc = testing.allocator;
    try testing.expectEqual(@as(usize, 5), tool_table.len);
    for (tool_table, 0..) |t, i| {
        var parsed = try std.json.parseFromSlice(Value, alloc, t.input_schema_json, .{});
        defer parsed.deinit();
        try testing.expect(parsed.value == .object);
        try testing.expectEqualStrings("object", parsed.value.object.get("type").?.string);
        try testing.expect(t.description.len > 0);
        for (tool_table[i + 1 ..]) |u| try testing.expect(!std.mem.eql(u8, t.name, u.name));
    }
}
