//! zmcp-lsp - LSP bridge: spawns a language server (zls, gopls, rust-analyzer,
//! pyright-langserver, typescript-language-server) as a child over stdio,
//! speaks JSON-RPC 2.0 with Content-Length framing, and exposes semantic code
//! navigation as a handful of tools. Tool names follow isaacphi/mcp-language-server
//! (definition, references, hover, diagnostics, rename_symbol) with an lsp_ prefix.
//!
//! Env:
//!   ZMCP_LSP_ROOT            workspace root (default: cwd); all paths are confined to it
//!   ZMCP_LSP_CMD_<LANG>      override server command (ZIG GO RUST PYTHON TYPESCRIPT); split on
//!                            spaces, "double quotes" group; never passed through a shell
//!   ZMCP_LSP_ALLOW_WRITE=1   let lsp_rename apply=true write files (default: preview only)
//!   ZMCP_LSP_TIMEOUT_MS      per-request timeout (default 20000)
//!   ZMCP_LSP_INIT_TIMEOUT_MS initialize timeout (default 60000)
//!   ZMCP_LSP_DIAG_WAIT_MS    wait for publishDiagnostics (default 5000)
//! Positions are 1-based; col counts Unicode characters and is converted to
//! 0-based UTF-16 code units for the server.

const std = @import("std");
const mcp = @import("mcp");
const proto = @import("proto.zig");
const client_mod = @import("client.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Client = client_mod.Client;

pub const MAX_OUTPUT: usize = 64 * 1024;
const MAX_FILE: usize = 8 * 1024 * 1024;
const DEFAULT_REFS: usize = 50;
const MAX_REFS: usize = 500;
const MAX_SYMBOLS: usize = 200;
const MAX_DIAGS: usize = 200;
const LINE_TEXT_CAP: usize = 160;

// ---------------------------------------------------------------- languages

const Lang = struct {
    name: []const u8,
    env: []const u8,
    cmd: []const u8,
    /// Files whose presence at the root suggests this language (workspace/symbol).
    markers: []const []const u8,
};

const langs = [_]Lang{
    .{ .name = "zig", .env = "ZMCP_LSP_CMD_ZIG", .cmd = "zls", .markers = &.{ "build.zig", "build.zig.zon" } },
    .{ .name = "go", .env = "ZMCP_LSP_CMD_GO", .cmd = "gopls", .markers = &.{"go.mod"} },
    .{ .name = "rust", .env = "ZMCP_LSP_CMD_RUST", .cmd = "rust-analyzer", .markers = &.{"Cargo.toml"} },
    .{ .name = "python", .env = "ZMCP_LSP_CMD_PYTHON", .cmd = "pyright-langserver --stdio", .markers = &.{ "pyproject.toml", "setup.py", "requirements.txt" } },
    .{ .name = "typescript", .env = "ZMCP_LSP_CMD_TYPESCRIPT", .cmd = "typescript-language-server --stdio", .markers = &.{ "tsconfig.json", "package.json" } },
};

const ExtEntry = struct { ext: []const u8, lang: usize, id: []const u8 };
const exts = [_]ExtEntry{
    .{ .ext = ".zig", .lang = 0, .id = "zig" },
    .{ .ext = ".zon", .lang = 0, .id = "zig" },
    .{ .ext = ".go", .lang = 1, .id = "go" },
    .{ .ext = ".rs", .lang = 2, .id = "rust" },
    .{ .ext = ".py", .lang = 3, .id = "python" },
    .{ .ext = ".pyi", .lang = 3, .id = "python" },
    .{ .ext = ".ts", .lang = 4, .id = "typescript" },
    .{ .ext = ".mts", .lang = 4, .id = "typescript" },
    .{ .ext = ".cts", .lang = 4, .id = "typescript" },
    .{ .ext = ".tsx", .lang = 4, .id = "typescriptreact" },
    .{ .ext = ".js", .lang = 4, .id = "javascript" },
    .{ .ext = ".mjs", .lang = 4, .id = "javascript" },
    .{ .ext = ".cjs", .lang = 4, .id = "javascript" },
    .{ .ext = ".jsx", .lang = 4, .id = "javascriptreact" },
};

fn extEntry(path: []const u8) ?ExtEntry {
    const e = std.fs.path.extension(path);
    for (exts) |x| if (std.mem.eql(u8, x.ext, e)) return x;
    return null;
}

/// Split a command string on whitespace; "double quotes" group. No shell.
pub fn splitCmd(alloc: Allocator, s: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
        if (i >= s.len) break;
        if (s[i] == '"') {
            i += 1;
            const st = i;
            while (i < s.len and s[i] != '"') i += 1;
            try out.append(alloc, s[st..i]);
            if (i < s.len) i += 1;
        } else {
            const st = i;
            while (i < s.len and s[i] != ' ' and s[i] != '\t') i += 1;
            try out.append(alloc, s[st..i]);
        }
    }
    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------- state

var g_gpa: Allocator = undefined;
var g_env: ?*const std.process.Environ.Map = null;
var g_mu: Io.Mutex = .init;
var g_root: ?[]const u8 = null;
var g_msg: []const u8 = "";
var g_servers: [langs.len]?*Server = [_]?*Server{null} ** langs.len;

fn envGet(key: []const u8) ?[]const u8 {
    const m = g_env orelse return null;
    return m.get(key);
}

fn envU32(key: []const u8, default: u32) u32 {
    const v = envGet(key) orelse return default;
    return std.fmt.parseInt(u32, v, 10) catch default;
}

fn allowWrite() bool {
    const v = envGet("ZMCP_LSP_ALLOW_WRITE") orelse return false;
    return std.mem.eql(u8, v, "1");
}

const Fail = error{Fail};

fn fail(a: Allocator, comptime fmt: []const u8, args: anytype) Fail {
    g_msg = std.fmt.allocPrint(a, fmt, args) catch "out of memory";
    return error.Fail;
}

// ---------------------------------------------------------------- transport seam

pub const Conn = struct {
    tr: client_mod.Transport,
    ctx: *anyopaque,
    /// Terminate the peer and release the transport (kills the child).
    closeFn: *const fn (ctx: *anyopaque, io: Io) void,
};

pub const ConnectFn = *const fn (alloc: Allocator, io: Io, argv: []const []const u8, cwd: []const u8) anyerror!Conn;
var connect_fn: ConnectFn = connectReal;

const ChildConn = struct {
    child: std.process.Child,
    io: Io,

    fn read(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *ChildConn = @ptrCast(@alignCast(ctx));
        const f = self.child.stdout orelse return 0;
        return f.readStreaming(self.io, &.{buf}) catch |e| switch (e) {
            error.EndOfStream => 0,
            else => e,
        };
    }
    fn write(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *ChildConn = @ptrCast(@alignCast(ctx));
        const f = self.child.stdin orelse return error.BrokenPipe;
        try f.writeStreamingAll(self.io, bytes);
    }
    fn close(ctx: *anyopaque, io: Io) void {
        const self: *ChildConn = @ptrCast(@alignCast(ctx));
        self.child.kill(io);
        g_gpa.destroy(self);
    }
};

fn connectReal(alloc: Allocator, io: Io, argv: []const []const u8, cwd: []const u8) anyerror!Conn {
    _ = alloc;
    const cc = try g_gpa.create(ChildConn);
    errdefer g_gpa.destroy(cc);
    cc.io = io;
    cc.child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch |e| switch (e) {
        error.FileNotFound => return error.ExecutableNotFound,
        else => return e,
    };
    return .{
        .tr = .{ .ctx = cc, .readFn = ChildConn.read, .writeFn = ChildConn.write },
        .ctx = cc,
        .closeFn = ChildConn.close,
    };
}

// ---------------------------------------------------------------- servers

const DocState = struct { version: i32, mtime: i96, size: u64, hash: u64, force: bool = false };

const Server = struct {
    lang: usize,
    client: Client,
    conn: Conn,
    root_uri: []u8,
    docs: std.StringHashMapUnmanaged(DocState) = .empty,
    pull_diag: bool = false,
};

fn getRoot(a: Allocator, io: Io) ![]const u8 {
    if (g_root) |r| return r;
    const raw: []const u8 = envGet("ZMCP_LSP_ROOT") orelse blk: {
        break :blk std.process.currentPathAlloc(io, a) catch return fail(a, "cannot determine cwd", .{});
    };
    const real = std.Io.Dir.cwd().realPathFileAlloc(io, raw, a) catch return fail(a, "workspace root not accessible: {s}", .{raw});
    const owned = try g_gpa.dupe(u8, real);
    g_root = owned;
    return owned;
}

fn insideRoot(root: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    if (root.len > 0 and (root[root.len - 1] == '/' or root[root.len - 1] == '\\')) return true;
    return path[root.len] == '/' or path[root.len] == '\\';
}

/// Canonicalize `p` (relative to root) and require it to stay inside the root.
fn resolveInRoot(a: Allocator, io: Io, p: []const u8) ![]const u8 {
    const root = try getRoot(a, io);
    if (p.len == 0) return fail(a, "empty path", .{});
    if (std.mem.indexOfScalar(u8, p, 0) != null) return fail(a, "invalid path", .{});
    const abs = if (std.fs.path.isAbsolute(p)) p else try std.fs.path.join(a, &.{ root, p });
    const real = std.Io.Dir.cwd().realPathFileAlloc(io, abs, a) catch return fail(a, "file not found: {s}", .{p});
    if (!insideRoot(root, real)) return fail(a, "path escapes workspace root: {s}", .{p});
    return real;
}

fn displayPath(a: Allocator, root: []const u8, path: []const u8) []const u8 {
    _ = a;
    if (insideRoot(root, path) and path.len > root.len) {
        var r = path[root.len..];
        if (r[0] == '/' or r[0] == '\\') r = r[1..];
        return r;
    }
    return path;
}

fn teardown(io: Io, srv: *Server) void {
    srv.conn.closeFn(srv.conn.ctx, io);
    srv.client.join();
    srv.client.deinit();
    var it = srv.docs.iterator();
    while (it.next()) |e| g_gpa.free(e.key_ptr.*);
    srv.docs.deinit(g_gpa);
    g_gpa.free(srv.root_uri);
    g_gpa.destroy(srv);
}

fn hasDiagProvider(caps: Value) bool {
    if (caps != .object) return false;
    const c = caps.object.get("capabilities") orelse return false;
    if (c != .object) return false;
    const d = c.object.get("diagnosticProvider") orelse return false;
    return d != .null and !(d == .bool and !d.bool);
}

const client_caps =
    \\{"workspace":{"configuration":true,"workspaceFolders":true,"applyEdit":false,"workspaceEdit":{"documentChanges":true}},"textDocument":{"synchronization":{"dynamicRegistration":false,"didSave":false},"definition":{"linkSupport":true},"references":{},"hover":{"contentFormat":["plaintext","markdown"]},"documentSymbol":{"hierarchicalDocumentSymbolSupport":true},"rename":{"prepareSupport":false},"publishDiagnostics":{},"diagnostic":{"dynamicRegistration":false}},"window":{"workDoneProgress":true}}
;

fn ensureServer(a: Allocator, io: Io, lang: usize) !*Server {
    if (g_servers[lang]) |s| {
        if (!s.client.isClosed()) return s;
        teardown(io, s);
        g_servers[lang] = null;
    }
    const root = try getRoot(a, io);
    const cmd_text = envGet(langs[lang].env) orelse langs[lang].cmd;
    const argv = try splitCmd(a, cmd_text);
    if (argv.len == 0) return fail(a, "{s} is empty", .{langs[lang].env});

    const conn = connect_fn(a, io, argv, root) catch |e| {
        return fail(a, "cannot start `{s}` ({s}): install it or set {s}", .{ argv[0], @errorName(e), langs[lang].env });
    };
    const srv = try g_gpa.create(Server);
    srv.* = .{
        .lang = lang,
        .client = Client.init(g_gpa, io, conn.tr),
        .conn = conn,
        .root_uri = try proto.pathToUri(g_gpa, root),
    };
    srv.client.root_uri = srv.root_uri;
    srv.client.root_name = std.fs.path.basename(root);
    srv.client.start() catch {
        teardown(io, srv);
        return fail(a, "cannot start reader thread", .{});
    };

    const uri_j = try std.json.Stringify.valueAlloc(a, srv.root_uri, .{});
    const name_j = try std.json.Stringify.valueAlloc(a, srv.client.root_name, .{});
    const full = try std.fmt.allocPrint(a, "{{\"processId\":null,\"clientInfo\":{{\"name\":\"zmcp-lsp\",\"version\":\"0.1.0\"}},\"rootUri\":{s},\"workspaceFolders\":[{{\"uri\":{s},\"name\":{s}}}],\"capabilities\":{s}}}", .{ uri_j, uri_j, name_j, client_caps });

    const init_res = srv.client.request(a, "initialize", full, envU32("ZMCP_LSP_INIT_TIMEOUT_MS", 60000)) catch |e| {
        const why = reqErrText(a, &srv.client, e, "initialize");
        teardown(io, srv);
        return fail(a, "`{s}` failed to initialize: {s}", .{ argv[0], why });
    };
    srv.pull_diag = hasDiagProvider(init_res);
    srv.client.notify("initialized", "{}") catch {};
    g_servers[lang] = srv;
    return srv;
}

fn reqErrText(a: Allocator, c: *Client, e: client_mod.RequestError, what: []const u8) []const u8 {
    return switch (e) {
        error.Timeout => std.fmt.allocPrint(a, "timeout waiting for {s}; the server may still be indexing, retry shortly (ZMCP_LSP_TIMEOUT_MS)", .{what}) catch "timeout",
        error.ServerError => std.fmt.allocPrint(a, "server error: {s}", .{c.lastError()}) catch "server error",
        error.ServerClosed => "language server exited (it is restarted on the next call)",
        error.WriteFailed => "write to language server failed",
        error.BadResponse => "malformed response from language server",
        error.OutOfMemory => "out of memory",
    };
}

fn call(a: Allocator, srv: *Server, method: []const u8, params: []const u8) !Value {
    return srv.client.request(a, method, params, envU32("ZMCP_LSP_TIMEOUT_MS", 20000)) catch |e| {
        return fail(a, "{s}", .{reqErrText(a, &srv.client, e, method)});
    };
}

/// Graceful shutdown of every running server (stdin EOF path).
pub fn shutdownAll(io: Io) void {
    for (&g_servers) |*slot| {
        const srv = slot.* orelse continue;
        slot.* = null;
        var arena = std.heap.ArenaAllocator.init(g_gpa);
        defer arena.deinit();
        if (!srv.client.isClosed()) {
            _ = srv.client.request(arena.allocator(), "shutdown", "null", 1500) catch {};
            srv.client.notify("exit", "null") catch {};
            io.sleep(Io.Duration.fromMilliseconds(100), .awake) catch {};
        }
        teardown(io, srv);
    }
    if (g_root) |r| g_gpa.free(r);
    g_root = null;
}

// ---------------------------------------------------------------- document sync

const Synced = struct { text: []const u8, seq_before: u64, sent: bool };

fn syncDoc(a: Allocator, io: Io, srv: *Server, path: []const u8, lang_id: []const u8) !Synced {
    const cwd = std.Io.Dir.cwd();
    const st = cwd.statFile(io, path, .{}) catch return fail(a, "cannot stat {s}", .{path});
    if (st.kind != .file) return fail(a, "not a regular file: {s}", .{path});
    const text = cwd.readFileAlloc(io, path, a, .limited(MAX_FILE)) catch |e| switch (e) {
        error.StreamTooLong => return fail(a, "file too large (>{d} MiB): {s}", .{ MAX_FILE >> 20, path }),
        else => return fail(a, "cannot read {s}: {s}", .{ path, @errorName(e) }),
    };
    const mtime = st.mtime.toNanoseconds();
    const hash = std.hash.Wyhash.hash(0, text);
    const uri = try proto.pathToUri(a, path);
    const seq_before = srv.client.diagSeq(path);

    if (srv.docs.getPtr(path)) |d| {
        if (!d.force and d.mtime == mtime and d.size == st.size and d.hash == hash) {
            return .{ .text = text, .seq_before = seq_before, .sent = false };
        }
        d.version += 1;
        d.mtime = mtime;
        d.size = st.size;
        d.hash = hash;
        d.force = false;
        const p = try std.json.Stringify.valueAlloc(a, .{
            .textDocument = .{ .uri = uri, .version = d.version },
            .contentChanges = [_]struct { text: []const u8 }{.{ .text = text }},
        }, .{});
        srv.client.notify("textDocument/didChange", p) catch return fail(a, "language server is not accepting input", .{});
    } else {
        const p = try std.json.Stringify.valueAlloc(a, .{
            .textDocument = .{ .uri = uri, .languageId = lang_id, .version = @as(i32, 1), .text = text },
        }, .{});
        srv.client.notify("textDocument/didOpen", p) catch return fail(a, "language server is not accepting input", .{});
        try srv.docs.put(g_gpa, try g_gpa.dupe(u8, path), .{ .version = 1, .mtime = mtime, .size = st.size, .hash = hash });
    }
    return .{ .text = text, .seq_before = seq_before, .sent = true };
}

// ---------------------------------------------------------------- arg helpers

fn argStr(v: Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}

fn argInt(v: Value, key: []const u8) ?i64 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return switch (x) {
        .integer => |i| i,
        .float => |f| @as(i64, @intFromFloat(f)),
        else => null,
    };
}

