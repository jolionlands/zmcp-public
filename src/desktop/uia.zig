//! Read-only UI Automation over the generated vtables in uia_com.zig.
//!
//! An observe walks the ControlView level by level (`.levels`, the default:
//! one cross-process call per expanded node returns its children with their
//! properties). `.walker` (one call per node, exact caps) and `.subtree` are
//! kept for tests and `--bench` only; see `default_strategy` for the numbers
//! and the known limit.
//! Every walk also stops at a wall-clock budget and a byte budget.
//! UIA runs with a 1 s connection and a 3 s transaction timeout
//! (IUIAutomation2 from CUIAutomation8), so a hung provider can't hang us.
//! Names and values are capped at 500 chars as they are converted; the UIA
//! API has no way to cap a BSTR before it crosses the process boundary.
//!
//! Values are read only for non-password elements of a few input roles, one
//! element at a time, after the cached IsPassword came back false; a password
//! field's value is never requested.
//!
//! Text (TextPattern DocumentRange, capped by GetText's maxLength) is read the
//! same way, for the fields a ValuePattern cannot read: a focusable edit,
//! group or custom element with a TextPattern (a contenteditable composer in
//! Chromium/Electron, a RichEdit). IsPassword is checked cached AND live
//! right before the read; a document (a whole web page) is never read.
//!
//! The act primitives (Z3: invoke, set value, focus, select, expand, scroll)
//! are thin pattern calls; every policy check (allowlist re-validation,
//! password and payment refusals, kill event, lock, user input, limits) runs
//! in main.zig before any of them.

const std = @import("std");
const com = @import("uia_com.zig");
const policy = @import("policy.zig");

pub const GUID = com.GUID;
pub const RECT = com.RECT;
pub const HRESULT = com.HRESULT;
pub const VARIANT = com.VARIANT;
pub const HWND = *anyopaque;

const COINIT_MULTITHREADED: u32 = 0x0;
const CLSCTX_INPROC_SERVER: u32 = 0x1;
const S_OK: HRESULT = 0;
const S_FALSE: HRESULT = 1;
const RPC_E_CHANGED_MODE: HRESULT = @bitCast(@as(u32, 0x80010106));

pub const TreeScope = struct {
    pub const element: i32 = 1;
    pub const children: i32 = 2;
    pub const descendants: i32 = 4;
    pub const subtree: i32 = 7;
};

pub const VT_EMPTY: u16 = 0;
pub const VT_I4: u16 = 3;
pub const VT_BSTR: u16 = 8;
pub const VT_BOOL: u16 = 11;
pub const VT_ARRAY: u16 = 0x2000;

