# zignore

Quickly update `.gitignore`

```sh
zignore add zig @dev           # append Zig + editor/OS rules to .gitignore
zignore add                    # pick templates interactively (tv/fzf)
zignore add py                 # 'py' → Python (unique prefix)
zignore add --diff python      # preview the change instead of writing
```

The template collection is embedded in the binary at build time. `add`
deduplicates against existing patterns, refuses edits that would shadow
a `!negation`, and writes each template under its own `# Name` section.

## Install

**Nix flake:**

```sh
nix run github:codx/zignore -- add zig    # ad-hoc
nix profile install github:codx/zignore   # persistent
```

**From source**

```sh
zig build --release=safe
./zig-out/bin/zignore --help
```

**Shell completions** — the binary ships its own scripts:

```sh
zignore completion fish | source                                    # ad-hoc
zignore completion fish > ~/.config/fish/completions/zignore.fish   # persistent
zignore completion bash > ~/.local/share/bash-completion/completions/zignore
zignore completion zsh  > ~/.zsh/completions/_zignore
```

## Commands

| Command                | What it does                                                                                                                                                                                                                                          |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `add [name\|@group]…`  | Append template patterns to `.gitignore`. With no positional or an ambiguous prefix, opens a picker (`tv` or `fzf`) seeded with templates autodetected for the current project. A unique prefix is resolved automatically (e.g. `add py` → `Python`). |
| `list`                 | List available templates.                                                                                                                                                                                                                             |
| `show <name\|@group>…` | Print a template to stdout (raw).                                                                                                                                                                                                                     |
| `check-staged`         | Exit 1 if any staged path matches a high-confidence bundled template (core polluters like Node/Python, and autodetected languages) — use as a pre-commit hook.                                                                                        |
| `completion <shell>`   | Print the bundled completion script for `bash`, `zsh`, or `fish`.                                                                                                                                                                                     |

### `add` flags

- `--diff` — print a unified diff of the change instead of writing.
- `--file=<path>` — write to `<path>` (relative to the repo root) instead
  of `.gitignore`. E.g. `--file=.dockerignore`.
- `--header=none` — skip the `# <Name>` section header when creating a
  new section.

## Groups

Arguments starting with `@` expand to a named bundle of templates:

| Group  | Members                                                                                                                                                  |
| ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `@dev` | popular editors (VS Code, JetBrains, Vim, Emacs, Sublime, Zed, Cursor), OS files (macOS, Linux, Windows), and common dev cruft (Archives, Backup, Tags). |

## Picker

`zignore add` shells out to any command that reads template names on
stdin and writes selections on stdout. By default it tries `tv` then
`fzf` on `$PATH`, using `zignore add --diff` as the preview command.

Templates autodetected for the current project (from marker files like
`Cargo.toml` and source-extension counts) are emitted first, so they
surface at the top of the list. If you pass an ambiguous prefix (e.g.
`zignore add vis`), the picker opens pre-filtered with that query.

Override with `$ZIGNORE_PICKER`:

```sh
export ZIGNORE_PICKER='tv --preview-command="zignore add --diff {}"'
export ZIGNORE_PICKER='fzf --multi --reverse --preview "zignore add --diff {}"'
export ZIGNORE_PICKER='fzf -m'   # minimal, no preview
```

If no picker is found, `zignore list | <your-picker> | xargs zignore add`
works just as well.

## Pre-commit hook

`zignore check-staged` exits non-zero if any staged path matches a
high-confidence set of bundled templates, catching accidentally-staged
build artifacts before they land, intended to be able to use as a
global hook when working with many small projects:

```sh
# .git/hooks/pre-commit
#!/bin/sh
exec zignore check-staged
```

## Development

```sh
nix develop            # dev shell with zig, zls, git
make test build        # unit + fixture tests
make update-subtrees   # pull the latest github/gitignore
```

## License

zignore's source code is licensed under ISC (see [LICENSE](LICENSE)).

The `.gitignore` template patterns bundled with zignore — both the vendored
[github/gitignore](https://github.com/github/gitignore) set under
`vendor/github/gitignore/` and the internal templates under
`src/internal_templates/` — are released under
[CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/).

`.gitignore` files produced by `zignore add` (and any other command that
emits template patterns, e.g. `zignore show`) inherit the CC0 status of
those patterns: you can copy, modify, and redistribute the generated
`.gitignore` without attribution or restriction.
