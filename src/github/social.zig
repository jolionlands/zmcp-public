//! Toolsets: notifications, gists, discussions (GraphQL), projects (Projects v2 REST).

const std = @import("std");
const core = @import("core.zig");
const Call = core.Call;
const T = core.T;
const S = core.S;
const OR = core.OR;
const PG = core.PG;

fn strAt(v: std.json.Value, k: []const u8) []const u8 {
    if (v != .object) return "";
    const x = v.object.get(k) orelse return "";
    return if (x == .string) x.string else "";
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

fn digits(c: *Call, k: []const u8) ![]const u8 {
    const s = try c.req(k);
    if (s.len > 20) return core.fail(c.alloc, "invalid '{s}'", .{k});
    for (s) |ch| if (!std.ascii.isDigit(ch)) return core.fail(c.alloc, "invalid '{s}': expected a numeric id", .{k});
    return s;
}

// ---------------------------------------------------------------------------
// notifications
// ---------------------------------------------------------------------------

const notif_spec = "id,unread,reason,subject.title>title,subject.type>type,repository.full_name>repo,updated_at";

fn listNotifications(c: *Call) ![]const u8 {
    const p = c.paging();
    var q = c.pq();
    if (try c.oneOf("filter", &.{ "default", "include_read_notifications", "only_participating" })) |f| {
        if (std.mem.eql(u8, f, "include_read_notifications")) q.b("all", true);
        if (std.mem.eql(u8, f, "only_participating")) q.b("participating", true);
    }
    q.s("since", try c.text("since", 40));
    q.s("before", try c.text("before", 40));
    const target = if (c.opt("owner") != null or c.opt("repo") != null)
        c.path("/repos/{s}/{s}/notifications{s}", .{ try c.owner(), try c.repo(), q.done() })
    else
        c.path("/notifications{s}", .{q.done()});
    const v = try c.get(target);
    return std.mem.concat(c.alloc, u8, &.{ try c.list(v, notif_spec, p), core.UNTRUSTED });
}

fn getNotificationDetails(c: *Call) ![]const u8 {
    const id = try digits(c, "notificationID");
    const v = try c.get(c.path("/notifications/threads/{s}", .{id}));
    return c.obj(v, notif_spec ++ ",last_read_at,subject.url>subject_url");
}

fn dismissNotification(c: *Call) ![]const u8 {
    try c.gate(.write, "dismiss_notification");
    const id = try digits(c, "threadID");
    const st = (try c.oneOf("state", &.{ "read", "done" })) orelse return core.fail(c.alloc, "missing required parameter 'state' (read|done)", .{});
    const target = c.path("/notifications/threads/{s}", .{id});
    _ = try c.ok(if (std.mem.eql(u8, st, "done")) .DELETE else .PATCH, target, null, core.accept_json);
    return std.fmt.allocPrint(c.alloc, "notification {s} marked {s}", .{ id, st });
}

fn markAllRead(c: *Call) ![]const u8 {
    try c.gate(.write, "mark_all_notifications_read");
    const b = try core.Out.init(c.alloc);
    try b.obj();
    try b.kvo("last_read_at", try c.text("lastReadAt", 40));
    try b.kv("read", true);
    try b.end();
    const target = if (c.opt("owner") != null or c.opt("repo") != null)
        c.path("/repos/{s}/{s}/notifications", .{ try c.owner(), try c.repo() })
    else
        "/notifications";
    _ = try c.ok(.PUT, target, b.text(), core.accept_json);
    return "notifications marked as read";
}

fn manageNotificationSubscription(c: *Call) ![]const u8 {
    try c.gate(.write, "manage_notification_subscription");
    const id = try digits(c, "notificationID");
    const act = (try c.oneOf("action", &.{ "ignore", "watch", "delete" })) orelse return core.fail(c.alloc, "missing required parameter 'action' (ignore|watch|delete)", .{});
    const target = c.path("/notifications/threads/{s}/subscription", .{id});
    if (std.mem.eql(u8, act, "delete")) {
        _ = try c.ok(.DELETE, target, null, core.accept_json);
    } else {
        _ = try c.ok(.PUT, target, if (std.mem.eql(u8, act, "ignore")) "{\"ignored\":true}" else "{\"ignored\":false}", core.accept_json);
    }
    return std.fmt.allocPrint(c.alloc, "thread {s}: {s}", .{ id, act });
}

fn manageRepoSubscription(c: *Call) ![]const u8 {
    try c.gate(.write, "manage_repository_notification_subscription");
    const o = try c.owner();
    const r = try c.repo();
    const act = (try c.oneOf("action", &.{ "ignore", "watch", "delete" })) orelse return core.fail(c.alloc, "missing required parameter 'action' (ignore|watch|delete)", .{});
    const target = c.path("/repos/{s}/{s}/subscription", .{ o, r });
    if (std.mem.eql(u8, act, "delete")) {
        _ = try c.ok(.DELETE, target, null, core.accept_json);
    } else {
        _ = try c.ok(.PUT, target, if (std.mem.eql(u8, act, "ignore")) "{\"ignored\":true}" else "{\"subscribed\":true}", core.accept_json);
    }
    return std.fmt.allocPrint(c.alloc, "{s}/{s}: {s}", .{ o, r, act });
}

// ---------------------------------------------------------------------------
// gists
// ---------------------------------------------------------------------------

fn gistId(c: *Call) ![]const u8 {
    const s = try c.req("gist_id");
    if (!core.validSlug(s)) return core.fail(c.alloc, "invalid 'gist_id'", .{});
    return s;
}

fn listGists(c: *Call) ![]const u8 {
    const p = c.paging();
    var q = c.pq();
    q.s("since", try c.text("since", 40));
    const target = if (c.opt("username")) |u| blk: {
        if (!core.validSlug(u)) return core.fail(c.alloc, "invalid 'username'", .{});
        break :blk c.path("/users/{s}/gists{s}", .{ u, q.done() });
    } else c.path("/gists{s}", .{q.done()});
    const v = try c.get(target);
    const o = try core.Out.init(c.alloc);
    try o.js.beginArray();
    if (v == .array) for (v.array.items) |g| {
        try o.js.beginObject();
        try core.writeFields(c, &o.js, g, "id,description~100,public,updated_at,html_url>url");
        try o.js.objectField("files");
        try o.js.beginArray();
        if (g == .object) if (g.object.get("files")) |f| if (f == .object) {
            var it = f.object.iterator();
            while (it.next()) |e| try o.js.write(e.key_ptr.*);
        };
        try o.js.endArray();
        try o.js.endObject();
    };
    try o.js.endArray();
    return c.withHint(o.text(), p);
}

fn getGist(c: *Call) ![]const u8 {
    const id = try gistId(c);
    const v = try c.get(c.path("/gists/{s}", .{id}));
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(c.alloc, try c.obj(v, "id,description~200,public,owner.login>owner,updated_at,html_url>url"));
    if (v == .object) if (v.object.get("files")) |f| if (f == .object) {
        var it = f.object.iterator();
        while (it.next()) |e| {
            const content = strAt(e.value_ptr.*, "content");
            try out.print(c.alloc, "\n--- {s} ---\n{s}", .{ e.key_ptr.*, core.trunc(c.alloc, content, 20000) });
        }
    };
    return std.mem.concat(c.alloc, u8, &.{ out.items, core.UNTRUSTED });
}

fn gistFiles(c: *Call, b: *core.Out, filename: []const u8, content: []const u8) !void {
    _ = c;
    try b.js.objectField("files");
    try b.obj();
    try b.js.objectField(filename);
    try b.obj();
    try b.kv("content", content);
    try b.end();
    try b.end();
}

fn createGist(c: *Call) ![]const u8 {
    try c.gate(.write, "create_gist");
    const filename = try c.reqText("filename", 255);
    if (std.mem.indexOfScalar(u8, filename, '/') != null) return core.fail(c.alloc, "invalid 'filename'", .{});
    const content = try c.reqText("content", 1 << 20);
    const b = try core.Out.init(c.alloc);
    try b.obj();
    try b.kvo("description", try c.text("description", 1000));
    try b.kv("public", c.boolean("public") orelse false);
    try gistFiles(c, b, filename, content);
    try b.end();
    const v = try c.json(.POST, "/gists", b.text());
    return c.obj(v, "id,html_url>url,public");
}

fn updateGist(c: *Call) ![]const u8 {
    try c.gate(.write, "update_gist");
    const id = try gistId(c);
    const filename = try c.reqText("filename", 255);
    if (std.mem.indexOfScalar(u8, filename, '/') != null) return core.fail(c.alloc, "invalid 'filename'", .{});
    const content = try c.reqText("content", 1 << 20);
    const b = try core.Out.init(c.alloc);
    try b.obj();
    try b.kvo("description", try c.text("description", 1000));
    try gistFiles(c, b, filename, content);
    try b.end();
    const v = try c.json(.PATCH, c.path("/gists/{s}", .{id}), b.text());
    return c.obj(v, "id,html_url>url,updated_at");
}

// ---------------------------------------------------------------------------
// discussions (GraphQL)
// ---------------------------------------------------------------------------

fn discRepo(c: *Call) !struct { o: []const u8, r: []const u8 } {
    const o = try c.owner();
    const r = if (c.opt("repo")) |x| blk: {
        if (!core.validRepoName(x)) return core.fail(c.alloc, "invalid 'repo'", .{});
        break :blk x;
    } else ".github";
    return .{ .o = o, .r = r };
}

fn discNumber(c: *Call) !i64 {
    const n = try c.reqInt("discussionNumber");
    if (n < 1) return core.fail(c.alloc, "'discussionNumber' must be >= 1", .{});
    return n;
}

fn pageMore(c: *Call, body: []const u8, info: ?std.json.Value, per: u32) ![]const u8 {
    if (info) |pi| {
        const more = if (pi == .object) (if (pi.object.get("hasNextPage")) |h| (h == .bool and h.bool) else false) else false;
        if (more) return std.fmt.allocPrint(c.alloc, "{s}\n[more results: after={s} (perPage={d})]", .{ body, strAt(pi, "endCursor"), per });
    }
    return body;
}

fn listDiscussions(c: *Call) ![]const u8 {
    const rp = try discRepo(c);
    const p = c.paging();
    const vars = try core.Out.init(c.alloc);
    try vars.obj();
    try vars.kv("o", rp.o);
    try vars.kv("r", rp.r);
    try vars.kv("first", p.per);
    try vars.kvo("after", try c.text("after", 200));
    if (c.opt("category")) |cat| {
        if (cat.len > 100) return core.fail(c.alloc, "invalid 'category'", .{});
        try vars.kv("cat", cat);
    }
    const ob = try c.oneOf("orderBy", &.{ "CREATED_AT", "UPDATED_AT" });
    const dir = try c.oneOf("direction", &.{ "ASC", "DESC" });
    if (ob != null or dir != null) {
        try vars.js.objectField("order");
        try vars.obj();
        try vars.kv("field", ob orelse "CREATED_AT");
        try vars.kv("direction", dir orelse "DESC");
        try vars.end();
    }
    try vars.end();
    const d = try c.graphql("query($o:String!,$r:String!,$first:Int!,$after:String,$cat:ID,$order:DiscussionOrder){repository(owner:$o,name:$r){discussions(first:$first,after:$after,categoryId:$cat,orderBy:$order){totalCount pageInfo{hasNextPage endCursor} nodes{number title closed createdAt updatedAt url author{login} category{name} comments{totalCount} upvoteCount answerChosenAt}}}}", vars.text());
    const disc = dig(d, &.{ "repository", "discussions" }) orelse return core.fail(c.alloc, "repository or discussions not found (are Discussions enabled?)", .{});
    const o = try core.Out.init(c.alloc);
    try o.js.beginArray();
    if (dig(disc, &.{"nodes"})) |nodes| if (nodes == .array) for (nodes.array.items) |n| {
        try core.writeSpec(c, &o.js, n, "number,title,closed,author.login>user,category.name>category,comments.totalCount>comments,upvoteCount>upvotes,answerChosenAt>answered,updatedAt,url");
    };
    try o.js.endArray();
    return std.mem.concat(c.alloc, u8, &.{ try pageMore(c, o.text(), dig(disc, &.{"pageInfo"}), p.per), core.UNTRUSTED });
}

fn getDiscussion(c: *Call) ![]const u8 {
    const rp = try discRepo(c);
    const n = try discNumber(c);
    _ = c.paging();
    const vars = try std.fmt.allocPrint(c.alloc, "{{\"o\":\"{s}\",\"r\":\"{s}\",\"n\":{d}}}", .{ rp.o, rp.r, n });
    const d = try c.graphql("query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){discussion(number:$n){number title body closed createdAt updatedAt url author{login} category{name} answer{id author{login} body} comments{totalCount} upvoteCount}}}", vars);
    const disc = dig(d, &.{ "repository", "discussion" }) orelse return core.fail(c.alloc, "discussion not found", .{});
    return std.mem.concat(c.alloc, u8, &.{ try c.obj(disc, "number,title,closed,author.login>user,category.name>category,comments.totalCount>comments,upvoteCount>upvotes,createdAt,updatedAt,url,body~B,answer.body~600>answer"), core.UNTRUSTED });
}

fn getDiscussionComments(c: *Call) ![]const u8 {
    const rp = try discRepo(c);
    const n = try discNumber(c);
    const p = c.paging();
    if (!c.has("max_chars")) c.max_chars = 800;
    const replies = c.boolean("includeReplies") orelse false;
    const vars = try core.Out.init(c.alloc);
    try vars.obj();
    try vars.kv("o", rp.o);
    try vars.kv("r", rp.r);
    try vars.kv("n", n);
    try vars.kv("first", p.per);
    try vars.kvo("after", try c.text("after", 200));
    try vars.end();
    const q = if (replies)
        "query($o:String!,$r:String!,$n:Int!,$first:Int!,$after:String){repository(owner:$o,name:$r){discussion(number:$n){comments(first:$first,after:$after){pageInfo{hasNextPage endCursor} nodes{id author{login} body createdAt isAnswer replies(first:20){nodes{id author{login} body createdAt}}}}}}}"
    else
        "query($o:String!,$r:String!,$n:Int!,$first:Int!,$after:String){repository(owner:$o,name:$r){discussion(number:$n){comments(first:$first,after:$after){pageInfo{hasNextPage endCursor} nodes{id author{login} body createdAt isAnswer}}}}}}";
    const d = try c.graphql(q, vars.text());
    const cm = dig(d, &.{ "repository", "discussion", "comments" }) orelse return core.fail(c.alloc, "discussion not found", .{});
    const o = try core.Out.init(c.alloc);
    try o.js.beginArray();
    if (dig(cm, &.{"nodes"})) |nodes| if (nodes == .array) for (nodes.array.items) |n2| {
        try o.js.beginObject();
        try core.writeFields(c, &o.js, n2, "id,author.login>user,createdAt>at,isAnswer,body~B");
        if (replies) if (dig(n2, &.{ "replies", "nodes" })) |rn| if (rn == .array and rn.array.items.len > 0) {
            try o.js.objectField("replies");
            try o.js.beginArray();
            for (rn.array.items) |rr| try core.writeSpec(c, &o.js, rr, "id,author.login>user,createdAt>at,body~B");
            try o.js.endArray();
        };
        try o.js.endObject();
    };
    try o.js.endArray();
    return std.mem.concat(c.alloc, u8, &.{ try pageMore(c, o.text(), dig(cm, &.{"pageInfo"}), p.per), core.UNTRUSTED });
}

fn listDiscussionCategories(c: *Call) ![]const u8 {
    const rp = try discRepo(c);
    const vars = try std.fmt.allocPrint(c.alloc, "{{\"o\":\"{s}\",\"r\":\"{s}\"}}", .{ rp.o, rp.r });
    const d = try c.graphql("query($o:String!,$r:String!){repository(owner:$o,name:$r){discussionCategories(first:50){nodes{id name slug isAnswerable}}}}", vars);
    const nodes = dig(d, &.{ "repository", "discussionCategories", "nodes" }) orelse return core.fail(c.alloc, "repository not found", .{});
    return c.arr(nodes, "id,name,slug,isAnswerable");
}

fn discussionCommentWrite(c: *Call) ![]const u8 {
    try c.gate(.write, "discussion_comment_write");
    const m = try c.method(&.{ "add", "reply", "update", "delete", "mark_answer", "unmark_answer" });
    if (std.mem.eql(u8, m, "delete")) try c.gate(.destructive, "discussion_comment_write delete");
    const body = try c.text("body", 65536);
    if (std.mem.eql(u8, m, "add") or std.mem.eql(u8, m, "reply")) {
        const rp = try discRepo(c);
        const n = try discNumber(c);
        const text = body orelse return core.fail(c.alloc, "'body' is required", .{});
        const idv = try std.fmt.allocPrint(c.alloc, "{{\"o\":\"{s}\",\"r\":\"{s}\",\"n\":{d}}}", .{ rp.o, rp.r, n });
        const d = try c.graphql("query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){discussion(number:$n){id}}}", idv);
        const did = strAt(dig(d, &.{ "repository", "discussion" }) orelse return core.fail(c.alloc, "discussion not found", .{}), "id");
        const vars = try core.Out.init(c.alloc);
        try vars.obj();
        try vars.js.objectField("input");
        try vars.obj();
        try vars.kv("discussionId", did);
        try vars.kv("body", text);
        if (std.mem.eql(u8, m, "reply")) try vars.kv("replyToId", try nodeId(c, "commentNodeID"));
        try vars.end();
        try vars.end();
        const res = try c.graphql("mutation($input:AddDiscussionCommentInput!){addDiscussionComment(input:$input){comment{id url}}}", vars.text());
        return c.obj(dig(res, &.{ "addDiscussionComment", "comment" }) orelse .null, "id,url");
    }
    const cid = try nodeId(c, "commentNodeID");
    const vars = try core.Out.init(c.alloc);
    try vars.obj();
    try vars.js.objectField("input");
    try vars.obj();
    if (std.mem.eql(u8, m, "update")) {
        try vars.kv("commentId", cid);
        try vars.kv("body", body orelse return core.fail(c.alloc, "'body' is required", .{}));
    } else try vars.kv("id", cid);
    try vars.end();
    try vars.end();
    const q = if (std.mem.eql(u8, m, "update"))
        "mutation($input:UpdateDiscussionCommentInput!){updateDiscussionComment(input:$input){comment{id url}}}"
    else if (std.mem.eql(u8, m, "delete"))
        "mutation($input:DeleteDiscussionCommentInput!){deleteDiscussionComment(input:$input){comment{id}}}"
    else if (std.mem.eql(u8, m, "mark_answer"))
        "mutation($input:MarkDiscussionCommentAsAnswerInput!){markDiscussionCommentAsAnswer(input:$input){discussion{id}}}"
    else
        "mutation($input:UnmarkDiscussionCommentAsAnswerInput!){unmarkDiscussionCommentAsAnswer(input:$input){discussion{id}}}";
    _ = try c.graphql(q, vars.text());
    return std.fmt.allocPrint(c.alloc, "{s} ok ({s})", .{ m, cid });
}

fn nodeId(c: *Call, k: []const u8) ![]const u8 {
    const s = try c.req(k);
    if (s.len > 100) return core.fail(c.alloc, "invalid '{s}'", .{k});
    for (s) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '=')) return core.fail(c.alloc, "invalid '{s}': expected a GraphQL node id", .{k});
    return s;
}

