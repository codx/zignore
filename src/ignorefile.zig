// Plain-text .gitignore manipulation. No managed markers — sections are
// identified by `# <TemplateName>` headers (case-insensitive). A section
// extends from its header to the first blank line, the first line starting
// with `#`, or EOF.
//
// Add semantics (see `add`):
//   1. Refuse if any new pattern would shadow an existing `!negation`.
//   2. If a matching header exists, insert the new patterns just before the
//      section boundary (first blank/`#` after the header).
//   3. Otherwise, append a fresh section at the end of the file.
//   4. Pattern lines already present anywhere in the file are skipped.

const std = @import("std");
const pattern = @import("pattern.zig");
const templates = @import("templates.zig");

pub const ShadowReport = struct {
    new_pattern: []const u8, // borrowed from input text
    negation_line: []const u8, // borrowed from input
};

pub const AddResult = union(enum) {
    ok: []u8, // owned
    shadowed: ShadowReport,
};

pub const HeaderMode = enum { fancy, none };

pub const Options = struct {
    header: HeaderMode = .fancy,
};

// Apply a template to existing .gitignore content. Returns either the new
// content (owned) or a ShadowReport when a new pattern would shadow an
// existing `!negation`. Section boundaries are determined by the bundled
// template-name set, so any zignore-managed sibling header ends the section.
//
// `opts.header` only affects the *create* path: when no existing header
// for `header_name` is found, .fancy emits a decorated `# ─── Name ──` line
// and .none appends the patterns directly. If a header is already present,
// behavior is identical for both modes (patterns slot into the existing
// section).
pub fn add(
    allocator: std.mem.Allocator,
    existing: []const u8,
    header_name: []const u8,
    template_content: []const u8,
    opts: Options,
) (std.mem.Allocator.Error || std.Io.Writer.Error)!AddResult {
    if (try detectShadow(allocator, existing, template_content)) |s| {
        return .{ .shadowed = s };
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    if (findHeader(existing, header_name)) |hdr| {
        const boundary = sectionEndKnown(existing, hdr.after_header);
        // Build the new chunk in a scratch buffer first; if every template
        // line is already present (i.e. nothing meaningful would be added)
        // skip the rewrite entirely. Keeps re-runs idempotent.
        var scratch: std.Io.Writer.Allocating = .init(allocator);
        defer scratch.deinit();
        try writeNewPatterns(&scratch.writer, existing, template_content);
        if (chunkIsEmpty(scratch.written())) return .{ .ok = try allocator.dupe(u8, existing) };
        try w.writeAll(existing[0..boundary]);
        try w.writeAll(scratch.written());
        try w.writeAll(existing[boundary..]);
    } else {
        // Build the body in scratch first; if every template line is
        // already present in `existing`, skip the rewrite entirely so we
        // don't leave a bare header line with no patterns behind.
        var scratch: std.Io.Writer.Allocating = .init(allocator);
        defer scratch.deinit();
        try writeNewPatterns(&scratch.writer, existing, template_content);
        if (chunkIsEmpty(scratch.written())) return .{ .ok = try allocator.dupe(u8, existing) };

        try w.writeAll(existing);
        if (existing.len > 0 and existing[existing.len - 1] != '\n')
            try w.writeByte('\n');
        if (existing.len > 0) try w.writeByte('\n');
        switch (opts.header) {
            .fancy => try writeFancyHeader(w, header_name),
            .none => {},
        }
        try w.writeAll(scratch.written());
    }

    return .{ .ok = try aw.toOwnedSlice() };
}

// Emit a decorated section header. The horizontal line fills to a visual
// width of target_width characters when rendered in a fixed-width font.
fn writeFancyHeader(w: *std.Io.Writer, name: []const u8) !void {
    const target_width: usize = 60;
    // Visual width of `# ─── {name} ` is 2 + 4 + name.len + 1 (each line char = 1 col).
    const prefix_visual: usize = 2 + 4 + name.len + 1;
    const trailing: usize = if (target_width > prefix_visual) target_width - prefix_visual else 8;
    try w.writeAll("# \xe2\x94\x80\xe2\x94\x80\xe2\x94\x80 "); // "# ─── "
    try w.writeAll(name);
    try w.writeByte(' ');
    var i: usize = 0;
    while (i < trailing) : (i += 1) try w.writeAll("\xe2\x94\x80"); // "─"
    try w.writeByte('\n');
}

const HeaderLoc = struct {
    /// Byte offset of the start of the header line.
    header_start: usize,
    /// Byte offset just after the header's trailing newline (or EOF).
    after_header: usize,
};

// Find a section header line for `name`. Returns the location of the first
// match. We try two passes:
//   1. STRICT: line is a comment whose ONLY name-token equals `name`. This
//      is the canonical form we emit (`# Python`, `# === Python ===`,
//      `# ─── Python ──`, etc.).
//   2. LENIENT: line is a comment that mentions `name` as one of several
//      name-tokens (e.g. `# Python tooling notes`). Picked up only when no
//      strict header exists, so a real `# === Python ===` further down
//      still wins over a narrative `# Python tooling` above.
// Returns null if neither form matches.
pub fn findHeader(text: []const u8, name: []const u8) ?HeaderLoc {
    return findHeaderPass(text, name, .strict) orelse findHeaderPass(text, name, .lenient);
}

const Match = enum { strict, lenient };

fn findHeaderPass(text: []const u8, name: []const u8, mode: Match) ?HeaderLoc {
    var line_start: usize = 0;
    while (line_start < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        const line = text[line_start..nl];
        if (lineMatchesName(line, name, mode)) {
            const after = if (nl < text.len) nl + 1 else nl;
            return .{ .header_start = line_start, .after_header = after };
        }
        line_start = if (nl < text.len) nl + 1 else nl;
    }
    return null;
}

// Returns true when `line` is a comment header for `name` under `mode`.
// strict  → line has exactly one name-token and it equals `name`.
// lenient → line is a comment and ANY of its name-tokens equals `name`.
//
// Name chars: ASCII alphanumeric plus `_`, `+`, `-`, `.` — covers all 266
// bundled template names (e.g. Python, Node, C++, Objective-C, ecu.test).
fn lineMatchesName(line_in: []const u8, name: []const u8, mode: Match) bool {
    const line = stripCR(line_in);
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i >= line.len or line[i] != '#') return false;
    while (i < line.len and line[i] == '#') i += 1;
    const rest = line[i..];

    var token_count: usize = 0;
    var matched = false;
    var token_start: ?usize = null;
    var idx: usize = 0;
    while (idx <= rest.len) : (idx += 1) {
        const at_end = idx == rest.len;
        const c = if (at_end) @as(u8, 0) else rest[idx];
        if (!at_end and isNameChar(c)) {
            if (token_start == null) token_start = idx;
        } else if (token_start) |ts| {
            const tok = rest[ts..idx];
            token_count += 1;
            if (std.ascii.eqlIgnoreCase(tok, name)) matched = true;
            token_start = null;
        }
    }
    if (!matched or token_count == 0) return false;
    return switch (mode) {
        .strict => token_count == 1,
        .lenient => true,
    };
}

