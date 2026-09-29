//! zmcp-wiki — drop-in replacement for the Node `wiki` extension.
//! Direct filesystem access over an Obsidian vault. No plugin required.
//!
//! Tools:
//!   wiki_search(pattern, case_insensitive?, max_hits?, subdir?)
//!   wiki_read_note(ref, max_chars?)
//!   wiki_list_notes(subdir?, limit?)
//!   wiki_backlinks(ref, max_hits?)
//!   wiki_list_tags(min_count?)
//!
//! WIKI_ROOT env var points at the vault root. Defaults to ./llm-wiki (relative to the working directory).

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


const DEFAULT_WIKI_ROOT = "llm-wiki"; // relative to the working directory; set WIKI_ROOT to override
const DEFAULT_SEARCH_HITS: usize = 80;
const DEFAULT_BACKLINK_HITS: usize = 50;
const DEFAULT_LIST_LIMIT: usize = 50;
const DEFAULT_MAX_CHARS: usize = 24000;
const SNIPPET_LEN: usize = 240;
const BACKLINK_SNIPPET_LEN: usize = 200;

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    g_env_io = init.io;
    const io = init.io;
    try mcp.run(arena, io, .{ .name = "zmcp-wiki", .version = "0.1.0" }, &tool_table);
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "wiki_search",
        .description = "Substring grep across all .md files in the vault (case-insensitive by default). Returns up to 80 file:line:snippet hits. Pattern is treated as a literal substring; for regex semantics use wiki_search via the agent's grep tool instead.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "pattern":          { "type": "string", "description": "Substring to search for." },
        \\    "case_insensitive": { "type": "boolean", "description": "Default true." },
        \\    "max_hits":         { "type": "integer", "description": "Cap (default 80)." },
        \\    "subdir":           { "type": "string",  "description": "Vault-relative subdir to restrict search to." }
        \\  },
        \\  "required": ["pattern"]
        \\}
        ,
        .handler = handleSearch,
        .read_only = true,
    },
    .{
        .name = "wiki_read_note",
        .description = "Read a note's full content. `ref` is a vault-relative path OR a bare title (resolved by basename match across the vault). Returns the file content (capped at max_chars, default 24000).",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "ref":       { "type": "string" },
        \\    "max_chars": { "type": "integer", "description": "Cap (default 24000)." }
        \\  },
        \\  "required": ["ref"]
        \\}
        ,
        .handler = handleReadNote,
        .read_only = true,
    },
    .{
        .name = "wiki_list_notes",
        .description = "List notes (sorted by mtime descending). Returns relative path, size, modified.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "subdir": { "type": "string",  "description": "Vault-relative subdir; omit for whole vault." },
        \\    "limit":  { "type": "integer", "description": "Default 50." }
        \\  }
        \\}
        ,
        .handler = handleListNotes,
        .read_only = true,
    },
    .{
        .name = "wiki_backlinks",
        .description = "Find notes that link to the target. Matches Obsidian wikilinks ([[Title]] or [[Title|alias]]) AND markdown links ([text](.../title.md)). Target may be a bare title or a vault-relative path.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "ref":      { "type": "string", "description": "Note title or vault-relative path." },
        \\    "max_hits": { "type": "integer", "description": "Cap (default 50)." }
        \\  },
        \\  "required": ["ref"]
        \\}
        ,
        .handler = handleBacklinks,
        .read_only = true,
    },
    .{
        .name = "wiki_list_tags",
        .description = "List all #tags found across the vault with usage counts (sorted desc). Excludes code fences and inline code.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "min_count": { "type": "integer", "description": "Drop tags below this count (default 1)." }
        \\  }
        \\}
        ,
        .handler = handleListTags,
        .read_only = true,
    },
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn wikiRoot(alloc: std.mem.Allocator) ![]u8 {
    if (envOwned(alloc, "WIKI_ROOT")) |v| {
        // Normalise backslashes to forward slashes.
        for (v) |*c| if (c.* == '\\') {
            c.* = '/';
        };
        return v;
    } else {
        return try alloc.dupe(u8, DEFAULT_WIKI_ROOT);
    }
}

