//! zmcp-browser: browser automation over the Chrome DevTools Protocol in pure
//! Zig. Speaks JSON over a loopback WebSocket to a Chrome/Chromium/Edge that
//! it launches itself (private temp profile, headless) or, only with
//! ZMCP_BROWSER_ATTACH=1, one already running with --remote-debugging-port.
//! No bundled browser, no Node.
//!
//! Env (read once at startup):
//!   ZMCP_BROWSER_BIN=<path>          browser binary (else PATH names, default install paths)
//!   ZMCP_BROWSER_HEADED=1            show the window instead of --headless=new
//!   ZMCP_BROWSER_NO_SANDBOX=1        pass --no-sandbox (needed as root / in containers)
//!   ZMCP_BROWSER_ATTACH=1            attach to an existing browser (CDP_URL, default http://127.0.0.1:9222)
//!                                    WARNING: that drives the user's logged-in profile
//!   ZMCP_BROWSER_ALLOW_LOCAL=1       allow navigating to loopback / private hosts
//!   ZMCP_BROWSER_ALLOW_ORIGINS=a,b   only navigate to these origins/hosts (https://x.com, x.com, *.x.com)
//!   ZMCP_BROWSER_NO_EVAL=1           disable browser_evaluate
//!
//! Page text is untrusted: every tool that returns page content prefixes it
//! with a reminder.

const std = @import("std");
const builtin = @import("builtin");
const mcp = @import("mcp");
const bmod = @import("browser.zig");
const tools = @import("tools.zig");
const launch = @import("launch.zig");
const policy = @import("policy.zig");
const cdp = @import("cdp.zig");

test {
    _ = @import("ws.zig");
    _ = @import("policy.zig");
    _ = @import("snapshot.zig");
    _ = @import("cdp.zig");
    _ = @import("launch.zig");
    _ = @import("browser.zig");
    _ = @import("tools.zig");
}

pub const tool_table = [_]mcp.ToolDef{
    .{
        .name = "browser_navigate",
        .description = "Open an http(s) URL and wait for load",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\"}},\"required\":[\"url\"]}",
        .handler = tools.navigate,
    },
    .{
        .name = "browser_back",
        .description = "Go back in history",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{}}",
        .handler = tools.back,
    },
    .{
        .name = "browser_snapshot",
        .description = "Page outline with element refs (eN); take before acting",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"depth\":{\"type\":\"integer\"},\"ref\":{\"type\":\"string\"},\"max_chars\":{\"type\":\"integer\"}}}",
        .handler = tools.snapshotTool,
        .read_only = true,
    },
    .{
        .name = "browser_click",
        .description = "Click element by ref",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"ref\":{\"type\":\"string\"},\"double\":{\"type\":\"boolean\"},\"button\":{\"type\":\"string\",\"enum\":[\"left\",\"right\",\"middle\"]}},\"required\":[\"ref\"]}",
        .handler = tools.click,
    },
    .{
        .name = "browser_type",
        .description = "Type into an input by ref; clear replaces, submit presses Enter",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"ref\":{\"type\":\"string\"},\"text\":{\"type\":\"string\"},\"submit\":{\"type\":\"boolean\"},\"clear\":{\"type\":\"boolean\"}},\"required\":[\"ref\",\"text\"]}",
        .handler = tools.typeTool,
    },
    .{
        .name = "browser_press_key",
        .description = "Press a key/chord (Enter, Tab, Control+a)",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"key\":{\"type\":\"string\"}},\"required\":[\"key\"]}",
        .handler = tools.pressKeyTool,
    },
    .{
        .name = "browser_select_option",
        .description = "Select <select> option(s) by value or label",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"ref\":{\"type\":\"string\"},\"values\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}},\"required\":[\"ref\",\"values\"]}",
        .handler = tools.selectOption,
    },
    .{
        .name = "browser_hover",
        .description = "Hover element by ref",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"ref\":{\"type\":\"string\"}},\"required\":[\"ref\"]}",
        .handler = tools.hover,
    },
    .{
        .name = "browser_screenshot",
        .description = "Screenshot of viewport, element (ref) or full page; downscaled",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"ref\":{\"type\":\"string\"},\"full_page\":{\"type\":\"boolean\"},\"format\":{\"type\":\"string\",\"enum\":[\"png\",\"jpeg\"]}}}",
        .handler = tools.screenshot,
        .read_only = true,
    },
    // Unmarked on purpose: arbitrary JS can change page and account state
    // (submit forms, call APIs with the page's cookies), so it is not
    // read-only; it cannot touch the user's system outside the browser
    // (same reach as click/type), so it is not destructive either.
    .{
        .name = "browser_evaluate",
        .description = "Run JS in the page (with ref, `el` is the element); truncated",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"expression\":{\"type\":\"string\"},\"ref\":{\"type\":\"string\"}},\"required\":[\"expression\"]}",
        .handler = tools.evaluate,
    },
    .{
        .name = "browser_console",
        .description = "Console messages and page errors (min level, default info)",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"level\":{\"type\":\"string\",\"enum\":[\"error\",\"warning\",\"info\",\"debug\"]},\"clear\":{\"type\":\"boolean\"},\"limit\":{\"type\":\"integer\"}}}",
        .handler = tools.console,
        .read_only = true,
    },
    .{
        .name = "browser_network",
        .description = "Recent requests; index=#n gives one with its response body",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"filter\":{\"type\":\"string\"},\"status_min\":{\"type\":\"integer\"},\"limit\":{\"type\":\"integer\"},\"index\":{\"type\":\"integer\"}}}",
        .handler = tools.network,
        .read_only = true,
    },
    .{
        .name = "browser_tabs",
        .description = "List, open, select or close tabs",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\",\"enum\":[\"list\",\"new\",\"select\",\"close\"]},\"index\":{\"type\":\"integer\"},\"url\":{\"type\":\"string\"}},\"required\":[\"action\"]}",
        .handler = tools.tabs,
    },
    .{
        .name = "browser_wait_for",
        .description = "Wait for text to appear/disappear or a fixed time (max 30000 ms)",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"},\"text_gone\":{\"type\":\"string\"},\"time_ms\":{\"type\":\"integer\"}}}",
        .handler = tools.waitFor,
        .read_only = true,
    },
    .{
        .name = "browser_handle_dialog",
        .description = "Accept or dismiss the open alert/confirm/prompt",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"accept\":{\"type\":\"boolean\"},\"prompt_text\":{\"type\":\"string\"}},\"required\":[\"accept\"]}",
        .handler = tools.handleDialog,
    },
    .{
        .name = "browser_resize",
        .description = "Set viewport size (CSS px)",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"width\":{\"type\":\"integer\"},\"height\":{\"type\":\"integer\"}},\"required\":[\"width\",\"height\"]}",
        .handler = tools.resize,
    },
};

