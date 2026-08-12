_GLIBCX_INTERCEPT_EXISTING=""
_GLIBCX_INTERCEPT_NEW=""

_cleanup_intercept() {
    [[ -n "${_GLIBCX_INTERCEPT_EXISTING:-}" ]] && rm -f "${_GLIBCX_INTERCEPT_EXISTING:?}"
    [[ -n "${_GLIBCX_INTERCEPT_NEW:-}" ]] && rm -f "${_GLIBCX_INTERCEPT_NEW:?}"
}

cmd_intercept() {
    local user_cmd="${1:-}"
    shift || true
    local runtime_request=""
    if [[ -z "$user_cmd" ]]; then
        echo "Usage: glibcx intercept '<command>' [--runtime <id>]" >&2
        echo "Example: glibcx intercept 'curl -fsSL https://bun.sh/install | bash' --runtime system" >&2
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
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
                echo "[glibcx] Error: unknown intercept option '$1'." >&2
                echo "Usage: glibcx intercept '<command>' [--runtime <id>]" >&2
                exit 1
                ;;
        esac
    done

    init_env

    local termux_bin="${PREFIX:-$(dirname "$(command -v pkg 2>/dev/null)" 2>/dev/null || echo /data/data/com.termux/files/usr)/../bin}"
    local mon_dirs=(
        "$HOME/.local/bin"
        "$HOME/bin"
        "$HOME/.bun/bin"
        "$HOME/.cargo/bin"
        "$HOME/.deno/bin"
        "$termux_bin"
    )

    # Allocate both temp files up front so the single trap covers both
    local existing_files new_files
    existing_files=$(mktemp)
    new_files=$(mktemp)
    _GLIBCX_INTERCEPT_EXISTING="$existing_files"
    _GLIBCX_INTERCEPT_NEW="$new_files"
    trap _cleanup_intercept EXIT

    echo "[glibcx] Taking pre-install snapshot of common bin directories..."
    for d in "${mon_dirs[@]}"; do
        [[ -d "$d" ]] && find "$d" -type f -executable \
            -exec env LC_ALL=C stat -c "%n %Y" {} + 2>/dev/null >> "$existing_files" || true
    done
    sort -o "$existing_files" "$existing_files"

    echo "[glibcx] Executing intercepted command:"
    echo " > $user_cmd"
    echo "----------------------------------------"
    local exit_code
    if eval "$user_cmd"; then
        exit_code=0
    else
        exit_code=$?
    fi
    echo "----------------------------------------"

    if [[ $exit_code -ne 0 ]]; then
        echo "[glibcx] Warning: intercepted command exited with code $exit_code." >&2
    fi

    echo "[glibcx] Taking post-install snapshot..."
    for d in "${mon_dirs[@]}"; do
        [[ -d "$d" ]] && find "$d" -type f -executable \
            -exec env LC_ALL=C stat -c "%n %Y" {} + 2>/dev/null >> "$new_files" || true
    done
    sort -o "$new_files" "$new_files"

    local found_any=0
    local patch_args=()
    [[ -n "$runtime_request" ]] && patch_args+=(--runtime "$runtime_request")
    echo "[glibcx] Inspecting new executables..."
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local bin="${line% *}"
        if LC_ALL=C file "$bin" | grep -q "ELF 64-bit LSB"; then
            if ! _is_aarch64_elf "$bin"; then
                echo "[glibcx] Ignored — non-AArch64 ELF: $bin"
                continue
            fi
            found_any=1
            local needed_libs
            needed_libs=$(LC_ALL=C readelf -W -d "$bin" 2>/dev/null | grep NEEDED || true)
            if echo "$needed_libs" | grep -qE "libc\.so\.6|ld-linux"; then
                echo "[glibcx] Intercepted new glibc binary: $bin"
                cmd_patch "$bin" "${patch_args[@]}"
            elif echo "$needed_libs" | grep -q "libc\.so"; then
                echo "[glibcx] Ignored — Bionic/native binary (links Bionic libc.so): $bin"
            else
                echo "[glibcx] Ignored — no libc NEEDED entry: $bin"
            fi
        fi
    done < <(comm -13 "$existing_files" "$new_files")

    if [[ "$found_any" -eq 0 ]]; then
        echo "[glibcx] No new glibc ELF executables detected in monitored directories."
    else
        echo "[glibcx] Intercept complete."
    fi
}
