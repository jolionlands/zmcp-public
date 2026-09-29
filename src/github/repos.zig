//! Toolsets: context, repos, git, users, orgs, stargazers.

const std = @import("std");
const core = @import("core.zig");
const Call = core.Call;
const T = core.T;
const S = core.S;
const OR = core.OR;
const PG = core.PG;

const repo_spec = "full_name,description~200,visibility,private,fork,archived,default_branch,language,stargazers_count>stars,forks_count>forks,open_issues_count>open_issues,topics,html_url>url,pushed_at";
const repo_min = "full_name,description~150,stargazers_count>stars,language,html_url>url";
const commit_spec = "sha,commit.message~200>message,commit.author.name>author,commit.author.date>date,author.login>login,html_url>url";
const release_spec = "tag_name,name,draft,prerelease,published_at,author.login>author,html_url>url";

// ---------------------------------------------------------------------------
// context
// ---------------------------------------------------------------------------

fn getMe(c: *Call) ![]const u8 {
    const v = try c.get("/user");
    return c.obj(v, "login,name,html_url>url,email,company,location,bio~300,public_repos,followers,following,created_at,plan.name>plan");
}

fn getTeams(c: *Call) ![]const u8 {
    if (c.opt("user")) |u| {
        if (!core.validSlug(u)) return core.fail(c.alloc, "invalid 'user'", .{});
        const vars = try std.fmt.allocPrint(c.alloc, "{{\"login\":\"{s}\"}}", .{u});
        const d = try c.graphql("query($login:String!){user(login:$login){organizations(first:20){nodes{login teams(first:50,userLogins:[$login]){nodes{slug name}}}}}}", vars);
        const w = try core.Out.init(c.alloc);
        try w.js.write(d);
        return w.text();
    }
    const p = c.paging();
    var q = c.pq();
    const v = try c.get(c.path("/user/teams{s}", .{q.done()}));
    return c.list(v, "slug,name,organization.login>org,description~100,privacy,html_url>url", p);
}

fn getTeamMembers(c: *Call) ![]const u8 {
    const org = try c.ownerKey("org");
    const slug = try c.slug("team_slug");
    const p = c.paging();
    var q = c.pq();
    const v = try c.get(c.path("/orgs/{s}/teams/{s}/members{s}", .{ org, slug, q.done() }));
    return c.list(v, "login,html_url>url", p);
}

// ---------------------------------------------------------------------------
// repos: reads
// ---------------------------------------------------------------------------

const MAX_INLINE_FILE: usize = 1 << 20;

fn stripSlashes(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, "/");
}

fn refOrSha(c: *Call) !?[]const u8 {
    if (try c.optSha("sha")) |s| return s;
    return try c.optRef("ref");
}

