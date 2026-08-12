cmd_trace_libs() {
    local target_bin="${1:-}"
    if [[ -z "$target_bin" ]]; then
        echo "Usage: glibcx trace-libs <binary> [-- args...]" >&2
        return 1
    fi
    shift
    [[ "${1:-}" == "--" ]] && shift
    init_env
    target_bin=$(realpath "$target_bin" 2>/dev/null || echo "$target_bin")
    local app_id manifest_path wrapper_path log_file exit_code
    app_id=$(state_get_app_id "$target_bin")
    manifest_path=$(state_get_manifest_path "$target_bin")
    if [[ -z "$app_id" || -z "$manifest_path" || ! -f "$manifest_path" ]]; then
        echo "[glibcx] Error: '$target_bin' is not registered; patch it first." >&2
        return 1
    fi
    wrapper_path=$(jq -r '.wrapper.path' "$manifest_path")
    if [[ ! -x "$wrapper_path" ]]; then
        echo "[glibcx] Error: registered wrapper is missing or not executable: $wrapper_path" >&2
        return 1
    fi
    log_file="${LOG_DIR}/trace-${app_id}-$(_timestamp_slug)-$$.log"
    : >"$log_file"
    chmod 600 "$log_file"
    echo "[glibcx] Executing target with glibc loader tracing enabled."
    echo "[glibcx] Trace log: $log_file"
    if "$wrapper_path" "--glibcx-internal-trace=${app_id}" "$@" \
        2>"$log_file"; then
        exit_code=0
    else
        exit_code=$?
    fi
    cat "$log_file" >&2
    echo "[glibcx] Observed loader file records (observations only; lock unchanged):"
    local observed
    observed=$(LC_ALL=C sed -n 's/^.*file=\([^ ]*\).*$/  \1/p' "$log_file" \
        | LC_ALL=C sort -u)
    if [[ -n "$observed" ]]; then
        printf '%s\n' "$observed"
    else
        echo "  (no loader file records parsed)"
    fi
    return "$exit_code"
}
