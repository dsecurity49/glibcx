_GLIBCX_FETCH_TMP_DIR=""

_cleanup_fetch() {
    [[ -n "${_GLIBCX_FETCH_TMP_DIR:-}" ]] && rm -rf "${_GLIBCX_FETCH_TMP_DIR:?}"
}

cmd_fetch() {
    local url="${1:-}"
    local custom_name="${2:-}"
    if [[ -z "$url" ]]; then
        echo "Usage: glibcx fetch <url>" >&2
        exit 1
    fi

    init_env

    local filename
    filename=$(basename "${url%%\?*}")
    if [[ -z "$filename" || "$filename" == "." || "$filename" == ".." ]]; then
        echo "[glibcx] Error: URL does not contain a safe filename: $url" >&2
        exit 1
    fi

    # Derive a clean name by stripping all known archive extensions
    if [[ -z "$custom_name" ]]; then
        custom_name="$filename"
        custom_name="${custom_name%.tar.gz}"
        custom_name="${custom_name%.tar.xz}"
        custom_name="${custom_name%.tar.bz2}"
        custom_name="${custom_name%.tar.zst}"
        custom_name="${custom_name%.tgz}"
        custom_name="${custom_name%.zip}"
        custom_name="${custom_name%.gz}"
    fi

    local safe_name="${custom_name//[^[:alnum:]._-]/_}"
    if [[ -z "$safe_name" || "$safe_name" == "." || "$safe_name" == ".." ]]; then
        echo "[glibcx] Error: invalid install name '$custom_name'." >&2
        exit 1
    fi
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    _GLIBCX_FETCH_TMP_DIR="$tmp_dir"
    trap _cleanup_fetch EXIT

    echo "[glibcx] Downloading $url ..."
    if ! curl -fSL --progress-bar "$url" -o "$tmp_dir/$filename"; then
        echo "[glibcx] Error: Download failed for $url" >&2
        exit 1
    fi

    local ext_dir="$tmp_dir/ext"
    mkdir -p "$ext_dir"

    echo "[glibcx] Extracting..."
    if [[ "$filename" == *.tar.gz || "$filename" == *.tgz ]]; then
        tar -xzf "$tmp_dir/$filename" -C "$ext_dir"
    elif [[ "$filename" == *.tar.xz ]]; then
        tar -xJf "$tmp_dir/$filename" -C "$ext_dir"
    elif [[ "$filename" == *.tar.bz2 ]]; then
        tar -xjf "$tmp_dir/$filename" -C "$ext_dir"
    elif [[ "$filename" == *.tar.zst ]]; then
        tar --use-compress-program=zstd -xf "$tmp_dir/$filename" -C "$ext_dir"
    elif [[ "$filename" == *.zip ]]; then
        if ! command -v unzip >/dev/null 2>&1; then
            echo "[glibcx] Installing unzip..."
            pkg install unzip -y
        fi
        unzip -q "$tmp_dir/$filename" -d "$ext_dir"
    elif [[ "$filename" == *.gz ]]; then
        gunzip -c "$tmp_dir/$filename" > "$ext_dir/${filename%.gz}"
        chmod +x "$ext_dir/${filename%.gz}"
    else
        # Assume raw binary
        cp "$tmp_dir/$filename" "$ext_dir/$filename"
        chmod +x "$ext_dir/$filename"
    fi

    local install_dir="${CLI_STORAGE}/opt/${safe_name}"
    rm -rf "${install_dir:?}"
    mkdir -p "$install_dir"
    cp -r "$ext_dir/"* "$install_dir/"

    echo "[glibcx] Searching for executables in $install_dir ..."
    local found_any=0
    while IFS= read -r bin; do
        if file "$bin" | grep -q "ELF 64-bit LSB"; then
            if ! _is_aarch64_elf "$bin"; then
                echo "[glibcx] Skipping non-AArch64 ELF: $(basename "$bin")" >&2
                continue
            fi
            found_any=1
            # glibc binaries have libc.so.6 in NEEDED; Bionic has libc.so without version
            if readelf -d "$bin" 2>/dev/null | grep -q "libc.so.6"; then
                echo "[glibcx] Auto-patching glibc binary: $(basename "$bin")"
                cmd_patch "$bin"
            else
                echo "[glibcx] Native/Bionic binary (no glibc dep). Symlinking: $(basename "$bin")"
                ln -sf "$bin" "${CLI_STORAGE}/bin/$(basename "$bin")"
            fi
        fi
    done < <(find "$install_dir" -type f -executable 2>/dev/null)

    if [[ "$found_any" -eq 0 ]]; then
        echo "[glibcx] Error: No ELF 64-bit executables found in archive." >&2
        exit 1
    fi

    echo "[glibcx] Fetch & install complete."
}
