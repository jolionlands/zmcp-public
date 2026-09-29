//! Toolsets: issues, labels.

const std = @import("std");
const core = @import("core.zig");
const Call = core.Call;
const T = core.T;
const S = core.S;
const OR = core.OR;
const PG = core.PG;

const issue_one = "number,title,state,state_reason,user.login>user,labels[].name>labels,assignees[].login>assignees,milestone.title>milestone,comments,created_at,updated_at,closed_at,html_url>url,type.name>type,body~B";
const issue_row = "number,title,state,user.login>user,labels[].name>labels,assignees[].login>assignees,comments,updated_at,html_url>url,body~200";
const comment_spec = "id,user.login>user,created_at,updated_at,html_url>url,body~B";
const label_spec = "name,color,description~120";

pub const reactions = [_][]const u8{ "+1", "-1", "laugh", "confused", "heart", "hooray", "rocket", "eyes" };

fn issueNumber(c: *Call, k: []const u8) !i64 {
    const n = try c.reqInt(k);
    if (n < 1) return core.fail(c.alloc, "'{s}' must be >= 1", .{k});
    return n;
}

fn issueRead(c: *Call) ![]const u8 {
    const m = try c.method(&.{ "get", "get_comments", "get_sub_issues", "get_parent", "get_labels" });
    const o = try c.owner();
    const r = try c.repo();
    const n = try issueNumber(c, "issue_number");
    const p = c.paging();
    var q = c.pq();
    const base = c.path("/repos/{s}/{s}/issues/{d}", .{ o, r, n });
    if (std.mem.eql(u8, m, "get")) {
        const v = try c.get(base);
        return std.mem.concat(c.alloc, u8, &.{ try c.obj(v, issue_one), core.UNTRUSTED });
    }
    if (std.mem.eql(u8, m, "get_comments")) {
        if (!c.has("max_chars")) c.max_chars = 800;
        const v = try c.get(c.path("{s}/comments{s}", .{ base, q.done() }));
        return std.mem.concat(c.alloc, u8, &.{ try c.list(v, comment_spec, p), core.UNTRUSTED });
    }
    if (std.mem.eql(u8, m, "get_sub_issues")) {
        const v = try c.get(c.path("{s}/sub_issues{s}", .{ base, q.done() }));
        return c.list(v, "id,number,title,state,user.login>user,html_url>url", p);
    }
    if (std.mem.eql(u8, m, "get_parent")) {
        const v = try c.get(c.path("{s}/parent", .{base}));
        return c.obj(v, "id,number,title,state,html_url>url");
    }
    const v = try c.get(c.path("{s}/labels{s}", .{ base, q.done() }));
    return c.list(v, label_spec, p);
}

fn labelsBody(c: *Call, b: *core.Out) !void {
    const labels = try c.strList("labels");
    if (c.has("labels")) try b.kv("labels", labels);
    const asg = try c.strList("assignees");
    if (c.has("assignees")) try b.kv("assignees", asg);
}

