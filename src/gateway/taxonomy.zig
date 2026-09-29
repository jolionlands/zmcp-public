//! Static tool taxonomy: category + tags per zmcp server, keyed by server
//! name. The gateway assigns these itself so no server needs an edit; an
//! unknown server (a new build, a third-party binary) falls back to a
//! category guessed from its name.

const std = @import("std");

/// The fixed category set. Keep it small: it is the first thing a model sees
/// in the categories overview.
pub const Category = enum {
    @"web-search",
    docs,
    code,
    vcs,
    data,
    files,
    memory,
    infra,
    comms,
    media,
    time,
    utility,

    pub fn text(self: Category) []const u8 {
        return @tagName(self);
    }

    pub fn parse(s: []const u8) ?Category {
        inline for (@typeInfo(Category).@"enum".fields) |f| {
            if (std.ascii.eqlIgnoreCase(f.name, s)) return @field(Category, f.name);
        }
        return null;
    }
};

pub const all_categories = blk: {
    const fields = @typeInfo(Category).@"enum".fields;
    var out: [fields.len]Category = undefined;
    for (fields, 0..) |f, i| out[i] = @field(Category, f.name);
    break :blk out;
};

pub const Assignment = struct {
    category: Category,
    /// Extra search vocabulary for the server's tools.
    tags: []const []const u8,
};

const Row = struct { server: []const u8, category: Category, tags: []const []const u8 };

const table = [_]Row{
    .{ .server = "datetime", .category = .time, .tags = &.{ "clock", "now", "timestamp", "date" } },
    .{ .server = "time", .category = .time, .tags = &.{ "timezone", "convert", "clock" } },
    .{ .server = "todo", .category = .utility, .tags = &.{ "tasks", "checklist", "scratchpad" } },
    .{ .server = "tickets", .category = .utility, .tags = &.{ "sprint", "issues", "tasks", "tracker" } },
    .{ .server = "hn", .category = .comms, .tags = &.{ "hacker", "news", "threads", "stories" } },
    .{ .server = "web-search", .category = .@"web-search", .tags = &.{ "google", "duckduckgo", "internet", "query" } },
    .{ .server = "websearch-apis", .category = .@"web-search", .tags = &.{ "tavily", "exa", "firecrawl", "scrape", "crawl" } },
    .{ .server = "fetch", .category = .@"web-search", .tags = &.{ "http", "download", "url", "scrape", "page" } },
    .{ .server = "freejobs", .category = .@"web-search", .tags = &.{ "jobs", "careers", "hiring" } },
    .{ .server = "rss", .category = .@"web-search", .tags = &.{ "feeds", "news", "atom", "subscribe" } },
    .{ .server = "social", .category = .comms, .tags = &.{ "reddit", "twitter", "posts", "social" } },
    .{ .server = "wiki", .category = .docs, .tags = &.{ "wikipedia", "encyclopedia", "reference", "articles" } },
    .{ .server = "arxiv", .category = .docs, .tags = &.{ "papers", "research", "academic", "preprints" } },
    .{ .server = "mslearn", .category = .docs, .tags = &.{ "microsoft", "azure", "learn", "documentation" } },
    .{ .server = "context7", .category = .docs, .tags = &.{ "library", "documentation", "api", "reference" } },
    .{ .server = "zig-docs", .category = .docs, .tags = &.{ "zig", "stdlib", "documentation", "language" } },
    .{ .server = "tldr", .category = .docs, .tags = &.{ "commands", "cheatsheet", "man", "cli", "examples" } },
    .{ .server = "zig-packages", .category = .code, .tags = &.{ "zig", "packages", "dependencies", "zon" } },
    .{ .server = "package-registry", .category = .code, .tags = &.{ "npm", "pypi", "crates", "packages", "dependencies", "versions" } },
    .{ .server = "compiler-explorer", .category = .code, .tags = &.{ "compile", "assembly", "godbolt", "compiler" } },
    .{ .server = "ast-grep", .category = .code, .tags = &.{ "ast", "refactor", "structural", "syntax", "rewrite" } },
    .{ .server = "ripgrep", .category = .code, .tags = &.{ "grep", "search", "regex", "text", "files" } },
    .{ .server = "git", .category = .vcs, .tags = &.{ "commit", "branch", "diff", "log", "repository" } },
    .{ .server = "github", .category = .vcs, .tags = &.{ "pull", "request", "issues", "repository", "review" } },
    .{ .server = "fs", .category = .files, .tags = &.{ "filesystem", "directory", "path", "read", "write" } },
    .{ .server = "memory", .category = .memory, .tags = &.{ "knowledge", "graph", "entities", "notes", "remember" } },
    .{ .server = "hippo", .category = .memory, .tags = &.{ "graph", "temporal", "knowledge", "remember" } },
    .{ .server = "sqlite", .category = .data, .tags = &.{ "sql", "database", "query", "tables" } },
    .{ .server = "duckdb", .category = .data, .tags = &.{ "sql", "database", "analytics", "csv", "parquet" } },
    .{ .server = "jq", .category = .data, .tags = &.{ "json", "query", "filter", "validate", "format" } },
    .{ .server = "redis", .category = .data, .tags = &.{ "cache", "keyvalue", "database", "keys" } },
    .{ .server = "huggingface", .category = .data, .tags = &.{ "models", "datasets", "ml", "machine", "learning" } },
    .{ .server = "docker", .category = .infra, .tags = &.{ "containers", "images", "compose", "volumes" } },
    .{ .server = "kubernetes", .category = .infra, .tags = &.{ "k8s", "cluster", "pods", "deployments", "kubectl" } },
    .{ .server = "diff-render", .category = .media, .tags = &.{ "diff", "render", "html", "patch" } },
    .{ .server = "markdown-render", .category = .media, .tags = &.{ "markdown", "render", "html", "preview" } },
    .{ .server = "ai-elements", .category = .media, .tags = &.{ "ui", "components", "render", "elements" } },
    .{ .server = "minimax", .category = .media, .tags = &.{ "image", "video", "speech", "audio", "generate" } },
    .{ .server = "blender", .category = .media, .tags = &.{ "3d", "modeling", "scene", "render" } },
    .{ .server = "weather", .category = .utility, .tags = &.{ "forecast", "temperature", "climate", "alerts" } },
    .{ .server = "currency", .category = .utility, .tags = &.{ "exchange", "rates", "convert", "money", "fx" } },
    .{ .server = "sequentialthinking", .category = .utility, .tags = &.{ "reasoning", "planning", "steps", "thoughts" } },
    .{ .server = "computer", .category = .utility, .tags = &.{ "desktop", "mouse", "keyboard", "screenshot", "automation" } },
    .{ .server = "desktop", .category = .utility, .tags = &.{ "windows", "ui", "automation", "accessibility" } },
};

