const std = @import("std");
const Ctx = @import("../cli.zig").Ctx;
const templates = @import("../templates.zig");

pub fn run(ctx: Ctx) !u8 {
    _ = ctx.args;
    var it = templates.iter();
    while (it.next()) |t| try ctx.stdout.print("{s}\n", .{t.name});
    return 0;
}