fn envFlag(env: *const std.process.Environ.Map, key: []const u8) bool {
    const v = env.get(key) orelse return false;
    return std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true");
}

pub fn settingsFromEnv(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) !bmod.Settings {
    var s: bmod.Settings = .{};
    s.allow_local = envFlag(env, "ZMCP_BROWSER_ALLOW_LOCAL");
    s.no_eval = envFlag(env, "ZMCP_BROWSER_NO_EVAL");
    s.attach = envFlag(env, "ZMCP_BROWSER_ATTACH");
    if (env.get("CDP_URL")) |u| if (u.len > 0) {
        s.cdp_url = u;
    };
    if (env.get("ZMCP_BROWSER_ALLOW_ORIGINS")) |o| s.origins = try policy.parseOrigins(gpa, o);
    s.launch = .{
        .bin = env.get("ZMCP_BROWSER_BIN"),
        .headed = envFlag(env, "ZMCP_BROWSER_HEADED"),
        .no_sandbox = envFlag(env, "ZMCP_BROWSER_NO_SANDBOX"),
    };
    return s;
}

pub fn main(init: std.process.Init) !void {
    bmod.g = .{ .gpa = init.gpa, .io = init.io, .env = init.environ_map };
    bmod.g.settings = try settingsFromEnv(init.gpa, init.environ_map);
    // The browser starts lazily on the first tool call; make sure it and its
    // temp profile are gone when the host closes stdin.
    defer bmod.g.teardown();
    try mcp.run(init.gpa, init.io, .{ .name = "zmcp-browser", .version = "0.1.0" }, &tool_table);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const Value = std.json.Value;

test "annotations: exactly the reading tools are read_only, nothing destructive" {
    var seen: usize = 0;
    for (tool_table) |t| {
        try testing.expect(!(t.read_only and t.destructive));
        try testing.expect(!t.destructive);
        const ro = std.mem.eql(u8, t.name, "browser_snapshot") or std.mem.eql(u8, t.name, "browser_screenshot") or
            std.mem.eql(u8, t.name, "browser_console") or std.mem.eql(u8, t.name, "browser_network") or
            std.mem.eql(u8, t.name, "browser_wait_for");
        try testing.expectEqual(ro, t.read_only);
        if (ro) seen += 1;
    }
    try testing.expectEqual(@as(usize, 5), seen);
    try testing.expectEqual(@as(usize, 16), tool_table.len);
}

test "tools/list stays small and every schema is valid JSON" {
    var total: usize = 0;
    for (tool_table) |t| {
        var p = try std.json.parseFromSlice(Value, testing.allocator, t.input_schema_json, .{});
        p.deinit();
        try testing.expect(t.description.len < 100);
        total += t.name.len + t.description.len + t.input_schema_json.len + 40;
    }
    try testing.expect(total < 4096);
}

test "settingsFromEnv" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("ZMCP_BROWSER_ALLOW_LOCAL", "1");
    try env.put("ZMCP_BROWSER_NO_EVAL", "1");
    try env.put("ZMCP_BROWSER_ALLOW_ORIGINS", "https://a.com,b.org");
    try env.put("ZMCP_BROWSER_NO_SANDBOX", "1");
    try env.put("CDP_URL", "http://127.0.0.1:9333");
    const s = try settingsFromEnv(testing.allocator, &env);
    defer testing.allocator.free(s.origins);
    try testing.expect(s.allow_local and s.no_eval and s.launch.no_sandbox);
    try testing.expect(!s.attach and !s.launch.headed);
    try testing.expectEqual(@as(usize, 2), s.origins.len);
    try testing.expectEqualStrings("http://127.0.0.1:9333", s.cdp_url);
    var env2: std.process.Environ.Map = .init(testing.allocator);
    defer env2.deinit();
    const d = try settingsFromEnv(testing.allocator, &env2);
    try testing.expect(!d.allow_local and !d.no_eval and !d.attach and !d.launch.no_sandbox);
}

