_setup_offer_phantom_process_limit() {
    local sdk response

    command -v rish >/dev/null 2>&1 || return 0
    sdk=$(getprop ro.build.version.sdk 2>/dev/null || true)
    [[ "$sdk" =~ ^[0-9]+$ ]] && (( sdk >= 31 )) || return 0
    [[ -t 0 && -t 1 ]] || return 0

    cat <<'NOTICE'
[glibcx] Android may stop large process trees through its phantom-process limit.
[glibcx] Shizuku can raise that limit. This changes an Android system setting
[glibcx] and is not required for ordinary use. glibcx would run:
[glibcx]   device_config put activity_manager max_phantom_processes 2147483647
NOTICE
    printf '[glibcx] Raise the phantom-process limit? [y/N] '
    read -r response || response=""
    case "${response,,}" in
        y|yes)
            if rish -c "device_config put activity_manager max_phantom_processes 2147483647"; then
                echo "[glibcx] Phantom-process limit raised. Restore Android's default with:"
                echo '[glibcx]   rish -c "device_config delete activity_manager max_phantom_processes"'
            else
                echo "[glibcx] Warning: Shizuku could not change the phantom-process limit." >&2
            fi
            ;;
    esac
}

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

    _setup_offer_phantom_process_limit

    echo "[glibcx] Setup complete. Restart your shell or run: source ~/.bashrc"
}
