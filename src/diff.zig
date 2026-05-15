// Line-oriented unified diff. LCS-based, so O(n*m) time and memory in line
// count — fine for .gitignore files (hundreds of lines at most). Output
// matches the conventional `--- / +++ / @@ -a,b +c,d @@` shape so the
// result can be piped to `delta`, `bat`, or `patch`.

const std = @import("std");

const Op = enum { keep, del, add };
const Edit = struct { op: Op, line: []const u8 };

// ANSI styling for diff output. Bold-everywhere by default so the +/- prefix
// glyph remains the primary signal even when colour is invisible (red/green
// is the textbook deuteranopia/protanopia blind spot). Colour reinforces.
pub const Style = struct {
    add: []const u8 = "",
    del: []const u8 = "",
    hunk: []const u8 = "",
    file: []const u8 = "",
    reset: []const u8 = "",

    pub const plain: Style = .{};
    pub const ansi: Style = .{
        .add = "\x1b[1;32m", // bold green
        .del = "\x1b[1;31m", // bold red
        .hunk = "\x1b[1;36m", // bold cyan
        .file = "\x1b[1m", // bold
        .reset = "\x1b[0m",
    };
};

pub fn write(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    old_label: []const u8,
    new_label: []const u8,
    old_text: []const u8,
    new_text: []const u8,
    context: usize,
    style: Style,
) !void {
    const old_lines = try splitLines(allocator, old_text);
    defer allocator.free(old_lines);
    const new_lines = try splitLines(allocator, new_text);
    defer allocator.free(new_lines);

    const edits = try diff(allocator, old_lines, new_lines);
    defer allocator.free(edits);

    if (!hasChanges(edits)) return;

    try w.print("{s}--- {s}{s}\n", .{ style.file, old_label, style.reset });
    try w.print("{s}+++ {s}{s}\n", .{ style.file, new_label, style.reset });
    try writeHunks(w, edits, context, style);
}

fn splitLines(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try lines.append(allocator, stripCR(line));
    // splitScalar yields a trailing empty entry when text ends with '\n'.
    // Drop it so a file ending in '\n' isn't reported as having an extra
    // blank line.
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) {
        _ = lines.pop();
    }
    return lines.toOwnedSlice(allocator);
}

fn stripCR(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == '\r') return s[0 .. s.len - 1];
    return s;
}

fn diff(
    allocator: std.mem.Allocator,
    a: []const []const u8,
    b: []const []const u8,
) ![]Edit {
    const n = a.len;
    const m = b.len;
    const stride = m + 1;
    const tbl = try allocator.alloc(usize, (n + 1) * stride);
    defer allocator.free(tbl);
    @memset(tbl, 0);

    var i: usize = 1;
    while (i <= n) : (i += 1) {
        var j: usize = 1;
        while (j <= m) : (j += 1) {
            if (std.mem.eql(u8, a[i - 1], b[j - 1])) {
                tbl[i * stride + j] = tbl[(i - 1) * stride + (j - 1)] + 1;
            } else {
                tbl[i * stride + j] = @max(tbl[(i - 1) * stride + j], tbl[i * stride + (j - 1)]);
            }
        }
    }

    var edits: std.ArrayList(Edit) = .empty;
    defer edits.deinit(allocator);

    var ii = n;
    var jj = m;
    while (ii > 0 or jj > 0) {
        if (ii > 0 and jj > 0 and std.mem.eql(u8, a[ii - 1], b[jj - 1])) {
            try edits.append(allocator, .{ .op = .keep, .line = a[ii - 1] });
            ii -= 1;
            jj -= 1;
        } else if (jj > 0 and (ii == 0 or tbl[ii * stride + (jj - 1)] >= tbl[(ii - 1) * stride + jj])) {
            try edits.append(allocator, .{ .op = .add, .line = b[jj - 1] });
            jj -= 1;
        } else {
            try edits.append(allocator, .{ .op = .del, .line = a[ii - 1] });
            ii -= 1;
        }
    }

    std.mem.reverse(Edit, edits.items);
    return edits.toOwnedSlice(allocator);
}

fn hasChanges(edits: []const Edit) bool {
    for (edits) |e| if (e.op != .keep) return true;
    return false;
}

