_GLIBCX_FETCH_TMP_DIR=""

_cleanup_fetch() {
    [[ -n "${_GLIBCX_FETCH_TMP_DIR:-}" ]] && rm -rf "${_GLIBCX_FETCH_TMP_DIR:?}"
}

_fetch_download() {
    local url="$1" destination="$2"
    curl -fSL \
        --retry 5 \
        --retry-all-errors \
        --retry-delay 2 \
        --retry-max-time 120 \
        --progress-bar \
        "$url" -o "$destination"
}

_fetch_archive_validate() {
    local archive_file="$1" archive_kind="$2" list_file verbose_file member normalized
    list_file=$(mktemp "${TMP_DIR}/provider-archive-list.XXXXXX")
    verbose_file=$(mktemp "${TMP_DIR}/provider-archive-types.XXXXXX")
    if [[ "$archive_kind" == zip ]]; then
        if ! LC_ALL=C unzip -Z1 "$archive_file" >"$list_file"; then
            echo "[glibcx] Error: ZIP archive cannot be listed safely." >&2
            rm -f "$list_file" "$verbose_file"
            return 1
        fi
    else
        if ! LC_ALL=C tar -tf "$archive_file" >"$list_file" \
            || ! LC_ALL=C tar -tvf "$archive_file" >"$verbose_file"; then
            echo "[glibcx] Error: tar archive cannot be listed safely." >&2
            rm -f "$list_file" "$verbose_file"
            return 1
        fi
        if ! awk 'substr($0, 1, 1) !~ /^[-dl]$/ {exit 1}' "$verbose_file"; then
            echo "[glibcx] Error: archive contains a special file or hard link." >&2
            rm -f "$list_file" "$verbose_file"
            return 1
        fi
    fi
    while IFS= read -r member; do
        normalized=${member#./}
        normalized=${normalized%/}
        [[ -z "$normalized" ]] && continue
        if ! _runtime_safe_relative_path "$normalized"; then
            echo "[glibcx] Error: unsafe archive path '$member'." >&2
            rm -f "$list_file" "$verbose_file"
            return 1
        fi
    done <"$list_file"
    rm -f "$list_file" "$verbose_file"
}

_fetch_tree_validate() {
    local tree_root="$1" node relative_path link_target resolved
    while IFS= read -r -d '' node; do
        relative_path=${node#"${tree_root}/"}
        if ! _runtime_safe_relative_path "$relative_path"; then
            echo "[glibcx] Error: extracted tree contains an unsafe path." >&2
            return 1
        fi
        if [[ -L "$node" ]]; then
            link_target=$(readlink "$node")
            resolved=$(realpath -m "$(dirname "$node")/${link_target}")
            if [[ "$link_target" == /* \
                || ( "$resolved" != "$tree_root" && "$resolved" != "${tree_root}/"* ) ]]; then
                echo "[glibcx] Error: extracted symlink escapes its archive root: $relative_path" >&2
                return 1
            fi
        elif [[ ! -f "$node" && ! -d "$node" ]]; then
            echo "[glibcx] Error: extracted tree contains a special file: $relative_path" >&2
            return 1
        fi
    done < <(find "$tree_root" -mindepth 1 -print0)
}

cmd_fetch() {
    local url="${1:-}"
    shift || true
    local custom_name=""
    local runtime_request=""
    if [[ -z "$url" ]]; then
        echo "Usage: glibcx fetch <url> [--runtime <id>]" >&2
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)
                [[ $# -ge 2 ]] || { echo "[glibcx] Error: --name requires a value." >&2; exit 1; }
                custom_name="$2"
                shift 2
                ;;
            --runtime)
                [[ $# -ge 2 ]] || { echo "[glibcx] Error: --runtime requires an ID." >&2; exit 1; }
                runtime_request="$2"
                shift 2
                ;;
            --runtime=*)
                runtime_request="${1#*=}"
                [[ -n "$runtime_request" ]] || { echo "[glibcx] Error: --runtime requires an ID." >&2; exit 1; }
                shift
                ;;
            *)
                echo "[glibcx] Error: unknown fetch option '$1'." >&2
                echo "Usage: glibcx fetch <url> [--runtime <id>]" >&2
                exit 1
                ;;
        esac
    done

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
    if ! _fetch_download "$url" "$tmp_dir/$filename"; then
        echo "[glibcx] Error: Download failed for $url" >&2
        exit 1
    fi

    local ext_dir="$tmp_dir/ext"
    mkdir -p "$ext_dir"

    echo "[glibcx] Extracting..."
    if [[ "$filename" == *.tar.gz || "$filename" == *.tgz ]]; then
        _fetch_archive_validate "$tmp_dir/$filename" tar
        tar -xzf "$tmp_dir/$filename" --no-same-owner --no-same-permissions -C "$ext_dir"
    elif [[ "$filename" == *.tar.xz ]]; then
        _fetch_archive_validate "$tmp_dir/$filename" tar
        tar -xJf "$tmp_dir/$filename" --no-same-owner --no-same-permissions -C "$ext_dir"
    elif [[ "$filename" == *.tar.bz2 ]]; then
        _fetch_archive_validate "$tmp_dir/$filename" tar
        tar -xjf "$tmp_dir/$filename" --no-same-owner --no-same-permissions -C "$ext_dir"
    elif [[ "$filename" == *.tar.zst ]]; then
        _fetch_archive_validate "$tmp_dir/$filename" tar
        tar --use-compress-program=zstd -xf "$tmp_dir/$filename" \
            --no-same-owner --no-same-permissions -C "$ext_dir"
    elif [[ "$filename" == *.zip ]]; then
        if ! command -v unzip >/dev/null 2>&1; then
            echo "[glibcx] Installing unzip..."
            pkg install unzip -y
        fi
        _fetch_archive_validate "$tmp_dir/$filename" zip
        unzip -q "$tmp_dir/$filename" -d "$ext_dir"
    elif [[ "$filename" == *.gz ]]; then
        gunzip -c "$tmp_dir/$filename" > "$ext_dir/${filename%.gz}"
        chmod +x "$ext_dir/${filename%.gz}"
    else
        # Assume raw binary
        cp "$tmp_dir/$filename" "$ext_dir/$filename"
        chmod +x "$ext_dir/$filename"
    fi
    _fetch_tree_validate "$ext_dir"

    local install_dir="${CLI_STORAGE}/opt/${safe_name}"
    rm -rf "${install_dir:?}"
    mkdir -p "$install_dir"
    cp -a "$ext_dir/." "$install_dir/"

    echo "[glibcx] Searching for executables in $install_dir ..."
    local found_any=0
    while IFS= read -r bin; do
        if LC_ALL=C file "$bin" | grep -q "ELF 64-bit LSB"; then
            if ! _is_aarch64_elf "$bin"; then
                echo "[glibcx] Skipping non-AArch64 ELF: $(basename "$bin")" >&2
                continue
            fi
            found_any=1
            # glibc binaries have libc.so.6 in NEEDED; Bionic has libc.so without version
            if LC_ALL=C readelf -W -d "$bin" 2>/dev/null | grep -q "libc.so.6"; then
                echo "[glibcx] Auto-patching glibc binary: $(basename "$bin")"
                local patch_args=()
                [[ -n "$runtime_request" ]] && patch_args+=(--runtime "$runtime_request")
                cmd_patch "$bin" "${patch_args[@]}"
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
