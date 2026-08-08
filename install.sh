#!/usr/bin/env bash
# glibcx installer — runs as: curl -fsSL https://raw.githubusercontent.com/dsecurity49/glibcx/main/install.sh | bash
set -euo pipefail

REPO="dsecurity49/glibcx"
INSTALL_DIR="${HOME}/bin"
BIN_NAME="glibcx"
RELEASES_API="https://api.github.com/repos/${REPO}/releases/latest"

FORCE=0
for arg in "$@"; do
    if [[ "$arg" == "--force" ]]; then
        FORCE=1
    fi
done

# ── helpers ──────────────────────────────────────────────────────────────────
say()  { printf '\033[1;32m[glibcx]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[glibcx] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not found. Run: pkg install $1"; }
TMP=""
TMP_SUM=""
cleanup() {
    [[ -n "${TMP:-}" ]] && rm -f "${TMP:?}"
    [[ -n "${TMP_SUM:-}" ]] && rm -f "${TMP_SUM:?}"
}

# ── sanity checks ─────────────────────────────────────────────────────────────
[[ "$(uname -o)" == "Android" ]] || die "glibcx is designed for Termux on Android."
[[ "$(uname -m)" == "aarch64" ]] || die "glibcx requires an AArch64 device."

need curl
need bash

# ── install prerequisites ─────────────────────────────────────────────────────
say "Installing prerequisites via pkg..."
pkg install -y glibc-runner binutils file jq clang curl nodejs 2>/dev/null || \
    say "Some packages may already be installed — continuing."

need jq

# ── download glibcx binary from latest GitHub Release ────────────────────────
mkdir -p "$INSTALL_DIR"

say "Fetching latest release info..."
if ! RELEASE_JSON="$(curl -fsSL "${RELEASES_API}")"; then
    die "Could not fetch latest release. Check your connection or wait for the first GitHub Release to be published."
fi

TAG="$(printf '%s' "$RELEASE_JSON" | jq -r '.tag_name')"
ASSET_URL="$(printf '%s' "$RELEASE_JSON" | jq -r '.assets[] | select(.name == "glibcx") | .browser_download_url' | head -n1)"
CHECKSUM_URL="$(printf '%s' "$RELEASE_JSON" | jq -r '.assets[] | select(.name == "glibcx.sha256") | .browser_download_url' | head -n1)"

if [[ -z "$ASSET_URL" || "$ASSET_URL" == "null" ]]; then
    die "Could not find glibcx binary asset in latest release. Check https://github.com/${REPO}/releases"
fi

say "Installing ${TAG}..."
TMP="$(mktemp)"
TMP_SUM="$(mktemp)"
trap cleanup EXIT

curl -fsSL --progress-bar "$ASSET_URL" -o "$TMP"

if [[ -n "$CHECKSUM_URL" && "$CHECKSUM_URL" != "null" ]]; then
    if ! curl -fsSL "$CHECKSUM_URL" -o "$TMP_SUM"; then
        die "Failed to download checksum file."
    fi
    
    EXPECTED_SUM="$(grep glibcx "$TMP_SUM" | awk '{print $1}')"
    ACTUAL_SUM="$(sha256sum "$TMP" | awk '{print $1}')"
    
    if [[ "$EXPECTED_SUM" != "$ACTUAL_SUM" ]]; then
        echo "" >&2
        echo "Expected: $EXPECTED_SUM" >&2
        echo "Actual  : $ACTUAL_SUM" >&2
        die "Checksum mismatch! Download may be corrupted or tampered."
    fi
    say "Checksum verified successfully."
else
    say "WARNING: No checksum asset (glibcx.sha256) found in release."
    if [[ "$FORCE" -ne 1 ]]; then
        echo "" >&2
        echo "[glibcx] Integrity cannot be verified. Refusing to install." >&2
        echo "[glibcx] Run: curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | bash -s -- --force" >&2
        echo "[glibcx] to bypass this check." >&2
        exit 1
    fi
    say "--force specified. Proceeding without checksum verification."
fi

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
