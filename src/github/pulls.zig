//! Toolsets: pull_requests, copilot (review request only).

const std = @import("std");
const core = @import("core.zig");
const issues = @import("issues.zig");
const Call = core.Call;
const T = core.T;
const S = core.S;
const OR = core.OR;
const PG = core.PG;

const pr_row = "number,title,state,draft,user.login>user,head.ref>head,base.ref>base,merged_at,labels[].name>labels,updated_at,html_url>url";
const pr_one = "number,title,state,draft,merged,mergeable,mergeable_state,user.login>user,head.ref>head,head.sha>head_sha,base.ref>base,labels[].name>labels,requested_reviewers[].login>reviewers,assignees[].login>assignees,commits,additions,deletions,changed_files,comments,review_comments,created_at,updated_at,merged_at,html_url>url,body~B";
const commit_spec = "sha,commit.message~200>message,commit.author.name>author,commit.author.date>date,html_url>url";

fn prNumber(c: *Call) !i64 {
    const n = try c.reqInt("pullNumber");
    if (n < 1) return core.fail(c.alloc, "'pullNumber' must be >= 1", .{});
    return n;
}

fn nodeId(c: *Call, k: []const u8) ![]const u8 {
    const s = try c.req(k);
    if (s.len > 100) return core.fail(c.alloc, "invalid '{s}'", .{k});
    for (s) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '=')) return core.fail(c.alloc, "invalid '{s}': expected a GraphQL node id", .{k});
    return s;
}

fn strField(v: std.json.Value, path: []const u8) []const u8 {
    var cur = v;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |seg| {
        if (cur != .object) return "";
        cur = cur.object.get(seg) orelse return "";
    }
    return if (cur == .string) cur.string else "";
}

fn headSha(c: *Call, base: []const u8) ![]const u8 {
    const pr = try c.get(base);
    const sha = strField(pr, "head.sha");
    if (!core.validSha(sha)) return core.fail(c.alloc, "could not read the PR head commit", .{});
    return sha;
}

fn listPullRequests(c: *Call) ![]const u8 {
    const o = try c.owner();
    const r = try c.repo();
    const p = c.paging();
    var q = c.pq();
    q.s("state", try c.oneOf("state", &.{ "open", "closed", "all" }));
    q.s("head", try c.text("head", 200));
    q.s("base", try c.text("base", 200));
    q.s("sort", try c.oneOf("sort", &.{ "created", "updated", "popularity", "long-running" }));
    q.s("direction", try c.oneOf("direction", &.{ "asc", "desc" }));
    const v = try c.get(c.path("/repos/{s}/{s}/pulls{s}", .{ o, r, q.done() }));
    return c.list(v, pr_row, p);
}