// ------------------------------------------------ scripted fake CDP endpoint

const ax_fixture =
    \\{"nodes":[
    \\{"nodeId":"1","ignored":false,"role":{"value":"RootWebArea"},"name":{"value":"Demo Page"},"childIds":["2","3","4"],"backendDOMNodeId":1},
    \\{"nodeId":"2","ignored":false,"role":{"value":"heading"},"name":{"value":"Welcome"},"properties":[{"name":"level","value":{"type":"integer","value":1}}],"childIds":["5"],"parentId":"1","backendDOMNodeId":41},
    \\{"nodeId":"5","ignored":false,"role":{"value":"StaticText"},"name":{"value":"Welcome"},"parentId":"2","backendDOMNodeId":45},
    \\{"nodeId":"3","ignored":false,"role":{"value":"button"},"name":{"value":"Go"},"parentId":"1","backendDOMNodeId":42},
    \\{"nodeId":"4","ignored":false,"role":{"value":"textbox"},"name":{"value":"Name"},"parentId":"1","backendDOMNodeId":43}
    \\]}
;

const FakeState = struct {
    /// what the next mouseReleased does: 0 nothing, 1 navigate, 2 open dialog
    on_release: u8 = 0,
    redirect_to_internal: bool = false,
};
var fake_state: FakeState = .{};

fn navEvents(arena: std.mem.Allocator, out: *std.ArrayList([]const u8), url: []const u8) !void {
    try out.append(arena, try std.fmt.allocPrint(arena, "{{\"method\":\"Page.frameNavigated\",\"sessionId\":\"S1\",\"params\":{{\"frame\":{{\"id\":\"F\",\"url\":\"{s}\"}},\"type\":\"Navigation\"}}}}", .{url}));
    try out.append(arena, "{\"method\":\"Network.requestWillBeSent\",\"sessionId\":\"S1\",\"params\":{\"requestId\":\"R1\",\"request\":{\"url\":\"http://example.com/\",\"method\":\"GET\"},\"type\":\"Document\"}}");
    try out.append(arena, "{\"method\":\"Network.responseReceived\",\"sessionId\":\"S1\",\"params\":{\"requestId\":\"R1\",\"response\":{\"status\":200,\"mimeType\":\"text/html\"},\"type\":\"Document\"}}");
    try out.append(arena, "{\"method\":\"Network.loadingFinished\",\"sessionId\":\"S1\",\"params\":{\"requestId\":\"R1\"}}");
    try out.append(arena, "{\"method\":\"Runtime.consoleAPICalled\",\"sessionId\":\"S1\",\"params\":{\"type\":\"warning\",\"args\":[{\"type\":\"string\",\"value\":\"careful\"}]}}");
    try out.append(arena, "{\"method\":\"Page.loadEventFired\",\"sessionId\":\"S1\",\"params\":{\"timestamp\":1}}");
}

fn reply(arena: std.mem.Allocator, out: *std.ArrayList([]const u8), id: i64, result: []const u8) !void {
    try out.append(arena, try std.fmt.allocPrint(arena, "{{\"id\":{d},\"result\":{s}}}", .{ id, result }));
}

