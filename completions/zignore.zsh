#compdef zignore
# zignore — zsh completion
# This file is embedded into the zignore binary at build time. Install with:
#   zignore completion zsh > ~/.zsh/completions/_zignore
# Ensure that directory is on $fpath in .zshrc before `compinit`:
#   fpath=(~/.zsh/completions $fpath)

_zignore() {
    local context state state_descr line
    typeset -A opt_args

    _arguments -C \
        '1: :->subcommand' \
        '*:: :->args' \
        && return 0

    case $state in
        subcommand)
            local -a subcmds=(
                'add:Add template(s) to .gitignore'
                'list:List bundled template names'
                'ls:Alias for list'
                'show:Print a template content to stdout'
                'cat:Alias for show'
                'check-staged:Pre-commit: refuse staged paths matching any bundled template'
                'completion:Print shell completion script'
                'help:Show usage'
            )
            _describe 'subcommand' subcmds
            ;;
        args)
            case $words[1] in
                add)
                    _arguments \
                        '--diff[Preview the unified diff instead of writing]' \
                        '--header=[Section header style]:style:(fancy none)' \
                        '--file=[Write to <path> instead of .gitignore]:path:_files' \
                        '*: :_zignore_templates'
                    ;;
                show|cat)
                    _arguments '*: :_zignore_templates'
                    ;;
                completion)
                    _arguments '1:shell:(bash zsh fish)'
                    ;;
            esac
            ;;
    esac
}

_zignore_templates() {
    local -a templates
    templates=(${(f)"$(zignore list 2>/dev/null)"})
    _describe 'template' templates
}

_zignore "$@"
