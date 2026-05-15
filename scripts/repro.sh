#!/bin/sh
# Third-party rebuild + verify script.
#
# Usage: ./scripts/repro.sh v0.2.0
#
# Rebuilds the release tarball for your host triple and compares its sha256
# against the published SHA256SUMS from the matching GitHub Release. A match
# proves the published artifact was built from the same source you can read.
#
# Requires: zig 0.16.x, git, curl, GNU tar (gtar on macOS via `brew install
# gnu-tar`), and either sha256sum (linux) or shasum (macOS).

set -eu

OWNER=codx
REPO=zignore

tag="${1:-}"
test -n "$tag" || { echo "usage: $0 <tag>  (e.g. $0 v0.2.0)" >&2; exit 1; }
version="${tag#v}"

# ---- Detect host triple ----------------------------------------------------
os=$(uname -s)
arch=$(uname -m)
case "$os" in
    Linux)  os_tag=linux-musl ;;
    Darwin) os_tag=macos ;;
    *) echo "unsupported OS: $os" >&2; exit 1 ;;
esac
case "$arch" in
    x86_64|amd64)  arch_tag=x86_64 ;;
    aarch64|arm64) arch_tag=aarch64 ;;
    *) echo "unsupported arch: $arch" >&2; exit 1 ;;
esac
triple="${arch_tag}-${os_tag}"
asset="zignore-${version}-${triple}.tar.gz"

# ---- Tool detection --------------------------------------------------------
TAR=tar
if ! "$TAR" --version 2>/dev/null | grep -q GNU; then
    if command -v gtar >/dev/null 2>&1; then
        TAR=gtar
    else
        echo "GNU tar required (macOS: 'brew install gnu-tar', then re-run)." >&2
        exit 1
    fi
fi

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        echo "need sha256sum or shasum" >&2; exit 1
    fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# ---- 1. clone source at the tag --------------------------------------------
echo "==> cloning ${OWNER}/${REPO} at ${tag}"
git clone --depth 1 --branch "$tag" "https://github.com/${OWNER}/${REPO}.git" "${work}/src"
cd "${work}/src"

# ---- 2. cross-compile with the same deterministic flags as release.yml -----
SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct)
export SOURCE_DATE_EPOCH
echo "==> building ${triple} (SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH})"
zig build -Dtarget="${triple}" --release=safe -Dstrip=true

# ---- 3. package ------------------------------------------------------------
"$TAR" --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime="@${SOURCE_DATE_EPOCH}" --format=ustar \
    -cf - -C zig-out/bin zignore \
  | gzip -n -9 > "${work}/${asset}"

local_sha=$(sha256 "${work}/${asset}")

# ---- 4. fetch the published checksum + compare -----------------------------
echo "==> fetching published SHA256SUMS"
curl -fsSL -o "${work}/SHA256SUMS" \
    "https://github.com/${OWNER}/${REPO}/releases/download/${tag}/SHA256SUMS"

published_sha=$(grep -E "  ${asset}\$" "${work}/SHA256SUMS" | awk '{print $1}' || true)
test -n "$published_sha" \
    || { echo "${asset} not listed in published SHA256SUMS" >&2; exit 1; }

echo
echo "  local:     ${local_sha}"
echo "  published: ${published_sha}"

if [ "$local_sha" = "$published_sha" ]; then
    echo
    echo "OK — local rebuild matches published ${asset}"
else
    echo
    echo "MISMATCH — local rebuild differs from published ${asset}" >&2
    exit 1
fi
