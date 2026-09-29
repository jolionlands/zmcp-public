//! Toolsets: actions, code_security, secret_protection, dependabot, security_advisories.

const std = @import("std");
const core = @import("core.zig");
const Call = core.Call;
const T = core.T;
const S = core.S;
const OR = core.OR;
const PG = core.PG;

const run_spec = "id,name,display_title,status,conclusion,event,head_branch>branch,head_sha>sha,run_number,run_attempt,actor.login>actor,created_at,updated_at,html_url>url";
const job_spec = "id,name,status,conclusion,started_at,completed_at,run_id,html_url>url";

fn numericId(c: *Call, k: []const u8) ![]const u8 {
    const s = try c.req(k);
    if (s.len > 20) return core.fail(c.alloc, "invalid '{s}'", .{k});
    for (s) |ch| if (!std.ascii.isDigit(ch)) return core.fail(c.alloc, "invalid '{s}': expected a numeric id", .{k});
    return s;
}

/// Workflow id or file name.
fn workflowId(c: *Call, s: []const u8) ![]const u8 {
    if (!core.validSlug(s)) return core.fail(c.alloc, "invalid workflow id/file name", .{});
    return s;
}

fn actionsGet(c: *Call) ![]const u8 {
    const m = try c.method(&.{ "get_workflow", "get_workflow_run", "get_workflow_job", "download_workflow_run_artifact", "get_workflow_run_usage", "get_workflow_run_logs_url" });
    const o = try c.owner();
    const r = try c.repo();
    const base = c.path("/repos/{s}/{s}/actions", .{ o, r });
    if (std.mem.eql(u8, m, "get_workflow")) {
        const id = try workflowId(c, try c.req("resource_id"));
        const v = try c.get(c.path("{s}/workflows/{s}", .{ base, id }));
        return c.obj(v, "id,name,path,state,html_url>url");
    }
    const id = try numericId(c, "resource_id");
    if (std.mem.eql(u8, m, "get_workflow_run")) {
        const v = try c.get(c.path("{s}/runs/{s}", .{ base, id }));
        return c.obj(v, run_spec ++ ",path,jobs_url");
    }
    if (std.mem.eql(u8, m, "get_workflow_job")) {
        const v = try c.get(c.path("{s}/jobs/{s}", .{ base, id }));
        const head = try c.obj(v, job_spec ++ ",runner_name");
        var lines: std.ArrayList(u8) = .empty;
        try lines.appendSlice(c.alloc, head);
        if (v == .object) if (v.object.get("steps")) |ss| if (ss == .array) for (ss.array.items) |s| {
            try lines.print(c.alloc, "\n{s}: {s}", .{ strAt(s, "name"), strAt(s, "conclusion") });
        };
        return lines.items;
    }
    if (std.mem.eql(u8, m, "get_workflow_run_usage")) {
        const v = try c.get(c.path("{s}/runs/{s}/timing", .{ base, id }));
        const o2 = try core.Out.init(c.alloc);
        try o2.js.write(v);
        return o2.text();
    }
    const suffix = if (std.mem.eql(u8, m, "get_workflow_run_logs_url")) c.path("/runs/{s}/logs", .{id}) else c.path("/artifacts/{s}/zip", .{id});
    const resp = try c.send(.GET, c.path("{s}{s}", .{ base, suffix }), null, core.accept_json, false);
    if (resp.status == 302 or resp.status == 301 or resp.status == 307) return std.fmt.allocPrint(c.alloc, "{{\"download_url\":\"{s}\",\"note\":\"short-lived; fetch without the GitHub token\"}}", .{resp.location});
    return core.fail(c.alloc, "{s}", .{core.errorMessage(c.alloc, resp)});
}

fn strAt(v: std.json.Value, k: []const u8) []const u8 {
    if (v != .object) return "";
    const x = v.object.get(k) orelse return "";
    return if (x == .string) x.string else "";
}