fn argBool(v: Value, key: []const u8) bool {
    if (v != .object) return false;
    const x = v.object.get(key) orelse return false;
    return x == .bool and x.bool;
}

fn field(v: Value, key: []const u8) ?Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn fieldInt(v: Value, key: []const u8) usize {
    const x = field(v, key) orelse return 0;
    return switch (x) {
        .integer => |i| if (i < 0) 0 else @intCast(i),
        .float => |f| if (f < 0) 0 else @intFromFloat(f),
        else => 0,
    };
}

const Range = struct { sl: usize, sc: usize, el: usize, ec: usize };

fn parseRange(v: Value) ?Range {
    const s = field(v, "start") orelse return null;
    const e = field(v, "end") orelse return null;
    return .{ .sl = fieldInt(s, "line"), .sc = fieldInt(s, "character"), .el = fieldInt(e, "line"), .ec = fieldInt(e, "character") };
}

const Prepared = struct {
    srv: *Server,
    path: []const u8,
    uri: []const u8,
    synced: Synced,
    params: []const u8,
    root: []const u8,
};

fn prepFile(a: Allocator, io: Io, args: Value) !Prepared {
    const file = argStr(args, "file") orelse return fail(a, "missing required argument: file", .{});
    const path = try resolveInRoot(a, io, file);
    const ee = extEntry(path) orelse return fail(a, "unsupported file type: {s} (supported: .zig .go .rs .py .ts .tsx .js .jsx)", .{std.fs.path.extension(path)});
    const root = try getRoot(a, io);
    const srv = try ensureServer(a, io, ee.lang);
    const synced = try syncDoc(a, io, srv, path, ee.id);
    return .{ .srv = srv, .path = path, .uri = try proto.pathToUri(a, path), .synced = synced, .params = "", .root = root };
}