fn getStr(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
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

fn getBool(args: std.json.Value, key: []const u8, default: bool) bool {
    if (args != .object) return default;
    const v = args.object.get(key) orelse return default;
    return switch (v) {
        .bool => |b| b,
        else => default,
    };
}

/// Walk the vault and return all .md file paths (forward-slash, absolute).
fn listAllNotes(
    alloc: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |p| alloc.free(p);
        out.deinit(alloc);
    }

    var root_dir = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch |err| {
        std.log.err("wiki: open root '{s}' failed: {s}", .{ root_path, @errorName(err) });
        return err;
    };
    defer root_dir.close(io);

    var walker = try root_dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        // Skip .obsidian, .git, node_modules at any depth.
        if (std.mem.indexOf(u8, entry.path, ".obsidian") != null) continue;
        if (std.mem.indexOf(u8, entry.path, ".git") != null) continue;
        if (std.mem.indexOf(u8, entry.path, "node_modules") != null) continue;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;

        // Build absolute path with forward slashes.
        var path_buf: std.Io.Writer.Allocating = .init(alloc);
        defer path_buf.deinit();
        try path_buf.writer.writeAll(root_path);
        try path_buf.writer.writeByte('/');
        try path_buf.writer.writeAll(entry.path);
        // Normalise backslashes in the relative tail.
        const total = try alloc.dupe(u8, path_buf.written());
        for (total) |*c| if (c.* == '\\') {
            c.* = '/';
        };
        try out.append(alloc, total);
    }
    return out;
}

fn basenameNoExt(p: []const u8) []const u8 {
    const base = std.fs.path.basename(p);
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| return base[0..dot];
    return base;
}

fn asciiToLower(buf: []u8) void {
    for (buf) |*c| c.* = std.ascii.toLower(c.*);
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return null;
}

fn relPath(abs: []const u8, root: []const u8) []const u8 {
    if (std.mem.startsWith(u8, abs, root) and abs.len > root.len + 1 and abs[root.len] == '/') {
        return abs[root.len + 1 ..];
    }
    return abs;
}

// ---------------------------------------------------------------------------
// wiki_search
// ---------------------------------------------------------------------------

fn handleSearch(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const pattern = getStr(args, "pattern") orelse return .{ .text = "error: pattern required", .is_error = true };
    if (pattern.len == 0) return .{ .text = "error: pattern required", .is_error = true };

    const ci = getBool(args, "case_insensitive", true);
    const max = @as(usize, @intCast(@max(1, getInt(args, "max_hits", @as(i64, @intCast(DEFAULT_SEARCH_HITS))))));
    const subdir = getStr(args, "subdir");

    const root = try wikiRoot(alloc);
    const search_root: []u8 = if (subdir) |sd|
        try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, sd })
    else
        try alloc.dupe(u8, root);

    var notes = listAllNotes(alloc, io, search_root) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "error opening vault '{s}': {s}", .{ search_root, @errorName(err) }), .is_error = true };
    };
    defer {
        for (notes.items) |p| alloc.free(p);
        notes.deinit(alloc);
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    var hit_count: usize = 0;
    for (notes.items) |abs| {
        if (hit_count >= max) break;
        const content = std.Io.Dir.cwd().readFileAlloc(io, abs, alloc, .limited(4 * 1024 * 1024)) catch continue;
        defer alloc.free(content);

        var line_no: usize = 0;
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line| {
            line_no += 1;
            const matched: bool = if (ci)
                (indexOfIgnoreCase(line, pattern) != null)
            else
                (std.mem.indexOf(u8, line, pattern) != null);
            if (matched) {
                const trim_line = std.mem.trim(u8, line, " \t\r");
                const snippet_end = @min(trim_line.len, SNIPPET_LEN);
                try out.writer.print(
                    "{s}:{d}: {s}\n",
                    .{ relPath(abs, root), line_no, trim_line[0..snippet_end] },
                );
                hit_count += 1;
                if (hit_count >= max) break;
            }
        }
    }

    return .{
        .text = try std.fmt.allocPrint(alloc, "{d} hit(s):\n{s}", .{ hit_count, out.written() }),
    };
}

// ---------------------------------------------------------------------------
// wiki_read_note
// ---------------------------------------------------------------------------

