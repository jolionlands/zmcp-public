//! Pure helpers for context-efficient tool exposure (used by mcp.zig).
//!
//! Nothing here knows about ToolDef or the transport: schema compaction,
//! first-sentence trimming, JSON re-serialization without nulls, and a
//! UTF-8-safe result cap.

const std = @import("std");

/// Property descriptions longer than this are cut to their first sentence.
pub const DESC_LIMIT: usize = 80;
/// Hard cap on a trimmed property/schema description.
pub const DESC_CAP: usize = 120;
/// Hard cap on a trimmed tool description.
pub const TOOL_DESC_CAP: usize = 160;

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// True when the text ending right before a '.' is a common abbreviation
/// ("e.g", "i.e", "vs", "etc", ...), so the period does not end a sentence.
fn endsWithAbbrev(before: []const u8) bool {
    const abbrevs = [_][]const u8{ "e.g", "i.e", "vs", "etc", "approx", "incl", "cf", "no", "eg", "ie" };
    for (abbrevs) |a| {
        if (before.len < a.len) continue;
        if (!std.ascii.eqlIgnoreCase(before[before.len - a.len ..], a)) continue;
        if (before.len == a.len or !std.ascii.isAlphanumeric(before[before.len - a.len - 1])) return true;
    }
    return false;
}

/// First sentence of `text` (trimmed), at most `cap` bytes, cut on a UTF-8
/// boundary. The result is a slice of `text`.
pub fn firstSentence(text: []const u8, cap: usize) []const u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    var end: usize = t.len;
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        const c = t[i];
        if (c == '.' or c == '!' or c == '?') {
            const at_end = i + 1 == t.len;
            if ((at_end or isSpace(t[i + 1])) and !(c == '.' and endsWithAbbrev(t[0..i]))) {
                end = i + 1;
                break;
            }
        } else if (c == '\n' and i + 1 < t.len and t[i + 1] == '\n') {
            end = i;
            break;
        }
    }
    if (end > cap) end = cap;
    while (end > 0 and end < t.len and (t[end] & 0xC0) == 0x80) end -= 1;
    return std.mem.trimEnd(u8, t[0..end], " \t\r\n");
}

/// Description shortened for the compact profile: kept as is when it is at
/// most DESC_LIMIT bytes, otherwise its first sentence (capped at DESC_CAP).
pub fn shortDescription(text: []const u8) []const u8 {
    if (text.len <= DESC_LIMIT) return text;
    return firstSentence(text, DESC_CAP);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Keys whose value is a map of name -> schema.
fn isSchemaMapKey(k: []const u8) bool {
    return eql(k, "properties") or eql(k, "$defs") or eql(k, "definitions") or eql(k, "patternProperties");
}

/// Keys whose value is a single schema (or, for `items`, possibly an array).
fn isSchemaKey(k: []const u8) bool {
    return eql(k, "items") or eql(k, "additionalProperties") or eql(k, "not") or eql(k, "if") or
        eql(k, "then") or eql(k, "else") or eql(k, "contains") or eql(k, "propertyNames");
}

/// Keys whose value is an array of schemas.
fn isSchemaArrayKey(k: []const u8) bool {
    return eql(k, "anyOf") or eql(k, "oneOf") or eql(k, "allOf") or eql(k, "prefixItems");
}

/// Write a JSON Schema node in the compact profile: drops `title`,
/// `additionalProperties:false`, empty `required`; shortens long
/// `description`s. Values such as `enum`, `default`, `const` and property
/// NAMES are never touched (a property called "title" survives).
pub fn writeCompactSchema(js: *std.json.Stringify, node: std.json.Value) std.json.Stringify.Error!void {
    if (node != .object) return js.write(node);
    try js.beginObject();
    var it = node.object.iterator();
    while (it.next()) |e| {
        const k = e.key_ptr.*;
        const v = e.value_ptr.*;
        if (eql(k, "title")) continue;
        if (eql(k, "additionalProperties") and v == .bool and !v.bool) continue;
        if (eql(k, "required") and v == .array and v.array.items.len == 0) continue;
        try js.objectField(k);
        if (eql(k, "description") and v == .string) {
            try js.write(shortDescription(v.string));
        } else if (isSchemaMapKey(k) and v == .object) {
            try js.beginObject();
            var pit = v.object.iterator();
            while (pit.next()) |p| {
                try js.objectField(p.key_ptr.*);
                try writeCompactSchema(js, p.value_ptr.*);
            }
            try js.endObject();
        } else if (isSchemaKey(k) and (v == .object or v == .array)) {
            if (v == .array) {
                try js.beginArray();
                for (v.array.items) |item| try writeCompactSchema(js, item);
                try js.endArray();
            } else try writeCompactSchema(js, v);
        } else if (isSchemaArrayKey(k) and v == .array) {
            try js.beginArray();
            for (v.array.items) |item| try writeCompactSchema(js, item);
            try js.endArray();
        } else {
            try js.write(v);
        }
    }
    try js.endObject();
}

/// Parse `schema_json` and return it minified in the compact profile.
pub fn compactSchema(allocator: std.mem.Allocator, schema_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, schema_json, .{});
    defer parsed.deinit();
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var js = std.json.Stringify{ .writer = &aw.writer };
    try writeCompactSchema(&js, parsed.value);
    return aw.toOwnedSlice();
}

fn writeNoNulls(js: *std.json.Stringify, v: std.json.Value) std.json.Stringify.Error!void {
    switch (v) {
        .object => |o| {
            try js.beginObject();
            var it = o.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.* == .null) continue;
                try js.objectField(e.key_ptr.*);
                try writeNoNulls(js, e.value_ptr.*);
            }
            try js.endObject();
        },
        .array => |a| {
            try js.beginArray();
            for (a.items) |item| try writeNoNulls(js, item);
            try js.endArray();
        },
        else => try js.write(v),
    }
}