fn prepPos(a: Allocator, io: Io, args: Value) !Prepared {
    const line = argInt(args, "line") orelse return fail(a, "missing required argument: line (1-based)", .{});
    const col = argInt(args, "col") orelse return fail(a, "missing required argument: col (1-based)", .{});
    if (line < 1 or col < 1) return fail(a, "line and col are 1-based (got {d}:{d})", .{ line, col });
    var p = try prepFile(a, io, args);
    const l0: usize = @intCast(line - 1);
    const text = proto.lineAt(p.synced.text, l0) orelse return fail(a, "line {d} is past the end of the file", .{line});
    const c16 = proto.cpToUtf16(text, @intCast(col - 1));
    p.params = try std.json.Stringify.valueAlloc(a, .{
        .textDocument = .{ .uri = p.uri },
        .position = .{ .line = l0, .character = c16 },
    }, .{});
    return p;
}

// ---------------------------------------------------------------- output helpers

const Src = struct {
    a: Allocator,
    io: Io,
    root: []const u8,
    cache: std.StringHashMapUnmanaged(?[]const u8) = .empty,

    fn text(self: *Src, path: []const u8) ?[]const u8 {
        if (self.cache.get(path)) |t| return t;
        var t: ?[]const u8 = null;
        if (insideRoot(self.root, path)) {
            // Re-canonicalize so a symlink inside the root cannot leak outside.
            if (std.Io.Dir.cwd().realPathFileAlloc(self.io, path, self.a)) |real| {
                if (insideRoot(self.root, real)) {
                    t = std.Io.Dir.cwd().readFileAlloc(self.io, real, self.a, .limited(MAX_FILE)) catch null;
                }
            } else |_| {}
        }
        self.cache.put(self.a, path, t) catch {};
        return t;
    }
};

fn trimLine(l: []const u8) []const u8 {
    const t = std.mem.trim(u8, l, " \t\r");
    if (t.len <= LINE_TEXT_CAP) return t;
    var n: usize = LINE_TEXT_CAP;
    while (n > 0 and (t[n] & 0xC0) == 0x80) n -= 1; // do not split a UTF-8 sequence
    return t[0..n];
}

/// `path:line:col  source line` for a server-provided (uri, line, utf16 col).
fn locLine(a: Allocator, src: *Src, uri: []const u8, line0: usize, c16: usize) ![]const u8 {
    const path = (try proto.uriToPath(a, uri)) orelse return std.fmt.allocPrint(a, "{s}:{d}:{d}", .{ uri, line0 + 1, c16 + 1 });
    const disp = displayPath(a, src.root, path);
    if (src.text(path)) |t| {
        if (proto.lineAt(t, line0)) |l| {
            const col = proto.utf16ToCp(l, c16) + 1;
            return std.fmt.allocPrint(a, "{s}:{d}:{d}  {s}", .{ disp, line0 + 1, col, trimLine(l) });
        }
    }
    return std.fmt.allocPrint(a, "{s}:{d}:{d}", .{ disp, line0 + 1, c16 + 1 });
}

fn capText(a: Allocator, text: []const u8, hint: []const u8) ![]const u8 {
    if (text.len <= MAX_OUTPUT) return text;
    var cut: usize = MAX_OUTPUT;
    if (std.mem.lastIndexOfScalar(u8, text[0..cut], '\n')) |nl| cut = nl;
    return std.fmt.allocPrint(a, "{s}\n... output truncated at {d} KiB ({s})", .{ text[0..cut], MAX_OUTPUT / 1024, hint });
}

const Lines = struct {
    a: Allocator,
    buf: std.ArrayList(u8) = .empty,
    n: usize = 0,

    fn add(self: *Lines, line: []const u8) !void {
        if (self.n > 0) try self.buf.append(self.a, '\n');
        try self.buf.appendSlice(self.a, line);
        self.n += 1;
    }
    fn done(self: *Lines) []const u8 {
        return self.buf.items;
    }
};

// ---------------------------------------------------------------- tools

/// Location | LocationLink -> (uri, range)
fn locOf(v: Value) ?struct { uri: []const u8, range: Range } {
    if (v != .object) return null;
    if (field(v, "targetUri")) |tu| {
        if (tu != .string) return null;
        const r = field(v, "targetSelectionRange") orelse field(v, "targetRange") orelse return null;
        return .{ .uri = tu.string, .range = parseRange(r) orelse return null };
    }
    const u = field(v, "uri") orelse return null;
    if (u != .string) return null;
    const r = parseRange(field(v, "range") orelse return null) orelse return null;
    return .{ .uri = u.string, .range = r };
}

fn locationsText(a: Allocator, io: Io, root: []const u8, res: Value, limit: usize, empty_msg: []const u8) ![]const u8 {
    var items: []const Value = &.{};
    var one: [1]Value = undefined;
    switch (res) {
        .array => |arr| items = arr.items,
        .object => {
            one[0] = res;
            items = &one;
        },
        else => {},
    }
    if (items.len == 0) return empty_msg;
    var src: Src = .{ .a = a, .io = io, .root = root };
    var out: Lines = .{ .a = a };
    var shown: usize = 0;
    for (items) |it| {
        const l = locOf(it) orelse continue;
        if (shown >= limit) break;
        try out.add(try locLine(a, &src, l.uri, l.range.sl, l.range.sc));
        shown += 1;
    }
    if (shown == 0) return empty_msg;
    if (items.len > shown) try out.add(try std.fmt.allocPrint(a, "... {d} more (raise limit or narrow the query)", .{items.len - shown}));
    return out.done();
}

