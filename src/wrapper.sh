_loader_clean_env() {
    env -i \
        HOME="${HOME:-/}" \
        PATH="${PATH:-/usr/bin:/bin}" \
        LANG=C.UTF-8 \
        LC_ALL=C.UTF-8 \
        "$@"
}

_loader_normalize_output() {
    local from_path="$1" to_path="$2"
    awk -v from="$from_path" -v to="$to_path" '
        {
            line=$0
            while ((position=index(line, from)) != 0) {
                line=substr(line, 1, position - 1) to substr(line, position + length(from))
            }
            sub(/[[:space:]]+\(0x[0-9A-Fa-f]+\)[[:space:]]*$/, "", line)
            print line
        }
    '
}

_loader_list_paths() {
    awk '
        /=>[[:space:]]*\// {
            line=$0
            sub(/^.*=>[[:space:]]*/, "", line)
            sub(/[[:space:]].*$/, "", line)
            print line
            next
        }
        /^[[:space:]]*\// {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            sub(/[[:space:]].*$/, "", line)
            print line
        }
    '
}

_loader_path_is_allowed() {
    local resolved_path="$1"
    shift
    local allowed_root
    for allowed_root in "$@"; do
        if [[ "$resolved_path" == "$allowed_root" || "$resolved_path" == "${allowed_root}/"* ]]; then
            return 0
        fi
    done
    return 1
}

# loader_verify_target <profile-summary-json> <actual-app-lib> <manifest-app-lib>
#                      <target> <inspection-json>
#
# Emits JSON and never runs target program logic. --verify and --list are
# startup-loader checks only.
loader_verify_target() {
    local profile_json="$1" actual_app_lib="$2" manifest_app_lib="$3"
    local target_bin="$4" inspection="$5"
    local proc_exe_mode="${6:-off}"
    local loader profile_libs library_path verify_output list_output normalized_list list_hash proc_shim=""
    local allowed_tunables
    local verify_exit=0 list_exit=0 valid=true
    local target_origin declared_path expanded_path resolved_path canonical_path
    local unexpected_lines="" unexpected_json
    local allowed_roots=()

    loader=$(jq -r '.loader' <<<"$profile_json")
    profile_libs=$(jq -r '.library_dirs | join(":")' <<<"$profile_json")
    library_path="${actual_app_lib}:${profile_libs}"
    allowed_tunables=$(jq -r '.allowed_tunables // [] | join(":")' <<<"$profile_json")
    if [[ "$proc_exe_mode" == on ]]; then
        proc_shim=$(jq -r '.proc_exe_shim.path // empty' <<<"$profile_json")
        if [[ -z "$proc_shim" || ! -f "$proc_shim" ]]; then
            echo "[glibcx] Error: proc-exe mode requires a verified profile shim." >&2
            return 1
        fi
    fi
    target_origin=$(dirname "$target_bin")
    allowed_roots+=("$(realpath -m "$actual_app_lib")" "$(realpath -m "$target_origin")")
    while IFS= read -r declared_path; do
        allowed_roots+=("$(realpath -m "$declared_path")")
    done < <(jq -r '.library_dirs[]' <<<"$profile_json")
    while IFS= read -r declared_path; do
        case "$declared_path" in
            '$ORIGIN') expanded_path="$target_origin" ;;
            '$ORIGIN/'*) expanded_path="${target_origin}/${declared_path#\$ORIGIN/}" ;;
            '${ORIGIN}') expanded_path="$target_origin" ;;
            '${ORIGIN}/'*) expanded_path="${target_origin}/${declared_path#\$\{ORIGIN\}/}" ;;
            /*) expanded_path="$declared_path" ;;
            *) continue ;;
        esac
        allowed_roots+=("$(realpath -m "$expanded_path")")
    done < <(jq -r '.dynamic.rpath[], .dynamic.runpath[]' <<<"$inspection")

    local verify_args=(--inhibit-cache --library-path "$library_path")
    [[ -n "$proc_shim" ]] && verify_args+=(--preload "$proc_shim")
    verify_args+=(--verify "$target_bin")
    if verify_output=$(_loader_clean_env GLIBC_TUNABLES="$allowed_tunables" \
        "$loader" "${verify_args[@]}" 2>&1); then
        verify_exit=0
    else
        verify_exit=$?
        valid=false
    fi
    local list_args=(--inhibit-cache --library-path "$library_path")
    [[ -n "$proc_shim" ]] && list_args+=(--preload "$proc_shim")
    list_args+=(--list "$target_bin")
    if list_output=$(_loader_clean_env GLIBC_TUNABLES="$allowed_tunables" \
        "$loader" "${list_args[@]}" 2>&1); then
        list_exit=0
    else
        list_exit=$?
        valid=false
    fi
    normalized_list=$(printf '%s\n' "$list_output" \
        | _loader_normalize_output "$actual_app_lib" "$manifest_app_lib")
    list_hash=$(_sha256_text "$normalized_list")

    if [[ "$list_exit" -eq 0 ]]; then
        while IFS= read -r resolved_path; do
            [[ -n "$resolved_path" ]] || continue
            canonical_path=$(realpath -m "$resolved_path")
            if ! _loader_path_is_allowed "$canonical_path" "${allowed_roots[@]}"; then
                unexpected_lines+="${canonical_path}"$'\n'
                valid=false
            fi
        done < <(_loader_list_paths <<<"$list_output")
    fi
    unexpected_json=$(printf '%s' "$unexpected_lines" | _elf_lines_to_json)

    jq -n \
        --argjson verified "$valid" \
        --argjson verify_exit "$verify_exit" \
        --arg verify_output "$verify_output" \
        --argjson list_exit "$list_exit" \
        --arg list_output "$normalized_list" \
        --arg list_hash "$list_hash" \
        --arg library_path "${manifest_app_lib}:${profile_libs}" \
        --arg proc_exe_mode "$proc_exe_mode" \
        --arg proc_exe_shim "$proc_shim" \
        --argjson unexpected "$unexpected_json" \
        '{
            verified: $verified,
            scope: "startup-loader-verified",
            verify: {exit_code: $verify_exit, output: $verify_output},
            list: {exit_code: $list_exit, output: $list_output},
            list_sha256: $list_hash,
            library_path: $library_path,
            proc_exe_mode: $proc_exe_mode,
            proc_exe_shim: (if $proc_exe_shim == "" then null else $proc_exe_shim end),
            unexpected_resolutions: $unexpected
        }'
}
