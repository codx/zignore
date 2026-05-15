const std = @import("std");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args_z = try init.minimal.args.toSlice(arena);
    const args = try arena.alloc([]const u8, args_z.len);
    for (args_z, args) |src, *dst| dst.* = src;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file = std.Io.File.stdout();
    var sw = stdout_file.writer(init.io, &stdout_buf);
    const stdout = &sw.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_file = std.Io.File.stderr();
    var ew = stderr_file.writer(init.io, &stderr_buf);
    const stderr = &ew.interface;

    const code = cli.dispatch(.{
        .io = init.io,
        .gpa = init.gpa,
        .args = args,
        .environ = init.minimal.environ,
        .stdout = stdout,
        .stderr = stderr,
    }) catch |err| blk: {
        stderr.print("zignore: {s}\n", .{@errorName(err)}) catch {};
        break :blk @as(u8, 1);
    };

    stdout.flush() catch {};
    stderr.flush() catch {};
    return code;
}

test {
    _ = @import("ignorefile.zig");
    _ = @import("pattern.zig");
    _ = @import("templates.zig");
    _ = @import("diff.zig"); // unified-diff renderer, still used by `add --diff`
    _ = @import("groups.zig");
    _ = @import("detect.zig");
    _ = @import("cli/completion.zig"); // embedded completion-script smoke tests
}
