const std = @import("std");
const Ctx = @import("../cli.zig").Ctx;
const git = @import("../git.zig");
const templates = @import("../templates.zig");
const pattern = @import("../pattern.zig");
const groups = @import("../groups.zig");
const detect = @import("../detect.zig");

const core_gitignore = @embedFile("../internal_templates/check_staged_core.gitignore");

// `zignore check-staged`: pre-commit hook. Refuses commits whose staged
// additions are matched by a very restricted set of high-confidence templates:
// an internal core list (node_modules, __pycache__, etc.) and anything
// autodetected.
pub fn run(ctx: Ctx) !u8 {
    const repo_root = git.repoRoot(ctx.io, ctx.gpa) catch |err| switch (err) {
        error.NotAGitRepo => {
            try ctx.stderr.writeAll("zignore check-staged: not a git repository\n");
            return 2;
        },
        else => return err,
    };
    defer ctx.gpa.free(repo_root);

    const staged = git.stagedFiles(ctx.io, ctx.gpa) catch |err| {
        try ctx.stderr.print("zignore check-staged: git failed ({s})\n", .{@errorName(err)});
        return 2;
    };
    defer ctx.gpa.free(staged);

    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(ctx.gpa);
    var sit = git.iterPaths(staged);
    while (sit.next()) |p| try paths.append(ctx.gpa, p);
    if (paths.items.len == 0) return 0;

    var selected_templates: std.StringHashMap(templates.Template) = .init(ctx.gpa);
    defer selected_templates.deinit();

    // 1. Core conservative patterns
    try selected_templates.put("Core", .{ .name = "Core", .content = core_gitignore });

    // 2. Autodetected templates based on project content
    if (detect.run(ctx.io, ctx.gpa, repo_root)) |suggestions| {
        defer ctx.gpa.free(suggestions);
        for (suggestions) |s| {
            if (templates.find(s.template)) |t| try selected_templates.put(t.name, t);
        }
    } else |_| {}

    var compiled: std.ArrayList(pattern.PatternList) = .empty;
    defer {
        for (compiled.items) |*pl| pl.deinit();
        compiled.deinit(ctx.gpa);
    }

    var tit = selected_templates.iterator();
    while (tit.next()) |entry| {
        const t = entry.value_ptr.*;
        var pl = try pattern.compile(ctx.gpa, t.name, t.content);
        // Skip overlay templates (e.g. JENKINS_HOME) — they declare
        // "ignore everything, then re-include a few paths" and would
        // false-positive against any normal repo.
        if (isOverlay(&pl)) {
            pl.deinit();
            continue;
        }
        try compiled.append(ctx.gpa, pl);
    }

    const max_display = 3;
    var any = false;
    for (paths.items) |p| {
        var n_matched: usize = 0;
        for (compiled.items) |*pl| {
            if (!pathIgnored(pl, p)) continue;
            n_matched += 1;
            if (n_matched == 1) {
                if (!any) {
                    try ctx.stdout.writeAll("zignore: staged paths match bundled templates:\n");
                    any = true;
                }
                try ctx.stdout.print("  {s}  ({s}", .{ p, pl.source_name });
            } else if (n_matched <= max_display) {
                try ctx.stdout.print(", {s}", .{pl.source_name});
            }
        }
        if (n_matched == 0) continue;
        if (n_matched > max_display) {
            try ctx.stdout.print(", +{d} more", .{n_matched - max_display});
        }
        try ctx.stdout.writeAll(")\n");
    }
    if (!any) return 0;

    try ctx.stdout.writeAll(
        "\nThese look like build artifacts the templates know about.\n" ++
            "  Add a template: zignore add <name>\n" ++
            "  Bypass once:    git commit --no-verify\n",
    );
    return 1;
}

// An "overlay" template is one whose top-level intent is "ignore
// everything, then re-include a few paths" — JENKINS_HOME being the
// canonical example. Detect by the presence of a bare `*`, `/*`, or
// `**` pattern (post-compile, all three reduce to a body of `*` or
// `**`). Such a template matches every path in a normal repo, so we
// exclude it from the bundled-template check.
fn isOverlay(pl: *const pattern.PatternList) bool {
    for (pl.items.items) |p| {
        if (p.negate) continue;
        if (std.mem.eql(u8, p.body, "*")) return true;
        if (std.mem.eql(u8, p.body, "**")) return true;
    }
    return false;
}

// True if `path` would be ignored by `pl` per gitignore semantics: the
// path itself matches, OR any ancestor directory matches. Re-include
// semantics for descendants of an ignored ancestor are not modeled —
// pattern.zig's header explains why that's safe here.
fn pathIgnored(pl: *const pattern.PatternList, path: []const u8) bool {
    if (pattern.match(pl, path, false) == .ignored) return true;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') {
            if (pattern.match(pl, path[0..i], true) == .ignored) return true;
        }
    }
    return false;
}