// ---------------------------------------------------------------------------
// projects (Projects v2 REST)
// ---------------------------------------------------------------------------

fn ownerBase(c: *Call) ![]const u8 {
    const o = try c.owner();
    if (try c.oneOf("owner_type", &.{ "user", "org" })) |t| return c.path("/{s}/{s}/projectsV2", .{ if (std.mem.eql(u8, t, "org")) "orgs" else "users", o });
    const u = try c.get(c.path("/users/{s}", .{o}));
    const org = std.mem.eql(u8, strAt(u, "type"), "Organization");
    return c.path("/{s}/{s}/projectsV2", .{ if (org) "orgs" else "users", o });
}

fn projNumber(c: *Call) !i64 {
    const n = try c.reqInt("project_number");
    if (n < 1) return core.fail(c.alloc, "'project_number' must be >= 1", .{});
    return n;
}

/// Comma list of field ids from `fields` (ids) or `field_names` (resolved).
fn fieldsParam(c: *Call, proj: []const u8) !?[]const u8 {
    const ids = try c.strList("fields");
    if (ids.len > 0) {
        for (ids) |i| for (i) |ch| if (!std.ascii.isDigit(ch)) return core.fail(c.alloc, "'fields' must be numeric field ids", .{});
        return try std.mem.join(c.alloc, ",", ids);
    }
    const names = try c.strList("field_names");
    if (names.len == 0) return null;
    const fl = try c.get(c.path("{s}/fields?per_page=100", .{proj}));
    var out: std.ArrayList([]const u8) = .empty;
    for (names) |nm| {
        var found = false;
        if (fl == .array) for (fl.array.items) |f| {
            if (std.ascii.eqlIgnoreCase(strAt(f, "name"), nm)) {
                if (f == .object) if (f.object.get("id")) |x| if (x == .integer) {
                    try out.append(c.alloc, try std.fmt.allocPrint(c.alloc, "{d}", .{x.integer}));
                    found = true;
                };
            }
        };
        if (!found) return core.fail(c.alloc, "unknown project field name '{s}'", .{nm});
    }
    return try std.mem.join(c.alloc, ",", out.items);
}