fn doDefinition(a: Allocator, io: Io, args: Value) ![]const u8 {
    const p = try prepPos(a, io, args);
    const res = try call(a, p.srv, "textDocument/definition", p.params);
    return locationsText(a, io, p.root, res, 20, "no definition found");
}

fn doReferences(a: Allocator, io: Io, args: Value) ![]const u8 {
    var p = try prepPos(a, io, args);
    const limit: usize = if (argInt(args, "limit")) |l| @intCast(std.math.clamp(l, 1, @as(i64, MAX_REFS))) else DEFAULT_REFS;
    // Splice includeDeclaration into the position params.
    p.params = try std.fmt.allocPrint(a, "{s},\"context\":{{\"includeDeclaration\":true}}}}", .{p.params[0 .. p.params.len - 1]});
    const res = try call(a, p.srv, "textDocument/references", p.params);
    return locationsText(a, io, p.root, res, limit, "no references found");
}

fn markedString(a: Allocator, out: *std.ArrayList(u8), v: Value) anyerror!void {
    switch (v) {
        .string => |s| try out.appendSlice(a, s),
        .object => {
            if (field(v, "value")) |x| if (x == .string) try out.appendSlice(a, x.string);
        },
        .array => |arr| for (arr.items) |x| {
            const before = out.items.len;
            try markedString(a, out, x);
            if (out.items.len > before) try out.appendSlice(a, "\n");
        },
        else => {},
    }
}

fn doHover(a: Allocator, io: Io, args: Value) ![]const u8 {
    const p = try prepPos(a, io, args);
    const res = try call(a, p.srv, "textDocument/hover", p.params);
    const contents = field(res, "contents") orelse return "no hover information";
    var out: std.ArrayList(u8) = .empty;
    try markedString(a, &out, contents);
    const t = std.mem.trim(u8, out.items, " \t\r\n");
    if (t.len == 0) return "no hover information";
    return capText(a, t, "hover text is long");
}

const kind_names = [_][]const u8{
    "?",       "file",     "module", "namespace", "package",  "class",  "method", "property", "field",
    "ctor",    "enum",     "iface",  "fn",        "var",      "const",  "string", "number",   "bool",
    "array",   "object",   "key",    "null",      "variant",  "struct", "event",  "op",       "type",
};

fn kindName(k: usize) []const u8 {
    return if (k < kind_names.len) kind_names[k] else "?";
}