fn scripted(f: *cdp.Fake, arena: std.mem.Allocator, id: i64, method: []const u8, session: ?[]const u8, params: Value, out: *std.ArrayList([]const u8)) anyerror!void {
    _ = f;
    _ = session;
    const m = method;
    if (std.mem.eql(u8, m, "Target.getTargets")) {
        try reply(arena, out, id, "{\"targetInfos\":[{\"targetId\":\"T1\",\"type\":\"page\",\"title\":\"Demo Page\",\"url\":\"about:blank\"},{\"targetId\":\"W1\",\"type\":\"service_worker\",\"title\":\"sw\",\"url\":\"x\"}]}");
    } else if (std.mem.eql(u8, m, "Target.attachToTarget")) {
        try reply(arena, out, id, "{\"sessionId\":\"S1\"}");
    } else if (std.mem.eql(u8, m, "Target.getTargetInfo")) {
        try reply(arena, out, id, "{\"targetInfo\":{\"targetId\":\"T1\",\"title\":\"Demo Page\"}}");
    } else if (std.mem.eql(u8, m, "Page.navigate")) {
        const url = cdp.getStr(params, "url") orelse "";
        try reply(arena, out, id, "{\"frameId\":\"F\",\"loaderId\":\"L1\"}");
        if (std.mem.eql(u8, url, "about:blank")) {
            try navEvents(arena, out, "about:blank");
        } else if (fake_state.redirect_to_internal) {
            try navEvents(arena, out, "http://169.254.169.254/latest/meta-data/");
        } else try navEvents(arena, out, url);
    } else if (std.mem.eql(u8, m, "Accessibility.getFullAXTree")) {
        try reply(arena, out, id, ax_fixture);
    } else if (std.mem.eql(u8, m, "Page.getFrameTree")) {
        try reply(arena, out, id, "{\"frameTree\":{\"frame\":{\"id\":\"F\",\"url\":\"http://example.com/\"},\"childFrames\":[{\"frame\":{\"id\":\"F2\",\"parentId\":\"F\",\"url\":\"http://ads.example/x\"}}]}}");
    } else if (std.mem.eql(u8, m, "DOM.scrollIntoViewIfNeeded") or std.mem.eql(u8, m, "DOM.focus")) {
        const bid = cdp.getInt(params, "backendNodeId") orelse 0;
        if (bid == 999) {
            try out.append(arena, try std.fmt.allocPrint(arena, "{{\"id\":{d},\"error\":{{\"code\":-32000,\"message\":\"Could not find node with given id\"}}}}", .{id}));
        } else try reply(arena, out, id, "{}");
    } else if (std.mem.eql(u8, m, "DOM.getContentQuads")) {
        try reply(arena, out, id, "{\"quads\":[[0,0,0,0,0,0,0,0],[10,10,110,10,110,50,10,50]]}");
    } else if (std.mem.eql(u8, m, "Input.dispatchMouseEvent")) {
        const ty = cdp.getStr(params, "type") orelse "";
        try reply(arena, out, id, "{}");
        if (std.mem.eql(u8, ty, "mouseReleased")) {
            if (fake_state.on_release == 1) {
                try navEvents(arena, out, "http://example.com/next");
            } else if (fake_state.on_release == 2) {
                try out.append(arena, "{\"method\":\"Page.javascriptDialogOpening\",\"sessionId\":\"S1\",\"params\":{\"url\":\"http://example.com/\",\"message\":\"Really?\",\"type\":\"confirm\",\"hasBrowserHandler\":false}}");
            }
        }
    } else if (std.mem.eql(u8, m, "Page.handleJavaScriptDialog")) {
        try reply(arena, out, id, "{}");
        try out.append(arena, "{\"method\":\"Page.javascriptDialogClosed\",\"sessionId\":\"S1\",\"params\":{\"result\":true,\"userInput\":\"\"}}");
    } else if (std.mem.eql(u8, m, "Runtime.evaluate")) {
        const expr = cdp.getStr(params, "expression") orelse "";
        if (std.mem.indexOf(u8, expr, "innerText") != null) {
            const found = std.mem.indexOf(u8, expr, "Welcome") != null;
            try reply(arena, out, id, if (found) "{\"result\":{\"type\":\"boolean\",\"value\":true}}" else "{\"result\":{\"type\":\"boolean\",\"value\":false}}");
        } else if (std.mem.eql(u8, expr, "1+1")) {
            try reply(arena, out, id, "{\"result\":{\"type\":\"number\",\"value\":2}}");
        } else if (std.mem.eql(u8, expr, "({a:[1,2]})")) {
            try reply(arena, out, id, "{\"result\":{\"type\":\"object\",\"value\":{\"a\":[1,2]}}}");
        } else {
            try reply(arena, out, id, "{\"result\":{\"type\":\"object\",\"subtype\":\"error\"},\"exceptionDetails\":{\"exceptionId\":1,\"text\":\"Uncaught\",\"lineNumber\":0,\"columnNumber\":0,\"exception\":{\"type\":\"object\",\"description\":\"ReferenceError: nope is not defined\\n    at <anonymous>:1:1\"}}}");
        }
    } else if (std.mem.eql(u8, m, "Input.insertText") or std.mem.eql(u8, m, "Input.dispatchKeyEvent") or
        std.mem.eql(u8, m, "Emulation.setDeviceMetricsOverride") or std.mem.eql(u8, m, "Page.enable") or
        std.mem.eql(u8, m, "Runtime.enable") or std.mem.eql(u8, m, "Network.enable") or
        std.mem.eql(u8, m, "Log.enable") or std.mem.eql(u8, m, "Accessibility.enable"))
    {
        try reply(arena, out, id, "{}");
    } else if (std.mem.eql(u8, m, "Network.getResponseBody")) {
        try reply(arena, out, id, "{\"body\":\"<html>hello</html>\",\"base64Encoded\":false}");
    } else if (std.mem.eql(u8, m, "Page.getLayoutMetrics")) {
        try reply(arena, out, id, "{\"cssVisualViewport\":{\"pageX\":0,\"pageY\":0,\"clientWidth\":1280,\"clientHeight\":720},\"cssContentSize\":{\"width\":1280,\"height\":9000}}");
    } else if (std.mem.eql(u8, m, "Page.captureScreenshot")) {
        try reply(arena, out, id, "{\"data\":\"iVBORw0KGgo=\"}");
    } else {
        try out.append(arena, try std.fmt.allocPrint(arena, "{{\"id\":{d},\"error\":{{\"code\":-32601,\"message\":\"'{s}' wasn't found\"}}}}", .{ id, m }));
    }
}