fn simpleValue(v: std.json.Value) std.json.Value {
    if (v == .object) {
        if (v.object.get("name")) |n| return n;
        if (v.object.get("title")) |n| return n;
    }
    return v;
}

fn writeItems(c: *Call, arr: std.json.Value) ![]const u8 {
    const o = try core.Out.init(c.alloc);
    try o.js.beginArray();
    if (arr == .array) for (arr.array.items) |it| try writeItem(c, o, it);
    try o.js.endArray();
    return o.text();
}

fn writeItem(c: *Call, o: *core.Out, it: std.json.Value) !void {
    try o.js.beginObject();
    try core.writeFields(c, &o.js, it, "id,content_type>type,content.number>number,content.title>title,content.state>state,content.html_url>url,archived_at");
    if (it == .object) if (it.object.get("fields")) |fs| if (fs == .array and fs.array.items.len > 0) {
        try o.js.objectField("fields");
        try o.js.beginObject();
        for (fs.array.items) |f| {
            const nm = strAt(f, "name");
            if (nm.len == 0 or f != .object) continue;
            const val = f.object.get("value") orelse continue;
            if (val == .null) continue;
            try o.js.objectField(nm);
            try o.js.write(simpleValue(val));
        }
        try o.js.endObject();
    };
    try o.js.endObject();
}