pub extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, coinit: u32) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;
pub extern "ole32" fn CoCreateInstance(rclsid: *const GUID, outer: ?*anyopaque, cls_context: u32, riid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT;
pub extern "oleaut32" fn SysFreeString(bstr: ?[*]u16) callconv(.winapi) void;
pub extern "oleaut32" fn SysStringLen(bstr: ?[*]u16) callconv(.winapi) u32;
extern "oleaut32" fn SysAllocStringLen(s: [*]const u16, len: u32) callconv(.winapi) ?[*]u16;

/// UIA ScrollAmount.
pub const ScrollAmount = enum(i32) { large_decrement = 0, small_decrement = 1, none = 2, large_increment = 3, small_increment = 4 };
pub extern "oleaut32" fn VariantClear(v: *VARIANT) callconv(.winapi) HRESULT;
extern "oleaut32" fn SafeArrayCreateVector(vt: u16, lbound: i32, count: u32) callconv(.winapi) ?*anyopaque;
extern "oleaut32" fn SafeArrayAccessData(psa: *anyopaque, data: *?*anyopaque) callconv(.winapi) HRESULT;
extern "oleaut32" fn SafeArrayUnaccessData(psa: *anyopaque) callconv(.winapi) HRESULT;
extern "oleaut32" fn SafeArrayGetLBound(psa: *anyopaque, dim: u32, out: *i32) callconv(.winapi) HRESULT;
extern "oleaut32" fn SafeArrayGetUBound(psa: *anyopaque, dim: u32, out: *i32) callconv(.winapi) HRESULT;
extern "oleaut32" fn SafeArrayDestroy(psa: *anyopaque) callconv(.winapi) HRESULT;
extern "kernel32" fn QueryPerformanceCounter(out: *i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(out: *i64) callconv(.winapi) i32;

pub const connection_timeout_ms: u32 = 1000;
pub const transaction_timeout_ms: u32 = 3000;

fn nowMs() u64 {
    var t: i64 = 0;
    var f: i64 = 1;
    _ = QueryPerformanceCounter(&t);
    _ = QueryPerformanceFrequency(&f);
    return @intCast(@divTrunc(@as(i128, t) * 1000, f));
}

fn failed(hr: HRESULT) bool {
    return hr < 0;
}

/// The properties every observed node carries (one bulk fetch).
const node_props = [_]i32{
    com.UIA_RuntimeIdPropertyId,          com.UIA_NamePropertyId,
    com.UIA_ControlTypePropertyId,        com.UIA_BoundingRectanglePropertyId,
    com.UIA_IsEnabledPropertyId,          com.UIA_IsKeyboardFocusablePropertyId,
    com.UIA_IsPasswordPropertyId,         com.UIA_IsValuePatternAvailablePropertyId,
    com.UIA_ProcessIdPropertyId,          com.UIA_AutomationIdPropertyId,
    com.UIA_ClassNamePropertyId,          com.UIA_IsTextPatternAvailablePropertyId,
};

/// `.walker`: one TreeWalker call per node (first child / next sibling, with
/// the element's properties cached), so max_nodes and the byte budget are
/// exact per node. `.levels`: one call per expanded node returns all its
/// children. `.subtree`: one call for the whole tree (unbounded; tests and
/// the bench only, never reachable from a tool call).
pub const Strategy = enum { walker, levels, subtree };

pub const TruncatedBy = enum { nodes, time, bytes };

/// `.levels`, not `.walker`: on 245 (Edge, 280 nodes) the walker's p50 was
/// 199 ms against 119 ms for levels, past the 150 ms gate. Known limit of
/// `.levels`: one call returns ALL children of an expanded node, so a single
/// node with thousands of children is fetched whole before max_nodes and the
/// byte budget apply to the reply. That call is bounded by the UIA 3 s
/// transaction timeout, and the time budget is checked between calls.
pub const default_strategy: Strategy = .levels;

pub const ObserveOptions = struct {
    max_depth: u8 = 8,
    max_nodes: usize = 400,
    strategy: Strategy = default_strategy,
    /// Wall-clock budget for the whole walk (values included).
    time_budget_ms: u64 = 2000,
    /// Budget for the text and ids held in memory for the reply.
    byte_budget: usize = 4 * 1024 * 1024,
    /// Read ValuePattern values (non-password input roles only).
    values: bool = true,
    /// At most this many value reads (one cross-process call each).
    max_values: usize = 32,
    /// Read TextPattern text (policy.wantsText elements only).
    texts: bool = true,
    /// At most this many text reads (three cross-process calls each). High
    /// enough that a window's message field is always among them (Signal
    /// has two text fields: the search box and the composer).
    max_texts: usize = 32,
};

/// One observed element. Slices are owned by the allocator passed to the
/// walk (the tool handler's arena).
pub const RawNode = struct {
    rid: []i32,
    parent: i32,
    depth: u8,
    control_type: i32,
    name: []u8,
    value: ?[]u8 = null,
    rect: RECT,
    enabled: bool,
    focusable: bool,
    is_password: bool,
    has_value: bool,
    pid: i32,
    /// UIA AutomationId and ClassName (structure, not content): what a host
    /// profile keys controls on (compose field, send button).
    automation_id: []u8 = &.{},
    class_name: []u8 = &.{},
    /// The element has a TextPattern.
    has_text: bool = false,
    /// TextPattern DocumentRange text (policy.wantsText elements only;
    /// never for a password field).
    text: ?[]u8 = null,
    /// `text` was cut at max_text_chars (the field holds more).
    text_truncated: bool = false,
};

pub const Observation = struct {
    nodes: []RawNode,
    truncated: bool,
    truncated_by: ?TruncatedBy = null,
};

pub const Uia = struct {
    automation: *com.IUIAutomation,
    /// The same object as IUIAutomation2 (timeouts).
    automation2: *com.IUIAutomation2,
    /// Subtree scope: the whole ControlView under the root in one call.
    req_tree: *com.IUIAutomationCacheRequest,
    /// Element + children: one level per call.
    req_level: *com.IUIAutomationCacheRequest,
    /// Element only (focus, resolve, the walker).
    req_el: *com.IUIAutomationCacheRequest,
    /// ControlView TreeWalker.
    walker: *com.IUIAutomationTreeWalker,
    owns_com: bool,

    pub fn init() !Uia {
        const hr_init = CoInitializeEx(null, COINIT_MULTITHREADED);
        const owns_com = hr_init == S_OK or hr_init == S_FALSE;
        if (!owns_com and hr_init != RPC_E_CHANGED_MODE) return error.CoInitializeFailed;
        errdefer if (owns_com) CoUninitialize();

        var raw: ?*anyopaque = null;
        const hr = CoCreateInstance(&com.CLSID_CUIAutomation8, null, CLSCTX_INPROC_SERVER, &com.IID_IUIAutomation, &raw);
        if (failed(hr) or raw == null) return error.CoCreateInstanceFailed;
        const automation: *com.IUIAutomation = @ptrCast(@alignCast(raw.?));
        errdefer _ = automation.vtbl.Release(automation);

        var raw2: ?*anyopaque = null;
        if (failed(automation.vtbl.QueryInterface(automation, &com.IID_IUIAutomation2, &raw2)) or raw2 == null)
            return error.NoIUIAutomation2;
        const automation2: *com.IUIAutomation2 = @ptrCast(@alignCast(raw2.?));
        errdefer _ = automation2.vtbl.Release(automation2);
        if (failed(automation2.vtbl.put_ConnectionTimeout(automation2, connection_timeout_ms))) return error.SetTimeoutFailed;
        if (failed(automation2.vtbl.put_TransactionTimeout(automation2, transaction_timeout_ms))) return error.SetTimeoutFailed;

        const req_tree = try newRequest(automation, TreeScope.subtree);
        errdefer _ = req_tree.vtbl.Release(req_tree);
        const req_level = try newRequest(automation, TreeScope.element | TreeScope.children);
        errdefer _ = req_level.vtbl.Release(req_level);
        const req_el = try newRequest(automation, TreeScope.element);
        errdefer _ = req_el.vtbl.Release(req_el);
        var walker: ?*com.IUIAutomationTreeWalker = null;
        if (failed(automation.vtbl.get_ControlViewWalker(automation, &walker)) or walker == null) return error.NoControlViewWalker;
        return .{ .automation = automation, .automation2 = automation2, .req_tree = req_tree, .req_level = req_level, .req_el = req_el, .walker = walker.?, .owns_com = owns_com };
    }

    fn newRequest(automation: *com.IUIAutomation, scope: i32) !*com.IUIAutomationCacheRequest {
        var out: ?*com.IUIAutomationCacheRequest = null;
        if (failed(automation.vtbl.CreateCacheRequest(automation, &out)) or out == null) return error.CreateCacheRequestFailed;
        const c = out.?;
        errdefer _ = c.vtbl.Release(c);
        for (node_props) |pid| if (failed(c.vtbl.AddProperty(c, pid))) return error.AddPropertyFailed;
        // The default TreeFilter is the ControlView condition, which is what we want.
        if (failed(c.vtbl.put_TreeScope(c, scope))) return error.PutTreeScopeFailed;
        return c;
    }

    pub fn deinit(self: Uia) void {
        _ = self.walker.vtbl.Release(self.walker);
        _ = self.req_el.vtbl.Release(self.req_el);
        _ = self.req_level.vtbl.Release(self.req_level);
        _ = self.req_tree.vtbl.Release(self.req_tree);
        _ = self.automation2.vtbl.Release(self.automation2);
        _ = self.automation.vtbl.Release(self.automation);
        if (self.owns_com) CoUninitialize();
    }

    pub fn timeouts(self: Uia) [2]u32 {
        var c: u32 = 0;
        var t: u32 = 0;
        _ = self.automation2.vtbl.get_ConnectionTimeout(self.automation2, &c);
        _ = self.automation2.vtbl.get_TransactionTimeout(self.automation2, &t);
        return .{ c, t };
    }

    pub fn elementFromHandle(self: Uia, hwnd: HWND) !Element {
        var el: ?*com.IUIAutomationElement = null;
        if (failed(self.automation.vtbl.ElementFromHandle(self.automation, hwnd, &el)) or el == null) return error.ElementFromHandleFailed;
        return .{ .ptr = el.? };
    }

    pub fn elementFromHandleCached(self: Uia, hwnd: HWND, req: *com.IUIAutomationCacheRequest) !Element {
        var el: ?*com.IUIAutomationElement = null;
        if (failed(self.automation.vtbl.ElementFromHandleBuildCache(self.automation, hwnd, req, &el)) or el == null) return error.ElementFromHandleFailed;
        return .{ .ptr = el.? };
    }

    /// The focused element (anywhere on the desktop), with node_props cached.
    /// The caller checks its process before using anything from it.
    pub fn focusedCached(self: Uia) !Element {
        var el: ?*com.IUIAutomationElement = null;
        if (failed(self.automation.vtbl.GetFocusedElementBuildCache(self.automation, self.req_el, &el)) or el == null) return error.NoFocusedElement;
        return .{ .ptr = el.? };
    }

    /// `CreatePropertyCondition(property_id, value)`: the VARIANT goes by value.
    pub fn propertyCondition(self: Uia, property_id: i32, value: VARIANT) !Condition {
        var c: ?*com.IUIAutomationCondition = null;
        const hr = self.automation.vtbl.CreatePropertyCondition(self.automation, property_id, value, &c);
        if (failed(hr) or c == null) return error.CreatePropertyConditionFailed;
        return .{ .ptr = c.? };
    }

    /// The element of `hwnd`'s subtree whose runtime id is `rid`, with
    /// `req`'s properties (and scope) cached. Stateless: re-resolved per call.
    pub fn resolve(self: Uia, hwnd: HWND, rid: []const i32, req: *com.IUIAutomationCacheRequest) !Element {
        var v = try runtimeIdVariant(rid);
        defer _ = VariantClear(&v);
        const cond = try self.propertyCondition(com.UIA_RuntimeIdPropertyId, v);
        defer cond.release();
        const root = try self.elementFromHandle(hwnd);
        defer root.release();
        return root.findFirst(TreeScope.subtree, cond, req) orelse error.ElementNotFound;
    }

    /// The ControlView parent of `el` (with req_el's properties), or null at the root.
    pub fn parentOf(self: Uia, el: Element) ?Element {
        var out: ?*com.IUIAutomationElement = null;
        if (failed(self.walker.vtbl.GetParentElementBuildCache(self.walker, el.ptr, self.req_el, &out))) return null;
        return if (out) |p| .{ .ptr = p } else null;
    }

    /// The element at a screen point, with req_el's properties cached.
    pub fn elementFromPoint(self: Uia, x: i32, y: i32) !Element {
        var el: ?*com.IUIAutomationElement = null;
        if (failed(self.automation.vtbl.ElementFromPointBuildCache(self.automation, .{ .x = x, .y = y }, self.req_el, &el)) or el == null)
            return error.NoElementAtPoint;
        return .{ .ptr = el.? };
    }

    /// Walk the ControlView under `hwnd` (or under the element `root_rid`).
    pub fn observe(self: Uia, allocator: std.mem.Allocator, hwnd: HWND, root_rid: ?[]const i32, opts: ObserveOptions) !Observation {
        const req = switch (opts.strategy) {
            .subtree => self.req_tree,
            .levels => self.req_level,
            .walker => self.req_el,
        };
        const root = if (root_rid) |rid| try self.resolve(hwnd, rid, req) else try self.elementFromHandleCached(hwnd, req);
        defer root.release();
        var w: Walk = .{ .uia = self, .allocator = allocator, .opts = opts, .t0 = nowMs() };
        defer w.releaseTargets();
        try w.visit(root, -1, 0, true);
        // Texts first: a message field's text is what a host verifies a send
        // with, so the value pass can't use up the time budget before it.
        if (opts.texts) w.fillTexts();
        if (opts.values) w.fillValues();
        return .{ .nodes = try w.nodes.toOwnedSlice(allocator), .truncated = w.truncated_by != null, .truncated_by = w.truncated_by };
    }

    const Target = struct { idx: usize, el: Element };

    const Walk = struct {
        uia: Uia,
        allocator: std.mem.Allocator,
        opts: ObserveOptions,
        nodes: std.ArrayList(RawNode) = .empty,
        /// Elements kept alive for the value pass (index-aligned subset).
        value_targets: std.ArrayList(Target) = .empty,
        /// Elements kept alive for the text pass.
        text_targets: std.ArrayList(Target) = .empty,
        truncated_by: ?TruncatedBy = null,
        t0: u64,
        bytes: usize = 0,

        /// The budgets, checked before every node after the root and before
        /// every cross-process call.
        fn overBudget(self: *Walk) bool {
            if (self.truncated_by != null) return true;
            if (self.nodes.items.len >= self.opts.max_nodes) {
                self.truncated_by = .nodes;
            } else if (nowMs() -| self.t0 >= self.opts.time_budget_ms) {
                self.truncated_by = .time;
            } else if (self.bytes >= self.opts.byte_budget) {
                self.truncated_by = .bytes;
            }
            return self.truncated_by != null;
        }

        fn visit(self: *Walk, el: Element, parent: i32, depth: u8, is_root: bool) error{OutOfMemory}!void {
            if (!is_root and self.overBudget()) return;
            const idx = self.nodes.items.len;
            const node = try el.cachedNode(self.allocator, parent, depth);
            self.bytes += @sizeOf(RawNode) + node.name.len + node.automation_id.len + node.class_name.len + node.rid.len * @sizeOf(i32);
            try self.nodes.append(self.allocator, node);
            if (self.opts.values and !node.is_password and node.has_value and policy.roleHasUsefulValue(node.control_type) and
                self.value_targets.items.len < self.opts.max_values)
            {
                _ = el.ptr.vtbl.AddRef(el.ptr);
                try self.value_targets.append(self.allocator, .{ .idx = idx, .el = el });
            }
            if (self.opts.texts and policy.wantsText(node.control_type, node.focusable, node.is_password, node.has_text) and
                self.text_targets.items.len < self.opts.max_texts)
            {
                _ = el.ptr.vtbl.AddRef(el.ptr);
                try self.text_targets.append(self.allocator, .{ .idx = idx, .el = el });
            }
            if (depth >= self.opts.max_depth) return;

            if (self.opts.strategy == .walker) return self.walkChildren(el, idx, depth);

            // `.levels`: every non-root node fetches its own children (one call).
            var holder: ?Element = null;
            defer if (holder) |h| h.release();
            var src = el;
            if (self.opts.strategy == .levels and !is_root) {
                if (self.overBudget()) return;
                holder = el.buildUpdatedCache(self.uia.req_level) catch return;
                src = holder.?;
            }
            const arr = src.cachedChildren() orelse return;
            defer arr.release();
            const n = arr.len();
            var i: i32 = 0;
            while (i < n) : (i += 1) {
                const child = arr.get(i) orelse continue;
                defer child.release();
                try self.visit(child, @intCast(idx), depth + 1, false);
                if (self.truncated_by != null) return;
            }
        }

        /// One cross-process call per child, each checked against the budgets first.
        fn walkChildren(self: *Walk, el: Element, idx: usize, depth: u8) error{OutOfMemory}!void {
            const w = self.uia.walker;
            if (self.overBudget()) return;
            var out: ?*com.IUIAutomationElement = null;
            if (failed(w.vtbl.GetFirstChildElementBuildCache(w, el.ptr, self.uia.req_el, &out))) return;
            var cur: ?Element = if (out) |p| .{ .ptr = p } else null;
            while (cur) |c| {
                defer c.release();
                try self.visit(c, @intCast(idx), depth + 1, false);
                if (self.overBudget()) return;
                var next: ?*com.IUIAutomationElement = null;
                if (failed(w.vtbl.GetNextSiblingElementBuildCache(w, c.ptr, self.uia.req_el, &next))) return;
                cur = if (next) |p| .{ .ptr = p } else null;
            }
        }

        fn releaseTargets(self: *Walk) void {
            for (self.value_targets.items) |vt| vt.el.release();
            self.value_targets.deinit(self.allocator);
            for (self.text_targets.items) |tt| tt.el.release();
            self.text_targets.deinit(self.allocator);
        }

        fn fillValues(self: *Walk) void {
            for (self.value_targets.items) |vt| {
                const node = &self.nodes.items[vt.idx];
                if (node.is_password) continue; // belt and braces: never for a password field
                if (nowMs() -| self.t0 >= self.opts.time_budget_ms) {
                    self.truncated_by = self.truncated_by orelse .time;
                    return;
                }
                if (self.bytes >= self.opts.byte_budget) {
                    self.truncated_by = self.truncated_by orelse .bytes;
                    return;
                }
                node.value = vt.el.currentValue(self.allocator) catch null;
                if (node.value) |v| self.bytes += v.len;
            }
        }

        fn fillTexts(self: *Walk) void {
            for (self.text_targets.items) |tt| {
                const node = &self.nodes.items[tt.idx];
                if (nowMs() -| self.t0 >= self.opts.time_budget_ms) {
                    self.truncated_by = self.truncated_by orelse .time;
                    return;
                }
                if (self.bytes >= self.opts.byte_budget) {
                    self.truncated_by = self.truncated_by orelse .bytes;
                    return;
                }
                tt.el.fillText(self.allocator, node);
                if (node.text) |t| self.bytes += t.len;
            }
        }
    };
};

pub const Condition = struct {
    ptr: *com.IUIAutomationCondition,
    pub fn release(self: Condition) void {
        _ = self.ptr.vtbl.Release(self.ptr);
    }
};

pub const ElementArray = struct {
    ptr: *com.IUIAutomationElementArray,
    pub fn release(self: ElementArray) void {
        _ = self.ptr.vtbl.Release(self.ptr);
    }
    pub fn len(self: ElementArray) i32 {
        var n: i32 = 0;
        if (failed(self.ptr.vtbl.get_Length(self.ptr, &n))) return 0;
        return n;
    }
    pub fn get(self: ElementArray, i: i32) ?Element {
        var el: ?*com.IUIAutomationElement = null;
        if (failed(self.ptr.vtbl.GetElement(self.ptr, i, &el))) return null;
        return if (el) |p| .{ .ptr = p } else null;
    }
};

pub const Element = struct {
    ptr: *com.IUIAutomationElement,

    pub fn release(self: Element) void {
        _ = self.ptr.vtbl.Release(self.ptr);
    }

    pub fn currentName(self: Element, allocator: std.mem.Allocator) ![]u8 {
        var b: ?[*]u16 = null;
        if (failed(self.ptr.vtbl.get_CurrentName(self.ptr, &b))) return error.GetNameFailed;
        return bstrToUtf8(allocator, b);
    }

    pub fn findFirst(self: Element, scope: i32, cond: Condition, req: *com.IUIAutomationCacheRequest) ?Element {
        var el: ?*com.IUIAutomationElement = null;
        if (failed(self.ptr.vtbl.FindFirstBuildCache(self.ptr, scope, cond.ptr, req, &el))) return null;
        return if (el) |p| .{ .ptr = p } else null;
    }

    pub fn buildUpdatedCache(self: Element, req: *com.IUIAutomationCacheRequest) !Element {
        var el: ?*com.IUIAutomationElement = null;
        if (failed(self.ptr.vtbl.BuildUpdatedCache(self.ptr, req, &el)) or el == null) return error.BuildUpdatedCacheFailed;
        return .{ .ptr = el.? };
    }

    pub fn cachedChildren(self: Element) ?ElementArray {
        var arr: ?*com.IUIAutomationElementArray = null;
        if (failed(self.ptr.vtbl.GetCachedChildren(self.ptr, &arr))) return null;
        return if (arr) |p| .{ .ptr = p } else null;
    }

    fn cachedVariant(self: Element, property_id: i32) VARIANT {
        var v: VARIANT = .{ .vt = VT_EMPTY };
        if (failed(self.ptr.vtbl.GetCachedPropertyValue(self.ptr, property_id, &v))) return .{ .vt = VT_EMPTY };
        return v;
    }

    fn cachedBool(self: Element, property_id: i32) bool {
        var v = self.cachedVariant(property_id);
        defer _ = VariantClear(&v);
        return v.vt == VT_BOOL and @as(u16, @truncate(v.data[0])) != 0;
    }

    fn cachedI32(self: Element, property_id: i32) i32 {
        var v = self.cachedVariant(property_id);
        defer _ = VariantClear(&v);
        return if (v.vt == VT_I4) @bitCast(@as(u32, @truncate(v.data[0]))) else 0;
    }

    pub fn cachedRuntimeId(self: Element, allocator: std.mem.Allocator) ![]i32 {
        var v = self.cachedVariant(com.UIA_RuntimeIdPropertyId);
        defer _ = VariantClear(&v);
        if (v.vt != (VT_ARRAY | VT_I4)) return allocator.alloc(i32, 0);
        const psa: *anyopaque = @ptrFromInt(@as(usize, @intCast(v.data[0])));
        return safeArrayI32(allocator, psa);
    }

    pub fn cachedProcessId(self: Element) i32 {
        var pid: i32 = 0;
        if (failed(self.ptr.vtbl.get_CachedProcessId(self.ptr, &pid))) return 0;
        return pid;
    }

    /// Everything the observe needs, from the cache (no cross-process call).
    pub fn cachedNode(self: Element, allocator: std.mem.Allocator, parent: i32, depth: u8) !RawNode {
        var name_b: ?[*]u16 = null;
        const name = if (failed(self.ptr.vtbl.get_CachedName(self.ptr, &name_b)))
            try allocator.alloc(u8, 0)
        else
            try bstrToUtf8(allocator, name_b);
        var ct: i32 = 0;
        _ = self.ptr.vtbl.get_CachedControlType(self.ptr, &ct);
        var r: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        _ = self.ptr.vtbl.get_CachedBoundingRectangle(self.ptr, &r);
        var en: i32 = 0;
        var fo: i32 = 0;
        var pw: i32 = 0;
        _ = self.ptr.vtbl.get_CachedIsEnabled(self.ptr, &en);
        _ = self.ptr.vtbl.get_CachedIsKeyboardFocusable(self.ptr, &fo);
        // An unreadable IsPassword is treated as a password field.
        if (failed(self.ptr.vtbl.get_CachedIsPassword(self.ptr, &pw))) pw = 1;
        return .{
            .rid = try self.cachedRuntimeId(allocator),
            .parent = parent,
            .depth = depth,
            .control_type = ct,
            .name = name,
            .rect = r,
            .enabled = en != 0,
            .focusable = fo != 0,
            .is_password = pw != 0,
            .has_value = self.cachedBool(com.UIA_IsValuePatternAvailablePropertyId),
            .pid = self.cachedProcessId(),
            .automation_id = try self.cachedBstr(allocator, .automation_id),
            .class_name = try self.cachedBstr(allocator, .class_name),
            .has_text = self.cachedBool(com.UIA_IsTextPatternAvailablePropertyId),
        };
    }

    /// A cached string property; empty when unreadable.
    fn cachedBstr(self: Element, allocator: std.mem.Allocator, which: enum { automation_id, class_name }) ![]u8 {
        var b: ?[*]u16 = null;
        const hr = switch (which) {
            .automation_id => self.ptr.vtbl.get_CachedAutomationId(self.ptr, &b),
            .class_name => self.ptr.vtbl.get_CachedClassName(self.ptr, &b),
        };
        if (failed(hr)) return allocator.alloc(u8, 0);
        return bstrToUtf8(allocator, b);
    }

    // ── act (Z3) ────────────────────────────────────────────────────────────
    // Callers (main.zig) run every policy check before any of these.

    /// IsPassword, live. An unreadable value counts as a password field.
    pub fn currentIsPassword(self: Element) bool {
        var pw: i32 = 0;
        if (failed(self.ptr.vtbl.get_CurrentIsPassword(self.ptr, &pw))) return true;
        return pw != 0;
    }

    pub fn setFocus(self: Element) !void {
        if (failed(self.ptr.vtbl.SetFocus(self.ptr))) return error.SetFocusFailed;
    }

    /// The pattern object for `pattern_id`, or null when the element lacks it.
    fn pattern(self: Element, comptime T: type, pattern_id: i32) ?*T {
        var p: ?*anyopaque = null;
        if (failed(self.ptr.vtbl.GetCurrentPattern(self.ptr, pattern_id, &p))) return null;
        return @ptrCast(@alignCast(p orelse return null));
    }

    pub fn hasPattern(self: Element, pattern_id: i32) bool {
        var p: ?*anyopaque = null;
        if (failed(self.ptr.vtbl.GetCurrentPattern(self.ptr, pattern_id, &p))) return false;
        const u: *com.IUIAutomationInvokePattern = @ptrCast(@alignCast(p orelse return false));
        _ = u.vtbl.Release(u); // every pattern starts with IUnknown
        return true;
    }

    /// InvokePattern.Invoke; error.NoPattern when the element has none.
    pub fn invoke(self: Element) !void {
        const p = self.pattern(com.IUIAutomationInvokePattern, com.UIA_InvokePatternId) orelse return error.NoPattern;
        defer _ = p.vtbl.Release(p);
        if (failed(p.vtbl.Invoke(p))) return error.PatternCallFailed;
    }

    /// ValuePattern.SetValue. Refuses a read-only value (error.ReadOnly).
    pub fn setValue(self: Element, text: []const u8) !void {
        const p = self.pattern(com.IUIAutomationValuePattern, com.UIA_ValuePatternId) orelse return error.NoPattern;
        defer _ = p.vtbl.Release(p);
        var ro: i32 = 1;
        if (failed(p.vtbl.get_CurrentIsReadOnly(p, &ro)) or ro != 0) return error.ReadOnly;
        const wide = try std.unicode.wtf8ToWtf16LeAlloc(std.heap.page_allocator, text);
        defer std.heap.page_allocator.free(wide);
        const b = SysAllocStringLen(wide.ptr, @intCast(wide.len)) orelse return error.OutOfMemory;
        defer SysFreeString(b);
        if (failed(p.vtbl.SetValue(p, b))) return error.PatternCallFailed;
    }

    pub fn select(self: Element) !void {
        const p = self.pattern(com.IUIAutomationSelectionItemPattern, com.UIA_SelectionItemPatternId) orelse return error.NoPattern;
        defer _ = p.vtbl.Release(p);
        if (failed(p.vtbl.Select(p))) return error.PatternCallFailed;
    }

    pub fn expand(self: Element) !void {
        const p = self.pattern(com.IUIAutomationExpandCollapsePattern, com.UIA_ExpandCollapsePatternId) orelse return error.NoPattern;
        defer _ = p.vtbl.Release(p);
        if (failed(p.vtbl.Expand(p))) return error.PatternCallFailed;
    }

    pub fn scrollIntoView(self: Element) !void {
        const p = self.pattern(com.IUIAutomationScrollItemPattern, com.UIA_ScrollItemPatternId) orelse return error.NoPattern;
        defer _ = p.vtbl.Release(p);
        if (failed(p.vtbl.ScrollIntoView(p))) return error.PatternCallFailed;
    }

    /// ScrollPattern.Scroll(horizontal, vertical) with ScrollAmount values.
    pub fn scroll(self: Element, horizontal: ScrollAmount, vertical: ScrollAmount) !void {
        const p = self.pattern(com.IUIAutomationScrollPattern, com.UIA_ScrollPatternId) orelse return error.NoPattern;
        defer _ = p.vtbl.Release(p);
        if (failed(p.vtbl.Scroll(p, @intFromEnum(horizontal), @intFromEnum(vertical)))) return error.PatternCallFailed;
    }

    /// A clickable point in screen pixels, or null when UIA has none.
    pub fn clickablePoint(self: Element) ?com.POINT {
        var pt: com.POINT = .{ .x = 0, .y = 0 };
        var got: i32 = 0;
        if (failed(self.ptr.vtbl.GetClickablePoint(self.ptr, &pt, &got)) or got == 0) return null;
        return pt;
    }

    /// ValuePattern.Value, live (one cross-process call). Callers only use it
    /// on elements whose IsPassword came back false.
    pub fn currentValue(self: Element, allocator: std.mem.Allocator) !?[]u8 {
        var v: VARIANT = .{ .vt = VT_EMPTY };
        if (failed(self.ptr.vtbl.GetCurrentPropertyValue(self.ptr, com.UIA_ValueValuePropertyId, &v))) return null;
        defer _ = VariantClear(&v);
        if (v.vt != VT_BSTR) return null;
        const b: ?[*]u16 = @ptrFromInt(@as(usize, @intCast(v.data[0])));
        const p = b orelse return null;
        const s = try policy.utf16ToUtf8Capped(allocator, p[0..SysStringLen(p)], policy.max_text_chars);
        return s;
    }

    /// TextPattern DocumentRange text, live, capped at max_text_chars (the
    /// provider cuts it: GetText's maxLength, in UTF-16 units, so a
    /// surrogate pair at the end still fits). Null when the element has no
    /// TextPattern. Callers only use it on elements whose IsPassword came
    /// back false; `fillText` checks that again, live.
    pub fn currentText(self: Element, allocator: std.mem.Allocator) !?Text {
        const p = self.pattern(com.IUIAutomationTextPattern, com.UIA_TextPatternId) orelse return null;
        defer _ = p.vtbl.Release(p);
        var r: ?*com.IUIAutomationTextRange = null;
        if (failed(p.vtbl.get_DocumentRange(p, &r))) return null;
        const range = r orelse return null;
        defer _ = range.vtbl.Release(range);
        var b: ?[*]u16 = null;
        // One unit past max_text_chars scalar values (at most 2 units each):
        // a longer text always comes back with more than max_text_chars.
        if (failed(range.vtbl.GetText(range, @intCast(policy.max_text_chars * 2 + 1), &b))) return null;
        const bs = b orelse return .{ .text = try allocator.alloc(u8, 0), .truncated = false };
        defer SysFreeString(bs);
        const units = bs[0..SysStringLen(bs)];
        return .{
            .text = try policy.utf16ToUtf8Capped(allocator, units, policy.max_text_chars),
            .truncated = policy.utf16ScalarCount(units) > policy.max_text_chars,
        };
    }

    pub const Text = struct { text: []u8, truncated: bool };

    /// Set `node.text` when policy.wantsText allows it for this element and
    /// the live IsPassword is still false (an unreadable one counts as a
    /// password field). Errors leave the text unread.
    pub fn fillText(self: Element, allocator: std.mem.Allocator, node: *RawNode) void {
        if (!policy.wantsText(node.control_type, node.focusable, node.is_password, node.has_text)) return;
        if (self.currentIsPassword()) {
            node.is_password = true;
            node.value = null;
            return;
        }
        const t = (self.currentText(allocator) catch null) orelse return;
        node.text = t.text;
        node.text_truncated = t.truncated;
    }
};

/// BSTR → owned UTF-8 capped at max_text_chars; frees the BSTR.
fn bstrToUtf8(allocator: std.mem.Allocator, bstr: ?[*]u16) ![]u8 {
    const p = bstr orelse return allocator.alloc(u8, 0);
    defer SysFreeString(p);
    return policy.utf16ToUtf8Capped(allocator, p[0..SysStringLen(p)], policy.max_text_chars);
}

fn safeArrayI32(allocator: std.mem.Allocator, psa: *anyopaque) ![]i32 {
    var lo: i32 = 0;
    var hi: i32 = -1;
    if (failed(SafeArrayGetLBound(psa, 1, &lo)) or failed(SafeArrayGetUBound(psa, 1, &hi)) or hi < lo)
        return allocator.alloc(i32, 0);
    const n: usize = @intCast(hi - lo + 1);
    if (n > policy.max_runtime_id_parts) return allocator.alloc(i32, 0);
    var data: ?*anyopaque = null;
    if (failed(SafeArrayAccessData(psa, &data)) or data == null) return allocator.alloc(i32, 0);
    defer _ = SafeArrayUnaccessData(psa);
    const src: [*]const i32 = @ptrCast(@alignCast(data.?));
    return allocator.dupe(i32, src[0..n]);
}

/// VARIANT(VT_ARRAY|VT_I4) holding `rid`. The caller VariantClear()s it.
pub fn runtimeIdVariant(rid: []const i32) !VARIANT {
    if (rid.len == 0 or rid.len > policy.max_runtime_id_parts) return error.BadElementId;
    const psa = SafeArrayCreateVector(VT_I4, 0, @intCast(rid.len)) orelse return error.OutOfMemory;
    var data: ?*anyopaque = null;
    if (failed(SafeArrayAccessData(psa, &data)) or data == null) {
        _ = SafeArrayDestroy(psa);
        return error.SafeArrayFailed;
    }
    const dst: [*]i32 = @ptrCast(@alignCast(data.?));
    @memcpy(dst[0..rid.len], rid);
    _ = SafeArrayUnaccessData(psa);
    return .{ .vt = VT_ARRAY | VT_I4, .data = .{ @intFromPtr(psa), 0 } };
}

pub fn i4Variant(v: i32) VARIANT {
    return .{ .vt = VT_I4, .data = .{ @as(u32, @bitCast(v)), 0 } };
}

pub fn boolVariant(b: bool) VARIANT {
    return .{ .vt = VT_BOOL, .data = .{ if (b) 0xFFFF else 0, 0 } }; // VARIANT_TRUE = -1
}

test "generated vtable layout matches the header slot counts" {
    try std.testing.expectEqual(@as(usize, 58), com.IUIAutomation.slot_count);
    try std.testing.expectEqual(@as(usize, 85), com.IUIAutomationElement.slot_count);
    try std.testing.expectEqual(@as(usize, 16), com.IUIAutomationTreeWalker.slot_count);
    try std.testing.expectEqual(@as(usize, 12), com.IUIAutomationCacheRequest.slot_count);
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(VARIANT));
}

test "runtime id VARIANT round-trips through a SAFEARRAY" {
    const rid = [_]i32{ 42, -7, 99 };
    var v = try runtimeIdVariant(&rid);
    defer _ = VariantClear(&v);
    try std.testing.expectEqual(VT_ARRAY | VT_I4, v.vt);
    const back = try safeArrayI32(std.testing.allocator, @ptrFromInt(@as(usize, @intCast(v.data[0]))));
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualSlices(i32, &rid, back);
}