fn resolveRef(alloc: std.mem.Allocator, io: std.Io, root: []const u8, ref: []const u8) !?[]u8 {
    // Try direct vault-relative path.
    const direct = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, ref });
    if (std.Io.Dir.cwd().statFile(io, direct, .{})) |s| {
        if (s.kind == .file) return direct;
    } else |_| {}

    if (!std.mem.endsWith(u8, ref, ".md")) {
        const with_ext = try std.fmt.allocPrint(alloc, "{s}/{s}.md", .{ root, ref });
        if (std.Io.Dir.cwd().statFile(io, with_ext, .{})) |s| {
            if (s.kind == .file) return with_ext;
        } else |_| {}
        alloc.free(with_ext);
    }
    alloc.free(direct);

    // Fall back to basename match across the vault.
    var notes = try listAllNotes(alloc, io, root);
    defer {
        for (notes.items) |p| alloc.free(p);
        notes.deinit(alloc);
    }

    const ref_lower = try alloc.dupe(u8, ref);
    defer alloc.free(ref_lower);
    const stripped: []u8 = if (std.mem.endsWith(u8, ref_lower, ".md"))
        ref_lower[0 .. ref_lower.len - 3]
    else
        ref_lower;
    asciiToLower(stripped);

    var candidates: std.ArrayList([]const u8) = .empty;
    defer candidates.deinit(alloc);

    for (notes.items) |p| {
        const base = basenameNoExt(p);
        // case-insensitive compare
        if (base.len != stripped.len) continue;
        var match = true;
        for (base, 0..) |c, i| {
            if (std.ascii.toLower(c) != stripped[i]) {
                match = false;
                break;
            }
        }
        if (match) try candidates.append(alloc, p);
    }

    if (candidates.items.len == 0) return null;
    if (candidates.items.len > 1) return error.AmbiguousRef;
    return try alloc.dupe(u8, candidates.items[0]);
}

fn handleReadNote(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const ref = getStr(args, "ref") orelse return .{ .text = "error: ref required", .is_error = true };
    const max_chars = @as(usize, @intCast(@max(1, getInt(args, "max_chars", @as(i64, @intCast(DEFAULT_MAX_CHARS))))));

    const root = try wikiRoot(alloc);

    const resolved = resolveRef(alloc, io, root, ref) catch |err| switch (err) {
        error.AmbiguousRef => return .{
            .text = try std.fmt.allocPrint(alloc, "ambiguous ref '{s}': multiple basename matches", .{ref}),
            .is_error = true,
        },
        else => return .{
            .text = try std.fmt.allocPrint(alloc, "wiki_read_note failed: {s}", .{@errorName(err)}),
            .is_error = true,
        },
    };
    if (resolved == null) return .{
        .text = try std.fmt.allocPrint(alloc, "(no note found for ref '{s}')", .{ref}),
    };
    const path = resolved.?;

    const content = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(8 * 1024 * 1024)) catch |err| {
        return .{
            .text = try std.fmt.allocPrint(alloc, "wiki_read_note read failed: {s}", .{@errorName(err)}),
            .is_error = true,
        };
    };

    const trimmed: []const u8 = if (content.len > max_chars) content[0..max_chars] else content;
    const suffix: []const u8 = if (content.len > max_chars)
        try std.fmt.allocPrint(alloc, "\n\n... (truncated, {d} more chars)", .{content.len - max_chars})
    else
        "";

    return .{
        .text = try std.fmt.allocPrint(
            alloc,
            "=== {s} ({d} chars) ===\n{s}{s}",
            .{ relPath(path, root), content.len, trimmed, suffix },
        ),
    };
}

// ---------------------------------------------------------------------------
// wiki_list_notes
// ---------------------------------------------------------------------------

const NoteStat = struct {
    path: []const u8,
    size: u64,
    mtime_ms: i64,
};