fn pullRequestRead(c: *Call) ![]const u8 {
    const m = try c.method(&.{ "get", "get_diff", "get_status", "get_files", "get_commits", "get_review_comments", "get_reviews", "get_comments", "get_check_runs" });
    const o = try c.owner();
    const r = try c.repo();
    const n = try prNumber(c);
    const p = c.paging();
    var q = c.pq();
    const base = c.path("/repos/{s}/{s}/pulls/{d}", .{ o, r, n });
    if (std.mem.eql(u8, m, "get")) {
        const v = try c.get(base);
        return std.mem.concat(c.alloc, u8, &.{ try c.obj(v, pr_one), core.UNTRUSTED });
    }
    if (std.mem.eql(u8, m, "get_diff")) {
        const d = try c.ok(.GET, base, null, core.accept_diff);
        if (d.len > core.MAX_OUT) return std.fmt.allocPrint(c.alloc, "{s}\n...[diff truncated at 64 KiB of {d} bytes: use pull_request_read get_files, or get_file_contents with ref for one file]", .{ d[0..core.MAX_OUT], d.len });
        return d;
    }
    if (std.mem.eql(u8, m, "get_status")) {
        const sha = try headSha(c, base);
        const v = try c.get(c.path("/repos/{s}/{s}/commits/{s}/status", .{ o, r, sha }));
        const head = try c.obj(v, "state,sha,total_count");
        var lines: std.ArrayList(u8) = .empty;
        try lines.appendSlice(c.alloc, head);
        if (v == .object) if (v.object.get("statuses")) |ss| if (ss == .array) for (ss.array.items) |s| {
            try lines.print(c.alloc, "\n{s}: {s}", .{ strField(s, "context"), strField(s, "state") });
        };
        return lines.items;
    }
    if (std.mem.eql(u8, m, "get_files")) {
        const v = try c.get(c.path("{s}/files{s}", .{ base, q.done() }));
        return c.list(v, "filename,status,additions,deletions,changes,previous_filename", p);
    }
    if (std.mem.eql(u8, m, "get_commits")) {
        const v = try c.get(c.path("{s}/commits{s}", .{ base, q.done() }));
        return c.list(v, commit_spec, p);
    }
    if (std.mem.eql(u8, m, "get_reviews")) {
        if (!c.has("max_chars")) c.max_chars = 800;
        const v = try c.get(c.path("{s}/reviews{s}", .{ base, q.done() }));
        return std.mem.concat(c.alloc, u8, &.{ try c.list(v, "id,user.login>user,state,submitted_at,commit_id>sha,html_url>url,body~B", p), core.UNTRUSTED });
    }
    if (std.mem.eql(u8, m, "get_comments")) {
        if (!c.has("max_chars")) c.max_chars = 800;
        const v = try c.get(c.path("/repos/{s}/{s}/issues/{d}/comments{s}", .{ o, r, n, q.done() }));
        return std.mem.concat(c.alloc, u8, &.{ try c.list(v, "id,user.login>user,created_at,html_url>url,body~B", p), core.UNTRUSTED });
    }
    if (std.mem.eql(u8, m, "get_check_runs")) {
        const sha = try headSha(c, base);
        const v = try c.get(c.path("/repos/{s}/{s}/commits/{s}/check-runs{s}", .{ o, r, sha, q.done() }));
        return c.searchKey(v, "check_runs", "id,name,status,conclusion,html_url>url,completed_at", p);
    }
    return reviewThreads(c, o, r, n);
}

fn reviewThreads(c: *Call, o: []const u8, r: []const u8, n: i64) ![]const u8 {
    const p = c.paging();
    if (!c.has("max_chars")) c.max_chars = 600;
    const vars = try core.Out.init(c.alloc);
    try vars.obj();
    try vars.kv("o", o);
    try vars.kv("r", r);
    try vars.kv("n", n);
    try vars.kv("per", p.per);
    try vars.kvo("after", c.opt("after"));
    try vars.end();
    const d = try c.graphql(
        "query($o:String!,$r:String!,$n:Int!,$per:Int!,$after:String){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:$per,after:$after){totalCount pageInfo{hasNextPage endCursor} nodes{id isResolved isOutdated path line startLine originalLine diffSide comments(first:30){nodes{databaseId author{login} body createdAt url}}}}}}}",
        vars.text(),
    );
    const rt = dig(d, &.{ "repository", "pullRequest", "reviewThreads" }) orelse return core.fail(c.alloc, "pull request not found", .{});
    const o2 = try core.Out.init(c.alloc);
    try o2.js.beginArray();
    if (rt == .object) if (rt.object.get("nodes")) |nodes| if (nodes == .array) for (nodes.array.items) |t| {
        try o2.js.beginObject();
        try core.writeFields(c, &o2.js, t, "id,isResolved,isOutdated,path,line,startLine,originalLine,diffSide");
        try o2.js.objectField("comments");
        try o2.js.beginArray();
        if (dig(t, &.{ "comments", "nodes" })) |cn| if (cn == .array) for (cn.array.items) |cm| {
            try core.writeSpec(c, &o2.js, cm, "databaseId>id,author.login>user,createdAt>at,url,body~B");
        };
        try o2.js.endArray();
        try o2.js.endObject();
    };
    try o2.js.endArray();
    var out = o2.text();
    if (dig(rt, &.{"pageInfo"})) |pi| if (pi == .object) {
        const more = if (pi.object.get("hasNextPage")) |h| (h == .bool and h.bool) else false;
        if (more) out = try std.fmt.allocPrint(c.alloc, "{s}\n[more threads: after={s} (perPage={d})]", .{ out, strField(pi, "endCursor"), p.per });
    };
    return std.mem.concat(c.alloc, u8, &.{ out, core.UNTRUSTED });
}

