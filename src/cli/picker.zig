const std = @import("std");
const Ctx = @import("../cli.zig").Ctx;
const templates = @import("../templates.zig");

// Interactive template picker. Used by `add` when invoked without positionals,
// or when a positional is a prefix of more than one template name.
//
// Picker resolution, in order:
//   1. $ZIGNORE_PICKER (run via `sh -c`, so flags + previews compose)
//   2. tv, then fzf on PATH (first found wins)
//   3. Return Status.no_picker — caller prints the template list and a hint
//
// An optional `initial_query` is passed through to the picker's pre-filter
// (`tv --input=…`, `fzf --query=…`). The query is sanitized before being
// spliced into the `sh -c` string — see `safeQuery`.

const PickerCmd = struct {
    name: []const u8,
    /// `sh -c` template. `{[exe]s}` is this binary's path so the picker's
    /// preview pane can call back into `zignore add --diff <name>`.
    /// `{[query]s}` is the pre-filter query (empty when no query).
    /// `{{}}` escapes to the picker's own `{}` placeholder for the entry.
    fmt: []const u8,
};

const candidates = [_]PickerCmd{
    .{
        .name = "tv",
        .fmt = "tv {[query]s}--preview-command='FORCE_COLOR=1 {[exe]s} add --diff {{}}' --preview-header='{{}}'",
    },
    .{
        .name = "fzf",
        .fmt = "fzf {[query]s}--ansi --multi --reverse --prompt='template> ' --preview='FORCE_COLOR=1 {[exe]s} add --diff {{}}'",
    },
};

pub const Status = enum { picked, canceled, no_picker };

pub const Result = struct {
    status: Status,
    /// Owned slice of canonical template names. Empty unless status == .picked.
    items: [][]const u8,

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        gpa.free(self.items);
    }
};

/// Run the picker over the full bundled template list. `initial_query` is the
/// arg the user typed (e.g. "vis") and is forwarded to the picker as a
/// pre-filter; pass "" for no pre-filter. `suggestions` lists canonical
/// template names to emit first (autodetected for the current project);
/// pass `&.{}` for none. Caller owns `result.items`.
pub fn run(ctx: Ctx, initial_query: []const u8, suggestions: []const []const u8) !Result {
    var cmd_buf: [1024]u8 = undefined;
    const cmd = resolvePicker(ctx, initial_query, &cmd_buf) orelse return .{
        .status = .no_picker,
        .items = &.{},
    };

    return runExternal(ctx, cmd, suggestions);
}

fn resolvePicker(ctx: Ctx, initial_query: []const u8, buf: []u8) ?[]const u8 {
    // $ZIGNORE_PICKER wins over auto-detect. The env override is opaque to us;
    // we don't try to splice the initial query into it (the user wrote that
    // command, so they own its arguments). The initial-query convenience is
    // for the built-in tv/fzf paths only.
    if (ctx.environ.getPosix("ZIGNORE_PICKER")) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (trimmed.len > 0) return trimmed;
    }

    const exe = std.process.executablePathAlloc(ctx.io, ctx.gpa) catch return null;
    defer ctx.gpa.free(exe);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var query_buf: [128]u8 = undefined;
    inline for (candidates) |c| {
        if (findInPath(ctx.io, ctx.environ, c.name, &path_buf) != null) {
            const q = formatQueryFragment(initial_query, &query_buf, c.name);
            return std.fmt.bufPrint(buf, c.fmt, .{ .exe = exe, .query = q }) catch return null;
        }
    }
    return null;
}

// Sanitize the initial-query string and format it as the picker-specific
// flag (e.g. `--input=py ` for tv, `--query=py ` for fzf). The trailing space
// keeps the fragment composable when slotted into the `sh -c` string.
//
// The accepted character set is `[A-Za-z0-9./_-]` — the full character set of
// every bundled template display name (verified by scanning vendor/github/gitignore
// and the internal template set). Anything else drops the pre-filter rather
// than risk shell metacharacters escaping the `sh -c` string.
fn formatQueryFragment(query: []const u8, buf: []u8, picker: []const u8) []const u8 {
    if (query.len == 0) return "";
    for (query) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-' or c == '/';
        if (!ok) return "";
    }
    const flag: []const u8 = if (std.mem.eql(u8, picker, "tv")) "--input=" else "--query=";
    return std.fmt.bufPrint(buf, "{s}{s} ", .{ flag, query }) catch "";
}

fn findInPath(io: std.Io, environ: std.process.Environ, name: []const u8, buf: []u8) ?[]const u8 {
    const path_var = environ.getPosix("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path_var, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, name }) catch continue;
        const f = std.Io.Dir.openFile(.cwd(), io, full, .{ .path_only = true }) catch continue;
        f.close(io);
        return full;
    }
    return null;
}

fn runExternal(ctx: Ctx, cmd: []const u8, suggestions: []const []const u8) !Result {
    const argv = [_][]const u8{ "/bin/sh", "-c", cmd };

    var child = try std.process.spawn(ctx.io, .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });

    {
        var sbuf: [4096]u8 = undefined;
        var sw = child.stdin.?.writer(ctx.io, &sbuf);
        const w = &sw.interface;

        // Suggested (autodetected) templates first, then everything else.
        // Both tv and fzf preserve input order, so detections surface at
        // the top of the picker. Dedup so a name doesn't appear twice.
        var seen: std.StringHashMap(void) = .init(ctx.gpa);
        defer seen.deinit();
        for (suggestions) |name| {
            const canonical = if (templates.find(name)) |t| templates.displayName(t) else name;
            const gop = try seen.getOrPut(canonical);
            if (gop.found_existing) continue;
            try w.print("{s}\n", .{canonical});
        }
        // Curated (namespace-less) templates next, then the community set. Both
        // tv and fzf preserve input order, so the curated names surface above
        // the much larger github/ list instead of being interleaved
        // alphabetically.
        for ([_]bool{ true, false }) |curated_pass| {
            var it = templates.iter();
            while (it.next()) |t| {
                if ((t.namespace.len == 0) != curated_pass) continue;
                const display = templates.displayName(t);
                const gop = try seen.getOrPut(display);
                if (gop.found_existing) continue;
                try w.print("{s}\n", .{display});
            }
        }
        try w.flush();
        child.stdin.?.close(ctx.io);
        child.stdin = null;
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ctx.gpa);
    {
        var rbuf: [4096]u8 = undefined;
        while (true) {
            const n = child.stdout.?.readStreaming(ctx.io, &.{&rbuf}) catch |e| switch (e) {
                error.EndOfStream => break,
                else => return e,
            };
            if (n == 0) break;
            try buf.appendSlice(ctx.gpa, rbuf[0..n]);
        }
        child.stdout.?.close(ctx.io);
        child.stdout = null;
    }

    const term = try child.wait(ctx.io);
    const exit_nonzero = !(term == .exited and term.exited == 0);

    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(ctx.gpa);
    var lit = std.mem.tokenizeScalar(u8, buf.items, '\n');
    while (lit.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        // Re-canonicalize so we own a slice into embedded template data
        // (which outlives buf), and so case-insensitive matches still work.
        if (templates.find(line)) |t| try names.append(ctx.gpa, t.name);
    }
    const owned = try names.toOwnedSlice(ctx.gpa);
    // Non-zero exit with no selections is a cancel (fzf returns 130 on Esc).
    // Non-zero exit *with* selections: honor the selections.
    const canceled = exit_nonzero and owned.len == 0;
    return .{
        .status = if (canceled) .canceled else .picked,
        .items = owned,
    };
}
