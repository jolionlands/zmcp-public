"""Generate src/desktop/uia_com.zig from the Windows SDK UIAutomationClient.h.

Every vtable slot is emitted in header order (taken from the C-style
`typedef struct <I>Vtbl` blocks). Slots zmcp-desktop calls get a typed Zig
function pointer; every other slot is `*const anyopaque`. Only the slot index
is emitted as a comment: the header's C signature text is deliberately NOT
copied into the output (it is Microsoft-copyrighted header text).

    python src/desktop/gen_uia.py [path/to/UIAutomationClient.h]
"""
import re, sys, pathlib

SDK = r"C:\Program Files (x86)\Windows Kits\10\Include\10.0.22621.0\um\UIAutomationClient.h"
hdr_path = sys.argv[1] if len(sys.argv) > 1 else SDK
src = pathlib.Path(hdr_path).read_text(encoding="latin-1")

IFACES = [
    "IUIAutomation",
    "IUIAutomation2",
    "IUIAutomationElement",
    "IUIAutomationElementArray",
    "IUIAutomationCondition",
    "IUIAutomationTreeWalker",
    "IUIAutomationCacheRequest",
    "IUIAutomationInvokePattern",
    "IUIAutomationValuePattern",
    # Z3 act tools.
    "IUIAutomationSelectionItemPattern",
    "IUIAutomationExpandCollapsePattern",
    "IUIAutomationScrollItemPattern",
    "IUIAutomationScrollPattern",
    # B5: TextPattern reads of contenteditable composers.
    "IUIAutomationTextPattern",
    "IUIAutomationTextRange",
]