fn dig(v: std.json.Value, path: []const []const u8) ?std.json.Value {
    var cur = v;
    for (path) |seg| {
        if (cur != .object) return null;
        cur = cur.object.get(seg) orelse return null;
        if (cur == .null) return null;
    }
    return cur;
}

fn requestReviewers(c: *Call, o: []const u8, r: []const u8, n: i64) !void {
    const rv = try c.strList("reviewers");
    if (rv.len == 0) return;
    for (rv) |u| if (!core.validSlug(u)) return core.fail(c.alloc, "invalid reviewer login '{s}'", .{u});
    const b = try core.Out.init(c.alloc);
    try b.obj();
    try b.kv("reviewers", rv);
    try b.end();
    _ = try c.ok(.POST, c.path("/repos/{s}/{s}/pulls/{d}/requested_reviewers", .{ o, r, n }), b.text(), core.accept_json);
}

fn validHead(s: []const u8) bool {
    if (s.len == 0 or s.len > 200 or s[0] == '-' or std.mem.indexOf(u8, s, "..") != null) return false;
    for (s) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '/' or ch == ':')) return false;
    return true;
}

fn createPullRequest(c: *Call) ![]const u8 {
    try c.gate(.write, "create_pull_request");
    const o = try c.owner();
    const r = try c.repo();
    const title = try c.reqText("title", 256);
    const head = try c.req("head");
    if (!validHead(head)) return core.fail(c.alloc, "invalid 'head': expected branch or user:branch", .{});
    const base = try c.ref("base");
    const b = try core.Out.init(c.alloc);
    try b.obj();
    try b.kv("title", title);
    try b.kv("head", head);
    try b.kv("base", base);
    try b.kvo("body", try c.text("body", 65536));
    try b.kvo("draft", c.boolean("draft"));
    try b.kvo("maintainer_can_modify", c.boolean("maintainer_can_modify"));
    try b.end();
    const v = try c.json(.POST, c.path("/repos/{s}/{s}/pulls", .{ o, r }), b.text());
    const num: i64 = if (v == .object) (if (v.object.get("number")) |x| (if (x == .integer) x.integer else 0) else 0) else 0;
    if (num > 0) try requestReviewers(c, o, r, num);
    return c.obj(v, "number,title,state,draft,html_url>url");
}

fn updatePullRequest(c: *Call) ![]const u8 {
    try c.gate(.write, "update_pull_request");
    const o = try c.owner();
    const r = try c.repo();
    const n = try prNumber(c);
    const b = try core.Out.init(c.alloc);
    try b.obj();
    try b.kvo("title", try c.text("title", 256));
    try b.kvo("body", try c.text("body", 65536));
    if (c.opt("base")) |bs| {
        if (!core.validRef(bs)) return core.fail(c.alloc, "invalid 'base'", .{});
        try b.kv("base", bs);
    }
    try b.kvo("state", try c.oneOf("state", &.{ "open", "closed" }));
    try b.kvo("maintainer_can_modify", c.boolean("maintainer_can_modify"));
    try b.end();
    const v = try c.json(.PATCH, c.path("/repos/{s}/{s}/pulls/{d}", .{ o, r, n }), b.text());
    try requestReviewers(c, o, r, n);
    if (c.boolean("draft")) |want| {
        const cur = if (v == .object) (if (v.object.get("draft")) |d| (d == .bool and d.bool) else false) else false;
        if (want != cur) {
            const id = strField(v, "node_id");
            if (id.len == 0) return core.fail(c.alloc, "PR node id missing; cannot change draft state", .{});
            const q = if (want)
                "mutation($id:ID!){convertPullRequestToDraft(input:{pullRequestId:$id}){pullRequest{isDraft}}}"
            else
                "mutation($id:ID!){markPullRequestReadyForReview(input:{pullRequestId:$id}){pullRequest{isDraft}}}";
            _ = try c.graphql(q, try std.fmt.allocPrint(c.alloc, "{{\"id\":\"{s}\"}}", .{id}));
        }
    }
    return c.obj(v, "number,title,state,draft,html_url>url");
}

