//! zmcp-hippo - pure-Zig MCP server wrapping the `hippo` CLI (graph + temporal
//! vector memory store). It spawns the hippo binary with a plain argv (no
//! shell) and returns its stdout, the same way `hippo mcp` itself does, but with
//! a broader, better described tool set and strict argument validation.
//!
//! Configuration (environment):
//!   HIPPO_BIN  path to the hippo executable (default: `hippo` on PATH)
//!   HIPPO_DIR  default store directory, passed as `--dir` (a per-call `dir`
//!              argument overrides it; when neither is set hippo uses its own
//!              default). HIPPO_EMBED_URL and the HIPPO_*_MODEL variables are
//!              inherited by the child untouched.
//!
//! Tools (each maps onto one hippo subcommand):
//!   hippo_recall, hippo_index, hippo_store, hippo_thought, hippo_link,
//!   hippo_invalidate, hippo_walk, hippo_trace, hippo_status, hippo_stats,
//!   hippo_dump, hippo_reflect, hippo_consolidate, hippo_summary (put|get|list),
//!   and the read-only temporal filesystem-graph tools hippo_fs_query,
//!   hippo_fs_search, hippo_fs_neighbors, hippo_fs_history, hippo_fs_at_time,
//!   hippo_fs_state_at, hippo_fs_diff.
//!
//! Deliberately NOT exposed: init, migrate, config, capture / capture-drain,
//! daemon, serve, mcp, ingest*, sweep, alias, trust, cache-*, procedure*,
//! fs-upsert-node / fs-apply-edge-event, summary purge, `dump --all`, and every
//! flag that reaches a network endpoint or rewrites the store wholesale
//! (--base-url, --model, --auto-supersede, --detect-conflicts, ...).
//!
//! Argument safety: hippo's flag parser treats any token starting with `--` as
//! a flag name and `-` as "read stdin". So values are always passed as their own
//! argv entry directly after their flag; identifier-like values must not start
//! with '-'; free text (content, query, topic...) may start with a single '-'
//! (markdown bullets are common) but not with `--` and may not be exactly `-`;
//! numbers are range checked and never negative; enums are checked against
//! hippo's real kind lists; unknown argument names are rejected.

const std = @import("std");
const mcp = @import("mcp");

const Io = std.Io;

pub const server_version = "0.1.0";

/// Bytes of hippo stdout handed back to the model. Anything longer is cut on a
/// UTF-8 boundary with a note saying how to narrow the request.
const MAX_OUT_BYTES: usize = 256 * 1024;
/// Hard cap on what we will read from the child before killing it.
const HARD_STDOUT_CAP: usize = 16 * 1024 * 1024;
const HARD_STDERR_CAP: usize = 1024 * 1024;
/// Linux rejects a single argv string over 128 KiB; stay safely below it.
const MAX_ARG_BYTES: usize = 100 * 1024;

// ---------------------------------------------------------------------------
// hippo's real enum lists (src/store.zig: Kind.parse / EdgeKind.parse)
// ---------------------------------------------------------------------------

const memory_kinds = [_][]const u8{
    "observation", "fact",      "event",       "summary",     "entity",
    "decision",    "question",  "rationale",   "thought",     "procedure",
    "code_file",   "code_symbol", "tool_call",
};
const fs_kinds = [_][]const u8{ "fs_entry", "fs_file", "fs_dir", "fs_tag" };
const all_kinds = memory_kinds ++ fs_kinds;
const fs_node_kinds = [_][]const u8{ "fs_file", "fs_dir", "fs_tag" };

/// Edge kinds use hippo's hyphenated spelling.
const edge_kinds = [_][]const u8{
    "related",     "caused",      "is-a",       "refines",    "contradicts",
    "mentions",    "follows",     "answers",    "justifies",  "supports",
    "supersedes",  "derived-from", "similar",   "cooccurred", "next-step",
    "branches-to", "evaluates",   "synthesizes", "precedes",  "enables",
    "defines",     "references",  "imports",    "calls",      "contains",
    "tagged-with",
};

const node_statuses = [_][]const u8{ "open", "resolved", "deprecated" };
const index_sorts = [_][]const u8{ "topic", "recent", "oldest", "id" };
const age_froms = [_][]const u8{ "created", "last-access" };
const summary_actions = [_][]const u8{ "put", "get", "list" };

// ---------------------------------------------------------------------------
// Tool description tables
// ---------------------------------------------------------------------------

const Kind = union(enum) {
    /// Free text (content, query, topic, ...). Rejects NUL, an exact "-" (hippo
    /// reads stdin for it) and a leading "--" (hippo would parse it as a flag).
    text,
    /// Strict token (paths, silo names, durations, ids-as-words). Rejects empty,
    /// NUL and any leading '-'.
    value,
    /// Non-negative integer (node id).
    id,
    int: struct { min: i64, max: i64 },
    float: struct { min: f64, max: f64 },
    /// Boolean; emitted as a bare flag when true, omitted when false.
    flag,
    one_of: []const []const u8,
    /// Comma separated list, every entry must be in the list.
    csv_of: []const []const u8,
    /// "ID:EDGE-KIND" as accepted by `hippo store --link-to`.
    link_spec,
};

const Arg = struct {
    /// JSON argument name.
    key: []const u8,
    /// CLI flag including the dashes, or "" for a positional argument.
    flag: []const u8,
    kind: Kind,
    required: bool = false,
    desc: []const u8,
};

const Spec = struct {
    name: []const u8,
    /// Subcommand words placed right after the binary.
    cli: []const []const u8,
    description: []const u8,
    args: []const Arg,
    /// Extra cross-argument validation; returns an error message or null.
    check: ?*const fn (std.json.Value) ?[]const u8 = null,
    read_only: bool = false,
    destructive: bool = false,
};

const nn_int = Kind{ .int = .{ .min = 0, .max = 1_000_000_000 } };

fn nodeId(comptime key: []const u8, comptime flag: []const u8, comptime desc: []const u8) Arg {
    return .{ .key = key, .flag = flag, .kind = .id, .required = true, .desc = desc };
}