/// Re-serialize JSON without whitespace, dropping object fields whose value
/// is null (array elements are kept so positions stay meaningful). Caller
/// owns the result. Invalid JSON returns the parse error.
pub fn compactJson(allocator: std.mem.Allocator, json_text: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var js = std.json.Stringify{ .writer = &aw.writer };
    try writeNoNulls(&js, parsed.value);
    return aw.toOwnedSlice();
}

/// Largest prefix length <= `max` that does not split a UTF-8 sequence.
pub fn utf8SafeLen(text: []const u8, max: usize) usize {
    if (text.len <= max) return text.len;
    var k = max;
    while (k > 0 and (text[k] & 0xC0) == 0x80) k -= 1;
    return k;
}

/// Cap `text` at `max` bytes (0 = unlimited). Returns null when nothing had
/// to be cut, otherwise an owned copy: the UTF-8-safe prefix followed by
/// "\n[truncated N bytes; narrow the query]".
pub fn truncateResult(allocator: std.mem.Allocator, text: []const u8, max: usize) !?[]u8 {
    if (max == 0 or text.len <= max) return null;
    const keep = utf8SafeLen(text, max);
    return try std.fmt.allocPrint(allocator, "{s}\n[truncated {d} bytes; narrow the query]", .{ text[0..keep], text.len - keep });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "firstSentence trims, respects abbreviations and caps on UTF-8 boundaries" {
    try std.testing.expectEqualStrings("Return the time.", firstSentence("Return the time. More detail follows.", 160));
    try std.testing.expectEqualStrings("Use e.g. a path to open it.", firstSentence("Use e.g. a path to open it. Second.", 160));
    try std.testing.expectEqualStrings("No period here", firstSentence("  No period here  ", 160));
    try std.testing.expectEqualStrings("Para one", firstSentence("Para one\n\nPara two.", 160));
    try std.testing.expectEqualStrings("Version 1.5 is fine.", firstSentence("Version 1.5 is fine. Ok", 160));
    // "é" is 2 bytes; a cap of 2 lands inside the second one.
    try std.testing.expectEqualStrings("é", firstSentence("éé tail", 3));
    try std.testing.expectEqualStrings("é", firstSentence("éé tail", 2));
}

test "compactSchema drops noise but keeps property names and enums" {
    const alloc = std.testing.allocator;
    const out = try compactSchema(alloc,
        \\{
        \\  "type": "object",
        \\  "title": "Args",
        \\  "additionalProperties": false,
        \\  "required": [],
        \\  "properties": {
        \\    "title": {"type": "string", "title": "T", "description": "Short."},
        \\    "q": {"type": "string", "description": "The query text to run against the index. It may contain operators such as AND and OR, quoted phrases, and field selectors like name:foo."},
        \\    "mode": {"type": "string", "enum": ["title", "description"], "default": "title"},
        \\    "nested": {"type": "object", "additionalProperties": false, "required": ["a"], "properties": {"a": {"type": "integer"}}}
        \\  }
        \\}
    );
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{\"title\":{\"type\":\"string\",\"description\":\"Short.\"}," ++
            "\"q\":{\"type\":\"string\",\"description\":\"The query text to run against the index.\"}," ++
            "\"mode\":{\"type\":\"string\",\"enum\":[\"title\",\"description\"],\"default\":\"title\"}," ++
            "\"nested\":{\"type\":\"object\",\"required\":[\"a\"],\"properties\":{\"a\":{\"type\":\"integer\"}}}}}",
        out,
    );
}

test "compactJson minifies and drops null object fields" {
    const alloc = std.testing.allocator;
    const out = try compactJson(alloc, "{ \"a\": 1, \"b\": null, \"c\": [1, null, {\"d\": null, \"e\": \"x\"}],\n \"f\": {\"g\": null} }");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("{\"a\":1,\"c\":[1,null,{\"e\":\"x\"}],\"f\":{}}", out);
    try std.testing.expectError(error.SyntaxError, compactJson(alloc, "{nope"));
}

test "truncateResult is UTF-8 safe and reports dropped bytes" {
    const alloc = std.testing.allocator;
    try std.testing.expect((try truncateResult(alloc, "hello", 0)) == null);
    try std.testing.expect((try truncateResult(alloc, "hello", 5)) == null);
    // "aé€𝄞" = 1 + 2 + 3 + 4 bytes. Every cut point must yield valid UTF-8.
    const text = "a\u{e9}\u{20ac}\u{1d11e}";
    try std.testing.expectEqual(@as(usize, 10), text.len);
    var max: usize = 1;
    while (max < text.len) : (max += 1) {
        const out = (try truncateResult(alloc, text, max)).?;
        defer alloc.free(out);
        try std.testing.expect(std.unicode.utf8ValidateSlice(out));
        const keep = utf8SafeLen(text, max);
        try std.testing.expect(keep <= max);
        var buf: [64]u8 = undefined;
        const note = try std.fmt.bufPrint(&buf, "\n[truncated {d} bytes; narrow the query]", .{text.len - keep});
        try std.testing.expect(std.mem.endsWith(u8, out, note));
    }
    const cut = (try truncateResult(alloc, text, 4)).?; // inside the 3-byte euro sign
    defer alloc.free(cut);
    try std.testing.expect(std.mem.startsWith(u8, cut, "a\u{e9}\n[truncated 7 bytes"));
}
