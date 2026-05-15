# zignore — bash completion
# This file is embedded into the zignore binary at build time. Install with:
#   zignore completion bash > ~/.local/share/bash-completion/completions/zignore
# Or source directly from ~/.bashrc:
#   source <(zignore completion bash)

_zignore() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local subcmds="add list ls show cat check-staged completion help"

    local sub="" i
    for ((i=1; i<COMP_CWORD; i++)); do
        case "${COMP_WORDS[i]}" in
            -*) ;;
            *)  sub="${COMP_WORDS[i]}"; break ;;
        esac
    done

    if [[ -z "$sub" ]]; then
        COMPREPLY=("$(compgen -W "$subcmds" -- "$cur")")
        return
    fi

    case "$sub" in
        add)
            if [[ "$cur" == --file=* ]]; then
                # Complete filesystem paths as the value of --file=<path>.
                local prefix="${cur#--file=}"
                local -a files
                mapfile -t files < <(compgen -f -- "$prefix")
                COMPREPLY=("${files[@]/#/--file=}")
                compopt -o filenames 2>/dev/null
            elif [[ "$cur" == -* ]]; then
                COMPREPLY=("$(compgen -W "--diff --header=none --header=fancy --file=" -- "$cur")")
            else
                COMPREPLY=("$(compgen -W "$(zignore list 2>/dev/null)" -- "$cur")")
            fi
            ;;
        show|cat)
            COMPREPLY=("$(compgen -W "$(zignore list 2>/dev/null)" -- "$cur")")
            ;;
        completion)
            COMPREPLY=("$(compgen -W "bash zsh fish" -- "$cur")")
            ;;
    esac
}
complete -F _zignore zignore