fn handleListNotes(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const limit = @as(usize, @intCast(@max(1, getInt(args, "limit", @as(i64, @intCast(DEFAULT_LIST_LIMIT))))));
    const subdir = getStr(args, "subdir");
    const root = try wikiRoot(alloc);
    const search_root: []u8 = if (subdir) |sd|
        try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, sd })
    else
        try alloc.dupe(u8, root);

    var notes = listAllNotes(alloc, io, search_root) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "error: {s}", .{@errorName(err)}), .is_error = true };
    };
    defer {
        for (notes.items) |p| alloc.free(p);
        notes.deinit(alloc);
    }

    var stats: std.ArrayList(NoteStat) = .empty;
    defer stats.deinit(alloc);
    for (notes.items) |abs| {
        const s = std.Io.Dir.cwd().statFile(io, abs, .{}) catch continue;
        try stats.append(alloc, .{
            .path = abs,
            .size = s.size,
            .mtime_ms = s.mtime.toMilliseconds(),
        });
    }

    std.mem.sort(NoteStat, stats.items, {}, struct {
        fn lessThan(_: void, a: NoteStat, b: NoteStat) bool {
            return a.mtime_ms > b.mtime_ms;
        }
    }.lessThan);

    const take = @min(stats.items.len, limit);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("{d} note(s):\n", .{take});

    var js = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try js.beginArray();
    var iso_buf: [40]u8 = undefined;
    for (stats.items[0..take]) |st| {
        try js.beginObject();
        try js.objectField("path");
        try js.write(relPath(st.path, root));
        try js.objectField("size");
        try js.write(st.size);
        try js.objectField("modified");
        try js.write(formatIso(&iso_buf, st.mtime_ms));
        try js.endObject();
    }
    try js.endArray();

    return .{ .text = try alloc.dupe(u8, out.written()) };
}

fn formatIso(buf: []u8, ts_ms: i64) []u8 {
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, @divFloor(ts_ms, 1000))) };
    const day_secs = epoch_secs.getDaySeconds();
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const ms: u32 = @intCast(@mod(ts_ms, 1000));
    const year_u: u32 = @intCast(year_day.year);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year_u,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
        ms,
    }) catch unreachable;
}

// ---------------------------------------------------------------------------
// wiki_backlinks
// ---------------------------------------------------------------------------

fn handleBacklinks(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const ref = getStr(args, "ref") orelse return .{ .text = "error: ref required", .is_error = true };
    const max = @as(usize, @intCast(@max(1, getInt(args, "max_hits", @as(i64, @intCast(DEFAULT_BACKLINK_HITS))))));

    const root = try wikiRoot(alloc);
    const ref_clean: []const u8 = if (std.mem.endsWith(u8, ref, ".md")) ref[0 .. ref.len - 3] else ref;
    const title = std.fs.path.basename(ref_clean);

    var notes = listAllNotes(alloc, io, root) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "error opening vault: {s}", .{@errorName(err)}), .is_error = true };
    };
    defer {
        for (notes.items) |p| alloc.free(p);
        notes.deinit(alloc);
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    var hit_count: usize = 0;
    for (notes.items) |abs| {
        if (hit_count >= max) break;
        const content = std.Io.Dir.cwd().readFileAlloc(io, abs, alloc, .limited(4 * 1024 * 1024)) catch continue;
        defer alloc.free(content);

        var line_no: usize = 0;
        var line_it = std.mem.splitScalar(u8, content, '\n');
        while (line_it.next()) |line| {
            line_no += 1;
            if (lineLinksTo(line, title)) {
                const trim_line = std.mem.trim(u8, line, " \t\r");
                const snippet_end = @min(trim_line.len, BACKLINK_SNIPPET_LEN);
                try out.writer.print("{s}:{d}: {s}\n", .{ relPath(abs, root), line_no, trim_line[0..snippet_end] });
                hit_count += 1;
                if (hit_count >= max) break;
            }
        }
    }

    return .{
        .text = try std.fmt.allocPrint(alloc, "{d} backlink(s) to '{s}':\n{s}", .{ hit_count, title, out.written() }),
    };
}

