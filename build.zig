const std = @import("std");

const Tool = struct {
    name: []const u8,
    binary: []const u8,
    src: []const u8,
};

const tools = [_]Tool{
    .{ .name = "datetime", .binary = "zmcp-datetime", .src = "src/datetime/main.zig" },
    .{ .name = "todo", .binary = "zmcp-todo", .src = "src/todo/main.zig" },
    .{ .name = "hn", .binary = "zmcp-hn", .src = "src/hn/main.zig" },
    .{ .name = "web-search", .binary = "zmcp-web-search", .src = "src/web_search/main.zig" },
    .{ .name = "fs", .binary = "zmcp-fs", .src = "src/fs/main.zig" },
    .{ .name = "fetch", .binary = "zmcp-fetch", .src = "src/fetch/main.zig" },
    .{ .name = "freejobs", .binary = "zmcp-freejobs", .src = "src/freejobs/main.zig" },
    .{ .name = "tickets", .binary = "zmcp-tickets", .src = "src/tickets/main.zig" },
    .{ .name = "time", .binary = "zmcp-time", .src = "src/time/main.zig" },
    .{ .name = "zig-packages", .binary = "zmcp-zig-packages", .src = "src/zig_packages/main.zig" },
    .{ .name = "package-registry", .binary = "zmcp-package-registry", .src = "src/package_registry/main.zig" },
    .{ .name = "wiki", .binary = "zmcp-wiki", .src = "src/wiki/main.zig" },
    .{ .name = "currency", .binary = "zmcp-currency", .src = "src/currency/main.zig" },
    .{ .name = "tldr", .binary = "zmcp-tldr", .src = "src/tldr/main.zig" },
    .{ .name = "ai-elements", .binary = "zmcp-ai-elements", .src = "src/ai_elements/main.zig" },
    .{ .name = "diff-render", .binary = "zmcp-diff-render", .src = "src/diff_render/main.zig" },
    .{ .name = "markdown-render", .binary = "zmcp-markdown-render", .src = "src/markdown_render/main.zig" },
    .{ .name = "huggingface", .binary = "zmcp-huggingface", .src = "src/huggingface/main.zig" },
    .{ .name = "rss", .binary = "zmcp-rss", .src = "src/rss/main.zig" },
    .{ .name = "arxiv", .binary = "zmcp-arxiv", .src = "src/arxiv/main.zig" },
    .{ .name = "sqlite", .binary = "zmcp-sqlite", .src = "src/sqlite/main.zig" },
    .{ .name = "zig-docs", .binary = "zmcp-zig-docs", .src = "src/zig_docs/main.zig" },
    .{ .name = "sequentialthinking", .binary = "zmcp-sequentialthinking", .src = "src/sequentialthinking/main.zig" },
    .{ .name = "weather", .binary = "zmcp-weather", .src = "src/weather/main.zig" },
    .{ .name = "github", .binary = "zmcp-github", .src = "src/github/main.zig" },
    .{ .name = "context7", .binary = "zmcp-context7", .src = "src/context7/main.zig" },
    .{ .name = "social", .binary = "zmcp-social", .src = "src/social/main.zig" },
    .{ .name = "compiler-explorer", .binary = "zmcp-compiler-explorer", .src = "src/compiler_explorer/main.zig" },
    .{ .name = "minimax", .binary = "zmcp-minimax", .src = "src/minimax/main.zig" },
    .{ .name = "ast-grep", .binary = "zmcp-ast-grep", .src = "src/ast_grep/main.zig" },
    .{ .name = "memory", .binary = "zmcp-memory", .src = "src/memory/main.zig" },
    .{ .name = "ripgrep", .binary = "zmcp-ripgrep", .src = "src/ripgrep/main.zig" },
    .{ .name = "git", .binary = "zmcp-git", .src = "src/git/main.zig" },
    .{ .name = "duckdb", .binary = "zmcp-duckdb", .src = "src/duckdb/main.zig" },
    .{ .name = "jq", .binary = "zmcp-jq", .src = "src/jq/main.zig" },
    .{ .name = "hippo", .binary = "zmcp-hippo", .src = "src/hippo/main.zig" },
    .{ .name = "mslearn", .binary = "zmcp-mslearn", .src = "src/mslearn/main.zig" },
    .{ .name = "kubernetes", .binary = "zmcp-kubernetes", .src = "src/kubernetes/main.zig" },
    .{ .name = "redis", .binary = "zmcp-redis", .src = "src/redis/main.zig" },
    .{ .name = "blender", .binary = "zmcp-blender", .src = "src/blender/main.zig" },
    .{ .name = "websearch-apis", .binary = "zmcp-websearch-apis", .src = "src/search_apis/main.zig" },
    .{ .name = "figma", .binary = "zmcp-figma", .src = "src/figma/main.zig" },
    .{ .name = "notion", .binary = "zmcp-notion", .src = "src/notion/main.zig" },
    .{ .name = "godot", .binary = "zmcp-godot", .src = "src/godot/main.zig" },
    .{ .name = "llm", .binary = "zmcp-llm", .src = "src/llm/main.zig" },
    .{ .name = "lsp", .binary = "zmcp-lsp", .src = "src/lsp/main.zig" },
    .{ .name = "zutil", .binary = "zmcp-zutil", .src = "src/zutil/main.zig" },
    .{ .name = "pdf", .binary = "zmcp-pdf", .src = "src/pdf/main.zig" },
    .{ .name = "postgres", .binary = "zmcp-postgres", .src = "src/postgres/main.zig" },
    .{ .name = "aws", .binary = "zmcp-aws", .src = "src/aws/main.zig" },
    .{ .name = "browser", .binary = "zmcp-browser", .src = "src/browser/main.zig" },
    .{ .name = "docker", .binary = "zmcp-docker", .src = "src/docker/main.zig" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mcp_mod = b.addModule("mcp", .{
        .root_source_file = b.path("src/mcp.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run all tests");

    // URL/SSRF policy shared by zmcp-browser (as a sibling file) and zmcp-fetch.
    const netpolicy_mod = b.createModule(.{
        .root_source_file = b.path("src/browser/policy.zig"),
        .target = target,
        .optimize = optimize,
    });

    inline for (tools) |t| {
        const root_mod = b.createModule(.{
            .root_source_file = b.path(t.src),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mcp", .module = mcp_mod },
            },
        });
        if (comptime std.mem.eql(u8, t.name, "fetch") or std.mem.eql(u8, t.name, "rss")) root_mod.addImport("netpolicy", netpolicy_mod);
        const exe = b.addExecutable(.{
            .name = t.binary,
            .root_module = root_mod,
        });
        b.installArtifact(exe);

        const tool_step = b.step(t.name, "Build " ++ t.binary);
        tool_step.dependOn(&b.addInstallArtifact(exe, .{}).step);

        const exe_tests = b.addTest(.{ .root_module = exe.root_module });
        const run_exe_tests = b.addRunArtifact(exe_tests);
        test_step.dependOn(&run_exe_tests.step);
    }

    // zmcp-gateway: one MCP endpoint over a slice of the servers above. It
    // spawns the zmcp-* binaries as children (no server module is linked).
    // zmcp-fake is a tiny helper server for its end-to-end tests only; it is
    // built for `zig build test` and never installed.
    {
        const gw_exe = b.addExecutable(.{
            .name = "zmcp-gateway",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/gateway/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "mcp", .module = mcp_mod }},
            }),
        });
        b.installArtifact(gw_exe);
        b.step("gateway", "Build zmcp-gateway").dependOn(&b.addInstallArtifact(gw_exe, .{}).step);

        const fake = b.addExecutable(.{
            .name = "zmcp-fake",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/gateway/fakechild.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "mcp", .module = mcp_mod }},
            }),
        });
        const gw_options = b.addOptions();
        gw_options.addOptionPath("fake_child_path", fake.getEmittedBin());
        const gw_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/gateway/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "mcp", .module = mcp_mod },
                    .{ .name = "build_options", .module = gw_options.createModule() },
                },
            }),
        });
        const run_gw_tests = b.addRunArtifact(gw_tests);
        test_step.dependOn(&run_gw_tests.step);
        b.step("test-gateway", "Run zmcp-gateway tests").dependOn(&run_gw_tests.step);
    }

    // Windows-only: native desktop control (computer_control + clawdcursor port).
    if (target.result.os.tag == .windows) {
        const computer = b.addExecutable(.{
            .name = "zmcp-computer",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/computer/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "mcp", .module = mcp_mod }},
            }),
        });
        b.installArtifact(computer);
        b.step("computer", "Build zmcp-computer").dependOn(&b.addInstallArtifact(computer, .{}).step);
        const computer_tests = b.addTest(.{ .root_module = computer.root_module });
        const run_computer_tests = b.addRunArtifact(computer_tests);
        test_step.dependOn(&run_computer_tests.step);
        b.step("test-computer", "Run zmcp-computer tests").dependOn(&run_computer_tests.step);
    }

    // Windows-only: zmcp-desktop, read-only UI Automation for allowlisted apps.
    // It reuses zmcp-computer's Win32 declarations and integrity check.
    if (target.result.os.tag == .windows) {
        const computer_shared = b.createModule(.{
            .root_source_file = b.path("src/computer/shared.zig"),
            .target = target,
            .optimize = optimize,
        });
        const desktop = b.addExecutable(.{
            .name = "zmcp-desktop",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/desktop/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "mcp", .module = mcp_mod },
                    .{ .name = "computer_shared", .module = computer_shared },
                },
            }),
        });
        b.installArtifact(desktop);
        b.step("desktop", "Build zmcp-desktop").dependOn(&b.addInstallArtifact(desktop, .{}).step);
        const desktop_tests = b.addTest(.{ .root_module = desktop.root_module });
        const run_desktop_tests = b.addRunArtifact(desktop_tests);
        test_step.dependOn(&run_desktop_tests.step);
        b.step("test-desktop", "Run zmcp-desktop tests").dependOn(&run_desktop_tests.step);
    }

    const mcp_tests = b.addTest(.{ .root_module = mcp_mod });
    const run_mcp_tests = b.addRunArtifact(mcp_tests);
    test_step.dependOn(&run_mcp_tests.step);
}
