//! Tiny SQL lexer for zmcp-postgres. It does NOT parse SQL; it only walks the
//! text the way the server's scanner does (comments, quoted strings, quoted
//! identifiers, E'' escapes, dollar quotes) so that we can tell:
//!   - how many top-level statements the text holds (semicolons inside quotes
//!     or comments do not count),
//!   - whether a top-level backslash is present (a psql meta-command such as
//!     `\!` would shell out),
//!   - the first keyword (for the allowlists) and whether a `program` word
//!     appears (COPY ... PROGRAM).
//! It is a pre-filter only: read-only-ness is enforced by the database
//! (BEGIN READ ONLY + default_transaction_read_only=on), never by this file.

const std = @import("std");

pub const ScanError = error{
    /// Nothing but whitespace/comments/semicolons.
    Empty,
    /// More than one top-level statement (only when multi-statement is off).
    MultipleStatements,
    /// A backslash outside quotes/comments (psql meta-command).
    MetaCommand,
    /// Unterminated string, identifier, comment or dollar quote.
    Unterminated,
    /// NUL byte in the input.
    NulByte,
};

pub const Scan = struct {
    /// The statement text: leading/trailing whitespace, comments outside the
    /// statement and (single-statement mode) the trailing `;` removed.
    sql: []const u8,
    /// First word of the statement (original case), e.g. "SELECT".
    first: []const u8,
    /// Number of non-empty top-level statements.
    statements: usize,
    /// A bare word `program` occurs outside quotes/comments.
    has_program: bool,

    pub fn firstIs(self: Scan, kw: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.first, kw);
    }

    pub fn firstIn(self: Scan, kws: []const []const u8) bool {
        for (kws) |k| if (self.firstIs(k)) return true;
        return false;
    }
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}

fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c) or c == '$';
}

/// Lex `text`. With `allow_multi` false, a second statement is an error.
pub fn scan(text: []const u8, allow_multi: bool) ScanError!Scan {
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.NulByte;

    var i: usize = 0;
    var start: ?usize = null; // first significant byte
    var end_no_semi: usize = 0; // one past last significant non-';' byte
    var end_any: usize = 0; // one past last significant byte incl ';'
    var stmts: usize = 0;
    var open = false; // inside a statement that has content and no ';' yet
    var first: []const u8 = "";
    var has_program = false;

    while (i < text.len) {
        const c = text[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c) {
            i += 1;
            continue;
        }
        if (c == '-' and i + 1 < text.len and text[i + 1] == '-') {
            i = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
            continue;
        }
        if (c == '/' and i + 1 < text.len and text[i + 1] == '*') {
            var depth: usize = 1;
            i += 2;
            while (depth > 0) {
                if (i + 1 >= text.len) return error.Unterminated;
                if (text[i] == '/' and text[i + 1] == '*') {
                    depth += 1;
                    i += 2;
                } else if (text[i] == '*' and text[i + 1] == '/') {
                    depth -= 1;
                    i += 2;
                } else i += 1;
            }
            continue;
        }
        if (c == ';') {
            if (open) {
                stmts += 1;
                open = false;
                end_any = i + 1;
            }
            i += 1;
            continue;
        }

        // From here on `c` is significant text.
        if (!allow_multi and stmts > 0) return error.MultipleStatements;
        if (c == '\\') return error.MetaCommand;
        if (start == null) start = i;
        open = true;

        if (c == '\'') {
            i = try skipQuoted(text, i, '\'', false);
        } else if (c == '"') {
            i = try skipQuoted(text, i, '"', false);
        } else if (c == '$') {
            i = try skipDollar(text, i);
        } else if (isIdentStart(c) or std.ascii.isDigit(c)) {
            const w0 = i;
            while (i < text.len and isIdentCont(text[i])) i += 1;
            const word = text[w0..i];
            if (first.len == 0) first = word;
            if (std.ascii.eqlIgnoreCase(word, "program")) has_program = true;
            // E'..' takes backslash escapes; only a lone E/e directly before
            // the quote counts (`abe'x'` is an identifier then a plain string).
            if (word.len == 1 and (word[0] == 'e' or word[0] == 'E') and i < text.len and text[i] == '\'') {
                i = try skipQuoted(text, i, '\'', true);
            }
        } else {
            i += 1;
        }
        end_no_semi = i;
        end_any = i;
    }

    if (start == null) return error.Empty;
    if (open) stmts += 1;
    const s = start.?;
    const e = if (allow_multi) end_any else end_no_semi;
    return .{
        .sql = text[s..e],
        .first = first,
        .statements = stmts,
        .has_program = has_program,
    };
}