fn getFileContents(c: *Call) ![]const u8 {
    const o = try c.owner();
    const r = try c.repo();
    const path = stripSlashes(c.opt("path") orelse "");
    if (path.len > 0 and !core.validPath(path)) return core.fail(c.alloc, "invalid 'path': repository-relative path without '..', leading '/' or ?#%\\", .{});
    var q = c.q();
    q.s("ref", try refOrSha(c));
    const v = try c.get(c.path("/repos/{s}/{s}/contents/{s}{s}", .{ o, r, core.encPath(c.alloc, path), q.done() }));
    if (v == .array) {
        var spec: []const u8 = "name,type,size,path";
        if (c.raw("fields")) |f| if (f == .array and f.array.items.len > 0) {
            const allowed = [_][]const u8{ "type", "name", "path", "size", "sha", "url", "git_url", "html_url", "download_url" };
            var parts: std.ArrayList([]const u8) = .empty;
            for (f.array.items) |x| {
                if (x != .string) continue;
                for (allowed) |a| if (std.mem.eql(u8, a, x.string)) try parts.append(c.alloc, a);
            }
            if (parts.items.len > 0) spec = try std.mem.join(c.alloc, ",", parts.items);
        };
        return c.arr(v, spec);
    }
    if (v != .object) return core.fail(c.alloc, "unexpected contents response", .{});
    const typ = if (v.object.get("type")) |t| (if (t == .string) t.string else "") else "";
    const head = try c.obj(v, "path,type,sha,size,target,html_url>url");
    if (!std.mem.eql(u8, typ, "file")) return head;
    const size: usize = if (v.object.get("size")) |s| (if (s == .integer and s.integer >= 0) @intCast(s.integer) else 0) else 0;
    const enc_v = if (v.object.get("content")) |x| (if (x == .string) x.string else "") else "";
    const dl = if (v.object.get("download_url")) |x| (if (x == .string) x.string else "") else "";
    if (size > MAX_INLINE_FILE or (enc_v.len == 0 and size > 0)) {
        return std.fmt.allocPrint(c.alloc, "{s}\n[file too large to inline ({d} bytes, cap {d}); download_url: {s}]", .{ head, size, MAX_INLINE_FILE, dl });
    }
    const clean = try c.alloc.alloc(u8, enc_v.len);
    var n: usize = 0;
    for (enc_v) |ch| if (ch != '\n' and ch != '\r') {
        clean[n] = ch;
        n += 1;
    };
    const dec = std.base64.standard.Decoder;
    const out_len = dec.calcSizeForSlice(clean[0..n]) catch return core.fail(c.alloc, "file content is not valid base64", .{});
    const data = try c.alloc.alloc(u8, out_len);
    dec.decode(data, clean[0..n]) catch return core.fail(c.alloc, "file content is not valid base64", .{});
    if (isBinary(data)) return std.fmt.allocPrint(c.alloc, "{s}\n[binary file, {d} bytes, not shown; download_url: {s}]", .{ head, data.len, dl });
    const cap = core.MAX_OUT - 1024;
    if (data.len > cap) {
        var cut: usize = cap;
        while (cut > 0 and (data[cut] & 0xC0) == 0x80) cut -= 1;
        return std.fmt.allocPrint(c.alloc, "{s}\n{s}\n[truncated: showing {d} of {d} bytes]", .{ head, data[0..cut], cut, data.len });
    }
    return std.fmt.allocPrint(c.alloc, "{s}\n{s}", .{ head, data });
}

pub fn isBinary(data: []const u8) bool {
    const probe = data[0..@min(data.len, 8000)];
    if (std.mem.indexOfScalar(u8, probe, 0) != null) return true;
    if (!std.unicode.utf8ValidateSlice(data)) return true;
    return false;
}

fn listBranches(c: *Call) ![]const u8 {
    const o = try c.owner();
    const r = try c.repo();
    const p = c.paging();
    var q = c.pq();
    const v = try c.get(c.path("/repos/{s}/{s}/branches{s}", .{ o, r, q.done() }));
    return c.list(v, "name,protected,commit.sha>sha", p);
}

fn listCommits(c: *Call) ![]const u8 {
    const o = try c.owner();
    const r = try c.repo();
    const p = c.paging();
    var q = c.pq();
    if (c.opt("sha")) |s| {
        if (!core.validRef(s)) return core.fail(c.alloc, "invalid 'sha'", .{});
        q.s("sha", s);
    }
    if (c.opt("path")) |pa| {
        if (!core.validPath(pa)) return core.fail(c.alloc, "invalid 'path'", .{});
        q.s("path", pa);
    }
    q.s("author", try c.text("author", 200));
    q.s("since", try c.text("since", 40));
    q.s("until", try c.text("until", 40));
    const v = try c.get(c.path("/repos/{s}/{s}/commits{s}", .{ o, r, q.done() }));
    return c.list(v, commit_spec, p);
}

fn getCommit(c: *Call) ![]const u8 {
    const o = try c.owner();
    const r = try c.repo();
    const s = try c.ref("sha");
    const detail = (try c.oneOf("detail", &.{ "none", "stats", "full_patch" })) orelse "stats";
    const p = c.paging();
    var q = c.pq();
    const v = try c.get(c.path("/repos/{s}/{s}/commits/{s}{s}", .{ o, r, core.enc(c.alloc, s), q.done() }));
    const head = try c.obj(v, "sha,commit.message~B>message,commit.author.name>author,commit.author.date>date,author.login>login,stats.total>total,stats.additions>additions,stats.deletions>deletions,html_url>url");
    if (std.mem.eql(u8, detail, "none")) return head;
    const files = if (v == .object) v.object.get("files") else null;
    const spec = if (std.mem.eql(u8, detail, "full_patch")) "filename,status,additions,deletions,patch~4000" else "filename,status,additions,deletions";
    const fl = try c.arr(files orelse .null, spec);
    return c.withHint(try std.fmt.allocPrint(c.alloc, "{s}\nfiles: {s}", .{ head, fl }), p);
}