fn containsFold(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn symbolLines(a: Allocator, src: *Src, out: *Lines, items: []const Value, depth: usize, doc_uri: []const u8, filter: ?[]const u8) anyerror!void {
    for (items) |it| {
        if (out.n >= MAX_SYMBOLS) return;
        const name = argStr(it, "name") orelse continue;
        const kind = kindName(fieldInt(it, "kind"));
        var uri = doc_uri;
        var rng: ?Range = null;
        if (field(it, "selectionRange")) |r| rng = parseRange(r);
        if (rng == null) if (field(it, "range")) |r| {
            rng = parseRange(r);
        };
        if (field(it, "location")) |loc| {
            if (argStr(loc, "uri")) |u| uri = u;
            if (field(loc, "range")) |r| rng = parseRange(r);
        }
        const r = rng orelse Range{ .sl = 0, .sc = 0, .el = 0, .ec = 0 };
        if (filter == null or containsFold(name, filter.?)) {
            const where = try locLine(a, src, uri, r.sl, r.sc);
            // Drop the source text; the symbol name carries the meaning.
            const cut = std.mem.indexOf(u8, where, "  ") orelse where.len;
            const indent = try a.alloc(u8, depth * 2);
            @memset(indent, ' ');
            var container: []const u8 = "";
            if (argStr(it, "containerName")) |c| if (c.len > 0) {
                container = try std.fmt.allocPrint(a, "  in {s}", .{c});
            };
            try out.add(try std.fmt.allocPrint(a, "{s}{s}  {s} {s}{s}", .{ indent, where[0..cut], kind, name, container }));
        }
        if (field(it, "children")) |ch| if (ch == .array) {
            try symbolLines(a, src, out, ch.array.items, depth + 1, doc_uri, filter);
        };
    }
}

fn detectLangs(a: Allocator, io: Io, root: []const u8) ![]const usize {
    var out: std.ArrayList(usize) = .empty;
    for (g_servers, 0..) |s, i| if (s != null) try out.append(a, i);
    if (out.items.len > 0) return out.items;
    for (langs, 0..) |l, i| {
        for (l.markers) |m| {
            const p = try std.fs.path.join(a, &.{ root, m });
            if (std.Io.Dir.cwd().statFile(io, p, .{})) |_| {
                try out.append(a, i);
                break;
            } else |_| {}
        }
    }
    return out.items;
}

fn doSymbols(a: Allocator, io: Io, args: Value) ![]const u8 {
    const query = argStr(args, "query");
    const root = try getRoot(a, io);
    var src: Src = .{ .a = a, .io = io, .root = root };
    var out: Lines = .{ .a = a };
    if (argStr(args, "file") != null) {
        const p = try prepFile(a, io, args);
        const params = try std.json.Stringify.valueAlloc(a, .{ .textDocument = .{ .uri = p.uri } }, .{});
        const res = try call(a, p.srv, "textDocument/documentSymbol", params);
        if (res == .array) try symbolLines(a, &src, &out, res.array.items, 0, p.uri, if (query) |q| (if (q.len > 0) q else null) else null);
    } else {
        const q = query orelse return fail(a, "provide file (document symbols) or query (workspace symbols)", .{});
        const ls = try detectLangs(a, io, root);
        if (ls.len == 0) return fail(a, "cannot pick a language server for workspace search: no project marker found; pass file instead", .{});
        const params = try std.json.Stringify.valueAlloc(a, .{ .query = q }, .{});
        var last_fail = false;
        for (ls) |li| {
            const srv = ensureServer(a, io, li) catch |e| {
                if (e == error.Fail) last_fail = true else return e;
                continue;
            };
            const res = call(a, srv, "workspace/symbol", params) catch |e| {
                if (e == error.Fail) last_fail = true else return e;
                continue;
            };
            if (res == .array) try symbolLines(a, &src, &out, res.array.items, 0, "", null);
        }
        if (out.n == 0 and last_fail) return error.Fail;
    }
    if (out.n == 0) return "no symbols found";
    var text = out.done();
    if (out.n >= MAX_SYMBOLS) text = try std.fmt.allocPrint(a, "{s}\n... capped at {d} symbols (narrow with query)", .{ text, MAX_SYMBOLS });
    return text;
}

const sev_names = [_][]const u8{ "?", "error", "warning", "info", "hint" };

fn diagLines(a: Allocator, src: *Src, out: *Lines, path: []const u8, items: []const Value) !void {
    const uri = try proto.pathToUri(a, path);
    for (items) |d| {
        if (out.n >= MAX_DIAGS) return;
        const r = parseRange(field(d, "range") orelse continue) orelse continue;
        const where = try locLine(a, src, uri, r.sl, r.sc);
        const cut = std.mem.indexOf(u8, where, "  ") orelse where.len;
        const sev = sev_names[@min(fieldInt(d, "severity"), sev_names.len - 1)];
        var msg = argStr(d, "message") orelse "";
        if (msg.len > 400) msg = msg[0..400];
        var fb: std.ArrayList(u8) = .empty;
        for (msg) |c| {
            const ws = c == '\n' or c == '\r' or c == '\t' or c == ' ';
            if (ws and (fb.items.len == 0 or fb.items[fb.items.len - 1] == ' ')) continue;
            try fb.append(a, if (ws) ' ' else c);
        }
        const flat = std.mem.trimEnd(u8, fb.items, " ");
        var codes: []const u8 = "";
        if (argStr(d, "source")) |s| codes = try std.fmt.allocPrint(a, " [{s}]", .{s});
        try out.add(try std.fmt.allocPrint(a, "{s}  {s}{s} {s}", .{ where[0..cut], sev, codes, flat }));
    }
}

fn doDiagnostics(a: Allocator, io: Io, args: Value) ![]const u8 {
    const p = try prepFile(a, io, args);
    var src: Src = .{ .a = a, .io = io, .root = p.root };
    var out: Lines = .{ .a = a };
    if (p.srv.pull_diag) {
        const params = try std.json.Stringify.valueAlloc(a, .{ .textDocument = .{ .uri = p.uri } }, .{});
        const res = try call(a, p.srv, "textDocument/diagnostic", params);
        if (field(res, "items")) |it| if (it == .array) try diagLines(a, &src, &out, p.path, it.array.items);
    } else {
        const wait = envU32("ZMCP_LSP_DIAG_WAIT_MS", 5000);
        const after: u64 = if (p.synced.sent) p.synced.seq_before else 0;
        const body = p.srv.client.waitDiag(a, p.path, after, wait) orelse
            return fail(a, "no diagnostics published within {d} ms (server may be busy; retry or raise ZMCP_LSP_DIAG_WAIT_MS)", .{wait});
        const msg = std.json.parseFromSliceLeaky(Value, a, body, .{}) catch return fail(a, "malformed diagnostics", .{});
        const params = field(msg, "params") orelse .null;
        if (field(params, "diagnostics")) |ds| if (ds == .array) try diagLines(a, &src, &out, p.path, ds.array.items);
    }
    if (out.n == 0) return "no diagnostics";
    return out.done();
}

// ---- rename

const Edit = struct { r: Range, new_text: []const u8 };
const FileEdits = struct { path: []const u8, edits: std.ArrayList(Edit) };

fn addEdits(a: Allocator, io: Io, files: *std.ArrayList(FileEdits), uri: []const u8, edits: Value) !void {
    if (edits != .array) return;
    const raw = (try proto.uriToPath(a, uri)) orelse return fail(a, "server returned a non-file URI: {s}", .{uri});
    const path = resolveInRoot(a, io, raw) catch |e| {
        if (e == error.Fail) return fail(a, "rename touches a file outside the workspace root (or missing): {s}", .{raw});
        return e;
    };
    var fe: *FileEdits = blk: {
        for (files.items) |*f| if (std.mem.eql(u8, f.path, path)) break :blk f;
        try files.append(a, .{ .path = path, .edits = .empty });
        break :blk &files.items[files.items.len - 1];
    };
    for (edits.array.items) |e| {
        const r = parseRange(field(e, "range") orelse continue) orelse continue;
        try fe.edits.append(a, .{ .r = r, .new_text = argStr(e, "newText") orelse "" });
    }
}

fn collectEdits(a: Allocator, io: Io, res: Value) !std.ArrayList(FileEdits) {
    var files: std.ArrayList(FileEdits) = .empty;
    if (field(res, "changes")) |ch| if (ch == .object) {
        var it = ch.object.iterator();
        while (it.next()) |e| try addEdits(a, io, &files, e.key_ptr.*, e.value_ptr.*);
    };
    if (field(res, "documentChanges")) |dc| if (dc == .array) {
        for (dc.array.items) |item| {
            if (field(item, "kind") != null) return fail(a, "server wants a file create/rename/delete as part of this edit; not supported", .{});
            const td = field(item, "textDocument") orelse continue;
            const uri = argStr(td, "uri") orelse continue;
            try addEdits(a, io, &files, uri, field(item, "edits") orelse .null);
        }
    };
    return files;
}

fn editLess(_: void, x: Edit, y: Edit) bool {
    if (x.r.sl != y.r.sl) return x.r.sl < y.r.sl;
    return x.r.sc < y.r.sc;
}

fn fileLess(_: void, x: FileEdits, y: FileEdits) bool {
    return std.mem.lessThan(u8, x.path, y.path);
}

fn slice(text: []const u8, r: Range) ?[]const u8 {
    const s = proto.lspToOffset(text, r.sl, r.sc) orelse return null;
    const e = proto.lspToOffset(text, r.el, r.ec) orelse return null;
    if (e < s) return null;
    return text[s..e];
}

fn oneLine(a: Allocator, s: []const u8, cap: usize) ![]const u8 {
    var n = @min(s.len, cap);
    while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
    const t = try a.dupe(u8, s[0..n]);
    for (t) |*c| if (c.* == '\n' or c.* == '\r' or c.* == '\t') {
        c.* = ' ';
    };
    return if (n < s.len) std.fmt.allocPrint(a, "{s}...", .{t}) else t;
}

fn doRename(a: Allocator, io: Io, args: Value) ![]const u8 {
    const new_name = argStr(args, "new_name") orelse return fail(a, "missing required argument: new_name", .{});
    if (new_name.len == 0) return fail(a, "new_name is empty", .{});
    const apply = argBool(args, "apply");
    if (apply and !allowWrite()) return fail(a, "apply refused: set ZMCP_LSP_ALLOW_WRITE=1 in the server environment to let lsp_rename write files (preview works without it)", .{});
    const p = try prepPos(a, io, args);
    const params = try std.fmt.allocPrint(a, "{s},\"newName\":{s}}}", .{ p.params[0 .. p.params.len - 1], try std.json.Stringify.valueAlloc(a, new_name, .{}) });
    const res = try call(a, p.srv, "textDocument/rename", params);
    if (res == .null) return "rename not possible at this position";
    const files = try collectEdits(a, io, res);
    std.mem.sort(FileEdits, files.items, {}, fileLess);
    var total: usize = 0;
    for (files.items) |*f| {
        std.mem.sort(Edit, f.edits.items, {}, editLess);
        total += f.edits.items.len;
    }
    if (total == 0) return "rename produced no edits";

    // Compute the new contents of every file first; nothing is written unless all succeed.
    var texts: std.ArrayList([]const u8) = .empty;
    var news: std.ArrayList([]const u8) = .empty;
    var out: Lines = .{ .a = a };
    try out.add(try std.fmt.allocPrint(a, "rename -> {s}: {d} edit{s} in {d} file{s} ({s})", .{
        new_name,                                     total,
        if (total == 1) "" else "s",                  files.items.len,
        if (files.items.len == 1) "" else "s",        if (apply) "applied" else "preview only; pass apply=true with ZMCP_LSP_ALLOW_WRITE=1 to write",
    }));
    var shown: usize = 0;
    for (files.items) |f| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, f.path, a, .limited(MAX_FILE)) catch return fail(a, "cannot read {s}", .{f.path});
        try texts.append(a, text);
        const disp = displayPath(a, p.root, f.path);
        var prev_end: usize = 0;
        for (f.edits.items) |e| {
            const s = proto.lspToOffset(text, e.r.sl, e.r.sc) orelse return fail(a, "edit range outside {s}", .{disp});
            const en = proto.lspToOffset(text, e.r.el, e.r.ec) orelse return fail(a, "edit range outside {s}", .{disp});
            if (en < s or s < prev_end) return fail(a, "overlapping or inverted edits in {s}", .{disp});
            prev_end = en;
            if (shown < 200) {
                const l = proto.lineAt(text, e.r.sl) orelse "";
                const col = proto.utf16ToCp(l, e.r.sc) + 1;
                try out.add(try std.fmt.allocPrint(a, "{s}:{d}:{d}  -{s} +{s}", .{ disp, e.r.sl + 1, col, try oneLine(a, text[s..en], 60), try oneLine(a, e.new_text, 60) }));
            }
            shown += 1;
        }
        // Splice back to front so earlier offsets stay valid.
        var buf: std.ArrayList(u8) = .empty;
        var cursor: usize = 0;
        for (f.edits.items) |e| {
            const s = proto.lspToOffset(text, e.r.sl, e.r.sc).?;
            const en = proto.lspToOffset(text, e.r.el, e.r.ec).?;
            try buf.appendSlice(a, text[cursor..s]);
            try buf.appendSlice(a, e.new_text);
            cursor = en;
        }
        try buf.appendSlice(a, text[cursor..]);
        try news.append(a, buf.items);
    }
    if (shown > 200) try out.add(try std.fmt.allocPrint(a, "... {d} more edits not listed", .{shown - 200}));

    if (apply) {
        for (files.items, 0..) |f, i| {
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = f.path, .data = news.items[i] }) catch |e| {
                return fail(a, "write failed for {s}: {s} (earlier files in this rename may already be written)", .{ f.path, @errorName(e) });
            };
            if (p.srv.docs.getPtr(f.path)) |d| d.force = true;
        }
    }
    return out.done();
}

// ---------------------------------------------------------------- MCP glue

