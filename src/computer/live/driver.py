"""zmcp-computer live test driver. Runs in the interactive session on 245.

Starts the instrumented target window, drives zmcp-computer over MCP stdio,
and checks each call against what the target actually received. Keyboard
steps only run while the target is the foreground window.
"""
import base64
import json
import os
import struct
import subprocess
import sys
import time
import traceback

D = os.environ.get("ZMCP_LIVE_DIR", r"K:\zmcp-live")
EXE = os.path.join(D, "zmcp-computer.exe")
results = []
transcript = open(os.path.join(D, "transcript.jsonl"), "w", encoding="utf8")


def check(name, ok, detail=""):
    results.append({"check": name, "ok": bool(ok), "detail": str(detail)[:400]})


class Mcp:
    def __init__(self):
        self.p = subprocess.Popen([EXE], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.id = 0

    def rpc(self, method, params=None):
        self.id += 1
        msg = {"jsonrpc": "2.0", "id": self.id, "method": method}
        if params is not None:
            msg["params"] = params
        self.p.stdin.write((json.dumps(msg) + "\n").encode())
        self.p.stdin.flush()
        line = self.p.stdout.readline()
        r = json.loads(line)
        transcript.write(json.dumps({"req": msg, "resp_len": len(line), "resp": r if len(line) < 4000 else "<large>"}) + "\n")
        return r

    def call(self, tool, **args):
        r = self.rpc("tools/call", {"name": tool, "arguments": args})
        if "error" in r:
            return {"error": r["error"], "text": "", "image": None, "is_error": True}
        c = r["result"]["content"]
        text = "".join(x.get("text", "") for x in c if x["type"] == "text")
        img = next((x for x in c if x["type"] == "image"), None)
        return {"text": text, "image": img, "is_error": r["result"].get("isError", False)}


def png_size(b64):
    raw = base64.b64decode(b64)
    assert raw[:8] == b"\x89PNG\r\n\x1a\n"
    return struct.unpack(">II", raw[16:24]), raw


def png_rows(raw, n):
    """Decode the first n rows of an 8-bit RGB PNG (all five filters)."""
    import zlib
    (w, _h) = struct.unpack(">II", raw[16:24])
    pos, idat = 8, b""
    while pos < len(raw):
        ln = struct.unpack(">I", raw[pos:pos + 4])[0]
        if raw[pos + 4:pos + 8] == b"IDAT":
            idat += raw[pos + 8:pos + 8 + ln]
        pos += 12 + ln
    data = zlib.decompress(idat)
    rl = 3 * w
    rows, prev = [], bytearray(rl)
    for y in range(n):
        f = data[y * (rl + 1)]
        cur = bytearray(data[y * (rl + 1) + 1:(y + 1) * (rl + 1)])
        for i in range(rl):
            a = cur[i - 3] if i >= 3 else 0
            b = prev[i]
            c = prev[i - 3] if i >= 3 else 0
            if f == 1:
                cur[i] = (cur[i] + a) & 0xFF
            elif f == 2:
                cur[i] = (cur[i] + b) & 0xFF
            elif f == 3:
                cur[i] = (cur[i] + (a + b) // 2) & 0xFF
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                cur[i] = (cur[i] + pr) & 0xFF
        rows.append(cur)
        prev = cur
    return rows


events_pos = 0


def new_events(wait=0.35):
    global events_pos
    time.sleep(wait)
    with open(os.path.join(D, "events.log"), encoding="utf8") as f:
        f.seek(events_pos)
        data = f.read()
        events_pos = f.tell()
    return [ln.split(" ") for ln in data.splitlines() if ln]


def last_text(evs):
    t = [e for e in evs if e[0] == "TEXT"]
    return base64.b64decode(t[-1][1]).decode("utf8") if t else None


def mouse(evs, code):
    return [(int(e[2]), int(e[3])) for e in evs if e[0] == "MOUSE" and e[1] == code]


def main():
    for f in ("events.log", "ready.json"):
        try:
            os.remove(os.path.join(D, f))
        except FileNotFoundError:
            pass
    target = subprocess.Popen(["powershell", "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", os.path.join(D, "target.ps1"), "-Dir", D])
    for _ in range(100):
        if os.path.exists(os.path.join(D, "ready.json")):
            break
        time.sleep(0.2)
    time.sleep(0.5)
    rd = json.load(open(os.path.join(D, "ready.json")))
    pad, box, probe, form = rd["pad"], rd["box"], rd["probe"], rd["form"]
    new_events(0)
    m = Mcp()
    init = m.rpc("initialize", {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "live", "version": "0"}})
    check("initialize", init["result"]["serverInfo"]["name"] == "zmcp-computer", init["result"]["serverInfo"])
    tools = m.rpc("tools/list")["result"]["tools"]
    check("tools/list 18", len(tools) == 18, [t["name"] for t in tools])

    ss = json.loads(m.call("window", action="screen_size")["text"])
    sf = ss["screenshotScaleFactor"]
    check("screen_size", ss["physicalWidth"] > 0, ss)
    gs = json.loads(m.call("get_screen_size")["text"])
    check("get_screen_size matches", gs["width"] == ss["physicalWidth"], gs)

    def img(v):  # physical -> image-space (exact inverse of round(img*sf))
        return round(v / sf)

    def phys(i):
        return int(round(i * sf))

    # --- activation + keyboard -------------------------------------------------
    r = m.call("activate_window", title_pattern="zmcp-live-target")
    check("activate_window", "Successfully activated" in r["text"], r["text"])
    act = json.loads(m.call("window", action="active")["text"])
    fg_ok = act.get("title") == "zmcp-live-target"
    check("window.active is target", fg_ok, act)
    bx, by = box["x"] + box["w"] // 2, box["y"] + box["h"] // 2
    r = m.call("click_screen", x=bx, y=by)
    new_events()
    if fg_ok:
        s = "Hello Zig \u2713 \u00fc \U0001F600\nline2\ttab"
        r = m.call("type_text", text=s)
        t = last_text(new_events(0.6))
        check("type_text unicode/newline/tab", t == "Hello Zig \u2713 \u00fc \U0001F600\r\nline2\ttab", repr(t))
        m.call("press_keys", keys=[["ctrl", "a"]])
        m.call("type_text", text="replaced")
        t = last_text(new_events())
        check("press_keys ctrl+a then type", t == "replaced", repr(t))
        m.call("press_keys", keys="ctrl+shift+k")
        evs = new_events()
        check("press_keys ctrl+shift+k", any(e[0] == "KEY" and e[1] == "K" and "Shift" in e[2] and "Control" in e[2] for e in evs), evs[-5:])
        m.call("key_down", key="shift")
        m.call("key_up", key="shift")
        evs = new_events()
        check("key_down/key_up shift", any(e[0] == "KEY" and e[1] == "ShiftKey" for e in evs), evs[-5:])
        m.call("press_keys", keys=["end", "enter", "a", "B", "!"])
        t = last_text(new_events())
        check("press_keys sequence (enter, a, B, !)", t == "replaced\r\naB!", repr(t))
        m.call("computer", action="key", combo="ctrl+a")
        m.call("computer", action="type", text="\u03a9mega")
        t = last_text(new_events())
        check("computer.key + computer.type", t == "\u03a9mega", repr(t))
        r = m.call("system", action="shortcuts_run", intent="select all", context="zmcp")
        m.call("type_text", text="via shortcut")
        t = last_text(new_events())
        check("system.shortcuts_run select all", t == "via shortcut", repr(t) + " " + r["text"][:120])
        m.call("computer", action="key_down", combo="shift")
        m.call("computer", action="key_up", combo="shift")
        evs = new_events()
        check("computer.key_down/up", any(e[0] == "KEY" and e[1] == "ShiftKey" for e in evs), evs[-3:])
        r = m.call("press_keys", keys=[["alt", "f4"]])
        check("alt+f4 blocked", r["is_error"] and "BLOCKED" in r["text"], r["text"])
        r = m.call("press_keys", keys="shift+alt+f4")
        check("contained chord shift+alt+f4 blocked", r["is_error"] and "BLOCKED" in r["text"], r["text"])
        r = m.call("type_text", text="x" * 65537)
        check("type_text cap", r["is_error"] and "65536" in r["text"], r["text"][:120])
        r = m.call("system", action="undo")
        t = last_text(new_events())
        check("system.undo", t is not None and t != "via shortcut", repr(t))
        m.call("key_down", key="alt")
        r = m.call("computer", action="key", combo="f4")
        m.call("key_up", key="menu")
        check("held alt then f4 blocked", r["is_error"] and "BLOCKED" in r["text"], r["text"])
        alive = json.loads(m.call("window", action="active")["text"])
        check("target still open after blocked chord", alive.get("title") == "zmcp-live-target", alive)
        m.call("press_keys", keys="escape")  # leave the menu mode a lone Alt tap enters
    else:
        check("keyboard steps skipped (target not foreground)", False, act)

    # --- argument guards (nothing is sent) --------------------------------------
    r = m.call("click_screen", x=ss["physicalWidth"] * 50, y=5)
    check("click outside desktop refused", r["is_error"] and "outside" in r["text"], r["text"])
    r = m.call("computer", action="click", x=1e300, y=5)
    check("x=1e300 refused without crash", r["is_error"], r["text"])
    r = m.call("window", action="open_file", path=r"C:\Windows\System32\calc.exe")
    check("open_file refuses .exe", r["is_error"] and "refused" in r["text"], r["text"])
    r = m.call("take_screenshot", save_to_downloads=True, max_width=200)
    check("save_to_downloads off by default", "Not saved" in r["text"], r["text"])

    # --- mouse ---------------------------------------------------------------
    px, py = pad["x"] + 100, pad["y"] + 80
    m.call("click_screen", x=px, y=py)
    evs = new_events()
    check("click_screen exact coords", mouse(evs, "0201") == [(px, py)] and mouse(evs, "0202") == [(px, py)], mouse(evs, "0201") + mouse(evs, "0202"))
    m.call("move_mouse", x=px + 50, y=py + 30)
    evs = new_events()
    mv = [(int(e[1]), int(e[2])) for e in evs if e[0] == "MOVE"]
    check("move_mouse exact", mv and mv[-1] == (px + 50, py + 30), mv[-3:])
    m.call("mouse_down", button="right")
    m.call("mouse_up", button="right")
    evs = new_events()
    check("mouse_down/up right", mouse(evs, "0204") and mouse(evs, "0205"), evs[-4:])

    ix, iy = img(pad["x"] + 200), img(pad["y"] + 120)
    ex, ey = phys(ix), phys(iy)
    m.call("computer", action="click", x=ix, y=iy)
    evs = new_events()
    check("computer.click image-space", mouse(evs, "0201") == [(ex, ey)], (mouse(evs, "0201"), (ex, ey), sf))
    time.sleep(0.6)
    new_events(0)
    m.call("computer", action="double_click", x=ix, y=iy)
    evs = new_events()
    check("computer.double_click -> WM_LBUTTONDBLCLK", mouse(evs, "0203") == [(ex, ey)], evs[-6:])
    time.sleep(0.6)
    new_events(0)
    m.call("computer", action="triple_click", x=ix, y=iy)
    evs = new_events()
    check("computer.triple_click 3 presses", len(mouse(evs, "0201")) + len(mouse(evs, "0203")) == 3, evs[-8:])
    m.call("computer", action="right_click", x=ix, y=iy)
    m.call("computer", action="middle_click", x=ix, y=iy)
    evs = new_events()
    check("computer.right_click/middle_click", mouse(evs, "0204") == [(ex, ey)] and mouse(evs, "0207") == [(ex, ey)], evs[-6:])
    m.call("computer", action="hover", x=ix + 10, y=iy + 10)
    evs = new_events()
    mv = [(int(e[1]), int(e[2])) for e in evs if e[0] == "MOVE"]
    check("computer.hover", mv and mv[-1] == (phys(ix + 10), phys(iy + 10)), mv[-2:])
    m.call("computer", action="move_relative", dx=5, dy=-3)
    evs = new_events()
    mv = [(int(e[1]), int(e[2])) for e in evs if e[0] == "MOVE"]
    check("computer.move_relative", mv and mv[-1] == (phys(ix + 10) + phys(5), phys(iy + 10) + phys(-3)), mv[-2:])
    m.call("computer", action="scroll", x=ix, y=iy, direction="down", amount=2)
    m.call("computer", action="scroll", x=ix, y=iy, direction="up")
    m.call("computer", action="scroll_horizontal", x=ix, y=iy, direction="right", amount=3)
    evs = new_events()
    wh = [(e[1], int(e[2])) for e in evs if e[0] == "WHEEL"]
    check("scroll down2/up3/hright3", wh == [("020A", -240), ("020A", 360), ("020E", 360)], wh)
    ax, ay, bx2, by2 = pad["x"] + 50, pad["y"] + 200, pad["x"] + 400, pad["y"] + 260
    m.call("drag_mouse", from_x=ax, from_y=ay, to_x=bx2, to_y=by2, duration=0.3)
    evs = new_events()
    check("drag_mouse down@A up@B", mouse(evs, "0201") == [(ax, ay)] and mouse(evs, "0202") == [(bx2, by2)], (mouse(evs, "0201"), mouse(evs, "0202")))
    moves = [e for e in evs if e[0] == "MOVE"]
    check("drag_mouse intermediate moves", len(moves) >= 5, len(moves))
    pts = [{"x": img(pad["x"] + 60), "y": img(pad["y"] + 60)}, {"x": img(pad["x"] + 160), "y": img(pad["y"] + 90)}, {"x": img(pad["x"] + 260), "y": img(pad["y"] + 60)}]
    m.call("computer", action="drag_path", path=json.dumps(pts))
    evs = new_events()
    check("computer.drag_path", mouse(evs, "0201") == [(phys(pts[0]["x"]), phys(pts[0]["y"]))] and mouse(evs, "0202") == [(phys(pts[2]["x"]), phys(pts[2]["y"]))], (mouse(evs, "0201"), mouse(evs, "0202")))
    m.call("computer", action="drag", startX=img(ax), startY=img(ay), endX=img(bx2), endY=img(by2))
    evs = new_events()
    check("computer.drag", mouse(evs, "0202") == [(phys(img(bx2)), phys(img(by2)))], mouse(evs, "0202"))
    m.call("computer", action="mouse_down", button="middle")
    m.call("computer", action="mouse_up", button="middle")
    evs = new_events()
    check("computer.mouse_down/up middle", mouse(evs, "0207") and mouse(evs, "0208"), evs[-3:])

    # --- capture / OCR ---------------------------------------------------------
    r = m.call("take_screenshot", title_pattern="zmcp-live-target")
    (w, h), raw = png_size(r["image"]["data"])
    open(os.path.join(D, "window.png"), "wb").write(raw)
    check("take_screenshot window (visible frame, borders cropped)", form["w"] - 24 <= w <= form["w"] and form["h"] - 24 <= h <= form["h"] and (w, h) != (form["w"], form["h"]), ((w, h), form, r["text"]))
    # The invisible resize borders (black in PrintWindow output) must be
    # cropped: pixel (3, 15) is in the title bar of the visible frame but
    # inside the 7 px invisible border of an uncropped capture.
    rgb = png_rows(raw, 16)
    check("window capture has no black border", sum(rgb[15][9:12]) > 150, bytes(rgb[15][9:12]).hex())
    r = m.call("take_screenshot", max_width=800)
    (w, h), _ = png_size(r["image"]["data"])
    check("take_screenshot max_width", w == 800, (w, h))
    r = m.call("take_screenshot")
    (w, h), _ = png_size(r["image"]["data"])
    check("take_screenshot full virtual desktop", w >= ss["physicalWidth"], (w, h, r["text"]))
    r = m.call("take_screenshot_with_ocr", title_pattern="zmcp-live-target")
    txt = r["text"]
    open(os.path.join(D, "ocr_window.txt"), "w", encoding="utf8").write(txt)
    probe_line = next((ln for ln in txt.split("\n") if "4217" in ln), None)
    check("take_screenshot_with_ocr finds probe", probe_line is not None, txt[:300])
    if probe_line:
        nums = [int(n) for n in probe_line.replace("[", " ").replace("]", " ").replace(",", " ").replace("(", " ").split() if n.lstrip("-").isdigit()][:8]
        x1, y1 = nums[0], nums[1]
        inside = probe["x"] - 5 <= x1 <= probe["x"] + probe["w"] and probe["y"] - 5 <= y1 <= probe["y"] + probe["h"]
        check("OCR box in absolute screen coords", inside, (nums, probe))
    r = m.call("take_screenshot_with_ocr", title_pattern="zmcp-live-target", scale_percent_for_ocr=50)
    check("OCR with scale_percent_for_ocr=50", "4217" in r["text"] or "PROBE" in r["text"], r["text"][:200])
    r = m.call("computer", action="screenshot")
    (w, h), _ = png_size(r["image"]["data"])
    check("computer.screenshot 1280 wide", w == min(1280, ss["physicalWidth"]), (w, h, r["text"]))
    r = m.call("computer", action="screenshot_region", x=img(probe["x"]), y=img(probe["y"]), width=img(probe["w"]), height=img(probe["h"]))
    (w, h), raw = png_size(r["image"]["data"])
    open(os.path.join(D, "region.png"), "wb").write(raw)
    check("computer.screenshot_region", abs(w - phys(img(probe["w"]))) <= 2, (w, h, r["text"]))
    r = m.call("system", action="ocr")
    o = json.loads(r["text"]) if not r["is_error"] else {}
    check("system.ocr finds probe", "4217" in o.get("fullText", ""), r["text"][:200])

    # --- windows ---------------------------------------------------------------
    lw = json.loads(m.call("list_windows")["text"])
    me = [x for x in lw if x["title"] == "zmcp-live-target"]
    check("list_windows has target", len(me) == 1 and me[0]["width"] == form["w"], me)
    wl = m.call("window", action="list")["text"]
    check("window.list has target", "zmcp-live-target" in wl, "")
    ld = json.loads(m.call("window", action="list_displays")["text"])
    check("window.list_displays", len(ld) >= 1 and any(d["primary"] for d in ld), ld)
    r = m.call("window", action="resize", title="zmcp-live-target", width=700, height=500)
    lw = json.loads(m.call("list_windows")["text"])
    me = [x for x in lw if x["title"] == "zmcp-live-target"][0]
    check("window.resize", (me["width"], me["height"]) == (700, 500), (r["text"], me))
    m.call("window", action="maximize", title="zmcp-live-target")
    time.sleep(0.3)
    me = [x for x in json.loads(m.call("list_windows")["text"]) if x["title"] == "zmcp-live-target"][0]
    check("window.maximize", me["is_maximized"], me)
    m.call("window", action="restore", title="zmcp-live-target")
    time.sleep(0.3)
    me = [x for x in json.loads(m.call("list_windows")["text"]) if x["title"] == "zmcp-live-target"][0]
    check("window.restore", not me["is_maximized"], me)
    m.call("window", action="minimize", title="zmcp-live-target")
    time.sleep(0.3)
    me = [x for x in json.loads(m.call("list_windows")["text"]) if x["title"] == "zmcp-live-target"][0]
    check("window.minimize", me["is_minimized"], me)
    r = m.call("window", action="focus", title="zmcp-live")
    act = json.loads(m.call("window", action="active")["text"])
    check("window.focus restores+foregrounds", act.get("title") == "zmcp-live-target", (r["text"], act))
    r = m.call("activate_window", title_pattern="^zmcp-live", use_regex=True)
    check("activate_window regex", "Successfully" in r["text"], r["text"])

    # --- clipboard (restored afterwards) ------------------------------------------
    orig = m.call("system", action="clipboard_read")
    sample = "zmcp clip \u2713 \U0001F600"
    m.call("system", action="clipboard_write", text=sample)
    back = m.call("system", action="clipboard_read")["text"]
    check("clipboard round-trip", back == sample, repr(back))
    if not orig["is_error"] and not orig["text"].startswith("(clipboard is empty"):
        m.call("system", action="clipboard_write", text=orig["text"])

    # --- misc -------------------------------------------------------------------
    t = json.loads(m.call("system", action="system_time")["text"])
    check("system.system_time", abs(t["epochMs"] / 1000 - time.time()) < 5, t)
    dw = json.loads(m.call("system", action="detect_webview")["text"])
    check("system.detect_webview", "candidates" in dw, str(dw)[:200])

    # --- open_app + close (Character Map: plain Win32, no save prompt) ------------
    r = m.call("window", action="open_app", name="charmap")
    check("window.open_app charmap", "Opened" in r["text"] or "Launched" in r["text"], r["text"])
    time.sleep(1.0)
    r = m.call("window", action="close", title="Character Map")
    check("window.close needs confirm", r["is_error"] and "confirm" in r["text"], r["text"])
    r = m.call("window", action="close", title="Character Map", confirm=True)
    time.sleep(0.8)
    still = [x for x in json.loads(m.call("list_windows")["text"]) if x["title"] == "Character Map"]
    check("window.close confirm=true", not still, (r["text"], still))

    # --- close the target ----------------------------------------------------------
    r = m.call("window", action="close", title="zmcp-live-target", confirm=True)
    target.wait(timeout=10)
    evs = new_events()
    check("target closed via window.close", any(e[0] == "CLOSED" for e in evs), r["text"])
    m.p.stdin.close()
    m.p.wait(timeout=10)


try:
    main()
except Exception:
    results.append({"check": "driver exception", "ok": False, "detail": traceback.format_exc()[-1500:]})
finally:
    json.dump(results, open(os.path.join(D, "results.json"), "w", encoding="utf8"), indent=1, ensure_ascii=False)
    open(os.path.join(D, "done.flag"), "w").write("done")
