#!/bin/sh
# zignore curl-pipe installer.
#
# Usage:
#   curl -fsSL https://codx.github.io/zignore/install.sh | sh
#
# Environment:
#   ZIGNORE_VERSION       Specific version to install (e.g. 0.2.0). Default: latest.
#   ZIGNORE_INSTALL_DIR   Install location. Default: $HOME/.local/bin.

set -eu

OWNER=codx
REPO=zignore

note() { printf 'install.sh: %s\n' "$*"; }
err()  { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

# ---- Detect platform -------------------------------------------------------
os=$(uname -s)
arch=$(uname -m)
case "$os" in
    Linux)  os_tag=linux-musl ;;
    Darwin) os_tag=macos ;;
    *)      err "unsupported OS: $os" ;;
esac
case "$arch" in
    x86_64|amd64)  arch_tag=x86_64 ;;
    aarch64|arm64) arch_tag=aarch64 ;;
    *)             err "unsupported arch: $arch" ;;
esac
triple="${arch_tag}-${os_tag}"

# ---- Resolve version -------------------------------------------------------
version="${ZIGNORE_VERSION:-}"
if [ -z "$version" ]; then
    note "resolving latest release..."
    version=$(curl -fsSL "https://api.github.com/repos/${OWNER}/${REPO}/releases/latest" \
        | sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v([^"]+)".*/\1/p' \
        | head -1)
    test -n "$version" || err "could not determine latest version"
fi

asset="zignore-${version}-${triple}.tar.gz"
base="https://github.com/${OWNER}/${REPO}/releases/download/v${version}"

# ---- Download + verify -----------------------------------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

note "downloading ${asset}"
curl -fsSL -o "${tmp}/${asset}"   "${base}/${asset}"
curl -fsSL -o "${tmp}/SHA256SUMS" "${base}/SHA256SUMS"

expected=$(grep -E "  ${asset}\$" "${tmp}/SHA256SUMS" | awk '{print $1}')
test -n "$expected" || err "asset not listed in SHA256SUMS: ${asset}"

if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "${tmp}/${asset}" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "${tmp}/${asset}" | awk '{print $1}')
else
    err "need sha256sum or shasum to verify checksum"
fi
test "$actual" = "$expected" \
    || err "checksum mismatch for ${asset} (expected ${expected}, got ${actual})"

# ---- Install ---------------------------------------------------------------
install_dir="${ZIGNORE_INSTALL_DIR:-"$HOME"/.local/bin}"
mkdir -p "$install_dir"
tar -xzf "${tmp}/${asset}" -C "$install_dir" zignore
chmod +x "${install_dir}/zignore"
note "installed zignore ${version} to ${install_dir}/zignore"

# ---- PATH hint -------------------------------------------------------------
case ":${PATH}:" in
    *":${install_dir}:"*) ;;
    *) note "${install_dir} is not in \$PATH — add this to your shell profile:"
       note "  export PATH=\"${install_dir}:\$PATH\""
       ;;
esac
