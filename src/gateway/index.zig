//! In-memory inverted index over the exposed tools, with BM25-style ranking.
//!
//! Built once at startup from a `View` (so tools hidden by the slice are
//! never indexed and can never show up in results). Fields feed one posting
//! list per term with field weights: name x5, description x2, server x2,
//! category/tags x1 (shared by a whole server, so weak). Query words also match term prefixes (at half weight),
//! and name hits get extra boosts so `git_commit` beats a description that
//! merely mentions committing.

const std = @import("std");
const mcp = @import("mcp");
const catalog = @import("catalog.zig");
const taxonomy = @import("taxonomy.zig");
const view_mod = @import("view.zig");

pub const Category = taxonomy.Category;

const W_NAME: u32 = 5;
const W_SERVER: u32 = 2;
const W_TAG: u32 = 1; // tags and category: shared by a whole server, so weak
const W_DESC: u32 = 2;
const K1: f32 = 1.2;
const B: f32 = 0.75;
const MAX_QUERY_TOKENS: usize = 16;
const LINE_DESC_CAP: usize = 110;

const Posting = struct { doc: u32, tf: u32 };

pub const Doc = struct {
    name: []const u8,
    server: []const u8,
    category: Category,
    description: []const u8,
    read_only: bool,
    destructive: bool,
    namespaced: bool,
    /// Normalized tokens of `name`, for the name boosts.
    name_tokens: []const []const u8,
};

pub const CategorySummary = struct {
    category: Category,
    tools: usize = 0,
    read_only: usize = 0,
    /// Distinct servers in the category, first-seen order.
    servers: []const []const u8 = &.{},
};

pub const Query = struct {
    text: []const u8 = "",
    category: ?Category = null,
    server: ?[]const u8 = null,
    read_only: ?bool = null,
    limit: usize = 15,
};

pub const Hit = struct { doc: u32, score: f32 };

