const std = @import("std");

pub const Error = error{
    NotAGitRepo,
    GitFailed,
} || std.process.RunError || std.mem.Allocator.Error;

// Run `git rev-parse --show-toplevel`. Caller owns result.
pub fn repoRoot(io: std.Io, gpa: std.mem.Allocator) Error![]u8 {
    const r = try run(io, gpa, &.{ "git", "rev-parse", "--show-toplevel" });
    defer gpa.free(r.stderr);
    if (!ok(r.term)) {
        gpa.free(r.stdout);
        return Error.NotAGitRepo;
    }
    return trimRight(gpa, r.stdout);
}

pub fn stagedFiles(io: std.Io, gpa: std.mem.Allocator) Error![]u8 {
    const r = try run(io, gpa, &.{ "git", "diff", "--cached", "--name-only", "-z", "--diff-filter=ACMR" });
    defer gpa.free(r.stderr);
    if (!ok(r.term)) {
        gpa.free(r.stdout);
        return Error.GitFailed;
    }
    return r.stdout;
}

// Iterate the NUL-separated paths in a buffer returned by the functions
// above. Empty entries are skipped (so a trailing separator is fine).
pub fn iterPaths(buf: []const u8) std.mem.TokenIterator(u8, .scalar) {
    return std.mem.tokenizeScalar(u8, buf, 0);
}

fn run(io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(gpa, io, .{ .argv = argv });
}

fn ok(term: std.process.Child.Term) bool {
    return term == .exited and term.exited == 0;
}

fn trimRight(gpa: std.mem.Allocator, s: []u8) ![]u8 {
    var end = s.len;
    while (end > 0 and (s[end - 1] == '\n' or s[end - 1] == '\r')) end -= 1;
    const out = try gpa.alloc(u8, end);
    @memcpy(out, s[0..end]);
    gpa.free(s);
    return out;
}
