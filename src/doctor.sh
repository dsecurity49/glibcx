_doctor_loader_command() {
    local tunables="${1:-}"
    local -a clean_env=(
        env
        -u LD_PRELOAD
        -u LD_LIBRARY_PATH
        -u GLIBC_LD_LIBRARY_PATH
        -u LD_AUDIT
        -u LD_DEBUG
        -u LD_DEBUG_OUTPUT
        -u LD_PROFILE
        -u GLIBC_TUNABLES
    )
    shift
    [[ -n "$tunables" ]] && clean_env+=(GLIBC_TUNABLES="$tunables")
    "${clean_env[@]}" "$@"
}

_doctor_print_values() {
    local json="$1" filter="$2" empty_text="$3"
    local values
    values=$(jq -r "$filter" <<<"$json")
    if [[ -n "$values" ]]; then
        sed 's/^/    /' <<<"$values"
    else
        echo "    $empty_text"
    fi
}

cmd_doctor() {
    local target_bin="${1:-}"
    local inspection valid interpreter app_id="" manifest_path="" app_lib=""
    local library_path verify_output="" verify_status="not-run"
    local list_output="" list_status="not-run" diagnostics_output=""
    local registered_status="not registered" target_drift="not registered"
    local runtime_drift="not registered" wrapper_drift="not registered"
    local dependency_drift="not registered" dependency_mismatches=0 dependency_json dependency_path dependency_hash
    local recorded_hash current_hash recorded_loader_hash current_loader_hash
    local recorded_profile_hash current_profile_hash profile_manifest_path
    local recorded_wrapper_hash current_wrapper_hash wrapper_path
    local doctor_profile_id="system" doctor_profile_kind="system" doctor_loader="$GLIBC_INTERPRETER"
    local doctor_profile_libs="$GLIBC_LIB_DIR" doctor_profile_json="" proc_exe_mode=off proc_exe_shim=""
    local doctor_tunables=""

    if [[ -z "$target_bin" || ! -f "$target_bin" ]]; then
        echo "Usage: glibcx doctor <binary>" >&2
        return 1
    fi
    _require_command jq jq
    _require_command readelf binutils
    target_bin=$(realpath "$target_bin")

    inspection=$(elf_inspect "$target_bin")
    valid=$(jq -r '.valid' <<<"$inspection")
    interpreter=$(jq -r '.program_headers.interpreter // empty' <<<"$inspection")

    if [[ -f "$REGISTRY_FILE" ]] \
        && jq -e '.schema == 3 and (.apps | type) == "object"' "$REGISTRY_FILE" >/dev/null 2>&1; then
        app_id=$(jq -r --arg path "$target_bin" '.apps[$path].app_id // empty' "$REGISTRY_FILE")
        manifest_path=$(jq -r --arg path "$target_bin" '.apps[$path].manifest // empty' "$REGISTRY_FILE")
    fi
    if [[ -n "$app_id" && -f "$manifest_path" ]]; then
        registered_status="registered as $app_id"
        app_lib=$(state_current_lib_path "$app_id")
        recorded_hash=$(jq -r '.target.sha256 // empty' "$manifest_path")
        current_hash=$(_sha256_file "$target_bin")
        if [[ "$recorded_hash" == "$current_hash" ]]; then
            target_drift="clean"
        else
            target_drift="DRIFT: target SHA-256 changed"
        fi

        doctor_profile_id=$(jq -r '.runtime.profile_id // "system"' "$manifest_path")
        doctor_profile_json=$(runtime_profile_load "$doctor_profile_id" summary 2>/dev/null || true)
        if [[ -n "$doctor_profile_json" ]]; then
            doctor_profile_kind=$(jq -r '.kind' <<<"$doctor_profile_json")
            doctor_loader=$(jq -r '.loader' <<<"$doctor_profile_json")
            doctor_profile_libs=$(jq -r '.library_dirs | join(":")' <<<"$doctor_profile_json")
            doctor_tunables=$(jq -r '.allowed_tunables | join(":")' <<<"$doctor_profile_json")
        fi
        proc_exe_mode=$(jq -r '.wrapper.proc_exe_mode // "off"' "$manifest_path")
        [[ "$proc_exe_mode" == on ]] \
            && proc_exe_shim=$(jq -r '.proc_exe_shim.path // empty' <<<"$doctor_profile_json")
        recorded_loader_hash=$(jq -r '.runtime.loader_sha256 // empty' "$manifest_path")
        current_loader_hash=""
        [[ -f "$doctor_loader" ]] && current_loader_hash=$(_sha256_file "$doctor_loader")
        recorded_profile_hash=$(jq -r '.runtime.manifest_sha256 // empty' "$manifest_path")
        profile_manifest_path=$(runtime_manifest_path "$doctor_profile_id" 2>/dev/null || true)
        current_profile_hash=""
        [[ -f "$profile_manifest_path" ]] && current_profile_hash=$(_sha256_file "$profile_manifest_path")
        if [[ -n "$recorded_loader_hash" && "$recorded_loader_hash" == "$current_loader_hash" \
            && -n "$recorded_profile_hash" && "$recorded_profile_hash" == "$current_profile_hash" ]]; then
            runtime_drift="clean"
        else
            runtime_drift="DRIFT or unlocked mutable profile"
        fi

        wrapper_path=$(jq -r '.wrapper.path // empty' "$manifest_path")
        recorded_wrapper_hash=$(jq -r '.wrapper.sha256 // empty' "$manifest_path")
        current_wrapper_hash=""
        [[ -f "$wrapper_path" ]] && current_wrapper_hash=$(_sha256_file "$wrapper_path")
        if [[ -n "$recorded_wrapper_hash" && "$recorded_wrapper_hash" == "$current_wrapper_hash" ]]; then
            wrapper_drift="clean"
        else
            wrapper_drift="DRIFT: wrapper missing or changed"
        fi

        while IFS= read -r dependency_json; do
            dependency_path=$(jq -r '.path' <<<"$dependency_json")
            dependency_hash=$(jq -r '.sha256' <<<"$dependency_json")
            if [[ ! -f "$dependency_path" || "$(_sha256_file "$dependency_path")" != "$dependency_hash" ]]; then
                dependency_mismatches=$((dependency_mismatches + 1))
            fi
        done < <(jq -c '.dependencies[]' "$manifest_path")
        if [[ "$dependency_mismatches" -eq 0 ]]; then
            dependency_drift="clean"
        else
            dependency_drift="DRIFT: $dependency_mismatches locked DSO(s) missing or changed"
        fi
    elif [[ -f "$REGISTRY_FILE" ]] && ! jq -e '.schema == 3' "$REGISTRY_FILE" >/dev/null 2>&1; then
        registered_status="legacy or invalid registry (migration is required before mutation)"
    elif [[ -f "${PROFILE_STATE_DIR}/system.json" ]]; then
        doctor_profile_json=$(runtime_profile_load system summary 2>/dev/null || true)
        if [[ -n "$doctor_profile_json" ]]; then
            doctor_loader=$(jq -r '.loader' <<<"$doctor_profile_json")
            doctor_profile_libs=$(jq -r '.library_dirs | join(":")' <<<"$doctor_profile_json")
            doctor_tunables=$(jq -r '.allowed_tunables | join(":")' <<<"$doctor_profile_json")
        fi
    fi

    if [[ -n "$app_lib" ]]; then
        library_path="${app_lib}:${doctor_profile_libs}"
    else
        library_path="$doctor_profile_libs"
    fi

    if [[ "$valid" == true && -x "$doctor_loader" ]]; then
        local verify_args=(--inhibit-cache --library-path "$library_path")
        local list_args=(--inhibit-cache --library-path "$library_path")
        [[ -n "$proc_exe_shim" ]] && verify_args+=(--preload "$proc_exe_shim")
        [[ -n "$proc_exe_shim" ]] && list_args+=(--preload "$proc_exe_shim")
        verify_args+=(--verify "$target_bin")
        list_args+=(--list "$target_bin")
        if verify_output=$(_doctor_loader_command "$doctor_tunables" "$doctor_loader" "${verify_args[@]}" 2>&1); then
            verify_status="pass"
        else
            verify_status="FAIL"
        fi
        if list_output=$(_doctor_loader_command "$doctor_tunables" "$doctor_loader" "${list_args[@]}" 2>&1); then
            list_status="pass"
        else
            list_status="FAIL"
        fi
        diagnostics_output=$(_doctor_loader_command "$doctor_tunables" "$doctor_loader" \
            --list-diagnostics 2>&1 || true)
    fi

    echo "[glibcx] Doctor report (read-only; target program logic was not executed)"
    echo
    echo "Target"
    echo "  Path         : $target_bin"
    echo "  Valid target : $valid"
    echo "  ELF          : $(jq -r '.header.class // "unknown"' <<<"$inspection") / $(jq -r '.header.machine // "unknown"' <<<"$inspection") / $(jq -r '.header.type // "unknown"' <<<"$inspection")"
    echo "  Interpreter  : ${interpreter:-none}"
    echo "  GNU ABI note : $(jq -r '.notes.abi // "not present"' <<<"$inspection")"
    echo "  Build ID     : $(jq -r '.notes.build_id // "not present"' <<<"$inspection")"
    echo "  RPATH        :"
    _doctor_print_values "$inspection" '.dynamic.rpath[]?' "none"
    echo "  RUNPATH      :"
    _doctor_print_values "$inspection" '.dynamic.runpath[]?' "none"
    echo "  Required symbol versions:"
    _doctor_print_values "$inspection" '.version_requirements[]?' "none recorded"
    echo "  Direct dependencies:"
    _doctor_print_values "$inspection" '.dynamic.needed[]?' "none"

    if [[ $(jq '(.errors // []) | length' <<<"$inspection") -gt 0 ]]; then
        echo "  Rejection reasons:"
        _doctor_print_values "$inspection" '.errors[]?' "none"
    fi
    if [[ $(jq '(.warnings // []) | length' <<<"$inspection") -gt 0 ]]; then
        echo "  Security/compatibility warnings:"
        _doctor_print_values "$inspection" '.warnings[]?' "none"
    fi

    echo
    echo "Runtime profile"
    echo "  Candidate     : $doctor_profile_id [$doctor_profile_kind]"
    echo "  Loader        : $doctor_loader"
    echo "  Library path  : $library_path"
    echo "  Search note   : legacy RPATH may precede --library-path; --library-path precedes RUNPATH"
    echo "  Managed trust : $(if [[ "$doctor_profile_kind" == managed ]]; then jq -r '.security_state + ", signed=" + (.signature_verified | tostring)' <<<"$doctor_profile_json"; else echo 'mutable development profile'; fi)"

    echo
    echo "State and drift"
    echo "  Registry      : $registered_status"
    echo "  Target        : $target_drift"
    echo "  Runtime       : $runtime_drift"
    echo "  Wrapper       : $wrapper_drift"
    echo "  Dependencies  : $dependency_drift"
    echo "  Proc-exe mode : $proc_exe_mode"
    if [[ "$proc_exe_mode" == on ]]; then
        echo "  Proc-exe shim : $proc_exe_shim"
        echo "  Shim limits   : libc interfaces only; raw syscalls and static code bypass it"
    fi
    if [[ -n "$manifest_path" && -f "$manifest_path" ]]; then
        echo "  Locked startup graph:"
        jq -r '.dependencies[]? | "    \(.soname) -> \(.path) [\(.source)]"' "$manifest_path"
        if [[ "$(jq '.verification.unexpected_resolutions | length' "$manifest_path")" -gt 0 ]]; then
            echo "  Unexpected resolutions:"
            jq -r '.verification.unexpected_resolutions[] | "    " + .' "$manifest_path"
        fi
        if [[ "$(jq -r '.repository // empty' "$manifest_path")" != "" ]]; then
            echo "  Repository snapshot:"
            jq -r 'if .repository then
                "    \(.repository.origin) / \(.repository.suite)\n    InRelease: \(.repository.inrelease_sha256)\n    signer: \(.repository.signing_fingerprint)"
                else empty end' "$manifest_path"
        fi
    fi

    echo
    echo "Loader checks"
    echo "  --verify      : $verify_status"
    [[ -n "$verify_output" ]] && sed 's/^/    /' <<<"$verify_output"
    echo "  --list        : $list_status (startup resolution only; does not prove dlopen or execution)"
    [[ -n "$list_output" ]] && sed 's/^/    /' <<<"$list_output"
    if [[ -n "$diagnostics_output" ]]; then
        echo "  --list-diagnostics (profile/system diagnostics):"
        sed 's/^/    /' <<<"$diagnostics_output"
    fi

    echo
    echo "Platform"
    echo "  Kernel        : $(uname -srm 2>/dev/null || echo unknown)"
    if command -v getprop >/dev/null 2>&1; then
        echo "  Android API   : $(getprop ro.build.version.sdk 2>/dev/null || echo unknown)"
        echo "  Android       : $(getprop ro.build.version.release 2>/dev/null || echo unknown)"
        echo "  Device        : $(getprop ro.product.manufacturer 2>/dev/null) $(getprop ro.product.model 2>/dev/null)"
    else
        echo "  Android       : not detected"
    fi

    [[ "$valid" == true && "$verify_status" == "pass" && "$list_status" == "pass" ]]
}