# Typed slots: (interface, method) -> Zig params after `self` (return is always HRESULT
# except AddRef/Release). Types: HRESULT=i32, BOOL=i32, BSTR=?[*:0]u16, CONTROLTYPEID=i32.
TYPED = {
    ("*", "QueryInterface"): "riid: *const GUID, out: *?*anyopaque",
    ("*", "AddRef"): None,  # special: returns ULONG
    ("*", "Release"): None,
    ("IUIAutomation", "ElementFromHandle"): "hwnd: ?*anyopaque, element: *?*IUIAutomationElement",
    ("IUIAutomation", "get_ControlViewWalker"): "walker: *?*IUIAutomationTreeWalker",
    ("IUIAutomation", "GetRootElement"): "root: *?*IUIAutomationElement",
    ("IUIAutomationElement", "get_CurrentName"): "ret: *?[*]u16",
    ("IUIAutomationElement", "get_CurrentClassName"): "ret: *?[*]u16",
    ("IUIAutomationElement", "get_CurrentControlType"): "ret: *i32",
    ("IUIAutomationElement", "get_CurrentIsEnabled"): "ret: *i32",
    ("IUIAutomationElement", "get_CurrentIsKeyboardFocusable"): "ret: *i32",
    ("IUIAutomationElement", "get_CurrentIsPassword"): "ret: *i32",
    ("IUIAutomationElement", "get_CurrentProcessId"): "ret: *i32",
    ("IUIAutomationElement", "get_CurrentBoundingRectangle"): "ret: *RECT",
    ("IUIAutomation", "CreateCacheRequest"): "req: *?*IUIAutomationCacheRequest",
    ("IUIAutomation", "ElementFromHandleBuildCache"): "hwnd: ?*anyopaque, req: *IUIAutomationCacheRequest, element: *?*IUIAutomationElement",
    ("IUIAutomationCacheRequest", "AddProperty"): "property_id: i32",
    ("IUIAutomationTreeWalker", "GetFirstChildElementBuildCache"): "element: *IUIAutomationElement, req: *IUIAutomationCacheRequest, first: *?*IUIAutomationElement",
    ("IUIAutomationTreeWalker", "GetNextSiblingElementBuildCache"): "element: *IUIAutomationElement, req: *IUIAutomationCacheRequest, next: *?*IUIAutomationElement",
    ("IUIAutomationElement", "get_CachedName"): "ret: *?[*]u16",
    ("IUIAutomationElement", "get_CachedControlType"): "ret: *i32",
    ("IUIAutomationElement", "get_CachedIsEnabled"): "ret: *i32",
    ("IUIAutomationElement", "get_CachedIsKeyboardFocusable"): "ret: *i32",
    ("IUIAutomationElement", "get_CachedIsPassword"): "ret: *i32",
    ("IUIAutomationElement", "get_CachedBoundingRectangle"): "ret: *RECT",
    ("IUIAutomationElementArray", "get_Length"): "length: *i32",
    ("IUIAutomationElementArray", "GetElement"): "index: i32, element: *?*IUIAutomationElement",
    ("IUIAutomationTreeWalker", "GetFirstChildElement"): "element: *IUIAutomationElement, first: *?*IUIAutomationElement",
    ("IUIAutomationTreeWalker", "GetNextSiblingElement"): "element: *IUIAutomationElement, next: *?*IUIAutomationElement",
    ("IUIAutomationInvokePattern", "Invoke"): "",
    ("IUIAutomationValuePattern", "get_CurrentValue"): "ret: *?[*]u16",
    ("IUIAutomationValuePattern", "get_CurrentIsReadOnly"): "ret: *i32",
    # Z2 observe tools.
    ("IUIAutomation", "CreatePropertyCondition"): "property_id: i32, value: VARIANT, cond: *?*IUIAutomationCondition",
    ("IUIAutomation", "CreateAndCondition"): "c1: *IUIAutomationCondition, c2: *IUIAutomationCondition, cond: *?*IUIAutomationCondition",
    ("IUIAutomation", "CreateOrCondition"): "c1: *IUIAutomationCondition, c2: *IUIAutomationCondition, cond: *?*IUIAutomationCondition",
    ("IUIAutomation", "get_ControlViewCondition"): "cond: *?*IUIAutomationCondition",
    ("IUIAutomation", "GetFocusedElementBuildCache"): "req: *IUIAutomationCacheRequest, element: *?*IUIAutomationElement",
    ("IUIAutomationElement", "FindFirstBuildCache"): "scope: i32, cond: *IUIAutomationCondition, req: *IUIAutomationCacheRequest, found: *?*IUIAutomationElement",
    ("IUIAutomationElement", "FindAllBuildCache"): "scope: i32, cond: *IUIAutomationCondition, req: *IUIAutomationCacheRequest, found: *?*IUIAutomationElementArray",
    ("IUIAutomationElement", "BuildUpdatedCache"): "req: *IUIAutomationCacheRequest, updated: *?*IUIAutomationElement",
    ("IUIAutomationElement", "GetCachedPropertyValue"): "property_id: i32, ret: *VARIANT",
    ("IUIAutomationElement", "GetCurrentPropertyValue"): "property_id: i32, ret: *VARIANT",
    ("IUIAutomationElement", "GetCachedChildren"): "ret: *?*IUIAutomationElementArray",
    ("IUIAutomationElement", "get_CachedProcessId"): "ret: *i32",
    ("IUIAutomationCacheRequest", "put_TreeScope"): "scope: i32",
    ("IUIAutomationCacheRequest", "put_TreeFilter"): "filter: *IUIAutomationCondition",
    # Z2 review: cross-process timeouts (IUIAutomation2, from CUIAutomation8).
    ("IUIAutomation2", "put_ConnectionTimeout"): "timeout_ms: u32",
    ("IUIAutomation2", "put_TransactionTimeout"): "timeout_ms: u32",
    ("IUIAutomation2", "get_ConnectionTimeout"): "timeout_ms: *u32",
    ("IUIAutomation2", "get_TransactionTimeout"): "timeout_ms: *u32",
    # Z3 act tools. BSTR in = a SysAllocString'd pointer; POINT by value is
    # 8 bytes (one register on x64 and AAPCS64).
    ("IUIAutomationElement", "SetFocus"): "",
    ("IUIAutomationElement", "GetCurrentPattern"): "pattern_id: i32, pattern: *?*anyopaque",
    ("IUIAutomationElement", "GetClickablePoint"): "clickable: *POINT, got: *i32",
    ("IUIAutomationElement", "get_CurrentHasKeyboardFocus"): "ret: *i32",
    ("IUIAutomation", "ElementFromPointBuildCache"): "pt: POINT, req: *IUIAutomationCacheRequest, element: *?*IUIAutomationElement",
    ("IUIAutomationTreeWalker", "GetParentElementBuildCache"): "element: *IUIAutomationElement, req: *IUIAutomationCacheRequest, parent: *?*IUIAutomationElement",
    ("IUIAutomationValuePattern", "SetValue"): "value: ?[*]u16",
    ("IUIAutomationSelectionItemPattern", "Select"): "",
    ("IUIAutomationExpandCollapsePattern", "Expand"): "",
    ("IUIAutomationScrollItemPattern", "ScrollIntoView"): "",
    ("IUIAutomationScrollPattern", "Scroll"): "horizontal: i32, vertical: i32",
    # expected_id: structure keys on every node.
    ("IUIAutomationElement", "get_CachedAutomationId"): "ret: *?[*]u16",
    ("IUIAutomationElement", "get_CachedClassName"): "ret: *?[*]u16",
    # B5: TextPattern. GetText's maxLength caps the BSTR on the provider side
    # (-1 = all); we always pass a cap.
    ("IUIAutomationTextPattern", "get_DocumentRange"): "range: *?*IUIAutomationTextRange",
    ("IUIAutomationTextRange", "GetText"): "max_length: i32, ret: *?[*]u16",
}