fn issueWrite(c: *Call) ![]const u8 {
    try c.gate(.write, "issue_write");
    const m = try c.method(&.{ "create", "update" });
    const o = try c.owner();
    const r = try c.repo();
    const b = try core.Out.init(c.alloc);
    try b.obj();
    try b.kvo("title", try c.text("title", 256));
    try b.kvo("body", try c.text("body", 65536));
    try labelsBody(c, b);
    if (c.int("milestone")) |ms| try b.kv("milestone", ms);
    if (c.raw("type")) |t| switch (t) {
        .null => try b.kv("type", null),
        .string => |s| try b.kv("type", s),
        else => return core.fail(c.alloc, "'type' must be a string or null", .{}),
    };
    if (c.has("issue_fields")) return core.fail(c.alloc, "issue_fields is not supported by zmcp-github (preview API); see the parity notes", .{});
    if (std.mem.eql(u8, m, "create")) {
        if (c.opt("title") == null) return core.fail(c.alloc, "missing required parameter 'title'", .{});
        try b.end();
        const v = try c.json(.POST, c.path("/repos/{s}/{s}/issues", .{ o, r }), b.text());
        var res = try c.obj(v, "number,title,state,html_url>url");
        if (c.int("parent_issue_number")) |pn| {
            const po = if (c.opt("parent_owner")) |x| x else o;
            const pr = if (c.opt("parent_repo")) |x| x else r;
            if (!core.validOwner(po) or !core.validRepoName(pr)) return core.fail(c.alloc, "invalid parent_owner/parent_repo", .{});
            const id = if (v == .object) (if (v.object.get("id")) |x| (if (x == .integer) x.integer else 0) else 0) else 0;
            const sb = try std.fmt.allocPrint(c.alloc, "{{\"sub_issue_id\":{d}}}", .{id});
            _ = try c.ok(.POST, c.path("/repos/{s}/{s}/issues/{d}/sub_issues", .{ po, pr, pn }), sb, core.accept_json);
            res = try std.fmt.allocPrint(c.alloc, "{s}\n(attached as sub-issue of {s}/{s}#{d})", .{ res, po, pr, pn });
        }
        return res;
    }
    const n = try issueNumber(c, "issue_number");
    if (try c.oneOf("state", &.{ "open", "closed" })) |st| try b.kv("state", st);
    if (try c.oneOf("state_reason", &.{ "completed", "not_planned", "duplicate", "reopened" })) |sr| try b.kv("state_reason", sr);
    try b.end();
    const v = try c.json(.PATCH, c.path("/repos/{s}/{s}/issues/{d}", .{ o, r, n }), b.text());
    if (c.int("duplicate_of")) |d| {
        const cb = try std.fmt.allocPrint(c.alloc, "{{\"body\":\"Duplicate of #{d}\"}}", .{d});
        _ = try c.ok(.POST, c.path("/repos/{s}/{s}/issues/{d}/comments", .{ o, r, n }), cb, core.accept_json);
    }
    return c.obj(v, "number,title,state,state_reason,html_url>url");
}

fn addIssueComment(c: *Call) ![]const u8 {
    try c.gate(.write, "add_issue_comment");
    const o = try c.owner();
    const r = try c.repo();
    const n = try issueNumber(c, "issue_number");
    const body = try c.text("body", 65536);
    const reaction = c.opt("reaction");
    if (body == null and reaction == null) return core.fail(c.alloc, "provide 'body' (comment) or 'reaction'", .{});
    if (body != null and reaction != null) return core.fail(c.alloc, "'body' and 'reaction' cannot be combined", .{});
    if (reaction) |rc| {
        var ok = false;
        for (reactions) |x| if (std.mem.eql(u8, x, rc)) {
            ok = true;
        };
        if (!ok) return core.fail(c.alloc, "invalid 'reaction': +1|-1|laugh|confused|heart|hooray|rocket|eyes", .{});
        const target = if (c.int("comment_id")) |cid| c.path("/repos/{s}/{s}/issues/comments/{d}/reactions", .{ o, r, cid }) else c.path("/repos/{s}/{s}/issues/{d}/reactions", .{ o, r, n });
        const v = try c.json(.POST, target, try std.fmt.allocPrint(c.alloc, "{{\"content\":\"{s}\"}}", .{rc}));
        return c.obj(v, "id,content");
    }
    const b = try core.Out.init(c.alloc);
    try b.obj();
    try b.kv("body", body.?);
    try b.end();
    const v = try c.json(.POST, c.path("/repos/{s}/{s}/issues/{d}/comments", .{ o, r, n }), b.text());
    return c.obj(v, "id,html_url>url");
}

fn updateIssueComment(c: *Call) ![]const u8 {
    try c.gate(.write, "update_issue_comment");
    const o = try c.owner();
    const r = try c.repo();
    const id = try c.reqInt("comment_id");
    const body = try c.reqText("body", 65536);
    const b = try core.Out.init(c.alloc);
    try b.obj();
    try b.kv("body", body);
    try b.end();
    const v = try c.json(.PATCH, c.path("/repos/{s}/{s}/issues/comments/{d}", .{ o, r, id }), b.text());
    return c.obj(v, "id,html_url>url,updated_at");
}

