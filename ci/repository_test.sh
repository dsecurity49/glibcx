#!/usr/bin/env bash
# Authenticated miniature Termux-glibc repository and package resolver tests.
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
# shellcheck source=../src/elf.sh
source src/elf.sh
# shellcheck source=../src/runtime.sh
source src/runtime.sh
# shellcheck source=../src/wrapper.sh
source src/wrapper.sh
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

command -v gpg >/dev/null 2>&1 || fail "gpg is required for repository fixtures"
command -v dpkg-deb >/dev/null 2>&1 || fail "dpkg-deb is required for repository fixtures"

fixture_gnupg="${TEST_TMP_DIR}/gnupg"
fixture_keyring="${TEST_TMP_DIR}/repository.gpg"
mkdir -m 700 "$fixture_gnupg"
GNUPGHOME="$fixture_gnupg" gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-gen-key 'glibcx repository fixture <fixture@invalid>' ed25519 sign 1d >/dev/null 2>&1
fixture_fingerprint=$(GNUPGHOME="$fixture_gnupg" gpg --batch --with-colons --list-keys \
    | awk -F: '$1 == "fpr" {print $10; exit}')
GNUPGHOME="$fixture_gnupg" gpg --batch --export "$fixture_fingerprint" >"$fixture_keyring"

if [[ -f "${PREFIX:-/nonexistent}/glibc/lib/libz.so.1.3.2" ]]; then
    source_dso="${PREFIX}/glibc/lib/libz.so.1.3.2"
else
    source_dso=$(find /lib /usr/lib -name 'libz.so.1.*' -type f -print -quit 2>/dev/null)
fi
[[ -n "$source_dso" ]] || fail "libz fixture DSO is unavailable"

bundled_origin="${TEST_TMP_DIR}/bundled-app"
mkdir -p "$bundled_origin" "${TEST_TMP_DIR}/empty-app-lib"
cp "$source_dso" "${bundled_origin}/libz.so.1"
bundled_profile='{"library_dirs":[]}'
bundled_inspection='{"dynamic":{"rpath":[],"runpath":[]}}'
bundled_resolution=$(_resolver_find_library libz.so.1 \
    "${TEST_TMP_DIR}/empty-app-lib" "$bundled_profile" "$bundled_origin" "$bundled_inspection")
[[ "$bundled_resolution" == "${bundled_origin}/libz.so.1" ]] \
    || fail "same-directory bundled DSO was not preferred"
pass "same-directory bundled DSO resolution"

repository_root="${TEST_TMP_DIR}/repo"
package_root="${TEST_TMP_DIR}/package-root"
package_pool="${repository_root}/pool/stable/z/zlib-fixture"
distribution_root="${repository_root}/dists/glibc"
mkdir -p "${package_root}/DEBIAN" \
    "${package_root}/data/data/com.termux/files/usr/glibc/lib" \
    "$package_pool" "${distribution_root}/stable/binary-aarch64"
chmod 755 "${package_root}/DEBIAN"
printf '%s\n' \
    'Package: zlib-fixture' \
    'Version: 1.0-1' \
    'Architecture: aarch64' \
    'Maintainer: glibcx fixture' \
    'Description: signed repository fixture' >"${package_root}/DEBIAN/control"
cp "$source_dso" "${package_root}/data/data/com.termux/files/usr/glibc/lib/libz.so.1.3.2"
ln -s libz.so.1.3.2 "${package_root}/data/data/com.termux/files/usr/glibc/lib/libz.so.1"
package_file="${package_pool}/zlib-fixture_1.0-1_aarch64.deb"
dpkg-deb --build "$package_root" "$package_file" >/dev/null
package_hash=$(_sha256_file "$package_file")
package_size=$(stat -c '%s' "$package_file")
printf '%s\n' \
    'Package: zlib-fixture' \
    'Version: 1.0-1' \
    'Architecture: aarch64' \
    'Maintainer: glibcx fixture' \
    'Description: signed repository fixture' \
    'Filename: pool/stable/z/zlib-fixture/zlib-fixture_1.0-1_aarch64.deb' \
    "Size: ${package_size}" \
    "SHA256: ${package_hash}" \
    '' >"${distribution_root}/stable/binary-aarch64/Packages"
printf '%s\n' \
    'data/data/com.termux/files/usr/glibc/lib/libz.so.1 stable/zlib-fixture' \
    'data/data/com.termux/files/usr/glibc/lib/libz.so.1.3.2 stable/zlib-fixture' \
    >"${distribution_root}/stable/Contents-aarch64"
gzip -n -c "${distribution_root}/stable/Contents-aarch64" \
    >"${distribution_root}/stable/Contents-aarch64.gz"

packages_file="${distribution_root}/stable/binary-aarch64/Packages"
contents_gz="${distribution_root}/stable/Contents-aarch64.gz"
release_file="${distribution_root}/Release"
release_expiry=$(date -u -d '+7 days' -R)
printf '%s\n' \
    'Origin: termux-glibc glibc' \
    'Label: termux-glibc glibc' \
    'Suite: glibc' \
    'Codename: glibc' \
    "Date: $(date -u -R)" \
    "Valid-Until: ${release_expiry}" \
    'Architectures: aarch64' \
    'Components: stable' \
    'SHA256:' \
    " $(_sha256_file "$packages_file") $(stat -c '%s' "$packages_file") stable/binary-aarch64/Packages" \
    " $(_sha256_file "$contents_gz") $(stat -c '%s' "$contents_gz") stable/Contents-aarch64.gz" \
    >"$release_file"
