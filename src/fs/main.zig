//! zmcp-fs — filesystem operations beyond the host's built-in read/write/edit/bash.
//!
//! Tools:
//!   fs_glob      → glob files matching a pattern (*, **, ?, {a,b}, [abc])
//!   fs_stat      → file size, kind, mtime ms
//!   fs_tree      → directory tree text output
//!   fs_mkdir     → create directory (optionally recursive)
//!   fs_rename    → rename / move file or directory
//!   fs_remove    → delete file or directory (optionally recursive)
//!   fs_touch     → create empty file or update mtime

const std = @import("std");
const mcp = @import("mcp");

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    const io = init.io;
    try mcp.run(arena, io, .{ .name = "zmcp-fs", .version = "0.1.0" }, &tool_table);
}

// ---------------------------------------------------------------------------
// Tool table
// ---------------------------------------------------------------------------

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "fs_glob",
        .description = "Glob for files matching a pattern. Supports *, **, ?, {a,b} alternates, [abc] char classes. Returns newline-separated paths (forward-slash), capped at 1000 entries. Skips .git/ always. A `cwd` with `..` or an absolute path outside the process cwd is refused unless allow_outside=true or ZMCP_FS_ALLOW_OUTSIDE=1.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "pattern":   { "type": "string", "description": "Glob pattern, e.g. \"**/*.zig\"" },
        \\    "cwd":       { "type": "string", "description": "Base directory (default: process cwd)" },
        \\    "gitignore": { "type": "boolean", "description": "Honour nearest .gitignore (default true)" },
        \\    "allow_outside": { "type": "boolean", "description": "Allow paths outside cwd (default false; env ZMCP_FS_ALLOW_OUTSIDE=1 also enables)" }
        \\  },
        \\  "required": ["pattern"],
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleGlob,
        .read_only = true,
    },
    .{
        .name = "fs_stat",
        .description = "Return file metadata: size (bytes), kind (file/dir/symlink/other), mtime_ms (Unix ms). Paths with `..` or absolute paths outside cwd are refused unless allow_outside=true or ZMCP_FS_ALLOW_OUTSIDE=1.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "path": { "type": "string", "description": "Path to stat" },
        \\    "allow_outside": { "type": "boolean", "description": "Allow paths outside cwd (default false; env ZMCP_FS_ALLOW_OUTSIDE=1 also enables)" }
        \\  },
        \\  "required": ["path"],
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleStat,
        .read_only = true,
    },
    .{
        .name = "fs_tree",
        .description = "Print a directory tree like `tree -L <depth>`. Default depth 3. Paths with `..` or absolute paths outside cwd are refused unless allow_outside=true or ZMCP_FS_ALLOW_OUTSIDE=1.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "path":  { "type": "string",  "description": "Root directory (default: .)" },
        \\    "depth": { "type": "integer", "description": "Max depth (default 3, max 20)" },
        \\    "allow_outside": { "type": "boolean", "description": "Allow paths outside cwd (default false; env ZMCP_FS_ALLOW_OUTSIDE=1 also enables)" }
        \\  },
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleTree,
        .read_only = true,
    },
    .{
        .name = "fs_mkdir",
        .description = "Create a directory. Set recursive=true to create parent directories. Paths with `..` or absolute paths outside cwd are refused unless allow_outside=true or ZMCP_FS_ALLOW_OUTSIDE=1.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "path":      { "type": "string",  "description": "Directory path to create" },
        \\    "recursive": { "type": "boolean", "description": "Create parents if needed (default false)" },
        \\    "allow_outside": { "type": "boolean", "description": "Allow paths outside cwd (default false; env ZMCP_FS_ALLOW_OUTSIDE=1 also enables)" }
        \\  },
        \\  "required": ["path"],
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleMkdir,
    },
    .{
        .name = "fs_rename",
        .description = "Rename or move a file or directory. Both paths must be relative to and inside cwd (no `..`, no absolute paths outside cwd) unless allow_outside=true or ZMCP_FS_ALLOW_OUTSIDE=1.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "src":           { "type": "string",  "description": "Source path" },
        \\    "dst":           { "type": "string",  "description": "Destination path" },
        \\    "allow_outside": { "type": "boolean", "description": "Allow paths outside cwd (default false; env ZMCP_FS_ALLOW_OUTSIDE=1 also enables)" }
        \\  },
        \\  "required": ["src", "dst"],
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleRename,
        .destructive = true,
    },
    .{
        .name = "fs_remove",
        .description = "Delete a file or directory. Set recursive=true for non-empty directories. Path must be relative to and inside cwd (no `..`, no absolute paths outside cwd) unless allow_outside=true or ZMCP_FS_ALLOW_OUTSIDE=1.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "path":          { "type": "string",  "description": "Path to delete" },
        \\    "recursive":     { "type": "boolean", "description": "Delete directory recursively (default false)" },
        \\    "allow_outside": { "type": "boolean", "description": "Allow paths outside cwd (default false; env ZMCP_FS_ALLOW_OUTSIDE=1 also enables)" }
        \\  },
        \\  "required": ["path"],
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleRemove,
        .destructive = true,
    },
    .{
        .name = "fs_touch",
        .description = "Create an empty file if it does not exist, or update its mtime to now. Paths with `..` or absolute paths outside cwd are refused unless allow_outside=true or ZMCP_FS_ALLOW_OUTSIDE=1.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "path": { "type": "string", "description": "File path" },
        \\    "allow_outside": { "type": "boolean", "description": "Allow paths outside cwd (default false; env ZMCP_FS_ALLOW_OUTSIDE=1 also enables)" }
        \\  },
        \\  "required": ["path"],
        \\  "additionalProperties": false
        \\}
        ,
        .handler = handleTouch,
    },
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Return true if path contains a `..` component.
fn hasParentTraversal(p: []const u8) bool {
    var it = std.mem.splitAny(u8, p, "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return true;
    }
    return false;
}