fn projectsList(c: *Call) ![]const u8 {
    const m = try c.method(&.{ "list_projects", "list_project_fields", "list_project_items" });
    const base = try ownerBase(c);
    const per: i64 = std.math.clamp(c.int("perPage") orelse 30, 1, 50);
    var q = c.q();
    q.i("per_page", per);
    q.s("after", try c.text("after", 200));
    q.s("before", try c.text("before", 200));
    const hint = struct {
        fn f(cc: *Call, body: []const u8) ![]const u8 {
            if (std.mem.indexOf(u8, cc.last.link, "rel=\"next\"") != null) if (std.mem.indexOf(u8, cc.last.link, "after=")) |i| {
                const rest = cc.last.link[i + 6 ..];
                const end = std.mem.indexOfAny(u8, rest, "&>") orelse rest.len;
                return std.fmt.allocPrint(cc.alloc, "{s}\n[more results: after={s}]", .{ body, rest[0..end] });
            };
            return body;
        }
    }.f;
    if (std.mem.eql(u8, m, "list_projects")) {
        q.s("q", try c.text("query", 500));
        const v = try c.get(c.path("{s}{s}", .{ base, q.done() }));
        return hint(c, try c.arr(v, "number,title,short_description~150>description,public,state,closed_at,updated_at"));
    }
    const proj = c.path("{s}/{d}", .{ base, try projNumber(c) });
    if (std.mem.eql(u8, m, "list_project_fields")) {
        const v = try c.get(c.path("{s}/fields{s}", .{ proj, q.done() }));
        return hint(c, try c.arr(v, "id,name,data_type,options[].name>options"));
    }
    q.s("q", try c.text("query", 500));
    q.s("fields", try fieldsParam(c, proj));
    const v = try c.get(c.path("{s}/items{s}", .{ proj, q.done() }));
    return std.mem.concat(c.alloc, u8, &.{ try hint(c, try writeItems(c, v)), core.UNTRUSTED });
}