fn mergePullRequest(c: *Call) ![]const u8 {
    try c.gate(.destructive, "merge_pull_request");
    const o = try c.owner();
    const r = try c.repo();
    const n = try prNumber(c);
    const b = try core.Out.init(c.alloc);
    try b.obj();
    try b.kvo("commit_title", try c.text("commit_title", 256));
    try b.kvo("commit_message", try c.text("commit_message", 10000));
    try b.kvo("merge_method", try c.oneOf("merge_method", &.{ "merge", "squash", "rebase" }));
    try b.kvo("sha", try c.optSha("expectedHeadSha"));
    try b.end();
    const v = try c.json(.PUT, c.path("/repos/{s}/{s}/pulls/{d}/merge", .{ o, r, n }), b.text());
    return c.obj(v, "merged,sha,message");
}

fn updatePullRequestBranch(c: *Call) ![]const u8 {
    try c.gate(.write, "update_pull_request_branch");
    const o = try c.owner();
    const r = try c.repo();
    const n = try prNumber(c);
    const b = try core.Out.init(c.alloc);
    try b.obj();
    try b.kvo("expected_head_sha", try c.optSha("expectedHeadSha"));
    try b.end();
    const v = try c.json(.PUT, c.path("/repos/{s}/{s}/pulls/{d}/update-branch", .{ o, r, n }), b.text());
    return c.obj(v, "message,url");
}

fn latestPendingReview(c: *Call, o: []const u8, r: []const u8, n: i64) !i64 {
    const v = try c.get(c.path("/repos/{s}/{s}/pulls/{d}/reviews?per_page=100", .{ o, r, n }));
    var id: i64 = 0;
    if (v == .array) for (v.array.items) |rv| {
        if (std.mem.eql(u8, strField(rv, "state"), "PENDING")) {
            if (rv == .object) if (rv.object.get("id")) |x| if (x == .integer) {
                id = x.integer;
            };
        }
    };
    if (id == 0) return core.fail(c.alloc, "no pending review found for the authenticated user on this pull request", .{});
    return id;
}

