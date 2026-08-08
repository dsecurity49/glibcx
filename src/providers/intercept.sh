cmd_intercept() {
    local user_cmd="${1:-}"
    if [[ -z "$user_cmd" ]]; then
        echo "Usage: glibcx intercept '<command>'" >&2
        echo "Example: glibcx intercept 'curl -fsSL https://bun.sh/install | bash'" >&2
        exit 1
    fi

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
    _intercept_cleanup() { rm -f "$existing_files" "$new_files"; }
    trap _intercept_cleanup EXIT

    echo "[glibcx] Taking pre-install snapshot of common bin directories..."
    for d in "${mon_dirs[@]}"; do
        [[ -d "$d" ]] && find "$d" -type f -executable 2>/dev/null >> "$existing_files" || true
    done
    sort -o "$existing_files" "$existing_files"

    echo "[glibcx] Executing intercepted command:"
    echo " > $user_cmd"
    echo "----------------------------------------"
    eval "$user_cmd"
    local exit_code=$?
    echo "----------------------------------------"

    if [[ $exit_code -ne 0 ]]; then
        echo "[glibcx] Warning: intercepted command exited with code $exit_code." >&2
    fi

    echo "[glibcx] Taking post-install snapshot..."
    for d in "${mon_dirs[@]}"; do
        [[ -d "$d" ]] && find "$d" -type f -executable 2>/dev/null >> "$new_files" || true
    done
    sort -o "$new_files" "$new_files"

    local found_any=0
    echo "[glibcx] Inspecting new executables..."
    while IFS= read -r bin; do
        [[ -z "$bin" ]] && continue
        if file "$bin" | grep -q "ELF 64-bit LSB"; then
            found_any=1
            if readelf -d "$bin" 2>/dev/null | grep -q "libc.so"; then
                echo "[glibcx] Intercepted new glibc binary: $bin"
                cmd_patch "$bin"
            else
                echo "[glibcx] Ignored — Bionic/native binary (no glibc dep): $bin"
            fi
        fi
    done < <(comm -13 "$existing_files" "$new_files")

    if [[ "$found_any" -eq 0 ]]; then
        echo "[glibcx] No new glibc ELF executables detected in monitored directories."
    else
        echo "[glibcx] Intercept complete."
    fi
}
