"""Z3 live act test on 245 (interactive session).

Launches its own Notepad (on its own file on K:, so the active tab is ours;
every Notepad act first checks that the active tab is still that file) and
Calculator, drives zmcp-desktop's act tools on them only, checks what
actually happened, then empties the document and closes both. appstate.py
snapshots and restores the apps' per-user state around this run. Only the
targets' windows are recorded; other windows' titles are never logged.
"""
import ctypes
import ctypes.wintypes as wt
import json
import os
import secrets
import subprocess
import threading
import time
import traceback

D = os.environ.get("ZMCP_DESKTOP_LIVE_DIR", r"K:\zmcp-z3\live")
EXE = os.environ.get("ZMCP_DESKTOP_EXE", r"K:\zmcp-z3\out\bin\zmcp-desktop.exe")
NOTE = os.path.join(D, "z3-notepad.txt")
u32 = ctypes.windll.user32
k32 = ctypes.windll.kernel32
k32.CreateEventW.restype = wt.HANDLE
k32.OpenProcess.restype = wt.HANDLE
u32.FindWindowW.restype = wt.HWND
u32.FindWindowExW.restype = wt.HWND
u32.GetForegroundWindow.restype = wt.HWND
u32.GetAncestor.restype = wt.HWND
out = {"checks": [], "info": {}}


def check(name, ok, detail=""):
    out["checks"].append({"check": name, "ok": bool(ok), "detail": str(detail)[:400]})


def info(k, v):
    out["info"][k] = v


EnumProc = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)


def windows():
    res = []

    def cb(h, _):
        if u32.IsWindowVisible(h):
            pid = wt.DWORD()
            u32.GetWindowThreadProcessId(h, ctypes.byref(pid))
            res.append((h, pid.value))
        return True

    u32.EnumWindows(EnumProc(cb), 0)
    return res


def title(h):
    n = u32.GetWindowTextLengthW(wt.HWND(h))
    b = ctypes.create_unicode_buffer(n + 1)
    u32.GetWindowTextW(wt.HWND(h), b, n + 1)
    return b.value


def pid_of(h):
    pid = wt.DWORD()
    u32.GetWindowThreadProcessId(wt.HWND(h), ctypes.byref(pid))
    return pid.value


def image_path(pid):
    h = k32.OpenProcess(0x1000, False, pid)
    if not h:
        return ""
    buf = ctypes.create_unicode_buffer(1024)
    n = wt.DWORD(1024)
    ok = k32.QueryFullProcessImageNameW(wt.HANDLE(h), 0, buf, ctypes.byref(n))
    k32.CloseHandle(wt.HANDLE(h))
    return buf.value if ok else ""


def hosted_pid(h):
    core = u32.FindWindowExW(wt.HWND(h), None, "Windows.UI.Core.CoreWindow", None)
    return pid_of(core) if core else 0


def fg_root():
    f = u32.GetForegroundWindow()
    return u32.GetAncestor(f, 2) if f else None


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", wt.WORD), ("wScan", wt.WORD), ("dwFlags", wt.DWORD), ("time", wt.DWORD), ("dwExtraInfo", ctypes.c_size_t)]


class INPUT(ctypes.Structure):
    class _U(ctypes.Union):
        _fields_ = [("ki", KEYBDINPUT), ("pad", ctypes.c_byte * 32)]
    _anonymous_ = ("u",)
    _fields_ = [("type", wt.DWORD), ("u", _U)]


def shift_tap():
    """A harmless Shift press from THIS process, standing in for the user:
    zmcp-desktop treats every input event that is not its own cookie-tagged
    injection (hardware or another process's SendInput) as the user's."""
    arr = (INPUT * 2)()
    for i, up in enumerate((0, 2)):
        arr[i].type = 1
        arr[i].ki.wVk = 0x10
        arr[i].ki.dwFlags = up
    return u32.SendInput(2, arr, ctypes.sizeof(INPUT))


class NotOurTab(Exception):
    pass


class Mcp:
    def __init__(self, args, stderr_path=None):
        err = open(stderr_path, "wb") if stderr_path else subprocess.DEVNULL
        self.p = subprocess.Popen([EXE] + args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err)
        self.i = 0
        self.lock = threading.Lock()
        self.rpc("initialize", {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "z3", "version": "0"}})

    def rpc(self, method, params=None):
        with self.lock:
            self.i += 1
            m = {"jsonrpc": "2.0", "id": self.i, "method": method}
            if params is not None:
                m["params"] = params
            self.p.stdin.write((json.dumps(m) + "\n").encode())
            self.p.stdin.flush()
            return json.loads(self.p.stdout.readline())

    def call(self, name, **a):
        r = self.rpc("tools/call", {"name": name, "arguments": a})
        res = r["result"]
        return res.get("isError", False), res["content"][0]["text"]

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(5)
        except Exception:
            self.p.kill()