def iid(name):
    m = re.search(r'MIDL_INTERFACE\("([0-9a-fA-F-]+)"\)\s*\n\s*' + name + r'\s*:', src)
    assert m, name
    return m.group(1)

def clsid(name):
    m = re.search(r'class DECLSPEC_UUID\("([0-9a-fA-F-]+)"\)\s*\n\s*' + name + r'\b', src)
    assert m, name
    return m.group(1)

def guid_zig(s):
    p = s.split("-")
    tail = p[3] + p[4]
    bs = ", ".join("0x" + tail[i:i+2] for i in range(0, 16, 2))
    return f".{{ .data1 = 0x{p[0]}, .data2 = 0x{p[1]}, .data3 = 0x{p[2]}, .data4 = .{{ {bs} }} }}"

def vtbl_methods(name):
    m = re.search(r"typedef struct " + name + r"Vtbl\s*\{(.*?)\}\s*" + name + r"Vtbl;", src, re.S)
    assert m, name
    body = m.group(1)
    out = []
    # each slot: DECLSPEC_XFGVIRT(Iface, Method) ... ( STDMETHODCALLTYPE *Method )( params );
    for sm in re.finditer(r"DECLSPEC_XFGVIRT\((\w+),\s*(\w+)\)(.*?\);)", body, re.S):
        decl = " ".join(sm.group(3).split())
        mm = re.search(r"\*\s*(\w+)\s*\)", decl)
        assert mm and mm.group(1) == sm.group(2), (name, sm.group(2))
        out.append((sm.group(2), decl))
    return out