const Harness = struct {
    fake: cdp.Fake,
    arena_state: std.heap.ArenaAllocator,

    fn setup(self: *Harness) !void {
        self.fake = cdp.Fake.init(testing.allocator, scripted);
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        fake_state = .{};
        bmod.g = .{ .gpa = testing.allocator, .io = testing.io };
        bmod.g.settings = .{};
        const c = try testing.allocator.create(cdp.Client);
        c.* = try cdp.Client.init(testing.allocator, testing.io, self.fake.transport());
        bmod.g.client = c;
    }
    fn teardown(self: *Harness) void {
        bmod.g.teardown();
        self.fake.deinit();
        self.arena_state.deinit();
    }
    fn a(self: *Harness) std.mem.Allocator {
        return self.arena_state.allocator();
    }
    fn args(self: *Harness, json: []const u8) !Value {
        return std.json.parseFromSliceLeaky(Value, self.a(), json, .{});
    }
};

test "e2e (fake CDP): navigate -> snapshot -> click -> stale ref" {
    var h: Harness = undefined;
    try h.setup();
    defer h.teardown();
    const a = h.a();
    const io = testing.io;

    const nav = try tools.navigate(a, io, try h.args("{\"url\":\"http://example.com/\"}"));
    try testing.expect(!nav.is_error);
    try testing.expect(std.mem.indexOf(u8, nav.text, "Navigated to http://example.com/") != null);
    try testing.expect(std.mem.indexOf(u8, nav.text, "Title: Demo Page") != null);
    try testing.expect(h.fake.saw("Page.navigate S1"));

    const snap = try tools.snapshotTool(a, io, try h.args("{}"));
    try testing.expect(!snap.is_error);
    try testing.expect(std.mem.indexOf(u8, snap.text, "Untrusted web content") != null);
    try testing.expect(std.mem.indexOf(u8, snap.text, "- heading \"Welcome\" [ref=e2] level=1") != null);
    try testing.expect(std.mem.indexOf(u8, snap.text, "- button \"Go\" [ref=e3]") != null);
    try testing.expect(std.mem.indexOf(u8, snap.text, "textbox \"Name\" [ref=e4]") != null);
    try testing.expect(std.mem.indexOf(u8, snap.text, "Other frames") != null);
    try testing.expect(std.mem.indexOf(u8, snap.text, "http://ads.example/x") != null);

    // subtree snapshot by ref
    const sub = try tools.snapshotTool(a, io, try h.args("{\"ref\":\"e3\"}"));
    try testing.expect(std.mem.indexOf(u8, sub.text, "- button \"Go\" [ref=e3]") != null);
    try testing.expect(std.mem.indexOf(u8, sub.text, "heading") == null);

    // click navigates: geometry (skips the degenerate quad), events, settle
    fake_state.on_release = 1;
    const clk = try tools.click(a, io, try h.args("{\"ref\":\"e3\"}"));
    try testing.expect(!clk.is_error);
    try testing.expect(std.mem.indexOf(u8, clk.text, "Clicked e3.") != null);
    try testing.expect(std.mem.indexOf(u8, clk.text, "Page navigated to http://example.com/next") != null);
    try testing.expect(h.fake.saw("\"type\":\"mousePressed\",\"x\":60,\"y\":30,\"button\":\"left\",\"buttons\":1,\"clickCount\":1"));
    try testing.expect(h.fake.saw("\"backendNodeId\":42"));

    // the navigation invalidated the refs
    const stale = try tools.click(a, io, try h.args("{\"ref\":\"e3\"}"));
    try testing.expect(stale.is_error);
    try testing.expect(std.mem.indexOf(u8, stale.text, "stale") != null);
    try testing.expect(std.mem.indexOf(u8, stale.text, "browser_snapshot") != null);
}

