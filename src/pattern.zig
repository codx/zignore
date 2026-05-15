// gitignore pattern matcher (subset of git's semantics).
//
// Supports: comments (#), blank lines, '*' (no /), '?' (no /), '[...]' char
// classes, '**' (path-segment wildcard), leading '/' (anchor to top), trailing
// '/' (directory-only), '!' negation.
//
// Deviations from full gitignore:
// - '**' inside the middle of a non-segment-bounded pattern collapses to '*';
//   only segment-bounded forms ('**/x', 'x/**', 'a/**/b') get the full
//   zero-or-more-segments semantics.
// - Negation re-include semantics match git's "last matching pattern wins"
//   rule but do NOT respect the "cannot re-include if parent dir is ignored"
//   rule. For our use (warn on staged/tracked artifacts), false-positive on
//   re-included files is a non-issue.
// - Character classes do not support POSIX [:alpha:] forms.

const std = @import("std");

pub const Pattern = struct {
    raw: []const u8, // owned slice; the original line (without # or trailing CR)
    body: []const u8, // view into raw with !, leading /, trailing / stripped
    negate: bool,
    anchored: bool, // leading '/' or pattern contains '/'
    dir_only: bool, // trailing '/'

    pub fn deinit(self: *Pattern, allocator: std.mem.Allocator) void {
        allocator.free(self.raw);
    }
};

pub const PatternList = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Pattern),
    source_name: []const u8, // owned; for diagnostics ("Python.gitignore")

    pub fn deinit(self: *PatternList) void {
        for (self.items.items) |*p| p.deinit(self.allocator);
        self.items.deinit(self.allocator);
        self.allocator.free(self.source_name);
    }
};

pub fn compile(allocator: std.mem.Allocator, source_name: []const u8, text: []const u8) !PatternList {
    var list: PatternList = .{
        .allocator = allocator,
        .items = .empty,
        .source_name = try allocator.dupe(u8, source_name),
    };
    errdefer list.deinit();

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line_in| {
        const line = stripCR(line_in);
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;

        var p_raw = trimmed;
        var negate = false;
        if (p_raw.len > 0 and p_raw[0] == '!') {
            negate = true;
            p_raw = p_raw[1..];
        }
        var dir_only = false;
        if (p_raw.len > 0 and p_raw[p_raw.len - 1] == '/') {
            dir_only = true;
            p_raw = p_raw[0 .. p_raw.len - 1];
        }
        var anchored = false;
        if (p_raw.len > 0 and p_raw[0] == '/') {
            anchored = true;
            p_raw = p_raw[1..];
        }
        // Per gitignore: a slash anywhere except trailing makes the pattern anchored.
        if (!anchored and containsSlash(p_raw)) anchored = true;

        const raw_owned = try allocator.dupe(u8, trimmed);
        // Re-derive body as a view into raw_owned so it shares lifetime.
        var body: []const u8 = raw_owned;
        if (body.len > 0 and body[0] == '!') body = body[1..];
        if (body.len > 0 and body[0] == '/') body = body[1..];
        if (body.len > 0 and body[body.len - 1] == '/') body = body[0 .. body.len - 1];
        try list.items.append(allocator, .{
            .raw = raw_owned,
            .body = body,
            .negate = negate,
            .anchored = anchored,
            .dir_only = dir_only,
        });
    }
    return list;
}

fn containsSlash(s: []const u8) bool {
    for (s) |c| if (c == '/') return true;
    return false;
}

fn stripCR(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == '\r') return s[0 .. s.len - 1];
    return s;
}

pub const MatchKind = enum { none, ignored, reincluded };

// Match a path against a single pattern. Path is forward-slash separated,
// no leading slash, no trailing slash. `is_dir` indicates whether the
// candidate path is known to be a directory.
pub fn matchOne(p: Pattern, path: []const u8, is_dir: bool) bool {
    if (p.dir_only and !is_dir) return false;
    if (p.anchored) return globMatch(p.body, path);
    // Unanchored: try matching against the full path, then any suffix
    // starting after a '/'.
    if (globMatch(p.body, path)) return true;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/' and i + 1 < path.len) {
            if (globMatch(p.body, path[i + 1 ..])) return true;
        }
    }
    return false;
}

// Match a list of patterns. Last matching pattern wins (git semantics).
pub fn match(list: *const PatternList, path: []const u8, is_dir: bool) MatchKind {
    var state: MatchKind = .none;
    for (list.items.items) |p| {
        if (matchOne(p, path, is_dir)) {
            state = if (p.negate) .reincluded else .ignored;
        }
    }
    return state;
}

// Glob matcher with '**' support. `pattern` and `path` are forward-slash
// separated. '**' matches zero or more path segments; '*' and '?' do not
// cross '/'; '[...]' is a char class.
fn globMatch(pattern: []const u8, path: []const u8) bool {
    return globRec(pattern, 0, path, 0);
}

