#!/usr/bin/env bash
# glibcx installer — runs as: curl -fsSL https://raw.githubusercontent.com/dsecurity49/glibcx/main/install.sh | bash
set -euo pipefail

REPO="dsecurity49/glibcx"
INSTALL_DIR="${HOME}/bin"
BIN_NAME="glibcx"
RELEASES_API="https://api.github.com/repos/${REPO}/releases/latest"

# ── helpers ──────────────────────────────────────────────────────────────────
say()  { printf '\033[1;32m[glibcx]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[glibcx] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not found. Run: pkg install $1"; }

# ── sanity checks ─────────────────────────────────────────────────────────────
[[ "$(uname -o)" == "Android" ]] || die "glibcx is designed for Termux on Android."
[[ "$(uname -m)" == "aarch64" ]] || die "glibcx requires an AArch64 device."

need curl
need bash

# ── install prerequisites ─────────────────────────────────────────────────────
say "Installing prerequisites via pkg..."
pkg install -y glibc-runner patchelf binutils xxd file jq clang curl nodejs 2>/dev/null || \
    say "Some packages may already be installed — continuing."

# ── download glibcx binary from latest GitHub Release ────────────────────────
mkdir -p "$INSTALL_DIR"

say "Fetching latest release info..."
RELEASE_JSON="$(curl -fsSL "${RELEASES_API}")"
TAG="$(printf '%s' "$RELEASE_JSON" | grep '"tag_name"' | head -1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')"
ASSET_URL="$(printf '%s' "$RELEASE_JSON" | grep '"browser_download_url"' | grep '"glibcx"' | head -1 | grep -oE 'https://[^""]+')"

if [[ -z "$ASSET_URL" ]]; then
    die "Could not find glibcx binary asset in latest release. Check https://github.com/${REPO}/releases"
fi

say "Installing ${TAG}..."
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

curl -fsSL --progress-bar "$ASSET_URL" -o "$TMP"

# Verify it's a shell script (built monolithic bash binary)
if ! head -1 "$TMP" | grep -q "bash\|sh"; then
    die "Downloaded file does not look like a valid glibcx binary."
fi

install -m 755 "$TMP" "${INSTALL_DIR}/${BIN_NAME}"
say "Installed to ${INSTALL_DIR}/${BIN_NAME}"

# ── PATH setup ────────────────────────────────────────────────────────────────
PATH_LINE='export PATH="$HOME/bin:$PATH"'
for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
    [[ -f "$rc" ]] || continue
    if ! grep -qs 'HOME/bin' "$rc"; then
        printf '\n# added by glibcx installer\n%s\n' "$PATH_LINE" >> "$rc"
        say "Added ~/bin to PATH in $rc"
    fi
done

# ── run first-time setup ──────────────────────────────────────────────────────
say "Running glibcx setup..."
bash "${INSTALL_DIR}/${BIN_NAME}" setup

# ── done ──────────────────────────────────────────────────────────────────────
say "Done! glibcx is ready."
say ""
say "  Restart your shell or run:  source ~/.bashrc"
say "  Then try:  glibcx gh install sharkdp/fd"