fn actionsList(c: *Call) ![]const u8 {
    const m = try c.method(&.{ "list_workflows", "list_workflow_runs", "list_workflow_jobs", "list_workflow_run_artifacts" });
    const o = try c.owner();
    const r = try c.repo();
    const p = c.paging();
    var q = c.pq();
    const base = c.path("/repos/{s}/{s}/actions", .{ o, r });
    if (std.mem.eql(u8, m, "list_workflows")) {
        const v = try c.get(c.path("{s}/workflows{s}", .{ base, q.done() }));
        return c.searchKey(v, "workflows", "id,name,path,state", p);
    }
    if (std.mem.eql(u8, m, "list_workflow_runs")) {
        if (c.raw("workflow_runs_filter")) |f| if (f == .object) {
            if (f.object.get("actor")) |x| if (x == .string) {
                if (!core.validSlug(x.string)) return core.fail(c.alloc, "invalid actor", .{});
                q.s("actor", x.string);
            };
            if (f.object.get("branch")) |x| if (x == .string) {
                if (!core.validRef(x.string)) return core.fail(c.alloc, "invalid branch", .{});
                q.s("branch", x.string);
            };
            if (f.object.get("event")) |x| if (x == .string) {
                if (!core.validSlug(x.string)) return core.fail(c.alloc, "invalid event", .{});
                q.s("event", x.string);
            };
            if (f.object.get("status")) |x| if (x == .string) {
                if (!core.validSlug(x.string)) return core.fail(c.alloc, "invalid status", .{});
                q.s("status", x.string);
            };
        };
        const target = if (c.opt("resource_id")) |w|
            c.path("{s}/workflows/{s}/runs{s}", .{ base, try workflowId(c, w), q.done() })
        else
            c.path("{s}/runs{s}", .{ base, q.done() });
        const v = try c.get(target);
        return c.searchKey(v, "workflow_runs", run_spec, p);
    }
    const id = try numericId(c, "resource_id");
    if (std.mem.eql(u8, m, "list_workflow_jobs")) {
        if (c.raw("workflow_jobs_filter")) |f| if (f == .object) if (f.object.get("filter")) |x| if (x == .string) {
            if (!std.mem.eql(u8, x.string, "latest") and !std.mem.eql(u8, x.string, "all")) return core.fail(c.alloc, "invalid filter: latest|all", .{});
            q.s("filter", x.string);
        };
        const v = try c.get(c.path("{s}/runs/{s}/jobs{s}", .{ base, id, q.done() }));
        return c.searchKey(v, "jobs", job_spec, p);
    }
    const v = try c.get(c.path("{s}/runs/{s}/artifacts{s}", .{ base, id, q.done() }));
    return c.searchKey(v, "artifacts", "id,name,size_in_bytes>size,expired,created_at", p);
}

fn actionsRunTrigger(c: *Call) ![]const u8 {
    try c.gate(.destructive, "actions_run_trigger");
    const m = try c.method(&.{ "run_workflow", "rerun_workflow_run", "rerun_failed_jobs", "cancel_workflow_run", "delete_workflow_run_logs" });
    const o = try c.owner();
    const r = try c.repo();
    const base = c.path("/repos/{s}/{s}/actions", .{ o, r });
    if (std.mem.eql(u8, m, "run_workflow")) {
        const wf = try workflowId(c, try c.req("workflow_id"));
        const ref = try c.ref("ref");
        const b = try core.Out.init(c.alloc);
        try b.obj();
        try b.kv("ref", ref);
        if (c.raw("inputs")) |inp| if (inp == .object) try b.kv("inputs", inp);
        try b.end();
        _ = try c.ok(.POST, c.path("{s}/workflows/{s}/dispatches", .{ base, wf }), b.text(), core.accept_json);
        return std.fmt.allocPrint(c.alloc, "workflow {s} dispatched on {s}", .{ wf, ref });
    }
    const run = try c.reqInt("run_id");
    if (std.mem.eql(u8, m, "delete_workflow_run_logs")) {
        _ = try c.ok(.DELETE, c.path("{s}/runs/{d}/logs", .{ base, run }), null, core.accept_json);
        return "run logs deleted";
    }
    const suffix: []const u8 = if (std.mem.eql(u8, m, "rerun_workflow_run")) "rerun" else if (std.mem.eql(u8, m, "rerun_failed_jobs")) "rerun-failed-jobs" else "cancel";
    _ = try c.ok(.POST, c.path("{s}/runs/{d}/{s}", .{ base, run, suffix }), null, core.accept_json);
    return std.fmt.allocPrint(c.alloc, "{s} requested for run {d}", .{ m, run });
}