fn projectsGet(c: *Call) ![]const u8 {
    const m = try c.method(&.{ "get_project", "get_project_field", "get_project_item" });
    const base = try ownerBase(c);
    const proj = c.path("{s}/{d}", .{ base, try projNumber(c) });
    if (std.mem.eql(u8, m, "get_project")) {
        const v = try c.get(proj);
        return c.obj(v, "number,title,description~B,short_description~200,public,state,closed_at,created_at,updated_at");
    }
    if (std.mem.eql(u8, m, "get_project_field")) {
        const v = try c.get(c.path("{s}/fields/{d}", .{ proj, try c.reqInt("field_id") }));
        return c.obj(v, "id,name,data_type,options[].name>options");
    }
    var q = c.q();
    q.s("fields", try fieldsParam(c, proj));
    const v = try c.get(c.path("{s}/items/{d}{s}", .{ proj, try c.reqInt("item_id"), q.done() }));
    const o = try core.Out.init(c.alloc);
    try writeItem(c, o, v);
    return std.mem.concat(c.alloc, u8, &.{ o.text(), core.UNTRUSTED });
}

fn resolveUpdatedField(c: *Call, proj: []const u8, uf: std.json.Value, b: *core.Out) !void {
    if (uf != .object) return core.fail(c.alloc, "'updated_field' must be an object {{id|name, value}}", .{});
    const value = uf.object.get("value") orelse .null;
    var id: i64 = 0;
    var val = value;
    if (uf.object.get("id")) |x| {
        if (x == .integer) id = x.integer else return core.fail(c.alloc, "updated_field.id must be an integer", .{});
    } else if (uf.object.get("name")) |nm| {
        if (nm != .string) return core.fail(c.alloc, "updated_field.name must be a string", .{});
        const fl = try c.get(c.path("{s}/fields?per_page=100", .{proj}));
        if (fl == .array) for (fl.array.items) |f| {
            if (!std.ascii.eqlIgnoreCase(strAt(f, "name"), nm.string)) continue;
            if (f == .object) if (f.object.get("id")) |x| if (x == .integer) {
                id = x.integer;
            };
            if (value == .string) if (f.object.get("options")) |opts| if (opts == .array) for (opts.array.items) |op| {
                if (std.ascii.eqlIgnoreCase(strAt(op, "name"), value.string)) val = if (op == .object) (op.object.get("id") orelse value) else value;
            };
        };
        if (id == 0) return core.fail(c.alloc, "unknown project field '{s}'", .{nm.string});
    } else return core.fail(c.alloc, "'updated_field' needs id or name", .{});
    try b.js.objectField("fields");
    try b.js.beginArray();
    try b.obj();
    try b.kv("id", id);
    try b.kv("value", val);
    try b.end();
    try b.js.endArray();
}

