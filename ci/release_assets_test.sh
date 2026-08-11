#!/usr/bin/env bash
# Complete signed release-asset assembly using an ephemeral fixture key.
set -euo pipefail

pass() { printf '  PASS %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*" >&2; exit 1; }

TEST_TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "${TEST_TMP_DIR:?}"; }
trap cleanup EXIT

# shellcheck source=../src/common.sh
source src/common.sh
# shellcheck source=../src/runtime.sh
source src/runtime.sh
TMP_DIR="${TEST_TMP_DIR}/tmp"
mkdir -p "$TMP_DIR"

if [[ -x "${PREFIX:-/nonexistent}/glibc/lib/ld-linux-aarch64.so.1" ]]; then
    source_loader="${PREFIX}/glibc/lib/ld-linux-aarch64.so.1"
    source_libc="${PREFIX}/glibc/lib/libc.so.6"
else
    source_loader=$(find /lib /usr/lib -name ld-linux-aarch64.so.1 -type f -print -quit 2>/dev/null)
    source_libc=$(find /lib /usr/lib -name libc.so.6 -type f -print -quit 2>/dev/null)
fi
[[ -n "$source_loader" && -n "$source_libc" ]] \
    || fail "AArch64 glibc fixture is unavailable"

if [[ -d "${PREFIX:-/nonexistent}/glibc/include" ]]; then
    shim_sysroot="${PREFIX}/glibc"
else
    shim_sysroot=/
fi
proc_shim="${TEST_TMP_DIR}/proc-exe-shim.so"
bash profiles/build-proc-exe-shim.sh "$shim_sysroot" profiles/proc-exe-shim.c "$proc_shim"
loader_audit="${TEST_TMP_DIR}/loader-audit.so"
bash profiles/build-loader-audit.sh "$shim_sysroot" profiles/loader-audit.c "$loader_audit"

prepared_tree="${TEST_TMP_DIR}/prepared"
source_tree="${TEST_TMP_DIR}/corresponding-source"
mkdir -p "${prepared_tree}/lib" "$source_tree"
cp "$source_loader" "${prepared_tree}/lib/ld-linux-aarch64.so.1"
cp "$source_libc" "${prepared_tree}/lib/libc.so.6"
printf 'fixture build recipe and corresponding source\n' >"${source_tree}/README"

fixture_gnupg="${TEST_TMP_DIR}/gnupg"
mkdir -m 700 "$fixture_gnupg"
fixture_passphrase='fixture-release-passphrase'
fixture_passphrase_file="${TEST_TMP_DIR}/fixture-passphrase"
printf '%s' "$fixture_passphrase" >"$fixture_passphrase_file"
chmod 600 "$fixture_passphrase_file"
GNUPGHOME="$fixture_gnupg" gpg --batch --pinentry-mode loopback --passphrase "$fixture_passphrase" \
    --quick-gen-key 'glibcx release fixture <fixture@invalid>' ed25519 cert 1d >/dev/null 2>&1
fixture_fingerprint=$(GNUPGHOME="$fixture_gnupg" gpg --batch --with-colons --list-keys \
    | awk -F: '$1 == "fpr" {print $10; exit}')
GNUPGHOME="$fixture_gnupg" gpg --batch --pinentry-mode loopback --passphrase "$fixture_passphrase" \
    --quick-add-key "$fixture_fingerprint" ed25519 sign 1d >/dev/null 2>&1
fixture_signing_fingerprint=$(GNUPGHOME="$fixture_gnupg" gpg --batch --with-colons --list-secret-keys \
    | awk -F: '$1 == "fpr" {count++; if (count == 2) {print $10; exit}}')
[[ -n "$fixture_signing_fingerprint" ]] || fail "ephemeral signing subkey was not created"
source_epoch=$(date -u '+%s')

profile_id=release-fixture
RUNTIME_ROOT="${TEST_TMP_DIR}/installed"
final_prefix="/data/data/com.termux/files/usr/opt/glibcx/runtimes/${profile_id}"
payload_output="${TEST_TMP_DIR}/payload"
env \
    GLIBC_VERSION=2.42 \
    TERMUX_PACKAGE_REVISION=fixture-1 \
    TERMUX_GLIBC_COMMIT=0000000000000000000000000000000000000000 \
    BUILD_SOURCE_URL=https://example.invalid/glibc-2.42.tar.xz \
    BUILD_SOURCE_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
    CORRESPONDING_SOURCE_URL="https://github.com/dsecurity49/glibcx/releases/download/v0.3.0/glibcx-runtime-${profile_id}-source.tar.xz" \
    TOOLCHAIN_DESCRIPTION=ubuntu-26.04-arm-clang \
    PROC_SHIM_BINARY="$proc_shim" \
    LOADER_AUDIT_BINARY="$loader_audit" \
    SOURCE_DATE_EPOCH="$source_epoch" \
    bash profiles/prepare-profile.sh \
        "$profile_id" "$prepared_tree" "$final_prefix" "$payload_output" >/dev/null

