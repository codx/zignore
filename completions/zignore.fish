# zignore — fish completions
# This file is embedded into the zignore binary at build time. Install with:
#   zignore completion fish | source                                   # ad-hoc
#   zignore completion fish > ~/.config/fish/completions/zignore.fish  # persistent

# Subcommand position (no subcommand seen yet)
complete -c zignore -f -n __fish_use_subcommand -a add           -d "Add template(s) to .gitignore"
complete -c zignore -f -n __fish_use_subcommand -a list          -d "List bundled template names"
complete -c zignore -f -n __fish_use_subcommand -a ls            -d "Alias for list"
complete -c zignore -f -n __fish_use_subcommand -a show          -d "Print a template's content to stdout"
complete -c zignore -f -n __fish_use_subcommand -a cat           -d "Alias for show"
complete -c zignore -f -n __fish_use_subcommand -a check-staged  -d "Pre-commit: refuse staged paths matching any bundled template"
complete -c zignore -f -n __fish_use_subcommand -a completion    -d "Print shell completion script"
complete -c zignore -f -n __fish_use_subcommand -a help          -d "Show usage"

# `add` flags
complete -c zignore -f -n "__fish_seen_subcommand_from add" -l diff        -d "Preview the unified diff instead of writing"
complete -c zignore -f -n "__fish_seen_subcommand_from add" -l header=none -d "Skip the section header when creating a new section"
# --file=<path>: -r requires a value, -F completes filesystem paths for it
complete -c zignore -n "__fish_seen_subcommand_from add" -l file -r -F     -d "Write to <path> instead of .gitignore"

# `completion <shell>` — accept bash/zsh/fish
complete -c zignore -f -n "__fish_seen_subcommand_from completion" -a "bash zsh fish"

# Template-name completion for every subcommand that takes a template name.
# Source is `zignore list` (single source of truth, stays in sync with the
# binary).
complete -c zignore -f -n "__fish_seen_subcommand_from add show cat" -a "(zignore list)" -d Template