fn isAbsolutePath(p: []const u8) bool {
    if (p.len > 0 and (p[0] == '/' or p[0] == '\\')) return true;
    return p.len > 1 and p[1] == ':' and std.ascii.isAlphabetic(p[0]);
}

/// True when `p` leaves the working directory: a `..` component, or an
/// absolute path that is not lexically under cwd. Symlinks are not resolved.
fn escapesCwd(alloc: std.mem.Allocator, io: std.Io, p: []const u8) bool {
    if (hasParentTraversal(p)) return true;
    if (!isAbsolutePath(p)) return false;
    const cwd = std.process.currentPathAlloc(io, alloc) catch return true;
    defer alloc.free(cwd);
    if (!std.mem.startsWith(u8, p, cwd)) return true;
    return p.len > cwd.len and p[cwd.len] != '/' and p[cwd.len] != '\\';
}

fn outsideAllowed(alloc: std.mem.Allocator, io: std.Io, arg: bool) bool {
    if (arg) return true;
    const v = mcp.envAlloc(alloc, io, "ZMCP_FS_ALLOW_OUTSIDE") orelse return false;
    defer alloc.free(v);
    return std.mem.eql(u8, v, "1");
}

const outside_msg = "error: path is outside the working directory (relative paths only; set ZMCP_FS_ALLOW_OUTSIDE=1 or allow_outside=true to override)";

/// Normalise path separators to forward-slash in-place.
fn normSep(buf: []u8) void {
    for (buf) |*c| {
        if (c.* == '\\') c.* = '/';
    }
}

