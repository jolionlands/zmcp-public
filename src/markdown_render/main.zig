//! zmcp-markdown-render - pure-Zig port of the local Node `markdown_render`.
//! Renders Markdown to ANSI for terminal display and extracts fenced code.

const std = @import("std");
const mcp = @import("mcp");

const RESET = "\x1b[0m";
const H1 = "\x1b[1;95m";
const H2 = "\x1b[1;96m";
const H3 = "\x1b[1;36m";
const H4 = "\x1b[1;94m";
const H5 = "\x1b[1;34m";
const H6 = "\x1b[1;90m";
const BOLD = "\x1b[1;97m";
const ITALIC = "\x1b[3;37m";
const CODE = "\x1b[93m";
const CODE_BLOCK = "\x1b[93m";
const CODE_FENCE = "\x1b[2;90m";
const LINK = "\x1b[4;94m";
const URL = "\x1b[2;90m";
const BLOCKQUOTE = "\x1b[90m";
const HR = "\x1b[2;90m";
const LIST = "\x1b[1;92m";
const TABLE_BORDER = "\x1b[2;90m";
const TABLE_HEAD = "\x1b[1;96m";
const STRIKE = "\x1b[9;90m";

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    const io = init.io;
    try mcp.run(arena, io, .{ .name = "zmcp-markdown-render", .version = "0.1.0" }, &tool_table);
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "md_render",
        .read_only = true,
        .description = "Render Markdown text to ANSI for terminal display. Covers headings, lists, fenced code, links, blockquotes, horizontal rules, simple tables, and common inline emphasis.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "markdown": { "type": "string", "description": "Markdown source." },
        \\    "width": { "type": "integer", "description": "Target width in columns. Default 100." }
        \\  },
        \\  "required": ["markdown"]
        \\}
        ,
        .handler = handleRender,
    },
    .{
        .name = "md_render_file",
        .read_only = true,
        .description = "Read a Markdown file from disk and render it to ANSI.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "path": { "type": "string", "description": "Absolute or cwd-relative path to a Markdown file." },
        \\    "width": { "type": "integer", "description": "Target width in columns. Default 100." }
        \\  },
        \\  "required": ["path"]
        \\}
        ,
        .handler = handleRenderFile,
    },
    .{
        .name = "md_extract_code",
        .read_only = true,
        .description = "Extract fenced code blocks from Markdown. Accepts inline markdown or a file path, and can filter by language tag.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "markdown": { "type": "string", "description": "Markdown source. Mutually exclusive with path." },
        \\    "path": { "type": "string", "description": "File to read instead of markdown." },
        \\    "lang": { "type": "string", "description": "Optional language filter, e.g. 'zig' or 'js'." }
        \\  }
        \\}
        ,
        .handler = handleExtractCode,
    },
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

fn readTextFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(8 * 1024 * 1024));
}

fn trimCR(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn trimLeftSpaces(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    return s[i..];
}

fn trimTrailingNewlines(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and s[end - 1] == '\n') : (end -= 1) {}
    return s[0..end];
}

fn appendWrapped(out: *std.ArrayList(u8), alloc: std.mem.Allocator, style: []const u8, text: []const u8) !void {
    try out.appendSlice(alloc, style);
    try out.appendSlice(alloc, text);
    try out.appendSlice(alloc, RESET);
}

fn appendWrappedOwned(out: *std.ArrayList(u8), alloc: std.mem.Allocator, style: []const u8, text: []const u8) !void {
    defer alloc.free(text);
    try appendWrapped(out, alloc, style, text);
}

fn findNext(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    if (start >= haystack.len) return null;
    const off = std.mem.indexOf(u8, haystack[start..], needle) orelse return null;
    return start + off;
}

fn stripAnsiLen(s: []const u8) usize {
    var i: usize = 0;
    var out_len: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
            i += 2;
            while (i < s.len and s[i] != 'm') : (i += 1) {}
            if (i < s.len) i += 1;
            continue;
        }
        out_len += 1;
        i += 1;
    }
    return out_len;
}

