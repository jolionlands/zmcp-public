//! Intent → keyboard-shortcut lookup (port of clawdcursor findShortcut).
//! Exact intent match first ("scroll down", "press scroll down"), otherwise
//! the closest intent within Levenshtein distance 1 on the alphanumeric-only
//! form. Context-scoped shortcuts (reddit, outlook, ...) only match when the
//! intent or the context hint mentions one of their hints.

const std = @import("std");
pub const data = @import("shortcuts_data.zig");
pub const Shortcut = data.Shortcut;

pub const categories = [_][]const u8{ "navigation", "browser", "editing", "social", "window", "file", "view", "quick" };

pub const Match = struct {
    shortcut: *const Shortcut,
    matched_intent: []const u8,
    exact: bool,
};

fn normalizeInto(buf: []u8, s: []const u8) []const u8 {
    // lower-case, drop quotes, collapse whitespace, trim
    var n: usize = 0;
    var pending_space = false;
    for (s) |c0| {
        if (c0 == '"' or c0 == '\'' or c0 == '`') continue;
        if (std.ascii.isWhitespace(c0)) {
            pending_space = n > 0;
            continue;
        }
        if (n + 2 > buf.len) break;
        if (pending_space) {
            buf[n] = ' ';
            n += 1;
            pending_space = false;
        }
        buf[n] = std.ascii.toLower(c0);
        n += 1;
    }
    return buf[0..n];
}

fn compactInto(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    for (s) |c| {
        const l = std.ascii.toLower(c);
        if (std.ascii.isAlphanumeric(l) and n < buf.len) {
            buf[n] = l;
            n += 1;
        }
    }
    return buf[0..n];
}

fn levenshtein(a: []const u8, b: []const u8) usize {
    if (std.mem.eql(u8, a, b)) return 0;
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    var prev: [129]usize = undefined;
    if (b.len >= prev.len) return std.math.maxInt(usize);
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 1..) |ca, i| {
        var diag = prev[0];
        prev[0] = i;
        for (b, 1..) |cb, j| {
            const tmp = prev[j];
            const cost: usize = if (ca == cb) 0 else 1;
            prev[j] = @min(@min(prev[j] + 1, prev[j - 1] + 1), diag + cost);
            diag = tmp;
        }
    }
    return prev[b.len];
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    return std.ascii.findIgnoreCase(hay, needle) != null;
}

pub fn contextAllows(s: *const Shortcut, normalized_intent: []const u8, context_hint: []const u8) bool {
    if (s.context.len == 0) return true;
    for (s.context) |hint| {
        if (containsIgnoreCase(normalized_intent, hint) or containsIgnoreCase(context_hint, hint)) return true;
    }
    return false;
}

pub fn find(intent: []const u8, context_hint: []const u8) ?Match {
    var nbuf: [256]u8 = undefined;
    var cbuf: [256]u8 = undefined;
    const normalized = normalizeInto(&nbuf, intent);
    const compact = compactInto(&cbuf, intent);
    var best: ?Match = null;
    var best_dist: usize = std.math.maxInt(usize);
    for (&data.all) |*s| {
        if (!contextAllows(s, normalized, context_hint)) continue;
        for (s.intents) |cand| {
            var ibuf: [256]u8 = undefined;
            const ni = normalizeInto(&ibuf, cand);
            if (std.mem.eql(u8, normalized, ni) or
                (std.mem.startsWith(u8, normalized, "press ") and std.mem.eql(u8, normalized[6..], ni)))
            {
                return .{ .shortcut = s, .matched_intent = cand, .exact = true };
            }
            var ic: [256]u8 = undefined;
            const d = levenshtein(compact, compactInto(&ic, cand));
            if (d <= 1 and d < best_dist) {
                best_dist = d;
                best = .{ .shortcut = s, .matched_intent = cand, .exact = false };
            }
        }
    }
    return best;
}

/// shortcuts_list filter: by category, and by context (universal shortcuts
/// always included when a context is given; context-scoped ones only when
/// hint and context overlap). Without a context only universal ones.
pub fn listed(s: *const Shortcut, category: ?[]const u8, context: ?[]const u8) bool {
    if (category) |c| if (!std.mem.eql(u8, s.category, c)) return false;
    if (context) |ctx| {
        if (s.context.len == 0) return true;
        for (s.context) |h| {
            if (containsIgnoreCase(h, ctx) or containsIgnoreCase(ctx, h)) return true;
        }
        return false;
    }
    return s.context.len == 0;
}

const t = std.testing;

test "exact, press-prefixed and fuzzy intents" {
    const m = find("scroll down", "").?;
    try t.expectEqualStrings("PageDown", m.shortcut.key);
    try t.expect(m.exact);
    try t.expectEqualStrings("Control+t", find("press new tab", "").?.shortcut.key);
    const f = find("new tabb", "").?;
    try t.expect(!f.exact);
    try t.expectEqualStrings("Control+t", f.shortcut.key);
    try t.expect(find("launch the rockets", "") == null);
}

test "context-scoped shortcuts need a matching hint" {
    try t.expect(find("upvote", "") == null);
    try t.expectEqualStrings("a", find("upvote", "reddit - Google Chrome").?.shortcut.key);
    try t.expectEqualStrings("Control+Return", find("send email", "olk Inbox").?.shortcut.key);
}

test "list filters" {
    var universal: usize = 0;
    var social_reddit: usize = 0;
    for (&data.all) |*s| {
        if (listed(s, null, null)) universal += 1;
        if (listed(s, "social", "reddit")) social_reddit += 1;
    }
    try t.expect(universal > 30);
    try t.expectEqual(@as(usize, 6), social_reddit);
}
