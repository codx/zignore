const std = @import("std");
const Ctx = @import("../cli.zig").Ctx;
const templates = @import("../templates.zig");

pub fn run(ctx: Ctx) !u8 {
    _ = ctx.args;

    const out_file: std.Io.File = .stdout();
    const tty = out_file.isTty(ctx.io) catch false;
    return if (tty) runPretty(ctx) else runPlain(ctx);
}

// One namespaced display name per line (e.g. `github/Python`). This is the
// machine-readable form the shell completions parse, so it is emitted whenever
// stdout is not a terminal — keep it byte-stable.
fn runPlain(ctx: Ctx) !u8 {
    var it = templates.iter();
    while (it.next()) |t| try ctx.stdout.print("{s}\n", .{templates.displayName(t)});
    return 0;
}

// Section heading for a namespace in the human-readable view, e.g.
// `Community (281)`. The curated set has no namespace and so no heading — its
// bare names lead the listing. Unknown namespaces fall back to the raw
// namespace string with just the count.
fn printHeading(w: *std.Io.Writer, namespace: []const u8, n: usize) !void {
    if (namespace.len == 0) return;
    if (std.mem.eql(u8, namespace, "github")) {
        try w.print("Community ({d})\n", .{n});
    } else {
        try w.print("{s} ({d})\n", .{ namespace, n });
    }
}

// Lower sorts first. Keeps the curated (namespace-less) set on top; anything
// unrecognised lands in the middle in first-seen order, with the community set
// last.
fn sectionRank(namespace: []const u8) u8 {
    if (namespace.len == 0) return 0;
    if (std.mem.eql(u8, namespace, "github")) return 2;
    return 1;
}

const Bucket = struct {
    namespace: []const u8,
    items: std.ArrayList(templates.Template),
};

// Grouped, multi-column view for terminals: a section per namespace with the
// bare template names laid out in columns, dropping the repeated `github/`
// prefix that makes the flat list hard to scan.
fn runPretty(ctx: Ctx) !u8 {
    const gpa = ctx.gpa;

    var buckets: std.ArrayList(Bucket) = .empty;
    defer {
        for (buckets.items) |*b| b.items.deinit(gpa);
        buckets.deinit(gpa);
    }

    var it = templates.iter();
    while (it.next()) |t| {
        const b = for (buckets.items) |*existing| {
            if (std.mem.eql(u8, existing.namespace, t.namespace)) break existing;
        } else blk: {
            try buckets.append(gpa, .{ .namespace = t.namespace, .items = .empty });
            break :blk &buckets.items[buckets.items.len - 1];
        };
        try b.items.append(gpa, t);
    }

    std.mem.sort(Bucket, buckets.items, {}, struct {
        fn lt(_: void, a: Bucket, c: Bucket) bool {
            return sectionRank(a.namespace) < sectionRank(c.namespace);
        }
    }.lt);

    const width = termWidth(ctx);
    const w = ctx.stdout;
    for (buckets.items, 0..) |b, i| {
        if (i != 0) try w.writeAll("\n");
        try printHeading(w, b.namespace, b.items.items.len);
        try printColumns(w, b.items.items, width);
    }
    try w.writeAll("\nAdd with: zignore add <name>… (or @<group>)\n");
    return 0;
}

const indent = 2;
const gutter = 2;

// Row-major column layout sized to `width`. Names are padded to the widest
// entry so columns align; falls back to a single column when nothing fits.
fn printColumns(w: *std.Io.Writer, items: []const templates.Template, width: usize) !void {
    var max_len: usize = 0;
    for (items) |t| max_len = @max(max_len, t.name.len);

    const col_width = max_len + gutter;
    const usable = if (width > indent) width - indent else 1;
    const ncols = @max(@as(usize, 1), usable / col_width);

    for (items, 0..) |t, i| {
        const col = i % ncols;
        if (col == 0) try w.splatByteAll(' ', indent);
        try w.writeAll(t.name);
        const last_in_row = col == ncols - 1 or i == items.len - 1;
        if (last_in_row) {
            try w.writeAll("\n");
        } else {
            try w.splatByteAll(' ', col_width - t.name.len);
        }
    }
}

// Terminal width from $COLUMNS, clamped to a sane floor; 80 when unset or
// unparseable. Avoids a per-OS TIOCGWINSZ ioctl for a value that only affects
// cosmetic wrapping.
fn termWidth(ctx: Ctx) usize {
    if (ctx.environ.getPosix("COLUMNS")) |v| {
        if (std.fmt.parseInt(usize, std.mem.trim(u8, v, " \t\r\n"), 10)) |n| {
            if (n >= 20) return n;
        } else |_| {}
    }
    return 80;
}