fn getStringArg(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn getBoolArg(args: std.json.Value, key: []const u8, default: bool) bool {
    if (args != .object) return default;
    const v = args.object.get(key) orelse return default;
    if (v != .bool) return default;
    return v.bool;
}

fn getIntArg(args: std.json.Value, key: []const u8, default: i64) i64 {
    if (args != .object) return default;
    const v = args.object.get(key) orelse return default;
    switch (v) {
        .integer => |n| return n,
        .float => |f| return @intFromFloat(f),
        else => return default,
    }
}

// ---------------------------------------------------------------------------
// Glob implementation
// ---------------------------------------------------------------------------

/// Simple glob matching: *, **, ?, {a,b}, [abc].
fn globMatch(pattern: []const u8, path: []const u8) bool {
    return globMatchInner(pattern, path);
}

fn globMatchInner(pat: []const u8, str: []const u8) bool {
    var p: usize = 0;
    var s: usize = 0;

    while (p < pat.len) {
        if (pat[p] == '*') {
            if (p + 1 < pat.len and pat[p + 1] == '*') {
                // ** — skip over optional slash after **
                var pp = p + 2;
                if (pp < pat.len and (pat[pp] == '/' or pat[pp] == '\\')) pp += 1;

                // Try matching ** against 0 or more path segments
                var ss = s;
                while (true) {
                    if (globMatchInner(pat[pp..], str[ss..])) return true;
                    // advance past next '/' in str
                    if (ss >= str.len) break;
                    const next_sep = indexOfSep(str[ss..]) orelse {
                        ss = str.len;
                        continue;
                    };
                    ss += next_sep + 1;
                }
                return false;
            } else {
                // * — match any chars except '/'
                p += 1;
                var ss = s;
                while (true) {
                    if (globMatchInner(pat[p..], str[ss..])) return true;
                    if (ss >= str.len) break;
                    if (str[ss] == '/' or str[ss] == '\\') break;
                    ss += 1;
                }
                return false;
            }
        } else if (pat[p] == '?') {
            if (s >= str.len or str[s] == '/' or str[s] == '\\') return false;
            p += 1;
            s += 1;
        } else if (pat[p] == '[') {
            const end = std.mem.indexOfScalarPos(u8, pat, p + 1, ']') orelse return false;
            if (s >= str.len) return false;
            const cls = pat[p + 1 .. end];
            const c = str[s];
            if (!charClassMatch(cls, c)) return false;
            p = end + 1;
            s += 1;
        } else if (pat[p] == '{') {
            // alternates {a,b,c}
            const end = findMatchingBrace(pat, p) orelse return false;
            const inner = pat[p + 1 .. end];
            const rest_pat = pat[end + 1 ..];
            var it = std.mem.splitScalar(u8, inner, ',');
            while (it.next()) |alt| {
                const combined_len = alt.len + rest_pat.len;
                if (combined_len > 512) return false;
                var buf: [512]u8 = undefined;
                @memcpy(buf[0..alt.len], alt);
                @memcpy(buf[alt.len..combined_len], rest_pat);
                if (globMatchInner(buf[0..combined_len], str[s..])) return true;
            }
            return false;
        } else {
            if (s >= str.len) return false;
            if (!charEq(pat[p], str[s])) return false;
            p += 1;
            s += 1;
        }
    }
    return s == str.len;
}

fn indexOfSep(s: []const u8) ?usize {
    for (s, 0..) |c, i| {
        if (c == '/' or c == '\\') return i;
    }
    return null;
}

fn charEq(a: u8, b: u8) bool {
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

fn charClassMatch(cls: []const u8, c: u8) bool {
    var i: usize = 0;
    const negate = cls.len > 0 and cls[0] == '^';
    if (negate) i = 1;
    var matched = false;
    while (i < cls.len) {
        if (i + 2 < cls.len and cls[i + 1] == '-') {
            if (c >= cls[i] and c <= cls[i + 2]) matched = true;
            i += 3;
        } else {
            if (cls[i] == c) matched = true;
            i += 1;
        }
    }
    return if (negate) !matched else matched;
}

fn findMatchingBrace(pat: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var i = start;
    while (i < pat.len) : (i += 1) {
        if (pat[i] == '{') depth += 1;
        if (pat[i] == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

/// Parse .gitignore lines into a list of patterns (owned by allocator).
fn parseGitignore(allocator: std.mem.Allocator, content: []const u8) !std.ArrayList([]const u8) {
    var patterns: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw_line| {
        var line = std.mem.trimEnd(u8, raw_line, "\r");
        line = std.mem.trim(u8, line, " ");
        if (line.len == 0 or line[0] == '#') continue;
        try patterns.append(allocator, try allocator.dupe(u8, line));
    }
    return patterns;
}

/// Check if a relative path matches any .gitignore pattern.
fn gitignoreMatch(patterns: []const []const u8, rel_path: []const u8) bool {
    for (patterns) |pat| {
        const p = if (pat.len > 0 and pat[0] == '/') pat[1..] else pat;
        const basename = std.fs.path.basename(rel_path);
        if (std.mem.indexOfScalar(u8, p, '/') == null and !std.mem.startsWith(u8, p, "**")) {
            if (globMatch(p, basename)) return true;
        } else {
            if (globMatch(p, rel_path)) return true;
        }
    }
    return false;
}

fn handleGlob(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const pattern = getStringArg(args, "pattern") orelse
        return .{ .text = "error: missing 'pattern' argument", .is_error = true };
    const cwd_arg = getStringArg(args, "cwd");
    const use_gitignore = getBoolArg(args, "gitignore", true);
    if (cwd_arg) |cp| {
        if (escapesCwd(allocator, io, cp) and !outsideAllowed(allocator, io, getBoolArg(args, "allow_outside", false)))
            return .{ .text = outside_msg, .is_error = true };
    }

    const cwd_dir = std.Io.Dir.cwd();

    // Open base directory
    var base_dir: std.Io.Dir = if (cwd_arg) |p| blk: {
        break :blk cwd_dir.openDir(io, p, .{ .iterate = true }) catch |err| {
            return .{ .text = try std.fmt.allocPrint(allocator, "error opening cwd '{s}': {s}", .{ p, @errorName(err) }), .is_error = true };
        };
    } else cwd_dir.openDir(io, ".", .{ .iterate = true }) catch |err| {
        return .{ .text = try std.fmt.allocPrint(allocator, "error opening '.': {s}", .{@errorName(err)}), .is_error = true };
    };
    defer base_dir.close(io);

    // Load .gitignore if requested
    var gi_patterns: std.ArrayList([]const u8) = .empty;
    defer gi_patterns.deinit(allocator);
    if (use_gitignore) {
        var gi_buf: [64 * 1024]u8 = undefined;
        if (base_dir.readFile(io, ".gitignore", &gi_buf)) |content| {
            gi_patterns = try parseGitignore(allocator, content);
        } else |_| {}
    }

    var results: std.ArrayList([]const u8) = .empty;
    defer results.deinit(allocator);

    var walker = try base_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        const raw = entry.path;
        const path_copy = try allocator.dupe(u8, raw);
        normSep(path_copy);

        // Skip .git directory contents
        const first_seg = std.mem.sliceTo(path_copy, '/');
        if (std.mem.eql(u8, first_seg, ".git")) continue;
        if (std.mem.startsWith(u8, path_copy, ".git/")) continue;

        // gitignore filtering
        if (use_gitignore and gi_patterns.items.len > 0) {
            if (gitignoreMatch(gi_patterns.items, path_copy)) continue;
        }

        // Match against pattern
        if (globMatch(pattern, path_copy)) {
            try results.append(allocator, path_copy);
            if (results.items.len >= 1000) break;
        }
    }

    if (results.items.len == 0) return .{ .text = "" };

    // Join with newlines
    var out: std.ArrayList(u8) = .empty;
    for (results.items, 0..) |p, i| {
        if (i > 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, p);
    }
    return .{ .text = out.items };
}

// ---------------------------------------------------------------------------
// fs_stat
// ---------------------------------------------------------------------------

fn handleStat(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const p = getStringArg(args, "path") orelse
        return .{ .text = "error: missing 'path' argument", .is_error = true };
    if (escapesCwd(allocator, io, p) and !outsideAllowed(allocator, io, getBoolArg(args, "allow_outside", false)))
        return .{ .text = outside_msg, .is_error = true };

    const cwd = std.Io.Dir.cwd();
    const s = cwd.statFile(io, p, .{}) catch |err| {
        return .{ .text = try std.fmt.allocPrint(allocator, "error: {s}", .{@errorName(err)}), .is_error = true };
    };

    const kind_str: []const u8 = switch (s.kind) {
        .file => "file",
        .directory => "dir",
        .sym_link => "symlink",
        else => "other",
    };
    const mtime_ms = s.mtime.toMilliseconds();

    return .{ .text = try std.fmt.allocPrint(
        allocator,
        "{{\"kind\":\"{s}\",\"size\":{d},\"mtime_ms\":{d}}}",
        .{ kind_str, s.size, mtime_ms },
    ) };
}

// ---------------------------------------------------------------------------
// fs_tree
// ---------------------------------------------------------------------------

const TreeCtx = struct {
    allocator: std.mem.Allocator,
    out: std.ArrayList(u8),
    io: std.Io,
    max_depth: usize,
};

const DirEntry = struct {
    name: []const u8,
    kind: std.Io.File.Kind,
};

fn buildTree(ctx: *TreeCtx, dir: std.Io.Dir, prefix: []const u8, depth: usize) !void {
    if (depth > ctx.max_depth) return;

    var pairs: std.ArrayList(DirEntry) = .empty;
    defer {
        for (pairs.items) |e| ctx.allocator.free(e.name);
        pairs.deinit(ctx.allocator);
    }

    var iter = dir.iterate();
    while (try iter.next(ctx.io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".git")) continue;
        try pairs.append(ctx.allocator, .{
            .name = try ctx.allocator.dupe(u8, entry.name),
            .kind = entry.kind,
        });
    }

    std.mem.sort(DirEntry, pairs.items, {}, struct {
        fn lessThan(_: void, a: DirEntry, b: DirEntry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    for (pairs.items, 0..) |pair, idx| {
        const is_last = idx == pairs.items.len - 1;
        const connector: []const u8 = if (is_last) "\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 " else "\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 ";
        const child_prefix_ext: []const u8 = if (is_last) "    " else "\xe2\x94\x82   ";

        try ctx.out.appendSlice(ctx.allocator, prefix);
        try ctx.out.appendSlice(ctx.allocator, connector);
        try ctx.out.appendSlice(ctx.allocator, pair.name);

        if (pair.kind == .directory) {
            try ctx.out.append(ctx.allocator, '/');
            try ctx.out.append(ctx.allocator, '\n');

            if (depth < ctx.max_depth) {
                var child_dir = dir.openDir(ctx.io, pair.name, .{ .iterate = true }) catch continue;
                defer child_dir.close(ctx.io);

                const new_prefix = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ prefix, child_prefix_ext });
                defer ctx.allocator.free(new_prefix);
                try buildTree(ctx, child_dir, new_prefix, depth + 1);
            }
        } else {
            try ctx.out.append(ctx.allocator, '\n');
        }
    }
}

fn handleTree(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const path_arg = getStringArg(args, "path") orelse ".";
    const depth_arg = getIntArg(args, "depth", 3);
    const max_depth: usize = @intCast(@min(20, @max(1, depth_arg)));
    if (escapesCwd(allocator, io, path_arg) and !outsideAllowed(allocator, io, getBoolArg(args, "allow_outside", false)))
        return .{ .text = outside_msg, .is_error = true };

    const cwd = std.Io.Dir.cwd();
    var root_dir = cwd.openDir(io, path_arg, .{ .iterate = true }) catch |err| {
        return .{ .text = try std.fmt.allocPrint(allocator, "error opening '{s}': {s}", .{ path_arg, @errorName(err) }), .is_error = true };
    };
    defer root_dir.close(io);

    var ctx: TreeCtx = .{
        .allocator = allocator,
        .out = .empty,
        .io = io,
        .max_depth = max_depth,
    };

    try ctx.out.appendSlice(allocator, path_arg);
    try ctx.out.append(allocator, '/');
    try ctx.out.append(allocator, '\n');

    try buildTree(&ctx, root_dir, "", 1);

    return .{ .text = ctx.out.items };
}

// ---------------------------------------------------------------------------
// fs_mkdir
// ---------------------------------------------------------------------------

fn handleMkdir(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const p = getStringArg(args, "path") orelse
        return .{ .text = "error: missing 'path' argument", .is_error = true };
    const recursive = getBoolArg(args, "recursive", false);
    if (escapesCwd(allocator, io, p) and !outsideAllowed(allocator, io, getBoolArg(args, "allow_outside", false)))
        return .{ .text = outside_msg, .is_error = true };

    const cwd = std.Io.Dir.cwd();
    if (recursive) {
        cwd.createDirPath(io, p) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return .{ .text = try std.fmt.allocPrint(allocator, "error: {s}", .{@errorName(err)}), .is_error = true },
        };
    } else {
        cwd.createDir(io, p, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return .{ .text = try std.fmt.allocPrint(allocator, "error: {s}", .{@errorName(err)}), .is_error = true },
        };
    }
    return .{ .text = try std.fmt.allocPrint(allocator, "created: {s}", .{p}) };
}

// ---------------------------------------------------------------------------
// fs_rename
// ---------------------------------------------------------------------------

fn handleRename(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const src = getStringArg(args, "src") orelse
        return .{ .text = "error: missing 'src' argument", .is_error = true };
    const dst = getStringArg(args, "dst") orelse
        return .{ .text = "error: missing 'dst' argument", .is_error = true };
    const allow_outside = getBoolArg(args, "allow_outside", false);

    if (!outsideAllowed(allocator, io, allow_outside)) {
        if (escapesCwd(allocator, io, src) or escapesCwd(allocator, io, dst))
            return .{ .text = outside_msg, .is_error = true };
        if (hasParentTraversal(src))
            return .{ .text = "error: src path traverses above cwd (use allow_outside=true to override)", .is_error = true };
        if (hasParentTraversal(dst))
            return .{ .text = "error: dst path traverses above cwd (use allow_outside=true to override)", .is_error = true };
    }

    const cwd = std.Io.Dir.cwd();
    std.Io.Dir.rename(cwd, src, cwd, dst, io) catch |err| {
        return .{ .text = try std.fmt.allocPrint(allocator, "error: {s}", .{@errorName(err)}), .is_error = true };
    };
    return .{ .text = try std.fmt.allocPrint(allocator, "renamed: {s} -> {s}", .{ src, dst }) };
}

// ---------------------------------------------------------------------------
// fs_remove
// ---------------------------------------------------------------------------

fn handleRemove(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const p = getStringArg(args, "path") orelse
        return .{ .text = "error: missing 'path' argument", .is_error = true };
    const recursive = getBoolArg(args, "recursive", false);
    const allow_outside = getBoolArg(args, "allow_outside", false);

    if (!outsideAllowed(allocator, io, allow_outside) and escapesCwd(allocator, io, p))
        return .{ .text = outside_msg, .is_error = true };

    const cwd = std.Io.Dir.cwd();

    const s = cwd.statFile(io, p, .{}) catch |err| {
        return .{ .text = try std.fmt.allocPrint(allocator, "error stat: {s}", .{@errorName(err)}), .is_error = true };
    };

    if (s.kind == .directory) {
        if (recursive) {
            cwd.deleteTree(io, p) catch |err| {
                return .{ .text = try std.fmt.allocPrint(allocator, "error: {s}", .{@errorName(err)}), .is_error = true };
            };
        } else {
            cwd.deleteDir(io, p) catch |err| switch (err) {
                error.DirNotEmpty => return .{ .text = "error: directory not empty (use recursive=true)", .is_error = true },
                else => return .{ .text = try std.fmt.allocPrint(allocator, "error: {s}", .{@errorName(err)}), .is_error = true },
            };
        }
    } else {
        cwd.deleteFile(io, p) catch |err| {
            return .{ .text = try std.fmt.allocPrint(allocator, "error: {s}", .{@errorName(err)}), .is_error = true };
        };
    }
    return .{ .text = try std.fmt.allocPrint(allocator, "removed: {s}", .{p}) };
}

// ---------------------------------------------------------------------------
// fs_touch
// ---------------------------------------------------------------------------

fn handleTouch(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const p = getStringArg(args, "path") orelse
        return .{ .text = "error: missing 'path' argument", .is_error = true };
    if (escapesCwd(allocator, io, p) and !outsideAllowed(allocator, io, getBoolArg(args, "allow_outside", false)))
        return .{ .text = outside_msg, .is_error = true };

    const cwd = std.Io.Dir.cwd();

    const file = cwd.createFile(io, p, .{ .truncate = false, .read = false }) catch |err| switch (err) {
        error.IsDir => return .{ .text = "error: path is a directory", .is_error = true },
        else => return .{ .text = try std.fmt.allocPrint(allocator, "error creating: {s}", .{@errorName(err)}), .is_error = true },
    };
    file.setTimestampsNow(io) catch {};
    file.close(io);

    return .{ .text = try std.fmt.allocPrint(allocator, "touched: {s}", .{p}) };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "globMatch basic *" {
    try std.testing.expect(globMatch("*.zig", "main.zig"));
    try std.testing.expect(!globMatch("*.zig", "main.txt"));
    try std.testing.expect(!globMatch("*.zig", "src/main.zig")); // * doesn't cross /
}

test "globMatch ** crosses directories" {
    try std.testing.expect(globMatch("**/*.zig", "src/main.zig"));
    try std.testing.expect(globMatch("**/*.zig", "a/b/c/foo.zig"));
    try std.testing.expect(globMatch("**/*.zig", "main.zig"));
    try std.testing.expect(!globMatch("**/*.zig", "main.txt"));
}

test "globMatch ? single char" {
    try std.testing.expect(globMatch("?.zig", "a.zig"));
    try std.testing.expect(!globMatch("?.zig", "ab.zig"));
}

test "globMatch {a,b} alternates" {
    try std.testing.expect(globMatch("{foo,bar}.zig", "foo.zig"));
    try std.testing.expect(globMatch("{foo,bar}.zig", "bar.zig"));
    try std.testing.expect(!globMatch("{foo,bar}.zig", "baz.zig"));
}

test "globMatch [abc] char class" {
    try std.testing.expect(globMatch("[abc].zig", "a.zig"));
    try std.testing.expect(globMatch("[abc].zig", "c.zig"));
    try std.testing.expect(!globMatch("[abc].zig", "d.zig"));
}

test "hasParentTraversal" {
    try std.testing.expect(hasParentTraversal("../foo"));
    try std.testing.expect(hasParentTraversal("foo/../../bar"));
    try std.testing.expect(!hasParentTraversal("foo/bar/baz"));
    try std.testing.expect(!hasParentTraversal("..foo"));
}

test "fs_glob finds .zig files" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "" });
    try tmp.dir.createDir(io, "sub", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/c.zig", .data = "" });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const tmp_path = path_buf[0..n];

    // Handlers are arena-allocated in production; mirror that in tests.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var map: std.json.ObjectMap = .{};
    defer map.deinit(arena);
    try map.put(arena, "pattern", .{ .string = "**/*.zig" });
    try map.put(arena, "cwd", .{ .string = tmp_path });
    try map.put(arena, "gitignore", .{ .bool = false });
    try map.put(arena, "allow_outside", .{ .bool = true });

    const result = try handleGlob(arena, io, .{ .object = map });
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "a.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "c.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "b.txt") == null);
}

