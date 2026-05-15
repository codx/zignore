// Best-effort autodetection of languages/frameworks used in a directory.
// Walks up to `max_depth` levels, skipping directories that are noisy or
// already excluded by convention (node_modules, target, .git, ...), and
// reports a deduped list of bundled template names that match.
//
// Two signal types:
//   * Marker files (Cargo.toml, package.json, go.mod, ...): single hit is
//     enough — anchored to repo root for confidence.
//   * Extension counts (.rs, .py, .ts, ...): require N>=ext_threshold to
//     avoid one stray file dragging in a whole template.
//
// Output is ordered: markers in declaration order, then extension hits
// sorted by descending count. Names are canonical template names, so
// `zignore add` / the picker can consume them directly.

const std = @import("std");
const templates = @import("templates.zig");

pub const max_depth: u8 = 4;
pub const ext_threshold: u32 = 3;

const MarkerRule = struct {
    file: []const u8,
    template: []const u8,
};

// Only matched at the repo root (depth 0). Order is the output order when
// multiple markers hit.
const markers = [_]MarkerRule{
    .{ .file = "Cargo.toml", .template = "Rust" },
    .{ .file = "go.mod", .template = "Go" },
    .{ .file = "package.json", .template = "Node" },
    .{ .file = "pyproject.toml", .template = "Python" },
    .{ .file = "requirements.txt", .template = "Python" },
    .{ .file = "Pipfile", .template = "Python" },
    .{ .file = "setup.py", .template = "Python" },
    .{ .file = "Gemfile", .template = "Ruby" },
    .{ .file = "pom.xml", .template = "Maven" },
    .{ .file = "build.gradle", .template = "Gradle" },
    .{ .file = "build.gradle.kts", .template = "Gradle" },
    .{ .file = "mix.exs", .template = "Elixir" },
    .{ .file = "Package.swift", .template = "Swift" },
    .{ .file = "CMakeLists.txt", .template = "CMake" },
    .{ .file = "build.zig", .template = "Zig" },
    .{ .file = "composer.json", .template = "Composer" },
    .{ .file = "pubspec.yaml", .template = "Dart" },
    .{ .file = "Cargo.lock", .template = "Rust" },
    .{ .file = "yarn.lock", .template = "Node" },
    .{ .file = "pnpm-lock.yaml", .template = "Node" },
    .{ .file = "stack.yaml", .template = "Haskell" },
    .{ .file = "dune-project", .template = "OCaml" },
};

const ExtRule = struct {
    ext: []const u8,
    template: []const u8,
};

const ext_rules = [_]ExtRule{
    .{ .ext = ".rs", .template = "Rust" },
    .{ .ext = ".py", .template = "Python" },
    .{ .ext = ".go", .template = "Go" },
    .{ .ext = ".zig", .template = "Zig" },
    .{ .ext = ".ts", .template = "Node" },
    .{ .ext = ".tsx", .template = "Node" },
    .{ .ext = ".js", .template = "Node" },
    .{ .ext = ".jsx", .template = "Node" },
    .{ .ext = ".rb", .template = "Ruby" },
    .{ .ext = ".java", .template = "Java" },
    .{ .ext = ".kt", .template = "Java" },
    .{ .ext = ".swift", .template = "Swift" },
    .{ .ext = ".ex", .template = "Elixir" },
    .{ .ext = ".exs", .template = "Elixir" },
    .{ .ext = ".dart", .template = "Dart" },
    .{ .ext = ".c", .template = "C" },
    .{ .ext = ".h", .template = "C" },
    .{ .ext = ".cpp", .template = "C++" },
    .{ .ext = ".hpp", .template = "C++" },
    .{ .ext = ".cc", .template = "C++" },
    .{ .ext = ".cs", .template = "VisualStudio" },
    .{ .ext = ".lua", .template = "Lua" },
    .{ .ext = ".hs", .template = "Haskell" },
    .{ .ext = ".ml", .template = "OCaml" },
    .{ .ext = ".scala", .template = "Scala" },
    .{ .ext = ".clj", .template = "Clojure" },
    .{ .ext = ".nim", .template = "Nim" },
    .{ .ext = ".cr", .template = "Crystal" },
    .{ .ext = ".erl", .template = "Erlang" },
};

// Directories we never descend into: VCS metadata, output dirs, vendored
// deps that are themselves gitignored. Matched as the entry's basename.
const skip_dirs = [_][]const u8{
    ".git",
    ".hg",
    ".svn",
    "node_modules",
    "target",
    "dist",
    "build",
    "out",
    "zig-out",
    "zig-cache",
    ".zig-cache",
    ".venv",
    "venv",
    "__pycache__",
    ".tox",
    ".cache",
    ".idea",
    ".vscode",
    "vendor",
    "Pods",
    "DerivedData",
};