pub const Index = struct {
    gpa: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    docs: []const Doc = &.{},
    terms: std.StringHashMapUnmanaged([]const Posting) = .empty,
    doc_len: []const f32 = &.{},
    avg_len: f32 = 1,
    summaries: []const CategorySummary = &.{},
    server_count: usize = 0,

    pub fn deinit(self: *Index) void {
        self.arena.deinit();
        self.gpa.destroy(self.arena);
    }

    pub fn build(gpa: std.mem.Allocator, v: *const view_mod.View) !Index {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(gpa);
        var ix: Index = .{ .gpa = gpa, .arena = arena };
        errdefer ix.deinit();
        const a = arena.allocator();

        var docs = try a.alloc(Doc, v.exposed.len);
        var lens = try a.alloc(f32, v.exposed.len);
        var lists: std.StringHashMapUnmanaged(std.ArrayList(Posting)) = .empty;
        var total_len: f32 = 0;

        for (v.exposed, 0..) |e, di| {
            var toks: std.ArrayList([]const u8) = .empty;
            try tokenize(a, e.name, &toks);
            docs[di] = .{
                .name = e.name,
                .server = e.server,
                .category = e.tool.category,
                .description = e.tool.description,
                .read_only = e.tool.read_only,
                .destructive = e.tool.destructive,
                .namespaced = e.namespaced,
                .name_tokens = toks.items,
            };

            // Weighted term frequencies for this doc.
            var tf: std.StringHashMapUnmanaged(u32) = .empty;
            var len: u32 = 0;
            const fields = [_]struct { text: []const u8, w: u32 }{
                .{ .text = e.tool.name, .w = W_NAME },
                .{ .text = e.server, .w = W_SERVER },
                .{ .text = e.tool.category.text(), .w = W_TAG },
                .{ .text = e.tool.description, .w = W_DESC },
            };
            for (fields) |f| try addField(a, &tf, &len, f.text, f.w);
            for (e.tool.tags) |tg| try addField(a, &tf, &len, tg, W_TAG);

            var it = tf.iterator();
            while (it.next()) |kv| {
                const g = try lists.getOrPut(a, kv.key_ptr.*);
                if (!g.found_existing) g.value_ptr.* = .empty;
                try g.value_ptr.append(a, .{ .doc = @intCast(di), .tf = kv.value_ptr.* });
            }
            lens[di] = @floatFromInt(@max(len, 1));
            total_len += lens[di];
        }

        var lit = lists.iterator();
        while (lit.next()) |kv| try ix.terms.put(a, kv.key_ptr.*, kv.value_ptr.items);

        ix.docs = docs;
        ix.doc_len = lens;
        ix.avg_len = if (docs.len == 0) 1 else total_len / @as(f32, @floatFromInt(docs.len));
        ix.server_count = v.servers.len;

        // Category overview.
        var sums: std.ArrayList(CategorySummary) = .empty;
        for (taxonomy.all_categories) |c| {
            var s: CategorySummary = .{ .category = c };
            var srv: std.ArrayList([]const u8) = .empty;
            for (docs) |d| {
                if (d.category != c) continue;
                s.tools += 1;
                if (d.read_only) s.read_only += 1;
                var seen = false;
                for (srv.items) |x| {
                    if (std.mem.eql(u8, x, d.server)) seen = true;
                }
                if (!seen) try srv.append(a, d.server);
            }
            s.servers = srv.items;
            if (s.tools > 0) try sums.append(a, s);
        }
        ix.summaries = sums.items;
        return ix;
    }

    fn passes(self: *const Index, di: usize, q: Query) bool {
        const d = self.docs[di];
        if (q.category) |c| if (d.category != c) return false;
        if (q.read_only) |ro| if (d.read_only != ro) return false;
        if (q.server) |s| if (!serverMatches(d, s)) return false;
        return true;
    }

    /// Ranked hits (best first, all matches, not truncated to `limit`).
    /// With an empty query text and at least one filter the matches come in
    /// catalog order with score 0. Owned by `a`.
    pub fn search(self: *const Index, a: std.mem.Allocator, q: Query) ![]Hit {
        var toks: std.ArrayList([]const u8) = .empty;
        try tokenize(a, q.text, &toks);
        if (toks.items.len > MAX_QUERY_TOKENS) toks.shrinkRetainingCapacity(MAX_QUERY_TOKENS);

        var hits: std.ArrayList(Hit) = .empty;
        if (toks.items.len == 0) {
            for (0..self.docs.len) |di| {
                if (self.passes(di, q)) try hits.append(a, .{ .doc = @intCast(di), .score = 0 });
            }
            return hits.items;
        }

        const n: f32 = @floatFromInt(self.docs.len);
        const scores = try a.alloc(f32, self.docs.len);
        @memset(scores, 0);
        const matched = try a.alloc(u16, self.docs.len);
        @memset(matched, 0);

        for (toks.items, 0..) |tok, qi| {
            const bit: u16 = @as(u16, 1) << @intCast(qi);
            // Exact term.
            if (self.terms.get(tok)) |plist| self.accumulate(plist, 1.0, n, scores, matched, bit);
            // Prefix expansion ("commit" finds "committed", "doc" finds "docs").
            if (tok.len >= 3) {
                var it = self.terms.iterator();
                while (it.next()) |kv| {
                    const term = kv.key_ptr.*;
                    if (term.len > tok.len and std.mem.startsWith(u8, term, tok)) {
                        self.accumulate(kv.value_ptr.*, 0.5, n, scores, matched, bit);
                    }
                }
            }
        }

        const joined = try joinTokens(a, toks.items);
        for (0..self.docs.len) |di| {
            if (matched[di] == 0 or !self.passes(di, q)) continue;
            const d = self.docs[di];
            var s = scores[di];
            // Name boosts.
            if (std.ascii.eqlIgnoreCase(d.name, q.text) or std.mem.eql(u8, joined, try joinTokens(a, d.name_tokens))) s += 25;
            for (toks.items) |tok| {
                var exact = false;
                var prefix = false;
                for (d.name_tokens) |nt| {
                    if (std.mem.eql(u8, nt, tok)) exact = true else if (tok.len >= 2 and std.mem.startsWith(u8, nt, tok)) prefix = true;
                }
                if (exact) s += 6 else if (prefix) s += 2;
            }
            const cover = @as(f32, @floatFromInt(@popCount(matched[di]))) / @as(f32, @floatFromInt(toks.items.len));
            s *= 0.6 + 0.4 * cover;
            try hits.append(a, .{ .doc = @intCast(di), .score = s });
        }
        std.mem.sort(Hit, hits.items, self, struct {
            fn lt(ix: *const Index, x: Hit, y: Hit) bool {
                if (x.score != y.score) return x.score > y.score;
                return std.mem.lessThan(u8, ix.docs[x.doc].name, ix.docs[y.doc].name);
            }
        }.lt);
        return hits.items;
    }

    fn accumulate(self: *const Index, plist: []const Posting, weight: f32, n: f32, scores: []f32, matched: []u16, bit: u16) void {
        const df: f32 = @floatFromInt(plist.len);
        const idf = @log(1.0 + (n - df + 0.5) / (df + 0.5));
        for (plist) |p| {
            const tf: f32 = @floatFromInt(p.tf);
            const norm = tf * (K1 + 1.0) / (tf + K1 * (1.0 - B + B * self.doc_len[p.doc] / self.avg_len));
            scores[p.doc] += weight * idf * norm;
            matched[p.doc] |= bit;
        }
    }

    // -----------------------------------------------------------------
    // Rendering
    // -----------------------------------------------------------------

    fn writeLine(self: *const Index, out: *std.ArrayList(u8), a: std.mem.Allocator, di: u32) !void {
        const d = self.docs[di];
        try out.appendSlice(a, d.name);
        try out.appendSlice(a, " [");
        try out.appendSlice(a, d.server);
        try out.append(a, '/');
        try out.appendSlice(a, d.category.text());
        if (d.read_only) try out.appendSlice(a, ", ro");
        if (d.destructive) try out.appendSlice(a, ", destructive");
        try out.append(a, ']');
        const desc = mcp.firstSentence(d.description, LINE_DESC_CAP);
        if (desc.len > 0) {
            try out.append(a, ' ');
            try out.appendSlice(a, desc);
        }
        try out.append(a, '\n');
    }

    /// Cheap overview: categories with counts and server names.
    pub fn renderOverview(self: *const Index, a: std.mem.Allocator, label: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.print(a, "{d} tools in {d} servers{s}{s}. Search: tools_search with query words; narrow with category, server, read_only.\n", .{
            self.docs.len,
            self.server_count,
            if (label.len > 0) " of slice " else "",
            label,
        });
        for (self.summaries) |s| {
            try out.print(a, "{s} ({d}", .{ s.category.text(), s.tools });
            if (s.read_only > 0) try out.print(a, ", {d} ro", .{s.read_only});
            try out.appendSlice(a, "): ");
            for (s.servers, 0..) |sv, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try out.appendSlice(a, sv);
            }
            try out.append(a, '\n');
        }
        var ns: usize = 0;
        for (self.docs) |d| {
            if (d.namespaced) ns += 1;
        }
        if (ns > 0) try out.print(a, "note: {d} tool names exist in several servers and are namespaced as server.tool\n", .{ns});
        return std.mem.trimEnd(u8, out.items, "\n");
    }

    /// Ranked (or filtered) results as `name [server/category, ro] description`.
    pub fn renderHits(self: *const Index, a: std.mem.Allocator, hits: []const Hit, q: Query) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        const shown = @min(hits.len, q.limit);
        var any_ns = false;
        for (hits[0..shown]) |h| {
            if (self.docs[h.doc].namespaced) any_ns = true;
        }
        if (any_ns) try out.appendSlice(a, "note: names shown as server.tool exist in several servers; use them exactly\n");
        for (hits[0..shown]) |h| try self.writeLine(&out, a, h.doc);
        if (hits.len > shown) try out.print(a, "... {d} more; raise limit or narrow with category/server\n", .{hits.len - shown});
        return std.mem.trimEnd(u8, out.items, "\n");
    }

    /// No-match message with the way forward.
    pub fn renderNoMatch(self: *const Index, a: std.mem.Allocator, q: Query) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.print(a, "no tools match '{s}'", .{q.text});
        if (q.category != null or q.server != null or q.read_only != null) try out.appendSlice(a, " with those filters");
        try out.appendSlice(a, "; try fewer words or drop filters. categories: ");
        for (self.summaries, 0..) |s, i| {
            if (i > 0) try out.appendSlice(a, ", ");
            try out.print(a, "{s}({d})", .{ s.category.text(), s.tools });
        }
        return out.items;
    }
};