const tool_specs = [_]Spec{
    .{
        .name = "hippo_recall",
        .cli = &.{"recall"},
        .description = "Top-k semantic recall over the hippo memory store. Costs one embedding round-trip (~1s) against the embed server (HIPPO_EMBED_URL). Returns JSON {ok, results:[{id, kind, topic, content, score...}]}. Use hippo_index first when you only need to know WHAT exists. The retrieval channels hybrid (BM25+dense fusion), ppr (personalised PageRank over the edge graph) and spread (spreading activation) are opt-in and experimental; hyde and rerank additionally call an LLM. Filesystem-index nodes are excluded unless include_fs is set. Recall bumps last_access on hits unless no_touch is true - pass no_touch for exploratory reads.",
        .args = &.{
            .{ .key = "query", .flag = "--query", .kind = .text, .required = true, .desc = "Query text" },
            .{ .key = "k", .flag = "--k", .kind = .{ .int = .{ .min = 1, .max = 50 } }, .desc = "Top-k results (default 8)" },
            .{ .key = "hybrid", .flag = "--hybrid", .kind = .flag, .desc = "Fuse BM25 lexical and dense rankings via RRF" },
            .{ .key = "ppr", .flag = "--ppr", .kind = .flag, .desc = "Personalised PageRank over the graph from the top semantic seeds" },
            .{ .key = "ppr_seeds", .flag = "--ppr-seeds", .kind = .{ .int = .{ .min = 1, .max = 50 } }, .desc = "Number of PPR seed nodes (default 5)" },
            .{ .key = "spread", .flag = "--spread", .kind = .flag, .desc = "Spreading-activation expansion along edges" },
            .{ .key = "spread_hops", .flag = "--spread-hops", .kind = .{ .int = .{ .min = 1, .max = 10 } }, .desc = "Spreading-activation hops (default 3)" },
            .{ .key = "hyde", .flag = "--hyde", .kind = .flag, .desc = "HyDE query expansion (calls an LLM)" },
            .{ .key = "rerank", .flag = "--rerank", .kind = .flag, .desc = "LLM reranking of the top candidates (calls an LLM)" },
            .{ .key = "kind", .flag = "--kind", .kind = .{ .one_of = &all_kinds }, .desc = "Only nodes of this kind" },
            .{ .key = "exclude_kind", .flag = "--exclude-kind", .kind = .{ .csv_of = &all_kinds }, .desc = "Comma-separated kinds to drop, e.g. \"thought,tool_call\". Overrides the default filesystem exclusion." },
            .{ .key = "topic", .flag = "--topic", .kind = .text, .desc = "Exact topic match" },
            .{ .key = "topic_prefix", .flag = "--topic-prefix", .kind = .text, .desc = "Only topics starting with this string" },
            .{ .key = "silo", .flag = "--silo", .kind = .value, .desc = "Scope to one project silo plus the global pool (default: the git root basename of the server's cwd; \"all\" = no scoping)" },
            .{ .key = "fts", .flag = "--fts", .kind = .text, .desc = "Literal substring that must occur in topic or content" },
            .{ .key = "mtime_since", .flag = "--mtime-since", .kind = .value, .desc = "Only nodes created since: \"30d\", \"48h\", \"2026-08-01\" or unix seconds" },
            .{ .key = "age_from", .flag = "--age-from", .kind = .{ .one_of = &age_froms }, .desc = "Measure recency decay from creation time or last access" },
            .{ .key = "no_touch", .flag = "--no-touch", .kind = .flag, .desc = "Do not bump last_access/access_count on the hits (use for background or exploratory reads)" },
            .{ .key = "include_deprecated", .flag = "--include-deprecated", .kind = .flag, .desc = "Also return deprecated nodes" },
            .{ .key = "include_fs", .flag = "--include-fs", .kind = .flag, .desc = "Include filesystem-index nodes (almost never wanted)" },
        },
    },
    .{
        .name = "hippo_index",
        .read_only = true,
        .cli = &.{"index"},
        .description = "Table of contents of the memory store: one row per memory (id, kind, topic, created, snippet). No embedding call, no LLM, no network. Call this FIRST to see what exists, then hippo_dump a specific id or hippo_recall within a topic_prefix. Filesystem-index nodes are excluded by default.",
        .args = &.{
            .{ .key = "kind", .flag = "--kind", .kind = .{ .one_of = &all_kinds }, .desc = "Only nodes of this kind" },
            .{ .key = "topic_prefix", .flag = "--topic-prefix", .kind = .text, .desc = "Only topics starting with this string" },
            .{ .key = "silo", .flag = "--silo", .kind = .value, .desc = "Scope to one project silo plus the global pool (\"all\" = no scoping)" },
            .{ .key = "mtime_since", .flag = "--mtime-since", .kind = .value, .desc = "Only nodes created since: \"30d\", \"48h\", \"2026-08-01\" or unix seconds" },
            .{ .key = "sort", .flag = "--sort", .kind = .{ .one_of = &index_sorts }, .desc = "Sort order (default topic)" },
            .{ .key = "limit", .flag = "--limit", .kind = .{ .int = .{ .min = 1, .max = 2000 } }, .desc = "Max rows (default 200)" },
            .{ .key = "offset", .flag = "--offset", .kind = nn_int, .desc = "Rows to skip" },
            .{ .key = "snippet_chars", .flag = "--snippet-chars", .kind = .{ .int = .{ .min = 0, .max = 400 } }, .desc = "Snippet length per row (default 100)" },
            .{ .key = "max_bytes", .flag = "--max-bytes", .kind = .{ .int = .{ .min = 4096, .max = 1048576 } }, .desc = "Byte cap on the reply (default 131072)" },
            .{ .key = "include_deprecated", .flag = "--include-deprecated", .kind = .flag, .desc = "Include deprecated nodes" },
            .{ .key = "include_fs", .flag = "--include-fs", .kind = .flag, .desc = "Include filesystem-index nodes (almost never wanted)" },
        },
    },
    .{
        .name = "hippo_store",
        .cli = &.{"store"},
        .description = "Append a new memory node (embeds topic+content via the embed server, adds auto similarity/co-occurrence edges). hippo is append-only: there is no delete; withdraw a node later with hippo_status(to=deprecated). Returns JSON {ok, id, ...}. For kind=entity an existing canonical entity is returned instead of creating a duplicate unless force_new is set. supersede and singleton deprecate older nodes, so use them only when the new node truly replaces the old.",
        .args = &.{
            .{ .key = "topic", .flag = "--topic", .kind = .text, .required = true, .desc = "Short topic / title. Automatically silo-tagged by hippo." },
            .{ .key = "content", .flag = "--content", .kind = .text, .required = true, .desc = "Memory content (max ~100 KB per call)" },
            .{ .key = "kind", .flag = "--kind", .kind = .{ .one_of = &memory_kinds }, .desc = "Node kind (default observation)" },
            .{ .key = "importance", .flag = "--importance", .kind = .{ .float = .{ .min = 0, .max = 10 } }, .desc = "Importance 0..10 (default 1)" },
            .{ .key = "silo", .flag = "--silo", .kind = .value, .desc = "Project silo (a-z 0-9 - _ . only); default the git root basename of the server's cwd" },
            .{ .key = "agent_id", .flag = "--agent-id", .kind = .value, .desc = "Writer identity for hippo's trust gate (default \"default\")" },
            .{ .key = "link_to", .flag = "--link-to", .kind = .link_spec, .desc = "Also create an edge from the new node to an existing one: \"ID:EDGE-KIND\", e.g. \"12:supports\"" },
            .{ .key = "supersede", .flag = "--supersede", .kind = .id, .desc = "Node id this memory replaces: adds a supersedes edge and DEPRECATES that node" },
            .{ .key = "singleton", .flag = "--singleton", .kind = .flag, .desc = "Deprecate every older open node with the same kind and topic" },
            .{ .key = "force_new", .flag = "--force-new", .kind = .flag, .desc = "Skip entity de-duplication and always create a new node" },
            .{ .key = "no_auto_edges", .flag = "--no-auto-edges", .kind = .flag, .desc = "Do not create automatic similarity/co-occurrence edges" },
            .{ .key = "ttl_seconds", .flag = "--ttl-seconds", .kind = .{ .float = .{ .min = 0, .max = 3.15e9 } }, .desc = "Expire the node after this many seconds (0 = never)" },
            .{ .key = "sim_threshold", .flag = "--sim-threshold", .kind = .{ .float = .{ .min = 0, .max = 1 } }, .desc = "Cosine threshold for automatic similar edges (default 0.85)" },
            .{ .key = "sim_top_k", .flag = "--sim-top-k", .kind = .{ .int = .{ .min = 1, .max = 100 } }, .desc = "Max automatic similar edges (default 5)" },
        },
    },
    .{
        .name = "hippo_thought",
        .cli = &.{"thought"},
        .description = "Append a reasoning (graph-of-thoughts) node, optionally chained to a parent: parent creates a next-step edge (or branches-to with branch=true); eval_of makes this node an evaluates critique of another thought. ephemeral thoughts are scratch nodes. Use hippo_trace to read a chain back. Embeds the content via the embed server.",
        .args = &.{
            .{ .key = "content", .flag = "--content", .kind = .text, .required = true, .desc = "Thought text" },
            .{ .key = "topic", .flag = "--topic", .kind = .text, .desc = "Topic (default \"thought\")" },
            .{ .key = "parent", .flag = "--parent", .kind = .id, .desc = "Parent thought node id" },
            .{ .key = "branch", .flag = "--branch", .kind = .flag, .desc = "Link to the parent as an alternative branch (branches-to) instead of next-step" },
            .{ .key = "eval_of", .flag = "--eval-of", .kind = .id, .desc = "Node id this thought critiques (evaluates edge)" },
            .{ .key = "ephemeral", .flag = "--ephemeral", .kind = .flag, .desc = "Mark as a scratch thought" },
            .{ .key = "importance", .flag = "--importance", .kind = .{ .float = .{ .min = 0, .max = 10 } }, .desc = "Importance 0..10 (default 1)" },
        },
    },
    .{
        .name = "hippo_link",
        .cli = &.{"link"},
        .description = "Create a typed, directed edge between two existing nodes (from -[kind]-> to). Idempotent: an identical live edge is reported as already_exists. Edge kinds: related, caused, is-a, refines, contradicts, mentions, follows, answers, justifies, supports, supersedes, derived-from, similar, cooccurred, next-step, branches-to, evaluates, synthesizes, precedes, enables, defines, references, imports, calls, contains, tagged-with.",
        .args = &.{
            nodeId("from", "--from", "Source node id"),
            nodeId("to", "--to", "Target node id"),
            .{ .key = "kind", .flag = "--kind", .kind = .{ .one_of = &edge_kinds }, .required = true, .desc = "Edge kind" },
            .{ .key = "weight", .flag = "--weight", .kind = .{ .float = .{ .min = 0, .max = 1e6 } }, .desc = "Edge weight (default 1.0)" },
            .{ .key = "decay", .flag = "--decay", .kind = .{ .float = .{ .min = 0, .max = 1e6 } }, .desc = "Edge decay rate (default 0)" },
        },
    },
    .{
        .name = "hippo_invalidate",
        .cli = &.{"invalidate"},
        .description = "Temporally invalidate the live edge(s) from one node to another (sets valid_until to now; the edge stays in history and reappears with include_invalid in hippo_walk). With kind, only edges of that kind; without it, ALL live edges between the pair. Returns {ok, affected}. To retract a node itself use hippo_status.",
        .args = &.{
            nodeId("from", "--from", "Source node id"),
            nodeId("to", "--to", "Target node id"),
            .{ .key = "kind", .flag = "--kind", .kind = .{ .one_of = &edge_kinds }, .desc = "Only invalidate edges of this kind (default: all kinds)" },
        },
    },
    .{
        .name = "hippo_walk",
        .read_only = true,
        .cli = &.{"walk"},
        .description = "Breadth-first walk of the memory graph from a node, following edges in both directions. Returns {ok, walk:[{id, depth, score, via_kind, kind, topic}]}. Restrict edge kinds with kind (comma-separated) and reveal invalidated edges with include_invalid.",
        .args = &.{
            nodeId("from", "--from", "Start node id"),
            .{ .key = "depth", .flag = "--depth", .kind = .{ .int = .{ .min = 1, .max = 8 } }, .desc = "Max hops (default 2)" },
            .{ .key = "kind", .flag = "--kind", .kind = .{ .csv_of = &edge_kinds }, .desc = "Comma-separated edge kinds to follow, e.g. \"caused,supports\" (default: all)" },
            .{ .key = "include_invalid", .flag = "--include-invalid", .kind = .flag, .desc = "Also follow temporally invalidated edges" },
        },
    },
    .{
        .name = "hippo_trace",
        .read_only = true,
        .cli = &.{"trace"},
        .description = "Print a reasoning chain (graph-of-thoughts) rooted at a thought node: the thought, its next-step/branches-to descendants and evaluates critiques, as text.",
        .args = &.{nodeId("root", "--root", "Root thought node id")},
    },
    .{
        .name = "hippo_status",
        .cli = &.{"status"},
        .description = "Set a node's lifecycle status. deprecated hides it from recall (this is how a stored memory is withdrawn - hippo has no delete), resolved closes a question, open reinstates it. Find the id with hippo_index or hippo_recall first.",
        .args = &.{
            nodeId("id", "--id", "Node id"),
            .{ .key = "to", .flag = "--to", .kind = .{ .one_of = &node_statuses }, .required = true, .desc = "New status" },
        },
    },
    .{
        .name = "hippo_stats",
        .read_only = true,
        .cli = &.{"stats"},
        .description = "Store statistics as JSON: {ok, dir, nodes, edges, text_bytes, dim}. Cheap; no embedding call. Also a good way to check that the configured store directory is right.",
        .args = &.{},
    },
    .{
        .name = "hippo_dump",
        .read_only = true,
        .cli = &.{"dump"},
        .description = "Read full node records (topic, content, kind, status, edges). With id: that single node. Without id: a page of nodes (filesystem-index nodes excluded unless include_fs) bounded by limit and max_bytes; page with offset. For a table of contents use hippo_index instead.",
        .args = &.{
            .{ .key = "id", .flag = "--id", .kind = .id, .desc = "Dump exactly this node" },
            .{ .key = "limit", .flag = "--limit", .kind = .{ .int = .{ .min = 1, .max = 500 } }, .desc = "Page size (default 50)" },
            .{ .key = "offset", .flag = "--offset", .kind = nn_int, .desc = "Nodes to skip" },
            .{ .key = "max_bytes", .flag = "--max-bytes", .kind = .{ .int = .{ .min = 4096, .max = 1048576 } }, .desc = "Byte cap on the page (default 262144)" },
            .{ .key = "include_fs", .flag = "--include-fs", .kind = .flag, .desc = "Include filesystem-index nodes" },
        },
    },
    .{
        .name = "hippo_reflect",
        .cli = &.{"reflect"},
        .description = "Reflection step: collect the most recent not-yet-reflected observation/event nodes for you to summarise. Returns candidate nodes with their content. Unless dry_run is true the returned nodes are MARKED reflected (so they will not be offered again). With threshold > 0 nothing is returned until the summed importance of the candidates reaches it ({ready:false} otherwise). Store the resulting summary yourself with hippo_store(kind=summary) and hippo_link(derived-from).",
        .args = &.{
            .{ .key = "limit", .flag = "--limit", .kind = .{ .int = .{ .min = 1, .max = 200 } }, .desc = "Max candidates (default 16)" },
            .{ .key = "threshold", .flag = "--threshold", .kind = .{ .float = .{ .min = 0, .max = 100000 } }, .desc = "Minimum summed importance before reflecting (default 0 = always ready)" },
            .{ .key = "dry_run", .flag = "--dry-run", .kind = .flag, .desc = "Return candidates without marking them reflected" },
        },
    },
    .{
        .name = "hippo_consolidate",
        .cli = &.{"consolidate"},
        .description = "Consolidation: cluster reflected, not-yet-consolidated observations/facts/events/decisions by embedding similarity and write an LLM-generated summary node per cluster (needs the embed server and an LLM endpoint; can take a while and WRITES nodes). Run with dry_run=true first to see what would be consolidated.",
        .args = &.{
            .{ .key = "dry_run", .flag = "--dry-run", .kind = .flag, .desc = "Report clusters without writing anything" },
            .{ .key = "min_cluster", .flag = "--min-cluster", .kind = .{ .int = .{ .min = 2, .max = 100 } }, .desc = "Minimum cluster size (default 4)" },
            .{ .key = "target_cluster", .flag = "--target-cluster", .kind = .{ .int = .{ .min = 2, .max = 100 } }, .desc = "Target cluster size (default 6)" },
            .{ .key = "threshold", .flag = "--threshold", .kind = .{ .float = .{ .min = 0, .max = 1 } }, .desc = "Cosine threshold for clustering (default 0.65)" },
            .{ .key = "min_importance", .flag = "--min-importance", .kind = .{ .float = .{ .min = 0, .max = 10 } }, .desc = "Ignore nodes below this importance (default 1)" },
        },
    },
    .{
        .name = "hippo_summary",
        .cli = &.{"summary"},
        .description = "Per-symbol code summaries kept in the store. action=put stores (file, symbol, content); action=get returns the summary for (file, symbol) as {found, summary}; action=list lists stored summaries. (Purging is not exposed.)",
        .args = &.{
            .{ .key = "action", .flag = "", .kind = .{ .one_of = &summary_actions }, .required = true, .desc = "put | get | list" },
            .{ .key = "file", .flag = "--file", .kind = .value, .desc = "Source file path (required for put and get)" },
            .{ .key = "symbol", .flag = "--symbol", .kind = .value, .desc = "Symbol name (required for put and get)" },
            .{ .key = "content", .flag = "--content", .kind = .text, .desc = "Summary text (required for put)" },
            .{ .key = "limit", .flag = "--limit", .kind = .{ .int = .{ .min = 1, .max = 1000 } }, .desc = "Max entries for list (default 100)" },
        },
        .check = checkSummary,
    },
    .{
        .name = "hippo_fs_query",
        .read_only = true,
        .cli = &.{"fs-query"},
        .description = "Read-only query of the indexed filesystem entries (fs_entry nodes from `hippo ingest-fs`): filter by name substring, extension, recency and size. Returns a JSON array of {path, size, mtime, ext}, newest first.",
        .args = &.{
            .{ .key = "name_like", .flag = "--name-like", .kind = .value, .desc = "Case-insensitive substring of the file name" },
            .{ .key = "extension", .flag = "--extension", .kind = .value, .desc = "File extension, e.g. \"zig\"" },
            .{ .key = "changed_within_days", .flag = "--changed-within-days", .kind = .{ .int = .{ .min = 0, .max = 36500 } }, .desc = "Only files modified within this many days" },
            .{ .key = "min_size_bytes", .flag = "--min-size-bytes", .kind = nn_int, .desc = "Only files at least this large" },
            .{ .key = "max_results", .flag = "--max-results", .kind = .{ .int = .{ .min = 1, .max = 5000 } }, .desc = "Result cap (default 100)" },
        },
    },
    .{
        .name = "hippo_fs_search",
        .read_only = true,
        .cli = &.{"fs-search"},
        .description = "Read-only search of the silt filesystem graph (fs_file / fs_dir / fs_tag nodes) by topic (path or tag name) substring. Returns {ok, count, hits:[{id, kind, path}]}.",
        .args = &.{
            .{ .key = "query", .flag = "--query", .kind = .text, .required = true, .desc = "Substring to match against paths / tag names" },
            .{ .key = "kind", .flag = "--kind", .kind = .{ .one_of = &fs_node_kinds }, .desc = "Restrict to one node kind" },
            .{ .key = "max_results", .flag = "--max-results", .kind = .{ .int = .{ .min = 1, .max = 1000 } }, .desc = "Result cap (default 50)" },
        },
    },
    .{
        .name = "hippo_fs_neighbors",
        .read_only = true,
        .cli = &.{"fs-neighbors"},
        .description = "Read-only: nodes reachable from a filesystem-graph node within N hops. Returns {ok, from, depth, count, hits:[{id, depth, score, via}]}.",
        .args = &.{
            nodeId("id", "--id", "Start node id"),
            .{ .key = "depth", .flag = "--depth", .kind = .{ .int = .{ .min = 1, .max = 8 } }, .desc = "Max hops (default 2)" },
        },
    },
    .{
        .name = "hippo_fs_history",
        .read_only = true,
        .cli = &.{"fs-history"},
        .description = "Read-only: the full temporal event history (edge added/removed events) of one filesystem-graph node, oldest first. Returns {ok, id, count, events:[...]}.",
        .args = &.{nodeId("id", "--id", "Node id")},
    },
    .{
        .name = "hippo_fs_at_time",
        .read_only = true,
        .cli = &.{"fs-at-time"},
        .description = "Read-only temporal query: filesystem-graph events that had occurred up to time t (milliseconds since the unix epoch). Returns {ok, t_ms, count, events:[...]}. Use hippo_fs_state_at for the resulting live edge set instead.",
        .args = &.{
            .{ .key = "t_ms", .flag = "--t-ms", .kind = .{ .int = .{ .min = 0, .max = 9_000_000_000_000_000 } }, .required = true, .desc = "Timestamp, unix epoch milliseconds" },
        },
    },
    .{
        .name = "hippo_fs_state_at",
        .read_only = true,
        .cli = &.{"fs-state-at"},
        .description = "Read-only temporal query: the set of filesystem-graph edges that were LIVE (added and not yet removed) at time t. Returns {ok, t_ms, live_count, live:[...]}.",
        .args = &.{
            .{ .key = "t_ms", .flag = "--t-ms", .kind = .{ .int = .{ .min = 0, .max = 9_000_000_000_000_000 } }, .required = true, .desc = "Timestamp, unix epoch milliseconds" },
        },
    },
    .{
        .name = "hippo_fs_diff",
        .read_only = true,
        .cli = &.{"fs-diff"},
        .description = "Read-only temporal diff of the filesystem graph between two instants: which edges were added and removed between t1 and t2. Returns {ok, t1_ms, t2_ms, added_count, removed_count, added:[...], removed:[...]}.",
        .args = &.{
            .{ .key = "t1_ms", .flag = "--t1-ms", .kind = .{ .int = .{ .min = 0, .max = 9_000_000_000_000_000 } }, .required = true, .desc = "Start, unix epoch milliseconds" },
            .{ .key = "t2_ms", .flag = "--t2-ms", .kind = .{ .int = .{ .min = 0, .max = 9_000_000_000_000_000 } }, .required = true, .desc = "End, unix epoch milliseconds" },
        },
    },
};