/// Drop the leading `2024-01-01T00:00:00.0000000Z ` stamp from each log line and keep the last n lines.
pub fn tailLog(alloc: std.mem.Allocator, log: []const u8, n: usize) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, log, '\n');
    while (it.next()) |ln0| {
        var ln = std.mem.trimEnd(u8, ln0, "\r");
        if (ln.len > 29 and ln[4] == '-' and ln[10] == 'T' and std.mem.indexOfScalar(u8, ln[19..@min(ln.len, 30)], 'Z') != null) {
            if (std.mem.indexOfScalar(u8, ln, ' ')) |sp| if (sp <= 30) {
                ln = ln[sp + 1 ..];
            };
        }
        try lines.append(alloc, ln);
    }
    var start: usize = 0;
    var total = lines.items.len;
    if (total > 0 and lines.items[total - 1].len == 0) total -= 1;
    if (total > n) start = total - n;
    var out: std.ArrayList(u8) = .empty;
    if (start > 0) try out.print(alloc, "[log truncated: last {d} of {d} lines]\n", .{ n, total });
    for (lines.items[start..total]) |ln| {
        try out.appendSlice(alloc, ln);
        try out.append(alloc, '\n');
    }
    return out.items;
}

fn jobLog(c: *Call, o: []const u8, r: []const u8, id: []const u8, want_content: bool, n: usize) ![]const u8 {
    const target = c.path("/repos/{s}/{s}/actions/jobs/{s}/logs", .{ o, r, id });
    if (!want_content) {
        const resp = try c.send(.GET, target, null, core.accept_json, false);
        if (resp.status >= 300 and resp.status < 400) return std.fmt.allocPrint(c.alloc, "{{\"job_id\":{s},\"logs_url\":\"{s}\"}}", .{ id, resp.location });
        return core.fail(c.alloc, "{s}", .{core.errorMessage(c.alloc, resp)});
    }
    c.max_body = 48 * 1024 * 1024;
    const body = try c.ok(.GET, target, null, core.accept_json);
    return tailLog(c.alloc, body, n);
}

fn getJobLogs(c: *Call) ![]const u8 {
    const o = try c.owner();
    const r = try c.repo();
    const want = c.boolean("return_content") orelse false;
    const n: usize = @intCast(std.math.clamp(c.int("tail_lines") orelse 500, 1, 5000));
    if (c.boolean("failed_only") orelse false) {
        const run = try c.reqInt("run_id");
        const v = try c.get(c.path("/repos/{s}/{s}/actions/runs/{d}/jobs?filter=latest&per_page=100", .{ o, r, run }));
        var out: std.ArrayList(u8) = .empty;
        var count: usize = 0;
        if (v == .object) if (v.object.get("jobs")) |jobs| if (jobs == .array) for (jobs.array.items) |j| {
            if (!std.mem.eql(u8, strAt(j, "conclusion"), "failure")) continue;
            const jid = if (j == .object) (if (j.object.get("id")) |x| (if (x == .integer) x.integer else 0) else 0) else 0;
            if (jid == 0) continue;
            count += 1;
            if (count > 5) break;
            try out.print(c.alloc, "== job {d} {s} ==\n", .{ jid, strAt(j, "name") });
            try out.appendSlice(c.alloc, try jobLog(c, o, r, try std.fmt.allocPrint(c.alloc, "{d}", .{jid}), want, @max(20, n / 2)));
            try out.append(c.alloc, '\n');
        };
        if (count == 0) return "no failed jobs in this run";
        return out.items;
    }
    const jid = try c.reqInt("job_id");
    return jobLog(c, o, r, try std.fmt.allocPrint(c.alloc, "{d}", .{jid}), want, n);
}

// ---------------------------------------------------------------------------
// code scanning, secret scanning, dependabot, advisories
// ---------------------------------------------------------------------------

