cmd_setup() {
    echo "[glibcx] Initializing setup and prerequisites..."
    pkg update -y
    pkg install glibc-repo -y
    pkg update -y
    pkg install glibc-runner binutils file jq clang curl nodejs util-linux gnupg -y

    init_env

    local path_line='export PATH="$HOME/.glibcx/bin:$PATH"'
    for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
        if [[ -f "$rc" ]]; then
            if ! grep -qs "glibcx/bin" "$rc"; then
                printf '\n# glibcx binary path\n%s\n' "$path_line" >> "$rc"
                echo "[glibcx] Appended PATH export to $rc"
            fi
        elif [[ "$rc" == "${HOME}/.bashrc" ]]; then
            printf '# glibcx binary path\n%s\n' "$path_line" > "$rc"
            echo "[glibcx] Created $rc with PATH export"
        fi
    done

    if command -v rish >/dev/null 2>&1; then
        echo "[glibcx] Shizuku (rish) detected. Lifting Android 12+ phantom process cap..."
        rish -c "device_config put activity_manager max_phantom_processes 2147483647" || true
        echo "[glibcx] Phantom process cap lifted."
    else
        echo "[glibcx] WARNING: 'rish' not found. On Android 12+, heavy workloads may be killed"
        echo "[glibcx]   by the phantom process killer. To fix:"
        echo "[glibcx]   1. Install Shizuku from Play Store"
        echo "[glibcx]   2. Pair via wireless debugging (Settings > Developer options)"
        echo "[glibcx]   3. Re-run 'glibcx setup'"
    fi

    echo "[glibcx] Setup complete. Restart your shell or run: source ~/.bashrc"
}