test "fs_tree output format" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "" });
    try tmp.dir.createDir(io, "core", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "core/messages.zig", .data = "" });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const tmp_path = path_buf[0..n];

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var map: std.json.ObjectMap = .{};
    defer map.deinit(arena);
    try map.put(arena, "path", .{ .string = tmp_path });
    try map.put(arena, "depth", .{ .integer = 3 });
    try map.put(arena, "allow_outside", .{ .bool = true });

    const result = try handleTree(arena, io, .{ .object = map });
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "core/") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "messages.zig") != null);
    // Check tree box-drawing characters appear
    try std.testing.expect(std.mem.indexOf(u8, result.text, "\xe2\x94") != null);
}

test "fs_mkdir recursive creates parents" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const tmp_path = path_buf[0..n];

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const nested = try std.fmt.allocPrint(arena, "{s}/a/b/c", .{tmp_path});

    var map: std.json.ObjectMap = .{};
    defer map.deinit(arena);
    try map.put(arena, "path", .{ .string = nested });
    try map.put(arena, "recursive", .{ .bool = true });
    try map.put(arena, "allow_outside", .{ .bool = true });

    const result = try handleMkdir(arena, io, .{ .object = map });
    try std.testing.expect(!result.is_error);

    const s = try tmp.dir.statFile(io, "a/b/c", .{});
    try std.testing.expectEqual(std.Io.File.Kind.directory, s.kind);
}

