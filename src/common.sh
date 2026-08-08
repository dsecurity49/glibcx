GLIBC_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}/glibc"
GLIBC_INTERPRETER="${GLIBC_PREFIX}/lib/ld-linux-aarch64.so.1"
GLIBC_LIB_DIR="${GLIBC_PREFIX}/lib"
CLI_STORAGE="${HOME:-/data/data/com.termux/files/home}/.glibcx"
REGISTRY_FILE="${CLI_STORAGE}/registry.json"

# Registry schema (per blueprint):
#   key   = absolute binary_path
#   value = { orig_hash, patched_fingerprint, glibc_required, patched_at }

init_env() {
    mkdir -p "${CLI_STORAGE}/bin" "${CLI_STORAGE}/storage" "${CLI_STORAGE}/logs" "${CLI_STORAGE}/opt"
    if [[ ! -f "$REGISTRY_FILE" ]]; then
        echo "{}" > "$REGISTRY_FILE"
    fi
}

# Drift fingerprint: file identity + size + mtime + ctime.  This catches
# in-place rewrites even when an updater preserves the original mtime.
_fingerprint() {
    stat -c '%d_%i_%s_%Y_%Z' "$1" 2>/dev/null || echo "missing"
}

# Return success only for an AArch64 ELF. Providers use this before offering a
# downloaded executable to cmd_patch, so a mixed-architecture archive does not
# abort an otherwise usable install.
_is_aarch64_elf() {
    file "$1" 2>/dev/null | grep -qE 'ELF 64-bit LSB.*(aarch64|ARM aarch64)'
}

# json_update_entry <binary_path> <orig_hash> <patched_fp> <glibc_required>
json_update_entry() {
    local path="$1" orig="$2" fp="$3" glibc="$4"
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u)
    if command -v jq >/dev/null 2>&1; then
        local tmp
        tmp="$(mktemp)"
        jq --arg path "$path" --arg orig "$orig" --arg fp "$fp" \
           --arg glibc "$glibc" --arg ts "$ts" \
           '.[$path] = {orig_hash: $orig, patched_fingerprint: $fp, glibc_required: $glibc, patched_at: $ts}' \
           "$REGISTRY_FILE" > "$tmp"
        mv "$tmp" "$REGISTRY_FILE"
    else
        python3 -c '
import json, sys, datetime
f, path, orig, fp, glibc = sys.argv[1:6]
try:
    with open(f) as fh: data = json.load(fh)
except Exception: data = {}
data[path] = {
    "orig_hash": orig,
    "patched_fingerprint": fp,
    "glibc_required": glibc,
    "patched_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
}
with open(f, "w") as fh: json.dump(data, fh, indent=2)
' "$REGISTRY_FILE" "$path" "$orig" "$fp" "$glibc"
    fi
}

json_delete_entry() {
    local path="$1"
    if command -v jq >/dev/null 2>&1; then
        local tmp
        tmp="$(mktemp)"
        jq --arg p "$path" 'del(.[$p])' "$REGISTRY_FILE" > "$tmp"
        mv "$tmp" "$REGISTRY_FILE"
    else
        python3 -c '
import json, sys
f, path = sys.argv[1:3]
try:
    with open(f) as fh: data = json.load(fh)
    data.pop(path, None)
    with open(f, "w") as fh: json.dump(data, fh, indent=2)
except Exception: pass
' "$REGISTRY_FILE" "$path"
    fi
}

# json_get_val <binary_path> <field>
json_get_val() {
    local path="$1" key="$2"
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg p "$path" '.[$p]['"\"$key\""'] // empty' "$REGISTRY_FILE" 2>/dev/null || echo ""
    else
        python3 -c '
import json, sys
f, path, key = sys.argv[1:4]
try:
    with open(f) as fh: data = json.load(fh)
    print(data.get(path, {}).get(key, ""))
except Exception: print("")
' "$REGISTRY_FILE" "$path" "$key"
    fi
}

# json_list_entries — prints human-readable table
json_list_entries() {
    if command -v jq >/dev/null 2>&1; then
        jq -r 'to_entries[]
            | "  \(.key)\n    glibc required : \(.value.glibc_required)\n    patched at     : \(.value.patched_at)\n    fingerprint    : \(.value.patched_fingerprint)"' \
            "$REGISTRY_FILE"
    else
        python3 -c '
import json, sys
f = sys.argv[1]
try:
    with open(f) as fh: data = json.load(fh)
    if not data:
        print("  No patched binaries registered.")
    for path, v in data.items():
        print(f"  {path}")
        print(f"    glibc required : {v.get(\"glibc_required\", \"\")}")
        print(f"    patched at     : {v.get(\"patched_at\", \"\")}")
        print(f"    fingerprint    : {v.get(\"patched_fingerprint\", \"\")}")
except Exception:
    print("  No patched binaries registered.")
' "$REGISTRY_FILE"
    fi
}

# json_list_paths — emit one absolute path per line (for iteration)
json_list_paths() {
    if command -v jq >/dev/null 2>&1; then
        jq -r 'keys[]' "$REGISTRY_FILE" 2>/dev/null || true
    else
        python3 -c '
import json, sys
f = sys.argv[1]
try:
    with open(f) as fh: data = json.load(fh)
    for k in data: print(k)
except Exception: pass
' "$REGISTRY_FILE"
    fi
}