fn writeHunks(w: *std.Io.Writer, edits: []const Edit, context: usize, style: Style) !void {
    var i: usize = 0;
    while (i < edits.len) {
        while (i < edits.len and edits[i].op == .keep) i += 1;
        if (i >= edits.len) break;

        // Walk back up to `context` keeps for leading context.
        var lo = i;
        var back: usize = 0;
        while (lo > 0 and back < context and edits[lo - 1].op == .keep) : (back += 1) {
            lo -= 1;
        }

        // Extend forward. A run of <=2*context keeps that's followed by
        // another change gets absorbed (so adjacent hunks merge); a longer
        // run terminates the hunk, keeping up to `context` trailing keeps.
        var hi = i + 1;
        while (hi < edits.len) {
            if (edits[hi].op != .keep) {
                hi += 1;
                continue;
            }
            var look = hi;
            var keeps: usize = 0;
            while (look < edits.len and edits[look].op == .keep) {
                keeps += 1;
                look += 1;
            }
            if (look < edits.len and keeps <= 2 * context) {
                hi = look;
                continue;
            }
            hi += @min(context, keeps);
            break;
        }
        if (hi > edits.len) hi = edits.len;

        var old_start: usize = 1;
        var new_start: usize = 1;
        for (edits[0..lo]) |e| switch (e.op) {
            .keep => {
                old_start += 1;
                new_start += 1;
            },
            .del => old_start += 1,
            .add => new_start += 1,
        };
        var old_count: usize = 0;
        var new_count: usize = 0;
        for (edits[lo..hi]) |e| switch (e.op) {
            .keep => {
                old_count += 1;
                new_count += 1;
            },
            .del => old_count += 1,
            .add => new_count += 1,
        };

        // Unified-diff convention: when count == 0 the line number points
        // at the line BEFORE the gap, so an insert at line 5 reads
        // "-4,0 +5,N".
        const old_hdr = if (old_count == 0 and old_start > 1) old_start - 1 else old_start;
        const new_hdr = if (new_count == 0 and new_start > 1) new_start - 1 else new_start;

        try w.print("{s}@@ -{d},{d} +{d},{d} @@{s}\n", .{ style.hunk, old_hdr, old_count, new_hdr, new_count, style.reset });
        for (edits[lo..hi]) |e| {
            const tint: []const u8 = switch (e.op) {
                .keep => "",
                .add => style.add,
                .del => style.del,
            };
            const prefix: u8 = switch (e.op) {
                .keep => ' ',
                .del => '-',
                .add => '+',
            };
            if (tint.len > 0) try w.writeAll(tint);
            try w.writeByte(prefix);
            try w.writeAll(e.line);
            if (tint.len > 0) try w.writeAll(style.reset);
            try w.writeByte('\n');
        }
        i = hi;
    }
}

// ---

const t = std.testing;

fn render(old: []const u8, new: []const u8, context: usize) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    errdefer aw.deinit();
    try write(t.allocator, &aw.writer, "a", "b", old, new, context, .plain);
    return aw.toOwnedSlice();
}

test "no changes produces empty output" {
    const out = try render("x\ny\nz\n", "x\ny\nz\n", 3);
    defer t.allocator.free(out);
    try t.expectEqualStrings("", out);
}

test "pure append" {
    const out = try render("x\ny\n", "x\ny\nz\n", 3);
    defer t.allocator.free(out);
    const expected =
        "--- a\n" ++
        "+++ b\n" ++
        "@@ -1,2 +1,3 @@\n" ++
        " x\n" ++
        " y\n" ++
        "+z\n";
    try t.expectEqualStrings(expected, out);
}

test "insertion in middle with context" {
    const out = try render("x\ny\nz\n", "x\ny\nA\nB\nz\n", 1);
    defer t.allocator.free(out);
    const expected =
        "--- a\n" ++
        "+++ b\n" ++
        "@@ -2,2 +2,4 @@\n" ++
        " y\n" ++
        "+A\n" ++
        "+B\n" ++
        " z\n";
    try t.expectEqualStrings(expected, out);
}

test "deletion produces minus lines" {
    const out = try render("x\ny\nz\n", "x\nz\n", 3);
    defer t.allocator.free(out);
    const expected =
        "--- a\n" ++
        "+++ b\n" ++
        "@@ -1,3 +1,2 @@\n" ++
        " x\n" ++
        "-y\n" ++
        " z\n";
    try t.expectEqualStrings(expected, out);
}

test "insertion into empty file" {
    const out = try render("", "hello\n", 3);
    defer t.allocator.free(out);
    const expected =
        "--- a\n" ++
        "+++ b\n" ++
        "@@ -1,0 +1,1 @@\n" ++
        "+hello\n";
    try t.expectEqualStrings(expected, out);
}