test "e2e (fake CDP): type, press key, console, network, evaluate, resize, screenshot" {
    var h: Harness = undefined;
    try h.setup();
    defer h.teardown();
    const a = h.a();
    const io = testing.io;
    _ = try tools.navigate(a, io, try h.args("{\"url\":\"https://example.com/\"}"));
    _ = try tools.snapshotTool(a, io, try h.args("{}"));

    const ty = try tools.typeTool(a, io, try h.args("{\"ref\":\"e4\",\"text\":\"Ada\",\"clear\":true,\"submit\":true}"));
    try testing.expect(!ty.is_error);
    try testing.expect(h.fake.saw("Input.insertText S1 {\"id\":") and h.fake.saw("\"text\":\"Ada\""));
    try testing.expect(h.fake.saw("\"commands\":[\"selectAll\"]"));
    try testing.expect(h.fake.saw("\"key\":\"Enter\""));
    try testing.expect(h.fake.saw("DOM.focus S1"));

    const pk = try tools.pressKeyTool(a, io, try h.args("{\"key\":\"Control+a\"}"));
    try testing.expect(!pk.is_error);
    const bad = try tools.pressKeyTool(a, io, try h.args("{\"key\":\"Nope\"}"));
    try testing.expect(bad.is_error);

    const con = try tools.console(a, io, try h.args("{}"));
    try testing.expect(std.mem.indexOf(u8, con.text, "warning: careful") != null);
    const con_err = try tools.console(a, io, try h.args("{\"level\":\"error\"}"));
    try testing.expect(std.mem.indexOf(u8, con_err.text, "careful") == null);
    try testing.expect(std.mem.indexOf(u8, con_err.text, "no console messages") != null);
    const con_bad = try tools.console(a, io, try h.args("{\"level\":\"loud\"}"));
    try testing.expect(con_bad.is_error);

    const net = try tools.network(a, io, try h.args("{}"));
    try testing.expect(std.mem.indexOf(u8, net.text, "GET 200 Document http://example.com/") != null);
    const net_f = try tools.network(a, io, try h.args("{\"status_min\":400}"));
    try testing.expect(std.mem.indexOf(u8, net_f.text, "no matching requests") != null);
    const one = try tools.network(a, io, try h.args("{\"index\":1}"));
    try testing.expect(std.mem.indexOf(u8, one.text, "body:\n<html>hello</html>") != null);
    const none = try tools.network(a, io, try h.args("{\"index\":99}"));
    try testing.expect(none.is_error);

    const ev = try tools.evaluate(a, io, try h.args("{\"expression\":\"1+1\"}"));
    try testing.expectEqualStrings("2", ev.text);
    const ev2 = try tools.evaluate(a, io, try h.args("{\"expression\":\"({a:[1,2]})\"}"));
    try testing.expectEqualStrings("{\"a\":[1,2]}", ev2.text);
    const ev3 = try tools.evaluate(a, io, try h.args("{\"expression\":\"nope\"}"));
    try testing.expect(ev3.is_error);
    try testing.expectEqualStrings("Error: ReferenceError: nope is not defined", ev3.text);
    bmod.g.settings.no_eval = true;
    const ev4 = try tools.evaluate(a, io, try h.args("{\"expression\":\"1+1\"}"));
    try testing.expect(ev4.is_error);
    try testing.expect(std.mem.indexOf(u8, ev4.text, "ZMCP_BROWSER_NO_EVAL") != null);
    bmod.g.settings.no_eval = false;

    const rs = try tools.resize(a, io, try h.args("{\"width\":800,\"height\":600}"));
    try testing.expect(!rs.is_error);
    try testing.expect(h.fake.saw("\"width\":800,\"height\":600,\"deviceScaleFactor\":1,\"mobile\":false"));
    const rs_bad = try tools.resize(a, io, try h.args("{\"width\":10,\"height\":600}"));
    try testing.expect(rs_bad.is_error);

    const shot = try tools.screenshot(a, io, try h.args("{}"));
    try testing.expect(!shot.is_error);
    try testing.expect(shot.image != null);
    try testing.expectEqualStrings("image/png", shot.image.?.mime_type);
    try testing.expectEqualStrings("iVBORw0KGgo=", shot.image.?.data_base64);
    const full = try tools.screenshot(a, io, try h.args("{\"full_page\":true,\"format\":\"jpeg\"}"));
    try testing.expectEqualStrings("image/jpeg", full.image.?.mime_type);
    try testing.expect(std.mem.indexOf(u8, full.text, "downscaled") != null);
    try testing.expect(h.fake.saw("\"captureBeyondViewport\":true"));
    try testing.expect(h.fake.saw("\"quality\":70"));

    const wf = try tools.waitFor(a, io, try h.args("{\"text\":\"Welcome\",\"time_ms\":2000}"));
    try testing.expect(!wf.is_error);
    const wf_gone = try tools.waitFor(a, io, try h.args("{\"text_gone\":\"Welcome\",\"time_ms\":300}"));
    try testing.expect(wf_gone.is_error);
    try testing.expect(std.mem.indexOf(u8, wf_gone.text, "Timed out") != null);
    const wf_time = try tools.waitFor(a, io, try h.args("{\"time_ms\":10}"));
    try testing.expect(!wf_time.is_error);
    const wf_none = try tools.waitFor(a, io, try h.args("{}"));
    try testing.expect(wf_none.is_error);
}