// Returns the single name token from a strictly-shaped header line, or
// null if the line is not a comment, has zero name-tokens, or has more
// than one. Used by the sibling-boundary scan, which must NOT match
// narrative comments like `# Python tooling notes`.
fn extractSingleHeaderToken(line_in: []const u8) ?[]const u8 {
    const line = stripCR(line_in);
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i >= line.len or line[i] != '#') return null;
    while (i < line.len and line[i] == '#') i += 1;
    const rest = line[i..];

    var found: ?[]const u8 = null;
    var token_start: ?usize = null;
    var idx: usize = 0;
    while (idx < rest.len) : (idx += 1) {
        const c = rest[idx];
        if (isNameChar(c)) {
            if (token_start == null) token_start = idx;
        } else {
            if (token_start) |ts| {
                if (found != null) return null;
                found = rest[ts..idx];
                token_start = null;
            }
        }
    }
    if (token_start) |ts| {
        if (found != null) return null;
        found = rest[ts..];
    }
    return found;
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '+' or c == '-' or c == '.';
}

// End-of-section offset. Scans from `after_header` to the first line that
// is a header for any bundled template name, or EOF. Blank lines and
// non-header comments do NOT end the section — only a sibling header does.
fn sectionEndKnown(text: []const u8, after_header: usize) usize {
    var p = after_header;
    while (p < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, p, '\n') orelse text.len;
        const line = text[p..nl];
        if (isAnyBundledHeader(line)) return p;
        p = if (nl < text.len) nl + 1 else nl;
    }
    return text.len;
}

fn isAnyBundledHeader(line: []const u8) bool {
    const tok = extractSingleHeaderToken(line) orelse return false;
    var it = templates.iter();
    while (it.next()) |t| if (std.ascii.eqlIgnoreCase(tok, t.name)) return true;
    return false;
}

// Write template content, skipping non-blank lines already present
// anywhere in `existing`. Both patterns AND comments are deduplicated so
// re-running `add` with the same template doesn't accumulate dupes. Blank
// lines from the template pass through verbatim; chunkIsEmpty + the
// caller's idempotency check prevent unbounded blank-line accumulation.
fn writeNewPatterns(w: *std.Io.Writer, existing: []const u8, template: []const u8) !void {
    var it = std.mem.splitScalar(u8, template, '\n');
    while (it.next()) |line_in| {
        if (line_in.len == 0 and it.peek() == null) continue;
        const line = stripCR(line_in);
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len != 0) {
            if (containsLine(existing, line)) continue;
        }
        try w.writeAll(line);
        try w.writeByte('\n');
    }
}