const cs_spec = "number,state,rule.id>rule,rule.severity>severity,rule.security_severity_level>security_severity,rule.description~200>description,tool.name>tool,most_recent_instance.location.path>path,most_recent_instance.location.start_line>line,most_recent_instance.ref>ref,dismissed_reason,created_at,html_url>url";
const ss_spec = "number,state,secret_type_display_name>type,secret_type,resolution,validity,push_protection_bypassed,created_at,html_url>url";
const db_spec = "number,state,dependency.package.name>package,dependency.package.ecosystem>ecosystem,dependency.manifest_path>manifest,security_advisory.severity>severity,security_advisory.ghsa_id>ghsa,security_advisory.cve_id>cve,security_advisory.summary~200>summary,security_vulnerability.vulnerable_version_range>vulnerable,security_vulnerability.first_patched_version.identifier>patched,html_url>url";
const adv_row = "ghsa_id,cve_id,summary~200,severity,published_at,html_url>url";

fn alertGet(c: *Call, area: []const u8, spec: []const u8) ![]const u8 {
    const o = try c.owner();
    const r = try c.repo();
    const n = try c.reqInt("alertNumber");
    const v = try c.get(c.path("/repos/{s}/{s}/{s}/alerts/{d}", .{ o, r, area, n }));
    return c.obj(v, spec);
}

fn getCodeScanningAlert(c: *Call) ![]const u8 {
    return alertGet(c, "code-scanning", cs_spec);
}
fn getSecretScanningAlert(c: *Call) ![]const u8 {
    return alertGet(c, "secret-scanning", ss_spec);
}
fn getDependabotAlert(c: *Call) ![]const u8 {
    return alertGet(c, "dependabot", db_spec);
}

fn alertList(c: *Call, area: []const u8, spec: []const u8, filters: []const []const u8, cursor: bool) ![]const u8 {
    const o = try c.owner();
    const r = try c.repo();
    const p = c.paging();
    var q = if (cursor) blk: {
        var qq = c.q();
        qq.i("per_page", p.per);
        qq.s("after", try c.text("after", 200));
        break :blk qq;
    } else c.pq();
    for (filters) |f| {
        const v = c.opt(f) orelse continue;
        if (!core.validText(v, 200)) return core.fail(c.alloc, "invalid '{s}'", .{f});
        const key = if (std.mem.eql(u8, f, "tool_name")) "tool_name" else f;
        q.s(key, v);
    }
    const v = try c.get(c.path("/repos/{s}/{s}/{s}/alerts{s}", .{ o, r, area, q.done() }));
    if (!cursor) return c.list(v, spec, p);
    const body = try c.arr(v, spec);
    if (std.mem.indexOf(u8, c.last.link, "rel=\"next\"") != null) {
        if (std.mem.indexOf(u8, c.last.link, "after=")) |i| {
            const rest = c.last.link[i + 6 ..];
            const end = std.mem.indexOfAny(u8, rest, "&>") orelse rest.len;
            return std.fmt.allocPrint(c.alloc, "{s}\n[more results: after={s}]", .{ body, rest[0..end] });
        }
    }
    return body;
}

fn listCodeScanningAlerts(c: *Call) ![]const u8 {
    return alertList(c, "code-scanning", cs_spec, &.{ "state", "severity", "tool_name", "ref" }, false);
}
fn listSecretScanningAlerts(c: *Call) ![]const u8 {
    return alertList(c, "secret-scanning", ss_spec, &.{ "state", "secret_type", "resolution" }, false);
}
fn listDependabotAlerts(c: *Call) ![]const u8 {
    return alertList(c, "dependabot", db_spec, &.{ "state", "severity" }, true);
}

fn getGlobalAdvisory(c: *Call) ![]const u8 {
    const id = try c.req("ghsaId");
    if (id.len > 40 or !core.validSlug(id)) return core.fail(c.alloc, "invalid 'ghsaId'", .{});
    const v = try c.get(c.path("/advisories/{s}", .{id}));
    return c.obj(v, adv_row ++ ",cvss.score>cvss,cwes[].cwe_id>cwes,vulnerabilities[].package.name>packages,description~B");
}