test "e2e (fake CDP): URL policy blocks before any CDP traffic; redirects to internal hosts are undone" {
    var h: Harness = undefined;
    try h.setup();
    defer h.teardown();
    const a = h.a();
    const io = testing.io;
    for ([_][]const u8{
        "{\"url\":\"file:///etc/passwd\"}",
        "{\"url\":\"chrome://settings\"}",
        "{\"url\":\"data:text/html,hi\"}",
        "{\"url\":\"http://127.0.0.1:9222/json\"}",
        "{\"url\":\"http://169.254.169.254/\"}",
    }) |j| {
        const r = try tools.navigate(a, io, try h.args(j));
        try testing.expect(r.is_error);
        try testing.expect(std.mem.indexOf(u8, r.text, "blocked") != null);
    }
    try testing.expect(!h.fake.saw("Page.navigate"));

    // A public URL that redirects to the metadata service.
    fake_state.redirect_to_internal = true;
    const r = try tools.navigate(a, io, try h.args("{\"url\":\"http://example.com/redir\"}"));
    try testing.expect(r.is_error);
    try testing.expect(std.mem.indexOf(u8, r.text, "blocked URL") != null);
    try testing.expect(h.fake.saw("\"url\":\"about:blank\""));

    // ALLOW_LOCAL lifts the host rule (not the scheme rule).
    fake_state.redirect_to_internal = false;
    bmod.g.settings.allow_local = true;
    const ok = try tools.navigate(a, io, try h.args("{\"url\":\"http://127.0.0.1:8000/\"}"));
    try testing.expect(!ok.is_error);
    const still = try tools.navigate(a, io, try h.args("{\"url\":\"file:///etc/passwd\"}"));
    try testing.expect(still.is_error);
    // Allowlist.
    bmod.g.settings.allow_local = false;
    const origins = [_][]const u8{"example.com"};
    bmod.g.settings.origins = &origins;
    const off = try tools.navigate(a, io, try h.args("{\"url\":\"https://other.org/\"}"));
    try testing.expect(off.is_error);
    try testing.expect(std.mem.indexOf(u8, off.text, "ZMCP_BROWSER_ALLOW_ORIGINS") != null);
    bmod.g.settings.origins = &.{};
}

test "e2e (fake CDP): a click that opens a dialog reports it; other actions refuse until handled" {
    var h: Harness = undefined;
    try h.setup();
    defer h.teardown();
    const a = h.a();
    const io = testing.io;
    _ = try tools.navigate(a, io, try h.args("{\"url\":\"http://example.com/\"}"));
    _ = try tools.snapshotTool(a, io, try h.args("{}"));

    fake_state.on_release = 2;
    const clk = try tools.click(a, io, try h.args("{\"ref\":\"e3\"}"));
    try testing.expect(!clk.is_error);
    try testing.expect(std.mem.indexOf(u8, clk.text, "confirm dialog is open: \"Really?\"") != null);

    const blocked = try tools.snapshotTool(a, io, try h.args("{}"));
    try testing.expect(blocked.is_error);
    try testing.expect(std.mem.indexOf(u8, blocked.text, "browser_handle_dialog") != null);

    const hd = try tools.handleDialog(a, io, try h.args("{\"accept\":true}"));
    try testing.expect(!hd.is_error);
    try testing.expect(std.mem.indexOf(u8, hd.text, "Accepted") != null);
    try testing.expect(h.fake.saw("\"accept\":true"));
    const none = try tools.handleDialog(a, io, try h.args("{\"accept\":true}"));
    try testing.expect(none.is_error);

    fake_state.on_release = 0;
    const after = try tools.snapshotTool(a, io, try h.args("{}"));
    try testing.expect(!after.is_error);
}