fn listTags(c: *Call) ![]const u8 {
    const o = try c.owner();
    const r = try c.repo();
    const p = c.paging();
    var q = c.pq();
    const v = try c.get(c.path("/repos/{s}/{s}/tags{s}", .{ o, r, q.done() }));
    return c.list(v, "name,commit.sha>sha", p);
}

fn getTag(c: *Call) ![]const u8 {
    const o = try c.owner();
    const r = try c.repo();
    const tag = try c.ref("tag");
    const ref = try c.get(c.path("/repos/{s}/{s}/git/ref/tags/{s}", .{ o, r, core.encPath(c.alloc, tag) }));
    const ot = if (ref == .object) ref.object.get("object") else null;
    const sha = if (ot) |x| (if (x == .object) (if (x.object.get("sha")) |s| (if (s == .string) s.string else "") else "") else "") else "";
    const typ = if (ot) |x| (if (x == .object) (if (x.object.get("type")) |s| (if (s == .string) s.string else "") else "") else "") else "";
    if (std.mem.eql(u8, typ, "tag") and core.validSha(sha)) {
        const t = try c.get(c.path("/repos/{s}/{s}/git/tags/{s}", .{ o, r, sha }));
        return c.obj(t, "tag,sha,message~B,tagger.name>tagger,tagger.date>date,object.type>target_type,object.sha>target_sha");
    }
    return std.fmt.allocPrint(c.alloc, "{{\"tag\":\"{s}\",\"lightweight\":true,\"target_sha\":\"{s}\",\"target_type\":\"{s}\"}}", .{ tag, sha, typ });
}

fn listReleases(c: *Call) ![]const u8 {
    const o = try c.owner();
    const r = try c.repo();
    const p = c.paging();
    var q = c.pq();
    const v = try c.get(c.path("/repos/{s}/{s}/releases{s}", .{ o, r, q.done() }));
    return c.list(v, release_spec ++ ",body~300", p);
}

fn getLatestRelease(c: *Call) ![]const u8 {
    const v = try c.get(c.path("/repos/{s}/{s}/releases/latest", .{ try c.owner(), try c.repo() }));
    return std.mem.concat(c.alloc, u8, &.{ try c.obj(v, release_spec ++ ",body~B,assets[].name>assets"), core.UNTRUSTED });
}

fn getReleaseByTag(c: *Call) ![]const u8 {
    const o = try c.owner();
    const r = try c.repo();
    const tag = try c.ref("tag");
    const v = try c.get(c.path("/repos/{s}/{s}/releases/tags/{s}", .{ o, r, core.encPath(c.alloc, tag) }));
    return std.mem.concat(c.alloc, u8, &.{ try c.obj(v, release_spec ++ ",body~B,assets[].name>assets"), core.UNTRUSTED });
}

fn listCollaborators(c: *Call) ![]const u8 {
    const o = try c.owner();
    const r = try c.repo();
    const p = c.paging();
    var q = c.pq();
    q.s("affiliation", try c.oneOf("affiliation", &.{ "outside", "direct", "all" }));
    const v = try c.get(c.path("/repos/{s}/{s}/collaborators{s}", .{ o, r, q.done() }));
    return c.list(v, "login,role_name>role", p);
}

// ---------------------------------------------------------------------------
// repos: writes
// ---------------------------------------------------------------------------

fn createBranch(c: *Call) ![]const u8 {
    try c.gate(.write, "create_branch");
    const o = try c.owner();
    const r = try c.repo();
    const branch = try c.ref("branch");
    var from: []const u8 = undefined;
    if (try c.optRef("from_branch")) |f| {
        from = f;
    } else {
        const rv = try c.get(c.path("/repos/{s}/{s}", .{ o, r }));
        from = if (rv == .object) (if (rv.object.get("default_branch")) |d| (if (d == .string) d.string else "main") else "main") else "main";
        if (!core.validRef(from)) return core.fail(c.alloc, "repository default branch name is not a safe ref", .{});
    }
    const fr = try c.get(c.path("/repos/{s}/{s}/git/ref/heads/{s}", .{ o, r, core.encPath(c.alloc, from) }));
    const sha = refSha(fr) orelse return core.fail(c.alloc, "could not resolve source branch '{s}'", .{from});
    const b = try core.Out.init(c.alloc);
    try b.obj();
    try b.kv("ref", try std.fmt.allocPrint(c.alloc, "refs/heads/{s}", .{branch}));
    try b.kv("sha", sha);
    try b.end();
    const res = try c.json(.POST, c.path("/repos/{s}/{s}/git/refs", .{ o, r }), b.text());
    return c.obj(res, "ref,object.sha>sha");
}