fn checkSummary(args: std.json.Value) ?[]const u8 {
    const action = optStr(args, "action") orelse return null;
    const need_fs = std.mem.eql(u8, action, "put") or std.mem.eql(u8, action, "get");
    if (need_fs) {
        if (optStr(args, "file") == null) return "action=put/get requires 'file'";
        if (optStr(args, "symbol") == null) return "action=put/get requires 'symbol'";
    }
    if (std.mem.eql(u8, action, "put") and optStr(args, "content") == null) return "action=put requires 'content'";
    return null;
}

fn optStr(args: std.json.Value, key: []const u8) ?[]const u8 {
    const v = optVal(args, key) orelse return null;
    return if (v == .string) v.string else null;
}

/// Present, non-null argument value.
fn optVal(args: std.json.Value, key: []const u8) ?std.json.Value {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return if (v == .null) null else v;
}

// ---------------------------------------------------------------------------
// Schema generation (from the same tables that drive validation)
// ---------------------------------------------------------------------------

fn writeJsonString(w: *Io.Writer, s: []const u8) !void {
    try std.json.Stringify.value(s, .{}, w);
}

fn writeEnum(w: *Io.Writer, items: []const []const u8) !void {
    try w.writeAll("[");
    for (items, 0..) |it, i| {
        if (i > 0) try w.writeAll(",");
        try writeJsonString(w, it);
    }
    try w.writeAll("]");
}

