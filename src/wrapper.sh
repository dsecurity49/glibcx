_loader_clean_env() {
    env -i \
        HOME="${HOME:-/}" \
        PATH="${PATH:-/usr/bin:/bin}" \
        LANG=C \
        LC_ALL=C \
        "$@"
}

_loader_normalize_output() {
    local from_path="$1" to_path="$2"
    if [[ "$from_path" == "$to_path" ]]; then
        cat
        return 0
    fi
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
        /=>[[:space:]]*/ {
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

_loader_hex_decode() {
    local encoded="$1" pair byte decoded=""
    [[ ${#encoded} -le 32768 && $(( ${#encoded} % 2 )) -eq 0 \
        && "$encoded" != *[!0-9a-f]* ]] || return 1
    while [[ -n "$encoded" ]]; do
        pair=${encoded:0:2}
        [[ "$pair" != 00 ]] || return 1
        printf -v byte '%b' "\\x${pair}"
        decoded+="$byte"
        encoded=${encoded:2}
    done
    [[ "$decoded" != *[$'\001'-$'\037'$'\177']* ]] || return 1
    REPLY="$decoded"
}

_loader_parse_audit() {
    local audit_file="$1" line kind object_id lmid encoded name flag requester
    local started=0 consistent=0 opened_file search_file
    local -a fields=()
    opened_file=$(mktemp "${TMP_DIR}/loader-audit-open.XXXXXX")
    search_file=$(mktemp "${TMP_DIR}/loader-audit-search.XXXXXX")
    : >"$opened_file"
    : >"$search_file"
    while IFS= read -r line; do
        IFS=$'\t' read -r -a fields <<<"$line"
        [[ "${fields[0]:-}" == GXA1 ]] || {
            rm -f "$opened_file" "$search_file"
            return 1
        }
        kind=${fields[1]:-}
        case "$kind" in
            START)
                [[ ${#fields[@]} -eq 2 && "$started" -eq 0 ]] || {
                    rm -f "$opened_file" "$search_file"; return 1;
                }
                started=1
                ;;
            CONSISTENT)
                [[ ${#fields[@]} -eq 2 && "$started" -eq 1 ]] || {
                    rm -f "$opened_file" "$search_file"; return 1;
                }
                consistent=1
                ;;
            OPEN)
                [[ "$started" -eq 1 && ${#fields[@]} -ge 4 && ${#fields[@]} -le 5 ]] || {
                    rm -f "$opened_file" "$search_file"; return 1;
                }
                object_id=${fields[2]}
                lmid=${fields[3]}
                encoded=${fields[4]:-}
                [[ "$object_id" =~ ^[0-9a-f]{16}$ && "$lmid" =~ ^[0-9a-f]{16}$ ]] \
                    && _loader_hex_decode "$encoded" || {
                        rm -f "$opened_file" "$search_file"; return 1;
                    }
                name=$REPLY
                printf '%s\t%s\t%s\n' "$object_id" "$lmid" "$name" >>"$opened_file"
                ;;
            SEARCH)
                [[ "$started" -eq 1 && ${#fields[@]} -eq 5 ]] || {
                    rm -f "$opened_file" "$search_file"; return 1;
                }
                requester=${fields[2]}
                flag=${fields[3]}
                encoded=${fields[4]}
                [[ "$requester" =~ ^[0-9a-f]{16}$ && "$flag" =~ ^[0-9a-f]{16}$ \
                    && ${#encoded} -le 32768 && $(( ${#encoded} % 2 )) -eq 0 \
                    && "$encoded" != *[!0-9a-f]* ]] || {
                        rm -f "$opened_file" "$search_file"; return 1;
                    }
                if [[ "$flag" == 0000000000000001 ]]; then
                    _loader_hex_decode "$encoded" || {
                        rm -f "$opened_file" "$search_file"; return 1;
                    }
                    name=$REPLY
                    printf '%s\t%s\t%s\n' "$requester" "$flag" "$name" >>"$search_file"
                fi
                ;;
            *)
                rm -f "$opened_file" "$search_file"
                return 1
                ;;
        esac
    done <"$audit_file"
    [[ "$started" -eq 1 ]] || {
        rm -f "$opened_file" "$search_file"
        return 1
    }
    local consistent_json=false opened_json searches_json
    [[ "$consistent" -eq 1 ]] && consistent_json=true
    opened_json=$(jq -Rn '[inputs | split("\t")
        | {object_id: .[0], lmid: .[1], path: .[2]}]' <"$opened_file")
    searches_json=$(jq -Rn '[inputs | split("\t")
        | {requester: .[0], flag: .[1], name: .[2]}]' <"$search_file")
    jq -n --argjson consistent "$consistent_json" \
        --argjson opened "$opened_json" --argjson searches "$searches_json" \
        '{protocol: 1, complete: false, consistent: $consistent,
          opened: $opened, searches: $searches}'
    rm -f "$opened_file" "$search_file"
}

_loader_audit_matches_list() {
    local audit_json="$1" list_output="$2" path
    local audit_paths list_paths
    audit_paths=$(mktemp "${TMP_DIR}/loader-audit-paths.XXXXXX")
    list_paths=$(mktemp "${TMP_DIR}/loader-list-paths.XXXXXX")
    : >"$audit_paths"
    : >"$list_paths"
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        [[ "$path" != linux-vdso.so.* && "$path" == /* ]] || continue
        realpath -m "$path"
    done < <(jq -r '.opened[] | select(.lmid == "0000000000000000") | .path' \
        <<<"$audit_json") | LC_ALL=C sort -u >"$audit_paths"
    while IFS= read -r path; do
        [[ -n "$path" && "$path" == /* ]] || {
            rm -f "$audit_paths" "$list_paths"
            return 1
        }
        realpath -m "$path"
    done < <(_loader_list_paths <<<"$list_output") | LC_ALL=C sort -u >"$list_paths"
    if ! cmp -s "$audit_paths" "$list_paths"; then
        rm -f "$audit_paths" "$list_paths"
        return 1
    fi
    rm -f "$audit_paths" "$list_paths"
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
    local audit_path audit_file audit_json audit_required=false hwcaps_mask hwcaps_policy=false
    local allowed_tunables
    local verify_exit=0 list_exit=0 valid=true
    local target_origin declared_path expanded_path resolved_path canonical_path
    local unexpected_lines="" unexpected_json
    local allowed_roots=()
    local -a loader_paths=()

    loader=$(jq -r '.loader' <<<"$profile_json")
    profile_libs=$(jq -r '.library_dirs | join(":")' <<<"$profile_json")
    library_path="${actual_app_lib}:${profile_libs}"
    allowed_tunables=$(jq -r '.allowed_tunables // [] | join(":")' <<<"$profile_json")
    audit_path=$(jq -r '.loader_audit.path // empty' <<<"$profile_json")
    hwcaps_mask=$(jq -r '.loader_policy.glibc_hwcaps_mask // empty' <<<"$profile_json")
    if jq -e '.loader_policy | has("glibc_hwcaps_mask")' <<<"$profile_json" >/dev/null 2>&1; then
        hwcaps_policy=true
    fi
    if [[ "$(jq -r '.kind' <<<"$profile_json")" == managed ]]; then
        audit_required=true
    fi
    if [[ -n "$audit_path" && ! -f "$audit_path" ]]; then
        echo "[glibcx] Error: selected runtime's loader-audit module is missing." >&2
        return 1
    fi
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
        canonical_path=$(realpath -m "$expanded_path")
        if ! _loader_path_is_allowed "$canonical_path" "${allowed_roots[@]}"; then
            unexpected_lines+="disallowed loader search path: ${canonical_path}"$'\n'
            valid=false
        fi
    done < <(jq -r '.dynamic.rpath[], .dynamic.runpath[]' <<<"$inspection")

    local verify_args=(--inhibit-cache)
    [[ "$hwcaps_policy" == true ]] && verify_args+=(--glibc-hwcaps-mask "$hwcaps_mask")
    verify_args+=(--library-path "$library_path")
    [[ -n "$proc_shim" ]] && verify_args+=(--preload "$proc_shim")
    verify_args+=(--verify "$target_bin")
    if verify_output=$(_loader_clean_env GLIBC_TUNABLES="$allowed_tunables" \
        "$loader" "${verify_args[@]}" 2>&1); then
        verify_exit=0
    else
        verify_exit=$?
        valid=false
    fi
    local list_args=(--inhibit-cache)
    [[ "$hwcaps_policy" == true ]] && list_args+=(--glibc-hwcaps-mask "$hwcaps_mask")
    list_args+=(--library-path "$library_path")
    audit_file=$(mktemp "${TMP_DIR}/loader-audit.XXXXXX")
    : >"$audit_file"
    [[ -n "$audit_path" ]] && list_args+=(--audit "$audit_path")
    [[ -n "$proc_shim" ]] && list_args+=(--preload "$proc_shim")
    list_args+=(--list "$target_bin")
    if list_output=$(_loader_clean_env GLIBC_TUNABLES="$allowed_tunables" \
        "$loader" "${list_args[@]}" 198>"$audit_file" 2>&1); then
        list_exit=0
    else
        list_exit=$?
        valid=false
    fi
    if [[ -n "$audit_path" ]]; then
        if ! audit_json=$(_loader_parse_audit "$audit_file"); then
            audit_json='{"protocol":1,"complete":false,"opened":[],"searches":[]}'
            valid=false
        elif [[ "$list_exit" -eq 0 ]]; then
            if _loader_audit_matches_list "$audit_json" "$list_output"; then
                audit_json=$(jq -c '.complete = true' <<<"$audit_json")
            else
                valid=false
            fi
        fi
    else
        audit_json='null'
        [[ "$audit_required" == false ]] || valid=false
    fi
    rm -f "$audit_file"
    normalized_list=$(printf '%s\n' "$list_output" \
        | _loader_normalize_output "$actual_app_lib" "$manifest_app_lib")
    list_hash=$(_sha256_text "$normalized_list")

    if [[ "$list_exit" -eq 0 ]]; then
        if [[ "$audit_json" != null ]]; then
            mapfile -t loader_paths < <(jq -r '.opened[] | select(.lmid == "0000000000000000") | .path' \
                <<<"$audit_json")
        else
            mapfile -t loader_paths < <(_loader_list_paths <<<"$list_output")
        fi
        for resolved_path in "${loader_paths[@]}"; do
            [[ -n "$resolved_path" ]] || continue
            [[ "$resolved_path" != linux-vdso.so.* ]] || continue
            if [[ "$resolved_path" != /* ]]; then
                unexpected_lines+="non-absolute loader result: ${resolved_path}"$'\n'
                valid=false
                continue
            fi
            canonical_path=$(realpath -m "$resolved_path")
            if ! _loader_path_is_allowed "$canonical_path" "${allowed_roots[@]}"; then
                unexpected_lines+="${canonical_path}"$'\n'
                valid=false
            fi
        done
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
        --argjson audit "$audit_json" \
        '{
            verified: $verified,
            scope: "startup-loader-verified",
            verify: {exit_code: $verify_exit, output: $verify_output},
            list: {exit_code: $list_exit, output: $list_output},
            list_sha256: $list_hash,
            library_path: $library_path,
            proc_exe_mode: $proc_exe_mode,
            proc_exe_shim: (if $proc_exe_shim == "" then null else $proc_exe_shim end),
            unexpected_resolutions: $unexpected,
            audit: $audit
        }'
}