fn listIssues(c: *Call) ![]const u8 {
    const o = try c.owner();
    const r = try c.repo();
    const p = c.paging();
    var q = c.pq();
    if (try c.oneOf("state", &.{ "OPEN", "CLOSED", "open", "closed" })) |s| q.s("state", try std.ascii.allocLowerString(c.alloc, s)) else q.s("state", "all");
    const labels = try c.strList("labels");
    if (labels.len > 0) q.s("labels", try std.mem.join(c.alloc, ",", labels));
    if (try c.oneOf("orderBy", &.{ "CREATED_AT", "UPDATED_AT", "COMMENTS" })) |ob| {
        q.s("sort", if (std.mem.eql(u8, ob, "CREATED_AT")) "created" else if (std.mem.eql(u8, ob, "UPDATED_AT")) "updated" else "comments");
    }
    if (try c.oneOf("direction", &.{ "ASC", "DESC" })) |d| q.s("direction", try std.ascii.allocLowerString(c.alloc, d));
    q.s("since", try c.text("since", 40));
    const v = try c.get(c.path("/repos/{s}/{s}/issues{s}", .{ o, r, q.done() }));
    // The issues endpoint also returns pull requests; drop them.
    var keep = std.json.Array.init(c.alloc);
    if (v == .array) for (v.array.items) |it| {
        if (it == .object and it.object.contains("pull_request")) continue;
        try keep.append(it);
    };
    return c.list(.{ .array = keep }, issue_row, p);
}

fn searchIssuesLike(c: *Call, scope: []const u8) ![]const u8 {
    const p = c.paging();
    const query = try c.reqText("query", 1000);
    var full: []const u8 = query;
    if (std.mem.indexOf(u8, query, scope) == null) full = try std.fmt.allocPrint(c.alloc, "{s} {s}", .{ full, scope });
    if (c.opt("owner")) |ow| {
        if (!core.validOwner(ow)) return core.fail(c.alloc, "invalid 'owner'", .{});
        if (c.opt("repo")) |rp| {
            if (!core.validRepoName(rp)) return core.fail(c.alloc, "invalid 'repo'", .{});
            full = try std.fmt.allocPrint(c.alloc, "{s} repo:{s}/{s}", .{ full, ow, rp });
        } else full = try std.fmt.allocPrint(c.alloc, "{s} user:{s}", .{ full, ow });
    }
    var q = c.pq();
    q.s("q", full);
    q.s("sort", try c.text("sort", 40));
    q.s("order", try c.oneOf("order", &.{ "asc", "desc" }));
    const v = try c.get(c.path("/search/issues{s}", .{q.done()}));
    return std.mem.concat(c.alloc, u8, &.{ try c.search(v, "number,title,state,draft,user.login>user,labels[].name>labels,comments,updated_at,html_url>url,body~200", p), core.UNTRUSTED });
}

fn searchIssues(c: *Call) ![]const u8 {
    return searchIssuesLike(c, "is:issue");
}

fn subIssueWrite(c: *Call) ![]const u8 {
    try c.gate(.write, "sub_issue_write");
    const m = try c.method(&.{ "add", "remove", "reprioritize" });
    const o = try c.owner();
    const r = try c.repo();
    const n = try issueNumber(c, "issue_number");
    const sid = try c.reqInt("sub_issue_id");
    const base = c.path("/repos/{s}/{s}/issues/{d}", .{ o, r, n });
    const b = try core.Out.init(c.alloc);
    try b.obj();
    try b.kv("sub_issue_id", sid);
    if (std.mem.eql(u8, m, "add")) {
        try b.kvo("replace_parent", c.boolean("replace_parent"));
        try b.end();
        const v = try c.json(.POST, c.path("{s}/sub_issues", .{base}), b.text());
        return c.obj(v, "number,title,state,html_url>url");
    }
    if (std.mem.eql(u8, m, "remove")) {
        try b.end();
        const v = try c.json(.DELETE, c.path("{s}/sub_issue", .{base}), b.text());
        return c.obj(v, "number,title,state,html_url>url");
    }
    if (c.int("after_id")) |a| try b.kv("after_id", a);
    if (c.int("before_id")) |a| try b.kv("before_id", a);
    try b.end();
    const v = try c.json(.PATCH, c.path("{s}/sub_issues/priority", .{base}), b.text());
    return c.obj(v, "number,title,state,html_url>url");
}

