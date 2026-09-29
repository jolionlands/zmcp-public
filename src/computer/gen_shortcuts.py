import os, re, sys
# Usage: gen_shortcuts.py <path to clawdcursor/src/shortcuts.ts>  (or set CLAWDCURSOR_SHORTCUTS)
path = sys.argv[1] if len(sys.argv) > 1 else os.environ.get('CLAWDCURSOR_SHORTCUTS')
if not path:
    sys.exit('usage: gen_shortcuts.py <path to clawdcursor shortcuts.ts>')
src = open(path, encoding='utf8').read()
start = src.index('export const SHORTCUTS')
body = src[start:src.index('\n];', start)]
body = body.replace('${MOD}', 'Control').replace('${CMD}', 'Super')
calls = re.findall(r"shortcut\((.*?)\)(?:,|\s*$)", body, re.S)
BS = chr(92)


def strs(s):
    return re.findall(r"'((?:[^'\\]|\\.)*)'|`((?:[^`\\]|\\.)*)`", s)


def esc(s):
    return s.replace(BS, BS + BS).replace('"', BS + '"')


out = ["//! Generated from clawdcursor src/shortcuts.ts (v0.9.3) by gen_shortcuts.py.",
       "//! Windows bindings only (keys.win32 ?? keys.default); entries with no Windows binding are dropped.",
       "", "pub const Shortcut = struct {", "    id: []const u8,", "    category: []const u8,", "    description: []const u8,",
       "    intent: []const u8,", "    intents: []const []const u8,", "    key: []const u8,",
       "    context: []const []const u8 = &.{},", "};", "",
       "pub const all = [_]Shortcut{"]
n = 0
for c in calls:
    m = re.match(r"\s*'([^']*)',\s*'([^']*)',\s*'([^']*)',\s*'([^']*)',\s*\[(.*?)\],\s*\{(.*?)\}(?:,\s*\[(.*?)\])?\s*$", c, re.S)
    if not m:
        raise SystemExit("unparsed: " + c[:80])
    id_, cat, desc, intent, intents, keys, ctx = m.groups()
    kd = dict((k, (a or b)) for k, a, b in re.findall(r"(\w+):\s*(?:'([^']*)'|`([^`]*)`)", keys))
    key = kd.get('win32', kd.get('default', ''))
    if not key:
        continue
    il = [a or b for a, b in strs(intents)]
    cl = [a or b for a, b in strs(ctx or '')]
    line = '    .{ .id = "%s", .category = "%s", .description = "%s", .intent = "%s", .intents = &.{ %s }, .key = "%s"' % (
        esc(id_), cat, esc(desc), esc(intent), ", ".join('"%s"' % esc(i) for i in il), esc(key))
    if cl:
        line += ', .context = &.{ %s }' % ", ".join('"%s"' % esc(i) for i in cl)
    out.append(line + " },")
    n += 1
out.append("};")
open('shortcuts_data.zig', 'w', newline='\n').write("\n".join(out) + "\n")
print(n, "shortcuts of", len(calls))
