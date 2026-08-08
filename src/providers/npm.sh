_GLIBCX_NPM_TMP_DIR=""
_GLIBCX_NPM_BIN_PATHS_FILE=""

_cleanup_npm() {
    [[ -n "${_GLIBCX_NPM_TMP_DIR:-}" ]] && rm -rf "${_GLIBCX_NPM_TMP_DIR:?}"
    [[ -n "${_GLIBCX_NPM_BIN_PATHS_FILE:-}" ]] && rm -f "${_GLIBCX_NPM_BIN_PATHS_FILE:?}"
}

cmd_npm() {
    local action="${1:-}"
    local raw_pkg="${2:-}"
    if [[ "$action" != "install" || -z "$raw_pkg" ]]; then
        echo "Usage: glibcx npm install <package>" >&2
        exit 1
    fi

    init_env

    if ! command -v npm >/dev/null 2>&1; then
        echo "[glibcx] Error: 'npm' is not installed. Install Node.js via 'pkg install nodejs'." >&2
        exit 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "[glibcx] Error: 'jq' is required. Run 'glibcx setup' first." >&2
        exit 1
    fi

    echo "[glibcx] Resolving NPM package '$raw_pkg'..."
    local target_pkg="$raw_pkg"

    # 1. Check for native Android optional dep
    local opt_deps
    opt_deps=$(npm view "$raw_pkg" optionalDependencies --json 2>/dev/null || echo "{}")

    local android_pkg
    android_pkg=$(echo "$opt_deps" | jq -r 'keys[] | select(test("android-arm64|linux-arm64-android"))' 2>/dev/null | head -n1 || true)

    if [[ -n "$android_pkg" ]]; then
        echo "[glibcx] Notice: Native Android build detected ($android_pkg). Redirecting to npm install -g ..."
        exec npm install -g "$raw_pkg"
    fi

    local arm_pkg
    arm_pkg=$(echo "$opt_deps" | jq -r 'keys[] | select(test("linux-arm64$|linux-aarch64$"))' 2>/dev/null | head -n1 || true)

    if [[ -n "$arm_pkg" ]]; then
        echo "[glibcx] No Android build. Using Linux ARM64 sub-package: $arm_pkg"
        target_pkg="$arm_pkg"
    fi

    # 2. Get the tarball URL and registry-provided content integrity together.
    # Fetching both fields in one query avoids mixing a URL from one version with
    # an integrity value from a later registry update.
    local dist_metadata tarball_url tarball_integrity
    dist_metadata=$(npm view "$target_pkg" dist --json 2>/dev/null || true)
    tarball_url=$(echo "$dist_metadata" | jq -r '.tarball // empty' 2>/dev/null || true)
    tarball_integrity=$(echo "$dist_metadata" | jq -r '.integrity // empty' 2>/dev/null || true)

    if [[ -z "$tarball_url" ]]; then
        echo "[glibcx] Error: Could not resolve tarball URL for '$target_pkg'." >&2
        exit 1
    fi
    if [[ "$tarball_integrity" != sha512-* ]]; then
        echo "[glibcx] Error: '$target_pkg' does not publish a SHA-512 dist.integrity value." >&2
        echo "[glibcx] Refusing an unverifiable direct tarball download." >&2
        exit 1
    fi

    # 3. Download and extract
    echo "[glibcx] Downloading $tarball_url ..."
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    _GLIBCX_NPM_TMP_DIR="$tmp_dir"
    trap _cleanup_npm EXIT

    if ! curl -fSL --progress-bar "$tarball_url" -o "$tmp_dir/package.tgz"; then
        echo "[glibcx] Error: Download failed." >&2
        exit 1
    fi
    local actual_integrity
    if ! actual_integrity=$(node -e '
const crypto = require("crypto");
const fs = require("fs");
console.log("sha512-" + crypto.createHash("sha512").update(fs.readFileSync(process.argv[1])).digest("base64"));
' "$tmp_dir/package.tgz"); then
        echo "[glibcx] Error: Could not calculate tarball integrity." >&2
        exit 1
    fi
    if [[ "$actual_integrity" != "$tarball_integrity" ]]; then
        echo "[glibcx] Error: NPM tarball integrity check failed for '$target_pkg'." >&2
        exit 1
    fi
    echo "[glibcx] Tarball integrity verified."

    echo "[glibcx] Extracting package..."
    mkdir -p "$tmp_dir/ext"
    tar -xzf "$tmp_dir/package.tgz" -C "$tmp_dir/ext"

    local pkg_json="$tmp_dir/ext/package/package.json"
    if [[ ! -f "$pkg_json" ]]; then
        echo "[glibcx] Error: package.json not found in tarball." >&2
        exit 1
    fi

    # 4. Resolve bin paths safely (no word-splitting)
    local bin_paths_file
    bin_paths_file=$(mktemp)
    _GLIBCX_NPM_BIN_PATHS_FILE="$bin_paths_file"
    jq -r '.bin | if type=="string" then . elif type=="object" then to_entries[].value else empty end' \
        "$pkg_json" 2>/dev/null > "$bin_paths_file" || true

    if [[ ! -s "$bin_paths_file" ]]; then
        echo "[glibcx] No 'bin' field. Searching for glibc ELF executables..."
        find "$tmp_dir/ext/package" -type f -executable -exec file {} \; 2>/dev/null \
            | grep "ELF 64-bit" \
            | awk -F: '{print $1}' \
            | sed "s|$tmp_dir/ext/package/||" > "$bin_paths_file" || true
    fi

    if [[ ! -s "$bin_paths_file" ]]; then
        echo "[glibcx] Error: No executables found in '$target_pkg'." >&2
        exit 1
    fi

    # 5. Install package files to permanent location
    local safe_pkg_name="${target_pkg//[^[:alnum:]@._-]/_}"
    if [[ -z "$safe_pkg_name" || "$safe_pkg_name" == "." || "$safe_pkg_name" == ".." ]]; then
        echo "[glibcx] Error: invalid package install name '$target_pkg'." >&2
        exit 1
    fi
    local install_dir="${CLI_STORAGE}/opt/${safe_pkg_name}"
    echo "[glibcx] Installing to $install_dir ..."
    rm -rf "${install_dir:?}"
    mkdir -p "$install_dir"
    cp -r "$tmp_dir/ext/package/"* "$install_dir/"

    # 6. Patch each binary (safe loop — no word-splitting)
    while IFS= read -r b_path; do
        [[ -z "$b_path" ]] && continue
        case "$b_path" in
            /*|..|../*|*/..|*/../*)
                echo "[glibcx] Warning: ignoring unsafe package bin path '$b_path'." >&2
                continue
                ;;
        esac
        local full_bin_path="$install_dir/$b_path"
        if [[ -f "$full_bin_path" ]]; then
            chmod +x "$full_bin_path"
            if _is_aarch64_elf "$full_bin_path"; then
                echo "[glibcx] Patching: $b_path"
                cmd_patch "$full_bin_path"
            elif file "$full_bin_path" | grep -q "ELF 64-bit"; then
                echo "[glibcx] Skipping non-AArch64 ELF: $b_path"
            else
                echo "[glibcx] Skipping non-ELF (script/wrapper): $b_path"
            fi
        else
            echo "[glibcx] Warning: declared binary '$b_path' not found at $full_bin_path"
        fi
    done < "$bin_paths_file"

    rm -f "$bin_paths_file"
    echo "[glibcx] NPM install complete."
}