pub fn buildSchema(alloc: std.mem.Allocator, spec: *const Spec) ![]u8 {
    var out: Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"type\":\"object\",\"properties\":{");
    for (spec.args) |a| {
        try writeJsonString(w, a.key);
        try w.writeAll(":");
        try writeProp(alloc, w, a);
        try w.writeAll(",");
    }
    try writeJsonString(w, "dir");
    try w.writeAll(":{\"type\":\"string\",\"description\":\"Store directory (--dir). Defaults to $HIPPO_DIR of the server, then hippo's own default.\"}");
    try w.writeAll("},\"required\":[");
    var first = true;
    for (spec.args) |a| {
        if (!a.required) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try writeJsonString(w, a.key);
    }
    try w.writeAll("],\"additionalProperties\":false}");
    return out.toOwnedSlice();
}

fn writeProp(alloc: std.mem.Allocator, w: *Io.Writer, a: Arg) !void {
    try w.writeAll("{");
    switch (a.kind) {
        .text, .value, .link_spec => try w.writeAll("\"type\":\"string\""),
        .id => try w.writeAll("\"type\":\"integer\",\"minimum\":0"),
        .int => |r| try w.print("\"type\":\"integer\",\"minimum\":{d},\"maximum\":{d}", .{ r.min, r.max }),
        .float => |r| try w.print("\"type\":\"number\",\"minimum\":{d},\"maximum\":{d}", .{ r.min, r.max }),
        .flag => try w.writeAll("\"type\":\"boolean\""),
        .one_of => |items| {
            try w.writeAll("\"type\":\"string\",\"enum\":");
            try writeEnum(w, items);
        },
        .csv_of => try w.writeAll("\"type\":\"string\""),
    }
    var desc: []const u8 = a.desc;
    if (a.kind == .csv_of) {
        const joined = try std.mem.join(alloc, ", ", a.kind.csv_of);
        desc = try std.fmt.allocPrint(alloc, "{s} Allowed entries: {s}.", .{ a.desc, joined });
    }
    try w.writeAll(",\"description\":");
    try writeJsonString(w, desc);
    try w.writeAll("}");
}

// ---------------------------------------------------------------------------
// Argument validation and argv construction (pure; unit tested)
// ---------------------------------------------------------------------------

pub const Built = union(enum) {
    argv: []const []const u8,
    err: []const u8,
};

fn errf(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !Built {
    return .{ .err = try std.fmt.allocPrint(alloc, fmt, args) };
}

fn inList(s: []const u8, list: []const []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn jsonInt(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (@floor(f) == f and @abs(f) < 9.0e15) @as(i64, @intFromFloat(f)) else null,
        else => null,
    };
}

fn jsonFloat(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @as(f64, @floatFromInt(i)),
        .float => |f| f,
        else => null,
    };
}

/// Validate one string value for `kind`; returns an error description or null.
fn checkString(kind: Kind, s: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, s, 0) != null) return "contains a NUL byte";
    if (s.len > MAX_ARG_BYTES) return "is too long for a command-line argument (limit ~100 KB); split it into smaller calls";
    switch (kind) {
        .text => {
            if (std.mem.eql(u8, s, "-")) return "must not be exactly '-' (hippo would read stdin)";
            if (std.mem.startsWith(u8, s, "--")) return "must not start with '--' (hippo would parse it as a flag); rephrase or add a leading word";
        },
        .value => {
            if (s.len == 0) return "must not be empty";
            if (s[0] == '-') return "must not start with '-'";
        },
        else => {},
    }
    return null;
}

/// Build the full argv for `spec` from JSON `args`. Every string is allocated
/// from `alloc`. Validation failures are returned as `.err` (a message for the
/// model), never as Zig errors.
pub fn buildArgv(
    alloc: std.mem.Allocator,
    bin: []const u8,
    default_dir: ?[]const u8,
    spec: *const Spec,
    args: std.json.Value,
) !Built {
    if (args != .object and args != .null) return errf(alloc, "arguments must be a JSON object", .{});

    // Reject unknown names: a typo or an attempt to reach an unadvertised flag.
    if (args == .object) {
        var it = args.object.iterator();
        while (it.next()) |e| {
            const k = e.key_ptr.*;
            if (std.mem.eql(u8, k, "dir")) continue;
            var known = false;
            for (spec.args) |a| {
                if (std.mem.eql(u8, a.key, k)) {
                    known = true;
                    break;
                }
            }
            if (!known) return errf(alloc, "{s}: unknown argument '{s}' (see the tool's inputSchema)", .{ spec.name, k });
        }
    }

    for (spec.args) |a| {
        if (a.required and optVal(args, a.key) == null) {
            return errf(alloc, "{s}: missing required argument '{s}'", .{ spec.name, a.key });
        }
    }

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(alloc, bin);
    try argv.appendSlice(alloc, spec.cli);

    // Positional arguments first (only `hippo summary <action>` has one).
    for (spec.args) |a| {
        if (a.flag.len != 0) continue;
        const v = optVal(args, a.key) orelse continue;
        if (try validateInto(alloc, spec, a, v, &argv)) |msg| return .{ .err = msg };
    }

    // --dir: per-call value wins over the server default.
    var dir: ?[]const u8 = default_dir;
    if (optVal(args, "dir")) |dv| {
        if (dv != .string) return errf(alloc, "{s}: 'dir' must be a string", .{spec.name});
        if (checkString(.value, dv.string)) |why| return errf(alloc, "{s}: 'dir' {s}", .{ spec.name, why });
        dir = dv.string;
    }
    if (dir) |d| {
        try argv.append(alloc, "--dir");
        try argv.append(alloc, d);
    }

    for (spec.args) |a| {
        if (a.flag.len == 0) continue;
        const v = optVal(args, a.key) orelse continue;
        if (try validateInto(alloc, spec, a, v, &argv)) |msg| return .{ .err = msg };
    }

    if (spec.check) |chk| {
        if (chk(args)) |msg| return errf(alloc, "{s}: {s}", .{ spec.name, msg });
    }
    return .{ .argv = try argv.toOwnedSlice(alloc) };
}

