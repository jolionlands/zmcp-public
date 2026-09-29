# zmcp

Small, fast [MCP](https://modelcontextprotocol.io) servers and CLI tools
written in Zig. Each server is a single static binary that speaks
line-delimited JSON-RPC over stdio, so it works with any MCP host (Claude
Code, Codex, Cursor and others). There is no Node runtime, no V8 and no JIT:
an idle server uses about 1 to 3 MB of memory and a typical `tools/list`
is a few kilobytes.

Read-only by default: anything that writes, executes code or deletes is
refused until you set an explicit `ZMCP_<NAME>_ALLOW_*` variable.

## Contents

- [Quick start](#quick-start)
- [Servers](#servers)
- [Environment variables](#environment-variables)
- [zmcp-gateway](#zmcp-gateway)
- [zmcp-computer](#zmcp-computer) and [zmcp-desktop](#zmcp-desktop) (Windows)
- [Library](#library), [License](#license), [Data sources](#data-sources-and-attribution)

## Quick start

Requires [Zig](https://ziglang.org/download/) 0.16.0.

```bash
zig build -Doptimize=ReleaseSmall     # all servers into zig-out/bin
zig build github                      # a single server
zig build install -p ~/bin            # install elsewhere
zig build test                        # run the test suite
```

Cross-compile with `-Dtarget=...` (Windows, Linux and macOS on x86_64 and
ARM64). `zmcp-computer` and `zmcp-desktop` are built for Windows targets only.

Point your MCP host at the binaries, for example in `mcp.json`:

```json
{
  "mcpServers": {
    "time":   { "command": "zmcp-time" },
    "git":    { "command": "zmcp-git" },
    "github": { "command": "zmcp-github", "env": { "GITHUB_TOKEN": "..." } }
  }
}
```

To keep context small when you use many servers, put them behind
[`zmcp-gateway`](#zmcp-gateway), which exposes three tools whatever the slice size.

## Servers

Every server is `zmcp-<name>`. Variables named in the tables are optional
unless the description says "needs".

### Web, search and docs

| Server | Description |
|---|---|
| `zmcp-web-search` | Web search via Brave (`BRAVE_API_KEY`), Tavily (`TAVILY_API_KEY`) or SearXNG (`SEARXNG_URL`). DuckDuckGo HTML scraping is off unless `ZMCP_WEB_SEARCH_ALLOW_DDG_SCRAPE=1` (may violate its terms) |
| `zmcp-websearch-apis` | Exa, Tavily and Firecrawl in one binary; a provider's tools appear only when its API key is set. Not run against the live APIs |
| `zmcp-fetch` | HTTP fetch with content-type-aware extraction |
| `zmcp-browser` | Chrome DevTools Protocol automation over a hand-written WebSocket client. See [zmcp-browser](#zmcp-browser) |
| `zmcp-context7` | Library id resolution and documentation lookup via Context7 |
| `zmcp-mslearn` | Microsoft Learn search and fetch through Microsoft's hosted MCP endpoint (no key). Untested against the live endpoint |
| `zmcp-zig-docs` | Zig tool wrappers plus stdlib symbol and file lookup (`ZIG_BIN`, default `zig` on `PATH`) |
| `zmcp-zig-packages` | Zig package search over GitHub |
| `zmcp-package-registry` | npm, PyPI and crates.io queries |
| `zmcp-compiler-explorer` | godbolt.org: compile, run, diagnostics, optimization analysis, share URLs |
| `zmcp-ai-elements` | Vercel AI Elements registry: browse, fetch, source, install commands |
| `zmcp-tldr` | tldr-pages fetch and search |
| `zmcp-huggingface` | Hugging Face Hub models, datasets, papers and model cards |
| `zmcp-arxiv` | arXiv search and single-paper fetch |
| `zmcp-hn`, `zmcp-social` | Hacker News (Algolia and Firebase); `zmcp-social` adds Reddit search, top, subreddit and thread browsing (set `REDDIT_USERNAME`) |
| `zmcp-rss` | RSS and Atom fetch and a merged multi-feed timeline |
| `zmcp-weather` | Forecasts, current conditions, alerts, historical, air quality and marine data from Open-Meteo and NOAA |
| `zmcp-currency` | FX conversion, spot rates and timeseries |

### Code and version control

| Server | Description |
|---|---|
| `zmcp-github` | GitHub REST and GraphQL with tool and parameter names matching the official GitHub MCP server. See [zmcp-github](#zmcp-github) |
| `zmcp-git` | Local git: status, diffs, log, show, add, commit, reset, branch, checkout. No push, force or clean; arguments cannot become flags |
| `zmcp-ripgrep` | ripgrep search, file listing and match counts with capped output |
| `zmcp-ast-grep` | AST-aware search and rewrite via the ast-grep CLI |
| `zmcp-lsp` | Language-server bridge (zls, gopls, rust-analyzer, pyright, typescript-language-server): definition, references, hover, symbols, diagnostics, rename preview. Applying a rename needs `ZMCP_LSP_ALLOW_WRITE=1`. Smoke-tested with pyright and typescript-language-server only |
| `zmcp-diff-render` | Difftastic-backed diff rendering for files, strings and git revisions |
| `zmcp-markdown-render` | Markdown to ANSI, plus fenced code extraction |
| `zmcp-jq` | JSON tools: jq-subset query, validate, format, key summary, schema inference. Unsupported jq syntax is rejected, not guessed |
| `zmcp-zutil` | Deterministic helpers models get wrong: codecs, hashes and HMAC, ids, JWT decode (unverified), calculator, units, base conversion, stats, cron next-fire, semver ranges |
| `zmcp-time`, `zmcp-datetime` | Time conversion and current time. `zmcp-time` defaults to UTC; override with `ZMCP_LOCAL_TZ` |

### Data and infrastructure

| Server | Description |
|---|---|
| `zmcp-postgres` | Via the `psql` CLI: read-only queries (single statement, read-only transaction), schema, explain. Writes need `ZMCP_POSTGRES_ALLOW_WRITE=1`. Also reads `ZMCP_POSTGRES_STATEMENT_TIMEOUT_MS`, `ZMCP_POSTGRES_PSQL` and the standard `PG*` variables. Use a least-privilege role: read-only transactions do not restrict privileged functions |
| `zmcp-sqlite` | Per-call query, exec and schema inspection via the local `sqlite3` CLI |
| `zmcp-duckdb` | DuckDB CLI: read-only SQL over databases or csv/parquet/json files, schema; writes need `ZMCP_DUCKDB_ALLOW_WRITE=1` |
| `zmcp-redis` | Native RESP2 client (`REDIS_URL`): get, list (SCAN), ttl, type, hgetall. set/delete need `ZMCP_REDIS_ALLOW_WRITE=1`. Plain TCP only, no TLS |
| `zmcp-docker` | Docker CLI: ps, images, logs, inspect, stats, compose. Start/stop/restart need `ZMCP_DOCKER_ALLOW_WRITE=1` |
| `zmcp-kubernetes` | kubectl: get, describe, logs, top, events, rollout status, context. Apply/delete/scale/restart need `ZMCP_KUBERNETES_ALLOW_WRITE=1`; no exec or port-forward; Secret values redacted |
| `zmcp-aws` | AWS CLI behind an allowlist of read operations; secret-returning calls blocked, output redacted. Writes need `ZMCP_AWS_ALLOW_WRITE=1`, destructive calls also `ZMCP_AWS_ALLOW_DESTRUCTIVE=1`. Tested with fakes and awscli v1 only |

### Files, memory and productivity

| Server | Description |
|---|---|
| `zmcp-fs` | Filesystem operations beyond a host's built-ins |
| `zmcp-pdf` | Pure-Zig PDF text extraction: info, page text, search. Encrypted and scanned PDFs are reported, not read. Confined to `ZMCP_PDF_ROOT` |
| `zmcp-memory` | Knowledge-graph memory (entities, relations, observations), JSONL-compatible with the reference server |
| `zmcp-hippo` | Wrapper over the `hippo` CLI (graph and temporal vector memory). Set `HIPPO_BIN` / `HIPPO_DIR`; admin and daemon commands are not exposed |
| `zmcp-sequentialthinking` | Branching, revision-aware sequential-thinking state machine (port of the reference server) |
| `zmcp-todo` | Per-project todo scratchpad |
| `zmcp-wiki` | Wiki search, note read, backlinks and tag views |
| `zmcp-tickets` | Ticket, sprint, verify and swarm tools |
| `zmcp-notion` | Search, pages, blocks as text, data-source queries, comments, users. Writes need `ZMCP_NOTION_ALLOW_WRITE=1` (`NOTION_TOKEN`). Not run against the live API |

### Media, creative and AI

| Server | Description |
|---|---|
| `zmcp-figma` | Figma files as compact layout JSON with a shared style table, plus image export to a confined directory (`FIGMA_API_KEY`, `ZMCP_FIGMA_OUT_DIR`). Not run against the live API |
| `zmcp-blender` | Client for the blender-mcp addon socket (`BLENDER_HOST` / `BLENDER_PORT`); `execute_blender_code` needs `ZMCP_BLENDER_ALLOW_EXEC=1`. Not run against a live Blender |
| `zmcp-godot` | Godot CLI: project info, scene create/add node/save (`ZMCP_GODOT_ALLOW_WRITE=1`), run/stop with captured output. `launch_editor` and `run_project` execute project scripts and need `ZMCP_GODOT_ALLOW_RUN=1` (`GODOT_PATH`). Smoke-tested on Godot 4.3 headless |
| `zmcp-minimax` | MiniMax REST: image description, web search, image/speech/music/video generation, quota |
| `zmcp-llm` | OpenAI-compatible client (Ollama, llama.cpp, LM Studio, vLLM, OpenRouter): chat, models, embeddings with cosine similarity, read-only `ollama_*`. Set `OPENAI_BASE_URL`, `OPENAI_API_KEY`, `ZMCP_LLM_MODEL`. Tested against a local stub only |
| `zmcp-freejobs` | Provider routing and CLI worker bridge tools (keys read from the environment) |

### Windows desktop

| Server | Description |
|---|---|
| `zmcp-computer` | Native desktop control: mouse and keyboard, screenshots, OCR, windows, clipboard. See [zmcp-computer](#zmcp-computer) |
| `zmcp-desktop` | UI Automation observe and act for allowlisted apps, with a kill switch, auto-pause on user input and step limits. See [zmcp-desktop](#zmcp-desktop) |

### Gateway

| Server | Description |
|---|---|
| `zmcp-gateway` | One MCP endpoint over a named slice of the servers above: searchable catalog, lazy child processes, idle reaping. See [zmcp-gateway](#zmcp-gateway) |

### zmcp-github

Tool and parameter names match the official GitHub MCP server: issues, pull
requests and reviews, repos, files and branches, Actions, code and secret
scanning, Dependabot, discussions, gists, notifications, projects and orgs.
It has not been run against the live API.

- **Toolsets:** `ZMCP_GITHUB_TOOLSETS` selects them. The default
  (`context,repos,issues,pull_requests,users`) is 44 tools, about 16.5 KB of
  `tools/list`; `all` is 85 tools, about 31.7 KB.
- **Auth:** `GITHUB_TOKEN` (or `GITHUB_PERSONAL_ACCESS_TOKEN` / `GH_TOKEN`).
  GitHub Enterprise via `GITHUB_API_URL` or `GITHUB_HOST`.
- **Writes:** need `ZMCP_GITHUB_ALLOW_WRITE=1`; destructive ones also need
  `ZMCP_GITHUB_ALLOW_DESTRUCTIVE=1`. `GITHUB_READ_ONLY=1` forces read-only.
- **Renamed tools:** the earlier zmcp names (`repo_view`, `issue_list`,
  `pr_view`, `gh_run`, ...) no longer exist.

### zmcp-browser

Launches a fresh headless Chrome or Edge with a temporary profile
(`ZMCP_BROWSER_BIN`): navigate, accessibility snapshot with refs,
click/type/select/hover, screenshot, console, network, tabs and dialogs.

- **Attach mode:** using your own running browser needs `ZMCP_BROWSER_ATTACH=1`.
- **URL policy:** `file:`, `chrome:` and private-network URLs are blocked by
  default. It is not DNS-rebinding safe.
- **`browser_evaluate`:** runs JavaScript in the page and is on by default;
  set `ZMCP_BROWSER_NO_EVAL=1` to disable it.
- **Tested** against real headless Chrome 141 on Linux only.

## Environment variables

Optional variables shared across servers (each server's own settings are in
its tool descriptions and the tables above):

| Variable | Used by | Effect |
|----------|---------|--------|
| `ZMCP_CONTACT` | every server that calls an HTTP API | Email or URL appended to the User-Agent as `; contact: ...`, so API operators can reach you. Recommended for `zmcp-package-registry` (crates.io policy) and `zmcp-arxiv` |
| `REDDIT_USERNAME` | `zmcp-social` | Reddit username for the User-Agent `linux:zmcp-social:0.1.0 (by /u/NAME)`. Unset means anonymous requests, which Reddit may throttle or block |
| `ZMCP_LOCAL_TZ` | `zmcp-time` | IANA zone used when a call gives no timezone (default `UTC`) |
| `ZMCP_WEB_SEARCH_ALLOW_DDG_SCRAPE` | `zmcp-web-search` | `1` allows the DuckDuckGo HTML scraping backend. Off by default; with no backend configured the tool returns an error explaining the options |

Every HTTP-calling server identifies itself honestly, for example
`zmcp-rss/0.1.0 (+https://github.com/jolionlands/zmcp-public)`.

## zmcp-gateway

One MCP endpoint that serves a named **slice** of the zmcp servers while
keeping context and memory tiny. It does not link the servers: it spawns the
real `zmcp-<name>` binaries as stdio children on first use, keeps them warm,
and reaps them after an idle timeout. Tools are found through a static
catalog, so searching never starts a process. It reuses `mcp.run`, so it also
gets stdio, `ZMCP_HTTP` hosting (streamable HTTP + SSE, token/origin checks)
and `ZMCP_MAX_RESULT_BYTES`.

```bash
zmcp-gateway catalog                 # spawn each sibling once, write catalog.json
zmcp-gateway profiles                # list profiles from gateway.json
zmcp-gateway list --profile dev      # servers / tools / byte cost (--tools for each tool)
zmcp-gateway search pull request     # try the ranked search from the shell
zmcp-gateway serve --profile dev     # MCP over stdio (add ZMCP_HTTP=127.0.0.1:8080 to host)
zmcp-gateway serve --servers memory,git   # ad-hoc slice
```

Host config: `{"command": "zmcp-gateway", "args": ["serve", "--profile", "dev"]}`.

### Profiles

`gateway.json` next to the executable (or `ZMCP_GATEWAY_CONFIG`):

```json
{"profiles": {
  "dev": {"servers": ["memory", "git", "ripgrep"], "tools_deny": ["git_reset"], "readonly": false},
  "ro":  {"servers": ["git", "docker"], "tools_allow": ["git_*", "docker_ps"], "readonly": true}
}}
```

Select with `--profile NAME` or `ZMCP_GATEWAY_PROFILE`; `--servers a,b` gives an
ad-hoc list (and overrides a profile's server list, keeping its rules). With
neither, every server found is served. Unknown server or profile names are a
startup error that names the closest matches. `tools_allow` / `tools_deny` take
exact names or a trailing `*` (same as `ZMCP_TOOLS`); deny wins. `readonly`
keeps only tools whose catalog entry has `annotations.readOnlyHint`; servers
that do not mark their tools yet contribute nothing, so a readonly slice can be
empty (reported on stderr, in `list`, and by `tools_search`, never a failure).
The gateway's own `ZMCP_TOOLS_DENY` and `ZMCP_READONLY` add to the profile;
`ZMCP_TOOLS` applies only when the profile has no allowlist.

The rules are enforced in the gateway itself (search results, `tool_schema` and
`tool_call`) and are also passed to each child as `ZMCP_TOOLS` /
`ZMCP_TOOLS_DENY` / `ZMCP_READONLY` (only the patterns that match that child's
tools) as defense in depth.

### Exposure

- **lazy** (default): exactly three tools, about 1 KB of context regardless of
  how many servers are in the slice.
  - `tools_search` - no arguments returns a category overview
    (`code (27): ast-grep, ripgrep, ...`); `query` runs a BM25-ranked search
    (name hits beat description hits; plural stemming, prefix matching);
    filters `category`, `server`, `read_only`, `limit`. Results are
    `name [server/category, ro] one-line description`.
  - `tool_schema` - compact input schemas by name.
  - `tool_call` - run a tool by name with an `arguments` object.
- **direct** (`ZMCP_GATEWAY_EXPOSE=direct` or `--expose direct`): advertise the
  slice's real tools (compact-rendered) and route calls by name. Costs context
  in proportion to the slice.

Categories are one of `web-search docs code vcs data files memory infra comms
media time utility`, assigned from a static table keyed by server name inside
the gateway (unknown servers get a category guessed from the name).

If two servers in the slice expose the same tool name (for example
`web_search` in `web-search` and `minimax`), both are exposed as
`server.tool`; search output says so and a bare name returns the choices.

### Children

Found next to the gateway executable (`ZMCP_GATEWAY_BIN_DIR` overrides that
directory), else on `PATH`. Argv-only: a validated server name
(`[a-z0-9_-]+`) becomes `zmcp-<name>`; no shell, no user string on a command
line. Children inherit the environment (so `ZMCP_DOCKER_ALLOW_WRITE`, API keys,
`ZMCP_MAX_RESULT_BYTES` work) minus the gateway-only variables `ZMCP_HTTP*`,
`ZMCP_GATEWAY_*` and `ZMCP_TOOL_MODE`, so they stay on stdio in full mode.
Tool arguments and environment values are never logged. A child that crashes
or times out is killed and marked dead; the call returns an `isError` result
and the next call respawns it (a request that could not even be written is
retried once on a fresh child; a failed spawn is retried once). Calls are
serialized through one lock (also across children); a slow call blocks the
others. Children are killed when the gateway exits or its stdin closes, and
exit by themselves if the gateway dies, since their stdin closes.

| Variable | Default | Meaning |
|---|---|---|
| `ZMCP_GATEWAY_PROFILE` | none | Profile to serve |
| `ZMCP_GATEWAY_CONFIG` | `gateway.json` next to the exe | Profiles file |
| `ZMCP_GATEWAY_CATALOG` | `catalog.json` next to the exe | Catalog file |
| `ZMCP_GATEWAY_BIN_DIR` | the exe's directory | Where `zmcp-*` binaries are |
| `ZMCP_GATEWAY_EXPOSE` | `lazy` | `lazy` or `direct` |
| `ZMCP_GATEWAY_IDLE_SECS` | 300 | Reap a child idle this long (0 = never) |
| `ZMCP_GATEWAY_CALL_TIMEOUT_SECS` | 120 | Per-call timeout; the child is killed on expiry |
| `ZMCP_GATEWAY_MAX_CHILDREN` | 8 | Live children cap; the least recently used idle one is reaped |

### Catalog

`zmcp-gateway catalog [--out FILE]` spawns every `zmcp-*` next to the gateway
once (initialize + `tools/list`) and writes the catalog: per server, each
tool's name, one-line description, compact schema, read-only/destructive marks,
category and tags, plus the binary's size and mtime. At `serve`, a missing
catalog is built on the fly (progress on stderr only); entries whose binary
changed are rebuilt and the file is rewritten (best effort). Build the catalog
with the environment you serve with: servers that register tools conditionally
(`zmcp-websearch-apis` needs API keys) are catalogued as they appeared then.

### Measured

Linux x86_64, `-Doptimize=ReleaseSmall`, measured on an earlier build with 42 non-Windows servers (235 tools); current totals are higher:

| | |
|---|---|
| gateway binary | 416 KB |
| gateway idle RSS (before any child), all 42 servers / 235 tools | 2.7 MB |
| same, 3-server `dev` profile | 1.4 MB |
| `tools/list` bytes, lazy mode, all servers | 1,040 B |
| `tools/list` bytes, lazy mode, 3-server slice | 1,038 B |
| `tools/list` bytes, direct mode (compact), 3 servers / 23 tools | 9.9 KB |
| `tools/list` bytes, direct mode (compact), all servers | 102 KB |
| `tools/list` bytes, the servers registered separately in full mode | 135 KB (11 KB for memory+git+ripgrep) |
| `tools_search` with no arguments (categories overview), all servers | 787 B |
| ranked `tools_search` over all 235 tools | 15-125 us in-process |
| cold spawn + handshake + first call (datetime / memory) | 1.7 ms / 1.3 ms |
| `zmcp-gateway catalog` (spawns 42 servers) | 70 ms |

A live child costs roughly 0.6 MB each (`zmcp-git`, `zmcp-memory`, `zmcp-datetime`).

## zmcp-computer

One Windows-only binary (`zig build computer`) that replaces two servers:
`computer_control_mcp` 0.3.10 (Python, pyautogui, RapidOCR) and clawdcursor
0.9.3 `mcp --compact` (Node, x64-only libnut). It is pure Zig over Win32 and
WinRT, has no C dependencies, and builds natively for ARM64.

It is one binary rather than two because both surfaces share the whole core
(input, capture, PNG, OCR, windows). Together they are 18 tools and about 12 KB
of `tools/list`. `--surface=computer-control` or `--surface=clawdcursor`
exposes a single upstream's tools as a drop-in replacement. The default is
`--surface=all`.

| Surface | Tools | Coordinates |
|---|---|---|
| computer_control | `click_screen`, `get_screen_size`, `type_text`, `take_screenshot`, `take_screenshot_with_ocr`, `move_mouse`, `mouse_down`, `mouse_up`, `drag_mouse`, `key_down`, `key_up`, `press_keys`, `list_windows`, `wait_milliseconds`, `activate_window` | Physical pixels on the virtual desktop |
| clawdcursor | `computer` (22 actions), `window` (15), `system` (14 listed, 8 working) | `computer`: image space (the primary monitor scaled to at most 1280 px wide). `window`: physical pixels |

The process is per-monitor-v2 DPI aware, so SendInput, window rectangles,
captures and monitor bounds all use physical pixels.

**Flags and environment:** `--dry-run` or `ZMCP_COMPUTER_DRY_RUN=1` stops the
server from injecting input, focusing windows, capturing the screen or touching
the clipboard; each call reports `[dry-run] would ...` instead.
`ZMCP_COMPUTER_ALLOW_BLOCKED_KEYS=1` lifts the destructive-combo blocklist.
`save_to_downloads` writes nothing to disk unless the server runs with
`ZMCP_COMPUTER_ALLOW_SAVE=1`. By default, screenshots exist only in the MCP
response. With the variable set, `COMPUTER_CONTROL_MCP_SCREENSHOT_DIR` works as
it does upstream.

**Guard rails:**

- **Destructive combos:** a combo is refused if it contains a blocked chord,
  meaning the chord's modifiers are a subset of the combo's modifiers and its
  key appears anywhere in the combo. `alt+f4+x`, `shift+alt+f4` and
  `ctrl+shift+w` are all refused. Modifier aliases (`menu`/`alt`,
  `win`/`lwin`/`rwin`/`super`/`meta`, `ctrl`/`control`) and left/right
  variants are normalised.
- **Held keys:** the server tracks keys held across `key_down`/`key_up`. Every
  keyboard send replays its events on top of those keys and the modifiers
  `GetAsyncKeyState` reports as down, so `key_down alt` followed by `f4` is
  refused on every path.
- **UIPI:** SendInput is silently dropped for higher-integrity windows. Input,
  `activate`, `resize`, `close`, and `maximize`/`minimize`/`restore` are
  refused when the target's integrity level is higher than the server's, or
  cannot be read. The target is the window under the point for mouse actions
  and the foreground window for keys.
- **Arguments:**
  - Numbers must be finite with |v| ≤ 1e7.
  - Points outside the virtual desktop are rejected, not clamped. A drag checks
    every point before the button goes down.
  - `screenshot_region` must lie entirely on the desktop.
  - Typed text is capped at 65,536 characters and is never echoed back.
- **`open_file`:** only an allowlist of document, image and media types
  (a fixed set, without csv/xml) is opened. The file is opened with
  `FILE_FLAG_OPEN_REPARSE_POINT` and resolved with
  `GetFinalPathNameByHandleW`. Reparse points, folders, and final paths that
  are UNC or device paths are refused. The allowlist runs on the FINAL long
  name, so an 8.3 name like `REPORT~1.PDF` for `report.pdfexe` is refused,
  and the resolved path is what gets opened. UNC, `\?\` and `\.\`
  inputs, DOS device names and `:` streams are refused up front.
- **OCR size:** images larger than `OcrEngine.MaxImageDimension` (queried at
  run time) are downscaled for OCR, and the coordinates are mapped back.

**Names and schemas:** every tool name, action name and argument name
matches the upstream servers. `schemas.zig` is generated from the upstream
definitions by `gen_schemas.py`, and `shortcuts_data.zig` by
`gen_shortcuts.py`. The server adds these arguments:

- `take_screenshot.max_width` scales the image down.
- `computer.key` is an alias for `combo`.
- `window.confirm` must be `true` for `close`. Over MCP, clawdcursor's safety layer
  always refused `close` with a "safety confirm" error.

**Behaviour changes (the better design wins):**

- **Typing (`type_text`, `computer.type`):** sends `KEYEVENTF_UNICODE`
  keystrokes, with Enter and Tab sent as real keys. pyautogui typed ASCII only,
  and clawdcursor pasted through the clipboard. Any character now works, and
  the clipboard is never touched.
- **Window screenshots (`title_pattern`):** use `PrintWindow(PW_RENDERFULLCONTENT)`
  cropped to the DWM visible frame. The window is **not** activated, so the
  user's focus is never stolen. `use_wgc` is accepted and ignored.
- **OCR:** uses Windows.Media.Ocr through WinRT vtables instead of RapidOCR.
  - Results come back per line, and confidence is always 1.0.
  - `take_screenshot_with_ocr` returns absolute screen coordinates even with
    `scale_percent_for_ocr`. Upstream did not add the window offset or undo
    the scaling, although its docstring said it did.
  - `system.ocr` returns words with their line index.
- **Blocked key combos:** clawdcursor's destructive-combo blocklist (`alt+f4`,
  `ctrl+alt+del`, `win+l/r/d`, `f11`, `ctrl+shift+esc`, `ctrl+w`) now applies
  to both surfaces, including `shortcuts_run`, as described under
  *Guard rails*. `press_keys` checks the whole sequence before it sends any
  key, and also accepts `"ctrl+c"` strings.
- **`type_text` reply:** says how many characters were typed instead of
  echoing the text.
- **Horizontal scroll:** `scroll_horizontal` uses `MOUSEEVENTF_HWHEEL`
  instead of Shift+wheel.
- **Screenshot format:** screenshots are PNG. clawdcursor sent JPEG.
- **Window listing:** `list_windows` is a single JSON array with added
  `process_name` and `pid` fields. Cloaked windows (other virtual desktops and
  hidden UWP frames) are left out.
- **Waits:** `wait_milliseconds` is capped at 10 minutes.
- **`open_app`:** has no Start-menu-typing fallback.
- **`navigate`:** opens Edge with CDP on port 9223, but there is no `browser`
  tool to drive it.

**Not implemented in this binary:**

- **`accessibility`:** UI Automation lives in a separate zmcp process
  (`zmcp-desktop`).
- **`browser`:** not in this binary; use the separate `zmcp-browser` server.
- **`task`:** needs the clawdcursor agent daemon.
- **`system` stubs:** `delegate`, `relaunch_with_cdp`, `app_guide`,
  `detect_app`, `classify_task` and `system_prompt` return a clear error.
  They need clawdcursor's LLM pipeline.
- **`detect_webview`:** does not probe CDP ports.
- **Label-based safety:** clawdcursor's "confirm" heuristics based on labels
  (send/delete/...) and on sensitive apps were not ported.

**Safety in tests:** `input.send`, screen capture, window state changes and
the clipboard all return an error inside a test binary. As a result, `zig build
test` cannot move the pointer, press a key, read the screen or foreground a
window on the machine that runs it. OCR is tested on text that GDI draws into an
offscreen bitmap.

**Live test:** `src/computer/live/` has an instrumented WinForms target
(`target.ps1`), which logs every mouse, wheel and key message it receives, and
an MCP driver (`driver.py`) with 57 checks.

Run it in an interactive session on a machine that nobody is using:

1. Copy the files and the x64 build to a scratch directory, e.g. `C:\zmcp-live`.
2. Start the driver in the interactive session:
   `schtasks /create /tn zmcp-live-test /tr "python C:\zmcp-live\driver.py" /sc once /st 23:59 /it` then `schtasks /run`.

The driver moves the pointer, types into its own window, opens and closes
Character Map, and round-trips the clipboard, restoring the previous text.

## zmcp-desktop

A Windows-only UI Automation server (`zig build desktop`) that observes and acts
on allowlisted apps, started by a host for one control session:

```
zmcp-desktop --allow "C:\Program Files\Signal\Signal.exe" --allow "C:\Windows\System32\charmap.exe" [--kill-event NAME]
             [--max-steps 100] [--step-timeout-ms 10000] [--session-timeout-s 900] [--idle-ms 750] [--allow-payments]
             [--resume-event NAME] [--debug-input]
```

`--debug-input` prints to stderr which input events the auto-pause counted as
the user's (kind, message, flags, dwExtraInfo; never key codes or positions).

It is pure Zig over COM vtables generated from the SDK's `UIAutomationClient.h`
(`src/desktop/gen_uia.py`). It makes no network calls.

| Tool | Returns |
|---|---|
| `desktop_list_windows {}` | `{windows:[{hwnd, exe, path, title, pid}]}` for visible windows of allowlisted processes only; other windows' titles are never read |
| `desktop_observe {hwnd, max_depth?=8, max_nodes?=400, root?}` | `{window:{hwnd,exe,path,title,pid}, count, truncated, truncated_by, ms, dropped, nodes:[{id, parent, role, name, value?, text?, rect:[x,y,w,h], enabled, focusable, is_password, automation_id?, class_name?, value_pattern, text_pattern?}]}`; `text` is the TextPattern text of a focusable edit/group/custom field (a contenteditable composer), never a password field's |
| `desktop_find {hwnd, role?, name_contains?, limit?=20}` | matching nodes, same shape |
| `desktop_focused {hwnd}` | the focused node when `hwnd` is the foreground window, with `value` and, for a contenteditable composer, `text` (TextPattern; never a password field's) |
| `desktop_act {hwnd, id, action, value?}` | `invoke` (InvokePattern, else a click at the element when the window is in front), `focus`, `set_value` (ValuePattern), `select`, `expand`, `scroll_into_view` |
| `desktop_type {hwnd, text, expected_id?}` | Unicode keystrokes into the focused element; the window must be the foreground window; with `expected_id`, refused unless that element has the focus |
| `desktop_key {hwnd, keys, expected_id?}` | one chord from a fixed allowlist (`enter`, `shift+enter`, `tab`, `shift+tab`, `escape`, editing and navigation keys, `ctrl+a/z/y/f`, `f2/f3/f5`); with `expected_id`, refused unless that element has the focus |
| `desktop_click {hwnd, x, y}` | a left click inside the foreground window, only where UIA can't invoke the element |
| `desktop_scroll {hwnd, id, direction, amount?=1}` | ScrollPattern on the element or its nearest scrollable ancestor |

Every act returns `{ok, action, after: {focused_id, window_title}}`, so the host
can verify it.

Element ids are UIA runtime ids encoded as `r<hex>-<hex>…` and are re-resolved
on every call (`root` accepts one). An observe walks the ControlView level by
level: one cross-process call per expanded node returns its children with
their properties (a cache request with `TreeScope_Element|Children`), so a huge
tree is never pulled far past the caps. Known limit: one call returns all
children of an expanded node, so a single node with thousands of children is
fetched whole (within UIA's 3 s transaction timeout) before the caps trim the
reply. A per-node TreeWalker gives exact caps but measured 199 ms p50 against
119 ms on a 280-node Edge window, so it is only reachable through
`--bench HWND [RUNS]`, which times all three strategies. The walk stops at `max_nodes`, 2 s or 4 MiB
of held text, and says which in `truncated_by` (`nodes`, `time`, `bytes`). UIA
runs with a 1 s connection and 3 s transaction timeout (`IUIAutomation2` from
`CUIAutomation8`).

**Guard rails:**

- **Allowlist format:** each `--allow` value is one or more FULL image paths,
  separated by `|`, exactly as `QueryFullProcessImageNameW` reports them
  (`C:\...\app.exe`). Matching is on the whole path, case-insensitively. An
  entry is dropped unless it is an absolute drive path with no `.`/`..`
  segment or wildcard; a bare name such as `signal.exe` matches nothing. There
  is no default: with no valid entry every call is refused, and
  `desktop_list_windows` refuses before opening any process. Paths are compared
in canonical form: the long name (`GetLongPathNameW`), lower-cased with
Unicode awareness (`CharLowerBuffW`), on both the entry and the process image.
- **UWP:** `ApplicationFrameHost.exe` is never accepted as an entry. A UWP
  frame (the genuine `System32\ApplicationFrameHost.exe`) is gated on the
  process of its hosted `Windows.UI.Core.CoreWindow`, so the allowlist names
  the app itself (for example the `CalculatorApp.exe` path under
  `WindowsApps`). A frame with no hosted window (suspended) is refused.
- The kill event `Local\zmcp-desktop-kill-<ppid>` (or `--kill-event NAME`) is
  checked before every call, watched by a thread, and polled between injected
  chunks. Once it is seen set, every call returns "stopped by the user" for the
  rest of the process, even if the event is reset.
- Windows of elevated processes (the zmcp-computer integrity check), the secure
  desktop, `LogonUI.exe`, `consent.exe` and `CredentialUIBroker.exe` are always
  refused. Nodes of a non-allowlisted process embedded in an allowlisted window
  are dropped with their subtree.
- Password fields: the value is never requested and never returned. Values are
  read only for non-password edit, combobox, document, slider and spinner
  nodes (at most 32 per observe).
- Text is capped at 500 characters per node and a reply at 256 KiB (`truncated`).

**Act guard rails** (checked when an act starts and again right before its side
effect, and before every chunk of injected input):

- The window's process and full image path must pass the allowlist and the
  integrity check at that moment (re-read, not taken from an earlier observe),
  and so must the element's own process.
- Never while the workstation is locked (WTS session flags, failing closed) or
  the input desktop is not `Default` (UAC, logon).
- Password fields are refused for every action (`desktop_key` allows only
  `tab`, `shift+tab` and `escape` to leave one). Buttons, links and menu items
  whose name looks like a payment (`pay…`, `purchase`, `buy now`, `checkout`,
  `check out`, `send money`, `transfer`, `place order`) are refused unless the
  host passes `--allow-payments` (a host application should never do so unattended).
- Typed and set text: at most 4096 characters and no control characters, so a
  line break can't act as Enter. Enter goes through `desktop_key`, where the
  host can tier it.
- Keys: the fixed chord allowlist, then the strict blocklist over the keys held
  at send time (ours plus physically held modifiers): any Windows key alone or
  in a chord, `ctrl+alt+*`, `alt+f4`, `alt+tab`, `alt+esc`, `alt+space`,
  `ctrl+esc`, `ctrl+shift+esc`, plus zmcp-computer's list. The key tables,
  held-key tracking, SendInput builders, typing cap and coordinate checks are
  shared with zmcp-computer (`src/computer/keys.zig`, `input.zig`, `guard.zig`).
- **Input tag:** every KEYBDINPUT and MOUSEINPUT that zmcp-desktop or
  zmcp-computer sends carries `dwExtraInfo = 0x4E415641` ("NAVA",
  `computer/input.zig`; the builders set it and `send` re-applies it). A host's
  auto-pause hook can treat only injected events with that tag as automation.
- User input: low-level keyboard and mouse hooks (installed on the first act;
  they only record a timestamp) count every event that is not tagged
  automation: hardware input, and input injected by any other program.
  `GetLastInputInfo` covers the time before the hooks start. An act waits
  until the user has been idle for `--idle-ms`; user input during an act
  stops it and pauses the session until the host signals `--resume-event`
  (the host's Continue button, and only that; a signal from before the pause is
  dropped, and there is no resume tool, so a model can't undo the user's
  takeover). Exception: UI
  Automation itself injects an untagged key (dwExtraInfo 0) to win foreground
  rights during some pattern calls (seen for Invoke on a UWP button and
  SetFocus on a background window), so injected events during our own UIA
  pattern call (plus 100 ms) count as ours. That in-flight window does not
  cover typing, keys or clicks (those are tagged), and it also swallows
  input from the on-screen keyboard or other assistive tools that inject
  untagged events inside it. A host's hook should use a matching window.
- Before each keystroke the focused element is re-read: a different runtime
  id, password flag or role stops the act ("focus moved"). Before a click,
  the window under the point (and, for invoke-by-click, the element there)
  is re-checked right before SendInput.
- Text also refuses U+2028/U+2029 and the bidi controls U+202A-202E and
  U+2066-2069.
- Typing is paced: one UTF-16 unit per SendInput, then a sync with the target's
  UI thread (two `WM_NULL` sends), then 30 ms. Win11 Notepad garbles faster
  Unicode keystrokes (it reads a queued `VK_PACKET` late and types the next
  one; zmcp-computer's bursts are garbled the same way). About 35 ms per
  character, so `set_value` is the fast path for long text. The act's time
  budget is the step timeout plus the pacing for its text.
- Limits: `--max-steps` acts per session, `--step-timeout-ms` per act,
  `--session-timeout-s` from the first act.
- `desktop_act focus` goes through UIA SetFocus. Windows' foreground lock can
  keep the window in the background (seen once when nothing had just
  been launched); `desktop_type`/`desktop_key`/`desktop_click` then refuse
  ("not the foreground window") rather than send input elsewhere.

**Live test** (`src/desktop/live/`): `driver.py` drives Notepad (on its own
file, checking before every Notepad act that the active tab is that file) and
Calculator in an interactive session on a test machine, never the user's own.
Run `appstate.py snap` before and `appstate.py restore` after it: Notepad
restores its previous session's tabs, and closing it rewrites that state.

## Library

`src/mcp.zig` is a tiny shared MCP server library: JSON-RPC line-delimited
framing, tool/resource registration, and request dispatch. Each tool's
`main.zig` stays small because the boilerplate is shared.

## License

MIT. See [LICENSE](LICENSE). Third-party notices for code, text and data that
zmcp reproduces or derives from are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); ship both files with any
binary you distribute.

## Trademarks and services

zmcp is an independent project. It is not affiliated with, endorsed by, or
sponsored by GitHub, Notion Labs, Figma, the Godot Engine project, the Blender
Foundation, Docker Inc., Microsoft (including Microsoft Learn), Vercel,
MiniMax, Upstash (Context7), Exa, Tavily, Firecrawl, Redis Ltd., Hugging Face,
Reddit, Y Combinator, the Kubernetes project, the OpenAI or Anthropic
organizations, or any other company named in this repository. All product
names, logos and brands are the property of their owners and are used here only
to identify the software or service a tool interoperates with. "MCP" refers to
the Model Context Protocol.

## Data sources and attribution

Several servers return data from third parties:

- Open-Meteo (weather forecasts, geocoding, air quality, marine, archive):
  CC BY 4.0, https://open-meteo.com. Results say `Data: Open-Meteo.com (CC BY 4.0)`.
  The free tier is for non-commercial use; commercial use needs a paid key.
- NOAA / National Weather Service (US forecasts, observations, alerts, river
  gauges): results say `Data: NOAA/NWS`.
- arXiv (`zmcp-arxiv`): results end with "Thank you to arXiv for use of its
  open access interoperability." Requests are throttled to arXiv's limit.
- tldr-pages (`zmcp-tldr`): CC BY 4.0, results end with `tldr-pages, CC BY 4.0`.
- Hacker News (Firebase and Algolia) and Reddit (`zmcp-social`, `zmcp-hn`):
  Reddit access is best effort and subject to Reddit's Data API terms.
- Microsoft Learn (`zmcp-mslearn`): content is CC BY 4.0 and is retrieved
  through Microsoft's hosted endpoint; source URLs are kept in results.
- crates.io, npm, PyPI, Hugging Face, Frankfurter (ECB rates), RainViewer
  (radar tiles), NIFC and other public APIs.
- API providers used with your own credentials: Brave Search, Tavily, Exa,
  Firecrawl, GitHub, Notion, Figma, Context7, MiniMax, and the
  OpenAI-compatible providers behind `zmcp-llm`.

You must follow each provider's terms of service and usage limits, and supply
your own API keys; zmcp does not bundle or share any. Content returned by these
services keeps its own license.