fn wrap(a: Allocator, io: Io, args: Value, comptime f: anytype) !mcp.ToolResult {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const text = f(a, io, args) catch |e| switch (e) {
        error.Fail => return .{ .text = g_msg, .is_error = true },
        error.OutOfMemory => return e,
        else => return .{ .text = try std.fmt.allocPrint(a, "error: {s}", .{@errorName(e)}), .is_error = true },
    };
    return .{ .text = try capText(a, text, "narrow the query or lower limit") };
}

fn hDefinition(a: Allocator, io: Io, args: Value) anyerror!mcp.ToolResult {
    return wrap(a, io, args, doDefinition);
}
fn hReferences(a: Allocator, io: Io, args: Value) anyerror!mcp.ToolResult {
    return wrap(a, io, args, doReferences);
}
fn hHover(a: Allocator, io: Io, args: Value) anyerror!mcp.ToolResult {
    return wrap(a, io, args, doHover);
}
fn hSymbols(a: Allocator, io: Io, args: Value) anyerror!mcp.ToolResult {
    return wrap(a, io, args, doSymbols);
}
fn hDiagnostics(a: Allocator, io: Io, args: Value) anyerror!mcp.ToolResult {
    return wrap(a, io, args, doDiagnostics);
}
fn hRename(a: Allocator, io: Io, args: Value) anyerror!mcp.ToolResult {
    return wrap(a, io, args, doRename);
}

const pos_schema =
    \\{"type":"object","properties":{"file":{"type":"string"},"line":{"type":"integer"},"col":{"type":"integer"}},"required":["file","line","col"]}
;

pub const tool_table = [_]mcp.ToolDef{
    .{
        .name = "lsp_definition",
        .description = "Go to definition via the language server. line/col 1-based.",
        .input_schema_json = pos_schema,
        .handler = hDefinition,
        .read_only = true,
    },
    .{
        .name = "lsp_references",
        .description = "Find references of the symbol at file:line:col (1-based).",
        .input_schema_json =
        \\{"type":"object","properties":{"file":{"type":"string"},"line":{"type":"integer"},"col":{"type":"integer"},"limit":{"type":"integer"}},"required":["file","line","col"]}
        ,
        .handler = hReferences,
        .read_only = true,
    },
    .{
        .name = "lsp_hover",
        .description = "Type/doc info at file:line:col (1-based).",
        .input_schema_json = pos_schema,
        .handler = hHover,
        .read_only = true,
    },
    .{
        .name = "lsp_symbols",
        .description = "Symbols in file, or workspace symbols matching query.",
        .input_schema_json =
        \\{"type":"object","properties":{"file":{"type":"string"},"query":{"type":"string"}}}
        ,
        .handler = hSymbols,
        .read_only = true,
    },
    .{
        .name = "lsp_diagnostics",
        .description = "Errors and warnings for a file.",
        .input_schema_json =
        \\{"type":"object","properties":{"file":{"type":"string"}},"required":["file"]}
        ,
        .handler = hDiagnostics,
        .read_only = true,
    },
    .{
        .name = "lsp_rename",
        .description = "Rename symbol at file:line:col. Previews edits; writes only with apply=true and ZMCP_LSP_ALLOW_WRITE=1.",
        .input_schema_json =
        \\{"type":"object","properties":{"file":{"type":"string"},"line":{"type":"integer"},"col":{"type":"integer"},"new_name":{"type":"string"},"apply":{"type":"boolean"}},"required":["file","line","col","new_name"]}
        ,
        .handler = hRename,
        .destructive = true,
    },
};

pub fn main(init: std.process.Init) !void {
    g_gpa = init.gpa;
    g_env = init.environ_map;
    defer shutdownAll(init.io);
    try mcp.run(init.gpa, init.io, .{ .name = "zmcp-lsp", .version = "0.1.0" }, &tool_table);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testIo() Io {
    return std.Io.Threaded.global_single_threaded.io();
}

test "splitCmd: spaces, quotes, empty" {
    const a = testing.allocator;
    const r = try splitCmd(a, "  zls  --log \"a b\" x ");
    defer a.free(r);
    try testing.expectEqual(@as(usize, 4), r.len);
    try testing.expectEqualStrings("zls", r[0]);
    try testing.expectEqualStrings("a b", r[2]);
    const e = try splitCmd(a, "   ");
    defer a.free(e);
    try testing.expectEqual(@as(usize, 0), e.len);
}

test "extEntry maps extensions and rejects others" {
    try testing.expectEqual(@as(usize, 0), extEntry("/x/a.zig").?.lang);
    try testing.expectEqualStrings("typescriptreact", extEntry("a.tsx").?.id);
    try testing.expect(extEntry("a.txt") == null);
    try testing.expect(extEntry("Makefile") == null);
}

test "insideRoot respects component boundaries" {
    try testing.expect(insideRoot("/w", "/w"));
    try testing.expect(insideRoot("/w", "/w/a/b"));
    try testing.expect(!insideRoot("/w", "/wx/a"));
    try testing.expect(!insideRoot("/w/a", "/w"));
}

test "tool table: names, marks, small schema budget" {
    var total: usize = 0;
    for (tool_table) |t| {
        try testing.expect(!(t.read_only and t.destructive));
        total += t.name.len + t.description.len + t.input_schema_json.len;
    }
    try testing.expect(total < 2400);
    for (tool_table) |t| {
        if (std.mem.eql(u8, t.name, "lsp_rename")) try testing.expect(t.destructive and !t.read_only) else try testing.expect(t.read_only);
    }
}

// ---- scripted fake language server for end-to-end tests

const Fake = struct {
    d: client_mod.Duplex,
    alloc: Allocator,
    mu: Io.Mutex = .init,
    io: Io,
    /// method -> canned result JSON; "%URI%" is replaced by the request's textDocument.uri.
    canned: []const [2][]const u8,
    recv: std.ArrayList([]u8) = .empty,
    thread: ?std.Thread = null,
    push_diag: ?[]const u8 = null, // sent as publishDiagnostics after didOpen/didChange (with %URI%)

    fn run(self: *Fake) void {
        var framer = proto.Framer.init(self.alloc);
        defer framer.deinit();
        var buf: [4096]u8 = undefined;
        while (true) {
            const body = (framer.next() catch return) orelse {
                const n = self.d.c2s.pull(&buf);
                if (n == 0) return;
                framer.feed(buf[0..n]) catch return;
                continue;
            };
            self.handle(body) catch return;
        }
    }

    fn send(self: *Fake, body: []const u8) !void {
        const f = try proto.frame(self.alloc, body);
        defer self.alloc.free(f);
        try self.d.s2c.push(f);
    }

    fn handle(self: *Fake, body: []const u8) !void {
        {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            try self.recv.append(self.alloc, try self.alloc.dupe(u8, body));
        }
        var p = try std.json.parseFromSlice(Value, self.alloc, body, .{});
        defer p.deinit();
        const method = argStr(p.value, "method") orelse return;
        var uri: []const u8 = "";
        if (field(p.value, "params")) |pr| if (field(pr, "textDocument")) |td| {
            uri = argStr(td, "uri") orelse "";
        };
        if (self.push_diag) |pd| if (std.mem.eql(u8, method, "textDocument/didOpen") or std.mem.eql(u8, method, "textDocument/didChange")) {
            const m = try std.mem.replaceOwned(u8, self.alloc, pd, "%URI%", uri);
            defer self.alloc.free(m);
            try self.send(m);
        };
        const idv = field(p.value, "id") orelse {
            if (std.mem.eql(u8, method, "exit")) self.d.s2c.close();
            return;
        };
        const id_json = try std.json.Stringify.valueAlloc(self.alloc, idv, .{});
        defer self.alloc.free(id_json);
        if (std.mem.eql(u8, method, "initialize")) {
            // Interleave a server->client request before the response, like real servers.
            try self.send("{\"jsonrpc\":\"2.0\",\"id\":7001,\"method\":\"window/workDoneProgress/create\",\"params\":{\"token\":1}}");
        }
        var result: []const u8 = "null";
        for (self.canned) |c| if (std.mem.eql(u8, c[0], method)) {
            result = c[1];
        };
        const res = try std.mem.replaceOwned(u8, self.alloc, result, "%URI%", uri);
        defer self.alloc.free(res);
        const out = try std.fmt.allocPrint(self.alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_json, res });
        defer self.alloc.free(out);
        try self.send(out);
    }

    fn sawContaining(self: *Fake, needle: []const u8) bool {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        for (self.recv.items) |m| if (std.mem.indexOf(u8, m, needle) != null) return true;
        return false;
    }

    fn countMethod(self: *Fake, method: []const u8) usize {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const pat = std.fmt.allocPrint(self.alloc, "\"method\":\"{s}\"", .{method}) catch return 0;
        defer self.alloc.free(pat);
        var n: usize = 0;
        for (self.recv.items) |m| if (std.mem.indexOf(u8, m, pat) != null) {
            n += 1;
        };
        return n;
    }

    fn deinit(self: *Fake) void {
        for (self.recv.items) |m| self.alloc.free(m);
        self.recv.deinit(self.alloc);
        self.d.c2s.deinit();
        self.d.s2c.deinit();
    }
};

