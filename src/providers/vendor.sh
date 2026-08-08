cmd_vendor() {
    local target_bin="${1:-}"
    shift
    if [[ -z "$target_bin" || $# -eq 0 ]]; then
        echo "Usage: glibcx vendor <binary_path> <lib1.so> [lib2.so...]" >&2
        echo "Example: glibcx vendor $(which hurl) /path/to/libxml2.so.2" >&2
        exit 1
    fi

    init_env
    target_bin="$(realpath "$target_bin" 2>/dev/null || echo "$target_bin")"

    if [[ -z "$(json_get_val "$target_bin" "orig_hash")" ]]; then
        echo "[glibcx] Error: '$target_bin' is not in the registry. Use 'glibcx patch' first." >&2
        exit 1
    fi

    local bin_name
    bin_name="$(basename "$target_bin")"
    local lib_dir="${CLI_STORAGE}/lib/${bin_name}"
    mkdir -p "$lib_dir"

    for lib_file in "$@"; do
        if [[ -f "$lib_file" ]]; then
            echo "[glibcx] Vendoring $(basename "$lib_file") for $bin_name..."
            cp "$lib_file" "$lib_dir/"
        else
            echo "[glibcx] Warning: Library file not found: $lib_file" >&2
        fi
    done

    echo "[glibcx] Done. Vendored libraries are stored in: $lib_dir"
}