/// Detect Obsidian wikilinks [[Title]] or [[Title|alias]] and markdown links
/// [text](relative/title.md) referencing the given title.
fn lineLinksTo(line: []const u8, title: []const u8) bool {
    // Wikilink scan: look for [[ then title then optional alias or ]]
    var i: usize = 0;
    while (i + 1 < line.len) : (i += 1) {
        if (line[i] == '[' and line[i + 1] == '[') {
            const inner_start = i + 2;
            const inner_end = std.mem.indexOfPos(u8, line, inner_start, "]]") orelse break;
            const inner = line[inner_start..inner_end];
            // [[Title|alias]] or [[Title]]; we allow leading whitespace/slashes
            const trimmed = std.mem.trim(u8, inner, " \t");
            // Strip alias if any.
            const target_end = std.mem.indexOfScalar(u8, trimmed, '|') orelse trimmed.len;
            const target = std.mem.trim(u8, trimmed[0..target_end], " \t");
            // Match if the bare title equals our target's basename (case-insensitive),
            // OR if our title appears as the last path segment.
            const seg = std.fs.path.basename(target);
            const seg_no_ext: []const u8 = if (std.mem.endsWith(u8, seg, ".md")) seg[0 .. seg.len - 3] else seg;
            if (eqlIgnoreCase(seg_no_ext, title)) return true;
            i = inner_end + 1;
        }
    }
    // Markdown link scan: ](...title[.md]) [#anchor] )
    // Cheaper: substring "/<title>.md" or "<title>.md" right after a "]("
    if (std.mem.indexOf(u8, line, "](")) |mdl| {
        var pos: usize = mdl;
        while (true) {
            const open = std.mem.indexOfPos(u8, line, pos, "](") orelse break;
            const close = std.mem.indexOfScalarPos(u8, line, open + 2, ')') orelse line.len;
            const url = line[open + 2 .. close];
            // Strip optional #anchor.
            const hash_idx = std.mem.indexOfScalar(u8, url, '#') orelse url.len;
            const url_path = url[0..hash_idx];
            const seg = std.fs.path.basename(std.mem.trim(u8, url_path, " \t"));
            const seg_no_ext: []const u8 = if (std.mem.endsWith(u8, seg, ".md")) seg[0 .. seg.len - 3] else seg;
            if (eqlIgnoreCase(seg_no_ext, title)) return true;
            pos = close + 1;
            if (pos >= line.len) break;
        }
    }
    return false;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// wiki_list_tags
// ---------------------------------------------------------------------------

fn isTagChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '/';
}

fn handleListTags(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const min_count = @max(1, getInt(args, "min_count", 1));
    const root = try wikiRoot(alloc);

    var notes = listAllNotes(alloc, io, root) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "error: {s}", .{@errorName(err)}), .is_error = true };
    };
    defer {
        for (notes.items) |p| alloc.free(p);
        notes.deinit(alloc);
    }

    // Map tag -> count.
    var counts = std.StringHashMap(usize).init(alloc);
    defer {
        var it = counts.iterator();
        while (it.next()) |e| alloc.free(e.key_ptr.*);
        counts.deinit();
    }

    for (notes.items) |abs| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, abs, alloc, .limited(4 * 1024 * 1024)) catch continue;
        defer alloc.free(text);
        try scanTags(alloc, &counts, text);
    }

    const TagCount = struct { tag: []const u8, count: usize };
    var rows: std.ArrayList(TagCount) = .empty;
    defer rows.deinit(alloc);
    var iter = counts.iterator();
    while (iter.next()) |e| {
        if (e.value_ptr.* >= min_count) {
            try rows.append(alloc, .{ .tag = e.key_ptr.*, .count = e.value_ptr.* });
        }
    }
    std.mem.sort(TagCount, rows.items, {}, struct {
        fn lt(_: void, a: TagCount, b: TagCount) bool {
            if (a.count == b.count) return std.mem.lessThan(u8, a.tag, b.tag);
            return a.count > b.count;
        }
    }.lt);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("{d} tag(s):\n", .{rows.items.len});
    var js = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try js.beginArray();
    for (rows.items) |r| {
        try js.beginObject();
        try js.objectField("tag");
        try js.write(r.tag);
        try js.objectField("count");
        try js.write(r.count);
        try js.endObject();
    }
    try js.endArray();

    return .{ .text = try alloc.dupe(u8, out.written()) };
}

