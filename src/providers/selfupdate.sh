_GLIBCX_UPDATE_TMP_BIN=""
_GLIBCX_UPDATE_TMP_SUM=""

_cleanup_selfupdate() {
    [[ -n "${_GLIBCX_UPDATE_TMP_BIN:-}" ]] && rm -f "${_GLIBCX_UPDATE_TMP_BIN:?}"
    [[ -n "${_GLIBCX_UPDATE_TMP_SUM:-}" ]] && rm -f "${_GLIBCX_UPDATE_TMP_SUM:?}"
}

cmd_selfupdate() {
    local FORCE=0
    for arg in "$@"; do
        case "$arg" in
            --force) FORCE=1 ;;
            *) echo "[glibcx] Error: Unknown option '$arg' (expected: --force)" >&2; exit 1 ;;
        esac
    done

    local REPO="dsecurity49/glibcx"
    local API_URL="https://api.github.com/repos/${REPO}/releases/latest"

    echo "[glibcx] Checking for updates..."

    if ! command -v jq >/dev/null 2>&1; then
        echo "[glibcx] Error: 'jq' is required. Run 'glibcx setup' first." >&2
        exit 1
    fi

    local release_json
    if ! release_json=$(curl -fsSL "$API_URL"); then
        echo "[glibcx] Error: Could not fetch latest release. Check your connection or wait for the first GitHub Release to be published." >&2
        exit 1
    fi

    local latest_tag
    latest_tag=$(echo "$release_json" | jq -r '.tag_name')

    if [[ -z "$latest_tag" || "$latest_tag" == "null" ]]; then
        echo "[glibcx] Error: Could not determine latest release version." >&2
        exit 1
    fi

    # Retrieve current version by running the executable itself
    local current_version
    current_version=$("$0" --help | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || echo "unknown")

    if [[ "$FORCE" -ne 1 && "$latest_tag" == "$current_version" ]]; then
        echo "[glibcx] You are already on the latest version ($current_version)."
        return 0
    fi

    if [[ "$FORCE" -eq 1 && "$latest_tag" == "$current_version" ]]; then
        echo "[glibcx] Already on $current_version. --force specified, re-downloading anyway."
    else
        echo "[glibcx] New version found: $latest_tag (current: $current_version)"
    fi

    local asset_url checksum_url
    asset_url=$(echo "$release_json" | jq -r '.assets[] | select(.name == "glibcx") | .browser_download_url' | head -n1)
    checksum_url=$(echo "$release_json" | jq -r '.assets[] | select(.name == "glibcx.sha256") | .browser_download_url' | head -n1)

    if [[ -z "$asset_url" || "$asset_url" == "null" ]]; then
        echo "[glibcx] Error: Could not find 'glibcx' binary asset in latest release." >&2
        exit 1
    fi

    local exe_path
    exe_path="$(realpath "$0")"

    if [[ ! -w "$exe_path" ]]; then
        echo "[glibcx] Error: Current executable ($exe_path) is not writable." >&2
        echo "[glibcx] Please update manually or run with appropriate permissions." >&2
        exit 1
    fi

    echo "[glibcx] Downloading $latest_tag..."
    local tmp_bin tmp_sum
    tmp_bin="$(mktemp)"
    tmp_sum="$(mktemp)"
    _GLIBCX_UPDATE_TMP_BIN="$tmp_bin"
    _GLIBCX_UPDATE_TMP_SUM="$tmp_sum"
    trap _cleanup_selfupdate EXIT

    if ! curl -fSL --progress-bar "$asset_url" -o "$tmp_bin"; then
        echo "[glibcx] Error: Download failed." >&2
        exit 1
    fi

    if [[ -n "$checksum_url" && "$checksum_url" != "null" ]]; then
        if ! curl -fsSL "$checksum_url" -o "$tmp_sum"; then
            echo "[glibcx] Error: Failed to download checksum file." >&2
            exit 1
        fi

        local expected_sum actual_sum
        expected_sum=$(grep -w "glibcx" "$tmp_sum" | awk '{print $1}')
        actual_sum=$(sha256sum "$tmp_bin" | awk '{print $1}')

        if [[ "$expected_sum" != "$actual_sum" ]]; then
            echo "" >&2
            echo "Expected: $expected_sum" >&2
            echo "Actual  : $actual_sum" >&2
            echo "[glibcx] Checksum mismatch! Download may be corrupted or tampered." >&2
            exit 1
        fi
        echo "[glibcx] Checksum verified successfully."
    else
        echo "[glibcx] WARNING: No checksum asset (glibcx.sha256) found in release."
        if [[ "$FORCE" -ne 1 ]]; then
            echo "[glibcx] Integrity cannot be verified. Refusing to update." >&2
            echo "[glibcx] Run 'glibcx self-update --force' to bypass this check." >&2
            exit 1
        fi
        echo "[glibcx] --force specified. Proceeding without checksum verification."
    fi

    if ! head -1 "$tmp_bin" | grep -q "bash\|sh"; then
        echo "[glibcx] Error: Downloaded file does not look like a valid glibcx binary." >&2
        exit 1
    fi

    chmod +x "$tmp_bin"
    mv "$tmp_bin" "$exe_path"

    echo "[glibcx] Successfully updated to $latest_tag."
    echo "[glibcx] Run 'glibcx --help' to verify."
}
