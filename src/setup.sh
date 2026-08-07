cmd_setup() {
    echo "[glibcx] Initializing setup and prerequisites..."
    pkg update -y
    pkg install glibc-runner patchelf binutils xxd file jq clang curl nodejs -y

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

    # Fix glibc-runner linker script issue
    # The glibc-runner package ships libc.so as a text linker script (normal for compilation).
    # However, if any library or fallback probes for libc.so at runtime, ld.so will crash
    # with "invalid ELF header". We safely move it and symlink to the real ELF.
    local glibc_lib="${PREFIX}/glibc/lib"
    if [[ -f "${glibc_lib}/libc.so" ]] && ! [[ -L "${glibc_lib}/libc.so" ]]; then
        if file "${glibc_lib}/libc.so" | grep -qi "text"; then
            echo "[glibcx] Applying Termux glibc-runner libc.so text-script fix..."
            mv "${glibc_lib}/libc.so" "${glibc_lib}/libc.so.script"
            ln -s "libc.so.6" "${glibc_lib}/libc.so"
        fi
    fi

    echo "[glibcx] Setup complete. Restart your shell or run: source ~/.bashrc"
}