var test_fake: ?*Fake = null;
var test_closed: bool = false;

fn fakeConnect(alloc: Allocator, io: Io, argv: []const []const u8, cwd: []const u8) anyerror!Conn {
    _ = alloc;
    _ = io;
    _ = argv;
    _ = cwd;
    const f = test_fake.?;
    f.thread = try std.Thread.spawn(.{}, Fake.run, .{f});
    return .{
        .tr = .{ .ctx = &f.d, .readFn = client_mod.Duplex.readFn, .writeFn = client_mod.Duplex.writeFn },
        .ctx = f,
        .closeFn = fakeClose,
    };
}

fn fakeClose(ctx: *anyopaque, io: Io) void {
    _ = io;
    const f: *Fake = @ptrCast(@alignCast(ctx));
    f.d.c2s.close();
    f.d.s2c.close();
    if (f.thread) |t| t.join();
    f.thread = null;
    test_closed = true;
}

const TestEnv = struct {
    tmp: std.testing.TmpDir,
    env: std.process.Environ.Map,
    arena: std.heap.ArenaAllocator,
    fake: Fake,

    fn setup(self: *TestEnv, canned: []const [2][]const u8) !void {
        const io = testIo();
        self.tmp = testing.tmpDir(.{});
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.env = std.process.Environ.Map.init(testing.allocator);
        var pbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try self.tmp.dir.realPath(io, &pbuf);
        try self.env.put("ZMCP_LSP_ROOT", pbuf[0..n]);
        try self.env.put("ZMCP_LSP_CMD_ZIG", "fake-zls --stdio");
        self.fake = .{
            .d = .{ .c2s = .{ .io = io, .alloc = testing.allocator }, .s2c = .{ .io = io, .alloc = testing.allocator } },
            .alloc = testing.allocator,
            .io = io,
            .canned = canned,
        };
        test_fake = &self.fake;
        test_closed = false;
        g_gpa = testing.allocator;
        g_env = &self.env;
        g_root = null;
        connect_fn = fakeConnect;
    }

    fn teardownAll(self: *TestEnv) void {
        shutdownAll(testIo());
        g_env = null;
        connect_fn = connectReal;
        test_fake = null;
        self.fake.deinit();
        self.env.deinit();
        self.arena.deinit();
        self.tmp.cleanup();
    }

    fn callTool(self: *TestEnv, name: []const u8, args_json: []const u8) !mcp.ToolResult {
        const a = self.arena.allocator();
        const args = try std.json.parseFromSliceLeaky(Value, a, args_json, .{});
        for (tool_table) |t| if (std.mem.eql(u8, t.name, name)) return t.handler(a, testIo(), args);
        return error.NoSuchTool;
    }
};

const init_result = "{\"capabilities\":{\"definitionProvider\":true}}";

test "e2e: initialize -> definition round trip with UTF-16 columns and interleaved server request" {
    var te: TestEnv = undefined;
    // Definition points at line 2 (0-based 1) of the same file, char 6 (utf16) = after "é😀" etc.
    try te.setup(&.{
        .{ "initialize", init_result },
        .{ "textDocument/definition", "[{\"uri\":\"%URI%\",\"range\":{\"start\":{\"line\":1,\"character\":6},\"end\":{\"line\":1,\"character\":9}}}]" },
    });
    defer te.teardownAll();
    // Line 1: 'é' (1 unit) + emoji (2 units) precede `foo`; line 2 mirrors it for the target.
    try te.tmp.dir.writeFile(testIo(), .{ .sub_path = "a.zig", .data = "const s = \"\xc3\xa9\xf0\x9f\x98\x80\"; foo();\nconst \xc3\xa9\xf0\x9f\x98\x80 = bar();\n" });

    // model col: 1-based char col of `foo` on line 1: `const s = "é😀"; foo();`
    // chars: c o n s t _ s _ = _ " é 😀 " ; _ f -> 'f' is char index 16 => col 17; utf16 index 17.
    const r = try te.callTool("lsp_definition", "{\"file\":\"a.zig\",\"line\":1,\"col\":17}");
    try testing.expect(!r.is_error);
    // Target: line 2, utf16 6 => chars "const " = 6 -> col 7.
    try testing.expectEqualStrings("a.zig:2:7  const \xc3\xa9\xf0\x9f\x98\x80 = bar();", r.text);
    // The server got utf16 col 17? chars before f: 16 code points, one of which is astral => 17 units.
    try testing.expect(te.fake.sawContaining("\"position\":{\"line\":0,\"character\":17}"));
    try testing.expect(te.fake.sawContaining("\"method\":\"initialized\""));
    try testing.expectEqual(@as(usize, 1), te.fake.countMethod("textDocument/didOpen"));

    // A second call reuses the warm server and does not re-open the unchanged file.
    const r2 = try te.callTool("lsp_definition", "{\"file\":\"a.zig\",\"line\":1,\"col\":17}");
    try testing.expect(!r2.is_error);
    try testing.expectEqual(@as(usize, 1), te.fake.countMethod("textDocument/didOpen"));
    try testing.expectEqual(@as(usize, 0), te.fake.countMethod("textDocument/didChange"));

    // Changing the file yields didChange (version 2), not a second didOpen.
    try te.tmp.dir.writeFile(testIo(), .{ .sub_path = "a.zig", .data = "// x\nconst s = 1;\n" });
    const r3 = try te.callTool("lsp_definition", "{\"file\":\"a.zig\",\"line\":2,\"col\":1}");
    try testing.expect(!r3.is_error);
    try testing.expectEqual(@as(usize, 1), te.fake.countMethod("textDocument/didOpen"));
    try testing.expectEqual(@as(usize, 1), te.fake.countMethod("textDocument/didChange"));
    try testing.expect(te.fake.sawContaining("\"version\":2"));
}

test "e2e: path confinement, unsupported type, bad position" {
    var te: TestEnv = undefined;
    try te.setup(&.{.{ "initialize", init_result }});
    defer te.teardownAll();
    try te.tmp.dir.writeFile(testIo(), .{ .sub_path = "a.zig", .data = "x\n" });
    try te.tmp.dir.writeFile(testIo(), .{ .sub_path = "n.txt", .data = "x\n" });

    for ([_][]const u8{
        "{\"file\":\"../../../../etc/passwd\",\"line\":1,\"col\":1}",
        "{\"file\":\"/etc/passwd\",\"line\":1,\"col\":1}",
        "{\"file\":\"nope.zig\",\"line\":1,\"col\":1}",
    }) |args| {
        const r = try te.callTool("lsp_hover", args);
        try testing.expect(r.is_error);
    }
    const esc = try te.callTool("lsp_hover", "{\"file\":\"/etc/passwd\",\"line\":1,\"col\":1}");
    try testing.expect(std.mem.indexOf(u8, esc.text, "escapes workspace root") != null);

    const t = try te.callTool("lsp_hover", "{\"file\":\"n.txt\",\"line\":1,\"col\":1}");
    try testing.expect(t.is_error and std.mem.indexOf(u8, t.text, "unsupported file type") != null);
    const z = try te.callTool("lsp_hover", "{\"file\":\"a.zig\",\"line\":0,\"col\":1}");
    try testing.expect(z.is_error and std.mem.indexOf(u8, z.text, "1-based") != null);
    // None of the rejected calls so far started a server.
    try testing.expectEqual(@as(usize, 0), te.fake.countMethod("initialize"));
    const past = try te.callTool("lsp_hover", "{\"file\":\"a.zig\",\"line\":99,\"col\":1}");
    try testing.expect(past.is_error and std.mem.indexOf(u8, past.text, "past the end") != null);

}

