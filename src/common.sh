GLIBC_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}/glibc"
GLIBC_INTERPRETER="${GLIBC_PREFIX}/lib/ld-linux-aarch64.so.1"
GLIBC_LIB_DIR="${GLIBC_PREFIX}/lib"

CLI_STORAGE="${HOME:-/data/data/com.termux/files/home}/.glibcx"
REGISTRY_FILE="${CLI_STORAGE}/registry.json"
APPS_DIR="${CLI_STORAGE}/apps"
BIN_DIR="${CLI_STORAGE}/bin"
CACHE_DIR="${CLI_STORAGE}/cache"
LOCK_DIR="${CLI_STORAGE}/locks"
LOG_DIR="${CLI_STORAGE}/logs"
TMP_DIR="${CLI_STORAGE}/tmp"
PROFILE_STATE_DIR="${CLI_STORAGE}/profiles"
RUNTIME_ROOT="${PREFIX:-/data/data/com.termux/files/usr}/opt/glibcx/runtimes"
STATE_SCHEMA=3
GLIBCX_VERSION="0.3.0-dev"
PROFILE_COMPATIBILITY_SCHEMA=2

# Release trust is pinned to the public key produced by the offline production
# ceremony. Fixture tests override these shell variables only after sourcing
# the modules.
RUNTIME_CATALOG_URL="https://github.com/dsecurity49/glibcx/releases/latest/download/glibcx-profiles-v1.json"
RUNTIME_CATALOG_SIGNATURE_URL="${RUNTIME_CATALOG_URL}.asc"
RUNTIME_RELEASE_KEYRING="${PREFIX:-/data/data/com.termux/files/usr}/share/glibcx/keys/glibcx-release.gpg"
RUNTIME_RELEASE_PRIMARY_FINGERPRINT="EB13DBFA9354A55285CF4B03B5255ACD0708C45E"
RUNTIME_TEST_ALLOW_LOCAL_ASSETS=false

TERMUX_GLIBC_REPOSITORY="https://packages-cf.termux.dev/apt/termux-glibc"
TERMUX_GLIBC_DISTRIBUTION="glibc"
TERMUX_GLIBC_COMPONENT="stable"
TERMUX_GLIBC_KEYRING="${PREFIX:-/data/data/com.termux/files/usr}/etc/apt/trusted.gpg.d/termux-autobuilds.gpg"
TERMUX_GLIBC_KEY_FINGERPRINT="CC72CF8BA7DBFA0182877D045A897D96E57CF20C"
RESOLVER_TEST_ALLOW_LOCAL_REPOSITORY=false

_require_command() {
    local command_name="$1" package_name="${2:-$1}"
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "[glibcx] Error: required command '$command_name' is missing." >&2
        echo "[glibcx] Install it with: pkg install $package_name" >&2
        return 1
    fi
}

init_env() {
    _require_command jq jq
    _require_command flock util-linux

    umask 077
    mkdir -p \
        "$APPS_DIR" \
        "$BIN_DIR" \
        "${CACHE_DIR}/apt" \
        "${CACHE_DIR}/packages" \
        "$LOCK_DIR" \
        "$LOG_DIR" \
        "$TMP_DIR" \
        "$PROFILE_STATE_DIR" \
        "${CLI_STORAGE}/storage" \
        "${CLI_STORAGE}/opt"

    state_initialize
}

_utc_timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u
}

_timestamp_slug() {
    date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null || date -u '+%s'
}

_sha256_file() {
    LC_ALL=C sha256sum "$1" | LC_ALL=C awk '{print $1}'
}

_sha256_text() {
    printf '%s' "$1" | LC_ALL=C sha256sum | LC_ALL=C awk '{print $1}'
}

_sanitize_basename() {
    local sanitized
    sanitized=$(printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9._-]/_/g; s/^[-.]*//; s/[-.]*$//')
    sanitized="${sanitized:0:64}"
    if [[ -z "$sanitized" ]]; then
        sanitized="app"
    fi
    printf '%s\n' "$sanitized"
}

# Drift fingerprint: file identity + size + mtime + ctime. This catches
# in-place rewrites even when an updater preserves the original mtime.
_fingerprint() {
    LC_ALL=C stat -c '%d_%i_%s_%Y_%Z' "$1" 2>/dev/null || echo "missing"
}

# Return success only for an AArch64 ELF. Providers use this before offering a
# downloaded executable to cmd_patch, so a mixed-architecture archive does not
# abort an otherwise usable install.
_is_aarch64_elf() {
    LC_ALL=C file "$1" 2>/dev/null | grep -qE 'ELF 64-bit LSB.*(aarch64|ARM aarch64)'
}
