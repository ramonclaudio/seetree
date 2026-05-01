#!/usr/bin/env bash
# One-shot installer for seetree. Fetches the matching prebuilt binary
# from GitHub Releases, verifies its SHA-256, and drops it into
# $PREFIX/bin (default /usr/local).
#
#   curl -fsSL https://raw.githubusercontent.com/ramonclaudio/seetree/main/install.sh | bash
#   VERSION=v0.1.0 PREFIX=$HOME/.local bash install.sh
set -euo pipefail

REPO="${SEETREE_REPO:-ramonclaudio/seetree}"
VERSION="${VERSION:-latest}"
PREFIX="${PREFIX:-/usr/local}"

os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)
case "$os-$arch" in
  darwin-arm64)    target="aarch64-macos" ;;
  darwin-x86_64)   target="x86_64-macos" ;;
  linux-x86_64)    target="x86_64-linux-musl" ;;
  linux-aarch64)   target="aarch64-linux-musl" ;;
  *) echo "seetree: unsupported platform $os-$arch" >&2; exit 1 ;;
esac

if [ "$VERSION" = "latest" ]; then
  base="https://github.com/$REPO/releases/latest/download"
else
  base="https://github.com/$REPO/releases/download/$VERSION"
fi

if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -q "$1" -O "$2"; }
else
  echo "seetree: need curl or wget to download" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  echo "seetree: need sha256sum or shasum to verify download" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "downloading seetree-$target"
fetch "$base/seetree-$target" "$tmp/seetree"
fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS"

expected=$(awk -v f="seetree-$target" '($2 == f) || ($2 == "*"f) {print $1}' "$tmp/SHA256SUMS")
if [ -z "$expected" ]; then
  echo "seetree: no checksum entry for seetree-$target in SHA256SUMS" >&2
  exit 1
fi
actual=$(sha256 "$tmp/seetree")
if [ "$expected" != "$actual" ]; then
  echo "seetree: checksum mismatch for seetree-$target" >&2
  echo "  expected: $expected" >&2
  echo "  actual:   $actual" >&2
  exit 1
fi
echo "verified sha256: $actual"

chmod +x "$tmp/seetree"

dest="$PREFIX/bin/seetree"
if mkdir -p "$PREFIX/bin" 2>/dev/null && [ -w "$PREFIX/bin" ]; then
  install -m 755 "$tmp/seetree" "$dest"
else
  sudo mkdir -p "$PREFIX/bin"
  sudo install -m 755 "$tmp/seetree" "$dest"
fi

echo "installed $dest"

# Strip the macOS quarantine xattr so Gatekeeper doesn't block first run.
# `curl ... | bash` downloads tag the binary as quarantined; we already
# verified the sha256 above, so the user is opting in. xattr exits 1 if
# the attribute isn't there (e.g. on Linux), so swallow that.
if [ "$os" = "darwin" ] && command -v xattr >/dev/null 2>&1; then
  xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
fi

"$dest" --version

case ":$PATH:" in
  *":$PREFIX/bin:"*) ;;
  *) echo "warning: $PREFIX/bin is not on \$PATH; add it to use 'seetree' directly" >&2 ;;
esac