package_once() {
    local output_dir="$1"
    env \
        GNUPGHOME="$fixture_gnupg" \
        SIGNING_KEY_FINGERPRINT="$fixture_signing_fingerprint" \
        RELEASE_PRIMARY_FINGERPRINT="$fixture_fingerprint" \
        SOURCE_DATE_EPOCH="$source_epoch" \
        SIGNING_KEY_PASSPHRASE_FILE="$fixture_passphrase_file" \
        GLIBCX_BINARY=./glibcx \
        bash profiles/package-release.sh \
            7 v0.3.0 "${payload_output}/${profile_id}.payload" \
            "$source_tree" "$output_dir" >/dev/null
}

assets="${TEST_TMP_DIR}/assets"
second_assets="${TEST_TMP_DIR}/assets-second"
package_once "$assets"
package_once "$second_assets"

expected_assets=$(printf '%s\n' \
    glibcx glibcx.asc glibcx.sha256 glibcx-release.gpg install.sh install.sh.asc \
    glibcx-profiles-v1.json glibcx-profiles-v1.json.asc \
    "glibcx-runtime-${profile_id}.tar.xz" \
    "glibcx-runtime-${profile_id}.tar.xz.asc" \
    "glibcx-runtime-${profile_id}-source.tar.xz" \
    "glibcx-runtime-${profile_id}-source.tar.xz.asc" | LC_ALL=C sort)
actual_assets=$(find "$assets" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort)
[[ "$actual_assets" == "$expected_assets" ]] || fail "release asset set is incomplete"
(cd "$assets" && sha256sum -c glibcx.sha256 >/dev/null) \
    || fail "release binary checksum did not verify"
pass "complete binary, runtime, catalog, source, key, hash, and signature asset set"

for signed_name in \
    glibcx \
    install.sh \
    glibcx-profiles-v1.json \
    "glibcx-runtime-${profile_id}.tar.xz" \
    "glibcx-runtime-${profile_id}-source.tar.xz"; do
    gpgv --keyring "${assets}/glibcx-release.gpg" \
        "${assets}/${signed_name}.asc" "${assets}/${signed_name}" >/dev/null 2>&1 \
        || fail "signature failed for $signed_name"
done
pass "all release signatures chain to the exported fixture key"

RUNTIME_TEST_ALLOW_LOCAL_ASSETS=false
_runtime_catalog_validate "${assets}/glibcx-profiles-v1.json" \
    || fail "generated release catalog failed client validation"
bundle="${assets}/glibcx-runtime-${profile_id}.tar.xz"
_runtime_archive_validate "$bundle" || fail "generated runtime archive failed safety validation"
extracted="${TEST_TMP_DIR}/extracted"
mkdir -p "$extracted"
tar -xJf "$bundle" -C "$extracted"
gpgv --keyring "${assets}/glibcx-release.gpg" \
    "${extracted}/profile.json.asc" "${extracted}/profile.json" >/dev/null 2>&1 \
    || fail "inner profile signature failed"
_runtime_profile_manifest_validate "${extracted}/profile.json" "$profile_id" "$final_prefix" \
    || fail "packaged profile failed client schema validation"
_runtime_apply_inventory_modes "$extracted" "${extracted}/profile.json"
_runtime_inventory_verify "$extracted" "${extracted}/profile.json" >/dev/null \
    || fail "packaged profile inventory failed client verification"
pass "generated catalog and nested runtime trust chain"

standalone_home="${TEST_TMP_DIR}/standalone-home"
env HOME="$standalone_home" bash ci/verify-release-assets.sh \
    "$assets" v0.3.0 "$fixture_fingerprint" "$fixture_signing_fingerprint" >/dev/null \
    || fail "standalone protected-release verifier rejected the fixture assets"
pass "standalone protected-release verifier"

first_hashes=$(find "$assets" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort \
    | while IFS= read -r asset_name; do
        sha256sum "${assets}/${asset_name}" | sed "s|${assets}/||"
    done)
second_hashes=$(find "$second_assets" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort \
    | while IFS= read -r asset_name; do
        sha256sum "${second_assets}/${asset_name}" | sed "s|${second_assets}/||"
    done)
[[ "$first_hashes" == "$second_hashes" ]] \
    || fail "fixed-input release packaging was not byte-reproducible"
pass "byte-reproducible signed release assembly"

printf '\nAll release asset tests passed.\n'