fn renderInline(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == '!' and text[i + 1] == '[') {
            if (findNext(text, i + 2, "](")) |mid| {
                if (findNext(text, mid + 2, ")")) |end| {
                    const alt = text[i + 2 .. mid];
                    const url = text[mid + 2 .. end];
                    try appendWrapped(&out, alloc, BOLD, "[img:");
                    try out.appendSlice(alloc, alt);
                    try appendWrapped(&out, alloc, BOLD, "]");
                    try out.append(alloc, ' ');
                    var url_buf: std.ArrayList(u8) = .empty;
                    defer url_buf.deinit(alloc);
                    try url_buf.append(alloc, '<');
                    try url_buf.appendSlice(alloc, url);
                    try url_buf.append(alloc, '>');
                    try appendWrapped(&out, alloc, URL, url_buf.items);
                    i = end + 1;
                    continue;
                }
            }
        }
        if (text[i] == '[') {
            if (findNext(text, i + 1, "](")) |mid| {
                if (findNext(text, mid + 2, ")")) |end| {
                    const label = text[i + 1 .. mid];
                    const url = text[mid + 2 .. end];
                    try appendWrapped(&out, alloc, LINK, label);
                    try out.append(alloc, ' ');
                    var url_buf: std.ArrayList(u8) = .empty;
                    defer url_buf.deinit(alloc);
                    try url_buf.append(alloc, '<');
                    try url_buf.appendSlice(alloc, url);
                    try url_buf.append(alloc, '>');
                    try appendWrapped(&out, alloc, URL, url_buf.items);
                    i = end + 1;
                    continue;
                }
            }
        }
        if (text[i] == '`') {
            if (findNext(text, i + 1, "`")) |end| {
                try appendWrapped(&out, alloc, CODE, text[i + 1 .. end]);
                i = end + 1;
                continue;
            }
        }
        if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            if (findNext(text, i + 2, "**")) |end| {
                try appendWrapped(&out, alloc, BOLD, text[i + 2 .. end]);
                i = end + 2;
                continue;
            }
        }
        if (i + 1 < text.len and text[i] == '_' and text[i + 1] == '_') {
            if (findNext(text, i + 2, "__")) |end| {
                try appendWrapped(&out, alloc, BOLD, text[i + 2 .. end]);
                i = end + 2;
                continue;
            }
        }
        if (i + 1 < text.len and text[i] == '~' and text[i + 1] == '~') {
            if (findNext(text, i + 2, "~~")) |end| {
                try appendWrapped(&out, alloc, STRIKE, text[i + 2 .. end]);
                i = end + 2;
                continue;
            }
        }
        if (text[i] == '*') {
            if (findNext(text, i + 1, "*")) |end| {
                if (end > i + 1) {
                    try appendWrapped(&out, alloc, ITALIC, text[i + 1 .. end]);
                    i = end + 1;
                    continue;
                }
            }
        }
        if (text[i] == '_') {
            if (findNext(text, i + 1, "_")) |end| {
                if (end > i + 1) {
                    try appendWrapped(&out, alloc, ITALIC, text[i + 1 .. end]);
                    i = end + 1;
                    continue;
                }
            }
        }
        try out.append(alloc, text[i]);
        i += 1;
    }

    return out.toOwnedSlice(alloc);
}

fn isHrLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 3) return false;
    for (trimmed) |c| {
        if (c != '-' and c != '*' and c != '_') return false;
    }
    return true;
}

fn isTableSepLine(line: []const u8) bool {
    if (std.mem.indexOfScalar(u8, line, '|') == null) return false;
    var it = std.mem.splitScalar(u8, line, '|');
    var seen = false;
    while (it.next()) |cell| {
        const trimmed = std.mem.trim(u8, cell, " \t");
        if (trimmed.len == 0) continue;
        seen = true;
        for (trimmed) |c| {
            if (c != '-' and c != ':' and c != ' ') return false;
        }
    }
    return seen;
}

fn splitTableRow(alloc: std.mem.Allocator, line: []const u8) !std.ArrayList([]u8) {
    var s = line;
    s = std.mem.trim(u8, s, " \t");
    if (s.len > 0 and s[0] == '|') s = s[1..];
    if (s.len > 0 and s[s.len - 1] == '|') s = s[0 .. s.len - 1];

    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |cell| alloc.free(cell);
        out.deinit(alloc);
    }
    var it = std.mem.splitScalar(u8, s, '|');
    while (it.next()) |cell| {
        try out.append(alloc, try alloc.dupe(u8, std.mem.trim(u8, cell, " \t")));
    }
    return out;
}

