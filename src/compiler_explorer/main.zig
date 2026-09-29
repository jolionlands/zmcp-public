//! zmcp-compiler-explorer — Zig-native port of the `ce-mcp` Python package
//! (FastMCP + aiohttp, ~5.7k LOC). Thin REST wrappers over the keyless public
//! Compiler Explorer API (https://godbolt.org/api) with JSON reshaping and
//! output capping.
//!
//! Tools (14, names match ce-mcp exactly):
//!   compile_check              — quick compilation validation
//!   compile_and_run            — compile + execute, captures stdout/stderr
//!   compile_with_diagnostics   — warnings/errors with line/column + suggestions
//!   analyze_optimization       — assembly output + opt remarks (500-line cap)
//!   compare_compilers          — assembly/execution/diagnostics comparison
//!   generate_share_url         — POST /shortener for a single-file session
//!   find_compilers             — experimental compiler search + categorization
//!   get_libraries              — simplified library list (id/name)
//!   get_library_details        — one library incl. versions
//!   get_languages              — simplified language list (id/name/extensions)
//!   lookup_instruction         — /asm/<set>/<opcode> docs + alias resolution
//!   download_shortlink         — save shortlink sources to local files
//!   cmake_build                — POST /compiler/<c>/cmake multifile build
//!   generate_cmake_share_url   — /shortener for a CMake multifile tree
//!
//! Parity deviations from ce-mcp (documented per porting contract):
//!   - On-disk response cache (~/.cache/compiler_explorer_mcp) and the
//!     in-memory compiler-tools validation cache are dropped (allowed).
//!   - YAML config file loading is dropped; ce-mcp defaults are compiled in
//!     (endpoint, filters, output limits, compiler_mappings).
//!   - Library "latest" resolution honors $order like the original; the
//!     PEP-440 semver fallback is a simplified dotted-numeric compare.
//!   - Library not-found suggestions use substring matching (the original's
//!     fuzzy character scoring is not ported).
//!   - download_shortlink filename extensions come from the static extension
//!     map; the live /languages extension lookup is not ported.
//!   - Tool descriptions are the first paragraph of the original docstrings
//!     rather than the full multi-KB text.
//!   - find_compilers version_info parsing extracts raw/full/modified plus
//!     version_number, commit_hash and build_date via simple scanning.
//!   - assembly side-by-side diff data is not computed (ce-mcp never exposes
//!     it in any tool response).
//!   - Unified diffs are produced by an LCS differ; hunk layout matches
//!     difflib but replace-block line pairing may differ in rare edge cases.
//!   - Unique-item lists in diff statistics are deduped in first-seen order
//!     (Python uses set(), whose order is nondeterministic).
//!   - find_compilers usage_example is only emitted in the flat proposal
//!     search branch, not in the categorized (show_all) branch.

const std = @import("std");
const mcp = @import("mcp");

const API_BASE = "https://godbolt.org/api";
const UA_PRODUCT = "zmcp-compiler-explorer/0.1.0";
const MAX_ASSEMBLY_LINES: usize = 500;

/// Essential compiler fields requested from /compilers/{language}?fields=...
const COMPILER_FIELDS_ESSENTIAL = "id,name,lang,compilerType,instructionSet,semver,group,groupName,hidden,isNightly,libsArr,supportsLibraryCodeFilter,supportsExecute,supportsBinary,supportsAsmDocs,supportsOptOutput";
const COMPILER_FIELDS_EXTENDED = COMPILER_FIELDS_ESSENTIAL ++ ",tools,possibleOverrides,possibleRuntimeTools,license,notification,options,alias";

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    const io = init.io;
    try mcp.run(arena, io, .{ .name = "zmcp-compiler-explorer", .version = "0.1.0" }, &tool_table);
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "compile_check",
        .description = "Quick compilation validation - checks if code compiles without verbose output. Returns success, exit_code, error_count, warning_count, first_error.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "source":   { "type": "string", "description": "Source code to compile (minimal comments preferred)." },
        \\    "language": { "type": "string", "description": "Programming language (c++, c, rust, go, python, etc.)." },
        \\    "compiler": { "type": "string", "description": "Compiler identifier (e.g., 'g132', 'clang1600') or friendly name." },
        \\    "options":  { "type": "string", "description": "Compiler flags (e.g., '-O2 -Wall', '-std=c++20').", "default": "" },
        \\    "extract_args": { "type": "boolean", "description": "If true, extracts compiler flags from source comments like '// flags: -Wall'.", "default": true },
        \\    "libraries": { "type": "array", "description": "Libraries with format [{\"id\": \"library_name\", \"version\": \"latest\"}]." },
        \\    "create_binary": { "type": "boolean", "description": "Create a full executable binary.", "default": false },
        \\    "create_object_only": { "type": "boolean", "description": "Create object file without linking.", "default": false }
        \\  },
        \\  "required": ["source", "language", "compiler"]
        \\}
        ,
        .handler = handleCompileCheck,
        .read_only = true,
    },
    .{
        .name = "compile_and_run",
        .description = "Compile and run code, returning execution results and program output: compiled, executed, exit_code, execution_time_ms, stdout, stderr, truncated.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "source":   { "type": "string", "description": "Source code to compile and execute." },
        \\    "language": { "type": "string", "description": "Programming language (c++, c, rust, go, python, etc.)." },
        \\    "compiler": { "type": "string", "description": "Compiler identifier (e.g., 'g132', 'clang1600') or friendly name." },
        \\    "options":  { "type": "string", "description": "Compiler flags.", "default": "" },
        \\    "stdin":    { "type": "string", "description": "Standard input for the program.", "default": "" },
        \\    "args":     { "type": "array", "items": { "type": "string" }, "description": "Command line arguments for the program." },
        \\    "timeout":  { "type": "integer", "description": "Maximum execution time in milliseconds.", "default": 5000 },
        \\    "libraries": { "type": "array", "description": "Libraries [{\"id\": \"library_name\", \"version\": \"latest\"}]." },
        \\    "tools":    { "type": "array", "description": "Tools to run alongside compilation [{\"id\": \"tool_name\", \"args\": []}]." },
        \\    "create_binary": { "type": "boolean", "description": "Create a full executable binary.", "default": false },
        \\    "create_object_only": { "type": "boolean", "description": "Create object file without linking.", "default": false }
        \\  },
        \\  "required": ["source", "language", "compiler"]
        \\}
        ,
        .handler = handleCompileAndRun,
    },
    .{
        .name = "compile_with_diagnostics",
        .description = "Get comprehensive compilation warnings and errors with detailed analysis: type, line, column, message, suggestion per diagnostic.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "source":   { "type": "string", "description": "Source code to analyze." },
        \\    "language": { "type": "string", "description": "Programming language (c++, c, rust, go, etc.)." },
        \\    "compiler": { "type": "string", "description": "Compiler identifier (e.g., 'g132', 'clang1600') or friendly name." },
        \\    "options":  { "type": "string", "description": "Additional compiler flags.", "default": "" },
        \\    "diagnostic_level": { "type": "string", "enum": ["normal", "verbose"], "description": "'normal' adds -Wall; 'verbose' adds -Wall -Wextra -Wpedantic.", "default": "normal" },
        \\    "libraries": { "type": "array", "description": "Libraries [{\"id\": \"library_name\", \"version\": \"latest\"}]." },
        \\    "tools":    { "type": "array", "description": "Tools to run alongside compilation [{\"id\": \"iwyu022\", \"args\": []}]." },
        \\    "create_binary": { "type": "boolean", "description": "Create a full executable binary.", "default": false },
        \\    "create_object_only": { "type": "boolean", "description": "Create object file without linking.", "default": false }
        \\  },
        \\  "required": ["source", "language", "compiler"]
        \\}
        ,
        .handler = handleCompileWithDiagnostics,
        .read_only = true,
    },
    .{
        .name = "analyze_optimization",
        .description = "Analyze compiler optimizations and generated assembly code. Returns assembly_lines, instruction_count, assembly_output (capped at 500 lines), truncated, total_instructions and optional optimization remarks.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "source":   { "type": "string", "description": "Source code to analyze for optimizations." },
        \\    "language": { "type": "string", "description": "Programming language (c++, c, rust, go, etc.)." },
        \\    "compiler": { "type": "string", "description": "Compiler identifier (e.g., 'g132', 'clang1600') or friendly name." },
        \\    "optimization_level": { "type": "string", "description": "Optimization flags (e.g., '-O0', '-O2', '-O3', '-Os', '-Ofast').", "default": "-O3" },
        \\    "include_optimization_remarks": { "type": "boolean", "description": "Include compiler optimization remarks/passes in output.", "default": true },
        \\    "filter_out_library_code": { "type": ["boolean", "null"], "description": "Hide standard library implementations for cleaner output." },
        \\    "filter_out_debug_calls": { "type": ["boolean", "null"], "description": "Hide debug and profiling function calls." },
        \\    "do_demangle": { "type": ["boolean", "null"], "description": "Convert mangled C++ symbols to readable names." },
        \\    "libraries": { "type": "array", "description": "Libraries [{\"id\": \"library_name\", \"version\": \"latest\"}]." }
        \\  },
        \\  "required": ["source", "language", "compiler"]
        \\}
        ,
        .handler = handleAnalyzeOptimization,
        .read_only = true,
    },
    .{
        .name = "compare_compilers",
        .description = "Compare output across different compilers/options. comparison_type is 'assembly' (detailed asm diff), 'execution' (program output diff), or 'diagnostics' (warning comparison).",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "source":   { "type": "string", "description": "Source code to compile." },
        \\    "language": { "type": "string", "description": "Programming language (e.g., 'c++', 'rust')." },
        \\    "compilers": { "type": "array", "description": "Compiler configurations: [{\"id\": \"g132\", \"options\": \"-O2\"}]." },
        \\    "comparison_type": { "type": "string", "enum": ["assembly", "execution", "diagnostics"], "description": "Type of comparison." },
        \\    "libraries": { "type": "array", "description": "Libraries [{\"id\": \"library_name\", \"version\": \"latest\"}]." }
        \\  },
        \\  "required": ["source", "language", "compilers", "comparison_type"]
        \\}
        ,
        .handler = handleCompareCompilers,
    },
    .{
        .name = "generate_share_url",
        .description = "Generate shareable Compiler Explorer URLs with code, compiler settings, and configuration pre-loaded.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "source":   { "type": "string", "description": "Source code to include in the shareable URL." },
        \\    "language": { "type": "string", "description": "Programming language (c++, c, rust, go, python, etc.)." },
        \\    "compiler": { "type": "string", "description": "Compiler identifier (e.g., 'g132', 'clang1600') or friendly name." },
        \\    "options":  { "type": "string", "description": "Compiler flags.", "default": "" },
        \\    "layout":   { "type": "string", "enum": ["simple", "comparison", "assembly"], "description": "Compiler Explorer interface layout.", "default": "simple" },
        \\    "libraries": { "type": "array", "description": "Libraries [{\"id\": \"library_name\", \"version\": \"latest\"}]." },
        \\    "tools":    { "type": "array", "description": "Tools [{\"id\": \"tool_name\", \"args\": []}]." },
        \\    "create_binary": { "type": "boolean", "description": "Create a full executable binary.", "default": false },
        \\    "create_object_only": { "type": "boolean", "description": "Create object file without linking.", "default": false }
        \\  },
        \\  "required": ["source", "language", "compiler"]
        \\}
        ,
        .handler = handleGenerateShareUrl,
    },
    .{
        .name = "find_compilers",
        .description = "Find compilers with optional filtering by experimental features, proposals, or tools. Avoid generic searches like 'gcc' or 'clang' - use specific terms like 'gcc 13', or exact compiler IDs with exact_search=true.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "language": { "type": "string", "description": "Programming language.", "default": "c++" },
        \\    "proposal": { "type": ["string", "null"], "description": "Proposal number to search for (e.g., 'P3385', '3385')." },
        \\    "feature":  { "type": ["string", "null"], "description": "Experimental feature (e.g., 'reflection', 'concepts', 'modules')." },
        \\    "category": { "type": ["string", "null"], "description": "Category to filter by (e.g., 'proposals', 'reflection')." },
        \\    "show_all": { "type": "boolean", "description": "Show all experimental compilers organized by category.", "default": false },
        \\    "search_text": { "type": ["string", "null"], "description": "Filter compilers by text in names and IDs (e.g., 'gcc 13', 'msvc', 'nightly')." },
        \\    "exact_search": { "type": "boolean", "description": "Treat search_text as an exact compiler ID match (case-sensitive).", "default": false },
        \\    "ids_only": { "type": "boolean", "description": "Return only compiler IDs.", "default": false },
        \\    "include_overrides": { "type": "boolean", "description": "Include possibleOverrides field.", "default": false },
        \\    "include_runtime_tools": { "type": "boolean", "description": "Include possibleRuntimeTools field.", "default": false },
        \\    "include_compile_tools": { "type": "boolean", "description": "Include tools field.", "default": false }
        \\  }
        \\}
        ,
        .handler = handleFindCompilers,
        .read_only = true,
    },
    .{
        .name = "get_libraries",
        .description = "Get simplified list of libraries (id and name only) for a language with optional search.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "language": { "type": "string", "description": "Programming language.", "default": "c++" },
        \\    "search_text": { "type": ["string", "null"], "description": "Filter libraries by text search in names and IDs." }
        \\  }
        \\}
        ,
        .handler = handleGetLibraries,
        .read_only = true,
    },
    .{
        .name = "get_library_details",
        .description = "Get detailed information for a specific library including versions.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "language": { "type": "string", "description": "Programming language.", "default": "c++" },
        \\    "library_id": { "type": "string", "description": "The ID of the library to get details for." }
        \\  },
        \\  "required": ["library_id"]
        \\}
        ,
        .handler = handleGetLibraryDetails,
        .read_only = true,
    },
    .{
        .name = "get_languages",
        .description = "Get simplified list of languages (id, name and extensions only) with optional search.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "search_text": { "type": ["string", "null"], "description": "Filter languages by text search in names and IDs." }
        \\  }
        \\}
        ,
        .handler = handleGetLanguages,
        .read_only = true,
    },
    .{
        .name = "lookup_instruction",
        .description = "Get detailed documentation for assembly instructions/opcodes across architectures (amd64, aarch64, ...). Aliases like x64/arm64 are resolved automatically.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "instruction_set": { "type": "string", "description": "Architecture/instruction set name (e.g., 'amd64', 'x86_64', 'aarch64', 'arm64')." },
        \\    "opcode": { "type": "string", "description": "Instruction/opcode to look up (e.g., 'pop', 'stp', 'mov')." },
        \\    "format_output": { "type": "boolean", "description": "Format for readability (true) vs raw JSON (false).", "default": true }
        \\  },
        \\  "required": ["instruction_set", "opcode"]
        \\}
        ,
        .handler = handleLookupInstruction,
        .read_only = true,
    },
    .{
        .name = "download_shortlink",
        .description = "Download and save source code from a Compiler Explorer shortlink to local files, preserving original filenames when available.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "shortlink_url": { "type": "string", "description": "Full CE URL (https://godbolt.org/z/G38YP7eW4) or just the ID (G38YP7eW4)." },
        \\    "destination_path": { "type": "string", "description": "Directory path where files should be saved." },
        \\    "preserve_filenames": { "type": "boolean", "description": "Use original CE filenames when available.", "default": true },
        \\    "fallback_prefix": { "type": "string", "description": "Prefix for generated filenames when no original name.", "default": "ce" },
        \\    "include_metadata": { "type": "boolean", "description": "Save compilation settings as JSON metadata file.", "default": true },
        \\    "overwrite_existing": { "type": "boolean", "description": "Overwrite existing files instead of creating numbered variants.", "default": false }
        \\  },
        \\  "required": ["shortlink_url", "destination_path"]
        \\}
        ,
        .handler = handleDownloadShortlink,
        .read_only = true,
    },
    .{
        .name = "cmake_build",
        .description = "Build a multifile CMake project using Compiler Explorer. Specify files inline (cmake_source + files with contents), via local paths (cmake_path + files with path), or via project_dir auto-discovery.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "compiler": { "type": "string", "description": "Compiler identifier (e.g., 'g132', 'clang1600') or friendly name." },
        \\    "cmake_source": { "type": "string", "description": "Inline contents of CMakeLists.txt.", "default": "" },
        \\    "cmake_path": { "type": "string", "description": "Local path to CMakeLists.txt file.", "default": "" },
        \\    "project_dir": { "type": "string", "description": "Local directory containing CMakeLists.txt and source files.", "default": "" },
        \\    "files": { "type": "array", "description": "Source files: {\"filename\": ..., \"contents\": ...} or {\"path\": ...}." },
        \\    "language": { "type": "string", "description": "Programming language.", "default": "c++" },
        \\    "options": { "type": "string", "description": "Compiler flags (e.g., '-O2 -Wall').", "default": "" },
        \\    "cmake_args": { "type": "string", "description": "CMake arguments (e.g., '-DCMAKE_BUILD_TYPE=Release').", "default": "" },
        \\    "execute": { "type": "boolean", "description": "Run the built binary after compilation.", "default": false },
        \\    "libraries": { "type": "array", "description": "Libraries [{\"id\": \"lib\", \"version\": \"latest\"}] (include paths only)." }
        \\  },
        \\  "required": ["compiler"]
        \\}
        ,
        .handler = handleCmakeBuild,
    },
    .{
        .name = "generate_cmake_share_url",
        .description = "Generate a shareable Compiler Explorer URL for a CMake multifile project with all source files and build configuration pre-loaded.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "compiler": { "type": "string", "description": "Compiler identifier (e.g., 'g132', 'clang1600') or friendly name." },
        \\    "cmake_source": { "type": "string", "description": "Inline contents of CMakeLists.txt.", "default": "" },
        \\    "cmake_path": { "type": "string", "description": "Local path to CMakeLists.txt file.", "default": "" },
        \\    "project_dir": { "type": "string", "description": "Local directory containing CMakeLists.txt and source files.", "default": "" },
        \\    "files": { "type": "array", "description": "Source files: {\"filename\": ..., \"contents\": ...} or {\"path\": ...}." },
        \\    "language": { "type": "string", "description": "Programming language.", "default": "c++" },
        \\    "options": { "type": "string", "description": "Compiler flags.", "default": "" },
        \\    "cmake_args": { "type": "string", "description": "CMake arguments.", "default": "" },
        \\    "libraries": { "type": "array", "description": "Libraries [{\"id\": \"lib\", \"version\": \"latest\"}]." }
        \\  },
        \\  "required": ["compiler"]
        \\}
        ,
        .handler = handleGenerateCmakeShareUrl,
    },
};

// ---------------------------------------------------------------------------
// HTTP fetch seam (tests swap in a mock)
// ---------------------------------------------------------------------------

const HttpResp = struct {
    status: u16,
    body: []const u8,
};

const FetchRequest = struct {
    method: std.http.Method,
    url: []const u8,
    body: ?[]const u8 = null,
};

const FetchFn = *const fn (alloc: std.mem.Allocator, io: std.Io, req: FetchRequest) anyerror!HttpResp;

/// Active fetch implementation. Tests swap in a mock.
var fetch_impl: FetchFn = httpsFetch;

fn httpsFetch(alloc: std.mem.Allocator, io: std.Io, req: FetchRequest) !HttpResp {
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();
    const ua_owned = try mcp.userAgent(alloc, io, UA_PRODUCT);
    defer alloc.free(ua_owned);

    var resp_buf: std.Io.Writer.Allocating = .init(alloc);
    defer resp_buf.deinit();
    var decompress_buf: [128 * 1024]u8 = undefined;

    var header_buf: [3]std.http.Header = undefined;
    var n: usize = 0;
    header_buf[n] = .{ .name = "User-Agent", .value = ua_owned };
    n += 1;
    header_buf[n] = .{ .name = "Accept", .value = "application/json" };
    n += 1;
    if (req.body != null) {
        header_buf[n] = .{ .name = "Content-Type", .value = "application/json" };
        n += 1;
    }

    const fetch_res = try client.fetch(.{
        .location = .{ .url = req.url },
        .response_writer = &resp_buf.writer,
        .method = req.method,
        .payload = req.body,
        .extra_headers = header_buf[0..n],
        .decompress_buffer = &decompress_buf,
    });

    return .{
        .status = @intFromEnum(fetch_res.status),
        .body = try alloc.dupe(u8, resp_buf.written()),
    };
}

fn apiFetch(alloc: std.mem.Allocator, io: std.Io, method: std.http.Method, url: []const u8, body: ?[]const u8) !HttpResp {
    return fetch_impl(alloc, io, .{ .method = method, .url = url, .body = body });
}

// ---------------------------------------------------------------------------
// Small JSON helpers
// ---------------------------------------------------------------------------

fn getStr(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn getBool(args: std.json.Value, key: []const u8, default: bool) bool {
    if (args != .object) return default;
    const v = args.object.get(key) orelse return default;
    return switch (v) {
        .bool => |b| b,
        else => default,
    };
}

fn getOptBool(args: std.json.Value, key: []const u8) ?bool {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

fn getInt(args: std.json.Value, key: []const u8, default: i64) i64 {
    if (args != .object) return default;
    const v = args.object.get(key) orelse return default;
    return switch (v) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => default,
    };
}

/// String field of a JSON object Value; "" when missing or not a string.
fn jsonStr(v: std.json.Value, field: []const u8) []const u8 {
    return jsonOptStr(v, field) orelse "";
}

fn jsonOptStr(v: std.json.Value, field: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const fv = v.object.get(field) orelse return null;
    return switch (fv) {
        .string => |s| s,
        else => null,
    };
}

fn jsonInt(v: std.json.Value, field: []const u8, default: i64) i64 {
    if (v != .object) return default;
    const fv = v.object.get(field) orelse return default;
    return switch (fv) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => default,
    };
}

fn jsonBool(v: std.json.Value, field: []const u8, default: bool) bool {
    if (v != .object) return default;
    const fv = v.object.get(field) orelse return default;
    return switch (fv) {
        .bool => |b| b,
        else => default,
    };
}

fn jsonArray(v: std.json.Value, field: []const u8) []const std.json.Value {
    if (v != .object) return &.{};
    const fv = v.object.get(field) orelse return &.{};
    if (fv != .array) return &.{};
    return fv.array.items;
}

fn newJs(sw: *std.Io.Writer.Allocating) std.json.Stringify {
    return .{ .writer = &sw.writer, .options = .{ .whitespace = .indent_2 } };
}

fn resultText(alloc: std.mem.Allocator, sw: *std.Io.Writer.Allocating) !mcp.ToolResult {
    return .{ .text = try alloc.dupe(u8, sw.written()) };
}

fn errText(alloc: std.mem.Allocator, comptime fmt: []const u8, fmt_args: anytype) !mcp.ToolResult {
    return .{ .text = try std.fmt.allocPrint(alloc, fmt, fmt_args), .is_error = true };
}

fn parseJson(alloc: std.mem.Allocator, body: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, body, .{});
}

// ---------------------------------------------------------------------------
// Static configuration (ce-mcp config.py defaults)
// ---------------------------------------------------------------------------

/// ce-mcp FiltersConfig defaults.
const Filters = struct {
    binary: bool = false,
    binaryObject: bool = false,
    commentOnly: bool = false,
    demangle: bool = true,
    directives: bool = true,
    execute: bool = false,
    intel: bool = true,
    labels: bool = true,
    libraryCode: bool = true,
    trim: bool = true,
    debugCalls: bool = true,
};

fn writeFilters(js: *std.json.Stringify, f: Filters) !void {
    try js.beginObject();
    try js.objectField("binary");
    try js.write(f.binary);
    try js.objectField("binaryObject");
    try js.write(f.binaryObject);
    try js.objectField("commentOnly");
    try js.write(f.commentOnly);
    try js.objectField("demangle");
    try js.write(f.demangle);
    try js.objectField("directives");
    try js.write(f.directives);
    try js.objectField("execute");
    try js.write(f.execute);
    try js.objectField("intel");
    try js.write(f.intel);
    try js.objectField("labels");
    try js.write(f.labels);
    try js.objectField("libraryCode");
    try js.write(f.libraryCode);
    try js.objectField("trim");
    try js.write(f.trim);
    try js.objectField("debugCalls");
    try js.write(f.debugCalls);
    try js.endObject();
}

/// ce-mcp compiler_mappings: friendly name -> CE compiler id.
fn resolveCompiler(name: []const u8) []const u8 {
    const map = [_][2][]const u8{
        .{ "g++", "g132" },
        .{ "gcc-latest", "g132" },
        .{ "clang++", "clang1700" },
        .{ "clang-latest", "clang1700" },
        .{ "fpc", "fpc322" },
        .{ "rustc", "r1740" },
        .{ "go", "gccgo132" },
    };
    for (map) |entry| {
        if (std.mem.eql(u8, entry[0], name)) return entry[1];
    }
    return name;
}

// ---------------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------------

// --- shared handler helpers ---

fn argValue(args: std.json.Value, key: []const u8) std.json.Value {
    if (args != .object) return .null;
    return args.object.get(key) orelse .null;
}

fn trimWs(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, &std.ascii.whitespace);
}

fn lowerDup(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try alloc.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        }
        if (j == needle.len) return i;
    }
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return indexOfIgnoreCase(haystack, needle) != null;
}

const JsonResp = union(enum) {
    ok: std.json.Value,
    err: mcp.ToolResult,
};

fn postJson(alloc: std.mem.Allocator, io: std.Io, url: []const u8, payload: []const u8) !JsonResp {
    const resp = apiFetch(alloc, io, .POST, url, payload) catch |err| {
        return .{ .err = try errText(alloc, "Compiler Explorer API request failed: {s}", .{@errorName(err)}) };
    };
    if (resp.status < 200 or resp.status >= 300) {
        return .{ .err = try errText(alloc, "Compiler Explorer API error: HTTP {d}", .{resp.status}) };
    }
    const v = parseJsonValue(alloc, resp.body) catch {
        return .{ .err = try errText(alloc, "Compiler Explorer API returned invalid JSON", .{}) };
    };
    return .{ .ok = v };
}