lines = []
w = lines.append
w("//! GENERATED by src/desktop/gen_uia.py from")
w("//!   the Windows SDK 10.0.22621.0 UIAutomationClient.h (GUIDs, vtable order, constants only)")
w("//! Do not hand-edit: every vtable slot is in header order; untyped slots are")
w("//! `*const anyopaque` placeholders that keep later offsets correct.")
w("//! COM on aarch64-windows uses the plain AAPCS64 C convention (`.winapi` == `.c`),")
w("//! `this` in x0; typed slots return HRESULT/ULONG and take pointers or 32-bit")
w("//! scalars, except CreatePropertyCondition, which takes a VARIANT (24 bytes) by")
w("//! value. Both the x64 MS ABI and AAPCS64 pass a composite over 16 bytes as a")
w("//! pointer to a caller-owned copy; Zig's C-ABI lowering does that for an extern")
w("//! struct parameter. uia.zig has a live test for it on each target.")
w("")
w("const std = @import(\"std\");")
w("")
w("pub const HRESULT = i32;")
w("pub const GUID = extern struct { data1: u32, data2: u16, data3: u16, data4: [8]u8 };")
w("pub const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };")
w("pub const POINT = extern struct { x: i32, y: i32 };")
w("/// VARIANT: 24 bytes, 8-aligned on 64-bit Windows (x64 and ARM64 alike).")
w("pub const VARIANT = extern struct { vt: u16, r1: u16 = 0, r2: u16 = 0, r3: u16 = 0, data: [2]u64 = .{ 0, 0 } };")
w("comptime {")
w("    std.debug.assert(@sizeOf(VARIANT) == 24 and @alignOf(VARIANT) == 8);")
w("}")
w("")
w(f"/// CLSID_CUIAutomation  {{{clsid('CUIAutomation')}}}")
w(f"pub const CLSID_CUIAutomation: GUID = {guid_zig(clsid('CUIAutomation'))};")
w(f"/// CLSID_CUIAutomation8  {{{clsid('CUIAutomation8')}}}")
w(f"pub const CLSID_CUIAutomation8: GUID = {guid_zig(clsid('CUIAutomation8'))};")
PROPS = ["BoundingRectangle", "ControlType", "Name", "AutomationId", "ClassName", "IsKeyboardFocusable", "IsEnabled", "IsPassword",
         "RuntimeId", "ProcessId", "HasKeyboardFocus", "IsValuePatternAvailable", "ValueValue",
         "ValueIsReadOnly", "NativeWindowHandle", "IsTextPatternAvailable"]
for pn in PROPS:
    m = re.search(r"const long UIA_" + pn + r"PropertyId\s*=\s*(\d+);", src)
    assert m, pn
    w(f"pub const UIA_{pn}PropertyId: i32 = {m.group(1)};")
PATTERNS = ["Invoke", "Value", "SelectionItem", "ExpandCollapse", "ScrollItem", "Scroll", "Text"]
for pn in PATTERNS:
    m = re.search(r"const long UIA_" + pn + r"PatternId\s*=\s*(\d+);", src)
    assert m, pn
    w(f"pub const UIA_{pn}PatternId: i32 = {m.group(1)};")
counts = {}
for name in IFACES:
    g = iid(name)
    w(f"/// IID_{name}  {{{g}}}")
    w(f"pub const IID_{name}: GUID = {guid_zig(g)};")
w("")
for name in IFACES:
    methods = vtbl_methods(name)
    counts[name] = len(methods)
    w(f"pub const {name} = extern struct {{")
    w(f"    vtbl: *const Vtbl,")
    w(f"    pub const Vtbl = extern struct {{")
    for i, (meth, decl) in enumerate(methods):
        key = (name, meth) if (name, meth) in TYPED else ("*", meth)
        if meth in ("AddRef", "Release"):
            w(f"        {meth}: *const fn (self: *{name}) callconv(.winapi) u32, // [{i}]")
        elif key in TYPED:
            params = TYPED[key]
            sep = ", " if params else ""
            w(f"        {meth}: *const fn (self: *{name}{sep}{params}) callconv(.winapi) HRESULT, // [{i}]")
        else:
            w(f"        {meth}: *const anyopaque, // [{i}]")
    w("    };")
    w(f"    pub const slot_count = {len(methods)};")
    w("};")
    w("")
# comptime layout checks: slot count * pointer size
w("comptime {")
for name in IFACES:
    w(f"    std.debug.assert(@sizeOf({name}.Vtbl) == {counts[name]} * @sizeOf(usize));")
w("}")
w("")
used = [k for k in TYPED if k[0] != "*"]
for (iface, meth) in used:
    idx = [m for m, _ in vtbl_methods(iface)].index(meth)
    w(f"comptime {{ std.debug.assert(@offsetOf({iface}.Vtbl, \"{meth}\") == {idx} * @sizeOf(usize)); }}")
out = pathlib.Path(__file__).with_name("uia_com.zig")
out.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
print({k: v for k, v in counts.items()})
