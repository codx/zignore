const std = @import("std");
const Ctx = @import("../cli.zig").Ctx;
const templates = @import("../templates.zig");
const groups = @import("../groups.zig");

pub fn run(ctx: Ctx) !u8 {
    if (ctx.args.len == 0) {
        try ctx.stderr.writeAll("zignore show: expected one or more template names or @groups\n");
        return 2;
    }

    var failure: groups.ResolveFailure = undefined;
    const tmpls = groups.resolve(ctx.gpa, ctx.args, &failure) catch |err|
        return groups.printResolveFailure(ctx.stderr, "zignore show", err, failure);
    defer ctx.gpa.free(tmpls);

    for (tmpls) |t| {
        try ctx.stdout.writeAll(t.content);
        if (t.content.len == 0 or t.content[t.content.len - 1] != '\n')
            try ctx.stdout.writeAll("\n");
    }
    return 0;
}
