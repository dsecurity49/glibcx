cmd_gh() {
    local action="${1:-}"
    local repo="${2:-}"
    if [[ "$action" != "install" || -z "$repo" ]]; then
        echo "Usage: glibcx gh install <owner/repo>" >&2
        exit 1
    fi

    init_env
    if ! command -v jq >/dev/null 2>&1; then
        echo "[glibcx] Error: 'jq' is required. Run 'glibcx setup' first." >&2
        exit 1
    fi

    echo "[glibcx] Querying GitHub for '$repo' latest release..."

    local api_url="https://api.github.com/repos/$repo/releases/latest"
    local curl_args=(-sL)
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        curl_args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
    fi

    local release_json
    release_json=$(curl "${curl_args[@]}" "$api_url")

    if echo "$release_json" | jq -e '.message' >/dev/null 2>&1; then
        local msg
        msg=$(echo "$release_json" | jq -r '.message')
        echo "[glibcx] Error: GitHub API returned: $msg" >&2
        echo "[glibcx] Tip: Set GITHUB_TOKEN to avoid rate limits (60 req/hr unauthenticated)." >&2
        exit 1
    fi

    local bad_ext_filter='[.]sha256$|[.]sha512$|[.]sig$|[.]asc$|[.]deb$|[.]rpm$|[.]AppImage$|[.]json$|[.]txt$'
    local arch_pattern='aarch64|arm64|armv8'

    # 1. Look for a native Android/Bionic asset first
    local android_url
    android_url=$(echo "$release_json" | jq -r \
        --arg bad "$bad_ext_filter" \
        --arg arch "$arch_pattern" \
        '.assets[]
         | select(
             (.name | ascii_downcase | test($bad) | not)
             and (.name | ascii_downcase | test("android"))
             and (.name | ascii_downcase | test($arch))
           )
         | .browser_download_url' | head -n1)

    if [[ -n "$android_url" && "$android_url" != "null" ]]; then
        echo "[glibcx] Native Android asset found, skipping patch."
        echo "[glibcx] Selected asset: $android_url"
        cmd_fetch "$android_url" "${repo##*/}"
        return
    fi

    echo "[glibcx] No native Android asset found, falling back to Linux glibc build..."

    # Select Linux ARM64 GNU (glibc) binaries only.
    # Explicitly EXCLUDE:
    #   - android  (these are Bionic-linked, not glibc)
    #   - musl, gnueabihf, gnu-eabihf  (wrong libc or ABI)
    #   - .deb, .rpm, .sig, checksums, etc. (via bad_ext_filter)
    local asset_url
    asset_url=$(echo "$release_json" | jq -r \
        --arg bad "$bad_ext_filter" \
        --arg arch "$arch_pattern" \
        '.assets[]
         | select(
             (.name | ascii_downcase | test($bad) | not)
             and (.name | ascii_downcase | test("linux"))
             and (.name | ascii_downcase | test($arch))
             and (.name | ascii_downcase | test("android") | not)
             and (.name | ascii_downcase | test("musl|gnueabihf|gnu-eabihf") | not)
           )
         | .browser_download_url' | head -n1)

    if [[ -z "$asset_url" || "$asset_url" == "null" ]]; then
        echo "[glibcx] Error: No suitable Linux ARM64 (glibc) asset found for '$repo'." >&2
        echo "[glibcx] Available assets:" >&2
        echo "$release_json" | jq -r '.assets[].name' | sed 's/^/  /' >&2
        exit 1
    fi

    echo "[glibcx] Selected glibc binary: $asset_url"
    cmd_fetch "$asset_url" "${repo##*/}"
}