fn parseJsonValue(alloc: std.mem.Allocator, body: []const u8) !std.json.Value {
    return (try parseJson(alloc, body)).value;
}

/// Split into lines like Python str.splitlines() for \n / \r\n input.
fn splitLines(alloc: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    if (text.len == 0) return list.items;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        var l = raw;
        if (l.len > 0 and l[l.len - 1] == '\r') l = l[0 .. l.len - 1];
        try list.append(alloc, l);
    }
    if (text[text.len - 1] == '\n') _ = list.pop();
    return list.items;
}

/// ce-mcp array-to-string conversion: join {"text": ...} items with no
/// separator; plain strings pass through.
fn streamText(alloc: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    switch (v) {
        .array => |arr| {
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            for (arr.items) |item| {
                switch (item) {
                    .object => try out.writer.writeAll(jsonStr(item, "text")),
                    .string => |s| try out.writer.writeAll(s),
                    .integer => |n| try out.writer.print("{d}", .{n}),
                    .float => |f| try out.writer.print("{d}", .{f}),
                    .bool => |b| try out.writer.writeAll(if (b) "True" else "False"),
                    else => {},
                }
            }
            return alloc.dupe(u8, out.written());
        },
        .string => |s| return alloc.dupe(u8, s),
        else => return "",
    }
}

fn libsToJson(alloc: std.mem.Allocator, libs: []const LibSpec) !?std.json.Value {
    if (libs.len == 0) return null;
    var arr = std.json.Array.init(alloc);
    for (libs) |l| {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(alloc, "id", .{ .string = l.id });
        try obj.put(alloc, "version", .{ .string = l.version });
        try arr.append(.{ .object = obj });
    }
    return std.json.Value{ .array = arr };
}

/// Execution-result shaping shared by compile_and_run and compare_compilers
/// (ce-mcp's "Handle different API response formats" block).
const ExecShape = struct {
    compiled: bool,
    executed: bool,
    exit_code: i64,
    stdout: []const u8,
    stderr: []const u8,
};

fn shapeExecution(alloc: std.mem.Allocator, result: std.json.Value) !ExecShape {
    const build_result = if (result == .object) result.object.get("buildResult") orelse result else result;
    const compiled = jsonInt(build_result, "code", 1) == 0;
    const executed = jsonBool(result, "didExecute", false) or
        (result == .object and result.object.get("execResult") != null);
    const exit_code = jsonInt(result, "code", -1);
    var stdout_v: []const u8 = undefined;
    var stderr_v: []const u8 = undefined;
    if (compiled) {
        stdout_v = try streamText(alloc, argValue(result, "stdout"));
        stderr_v = try streamText(alloc, argValue(result, "stderr"));
    } else {
        stdout_v = try streamText(alloc, argValue(build_result, "stdout"));
        stderr_v = try collectAllStderr(alloc, result);
    }
    return .{
        .compiled = compiled,
        .executed = executed,
        .exit_code = exit_code,
        .stdout = stdout_v,
        .stderr = stderr_v,
    };
}

fn countWarnings(result: std.json.Value) usize {
    var n: usize = 0;
    for (jsonArray(result, "stderr")) |d| {
        if (containsIgnoreCase(jsonStr(d, "text"), "warning")) n += 1;
    }
    return n;
}

fn handleCompileCheck(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const source = getStr(args, "source") orelse return errText(alloc, "error: source required", .{});
    const language = getStr(args, "language") orelse return errText(alloc, "error: language required", .{});
    const compiler = resolveCompiler(getStr(args, "compiler") orelse return errText(alloc, "error: compiler required", .{}));

    var options = getStr(args, "options") orelse "";
    if (getBool(args, "extract_args", true)) {
        if (try extractCompileArgs(alloc, source)) |ea| {
            options = trimWs(try std.fmt.allocPrint(alloc, "{s} {s}", .{ options, ea }));
        }
    }

    const libs = switch (try resolveLibraries(alloc, io, language, compiler, argValue(args, "libraries"))) {
        .ok => |l| l,
        .err => |msg| return .{ .text = msg, .is_error = true },
    };

    var filters = Filters{};
    if (getBool(args, "create_binary", false)) filters.binary = true;
    if (getBool(args, "create_object_only", false)) filters.binaryObject = true;

    const payload = try buildCompilePayload(alloc, source, language, compiler, options, filters, try libsToJson(alloc, libs), null, false);
    const url = try std.fmt.allocPrint(alloc, "{s}/compiler/{s}/compile", .{ API_BASE, compiler });
    const result = switch (try postJson(alloc, io, url, payload)) {
        .ok => |v| v,
        .err => |e| return e,
    };

    const code = jsonInt(result, "code", 1);
    var error_count: i64 = 0;
    var warning_count: i64 = 0;
    var first_error: ?[]const u8 = null;
    for (jsonArray(result, "diagnostics")) |d| {
        const t = jsonStr(d, "type");
        if (std.mem.eql(u8, t, "error")) {
            error_count += 1;
            if (first_error == null) first_error = jsonStr(d, "message");
        } else if (std.mem.eql(u8, t, "warning")) {
            warning_count += 1;
        }
    }

    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = newJs(&sw);
    try js.beginObject();
    try js.objectField("success");
    try js.write(code == 0);
    try js.objectField("exit_code");
    try js.write(code);
    try js.objectField("error_count");
    try js.write(error_count);
    try js.objectField("warning_count");
    try js.write(warning_count);
    try js.objectField("first_error");
    try js.write(first_error);
    try js.endObject();
    return resultText(alloc, &sw);
}

fn handleCompileAndRun(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const source = getStr(args, "source") orelse return errText(alloc, "error: source required", .{});
    const language = getStr(args, "language") orelse return errText(alloc, "error: language required", .{});
    const compiler = resolveCompiler(getStr(args, "compiler") orelse return errText(alloc, "error: compiler required", .{}));
    const options = getStr(args, "options") orelse "";
    const stdin = getStr(args, "stdin") orelse "";

    const libs = switch (try resolveLibraries(alloc, io, language, compiler, argValue(args, "libraries"))) {
        .ok => |l| l,
        .err => |msg| return .{ .text = msg, .is_error = true },
    };
    const validated = try validateTools(alloc, io, language, compiler, argValue(args, "tools"));

    var filters = Filters{ .execute = true };
    if (getBool(args, "create_binary", false)) filters.binary = true;
    if (getBool(args, "create_object_only", false)) filters.binaryObject = true;

    const payload = try buildExecutePayload(alloc, source, options, stdin, argValue(args, "args"), filters, try libsToJson(alloc, libs), validated.tools);
    const url = try std.fmt.allocPrint(alloc, "{s}/compiler/{s}/compile", .{ API_BASE, compiler });
    const result = switch (try postJson(alloc, io, url, payload)) {
        .ok => |v| v,
        .err => |e| return e,
    };

    const shape = try shapeExecution(alloc, result);

    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = newJs(&sw);
    try js.beginObject();
    try js.objectField("compiled");
    try js.write(shape.compiled);
    try js.objectField("executed");
    try js.write(shape.executed);
    try js.objectField("exit_code");
    try js.write(shape.exit_code);
    try js.objectField("execution_time_ms");
    try js.write(jsonInt(result, "execTime", 0));
    try js.objectField("stdout");
    try js.write(shape.stdout);
    try js.objectField("stderr");
    try js.write(shape.stderr);
    try js.objectField("truncated");
    try js.write(jsonBool(result, "truncated", false));
    if (validated.warnings.len > 0) {
        try js.objectField("tool_warnings");
        try js.beginArray();
        for (validated.warnings) |w| try js.write(w);
        try js.endArray();
    }
    try js.endObject();
    return resultText(alloc, &sw);
}

fn handleCompileWithDiagnostics(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const source = getStr(args, "source") orelse return errText(alloc, "error: source required", .{});
    const language = getStr(args, "language") orelse return errText(alloc, "error: language required", .{});
    const compiler = resolveCompiler(getStr(args, "compiler") orelse return errText(alloc, "error: compiler required", .{}));

    var options = getStr(args, "options") orelse "";
    const level = getStr(args, "diagnostic_level") orelse "normal";
    if (std.mem.eql(u8, level, "verbose")) {
        options = trimWs(try std.fmt.allocPrint(alloc, "{s} -Wall -Wextra -Wpedantic", .{options}));
    } else if (std.mem.eql(u8, level, "normal")) {
        options = trimWs(try std.fmt.allocPrint(alloc, "{s} -Wall", .{options}));
    }

    const libs = switch (try resolveLibraries(alloc, io, language, compiler, argValue(args, "libraries"))) {
        .ok => |l| l,
        .err => |msg| return .{ .text = msg, .is_error = true },
    };
    const validated = try validateTools(alloc, io, language, compiler, argValue(args, "tools"));

    var filters = Filters{};
    if (getBool(args, "create_binary", false)) filters.binary = true;
    if (getBool(args, "create_object_only", false)) filters.binaryObject = true;

    const payload = try buildCompilePayload(alloc, source, language, compiler, options, filters, try libsToJson(alloc, libs), validated.tools, false);
    const url = try std.fmt.allocPrint(alloc, "{s}/compiler/{s}/compile", .{ API_BASE, compiler });
    const result = switch (try postJson(alloc, io, url, payload)) {
        .ok => |v| v,
        .err => |e| return e,
    };

    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = newJs(&sw);
    try js.beginObject();
    try js.objectField("success");
    try js.write(jsonInt(result, "code", 1) == 0);
    try js.objectField("diagnostics");
    try js.beginArray();
    for (jsonArray(result, "stderr")) |diag| {
        if (diag != .object) continue;
        const raw_text = jsonOptStr(diag, "text") orelse continue;
        const tag_v = diag.object.get("tag") orelse .null;
        if (tag_v == .object) {
            // ce-mcp severity mapping: 0=note, 1=warning, >=2 error
            const severity = jsonInt(tag_v, "severity", 2);
            const diag_type: []const u8 = if (severity == 0) "note" else if (severity == 1) "warning" else if (severity >= 2) "error" else "warning";
            const message = jsonOptStr(tag_v, "text") orelse raw_text;
            const suggestion = try extractCompilerSuggestion(alloc, message);
            try js.beginObject();
            try js.objectField("type");
            try js.write(diag_type);
            try js.objectField("line");
            try js.write(jsonInt(tag_v, "line", 0));
            try js.objectField("column");
            try js.write(jsonInt(tag_v, "column", 0));
            try js.objectField("message");
            try js.write(message);
            try js.objectField("suggestion");
            try js.write(suggestion);
            try js.endObject();
        } else if (diag.object.get("line") != null and diag.object.get("column") != null) {
            const diag_type: []const u8 = if (containsIgnoreCase(raw_text, "error")) "error" else "warning";
            const suggestion = try extractCompilerSuggestion(alloc, raw_text);
            try js.beginObject();
            try js.objectField("type");
            try js.write(diag_type);
            try js.objectField("line");
            try js.write(jsonInt(diag, "line", 0));
            try js.objectField("column");
            try js.write(jsonInt(diag, "column", 0));
            try js.objectField("message");
            try js.write(raw_text);
            try js.objectField("suggestion");
            try js.write(suggestion);
            try js.endObject();
        }
    }
    try js.endArray();
    try js.objectField("command");
    try js.write(try std.fmt.allocPrint(alloc, "{s} {s} <source>", .{ compiler, options }));
    try js.objectField("tool_outputs");
    try js.beginArray();
    for (jsonArray(result, "tools")) |tool_result| {
        if (tool_result != .object) continue;
        if (tool_result.object.get("stdout") == null) continue;
        try js.beginObject();
        try js.objectField("tool_id");
        try js.write(jsonOptStr(tool_result, "id") orelse "unknown");
        try js.objectField("stdout");
        try js.write(argValue(tool_result, "stdout"));
        try js.objectField("stderr");
        try js.write(argValue(tool_result, "stderr"));
        try js.objectField("code");
        try js.write(jsonInt(tool_result, "code", 0));
        try js.endObject();
    }
    try js.endArray();
    if (validated.warnings.len > 0) {
        try js.objectField("tool_warnings");
        try js.beginArray();
        for (validated.warnings) |w| try js.write(w);
        try js.endArray();
    }
    try js.endObject();
    return resultText(alloc, &sw);
}

fn handleAnalyzeOptimization(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const source = getStr(args, "source") orelse return errText(alloc, "error: source required", .{});
    const language = getStr(args, "language") orelse return errText(alloc, "error: language required", .{});
    const compiler = resolveCompiler(getStr(args, "compiler") orelse return errText(alloc, "error: compiler required", .{}));
    const options = getStr(args, "optimization_level") orelse "-O3";
    const include_remarks = getBool(args, "include_optimization_remarks", true);

    // ce-mcp inverts the "filter_out_*" booleans into CE filter flags
    var filters = Filters{};
    if (getOptBool(args, "filter_out_library_code")) |v| filters.libraryCode = !v;
    if (getOptBool(args, "filter_out_debug_calls")) |v| filters.debugCalls = !v;
    if (getOptBool(args, "do_demangle")) |v| filters.demangle = v;

    const libs = switch (try resolveLibraries(alloc, io, language, compiler, argValue(args, "libraries"))) {
        .ok => |l| l,
        .err => |msg| return .{ .text = msg, .is_error = true },
    };

    const payload = try buildCompilePayload(alloc, source, language, compiler, options, filters, try libsToJson(alloc, libs), null, true);
    const url = try std.fmt.allocPrint(alloc, "{s}/compiler/{s}/compile", .{ API_BASE, compiler });
    const result = switch (try postJson(alloc, io, url, payload)) {
        .ok => |v| v,
        .err => |e| return e,
    };

    const asm_text = try joinTexts(alloc, argValue(result, "asm"), "\n");
    const asm_lines = try splitLines(alloc, asm_text);

    var instruction_lines: std.ArrayList([]const u8) = .empty;
    for (asm_lines) |line| {
        const stripped = trimWs(line);
        if (stripped.len > 0) try instruction_lines.append(alloc, stripped);
    }

    var truncated = false;
    if (instruction_lines.items.len > MAX_ASSEMBLY_LINES) {
        instruction_lines.shrinkRetainingCapacity(MAX_ASSEMBLY_LINES);
        truncated = true;
    }

    // Optimization pass texts (optOutput)
    var opt_info: std.ArrayList([]const u8) = .empty;
    var remarks: std.ArrayList([]const u8) = .empty;
    const opt_output = argValue(result, "optOutput");
    if (opt_output == .array) {
        for (opt_output.array.items) |item| {
            switch (item) {
                .object => {
                    try opt_info.append(alloc, jsonStr(item, "text"));
                    if (include_remarks) {
                        const display = jsonStr(item, "displayString");
                        if (display.len > 0) {
                            const pass_name = jsonStr(item, "Pass");
                            const opt_type_lower = try lowerDup(alloc, jsonStr(item, "optType"));
                            const debug_loc = argValue(item, "DebugLoc");
                            if (debug_loc == .object) {
                                try remarks.append(alloc, try std.fmt.allocPrint(alloc, "{s}:{d}:{d}: remark: {s} [-R{s}={s}]", .{
                                    jsonOptStr(debug_loc, "File") orelse "example.cpp",
                                    jsonInt(debug_loc, "Line", 0),
                                    jsonInt(debug_loc, "Column", 0),
                                    display,
                                    opt_type_lower,
                                    pass_name,
                                }));
                            } else {
                                try remarks.append(alloc, try std.fmt.allocPrint(alloc, "remark: {s} [-R{s}={s}]", .{ display, opt_type_lower, pass_name }));
                            }
                        }
                    }
                },
                .string => |s| try opt_info.append(alloc, s),
                .integer => |n| try opt_info.append(alloc, try std.fmt.allocPrint(alloc, "{d}", .{n})),
                else => {},
            }
        }
    } else if (opt_output == .string) {
        try opt_info.append(alloc, opt_output.string);
    }

    var any_opt_info = false;
    for (opt_info.items) |info| {
        if (trimWs(info).len > 0) any_opt_info = true;
    }

    const total_instructions = instruction_lines.items.len +
        (if (truncated) asm_lines.len - MAX_ASSEMBLY_LINES else 0);

    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = newJs(&sw);
    try js.beginObject();
    try js.objectField("assembly_lines");
    try js.write(asm_lines.len);
    try js.objectField("instruction_count");
    try js.write(instruction_lines.items.len);
    try js.objectField("assembly_output");
    try js.beginArray();
    for (instruction_lines.items) |l| try js.write(l);
    try js.endArray();
    try js.objectField("truncated");
    try js.write(truncated);
    try js.objectField("total_instructions");
    try js.write(total_instructions);
    if (any_opt_info) {
        try js.objectField("optimization_info");
        try js.beginArray();
        for (opt_info.items) |info| try js.write(info);
        try js.endArray();
    }
    if (include_remarks and remarks.items.len > 0) {
        try js.objectField("optimization_remarks");
        try js.beginArray();
        for (remarks.items) |r| try js.write(r);
        try js.endArray();
    }
    try js.endObject();
    return resultText(alloc, &sw);
}

const ComparisonType = enum { assembly, execution, diagnostics };

const CompareResult = struct {
    compiler: []const u8,
    options: []const u8,
    compiled: bool = false,
    executed: bool = false,
    exit_code: i64 = -1,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    asm_text: []const u8 = "",
    assembly_size: usize = 0,
    warnings: usize = 0,
};

fn handleCompareCompilers(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const source = getStr(args, "source") orelse return errText(alloc, "error: source required", .{});
    const language = getStr(args, "language") orelse return errText(alloc, "error: language required", .{});
    const compilers_v = argValue(args, "compilers");
    if (compilers_v != .array or compilers_v.array.items.len == 0) {
        return errText(alloc, "error: compilers array required", .{});
    }
    const ctype_str = getStr(args, "comparison_type") orelse return errText(alloc, "error: comparison_type required", .{});
    const ctype: ComparisonType = if (std.mem.eql(u8, ctype_str, "assembly"))
        .assembly
    else if (std.mem.eql(u8, ctype_str, "execution"))
        .execution
    else if (std.mem.eql(u8, ctype_str, "diagnostics"))
        .diagnostics
    else
        return errText(alloc, "error: comparison_type must be assembly, execution, or diagnostics", .{});

    const first_compiler = resolveCompiler(jsonStr(compilers_v.array.items[0], "id"));
    const libs = switch (try resolveLibraries(alloc, io, language, first_compiler, argValue(args, "libraries"))) {
        .ok => |l| l,
        .err => |msg| return .{ .text = msg, .is_error = true },
    };
    const libs_json = try libsToJson(alloc, libs);

    var results: std.ArrayList(CompareResult) = .empty;
    for (compilers_v.array.items) |cc| {
        if (cc != .object) continue;
        const cid = resolveCompiler(jsonStr(cc, "id"));
        const coptions = jsonStr(cc, "options");
        const url = try std.fmt.allocPrint(alloc, "{s}/compiler/{s}/compile", .{ API_BASE, cid });
        switch (ctype) {
            .execution => {
                const payload = try buildExecutePayload(alloc, source, coptions, "", .null, .{ .execute = true }, libs_json, null);
                const result = switch (try postJson(alloc, io, url, payload)) {
                    .ok => |v| v,
                    .err => |e| return e,
                };
                const shape = try shapeExecution(alloc, result);
                try results.append(alloc, .{
                    .compiler = cid,
                    .options = coptions,
                    .compiled = shape.compiled,
                    .executed = shape.executed,
                    .exit_code = shape.exit_code,
                    .stdout = shape.stdout,
                    .stderr = shape.stderr,
                });
            },
            .assembly => {
                const payload = try buildCompilePayload(alloc, source, language, cid, coptions, .{}, libs_json, null, false);
                const result = switch (try postJson(alloc, io, url, payload)) {
                    .ok => |v| v,
                    .err => |e| return e,
                };
                const asm_text = try joinTexts(alloc, argValue(result, "asm"), "\n");
                const asm_size = (try splitLines(alloc, asm_text)).len;
                try results.append(alloc, .{
                    .compiler = cid,
                    .options = coptions,
                    .asm_text = asm_text,
                    .assembly_size = asm_size,
                    .warnings = countWarnings(result),
                });
            },
            .diagnostics => {
                const payload = try buildCompilePayload(alloc, source, language, cid, coptions, .{}, libs_json, null, false);
                const result = switch (try postJson(alloc, io, url, payload)) {
                    .ok => |v| v,
                    .err => |e| return e,
                };
                try results.append(alloc, .{
                    .compiler = cid,
                    .options = coptions,
                    .warnings = countWarnings(result),
                });
            },
        }
    }

    var differences: std.ArrayList([]const u8) = .empty;

    // assembly_diff / execution_diff data (emitted only when computed)
    var asm_diff_stats: ?DiffStats = null;
    var asm_diff_summary: []const u8 = "";
    var asm_diff_unified: []const u8 = "";
    var exec_stdout_diff: ?[]const u8 = null;
    var exec_stderr_diff: ?[]const u8 = null;
    var exec_diff_summary: ?[]const u8 = null;

    if (results.items.len >= 2) {
        const r1 = results.items[0];
        const r2 = results.items[1];
        switch (ctype) {
            .assembly => {
                const size_diff: i64 = @as(i64, @intCast(r1.assembly_size)) - @as(i64, @intCast(r2.assembly_size));
                if (size_diff != 0) {
                    const abs_diff: u64 = @intCast(if (size_diff < 0) -size_diff else size_diff);
                    const percent_f = @as(f64, @floatFromInt(abs_diff)) / @as(f64, @floatFromInt(@max(r1.assembly_size, 1))) * 100.0;
                    const percent: u64 = @intFromFloat(@round(percent_f));
                    try differences.append(alloc, try std.fmt.allocPrint(alloc, "{s} produces {d}% {s} code", .{
                        r2.compiler,
                        percent,
                        if (size_diff > 0) "smaller" else "larger",
                    }));
                }
                const label1 = try std.fmt.allocPrint(alloc, "{s} {s}", .{ r1.compiler, r1.options });
                const label2 = try std.fmt.allocPrint(alloc, "{s} {s}", .{ r2.compiler, r2.options });
                const lines1 = try normalizeAssembly(alloc, r1.asm_text);
                const lines2 = try normalizeAssembly(alloc, r2.asm_text);
                const diff_text = try unifiedDiff(alloc, lines1, lines2, label1, label2, 3);
                const stats = try analyzeDiffText(alloc, diff_text);
                asm_diff_stats = stats;
                asm_diff_summary = try generateDiffSummary(alloc, stats, lines1, lines2);
                // ce-mcp truncates the unified diff to 50 lines
                const diff_lines = try splitLines(alloc, diff_text);
                const keep = @min(diff_lines.len, 50);
                var ud: std.Io.Writer.Allocating = .init(alloc);
                defer ud.deinit();
                for (diff_lines[0..keep], 0..) |l, i| {
                    if (i > 0) try ud.writer.writeByte('\n');
                    try ud.writer.writeAll(l);
                }
                try ud.writer.writeAll("\n... (truncated)");
                asm_diff_unified = try alloc.dupe(u8, ud.written());
                try differences.append(alloc, asm_diff_summary);
            },
            .execution => {
                // _analyze_execution_differences port
                if (r1.compiled != r2.compiled) {
                    if (r1.compiled) {
                        try differences.append(alloc, try std.fmt.allocPrint(alloc, "{s} compiled successfully, {s} failed", .{ r1.compiler, r2.compiler }));
                    } else {
                        try differences.append(alloc, try std.fmt.allocPrint(alloc, "{s} compiled successfully, {s} failed", .{ r2.compiler, r1.compiler }));
                    }
                } else if (r1.compiled) {
                    try differences.append(alloc, "Both compilers compiled successfully");
                } else {
                    try differences.append(alloc, "Both compilers failed to compile");
                }
                if (r1.compiled and r2.compiled) {
                    if (r1.executed != r2.executed) {
                        try differences.append(alloc, try std.fmt.allocPrint(alloc, "Execution status differs: {s}={s}, {s}={s}", .{
                            r1.compiler,
                            if (r1.executed) "executed" else "not executed",
                            r2.compiler,
                            if (r2.executed) "executed" else "not executed",
                        }));
                    }
                    if (r1.exit_code != r2.exit_code) {
                        try differences.append(alloc, try std.fmt.allocPrint(alloc, "Exit codes differ: {s}={d}, {s}={d}", .{ r1.compiler, r1.exit_code, r2.compiler, r2.exit_code }));
                    }
                    const label1 = try std.fmt.allocPrint(alloc, "{s} {s}", .{ r1.compiler, r1.options });
                    const label2 = try std.fmt.allocPrint(alloc, "{s} {s}", .{ r2.compiler, r2.options });
                    if (!std.mem.eql(u8, r1.stdout, r2.stdout)) {
                        const sl1 = try splitLines(alloc, r1.stdout);
                        const sl2 = try splitLines(alloc, r2.stdout);
                        if (sl1.len != sl2.len) {
                            const diff_lines: i64 = @as(i64, @intCast(sl2.len)) - @as(i64, @intCast(sl1.len));
                            if (diff_lines > 0) {
                                try differences.append(alloc, try std.fmt.allocPrint(alloc, "Stdout differs: {s} output has {d} more lines", .{ r2.compiler, diff_lines }));
                            } else {
                                try differences.append(alloc, try std.fmt.allocPrint(alloc, "Stdout differs: {s} output has {d} more lines", .{ r1.compiler, -diff_lines }));
                            }
                        } else {
                            try differences.append(alloc, "Stdout content differs");
                        }
                        exec_stdout_diff = try unifiedDiff(alloc, sl1, sl2, label1, label2, 3);
                    }
                    if (!std.mem.eql(u8, r1.stderr, r2.stderr)) {
                        const sl1 = try splitLines(alloc, r1.stderr);
                        const sl2 = try splitLines(alloc, r2.stderr);
                        if (sl1.len != sl2.len) {
                            const diff_lines: i64 = @as(i64, @intCast(sl2.len)) - @as(i64, @intCast(sl1.len));
                            if (diff_lines > 0) {
                                try differences.append(alloc, try std.fmt.allocPrint(alloc, "Stderr differs: {s} output has {d} more lines", .{ r2.compiler, diff_lines }));
                            } else {
                                try differences.append(alloc, try std.fmt.allocPrint(alloc, "Stderr differs: {s} output has {d} more lines", .{ r1.compiler, -diff_lines }));
                            }
                        } else {
                            try differences.append(alloc, "Stderr content differs");
                        }
                        exec_stderr_diff = try unifiedDiff(alloc, sl1, sl2, label1, label2, 3);
                    }
                }
                if (exec_stdout_diff != null or exec_stderr_diff != null) {
                    var parts: std.ArrayList([]const u8) = .empty;
                    if (exec_stdout_diff != null) try parts.append(alloc, "stdout differs");
                    if (exec_stderr_diff != null) try parts.append(alloc, "stderr differs");
                    var sum: std.Io.Writer.Allocating = .init(alloc);
                    defer sum.deinit();
                    try sum.writer.writeAll("Execution comparison: ");
                    for (parts.items, 0..) |p, i| {
                        if (i > 0) try sum.writer.writeAll(", ");
                        try sum.writer.writeAll(p);
                    }
                    exec_diff_summary = try alloc.dupe(u8, sum.written());
                }
            },
            .diagnostics => {
                const warn_diff: i64 = @as(i64, @intCast(r1.warnings)) - @as(i64, @intCast(r2.warnings));
                if (warn_diff != 0) {
                    const abs_diff: u64 = @intCast(if (warn_diff < 0) -warn_diff else warn_diff);
                    try differences.append(alloc, try std.fmt.allocPrint(alloc, "{s} produces {d} {s} warnings", .{
                        r2.compiler,
                        abs_diff,
                        if (warn_diff > 0) "fewer" else "more",
                    }));
                }
            },
        }
    }

    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = newJs(&sw);
    try js.beginObject();
    try js.objectField("results");
    try js.beginArray();
    for (results.items) |r| {
        try js.beginObject();
        try js.objectField("compiler");
        try js.write(r.compiler);
        try js.objectField("options");
        try js.write(r.options);
        switch (ctype) {
            .execution => {
                try js.objectField("compiled");
                try js.write(r.compiled);
                try js.objectField("executed");
                try js.write(r.executed);
                try js.objectField("exit_code");
                try js.write(r.exit_code);
                try js.objectField("stdout");
                try js.write(r.stdout);
                try js.objectField("stderr");
                try js.write(r.stderr);
                try js.objectField("assembly_size");
                try js.write(@as(usize, 0));
                try js.objectField("warnings");
                try js.write(@as(usize, 0));
            },
            .assembly, .diagnostics => {
                try js.objectField("execution_result");
                try js.write("");
                try js.objectField("assembly_size");
                try js.write(if (ctype == .assembly) r.assembly_size else 0);
                try js.objectField("warnings");
                try js.write(r.warnings);
            },
        }
        try js.endObject();
    }
    try js.endArray();
    try js.objectField("differences");
    try js.beginArray();
    for (differences.items) |d| try js.write(d);
    try js.endArray();
    if (asm_diff_stats) |stats| {
        try js.objectField("assembly_diff");
        try js.beginObject();
        try js.objectField("statistics");
        try writeDiffStats(&js, stats);
        try js.objectField("summary");
        try js.write(asm_diff_summary);
        try js.objectField("unified_diff");
        try js.write(asm_diff_unified);
        try js.endObject();
    }
    if (exec_stdout_diff != null or exec_stderr_diff != null) {
        try js.objectField("execution_diff");
        try js.beginObject();
        if (exec_stdout_diff) |d| {
            try js.objectField("stdout_diff");
            try js.write(d);
        }
        if (exec_stderr_diff) |d| {
            try js.objectField("stderr_diff");
            try js.write(d);
        }
        if (exec_diff_summary) |s| {
            try js.objectField("summary");
            try js.write(s);
        }
        try js.endObject();
    }
    try js.endObject();
    return resultText(alloc, &sw);
}

