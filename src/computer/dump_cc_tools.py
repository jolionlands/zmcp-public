"""Dump computer_control_mcp's FastMCP tool schemas to cc_tools.json (input
for gen_schemas.py). RapidOCR is stubbed so importing core.py does not load
the OCR model; nothing is executed besides list_tools().

Run with the Python that has computer_control_mcp installed, from a directory
without a stray mcp.py:  python -E dump_cc_tools.py
"""
import sys, types, json, asyncio
m = types.ModuleType("rapidocr"); m.RapidOCR = lambda *a, **k: None; sys.modules["rapidocr"] = m
from computer_control_mcp import core
tools = asyncio.run(core.mcp.list_tools())
out = [{"name": t.name, "description": t.description, "inputSchema": t.inputSchema} for t in tools]
json.dump(out, open("cc_tools.json","w"), indent=1)
print(len(out))