pub const Suggestion = struct {
    template: []const u8, // canonical name (borrowed from bundled data)
    reason: Reason,
};

pub const Reason = union(enum) {
    marker: []const u8, // filename that matched (borrowed from markers[])
    extension: struct { ext: []const u8, count: u32 },
};

// Caller owns the returned slice. Walks `root_path` (relative or absolute).
pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    root_path: []const u8,
) ![]Suggestion {
    var root = try std.Io.Dir.openDir(.cwd(), io, root_path, .{ .iterate = true });
    defer root.close(io);

    var ext_counts: std.StringHashMap(u32) = .init(gpa);
    defer ext_counts.deinit();

    var out: std.ArrayList(Suggestion) = .empty;
    errdefer out.deinit(gpa);

    var hit: std.StringHashMap(void) = .init(gpa);
    defer hit.deinit();

    // Pass 1: marker files at root, in declaration order.
    for (markers) |m| {
        const f = root.openFile(io, m.file, .{ .path_only = true }) catch continue;
        f.close(io);
        if (templates.find(m.template)) |t| {
            const gop = try hit.getOrPut(t.name);
            if (!gop.found_existing) {
                try out.append(gpa, .{ .template = t.name, .reason = .{ .marker = m.file } });
            }
        }
    }

    // Pass 2: extension counts via recursive walk.
    try walk(io, gpa, &root, 0, &ext_counts);

    // Emit extension suggestions sorted by descending count.
    var ext_hits: std.ArrayList(Suggestion) = .empty;
    defer ext_hits.deinit(gpa);

    for (ext_rules) |r| {
        const n = ext_counts.get(r.ext) orelse 0;
        if (n < ext_threshold) continue;
        const t = templates.find(r.template) orelse continue;
        const gop = try hit.getOrPut(t.name);
        if (gop.found_existing) continue;
        try ext_hits.append(gpa, .{
            .template = t.name,
            .reason = .{ .extension = .{ .ext = r.ext, .count = n } },
        });
    }

    std.mem.sort(Suggestion, ext_hits.items, {}, struct {
        fn lt(_: void, a: Suggestion, b: Suggestion) bool {
            return a.reason.extension.count > b.reason.extension.count;
        }
    }.lt);

    try out.appendSlice(gpa, ext_hits.items);
    return out.toOwnedSlice(gpa);
}

fn walk(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: *std.Io.Dir,
    depth: u8,
    ext_counts: *std.StringHashMap(u32),
) !void {
    var idir = dir.openDir(io, ".", .{ .iterate = true }) catch return;
    defer idir.close(io);

    var it = idir.iterate();
    while (it.next(io) catch |err| {
        std.log.warn("zignore detect: iterate at depth {d}: {s}", .{ depth, @errorName(err) });
        return;
    }) |entry| {
        switch (entry.kind) {
            .file => {
                if (extOf(entry.name)) |e| {
                    const gop = try ext_counts.getOrPut(e);
                    if (gop.found_existing) {
                        gop.value_ptr.* += 1;
                    } else {
                        gop.value_ptr.* = 1;
                    }
                }
            },
            .directory => {
                if (depth + 1 >= max_depth) continue;
                if (shouldSkip(entry.name)) continue;
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer sub.close(io);
                try walk(io, gpa, &sub, depth + 1, ext_counts);
            },
            else => {},
        }
    }
}

fn shouldSkip(name: []const u8) bool {
    if (name.len > 0 and name[0] == '.') {
        // Skip dotted dirs by default — most are caches or VCS metadata. The
        // explicit allowlist below is small enough to grow as needed.
        for (skip_dirs) |d| if (std.mem.eql(u8, d, name)) return true;
        return true;
    }
    for (skip_dirs) |d| if (std.mem.eql(u8, d, name)) return true;
    return false;
}

// Returns a slice borrowed from one of the ext_rules entries so map keys
// have a stable lifetime. nil if the file has no extension we care about.
fn extOf(name: []const u8) ?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    if (dot == 0) return null;
    const ext = name[dot..];
    for (ext_rules) |r| {
        if (std.mem.eql(u8, r.ext, ext)) return r.ext;
    }
    return null;
}

test "extOf canonicalizes to rule slice" {
    try std.testing.expect(extOf("foo") == null);
    try std.testing.expect(extOf(".hidden") == null);
    const e = extOf("main.zig") orelse return error.TestFailed;
    try std.testing.expectEqualStrings(".zig", e);
}

test "shouldSkip" {
    try std.testing.expect(shouldSkip(".git"));
    try std.testing.expect(shouldSkip("node_modules"));
    try std.testing.expect(shouldSkip(".hidden"));
    try std.testing.expect(!shouldSkip("src"));
}