fn reviewWrite(c: *Call) ![]const u8 {
    try c.gate(.write, "pull_request_review_write");
    const m = try c.method(&.{ "create", "submit_pending", "delete_pending", "resolve_thread", "unresolve_thread" });
    if (std.mem.eql(u8, m, "resolve_thread") or std.mem.eql(u8, m, "unresolve_thread")) {
        const id = try nodeId(c, "threadId");
        const resolve = std.mem.eql(u8, m, "resolve_thread");
        const q = if (resolve)
            "mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{id isResolved}}}"
        else
            "mutation($id:ID!){unresolveReviewThread(input:{threadId:$id}){thread{id isResolved}}}";
        const d = try c.graphql(q, try std.fmt.allocPrint(c.alloc, "{{\"id\":\"{s}\"}}", .{id}));
        _ = d;
        return std.fmt.allocPrint(c.alloc, "thread {s} {s}", .{ id, if (resolve) "resolved" else "unresolved" });
    }
    if (std.mem.eql(u8, m, "delete_pending")) try c.gate(.destructive, "pull_request_review_write delete_pending");
    const o = try c.owner();
    const r = try c.repo();
    const n = try prNumber(c);
    const base = c.path("/repos/{s}/{s}/pulls/{d}/reviews", .{ o, r, n });
    const events = [_][]const u8{ "APPROVE", "REQUEST_CHANGES", "COMMENT" };
    const event = try c.oneOf("event", &events);
    const body = try c.text("body", 65536);
    if (std.mem.eql(u8, m, "create")) {
        const b = try core.Out.init(c.alloc);
        try b.obj();
        try b.kvo("body", body);
        try b.kvo("event", event);
        try b.kvo("commit_id", try c.optSha("commitID"));
        try b.end();
        const v = try c.json(.POST, base, b.text());
        return c.obj(v, "id,state,html_url>url");
    }
    const id = try latestPendingReview(c, o, r, n);
    if (std.mem.eql(u8, m, "delete_pending")) {
        _ = try c.ok(.DELETE, c.path("{s}/{d}", .{ base, id }), null, core.accept_json);
        return "pending review deleted";
    }
    const ev = event orelse return core.fail(c.alloc, "'event' (APPROVE|REQUEST_CHANGES|COMMENT) is required to submit", .{});
    const b = try core.Out.init(c.alloc);
    try b.obj();
    try b.kvo("body", body);
    try b.kv("event", ev);
    try b.end();
    const v = try c.json(.POST, c.path("{s}/{d}/events", .{ base, id }), b.text());
    return c.obj(v, "id,state,html_url>url");
}

fn addCommentToPendingReview(c: *Call) ![]const u8 {
    try c.gate(.write, "add_comment_to_pending_review");
    const o = try c.owner();
    const r = try c.repo();
    const n = try prNumber(c);
    const path = try c.pathArg("path");
    const body = try c.reqText("body", 65536);
    const subject = (try c.oneOf("subjectType", &.{ "FILE", "LINE" })) orelse return core.fail(c.alloc, "missing required parameter 'subjectType' (FILE|LINE)", .{});
    const side = try c.oneOf("side", &.{ "LEFT", "RIGHT" });
    const start_side = try c.oneOf("startSide", &.{ "LEFT", "RIGHT" });
    const qv = try core.Out.init(c.alloc);
    try qv.obj();
    try qv.kv("o", o);
    try qv.kv("r", r);
    try qv.kv("n", n);
    try qv.end();
    const d = try c.graphql("query($o:String!,$r:String!,$n:Int!){viewer{login} repository(owner:$o,name:$r){pullRequest(number:$n){id reviews(last:50,states:PENDING){nodes{id author{login}}}}}}", qv.text());
    const viewer = strField(d, "viewer.login");
    const pr = dig(d, &.{ "repository", "pullRequest" }) orelse return core.fail(c.alloc, "pull request not found", .{});
    var review_id: []const u8 = "";
    if (dig(pr, &.{ "reviews", "nodes" })) |nodes| if (nodes == .array) for (nodes.array.items) |rv| {
        if (std.mem.eql(u8, strField(rv, "author.login"), viewer)) review_id = strField(rv, "id");
    };
    if (review_id.len == 0) return core.fail(c.alloc, "no pending review; create one first with pull_request_review_write method=create (no event)", .{});
    const vars = try core.Out.init(c.alloc);
    try vars.obj();
    try vars.js.objectField("input");
    try vars.obj();
    try vars.kv("pullRequestReviewId", review_id);
    try vars.kv("path", path);
    try vars.kv("body", body);
    try vars.kv("subjectType", subject);
    if (c.int("line")) |l| try vars.kv("line", l);
    try vars.kvo("side", side);
    if (c.int("startLine")) |l| try vars.kv("startLine", l);
    try vars.kvo("startSide", start_side);
    try vars.end();
    try vars.end();
    const res = try c.graphql("mutation($input:AddPullRequestReviewThreadInput!){addPullRequestReviewThread(input:$input){thread{id isResolved}}}", vars.text());
    const tid = strField(res, "addPullRequestReviewThread.thread.id");
    return std.fmt.allocPrint(c.alloc, "{{\"thread\":\"{s}\",\"pending_review\":\"{s}\"}}", .{ tid, review_id });
}