/// Scan text for `#tag` occurrences, excluding code fences (```...```) and
/// inline backtick spans. Tag := alpha/digit/_/-/ followed by chars (must
/// start with alpha or digit per Obsidian convention).
fn scanTags(
    alloc: std.mem.Allocator,
    counts: *std.StringHashMap(usize),
    text: []const u8,
) !void {
    var i: usize = 0;
    var in_fence = false;
    var in_inline = false;

    while (i < text.len) {
        // Fence delimiter ```
        if (!in_inline and i + 2 < text.len and text[i] == '`' and text[i + 1] == '`' and text[i + 2] == '`') {
            in_fence = !in_fence;
            i += 3;
            continue;
        }
        if (in_fence) {
            i += 1;
            continue;
        }
        if (text[i] == '`') {
            in_inline = !in_inline;
            i += 1;
            continue;
        }
        if (in_inline) {
            i += 1;
            continue;
        }

        if (text[i] == '#') {
            // Must be at start-of-line OR preceded by whitespace.
            const prev_ok = i == 0 or std.ascii.isWhitespace(text[i - 1]);
            if (!prev_ok) {
                i += 1;
                continue;
            }
            // First char after # must be alpha/digit/underscore (not heading).
            if (i + 1 >= text.len) break;
            const first = text[i + 1];
            if (!(std.ascii.isAlphabetic(first) or first == '_')) {
                i += 1;
                continue;
            }
            // Scan tag body.
            var end = i + 1;
            while (end < text.len and isTagChar(text[end])) end += 1;
            const tag = text[i + 1 .. end];
            if (tag.len > 0) {
                const owned = try alloc.dupe(u8, tag);
                const gop = try counts.getOrPut(owned);
                if (gop.found_existing) {
                    alloc.free(owned);
                    gop.value_ptr.* += 1;
                } else {
                    gop.value_ptr.* = 1;
                }
            }
            i = end;
            continue;
        }

        i += 1;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "basenameNoExt strips .md" {
    try std.testing.expectEqualStrings("foo", basenameNoExt("docs/foo.md"));
    try std.testing.expectEqualStrings("bar", basenameNoExt("bar"));
}

test "indexOfIgnoreCase basic" {
    try std.testing.expectEqual(@as(?usize, 4), indexOfIgnoreCase("foo BAR baz", "bar"));
    try std.testing.expect(indexOfIgnoreCase("foo", "z") == null);
}

test "lineLinksTo wikilink" {
    try std.testing.expect(lineLinksTo("see [[foo]] and [[bar|Bar]]", "foo"));
    try std.testing.expect(lineLinksTo("see [[bar|Bar]]", "bar"));
    try std.testing.expect(!lineLinksTo("see [[other]]", "foo"));
}

test "lineLinksTo markdown link" {
    try std.testing.expect(lineLinksTo("see [text](path/foo.md)", "foo"));
    try std.testing.expect(lineLinksTo("with anchor [text](path/foo.md#sec)", "foo"));
    try std.testing.expect(!lineLinksTo("see [text](path/other.md)", "foo"));
}

test "scanTags basic" {
    const alloc = std.testing.allocator;
    var counts = std.StringHashMap(usize).init(alloc);
    defer {
        var it = counts.iterator();
        while (it.next()) |e| alloc.free(e.key_ptr.*);
        counts.deinit();
    }
    try scanTags(alloc, &counts, "Some text #foo and #bar and #foo again. A #baz here.");
    try std.testing.expectEqual(@as(usize, 2), counts.get("foo").?);
    try std.testing.expectEqual(@as(usize, 1), counts.get("bar").?);
    try std.testing.expectEqual(@as(usize, 1), counts.get("baz").?);
}

test "scanTags ignores fences and inline code" {
    const alloc = std.testing.allocator;
    var counts = std.StringHashMap(usize).init(alloc);
    defer {
        var it = counts.iterator();
        while (it.next()) |e| alloc.free(e.key_ptr.*);
        counts.deinit();
    }
    try scanTags(alloc, &counts, "Use `#fake` not real. ```\n#alsofake\n``` But #real exists.");
    try std.testing.expectEqual(@as(usize, 1), counts.get("real").?);
    try std.testing.expect(counts.get("fake") == null);
    try std.testing.expect(counts.get("alsofake") == null);
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
