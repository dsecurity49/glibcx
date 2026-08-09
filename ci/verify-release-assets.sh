#!/usr/bin/env bash
# Verify the complete production release asset set without network access.
set -euo pipefail

usage() {
    echo "Usage: ci/verify-release-assets.sh <assets-dir> <release-tag> <primary-fingerprint> <signing-fingerprint>" >&2
    exit 1
}

[[ $# -eq 4 ]] || usage
ASSETS_DIR="$1"
RELEASE_TAG="$2"
EXPECTED_PRIMARY="${3^^}"
EXPECTED_SIGNER="${4^^}"

[[ -d "$ASSETS_DIR" ]] || usage
[[ "$RELEASE_TAG" =~ ^v[0-9]+[.][0-9]+[.][0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || usage
[[ "$EXPECTED_PRIMARY" =~ ^[0-9A-F]{40,64}$ \
    && "$EXPECTED_SIGNER" =~ ^[0-9A-F]{40,64}$ ]] || usage

for command_name in gpg gpgv jq sha256sum tar xz; do
    command -v "$command_name" >/dev/null 2>&1 \
        || { echo "[verify-release] Error: missing command '$command_name'." >&2; exit 1; }
done

# shellcheck source=../src/common.sh
source src/common.sh
# shellcheck source=../src/runtime.sh
source src/runtime.sh

# This verifier runs before glibcx has initialized user state. Keep helper and
# GnuPG scratch files isolated instead of assuming HOME or ~/.glibcx/tmp exists.
verification_root=$(mktemp -d)
cleanup() { rm -rf "${verification_root:?}"; }
trap cleanup EXIT
TMP_DIR="${verification_root}/runtime-tmp"
mkdir -p "$TMP_DIR"
GNUPGHOME="${verification_root}/gnupg"
export GNUPGHOME
mkdir -m 700 "$GNUPGHOME"

keyring="${ASSETS_DIR}/glibcx-release.gpg"
catalog="${ASSETS_DIR}/glibcx-profiles-v1.json"
catalog_signature="${catalog}.asc"

observed_primary=$(LC_ALL=C gpg --batch --show-keys --with-colons "$keyring" 2>/dev/null \
    | LC_ALL=C awk -F: '$1 == "fpr" {print toupper($10); exit}')
[[ "$observed_primary" == "$EXPECTED_PRIMARY" ]] \
    || { echo "[verify-release] Error: release key primary fingerprint mismatch." >&2; exit 1; }

profile_id=$(jq -r '.profiles | if length == 1 then .[0].profile_id else empty end' "$catalog")
[[ "$profile_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || { echo "[verify-release] Error: catalog must contain exactly one valid profile." >&2; exit 1; }

bundle_name="glibcx-runtime-${profile_id}.tar.xz"
source_name="glibcx-runtime-${profile_id}-source.tar.xz"
expected_assets=$(printf '%s\n' \
    glibcx glibcx.asc glibcx.sha256 glibcx-release.gpg \
    glibcx-profiles-v1.json glibcx-profiles-v1.json.asc \
    "$bundle_name" "${bundle_name}.asc" \
    "$source_name" "${source_name}.asc" | LC_ALL=C sort)
actual_assets=$(find "$ASSETS_DIR" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort)
[[ "$actual_assets" == "$expected_assets" ]] \
    || { echo "[verify-release] Error: release asset set is incomplete or contains extras." >&2; exit 1; }

verify_signature() {
    local signed_file="$1" signature_file="$2" status signer primary
    status=$(LC_ALL=C gpgv --status-fd 1 --keyring "$keyring" \
        "$signature_file" "$signed_file" 2>/dev/null) \
        || { echo "[verify-release] Error: invalid signature for '${signed_file##*/}'." >&2; exit 1; }
    signer=$(LC_ALL=C awk '$2 == "VALIDSIG" {print toupper($3); exit}' <<<"$status")
    primary=$(LC_ALL=C awk '$2 == "VALIDSIG" {print toupper($NF); exit}' <<<"$status")
    [[ "$signer" == "$EXPECTED_SIGNER" && ( "$primary" == "$EXPECTED_PRIMARY" \
        || "$signer" == "$EXPECTED_PRIMARY" ) ]] \
        || { echo "[verify-release] Error: unexpected signer for '${signed_file##*/}'." >&2; exit 1; }
}

verify_signature "${ASSETS_DIR}/glibcx" "${ASSETS_DIR}/glibcx.asc"
verify_signature "$catalog" "$catalog_signature"
verify_signature "${ASSETS_DIR}/${bundle_name}" "${ASSETS_DIR}/${bundle_name}.asc"
verify_signature "${ASSETS_DIR}/${source_name}" "${ASSETS_DIR}/${source_name}.asc"

(cd "$ASSETS_DIR" && LC_ALL=C sha256sum -c glibcx.sha256 >/dev/null) \
    || { echo "[verify-release] Error: binary checksum mismatch." >&2; exit 1; }

RUNTIME_TEST_ALLOW_LOCAL_ASSETS=false
_runtime_catalog_validate "$catalog"
[[ "$(jq -r '.signing_subkey_fingerprint | ascii_upcase' "$catalog")" == "$EXPECTED_SIGNER" ]] \
    || { echo "[verify-release] Error: catalog signing-subkey binding mismatch." >&2; exit 1; }

release_base="https://github.com/dsecurity49/glibcx/releases/download/${RELEASE_TAG}"
jq -e \
    --arg bundle_url "${release_base}/${bundle_name}" \
    --arg source_url "${release_base}/${source_name}" '
        .profiles | length == 1
        and .[0].bundle.url == $bundle_url
        and .[0].bundle.signature_url == ($bundle_url + ".asc")
        and .[0].corresponding_source.url == $source_url
        and .[0].corresponding_source.signature_url == ($source_url + ".asc")
    ' "$catalog" >/dev/null \
    || { echo "[verify-release] Error: catalog URLs do not bind the release tag." >&2; exit 1; }

[[ "$(LC_ALL=C sha256sum "${ASSETS_DIR}/${bundle_name}" | LC_ALL=C awk '{print $1}')" \
    == "$(jq -r '.profiles[0].bundle.sha256' "$catalog")" ]] \
    || { echo "[verify-release] Error: runtime bundle hash mismatch." >&2; exit 1; }
[[ "$(LC_ALL=C sha256sum "${ASSETS_DIR}/${source_name}" | LC_ALL=C awk '{print $1}')" \
    == "$(jq -r '.profiles[0].corresponding_source.sha256' "$catalog")" ]] \
    || { echo "[verify-release] Error: corresponding-source hash mismatch." >&2; exit 1; }

_runtime_archive_validate "${ASSETS_DIR}/${bundle_name}"
verification_dir="${verification_root}/bundle"
mkdir -p "$verification_dir"
tar -xJf "${ASSETS_DIR}/${bundle_name}" -C "$verification_dir"
verify_signature "${verification_dir}/profile.json" "${verification_dir}/profile.json.asc"

manifest_hash=$(LC_ALL=C sha256sum "${verification_dir}/profile.json" | LC_ALL=C awk '{print $1}')
[[ "$manifest_hash" == "$(jq -r '.profiles[0].manifest_sha256' "$catalog")" ]] \
    || { echo "[verify-release] Error: inner profile manifest hash mismatch." >&2; exit 1; }
profile_prefix=$(jq -r '.prefix' "${verification_dir}/profile.json")
_runtime_profile_manifest_validate "${verification_dir}/profile.json" "$profile_id" "$profile_prefix"
_runtime_apply_inventory_modes "$verification_dir" "${verification_dir}/profile.json"
_runtime_inventory_verify "$verification_dir" "${verification_dir}/profile.json" >/dev/null

source_listing=$(LC_ALL=C tar -tJf "${ASSETS_DIR}/${source_name}")
[[ -n "$source_listing" ]] \
    || { echo "[verify-release] Error: corresponding-source archive is empty." >&2; exit 1; }
while IFS= read -r source_path; do
    source_path=${source_path#./}
    [[ -z "$source_path" || "$source_path" == "." ]] && continue
    _runtime_safe_relative_path "${source_path%/}" \
        || { echo "[verify-release] Error: unsafe corresponding-source path '$source_path'." >&2; exit 1; }
done <<<"$source_listing"

printf '[verify-release] PASS: %s (%s)\n' "$RELEASE_TAG" "$profile_id"