/// Validate `v` against `a` and append `flag value` (or a bare flag / positional)
/// to argv. Returns an error message on failure.
fn validateInto(
    alloc: std.mem.Allocator,
    spec: *const Spec,
    a: Arg,
    v: std.json.Value,
    argv: *std.ArrayList([]const u8),
) !?[]const u8 {
    var value: []const u8 = undefined;
    switch (a.kind) {
        .flag => {
            if (v != .bool) return try std.fmt.allocPrint(alloc, "{s}: '{s}' must be a boolean", .{ spec.name, a.key });
            if (v.bool) try argv.append(alloc, a.flag);
            return null;
        },
        .text, .value => {
            if (v != .string) return try std.fmt.allocPrint(alloc, "{s}: '{s}' must be a string", .{ spec.name, a.key });
            if (checkString(a.kind, v.string)) |why| return try std.fmt.allocPrint(alloc, "{s}: '{s}' {s}", .{ spec.name, a.key, why });
            value = v.string;
        },
        .id => {
            const i = jsonInt(v) orelse return try std.fmt.allocPrint(alloc, "{s}: '{s}' must be a non-negative integer", .{ spec.name, a.key });
            if (i < 0 or i > 1_000_000_000_000) return try std.fmt.allocPrint(alloc, "{s}: '{s}' must be a non-negative node id", .{ spec.name, a.key });
            value = try std.fmt.allocPrint(alloc, "{d}", .{i});
        },
        .int => |r| {
            const i = jsonInt(v) orelse return try std.fmt.allocPrint(alloc, "{s}: '{s}' must be an integer", .{ spec.name, a.key });
            if (i < r.min or i > r.max) return try std.fmt.allocPrint(alloc, "{s}: '{s}' must be between {d} and {d}", .{ spec.name, a.key, r.min, r.max });
            value = try std.fmt.allocPrint(alloc, "{d}", .{i});
        },
        .float => |r| {
            const f = jsonFloat(v) orelse return try std.fmt.allocPrint(alloc, "{s}: '{s}' must be a number", .{ spec.name, a.key });
            if (!(f >= r.min and f <= r.max)) return try std.fmt.allocPrint(alloc, "{s}: '{s}' must be between {d} and {d}", .{ spec.name, a.key, r.min, r.max });
            value = try std.fmt.allocPrint(alloc, "{d}", .{f});
        },
        .one_of => |items| {
            if (v != .string) return try std.fmt.allocPrint(alloc, "{s}: '{s}' must be a string", .{ spec.name, a.key });
            if (!inList(v.string, items)) {
                const joined = try std.mem.join(alloc, ", ", items);
                return try std.fmt.allocPrint(alloc, "{s}: invalid {s} '{s}'; allowed: {s}", .{ spec.name, a.key, v.string, joined });
            }
            value = v.string;
        },
        .csv_of => |items| {
            if (v != .string) return try std.fmt.allocPrint(alloc, "{s}: '{s}' must be a comma-separated string", .{ spec.name, a.key });
            if (v.string.len == 0) return try std.fmt.allocPrint(alloc, "{s}: '{s}' must not be empty", .{ spec.name, a.key });
            var it = std.mem.splitScalar(u8, v.string, ',');
            while (it.next()) |part| {
                if (!inList(part, items)) {
                    const joined = try std.mem.join(alloc, ", ", items);
                    return try std.fmt.allocPrint(alloc, "{s}: invalid entry '{s}' in {s}; allowed: {s}", .{ spec.name, part, a.key, joined });
                }
            }
            value = v.string;
        },
        .link_spec => {
            if (v != .string) return try std.fmt.allocPrint(alloc, "{s}: '{s}' must be a string like \"12:supports\"", .{ spec.name, a.key });
            const colon = std.mem.indexOfScalar(u8, v.string, ':') orelse
                return try std.fmt.allocPrint(alloc, "{s}: '{s}' must look like ID:EDGE-KIND, e.g. \"12:supports\"", .{ spec.name, a.key });
            const id_part = v.string[0..colon];
            const kind_part = v.string[colon + 1 ..];
            if (id_part.len == 0 or id_part.len > 12) return try std.fmt.allocPrint(alloc, "{s}: '{s}' has a bad node id", .{ spec.name, a.key });
            for (id_part) |c| if (c < '0' or c > '9') return try std.fmt.allocPrint(alloc, "{s}: '{s}' has a bad node id", .{ spec.name, a.key });
            if (!inList(kind_part, &edge_kinds)) {
                const joined = try std.mem.join(alloc, ", ", &edge_kinds);
                return try std.fmt.allocPrint(alloc, "{s}: invalid edge kind '{s}' in {s}; allowed: {s}", .{ spec.name, kind_part, a.key, joined });
            }
            value = v.string;
        },
    }
    if (a.flag.len != 0) try argv.append(alloc, a.flag);
    try argv.append(alloc, value);
    return null;
}

// ---------------------------------------------------------------------------
// Process execution seam (injectable for offline unit tests)
// ---------------------------------------------------------------------------

pub const ExecResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    /// The child produced more than the hard read cap and was killed.
    cut: bool = false,
};

pub const ExecFn = *const fn (
    alloc: std.mem.Allocator,
    io: Io,
    argv: []const []const u8,
) anyerror!ExecResult;

var exec_fn: ExecFn = execReal;

/// Set from the environment in main().
var cfg_bin: []const u8 = "hippo";
var cfg_dir: ?[]const u8 = null;