test "e2e (fake CDP): tabs list, refusing to close the last tab, stale node" {
    var h: Harness = undefined;
    try h.setup();
    defer h.teardown();
    const a = h.a();
    const io = testing.io;
    const list = try tools.tabs(a, io, try h.args("{\"action\":\"list\"}"));
    try testing.expect(!list.is_error);
    try testing.expect(std.mem.indexOf(u8, list.text, "[0] * Demo Page - about:blank") != null);
    try testing.expect(std.mem.indexOf(u8, list.text, "[1]") == null); // only page targets
    const close = try tools.tabs(a, io, try h.args("{\"action\":\"close\"}"));
    try testing.expect(close.is_error);
    try testing.expect(std.mem.indexOf(u8, close.text, "last tab") != null);
    const sel = try tools.tabs(a, io, try h.args("{\"action\":\"select\",\"index\":5}"));
    try testing.expect(sel.is_error);
    const badact = try tools.tabs(a, io, try h.args("{\"action\":\"explode\"}"));
    try testing.expect(badact.is_error);
    const new_blocked = try tools.tabs(a, io, try h.args("{\"action\":\"new\",\"url\":\"file:///x\"}"));
    try testing.expect(new_blocked.is_error);

    // A ref whose node vanished maps to the re-snapshot hint.
    _ = try tools.navigate(a, io, try h.args("{\"url\":\"http://example.com/\"}"));
    _ = try tools.snapshotTool(a, io, try h.args("{}"));
    bmod.g.refs[2] = 999; // e3 now points at a node the fake reports as gone
    const gone = try tools.click(a, io, try h.args("{\"ref\":\"e3\"}"));
    try testing.expect(gone.is_error);
    try testing.expect(std.mem.indexOf(u8, gone.text, "stale") != null);
}

fn refOf(text: []const u8, needle: []const u8) ?[]const u8 {
    const i = std.mem.indexOf(u8, text, needle) orelse return null;
    const r = std.mem.indexOfPos(u8, text, i, "[ref=") orelse return null;
    const e = std.mem.indexOfScalarPos(u8, text, r, ']') orelse return null;
    return text[r + 5 .. e];
}

// Opt-in: needs a real Chromium-family binary.
//   ZMCP_BROWSER_TEST_BIN=/path/to/chrome [ZMCP_BROWSER_TEST_NO_SANDBOX=1] zig test ...
test "real Chrome smoke: navigate, evaluate, snapshot, type, click, console, screenshot (opt-in)" {
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    const bin = env.get("ZMCP_BROWSER_TEST_BIN") orelse return error.SkipZigTest;
    bmod.g = .{ .gpa = testing.allocator, .io = testing.io, .env = &env };
    bmod.g.settings.launch = .{ .bin = bin, .no_sandbox = env.get("ZMCP_BROWSER_TEST_NO_SANDBOX") != null };
    defer bmod.g.teardown();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = testing.io;

    const nav = try tools.navigate(a, io, try std.json.parseFromSliceLeaky(Value, a, "{\"url\":\"about:blank\"}", .{}));
    try testing.expect(!nav.is_error);
    const setup = try tools.evaluate(a, io, try std.json.parseFromSliceLeaky(Value, a,
        \\{"expression":"document.body.innerHTML='<input aria-label=Name><button onclick=\"document.title=document.querySelector(\\'input\\').value;console.log(\\'clicked\\')\">Go</button>'; 7"}
    , .{}));
    try testing.expectEqualStrings("7", setup.text);
    const snap = try tools.snapshotTool(a, io, try std.json.parseFromSliceLeaky(Value, a, "{}", .{}));
    try testing.expect(!snap.is_error);
    const name_ref = refOf(snap.text, "textbox \"Name\"") orelse return error.NoTextbox;
    const go_ref = refOf(snap.text, "button \"Go\"") orelse return error.NoButton;
    const ty = try tools.typeTool(a, io, try std.json.parseFromSliceLeaky(Value, a, try std.fmt.allocPrint(a, "{{\"ref\":\"{s}\",\"text\":\"zig\"}}", .{name_ref}), .{}));
    try testing.expect(!ty.is_error);
    const ck = try tools.click(a, io, try std.json.parseFromSliceLeaky(Value, a, try std.fmt.allocPrint(a, "{{\"ref\":\"{s}\"}}", .{go_ref}), .{}));
    try testing.expect(!ck.is_error);
    const title = try tools.evaluate(a, io, try std.json.parseFromSliceLeaky(Value, a, "{\"expression\":\"document.title\"}", .{}));
    try testing.expectEqualStrings("zig", title.text);
    const con = try tools.console(a, io, try std.json.parseFromSliceLeaky(Value, a, "{}", .{}));
    try testing.expect(std.mem.indexOf(u8, con.text, "info: clicked") != null);
    const shot = try tools.screenshot(a, io, try std.json.parseFromSliceLeaky(Value, a, "{}", .{}));
    try testing.expect(shot.image != null);
    var raw: [18]u8 = undefined;
    try std.base64.standard.Decoder.decode(&raw, shot.image.?.data_base64[0..24]);
    try testing.expectEqualStrings("\x89PNG\r\n\x1a\n", raw[0..8]);
}
