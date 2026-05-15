# Release plan

Status: **planning**. No tagged release exists yet. This document is the
strategy doc that the CI workflows, distribution wrappers, and channel
tap/plugin repos should be implemented against. It is the source of truth
when the actual rollout lands.

## Goals

A user on macOS, Linux, or Windows should be able to run:

```sh
nix run github:codx/zignore -- add zig
brew install codx/tap/zignore && zignore add zig
npx zignore add zig
bunx zignore add zig
uvx zignore add zig
mise x ubi:codx/zignore -- zignore add zig
docker run --rm -v "$PWD:/work" -w /work ghcr.io/codx/zignore add zig
curl -fsSL https://codx.github.io/zignore/install.sh | sh
```

…all resolving to the **same binary**, at the **same version**, with a
cryptographic checksum/signature trail back to the same GitHub Release
artifact. Everything else is a thin shim around that one source of truth.

---

## Foundation: tagged GitHub Releases with prebuilt binaries

Everything else depends on this. Implement first.

### Version source of truth

- `build.zig.zon`'s `.version` field is canonical.
- Git tags follow `v<version>` (e.g. `v0.2.0`).
- CI verifies on every PR that `build.zig.zon`'s version is **either** unchanged
  vs. `main`, **or** matches the package manifests in `dist/npm/package.json`,
  `dist/pypi/pyproject.toml`, and `flake.nix`'s `version` attribute. Drift
  between manifests is a CI failure.

### CI workflow

`.github/workflows/release.yml`, triggered on `v*` tag push.

Matrix:

| Target triple | Notes |
| --- | --- |
| `x86_64-linux-musl` | Static. One binary, no glibc bind. |
| `aarch64-linux-musl` | Static. ARM servers, Pi 4/5. |
| `x86_64-macos` | Intel macs. |
| `aarch64-macos` | Apple silicon. |

> **Windows is deferred.** `src/cli/{add,picker}.zig` call
> `std.process.Environ.getPosix`, which does not compile on Windows in
> Zig 0.16. Re-add `x86_64-windows` to the matrix (and reinstate the
> `.zip` packaging branch + Scoop bucket discussion below) once those
> call sites use a cross-platform env API.