fn writeDiffStats(js: *std.json.Stringify, stats: DiffStats) !void {
    try js.beginObject();
    try js.objectField("lines_added");
    try js.write(stats.lines_added);
    try js.objectField("lines_removed");
    try js.write(stats.lines_removed);
    try js.objectField("lines_changed");
    try js.write(@as(usize, 0));
    inline for (.{
        .{ "instructions_added", stats.instructions_added },
        .{ "instructions_removed", stats.instructions_removed },
        .{ "function_calls_added", stats.calls_added },
        .{ "function_calls_removed", stats.calls_removed },
        .{ "unique_instructions_added", stats.unique_instructions_added },
        .{ "unique_instructions_removed", stats.unique_instructions_removed },
        .{ "unique_calls_added", stats.unique_calls_added },
        .{ "unique_calls_removed", stats.unique_calls_removed },
    }) |field| {
        try js.objectField(field[0]);
        try js.beginArray();
        for (field[1]) |s| try js.write(s);
        try js.endArray();
    }
    try js.endObject();
}

fn handleGenerateShareUrl(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const source = getStr(args, "source") orelse return errText(alloc, "error: source required", .{});
    const language = getStr(args, "language") orelse return errText(alloc, "error: language required", .{});
    const compiler = resolveCompiler(getStr(args, "compiler") orelse return errText(alloc, "error: compiler required", .{}));
    const options = getStr(args, "options") orelse "";
    // layout is accepted for schema parity; ce-mcp does not put it in the payload

    const libs = switch (try resolveLibraries(alloc, io, language, compiler, argValue(args, "libraries"))) {
        .ok => |l| l,
        .err => |msg| return .{ .text = msg, .is_error = true },
    };
    const validated = try validateTools(alloc, io, language, compiler, argValue(args, "tools"));

    const payload = try buildSharePayload(
        alloc,
        source,
        language,
        compiler,
        options,
        try libsToJson(alloc, libs),
        validated.tools,
        getBool(args, "create_binary", false),
        getBool(args, "create_object_only", false),
    );
    const url = try std.fmt.allocPrint(alloc, "{s}/shortener", .{API_BASE});
    const result = switch (try postJson(alloc, io, url, payload)) {
        .ok => |v| v,
        .err => |e| return e,
    };

    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = newJs(&sw);
    try js.beginObject();
    try js.objectField("url");
    try js.write(jsonStr(result, "url"));
    try js.endObject();
    return resultText(alloc, &sw);
}

/// Fixed category order from ce-mcp's ExperimentalCompilerFinder.
const category_order = [_][]const u8{
    "proposals",
    "reflection",
    "concepts",
    "modules",
    "coroutines",
    "contracts",
    "lifetime_analysis",
    "metaprogramming",
    "trunk_nightly",
    "other_experimental",
};

fn handleFindCompilers(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const language = getStr(args, "language") orelse "c++";
    const proposal = getStr(args, "proposal");
    const feature = getStr(args, "feature");
    const category = getStr(args, "category");
    const show_all = getBool(args, "show_all", false);
    const search_text = getStr(args, "search_text");
    const exact_search = getBool(args, "exact_search", false);
    const ids_only = getBool(args, "ids_only", false);
    const include_overrides = getBool(args, "include_overrides", false);
    const include_runtime_tools = getBool(args, "include_runtime_tools", false);
    const include_compile_tools = getBool(args, "include_compile_tools", false);

    // ce-mcp's broad-search guard (no HTTP call needed)
    if (search_text) |st| {
        if (!exact_search) {
            const lower = trimWs(try lowerDup(alloc, st));
            const forbidden = [_][]const u8{ "gcc", "clang", "g++", "clang++" };
            for (forbidden) |term| {
                if (std.mem.eql(u8, lower, term)) {
                    var sw: std.Io.Writer.Allocating = .init(alloc);
                    defer sw.deinit();
                    var js = newJs(&sw);
                    try js.beginObject();
                    try js.objectField("error");
                    try js.write(try std.fmt.allocPrint(alloc, "Search term '{s}' is too broad and would exceed token limits (25k+). Please be more specific:", .{st}));
                    try js.objectField("suggestions");
                    try js.beginArray();
                    try js.write(try std.fmt.allocPrint(alloc, "Use specific versions: '{s} 13', '{s} 14', '{s} 17'", .{ st, st, st }));
                    try js.write(try std.fmt.allocPrint(alloc, "Use architecture prefix: 'x86-64 {s}', 'arm64 {s}'", .{ st, st }));
                    try js.write(try std.fmt.allocPrint(alloc, "Use exact compiler ID with exact_search=True: '{s}132', '{s}1600'", .{ st, st }));
                    try js.endArray();
                    try js.objectField("valid_examples");
                    try js.beginArray();
                    for ([_][]const u8{ "gcc 13", "clang 17", "msvc", "nightly", "g132", "clang1600" }) |ex| try js.write(ex);
                    try js.endArray();
                    try js.endObject();
                    return resultText(alloc, &sw);
                }
            }
        }
    }

    const url = try std.fmt.allocPrint(alloc, "{s}/compilers/{s}?fields={s}", .{ API_BASE, language, COMPILER_FIELDS_EXTENDED });
    const resp = apiFetch(alloc, io, .GET, url, null) catch |err| {
        return errText(alloc, "Compiler Explorer API request failed: {s}", .{@errorName(err)});
    };
    if (resp.status != 200) return errText(alloc, "Compiler Explorer API error: HTTP {d}", .{resp.status});
    const compilers = parseJsonValue(alloc, resp.body) catch return errText(alloc, "Compiler Explorer API returned invalid JSON", .{});
    const comp_list = if (compilers == .array) compilers.array.items else &.{}; // unexpected shape -> empty

    const use_categories = (proposal == null and feature == null and category == null and search_text == null) or show_all;

    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = newJs(&sw);

    if (use_categories) {
        // Categorize all experimental compilers (fixed category order).
        var cats: [category_order.len]std.ArrayList(ExpCompiler) = undefined;
        for (&cats) |*c| c.* = .empty;

        for (comp_list) |comp| {
            if (comp != .object) continue;
            const name = jsonStr(comp, "name");
            const id = jsonStr(comp, "id");
            const name_lower = try lowerDup(alloc, name);
            const id_lower = try lowerDup(alloc, id);
            if (!isExperimental(name_lower, id_lower, jsonBool(comp, "isNightly", false))) continue;
            const cat = determineCategory(name_lower);
            const ec = try makeExpCompiler(alloc, comp, cat);
            if (ec.proposals.len > 0) {
                try cats[0].append(alloc, ec);
                // also add to the feature-based category
                for (category_order[1..], cats[1..]) |cname, *clist| {
                    if (std.mem.eql(u8, cname, cat)) {
                        try clist.append(alloc, ec);
                        break;
                    }
                }
            } else {
                for (category_order, &cats) |cname, *clist| {
                    if (std.mem.eql(u8, cname, cat)) {
                        try clist.append(alloc, ec);
                        break;
                    }
                }
            }
        }

        // Fetch version info for nightly compilers in each category.
        for (&cats) |*clist| {
            for (clist.items) |*ec| {
                if (ec.is_nightly) try fetchVersionInfo(alloc, io, ec);
            }
        }

        // Compute per-category filtered lists first so summary counts are
        // known before anything is emitted.
        var filtered_cats: [category_order.len][]const ExpCompiler = undefined;
        var total_experimental: usize = 0;
        var categories_found: usize = 0;
        for (&cats, 0..) |*clist, i| {
            const filtered = try applyTextFilter(alloc, clist.items, search_text, exact_search);
            filtered_cats[i] = filtered;
            if (filtered.len == 0) continue;
            total_experimental += filtered.len;
            categories_found += 1;
        }

        try js.beginObject();
        try js.objectField("summary");
        try js.beginObject();
        try js.objectField("language");
        try js.write(language);
        try js.objectField("total_experimental");
        try js.write(total_experimental);
        try js.objectField("categories_found");
        try js.write(categories_found);
        try js.objectField("filter_used");
        try js.write(search_text);
        try js.endObject();
        try js.objectField("categories");
        try js.beginObject();
        for (category_order, &filtered_cats) |cname, filtered| {
            if (filtered.len == 0) continue;
            try js.objectField(cname);
            try js.beginObject();
            try js.objectField("count");
            try js.write(filtered.len);
            try js.objectField("compilers");
            try js.beginArray();
            for (filtered) |ec| {
                if (ids_only) {
                    try js.write(ec.id);
                } else {
                    try writeCompilerInfo(&js, alloc, ec, include_overrides, include_runtime_tools, include_compile_tools);
                }
            }
            try js.endArray();
            try js.endObject();
        }
        try js.endObject();
        try js.endObject();
        return resultText(alloc, &sw);
    }

    // Flat list branch.
    var list: std.ArrayList(ExpCompiler) = .empty;
    if (proposal) |p| {
        for (comp_list) |comp| {
            if (comp != .object) continue;
            if (try matchProposal(alloc, comp, p)) {
                try list.append(alloc, try makeExpCompiler(alloc, comp, "proposals"));
            }
        }
    } else if (feature) |f| {
        const feature_lower = try lowerDup(alloc, f);
        const keywords = featureKeywords(feature_lower);
        for (comp_list) |comp| {
            if (comp != .object) continue;
            const name_lower = try lowerDup(alloc, jsonStr(comp, "name"));
            var matched = false;
            for (keywords) |kw| {
                if (std.mem.indexOf(u8, name_lower, kw) != null) matched = true;
            }
            if (matched) try list.append(alloc, try makeExpCompiler(alloc, comp, feature_lower));
        }
    } else {
        for (comp_list) |comp| {
            if (comp != .object) continue;
            const name = jsonStr(comp, "name");
            const id = jsonStr(comp, "id");
            const name_lower = try lowerDup(alloc, name);
            const id_lower = try lowerDup(alloc, id);
            if (!isExperimental(name_lower, id_lower, jsonBool(comp, "isNightly", false))) continue;
            const ec = try makeExpCompiler(alloc, comp, determineCategory(name_lower));
            if (category) |cat| {
                if (!std.mem.eql(u8, ec.category, cat)) continue;
            }
            try list.append(alloc, ec);
        }
    }

    // Fetch version info for nightly builds.
    for (list.items) |*ec| {
        if (ec.is_nightly) try fetchVersionInfo(alloc, io, ec);
    }

    // Sort: compilers with modified desc first, then by name desc.
    std.mem.sort(ExpCompiler, list.items, {}, expCompilerLessThan);

    const filtered = try applyTextFilter(alloc, list.items, search_text, exact_search);

    try js.beginObject();
    try js.objectField("summary");
    try js.beginObject();
    try js.objectField("total_found");
    try js.write(filtered.len);
    try js.objectField("language");
    try js.write(language);
    try js.objectField("filter_used");
    try js.write(proposal orelse feature orelse category orelse search_text);
    try js.endObject();
    try js.objectField("compilers");
    try js.beginArray();
    var example_compilers: std.ArrayList([]const u8) = .empty;
    for (filtered) |ec| {
        if (proposal != null and !ids_only and example_compilers.items.len < 3) {
            try example_compilers.append(alloc, ec.id);
        }
        if (ids_only) {
            try js.write(ec.id);
        } else {
            try writeCompilerInfo(&js, alloc, ec, include_overrides, include_runtime_tools, include_compile_tools);
        }
    }
    try js.endArray();
    if (proposal != null and !ids_only and example_compilers.items.len > 0) {
        try js.objectField("usage_example");
        try js.beginObject();
        try js.objectField("description");
        try js.write(try std.fmt.allocPrint(alloc, "To use {s} features with the found compiler(s)", .{proposal.?}));
        try js.objectField("example_compilers");
        try js.beginArray();
        for (example_compilers.items) |id| try js.write(id);
        try js.endArray();
        try js.endObject();
    }
    try js.endObject();
    return resultText(alloc, &sw);
}

fn expCompilerLessThan(_: void, a: ExpCompiler, b: ExpCompiler) bool {
    // reverse=True on key (has_modified, modified-or-name)
    const am = a.modified orelse "";
    const bm = b.modified orelse "";
    if (am.len > 0 and bm.len > 0) return std.mem.order(u8, am, bm) == .gt;
    if (am.len > 0) return true;
    if (bm.len > 0) return false;
    return std.mem.order(u8, a.name, b.name) == .gt;
}

fn applyTextFilter(alloc: std.mem.Allocator, comps: []const ExpCompiler, search_text: ?[]const u8, exact_search: bool) ![]const ExpCompiler {
    const st = search_text orelse return comps;
    if (st.len == 0) return comps;
    var list: std.ArrayList(ExpCompiler) = .empty;
    for (comps) |c| {
        if (exact_search) {
            if (std.mem.eql(u8, c.id, st)) try list.append(alloc, c);
        } else {
            if (containsIgnoreCase(c.id, st) or containsIgnoreCase(c.name, st)) try list.append(alloc, c);
        }
    }
    return list.items;
}

fn handleGetLibraries(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const language = getStr(args, "language") orelse "c++";
    const search_text = getStr(args, "search_text");

    const url = try std.fmt.allocPrint(alloc, "{s}/libraries/{s}", .{ API_BASE, language });
    const resp = apiFetch(alloc, io, .GET, url, null) catch |err| {
        return errText(alloc, "Compiler Explorer API request failed: {s}", .{@errorName(err)});
    };

    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = newJs(&sw);

    if (resp.status != 200) {
        try js.beginObject();
        try js.objectField("error");
        try js.write(try std.fmt.allocPrint(alloc, "Failed to get libraries: HTTP {d}", .{resp.status}));
        try js.objectField("language");
        try js.write(language);
        try js.objectField("search_text");
        try js.write(search_text);
        try js.endObject();
        return resultText(alloc, &sw);
    }

    const libs = parseJsonValue(alloc, resp.body) catch return errText(alloc, "Compiler Explorer API returned invalid JSON", .{});

    try js.beginObject();
    try js.objectField("language");
    try js.write(language);
    try js.objectField("search_text");
    try js.write(search_text);
    var count: usize = 0;
    // write libraries into a scratch buffer first to know the count
    var scratch: std.Io.Writer.Allocating = .init(alloc);
    defer scratch.deinit();
    var js2 = newJs(&scratch);
    try js2.beginArray();
    if (libs == .array) {
        for (libs.array.items) |lib| {
            if (lib != .object) continue;
            const id = jsonStr(lib, "id");
            const name = jsonStr(lib, "name");
            if (search_text) |st| {
                if (!containsIgnoreCase(id, st) and !containsIgnoreCase(name, st)) continue;
            }
            count += 1;
            try js2.beginObject();
            try js2.objectField("id");
            try js2.write(id);
            try js2.objectField("name");
            try js2.write(name);
            try js2.endObject();
        }
    }
    try js2.endArray();
    try js.objectField("count");
    try js.write(count);
    try js.objectField("libraries");
    try js.write(try parseJsonValue(alloc, scratch.written()));
    try js.endObject();
    return resultText(alloc, &sw);
}

fn handleGetLibraryDetails(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const language = getStr(args, "language") orelse "c++";
    const library_id = getStr(args, "library_id");

    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = newJs(&sw);

    if (library_id == null or library_id.?.len == 0) {
        try js.beginObject();
        try js.objectField("error");
        try js.write("library_id parameter is required");
        try js.objectField("language");
        try js.write(language);
        try js.endObject();
        return resultText(alloc, &sw);
    }

    const url = try std.fmt.allocPrint(alloc, "{s}/libraries/{s}", .{ API_BASE, language });
    const resp = apiFetch(alloc, io, .GET, url, null) catch |err| {
        return errText(alloc, "Compiler Explorer API request failed: {s}", .{@errorName(err)});
    };
    if (resp.status != 200) {
        try js.beginObject();
        try js.objectField("error");
        try js.write(try std.fmt.allocPrint(alloc, "Failed to get library details: HTTP {d}", .{resp.status}));
        try js.objectField("language");
        try js.write(language);
        try js.objectField("library_id");
        try js.write(library_id.?);
        try js.endObject();
        return resultText(alloc, &sw);
    }
    const libs = parseJsonValue(alloc, resp.body) catch return errText(alloc, "Compiler Explorer API returned invalid JSON", .{});

    var target: ?std.json.Value = null;
    if (libs == .array) {
        for (libs.array.items) |lib| {
            if (lib != .object) continue;
            if (std.mem.eql(u8, jsonStr(lib, "id"), library_id.?)) {
                target = lib;
                break;
            }
        }
    }

    try js.beginObject();
    if (target == null) {
        try js.objectField("error");
        try js.write(try std.fmt.allocPrint(alloc, "Library '{s}' not found for language '{s}'", .{ library_id.?, language }));
        try js.objectField("language");
        try js.write(language);
        try js.objectField("library_id");
        try js.write(library_id.?);
    } else {
        const lib = target.?;
        try js.objectField("language");
        try js.write(language);
        try js.objectField("library_id");
        try js.write(library_id.?);
        try js.objectField("library");
        try js.beginObject();
        try js.objectField("id");
        try js.write(jsonStr(lib, "id"));
        try js.objectField("name");
        try js.write(jsonStr(lib, "name"));
        try js.objectField("url");
        try js.write(jsonStr(lib, "url"));
        try js.objectField("description");
        try js.write(jsonStr(lib, "description"));
        try js.objectField("versions");
        try js.beginArray();
        for (jsonArray(lib, "versions")) |ver| {
            if (ver != .object) continue;
            try js.beginObject();
            try js.objectField("id");
            try js.write(jsonStr(ver, "id"));
            try js.objectField("version");
            try js.write(jsonStr(ver, "version"));
            try js.endObject();
        }
        try js.endArray();
        try js.endObject();
    }
    try js.endObject();
    return resultText(alloc, &sw);
}

fn handleGetLanguages(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const search_text = getStr(args, "search_text");

    const url = try std.fmt.allocPrint(alloc, "{s}/languages", .{API_BASE});
    const resp = apiFetch(alloc, io, .GET, url, null) catch |err| {
        return errText(alloc, "Compiler Explorer API request failed: {s}", .{@errorName(err)});
    };

    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = newJs(&sw);

    if (resp.status != 200) {
        try js.beginObject();
        try js.objectField("error");
        try js.write(try std.fmt.allocPrint(alloc, "Failed to get languages: HTTP {d}", .{resp.status}));
        try js.endObject();
        return resultText(alloc, &sw);
    }

    const langs = parseJsonValue(alloc, resp.body) catch return errText(alloc, "Compiler Explorer API returned invalid JSON", .{});

    var scratch: std.Io.Writer.Allocating = .init(alloc);
    defer scratch.deinit();
    var js2 = newJs(&scratch);
    var count: usize = 0;
    try js2.beginArray();
    if (langs == .array) {
        for (langs.array.items) |lang| {
            if (lang != .object) continue;
            const id = jsonStr(lang, "id");
            const name = jsonStr(lang, "name");
            if (search_text) |st| {
                if (!containsIgnoreCase(id, st) and !containsIgnoreCase(name, st)) continue;
            }
            count += 1;
            try js2.beginObject();
            try js2.objectField("id");
            try js2.write(id);
            try js2.objectField("name");
            try js2.write(name);
            try js2.objectField("extensions");
            try js2.write(argValue(lang, "extensions"));
            try js2.endObject();
        }
    }
    try js2.endArray();

    try js.beginObject();
    try js.objectField("search_text");
    try js.write(search_text);
    try js.objectField("count");
    try js.write(count);
    try js.objectField("languages");
    try js.write(try parseJsonValue(alloc, scratch.written()));
    try js.endObject();
    return resultText(alloc, &sw);
}

fn handleLookupInstruction(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const instruction_set = getStr(args, "instruction_set") orelse return errText(alloc, "error: instruction_set required", .{});
    const opcode = getStr(args, "opcode") orelse return errText(alloc, "error: opcode required", .{});
    const format_output = getBool(args, "format_output", true);

    const set_lower = try lowerDup(alloc, trimWs(instruction_set));
    const op_lower = try lowerDup(alloc, trimWs(opcode));
    const resolved = resolveInstructionSet(set_lower);

    var used_set = resolved;
    var resp = apiFetch(alloc, io, .GET, try std.fmt.allocPrint(alloc, "{s}/asm/{s}/{s}", .{ API_BASE, resolved, op_lower }), null) catch |err| {
        return errText(alloc, "Compiler Explorer API request failed: {s}", .{@errorName(err)});
    };
    if (resp.status == 404 and !std.mem.eql(u8, resolved, set_lower)) {
        // Fall back to the original (un-aliased) instruction set.
        used_set = set_lower;
        resp = apiFetch(alloc, io, .GET, try std.fmt.allocPrint(alloc, "{s}/asm/{s}/{s}", .{ API_BASE, set_lower, op_lower }), null) catch |err| {
            return errText(alloc, "Compiler Explorer API request failed: {s}", .{@errorName(err)});
        };
    }

    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = newJs(&sw);

    if (resp.status != 200) {
        try js.beginObject();
        try js.objectField("error");
        try js.write(try std.fmt.allocPrint(alloc, "Instruction '{s}' not found for instruction set '{s}'", .{ op_lower, instruction_set }));
        try js.objectField("instruction_set");
        try js.write(instruction_set);
        try js.objectField("opcode");
        try js.write(op_lower);
        try js.objectField("found");
        try js.write(false);
        try js.endObject();
        return resultText(alloc, &sw);
    }

    const docs = parseJsonValue(alloc, resp.body) catch return errText(alloc, "Compiler Explorer API returned invalid JSON", .{});

    try js.beginObject();
    try js.objectField("instruction_set");
    try js.write(used_set);
    try js.objectField("opcode");
    try js.write(op_lower);
    try js.objectField("found");
    try js.write(true);
    try js.objectField("documentation");
    try js.write(docs);
    if (format_output) {
        try js.objectField("formatted_docs");
        try js.write(try formatInstructionDocs(alloc, op_lower, used_set, docs));
    }
    try js.objectField("original_instruction_set");
    try js.write(instruction_set);
    try js.objectField("resolved_instruction_set");
    try js.write(resolved);
    try js.endObject();
    return resultText(alloc, &sw);
}

