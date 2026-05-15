const std = @import("std");
const Ctx = @import("../cli.zig").Ctx;
const templates = @import("../templates.zig");
const groups = @import("../groups.zig");
const ignorefile = @import("../ignorefile.zig");
const git = @import("../git.zig");
const diff = @import("../diff.zig");
const picker = @import("picker.zig");
const detect = @import("../detect.zig");

// `zignore add`: append a template's patterns under a `# <Name>` section.
//
// Name resolution (per positional):
//   1. Exact (case-insensitive) match → use it.
//   2. Case-insensitive prefix matches exactly one template → use it.
//   3. Ambiguous or zero positionals → launch picker (with the typed prefix
//      as the picker's initial query, if any).
//   4. Zero matches → error.
//
// Multi-positional with an ambiguous prefix is rejected — mixing positional
// args with interactive selection is confusing. Pass an exact name, or run
// `zignore add` with no positionals for a picker over everything.
//
// `--diff` switches to preview mode: no write, prints a unified diff
// against the repo's current .gitignore. Outside a git repo, `--diff`
// prints the resolved template content(s) raw — useful for ad-hoc
// inspection and for the picker's preview pane in scratch dirs.

pub fn run(ctx: Ctx) !u8 {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(ctx.gpa);
    var opts: ignorefile.Options = .{};
    var diff_mode = false;
    var rel_path: []const u8 = ".gitignore";

    for (ctx.args) |arg| {
        if (std.mem.eql(u8, arg, "--diff")) {
            diff_mode = true;
        } else if (std.mem.eql(u8, arg, "--header=none")) {
            opts.header = .none;
        } else if (std.mem.eql(u8, arg, "--header=fancy")) {
            opts.header = .fancy;
        } else if (std.mem.startsWith(u8, arg, "--header=")) {
            try ctx.stderr.print("zignore add: --header expects 'fancy' or 'none', got '{s}'\n", .{arg["--header=".len..]});
            return 2;
        } else if (std.mem.startsWith(u8, arg, "--file=")) {
            const v = arg["--file=".len..];
            if (v.len == 0) {
                try ctx.stderr.writeAll("zignore add: --file= requires a path\n");
                return 2;
            }
            rel_path = v;
        } else if (arg.len > 0 and arg[0] == '-') {
            try ctx.stderr.print("zignore add: unknown flag '{s}'\n", .{arg});
            return 2;
        } else {
            try names.append(ctx.gpa, arg);
        }
    }

    // Resolve positional names. Substitutes prefix-matched templates in place,
    // and decides whether we need to spawn the picker. The function prints
    // its own error message before returning `AmbiguousPositional`.
    const resolved = resolveNames(ctx, &names) catch |err| switch (err) {
        error.AmbiguousPositional => return 2,
        else => return err,
    };
    defer ctx.gpa.free(resolved.picker_query);

    var picker_selections: ?picker.Result = null;
    defer if (picker_selections) |*r| r.deinit(ctx.gpa);

    var effective_args: []const []const u8 = names.items;
    if (resolved.use_picker) {
        const suggestions = collectSuggestions(ctx);
        defer ctx.gpa.free(suggestions);

        var result = picker.run(ctx, resolved.picker_query, suggestions) catch |err| {
            try ctx.stderr.print("zignore add: picker failed ({s})\n", .{@errorName(err)});
            return 2;
        };

        switch (result.status) {
            .canceled => {
                result.deinit(ctx.gpa);
                return 0;
            },
            .no_picker => {
                result.deinit(ctx.gpa);
                try ctx.stderr.writeAll(
                    "zignore add: no picker found.\n" ++
                        "  Install tv (television) or fzf, or set $ZIGNORE_PICKER to\n" ++
                        "  any command that reads names on stdin and writes selections\n" ++
                        "  on stdout (e.g. ZIGNORE_PICKER='sk --multi').\n" ++
                        "  Or pass a template name: `zignore list` shows what's available.\n",
                );
                return 2;
            },
            .picked => {
                if (result.items.len == 0) {
                    result.deinit(ctx.gpa);
                    return 0;
                }
                picker_selections = result;
                effective_args = result.items;
            },
        }
    }

    var failure: groups.ResolveFailure = undefined;
    const tmpls = groups.resolve(ctx.gpa, effective_args, &failure) catch |err|
        return groups.printResolveFailure(ctx.stderr, "zignore add", err, failure);
    defer ctx.gpa.free(tmpls);

    const repo_root = git.repoRoot(ctx.io, ctx.gpa) catch |err| switch (err) {
        error.NotAGitRepo => {
            if (diff_mode) return showRaw(ctx, tmpls);
            try ctx.stderr.writeAll("zignore add: not a git repository\n");
            return 2;
        },
        else => return err,
    };
    defer ctx.gpa.free(repo_root);

    const original = try ignorefile.readFile(ctx.io, ctx.gpa, repo_root, rel_path);
    defer ctx.gpa.free(original);
    var content = try ctx.gpa.dupe(u8, original);
    defer ctx.gpa.free(content);

    for (tmpls) |tmpl| {
        switch (try ignorefile.add(ctx.gpa, content, tmpl.name, tmpl.content, opts)) {
            .ok => |updated| {
                const changed = !std.mem.eql(u8, updated, content);
                ctx.gpa.free(content);
                content = updated;
                if (!diff_mode) {
                    const label: []const u8 = if (changed) "added" else "up to date";
                    try ctx.stdout.print("  {s}: {s}\n", .{ tmpl.name, label });
                }
            },
            .shadowed => |s| {
                const verb = if (diff_mode) "would shadow" else "refusing to add";
                try ctx.stderr.print(
                    "zignore add: {s} {s} `{s}` (pattern `{s}`)\n",
                    .{ tmpl.name, verb, s.negation_line, s.new_pattern },
                );
                if (!diff_mode) {
                    try ctx.stderr.writeAll("  Add the patterns by hand if you want this, or remove the negation first.\n");
                }
                return 2;
            },
        }
    }

    if (diff_mode) {
        if (std.mem.eql(u8, original, content)) {
            try ctx.stderr.writeAll("zignore add --diff: up to date — no changes\n");
            return 0;
        }
        const a_label = try std.fmt.allocPrint(ctx.gpa, "a/{s}", .{rel_path});
        defer ctx.gpa.free(a_label);
        const b_label = try std.fmt.allocPrint(ctx.gpa, "b/{s}", .{rel_path});
        defer ctx.gpa.free(b_label);
        try diff.write(ctx.gpa, ctx.stdout, a_label, b_label, original, content, 3, pickDiffStyle(ctx));
        return 0;
    }

    if (!std.mem.eql(u8, content, original)) {
        try ignorefile.writeFileAtomic(ctx.io, ctx.gpa, repo_root, rel_path, content);
    }
    return 0;
}

