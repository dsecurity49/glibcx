#!/usr/bin/env bash
# Prepare an unsigned managed-runtime payload from a glibc tree that was built
# by the Android-patched Termux glibc recipe for FINAL_PREFIX. Signing is a
# separate protected release action.
set -euo pipefail

usage() {
    echo "Usage: profiles/prepare-profile.sh <profile-id> <prepared-tree> <final-prefix> <output-dir>" >&2
    exit 1
}

PROFILE_ID="${1:-}"
PREPARED_TREE="${2:-}"
FINAL_PREFIX="${3:-}"
OUTPUT_DIR="${4:-}"
[[ $# -eq 4 ]] || usage
[[ "$PROFILE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || usage
[[ -d "$PREPARED_TREE" && "$FINAL_PREFIX" == /* && -n "$OUTPUT_DIR" ]] || usage

required_build_value() {
    local variable_name="$1" value
    value="${!variable_name:-}"
    if [[ -z "$value" ]]; then
        echo "[profile] Error: required build variable '$variable_name' is unset." >&2
        exit 1
    fi
    printf '%s' "$value"
}

GLIBC_VERSION=$(required_build_value GLIBC_VERSION)
TERMUX_PACKAGE_REVISION=$(required_build_value TERMUX_PACKAGE_REVISION)
TERMUX_GLIBC_COMMIT=$(required_build_value TERMUX_GLIBC_COMMIT)
BUILD_SOURCE_URL=$(required_build_value BUILD_SOURCE_URL)
BUILD_SOURCE_SHA256=$(required_build_value BUILD_SOURCE_SHA256)
CORRESPONDING_SOURCE_URL=$(required_build_value CORRESPONDING_SOURCE_URL)
TOOLCHAIN_DESCRIPTION=$(required_build_value TOOLCHAIN_DESCRIPTION)
TERMUX_PACKAGE_NAME="${TERMUX_PACKAGE_NAME:-com.termux}"
TERMUX_INSTALL_PREFIX="${TERMUX_INSTALL_PREFIX:-/data/data/com.termux/files/usr}"
ANDROID_MIN_API="${ANDROID_MIN_API:-31}"
ANDROID_MAX_API="${ANDROID_MAX_API:-36}"
KERNEL_MIN="${KERNEL_MIN:-4.14}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"

[[ "$TERMUX_GLIBC_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
    || { echo "[profile] Error: TERMUX_GLIBC_COMMIT must be a full SHA-1." >&2; exit 1; }
[[ "$BUILD_SOURCE_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || { echo "[profile] Error: BUILD_SOURCE_SHA256 must be SHA-256." >&2; exit 1; }
[[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] \
    || { echo "[profile] Error: SOURCE_DATE_EPOCH must be a non-negative integer." >&2; exit 1; }
[[ "$ANDROID_MIN_API" =~ ^[0-9]+$ && "$ANDROID_MAX_API" =~ ^[0-9]+$ \
    && "$ANDROID_MIN_API" -ge 31 && "$ANDROID_MAX_API" -ge "$ANDROID_MIN_API" ]] \
    || { echo "[profile] Error: invalid Android API range." >&2; exit 1; }

PAYLOAD_DIR="${OUTPUT_DIR}/${PROFILE_ID}.payload"
if [[ -e "$PAYLOAD_DIR" ]]; then
    echo "[profile] Error: output already exists: $PAYLOAD_DIR" >&2
    exit 1
fi
mkdir -p "$OUTPUT_DIR" "$PAYLOAD_DIR"
chmod 755 "$PAYLOAD_DIR"

for inventory_root in lib etc share; do
    if [[ -d "${PREPARED_TREE}/${inventory_root}" ]]; then
        cp -a "${PREPARED_TREE}/${inventory_root}" "$PAYLOAD_DIR/"
    fi
done
[[ -f "${PAYLOAD_DIR}/lib/ld-linux-aarch64.so.1" \
    && -f "${PAYLOAD_DIR}/lib/libc.so.6" ]] \
    || { echo "[profile] Error: prepared tree lacks the AArch64 loader/libc pair." >&2; exit 1; }
for runtime_core in \
    "${PAYLOAD_DIR}/lib/ld-linux-aarch64.so.1" \
    "${PAYLOAD_DIR}/lib/libc.so.6"; do
    if ! LC_ALL=C readelf -W -h "$runtime_core" 2>/dev/null \
        | awk -F: '
            /Class:/ {if ($2 ~ /ELF64/) class_ok=1}
            /Data:/ {if ($2 ~ /little endian/) data_ok=1}
            /Machine:/ {if ($2 ~ /AArch64/) machine_ok=1}
            END {exit !(class_ok && data_ok && machine_ok)}
        '; then
        echo "[profile] Error: runtime core is not little-endian AArch64 ELF64: $runtime_core" >&2
        exit 1
    fi
done

# SDK-only material is deliberately excluded from the runtime payload.
find "$PAYLOAD_DIR" -type f \( -name '*.a' -o -name '*.o' -o -name '*.la' \) -delete
while IFS= read -r -d '' payload_file; do
    if [[ -x "$payload_file" ]]; then
        chmod 755 "$payload_file"
    else
        chmod 644 "$payload_file"
    fi
done < <(find "$PAYLOAD_DIR" -type f -print0)
chmod 755 "${PAYLOAD_DIR}/lib/ld-linux-aarch64.so.1"

PROC_SHIM_RELATIVE=""
if [[ -n "${PROC_SHIM_BINARY:-}" ]]; then
    [[ -f "$PROC_SHIM_BINARY" ]] \
        || { echo "[profile] Error: PROC_SHIM_BINARY does not exist." >&2; exit 1; }
    if ! LC_ALL=C readelf -W -h "$PROC_SHIM_BINARY" 2>/dev/null \
        | awk -F: '/Class:/{if ($2 !~ /ELF64/) bad=1}
                   /Machine:/{if ($2 !~ /AArch64/) bad=1; found=1}
                   END {exit bad || !found}'; then
        echo "[profile] Error: proc-exe shim is not an AArch64 ELF64 DSO." >&2
        exit 1
    fi
    if ! LC_ALL=C readelf -W -d "$PROC_SHIM_BINARY" 2>/dev/null | grep -q 'libc[.]so[.]6'; then
        echo "[profile] Error: proc-exe shim is not linked to glibc libc.so.6." >&2
        exit 1
    fi
    PROC_SHIM_RELATIVE="lib/glibcx-proc-exe-shim.so"
    cp -p "$PROC_SHIM_BINARY" "${PAYLOAD_DIR}/${PROC_SHIM_RELATIVE}"
    chmod 755 "${PAYLOAD_DIR}/${PROC_SHIM_RELATIVE}"
fi

LOADER_AUDIT_BINARY=$(required_build_value LOADER_AUDIT_BINARY)
[[ -f "$LOADER_AUDIT_BINARY" ]] \
    || { echo "[profile] Error: LOADER_AUDIT_BINARY does not exist." >&2; exit 1; }
if ! LC_ALL=C readelf -W -h "$LOADER_AUDIT_BINARY" 2>/dev/null \
    | awk -F: '/Class:/{if ($2 !~ /ELF64/) bad=1}
               /Machine:/{if ($2 !~ /AArch64/) bad=1; found=1}
               END {exit bad || !found}'; then
    echo "[profile] Error: loader-audit module is not an AArch64 ELF64 DSO." >&2
    exit 1
fi
if LC_ALL=C readelf -W -d "$LOADER_AUDIT_BINARY" 2>/dev/null | grep -q '(NEEDED)'; then
    echo "[profile] Error: loader-audit module must not have DT_NEEDED entries." >&2
    exit 1
fi
LOADER_AUDIT_RELATIVE="lib/glibcx-loader-audit.so"
cp -p "$LOADER_AUDIT_BINARY" "${PAYLOAD_DIR}/${LOADER_AUDIT_RELATIVE}"
chmod 755 "${PAYLOAD_DIR}/${LOADER_AUDIT_RELATIVE}"

records_file=$(mktemp)
versions_file=$(mktemp)
cleanup() { rm -f "${records_file:?}" "${versions_file:?}"; }
trap cleanup EXIT
: >"$records_file"
: >"$versions_file"

while IFS= read -r -d '' payload_file; do
    relative_path=${payload_file#"${PAYLOAD_DIR}/"}
    file_hash=$(LC_ALL=C sha256sum "$payload_file" | LC_ALL=C awk '{print $1}')
    file_mode=$(LC_ALL=C stat -c '%a' "$payload_file")
    case "$file_mode" in 644|755) ;; *)
        echo "[profile] Error: unsupported file mode $file_mode for $relative_path" >&2
        exit 1
    esac
    printf '%s\tfile\t%s\t%s\n' "$relative_path" "$file_hash" "$file_mode" >>"$records_file"
    LC_ALL=C readelf -W -V "$payload_file" 2>/dev/null \
        | grep -oE 'GLIBC_ABI_[A-Za-z0-9_.]+|GLIBC_[0-9][A-Za-z0-9_.]*|GLIBCXX_[0-9][A-Za-z0-9_.]*|CXXABI_[0-9][A-Za-z0-9_.]*|GCC_[0-9][A-Za-z0-9_.]*' \
        >>"$versions_file" || true
done < <(find "$PAYLOAD_DIR" -type f -print0 | LC_ALL=C sort -z)

while IFS= read -r -d '' payload_link; do
    relative_path=${payload_link#"${PAYLOAD_DIR}/"}
    link_target=$(readlink "$payload_link")
    if [[ "$link_target" == /* ]]; then
        echo "[profile] Error: symlink target must be relative: $relative_path" >&2
        exit 1
    fi
    resolved_target=$(realpath -m "$(dirname "$payload_link")/${link_target}")
    [[ "$resolved_target" == "$PAYLOAD_DIR" || "$resolved_target" == "${PAYLOAD_DIR}/"* ]] \
        || { echo "[profile] Error: symlink escapes payload: $relative_path" >&2; exit 1; }
    printf '%s\tsymlink\t%s\t\n' "$relative_path" "$link_target" >>"$records_file"
done < <(find "$PAYLOAD_DIR" -type l -print0 | LC_ALL=C sort -z)

files_json=$(LC_ALL=C sort "$records_file" | jq -Rn '[
    inputs | split("\t")
    | if .[1] == "file"
      then {path: .[0], type: "file", sha256: .[2], mode: .[3]}
      else {path: .[0], type: "symlink", target: .[2]}
      end
]')
versions_json=$(LC_ALL=C sort -uV "$versions_file" \
    | jq -Rsc 'split("\n") | map(select(length > 0))')
created_at=$(date -u -d "@${SOURCE_DATE_EPOCH}" '+%Y-%m-%dT%H:%M:%SZ')
proc_shim_json=null
if [[ -n "$PROC_SHIM_RELATIVE" ]]; then
    proc_shim_json=$(jq -n \
        --arg path "${FINAL_PREFIX}/${PROC_SHIM_RELATIVE}" \
        --arg hash "$(LC_ALL=C sha256sum "${PAYLOAD_DIR}/${PROC_SHIM_RELATIVE}" \
            | LC_ALL=C awk '{print $1}')" \
        '{path: $path, sha256: $hash, auto_targets: []}')
fi
loader_audit_json=$(jq -n \
    --arg path "${FINAL_PREFIX}/${LOADER_AUDIT_RELATIVE}" \
    --arg hash "$(LC_ALL=C sha256sum "${PAYLOAD_DIR}/${LOADER_AUDIT_RELATIVE}" \
        | LC_ALL=C awk '{print $1}')" \
    '{path: $path, sha256: $hash, protocol: 1, fd: 198}')

jq -n \
    --arg id "$PROFILE_ID" \
    --arg created_at "$created_at" \
    --arg glibc_version "$GLIBC_VERSION" \
    --arg prefix "$FINAL_PREFIX" \
    --arg termux_package "$TERMUX_PACKAGE_NAME" \
    --arg termux_prefix "$TERMUX_INSTALL_PREFIX" \
    --arg termux_revision "$TERMUX_PACKAGE_REVISION" \
    --argjson min_api "$ANDROID_MIN_API" \
    --argjson max_api "$ANDROID_MAX_API" \
    --arg kernel_min "$KERNEL_MIN" \
    --arg source_url "$BUILD_SOURCE_URL" \
    --arg source_hash "$BUILD_SOURCE_SHA256" \
    --arg termux_commit "$TERMUX_GLIBC_COMMIT" \
    --arg source_offer "$CORRESPONDING_SOURCE_URL" \
    --arg toolchain "$TOOLCHAIN_DESCRIPTION" \
    --argjson files "$files_json" \
    --argjson versions "$versions_json" \
    --argjson proc_shim "$proc_shim_json" \
    --argjson loader_audit "$loader_audit_json" \
    '{
        schema: 1,
        compatibility_schema: 2,
        profile_id: $id,
        kind: "managed",
        created_at: $created_at,
        glibc_version: $glibc_version,
        architecture: "aarch64",
        elf_class: "ELF64",
        endianness: "little-endian",
        prefix: $prefix,
        loader: ($prefix + "/lib/ld-linux-aarch64.so.1"),
        library_dirs: [($prefix + "/lib")],
        termux: {package_name: $termux_package, prefix: $termux_prefix, package_revision: $termux_revision},
        android: {min_api: $min_api, max_api: $max_api},
        kernel_min: $kernel_min,
        build: {
            source_url: $source_url,
            source_sha256: $source_hash,
            termux_glibc_commit: $termux_commit,
            corresponding_source_url: $source_offer,
            toolchain: $toolchain,
            licenses: ["LGPL-2.1-or-later", "GPL-2.0-or-later"]
        },
        provided_versions: $versions,
        allowed_tunables: [],
        loader_audit: $loader_audit,
        loader_policy: {glibc_hwcaps_mask: ""},
        files: $files
    } + (if $proc_shim == null then {} else {proc_exe_shim: $proc_shim} end)' \
    >"${PAYLOAD_DIR}/profile.json"
chmod 644 "${PAYLOAD_DIR}/profile.json"

echo "[profile] Prepared unsigned payload: $PAYLOAD_DIR"
echo "[profile] Sign profile.json, create a deterministic .tar.xz, then sign the outer archive in protected release CI."