fn addReplyToPullRequestComment(c: *Call) ![]const u8 {
    try c.gate(.write, "add_reply_to_pull_request_comment");
    const o = try c.owner();
    const r = try c.repo();
    const cid = try c.reqInt("commentId");
    if (c.opt("reaction")) |rc| {
        var ok = false;
        for (issues.reactions) |x| if (std.mem.eql(u8, x, rc)) {
            ok = true;
        };
        if (!ok) return core.fail(c.alloc, "invalid 'reaction': +1|-1|laugh|confused|heart|hooray|rocket|eyes", .{});
        const v = try c.json(.POST, c.path("/repos/{s}/{s}/pulls/comments/{d}/reactions", .{ o, r, cid }), try std.fmt.allocPrint(c.alloc, "{{\"content\":\"{s}\"}}", .{rc}));
        return c.obj(v, "id,content");
    }
    const n = try prNumber(c);
    const body = try c.reqText("body", 65536);
    const b = try core.Out.init(c.alloc);
    try b.obj();
    try b.kv("body", body);
    try b.end();
    const v = try c.json(.POST, c.path("/repos/{s}/{s}/pulls/{d}/comments/{d}/replies", .{ o, r, n, cid }), b.text());
    return c.obj(v, "id,html_url>url");
}

fn requestCopilotReview(c: *Call) ![]const u8 {
    try c.gate(.write, "request_copilot_review");
    const o = try c.owner();
    const r = try c.repo();
    const n = try prNumber(c);
    _ = try c.ok(.POST, c.path("/repos/{s}/{s}/pulls/{d}/requested_reviewers", .{ o, r, n }), "{\"reviewers\":[\"copilot-pull-request-reviewer[bot]\"]}", core.accept_json);
    return "Copilot review requested";
}

const PN = "\"pullNumber\":{\"type\":\"number\"}";