fn refSha(v: std.json.Value) ?[]const u8 {
    if (v != .object) return null;
    const ob = v.object.get("object") orelse return null;
    if (ob != .object) return null;
    const s = ob.object.get("sha") orelse return null;
    return if (s == .string) s.string else null;
}

const MAX_WRITE_BYTES: usize = 4 << 20;

fn createOrUpdateFile(c: *Call) ![]const u8 {
    try c.gate(.write, "create_or_update_file");
    const o = try c.owner();
    const r = try c.repo();
    const path = try c.pathArg("path");
    const content = c.opt("content") orelse "";
    if (!c.has("content")) return core.fail(c.alloc, "missing required parameter 'content'", .{});
    if (content.len > MAX_WRITE_BYTES) return core.fail(c.alloc, "content too large (cap {d} bytes)", .{MAX_WRITE_BYTES});
    const message = try c.reqText("message", 2000);
    const branch = try c.ref("branch");
    const sha = try c.optSha("sha");
    const b64 = try c.alloc.alloc(u8, std.base64.standard.Encoder.calcSize(content.len));
    _ = std.base64.standard.Encoder.encode(b64, content);
    const b = try core.Out.init(c.alloc);
    try b.obj();
    try b.kv("message", message);
    try b.kv("content", b64);
    try b.kv("branch", branch);
    try b.kvo("sha", sha);
    try b.end();
    const res = try c.json(.PUT, c.path("/repos/{s}/{s}/contents/{s}", .{ o, r, core.encPath(c.alloc, path) }), b.text());
    return c.obj(res, "content.path>path,content.sha>sha,commit.sha>commit,commit.html_url>url");
}

fn deleteFile(c: *Call) ![]const u8 {
    try c.gate(.destructive, "delete_file");
    const o = try c.owner();
    const r = try c.repo();
    const path = try c.pathArg("path");
    const message = try c.reqText("message", 2000);
    const branch = try c.ref("branch");
    const enc_path = core.encPath(c.alloc, path);
    const cur = try c.get(c.path("/repos/{s}/{s}/contents/{s}?ref={s}", .{ o, r, enc_path, core.enc(c.alloc, branch) }));
    const fsha = if (cur == .object) (if (cur.object.get("sha")) |s| (if (s == .string) s.string else "") else "") else "";
    if (!core.validSha(fsha)) return core.fail(c.alloc, "'{s}' is not a file on branch '{s}'", .{ path, branch });
    const b = try core.Out.init(c.alloc);
    try b.obj();
    try b.kv("message", message);
    try b.kv("sha", fsha);
    try b.kv("branch", branch);
    try b.end();
    const res = try c.json(.DELETE, c.path("/repos/{s}/{s}/contents/{s}", .{ o, r, enc_path }), b.text());
    return c.obj(res, "commit.sha>commit,commit.html_url>url");
}