fn basename(path: []const u8) []const u8 {
    var base = path;
    if (std.mem.lastIndexOfAny(u8, base, "/\\")) |i| base = base[i + 1 ..];
    return base;
}

const SavedEntry = struct {
    original_name: []const u8,
    saved_as: []const u8,
};

fn handleDownloadShortlink(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const shortlink_url = getStr(args, "shortlink_url") orelse return errText(alloc, "error: shortlink_url required", .{});
    const destination = getStr(args, "destination_path") orelse return errText(alloc, "error: destination_path required", .{});
    const preserve = getBool(args, "preserve_filenames", true);
    const prefix = getStr(args, "fallback_prefix") orelse "ce";
    const include_metadata = getBool(args, "include_metadata", true);
    const overwrite = getBool(args, "overwrite_existing", false);

    const id = try extractLinkId(alloc, shortlink_url);
    const url = try std.fmt.allocPrint(alloc, "{s}/shortlinkinfo/{s}", .{ API_BASE, id });
    const resp = apiFetch(alloc, io, .GET, url, null) catch |err| {
        return errText(alloc, "Compiler Explorer API request failed: {s}", .{@errorName(err)});
    };
    if (resp.status != 200) return errText(alloc, "Compiler Explorer API error: HTTP {d}", .{resp.status});
    const info = parseJsonValue(alloc, resp.body) catch return errText(alloc, "Compiler Explorer API returned invalid JSON", .{});

    std.Io.Dir.cwd().createDirPath(io, destination) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return errText(alloc, "error: cannot create destination path: {s}", .{@errorName(err)}),
    };
    var dest_dir = std.Io.Dir.cwd().openDir(io, destination, .{}) catch |err| {
        return errText(alloc, "error: cannot open destination path: {s}", .{@errorName(err)});
    };
    defer dest_dir.close(io);

    const ToSave = struct {
        original_name: []const u8,
        filename: []const u8,
        contents: []const u8,
    };
    var to_save: std.ArrayList(ToSave) = .empty;
    var index: usize = 0;

    for (jsonArray(info, "sessions")) |session| {
        if (session != .object) continue;
        const source = jsonOptStr(session, "source") orelse continue;
        index += 1;
        const original = jsonOptStr(session, "filename");
        const name = if (preserve and original != null and basename(original.?).len > 0)
            basename(original.?)
        else
            try generateFileName(alloc, original, jsonStr(session, "language"), index, prefix, true);
        try to_save.append(alloc, .{ .original_name = original orelse name, .filename = name, .contents = source });
    }
    for (jsonArray(info, "trees")) |tree| {
        if (tree != .object) continue;
        for (jsonArray(tree, "files")) |f| {
            if (f != .object) continue;
            const content = jsonOptStr(f, "content") orelse continue;
            index += 1;
            const lang = jsonOptStr(f, "langId") orelse jsonStr(tree, "compilerLanguageId");
            const original = jsonOptStr(f, "filename");
            const name = if (preserve and original != null and basename(original.?).len > 0)
                basename(original.?)
            else
                try generateFileName(alloc, original, lang, index, prefix, jsonBool(f, "isMainSource", false));
            try to_save.append(alloc, .{ .original_name = original orelse name, .filename = name, .contents = content });
        }
    }

    var saved: std.ArrayList(SavedEntry) = .empty;
    for (to_save.items) |f| {
        const final_name = if (overwrite) f.filename else try resolveNameConflicts(alloc, io, dest_dir, f.filename);
        dest_dir.writeFile(io, .{ .sub_path = final_name, .data = f.contents }) catch |err| {
            return errText(alloc, "error: cannot write '{s}': {s}", .{ final_name, @errorName(err) });
        };
        try saved.append(alloc, .{ .original_name = f.original_name, .saved_as = final_name });
    }

    var metadata_files: std.ArrayList([]const u8) = .empty;
    if (include_metadata) {
        var msw: std.Io.Writer.Allocating = .init(alloc);
        defer msw.deinit();
        var mjs = newJs(&msw);
        try mjs.beginObject();
        try mjs.objectField("shortlink_id");
        try mjs.write(id);
        try mjs.objectField("shortlink_url");
        try mjs.write(shortlink_url);
        try mjs.objectField("sessions");
        try mjs.write(argValue(info, "sessions"));
        try mjs.objectField("trees");
        try mjs.write(argValue(info, "trees"));
        try mjs.endObject();
        const meta_name = try std.fmt.allocPrint(alloc, "{s}_metadata.json", .{id});
        dest_dir.writeFile(io, .{ .sub_path = meta_name, .data = msw.written() }) catch |err| {
            return errText(alloc, "error: cannot write metadata: {s}", .{@errorName(err)});
        };
        try metadata_files.append(alloc, meta_name);
    }

    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = newJs(&sw);
    try js.beginObject();
    try js.objectField("shortlink_id");
    try js.write(id);
    try js.objectField("files_saved");
    try js.beginArray();
    for (saved.items) |s| {
        try js.beginObject();
        try js.objectField("original_name");
        try js.write(s.original_name);
        try js.objectField("saved_as");
        try js.write(s.saved_as);
        try js.endObject();
    }
    try js.endArray();
    try js.objectField("total_files");
    try js.write(saved.items.len);
    try js.objectField("metadata_files");
    try js.beginArray();
    for (metadata_files.items) |m| try js.write(m);
    try js.endArray();
    try js.objectField("summary");
    try js.write(try std.fmt.allocPrint(alloc, "Saved {d} file{s} from CE shortlink {s} to {s}", .{
        saved.items.len,
        if (saved.items.len == 1) "" else "s",
        id,
        destination,
    }));
    try js.endObject();
    return resultText(alloc, &sw);
}

fn handleCmakeBuild(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const compiler = resolveCompiler(getStr(args, "compiler") orelse return errText(alloc, "error: compiler required", .{}));
    var err_msg: ?[]const u8 = null;
    const inputs = (try resolveCmakeInputsIo(alloc, io, args, &err_msg)) orelse
        return .{ .text = err_msg orelse try alloc.dupe(u8, "error: invalid cmake inputs"), .is_error = true };
    const language = getStr(args, "language") orelse "c++";
    const options = getStr(args, "options") orelse "";
    const cmake_args = getStr(args, "cmake_args") orelse "";
    const execute = getBool(args, "execute", false);

    const libs = switch (try resolveLibraries(alloc, io, language, compiler, argValue(args, "libraries"))) {
        .ok => |l| l,
        .err => |msg| return .{ .text = msg, .is_error = true },
    };

    const payload = try buildCmakePayload(alloc, inputs.cmake_source, inputs.files, options, cmake_args, execute, .{ .execute = execute }, try libsToJson(alloc, libs));
    const url = try std.fmt.allocPrint(alloc, "{s}/compiler/{s}/cmake", .{ API_BASE, compiler });
    const result = switch (try postJson(alloc, io, url, payload)) {
        .ok => |v| v,
        .err => |e| return e,
    };

    const exec_result = argValue(result, "execResult");

    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = newJs(&sw);
    try js.beginObject();
    try js.objectField("success");
    try js.write(jsonInt(result, "code", 1) == 0);
    try js.objectField("build_steps");
    try js.beginArray();
    for (jsonArray(result, "buildsteps")) |step| {
        if (step != .object) continue;
        try js.beginObject();
        try js.objectField("step");
        try js.write(jsonStr(step, "step"));
        try js.objectField("code");
        try js.write(jsonInt(step, "code", 0));
        try js.objectField("stdout");
        try js.write(try streamText(alloc, argValue(step, "stdout")));
        try js.objectField("stderr");
        try js.write(try streamText(alloc, argValue(step, "stderr")));
        try js.endObject();
    }
    try js.endArray();
    try js.objectField("executed");
    try js.write(jsonBool(result, "didExecute", false) or exec_result == .object);
    if (exec_result == .object) {
        try js.objectField("exit_code");
        try js.write(jsonInt(exec_result, "code", -1));
        try js.objectField("execution_time_ms");
        try js.write(jsonInt(exec_result, "execTime", 0));
        try js.objectField("stdout");
        try js.write(try stripAnsi(alloc, try streamText(alloc, argValue(exec_result, "stdout"))));
        try js.objectField("stderr");
        try js.write(try stripAnsi(alloc, try streamText(alloc, argValue(exec_result, "stderr"))));
    }
    try js.endObject();
    return resultText(alloc, &sw);
}

fn handleGenerateCmakeShareUrl(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const compiler = resolveCompiler(getStr(args, "compiler") orelse return errText(alloc, "error: compiler required", .{}));
    var err_msg: ?[]const u8 = null;
    const inputs = (try resolveCmakeInputsIo(alloc, io, args, &err_msg)) orelse
        return .{ .text = err_msg orelse try alloc.dupe(u8, "error: invalid cmake inputs"), .is_error = true };
    const language = getStr(args, "language") orelse "c++";
    const options = getStr(args, "options") orelse "";
    const cmake_args = getStr(args, "cmake_args") orelse "";

    const libs = switch (try resolveLibraries(alloc, io, language, compiler, argValue(args, "libraries"))) {
        .ok => |l| l,
        .err => |msg| return .{ .text = msg, .is_error = true },
    };

    const payload = try buildCmakeSharePayload(alloc, inputs.cmake_source, inputs.files, language, compiler, options, cmake_args, try libsToJson(alloc, libs));
    const url = try std.fmt.allocPrint(alloc, "{s}/shortener", .{API_BASE});
    const result = switch (try postJson(alloc, io, url, payload)) {
        .ok => |v| v,
        .err => |e| return e,
    };

    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = newJs(&sw);
    try js.beginObject();
    try js.objectField("url");
    try js.write(jsonStr(result, "url"));
    try js.endObject();
    return resultText(alloc, &sw);
}

// --- pure helpers ---

fn upperDup(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try alloc.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toUpper(c.*);
    return out;
}

/// Scan the first 10 source lines for `flags:` / `compile:` comment markers
/// (ce-mcp extract_compile_args).
fn extractCompileArgs(alloc: std.mem.Allocator, source: []const u8) !?[]const u8 {
    var it = std.mem.splitScalar(u8, source, '\n');
    var line_no: usize = 0;
    while (it.next()) |line| {
        line_no += 1;
        if (line_no > 10) break;
        var rest: ?[]const u8 = null;
        if (indexOfIgnoreCase(line, "flags:")) |i| {
            rest = line[i + "flags:".len ..];
        } else if (indexOfIgnoreCase(line, "compile:")) |i| {
            rest = line[i + "compile:".len ..];
        }
        if (rest) |r0| {
            var r = trimWs(r0);
            // strip trailing comment closers
            while (true) {
                if (std.mem.endsWith(u8, r, "*/")) {
                    r = trimWs(r[0 .. r.len - 2]);
                } else if (std.mem.endsWith(u8, r, "-->")) {
                    r = trimWs(r[0 .. r.len - 3]);
                } else if (std.mem.endsWith(u8, r, "}")) {
                    r = trimWs(r[0 .. r.len - 1]);
                } else break;
            }
            if (r.len > 0) return try alloc.dupe(u8, r);
        }
    }
    return null;
}

/// ce-mcp suggestion patterns: "did you mean", "suggested alternative",
/// "fix-it", "use ... instead".
fn extractCompilerSuggestion(alloc: std.mem.Allocator, message: []const u8) !?[]const u8 {
    if (indexOfIgnoreCase(message, "did you mean")) |i| {
        return try alloc.dupe(u8, trimWs(message[i..]));
    }
    if (indexOfIgnoreCase(message, "suggested alternative")) |i| {
        return try alloc.dupe(u8, trimWs(message[i..]));
    }
    if (indexOfIgnoreCase(message, "fix-it")) |i| {
        const after = message[i..];
        if (std.mem.indexOfScalar(u8, after, ':')) |ci| {
            return try std.fmt.allocPrint(alloc, "fix-it{s}", .{after[ci..]});
        }
        return try alloc.dupe(u8, trimWs(after));
    }
    if (indexOfIgnoreCase(message, "instead") != null) {
        if (indexOfIgnoreCase(message, "use ")) |ui| {
            return try alloc.dupe(u8, trimWs(message[ui..]));
        }
    }
    return null;
}

/// Remove ANSI CSI escape sequences (e.g. colour codes in executor output).
fn stripAnsi(alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == 0x1b and i + 1 < text.len and text[i + 1] == '[') {
            var j = i + 2;
            while (j < text.len) : (j += 1) {
                const fc = text[j];
                if (fc >= 0x40 and fc <= 0x7e) {
                    j += 1;
                    break;
                }
            }
            i = j;
            continue;
        }
        try out.writer.writeByte(c);
        i += 1;
    }
    return alloc.dupe(u8, out.written());
}

/// ce-mcp instruction-set alias table. Matching is case-insensitive; the
/// canonical names are static strings so no allocator is needed.
fn resolveInstructionSet(set: []const u8) []const u8 {
    const table = [_][2][]const u8{
        .{ "x86_64", "amd64" },
        .{ "x64", "amd64" },
        .{ "x86-64", "amd64" },
        .{ "intel", "amd64" },
        .{ "amd64", "amd64" },
        .{ "arm64", "aarch64" },
        .{ "armv8", "aarch64" },
        .{ "arm", "aarch64" },
        .{ "aarch64", "aarch64" },
        .{ "riscv", "riscv" },
        .{ "arm32", "arm32" },
        .{ "avr", "avr" },
        .{ "mips", "mips" },
        .{ "mips64", "mips64" },
        .{ "powerpc", "powerpc" },
        .{ "powerpc64", "powerpc64" },
        .{ "sparc", "sparc" },
        .{ "systemz", "systemz" },
        .{ "wasm32", "wasm32" },
        .{ "6502", "6502" },
        .{ "ptx", "ptx" },
    };
    for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(entry[0], set)) return entry[1];
    }
    return set;
}

/// Accepts a full CE URL (https://godbolt.org/z/<id>) or a bare id.
fn extractLinkId(alloc: std.mem.Allocator, url: []const u8) ![]const u8 {
    var s = trimWs(url);
    if (std.mem.lastIndexOf(u8, s, "/z/")) |i| s = s[i + 3 ..];
    if (std.mem.indexOfAny(u8, s, "?#")) |i| s = s[0..i];
    s = std.mem.trimEnd(u8, s, "/");
    return alloc.dupe(u8, s);
}

const lang_extensions = [_][2][]const u8{
    .{ "c++", ".cpp" },
    .{ "c", ".c" },
    .{ "rust", ".rs" },
    .{ "go", ".go" },
    .{ "python", ".py" },
    .{ "java", ".java" },
    .{ "d", ".d" },
    .{ "nim", ".nim" },
    .{ "fortran", ".f90" },
    .{ "pascal", ".pas" },
    .{ "haskell", ".hs" },
    .{ "swift", ".swift" },
    .{ "kotlin", ".kt" },
    .{ "csharp", ".cs" },
    .{ "zig", ".zig" },
    .{ "assembly", ".asm" },
    .{ "llvm", ".ll" },
    .{ "ocaml", ".ml" },
    .{ "cobol", ".cob" },
    .{ "javascript", ".js" },
    .{ "typescript", ".ts" },
    .{ "ruby", ".rb" },
    .{ "dart", ".dart" },
    .{ "ada", ".adb" },
    .{ "cuda", ".cu" },
    .{ "ispc", ".ispc" },
    .{ "vala", ".vala" },
    .{ "crystal", ".cr" },
};

fn extensionForLanguage(language: []const u8) []const u8 {
    for (lang_extensions) |entry| {
        if (std.mem.eql(u8, entry[0], language)) return entry[1];
    }
    return ".txt";
}

/// ce-mcp filename generation: keep the original basename when present
/// (inserting "_main" before the extension for main sources), otherwise
/// generate "<prefix>_<index:03>[_main]<ext>" from the static extension map.
fn generateFileName(alloc: std.mem.Allocator, original: ?[]const u8, language: []const u8, index: usize, prefix: []const u8, is_main: bool) ![]const u8 {
    if (original) |o| {
        const base = basename(o);
        if (base.len > 0) {
            if (is_main and !std.mem.endsWith(u8, base, "_main")) {
                if (std.mem.lastIndexOfScalar(u8, base, '.')) |d| {
                    return std.fmt.allocPrint(alloc, "{s}_main{s}", .{ base[0..d], base[d..] });
                }
                return std.fmt.allocPrint(alloc, "{s}_main", .{base});
            }
            return alloc.dupe(u8, base);
        }
    }
    const ext = extensionForLanguage(language);
    if (is_main) return std.fmt.allocPrint(alloc, "{s}_{d:0>3}_main{s}", .{ prefix, index, ext });
    return std.fmt.allocPrint(alloc, "{s}_{d:0>3}{s}", .{ prefix, index, ext });
}

/// If `name` already exists in `dir`, append _1, _2, ... before the extension.
fn resolveNameConflicts(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) ![]const u8 {
    if (dir.access(io, name, .{})) |_| {
        // exists -> find a numbered variant
    } else |_| {
        return alloc.dupe(u8, name);
    }
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    var n: usize = 1;
    while (true) : (n += 1) {
        const candidate = if (dot) |d|
            try std.fmt.allocPrint(alloc, "{s}_{d}{s}", .{ name[0..d], n, name[d..] })
        else
            try std.fmt.allocPrint(alloc, "{s}_{d}", .{ name, n });
        if (dir.access(io, candidate, .{})) |_| continue else |_| return candidate;
    }
}

fn hasProposalPattern(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == 'p' or c == 'n') {
            if (i > 0 and (std.ascii.isAlphanumeric(s[i - 1]) or s[i - 1] == '_')) continue;
            var j = i + 1;
            while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
            if (j - (i + 1) >= 4) return true;
        }
    }
    return false;
}

/// Extract C++ proposal numbers (P#### / N####) from a compiler name.
fn extractProposalNumbers(alloc: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == 'P' or c == 'p' or c == 'N' or c == 'n') {
            if (i > 0 and (std.ascii.isAlphanumeric(text[i - 1]) or text[i - 1] == '_')) continue;
            var j = i + 1;
            while (j < text.len and std.ascii.isDigit(text[j])) j += 1;
            const ndigits = j - (i + 1);
            if (ndigits >= 4) {
                const out = try alloc.alloc(u8, 1 + ndigits);
                out[0] = std.ascii.toUpper(c);
                @memcpy(out[1..], text[i + 1 .. j]);
                try list.append(alloc, out);
                i = j - 1;
            }
        }
    }
    return list.items;
}

const feature_keyword_table = [_]struct { kw: []const u8, name: []const u8 }{
    .{ .kw = "reflection", .name = "reflection" },
    .{ .kw = "concepts", .name = "concepts" },
    .{ .kw = "modules", .name = "modules" },
    .{ .kw = "coroutine", .name = "coroutines" },
    .{ .kw = "contract", .name = "contracts" },
    .{ .kw = "lifetime", .name = "lifetime_analysis" },
    .{ .kw = "metaprogramming", .name = "metaprogramming" },
};

fn extractFeatures(alloc: std.mem.Allocator, name_lower: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (feature_keyword_table) |f| {
        if (std.mem.indexOf(u8, name_lower, f.kw) != null) try list.append(alloc, f.name);
    }
    return list.items;
}

fn determineCategory(name_lower: []const u8) []const u8 {
    for (feature_keyword_table) |f| {
        if (std.mem.indexOf(u8, name_lower, f.kw) != null) return f.name;
    }
    if (std.mem.indexOf(u8, name_lower, "trunk") != null or
        std.mem.indexOf(u8, name_lower, "nightly") != null or
        std.mem.indexOf(u8, name_lower, "master") != null) return "trunk_nightly";
    return "other_experimental";
}

fn isExperimental(name_lower: []const u8, id_lower: []const u8, is_nightly: bool) bool {
    if (is_nightly) return true;
    const kws = [_][]const u8{ "trunk", "nightly", "master", "experimental", "fork", "reflection", "concepts", "modules", "coroutine", "contract", "lifetime", "metaprogramming" };
    for (kws) |kw| {
        if (std.mem.indexOf(u8, name_lower, kw) != null) return true;
        if (std.mem.indexOf(u8, id_lower, kw) != null) return true;
    }
    return hasProposalPattern(name_lower) or hasProposalPattern(id_lower);
}

/// Keywords used for a feature search; unknown features match nothing
/// (ce-mcp only supports its known feature set).
fn featureKeywords(feature_lower: []const u8) []const []const u8 {
    const map = [_]struct { f: []const u8, kws: []const []const u8 }{
        .{ .f = "reflection", .kws = &.{"reflection"} },
        .{ .f = "concepts", .kws = &.{ "concepts", "concept" } },
        .{ .f = "modules", .kws = &.{"modules"} },
        .{ .f = "coroutines", .kws = &.{"coroutine"} },
        .{ .f = "contracts", .kws = &.{"contract"} },
        .{ .f = "lifetime_analysis", .kws = &.{"lifetime"} },
        .{ .f = "metaprogramming", .kws = &.{ "metaprogramming", "constexpr" } },
    };
    for (map) |e| {
        if (std.mem.eql(u8, e.f, feature_lower)) return e.kws;
    }
    return &.{};
}

fn matchProposal(alloc: std.mem.Allocator, comp: std.json.Value, proposal: []const u8) !bool {
    const props = try extractProposalNumbers(alloc, jsonStr(comp, "name"));
    var buf: [17]u8 = undefined;
    var want: []const u8 = proposal;
    if (proposal.len > 0 and std.ascii.isDigit(proposal[0]) and proposal.len + 1 <= buf.len) {
        buf[0] = 'P';
        @memcpy(buf[1 .. proposal.len + 1], proposal);
        want = buf[0 .. proposal.len + 1];
    }
    for (props) |p| {
        if (std.ascii.eqlIgnoreCase(p, want)) return true;
    }
    return false;
}

const dev_version_keywords = [_][]const u8{ "trunk", "master", "main", "dev", "nightly", "snapshot", "head" };

fn isDevVersion(id_lower: []const u8, ver_lower: []const u8) bool {
    for (dev_version_keywords) |kw| {
        if (std.mem.indexOf(u8, id_lower, kw) != null) return true;
        if (std.mem.indexOf(u8, ver_lower, kw) != null) return true;
    }
    return false;
}

/// Simplified dotted-numeric compare (ce-mcp's semver fallback).
fn compareDottedVersions(a: []const u8, b: []const u8) i8 {
    var ai = std.mem.splitScalar(u8, a, '.');
    var bi = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const x = ai.next();
        const y = bi.next();
        if (x == null and y == null) return 0;
        const xs = x orelse "0";
        const ys = y orelse "0";
        const xn = std.fmt.parseInt(i64, numericPrefix(xs), 10) catch 0;
        const yn = std.fmt.parseInt(i64, numericPrefix(ys), 10) catch 0;
        if (xn < yn) return -1;
        if (xn > yn) return 1;
    }
}

fn numericPrefix(s: []const u8) []const u8 {
    var end: usize = 0;
    while (end < s.len and std.ascii.isDigit(s[end])) end += 1;
    return if (end == 0) "0" else s[0..end];
}

/// ce-mcp latest-version resolution: drop dev versions, then max $order
/// (or simplified dotted-numeric compare when $order is missing). When every
/// version is a dev version, fall back to max $order over the full list.
fn getLatestVersionId(alloc: std.mem.Allocator, versions: []const std.json.Value) ![]const u8 {
    if (versions.len == 0) return error.NoVersions;
    var stable: std.ArrayList(std.json.Value) = .empty;
    for (versions) |v| {
        if (v != .object) continue;
        const id_lower = try lowerDup(alloc, jsonStr(v, "id"));
        const ver_lower = try lowerDup(alloc, jsonStr(v, "version"));
        if (!isDevVersion(id_lower, ver_lower)) try stable.append(alloc, v);
    }
    const candidates = if (stable.items.len > 0) stable.items else versions;
    var all_order = candidates.len > 0;
    for (candidates) |v| {
        if (v != .object or v.object.get("$order") == null) {
            all_order = false;
            break;
        }
    }
    var best: std.json.Value = candidates[0];
    for (candidates[1..]) |v| {
        if (all_order) {
            if (jsonInt(v, "$order", 0) > jsonInt(best, "$order", 0)) best = v;
        } else {
            if (compareDottedVersions(jsonStr(v, "version"), jsonStr(best, "version")) > 0) best = v;
        }
    }
    const id = jsonStr(best, "id");
    if (id.len == 0) return error.NoVersions;
    return id;
}

/// Match a requested version against id, version string, or alias; returns
/// the matching version id.
fn resolveLibraryVersion(versions: []const std.json.Value, requested: []const u8) ?[]const u8 {
    for (versions) |v| {
        if (v != .object) continue;
        if (std.mem.eql(u8, jsonStr(v, "id"), requested)) return jsonStr(v, "id");
        if (std.mem.eql(u8, jsonStr(v, "version"), requested)) return jsonStr(v, "id");
        for (jsonArray(v, "alias")) |a| {
            if (a == .string and std.mem.eql(u8, a.string, requested)) return jsonStr(v, "id");
        }
    }
    return null;
}