fn projectsWrite(c: *Call) ![]const u8 {
    try c.gate(.write, "projects_write");
    const m = try c.method(&.{ "add_project_item", "update_project_item", "update_project_items", "delete_project_item" });
    if (std.mem.eql(u8, m, "delete_project_item")) try c.gate(.destructive, "projects_write delete_project_item");
    const base = try ownerBase(c);
    const proj = c.path("{s}/{d}", .{ base, try projNumber(c) });
    if (std.mem.eql(u8, m, "delete_project_item")) {
        _ = try c.ok(.DELETE, c.path("{s}/items/{d}", .{ proj, try c.reqInt("item_id") }), null, core.accept_json);
        return "project item deleted";
    }
    if (std.mem.eql(u8, m, "add_project_item")) {
        const io = try c.ownerKey("item_owner");
        const ir = try c.slug("item_repo");
        const typ = (try c.oneOf("item_type", &.{ "issue", "pull_request" })) orelse return core.fail(c.alloc, "missing 'item_type' (issue|pull_request)", .{});
        const is_pr = std.mem.eql(u8, typ, "pull_request");
        const num = c.int(if (is_pr) "pull_request_number" else "issue_number") orelse c.int("issue_number") orelse return core.fail(c.alloc, "missing issue_number / pull_request_number", .{});
        const src = try c.get(c.path("/repos/{s}/{s}/{s}/{d}", .{ io, ir, if (is_pr) "pulls" else "issues", num }));
        const id = if (src == .object) (if (src.object.get("id")) |x| (if (x == .integer) x.integer else 0) else 0) else 0;
        if (id == 0) return core.fail(c.alloc, "could not resolve the issue/PR id", .{});
        const body = try std.fmt.allocPrint(c.alloc, "{{\"type\":\"{s}\",\"id\":{d}}}", .{ if (is_pr) "PullRequest" else "Issue", id });
        const v = try c.json(.POST, c.path("{s}/items", .{proj}), body);
        return c.obj(v, "id,content_type>type");
    }
    const uf = c.raw("updated_field") orelse return core.fail(c.alloc, "'updated_field' is required", .{});
    if (std.mem.eql(u8, m, "update_project_item")) {
        const b = try core.Out.init(c.alloc);
        try b.obj();
        try resolveUpdatedField(c, proj, uf, b);
        try b.end();
        const v = try c.json(.PATCH, c.path("{s}/items/{d}", .{ proj, try c.reqInt("item_id") }), b.text());
        return c.obj(v, "id,content_type>type");
    }
    const items = c.raw("items") orelse return core.fail(c.alloc, "'items' is required", .{});
    if (items != .array or items.array.items.len == 0 or items.array.items.len > 50) return core.fail(c.alloc, "'items' must hold 1-50 entries with item_id", .{});
    const b = try core.Out.init(c.alloc);
    try b.obj();
    try resolveUpdatedField(c, proj, uf, b);
    try b.end();
    var done: usize = 0;
    for (items.array.items) |it| {
        const iid = if (it == .object) (if (it.object.get("item_id")) |x| (if (x == .integer) x.integer else 0) else 0) else 0;
        if (iid <= 0) return core.fail(c.alloc, "each item needs a numeric item_id ({d} updated before this)", .{done});
        _ = try c.ok(.PATCH, c.path("{s}/items/{d}", .{ proj, iid }), b.text(), core.accept_json);
        done += 1;
    }
    return std.fmt.allocPrint(c.alloc, "updated {d} items", .{done});
}