GNUPGHOME="$fixture_gnupg" gpg --batch --yes --clearsign --digest-algo SHA256 \
    --output "${distribution_root}/InRelease" "$release_file"
find "$repository_root" -type d -exec chmod 755 {} +
find "$repository_root" -type f -exec chmod 644 {} +

TERMUX_GLIBC_REPOSITORY="file://${repository_root}"
TERMUX_GLIBC_KEYRING="$fixture_keyring"
TERMUX_GLIBC_KEY_FINGERPRINT="$fixture_fingerprint"
RESOLVER_TEST_ALLOW_LOCAL_REPOSITORY=true

snapshot_dir=$(_resolver_repository_refresh)
jq -e --arg signer "$fixture_fingerprint" '
    .origin == "termux-glibc glibc"
    and .suite == "glibc"
    and .architecture == "aarch64"
    and .signing_fingerprint == $signer
' "${snapshot_dir}/repository.json" >/dev/null || fail "repository trust metadata is incomplete"
provider=$(_resolver_contents_provider "${snapshot_dir}/Contents-aarch64" libz.so.1)
[[ "$provider" == zlib-fixture ]] || fail "Contents provider lookup returned '$provider'"
package_json=$(_resolver_package_metadata "${snapshot_dir}/Packages" "$provider")
jq -e --arg hash "$package_hash" '.package == "zlib-fixture" and .sha256 == $hash' \
    <<<"$package_json" >/dev/null || fail "Packages metadata lookup was incorrect"
resolved_package=$(_resolver_download_package "$package_json" false)
[[ "$(_sha256_file "$resolved_package")" == "$package_hash" ]] \
    || fail "downloaded fixture package was not content-addressed"
offline_package=$(_resolver_download_package "$package_json" true)
[[ "$offline_package" == "$resolved_package" ]] \
    || fail "offline package reuse did not select the content-addressed cache"
mkdir -p "${TEST_TMP_DIR}/app/lib"
_resolver_copy_package_dso "$resolved_package" libz.so.1 "${TEST_TMP_DIR}/app/lib" \
    "$package_json" "$snapshot_dir"
[[ -L "${TEST_TMP_DIR}/app/lib/libz.so.1" \
    && -f "${TEST_TMP_DIR}/app/lib/libz.so.1.3.2" ]] \
    || fail "safe DSO symlink chain was not copied"
jq -e '
    .libraries[0].soname == "libz.so.1"
    and .libraries[0].package.package == "zlib-fixture"
    and (.libraries[0].repository.inrelease_sha256 | test("^[0-9a-f]{64}$"))
' "${TEST_TMP_DIR}/app/resolver-packages.json" >/dev/null \
    || fail "repository provenance was not recorded"
pass "signed repository refresh, provider lookup, package lock, and extraction"

escape_root="${TEST_TMP_DIR}/escape-package-root"
mkdir -p "${escape_root}/DEBIAN" \
    "${escape_root}/data/data/com.termux/files/usr/glibc/lib"
chmod 755 "${escape_root}/DEBIAN"
printf '%s\n' \
    'Package: escape-fixture' \
    'Version: 1.0-1' \
    'Architecture: aarch64' \
    'Maintainer: glibcx fixture' \
    'Description: escaping symlink fixture' >"${escape_root}/DEBIAN/control"
ln -s ../../../../../../../../../../outside \
    "${escape_root}/data/data/com.termux/files/usr/glibc/lib/libescape.so.1"
escape_package="${TEST_TMP_DIR}/escape-fixture.deb"
dpkg-deb --build "$escape_root" "$escape_package" >/dev/null
if _resolver_copy_package_dso "$escape_package" libescape.so.1 \
    "${TEST_TMP_DIR}/escape-app/lib" "$package_json" "$snapshot_dir" >/dev/null 2>&1; then
    fail "escaping package symlink was accepted"
fi
pass "malicious package symlink rejection"

cp "${distribution_root}/InRelease" "${distribution_root}/InRelease.good"
printf '\ncorrupt\n' >>"${distribution_root}/InRelease"
if _resolver_repository_refresh >/dev/null 2>&1; then
    fail "bad InRelease signature was accepted"
fi
mv "${distribution_root}/InRelease.good" "${distribution_root}/InRelease"
pass "bad InRelease signature rejection"

printf 'tamper\n' >>"$contents_gz"
if _resolver_repository_refresh >/dev/null 2>&1; then
    fail "Contents hash mismatch was accepted"
fi
pass "bad Contents hash rejection"

ambiguous_contents="${TEST_TMP_DIR}/ambiguous-contents"
printf '%s\n' \
    'data/data/com.termux/files/usr/glibc/lib/libambiguous.so.1 stable/provider-one' \
    'data/data/com.termux/files/usr/glibc/lib/libambiguous.so.1 stable/provider-two' \
    >"$ambiguous_contents"
if _resolver_contents_provider "$ambiguous_contents" libambiguous.so.1 >/dev/null 2>&1; then
    fail "ambiguous SONAME providers were accepted"
fi
pass "ambiguous SONAME provider rejection"

printf '\nAll repository resolver tests passed.\n'
