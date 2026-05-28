const std = @import("std");
const add_cmd = @import("cli/add.zig");
const list_cmd = @import("cli/list.zig");
const check_cmd = @import("cli/check_staged.zig");
const show_cmd = @import("cli/show.zig");
const completion_cmd = @import("cli/completion.zig");

const Writer = std.Io.Writer;

pub const Ctx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    args: []const []const u8, // includes argv[0]
    environ: std.process.Environ,
    stdout: *Writer,
    stderr: *Writer,

    pub fn withArgs(self: Ctx, args: []const []const u8) Ctx {
        return .{
            .io = self.io,
            .gpa = self.gpa,
            .args = args,
            .environ = self.environ,
            .stdout = self.stdout,
            .stderr = self.stderr,
        };
    }
};

const usage_text =
    \\zignore — quickly update gitignore
    \\
    \\Usage:
    \\  zignore <command> [args]
    \\
    \\Commands:
    \\  add [name|@group]…    append template patterns to .gitignore;
    \\                        with no name or an ambiguous prefix, picks
    \\                        interactively (tv/fzf)
    \\  list                  list available templates (`github/...`, `internal/...`)
    \\  show <name|@group>…   print a template to stdout
    \\  check-staged          exit 1 if staged paths match a bundled template
    \\  completion <shell>    print shell completions (bash | zsh | fish)
    \\  help                  show this help
    \\
    \\Flags:
    \\  add  --diff           preview the diff instead of writing
    \\       --file=<path>    write to <path> (e.g. .dockerignore)
    \\       --header=none    skip the `# <Name>` section header
    \\
    \\Groups (expand with `@<name>`):
    \\  @dev                  editors, OS files, common dev cruft
    \\
    \\Picker: set $ZIGNORE_PICKER to any command reading names on stdin
    \\and writing selections on stdout. Defaults to tv → fzf on $PATH.
    \\
    \\See README.md for details.
    \\
;

pub fn dispatch(ctx: Ctx) !u8 {
    if (ctx.args.len < 2) {
        try ctx.stderr.writeAll(usage_text);
        return 2;
    }
    const cmd = ctx.args[1];
    const sub = ctx.withArgs(ctx.args[2..]);

    if (eq(cmd, "help") or eq(cmd, "--help") or eq(cmd, "-h")) {
        try ctx.stdout.writeAll(usage_text);
        return 0;
    }
    if (eq(cmd, "add")) return add_cmd.run(sub);
    if (eq(cmd, "list") or eq(cmd, "ls")) return list_cmd.run(sub);
    if (eq(cmd, "show") or eq(cmd, "cat")) return show_cmd.run(sub);
    if (eq(cmd, "check-staged")) return check_cmd.run(sub);
    if (eq(cmd, "completion")) return completion_cmd.run(sub);

    try ctx.stderr.print("zignore: unknown command '{s}'\n\n", .{cmd});
    try ctx.stderr.writeAll(usage_text);
    return 2;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