const PROJ = "\"method\":{\"type\":\"string\"},\"owner\":{\"type\":\"string\"},\"owner_type\":{\"type\":\"string\",\"enum\":[\"user\",\"org\"]},\"project_number\":{\"type\":\"number\"}";

pub const tools = [_]core.Tool{
    T("notifications", "list_notifications", "List your notifications (filter: default|include_read_notifications|only_participating).", S("\"filter\":{\"type\":\"string\",\"enum\":[\"default\",\"include_read_notifications\",\"only_participating\"]},\"since\":{\"type\":\"string\"},\"before\":{\"type\":\"string\"},\"owner\":{\"type\":\"string\"},\"repo\":{\"type\":\"string\"}," ++ PG, ""), listNotifications, .ro),
    T("notifications", "get_notification_details", "Get one notification thread.", S("\"notificationID\":{\"type\":\"string\"}", "\"notificationID\""), getNotificationDetails, .ro),
    T("notifications", "dismiss_notification", "Mark a notification read or done.", S("\"threadID\":{\"type\":\"string\"},\"state\":{\"type\":\"string\",\"enum\":[\"read\",\"done\"]}", "\"threadID\",\"state\""), dismissNotification, .add),
    T("notifications", "mark_all_notifications_read", "Mark all (or one repo's) notifications read.", S("\"lastReadAt\":{\"type\":\"string\"},\"owner\":{\"type\":\"string\"},\"repo\":{\"type\":\"string\"}", ""), markAllRead, .add),
    T("notifications", "manage_notification_subscription", "Ignore/watch/delete a thread subscription.", S("\"notificationID\":{\"type\":\"string\"},\"action\":{\"type\":\"string\",\"enum\":[\"ignore\",\"watch\",\"delete\"]}", "\"notificationID\",\"action\""), manageNotificationSubscription, .add),
    T("notifications", "manage_repository_notification_subscription", "Ignore/watch/delete a repo subscription.", S(OR ++ ",\"action\":{\"type\":\"string\",\"enum\":[\"ignore\",\"watch\",\"delete\"]}", "\"owner\",\"repo\",\"action\""), manageRepoSubscription, .add),

    T("gists", "list_gists", "List your gists or `username`'s.", S("\"username\":{\"type\":\"string\"},\"since\":{\"type\":\"string\"}," ++ PG, ""), listGists, .ro),
    T("gists", "get_gist", "Get a gist with file contents.", S("\"gist_id\":{\"type\":\"string\"}", "\"gist_id\""), getGist, .ro),
    T("gists", "create_gist", "Create a gist with one file.", S("\"description\":{\"type\":\"string\"},\"filename\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"},\"public\":{\"type\":\"boolean\"}", "\"filename\",\"content\""), createGist, .add),
    T("gists", "update_gist", "Overwrite/add a file in a gist.", S("\"gist_id\":{\"type\":\"string\"},\"description\":{\"type\":\"string\"},\"filename\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}", "\"gist_id\",\"filename\",\"content\""), updateGist, .add),

    T("discussions", "list_discussions", "List discussions (cursor: after; repo defaults to .github).", S("\"owner\":{\"type\":\"string\"},\"repo\":{\"type\":\"string\"},\"category\":{\"type\":\"string\"},\"orderBy\":{\"type\":\"string\",\"enum\":[\"CREATED_AT\",\"UPDATED_AT\"]},\"direction\":{\"type\":\"string\",\"enum\":[\"ASC\",\"DESC\"]},\"after\":{\"type\":\"string\"},\"perPage\":{\"type\":\"number\"}", "\"owner\""), listDiscussions, .ro),
    T("discussions", "get_discussion", "Get a discussion.", S("\"owner\":{\"type\":\"string\"},\"repo\":{\"type\":\"string\"},\"discussionNumber\":{\"type\":\"number\"}," ++ core.MC, "\"owner\",\"discussionNumber\""), getDiscussion, .ro),
    T("discussions", "get_discussion_comments", "Get discussion comments (cursor: after).", S("\"owner\":{\"type\":\"string\"},\"repo\":{\"type\":\"string\"},\"discussionNumber\":{\"type\":\"number\"},\"after\":{\"type\":\"string\"},\"perPage\":{\"type\":\"number\"},\"includeReplies\":{\"type\":\"boolean\"}," ++ core.MC, "\"owner\",\"discussionNumber\""), getDiscussionComments, .ro),
    T("discussions", "list_discussion_categories", "List discussion categories.", S("\"owner\":{\"type\":\"string\"},\"repo\":{\"type\":\"string\"}", "\"owner\""), listDiscussionCategories, .ro),
    T("discussions", "discussion_comment_write", "Discussion comment: method=add|reply|update|delete|mark_answer|unmark_answer.", S("\"method\":{\"type\":\"string\",\"enum\":[\"add\",\"reply\",\"update\",\"delete\",\"mark_answer\",\"unmark_answer\"]},\"owner\":{\"type\":\"string\"},\"repo\":{\"type\":\"string\"},\"discussionNumber\":{\"type\":\"number\"},\"body\":{\"type\":\"string\"},\"commentNodeID\":{\"type\":\"string\"}", "\"method\""), discussionCommentWrite, .destructive),

    T("projects", "projects_list", "List: method=list_projects|list_project_fields|list_project_items (cursor: after).", S(PROJ ++ ",\"query\":{\"type\":\"string\"},\"fields\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"field_names\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"after\":{\"type\":\"string\"},\"before\":{\"type\":\"string\"},\"perPage\":{\"type\":\"number\"}", "\"method\",\"owner\""), projectsList, .ro),
    T("projects", "projects_get", "Get: method=get_project|get_project_field|get_project_item.", S(PROJ ++ ",\"field_id\":{\"type\":\"number\"},\"item_id\":{\"type\":\"number\"},\"fields\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"field_names\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}", "\"method\",\"owner\",\"project_number\""), projectsGet, .ro),
    T("projects", "projects_write", "Write: method=add_project_item|update_project_item|update_project_items|delete_project_item.", S(PROJ ++ ",\"item_id\":{\"type\":\"number\"},\"item_owner\":{\"type\":\"string\"},\"item_repo\":{\"type\":\"string\"},\"item_type\":{\"type\":\"string\",\"enum\":[\"issue\",\"pull_request\"]},\"issue_number\":{\"type\":\"number\"},\"pull_request_number\":{\"type\":\"number\"},\"updated_field\":{\"type\":\"object\"},\"items\":{\"type\":\"array\",\"items\":{\"type\":\"object\"}}", "\"method\",\"owner\",\"project_number\""), projectsWrite, .destructive),
};
