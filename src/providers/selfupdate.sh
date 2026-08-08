cmd_selfupdate() {
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

    if [[ "$latest_tag" == "$current_version" ]]; then
        echo "[glibcx] You are already on the latest version ($current_version)."
        return 0
    fi

    echo "[glibcx] New version found: $latest_tag (current: $current_version)"
    
    local asset_url
    asset_url=$(echo "$release_json" | jq -r '.assets[] | select(.name == "glibcx") | .browser_download_url' | head -n1)

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
    local tmp_bin
    tmp_bin="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f \"$tmp_bin\"" EXIT

    if ! curl -fSL --progress-bar "$asset_url" -o "$tmp_bin"; then
        echo "[glibcx] Error: Download failed." >&2
        exit 1
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