test "fs_rename moves file; fs_stat confirms" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const tmp_path = path_buf[0..n];

    try tmp.dir.writeFile(io, .{ .sub_path = "old.txt", .data = "hello" });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src_path = try std.fmt.allocPrint(arena, "{s}/old.txt", .{tmp_path});
    const dst_path = try std.fmt.allocPrint(arena, "{s}/new.txt", .{tmp_path});

    var rename_map: std.json.ObjectMap = .{};
    defer rename_map.deinit(arena);
    try rename_map.put(arena, "src", .{ .string = src_path });
    try rename_map.put(arena, "dst", .{ .string = dst_path });
    try rename_map.put(arena, "allow_outside", .{ .bool = true });

    const rename_result = try handleRename(arena, io, .{ .object = rename_map });
    try std.testing.expect(!rename_result.is_error);

    var stat_map: std.json.ObjectMap = .{};
    defer stat_map.deinit(arena);
    try stat_map.put(arena, "path", .{ .string = dst_path });
    try stat_map.put(arena, "allow_outside", .{ .bool = true });

    const stat_result = try handleStat(arena, io, .{ .object = stat_map });
    try std.testing.expect(!stat_result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, stat_result.text, "\"kind\":\"file\"") != null);

    const stat2 = tmp.dir.statFile(io, "old.txt", .{});
    try std.testing.expectError(error.FileNotFound, stat2);
}