/// Strip '#' comments, collapse whitespace runs, drop empty lines.
fn normalizeAssembly(alloc: std.mem.Allocator, asm_text: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, asm_text, '\n');
    while (it.next()) |raw0| {
        var raw = raw0;
        if (raw.len > 0 and raw[raw.len - 1] == '\r') raw = raw[0 .. raw.len - 1];
        if (std.mem.indexOfScalar(u8, raw, '#')) |ci| raw = raw[0..ci];
        var out: std.ArrayList(u8) = .empty;
        var last_ws = true; // also trims leading whitespace
        for (raw) |c| {
            if (c == ' ' or c == '\t') {
                if (!last_ws) {
                    try out.append(alloc, ' ');
                    last_ws = true;
                }
            } else {
                try out.append(alloc, c);
                last_ws = false;
            }
        }
        var line = out.items;
        if (line.len > 0 and line[line.len - 1] == ' ') line = line[0 .. line.len - 1];
        if (line.len > 0) try list.append(alloc, line);
    }
    return list.items;
}

const DiffOp = struct {
    tag: enum { eq, del, ins },
    line: []const u8,
};

/// difflib-style unified diff over line slices (LCS based).
fn unifiedDiff(alloc: std.mem.Allocator, a: []const []const u8, b: []const []const u8, label1: []const u8, label2: []const u8, context: usize) ![]const u8 {
    const n = a.len;
    const m = b.len;
    // LCS lengths table
    var dp = try alloc.alloc(usize, (n + 1) * (m + 1));
    @memset(dp, 0);
    const stride = m + 1;
    for (1..n + 1) |i| {
        for (1..m + 1) |j| {
            if (std.mem.eql(u8, a[i - 1], b[j - 1])) {
                dp[i * stride + j] = dp[(i - 1) * stride + (j - 1)] + 1;
            } else {
                dp[i * stride + j] = @max(dp[(i - 1) * stride + j], dp[i * stride + (j - 1)]);
            }
        }
    }
    // backtrack into an op list (deletes precede inserts, difflib-style)
    var ops_rev: std.ArrayList(DiffOp) = .empty;
    var i = n;
    var j = m;
    while (i > 0 or j > 0) {
        if (i > 0 and j > 0 and std.mem.eql(u8, a[i - 1], b[j - 1])) {
            try ops_rev.append(alloc, .{ .tag = .eq, .line = a[i - 1] });
            i -= 1;
            j -= 1;
        } else if (j > 0 and (i == 0 or dp[i * stride + (j - 1)] >= dp[(i - 1) * stride + j])) {
            try ops_rev.append(alloc, .{ .tag = .ins, .line = b[j - 1] });
            j -= 1;
        } else {
            try ops_rev.append(alloc, .{ .tag = .del, .line = a[i - 1] });
            i -= 1;
        }
    }
    const ops_len = ops_rev.items.len;
    var ops = try alloc.alloc(DiffOp, ops_len);
    for (ops_rev.items, 0..) |op, k| ops[ops_len - 1 - k] = op;

    // per-op source line positions (0-based, before the op consumes its line)
    var a_idx = try alloc.alloc(usize, ops_len + 1);
    var b_idx = try alloc.alloc(usize, ops_len + 1);
    var a_pos: usize = 0;
    var b_pos: usize = 0;
    for (ops, 0..) |op, k| {
        a_idx[k] = a_pos;
        b_idx[k] = b_pos;
        switch (op.tag) {
            .eq => {
                a_pos += 1;
                b_pos += 1;
            },
            .del => a_pos += 1,
            .ins => b_pos += 1,
        }
    }
    a_idx[ops_len] = a_pos;
    b_idx[ops_len] = b_pos;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    // group changes into hunks with `context` equal lines around them
    var wrote_header = false;
    var k: usize = 0;
    while (k < ops_len) {
        // find next change
        while (k < ops_len and ops[k].tag == .eq) k += 1;
        if (k >= ops_len) break;
        const first_change = k;
        var last_change = k;
        var p = k + 1;
        var eq_run: usize = 0;
        while (p < ops_len) : (p += 1) {
            if (ops[p].tag == .eq) {
                eq_run += 1;
            } else {
                if (eq_run > 2 * context) break; // gap too large -> new hunk
                eq_run = 0;
                last_change = p;
            }
        }
        const hunk_start = first_change - @min(first_change, context);
        const hunk_end = @min(last_change + context + 1, ops_len);

        if (!wrote_header) {
            try out.writer.print("--- {s}\n+++ {s}\n", .{ label1, label2 });
            wrote_header = true;
        }
        const a_count = blk: {
            var c: usize = 0;
            for (ops[hunk_start..hunk_end]) |op| {
                if (op.tag != .ins) c += 1;
            }
            break :blk c;
        };
        const b_count = blk: {
            var c: usize = 0;
            for (ops[hunk_start..hunk_end]) |op| {
                if (op.tag != .del) c += 1;
            }
            break :blk c;
        };
        try out.writer.writeAll("@@ -");
        try writeRange(&out.writer, a_idx[hunk_start], a_count);
        try out.writer.writeAll(" +");
        try writeRange(&out.writer, b_idx[hunk_start], b_count);
        try out.writer.writeAll(" @@\n");
        for (ops[hunk_start..hunk_end]) |op| {
            const prefix: u8 = switch (op.tag) {
                .eq => ' ',
                .del => '-',
                .ins => '+',
            };
            try out.writer.writeByte(prefix);
            try out.writer.writeAll(op.line);
            try out.writer.writeByte('\n');
        }
        k = p;
    }
    return alloc.dupe(u8, out.written());
}

/// difflib range formatting: "start,count", but plain "start" for count 1
/// and start-1 for count 0.
fn writeRange(w: *std.Io.Writer, start0: usize, count: usize) !void {
    if (count == 1) {
        try w.print("{d}", .{start0 + 1});
    } else if (count == 0) {
        try w.print("{d},0", .{start0});
    } else {
        try w.print("{d},{d}", .{ start0 + 1, count });
    }
}

/// First token of a line if it looks like an assembly instruction (skips
/// labels, directives and comments).
fn extractInstruction(line: []const u8) ?[]const u8 {
    const t = trimWs(line);
    if (t.len == 0) return null;
    if (t[0] == '.' or t[0] == '#' or t[0] == ';' or t[0] == '/') return null;
    const end = std.mem.indexOfAny(u8, t, " \t") orelse t.len;
    const word = t[0..end];
    if (word.len == 0) return null;
    if (word[word.len - 1] == ':') return null;
    return word;
}

fn isRegisterName(w: []const u8) bool {
    const regs = [_][]const u8{
        "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp",
        "r8",  "r9",  "r10", "r11", "r12", "r13", "r14", "r15",
        "eax", "ebx", "ecx", "edx", "esi", "edi", "ebp", "esp",
        "x0",  "x1",  "x2",  "x3",  "x4",  "x5",  "x6",  "x7",
        "x8",  "x9",  "x10", "x11", "x12", "w0",  "w1",  "w2",
    };
    for (regs) |r| {
        if (std.ascii.eqlIgnoreCase(r, w)) return true;
    }
    return false;
}

/// Call target of a call/bl line; memory/register operands become
/// "indirect_call".
fn extractFunctionCall(line: []const u8) ?[]const u8 {
    const t = trimWs(line);
    const end = std.mem.indexOfAny(u8, t, " \t") orelse return null;
    const op = t[0..end];
    if (!std.mem.eql(u8, op, "call") and !std.mem.eql(u8, op, "bl")) return null;
    const target = trimWs(t[end..]);
    if (target.len == 0) return null;
    if (std.mem.indexOfScalar(u8, target, '[') != null) return "indirect_call";
    const wend = std.mem.indexOfAny(u8, target, " \t,") orelse target.len;
    var word = target[0..wend];
    if (std.mem.indexOfScalar(u8, word, '#')) |ci| word = trimWs(word[0..ci]);
    if (word.len == 0) return "indirect_call";
    if (isRegisterName(word)) return "indirect_call";
    return word;
}

fn dedupFirstSeen(alloc: std.mem.Allocator, items: []const []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (items) |s| {
        var seen = false;
        for (list.items) |e| {
            if (std.mem.eql(u8, e, s)) {
                seen = true;
                break;
            }
        }
        if (!seen) try list.append(alloc, s);
    }
    return list.items;
}

const DiffStats = struct {
    lines_added: usize = 0,
    lines_removed: usize = 0,
    instructions_added: []const []const u8 = &.{},
    instructions_removed: []const []const u8 = &.{},
    calls_added: []const []const u8 = &.{},
    calls_removed: []const []const u8 = &.{},
    unique_instructions_added: []const []const u8 = &.{},
    unique_instructions_removed: []const []const u8 = &.{},
    unique_calls_added: []const []const u8 = &.{},
    unique_calls_removed: []const []const u8 = &.{},
};

fn analyzeDiffText(alloc: std.mem.Allocator, diff_text: []const u8) !DiffStats {
    var stats: DiffStats = .{};
    var instr_added: std.ArrayList([]const u8) = .empty;
    var instr_removed: std.ArrayList([]const u8) = .empty;
    var calls_added: std.ArrayList([]const u8) = .empty;
    var calls_removed: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, diff_text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "+++") or std.mem.startsWith(u8, line, "---")) continue;
        switch (line[0]) {
            '+' => {
                stats.lines_added += 1;
                const content = line[1..];
                if (extractInstruction(content)) |ins| try instr_added.append(alloc, ins);
                if (extractFunctionCall(content)) |c| try calls_added.append(alloc, c);
            },
            '-' => {
                stats.lines_removed += 1;
                const content = line[1..];
                if (extractInstruction(content)) |ins| try instr_removed.append(alloc, ins);
                if (extractFunctionCall(content)) |c| try calls_removed.append(alloc, c);
            },
            else => {},
        }
    }
    stats.instructions_added = instr_added.items;
    stats.instructions_removed = instr_removed.items;
    stats.calls_added = calls_added.items;
    stats.calls_removed = calls_removed.items;
    stats.unique_instructions_added = try dedupFirstSeen(alloc, instr_added.items);
    stats.unique_instructions_removed = try dedupFirstSeen(alloc, instr_removed.items);
    stats.unique_calls_added = try dedupFirstSeen(alloc, calls_added.items);
    stats.unique_calls_removed = try dedupFirstSeen(alloc, calls_removed.items);
    return stats;
}

fn writeJoined(w: *std.Io.Writer, items: []const []const u8, sep: []const u8) !void {
    for (items, 0..) |s, i| {
        if (i > 0) try w.writeAll(sep);
        try w.writeAll(s);
    }
}

fn generateDiffSummary(alloc: std.mem.Allocator, stats: DiffStats, lines1: []const []const u8, lines2: []const []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    if (lines1.len == lines2.len) {
        try out.writer.print("Both assemblies have the same number of lines ({d}).", .{lines1.len});
    } else if (lines2.len > lines1.len) {
        try out.writer.print("Assembly 2 is {d} lines longer ({d} -> {d}).", .{ lines2.len - lines1.len, lines1.len, lines2.len });
    } else {
        try out.writer.print("Assembly 2 is {d} lines shorter ({d} -> {d}).", .{ lines1.len - lines2.len, lines1.len, lines2.len });
    }
    if (stats.unique_instructions_added.len > 0) {
        try out.writer.writeAll("\nNew instructions: ");
        try writeJoined(&out.writer, stats.unique_instructions_added, ", ");
    }
    if (stats.unique_instructions_removed.len > 0) {
        try out.writer.writeAll("\nRemoved instructions: ");
        try writeJoined(&out.writer, stats.unique_instructions_removed, ", ");
    }
    if (stats.unique_calls_added.len > 0) {
        try out.writer.writeAll("\nNew function calls: ");
        try writeJoined(&out.writer, stats.unique_calls_added, ", ");
    }
    if (stats.unique_calls_removed.len > 0) {
        try out.writer.writeAll("\nRemoved function calls: ");
        try writeJoined(&out.writer, stats.unique_calls_removed, ", ");
    }
    return alloc.dupe(u8, out.written());
}

fn ensureTrailingNewline(out: *std.Io.Writer.Allocating) !void {
    const w = out.written();
    if (w.len > 0 and w[w.len - 1] != '\n') try out.writer.writeByte('\n');
}

/// ce-mcp stderr merge for failed executions: buildResult detail first,
/// generic top-level messages skipped when details exist, build-step and
/// execution stderr appended with prefixes.
fn collectAllStderr(alloc: std.mem.Allocator, result: std.json.Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var has_detail = false;
    const br = argValue(result, "buildResult");
    if (br == .object) {
        const t = try streamText(alloc, argValue(br, "stderr"));
        if (trimWs(t).len > 0) {
            try out.writer.writeAll(t);
            has_detail = true;
        }
    }
    const top = try streamText(alloc, argValue(result, "stderr"));
    if (trimWs(top).len > 0) {
        const generic = containsIgnoreCase(top, "Build failed") or containsIgnoreCase(top, "Compilation failed");
        if (!(generic and has_detail)) {
            try ensureTrailingNewline(&out);
            try out.writer.writeAll(top);
        }
    }
    for (jsonArray(result, "buildsteps"), 1..) |step, idx| {
        const t = try streamText(alloc, argValue(step, "stderr"));
        if (trimWs(t).len > 0) {
            try ensureTrailingNewline(&out);
            try out.writer.print("Build step {d}: {s}", .{ idx, t });
        }
    }
    const er = argValue(result, "execResult");
    if (er == .object) {
        const t = try streamText(alloc, argValue(er, "stderr"));
        if (trimWs(t).len > 0) {
            try ensureTrailingNewline(&out);
            try out.writer.print("Execution: {s}", .{t});
        }
    }
    return alloc.dupe(u8, out.written());
}

/// Join an array of {"text": ...} items (or plain strings) with a separator.
fn joinTexts(alloc: std.mem.Allocator, v: std.json.Value, sep: []const u8) ![]const u8 {
    switch (v) {
        .array => |arr| {
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            for (arr.items, 0..) |item, i| {
                if (i > 0) try out.writer.writeAll(sep);
                switch (item) {
                    .object => try out.writer.writeAll(jsonStr(item, "text")),
                    .string => |s| try out.writer.writeAll(s),
                    .integer => |n| try out.writer.print("{d}", .{n}),
                    .float => |f| try out.writer.print("{d}", .{f}),
                    else => {},
                }
            }
            return alloc.dupe(u8, out.written());
        },
        .string => |s| return alloc.dupe(u8, s),
        else => return "",
    }
}

/// Human-readable rendering of the /asm/<set>/<opcode> documentation JSON.
fn formatInstructionDocs(alloc: std.mem.Allocator, opcode: []const u8, instruction_set: []const u8, docs: std.json.Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("## {s} - {s} Instruction\n", .{
        try upperDup(alloc, opcode),
        try upperDup(alloc, instruction_set),
    });
    const tooltip = jsonStr(docs, "tooltip");
    if (tooltip.len > 0) try out.writer.print("\n{s}\n", .{tooltip});
    const forms = jsonArray(docs, "forms");
    if (forms.len > 0) {
        try out.writer.writeAll("\nAssembly forms:\n");
        for (forms) |form| {
            if (form != .object) continue;
            var it = form.object.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.* == .string) {
                    try out.writer.print("  {s}\n", .{kv.value_ptr.string});
                }
            }
        }
    }
    return alloc.dupe(u8, out.written());
}

// --- experimental compiler model (find_compilers) ---

const ExpCompiler = struct {
    id: []const u8,
    name: []const u8,
    category: []const u8,
    proposals: []const []const u8 = &.{},
    features: []const []const u8 = &.{},
    is_nightly: bool = false,
    modified: ?[]const u8 = null,
    version_info: ?std.json.Value = null,
    raw: std.json.Value = .null,
};

fn makeExpCompiler(alloc: std.mem.Allocator, comp: std.json.Value, category: []const u8) !ExpCompiler {
    const name = jsonStr(comp, "name");
    const name_lower = try lowerDup(alloc, name);
    return .{
        .id = jsonStr(comp, "id"),
        .name = name,
        .category = category,
        .proposals = try extractProposalNumbers(alloc, name),
        .features = try extractFeatures(alloc, name_lower),
        .is_nightly = jsonBool(comp, "isNightly", false),
        .raw = comp,
    };
}

/// Token after " version " in a raw version string ("clang version 21.0.0git
/// (...)" -> "21.0.0git").
fn extractVersionNumber(raw: []const u8) ?[]const u8 {
    if (indexOfIgnoreCase(raw, "version ")) |i| {
        const rest = raw[i + "version ".len ..];
        const end = std.mem.indexOfAny(u8, rest, " \t(") orelse rest.len;
        const tok = rest[0..end];
        if (tok.len > 0) return tok;
    }
    return null;
}

/// First run of >= 32 hex characters (git commit hash in the version string).
fn extractCommitHash(raw: []const u8) ?[]const u8 {
    var start: ?usize = null;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const is_hex = std.ascii.isHex(raw[i]);
        if (is_hex and start == null) start = i;
        if ((!is_hex or i == raw.len - 1) and start != null) {
            const end = if (is_hex) i + 1 else i;
            if (end - start.? >= 32) return raw[start.?..end];
            start = null;
        }
    }
    return null;
}

/// Fetch and parse deployed-version info for a nightly compiler. Failures
/// are non-fatal (version_info stays null).
fn fetchVersionInfo(alloc: std.mem.Allocator, io: std.Io, ec: *ExpCompiler) !void {
    const url = try std.fmt.allocPrint(alloc, "https://api.compiler-explorer.com/get_deployed_exe_version?id={s}", .{ec.id});
    const resp = apiFetch(alloc, io, .GET, url, null) catch return;
    if (resp.status != 200) return;
    const v = parseJsonValue(alloc, resp.body) catch return;
    if (v != .object) return;
    const raw = jsonStr(v, "version");
    ec.modified = jsonOptStr(v, "modified");

    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "raw", .{ .string = raw });
    try obj.put(alloc, "full", .{ .string = jsonStr(v, "full_version") });
    if (ec.modified) |mod| try obj.put(alloc, "modified", .{ .string = mod });
    if (extractVersionNumber(raw)) |vn| try obj.put(alloc, "version_number", .{ .string = vn });
    if (extractCommitHash(raw)) |ch| try obj.put(alloc, "commit_hash", .{ .string = ch });
    ec.version_info = .{ .object = obj };
}

fn writeCompilerInfo(js: *std.json.Stringify, alloc: std.mem.Allocator, ec: ExpCompiler, include_overrides: bool, include_runtime_tools: bool, include_compile_tools: bool) !void {
    _ = alloc;
    try js.beginObject();
    try js.objectField("id");
    try js.write(ec.id);
    try js.objectField("name");
    try js.write(ec.name);
    try js.objectField("category");
    try js.write(ec.category);
    if (ec.proposals.len > 0) {
        try js.objectField("proposals");
        try js.beginArray();
        for (ec.proposals) |p| try js.write(p);
        try js.endArray();
    }
    if (ec.features.len > 0) {
        try js.objectField("features");
        try js.beginArray();
        for (ec.features) |f| try js.write(f);
        try js.endArray();
    }
    if (ec.modified) |mod| {
        try js.objectField("modified");
        try js.write(mod);
    }
    if (ec.version_info) |vi| {
        try js.objectField("version_info");
        try js.write(vi);
    }
    if (include_overrides) {
        try js.objectField("possibleOverrides");
        try js.write(argValue(ec.raw, "possibleOverrides"));
    }
    if (include_runtime_tools) {
        try js.objectField("possibleRuntimeTools");
        try js.write(argValue(ec.raw, "possibleRuntimeTools"));
    }
    if (include_compile_tools) {
        try js.objectField("tools");
        try js.write(argValue(ec.raw, "tools"));
    }
    try js.endObject();
}

// --- payload builders ---

fn writeOptValueArray(js: *std.json.Stringify, v: ?std.json.Value) !void {
    if (v) |val| {
        try js.write(val);
    } else {
        try js.beginArray();
        try js.endArray();
    }
}

/// The produce*/overrides compilerOptions block ce-mcp sends for compile
/// requests.
fn writeProduceCompilerOptions(js: *std.json.Stringify, produce_opt_info: bool) !void {
    try js.beginObject();
    try js.objectField("producePp");
    try js.write(null);
    try js.objectField("produceAst");
    try js.write(null);
    try js.objectField("produceGccDump");
    try js.beginObject();
    try js.endObject();
    try js.objectField("produceCfg");
    try js.write(false);
    try js.objectField("produceGnatDebugTree");
    try js.write(null);
    try js.objectField("produceGnatDebug");
    try js.write(null);
    try js.objectField("produceIr");
    try js.write(null);
    try js.objectField("produceOptInfo");
    try js.write(produce_opt_info);
    try js.objectField("produceStackUsageInfo");
    try js.write(null);
    try js.objectField("produceCppCheck");
    try js.write(null);
    try js.objectField("produceDevice");
    try js.write(null);
    try js.objectField("overrides");
    try js.write(null);
    try js.endObject();
}

fn buildCompilePayload(alloc: std.mem.Allocator, source: []const u8, language: []const u8, compiler: []const u8, options: []const u8, filters: Filters, libraries: ?std.json.Value, tools: ?std.json.Value, produce_opt_info: bool) ![]u8 {
    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = newJs(&sw);
    try js.beginObject();
    try js.objectField("source");
    try js.write(source);
    try js.objectField("compiler");
    try js.write(compiler);
    try js.objectField("lang");
    try js.write(language);
    try js.objectField("options");
    try js.beginObject();
    try js.objectField("userArguments");
    try js.write(options);
    try js.objectField("compilerOptions");
    try writeProduceCompilerOptions(&js, produce_opt_info);
    try js.objectField("filters");
    try writeFilters(&js, filters);
    try js.objectField("tools");
    try writeOptValueArray(&js, tools);
    try js.objectField("libraries");
    try writeOptValueArray(&js, libraries);
    try js.endObject();
    try js.endObject();
    return alloc.dupe(u8, sw.written());
}

fn buildExecutePayload(alloc: std.mem.Allocator, source: []const u8, options: []const u8, stdin: []const u8, exec_args: std.json.Value, filters: Filters, libraries: ?std.json.Value, tools: ?std.json.Value) ![]u8 {
    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = newJs(&sw);
    try js.beginObject();
    try js.objectField("source");
    try js.write(source);
    try js.objectField("options");
    try js.beginObject();
    try js.objectField("userArguments");
    try js.write(options);
    try js.objectField("executeParameters");
    try js.beginObject();
    try js.objectField("args");
    if (exec_args == .array) {
        try js.write(exec_args);
    } else {
        try js.beginArray();
        try js.endArray();
    }
    try js.objectField("stdin");
    try js.write(stdin);
    try js.endObject();
    try js.objectField("compilerOptions");
    try js.beginObject();
    try js.objectField("executorRequest");
    try js.write(true);
    try js.objectField("skipAsm");
    try js.write(true);
    try js.endObject();
    try js.objectField("filters");
    try writeFilters(&js, filters);
    try js.objectField("tools");
    try writeOptValueArray(&js, tools);
    try js.objectField("libraries");
    try writeOptValueArray(&js, libraries);
    try js.endObject();
    try js.endObject();
    return alloc.dupe(u8, sw.written());
}

const CMakeFile = struct {
    filename: []const u8,
    contents: []const u8,
};

fn buildCmakePayload(alloc: std.mem.Allocator, cmake_source: []const u8, files: []const CMakeFile, options: []const u8, cmake_args: []const u8, execute: bool, filters: Filters, libraries: ?std.json.Value) ![]u8 {
    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = newJs(&sw);
    try js.beginObject();
    try js.objectField("source");
    try js.write(cmake_source);
    try js.objectField("files");
    try js.beginArray();
    for (files) |f| {
        try js.beginObject();
        try js.objectField("filename");
        try js.write(f.filename);
        try js.objectField("contents");
        try js.write(f.contents);
        try js.endObject();
    }
    try js.endArray();
    try js.objectField("options");
    try js.beginObject();
    try js.objectField("userArguments");
    try js.write(options);
    try js.objectField("compilerOptions");
    try js.beginObject();
    try js.objectField("executorRequest");
    try js.write(execute);
    try js.objectField("cmakeArgs");
    try js.write(cmake_args);
    try js.objectField("customOutputFilename");
    try js.write("");
    try js.endObject();
    try js.objectField("filters");
    try writeFilters(&js, filters);
    try js.objectField("libraries");
    try writeOptValueArray(&js, libraries);
    try js.endObject();
    try js.endObject();
    return alloc.dupe(u8, sw.written());
}

fn buildSharePayload(alloc: std.mem.Allocator, source: []const u8, language: []const u8, compiler: []const u8, options: []const u8, libraries: ?std.json.Value, tools: ?std.json.Value, create_binary: bool, create_object_only: bool) ![]u8 {
    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = newJs(&sw);
    try js.beginObject();
    try js.objectField("sessions");
    try js.beginArray();
    try js.beginObject();
    try js.objectField("id");
    try js.write(@as(i64, 1));
    try js.objectField("language");
    try js.write(language);
    try js.objectField("source");
    try js.write(source);
    try js.objectField("compilers");
    try js.beginArray();
    try js.beginObject();
    try js.objectField("id");
    try js.write(compiler);
    try js.objectField("options");
    try js.write(options);
    try js.objectField("filters");
    try js.beginObject();
    try js.objectField("binary");
    try js.write(create_binary);
    try js.objectField("binaryObject");
    try js.write(create_object_only);
    try js.endObject();
    try js.objectField("libs");
    try writeOptValueArray(&js, libraries);
    if (tools) |t| {
        try js.objectField("tools");
        try js.write(t);
    }
    try js.endObject();
    try js.endArray();
    try js.endObject();
    try js.endArray();
    try js.endObject();
    return alloc.dupe(u8, sw.written());
}