test "e2e: symlink escaping the root is rejected" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var te: TestEnv = undefined;
    try te.setup(&.{.{ "initialize", init_result }});
    defer te.teardownAll();
    te.tmp.dir.symLink(testIo(), "/etc/passwd", "link.zig", .{}) catch return error.SkipZigTest;
    const r = try te.callTool("lsp_hover", "{\"file\":\"link.zig\",\"line\":1,\"col\":1}");
    try testing.expect(r.is_error and std.mem.indexOf(u8, r.text, "escapes workspace root") != null);
}

test "e2e: hover, references limit, symbols tree, diagnostics via push" {
    var te: TestEnv = undefined;
    try te.setup(&.{
        .{ "initialize", init_result },
        .{ "textDocument/hover", "{\"contents\":{\"kind\":\"markdown\",\"value\":\"fn foo() void\"}}" },
        .{ "textDocument/references", "[{\"uri\":\"%URI%\",\"range\":{\"start\":{\"line\":0,\"character\":6},\"end\":{\"line\":0,\"character\":9}}},{\"uri\":\"%URI%\",\"range\":{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":1,\"character\":3}}},{\"uri\":\"file:///elsewhere/x.zig\",\"range\":{\"start\":{\"line\":4,\"character\":1},\"end\":{\"line\":4,\"character\":2}}}]" },
        .{ "textDocument/documentSymbol", "[{\"name\":\"Outer\",\"kind\":23,\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":1,\"character\":0}},\"selectionRange\":{\"start\":{\"line\":0,\"character\":6},\"end\":{\"line\":0,\"character\":11}},\"children\":[{\"name\":\"inner\",\"kind\":12,\"range\":{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":1,\"character\":3}},\"selectionRange\":{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":1,\"character\":3}}}]}]" },
    });
    te.fake.push_diag = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"%URI%\",\"diagnostics\":[{\"range\":{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":1,\"character\":3}},\"severity\":1,\"source\":\"zls\",\"message\":\"expected ';'\\nafter this\"}]}}";
    defer te.teardownAll();
    try te.tmp.dir.writeFile(testIo(), .{ .sub_path = "a.zig", .data = "const Outer = struct {\nfoo\n" });

    const h = try te.callTool("lsp_hover", "{\"file\":\"a.zig\",\"line\":1,\"col\":7}");
    try testing.expectEqualStrings("fn foo() void", h.text);

    const refs = try te.callTool("lsp_references", "{\"file\":\"a.zig\",\"line\":1,\"col\":7,\"limit\":2}");
    try testing.expectEqualStrings(
        "a.zig:1:7  const Outer = struct {\na.zig:2:1  foo\n... 1 more (raise limit or narrow the query)",
        refs.text,
    );
    const refs_all = try te.callTool("lsp_references", "{\"file\":\"a.zig\",\"line\":1,\"col\":7}");
    // Outside-root location: absolute path, no source text read.
    try testing.expect(std.mem.endsWith(u8, refs_all.text, "/elsewhere/x.zig:5:2"));
    try testing.expect(te.fake.sawContaining("\"includeDeclaration\":true"));

    const syms = try te.callTool("lsp_symbols", "{\"file\":\"a.zig\"}");
    try testing.expectEqualStrings("a.zig:1:7  struct Outer\n  a.zig:2:1  fn inner", syms.text);
    const filt = try te.callTool("lsp_symbols", "{\"file\":\"a.zig\",\"query\":\"INN\"}");
    try testing.expectEqualStrings("  a.zig:2:1  fn inner", filt.text);

    const dg = try te.callTool("lsp_diagnostics", "{\"file\":\"a.zig\"}");
    try testing.expectEqualStrings("a.zig:2:1  error [zls] expected ';' after this", dg.text);
    // Unchanged file: served from the stored publish without waiting.
    const dg2 = try te.callTool("lsp_diagnostics", "{\"file\":\"a.zig\"}");
    try testing.expectEqualStrings(dg.text, dg2.text);
}

test "e2e: rename previews by default, refuses apply without the flag, applies with it (UTF-16 safe)" {
    var te: TestEnv = undefined;
    // Two edits on line 2; the second sits after an astral char (utf16 col 4 = 1 cp + 1 astral(2) + ... ).
    try te.setup(&.{
        .{ "initialize", init_result },
        .{ "textDocument/rename", "{\"changes\":{\"%URI%\":[{\"range\":{\"start\":{\"line\":0,\"character\":6},\"end\":{\"line\":0,\"character\":9}},\"newText\":\"quux\"},{\"range\":{\"start\":{\"line\":1,\"character\":5},\"end\":{\"line\":1,\"character\":8}},\"newText\":\"quux\"}]}}" },
    });
    defer te.teardownAll();
    const orig = "const foo = 1;\n\xf0\x9f\x98\x80 x foo;\n";
    try te.tmp.dir.writeFile(testIo(), .{ .sub_path = "a.zig", .data = orig });

    const prev = try te.callTool("lsp_rename", "{\"file\":\"a.zig\",\"line\":1,\"col\":7,\"new_name\":\"quux\"}");
    try testing.expect(!prev.is_error);
    try testing.expect(std.mem.indexOf(u8, prev.text, "2 edits in 1 file (preview only") != null);
    try testing.expect(std.mem.indexOf(u8, prev.text, "a.zig:1:7  -foo +quux") != null);
    // "😀 x foo;": foo starts at utf16 5 = code point 4 -> 1-based col 5.
    try testing.expect(std.mem.indexOf(u8, prev.text, "a.zig:2:5  -foo +quux") != null);
    const still = try te.tmp.dir.readFileAlloc(testIo(), "a.zig", testing.allocator, .limited(1024));
    defer testing.allocator.free(still);
    try testing.expectEqualStrings(orig, still);

    const refused = try te.callTool("lsp_rename", "{\"file\":\"a.zig\",\"line\":1,\"col\":7,\"new_name\":\"quux\",\"apply\":true}");
    try testing.expect(refused.is_error and std.mem.indexOf(u8, refused.text, "ZMCP_LSP_ALLOW_WRITE=1") != null);
    const still2 = try te.tmp.dir.readFileAlloc(testIo(), "a.zig", testing.allocator, .limited(1024));
    defer testing.allocator.free(still2);
    try testing.expectEqualStrings(orig, still2);

    try te.env.put("ZMCP_LSP_ALLOW_WRITE", "1");
    const done = try te.callTool("lsp_rename", "{\"file\":\"a.zig\",\"line\":1,\"col\":7,\"new_name\":\"quux\",\"apply\":true}");
    try testing.expect(!done.is_error);
    try testing.expect(std.mem.indexOf(u8, done.text, "(applied)") != null);
    const now = try te.tmp.dir.readFileAlloc(testIo(), "a.zig", testing.allocator, .limited(1024));
    defer testing.allocator.free(now);
    try testing.expectEqualStrings("const quux = 1;\n\xf0\x9f\x98\x80 x quux;\n", now);
}

test "e2e: server start failure and shutdown handshake" {
    var te: TestEnv = undefined;
    try te.setup(&.{.{ "initialize", init_result }});
    defer te.teardownAll();
    try te.tmp.dir.writeFile(testIo(), .{ .sub_path = "a.zig", .data = "x\n" });
    connect_fn = struct {
        fn f(_: Allocator, _: Io, _: []const []const u8, _: []const u8) anyerror!Conn {
            return error.ExecutableNotFound;
        }
    }.f;
    const r = try te.callTool("lsp_hover", "{\"file\":\"a.zig\",\"line\":1,\"col\":1}");
    try testing.expect(r.is_error and std.mem.indexOf(u8, r.text, "ZMCP_LSP_CMD_ZIG") != null);
    connect_fn = fakeConnect;
    const ok = try te.callTool("lsp_hover", "{\"file\":\"a.zig\",\"line\":1,\"col\":1}");
    try testing.expectEqualStrings("no hover information", ok.text);
    shutdownAll(testIo());
    try testing.expect(te.fake.sawContaining("\"method\":\"shutdown\""));
    try testing.expect(te.fake.sawContaining("\"method\":\"exit\""));
    try testing.expect(test_closed);
}