fn pushFiles(c: *Call) ![]const u8 {
    try c.gate(.write, "push_files");
    const o = try c.owner();
    const r = try c.repo();
    const branch = try c.ref("branch");
    const message = try c.reqText("message", 2000);
    const files = c.raw("files") orelse return core.fail(c.alloc, "missing required parameter 'files'", .{});
    if (files != .array or files.array.items.len == 0 or files.array.items.len > 100) return core.fail(c.alloc, "'files' must be an array of 1-100 {{path,content}} objects", .{});
    var total: usize = 0;
    for (files.array.items) |f| {
        if (f != .object) return core.fail(c.alloc, "each file must be an object with path and content", .{});
        const p = f.object.get("path") orelse return core.fail(c.alloc, "file entry missing 'path'", .{});
        const ct = f.object.get("content") orelse return core.fail(c.alloc, "file entry missing 'content'", .{});
        if (p != .string or ct != .string or !core.validPath(p.string)) return core.fail(c.alloc, "invalid file entry (path must be a safe relative path, content a string)", .{});
        total += ct.string.len;
    }
    if (total > MAX_WRITE_BYTES) return core.fail(c.alloc, "files too large (cap {d} bytes total)", .{MAX_WRITE_BYTES});
    const eb = core.encPath(c.alloc, branch);
    const ref = try c.get(c.path("/repos/{s}/{s}/git/ref/heads/{s}", .{ o, r, eb }));
    const head_sha = refSha(ref) orelse return core.fail(c.alloc, "branch '{s}' not found", .{branch});
    const commit = try c.get(c.path("/repos/{s}/{s}/git/commits/{s}", .{ o, r, head_sha }));
    const base_tree = if (commit == .object) (if (commit.object.get("tree")) |t| (if (t == .object) (if (t.object.get("sha")) |s| (if (s == .string) s.string else "") else "") else "") else "") else "";
    if (!core.validSha(base_tree)) return core.fail(c.alloc, "could not read base tree", .{});
    const tb = try core.Out.init(c.alloc);
    try tb.obj();
    try tb.kv("base_tree", base_tree);
    try tb.js.objectField("tree");
    try tb.js.beginArray();
    for (files.array.items) |f| {
        try tb.obj();
        try tb.kv("path", f.object.get("path").?.string);
        try tb.kv("mode", "100644");
        try tb.kv("type", "blob");
        try tb.kv("content", f.object.get("content").?.string);
        try tb.end();
    }
    try tb.js.endArray();
    try tb.end();
    const tree = try c.json(.POST, c.path("/repos/{s}/{s}/git/trees", .{ o, r }), tb.text());
    const tree_sha = if (tree == .object) (if (tree.object.get("sha")) |s| (if (s == .string) s.string else "") else "") else "";
    if (!core.validSha(tree_sha)) return core.fail(c.alloc, "tree creation returned no sha", .{});
    const cb = try core.Out.init(c.alloc);
    try cb.obj();
    try cb.kv("message", message);
    try cb.kv("tree", tree_sha);
    try cb.kv("parents", &[_][]const u8{head_sha});
    try cb.end();
    const nc = try c.json(.POST, c.path("/repos/{s}/{s}/git/commits", .{ o, r }), cb.text());
    const nsha = if (nc == .object) (if (nc.object.get("sha")) |s| (if (s == .string) s.string else "") else "") else "";
    if (!core.validSha(nsha)) return core.fail(c.alloc, "commit creation returned no sha", .{});
    const ub = try std.fmt.allocPrint(c.alloc, "{{\"sha\":\"{s}\",\"force\":false}}", .{nsha});
    _ = try c.ok(.PATCH, c.path("/repos/{s}/{s}/git/refs/heads/{s}", .{ o, r, eb }), ub, core.accept_json);
    return std.fmt.allocPrint(c.alloc, "{{\"commit\":\"{s}\",\"branch\":\"{s}\",\"files\":{d}}}", .{ nsha, branch, files.array.items.len });
}

fn createRepository(c: *Call) ![]const u8 {
    try c.gate(.write, "create_repository");
    const name = try c.slug("name");
    const b = try core.Out.init(c.alloc);
    try b.obj();
    try b.kv("name", name);
    try b.kvo("description", try c.text("description", 1000));
    try b.kvo("private", c.boolean("private"));
    try b.kvo("auto_init", c.boolean("autoInit"));
    try b.end();
    const target = if (c.opt("organization")) |org| blk: {
        if (!core.validOwner(org)) return core.fail(c.alloc, "invalid 'organization'", .{});
        break :blk c.path("/orgs/{s}/repos", .{org});
    } else "/user/repos";
    const v = try c.json(.POST, target, b.text());
    return c.obj(v, "full_name,private,html_url>url,default_branch");
}

fn forkRepository(c: *Call) ![]const u8 {
    try c.gate(.write, "fork_repository");
    const o = try c.owner();
    const r = try c.repo();
    const b = try core.Out.init(c.alloc);
    try b.obj();
    if (c.opt("organization")) |org| {
        if (!core.validOwner(org)) return core.fail(c.alloc, "invalid 'organization'", .{});
        try b.kv("organization", org);
    }
    try b.end();
    const v = try c.json(.POST, c.path("/repos/{s}/{s}/forks", .{ o, r }), b.text());
    const res = try c.obj(v, "full_name,html_url>url,default_branch");
    return std.fmt.allocPrint(c.alloc, "{s}\n(fork creation is asynchronous; it may take a moment to appear)", .{res});
}

fn deleteRepository(c: *Call) ![]const u8 {
    try c.gate(.destructive, "delete_repository");
    const o = try c.owner();
    const r = try c.repo();
    _ = try c.ok(.DELETE, c.path("/repos/{s}/{s}", .{ o, r }), null, core.accept_json);
    return std.fmt.allocPrint(c.alloc, "deleted {s}/{s}", .{ o, r });
}

