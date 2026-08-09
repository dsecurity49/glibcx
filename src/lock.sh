# lock_acquire <output-variable> <lock-name> [shared]
#
# File descriptors are deliberately returned to the caller instead of hidden
# behind a subshell: flock locks are tied to the live descriptor.
lock_acquire() {
    local output_var="$1" lock_name="$2" lock_mode="${3:-exclusive}"
    local lock_fd

    case "$lock_name" in
        ""|*/*|*'..'*)
            echo "[glibcx] Error: invalid lock name '$lock_name'." >&2
            return 1
            ;;
    esac

    mkdir -p "$LOCK_DIR"
    exec {lock_fd}>"${LOCK_DIR}/${lock_name}.lock"
    if [[ "$lock_mode" == "shared" ]]; then
        flock -s "$lock_fd"
    else
        flock -x "$lock_fd"
    fi
    printf -v "$output_var" '%s' "$lock_fd"
}

lock_release() {
    local lock_fd="${1:-}"
    if [[ -n "$lock_fd" ]]; then
        flock -u "$lock_fd" 2>/dev/null || true
        exec {lock_fd}>&-
    fi
}

lock_target_name() {
    printf 'target-%s\n' "$(_sha256_text "$1")"
}

lock_app_name() {
    printf 'app-%s\n' "$(_sha256_text "$1")"
}