/// `i` points at the opening quote; returns the index one past the closing one.
fn skipQuoted(text: []const u8, open_at: usize, q: u8, backslash: bool) ScanError!usize {
    var i = open_at + 1;
    while (i < text.len) {
        const c = text[i];
        if (backslash and c == '\\') {
            i += 2;
            continue;
        }
        if (c == q) {
            if (i + 1 < text.len and text[i + 1] == q) {
                i += 2;
                continue;
            }
            return i + 1;
        }
        i += 1;
    }
    return error.Unterminated;
}

/// `i` points at a `$` that is not preceded by an identifier character.
/// Handles `$tag$ ... $tag$`; a `$1` parameter or lone `$` is plain text.
fn skipDollar(text: []const u8, at: usize) ScanError!usize {
    var j = at + 1;
    if (j < text.len and isIdentStart(text[j]) and text[j] != '$') {
        while (j < text.len and isIdentCont(text[j]) and text[j] != '$') j += 1;
    }
    if (j >= text.len or text[j] != '$') return at + 1; // $1, $, $abc (no closing $)
    const tag = text[at .. j + 1]; // includes both '$'
    const body_start = j + 1;
    const close = std.mem.indexOfPos(u8, text, body_start, tag) orelse return error.Unterminated;
    return close + tag.len;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectSql(want: []const u8, text: []const u8) !void {
    const s = try scan(text, false);
    try testing.expectEqualStrings(want, s.sql);
}

test "single statement, trailing semicolon and comments trimmed" {
    try expectSql("SELECT 1", "  SELECT 1;  ");
    try expectSql("SELECT 1", "-- hi\nSELECT 1; -- bye\n/* x */");
    try expectSql("select 1 /* mid ; */ + 2", "select 1 /* mid ; */ + 2;;;");
    const s = try scan("\n  (select 1)", false);
    try testing.expect(s.firstIs("SELECT"));
    try testing.expectEqual(@as(usize, 1), s.statements);
}

test "semicolons inside quotes, comments and dollar quotes are not separators" {
    try expectSql("SELECT 'a;b'", "SELECT 'a;b'");
    try expectSql("SELECT 'it''s;'", "SELECT 'it''s;';");
    try expectSql("SELECT \"a;b\" FROM t", "SELECT \"a;b\" FROM t");
    try expectSql("SELECT \"a\"\";b\"", "SELECT \"a\"\";b\"");
    try expectSql("SELECT 1", "SELECT 1 -- ; DROP TABLE x");
    try expectSql("SELECT /* ; /* nested ; */ ; */ 1", "SELECT /* ; /* nested ; */ ; */ 1");
    try expectSql("SELECT $$a;b$$", "SELECT $$a;b$$;");
    try expectSql("SELECT $q$ ; $$ ; $q$", "SELECT $q$ ; $$ ; $q$");
    try expectSql("SELECT $1, $2", "SELECT $1, $2");
    try expectSql("DO $f$ BEGIN PERFORM 1; END $f$", "DO $f$ BEGIN PERFORM 1; END $f$;");
}

test "multiple statements rejected" {
    try testing.expectError(error.MultipleStatements, scan("SELECT 1; DROP TABLE x", false));
    try testing.expectError(error.MultipleStatements, scan("SELECT 1;SELECT 2", false));
    try testing.expectError(error.MultipleStatements, scan("SELECT 1; -- c\n DROP TABLE x;", false));
    try testing.expectError(error.MultipleStatements, scan("SELECT 'a'; INSERT INTO t VALUES ('b')", false));
    // a semicolon hidden in a comment/quote must not fool it the other way either
    try testing.expectError(error.MultipleStatements, scan("SELECT 1 /* ; */ ; SELECT 2", false));
    const m = try scan("SELECT 1; SELECT 2;", true);
    try testing.expectEqual(@as(usize, 2), m.statements);
    try testing.expectEqualStrings("SELECT 1; SELECT 2;", m.sql);
}

test "E-strings honour backslash escapes, plain strings do not" {
    // E'\'' is one string; the ; after it is a real separator
    try testing.expectError(error.MultipleStatements, scan("SELECT E'\\'' ; DROP TABLE x", false));
    try expectSql("SELECT E'a\\';b'", "SELECT E'a\\';b'");
    try expectSql("SELECT e'x\\\\'", "SELECT e'x\\\\'"); // E'x\\' ends at the last quote
    // plain string: backslash is literal, so ' after it closes the string
    try testing.expectError(error.MultipleStatements, scan("SELECT 'a\\' ; DROP TABLE x; --'", false));
    // identifier ending in e before a quote is not an E-string
    try testing.expectError(error.MultipleStatements, scan("SELECT abe'x\\' ; DROP TABLE t; --'", false));
}

test "backslash meta-commands rejected outside quotes" {
    try testing.expectError(error.MetaCommand, scan("\\! id", false));
    try testing.expectError(error.MetaCommand, scan("SELECT 1\n\\! id", false));
    try testing.expectError(error.MetaCommand, scan("SELECT 1 \\gexec", false));
    try testing.expectError(error.MetaCommand, scan("\\c otherdb", true));
    try expectSql("SELECT 'a\\b'", "SELECT 'a\\b'"); // inside a string it is data
    try expectSql("SELECT 1", "SELECT 1 -- \\! id"); // inside a comment too
}

test "unterminated constructs, empty input and NUL" {
    try testing.expectError(error.Unterminated, scan("SELECT 'abc", false));
    try testing.expectError(error.Unterminated, scan("SELECT \"abc", false));
    try testing.expectError(error.Unterminated, scan("SELECT /* abc", false));
    try testing.expectError(error.Unterminated, scan("SELECT /* a /* b */", false));
    try testing.expectError(error.Unterminated, scan("SELECT $$abc", false));
    try testing.expectError(error.Unterminated, scan("SELECT $t$ abc $u$", false));
    try testing.expectError(error.Empty, scan("", false));
    try testing.expectError(error.Empty, scan("  ; -- c\n /* d */ ;", false));
    try testing.expectError(error.NulByte, scan("SELECT 1\x00; DROP TABLE x", false));
}

test "first keyword and program detection" {
    const a = try scan("/* c */ WITH x AS (SELECT 1) SELECT * FROM x", false);
    try testing.expect(a.firstIs("with"));
    try testing.expect(!a.has_program);
    const b = try scan("copy t to program 'id'", false);
    try testing.expect(b.firstIs("COPY"));
    try testing.expect(b.has_program);
    const c = try scan("SELECT 'program'", false);
    try testing.expect(!c.has_program);
    try testing.expect(c.firstIn(&.{ "insert", "select" }));
    try testing.expect(!c.firstIn(&.{ "insert", "delete" }));
}

test "dollar sign inside identifiers is not a dollar quote" {
    try expectSql("SELECT a$b$c FROM t", "SELECT a$b$c FROM t");
    try testing.expectError(error.MultipleStatements, scan("SELECT a$b$ ; SELECT 2", false));
}
