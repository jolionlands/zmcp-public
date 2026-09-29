"""Snapshot / restore / diff Notepad's and Calculator's per-user package state
(LocalState + Settings) around the Z3 live test, so the test leaves the
user's Notepad session and Calculator settings exactly as they were.

    python appstate.py snap      copy into K:\\zmcp-z3\\appstate-pre
    python appstate.py diff      list files that differ from the snapshot
    python appstate.py restore   put every differing file back; files the run
                                 created are moved to K:\\zmcp-z3\\appstate-created
"""
import hashlib
import os
import shutil
import subprocess
import sys

PKGS = ["Microsoft.WindowsNotepad_8wekyb3d8bbwe", "Microsoft.WindowsCalculator_8wekyb3d8bbwe"]
SUBS = ["LocalState", "Settings"]
BASE = os.path.join(os.environ["LOCALAPPDATA"], "Packages")
ROOT = os.environ.get("ZMCP_DESKTOP_APPSTATE_DIR", r"K:\zmcp-z3")
PRE = os.path.join(ROOT, "appstate-pre")
CREATED = os.path.join(ROOT, "appstate-created")


def files(root):
    out = set()
    for dp, _, fn in os.walk(root):
        for f in fn:
            out.add(os.path.relpath(os.path.join(dp, f), root))
    return out


def h(p):
    try:
        return hashlib.sha256(open(p, "rb").read()).hexdigest()
    except OSError:
        return None


def running():
    t = subprocess.run(["tasklist"], capture_output=True, text=True).stdout.lower()
    return "notepad.exe" in t or "calculatorapp.exe" in t


def main(cmd):
    diffs = 0
    for pkg in PKGS:
        for sub in SUBS:
            live = os.path.join(BASE, pkg, sub)
            pre = os.path.join(PRE, pkg, sub)
            if cmd == "snap":
                if os.path.exists(pre):
                    shutil.rmtree(pre)
                shutil.copytree(live, pre)
                print("snap", pkg, sub, len(files(pre)))
                continue
            for r in sorted(files(live) | files(pre)):
                a, b = os.path.join(live, r), os.path.join(pre, r)
                ha, hb = h(a) if os.path.exists(a) else "-", h(b) if os.path.exists(b) else "-"
                if ha == hb:
                    continue
                diffs += 1
                print("DIFF", pkg, sub, r, "pre" if hb != "-" else "new")
                if cmd == "restore":
                    if hb == "-":
                        dst = os.path.join(CREATED, pkg, sub, r)
                        os.makedirs(os.path.dirname(dst), exist_ok=True)
                        shutil.move(a, dst)
                    else:
                        os.makedirs(os.path.dirname(a), exist_ok=True)
                        shutil.copy2(b, a)
    if cmd != "snap":
        print("differences:", diffs)


if __name__ == "__main__":
    if sys.argv[1] in ("restore", "snap") and running():
        sys.exit("Notepad or Calculator is running; refusing")
    main(sys.argv[1])