fn buildCmakeSharePayload(alloc: std.mem.Allocator, cmake_source: []const u8, files: []const CMakeFile, language: []const u8, compiler: []const u8, options: []const u8, cmake_args: []const u8, libraries: ?std.json.Value) ![]u8 {
    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    var js = newJs(&sw);
    try js.beginObject();
    try js.objectField("sessions");
    try js.beginArray();
    try js.beginObject();
    try js.objectField("id");
    try js.write(@as(i64, 1));
    try js.objectField("language");
    try js.write("cmake");
    try js.objectField("filename");
    try js.write("CMakeLists.txt");
    try js.objectField("source");
    try js.write(cmake_source);
    try js.objectField("compilers");
    try js.beginArray();
    try js.endArray();
    try js.endObject();
    try js.endArray();
    try js.objectField("trees");
    try js.beginArray();
    try js.beginObject();
    try js.objectField("id");
    try js.write(@as(i64, 1));
    try js.objectField("compilerLanguageId");
    try js.write(language);
    try js.objectField("isCMakeProject");
    try js.write(true);
    try js.objectField("files");
    try js.beginArray();
    for (files) |f| {
        try js.beginObject();
        try js.objectField("filename");
        try js.write(f.filename);
        try js.objectField("content");
        try js.write(f.contents);
        try js.objectField("isMainSource");
        try js.write(false);
        try js.objectField("langId");
        try js.write(language);
        try js.endObject();
    }
    // CMakeLists.txt travels as the tree's main source.
    try js.beginObject();
    try js.objectField("filename");
    try js.write("CMakeLists.txt");
    try js.objectField("content");
    try js.write(cmake_source);
    try js.objectField("isMainSource");
    try js.write(true);
    try js.objectField("langId");
    try js.write("cmake");
    try js.objectField("editorId");
    try js.write(@as(i64, 1));
    try js.endObject();
    try js.endArray();
    try js.objectField("compilers");
    try js.beginArray();
    try js.beginObject();
    try js.objectField("id");
    try js.write(compiler);
    try js.objectField("options");
    try js.write(options);
    try js.objectField("cmakeArgs");
    try js.write(cmake_args);
    try js.objectField("libs");
    try writeOptValueArray(&js, libraries);
    try js.endObject();
    try js.endArray();
    try js.endObject();
    try js.endArray();
    try js.endObject();
    return alloc.dupe(u8, sw.written());
}

// --- libraries / tools validation ---

const LibSpec = struct {
    id: []const u8,
    version: []const u8,
};

const LibResult = union(enum) {
    ok: []const LibSpec,
    err: []const u8,
};

fn strLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// ce-mcp library-not-found message with substring-based suggestions.
fn libraryNotFoundMsg(alloc: std.mem.Allocator, lib_list: []const std.json.Value, language: []const u8, id: []const u8) ![]const u8 {
    var suggestions: std.ArrayList(std.json.Value) = .empty;
    for (lib_list) |lib| {
        if (lib != .object) continue;
        if (containsIgnoreCase(jsonStr(lib, "id"), id) or containsIgnoreCase(jsonStr(lib, "name"), id)) {
            try suggestions.append(alloc, lib);
        }
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("Library '{s}' not found for {s}", .{ id, language });
    if (suggestions.items.len == 0) {
        try out.writer.print("\n\nNo similar libraries found for {s}.", .{language});
    } else {
        try out.writer.writeAll("\n\nDid you mean:");
        for (suggestions.items) |lib| {
            try out.writer.print("\n  - {s} ({s}) - versions: ", .{ jsonStr(lib, "id"), jsonStr(lib, "name") });
            const versions = jsonArray(lib, "versions");
            const show = @min(versions.len, 3);
            for (versions[0..show], 0..) |v, i| {
                if (i > 0) try out.writer.writeAll(", ");
                try out.writer.writeAll(jsonStr(v, "version"));
            }
            if (versions.len > show) try out.writer.print(", +{d} more", .{versions.len - show});
        }
        try out.writer.print("\n\nExample usage: [{{\"id\": \"{s}\", \"version\": \"latest\"}}]", .{jsonStr(suggestions.items[0], "id")});
    }
    return alloc.dupe(u8, out.written());
}

/// Resolve [{"id","version"}] library specs against /libraries/{language},
/// resolving "latest" and validating compiler support via libsArr.
fn resolveLibraries(alloc: std.mem.Allocator, io: std.Io, language: []const u8, compiler: []const u8, libs_arg: std.json.Value) !LibResult {
    if (libs_arg != .array or libs_arg.array.items.len == 0) return .{ .ok = &.{} };

    const url = try std.fmt.allocPrint(alloc, "{s}/libraries/{s}", .{ API_BASE, language });
    const resp = apiFetch(alloc, io, .GET, url, null) catch |err| {
        return .{ .err = try std.fmt.allocPrint(alloc, "Compiler Explorer API request failed: {s}", .{@errorName(err)}) };
    };
    if (resp.status != 200) {
        return .{ .err = try std.fmt.allocPrint(alloc, "Compiler Explorer API error: HTTP {d}", .{resp.status}) };
    }
    const libs_json = parseJsonValue(alloc, resp.body) catch {
        return .{ .err = try alloc.dupe(u8, "Compiler Explorer API returned invalid JSON") };
    };
    const lib_list = if (libs_json == .array) libs_json.array.items else &.{};

    // Compiler support info (libsArr non-empty means only those are allowed).
    var supported: ?[]const std.json.Value = null;
    const curl = try std.fmt.allocPrint(alloc, "{s}/compilers/{s}?fields={s}", .{ API_BASE, language, COMPILER_FIELDS_ESSENTIAL });
    if (apiFetch(alloc, io, .GET, curl, null)) |cresp| {
        if (cresp.status == 200) {
            if (parseJsonValue(alloc, cresp.body)) |comps| {
                if (comps == .array) {
                    for (comps.array.items) |c| {
                        if (c != .object) continue;
                        if (std.mem.eql(u8, jsonStr(c, "id"), compiler)) {
                            const arr = jsonArray(c, "libsArr");
                            if (arr.len > 0) supported = arr;
                            break;
                        }
                    }
                }
            } else |_| {}
        }
    } else |_| {}

    var out: std.ArrayList(LibSpec) = .empty;
    for (libs_arg.array.items) |req| {
        if (req != .object) continue;
        const id = jsonStr(req, "id");
        if (id.len == 0) continue;

        if (supported) |arr| {
            var found = false;
            for (arr) |s| {
                if (s == .string and std.mem.eql(u8, s.string, id)) found = true;
            }
            if (!found) {
                return .{ .err = try std.fmt.allocPrint(alloc, "Compiler '{s}' does not support libraries: {s}", .{ compiler, id }) };
            }
        }

        var target: ?std.json.Value = null;
        for (lib_list) |lib| {
            if (lib != .object) continue;
            if (std.mem.eql(u8, jsonStr(lib, "id"), id)) {
                target = lib;
                break;
            }
        }
        const lib = target orelse return .{ .err = try libraryNotFoundMsg(alloc, lib_list, language, id) };

        const versions = jsonArray(lib, "versions");
        const req_version = jsonOptStr(req, "version");
        var resolved: ?[]const u8 = null;
        if (req_version == null or std.mem.eql(u8, req_version.?, "latest")) {
            resolved = getLatestVersionId(alloc, versions) catch null;
        } else {
            resolved = resolveLibraryVersion(versions, req_version.?);
            if (resolved == null) {
                return .{ .err = try std.fmt.allocPrint(alloc, "Version '{s}' not found for library '{s}'", .{ req_version.?, id }) };
            }
        }
        try out.append(alloc, .{ .id = id, .version = resolved orelse "" });
    }
    return .{ .ok = out.items };
}

const ToolsResult = struct {
    /// Validated tools array Value to embed in payloads (null -> empty array).
    tools: ?std.json.Value = null,
    warnings: []const []const u8 = &.{},
};

const tools_unvalidated_warning = "Warning: Could not validate tools for compiler '{s}' - compiler not found or tools info unavailable";

/// Validate requested tools against the compiler's advertised tool set.
/// Invalid ids are dropped with a warning; when validation is impossible
/// the tools pass through unchanged.
fn validateTools(alloc: std.mem.Allocator, io: std.Io, language: []const u8, compiler: []const u8, tools_arg: std.json.Value) !ToolsResult {
    if (tools_arg != .array or tools_arg.array.items.len == 0) return .{};

    var comp_tools: ?std.json.Value = null;
    const url = try std.fmt.allocPrint(alloc, "{s}/compilers/{s}?fields={s}", .{ API_BASE, language, COMPILER_FIELDS_EXTENDED });
    if (apiFetch(alloc, io, .GET, url, null)) |resp| {
        if (resp.status == 200) {
            if (parseJsonValue(alloc, resp.body)) |comps| {
                if (comps == .array) {
                    for (comps.array.items) |c| {
                        if (c != .object) continue;
                        if (std.mem.eql(u8, jsonStr(c, "id"), compiler)) {
                            const t = argValue(c, "tools");
                            if (t == .object) comp_tools = t;
                            break;
                        }
                    }
                }
            } else |_| {}
        }
    } else |_| {}

    if (comp_tools == null) {
        const w = try std.fmt.allocPrint(alloc, tools_unvalidated_warning, .{compiler});
        const ws = try alloc.alloc([]const u8, 1);
        ws[0] = w;
        return .{ .tools = tools_arg, .warnings = ws };
    }

    var available: std.ArrayList([]const u8) = .empty;
    var it = comp_tools.?.object.iterator();
    while (it.next()) |kv| try available.append(alloc, kv.key_ptr.*);
    std.mem.sort([]const u8, available.items, {}, strLessThan);

    var kept = std.json.Array.init(alloc);
    var warnings: std.ArrayList([]const u8) = .empty;
    for (tools_arg.array.items) |tool| {
        const id = jsonStr(tool, "id");
        var ok = false;
        for (available.items) |a| {
            if (std.mem.eql(u8, a, id)) {
                ok = true;
                break;
            }
        }
        if (ok) {
            try kept.append(tool);
            continue;
        }
        var suggs: std.ArrayList([]const u8) = .empty;
        for (available.items) |a| {
            if (containsIgnoreCase(a, id) or containsIgnoreCase(id, a)) try suggs.append(alloc, a);
        }
        if (suggs.items.len > 0) {
            const show = @min(suggs.items.len, 2);
            var buf: std.Io.Writer.Allocating = .init(alloc);
            defer buf.deinit();
            for (suggs.items[0..show], 0..) |s, i| {
                if (i > 0) try buf.writer.writeAll("', '");
                try buf.writer.writeAll(s);
            }
            try warnings.append(alloc, try std.fmt.allocPrint(alloc, "Warning: Tool '{s}' not available for compiler '{s}'. Did you mean: '{s}'?", .{ id, compiler, buf.written() }));
        } else {
            const show = @min(available.items.len, 5);
            var buf: std.Io.Writer.Allocating = .init(alloc);
            defer buf.deinit();
            for (available.items[0..show], 0..) |s, i| {
                if (i > 0) try buf.writer.writeAll("', '");
                try buf.writer.writeAll(s);
            }
            if (available.items.len > show) {
                try warnings.append(alloc, try std.fmt.allocPrint(alloc, "Warning: Tool '{s}' not available for compiler '{s}'. Available tools: '{s}' (and {d} more)", .{ id, compiler, buf.written(), available.items.len - show }));
            } else {
                try warnings.append(alloc, try std.fmt.allocPrint(alloc, "Warning: Tool '{s}' not available for compiler '{s}'. Available tools: '{s}'", .{ id, compiler, buf.written() }));
            }
        }
    }
    return .{ .tools = .{ .array = kept }, .warnings = warnings.items };
}

// --- cmake input resolution ---

const CMakeInputs = struct {
    cmake_source: []const u8,
    files: []const CMakeFile,
};

const cmake_source_extensions = [_][]const u8{ ".c", ".cc", ".cpp", ".cxx", ".c++", ".h", ".hh", ".hpp", ".hxx", ".ixx", ".cppm", ".s", ".asm" };

fn isSourceFileName(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const ext = name[dot..];
    for (cmake_source_extensions) |e| {
        if (std.ascii.eqlIgnoreCase(e, ext)) return true;
    }
    return false;
}

/// Test-facing wrapper (inline inputs only; file modes need the Io variant).
fn resolveCmakeInputs(alloc: std.mem.Allocator, args: std.json.Value, err_msg: *?[]const u8) !?CMakeInputs {
    return resolveCmakeInputsImpl(alloc, null, args, err_msg);
}

fn resolveCmakeInputsIo(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value, err_msg: *?[]const u8) !?CMakeInputs {
    return resolveCmakeInputsImpl(alloc, io, args, err_msg);
}

/// Resolve the three ce-mcp input modes: inline (cmake_source), single file
/// (cmake_path), or directory auto-discovery (project_dir).
fn resolveCmakeInputsImpl(alloc: std.mem.Allocator, io_opt: ?std.Io, args: std.json.Value, err_msg: *?[]const u8) !?CMakeInputs {
    const cmake_source_arg = getStr(args, "cmake_source");
    const cmake_path = getStr(args, "cmake_path");
    const project_dir = getStr(args, "project_dir");

    const use_source = cmake_source_arg != null and cmake_source_arg.?.len > 0;
    const use_path = !use_source and cmake_path != null and cmake_path.?.len > 0;
    const use_dir = !use_source and !use_path and project_dir != null and project_dir.?.len > 0;

    var cmake_source: []const u8 = "";
    if (use_source) {
        cmake_source = cmake_source_arg.?;
    } else if (use_path) {
        const io = io_opt orelse {
            err_msg.* = "error: file access unavailable in this context";
            return null;
        };
        cmake_source = std.Io.Dir.cwd().readFileAlloc(io, cmake_path.?, alloc, .limited(8 * 1024 * 1024)) catch {
            err_msg.* = try std.fmt.allocPrint(alloc, "error: cannot read cmake_path '{s}'", .{cmake_path.?});
            return null;
        };
    } else if (use_dir) {
        const io = io_opt orelse {
            err_msg.* = "error: file access unavailable in this context";
            return null;
        };
        const cpath = try std.fmt.allocPrint(alloc, "{s}/CMakeLists.txt", .{project_dir.?});
        cmake_source = std.Io.Dir.cwd().readFileAlloc(io, cpath, alloc, .limited(8 * 1024 * 1024)) catch {
            err_msg.* = try std.fmt.allocPrint(alloc, "error: cannot read CMakeLists.txt in project_dir '{s}'", .{project_dir.?});
            return null;
        };
    } else {
        err_msg.* = "error: one of cmake_source, cmake_path, or project_dir is required";
        return null;
    }

    var files: std.ArrayList(CMakeFile) = .empty;

    if (use_dir) {
        // Auto-discover source/header files (sorted), excluding CMakeLists.txt.
        const io = io_opt.?;
        var dir = std.Io.Dir.cwd().openDir(io, project_dir.?, .{ .iterate = true }) catch {
            err_msg.* = try std.fmt.allocPrint(alloc, "error: cannot open project_dir '{s}'", .{project_dir.?});
            return null;
        };
        defer dir.close(io);
        var names: std.ArrayList([]const u8) = .empty;
        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            try names.append(alloc, try alloc.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, strLessThan);
        for (names.items) |name| {
            if (std.mem.eql(u8, name, "CMakeLists.txt")) continue;
            if (!isSourceFileName(name)) continue;
            const contents = dir.readFileAlloc(io, name, alloc, .limited(8 * 1024 * 1024)) catch continue;
            try files.append(alloc, .{ .filename = name, .contents = contents });
        }
    }

    // Explicit files entries: {filename, contents} inline or {path} on disk.
    for (jsonArray(args, "files")) |f| {
        if (f != .object) continue;
        if (jsonOptStr(f, "contents")) |contents| {
            const fname = jsonOptStr(f, "filename") orelse continue;
            try files.append(alloc, .{ .filename = fname, .contents = contents });
        } else if (jsonOptStr(f, "path")) |p| {
            const io = io_opt orelse {
                err_msg.* = "error: file access unavailable in this context";
                return null;
            };
            const contents = std.Io.Dir.cwd().readFileAlloc(io, p, alloc, .limited(8 * 1024 * 1024)) catch {
                err_msg.* = try std.fmt.allocPrint(alloc, "error: cannot read file '{s}'", .{p});
                return null;
            };
            try files.append(alloc, .{ .filename = basename(p), .contents = contents });
        }
    }

    return .{ .cmake_source = cmake_source, .files = files.items };
}

// ---------------------------------------------------------------------------
// Tests — canned godbolt.org responses through the fetch seam
// ---------------------------------------------------------------------------

const Canned = struct {
    status: u16,
    body: []const u8,
};

var mock_responses: []const Canned = &.{};
var mock_count: usize = 0;
var mock_reqs: [32]?FetchRequest = .{null} ** 32;

fn mockFetch(alloc: std.mem.Allocator, io: std.Io, req: FetchRequest) anyerror!HttpResp {
    _ = io;
    const idx = mock_count;
    if (idx >= mock_reqs.len) return error.TooManyMockCalls;
    mock_reqs[idx] = .{
        .method = req.method,
        .url = try alloc.dupe(u8, req.url),
        .body = if (req.body) |b| try alloc.dupe(u8, b) else null,
    };
    mock_count += 1;
    if (idx >= mock_responses.len) return error.UnexpectedFetch;
    const c = mock_responses[idx];
    return .{ .status = c.status, .body = try alloc.dupe(u8, c.body) };
}

const TestEnv = struct {
    arena_state: std.heap.ArenaAllocator,

    fn init() TestEnv {
        fetch_impl = mockFetch;
        mock_responses = &.{};
        mock_count = 0;
        mock_reqs = .{null} ** 32;
        return .{ .arena_state = std.heap.ArenaAllocator.init(std.testing.allocator) };
    }

    fn deinit(self: *TestEnv) void {
        fetch_impl = httpsFetch;
        self.arena_state.deinit();
    }

    fn alloc(self: *TestEnv) std.mem.Allocator {
        return self.arena_state.allocator();
    }
};

fn parseArgs(alloc: std.mem.Allocator, s: []const u8) !std.json.Value {
    return (try std.json.parseFromSlice(std.json.Value, alloc, s, .{})).value;
}

// --- canned fixtures ---------------------------------------------------------

const LIBRARIES_JSON =
    \\[
    \\  {"id":"fmt","name":"{fmt}","url":"https://fmt.dev","description":"A modern formatting library",
    \\   "versions":[
    \\     {"id":"1010","version":"10.1.0","$order":10,"alias":[]},
    \\     {"id":"1100","version":"11.0.0","$order":11,"alias":["latest"]},
    \\     {"id":"trunk","version":"trunk","$order":99,"alias":[]}
    \\   ]},
    \\  {"id":"boost","name":"Boost","url":"https://boost.org","description":"Boost C++ libraries",
    \\   "versions":[{"id":"183","version":"1.83.0","$order":1,"alias":[]}]}
    \\]
;

const COMPILERS_ESSENTIAL_JSON =
    \\[
    \\  {"id":"g132","name":"x86-64 gcc 13.2","lang":"c++","isNightly":false,"libsArr":[]},
    \\  {"id":"clang1600","name":"x86-64 clang 16.0.0","lang":"c++","isNightly":false,"libsArr":[]}
    \\]
;

const COMPILERS_EXTENDED_JSON =
    \\[
    \\  {"id":"g132","name":"x86-64 gcc 13.2","lang":"c++","isNightly":false,"libsArr":[]},
    \\  {"id":"clang1600","name":"x86-64 clang 16.0.0","lang":"c++","isNightly":false,"libsArr":[]},
    \\  {"id":"clang_p3385","name":"clang P3385 (experimental reflection)","lang":"c++","isNightly":true,"libsArr":[]}
    \\]
;

const LANGUAGES_JSON =
    \\[
    \\  {"id":"c++","name":"C++","extensions":[".cpp",".cxx"],"defaultCompiler":"g132"},
    \\  {"id":"python","name":"Python","extensions":[".py"]},
    \\  {"id":"javascript","name":"JavaScript","extensions":[".js"]}
    \\]
;

// --- compile_check -----------------------------------------------------------

test "compile_check posts merged extract_args, resolves friendly compiler, shapes response" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{.{ .status = 200, .body = "{\"code\": 0, \"stdout\": [], \"stderr\": []}" }};

    const args = try parseArgs(env.alloc(),
        \\{"source": "// flags: -std=c++20\nint main() { return 0; }", "language": "c++", "compiler": "g++", "options": "-O2", "create_binary": true}
    );
    const res = try handleCompileCheck(env.alloc(), std.testing.io, args);
    try std.testing.expect(!res.is_error);

    try std.testing.expectEqual(@as(usize, 1), mock_count);
    const req = mock_reqs[0].?;
    try std.testing.expect(req.method == .POST);
    // friendly name "g++" resolved via compiler_mappings
    try std.testing.expectEqualStrings("https://godbolt.org/api/compiler/g132/compile", req.url);

    const body = (try parseJson(env.alloc(), req.body.?)).value;
    try std.testing.expectEqualStrings("c++", jsonStr(body, "lang"));
    try std.testing.expectEqualStrings("g132", jsonStr(body, "compiler"));
    const opts = body.object.get("options").?;
    // options + extracted flags merged
    try std.testing.expectEqualStrings("-O2 -std=c++20", jsonStr(opts, "userArguments"));
    const filters = opts.object.get("filters").?;
    try std.testing.expect(jsonBool(filters, "binary", false));
    try std.testing.expect(!jsonBool(filters, "binaryObject", true));
    try std.testing.expect(!jsonBool(filters, "execute", true));
    try std.testing.expect(jsonBool(filters, "intel", false));
    const co = opts.object.get("compilerOptions").?;
    try std.testing.expect(!jsonBool(co, "produceOptInfo", true));

    const out = (try parseJson(env.alloc(), res.text)).value;
    try std.testing.expect(jsonBool(out, "success", false));
    try std.testing.expectEqual(@as(i64, 0), jsonInt(out, "exit_code", -1));
    try std.testing.expectEqual(@as(i64, 0), jsonInt(out, "error_count", -1));
    try std.testing.expectEqual(@as(i64, 0), jsonInt(out, "warning_count", -1));
    try std.testing.expect(out.object.get("first_error").? == .null);
}

test "compile_check maps HTTP errors to is_error" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{.{ .status = 400, .body = "bad request" }};

    const args = try parseArgs(env.alloc(),
        \\{"source": "int main(){}", "language": "c++", "compiler": "g132"}
    );
    const res = try handleCompileCheck(env.alloc(), std.testing.io, args);
    try std.testing.expect(res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "400") != null);
}

test "compile_check requires source/language/compiler" {
    var env = TestEnv.init();
    defer env.deinit();
    const res = try handleCompileCheck(env.alloc(), std.testing.io, try parseArgs(env.alloc(), "{\"language\":\"c++\"}"));
    try std.testing.expect(res.is_error);
}

// --- compile_and_run ---------------------------------------------------------

test "compile_and_run builds executor payload and shapes execution result" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{.{ .status = 200, .body =
        \\{"code": 0, "didExecute": true, "execTime": 3, "stdout": [{"text": "Hello\n"}], "stderr": [], "buildResult": {"code": 0, "stdout": [], "stderr": []}, "truncated": false}
    }};

    const args = try parseArgs(env.alloc(),
        \\{"source": "int main(){return 0;}", "language": "c++", "compiler": "g132", "stdin": "42", "args": ["a1", "a2"]}
    );
    const res = try handleCompileAndRun(env.alloc(), std.testing.io, args);
    try std.testing.expect(!res.is_error);

    const req = mock_reqs[0].?;
    try std.testing.expect(req.method == .POST);
    try std.testing.expectEqualStrings("https://godbolt.org/api/compiler/g132/compile", req.url);
    const body = (try parseJson(env.alloc(), req.body.?)).value;
    const opts = body.object.get("options").?;
    const ep = opts.object.get("executeParameters").?;
    try std.testing.expectEqualStrings("42", jsonStr(ep, "stdin"));
    const ep_args = jsonArray(ep, "args");
    try std.testing.expectEqual(@as(usize, 2), ep_args.len);
    try std.testing.expectEqualStrings("a1", ep_args[0].string);
    const co = opts.object.get("compilerOptions").?;
    try std.testing.expect(jsonBool(co, "executorRequest", false));
    try std.testing.expect(jsonBool(co, "skipAsm", false));
    try std.testing.expect(jsonBool(opts.object.get("filters").?, "execute", false));

    const out = (try parseJson(env.alloc(), res.text)).value;
    try std.testing.expect(jsonBool(out, "compiled", false));
    try std.testing.expect(jsonBool(out, "executed", false));
    try std.testing.expectEqual(@as(i64, 0), jsonInt(out, "exit_code", -99));
    try std.testing.expectEqual(@as(i64, 3), jsonInt(out, "execution_time_ms", -1));
    try std.testing.expectEqualStrings("Hello\n", jsonStr(out, "stdout"));
    try std.testing.expect(!jsonBool(out, "truncated", true));
}

test "compile_and_run failed compilation collects stderr from buildResult" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{.{ .status = 200, .body =
        \\{"code": -1, "didExecute": false, "buildResult": {"code": 1, "stdout": [], "stderr": [{"text": "error: nope\n"}]}, "stderr": [{"text": "Build failed"}], "execResult": {"stderr": []}}
    }};

    const args = try parseArgs(env.alloc(),
        \\{"source": "int main(){", "language": "c++", "compiler": "g132"}
    );
    const res = try handleCompileAndRun(env.alloc(), std.testing.io, args);
    const out = (try parseJson(env.alloc(), res.text)).value;
    try std.testing.expect(!jsonBool(out, "compiled", true));
    // execResult key present -> executed true (parity with ce-mcp)
    try std.testing.expect(jsonBool(out, "executed", false));
    try std.testing.expectEqual(@as(i64, -1), jsonInt(out, "exit_code", 0));
    try std.testing.expectEqualStrings("error: nope\n", jsonStr(out, "stderr"));
}