test "fs_remove non-recursive on non-empty dir returns error" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const tmp_path = path_buf[0..n];

    try tmp.dir.createDir(io, "nonempty", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "nonempty/file.txt", .data = "x" });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir_path = try std.fmt.allocPrint(arena, "{s}/nonempty", .{tmp_path});

    var map: std.json.ObjectMap = .{};
    defer map.deinit(arena);
    try map.put(arena, "path", .{ .string = dir_path });
    try map.put(arena, "recursive", .{ .bool = false });
    try map.put(arena, "allow_outside", .{ .bool = true });

    const result = try handleRemove(arena, io, .{ .object = map });
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "not empty") != null);
}

test "fs_remove recursive succeeds" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const tmp_path = path_buf[0..n];

    try tmp.dir.createDir(io, "target", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "target/file.txt", .data = "x" });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir_path = try std.fmt.allocPrint(arena, "{s}/target", .{tmp_path});

    var map: std.json.ObjectMap = .{};
    defer map.deinit(arena);
    try map.put(arena, "path", .{ .string = dir_path });
    try map.put(arena, "recursive", .{ .bool = true });
    try map.put(arena, "allow_outside", .{ .bool = true });

    const result = try handleRemove(arena, io, .{ .object = map });
    try std.testing.expect(!result.is_error);

    const s = tmp.dir.statFile(io, "target", .{});
    try std.testing.expectError(error.FileNotFound, s);
}