// ---------------------------------------------------------------------------
// search
// ---------------------------------------------------------------------------

fn searchQuery(c: *Call, path: []const u8, extra_q: ?[]const u8) ![]const u8 {
    const query = try c.reqText("query", 1000);
    const full = if (extra_q) |e| try std.fmt.allocPrint(c.alloc, "{s} {s}", .{ query, e }) else query;
    var q = c.pq();
    q.s("q", full);
    q.s("sort", try c.text("sort", 40));
    q.s("order", try c.oneOf("order", &.{ "asc", "desc" }));
    return c.path("{s}{s}", .{ path, q.done() });
}

fn searchRepositories(c: *Call) ![]const u8 {
    const p = c.paging();
    const v = try c.get(try searchQuery(c, "/search/repositories", null));
    const minimal = c.boolean("minimal_output") orelse true;
    return c.search(v, if (minimal) repo_min else repo_spec, p);
}

fn searchCode(c: *Call) ![]const u8 {
    const p = c.paging();
    const target = try searchQuery(c, "/search/code", null);
    const body = try c.ok(.GET, target, null, "application/vnd.github.text-match+json");
    const v = try c.parse(body);
    return c.search(v, "path,repository.full_name>repo,html_url>url,text_matches[].fragment~240>matches", p);
}

fn searchCommits(c: *Call) ![]const u8 {
    const p = c.paging();
    const v = try c.get(try searchQuery(c, "/search/commits", null));
    return c.search(v, "sha,commit.message~150>message,commit.author.date>date,author.login>login,repository.full_name>repo,html_url>url", p);
}

fn searchUsers(c: *Call) ![]const u8 {
    const p = c.paging();
    const v = try c.get(try searchQuery(c, "/search/users", null));
    return c.search(v, "login,type,html_url>url", p);
}

fn searchOrgs(c: *Call) ![]const u8 {
    const p = c.paging();
    const v = try c.get(try searchQuery(c, "/search/users", "type:org"));
    return c.search(v, "login,html_url>url", p);
}

// ---------------------------------------------------------------------------
// git + stargazers
// ---------------------------------------------------------------------------

fn getRepositoryTree(c: *Call) ![]const u8 {
    const o = try c.owner();
    const r = try c.repo();
    var tree_ref: []const u8 = undefined;
    if (try c.optRef("tree_sha")) |t| {
        tree_ref = t;
    } else {
        const rv = try c.get(c.path("/repos/{s}/{s}", .{ o, r }));
        tree_ref = if (rv == .object) (if (rv.object.get("default_branch")) |d| (if (d == .string) d.string else "HEAD") else "HEAD") else "HEAD";
        if (!core.validRef(tree_ref)) return core.fail(c.alloc, "default branch name is not a safe ref", .{});
    }
    const recursive = c.boolean("recursive") orelse false;
    const filter = c.opt("path_filter");
    if (filter) |f| if (!core.validText(f, 500)) return core.fail(c.alloc, "invalid 'path_filter'", .{});
    const v = try c.get(c.path("/repos/{s}/{s}/git/trees/{s}{s}", .{ o, r, core.encPath(c.alloc, tree_ref), if (recursive) "?recursive=1" else "" }));
    const tree = if (v == .object) v.object.get("tree") else null;
    var out: std.ArrayList(u8) = .empty;
    var n: usize = 0;
    const cap: usize = 2000;
    if (tree) |t| if (t == .array) for (t.array.items) |e| {
        if (e != .object) continue;
        const pth = if (e.object.get("path")) |x| (if (x == .string) x.string else "") else "";
        if (filter) |f| if (!std.mem.startsWith(u8, pth, f)) continue;
        if (n >= cap) {
            n += 1;
            continue;
        }
        const ty = if (e.object.get("type")) |x| (if (x == .string) x.string else "") else "";
        const sz = if (e.object.get("size")) |x| (if (x == .integer) x.integer else -1) else -1;
        if (sz >= 0) {
            try out.print(c.alloc, "{s} {s} {d}\n", .{ ty, pth, sz });
        } else try out.print(c.alloc, "{s} {s}\n", .{ ty, pth });
        n += 1;
    };
    if (n > cap) try out.print(c.alloc, "[{d} more entries omitted: use path_filter or recursive=false]\n", .{n - cap});
    if (v == .object) if (v.object.get("truncated")) |t| if (t == .bool and t.bool) try out.appendSlice(c.alloc, "[GitHub truncated this tree: use path_filter/non-recursive listing]\n");
    if (out.items.len == 0) return "(no entries)";
    return out.items;
}