fn serverMatches(d: Doc, want: []const u8) bool {
    return std.ascii.eqlIgnoreCase(d.server, want);
}

fn joinTokens(a: std.mem.Allocator, toks: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (toks, 0..) |t, i| {
        if (i > 0) try out.append(a, '_');
        try out.appendSlice(a, t);
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// Tokenizing
// ---------------------------------------------------------------------------

const stop_words = [_][]const u8{ "the", "a", "an", "of", "to", "for", "and", "or", "in", "on", "with", "by", "is", "it", "this", "that", "from", "as", "at", "be", "are", "any" };

fn isStop(t: []const u8) bool {
    for (stop_words) |s| {
        if (std.mem.eql(u8, s, t)) return true;
    }
    return false;
}

/// Light plural stemming: "issues" -> "issue", "entries" -> "entry".
fn stem(t: []u8) []u8 {
    if (t.len > 4 and std.mem.endsWith(u8, t, "ies")) {
        t[t.len - 3] = 'y';
        return t[0 .. t.len - 2];
    }
    if (t.len > 3 and t[t.len - 1] == 's' and t[t.len - 2] != 's' and t[t.len - 2] != 'u' and t[t.len - 2] != 'i') return t[0 .. t.len - 1];
    return t;
}

/// Lowercased alphanumeric tokens (stemmed, stop words dropped), owned by `a`.
pub fn tokenize(a: std.mem.Allocator, text: []const u8, out: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and !std.ascii.isAlphanumeric(text[i])) i += 1;
        const start = i;
        while (i < text.len and std.ascii.isAlphanumeric(text[i])) i += 1;
        if (i == start) break;
        const buf = try a.alloc(u8, i - start);
        for (text[start..i], 0..) |c, k| buf[k] = std.ascii.toLower(c);
        const t = stem(buf);
        if (t.len == 0 or isStop(t)) continue;
        try out.append(a, t);
    }
}

