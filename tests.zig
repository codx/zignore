// Test entry point at project root so fixture @embedFile paths resolve
// to tests/fixtures/. Imports src/main.zig to pull in its module tests
// (pattern matcher, templates lookup, etc.) alongside the fixture tests.

const std = @import("std");
const ignorefile = @import("src/ignorefile.zig");

fn runFixture(comptime case: []const u8) !void {
    const before = @embedFile("tests/fixtures/" ++ case ++ "/before.gitignore");
    const template = @embedFile("tests/fixtures/" ++ case ++ "/template.gitignore");
    const header_raw = @embedFile("tests/fixtures/" ++ case ++ "/header");
    const header_name = std.mem.trim(u8, header_raw, " \t\r\n");
    const after = @embedFile("tests/fixtures/" ++ case ++ "/after.gitignore");

    const result = try ignorefile.add(std.testing.allocator, before, header_name, template, .{});
    switch (result) {
        .ok => |out| {
            defer std.testing.allocator.free(out);
            try std.testing.expectEqualStrings(after, out);
        },
        .shadowed => return error.UnexpectedShadow,
    }
}

fn runFixtureExpectShadow(comptime case: []const u8) !void {
    const before = @embedFile("tests/fixtures/" ++ case ++ "/before.gitignore");
    const template = @embedFile("tests/fixtures/" ++ case ++ "/template.gitignore");
    const header_raw = @embedFile("tests/fixtures/" ++ case ++ "/header");
    const header_name = std.mem.trim(u8, header_raw, " \t\r\n");

    const result = try ignorefile.add(std.testing.allocator, before, header_name, template, .{});
    switch (result) {
        .ok => |out| {
            std.testing.allocator.free(out);
            return error.ExpectedShadow;
        },
        .shadowed => {},
    }
}

test "fixture: add-to-empty" {
    try runFixture("add-to-empty");
}

test "fixture: append-to-existing" {
    try runFixture("append-to-existing");
}

test "fixture: dedup-existing" {
    try runFixture("dedup-existing");
}

test "fixture: bounded-by-sibling" {
    try runFixture("bounded-by-sibling");
}

test "fixture: bail-on-negation-shadow" {
    try runFixtureExpectShadow("bail-on-negation-shadow");
}

test "fixture: bail-on-dir-shadow" {
    try runFixtureExpectShadow("bail-on-dir-shadow");
}

test "fixture: idempotent-with-negation" {
    // Regression: re-applying a template that bundles its own `!negation`
    // must not self-shadow on the second run.
    try runFixture("idempotent-with-negation");
}

test "lenient header match: multi-token line is recognized" {
    const before = "# Python tooling notes\n*.pyc\n";
    const template = "__pycache__/\n";
    const result = try ignorefile.add(std.testing.allocator, before, "Python", template, .{});
    switch (result) {
        .ok => |out| {
            defer std.testing.allocator.free(out);
            // Patterns slot under the lenient header — no new section created.
            try std.testing.expectEqualStrings(
                "# Python tooling notes\n*.pyc\n__pycache__/\n",
                out,
            );
        },
        .shadowed => return error.UnexpectedShadow,
    }
}

test "strict header beats lenient when both present" {
    // A narrative `# Python tooling` appears first, but a canonical
    // `# === Python ===` lives below. The canonical one wins.
    const before =
        "# Python tooling — see wiki\nnotes.md\n\n# === Python ===\n*.pyc\n";
    const template = "__pycache__/\n";
    const result = try ignorefile.add(std.testing.allocator, before, "Python", template, .{});
    switch (result) {
        .ok => |out| {
            defer std.testing.allocator.free(out);
            try std.testing.expectEqualStrings(
                "# Python tooling — see wiki\nnotes.md\n\n# === Python ===\n*.pyc\n__pycache__/\n",
                out,
            );
        },
        .shadowed => return error.UnexpectedShadow,
    }
}

test "--header=none skips the header when creating a new section" {
    const before = "*.log\n";
    const template = "__pycache__/\n*.pyc\n";
    const result = try ignorefile.add(
        std.testing.allocator,
        before,
        "Python",
        template,
        .{ .header = .none },
    );
    switch (result) {
        .ok => |out| {
            defer std.testing.allocator.free(out);
            try std.testing.expectEqualStrings(
                "*.log\n\n__pycache__/\n*.pyc\n",
                out,
            );
        },
        .shadowed => return error.UnexpectedShadow,
    }
}

test "--header=none has no effect when section already exists" {
    const before = "# Python\n*.pyc\n";
    const template = "__pycache__/\n";
    const result = try ignorefile.add(
        std.testing.allocator,
        before,
        "Python",
        template,
        .{ .header = .none },
    );
    switch (result) {
        .ok => |out| {
            defer std.testing.allocator.free(out);
            try std.testing.expectEqualStrings(
                "# Python\n*.pyc\n__pycache__/\n",
                out,
            );
        },
        .shadowed => return error.UnexpectedShadow,
    }
}

test {
    // Pull in module-level tests from src/ (pattern matcher, etc.).
    _ = @import("src/main.zig");
}