For each target (deterministic flags — see [Reproducibility](#reproducibility)
for what each one is defending against):

```sh
export SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct)
zig build -Dtarget=<triple> --release=safe -Dstrip=true
tar --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime="@${SOURCE_DATE_EPOCH}" --format=ustar \
    -cf - -C zig-out/bin zignore \
  | gzip -n -9 > zignore-<version>-<triple>.tar.gz
```

After the matrix completes, a single `publish` job:

1. Downloads all matrix artifacts.
2. Generates `SHA256SUMS` over the tarballs.
3. Signs `SHA256SUMS` with [`cosign`](https://docs.sigstore.dev/) using
   GitHub OIDC (keyless — no private key to manage).
4. Generates per-artifact build provenance via
   [`actions/attest-build-provenance`](https://github.com/actions/attest-build-provenance);
   users verify with `gh attestation verify`.
5. Uploads via `softprops/action-gh-release` (pinned by full commit SHA)
   to the tag's GitHub Release, along with auto-generated release notes
   (initial: `git log` between tags; can adopt `git-cliff` later).

All third-party actions are pinned by 40-char commit SHA, not tag, with
Dependabot keeping them current. See [Supply-chain hardening](#supply-chain-hardening).

### Dry-run CI

`.github/workflows/ci.yml`, triggered on PRs. Runs the same build matrix
without uploading. Catches cross-compile breakage before tagging.

Also runs `zig build test` and `nix flake check`.

---

## Channel: Nix flake

Already works via `nix run github:codx/zignore` (builds from source
in a sandboxed Zig invocation).

Phase-1 work:

- Add `nix flake check` to the PR workflow above.
- Read `version` from `build.zig.zon` rather than hard-coding it in
  `flake.nix`. The drift check above relies on this being kept in sync.
- Future (phase 2): add a `packages.zignore-bin` output that consumes the
  GitHub Release tarball instead of compiling from source, for users who
  don't want a Zig toolchain pulled in.

---

## Channel: Homebrew tap

New repo: `codx/homebrew-tap` with `Formula/zignore.rb`.

Formula sketch:

```ruby
class Zignore < Formula
  desc "Quickly update gitignore"
  homepage "https://github.com/codx/zignore"
  version "0.2.0"
  license "MIT"  # confirm before tagging

  on_macos do
    on_arm do
      url "https://github.com/codx/zignore/releases/download/v#{version}/zignore-#{version}-aarch64-macos.tar.gz"
      sha256 "<filled in by bump>"
    end
    on_intel do
      url "..."
      sha256 "..."
    end
  end

  on_linux do
    on_arm do
      url "..."
      sha256 "..."
    end
    on_intel do
      url "..."
      sha256 "..."
    end
  end

  depends_on "git"  # runtime dep — mirrors flake.nix's wrapProgram

  def install
    bin.install "zignore"
  end

  test do
    system "#{bin}/zignore", "help"
  end
end
```

**Auto-bump**: on each release, the main repo's `release.yml` triggers a
`repository_dispatch` to `homebrew-tap`, which runs
[`dawidd6/action-homebrew-bump-formula`](https://github.com/dawidd6/action-homebrew-bump-formula)
to update version + sha256 fields.

Install for end users: `brew install codx/tap/zignore`.

---

## Channel: npm wrapper (enables `npx` and `bunx`)

New directory in main repo: `dist/npm/`.

Layout:

```
dist/npm/
├── package.json         # name, version (matches build.zig.zon), bin entry
├── README.md
├── install.js           # postinstall: download matching binary
└── bin/
    └── zignore.js       # thin shim; execs the downloaded binary
```

`install.js` runs at `npm install` time (and at `npx`/`bunx` resolve time):

1. Reads `process.platform` + `process.arch`; maps to a release-asset name.
2. Downloads `https://github.com/codx/zignore/releases/download/v<version>/<asset>.tar.gz`.
3. Verifies SHA256 against a snapshot of `SHA256SUMS` bundled in the package
   (cuts the download-then-checksum trust chain — the version on npm is
   immutable, so the snapshot is the trust anchor).
4. Extracts the binary into `dist/npm/bin/`.

`bin/zignore.js` is a 5-line shim that `child_process.spawnSync`s the
extracted binary, forwarding `process.argv.slice(2)` and exiting with the
child's exit code.

Publish workflow: after the release job uploads binaries, a `publish-npm`
job:

1. Updates `dist/npm/package.json` version + bundled `SHA256SUMS`.
2. `npm publish --provenance --access public`.

Package name: claim `zignore` on npm if available, else `@codx/zignore`.

---

## Channel: mise (`ubi` backend, no registry PR)

mise's built-in `ubi` backend installs any GitHub-Release-backed binary
by inferring the right asset from platform/arch and the filenames the
matrix already produces. No plugin code on our side, no registration in
an externally-owned repo.

End-user install — works the moment we cut a release:

```sh
# install pinned
mise install ubi:codx/zignore@latest

# or one-shot
mise x ubi:codx/zignore -- zignore add zig
```

Users can drop the `ubi:` prefix locally in their `mise.toml`:

```toml
[tools]
"ubi:codx/zignore" = "latest"
```

### What we are deliberately not doing

- **No PR to [`mise-plugins/registry`](https://github.com/mise-plugins/registry)**.
  That would shorten installs to `mise install zignore@latest`, but it
  requires registering in an externally-owned repo. The `ubi:` prefix
  above is the small cost of not depending on a third party.
- **No PR to [`aquaproj/aqua-registry`](https://github.com/aquaproj/aqua-registry)**.
  Same reason. aqua users who already use the tool can write their own
  registry entry pointing at our releases; we don't ship anything for
  them.
- **No classic `codx/asdf-zignore` repo**. asdf is in maintenance
  mode and mise is its modern successor. asdf holdouts can use the
  curl-pipe installer.

### eget (README mention, no work)

[`eget`](https://github.com/zyedidia/eget) downloads release binaries
with zero registration. Worth a line in the README as a no-setup
fallback: `eget codx/zignore`.

---

## Channel: curl-pipe installer

Standard for CLI tools (uv, rustup, deno, bun). Considered phase-1 table
stakes.

Layout: `install.sh` at repo root, served from a GitHub Pages branch at
`https://codx.github.io/zignore/install.sh`.

Script flow:

1. Detect `uname -s` (OS) and `uname -m` (arch); map to release-asset name.
2. `curl -fsSL` the matching tarball.
3. Verify SHA256 against `SHA256SUMS` from the same release.
4. Extract binary to `${ZIGNORE_INSTALL_DIR:-$HOME/.local/bin}`.
5. Print a hint about adding `~/.local/bin` to `$PATH` if it isn't already.

End-user one-liner:

```sh
curl -fsSL https://codx.github.io/zignore/install.sh | sh
```

---

## Channel: PyPI wheel (enables `uvx` and `pipx`)

`uvx` executes a Python entry point from a wheel. zignore is a single
native binary, so the wheel is a thin Python shim using the same
download-and-exec pattern as the npm wrapper.

Layout under `dist/pypi/`:

```
dist/pypi/
├── pyproject.toml       # name = "zignore", version mirrors build.zig.zon
└── src/zignore/
    ├── __init__.py
    └── __main__.py      # downloads + execs the binary
```

`__main__.py` mirrors `install.js` semantics but in Python. Cached binary
goes under `~/.cache/zignore/<version>/`.

Publish via GitHub Actions on tag push: `python -m build && twine upload`.
Use OIDC trusted publishing instead of an API token.

End users: `uvx zignore add zig`, `pipx install zignore`.

(Phase 2 — wait until npm wrapper is shaken out; reuse the same logic.)

---

## Channel: Docker image (GHCR)

Cheap to ship, useful for CI pipelines and sandboxed/airgapped
environments. Published as `ghcr.io/codx/zignore:v<version>` and
`:latest`.

`Dockerfile` at repo root:

```dockerfile
FROM alpine:3.20
RUN apk add --no-cache git
COPY zignore /usr/local/bin/zignore
ENTRYPOINT ["zignore"]
```

Base image is `alpine` + `git`. **Not** `scratch` or `distroless/static`
— zignore shells out to `git` at runtime (mirrors the flake's
`wrapProgram` with git in PATH). Final image is ~17 MB. Pin the alpine
tag (`alpine:3.20`, not `:latest`) for reproducibility.

(Open question for a later round: if the git runtime dep can be replaced
with a few syscalls — finding the repo root, writing files — the image
drops to <2 MB on `scratch` and removes the only non-source dep. Out of
scope for the initial release.)

Build step in `release.yml`, after the cross-compile matrix:

1. `docker buildx build --platform linux/amd64,linux/arm64 \
   --output type=image,rewrite-timestamp=true,push=true \
   --tag ghcr.io/codx/zignore:v${VERSION} \
   --tag ghcr.io/codx/zignore:latest .`
   — consumes the `*-linux-musl` binaries from the matrix.
2. `cosign sign ghcr.io/codx/zignore@<digest>` — same OIDC keyless
   flow as `SHA256SUMS`.
3. `actions/attest-build-provenance` with `subject-digest` for the
   image.

End-user one-liner (note the volume mount — zignore writes to cwd):

```sh
docker run --rm -v "$PWD:/work" -w /work \
  ghcr.io/codx/zignore add zig
```

Document the volume-mount caveat in the README. Real audience is CI
pipelines, not interactive use.

---

## Other channels worth considering

| Channel | Verdict | Notes |
| --- | --- | --- |
| **AUR (`zignore-bin`)** | Skip | Static musl tarball + curl-pipe + Docker covers Arch. Revisit on specific demand; `nfpm` can emit a `PKGBUILD`/`.deb`/`.rpm`/`.apk` from one YAML when that day comes. |
| **Native `.deb` / `.rpm` / `.apk`** | Skip | Same rationale — `nfpm` is the cheap path when demand appears. True `apt install` / `dnf install` needs a signed hosted repo, which is real infra not worth standing up speculatively. |
| **Scoop bucket** | Phase 3 if Windows demand exists | `codx/scoop-bucket` repo, manifest points at Windows release zip. |
| **MacPorts** | Skip | Small audience that already has Homebrew. |
| **Snap / Flatpak** | Skip | Heavy, opinionated; little value for a single-binary CLI tool. |
| **`go install` / `cargo install`** | Not applicable | Both require source in their native language. |
| **Direct download from Releases page** | Free | Falls out of the GitHub Releases work. Document in README. |

---

## Phased rollout

**Phase 1 — foundation** (blocks everything else):

1. `.github/workflows/release.yml` — cross-compile matrix with deterministic
   flags, sign (`cosign`), attest (`attest-build-provenance`), upload.
2. `.github/workflows/ci.yml` — PR build/test/cross-compile dry-run,
   version-drift check, reproducibility check (build twice, diff sha256).
3. `scripts/repro.sh` — third-party rebuild + verify script.
4. `install.sh` — curl-pipe installer.
5. Tag `v0.2.0` to validate end-to-end.

**Phase 2 — package managers and container**:

6. `dist/npm/` + publish workflow → `npx`, `bunx`.
7. `codx/homebrew-tap` + auto-bump → `brew install`.
8. README documents `mise x ubi:codx/zignore` (no registry PR — `ubi` backend is built into mise).
9. `Dockerfile` + GHCR push (signed + attested) → `docker run ghcr.io/codx/zignore`.

**Phase 3 — Python ecosystem and niche distros**:

10. `dist/pypi/` + publish workflow → `uvx`, `pipx`.
11. Scoop bucket (if Windows traction).

---

## Reproducibility

Goal: two independent runs from the same git tag produce byte-identical
binaries and tarballs. This makes the cosign signature on `SHA256SUMS`
verifiable by anyone who rebuilds from source — supply-chain attacks that
swap in a different binary become *detectable*, not just suspicious.

### Build-side knobs

- **Pin the Zig toolchain by exact version**. The setup action is pinned
  by full commit SHA; the `version` input is a specific Zig release. No
  moving channels.
- **Set `SOURCE_DATE_EPOCH`** at the top of the release job from the
  commit timestamp:
  ```sh
  export SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct)
  ```
  Consumed by `tar` and `gzip` for deterministic mtimes.
- **Strip debug info** via a `-Dstrip=true` option wired up in `build.zig`
  (`exe.root_module.strip = strip`). Debug sections can embed absolute
  build paths and toolchain identifiers that vary across runners.
- **Stick with `--release=safe`** (already planned). LLVM's
  `--release=fast` is more sensitive to host CPU feature differences.
- **No embedded build timestamps in the binary**: don't `@embedFile` a
  generated file with `date` / `git describe --dirty` output. If a runtime
  version string is needed, read it from `build.zig.zon` at compile time.

### Archive-side knobs

The `tar` invocation in the [CI workflow](#ci-workflow) snippet above is
already the deterministic form. Key flags: `--sort=name`, fixed
`--owner`/`--group`, `--mtime=@${SOURCE_DATE_EPOCH}`, `--format=ustar`,
piped through `gzip -n -9` (which omits the original filename + mtime
gzip header).

For Windows: standard `zip` embeds per-entry mtimes that are awkward to
override. Use `7z a -tzip -mtc=off` or `python -m zipfile` with explicitly
sorted entries.

### Verification job in CI

`.github/workflows/ci.yml` gains a `repro-check` job that, for one target
triple (start with `x86_64-linux-musl`):

1. Builds the tarball twice in fresh runners.
2. Compares `sha256sum` of the resulting artifact.
3. Fails the PR if they differ.

A stronger second pass — same build on a different host OS (nix sandbox
vs. ubuntu-latest) — defers to Phase 2.

### Third-party rebuild script

Ship `scripts/repro.sh` at repo root:

```sh
# Usage: ./scripts/repro.sh v0.2.0
# Rebuilds a release locally and verifies it matches the published SHA256SUMS.
```

Linked from README. For a small project this is the strongest trust
signal we can offer — anyone can independently confirm the published
binaries came from the published source.

### Docker image reproducibility

OCI images are harder to make byte-reproducible than tarballs (layer
mtimes, manifest ordering, BuildKit nondeterminism). Two tiers:

- **`docker buildx … --output rewrite-timestamp=true`** — normalizes
  layer timestamps. Acceptable for Phase 2. The binary inside is
  reproducible; the image layers are mostly reproducible.
- **apko + melange** (Chainguard) — declarative, byte-reproducible images
  built without Docker. Worth switching to if the image becomes a primary
  distribution channel. Skip for Phase 2.

---

## Supply-chain hardening

Layered on top of the `cosign` signing + `npm publish --provenance` + PyPI
OIDC trusted publishing that the release workflow already does:

1. **`actions/attest-build-provenance`** — generates a Sigstore-backed
   in-toto attestation per release artifact. Users verify with:
   ```sh
   gh attestation verify zignore-<ver>-<triple>.tar.gz \
     --repo codx/zignore
   ```
   ~10 lines of yaml; strictly better than nothing, and lighter weight
   than the full SLSA L3 generator.
2. **Pin every third-party Action by full commit SHA** (not tag):
   `softprops/action-gh-release@<40-char-sha>`, not `@v1`. Dependabot
   keeps them current. Mitigates tag-rewriting attacks on third-party
   actions.
3. **Scoped `permissions:` blocks per job**. Default the workflow to
   `permissions: {}` and opt in: `contents: write` only on the upload
   job; `id-token: write` only on jobs running cosign / OIDC publish.
4. **`syft` SBOM** (CycloneDX format) attached to each release as
   `zignore-<version>.cdx.json`. Cheap; mostly signaling for a tool with
   one runtime dep (`git`). Add when a downstream consumer asks.
5. **CODEOWNERS** on `.github/workflows/release.yml`,
   `.github/workflows/ci.yml`, `build.zig`, and `build.zig.zon` —
   require maintainer review for any change to the release path.
6. **Branch + tag protection**: only maintainers can push `v*` tags or
   merge to `main`.

Out of scope:

- **Full SLSA Level 3** via `slsa-framework/slsa-github-generator`. The
  isolated-builder requirement is heavy for the marginal additional
  assurance over attestations + cosign + reproducible builds. Revisit
  only if a downstream consumer explicitly needs L3.

---

## Versioning policy

- Pre-1.0: `0.MINOR.PATCH`. Minor = features, patch = fixes.
- All channels track the same version; CI fails if any channel's manifest
  drifts from `build.zig.zon`.
- `vendor/github/gitignore` subtree updates **do not** bump the version
  unless we want users to pull them; document the subtree pin commit in
  release notes.

---

## Critical files for the implementation phase

| File | Purpose |
| --- | --- |
| `.github/workflows/release.yml` | Cross-compile matrix + sign + upload. |
| `.github/workflows/ci.yml` | PR build/test + cross-compile dry-run + drift check. |
| `install.sh` | Curl-pipe installer; served via GitHub Pages. |
| `dist/npm/package.json` | npm package manifest. |
| `dist/npm/install.js` | Postinstall download + verify. |
| `dist/npm/bin/zignore.js` | Exec shim. |
| `dist/pypi/pyproject.toml` | PyPI package manifest (phase 2). |
| `dist/pypi/src/zignore/__main__.py` | Python download + exec shim. |
| `flake.nix` | Version pulled from `build.zig.zon` instead of hard-coded. |
| `build.zig` | `-Dstrip` option wired through; optional `releaseAll` step for local matrix builds. |
| `Dockerfile` | Alpine + git base for GHCR image. |
| `scripts/repro.sh` | Third-party rebuild + verify script. |

Separate repos to create — all under our own namespace; no PRs to
externally-owned registries:

- `codx/homebrew-tap` — formula + auto-bump workflow.
- A `gh-pages` branch on the main repo — `install.sh` hosting.