fn listIssueTypes(c: *Call) ![]const u8 {
    const o = try c.owner();
    const v = try c.get(c.path("/orgs/{s}/issue-types", .{o}));
    return c.arr(v, "id,name,description~100,is_enabled");
}

fn getLabel(c: *Call) ![]const u8 {
    const o = try c.owner();
    const r = try c.repo();
    const name = try c.reqText("name", 200);
    const v = try c.get(c.path("/repos/{s}/{s}/labels/{s}", .{ o, r, core.enc(c.alloc, name) }));
    return c.obj(v, label_spec);
}

fn listLabel(c: *Call) ![]const u8 {
    const o = try c.owner();
    const r = try c.repo();
    const p = c.paging();
    var q = c.pq();
    const v = try c.get(c.path("/repos/{s}/{s}/labels{s}", .{ o, r, q.done() }));
    return c.list(v, label_spec, p);
}

fn labelWrite(c: *Call) ![]const u8 {
    try c.gate(.write, "label_write");
    const m = try c.method(&.{ "create", "update", "delete" });
    if (std.mem.eql(u8, m, "delete")) try c.gate(.destructive, "label_write delete");
    const o = try c.owner();
    const r = try c.repo();
    const name = try c.reqText("name", 200);
    if (c.opt("color")) |col| {
        if (col.len != 6) return core.fail(c.alloc, "'color' must be a 6-digit hex code without '#'", .{});
        for (col) |ch| if (!std.ascii.isHex(ch)) return core.fail(c.alloc, "'color' must be a 6-digit hex code without '#'", .{});
    }
    const base = c.path("/repos/{s}/{s}/labels", .{ o, r });
    if (std.mem.eql(u8, m, "delete")) {
        _ = try c.ok(.DELETE, c.path("{s}/{s}", .{ base, core.enc(c.alloc, name) }), null, core.accept_json);
        return std.fmt.allocPrint(c.alloc, "deleted label {s}", .{name});
    }
    const b = try core.Out.init(c.alloc);
    try b.obj();
    if (std.mem.eql(u8, m, "create")) {
        if (c.opt("color") == null) return core.fail(c.alloc, "'color' is required for create", .{});
        try b.kv("name", name);
    } else try b.kvo("new_name", try c.text("new_name", 200));
    try b.kvo("color", c.opt("color"));
    try b.kvo("description", try c.text("description", 200));
    try b.end();
    const v = if (std.mem.eql(u8, m, "create"))
        try c.json(.POST, base, b.text())
    else
        try c.json(.PATCH, c.path("{s}/{s}", .{ base, core.enc(c.alloc, name) }), b.text());
    return c.obj(v, label_spec);
}