test "fs_remove path safety rejects .." {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var map: std.json.ObjectMap = .{};
    defer map.deinit(arena);
    try map.put(arena, "path", .{ .string = "../foo" });

    const result = try handleRemove(arena, io, .{ .object = map });
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "outside the working directory") != null);
}

test "fs_remove refuses absolute paths outside cwd" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var map: std.json.ObjectMap = .{};
    try map.put(arena, "path", .{ .string = "/etc/zmcp-should-never-be-touched" });
    try map.put(arena, "recursive", .{ .bool = true });
    const result = try handleRemove(arena, std.testing.io, .{ .object = map });
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "outside the working directory") != null);
}

test "read tools and mkdir/touch refuse outside-cwd paths by default" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var m1: std.json.ObjectMap = .{};
    try m1.put(arena, "path", .{ .string = "/etc/shadow" });
    const r1 = try handleStat(arena, io, .{ .object = m1 });
    try std.testing.expect(r1.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r1.text, "outside the working directory") != null);

    var m2: std.json.ObjectMap = .{};
    try m2.put(arena, "path", .{ .string = "../.." });
    const r2 = try handleTree(arena, io, .{ .object = m2 });
    try std.testing.expect(r2.is_error);

    var m3: std.json.ObjectMap = .{};
    try m3.put(arena, "pattern", .{ .string = "*" });
    try m3.put(arena, "cwd", .{ .string = "/etc" });
    const r3 = try handleGlob(arena, io, .{ .object = m3 });
    try std.testing.expect(r3.is_error);

    var m4: std.json.ObjectMap = .{};
    try m4.put(arena, "path", .{ .string = "/tmp/zmcp-should-not-exist-dir" });
    const r4 = try handleMkdir(arena, io, .{ .object = m4 });
    try std.testing.expect(r4.is_error);

    var m5: std.json.ObjectMap = .{};
    try m5.put(arena, "path", .{ .string = "/tmp/zmcp-should-not-exist-file" });
    const r5 = try handleTouch(arena, io, .{ .object = m5 });
    try std.testing.expect(r5.is_error);
}