const Resolved = struct {
    use_picker: bool,
    /// Owned (possibly empty) string passed to the picker as `--input=`/`--query=`.
    /// Allocated on `ctx.gpa`.
    picker_query: []u8,
};

// Walks the positional list, replacing each entry with its canonical template
// name when the user typed a unique prefix. May reduce a single fuzzy arg to
// a picker invocation, or reject a multi-positional list that contains an
// ambiguous prefix.
fn resolveNames(ctx: Ctx, names: *std.ArrayList([]const u8)) !Resolved {
    const empty_query = try ctx.gpa.alloc(u8, 0);
    if (names.items.len == 0) return .{ .use_picker = true, .picker_query = empty_query };

    // Single positional: a fuzzy/ambiguous arg is a picker trigger (with the
    // typed arg as initial query). With multiple positionals we can't sensibly
    // intersperse a picker, so we error instead.
    var i: usize = 0;
    while (i < names.items.len) : (i += 1) {
        const arg = names.items[i];
        if (groups.isRef(arg)) continue;
        if (templates.find(arg) != null) continue;

        switch (templates.prefixMatches(arg)) {
            .none => continue, // let groups.resolve report the unknown template
            .one => |t| {
                if (!std.mem.eql(u8, t.name, arg)) {
                    try ctx.stderr.print("zignore add: '{s}' → {s}\n", .{ arg, t.name });
                }
                names.items[i] = t.name;
            },
            .many => {
                if (names.items.len > 1) {
                    ctx.gpa.free(empty_query);
                    try ctx.stderr.print(
                        "zignore add: '{s}' is ambiguous; pass an exact template name " ++
                            "(see `zignore list`) or run `zignore add` alone for a picker.\n",
                        .{arg},
                    );
                    return error.AmbiguousPositional;
                }
                // Single ambiguous positional → picker with the typed prefix
                // as the pre-filter. Hand ownership of the query buffer over.
                const query = try ctx.gpa.dupe(u8, arg);
                ctx.gpa.free(empty_query);
                return .{ .use_picker = true, .picker_query = query };
            },
        }
    }
    return .{ .use_picker = false, .picker_query = empty_query };
}

// Best-effort: detect templates that look relevant to the current project
// and return their canonical names so the picker can surface them first.
// Any failure (no git repo, walk error, OOM) yields an empty slice —
// autodetect is a nicety, not a hard requirement.
fn collectSuggestions(ctx: Ctx) []const []const u8 {
    const root_owned: ?[]u8 = git.repoRoot(ctx.io, ctx.gpa) catch null;
    defer if (root_owned) |r| ctx.gpa.free(r);
    const root: []const u8 = root_owned orelse ".";

    const suggestions = detect.run(ctx.io, ctx.gpa, root) catch return &.{};
    defer ctx.gpa.free(suggestions);
    if (suggestions.len == 0) return &.{};

    const names = ctx.gpa.alloc([]const u8, suggestions.len) catch return &.{};
    for (suggestions, names) |s, *n| n.* = s.template;
    return names;
}

fn showRaw(ctx: Ctx, tmpls: []const templates.Template) !u8 {
    for (tmpls) |t| {
        try ctx.stdout.writeAll(t.content);
        if (t.content.len == 0 or t.content[t.content.len - 1] != '\n')
            try ctx.stdout.writeAll("\n");
    }
    return 0;
}

// $NO_COLOR disables, $FORCE_COLOR / $CLICOLOR_FORCE force-enable,
// otherwise TTY autodetect.
fn pickDiffStyle(ctx: Ctx) diff.Style {
    if (ctx.environ.getPosix("NO_COLOR")) |v| {
        if (v.len > 0) return .plain;
    }
    if (ctx.environ.getPosix("FORCE_COLOR")) |v| {
        if (v.len > 0) return .ansi;
    }
    if (ctx.environ.getPosix("CLICOLOR_FORCE")) |v| {
        if (v.len > 0 and !(v.len == 1 and v[0] == '0')) return .ansi;
    }
    const out_file: std.Io.File = .stdout();
    const tty = out_file.isTty(ctx.io) catch false;
    return if (tty) .ansi else .plain;
}