fn addField(a: std.mem.Allocator, tf: *std.StringHashMapUnmanaged(u32), len: *u32, text: []const u8, w: u32) !void {
    var toks: std.ArrayList([]const u8) = .empty;
    try tokenize(a, text, &toks);
    for (toks.items) |t| {
        const g = try tf.getOrPut(a, t);
        if (g.found_existing) g.value_ptr.* += w else g.value_ptr.* = w;
        len.* += 1;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const catalog_text =
    \\{"version":1,"servers":[
    \\{"name":"git","tools":[
    \\ {"name":"git_commit","description":"Record changes to the repository","category":"vcs","tags":["commit","save"]},
    \\ {"name":"git_log","description":"Show commit history of a branch","readOnly":true,"category":"vcs","tags":["history"]},
    \\ {"name":"git_reset","description":"Reset HEAD; can discard commits","destructive":true,"category":"vcs","tags":[]}]},
    \\{"name":"github","tools":[
    \\ {"name":"list_issues","description":"List issues of a repository","readOnly":true,"category":"vcs","tags":["issues","tracker"]},
    \\ {"name":"create_pull_request","description":"Open a pull request; mentions commit only in passing","category":"vcs","tags":["review"]}]},
    \\{"name":"docker","tools":[
    \\ {"name":"docker_ps","description":"List running containers","readOnly":true,"category":"infra","tags":["containers"]},
    \\ {"name":"docker_rm","description":"Remove containers","destructive":true,"category":"infra","tags":[]}]},
    \\{"name":"memory","tools":[
    \\ {"name":"create_entities","description":"Create entities in the knowledge graph","category":"memory","tags":["remember"]},
    \\ {"name":"search_nodes","description":"Search the knowledge graph for nodes","readOnly":true,"category":"memory","tags":[]}]}
    \\]}
;

const Fixture = struct {
    cat: catalog.Catalog,
    view: view_mod.View,
    ix: Index,

    fn init(alloc: std.mem.Allocator, servers: []const []const u8, slice: @import("profile.zig").Slice) !Fixture {
        var f: Fixture = undefined;
        f.cat = try catalog.parse(alloc, catalog_text);
        errdefer f.cat.deinit();
        f.view = try view_mod.View.build(alloc, &f.cat, servers, slice);
        errdefer f.view.deinit();
        f.ix = try Index.build(alloc, &f.view);
        return f;
    }

    fn deinit(self: *Fixture) void {
        self.ix.deinit();
        self.view.deinit();
        self.cat.deinit();
    }
};

fn topName(f: *const Fixture, a: std.mem.Allocator, q: Query) ![]const u8 {
    const hits = try f.ix.search(a, q);
    if (hits.len == 0) return "";
    return f.ix.docs[hits[0].doc].name;
}

test "tokenize lowercases, splits on punctuation, stems plurals, drops stop words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    try tokenize(arena.allocator(), "List the Open Issues; create_pull_request entries", &out);
    const want = [_][]const u8{ "list", "open", "issue", "create", "pull", "request", "entry" };
    try std.testing.expectEqual(want.len, out.items.len);
    for (want, out.items) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "ranking: a name hit beats a description-only hit" {
    var f = try Fixture.init(std.testing.allocator, &.{ "git", "github", "docker", "memory" }, .{});
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // create_pull_request only mentions "commit" in its description.
    const hits = try f.ix.search(a, .{ .text = "commit" });
    try std.testing.expect(hits.len >= 2);
    try std.testing.expectEqualStrings("git_commit", f.ix.docs[hits[0].doc].name);
    var pos_pr: usize = 99;
    for (hits, 0..) |h, i| {
        if (std.mem.eql(u8, f.ix.docs[h.doc].name, "create_pull_request")) pos_pr = i;
    }
    try std.testing.expect(pos_pr != 99 and pos_pr > 0); // found, but behind the name hit
    try std.testing.expect(hits[0].score > hits[pos_pr].score * 2);
    // Exact name query wins outright.
    try std.testing.expectEqualStrings("docker_ps", try topName(&f, a, .{ .text = "docker_ps" }));
    // Multi-word natural query finds the right tool first.
    try std.testing.expectEqualStrings("list_issues", try topName(&f, a, .{ .text = "list github issues" }));
    // Tags and plural stemming widen recall; prefix expansion helps too.
    try std.testing.expectEqualStrings("docker_ps", try topName(&f, a, .{ .text = "container" }));
    try std.testing.expectEqualStrings("create_entities", try topName(&f, a, .{ .text = "remember entit" }));
}

test "filters: category, server, read_only and limit rendering" {
    var f = try Fixture.init(std.testing.allocator, &.{ "git", "github", "docker", "memory" }, .{});
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const infra = try f.ix.search(a, .{ .text = "list", .category = .infra });
    try std.testing.expectEqual(@as(usize, 1), infra.len);
    try std.testing.expectEqualStrings("docker_ps", f.ix.docs[infra[0].doc].name);

    const srv = try f.ix.search(a, .{ .text = "commit", .server = "GIT" });
    for (srv) |h| try std.testing.expectEqualStrings("git", f.ix.docs[h.doc].server);
    try std.testing.expect(srv.len >= 2);

    const ro = try f.ix.search(a, .{ .text = "list", .read_only = true });
    for (ro) |h| try std.testing.expect(f.ix.docs[h.doc].read_only);
    try std.testing.expectEqual(@as(usize, 2), ro.len);

    const rw = try f.ix.search(a, .{ .read_only = false, .server = "docker" });
    try std.testing.expectEqual(@as(usize, 1), rw.len);
    try std.testing.expectEqualStrings("docker_rm", f.ix.docs[rw[0].doc].name);

    // No text, only a filter: catalog order.
    const vcs = try f.ix.search(a, .{ .category = .vcs });
    try std.testing.expectEqual(@as(usize, 5), vcs.len);
    try std.testing.expectEqualStrings("git_commit", f.ix.docs[vcs[0].doc].name);

    const text = try f.ix.renderHits(a, vcs, .{ .limit = 2 });
    try std.testing.expect(std.mem.indexOf(u8, text, "git_commit [git/vcs] Record changes to the repository\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "git_log [git/vcs, ro] Show commit history of a branch") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "... 3 more") != null);
    const destructive = try f.ix.renderHits(a, try f.ix.search(a, .{ .text = "reset" }), .{});
    try std.testing.expect(std.mem.indexOf(u8, destructive, "git_reset [git/vcs, destructive]") != null);
}

test "no-query overview lists categories with counts and server names" {
    var f = try Fixture.init(std.testing.allocator, &.{ "git", "github", "docker", "memory" }, .{});
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try f.ix.renderOverview(arena.allocator(), "dev");
    try std.testing.expect(std.mem.indexOf(u8, text, "9 tools in 4 servers of slice dev") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "vcs (5, 2 ro): git, github\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "infra (2, 1 ro): docker") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "memory (2, 1 ro): memory") != null);
    // Empty categories are not listed.
    try std.testing.expect(std.mem.indexOf(u8, text, "media") == null);
}

test "index stays consistent under slicing: hidden tools never appear anywhere" {
    const profile = @import("profile.zig");
    var f = try Fixture.init(std.testing.allocator, &.{ "git", "github", "docker", "memory" }, .{ .deny = &.{ "git_reset", "docker_rm" }, .allow = &.{ "git_*", "docker_*", "list_*" } });
    defer f.deinit();
    _ = profile;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(usize, 4), f.ix.docs.len); // commit, log, ps, list_issues
    for ([_][]const u8{ "reset", "git_reset", "remove", "docker_rm", "entities", "graph", "pull request", "discard" }) |q| {
        const hits = try f.ix.search(a, .{ .text = q });
        for (hits) |h| {
            const n = f.ix.docs[h.doc].name;
            try std.testing.expect(!std.mem.eql(u8, n, "git_reset"));
            try std.testing.expect(!std.mem.eql(u8, n, "docker_rm"));
            try std.testing.expect(!std.mem.eql(u8, n, "create_entities"));
            try std.testing.expect(!std.mem.eql(u8, n, "create_pull_request"));
        }
    }
    // Hidden category does not appear in the overview either.
    const ov = try f.ix.renderOverview(a, "");
    try std.testing.expect(std.mem.indexOf(u8, ov, "memory (") == null);
    try std.testing.expect(std.mem.indexOf(u8, ov, "4 tools in 4 servers") != null);
    // A term that exists only in hidden tools has no postings at all.
    try std.testing.expect(f.ix.terms.get("graph") == null);
    try std.testing.expect(f.ix.terms.get("reset") == null);
}

test "namespaced collisions are flagged in results" {
    const alloc = std.testing.allocator;
    var cat = try catalog.parse(alloc, view_mod.test_catalog_text);
    defer cat.deinit();
    var v = try view_mod.View.build(alloc, &cat, &.{ "git", "docker" }, .{});
    defer v.deinit();
    var ix = try Index.build(alloc, &v);
    defer ix.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const hits = try ix.search(a, .{ .text = "status" });
    const text = try ix.renderHits(a, hits, .{});
    try std.testing.expect(std.mem.indexOf(u8, text, "git.status [git/vcs, ro]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "docker.status [docker/infra, ro]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "several servers") != null);
}

test "no match message points at categories; empty index is safe" {
    var f = try Fixture.init(std.testing.allocator, &.{ "git", "docker" }, .{});
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hits = try f.ix.search(a, .{ .text = "zzzzqqqq" });
    try std.testing.expectEqual(@as(usize, 0), hits.len);
    const msg = try f.ix.renderNoMatch(a, .{ .text = "zzzzqqqq" });
    try std.testing.expect(std.mem.indexOf(u8, msg, "vcs(3)") != null);

    var empty = try Fixture.init(std.testing.allocator, &.{"memory"}, .{ .readonly = true });
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try empty.ix.search(a, .{ .text = "anything" })).len);
    _ = try empty.ix.renderOverview(a, "");
}
