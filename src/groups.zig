// Named bundles of template names, expanded by `add`/`diff`/`show` when an
// argument starts with `@`. A group is a thin alias: it never owns patterns
// of its own — it just maps to a list of bundled template names that go
// through the normal add pipeline (dedupe, shadow check, header).
//
// Members must be canonical template names (case as in vendor/*.gitignore);
// expansion fails loudly if any member is missing so a vendor rename can't
// silently drop a template.

const std = @import("std");
const templates = @import("templates.zig");

pub const Group = struct {
    name: []const u8, // without `@`
    description: []const u8,
    members: []const []const u8,
};

pub const all = [_]Group{
    .{
        .name = "dev",
        .description = "popular editors, OS files, and common dev cruft",
        .members = &.{
            // Editors
            "VisualStudioCode",
            "Vim",
            // OS
            "macOS",
            "Linux",
            "Windows",
            // Cross-cutting dev cruft
            "Archives",
            "Backup",
            "Tags",
        },
    },
};

pub fn isRef(arg: []const u8) bool {
    return arg.len > 1 and arg[0] == '@';
}

pub fn find(name_with_at: []const u8) ?Group {
    const name = if (isRef(name_with_at)) name_with_at[1..] else name_with_at;
    for (all) |g| {
        if (std.ascii.eqlIgnoreCase(g.name, name)) return g;
    }
    return null;
}

// Expand a `@group` reference into canonical template names. Caller owns
// the slice. Errors if the group is unknown or any member is missing from
// the bundled template set.
pub fn expand(
    gpa: std.mem.Allocator,
    name_with_at: []const u8,
) error{ UnknownGroup, MissingMember, OutOfMemory }![]templates.Template {
    const g = find(name_with_at) orelse return error.UnknownGroup;
    var out: std.ArrayList(templates.Template) = .empty;
    errdefer out.deinit(gpa);
    for (g.members) |m| {
        const t = templates.find(m) orelse return error.MissingMember;
        try out.append(gpa, t);
    }
    return out.toOwnedSlice(gpa);
}

pub const ResolveError = error{ UnknownGroup, MissingMember, UnknownTemplate, OutOfMemory };

pub const ResolveFailure = union(enum) {
    unknown_group: []const u8, // arg as passed, e.g. "@xyz"
    unknown_template: []const u8, // arg as passed
    missing_member: struct { group: []const u8, member: []const u8 },
};

// Resolve a list of `add`/`diff`/`show` positional args into a deduped list
// of canonical Templates. `@<group>` args expand to their members; bare names
// look up like before. Order matches first-seen-in-args order so the user
// can predict section ordering. On failure, fills `failure` and returns the
// error so the caller can write a tailored message.
pub fn resolve(
    gpa: std.mem.Allocator,
    args: []const []const u8,
    failure: *ResolveFailure,
) ResolveError![]templates.Template {
    var out: std.ArrayList(templates.Template) = .empty;
    errdefer out.deinit(gpa);

    var seen: std.StringHashMap(void) = .init(gpa);
    defer seen.deinit();

    for (args) |arg| {
        if (isRef(arg)) {
            const g = find(arg) orelse {
                failure.* = .{ .unknown_group = arg };
                return error.UnknownGroup;
            };
            for (g.members) |m| {
                const t = templates.find(m) orelse {
                    failure.* = .{ .missing_member = .{ .group = g.name, .member = m } };
                    return error.MissingMember;
                };
                const gop = try seen.getOrPut(t.name);
                if (!gop.found_existing) try out.append(gpa, t);
            }
        } else {
            const t = templates.find(arg) orelse {
                failure.* = .{ .unknown_template = arg };
                return error.UnknownTemplate;
            };
            const gop = try seen.getOrPut(t.name);
            if (!gop.found_existing) try out.append(gpa, t);
        }
    }

    return out.toOwnedSlice(gpa);
}

// Print a tailored error for a `resolve` failure and return the exit code
// the caller should propagate. `cmd` is the full command prefix used in
// messages, e.g. "zignore add". OutOfMemory is propagated to the caller.
pub fn printResolveFailure(
    stderr: *std.Io.Writer,
    cmd: []const u8,
    err: ResolveError,
    failure: ResolveFailure,
) !u8 {
    switch (err) {
        error.UnknownGroup => {
            try stderr.print("{s}: no such group: {s}\n", .{ cmd, failure.unknown_group });
            return 2;
        },
        error.UnknownTemplate => {
            try stderr.print("{s}: no such template: {s}\n", .{ cmd, failure.unknown_template });
            return 1;
        },
        error.MissingMember => {
            try stderr.print("{s}: group @{s}: missing template '{s}'\n", .{ cmd, failure.missing_member.group, failure.missing_member.member });
            return 2;
        },
        error.OutOfMemory => return error.OutOfMemory,
    }
}

test "isRef" {
    try std.testing.expect(isRef("@dev"));
    try std.testing.expect(!isRef("dev"));
    try std.testing.expect(!isRef("@"));
    try std.testing.expect(!isRef(""));
}

test "find @dev case-insensitive" {
    try std.testing.expect(find("@dev") != null);
    try std.testing.expect(find("@DEV") != null);
    try std.testing.expect(find("@nope") == null);
}

test "every @dev member resolves" {
    // Guards against vendor renames silently dropping a group member.
    const g = find("@dev").?;
    for (g.members) |m| {
        if (templates.find(m) == null) {
            std.debug.print("group @dev: missing template '{s}'\n", .{m});
            return error.TestFailed;
        }
    }
}