// --- compile_with_diagnostics ------------------------------------------------

test "compile_with_diagnostics parses tagged stderr and extracts suggestions" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{.{ .status = 200, .body =
        \\{"code": 1, "stderr": [
        \\  {"text": "<source>:3:5: error: use of undeclared identifier 'vaule'; did you mean 'value'?", "tag": {"line": 3, "column": 5, "severity": 2, "text": "use of undeclared identifier 'vaule'; did you mean 'value'?"}},
        \\  {"text": "<source>:2:7: warning: unused variable", "tag": {"line": 2, "column": 7, "severity": 1, "text": "unused variable 'x'"}}
        \\]}
    }};

    const args = try parseArgs(env.alloc(),
        \\{"source": "int main(){int x; return vaule;}", "language": "c++", "compiler": "g132"}
    );
    const res = try handleCompileWithDiagnostics(env.alloc(), std.testing.io, args);
    try std.testing.expect(!res.is_error);

    // normal level appends -Wall
    const body = (try parseJson(env.alloc(), mock_reqs[0].?.body.?)).value;
    try std.testing.expectEqualStrings("-Wall", jsonStr(body.object.get("options").?, "userArguments"));

    const out = (try parseJson(env.alloc(), res.text)).value;
    try std.testing.expect(!jsonBool(out, "success", true));
    try std.testing.expectEqualStrings("g132 -Wall <source>", jsonStr(out, "command"));
    const diags = jsonArray(out, "diagnostics");
    try std.testing.expectEqual(@as(usize, 2), diags.len);
    try std.testing.expectEqualStrings("error", jsonStr(diags[0], "type"));
    try std.testing.expectEqual(@as(i64, 3), jsonInt(diags[0], "line", 0));
    try std.testing.expectEqual(@as(i64, 5), jsonInt(diags[0], "column", 0));
    try std.testing.expectEqualStrings("use of undeclared identifier 'vaule'; did you mean 'value'?", jsonStr(diags[0], "message"));
    try std.testing.expectEqualStrings("did you mean 'value'?", jsonStr(diags[0], "suggestion"));
    try std.testing.expectEqualStrings("warning", jsonStr(diags[1], "type"));
    try std.testing.expect(diags[1].object.get("suggestion").? == .null);
}

test "compile_with_diagnostics verbose level appends full warning flags" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{.{ .status = 200, .body = "{\"code\": 0, \"stderr\": []}" }};
    const args = try parseArgs(env.alloc(),
        \\{"source": "int main(){return 0;}", "language": "c++", "compiler": "g132", "options": "-std=c++20", "diagnostic_level": "verbose"}
    );
    const res = try handleCompileWithDiagnostics(env.alloc(), std.testing.io, args);
    try std.testing.expect(!res.is_error);
    const body = (try parseJson(env.alloc(), mock_reqs[0].?.body.?)).value;
    try std.testing.expectEqualStrings("-std=c++20 -Wall -Wextra -Wpedantic", jsonStr(body.object.get("options").?, "userArguments"));
}

// --- analyze_optimization ----------------------------------------------------

test "analyze_optimization filters asm, inverts filter flags, formats opt remarks" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{.{ .status = 200, .body =
        \\{"code": 0,
        \\ "asm": [{"text": "main:"}, {"text": ""}, {"text": "        push rbp"}, {"text": "        call foo"}],
        \\ "optOutput": [{"text": "raw", "displayString": "vectorized loop", "Pass": "loop-vectorize", "optType": "Missed", "DebugLoc": {"File": "example.cpp", "Line": 3, "Column": 5}}]}
    }};

    const args = try parseArgs(env.alloc(),
        \\{"source": "int main(){return 0;}", "language": "c++", "compiler": "g132", "optimization_level": "-O2", "filter_out_library_code": true, "do_demangle": false}
    );
    const res = try handleAnalyzeOptimization(env.alloc(), std.testing.io, args);
    try std.testing.expect(!res.is_error);

    const body = (try parseJson(env.alloc(), mock_reqs[0].?.body.?)).value;
    const opts = body.object.get("options").?;
    try std.testing.expectEqualStrings("-O2", jsonStr(opts, "userArguments"));
    const filters = opts.object.get("filters").?;
    // inverted: filter_out_library_code=true -> libraryCode=false
    try std.testing.expect(!jsonBool(filters, "libraryCode", true));
    try std.testing.expect(!jsonBool(filters, "demangle", true));
    try std.testing.expect(jsonBool(opts.object.get("compilerOptions").?, "produceOptInfo", false));

    const out = (try parseJson(env.alloc(), res.text)).value;
    try std.testing.expectEqual(@as(i64, 4), jsonInt(out, "assembly_lines", -1));
    try std.testing.expectEqual(@as(i64, 3), jsonInt(out, "instruction_count", -1));
    try std.testing.expect(!jsonBool(out, "truncated", true));
    const asm_out = jsonArray(out, "assembly_output");
    try std.testing.expectEqual(@as(usize, 3), asm_out.len);
    try std.testing.expectEqualStrings("main:", asm_out[0].string);
    try std.testing.expectEqualStrings("push rbp", asm_out[1].string);
    const remarks = jsonArray(out, "optimization_remarks");
    try std.testing.expectEqual(@as(usize, 1), remarks.len);
    try std.testing.expectEqualStrings("example.cpp:3:5: remark: vectorized loop [-Rmissed=loop-vectorize]", remarks[0].string);
}

test "analyze_optimization caps assembly at 500 lines" {
    var env = TestEnv.init();
    defer env.deinit();

    var buf: std.Io.Writer.Allocating = .init(env.alloc());
    defer buf.deinit();
    try buf.writer.writeAll("{\"code\": 0, \"asm\": [");
    for (0..600) |i| {
        if (i > 0) try buf.writer.writeAll(",");
        try buf.writer.print("{{\"text\": \"insn{d}\"}}", .{i});
    }
    try buf.writer.writeAll("]}");

    mock_responses = &.{.{ .status = 200, .body = buf.written() }};
    const args = try parseArgs(env.alloc(),
        \\{"source": "int main(){return 0;}", "language": "c++", "compiler": "g132", "include_optimization_remarks": false}
    );
    const res = try handleAnalyzeOptimization(env.alloc(), std.testing.io, args);
    const out = (try parseJson(env.alloc(), res.text)).value;
    try std.testing.expectEqual(@as(i64, 600), jsonInt(out, "assembly_lines", -1));
    try std.testing.expectEqual(@as(i64, 500), jsonInt(out, "instruction_count", -1));
    try std.testing.expect(jsonBool(out, "truncated", false));
    try std.testing.expectEqual(@as(i64, 600), jsonInt(out, "total_instructions", -1));
    try std.testing.expectEqual(@as(usize, 500), jsonArray(out, "assembly_output").len);
}

// --- compare_compilers -------------------------------------------------------

test "compare_compilers assembly produces diff with statistics and summary" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{
        .{ .status = 200, .body =
            \\{"code": 0, "asm": [{"text": "main:"}, {"text": "        push rbp"}, {"text": "        call foo"}], "stderr": []}
        },
        .{ .status = 200, .body =
            \\{"code": 0, "asm": [{"text": "main:"}, {"text": "        call bar"}, {"text": "        ret"}, {"text": "        nop"}], "stderr": []}
        },
    };

    const args = try parseArgs(env.alloc(),
        \\{"source": "int main(){return 0;}", "language": "c++",
        \\ "compilers": [{"id": "g132", "options": "-O0"}, {"id": "clang1600", "options": "-O2"}],
        \\ "comparison_type": "assembly"}
    );
    const res = try handleCompareCompilers(env.alloc(), std.testing.io, args);
    try std.testing.expect(!res.is_error);
    try std.testing.expectEqual(@as(usize, 2), mock_count);
    try std.testing.expectEqualStrings("https://godbolt.org/api/compiler/g132/compile", mock_reqs[0].?.url);
    try std.testing.expectEqualStrings("https://godbolt.org/api/compiler/clang1600/compile", mock_reqs[1].?.url);

    const out = (try parseJson(env.alloc(), res.text)).value;
    const results = jsonArray(out, "results");
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(@as(i64, 3), jsonInt(results[0], "assembly_size", -1));
    try std.testing.expectEqual(@as(i64, 4), jsonInt(results[1], "assembly_size", -1));

    const diffs = jsonArray(out, "differences");
    try std.testing.expect(diffs.len >= 1);
    try std.testing.expectEqualStrings("clang1600 produces 33% larger code", diffs[0].string);

    const asm_diff = out.object.get("assembly_diff").?;
    const stats = asm_diff.object.get("statistics").?;
    try std.testing.expectEqual(@as(i64, 3), jsonInt(stats, "lines_added", -1));
    try std.testing.expectEqual(@as(i64, 2), jsonInt(stats, "lines_removed", -1));
    try std.testing.expectEqualStrings("clang1600 produces 33% larger code", diffs[0].string);
    const summary = jsonStr(asm_diff, "summary");
    try std.testing.expect(std.mem.indexOf(u8, summary, "1 lines longer") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "New function calls: bar") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "Removed function calls: foo") != null);
    const ud = jsonStr(asm_diff, "unified_diff");
    try std.testing.expect(std.mem.indexOf(u8, ud, "-push rbp") != null);
    try std.testing.expect(std.mem.indexOf(u8, ud, "+call bar") != null);
    try std.testing.expect(std.mem.indexOf(u8, ud, "... (truncated)") != null);
}

test "compare_compilers execution reports exit code and stdout differences" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{
        .{ .status = 200, .body = "{\"code\": 0, \"didExecute\": true, \"execTime\": 2, \"stdout\": [{\"text\": \"1\\n\"}], \"stderr\": [], \"buildResult\": {\"code\": 0}}" },
        .{ .status = 200, .body = "{\"code\": 1, \"didExecute\": true, \"execTime\": 2, \"stdout\": [{\"text\": \"2\\n\"}], \"stderr\": [], \"buildResult\": {\"code\": 0}}" },
    };
    const args = try parseArgs(env.alloc(),
        \\{"source": "int main(){return 0;}", "language": "c++",
        \\ "compilers": [{"id": "g132", "options": "-O0"}, {"id": "clang1600", "options": "-O2"}],
        \\ "comparison_type": "execution"}
    );
    const res = try handleCompareCompilers(env.alloc(), std.testing.io, args);
    const out = (try parseJson(env.alloc(), res.text)).value;
    const results = jsonArray(out, "results");
    try std.testing.expect(jsonBool(results[0], "compiled", false));
    try std.testing.expect(jsonBool(results[0], "executed", false));
    try std.testing.expectEqual(@as(i64, 1), jsonInt(results[1], "exit_code", -99));
    const diffs = jsonArray(out, "differences");
    var found_exit = false;
    var found_stdout = false;
    for (diffs) |d| {
        if (std.mem.indexOf(u8, d.string, "Exit codes differ: g132=0, clang1600=1") != null) found_exit = true;
        if (std.mem.indexOf(u8, d.string, "Stdout content differs") != null) found_stdout = true;
    }
    try std.testing.expect(found_exit);
    try std.testing.expect(found_stdout);
    const exec_diff = out.object.get("execution_diff").?;
    try std.testing.expect(std.mem.indexOf(u8, jsonStr(exec_diff, "stdout_diff"), "-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonStr(exec_diff, "summary"), "stdout differs") != null);
}

test "compare_compilers diagnostics compares warning counts" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{
        .{ .status = 200, .body = "{\"code\": 0, \"stderr\": [{\"text\": \"warning: unused\"}]}" },
        .{ .status = 200, .body = "{\"code\": 0, \"stderr\": []}" },
    };
    const args = try parseArgs(env.alloc(),
        \\{"source": "int main(){int x; return 0;}", "language": "c++",
        \\ "compilers": [{"id": "g132"}, {"id": "clang1600"}],
        \\ "comparison_type": "diagnostics"}
    );
    const res = try handleCompareCompilers(env.alloc(), std.testing.io, args);
    const out = (try parseJson(env.alloc(), res.text)).value;
    const diffs = jsonArray(out, "differences");
    try std.testing.expectEqual(@as(usize, 1), diffs.len);
    try std.testing.expectEqualStrings("clang1600 produces 1 fewer warnings", diffs[0].string);
    const results = jsonArray(out, "results");
    try std.testing.expectEqual(@as(i64, 1), jsonInt(results[0], "warnings", -1));
}

// --- generate_share_url ------------------------------------------------------

test "generate_share_url resolves libraries and posts session to shortener" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{
        .{ .status = 200, .body = LIBRARIES_JSON },
        .{ .status = 200, .body = COMPILERS_ESSENTIAL_JSON },
        .{ .status = 200, .body = "{\"url\": \"https://godbolt.org/z/abc123\"}" },
    };
    const args = try parseArgs(env.alloc(),
        \\{"source": "int main(){return 0;}", "language": "c++", "compiler": "g132",
        \\ "libraries": [{"id": "fmt", "version": "latest"}], "create_binary": true}
    );
    const res = try handleGenerateShareUrl(env.alloc(), std.testing.io, args);
    try std.testing.expect(!res.is_error);
    try std.testing.expectEqual(@as(usize, 3), mock_count);
    const req = mock_reqs[2].?;
    try std.testing.expectEqualStrings("https://godbolt.org/api/shortener", req.url);
    const body = (try parseJson(env.alloc(), req.body.?)).value;
    const sessions = jsonArray(body, "sessions");
    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings("c++", jsonStr(sessions[0], "language"));
    const comps = jsonArray(sessions[0], "compilers");
    try std.testing.expectEqualStrings("g132", jsonStr(comps[0], "id"));
    const libs = jsonArray(comps[0], "libs");
    try std.testing.expectEqual(@as(usize, 1), libs.len);
    try std.testing.expectEqualStrings("fmt", jsonStr(libs[0], "id"));
    try std.testing.expectEqualStrings("1100", jsonStr(libs[0], "version"));
    try std.testing.expect(jsonBool(comps[0].object.get("filters").?, "binary", false));

    const out = (try parseJson(env.alloc(), res.text)).value;
    try std.testing.expectEqualStrings("https://godbolt.org/z/abc123", jsonStr(out, "url"));
}

// --- find_compilers ----------------------------------------------------------

test "find_compilers rejects overly broad search terms without HTTP" {
    var env = TestEnv.init();
    defer env.deinit();
    const args = try parseArgs(env.alloc(), "{\"search_text\": \"gcc\"}");
    const res = try handleFindCompilers(env.alloc(), std.testing.io, args);
    try std.testing.expect(!res.is_error);
    try std.testing.expectEqual(@as(usize, 0), mock_count);
    const out = (try parseJson(env.alloc(), res.text)).value;
    try std.testing.expect(std.mem.indexOf(u8, jsonStr(out, "error"), "too broad") != null);
    try std.testing.expect(jsonArray(out, "valid_examples").len > 0);
}

test "find_compilers feature search finds nightly compiler and fetches version info" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{
        .{ .status = 200, .body = COMPILERS_EXTENDED_JSON },
        .{ .status = 200, .body = "{\"version\": \"clang version 21.0.0git (https://github.com/llvm/llvm-project 0123456789abcdef0123456789abcdef01234567)\", \"full_version\": \"full\", \"modified\": \"2025-07-24T00:00:00\"}" },
    };
    const args = try parseArgs(env.alloc(), "{\"language\": \"c++\", \"feature\": \"reflection\"}");
    const res = try handleFindCompilers(env.alloc(), std.testing.io, args);
    try std.testing.expect(!res.is_error);
    try std.testing.expectEqual(@as(usize, 2), mock_count);
    try std.testing.expectEqualStrings(
        "https://godbolt.org/api/compilers/c++?fields=" ++ COMPILER_FIELDS_EXTENDED,
        mock_reqs[0].?.url,
    );
    try std.testing.expectEqualStrings(
        "https://api.compiler-explorer.com/get_deployed_exe_version?id=clang_p3385",
        mock_reqs[1].?.url,
    );

    const out = (try parseJson(env.alloc(), res.text)).value;
    try std.testing.expectEqual(@as(i64, 1), jsonInt(out.object.get("summary").?, "total_found", -1));
    const comps = jsonArray(out, "compilers");
    try std.testing.expectEqual(@as(usize, 1), comps.len);
    try std.testing.expectEqualStrings("clang_p3385", jsonStr(comps[0], "id"));
    try std.testing.expectEqualStrings("reflection", jsonStr(comps[0], "category"));
    const proposals = jsonArray(comps[0], "proposals");
    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    try std.testing.expectEqualStrings("P3385", proposals[0].string);
    const vi = comps[0].object.get("version_info").?;
    try std.testing.expectEqualStrings("21.0.0git", jsonStr(vi, "version_number"));
    try std.testing.expectEqualStrings("2025-07-24T00:00:00", jsonStr(comps[0], "modified"));
}

test "find_compilers show_all categorizes experimental compilers" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{
        .{ .status = 200, .body = COMPILERS_EXTENDED_JSON },
        // nightly appears in two categories (proposals + reflection) -> two version fetches
        .{ .status = 200, .body = "{\"version\": \"clang version 21.0.0git\", \"modified\": \"2025-07-24\"}" },
        .{ .status = 200, .body = "{\"version\": \"clang version 21.0.0git\", \"modified\": \"2025-07-24\"}" },
    };
    const args = try parseArgs(env.alloc(), "{\"language\": \"c++\", \"show_all\": true}");
    const res = try handleFindCompilers(env.alloc(), std.testing.io, args);
    try std.testing.expect(!res.is_error);
    const out = (try parseJson(env.alloc(), res.text)).value;
    const cats = out.object.get("categories").?;
    const proposals = cats.object.get("proposals").?;
    try std.testing.expectEqual(@as(i64, 1), jsonInt(proposals, "count", -1));
    const reflection = cats.object.get("reflection").?;
    try std.testing.expectEqual(@as(i64, 1), jsonInt(reflection, "count", -1));
    const summary = out.object.get("summary").?;
    try std.testing.expectEqual(@as(i64, 2), jsonInt(summary, "categories_found", -1));
}

test "find_compilers exact_search ids_only returns plain id list" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{
        .{ .status = 200, .body = COMPILERS_EXTENDED_JSON },
        .{ .status = 200, .body = "{\"version\": \"clang version 21.0.0git\", \"modified\": \"2025-07-24\"}" },
    };
    const args = try parseArgs(env.alloc(),
        \\{"language": "c++", "search_text": "clang_p3385", "exact_search": true, "ids_only": true}
    );
    const res = try handleFindCompilers(env.alloc(), std.testing.io, args);
    const out = (try parseJson(env.alloc(), res.text)).value;
    const comps = jsonArray(out, "compilers");
    try std.testing.expectEqual(@as(usize, 1), comps.len);
    try std.testing.expectEqualStrings("clang_p3385", comps[0].string);
}

// --- get_libraries / get_library_details / get_languages ---------------------

test "get_libraries simplifies to id/name and filters by search_text" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{.{ .status = 200, .body = LIBRARIES_JSON }};
    const args = try parseArgs(env.alloc(), "{\"language\": \"c++\", \"search_text\": \"boost\"}");
    const res = try handleGetLibraries(env.alloc(), std.testing.io, args);
    try std.testing.expect(!res.is_error);
    try std.testing.expectEqualStrings("https://godbolt.org/api/libraries/c++", mock_reqs[0].?.url);
    const out = (try parseJson(env.alloc(), res.text)).value;
    try std.testing.expectEqual(@as(i64, 1), jsonInt(out, "count", -1));
    const libs = jsonArray(out, "libraries");
    try std.testing.expectEqualStrings("boost", jsonStr(libs[0], "id"));
    try std.testing.expectEqualStrings("Boost", jsonStr(libs[0], "name"));
}

test "get_library_details returns versions with id/version only" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{.{ .status = 200, .body = LIBRARIES_JSON }};
    const args = try parseArgs(env.alloc(), "{\"language\": \"c++\", \"library_id\": \"fmt\"}");
    const res = try handleGetLibraryDetails(env.alloc(), std.testing.io, args);
    const out = (try parseJson(env.alloc(), res.text)).value;
    const lib = out.object.get("library").?;
    try std.testing.expectEqualStrings("fmt", jsonStr(lib, "id"));
    try std.testing.expectEqualStrings("https://fmt.dev", jsonStr(lib, "url"));
    const versions = jsonArray(lib, "versions");
    try std.testing.expectEqual(@as(usize, 3), versions.len);
    try std.testing.expectEqualStrings("1010", jsonStr(versions[0], "id"));
    try std.testing.expectEqualStrings("10.1.0", jsonStr(versions[0], "version"));
    try std.testing.expect(versions[0].object.get("$order") == null);
}

test "get_library_details reports unknown library" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{.{ .status = 200, .body = LIBRARIES_JSON }};
    const args = try parseArgs(env.alloc(), "{\"language\": \"c++\", \"library_id\": \"nope\"}");
    const res = try handleGetLibraryDetails(env.alloc(), std.testing.io, args);
    const out = (try parseJson(env.alloc(), res.text)).value;
    try std.testing.expect(std.mem.indexOf(u8, jsonStr(out, "error"), "not found") != null);
}

test "get_languages simplifies and filters" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{.{ .status = 200, .body = LANGUAGES_JSON }};
    const res = try handleGetLanguages(env.alloc(), std.testing.io, try parseArgs(env.alloc(), "{\"search_text\": \"script\"}"));
    try std.testing.expect(!res.is_error);
    try std.testing.expectEqualStrings("https://godbolt.org/api/languages", mock_reqs[0].?.url);
    const out = (try parseJson(env.alloc(), res.text)).value;
    try std.testing.expectEqual(@as(i64, 1), jsonInt(out, "count", -1));
    const langs = jsonArray(out, "languages");
    try std.testing.expectEqualStrings("javascript", jsonStr(langs[0], "id"));
    try std.testing.expectEqualStrings(".js", jsonArray(langs[0], "extensions")[0].string);
}

// --- lookup_instruction ------------------------------------------------------

test "lookup_instruction resolves arm64 alias and formats docs" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{.{ .status = 200, .body = "{\"tooltip\": \"Store Pair of Registers\", \"forms\": [{\"gas\": \"stp x0, x1, [sp]\"}]}" }};
    const args = try parseArgs(env.alloc(), "{\"instruction_set\": \"arm64\", \"opcode\": \"STP\"}");
    const res = try handleLookupInstruction(env.alloc(), std.testing.io, args);
    try std.testing.expect(!res.is_error);
    try std.testing.expectEqualStrings("https://godbolt.org/api/asm/aarch64/stp", mock_reqs[0].?.url);
    const out = (try parseJson(env.alloc(), res.text)).value;
    try std.testing.expect(jsonBool(out, "found", false));
    try std.testing.expectEqualStrings("aarch64", jsonStr(out, "instruction_set"));
    try std.testing.expectEqualStrings("arm64", jsonStr(out, "original_instruction_set"));
    try std.testing.expectEqualStrings("aarch64", jsonStr(out, "resolved_instruction_set"));
    const docs = jsonStr(out, "formatted_docs");
    try std.testing.expect(std.mem.indexOf(u8, docs, "## STP - AARCH64 Instruction") != null);
    try std.testing.expect(std.mem.indexOf(u8, docs, "Store Pair of Registers") != null);
    try std.testing.expect(std.mem.indexOf(u8, docs, "stp x0, x1, [sp]") != null);
}

test "lookup_instruction 404 falls back to original instruction set" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{
        .{ .status = 404, .body = "" },
        .{ .status = 404, .body = "" },
    };
    const args = try parseArgs(env.alloc(), "{\"instruction_set\": \"x86_64\", \"opcode\": \"bogus\"}");
    const res = try handleLookupInstruction(env.alloc(), std.testing.io, args);
    try std.testing.expect(!res.is_error);
    try std.testing.expectEqual(@as(usize, 2), mock_count);
    try std.testing.expectEqualStrings("https://godbolt.org/api/asm/amd64/bogus", mock_reqs[0].?.url);
    try std.testing.expectEqualStrings("https://godbolt.org/api/asm/x86_64/bogus", mock_reqs[1].?.url);
    const out = (try parseJson(env.alloc(), res.text)).value;
    try std.testing.expect(!jsonBool(out, "found", true));
    try std.testing.expect(std.mem.indexOf(u8, jsonStr(out, "error"), "not found") != null);
}

// --- library resolution (via compile_check with libraries) -------------------

test "compile_check resolves library 'latest' via $order and passes to payload" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{
        .{ .status = 200, .body = LIBRARIES_JSON },
        .{ .status = 200, .body = COMPILERS_ESSENTIAL_JSON },
        .{ .status = 200, .body = "{\"code\": 0, \"stderr\": []}" },
    };
    const args = try parseArgs(env.alloc(),
        \\{"source": "int main(){return 0;}", "language": "c++", "compiler": "g132",
        \\ "libraries": [{"id": "fmt", "version": "latest"}]}
    );
    const res = try handleCompileCheck(env.alloc(), std.testing.io, args);
    try std.testing.expect(!res.is_error);
    try std.testing.expectEqualStrings("https://godbolt.org/api/libraries/c++", mock_reqs[0].?.url);
    try std.testing.expectEqualStrings(
        "https://godbolt.org/api/compilers/c++?fields=" ++ COMPILER_FIELDS_ESSENTIAL,
        mock_reqs[1].?.url,
    );
    const body = (try parseJson(env.alloc(), mock_reqs[2].?.body.?)).value;
    const libs = jsonArray(body.object.get("options").?, "libraries");
    try std.testing.expectEqual(@as(usize, 1), libs.len);
    try std.testing.expectEqualStrings("fmt", jsonStr(libs[0], "id"));
    // trunk excluded despite higher $order; 11.0.0 is latest stable
    try std.testing.expectEqualStrings("1100", jsonStr(libs[0], "version"));
}

