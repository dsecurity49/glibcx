#!/usr/bin/env bash
# Assemble and sign the complete versioned v0.3 release asset set. This script
# consumes a prepared profile payload and corresponding-source tree; it never
# creates or imports signing keys.
set -euo pipefail

usage() {
    echo "Usage: profiles/package-release.sh <catalog-version> <release-tag> <payload-dir> <source-dir> <output-dir>" >&2
    exit 1
}

[[ $# -eq 5 ]] || usage
CATALOG_VERSION="$1"
RELEASE_TAG="$2"
PAYLOAD_DIR="$3"
SOURCE_DIR="$4"
OUTPUT_DIR="$5"

[[ "$CATALOG_VERSION" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$RELEASE_TAG" =~ ^v[0-9]+[.][0-9]+[.][0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || usage
[[ -d "$PAYLOAD_DIR" && -d "$SOURCE_DIR" && ! -e "$OUTPUT_DIR" ]] || usage

required_release_value() {
    local variable_name="$1" value
    value="${!variable_name:-}"
    if [[ -z "$value" ]]; then
        echo "[release] Error: required release variable '$variable_name' is unset." >&2
        exit 1
    fi
    printf '%s' "$value"
}

SIGNING_KEY_FINGERPRINT=$(required_release_value SIGNING_KEY_FINGERPRINT)
RELEASE_PRIMARY_FINGERPRINT=$(required_release_value RELEASE_PRIMARY_FINGERPRINT)
SOURCE_DATE_EPOCH=$(required_release_value SOURCE_DATE_EPOCH)
GLIBCX_BINARY="${GLIBCX_BINARY:-./glibcx}"
RELEASE_BASE_URL="${RELEASE_BASE_URL:-https://github.com/dsecurity49/glibcx/releases/download/${RELEASE_TAG}}"
PROFILE_SECURITY_STATE="${PROFILE_SECURITY_STATE:-recommended}"
PROFILE_PRIORITY="${PROFILE_PRIORITY:-100}"
MIN_GLIBCX_VERSION="${MIN_GLIBCX_VERSION:-0.3.0}"

SIGNING_KEY_FINGERPRINT=${SIGNING_KEY_FINGERPRINT^^}
RELEASE_PRIMARY_FINGERPRINT=${RELEASE_PRIMARY_FINGERPRINT^^}
[[ "$SIGNING_KEY_FINGERPRINT" =~ ^[0-9A-F]{40,64}$ \
    && "$RELEASE_PRIMARY_FINGERPRINT" =~ ^[0-9A-F]{40,64}$ ]] \
    || { echo "[release] Error: signing fingerprints must be full hexadecimal fingerprints." >&2; exit 1; }
[[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] \
    || { echo "[release] Error: SOURCE_DATE_EPOCH must be a non-negative integer." >&2; exit 1; }
[[ "$PROFILE_PRIORITY" =~ ^[0-9]+$ ]] \
    || { echo "[release] Error: PROFILE_PRIORITY must be a non-negative integer." >&2; exit 1; }
case "$PROFILE_SECURITY_STATE" in recommended|supported|deprecated) ;; *) usage ;; esac
[[ "$MIN_GLIBCX_VERSION" =~ ^[0-9]+[.][0-9]+[.][0-9]+([+-][A-Za-z0-9._-]+)?$ ]] \
    || { echo "[release] Error: MIN_GLIBCX_VERSION must be semantic version text." >&2; exit 1; }
[[ "$RELEASE_BASE_URL" == "https://github.com/dsecurity49/glibcx/releases/download/${RELEASE_TAG}" ]] \
    || { echo "[release] Error: release asset URL must use the canonical version-tag URL." >&2; exit 1; }
[[ -f "$GLIBCX_BINARY" && -f "${PAYLOAD_DIR}/profile.json" ]] \
    || { echo "[release] Error: binary or prepared profile manifest is missing." >&2; exit 1; }

for release_command in gpg jq tar xz sha256sum; do
    command -v "$release_command" >/dev/null 2>&1 \
        || { echo "[release] Error: required command '$release_command' is unavailable." >&2; exit 1; }
done

secret_fingerprints=$(LC_ALL=C gpg --batch --with-colons --list-secret-keys "$SIGNING_KEY_FINGERPRINT" 2>/dev/null \
    | awk -F: '$1 == "fpr" {print toupper($10)}')
grep -qx "$SIGNING_KEY_FINGERPRINT" <<<"$secret_fingerprints" \
    || { echo "[release] Error: the requested signing secret key is unavailable." >&2; exit 1; }
public_fingerprints=$(LC_ALL=C gpg --batch --with-colons --list-keys "$RELEASE_PRIMARY_FINGERPRINT" 2>/dev/null \
    | awk -F: '$1 == "fpr" {print toupper($10)}')
grep -qx "$RELEASE_PRIMARY_FINGERPRINT" <<<"$public_fingerprints" \
    || { echo "[release] Error: the requested release primary key is unavailable." >&2; exit 1; }

profile_id=$(jq -r '.profile_id // empty' "${PAYLOAD_DIR}/profile.json")
[[ "$profile_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || { echo "[release] Error: prepared profile ID is invalid." >&2; exit 1; }
bundle_name="glibcx-runtime-${profile_id}.tar.xz"
source_name="glibcx-runtime-${profile_id}-source.tar.xz"
expected_source_url="${RELEASE_BASE_URL}/${source_name}"
[[ "$(jq -r '.build.corresponding_source_url // empty' "${PAYLOAD_DIR}/profile.json")" \
    == "$expected_source_url" ]] || {
    echo "[release] Error: profile corresponding-source URL does not match this immutable release." >&2
    exit 1
}

output_parent=$(dirname "$OUTPUT_DIR")
output_name=$(basename "$OUTPUT_DIR")
mkdir -p "$output_parent"
release_stage=$(mktemp -d "${output_parent}/.release-assets.XXXXXX")
profile_stage=$(mktemp -d "${output_parent}/.profile-bundle.XXXXXX")
cleanup() {
    [[ -d "${release_stage:-}" ]] && rm -rf "${release_stage:?}"
    [[ -d "${profile_stage:-}" ]] && rm -rf "${profile_stage:?}"
}
trap cleanup EXIT

cp -a "${PAYLOAD_DIR}/." "$profile_stage/"
if [[ -e "${profile_stage}/profile.json.asc" || -e "${profile_stage}/manifest.json" ]]; then
    echo "[release] Error: payload contains generated trust state; start from an unsigned prepared payload." >&2
    exit 1
fi

sign_file() {
    local input_file="$1" output_file="$2"
    LC_ALL=C gpg --batch --yes --armor --detach-sign \
        --faked-system-time "${SOURCE_DATE_EPOCH}!" \
        --local-user "${SIGNING_KEY_FINGERPRINT}!" \
        --output "$output_file" "$input_file"
}

sign_file "${profile_stage}/profile.json" "${profile_stage}/profile.json.asc"
chmod 644 "${profile_stage}/profile.json.asc"

LC_ALL=C tar --sort=name --mtime="@${SOURCE_DATE_EPOCH}" \
    --owner=0 --group=0 --numeric-owner --format=posix \
    --pax-option=delete=atime,delete=ctime \
    -cJf "${release_stage}/${bundle_name}" -C "$profile_stage" .
LC_ALL=C tar --sort=name --mtime="@${SOURCE_DATE_EPOCH}" \
    --owner=0 --group=0 --numeric-owner --format=posix \
    --pax-option=delete=atime,delete=ctime \
    -cJf "${release_stage}/${source_name}" -C "$SOURCE_DIR" .
sign_file "${release_stage}/${bundle_name}" "${release_stage}/${bundle_name}.asc"
sign_file "${release_stage}/${source_name}" "${release_stage}/${source_name}.asc"

install -m 755 "$GLIBCX_BINARY" "${release_stage}/glibcx"
LC_ALL=C sha256sum "${release_stage}/glibcx" \
    | LC_ALL=C awk '{print $1 "  glibcx"}' >"${release_stage}/glibcx.sha256"
sign_file "${release_stage}/glibcx" "${release_stage}/glibcx.asc"
LC_ALL=C gpg --batch --export "$RELEASE_PRIMARY_FINGERPRINT" \
    >"${release_stage}/glibcx-release.gpg"
[[ -s "${release_stage}/glibcx-release.gpg" ]] \
    || { echo "[release] Error: exported release public key is empty." >&2; exit 1; }

published_at=$(date -u -d "@${SOURCE_DATE_EPOCH}" '+%Y-%m-%dT%H:%M:%SZ')
expires_epoch=$((SOURCE_DATE_EPOCH + 180 * 24 * 60 * 60))
expires_at=$(date -u -d "@${expires_epoch}" '+%Y-%m-%dT%H:%M:%SZ')
profile_hash=$(LC_ALL=C sha256sum "${profile_stage}/profile.json" | LC_ALL=C awk '{print $1}')
bundle_hash=$(LC_ALL=C sha256sum "${release_stage}/${bundle_name}" | LC_ALL=C awk '{print $1}')
source_hash=$(LC_ALL=C sha256sum "${release_stage}/${source_name}" | LC_ALL=C awk '{print $1}')
catalog_name=glibcx-profiles-v1.json
jq -n \
    --argjson catalog_version "$CATALOG_VERSION" \
    --arg issued_at "$published_at" \
    --arg published_at "$published_at" \
    --arg expires_at "$expires_at" \
    --arg min_glibcx_version "$MIN_GLIBCX_VERSION" \
    --arg signing_subkey_fingerprint "$SIGNING_KEY_FINGERPRINT" \
    --arg profile_id "$profile_id" \
    --argjson priority "$PROFILE_PRIORITY" \
    --arg security_state "$PROFILE_SECURITY_STATE" \
    --arg manifest_hash "$profile_hash" \
    --arg bundle_url "${RELEASE_BASE_URL}/${bundle_name}" \
    --arg bundle_signature_url "${RELEASE_BASE_URL}/${bundle_name}.asc" \
    --arg bundle_hash "$bundle_hash" \
    --arg source_url "${RELEASE_BASE_URL}/${source_name}" \
    --arg source_signature_url "${RELEASE_BASE_URL}/${source_name}.asc" \
    --arg source_hash "$source_hash" \
    '{
        schema: 1,
        catalog_version: $catalog_version,
        issued_at: $issued_at,
        published_at: $published_at,
        expires_at: $expires_at,
        min_glibcx_version: $min_glibcx_version,
        signing_subkey_fingerprint: $signing_subkey_fingerprint,
        profile_compatibility_schema: 1,
        profiles: [{
            profile_id: $profile_id,
            architecture: "aarch64",
            priority: $priority,
            security_state: $security_state,
            manifest_sha256: $manifest_hash,
            bundle: {
                url: $bundle_url,
                signature_url: $bundle_signature_url,
                sha256: $bundle_hash
            },
            corresponding_source: {
                url: $source_url,
                signature_url: $source_signature_url,
                sha256: $source_hash
            }
        }]
    }' >"${release_stage}/${catalog_name}"
sign_file "${release_stage}/${catalog_name}" "${release_stage}/${catalog_name}.asc"

find "$release_stage" -type f -exec chmod 644 {} +
chmod 755 "${release_stage}/glibcx"
mv "$release_stage" "${output_parent}/${output_name}"
release_stage=""
echo "[release] Signed versioned release assets: $OUTPUT_DIR"