fn execReal(alloc: std.mem.Allocator, io: Io, argv: []const []const u8) !ExecResult {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.ExecutableNotFound,
        else => return err,
    };
    defer child.kill(io);

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(alloc, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    var cut = false;
    while (multi_reader.fill(64, .none)) |_| {
        if (stdout_reader.buffered().len > HARD_STDOUT_CAP or stderr_reader.buffered().len > HARD_STDERR_CAP) {
            cut = true;
            break;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }

    if (cut) {
        // The deferred kill reaps the child.
        return .{
            .term = .{ .exited = 0 },
            .stdout = try multi_reader.toOwnedSlice(0),
            .stderr = try multi_reader.toOwnedSlice(1),
            .cut = true,
        };
    }

    try multi_reader.checkAnyError();
    const term = try child.wait(io);
    return .{
        .term = term,
        .stdout = try multi_reader.toOwnedSlice(0),
        .stderr = try multi_reader.toOwnedSlice(1),
    };
}

// ---------------------------------------------------------------------------
// Tool execution
// ---------------------------------------------------------------------------

fn toolError(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !mcp.ToolResult {
    return .{ .text = try std.fmt.allocPrint(alloc, fmt, args), .is_error = true };
}

/// Cut `s` to at most `max` bytes on a UTF-8 boundary.
fn utf8Prefix(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var cut = max;
    while (cut > 0 and (s[cut] & 0xC0) == 0x80) cut -= 1;
    return s[0..cut];
}

pub fn runTool(alloc: std.mem.Allocator, io: Io, spec: *const Spec, args: std.json.Value) !mcp.ToolResult {
    const built = try buildArgv(alloc, cfg_bin, cfg_dir, spec, args);
    const argv = switch (built) {
        .err => |m| return .{ .text = m, .is_error = true },
        .argv => |a| a,
    };

    const res = exec_fn(alloc, io, argv) catch |err| switch (err) {
        error.ExecutableNotFound, error.AccessDenied, error.FileNotFound => return toolError(
            alloc,
            "hippo binary not found or not executable: '{s}' ({s}). Install hippo and put it on PATH, or set HIPPO_BIN to its full path.",
            .{ argv[0], @errorName(err) },
        ),
        else => return toolError(alloc, "failed to run hippo ({s}): {s}", .{ argv[0], @errorName(err) }),
    };

    const out = std.mem.trim(u8, res.stdout, " \t\r\n");
    const errtxt = std.mem.trim(u8, res.stderr, " \t\r\n");

    const ok = switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        const code_desc: []const u8 = switch (res.term) {
            .exited => |code| try std.fmt.allocPrint(alloc, "exit {d}", .{code}),
            else => "terminated abnormally",
        };
        return toolError(alloc, "hippo {s} failed ({s}).\nstderr: {s}\nstdout: {s}", .{
            spec.cli[0],
            code_desc,
            utf8Prefix(errtxt, 16 * 1024),
            utf8Prefix(out, 16 * 1024),
        });
    }

    var text: []const u8 = out;
    if (out.len > MAX_OUT_BYTES or res.cut) {
        const shown = utf8Prefix(out, MAX_OUT_BYTES);
        text = try std.fmt.allocPrint(
            alloc,
            "{s}\n\n[zmcp-hippo: output truncated - {d} of {d}{s} bytes shown, so it may no longer be valid JSON. Narrow the request (limit, offset, k, max_bytes, topic_prefix, kind).]",
            .{ shown, shown.len, out.len, if (res.cut) "+" else "" },
        );
    } else if (out.len == 0) {
        text = if (errtxt.len > 0) errtxt else "(hippo produced no output)";
    }
    return .{ .text = text };
}

fn makeHandler(comptime i: usize) mcp.ToolHandler {
    return struct {
        fn handle(alloc: std.mem.Allocator, io: Io, args: std.json.Value) anyerror!mcp.ToolResult {
            return runTool(alloc, io, &tool_specs[i], args);
        }
    }.handle;
}

const handlers = blk: {
    var hs: [tool_specs.len]mcp.ToolHandler = undefined;
    for (0..tool_specs.len) |i| hs[i] = makeHandler(i);
    break :blk hs;
};

pub fn buildToolDefs(alloc: std.mem.Allocator) ![]mcp.ToolDef {
    const defs = try alloc.alloc(mcp.ToolDef, tool_specs.len);
    for (&tool_specs, 0..) |*s, i| {
        defs[i] = .{
            .name = s.name,
            .description = s.description,
            .input_schema_json = try buildSchema(alloc, s),
            .handler = handlers[i],
            .read_only = s.read_only,
            .destructive = s.destructive,
        };
    }
    return defs;
}

pub fn main(init: std.process.Init) !void {
    // Process-lifetime configuration and schemas live in the permanent arena;
    // per-request work uses the reclaiming gpa inside mcp.run.
    const perm = init.arena.allocator();
    const gpa = init.gpa;
    if (init.environ_map.get("HIPPO_BIN")) |v| {
        if (v.len > 0) cfg_bin = try perm.dupe(u8, v);
    }
    if (init.environ_map.get("HIPPO_DIR")) |v| {
        if (v.len > 0) cfg_dir = try perm.dupe(u8, v);
    }
    const defs = try buildToolDefs(perm);
    try mcp.run(gpa, init.io, .{ .name = "zmcp-hippo", .version = server_version }, defs);
}

// ---------------------------------------------------------------------------
// Tests (none of these need hippo installed, except the opt-in e2e test)
// ---------------------------------------------------------------------------

const TestCtx = struct {
    arena_state: std.heap.ArenaAllocator,
    arena: std.mem.Allocator,

    /// Initialise IN PLACE (`arena` points into `arena_state`).
    fn init(ctx: *TestCtx) void {
        ctx.arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        ctx.arena = ctx.arena_state.allocator();
        exec_fn = fakeExec;
        cfg_bin = "hippo";
        cfg_dir = null;
        fake_calls = 0;
        fake_argv = &.{};
        fake_result = .{ .term = .{ .exited = 0 }, .stdout = @constCast("{\"ok\":true}\n"), .stderr = @constCast("") };
        fake_error = null;
    }

    fn deinit(ctx: *TestCtx) void {
        exec_fn = execReal;
        cfg_bin = "hippo";
        cfg_dir = null;
        ctx.arena_state.deinit();
    }

    fn json(ctx: *TestCtx, text: []const u8) !std.json.Value {
        return (try std.json.parseFromSlice(std.json.Value, ctx.arena, text, .{})).value;
    }
};

var fake_calls: usize = 0;
var fake_argv: []const []const u8 = &.{};
var fake_result: ExecResult = undefined;
var fake_error: ?anyerror = null;

fn fakeExec(alloc: std.mem.Allocator, io: Io, argv: []const []const u8) !ExecResult {
    _ = alloc;
    _ = io;
    fake_calls += 1;
    fake_argv = argv;
    if (fake_error) |e| return e;
    return fake_result;
}

fn specByName(name: []const u8) *const Spec {
    for (&tool_specs) |*s| if (std.mem.eql(u8, s.name, name)) return s;
    @panic("no such tool");
}

fn expectBuilt(ctx: *TestCtx, tool: []const u8, json: []const u8, want: []const []const u8) !void {
    const built = try buildArgv(ctx.arena, cfg_bin, cfg_dir, specByName(tool), try ctx.json(json));
    switch (built) {
        .err => |m| {
            std.debug.print("unexpected error: {s}\n", .{m});
            return error.TestUnexpectedError;
        },
        .argv => |got| {
            try std.testing.expectEqual(want.len, got.len);
            for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
        },
    }
}

fn expectRejected(ctx: *TestCtx, tool: []const u8, json: []const u8, needle: []const u8) !void {
    const built = try buildArgv(ctx.arena, cfg_bin, cfg_dir, specByName(tool), try ctx.json(json));
    switch (built) {
        .argv => |got| {
            std.debug.print("expected rejection of {s}, got argv:", .{json});
            for (got) |g| std.debug.print(" [{s}]", .{g});
            std.debug.print("\n", .{});
            return error.TestExpectedRejection;
        },
        .err => |m| {
            if (std.mem.indexOf(u8, m, needle) == null) {
                std.debug.print("error '{s}' does not contain '{s}'\n", .{ m, needle });
                return error.TestWrongError;
            }
        },
    }
}

test "tool table: unique names, hippo_ prefix, no forbidden subcommands" {
    const forbidden = [_][]const u8{ "init", "migrate", "config", "capture", "capture-drain", "daemon", "serve", "mcp", "ingest", "sweep", "alias", "trust", "fs-upsert-node", "fs-apply-edge-event" };
    for (tool_specs, 0..) |s, i| {
        try std.testing.expect(std.mem.startsWith(u8, s.name, "hippo_"));
        for (tool_specs[i + 1 ..]) |o| try std.testing.expect(!std.mem.eql(u8, s.name, o.name));
        try std.testing.expect(!inList(s.cli[0], &forbidden));
    }
    try std.testing.expect(tool_specs.len >= 20);
}

test "tool table: required tools are present" {
    const want = [_][]const u8{
        "hippo_recall",  "hippo_store",     "hippo_link",         "hippo_invalidate", "hippo_walk",
        "hippo_status",  "hippo_stats",     "hippo_dump",         "hippo_consolidate", "hippo_reflect",
        "hippo_trace",   "hippo_thought",   "hippo_summary",      "hippo_fs_query",   "hippo_fs_search",
        "hippo_fs_neighbors", "hippo_fs_history", "hippo_fs_at_time", "hippo_fs_state_at", "hippo_fs_diff",
    };
    for (want) |n| _ = specByName(n);
}

test "schemas: valid JSON, properties and required match the arg tables" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    for (&tool_specs) |*s| {
        const schema = try buildSchema(ctx.arena, s);
        const v = try ctx.json(schema);
        try std.testing.expect(v == .object);
        const props = v.object.get("properties").?.object;
        try std.testing.expectEqual(s.args.len + 1, props.count());
        for (s.args) |a| try std.testing.expect(props.get(a.key) != null);
        try std.testing.expect(props.get("dir") != null);
        const req = v.object.get("required").?.array;
        var n_req: usize = 0;
        for (s.args) |a| {
            if (a.required) n_req += 1;
        }
        try std.testing.expectEqual(n_req, req.items.len);
        try std.testing.expectEqual(false, v.object.get("additionalProperties").?.bool);
    }
}

test "schemas: recall kind enum carries hippo's real kinds" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    const v = try ctx.json(try buildSchema(ctx.arena, specByName("hippo_recall")));
    const en = v.object.get("properties").?.object.get("kind").?.object.get("enum").?.array;
    try std.testing.expectEqual(@as(usize, 17), en.items.len);
    const link = try ctx.json(try buildSchema(ctx.arena, specByName("hippo_link")));
    const een = link.object.get("properties").?.object.get("kind").?.object.get("enum").?.array;
    try std.testing.expectEqual(@as(usize, 26), een.items.len);
}

test "argv: recall builds flags as separate entries, bare booleans" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    try expectBuilt(&ctx, "hippo_recall",
        \\{"query":"embedding host","k":5,"hybrid":true,"ppr":true,"spread":false,"no_touch":true,"kind":"fact","exclude_kind":"thought,tool_call","topic_prefix":"hippo-"}
    , &.{ "hippo", "recall", "--query", "embedding host", "--k", "5", "--hybrid", "--ppr", "--kind", "fact", "--exclude-kind", "thought,tool_call", "--topic-prefix", "hippo-", "--no-touch" });
}

test "argv: --dir from HIPPO_DIR default, per-call dir wins" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    cfg_dir = "/env/store";
    try expectBuilt(&ctx, "hippo_stats", "{}", &.{ "hippo", "stats", "--dir", "/env/store" });
    try expectBuilt(&ctx, "hippo_stats", "null", &.{ "hippo", "stats", "--dir", "/env/store" });
    try expectBuilt(&ctx, "hippo_stats", "{\"dir\":\"/call/store\"}", &.{ "hippo", "stats", "--dir", "/call/store" });
    try expectRejected(&ctx, "hippo_stats", "{\"dir\":\"--dir\"}", "'dir'");
    try expectRejected(&ctx, "hippo_stats", "{\"dir\":\"-x\"}", "must not start with '-'");
    try expectRejected(&ctx, "hippo_stats", "{\"dir\":\"\"}", "must not be empty");
}

test "argv: custom binary path is argv[0]" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    cfg_bin = "/opt/hippo/bin/hippo";
    try expectBuilt(&ctx, "hippo_trace", "{\"root\":7}", &.{ "/opt/hippo/bin/hippo", "trace", "--root", "7" });
}

test "argv: store with link_to, supersede, importance, kind" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    try expectBuilt(&ctx, "hippo_store",
        \\{"topic":"host","content":"1024-dim","kind":"fact","importance":5,"link_to":"12:supports","supersede":3,"singleton":true,"ttl_seconds":60,"silo":"proj"}
    , &.{ "hippo", "store", "--topic", "host", "--content", "1024-dim", "--kind", "fact", "--importance", "5", "--silo", "proj", "--link-to", "12:supports", "--supersede", "3", "--singleton", "--ttl-seconds", "60" });
}