// True if the chunk contains nothing but blank lines — used to short-circuit
// idempotent re-runs of `add` so we don't accumulate phantom blanks.
fn chunkIsEmpty(chunk: []const u8) bool {
    var it = std.mem.splitScalar(u8, chunk, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len != 0) return false;
    }
    return true;
}

// Whole-line containment: returns true iff `needle` appears as a complete
// line anywhere in `hay`. Avoids substring false positives.
fn containsLine(hay: []const u8, needle_in: []const u8) bool {
    const needle = std.mem.trim(u8, needle_in, " \t");
    var line_start: usize = 0;
    while (line_start <= hay.len) {
        const nl = std.mem.indexOfScalarPos(u8, hay, line_start, '\n') orelse hay.len;
        const line = stripCR(hay[line_start..nl]);
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.eql(u8, trimmed, needle)) return true;
        if (nl >= hay.len) break;
        line_start = nl + 1;
    }
    return false;
}

// Detect whether any non-negation pattern in `template` would shadow an
// existing `!Q` line in `existing` once inserted. Heuristic — see notes at
// the top of pattern.zig. Reports the first conflict found.
fn detectShadow(
    allocator: std.mem.Allocator,
    existing: []const u8,
    template: []const u8,
) (std.mem.Allocator.Error || std.Io.Writer.Error)!?ShadowReport {
    var negations: std.ArrayList(struct {
        line: []const u8,
        body: []const u8, // negation body, leading '!' stripped
    }) = .empty;
    defer negations.deinit(allocator);

    {
        var it = std.mem.splitScalar(u8, existing, '\n');
        while (it.next()) |line_in| {
            const line = stripCR(line_in);
            const t = std.mem.trim(u8, line, " \t");
            if (t.len < 2 or t[0] != '!') continue;
            try negations.append(allocator, .{ .line = line, .body = t[1..] });
        }
    }

    if (negations.items.len == 0) return null;

    var it = std.mem.splitScalar(u8, template, '\n');
    while (it.next()) |line_in| {
        const line = stripCR(line_in);
        const t = std.mem.trim(u8, line, " \t");
        if (t.len == 0 or t[0] == '#' or t[0] == '!') continue;
        // Idempotency: a candidate already present as a complete line in
        // `existing` is not being added — it can't shadow anything that
        // didn't already coexist with it on the prior run. Without this,
        // re-running `add` on a template that bundles its own negation
        // (e.g. Python's `.pixi/*` + `!.pixi/config.toml`) self-trips.
        if (containsLine(existing, line)) continue;

        var pl = try pattern.compile(allocator, "candidate", t);
        defer pl.deinit();
        if (pl.items.items.len == 0) continue;
        const p = pl.items.items[0];

        for (negations.items) |n| {
            const neg_path = stripTrailingSlash(n.body);
            if (neg_path.len == 0) continue;
            const is_dir = std.mem.endsWith(u8, n.body, "/");

            // Direct shadow: candidate pattern matches the negation's path.
            if (pattern.matchOne(p, neg_path, is_dir)) {
                return .{ .new_pattern = t, .negation_line = n.line };
            }

            // Dir-prefix shadow: candidate is a dir pattern that would
            // ignore a parent of the negation's path. E.g., `dist/` shadows
            // `!dist/keep`.
            if (std.mem.indexOfScalar(u8, neg_path, '/')) |slash| {
                const parent = neg_path[0..slash];
                if (pattern.matchOne(p, parent, true)) {
                    return .{ .new_pattern = t, .negation_line = n.line };
                }
            }
        }
    }

    return null;
}

fn stripTrailingSlash(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == '/') return s[0 .. s.len - 1];
    return s;
}

fn stripCR(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == '\r') return s[0 .. s.len - 1];
    return s;
}

// --- file I/O ---

pub fn readFile(io: std.Io, allocator: std.mem.Allocator, repo_root: []const u8, rel_path: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ repo_root, rel_path });
    defer allocator.free(path);
    return std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => err,
    };
}

pub fn writeFileAtomic(io: std.Io, allocator: std.mem.Allocator, repo_root: []const u8, rel_path: []const u8, content: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ repo_root, rel_path });
    defer allocator.free(path);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.zignore.tmp", .{path});
    defer allocator.free(tmp_path);
    {
        var f = try std.Io.Dir.createFile(.cwd(), io, tmp_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, content);
    }
    try std.Io.Dir.rename(.cwd(), tmp_path, .cwd(), path, io);
}

// Fixture-based tests live in tests.zig (project root) so @embedFile can
// reach tests/fixtures/.