const Guess = struct { needle: []const u8, category: Category };

const guesses = [_]Guess{
    .{ .needle = "search", .category = .@"web-search" },
    .{ .needle = "web", .category = .@"web-search" },
    .{ .needle = "doc", .category = .docs },
    .{ .needle = "wiki", .category = .docs },
    .{ .needle = "git", .category = .vcs },
    .{ .needle = "sql", .category = .data },
    .{ .needle = "db", .category = .data },
    .{ .needle = "redis", .category = .data },
    .{ .needle = "data", .category = .data },
    .{ .needle = "fs", .category = .files },
    .{ .needle = "file", .category = .files },
    .{ .needle = "mem", .category = .memory },
    .{ .needle = "docker", .category = .infra },
    .{ .needle = "kube", .category = .infra },
    .{ .needle = "cloud", .category = .infra },
    .{ .needle = "mail", .category = .comms },
    .{ .needle = "chat", .category = .comms },
    .{ .needle = "slack", .category = .comms },
    .{ .needle = "image", .category = .media },
    .{ .needle = "render", .category = .media },
    .{ .needle = "time", .category = .time },
    .{ .needle = "date", .category = .time },
    .{ .needle = "code", .category = .code },
    .{ .needle = "lint", .category = .code },
    .{ .needle = "grep", .category = .code },
};

/// Category and tags for `server`: the static table, else a category guessed
/// from the name (default `utility`) and no extra tags.
pub fn forServer(server: []const u8) Assignment {
    for (table) |r| {
        if (std.mem.eql(u8, r.server, server)) return .{ .category = r.category, .tags = r.tags };
    }
    return .{ .category = guessCategory(server), .tags = &.{} };
}

pub fn guessCategory(server: []const u8) Category {
    for (guesses) |g| {
        if (std.ascii.indexOfIgnoreCase(server, g.needle) != null) return g.category;
    }
    return .utility;
}

test "every table row names a distinct server" {
    for (table, 0..) |a, i| {
        for (table[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a.server, b.server));
    }
}

test "forServer uses the table and falls back to a name-based guess" {
    try std.testing.expectEqual(Category.vcs, forServer("git").category);
    try std.testing.expectEqual(Category.infra, forServer("docker").category);
    try std.testing.expect(forServer("git").tags.len > 0);
    // Not in the table: guessed from the name.
    try std.testing.expectEqual(Category.@"web-search", forServer("my-search-thing").category);
    try std.testing.expectEqual(Category.data, forServer("postgres-db").category);
    try std.testing.expectEqual(Category.utility, forServer("zzz").category);
    try std.testing.expectEqual(@as(usize, 0), forServer("zzz").tags.len);
}

test "Category.parse is case-insensitive and rejects unknown names" {
    try std.testing.expectEqual(Category.@"web-search", Category.parse("Web-Search").?);
    try std.testing.expect(Category.parse("nope") == null);
    try std.testing.expectEqual(@as(usize, 12), all_categories.len);
}
