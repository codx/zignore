const std = @import("std");
const data = @import("templates_data");

pub const Template = data.Template;

// Conservative, very-low-false-positive polluter baseline for `check-staged`.
// Deliberately not part of the user-facing template set (`all`), so it never
// shows up in `list` or the interactive picker.
pub const check_staged_core: []const u8 = data.check_staged_core;

pub fn count() usize {
    return data.all.len;
}

pub fn at(i: usize) Template {
    return data.all[i];
}

pub fn iter() Iterator {
    return .{ .i = 0 };
}

pub fn displayName(t: Template) []const u8 {
    return t.display_name;
}

pub const Iterator = struct {
    i: usize,

    pub fn next(self: *Iterator) ?Template {
        if (self.i >= data.all.len) return null;
        const t = data.all[self.i];
        self.i += 1;
        return t;
    }
};

// Case-insensitive lookup. Accepts either the short name (`Python`) or the
// namespaced display name (`github/Python`) and returns the canonical
// Template (with original capitalization) so we can render markers and report
// names consistently.
pub fn find(name: []const u8) ?Template {
    for (data.all) |t| {
        if (std.ascii.eqlIgnoreCase(t.name, name)) return t;
        if (std.ascii.eqlIgnoreCase(t.display_name, name)) return t;
    }
    return null;
}

pub const PrefixMatch = union(enum) {
    none,
    one: Template,
    many,
};

// Case-insensitive prefix match. An exact match is reported as `.one` too —
// callers that distinguish exact vs. partial should call `find` first.
//
// Empty `name` is treated as `.many` so a bare invocation doesn't auto-select
// the first template.
pub fn prefixMatches(name: []const u8) PrefixMatch {
    if (name.len == 0) return .many;
    var hit: ?Template = null;
    for (data.all) |t| {
        if (!std.ascii.startsWithIgnoreCase(t.name, name) and !std.ascii.startsWithIgnoreCase(t.display_name, name)) continue;
        if (hit) |_| return .many;
        hit = t;
    }
    return if (hit) |t| .{ .one = t } else .none;
}

test "find is case-insensitive" {
    // Smoke test only — assumes templates/ has at least one entry.
    if (data.all.len == 0) return error.SkipZigTest;
    const first = data.all[0];
    const found = find(first.name) orelse return error.TestFailed;
    try std.testing.expectEqualStrings(first.name, found.name);
}

test "find accepts namespaced aliases" {
    if (data.all.len == 0) return error.SkipZigTest;
    const first = data.all[0];
    const found = find(first.display_name) orelse return error.TestFailed;
    try std.testing.expectEqualStrings(first.name, found.name);
}

test "prefixMatches: unique prefix" {
    // `php` is unique to the curated set (no `github/PHP`), so it resolves
    // to exactly one template.
    switch (prefixMatches("php")) {
        .one => |t| try std.testing.expectEqualStrings("PHP", t.name),
        .none, .many => return error.TestFailed,
    }
}

test "prefixMatches: namespaced prefix" {
    switch (prefixMatches("github/py")) {
        .one => |t| try std.testing.expectEqualStrings("Python", t.name),
        .none, .many => return error.TestFailed,
    }
}

test "prefixMatches: ambiguous prefix" {
    // `py` matches both the curated `Python` and `github/Python`.
    try std.testing.expect(prefixMatches("py") == .many);
}

test "prefixMatches: no candidates" {
    try std.testing.expect(prefixMatches("zzzz-not-a-real-template") == .none);
}

test "prefixMatches: empty" {
    try std.testing.expect(prefixMatches("") == .many);
}