fn advisoryQuery(c: *Call, keys: []const []const u8) !core.Q {
    var q = c.pq();
    for (keys) |k| {
        const v = c.opt(k) orelse continue;
        if (!core.validText(v, 200)) return core.fail(c.alloc, "invalid '{s}'", .{k});
        q.s(if (std.mem.eql(u8, k, "cveId")) "cve_id" else if (std.mem.eql(u8, k, "ghsaId")) "ghsa_id" else if (std.mem.eql(u8, k, "isWithdrawn")) "is_withdrawn" else k, v);
    }
    if (c.boolean("isWithdrawn")) |w| q.b("is_withdrawn", w);
    return q;
}

fn listGlobalAdvisories(c: *Call) ![]const u8 {
    const p = c.paging();
    var q = try advisoryQuery(c, &.{ "affects", "cveId", "ecosystem", "ghsaId", "modified", "published", "severity", "type", "updated" });
    const cwes = try c.strList("cwes");
    if (cwes.len > 0) q.s("cwes", try std.mem.join(c.alloc, ",", cwes));
    const v = try c.get(c.path("/advisories{s}", .{q.done()}));
    return c.list(v, adv_row, p);
}

fn listRepoAdvisories(c: *Call) ![]const u8 {
    const o = try c.owner();
    const r = try c.repo();
    const p = c.paging();
    var q = try advisoryQuery(c, &.{ "direction", "sort", "state" });
    const v = try c.get(c.path("/repos/{s}/{s}/security-advisories{s}", .{ o, r, q.done() }));
    return c.list(v, adv_row, p);
}

fn listOrgAdvisories(c: *Call) ![]const u8 {
    const org = try c.ownerKey("org");
    const p = c.paging();
    var q = try advisoryQuery(c, &.{ "direction", "sort", "state" });
    const v = try c.get(c.path("/orgs/{s}/security-advisories{s}", .{ org, q.done() }));
    return c.list(v, adv_row, p);
}

const AN = "\"alertNumber\":{\"type\":\"number\"}";
const ADV_FILTERS = "\"direction\":{\"type\":\"string\",\"enum\":[\"asc\",\"desc\"]},\"sort\":{\"type\":\"string\"},\"state\":{\"type\":\"string\"}," ++ PG;
const RESOURCE = "\"method\":{\"type\":\"string\"}," ++ OR ++ ",\"resource_id\":{\"type\":\"string\"}";