test "argv: link, invalidate, walk, status, dump, reflect, consolidate, thought" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    try expectBuilt(&ctx, "hippo_link", "{\"from\":1,\"to\":2,\"kind\":\"is-a\",\"weight\":0.5}", &.{ "hippo", "link", "--from", "1", "--to", "2", "--kind", "is-a", "--weight", "0.5" });
    try expectBuilt(&ctx, "hippo_invalidate", "{\"from\":1,\"to\":2}", &.{ "hippo", "invalidate", "--from", "1", "--to", "2" });
    try expectBuilt(&ctx, "hippo_invalidate", "{\"from\":1,\"to\":2,\"kind\":\"derived-from\"}", &.{ "hippo", "invalidate", "--from", "1", "--to", "2", "--kind", "derived-from" });
    try expectBuilt(&ctx, "hippo_walk", "{\"from\":4,\"depth\":3,\"kind\":\"caused,supports\",\"include_invalid\":true}", &.{ "hippo", "walk", "--from", "4", "--depth", "3", "--kind", "caused,supports", "--include-invalid" });
    try expectBuilt(&ctx, "hippo_status", "{\"id\":9,\"to\":\"deprecated\"}", &.{ "hippo", "status", "--id", "9", "--to", "deprecated" });
    try expectBuilt(&ctx, "hippo_dump", "{\"id\":0}", &.{ "hippo", "dump", "--id", "0" });
    try expectBuilt(&ctx, "hippo_dump", "{\"limit\":10,\"offset\":20,\"include_fs\":true}", &.{ "hippo", "dump", "--limit", "10", "--offset", "20", "--include-fs" });
    try expectBuilt(&ctx, "hippo_reflect", "{\"limit\":8,\"threshold\":2.5,\"dry_run\":true}", &.{ "hippo", "reflect", "--limit", "8", "--threshold", "2.5", "--dry-run" });
    try expectBuilt(&ctx, "hippo_consolidate", "{\"dry_run\":true,\"threshold\":0.7}", &.{ "hippo", "consolidate", "--dry-run", "--threshold", "0.7" });
    try expectBuilt(&ctx, "hippo_thought", "{\"content\":\"try B\",\"parent\":5,\"branch\":true,\"ephemeral\":true}", &.{ "hippo", "thought", "--content", "try B", "--parent", "5", "--branch", "--ephemeral" });
}

test "argv: summary puts the action positional before flags" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    cfg_dir = "/s";
    try expectBuilt(&ctx, "hippo_summary", "{\"action\":\"put\",\"file\":\"src/a.zig\",\"symbol\":\"main\",\"content\":\"entry point\"}", &.{ "hippo", "summary", "put", "--dir", "/s", "--file", "src/a.zig", "--symbol", "main", "--content", "entry point" });
    try expectBuilt(&ctx, "hippo_summary", "{\"action\":\"list\",\"limit\":5}", &.{ "hippo", "summary", "list", "--dir", "/s", "--limit", "5" });
    try expectRejected(&ctx, "hippo_summary", "{\"action\":\"get\",\"file\":\"a\"}", "requires 'symbol'");
    try expectRejected(&ctx, "hippo_summary", "{\"action\":\"put\",\"file\":\"a\",\"symbol\":\"b\"}", "requires 'content'");
    try expectRejected(&ctx, "hippo_summary", "{\"action\":\"purge\"}", "allowed: put, get, list");
    try expectRejected(&ctx, "hippo_summary", "{\"file\":\"a\"}", "missing required argument 'action'");
}

test "argv: fs tools" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    try expectBuilt(&ctx, "hippo_fs_query", "{\"name_like\":\"main\",\"extension\":\"zig\",\"changed_within_days\":7,\"min_size_bytes\":1024,\"max_results\":20}", &.{ "hippo", "fs-query", "--name-like", "main", "--extension", "zig", "--changed-within-days", "7", "--min-size-bytes", "1024", "--max-results", "20" });
    try expectBuilt(&ctx, "hippo_fs_search", "{\"query\":\"src\",\"kind\":\"fs_dir\"}", &.{ "hippo", "fs-search", "--query", "src", "--kind", "fs_dir" });
    try expectBuilt(&ctx, "hippo_fs_neighbors", "{\"id\":3,\"depth\":2}", &.{ "hippo", "fs-neighbors", "--id", "3", "--depth", "2" });
    try expectBuilt(&ctx, "hippo_fs_history", "{\"id\":3}", &.{ "hippo", "fs-history", "--id", "3" });
    try expectBuilt(&ctx, "hippo_fs_at_time", "{\"t_ms\":1700000000000}", &.{ "hippo", "fs-at-time", "--t-ms", "1700000000000" });
    try expectBuilt(&ctx, "hippo_fs_state_at", "{\"t_ms\":5}", &.{ "hippo", "fs-state-at", "--t-ms", "5" });
    try expectBuilt(&ctx, "hippo_fs_diff", "{\"t1_ms\":1,\"t2_ms\":2}", &.{ "hippo", "fs-diff", "--t1-ms", "1", "--t2-ms", "2" });
    try expectRejected(&ctx, "hippo_fs_search", "{\"query\":\"x\",\"kind\":\"fact\"}", "invalid kind");
    try expectRejected(&ctx, "hippo_fs_at_time", "{\"t_ms\":-1}", "between 0 and");
}

test "injection: values starting with '-' or '--' are rejected where a value is expected" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    // strict tokens
    try expectRejected(&ctx, "hippo_recall", "{\"query\":\"q\",\"silo\":\"--dir\"}", "must not start with '-'");
    try expectRejected(&ctx, "hippo_recall", "{\"query\":\"q\",\"silo\":\"-all\"}", "must not start with '-'");
    try expectRejected(&ctx, "hippo_recall", "{\"query\":\"q\",\"mtime_since\":\"-5d\"}", "must not start with '-'");
    try expectRejected(&ctx, "hippo_summary", "{\"action\":\"get\",\"file\":\"--dir\",\"symbol\":\"x\"}", "must not start with '-'");
    try expectRejected(&ctx, "hippo_store", "{\"topic\":\"t\",\"content\":\"c\",\"agent_id\":\"-x\"}", "must not start with '-'");
    try expectRejected(&ctx, "hippo_fs_query", "{\"name_like\":\"--pretty\"}", "must not start with '-'");
    // free text: '--' and lone '-'
    try expectRejected(&ctx, "hippo_recall", "{\"query\":\"--dir /etc\"}", "must not start with '--'");
    try expectRejected(&ctx, "hippo_recall", "{\"query\":\"--help\"}", "must not start with '--'");
    try expectRejected(&ctx, "hippo_store", "{\"topic\":\"--kind\",\"content\":\"c\"}", "must not start with '--'");
    try expectRejected(&ctx, "hippo_store", "{\"topic\":\"t\",\"content\":\"-\"}", "exactly '-'");
    try expectRejected(&ctx, "hippo_thought", "{\"content\":\"--parent\"}", "must not start with '--'");
    // NUL bytes
    try expectRejected(&ctx, "hippo_recall", "{\"query\":\"a\\u0000b\"}", "NUL");
    // oversize
    const big = try ctx.arena.alloc(u8, MAX_ARG_BYTES + 1);
    @memset(big, 'a');
    const big_json = try std.fmt.allocPrint(ctx.arena, "{{\"topic\":\"t\",\"content\":\"{s}\"}}", .{big});
    try expectRejected(&ctx, "hippo_store", big_json, "too long");
}

test "injection: text with an embedded flag stays a single argv entry" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    try expectBuilt(&ctx, "hippo_store", "{\"topic\":\"t\",\"content\":\"run it with --dir /tmp/evil\"}", &.{ "hippo", "store", "--topic", "t", "--content", "run it with --dir /tmp/evil" });
    try expectBuilt(&ctx, "hippo_store", "{\"topic\":\"t\",\"content\":\"- bullet one\\n- bullet two\"}", &.{ "hippo", "store", "--topic", "t", "--content", "- bullet one\n- bullet two" });
    try expectBuilt(&ctx, "hippo_recall", "{\"query\":\"a; rm -rf / $(id) `x` | y\"}", &.{ "hippo", "recall", "--query", "a; rm -rf / $(id) `x` | y" });
}

test "validation: enums are checked against hippo's lists" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    try expectRejected(&ctx, "hippo_recall", "{\"query\":\"q\",\"kind\":\"bogus\"}", "invalid kind 'bogus'");
    try expectRejected(&ctx, "hippo_recall", "{\"query\":\"q\",\"kind\":\"--dir\"}", "invalid kind");
    try expectRejected(&ctx, "hippo_recall", "{\"query\":\"q\",\"exclude_kind\":\"thought,nope\"}", "invalid entry 'nope'");
    try expectRejected(&ctx, "hippo_recall", "{\"query\":\"q\",\"exclude_kind\":\"thought,\"}", "invalid entry ''");
    try expectRejected(&ctx, "hippo_store", "{\"topic\":\"t\",\"content\":\"c\",\"kind\":\"fs_file\"}", "invalid kind");
    try expectRejected(&ctx, "hippo_link", "{\"from\":1,\"to\":2,\"kind\":\"is_a\"}", "invalid kind 'is_a'");
    try expectRejected(&ctx, "hippo_link", "{\"from\":1,\"to\":2,\"kind\":\"-x\"}", "invalid kind");
    try expectRejected(&ctx, "hippo_invalidate", "{\"from\":1,\"to\":2,\"kind\":\"bogus\"}", "invalid kind");
    try expectRejected(&ctx, "hippo_walk", "{\"from\":1,\"kind\":\"caused,zzz\"}", "invalid entry 'zzz'");
    try expectRejected(&ctx, "hippo_status", "{\"id\":1,\"to\":\"deleted\"}", "invalid to");
    try expectRejected(&ctx, "hippo_store", "{\"topic\":\"t\",\"content\":\"c\",\"link_to\":\"12\"}", "ID:EDGE-KIND");
    try expectRejected(&ctx, "hippo_store", "{\"topic\":\"t\",\"content\":\"c\",\"link_to\":\"x:supports\"}", "bad node id");
    try expectRejected(&ctx, "hippo_store", "{\"topic\":\"t\",\"content\":\"c\",\"link_to\":\"1:nope\"}", "invalid edge kind");
    try expectRejected(&ctx, "hippo_store", "{\"topic\":\"t\",\"content\":\"c\",\"link_to\":\"-1:related\"}", "bad node id");
}

