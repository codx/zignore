const std = @import("std");
const Ctx = @import("../cli.zig").Ctx;

// `zignore completion <shell>`: print the bundled completion script for the
// named shell to stdout. The three scripts under completions/ are embedded
// at build time, so the binary is self-sufficient — no need for the repo or
// a Makefile target to be installed alongside it.
//
// Install patterns (one-liner per shell):
//   zignore completion fish | source                                    # ad-hoc
//   zignore completion fish > ~/.config/fish/completions/zignore.fish   # persistent
//   zignore completion bash > ~/.local/share/bash-completion/completions/zignore
//   zignore completion zsh  > ~/.zsh/completions/_zignore

const data = @import("completions_data");
const bash_completion = data.bash;
const zsh_completion = data.zsh;
const fish_completion = data.fish;

pub fn run(ctx: Ctx) !u8 {
    if (ctx.args.len == 0) {
        try ctx.stderr.writeAll(
            "zignore completion: missing shell name\n" ++
                "  usage: zignore completion <bash|zsh|fish>\n",
        );
        return 2;
    }
    if (ctx.args.len > 1) {
        try ctx.stderr.writeAll("zignore completion: too many arguments\n");
        return 2;
    }

    const shell = ctx.args[0];
    const script: []const u8 = blk: {
        if (std.mem.eql(u8, shell, "bash")) break :blk bash_completion;
        if (std.mem.eql(u8, shell, "zsh")) break :blk zsh_completion;
        if (std.mem.eql(u8, shell, "fish")) break :blk fish_completion;
        try ctx.stderr.print(
            "zignore completion: unknown shell '{s}' (try bash, zsh, or fish)\n",
            .{shell},
        );
        return 2;
    };

    try ctx.stdout.writeAll(script);
    return 0;
}

test "embedded scripts are non-empty and start with a header line" {
    try std.testing.expect(bash_completion.len > 0);
    try std.testing.expect(zsh_completion.len > 0);
    try std.testing.expect(fish_completion.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, bash_completion, "# zignore"));
    try std.testing.expect(std.mem.startsWith(u8, zsh_completion, "#compdef zignore"));
    try std.testing.expect(std.mem.startsWith(u8, fish_completion, "# zignore"));
}