pub const tools = [_]core.Tool{
    T("actions", "actions_get", "Get an Actions resource: method=get_workflow|get_workflow_run|get_workflow_job|download_workflow_run_artifact|get_workflow_run_usage|get_workflow_run_logs_url.", S(RESOURCE, "\"method\",\"owner\",\"repo\",\"resource_id\""), actionsGet, .ro),
    T("actions", "actions_list", "List workflows, runs, jobs or artifacts: method=list_workflows|list_workflow_runs|list_workflow_jobs|list_workflow_run_artifacts.", S(RESOURCE ++ "," ++ PG ++ ",\"workflow_runs_filter\":{\"type\":\"object\",\"properties\":{\"actor\":{\"type\":\"string\"},\"branch\":{\"type\":\"string\"},\"event\":{\"type\":\"string\"},\"status\":{\"type\":\"string\"}}},\"workflow_jobs_filter\":{\"type\":\"object\",\"properties\":{\"filter\":{\"type\":\"string\",\"enum\":[\"latest\",\"all\"]}}}", "\"method\",\"owner\",\"repo\""), actionsList, .ro),
    T("actions", "actions_run_trigger", "Run/rerun/cancel a workflow or delete run logs. DESTRUCTIVE.", S("\"method\":{\"type\":\"string\",\"enum\":[\"run_workflow\",\"rerun_workflow_run\",\"rerun_failed_jobs\",\"cancel_workflow_run\",\"delete_workflow_run_logs\"]}," ++ OR ++ ",\"workflow_id\":{\"type\":\"string\"},\"ref\":{\"type\":\"string\"},\"inputs\":{\"type\":\"object\"},\"run_id\":{\"type\":\"number\"}", "\"method\",\"owner\",\"repo\""), actionsRunTrigger, .destructive),
    T("actions", "get_job_logs", "Job logs: job_id, or run_id+failed_only. return_content=true for text (tail_lines, default 500), else a URL.", S(OR ++ ",\"job_id\":{\"type\":\"number\"},\"run_id\":{\"type\":\"number\"},\"failed_only\":{\"type\":\"boolean\"},\"return_content\":{\"type\":\"boolean\"},\"tail_lines\":{\"type\":\"number\"}", "\"owner\",\"repo\""), getJobLogs, .ro),

    T("code_security", "get_code_scanning_alert", "Get a code scanning alert.", S(OR ++ "," ++ AN, "\"owner\",\"repo\",\"alertNumber\""), getCodeScanningAlert, .ro),
    T("code_security", "list_code_scanning_alerts", "List code scanning alerts.", S(OR ++ ",\"state\":{\"type\":\"string\"},\"severity\":{\"type\":\"string\"},\"tool_name\":{\"type\":\"string\"},\"ref\":{\"type\":\"string\"}," ++ PG, "\"owner\",\"repo\""), listCodeScanningAlerts, .ro),
    T("secret_protection", "get_secret_scanning_alert", "Get a secret scanning alert (secret value never returned).", S(OR ++ "," ++ AN, "\"owner\",\"repo\",\"alertNumber\""), getSecretScanningAlert, .ro),
    T("secret_protection", "list_secret_scanning_alerts", "List secret scanning alerts.", S(OR ++ ",\"state\":{\"type\":\"string\"},\"secret_type\":{\"type\":\"string\"},\"resolution\":{\"type\":\"string\"}," ++ PG, "\"owner\",\"repo\""), listSecretScanningAlerts, .ro),
    T("dependabot", "get_dependabot_alert", "Get a Dependabot alert.", S(OR ++ "," ++ AN, "\"owner\",\"repo\",\"alertNumber\""), getDependabotAlert, .ro),
    T("dependabot", "list_dependabot_alerts", "List Dependabot alerts (cursor: after).", S(OR ++ ",\"state\":{\"type\":\"string\"},\"severity\":{\"type\":\"string\"},\"after\":{\"type\":\"string\"},\"perPage\":{\"type\":\"number\"}", "\"owner\",\"repo\""), listDependabotAlerts, .ro),
    T("security_advisories", "get_global_security_advisory", "Get a global security advisory by GHSA id.", S("\"ghsaId\":{\"type\":\"string\"}," ++ core.MC, "\"ghsaId\""), getGlobalAdvisory, .ro),
    T("security_advisories", "list_global_security_advisories", "List global security advisories.", S("\"affects\":{\"type\":\"string\"},\"cveId\":{\"type\":\"string\"},\"cwes\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"ecosystem\":{\"type\":\"string\"},\"ghsaId\":{\"type\":\"string\"},\"isWithdrawn\":{\"type\":\"boolean\"},\"modified\":{\"type\":\"string\"},\"published\":{\"type\":\"string\"},\"severity\":{\"type\":\"string\"},\"type\":{\"type\":\"string\"},\"updated\":{\"type\":\"string\"}," ++ PG, ""), listGlobalAdvisories, .ro),
    T("security_advisories", "list_repository_security_advisories", "List a repository's security advisories.", S(OR ++ "," ++ ADV_FILTERS, "\"owner\",\"repo\""), listRepoAdvisories, .ro),
    T("security_advisories", "list_org_repository_security_advisories", "List security advisories across an org's repositories.", S("\"org\":{\"type\":\"string\"}," ++ ADV_FILTERS, "\"org\""), listOrgAdvisories, .ro),
};

test "tailLog strips timestamps and keeps the tail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const log = "2024-01-01T00:00:00.0000000Z one\n2024-01-01T00:00:01.0000000Z two\n2024-01-01T00:00:02.0000000Z three\n";
    const out = try tailLog(arena.allocator(), log, 2);
    try std.testing.expectEqualStrings("[log truncated: last 2 of 3 lines]\ntwo\nthree\n", out);
}