fn renderTable(alloc: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    var rows: std.ArrayList(std.ArrayList([]u8)) = .empty;
    defer {
        for (rows.items) |*row| {
            for (row.items) |cell| alloc.free(cell);
            row.deinit(alloc);
        }
        rows.deinit(alloc);
    }

    for (lines) |line| try rows.append(alloc, try splitTableRow(alloc, line));
    if (rows.items.len < 2) return alloc.dupe(u8, "");

    const cols = rows.items[0].items.len;
    var widths = try alloc.alloc(usize, cols);
    defer alloc.free(widths);
    @memset(widths, 0);

    for (rows.items, 0..) |row, row_idx| {
        if (row_idx == 1) continue;
        for (row.items, 0..) |cell, col| {
            widths[col] = @max(widths[col], cell.len);
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    const writeSep = struct {
        fn f(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, ws: []usize) !void {
            try buf.appendSlice(allocator, TABLE_BORDER);
            try buf.append(allocator, '+');
            for (ws) |w| {
                try buf.appendNTimes(allocator, '-', w + 2);
                try buf.append(allocator, '+');
            }
            try buf.appendSlice(allocator, RESET);
            try buf.append(allocator, '\n');
        }
    }.f;

    try writeSep(&out, alloc, widths);
    for (rows.items, 0..) |row, row_idx| {
        if (row_idx == 1) continue;
        try out.appendSlice(alloc, TABLE_BORDER);
        try out.append(alloc, '|');
        try out.appendSlice(alloc, RESET);
        for (row.items, 0..) |cell, col| {
            try out.append(alloc, ' ');
            if (row_idx == 0) {
                try appendWrapped(&out, alloc, TABLE_HEAD, cell);
            } else {
                try out.appendSlice(alloc, cell);
            }
            const pad = widths[col] - cell.len;
            if (pad > 0) try out.appendNTimes(alloc, ' ', pad);
            try out.append(alloc, ' ');
            try out.appendSlice(alloc, TABLE_BORDER);
            try out.append(alloc, '|');
            try out.appendSlice(alloc, RESET);
        }
        try out.append(alloc, '\n');
        if (row_idx == 0) try writeSep(&out, alloc, widths);
    }
    try writeSep(&out, alloc, widths);
    if (out.items.len > 0 and out.items[out.items.len - 1] == '\n') _ = out.pop();
    return out.toOwnedSlice(alloc);
}

fn renderMarkdown(alloc: std.mem.Allocator, src: []const u8, width: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var lines = std.mem.splitScalar(u8, src, '\n');
    var in_fence = false;
    var fence_lang: []const u8 = "";
    var fence_buf: std.ArrayList([]u8) = .empty;
    defer {
        for (fence_buf.items) |line| alloc.free(line);
        fence_buf.deinit(alloc);
    }
    var table_buf: std.ArrayList([]u8) = .empty;
    defer {
        for (table_buf.items) |line| alloc.free(line);
        table_buf.deinit(alloc);
    }

    const flushTable = struct {
        fn f(buf: *std.ArrayList([]u8), out_buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
            if (buf.items.len == 0) return;
            var refs: std.ArrayList([]const u8) = .empty;
            defer refs.deinit(allocator);
            for (buf.items) |line| try refs.append(allocator, line);
            const rendered = try renderTable(allocator, refs.items);
            defer allocator.free(rendered);
            try out_buf.appendSlice(allocator, rendered);
            try out_buf.append(allocator, '\n');
            for (buf.items) |line| allocator.free(line);
            buf.clearRetainingCapacity();
        }
    }.f;

    while (lines.next()) |raw_line| {
        const line = trimCR(raw_line);
        if (!in_fence and std.mem.startsWith(u8, line, "```")) {
            try flushTable(&table_buf, &out, alloc);
            in_fence = true;
            fence_lang = std.mem.trim(u8, line[3..], " \t");
            continue;
        }
        if (in_fence) {
            if (std.mem.eql(u8, std.mem.trim(u8, line, " \t"), "```")) {
                try out.appendSlice(alloc, CODE_FENCE);
                try out.appendSlice(alloc, "  +---");
                if (fence_lang.len > 0) {
                    try out.append(alloc, ' ');
                    try out.appendSlice(alloc, fence_lang);
                    try out.append(alloc, ' ');
                } else {
                    try out.appendSlice(alloc, "  ");
                }
                const used = if (fence_lang.len > 0) 7 + fence_lang.len else 7;
                if (width > used) try out.appendNTimes(alloc, '-', width - used);
                try out.appendSlice(alloc, "+" ++ RESET ++ "\n");
                for (fence_buf.items) |fline| {
                    try out.appendSlice(alloc, "  ");
                    try appendWrapped(&out, alloc, CODE_BLOCK, fline);
                    try out.append(alloc, '\n');
                }
                try out.appendSlice(alloc, CODE_FENCE);
                try out.appendSlice(alloc, "  +");
                if (width > 4) try out.appendNTimes(alloc, '-', width - 4);
                try out.appendSlice(alloc, "+" ++ RESET ++ "\n");
                for (fence_buf.items) |fline| alloc.free(fline);
                fence_buf.clearRetainingCapacity();
                in_fence = false;
                fence_lang = "";
                continue;
            }
            try fence_buf.append(alloc, try alloc.dupe(u8, line));
            continue;
        }

        if (std.mem.indexOfScalar(u8, line, '|') != null) {
            if (table_buf.items.len == 0) {
                try table_buf.append(alloc, try alloc.dupe(u8, line));
                continue;
            } else if (table_buf.items.len == 1 and isTableSepLine(line)) {
                try table_buf.append(alloc, try alloc.dupe(u8, line));
                continue;
            } else if (table_buf.items.len >= 2) {
                try table_buf.append(alloc, try alloc.dupe(u8, line));
                continue;
            }
        }
        try flushTable(&table_buf, &out, alloc);

        if (line.len == 0) {
            try out.append(alloc, '\n');
            continue;
        }
        if (isHrLine(line)) {
            try appendWrappedOwned(&out, alloc, HR, try alloc.dupe(u8, try std.fmt.allocPrint(alloc, "{s}", .{"-"}) ));
            _ = out.pop();
        }

        var heading_level: usize = 0;
        while (heading_level < line.len and line[heading_level] == '#') : (heading_level += 1) {}
        if (heading_level > 0 and heading_level <= 6 and heading_level < line.len and line[heading_level] == ' ') {
            const rendered = try renderInline(alloc, line[heading_level + 1 ..]);
            defer alloc.free(rendered);
            const style = switch (heading_level) {
                1 => H1,
                2 => H2,
                3 => H3,
                4 => H4,
                5 => H5,
                else => H6,
            };
            try out.appendSlice(alloc, style);
            try out.appendNTimes(alloc, '#', heading_level);
            try out.append(alloc, ' ');
            try out.appendSlice(alloc, rendered);
            try out.appendSlice(alloc, RESET ++ "\n");
            if (heading_level == 1 or heading_level == 2) {
                try out.appendSlice(alloc, style);
                try out.appendNTimes(alloc, if (heading_level == 1) '=' else '-', @min(width, stripAnsiLen(rendered) + 2));
                try out.appendSlice(alloc, RESET ++ "\n");
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, ">")) {
            const body = trimLeftSpaces(line[1..]);
            const rendered = try renderInline(alloc, body);
            defer alloc.free(rendered);
            try out.appendSlice(alloc, BLOCKQUOTE ++ "  > ");
            try out.appendSlice(alloc, rendered);
            try out.appendSlice(alloc, RESET ++ "\n");
            continue;
        }

        const trimmed_left = trimLeftSpaces(line);
        const indent_len = line.len - trimmed_left.len;
        if (trimmed_left.len >= 2 and (trimmed_left[0] == '-' or trimmed_left[0] == '*' or trimmed_left[0] == '+') and trimmed_left[1] == ' ') {
            const rendered = try renderInline(alloc, trimmed_left[2..]);
            defer alloc.free(rendered);
            try out.appendNTimes(alloc, ' ', indent_len);
            try out.appendSlice(alloc, LIST ++ "* " ++ RESET);
            try out.appendSlice(alloc, rendered);
            try out.append(alloc, '\n');
            continue;
        }
        var num_end: usize = 0;
        while (num_end < trimmed_left.len and std.ascii.isDigit(trimmed_left[num_end])) : (num_end += 1) {}
        if (num_end > 0 and num_end + 1 < trimmed_left.len and trimmed_left[num_end] == '.' and trimmed_left[num_end + 1] == ' ') {
            const rendered = try renderInline(alloc, trimmed_left[num_end + 2 ..]);
            defer alloc.free(rendered);
            try out.appendNTimes(alloc, ' ', indent_len);
            try out.appendSlice(alloc, LIST);
            try out.appendSlice(alloc, trimmed_left[0 .. num_end + 1]);
            try out.appendSlice(alloc, " " ++ RESET);
            try out.appendSlice(alloc, rendered);
            try out.append(alloc, '\n');
            continue;
        }

        const rendered = try renderInline(alloc, line);
        defer alloc.free(rendered);
        try out.appendSlice(alloc, rendered);
        try out.append(alloc, '\n');
    }

    try flushTable(&table_buf, &out, alloc);
    if (in_fence) {
        try out.appendSlice(alloc, CODE_FENCE ++ "  +-(unclosed code fence)+\n" ++ RESET);
        for (fence_buf.items) |fline| {
            try out.appendSlice(alloc, "  ");
            try appendWrapped(&out, alloc, CODE_BLOCK, fline);
            try out.append(alloc, '\n');
        }
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == '\n') _ = out.pop();
    return out.toOwnedSlice(alloc);
}

const CodeBlock = struct {
    lang: []const u8,
    code: []const u8,
};

fn extractCodeBlocks(alloc: std.mem.Allocator, src: []const u8, lang_filter: ?[]const u8) !std.ArrayList(CodeBlock) {
    var out: std.ArrayList(CodeBlock) = .empty;
    errdefer {
        for (out.items) |b| {
            alloc.free(b.lang);
            alloc.free(b.code);
        }
        out.deinit(alloc);
    }
    var lines = std.mem.splitScalar(u8, src, '\n');
    var in_fence = false;
    var lang: []const u8 = "";
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    while (lines.next()) |raw| {
        const line = trimCR(raw);
        if (!in_fence and std.mem.startsWith(u8, line, "```")) {
            in_fence = true;
            lang = std.mem.trim(u8, line[3..], " \t");
            buf.clearRetainingCapacity();
            continue;
        }
        if (in_fence and std.mem.eql(u8, std.mem.trim(u8, line, " \t"), "```")) {
            if (lang_filter == null or std.ascii.eqlIgnoreCase(lang_filter.?, lang)) {
                try out.append(alloc, .{
                    .lang = try alloc.dupe(u8, lang),
                    .code = try alloc.dupe(u8, trimTrailingNewlines(buf.items)),
                });
            }
            in_fence = false;
            lang = "";
            continue;
        }
        if (in_fence) {
            try buf.appendSlice(alloc, line);
            try buf.append(alloc, '\n');
        }
    }

    return out;
}

fn blocksToJson(alloc: std.mem.Allocator, blocks: []const CodeBlock) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var js = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try js.beginArray();
    for (blocks) |b| {
        try js.beginObject();
        try js.objectField("lang");
        try js.write(b.lang);
        try js.objectField("code");
        try js.write(b.code);
        try js.endObject();
    }
    try js.endArray();
    return out.toOwnedSlice();
}

fn handleRender(alloc: std.mem.Allocator, _: std.Io, args: std.json.Value) !mcp.ToolResult {
    const markdown = getStr(args, "markdown") orelse return .{ .text = "error: markdown is required", .is_error = true };
    const width_i = getInt(args, "width", 100);
    const width: usize = if (width_i > 20) @intCast(width_i) else 100;
    return .{ .text = try renderMarkdown(alloc, markdown, width) };
}

fn handleRenderFile(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const path = getStr(args, "path") orelse return .{ .text = "error: path is required", .is_error = true };
    const markdown = readTextFile(alloc, io, path) catch |err| {
        return .{ .text = try std.fmt.allocPrint(alloc, "error: failed to read {s}: {s}", .{ path, @errorName(err) }), .is_error = true };
    };
    defer alloc.free(markdown);
    const width_i = getInt(args, "width", 100);
    const width: usize = if (width_i > 20) @intCast(width_i) else 100;
    return .{ .text = try renderMarkdown(alloc, markdown, width) };
}

fn handleExtractCode(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const lang = getStr(args, "lang");
    var owned_markdown: ?[]u8 = null;
    defer if (owned_markdown) |buf| alloc.free(buf);
    const markdown = if (getStr(args, "markdown")) |m| m else blk: {
        const path = getStr(args, "path") orelse return .{ .text = "error: markdown or path required", .is_error = true };
        owned_markdown = readTextFile(alloc, io, path) catch |err| {
            return .{ .text = try std.fmt.allocPrint(alloc, "error: failed to read {s}: {s}", .{ path, @errorName(err) }), .is_error = true };
        };
        break :blk owned_markdown.?;
    };
    var blocks = try extractCodeBlocks(alloc, markdown, lang);
    defer {
        for (blocks.items) |b| {
            alloc.free(b.lang);
            alloc.free(b.code);
        }
        blocks.deinit(alloc);
    }
    return .{ .text = try blocksToJson(alloc, blocks.items) };
}