pub const tools = [_]core.Tool{
    T("pull_requests", "list_pull_requests", "List pull requests.", S(OR ++ ",\"state\":{\"type\":\"string\",\"enum\":[\"open\",\"closed\",\"all\"]},\"head\":{\"type\":\"string\"},\"base\":{\"type\":\"string\"},\"sort\":{\"type\":\"string\",\"enum\":[\"created\",\"updated\",\"popularity\",\"long-running\"]},\"direction\":{\"type\":\"string\",\"enum\":[\"asc\",\"desc\"]}," ++ PG, "\"owner\",\"repo\""), listPullRequests, .ro),
    T("pull_requests", "pull_request_read", "Read a PR: method=get|get_diff|get_status|get_files|get_commits|get_review_comments|get_reviews|get_comments|get_check_runs.", S("\"method\":{\"type\":\"string\",\"enum\":[\"get\",\"get_diff\",\"get_status\",\"get_files\",\"get_commits\",\"get_review_comments\",\"get_reviews\",\"get_comments\",\"get_check_runs\"]}," ++ OR ++ "," ++ PN ++ "," ++ PG ++ ",\"after\":{\"type\":\"string\"}," ++ core.MC, "\"method\",\"owner\",\"repo\",\"pullNumber\""), pullRequestRead, .ro),
    T("pull_requests", "search_pull_requests", "Search pull requests (scoped to is:pr).", S("\"query\":{\"type\":\"string\"}," ++ OR ++ ",\"sort\":{\"type\":\"string\"},\"order\":{\"type\":\"string\",\"enum\":[\"asc\",\"desc\"]}," ++ PG, "\"query\""), issues.searchPullRequests, .ro),
    T("pull_requests", "create_pull_request", "Open a pull request.", S(OR ++ ",\"title\":{\"type\":\"string\"},\"head\":{\"type\":\"string\"},\"base\":{\"type\":\"string\"},\"body\":{\"type\":\"string\"},\"draft\":{\"type\":\"boolean\"},\"maintainer_can_modify\":{\"type\":\"boolean\"},\"reviewers\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}", "\"owner\",\"repo\",\"title\",\"head\",\"base\""), createPullRequest, .add),
    T("pull_requests", "update_pull_request", "Edit a PR (title, body, state, base, draft, reviewers).", S(OR ++ "," ++ PN ++ ",\"title\":{\"type\":\"string\"},\"body\":{\"type\":\"string\"},\"state\":{\"type\":\"string\",\"enum\":[\"open\",\"closed\"]},\"base\":{\"type\":\"string\"},\"draft\":{\"type\":\"boolean\"},\"maintainer_can_modify\":{\"type\":\"boolean\"},\"reviewers\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}", "\"owner\",\"repo\",\"pullNumber\""), updatePullRequest, .add),
    T("pull_requests", "merge_pull_request", "Merge a PR (irreversible). DESTRUCTIVE.", S(OR ++ "," ++ PN ++ ",\"merge_method\":{\"type\":\"string\",\"enum\":[\"merge\",\"squash\",\"rebase\"]},\"commit_title\":{\"type\":\"string\"},\"commit_message\":{\"type\":\"string\"},\"expectedHeadSha\":{\"type\":\"string\"}", "\"owner\",\"repo\",\"pullNumber\""), mergePullRequest, .destructive),
    T("pull_requests", "update_pull_request_branch", "Merge the base branch into the PR branch.", S(OR ++ "," ++ PN ++ ",\"expectedHeadSha\":{\"type\":\"string\"}", "\"owner\",\"repo\",\"pullNumber\""), updatePullRequestBranch, .add),
    T("pull_requests", "pull_request_review_write", "Review: method=create|submit_pending|delete_pending|resolve_thread|unresolve_thread.", S("\"method\":{\"type\":\"string\",\"enum\":[\"create\",\"submit_pending\",\"delete_pending\",\"resolve_thread\",\"unresolve_thread\"]}," ++ OR ++ "," ++ PN ++ ",\"body\":{\"type\":\"string\"},\"event\":{\"type\":\"string\",\"enum\":[\"APPROVE\",\"REQUEST_CHANGES\",\"COMMENT\"]},\"commitID\":{\"type\":\"string\"},\"threadId\":{\"type\":\"string\"}", "\"method\""), reviewWrite, .destructive),
    T("pull_requests", "add_comment_to_pending_review", "Add a line/file comment to your pending review.", S(OR ++ "," ++ PN ++ ",\"path\":{\"type\":\"string\"},\"body\":{\"type\":\"string\"},\"subjectType\":{\"type\":\"string\",\"enum\":[\"FILE\",\"LINE\"]},\"line\":{\"type\":\"number\"},\"side\":{\"type\":\"string\",\"enum\":[\"LEFT\",\"RIGHT\"]},\"startLine\":{\"type\":\"number\"},\"startSide\":{\"type\":\"string\",\"enum\":[\"LEFT\",\"RIGHT\"]}", "\"owner\",\"repo\",\"pullNumber\",\"path\",\"body\",\"subjectType\""), addCommentToPendingReview, .add),
    T("pull_requests", "add_reply_to_pull_request_comment", "Reply to (or react to) a PR review comment.", S(OR ++ "," ++ PN ++ ",\"commentId\":{\"type\":\"number\"},\"body\":{\"type\":\"string\"},\"reaction\":{\"type\":\"string\"}", "\"owner\",\"repo\",\"commentId\""), addReplyToPullRequestComment, .add),
    T("copilot", "request_copilot_review", "Request a Copilot code review of a PR.", S(OR ++ "," ++ PN, "\"owner\",\"repo\",\"pullNumber\""), requestCopilotReview, .add),
};