test "validation: numbers, types, unknown and missing arguments" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    try expectRejected(&ctx, "hippo_link", "{\"from\":-1,\"to\":2,\"kind\":\"related\"}", "non-negative");
    try expectRejected(&ctx, "hippo_link", "{\"from\":\"1\",\"to\":2,\"kind\":\"related\"}", "non-negative integer");
    try expectRejected(&ctx, "hippo_link", "{\"from\":1,\"to\":2,\"kind\":\"related\",\"weight\":-3}", "between 0 and");
    try expectRejected(&ctx, "hippo_link", "{\"from\":1,\"to\":2}", "missing required argument 'kind'");
    try expectRejected(&ctx, "hippo_recall", "{\"query\":\"q\",\"k\":0}", "between 1 and 50");
    try expectRejected(&ctx, "hippo_recall", "{\"query\":\"q\",\"k\":51}", "between 1 and 50");
    try expectRejected(&ctx, "hippo_recall", "{\"query\":\"q\",\"k\":1.5}", "must be an integer");
    try expectRejected(&ctx, "hippo_recall", "{\"query\":\"q\",\"hybrid\":\"yes\"}", "must be a boolean");
    try expectRejected(&ctx, "hippo_recall", "{}", "missing required argument 'query'");
    try expectRejected(&ctx, "hippo_recall", "{\"query\":5}", "must be a string");
    try expectRejected(&ctx, "hippo_recall", "{\"query\":\"q\",\"base_url\":\"http://evil\"}", "unknown argument 'base_url'");
    try expectRejected(&ctx, "hippo_recall", "{\"query\":\"q\",\"pretty\":true}", "unknown argument 'pretty'");
    try expectRejected(&ctx, "hippo_dump", "{\"all\":true}", "unknown argument 'all'");
    try expectRejected(&ctx, "hippo_store", "{\"topic\":\"t\",\"content\":\"c\",\"auto_supersede\":true}", "unknown argument");
    try expectRejected(&ctx, "hippo_store", "{\"topic\":\"t\",\"content\":\"c\",\"importance\":11}", "between 0 and 10");
    try expectRejected(&ctx, "hippo_stats", "[1]", "must be a JSON object");
    // null values behave as absent
    try expectBuilt(&ctx, "hippo_recall", "{\"query\":\"q\",\"k\":null,\"kind\":null}", &.{ "hippo", "recall", "--query", "q" });
    // integral floats are accepted as integers
    try expectBuilt(&ctx, "hippo_trace", "{\"root\":3.0}", &.{ "hippo", "trace", "--root", "3" });
}

test "exec: success returns stdout, argv passed to the seam" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fake_result = .{ .term = .{ .exited = 0 }, .stdout = @constCast("{\"ok\":true,\"nodes\":3}\n"), .stderr = @constCast("") };
    const res = try runTool(ctx.arena, std.testing.io, specByName("hippo_stats"), try ctx.json("{}"));
    try std.testing.expect(!res.is_error);
    try std.testing.expectEqualStrings("{\"ok\":true,\"nodes\":3}", res.text);
    try std.testing.expectEqual(@as(usize, 1), fake_calls);
    try std.testing.expectEqualStrings("hippo", fake_argv[0]);
    try std.testing.expectEqualStrings("stats", fake_argv[1]);
}

test "exec: validation failure never spawns" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    const res = try runTool(ctx.arena, std.testing.io, specByName("hippo_recall"), try ctx.json("{\"query\":\"--dir x\"}"));
    try std.testing.expect(res.is_error);
    try std.testing.expectEqual(@as(usize, 0), fake_calls);
}

test "exec: non-zero exit is a tool error carrying stderr and stdout" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fake_result = .{ .term = .{ .exited = 1 }, .stdout = @constCast("{\"ok\":false}"), .stderr = @constCast("hippo: invalid --kind\n") };
    const res = try runTool(ctx.arena, std.testing.io, specByName("hippo_stats"), try ctx.json("{}"));
    try std.testing.expect(res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "exit 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "hippo: invalid --kind") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "{\"ok\":false}") != null);
}

test "exec: missing binary gives a clear error" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    cfg_bin = "/no/such/hippo";
    fake_error = error.ExecutableNotFound;
    const res = try runTool(ctx.arena, std.testing.io, specByName("hippo_stats"), try ctx.json("{}"));
    try std.testing.expect(res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "/no/such/hippo") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "HIPPO_BIN") != null);
}

test "exec: other spawn errors are reported, not crashed" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fake_error = error.SystemResources;
    const res = try runTool(ctx.arena, std.testing.io, specByName("hippo_stats"), try ctx.json("{}"));
    try std.testing.expect(res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "SystemResources") != null);
}

test "exec: oversize output is capped on a UTF-8 boundary with a note" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    // 2-byte codepoints straddling the cap.
    const n = MAX_OUT_BYTES + 1000;
    const big = try ctx.arena.alloc(u8, n);
    var i: usize = 0;
    while (i + 1 < n) : (i += 2) {
        big[i] = 0xC3;
        big[i + 1] = 0xA9;
    }
    if (i < n) big[i] = 'x';
    fake_result = .{ .term = .{ .exited = 0 }, .stdout = big, .stderr = @constCast("") };
    const res = try runTool(ctx.arena, std.testing.io, specByName("hippo_dump"), try ctx.json("{}"));
    try std.testing.expect(!res.is_error);
    try std.testing.expect(res.text.len < MAX_OUT_BYTES + 500);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "output truncated") != null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(res.text));
}

test "exec: empty stdout falls back to a placeholder" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    fake_result = .{ .term = .{ .exited = 0 }, .stdout = @constCast(""), .stderr = @constCast("") };
    const res = try runTool(ctx.arena, std.testing.io, specByName("hippo_stats"), try ctx.json("{}"));
    try std.testing.expect(!res.is_error);
    try std.testing.expect(res.text.len > 0);
}

test "utf8Prefix never splits a codepoint" {
    const s = "a\xC3\xA9b";
    try std.testing.expectEqualStrings("a", utf8Prefix(s, 2));
    try std.testing.expectEqualStrings("a\xC3\xA9", utf8Prefix(s, 3));
    try std.testing.expectEqualStrings(s, utf8Prefix(s, 10));
}

test "real spawn: a missing binary maps to the clear error (no hippo needed)" {
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    exec_fn = execReal;
    cfg_bin = "zmcp-hippo-definitely-not-installed-binary";
    const res = try runTool(ctx.arena, std.testing.io, specByName("hippo_stats"), try ctx.json("{}"));
    try std.testing.expect(res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "HIPPO_BIN") != null);
}

test "e2e (opt-in): real hippo binary via ZMCP_HIPPO_E2E_BIN" {
    // Skips unless ZMCP_HIPPO_E2E_BIN points at a hippo executable. Uses a
    // scratch store under ZMCP_HIPPO_E2E_DIR (default /tmp). Needs no embed
    // server: only init, stats and status-free reads are exercised.
    var ctx: TestCtx = undefined;
    ctx.init();
    defer ctx.deinit();
    exec_fn = execReal;
    const bin = std.testing.environ.getAlloc(ctx.arena, "ZMCP_HIPPO_E2E_BIN") catch {
        std.debug.print("skipping e2e: ZMCP_HIPPO_E2E_BIN not set\n", .{});
        return;
    };
    const base = std.testing.environ.getAlloc(ctx.arena, "ZMCP_HIPPO_E2E_DIR") catch "/tmp";
    const io = std.testing.io;
    const dir = try std.fmt.allocPrint(ctx.arena, "{s}/zmcp-hippo-e2e-{d}", .{ base, std.Io.Clock.real.now(io).toNanoseconds() });
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const init_res = try execReal(ctx.arena, io, &.{ bin, "init", "--dir", dir });
    try std.testing.expect(init_res.term == .exited and init_res.term.exited == 0);

    cfg_bin = bin;
    const stats = try runTool(ctx.arena, io, specByName("hippo_stats"), try ctx.json(try std.fmt.allocPrint(ctx.arena, "{{\"dir\":\"{s}\"}}", .{dir})));
    try std.testing.expect(!stats.is_error);
    try std.testing.expect(std.mem.indexOf(u8, stats.text, "\"nodes\":0") != null);

    const bad = try runTool(ctx.arena, io, specByName("hippo_walk"), try ctx.json(try std.fmt.allocPrint(ctx.arena, "{{\"from\":5,\"dir\":\"{s}\"}}", .{dir})));
    try std.testing.expect(bad.is_error);
}