fn listStarred(c: *Call) ![]const u8 {
    const p = c.paging();
    var q = c.pq();
    q.s("sort", try c.oneOf("sort", &.{ "created", "updated" }));
    q.s("direction", try c.oneOf("direction", &.{ "asc", "desc" }));
    const target = if (c.opt("username")) |u| blk: {
        if (!core.validSlug(u)) return core.fail(c.alloc, "invalid 'username'", .{});
        break :blk c.path("/users/{s}/starred{s}", .{ u, q.done() });
    } else c.path("/user/starred{s}", .{q.done()});
    const v = try c.get(target);
    return c.list(v, repo_min, p);
}

fn starRepository(c: *Call) ![]const u8 {
    try c.gate(.write, "star_repository");
    const o = try c.owner();
    const r = try c.repo();
    _ = try c.ok(.PUT, c.path("/user/starred/{s}/{s}", .{ o, r }), null, core.accept_json);
    return std.fmt.allocPrint(c.alloc, "starred {s}/{s}", .{ o, r });
}

fn unstarRepository(c: *Call) ![]const u8 {
    try c.gate(.write, "unstar_repository");
    const o = try c.owner();
    const r = try c.repo();
    _ = try c.ok(.DELETE, c.path("/user/starred/{s}/{s}", .{ o, r }), null, core.accept_json);
    return std.fmt.allocPrint(c.alloc, "unstarred {s}/{s}", .{ o, r });
}

// ---------------------------------------------------------------------------
// table
// ---------------------------------------------------------------------------

const Q1 = "\"query\":{\"type\":\"string\"},\"sort\":{\"type\":\"string\"},\"order\":{\"type\":\"string\",\"enum\":[\"asc\",\"desc\"]}," ++ PG;