fn globRec(p: []const u8, pi_in: usize, s: []const u8, si_in: usize) bool {
    var pi = pi_in;
    var si = si_in;
    while (pi < p.len) {
        // '**' handling
        if (pi + 1 < p.len and p[pi] == '*' and p[pi + 1] == '*') {
            // Consume optional trailing slash in the pattern after '**'
            var rest_start = pi + 2;
            if (rest_start < p.len and p[rest_start] == '/') rest_start += 1;
            // If '**' is at end of pattern, it matches everything remaining.
            if (rest_start >= p.len) return true;
            // Otherwise try to match the rest at every position in s, but
            // '**' must align with segment boundaries.
            var k: usize = si;
            while (true) {
                if (globRec(p, rest_start, s, k)) return true;
                if (k >= s.len) return false;
                // Advance to character after the next '/'.
                while (k < s.len and s[k] != '/') k += 1;
                if (k < s.len) k += 1; // skip the '/'
            }
        }

        if (si >= s.len) {
            // Pattern can only still match if it is "*" or trailing optional.
            // Single '*' at end matches empty.
            if (p[pi] == '*' and pi + 1 == p.len) return true;
            return false;
        }

        const pc = p[pi];
        const sc = s[si];
        switch (pc) {
            '*' => {
                // '*' matches zero or more non-'/' chars.
                // Try matching empty first, then expand.
                var k: usize = si;
                while (true) {
                    if (globRec(p, pi + 1, s, k)) return true;
                    if (k >= s.len or s[k] == '/') return false;
                    k += 1;
                }
            },
            '?' => {
                if (sc == '/') return false;
                pi += 1;
                si += 1;
            },
            '[' => {
                const close = std.mem.indexOfScalarPos(u8, p, pi + 1, ']') orelse return false;
                if (sc == '/') return false;
                if (!classMatch(p[pi + 1 .. close], sc)) return false;
                pi = close + 1;
                si += 1;
            },
            '\\' => {
                if (pi + 1 >= p.len) return false;
                if (p[pi + 1] != sc) return false;
                pi += 2;
                si += 1;
            },
            else => {
                if (pc != sc) return false;
                pi += 1;
                si += 1;
            },
        }
    }
    return si == s.len;
}

fn classMatch(class: []const u8, c: u8) bool {
    if (class.len == 0) return false;
    var negate = false;
    var i: usize = 0;
    if (class[0] == '!' or class[0] == '^') {
        negate = true;
        i = 1;
    }
    var matched = false;
    while (i < class.len) {
        if (i + 2 < class.len and class[i + 1] == '-') {
            const lo = class[i];
            const hi = class[i + 2];
            if (c >= lo and c <= hi) matched = true;
            i += 3;
        } else {
            if (class[i] == c) matched = true;
            i += 1;
        }
    }
    return matched != negate; // XOR
}

// --- tests ---

test "simple star" {
    const t = std.testing;
    var lst = try compile(t.allocator, "test", "*.pyc\n");
    defer lst.deinit();
    try t.expectEqual(MatchKind.ignored, match(&lst, "foo.pyc", false));
    try t.expectEqual(MatchKind.ignored, match(&lst, "sub/foo.pyc", false));
    try t.expectEqual(MatchKind.none, match(&lst, "foo.py", false));
}

test "directory only" {
    const t = std.testing;
    var lst = try compile(t.allocator, "test", "node_modules/\n");
    defer lst.deinit();
    try t.expectEqual(MatchKind.ignored, match(&lst, "node_modules", true));
    try t.expectEqual(MatchKind.ignored, match(&lst, "a/node_modules", true));
    try t.expectEqual(MatchKind.none, match(&lst, "node_modules", false));
}

test "anchored leading slash" {
    const t = std.testing;
    var lst = try compile(t.allocator, "test", "/foo\n");
    defer lst.deinit();
    try t.expectEqual(MatchKind.ignored, match(&lst, "foo", false));
    try t.expectEqual(MatchKind.none, match(&lst, "a/foo", false));
}

test "negation re-include" {
    const t = std.testing;
    var lst = try compile(t.allocator, "test", "*.log\n!important.log\n");
    defer lst.deinit();
    try t.expectEqual(MatchKind.ignored, match(&lst, "foo.log", false));
    try t.expectEqual(MatchKind.reincluded, match(&lst, "important.log", false));
}

test "double star" {
    const t = std.testing;
    var lst = try compile(t.allocator, "test", "**/__pycache__/\n");
    defer lst.deinit();
    try t.expectEqual(MatchKind.ignored, match(&lst, "__pycache__", true));
    try t.expectEqual(MatchKind.ignored, match(&lst, "a/b/__pycache__", true));
}

test "char class" {
    const t = std.testing;
    var lst = try compile(t.allocator, "test", "*.py[cod]\n");
    defer lst.deinit();
    try t.expectEqual(MatchKind.ignored, match(&lst, "x.pyc", false));
    try t.expectEqual(MatchKind.ignored, match(&lst, "x.pyo", false));
    try t.expectEqual(MatchKind.none, match(&lst, "x.pyx", false));
}

test "comments and blanks skipped" {
    const t = std.testing;
    var lst = try compile(t.allocator, "test", "# a comment\n\n*.pyc\n");
    defer lst.deinit();
    try t.expectEqual(@as(usize, 1), lst.items.items.len);
}
