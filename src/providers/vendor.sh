cmd_vendor() {
    local target_bin="${1:-}"
    if [[ $# -gt 0 ]]; then
        shift
    fi
    if [[ -z "$target_bin" || $# -eq 0 ]]; then
        echo "Usage: glibcx vendor <binary_path> <lib1.so> [lib2.so...]" >&2
        echo "Example: glibcx vendor $(which hurl) /path/to/libxml2.so.2" >&2
        exit 1
    fi

    init_env
    target_bin="$(realpath "$target_bin" 2>/dev/null || echo "$target_bin")"

    # If the user passed the wrapper path, resolve it to the original binary via registry
    if [[ "$target_bin" == "${CLI_STORAGE}/bin/"* ]]; then
        local wrapper_base
        wrapper_base="$(basename "$target_bin")"
        local resolved=""
        while IFS= read -r path; do
            [[ -z "$path" ]] && continue
            if [[ "$(basename "$path")" == "$wrapper_base" ]]; then
                resolved="$path"
                break
            fi
        done < <(json_list_paths)
        if [[ -n "$resolved" ]]; then
            target_bin="$resolved"
        fi
    fi

    if [[ -z "$(json_get_val "$target_bin" "orig_hash")" ]]; then
        echo "[glibcx] Error: '$target_bin' is not in the registry. Use 'glibcx patch' first." >&2
        exit 1
    fi

    # Vendored libs are stored in ~/.glibcx/lib/<basename>; refuse ambiguous dirs.
    local bin_name
    bin_name="$(basename "$target_bin")"
    local other_path
    while IFS= read -r other_path; do
        [[ -z "$other_path" ]] && continue
        if [[ "$other_path" != "$target_bin" && "$(basename "$other_path")" == "$bin_name" ]]; then
            echo "[glibcx] Error: '$bin_name' is also registered for a different binary:" >&2
            echo "  $other_path" >&2
            echo "[glibcx] Re-register the conflicting entry first (glibcx clean / restore)." >&2
            exit 1
        fi
    done < <(json_list_paths)

    local lib_dir="${CLI_STORAGE}/lib/${bin_name}"
    mkdir -p "$lib_dir"

    for lib_file in "$@"; do
        if [[ -f "$lib_file" ]]; then
            if ! file "$lib_file" | grep -qE "ELF 64-bit LSB shared object.*(aarch64|ARM aarch64)"; then
                echo "[glibcx] Warning: '$lib_file' does not appear to be an AArch64 shared object. Skipping." >&2
                continue
            fi
            echo "[glibcx] Vendoring $(basename "$lib_file") for $bin_name..."
            cp "$lib_file" "$lib_dir/"
        else
            echo "[glibcx] Warning: Library file not found: $lib_file" >&2
        fi
    done

    echo "[glibcx] Done. Vendored libraries are stored in: $lib_dir"
}