pub const tools = [_]core.Tool{
    T("context", "get_me", "Get the authenticated user's profile.", "{\"type\":\"object\",\"properties\":{}}", getMe, .ro),
    T("context", "get_teams", "List teams of the authenticated user (or of `user`).", S("\"user\":{\"type\":\"string\"}," ++ PG, ""), getTeams, .ro),
    T("context", "get_team_members", "List members of an org team.", S("\"org\":{\"type\":\"string\"},\"team_slug\":{\"type\":\"string\"}," ++ PG, "\"org\",\"team_slug\""), getTeamMembers, .ro),

    T("repos", "get_file_contents", "Get a file's text or a directory listing (ref/sha optional).", S(OR ++ ",\"path\":{\"type\":\"string\"},\"ref\":{\"type\":\"string\"},\"sha\":{\"type\":\"string\"},\"fields\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}", "\"owner\",\"repo\""), getFileContents, .ro),
    T("repos", "list_branches", "List branches.", S(OR ++ "," ++ PG, "\"owner\",\"repo\""), listBranches, .ro),
    T("repos", "list_commits", "List commits of a branch/sha, optionally by path/author/date.", S(OR ++ ",\"sha\":{\"type\":\"string\"},\"path\":{\"type\":\"string\"},\"author\":{\"type\":\"string\"},\"since\":{\"type\":\"string\"},\"until\":{\"type\":\"string\"}," ++ PG, "\"owner\",\"repo\""), listCommits, .ro),
    T("repos", "get_commit", "Get a commit; detail=none|stats|full_patch.", S(OR ++ ",\"sha\":{\"type\":\"string\"},\"detail\":{\"type\":\"string\",\"enum\":[\"none\",\"stats\",\"full_patch\"]}," ++ PG ++ "," ++ core.MC, "\"owner\",\"repo\",\"sha\""), getCommit, .ro),
    T("repos", "list_tags", "List tags.", S(OR ++ "," ++ PG, "\"owner\",\"repo\""), listTags, .ro),
    T("repos", "get_tag", "Get a tag's details.", S(OR ++ ",\"tag\":{\"type\":\"string\"}," ++ core.MC, "\"owner\",\"repo\",\"tag\""), getTag, .ro),
    T("repos", "list_releases", "List releases.", S(OR ++ "," ++ PG, "\"owner\",\"repo\""), listReleases, .ro),
    T("repos", "get_latest_release", "Get the latest release.", S(OR ++ "," ++ core.MC, "\"owner\",\"repo\""), getLatestRelease, .ro),
    T("repos", "get_release_by_tag", "Get a release by tag name.", S(OR ++ ",\"tag\":{\"type\":\"string\"}," ++ core.MC, "\"owner\",\"repo\",\"tag\""), getReleaseByTag, .ro),
    T("repos", "list_repository_collaborators", "List collaborators.", S(OR ++ ",\"affiliation\":{\"type\":\"string\",\"enum\":[\"outside\",\"direct\",\"all\"]}," ++ PG, "\"owner\",\"repo\""), listCollaborators, .ro),
    T("repos", "search_repositories", "Search repositories (GitHub search syntax).", S(Q1 ++ ",\"minimal_output\":{\"type\":\"boolean\"}", "\"query\""), searchRepositories, .ro),
    T("repos", "search_code", "Search code (GitHub search syntax).", S(Q1, "\"query\""), searchCode, .ro),
    T("repos", "search_commits", "Search commits.", S(Q1, "\"query\""), searchCommits, .ro),
    T("repos", "create_branch", "Create a branch from from_branch (default: default branch).", S(OR ++ ",\"branch\":{\"type\":\"string\"},\"from_branch\":{\"type\":\"string\"}", "\"owner\",\"repo\",\"branch\""), createBranch, .add),
    T("repos", "create_or_update_file", "Create or update one file in a commit (sha required to update).", S(OR ++ ",\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"},\"message\":{\"type\":\"string\"},\"branch\":{\"type\":\"string\"},\"sha\":{\"type\":\"string\"}", "\"owner\",\"repo\",\"path\",\"content\",\"message\",\"branch\""), createOrUpdateFile, .add),
    T("repos", "delete_file", "Delete a file in a commit. DESTRUCTIVE.", S(OR ++ ",\"path\":{\"type\":\"string\"},\"message\":{\"type\":\"string\"},\"branch\":{\"type\":\"string\"}", "\"owner\",\"repo\",\"path\",\"message\",\"branch\""), deleteFile, .destructive),
    T("repos", "push_files", "Commit several files to a branch in one commit.", S(OR ++ ",\"branch\":{\"type\":\"string\"},\"message\":{\"type\":\"string\"},\"files\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]}}", "\"owner\",\"repo\",\"branch\",\"files\",\"message\""), pushFiles, .add),
    T("repos", "create_repository", "Create a repository (additive).", S("\"name\":{\"type\":\"string\"},\"description\":{\"type\":\"string\"},\"private\":{\"type\":\"boolean\"},\"autoInit\":{\"type\":\"boolean\"},\"organization\":{\"type\":\"string\"}", "\"name\""), createRepository, .add),
    T("repos", "fork_repository", "Fork a repository (additive).", S(OR ++ ",\"organization\":{\"type\":\"string\"}", "\"owner\",\"repo\""), forkRepository, .add),
    T("repos", "delete_repository", "Delete a repository permanently. DESTRUCTIVE.", S(OR, "\"owner\",\"repo\""), deleteRepository, .destructive),

    T("git", "get_repository_tree", "List a repo tree (`type path [size]` lines).", S(OR ++ ",\"tree_sha\":{\"type\":\"string\"},\"recursive\":{\"type\":\"boolean\"},\"path_filter\":{\"type\":\"string\"}", "\"owner\",\"repo\""), getRepositoryTree, .ro),

    T("users", "search_users", "Search users.", S(Q1, "\"query\""), searchUsers, .ro),
    T("orgs", "search_orgs", "Search organizations.", S(Q1, "\"query\""), searchOrgs, .ro),

    T("stargazers", "list_starred_repositories", "List repos starred by you or `username`.", S("\"username\":{\"type\":\"string\"},\"sort\":{\"type\":\"string\",\"enum\":[\"created\",\"updated\"]},\"direction\":{\"type\":\"string\",\"enum\":[\"asc\",\"desc\"]}," ++ PG, ""), listStarred, .ro),
    T("stargazers", "star_repository", "Star a repository.", S(OR, "\"owner\",\"repo\""), starRepository, .add),
    T("stargazers", "unstar_repository", "Unstar a repository.", S(OR, "\"owner\",\"repo\""), unstarRepository, .add),
};

test "repos tools compile and table is well-formed" {
    inline for (tools) |t| {
        try std.testing.expect(t.def.name.len > 0);
        try std.testing.expect(!(t.def.read_only and t.def.destructive));
    }
}
