cmd_vendor() {
    local target_bin="${1:-}"
    if [[ $# -gt 0 ]]; then
        shift
    fi
    if [[ -z "$target_bin" || $# -eq 0 ]]; then
        echo "Usage: glibcx vendor <binary_path> <lib1.so> [lib2.so...]" >&2
        exit 1
    fi

    init_env
    target_bin="$(realpath "$target_bin" 2>/dev/null || echo "$target_bin")"

    if [[ "$target_bin" == "${BIN_DIR}/"* ]]; then
        local wrapper_base resolved
        wrapper_base="$(basename "$target_bin")"
        resolved=$(state_target_for_alias "$wrapper_base" 2>/dev/null || true)
        [[ -n "$resolved" ]] && target_bin="$resolved"
    fi

    local app_id manifest_path app_root current_dir bin_name profile_id profile_json
    app_id=$(state_get_app_id "$target_bin")
    if [[ -z "$app_id" ]]; then
        echo "[glibcx] Error: '$target_bin' is not in the registry. Use 'glibcx patch' first." >&2
        exit 1
    fi
    manifest_path=$(state_get_manifest_path "$target_bin")
    if [[ -z "$manifest_path" || ! -f "$manifest_path" ]]; then
        echo "[glibcx] Error: registered manifest is missing for '$target_bin'. Re-patch it first." >&2
        exit 1
    fi
    app_root=$(state_app_root "$app_id")
    bin_name=$(basename "$target_bin")
    profile_id=$(jq -r '.runtime.profile_id' "$manifest_path")
    profile_json=$(runtime_profile_load "$profile_id" summary) || exit 1

    local target_lock registry_lock app_lock stage_root stage_lib manifest_tmp
    local previous_current generation_number generation_dir registry_snapshot
    local lib_file lib_name lib_soname lib_inspection lib_hash vendor_records vendor_count
    local target_inspection verification_json dependencies_json
    lock_acquire target_lock "$(lock_target_name "$target_bin")"
    lock_acquire registry_lock registry
    lock_acquire app_lock "$(lock_app_name "$app_id")"

    previous_current=$(readlink "${app_root}/current" 2>/dev/null || true)
    if [[ ! "$previous_current" =~ ^generations/[1-9][0-9]*$ \
        || ! -d "${app_root}/${previous_current}" ]]; then
        echo "[glibcx] Error: app current generation is invalid." >&2
        lock_release "$app_lock"
        lock_release "$registry_lock"
        lock_release "$target_lock"
        exit 1
    fi
    current_dir="${app_root}/${previous_current}"
    manifest_path=$(state_current_manifest_path "$app_id")
    stage_root=$(mktemp -d "${app_root}/generations/.stage.XXXXXX")
    cp -a "${current_dir}/." "$stage_root/"
    stage_lib="${stage_root}/lib"
    mkdir -p "$stage_lib"
    vendor_records='[]'

    for lib_file in "$@"; do
        if [[ ! -f "$lib_file" ]]; then
            echo "[glibcx] Error: library file not found: $lib_file" >&2
            rm -rf "${stage_root:?}"
            lock_release "$app_lock"
            lock_release "$registry_lock"
            lock_release "$target_lock"
            exit 1
        fi
        lib_file=$(realpath "$lib_file")
        lib_inspection=$(elf_inspect "$lib_file" dso)
        if [[ "$(jq -r '.valid' <<<"$lib_inspection")" != "true" ]]; then
            echo "[glibcx] Error: '$lib_file' is not a supported AArch64 DSO." >&2
            elf_print_errors <<<"$lib_inspection"
            rm -rf "${stage_root:?}"
            lock_release "$app_lock"
            lock_release "$registry_lock"
            lock_release "$target_lock"
            exit 1
        fi
        lib_name=$(basename "$lib_file")
        lib_soname=$(jq -r '.dynamic.soname // empty' <<<"$lib_inspection")
        lib_hash=$(_sha256_file "$lib_file")
        cp -p "$lib_file" "${stage_lib}/${lib_name}"
        if [[ -n "$lib_soname" && "$lib_soname" != "$lib_name" ]]; then
            if [[ "$lib_soname" == */* || "$lib_soname" == . || "$lib_soname" == .. ]]; then
                echo "[glibcx] Error: unsafe DSO SONAME '$lib_soname'." >&2
                rm -rf "${stage_root:?}"
                lock_release "$app_lock"
                lock_release "$registry_lock"
                lock_release "$target_lock"
                exit 1
            fi
            rm -f "${stage_lib}/${lib_soname}"
            ln -s "$lib_name" "${stage_lib}/${lib_soname}"
        fi
        vendor_records=$(jq -c \
            --arg source "$lib_file" \
            --arg destination "$(state_current_lib_path "$app_id")/${lib_name}" \
            --arg hash "$lib_hash" \
            --arg added_at "$(_utc_timestamp)" \
            '. + [{source_path: $source, path: $destination, sha256: $hash, added_at: $added_at}]' \
            <<<"$vendor_records")
    done

    target_inspection=$(elf_inspect "$target_bin")
    if [[ "$(jq -r '.valid' <<<"$target_inspection")" != "true" ]]; then
        echo "[glibcx] Error: target drifted into an unsupported ELF; re-patch it first." >&2
        rm -rf "${stage_root:?}"
        lock_release "$app_lock"
        lock_release "$registry_lock"
        lock_release "$target_lock"
        exit 1
    fi
    verification_json=$(loader_verify_target "$profile_json" "$stage_lib" \
        "$(state_current_lib_path "$app_id")" "$target_bin" "$target_inspection" \
        "$(jq -r '.wrapper.proc_exe_mode // "off"' "$manifest_path")")
    if [[ "$(jq -r '.verified' <<<"$verification_json")" != "true" ]]; then
        echo "[glibcx] Error: vendored libraries do not produce a valid startup closure." >&2
        jq -r '.list.output, .unexpected_resolutions[]?' <<<"$verification_json" >&2
        rm -rf "${stage_root:?}"
        lock_release "$app_lock"
        lock_release "$registry_lock"
        lock_release "$target_lock"
        exit 1
    fi
    if ! dependencies_json=$(resolver_manifest_dependencies "$verification_json" "$profile_json" \
        "$stage_lib" "$(state_current_lib_path "$app_id")"); then
        rm -rf "${stage_root:?}"
        lock_release "$app_lock"
        lock_release "$registry_lock"
        lock_release "$target_lock"
        exit 1
    fi

    generation_number=$(state_next_generation_locked "$app_id")
    manifest_tmp=$(mktemp "${stage_root}/.manifest.vendor.XXXXXX")
    if ! jq \
        --arg updated_at "$(_utc_timestamp)" \
        --argjson generation "$generation_number" \
        --argjson vendors "$vendor_records" \
        --argjson verification "$verification_json" \
        --argjson dependencies "$dependencies_json" \
        '.generation = $generation
         | .updated_at = $updated_at
         | .manual_vendors = ((.manual_vendors // []) + $vendors | unique_by(.path))
         | .verification = $verification
         | .dependencies = $dependencies
         | .status.dependency_drift = false' \
        "${stage_root}/manifest.json" >"$manifest_tmp"; then
        rm -f "$manifest_tmp"
        rm -rf "${stage_root:?}"
        lock_release "$app_lock"
        lock_release "$registry_lock"
        lock_release "$target_lock"
        exit 1
    fi

    if ! mv "$manifest_tmp" "${stage_root}/manifest.json" \
        || ! jq -r '.list.output' <<<"$verification_json" >"${stage_root}/resolution.txt"; then
        rm -f "$manifest_tmp"
        rm -rf "${stage_root:?}"
        lock_release "$app_lock"
        lock_release "$registry_lock"
        lock_release "$target_lock"
        exit 1
    fi
    if ! chmod 600 "${stage_root}/manifest.json" "${stage_root}/resolution.txt"; then
        echo "[glibcx] Error: failed to restrict staged state files." >&2
        rm -rf "${stage_root:?}"
        lock_release "$app_lock"
        lock_release "$registry_lock"
        lock_release "$target_lock"
        exit 1
    fi

    generation_dir="${app_root}/generations/${generation_number}"
    if ! mv "$stage_root" "$generation_dir"; then
        rm -rf "${stage_root:?}"
        lock_release "$app_lock"
        lock_release "$registry_lock"
        lock_release "$target_lock"
        echo "[glibcx] Error: failed to stage vendored app generation." >&2
        exit 1
    fi
    registry_snapshot=$(mktemp "${CLI_STORAGE}/.registry.rollback.XXXXXX")
    cp -p "$REGISTRY_FILE" "$registry_snapshot"
    if ! _state_atomic_symlink "generations/${generation_number}" "${app_root}/current" \
        || ! state_register_app_locked "$target_bin" "$app_id" "$(state_current_manifest_path "$app_id")" \
        || ! state_refresh_aliases_locked "$bin_name" false; then
        _state_atomic_symlink "$previous_current" "${app_root}/current" || true
        _state_commit_temp "$registry_snapshot" "$REGISTRY_FILE"
        registry_snapshot=""
        rm -rf "${generation_dir:?}"
        state_refresh_aliases_locked "$bin_name" false || true
        lock_release "$app_lock"
        lock_release "$registry_lock"
        lock_release "$target_lock"
        echo "[glibcx] Error: failed to publish vendored app generation." >&2
        exit 1
    fi
    rm -f "$registry_snapshot"

    lock_release "$app_lock"
    lock_release "$registry_lock"
    lock_release "$target_lock"
    vendor_count=$(jq 'length' <<<"$vendor_records")
    echo "[glibcx] Vendored $vendor_count library file(s) for '$bin_name'."
    echo "[glibcx] Startup closure reverified: $(state_current_lib_path "$app_id")"
}
