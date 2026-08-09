#!/usr/bin/env bash
# Networked release-gate prototype for the actual Termux glibc repository.
# This is intentionally separate from deterministic CI fixtures.
set -euo pipefail

pass() { printf '  PASS %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*" >&2; exit 1; }

TEST_TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "${TEST_TMP_DIR:?}"; }
trap cleanup EXIT

# shellcheck source=../src/common.sh
source src/common.sh
# shellcheck source=../src/lock.sh
source src/lock.sh
# shellcheck source=../src/state.sh
source src/state.sh
# shellcheck source=../src/runtime.sh
source src/runtime.sh
# shellcheck source=../src/resolver.sh
source src/resolver.sh

CLI_STORAGE="${TEST_TMP_DIR}/state"
REGISTRY_FILE="${CLI_STORAGE}/registry.json"
APPS_DIR="${CLI_STORAGE}/apps"
BIN_DIR="${CLI_STORAGE}/bin"
CACHE_DIR="${CLI_STORAGE}/cache"
LOCK_DIR="${CLI_STORAGE}/locks"
LOG_DIR="${CLI_STORAGE}/logs"
TMP_DIR="${CLI_STORAGE}/tmp"
PROFILE_STATE_DIR="${CLI_STORAGE}/profiles"
RUNTIME_ROOT="${TEST_TMP_DIR}/runtimes"
init_env

[[ "$TERMUX_GLIBC_REPOSITORY" == "https://packages-cf.termux.dev/apt/termux-glibc" \
    && "$TERMUX_GLIBC_DISTRIBUTION" == glibc \
    && "$TERMUX_GLIBC_COMPONENT" == stable ]] \
    || fail "repository URL/distribution/component contract changed"

snapshot_dir=$(_resolver_repository_refresh) \
    || fail "authenticated repository refresh"
jq -e '
    .origin == "termux-glibc glibc"
    and .suite == "glibc"
    and .architecture == "aarch64"
    and (.signing_fingerprint | length) >= 40
' "${snapshot_dir}/repository.json" >/dev/null \
    || fail "authenticated repository identity metadata"
grep -qE '^[^[:space:]]*glibc/(lib|usr/lib)/[^[:space:]]+[[:space:]]+[^[:space:]]+' \
    "${snapshot_dir}/Contents-aarch64" \
    || fail "Contents-aarch64 does not expose glibc library paths"
pass "InRelease, stable/binary-aarch64/Packages, and stable/Contents-aarch64.gz"

probe_soname="${1:-libz.so.1}"
provider=$(_resolver_contents_provider "${snapshot_dir}/Contents-aarch64" "$probe_soname") \
    || fail "unique package provider for $probe_soname"
[[ "$provider" != glibc ]] || fail "$probe_soname is not independently packaged"
package_json=$(_resolver_package_metadata "${snapshot_dir}/Packages" "$provider") \
    || fail "package metadata for $provider"
package_file=$(_resolver_download_package "$package_json" false) \
    || fail "exact authenticated .deb download for $provider"
[[ -f "$package_file" ]] || fail "downloaded package is missing"
pass "$probe_soname is independently packaged by $provider"

# Prove the alternative APT install pipeline too. It uses only the isolated
# state/status/cache written by the resolver and never invokes dpkg.
keyring=$(_resolver_repository_keyring)
apt_config=$(_resolver_apt_configure "$keyring")
package_version=$(jq -r '.version' <<<"$package_json")
apt_log="${TEST_TMP_DIR}/apt-download-only.log"
if ! LC_ALL=C apt-get -qq -c "$apt_config" --download-only --no-install-recommends \
    install "${provider}=${package_version}" >"$apt_log" 2>&1; then
    tail -n 30 "$apt_log" >&2
    fail "apt-get --download-only with isolated state"
fi
pass "apt-get --download-only works with isolated state"

printf '\nLive repository contract probe passed.\n'