test "compile_check unknown library errors with suggestions" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{
        .{ .status = 200, .body = LIBRARIES_JSON },
        .{ .status = 200, .body = COMPILERS_ESSENTIAL_JSON },
    };
    const args = try parseArgs(env.alloc(),
        \\{"source": "int main(){return 0;}", "language": "c++", "compiler": "g132",
        \\ "libraries": [{"id": "fm"}]}
    );
    const res = try handleCompileCheck(env.alloc(), std.testing.io, args);
    try std.testing.expect(res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "Library 'fm' not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "Did you mean") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "fmt") != null);
}

test "compile_check library unsupported by compiler errors" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{
        .{ .status = 200, .body = LIBRARIES_JSON },
        .{ .status = 200, .body =
            \\[{"id":"g132","name":"x86-64 gcc 13.2","lang":"c++","isNightly":false,"libsArr":["boost"]}]
        },
    };
    const args = try parseArgs(env.alloc(),
        \\{"source": "int main(){return 0;}", "language": "c++", "compiler": "g132",
        \\ "libraries": [{"id": "fmt"}]}
    );
    const res = try handleCompileCheck(env.alloc(), std.testing.io, args);
    try std.testing.expect(res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "does not support libraries: fmt") != null);
}

// --- tool validation warnings (via compile_and_run with tools) ---------------

test "compile_and_run invalid tool ids produce tool_warnings" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{
        .{ .status = 200, .body =
            \\[{"id":"g132","name":"x86-64 gcc 13.2","lang":"c++","isNightly":false,"tools":{"iwyu022":{"id":"iwyu022","tool":{"name":"Include What You Use"}}}}]
        },
        .{ .status = 200, .body = "{\"code\": 0, \"didExecute\": true, \"execTime\": 1, \"stdout\": [], \"stderr\": [], \"buildResult\": {\"code\": 0}}" },
    };
    const args = try parseArgs(env.alloc(),
        \\{"source": "int main(){return 0;}", "language": "c++", "compiler": "g132",
        \\ "tools": [{"id": "iwyu022", "args": []}, {"id": "bogus"}]}
    );
    const res = try handleCompileAndRun(env.alloc(), std.testing.io, args);
    try std.testing.expect(!res.is_error);
    try std.testing.expectEqualStrings(
        "https://godbolt.org/api/compilers/c++?fields=" ++ COMPILER_FIELDS_EXTENDED,
        mock_reqs[0].?.url,
    );
    // only the valid tool reaches the payload
    const body = (try parseJson(env.alloc(), mock_reqs[1].?.body.?)).value;
    const tools = jsonArray(body.object.get("options").?, "tools");
    try std.testing.expectEqual(@as(usize, 1), tools.len);
    try std.testing.expectEqualStrings("iwyu022", jsonStr(tools[0], "id"));

    const out = (try parseJson(env.alloc(), res.text)).value;
    const warnings = jsonArray(out, "tool_warnings");
    try std.testing.expectEqual(@as(usize, 1), warnings.len);
    try std.testing.expect(std.mem.indexOf(u8, warnings[0].string, "Tool 'bogus' not available for compiler 'g132'") != null);
}

// --- download_shortlink ------------------------------------------------------

fn tmpFsPath(alloc: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]const u8 {
    return std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path });
}

fn forwardSlashes(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try alloc.dupe(u8, s);
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

test "download_shortlink saves session source with preserved name and metadata" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{.{ .status = 200, .body =
        \\{"sessions": [{"id": 1, "language": "c++", "source": "int main() { return 0; }\n", "filename": "example.cpp", "compilers": [{"id": "g132"}]}]}
    }};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dest = try forwardSlashes(env.alloc(), try tmpFsPath(env.alloc(), &tmp));
    // pre-existing file forces conflict numbering
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "example.cpp", .data = "old" });

    const args_json = try std.fmt.allocPrint(env.alloc(),
        \\{{"shortlink_url": "https://godbolt.org/z/AbC123", "destination_path": "{s}"}}
    , .{dest});
    const res = try handleDownloadShortlink(env.alloc(), std.testing.io, try parseArgs(env.alloc(), args_json));
    try std.testing.expect(!res.is_error);
    try std.testing.expectEqualStrings("https://godbolt.org/api/shortlinkinfo/AbC123", mock_reqs[0].?.url);

    const out = (try parseJson(env.alloc(), res.text)).value;
    try std.testing.expectEqualStrings("AbC123", jsonStr(out, "shortlink_id"));
    try std.testing.expectEqual(@as(i64, 1), jsonInt(out, "total_files", -1));
    const saved = jsonArray(out, "files_saved");
    try std.testing.expectEqual(@as(usize, 1), saved.len);
    try std.testing.expectEqualStrings("example_1.cpp", jsonStr(saved[0], "saved_as"));
    try std.testing.expectEqualStrings("example.cpp", jsonStr(saved[0], "original_name"));

    const contents = try tmp.dir.readFileAlloc(std.testing.io, "example_1.cpp", env.alloc(), .limited(1 << 16));
    try std.testing.expectEqualStrings("int main() { return 0; }\n", contents);
    const meta = try tmp.dir.readFileAlloc(std.testing.io, "AbC123_metadata.json", env.alloc(), .limited(1 << 16));
    try std.testing.expect(std.mem.indexOf(u8, meta, "\"shortlink_id\": \"AbC123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonStr(out, "summary"), "Saved 1 file from CE shortlink AbC123") != null);
}

test "download_shortlink handles CMake tree projects" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{.{ .status = 200, .body =
        \\{"sessions": [], "trees": [{"id": 1, "compilerLanguageId": "c++", "isCMakeProject": true, "compilers": [{"id": "g132"}],
        \\  "files": [
        \\    {"filename": "main.cpp", "content": "int main(){}\n", "isMainSource": true, "langId": "c++"},
        \\    {"filename": "helper.cpp", "content": "int add(int a, int b){return a+b;}\n"}
        \\  ]}]}
    }};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dest = try forwardSlashes(env.alloc(), try tmpFsPath(env.alloc(), &tmp));
    const args_json = try std.fmt.allocPrint(env.alloc(),
        \\{{"shortlink_url": "TreeLink9", "destination_path": "{s}", "include_metadata": false}}
    , .{dest});
    const res = try handleDownloadShortlink(env.alloc(), std.testing.io, try parseArgs(env.alloc(), args_json));
    try std.testing.expect(!res.is_error);
    const out = (try parseJson(env.alloc(), res.text)).value;
    try std.testing.expectEqual(@as(i64, 2), jsonInt(out, "total_files", -1));
    _ = try tmp.dir.readFileAlloc(std.testing.io, "main.cpp", env.alloc(), .limited(1 << 16));
    _ = try tmp.dir.readFileAlloc(std.testing.io, "helper.cpp", env.alloc(), .limited(1 << 16));
    try std.testing.expectEqual(@as(usize, 0), jsonArray(out, "metadata_files").len);
}

// --- cmake_build / generate_cmake_share_url ----------------------------------

test "cmake_build posts cmake payload and parses build steps with ANSI stripping" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{.{ .status = 200, .body =
        \\{"code": 0,
        \\ "buildsteps": [
        \\   {"step": "cmake", "code": 0, "stdout": [{"text": "-- Configuring done\n"}], "stderr": []},
        \\   {"step": "build", "code": 0, "stdout": [], "stderr": []}
        \\ ],
        \\ "result": {"code": 0},
        \\ "didExecute": true,
        \\ "execResult": {"code": 0, "stdout": [{"text": "\u001b[32m3\u001b[0m\n"}], "stderr": [], "execTime": 5}}
    }};

    const args = try parseArgs(env.alloc(),
        \\{"compiler": "g132", "execute": true,
        \\ "cmake_source": "cmake_minimum_required(VERSION 3.10)\nproject(x)\nadd_executable(output.s main.cpp)",
        \\ "files": [{"filename": "main.cpp", "contents": "int main(){return 0;}"}]}
    );
    const res = try handleCmakeBuild(env.alloc(), std.testing.io, args);
    try std.testing.expect(!res.is_error);

    const req = mock_reqs[0].?;
    try std.testing.expectEqualStrings("https://godbolt.org/api/compiler/g132/cmake", req.url);
    const body = (try parseJson(env.alloc(), req.body.?)).value;
    try std.testing.expectEqualStrings("cmake_minimum_required(VERSION 3.10)\nproject(x)\nadd_executable(output.s main.cpp)", jsonStr(body, "source"));
    const files = jsonArray(body, "files");
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("main.cpp", jsonStr(files[0], "filename"));
    const opts = body.object.get("options").?;
    const co = opts.object.get("compilerOptions").?;
    try std.testing.expect(jsonBool(co, "executorRequest", false));
    try std.testing.expect(jsonBool(opts.object.get("filters").?, "execute", false));

    const out = (try parseJson(env.alloc(), res.text)).value;
    try std.testing.expect(jsonBool(out, "success", false));
    const steps = jsonArray(out, "build_steps");
    try std.testing.expectEqual(@as(usize, 2), steps.len);
    try std.testing.expectEqualStrings("cmake", jsonStr(steps[0], "step"));
    try std.testing.expectEqualStrings("-- Configuring done\n", jsonStr(steps[0], "stdout"));
    try std.testing.expect(jsonBool(out, "executed", false));
    try std.testing.expectEqual(@as(i64, 0), jsonInt(out, "exit_code", -1));
    try std.testing.expectEqual(@as(i64, 5), jsonInt(out, "execution_time_ms", -1));
    // ANSI colour codes stripped from program output
    try std.testing.expectEqualStrings("3\n", jsonStr(out, "stdout"));
}

test "cmake_build requires one input mode" {
    var env = TestEnv.init();
    defer env.deinit();
    const res = try handleCmakeBuild(env.alloc(), std.testing.io, try parseArgs(env.alloc(), "{\"compiler\": \"g132\"}"));
    try std.testing.expect(res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "cmake_source, cmake_path, or project_dir is required") != null);
}

test "cmake_build project_dir mode discovers CMakeLists.txt and sources" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{.{ .status = 200, .body =
        \\{"code": 0, "buildsteps": [{"step": "build", "code": 0, "stdout": [], "stderr": []}], "result": {"code": 0}}
    }};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "CMakeLists.txt", .data = "project(x)\nadd_executable(output.s main.cpp)" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "main.cpp", .data = "int main(){return 0;}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "helper.h", .data = "#pragma once" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "notes.txt", .data = "ignored" });

    const proj = try forwardSlashes(env.alloc(), try tmpFsPath(env.alloc(), &tmp));
    const args_json = try std.fmt.allocPrint(env.alloc(),
        \\{{"compiler": "g132", "project_dir": "{s}"}}
    , .{proj});
    const res = try handleCmakeBuild(env.alloc(), std.testing.io, try parseArgs(env.alloc(), args_json));
    try std.testing.expect(!res.is_error);
    const body = (try parseJson(env.alloc(), mock_reqs[0].?.body.?)).value;
    try std.testing.expectEqualStrings("project(x)\nadd_executable(output.s main.cpp)", jsonStr(body, "source"));
    const files = jsonArray(body, "files");
    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings("helper.h", jsonStr(files[0], "filename"));
    try std.testing.expectEqualStrings("main.cpp", jsonStr(files[1], "filename"));
}

test "generate_cmake_share_url posts tree with CMakeLists.txt as main source" {
    var env = TestEnv.init();
    defer env.deinit();
    mock_responses = &.{.{ .status = 200, .body = "{\"url\": \"https://godbolt.org/z/tree99\"}" }};
    const args = try parseArgs(env.alloc(),
        \\{"compiler": "g132",
        \\ "cmake_source": "project(x)",
        \\ "files": [{"filename": "main.cpp", "contents": "int main(){return 0;}"}]}
    );
    const res = try handleGenerateCmakeShareUrl(env.alloc(), std.testing.io, args);
    try std.testing.expect(!res.is_error);
    const req = mock_reqs[0].?;
    try std.testing.expectEqualStrings("https://godbolt.org/api/shortener", req.url);
    const body = (try parseJson(env.alloc(), req.body.?)).value;
    const sessions = jsonArray(body, "sessions");
    try std.testing.expectEqualStrings("cmake", jsonStr(sessions[0], "language"));
    try std.testing.expectEqualStrings("CMakeLists.txt", jsonStr(sessions[0], "filename"));
    const trees = jsonArray(body, "trees");
    try std.testing.expectEqual(@as(usize, 1), trees.len);
    try std.testing.expect(jsonBool(trees[0], "isCMakeProject", false));
    try std.testing.expectEqualStrings("c++", jsonStr(trees[0], "compilerLanguageId"));
    const tfiles = jsonArray(trees[0], "files");
    try std.testing.expectEqual(@as(usize, 2), tfiles.len);
    try std.testing.expectEqualStrings("main.cpp", jsonStr(tfiles[0], "filename"));
    try std.testing.expect(!jsonBool(tfiles[0], "isMainSource", true));
    try std.testing.expectEqualStrings("CMakeLists.txt", jsonStr(tfiles[1], "filename"));
    try std.testing.expect(jsonBool(tfiles[1], "isMainSource", false));
    try std.testing.expectEqualStrings("cmake", jsonStr(tfiles[1], "langId"));
    const tcomps = jsonArray(trees[0], "compilers");
    try std.testing.expectEqualStrings("g132", jsonStr(tcomps[0], "id"));

    const out = (try parseJson(env.alloc(), res.text)).value;
    try std.testing.expectEqualStrings("https://godbolt.org/z/tree99", jsonStr(out, "url"));
}

// --- pure helper tests --------------------------------------------------------

test "extractCompileArgs finds flags in common comment styles" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    try std.testing.expectEqualStrings("-Wall -O2", (try extractCompileArgs(alloc, "// flags: -Wall -O2\nint main(){}")).?);
    try std.testing.expectEqualStrings("-lm", (try extractCompileArgs(alloc, "# compile: -lm")).?);
    try std.testing.expectEqualStrings("-O3", (try extractCompileArgs(alloc, "/* flags: -O3 */")).?);
    try std.testing.expectEqualStrings("-Mdelphi", (try extractCompileArgs(alloc, "{ compile: -Mdelphi }")).?);
    try std.testing.expectEqualStrings("-x", (try extractCompileArgs(alloc, "-- flags: -x")).?);
    // case-insensitive keyword
    try std.testing.expectEqualStrings("-O2", (try extractCompileArgs(alloc, "// COMPILE: -O2")).?);
    // no match
    try std.testing.expect((try extractCompileArgs(alloc, "int main(){}")) == null);
    // only first 10 lines are scanned
    try std.testing.expect((try extractCompileArgs(alloc, "\n\n\n\n\n\n\n\n\n\n\n// flags: -O2")) == null);
}

test "extractCompilerSuggestion matches ce-mcp patterns" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    try std.testing.expectEqualStrings("did you mean 'value'?", (try extractCompilerSuggestion(alloc, "use of undeclared identifier 'vaule'; did you mean 'value'?")).?);
    try std.testing.expectEqualStrings("use 'std::vector' instead", (try extractCompilerSuggestion(alloc, "note: use 'std::vector' instead")).?);
    try std.testing.expectEqualStrings("suggested alternative: 'printf'", (try extractCompilerSuggestion(alloc, "note: suggested alternative: 'printf'")).?);
    try std.testing.expectEqualStrings("fix-it: 'foo'", (try extractCompilerSuggestion(alloc, "fix-it applied: 'foo'")).?);
    try std.testing.expect((try extractCompilerSuggestion(alloc, "plain error")) == null);
}

test "stripAnsi removes colour escape sequences" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    try std.testing.expectEqualStrings("ok", try stripAnsi(alloc, "\x1b[32mok\x1b[0m"));
    try std.testing.expectEqualStrings("plain", try stripAnsi(alloc, "plain"));
}

test "resolveInstructionSet maps aliases and lowercases" {
    try std.testing.expectEqualStrings("amd64", resolveInstructionSet("x86_64"));
    try std.testing.expectEqualStrings("amd64", resolveInstructionSet("x64"));
    try std.testing.expectEqualStrings("amd64", resolveInstructionSet("x86-64"));
    try std.testing.expectEqualStrings("amd64", resolveInstructionSet("intel"));
    try std.testing.expectEqualStrings("aarch64", resolveInstructionSet("ARM64"));
    try std.testing.expectEqualStrings("aarch64", resolveInstructionSet("armv8"));
    try std.testing.expectEqualStrings("riscv", resolveInstructionSet("RISCV"));
}

test "extractLinkId handles URLs and bare ids" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    try std.testing.expectEqualStrings("G38YP7eW4", try extractLinkId(alloc, "https://godbolt.org/z/G38YP7eW4"));
    try std.testing.expectEqualStrings("G38YP7eW4", try extractLinkId(alloc, "G38YP7eW4"));
    try std.testing.expectEqualStrings("abc", try extractLinkId(alloc, "http://godbolt.org/z/abc"));
}

test "generateFileName mirrors ce-mcp naming rules" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    try std.testing.expectEqualStrings("foo_main.cpp", try generateFileName(alloc, "foo.cpp", "c++", 1, "ce", true));
    try std.testing.expectEqualStrings("foo_main_main.cpp", try generateFileName(alloc, "foo_main.cpp", "c++", 1, "ce", true));
    try std.testing.expectEqualStrings("foo.cpp", try generateFileName(alloc, "foo.cpp", "c++", 1, "ce", false));
    try std.testing.expectEqualStrings("ce_002.cpp", try generateFileName(alloc, null, "c++", 2, "ce", false));
    try std.testing.expectEqualStrings("ce_002_main.cpp", try generateFileName(alloc, null, "c++", 2, "ce", true));
    try std.testing.expectEqualStrings("ce_001.rs", try generateFileName(alloc, null, "rust", 1, "ce", false));
    try std.testing.expectEqualStrings("ce_001.txt", try generateFileName(alloc, null, "cobol-unknown", 1, "ce", false));
}

test "resolveNameConflicts appends numbers before extension" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectEqualStrings("a.cpp", try resolveNameConflicts(alloc, std.testing.io, tmp.dir, "a.cpp"));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.cpp", .data = "x" });
    try std.testing.expectEqualStrings("a_1.cpp", try resolveNameConflicts(alloc, std.testing.io, tmp.dir, "a.cpp"));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a_1.cpp", .data = "x" });
    try std.testing.expectEqualStrings("a_2.cpp", try resolveNameConflicts(alloc, std.testing.io, tmp.dir, "a.cpp"));
}

test "getLatestVersionId prefers highest stable $order and falls back for dev-only lists" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const libs = (try parseJson(alloc, LIBRARIES_JSON)).value;
    const fmt = libs.array.items[0];
    try std.testing.expectEqualStrings("1100", try getLatestVersionId(alloc, jsonArray(fmt, "versions")));

    const dev_only = (try parseJson(alloc,
        \\[{"id":"t1","version":"trunk","$order":5},{"id":"t2","version":"master","$order":3}]
    )).value;
    try std.testing.expectEqualStrings("t1", try getLatestVersionId(alloc, dev_only.array.items));
}

test "resolveLibraryVersion matches id, version string, and alias" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const libs = (try parseJson(alloc, LIBRARIES_JSON)).value;
    const versions = jsonArray(libs.array.items[0], "versions");
    try std.testing.expectEqualStrings("1010", resolveLibraryVersion(versions, "1010").?);
    try std.testing.expectEqualStrings("1010", resolveLibraryVersion(versions, "10.1.0").?);
    try std.testing.expectEqualStrings("1100", resolveLibraryVersion(versions, "latest").?);
    try std.testing.expect(resolveLibraryVersion(versions, "9.9.9") == null);
}

test "proposal numbers and features extracted from compiler names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const props = try extractProposalNumbers(alloc, "clang P3385 and n3089 (experimental)");
    try std.testing.expectEqual(@as(usize, 2), props.len);
    try std.testing.expectEqualStrings("P3385", props[0]);
    try std.testing.expectEqualStrings("N3089", props[1]);
    try std.testing.expectEqual(@as(usize, 0), (try extractProposalNumbers(alloc, "gcc 13.2")).len);

    const feats = try extractFeatures(alloc, "clang reflection modules-ts build");
    try std.testing.expect(feats.len >= 2);
    try std.testing.expectEqualStrings("reflection", determineCategory("clang reflection fork"));
    try std.testing.expectEqualStrings("concepts", determineCategory("gcc concepts-ts"));
    try std.testing.expectEqualStrings("trunk_nightly", determineCategory("x86-64 clang (trunk)"));
    try std.testing.expectEqualStrings("other_experimental", determineCategory("some fork"));
    try std.testing.expect(isExperimental("gcc trunk build", "gtrunk", true));
    try std.testing.expect(isExperimental("clang p3385", "clangp3385", false));
    try std.testing.expect(!isExperimental("x86-64 gcc 13.2", "g132", false));
}

test "unifiedDiff emits difflib-style hunks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const a = [_][]const u8{ "main:", "push rbp", "call foo" };
    const b = [_][]const u8{ "main:", "call bar", "ret" };
    const diff = try unifiedDiff(alloc, &a, &b, "l1", "l2", 3);
    try std.testing.expect(std.mem.startsWith(u8, diff, "--- l1\n+++ l2\n"));
    try std.testing.expect(std.mem.indexOf(u8, diff, "@@ -1,3 +1,3 @@") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "\n main:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "\n-push rbp\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "\n-call foo\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "\n+call bar\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "\n+ret") != null);

    // identical inputs produce no diff
    try std.testing.expectEqualStrings("", try unifiedDiff(alloc, &a, &a, "l1", "l2", 3));
}

test "extractInstruction and extractFunctionCall classify asm lines" {
    try std.testing.expectEqualStrings("push", extractInstruction("push rbp").?);
    try std.testing.expectEqualStrings("movdqu", extractInstruction("movdqu xmm0, [rax]").?);
    try std.testing.expect(extractInstruction("main:") == null);
    try std.testing.expect(extractInstruction(".text") == null);
    try std.testing.expect(extractInstruction("# comment") == null);

    try std.testing.expectEqualStrings("foo", extractFunctionCall("call foo").?);
    try std.testing.expectEqualStrings("_bar", extractFunctionCall("bl _bar").?);
    try std.testing.expectEqualStrings("indirect_call", extractFunctionCall("call QWORD PTR [rax]").?);
    try std.testing.expect(extractFunctionCall("mov eax, 1") == null);
}

test "analyzeDiffText and generateDiffSummary produce ce-mcp statistics" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const a = [_][]const u8{ "main:", "push rbp", "call foo" };
    const b = [_][]const u8{ "main:", "call bar", "ret" };
    const diff = try unifiedDiff(alloc, &a, &b, "l1", "l2", 3);
    const stats = try analyzeDiffText(alloc, diff);
    try std.testing.expectEqual(@as(usize, 2), stats.lines_added);
    try std.testing.expectEqual(@as(usize, 2), stats.lines_removed);
    try std.testing.expectEqual(@as(usize, 2), stats.instructions_added.len);
    try std.testing.expectEqualStrings("call", stats.instructions_removed[1]);
    try std.testing.expectEqualStrings("foo", stats.calls_removed[0]);
    try std.testing.expectEqualStrings("bar", stats.calls_added[0]);

    const summary = try generateDiffSummary(alloc, stats, &a, &b);
    try std.testing.expect(std.mem.indexOf(u8, summary, "same number of lines") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "New instructions: call, ret") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "Removed instructions: push, call") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "New function calls: bar") != null);
}

test "normalizeAssembly strips comments and collapses whitespace" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const lines = try normalizeAssembly(alloc, "main:  # entry\n        push   rbp # save\n# full comment\n\n        ret");
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("main:", lines[0]);
    try std.testing.expectEqualStrings("push rbp", lines[1]);
    try std.testing.expectEqualStrings("ret", lines[2]);
}

test "collectAllStderr merges buildResult, top-level, steps and exec stderr" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const result = (try parseJson(alloc,
        \\{"code": -1,
        \\ "buildResult": {"code": 1, "stderr": [{"text": "detail error\n"}]},
        \\ "stderr": [{"text": "Build failed"}],
        \\ "buildsteps": [{"stderr": [{"text": "step fail\n"}]}],
        \\ "execResult": {"stderr": [{"text": "exec fail\n"}]}}
    )).value;
    const stderr = try collectAllStderr(alloc, result);
    try std.testing.expect(std.mem.indexOf(u8, stderr, "detail error") != null);
    // generic "Build failed" is skipped when detailed errors exist
    try std.testing.expect(std.mem.indexOf(u8, stderr, "Build failed") == null);
    try std.testing.expect(std.mem.indexOf(u8, stderr, "Build step 1: step fail") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr, "Execution: exec fail") != null);
}

test "resolveCmakeInputs validates input modes" {
    var env = TestEnv.init();
    defer env.deinit();
    var err_msg: ?[]const u8 = null;
    const r = try resolveCmakeInputs(env.alloc(), try parseArgs(env.alloc(), "{}"), &err_msg);
    try std.testing.expect(r == null);
    try std.testing.expect(std.mem.indexOf(u8, err_msg.?, "cmake_source, cmake_path, or project_dir is required") != null);

    err_msg = null;
    const r2 = try resolveCmakeInputs(env.alloc(), try parseArgs(env.alloc(),
        \\{"cmake_source": "project(x)", "files": [{"filename": "a.cpp", "contents": "int a;"}]}
    ), &err_msg);
    try std.testing.expect(r2 != null);
    try std.testing.expectEqualStrings("project(x)", r2.?.cmake_source);
    try std.testing.expectEqual(@as(usize, 1), r2.?.files.len);
    try std.testing.expectEqualStrings("a.cpp", r2.?.files[0].filename);
}
