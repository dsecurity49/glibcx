#!/usr/bin/env bash
# glibcx installer — verify this versioned release asset before executing it.
set -euo pipefail

REPO="dsecurity49/glibcx"
INSTALL_DIR="${HOME}/bin"
BIN_NAME="glibcx"
RELEASES_API="https://api.github.com/repos/${REPO}/releases/latest"
RELEASE_PRIMARY_FINGERPRINT="EB13DBFA9354A55285CF4B03B5255ACD0708C45E"
KEY_INSTALL_DIR="${PREFIX:-/data/data/com.termux/files/usr}/share/glibcx/keys"

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
TMP_SIG=""
TMP_KEY=""
cleanup() {
    [[ -n "${TMP:-}" ]] && rm -f "${TMP:?}"
    [[ -n "${TMP_SUM:-}" ]] && rm -f "${TMP_SUM:?}"
    [[ -n "${TMP_SIG:-}" ]] && rm -f "${TMP_SIG:?}"
    [[ -n "${TMP_KEY:-}" ]] && rm -f "${TMP_KEY:?}"
}

# ── sanity checks ─────────────────────────────────────────────────────────────
[[ "$(uname -o)" == "Android" ]] || die "glibcx is designed for Termux on Android."
[[ "$(uname -m)" == "aarch64" ]] || die "glibcx requires an AArch64 device."

need curl
need bash

# ── install prerequisites ─────────────────────────────────────────────────────
say "Refreshing the Termux package index..."
pkg update -y || die "Could not refresh the Termux package index."

say "Enabling the Termux glibc repository..."
pkg install -y glibc-repo || die "Could not install glibc-repo."

say "Refreshing package metadata with the glibc repository enabled..."
pkg update -y || die "Could not refresh the glibc package index."

say "Installing prerequisites via pkg..."
pkg install -y glibc-runner binutils file jq clang curl nodejs util-linux gnupg \
    || die "Could not install glibcx prerequisites."

need jq
need gpg
need gpgv

# ── download glibcx binary from latest GitHub Release ────────────────────────
mkdir -p "$INSTALL_DIR"

say "Fetching latest release info..."
if ! RELEASE_JSON="$(curl -fsSL "${RELEASES_API}")"; then
    die "Could not fetch latest release. Check your connection or wait for the first GitHub Release to be published."
fi

TAG="$(printf '%s' "$RELEASE_JSON" | jq -r '.tag_name')"
ASSET_URL="$(printf '%s' "$RELEASE_JSON" | jq -r '.assets[] | select(.name == "glibcx") | .browser_download_url' | head -n1)"
CHECKSUM_URL="$(printf '%s' "$RELEASE_JSON" | jq -r '.assets[] | select(.name == "glibcx.sha256") | .browser_download_url' | head -n1)"
SIGNATURE_URL="$(printf '%s' "$RELEASE_JSON" | jq -r '.assets[] | select(.name == "glibcx.asc") | .browser_download_url' | head -n1)"
KEY_URL="$(printf '%s' "$RELEASE_JSON" | jq -r '.assets[] | select(.name == "glibcx-release.gpg") | .browser_download_url' | head -n1)"

if [[ -z "$ASSET_URL" || "$ASSET_URL" == "null" ]]; then
    die "Could not find glibcx binary asset in latest release. Check https://github.com/${REPO}/releases"
fi
if [[ -z "$CHECKSUM_URL" || "$CHECKSUM_URL" == "null" \
    || -z "$SIGNATURE_URL" || "$SIGNATURE_URL" == "null" \
    || -z "$KEY_URL" || "$KEY_URL" == "null" ]]; then
    die "Release is missing its mandatory checksum, signature, or public key asset."
fi
if [[ ! "$RELEASE_PRIMARY_FINGERPRINT" =~ ^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$ ]]; then
    die "The production release-key fingerprint has not been provisioned in this installer."
fi
if [[ "$FORCE" -eq 1 ]]; then
    say "--force requested; signature, pinned-key, and checksum verification remain mandatory."
fi

say "Installing ${TAG}..."
TMP="$(mktemp)"
TMP_SUM="$(mktemp)"
TMP_SIG="$(mktemp)"
TMP_KEY="$(mktemp)"
trap cleanup EXIT

curl -fsSL --progress-bar "$ASSET_URL" -o "$TMP"
curl -fsSL "$CHECKSUM_URL" -o "$TMP_SUM"
curl -fsSL "$SIGNATURE_URL" -o "$TMP_SIG"
curl -fsSL "$KEY_URL" -o "$TMP_KEY"

EXPECTED_SUM="$(awk '$2 == "glibcx" || $2 == "*glibcx" {print $1; exit}' "$TMP_SUM")"
ACTUAL_SUM="$(LC_ALL=C sha256sum "$TMP" | LC_ALL=C awk '{print $1}')"
[[ "$EXPECTED_SUM" =~ ^[0-9a-f]{64}$ ]] || die "Release checksum file is invalid."
[[ "$EXPECTED_SUM" == "$ACTUAL_SUM" ]] || die "Checksum mismatch! Download may be corrupted or tampered."

OBSERVED_FINGERPRINT="$(LC_ALL=C gpg --batch --show-keys --with-colons "$TMP_KEY" 2>/dev/null \
    | awk -F: '$1 == "fpr" {print toupper($10); exit}')"
[[ "$OBSERVED_FINGERPRINT" == "${RELEASE_PRIMARY_FINGERPRINT^^}" ]] \
    || die "Downloaded release key does not match the pinned primary fingerprint."
GPG_STATUS="$(LC_ALL=C gpgv --status-fd 1 --keyring "$TMP_KEY" "$TMP_SIG" "$TMP" 2>/dev/null)" \
    || die "Release signature verification failed."
SIGNING_FINGERPRINT="$(awk '$2 == "VALIDSIG" {print toupper($3); exit}' <<<"$GPG_STATUS")"
SIGNING_PRIMARY="$(awk '$2 == "VALIDSIG" {print toupper($NF); exit}' <<<"$GPG_STATUS")"
if [[ "$SIGNING_FINGERPRINT" != "${RELEASE_PRIMARY_FINGERPRINT^^}" \
    && "$SIGNING_PRIMARY" != "${RELEASE_PRIMARY_FINGERPRINT^^}" ]]; then
    die "Release signature is not rooted in the pinned primary key."
fi
say "Checksum and OpenPGP signature verified successfully."

# Verify it's a shell script (built monolithic bash binary)
if ! head -1 "$TMP" | grep -q "bash\|sh"; then
    die "Downloaded file does not look like a valid glibcx binary."
fi

mkdir -p "$KEY_INSTALL_DIR"
install -m 644 "$TMP_KEY" "${KEY_INSTALL_DIR}/glibcx-release.gpg"
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