pub const tools = [_]core.Tool{
    T("issues", "issue_read", "Read an issue: method=get|get_comments|get_sub_issues|get_parent|get_labels.", S("\"method\":{\"type\":\"string\",\"enum\":[\"get\",\"get_comments\",\"get_sub_issues\",\"get_parent\",\"get_labels\"]}," ++ OR ++ ",\"issue_number\":{\"type\":\"number\"}," ++ PG ++ "," ++ core.MC, "\"method\",\"owner\",\"repo\",\"issue_number\""), issueRead, .ro),
    T("issues", "issue_write", "Create or update an issue (method=create|update).", S("\"method\":{\"type\":\"string\",\"enum\":[\"create\",\"update\"]}," ++ OR ++ ",\"issue_number\":{\"type\":\"number\"},\"title\":{\"type\":\"string\"},\"body\":{\"type\":\"string\"},\"assignees\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"labels\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"milestone\":{\"type\":\"number\"},\"state\":{\"type\":\"string\",\"enum\":[\"open\",\"closed\"]},\"state_reason\":{\"type\":\"string\",\"enum\":[\"completed\",\"not_planned\",\"duplicate\",\"reopened\"]},\"duplicate_of\":{\"type\":\"number\"},\"type\":{\"type\":[\"string\",\"null\"]},\"parent_issue_number\":{\"type\":\"number\"},\"parent_owner\":{\"type\":\"string\"},\"parent_repo\":{\"type\":\"string\"}", "\"method\",\"owner\",\"repo\""), issueWrite, .add),
    T("issues", "add_issue_comment", "Comment on (or react to) an issue or pull request.", S(OR ++ ",\"issue_number\":{\"type\":\"number\"},\"body\":{\"type\":\"string\"},\"comment_id\":{\"type\":\"number\"},\"reaction\":{\"type\":\"string\"}", "\"owner\",\"repo\",\"issue_number\""), addIssueComment, .add),
    T("issues", "update_issue_comment", "Edit an issue/PR conversation comment.", S(OR ++ ",\"comment_id\":{\"type\":\"number\"},\"body\":{\"type\":\"string\"}", "\"owner\",\"repo\",\"comment_id\",\"body\""), updateIssueComment, .add),
    T("issues", "list_issues", "List issues (no PRs); state OPEN|CLOSED, labels, orderBy, direction, since.", S(OR ++ ",\"state\":{\"type\":\"string\",\"enum\":[\"OPEN\",\"CLOSED\"]},\"labels\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"orderBy\":{\"type\":\"string\",\"enum\":[\"CREATED_AT\",\"UPDATED_AT\",\"COMMENTS\"]},\"direction\":{\"type\":\"string\",\"enum\":[\"ASC\",\"DESC\"]},\"since\":{\"type\":\"string\"}," ++ PG, "\"owner\",\"repo\""), listIssues, .ro),
    T("issues", "search_issues", "Search issues (GitHub search syntax; scoped to is:issue).", S("\"query\":{\"type\":\"string\"}," ++ OR ++ ",\"sort\":{\"type\":\"string\"},\"order\":{\"type\":\"string\",\"enum\":[\"asc\",\"desc\"]}," ++ PG, "\"query\""), searchIssues, .ro),
    T("issues", "sub_issue_write", "Add, remove or reprioritize a sub-issue.", S("\"method\":{\"type\":\"string\",\"enum\":[\"add\",\"remove\",\"reprioritize\"]}," ++ OR ++ ",\"issue_number\":{\"type\":\"number\"},\"sub_issue_id\":{\"type\":\"number\"},\"replace_parent\":{\"type\":\"boolean\"},\"after_id\":{\"type\":\"number\"},\"before_id\":{\"type\":\"number\"}", "\"method\",\"owner\",\"repo\",\"issue_number\",\"sub_issue_id\""), subIssueWrite, .add),
    T("issues", "list_issue_types", "List issue types of an organization.", S("\"owner\":{\"type\":\"string\"}", "\"owner\""), listIssueTypes, .ro),
    T("issues", "get_label", "Get a repository label.", S(OR ++ ",\"name\":{\"type\":\"string\"}", "\"owner\",\"repo\",\"name\""), getLabel, .ro),
    T("labels", "get_label", "Get a repository label.", S(OR ++ ",\"name\":{\"type\":\"string\"}", "\"owner\",\"repo\",\"name\""), getLabel, .ro),
    T("labels", "list_label", "List repository labels.", S(OR ++ "," ++ PG, "\"owner\",\"repo\""), listLabel, .ro),
    T("labels", "label_write", "Create/update/delete a label (delete is destructive).", S("\"method\":{\"type\":\"string\",\"enum\":[\"create\",\"update\",\"delete\"]}," ++ OR ++ ",\"name\":{\"type\":\"string\"},\"new_name\":{\"type\":\"string\"},\"color\":{\"type\":\"string\"},\"description\":{\"type\":\"string\"}", "\"method\",\"owner\",\"repo\",\"name\""), labelWrite, .destructive),
};

/// Shared with pulls.zig.
pub fn searchPullRequests(c: *Call) ![]const u8 {
    return searchIssuesLike(c, "is:pr");
}