def nodes(m, h, **kw):
    err, txt = m.call("desktop_find", hwnd=int(h), **kw)
    return [] if err else json.loads(txt)["nodes"]


def doc_node(m, h):
    for role in ("document", "edit"):
        ns = [n for n in nodes(m, h, role=role, limit=50) if not n["is_password"]]
        if ns:
            return ns[0]
    return None


def doc_value(m, h):
    """The focused element's value (the document, when Notepad is in front)."""
    err, txt = m.call("desktop_focused", hwnd=int(h))
    if err:
        return None
    ns = json.loads(txt)["nodes"]
    return ns[0].get("value") if ns else None


launched = []
notepad = calc = None
kill_ev = None
try:
    before = {h for h, _ in windows()}
    open(NOTE, "w").close()
    launched.append(subprocess.Popen(["notepad.exe", NOTE]))
    subprocess.Popen(["calc.exe"])
    for _ in range(40):
        time.sleep(0.5)
        for h, pid in windows():
            if h in before:
                continue
            p = image_path(pid).lower()
            if p.endswith("\\notepad.exe") and notepad is None and title(h).startswith("z3-notepad"):
                notepad = h
            if p.endswith("applicationframehost.exe") and title(h) == "Calculator" and hosted_pid(h):
                calc = h
        if notepad and calc:
            break
    time.sleep(1.5)
    check("targets launched", notepad and calc, [notepad, calc])
    np_path = image_path(pid_of(notepad))
    calc_path = image_path(hosted_pid(calc))
    info("paths", [np_path, calc_path])

    nonce = secrets.token_hex(16)
    kill_name = f"Local\\zmcp-z3-kill-{nonce}"
    kill_ev = k32.CreateEventW(None, True, False, kill_name)
    resume_name = f"Local\\zmcp-z3-resume-{nonce}"
    resume_ev = k32.CreateEventW(None, True, False, resume_name)
    m = Mcp(["--allow", np_path + "|" + calc_path, "--kill-event", kill_name, "--resume-event", resume_name, "--debug-input"], os.path.join(D, "server-stderr.txt"))

    def np_guard():
        """Every Notepad act first checks the active tab is still our file."""
        if not (u32.IsWindow(wt.HWND(notepad)) and title(notepad).lstrip("*").startswith("z3-notepad")):
            raise NotOurTab(title(notepad)[:40])

    def npc(name, **a):
        np_guard()
        return m.call(name, **a)

    err, txt = m.call("desktop_list_windows")
    listed = {w["hwnd"] for w in json.loads(txt)["windows"]} if not err else set()
    check("list_windows lists both targets", notepad in listed and calc in listed, txt[:200])

    # ── Notepad: focus, type, key ────────────────────────────────────────
    d = doc_node(m, notepad)
    check("notepad document found", d is not None, d)
    info("notepad_doc", {k: d[k] for k in ("id", "role", "name")} if d else None)
    err, txt = npc("desktop_act", hwnd=int(notepad), id=d["id"], action="focus")
    check("act focus ok", not err and json.loads(txt)["ok"], txt)
    time.sleep(0.4)
    check("focus made notepad the foreground window", fg_root() == notepad, [fg_root(), notepad])

    err, txt = npc("desktop_type", hwnd=int(notepad), text="hello from zmcp-desktop, a quick brown fox 42")
    check("type ok", not err, txt)
    if not err:
        check("type reply names the focused document", json.loads(txt)["after"]["focused_id"] == d["id"], txt)
    time.sleep(0.4)
    v = doc_value(m, notepad)
    check("typed text arrived in notepad", v is not None and "hello from zmcp-desktop, a quick brown fox 42" in v, repr(v))

    err, txt = npc("desktop_key", hwnd=int(notepad), keys="ctrl+a")
    check("key ctrl+a ok", not err, txt)
    err, txt = npc("desktop_type", hwnd=int(notepad), text="replaced \u00e9\u00e8 \U0001F600")
    check("type after ctrl+a ok", not err, txt)
    time.sleep(0.4)
    v = doc_value(m, notepad)
    check("ctrl+a then type replaced the text (unicode incl. emoji)", v is not None and v.strip() == "replaced \u00e9\u00e8 \U0001F600", repr(v))

    info("notepad rewrites a typed 'z3' as '33' by itself (not injection: same with zmcp-computer, any pacing)", True)
    err, txt = npc("desktop_key", hwnd=int(notepad), keys="enter")
    err2, _ = npc("desktop_type", hwnd=int(notepad), text="line2")
    time.sleep(0.4)
    v = doc_value(m, notepad) or ""
    check("enter via desktop_key makes a new line", not err and not err2 and "line2" in v and ("\r" in v or "\n" in v), repr(v))

    before_run = {h for h, _ in windows()}
    for k in ("win+r", "alt+f4", "ctrl+alt+del", "alt+tab", "ctrl+esc", "lwin", "alt+space", "ctrl+shift+esc", "ctrl+v", "super+d"):
        err, txt = npc("desktop_key", hwnd=int(notepad), keys=k)
        check(f"key {k} refused", err and "not on the allowed list" in txt, txt)
    err, txt = npc("desktop_type", hwnd=int(notepad), text="a\nb")
    check("type with a newline refused", err and "control character" in txt, txt)
    time.sleep(0.5)
    new_wins = [h for h, _ in windows() if h not in before_run]
    check("no new window appeared after the refused chords", not new_wins, len(new_wins))
    check("notepad still open and in front", u32.IsWindow(wt.HWND(notepad)) and fg_root() == notepad)

    err, txt = npc("desktop_act", hwnd=int(notepad), id=d["id"], action="set_value", value="set via ValuePattern")
    info("notepad set_value", [err, txt[:200]])
    if not err:
        time.sleep(0.3)
        v = doc_value(m, notepad)
        check("set_value on the document", v == "set via ValuePattern", repr(v))

    err, txt = npc("desktop_scroll", hwnd=int(notepad), id=d["id"], direction="down", amount=2)
    info("notepad scroll", [err, txt[:200]])
    check("scroll answers (done, or a clean refusal/failure)", (not err and json.loads(txt)["ok"]) or "scrollable" in txt or "does not support" in txt or "did not confirm" in txt, txt)

    # desktop_click: a point inside the document (no InvokePattern there), then outside the window.
    x, y, wdt, hgt = d["rect"]
    err, txt = npc("desktop_click", hwnd=int(notepad), x=x + wdt // 2, y=y + hgt // 2)
    check("click inside the document ok", not err, txt)
    err, txt = npc("desktop_key", hwnd=int(notepad), keys="end")
    check("our own click does not count as user input", not err, txt)
    r = wt.RECT()
    u32.GetWindowRect(wt.HWND(notepad), ctypes.byref(r))
    err, txt = npc("desktop_click", hwnd=int(notepad), x=r.right + 50, y=r.top + 10)
    check("click outside the window refused", err and "outside the window" in txt, txt)

    # ── Calculator: invoke ─────────────────────────────────────────────
    def calc_button(name):
        for n in nodes(m, calc, role="button", name_contains=name, limit=50):
            if n["name"] == name:
                return n
        return None

    seq = ["Clear", "One", "Plus", "Two", "Equals"]
    ok_all = True
    for name in seq:
        b = calc_button(name)
        if b is None:
            if name == "Clear":
                continue
            ok_all = False
            check(f"calc button {name} found", False)
            break
        err, txt = m.call("desktop_act", hwnd=int(calc), id=b["id"], action="invoke")
        ok_all = ok_all and not err
        if err:
            check(f"invoke {name}", False, txt)
    time.sleep(0.5)
    disp = [n["name"] for n in nodes(m, calc, name_contains="Display is", limit=5)]
    check("calculator: invoke One + Two = shows 3", ok_all and any(s.strip().endswith(" 3") for s in disp), disp)
    info("calculator invoke left notepad in front", fg_root() == notepad)

    # Foreground refusal: type into Calculator while another window is in front.
    err, txt = npc("desktop_act", hwnd=int(notepad), id=d["id"], action="focus")
    time.sleep(0.4)
    err, txt = m.call("desktop_type", hwnd=int(calc), text="5")
    check("type into a background window refused", fg_root() != calc and err and "not the foreground window" in txt, txt)

    # Not allowlisted: the taskbar.
    tray = u32.FindWindowW("Shell_TrayWnd", None)
    err, txt = m.call("desktop_act", hwnd=int(tray), id="r1-2", action="invoke")
    check("act on a non-allowlisted window refused", err and "allowlist" in txt, txt)

    # ── user input: idle wait, then mid-act pause + resume ─────────────
    one = calc_button("One")
    shift_tap()
    err, txt = m.call("desktop_act", hwnd=int(calc), id=one["id"], action="invoke")
    check("act right after other input waits", err and txt.startswith("waiting"), txt)
    time.sleep(1.0)
    err, txt = m.call("desktop_act", hwnd=int(calc), id=one["id"], action="invoke")
    check("act after the user is idle again ok", not err, txt)

    # Calculator's invoke may have taken the foreground: focus Notepad again.
    err, txt = npc("desktop_act", hwnd=int(notepad), id=d["id"], action="focus")
    time.sleep(0.4)
    check("refocus notepad", not err and fg_root() == notepad, txt)
    err, txt = npc("desktop_key", hwnd=int(notepad), keys="ctrl+a")
    check("ctrl+a before the long type", not err, txt)
    long_text = "x" * 4000
    res = {}

    def typer():
        res["r"] = npc("desktop_type", hwnd=int(notepad), text=long_text)

    th = threading.Thread(target=typer)
    th.start()
    time.sleep(0.6)
    shift_tap()
    th.join(60)
    err, txt = res.get("r", (False, "no reply"))
    check("input during a long type stops it part-way and pauses", err and "paused" in txt, txt)
    time.sleep(1.0)
    v = doc_value(m, notepad) or ""
    info("typed before the pause", len(v))
    check("only part of the text was typed", 0 < len(v) < 4000, len(v))
    err, txt = npc("desktop_key", hwnd=int(notepad), keys="ctrl+a")
    check("the session stays paused", err and txt.startswith("paused"), txt)
    k32.SetEvent(wt.HANDLE(resume_ev))  # the user's Continue in the host
    check("no resume tool exists", "desktop_resume" not in json.dumps(m.rpc("tools/list")))
    time.sleep(1.0)

    # Cleanup of the document (before the kill test): select all, delete.
    e1, _ = npc("desktop_key", hwnd=int(notepad), keys="ctrl+a")
    e2, _ = npc("desktop_key", hwnd=int(notepad), keys="delete")
    time.sleep(0.4)
    check("notepad document emptied", not e1 and not e2 and (doc_value(m, notepad) or "") == "", repr(doc_value(m, notepad)))

    # ── kill event ─────────────────────────────────────────────────────
    k32.SetEvent(wt.HANDLE(kill_ev))
    time.sleep(0.2)
    err, txt = m.call("desktop_list_windows")
    check("kill: list stops", err and txt == "stopped by the user", txt)
    err, txt = m.call("desktop_act", hwnd=int(calc), id=one["id"], action="invoke")
    check("kill: act stops", err and txt == "stopped by the user", txt)
    k32.ResetEvent(wt.HANDLE(kill_ev))
    err, txt = npc("desktop_key", hwnd=int(notepad), keys="enter")
    check("kill: still stopped after the event is reset (latched)", err and txt == "stopped by the user", txt)
    k32.SetEvent(wt.HANDLE(resume_ev))
    err, txt = m.call("desktop_key", hwnd=int(notepad), keys="enter")
    check("kill: the resume event can't undo it", err and txt == "stopped by the user", txt)

    class PMC(ctypes.Structure):
        _fields_ = [("cb", wt.DWORD), ("PageFaultCount", wt.DWORD)] + [(n, ctypes.c_size_t) for n in [
            "PeakWorkingSetSize", "WorkingSetSize", "QuotaPeakPagedPoolUsage", "QuotaPagedPoolUsage",
            "QuotaPeakNonPagedPoolUsage", "QuotaNonPagedPoolUsage", "PagefileUsage", "PeakPagefileUsage", "PrivateUsage"]]

    hp = k32.OpenProcess(0x1000 | 0x0010, False, m.p.pid)
    pmc = PMC()
    pmc.cb = ctypes.sizeof(PMC)
    ctypes.windll.psapi.GetProcessMemoryInfo(wt.HANDLE(hp), ctypes.byref(pmc), pmc.cb)
    info("server_mem", {"ws": pmc.WorkingSetSize, "peak_ws": pmc.PeakWorkingSetSize, "private": pmc.PrivateUsage})
    m.close()

    # ── step limit (a second session) ──────────────────────────────────
    m2 = Mcp(["--allow", np_path + "|" + calc_path, "--max-steps", "2"])
    r = [m2.call("desktop_act", hwnd=int(calc), id=one["id"], action="invoke") for _ in range(3)]
    check("step limit: third act refused", not r[0][0] and not r[1][0] and r[2][0] and "step limit" in r[2][1], r)
    m2.close()
except NotOurTab as e:
    out["exception"] = "stopped: Notepad's active tab is not the test file: %s" % e
except Exception:
    out["exception"] = traceback.format_exc()
finally:
    for h in (notepad, calc):
        if h and u32.IsWindow(wt.HWND(h)):
            u32.PostMessageW(wt.HWND(h), 0x10, 0, 0)
    time.sleep(3)
    left = [h for h in (notepad, calc) if h and u32.IsWindow(wt.HWND(h))]
    for h in left:
        subprocess.run(["taskkill", "/F", "/PID", str(pid_of(h) if h != calc else hosted_pid(h))], capture_output=True)
    time.sleep(1)
    out["cleanup_left"] = [h for h in (notepad, calc) if h and u32.IsWindow(wt.HWND(h))]
    out["cleanup_forced"] = len(left)
    if kill_ev:
        k32.CloseHandle(wt.HANDLE(kill_ev))
    with open(os.path.join(D, "results.json"), "w", encoding="utf8") as f:
        json.dump(out, f, indent=1, ensure_ascii=False)
    with open(os.path.join(D, "done.flag"), "w") as f:
        f.write("done")
