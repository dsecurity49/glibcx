_state_commit_temp() {
    local temporary_file="$1" destination="$2"
    chmod 600 "$temporary_file"
    mv -f "$temporary_file" "$destination"
}

_state_new_registry_locked() {
    local registry_tmp
    registry_tmp=$(mktemp "${CLI_STORAGE}/.registry.new.XXXXXX")
    if ! jq -n --argjson schema "$STATE_SCHEMA" '{schema: $schema, apps: {}}' >"$registry_tmp"; then
        rm -f "$registry_tmp"
        return 1
    fi
    _state_commit_temp "$registry_tmp" "$REGISTRY_FILE"
}

_state_registry_kind() {
    jq -r '
        if type != "object" then "invalid"
        elif .schema == 3 and (.apps | type) == "object" then "v3"
        elif (has("schema") or has("apps")) then "invalid"
        elif all(.[]; type == "object") then "v2"
        else "invalid"
        end
    ' "$REGISTRY_FILE" 2>/dev/null || printf 'invalid\n'
}

_state_validate_v3_locked() {
    local target_path app_id manifest_path expected_manifest current_link current_target generation
    if ! jq -e '
        .schema == 3
        and (.apps | type) == "object"
        and ([.apps | keys[] |
            (startswith("/")
            and (contains("\n") | not)
            and (contains("\r") | not))] | all)
        and ([.apps[] |
            type == "object"
            and (.app_id | type) == "string"
            and (.manifest | type) == "string"] | all)
    ' "$REGISTRY_FILE" >/dev/null; then
        return 1
    fi

    while IFS= read -r target_path; do
        app_id=$(jq -r --arg path "$target_path" '.apps[$path].app_id' "$REGISTRY_FILE")
        manifest_path=$(jq -r --arg path "$target_path" '.apps[$path].manifest' "$REGISTRY_FILE")
        if [[ ! "$app_id" =~ ^[A-Za-z0-9._-]+-[0-9a-f]{16,64}(-[0-9a-f]{12,64})?$ ]] \
            || [[ "$app_id" == */* ]]; then
            return 1
        fi
        expected_manifest="${APPS_DIR}/${app_id}/current/manifest.json"
        if [[ "$manifest_path" != "$expected_manifest" || ! -f "$manifest_path" ]]; then
            return 1
        fi
        current_link="${APPS_DIR}/${app_id}/current"
        current_target=$(readlink "$current_link" 2>/dev/null || true)
        if [[ ! -L "$current_link" || ! "$current_target" =~ ^generations/[1-9][0-9]*$ \
            || ! -d "${APPS_DIR}/${app_id}/${current_target}" ]]; then
            return 1
        fi
        generation=${current_target##*/}
        if ! jq -e --argjson schema "$STATE_SCHEMA" --argjson generation "$generation" \
            --arg id "$app_id" --arg path "$target_path" \
            '.schema == $schema and .generation == $generation
             and .app_id == $id and .target.path == $path' \
            "$manifest_path" >/dev/null; then
            return 1
        fi
    done < <(jq -r '.apps | keys[]' "$REGISTRY_FILE")
}

state_app_root() {
    printf '%s/%s\n' "$APPS_DIR" "$1"
}

state_current_dir() {
    printf '%s/%s/current\n' "$APPS_DIR" "$1"
}

state_current_manifest_path() {
    printf '%s/%s/current/manifest.json\n' "$APPS_DIR" "$1"
}

state_current_wrapper_path() {
    printf '%s/%s/current/wrapper\n' "$APPS_DIR" "$1"
}

state_current_lib_path() {
    printf '%s/%s/current/lib\n' "$APPS_DIR" "$1"
}

state_next_generation_locked() {
    local generations_dir="${APPS_DIR}/${1}/generations"
    local generation_path generation_number highest=0
    if [[ -d "$generations_dir" ]]; then
        while IFS= read -r generation_path; do
            generation_number=$(basename "$generation_path")
            [[ "$generation_number" =~ ^[1-9][0-9]*$ ]] || continue
            generation_number=$((10#$generation_number))
            (( generation_number > highest )) && highest=$generation_number
        done < <(find "$generations_dir" -mindepth 1 -maxdepth 1 -type d -print)
    fi
    printf '%s\n' "$((highest + 1))"
}

_state_allocate_id_from_registry() {
    local registry_source="$1" basename="$2" target_hash="$3" canonical_path="$4"
    local safe_basename candidate prefix_length path_hash suffix_length
    local collision_manifest collision_hash

    safe_basename=$(_sanitize_basename "$basename")
    prefix_length=16
    while (( prefix_length <= 64 )); do
        candidate="${safe_basename}-${target_hash:0:prefix_length}"
        if jq -e --arg id "$candidate" '[.apps[].app_id] | index($id) == null' \
            "$registry_source" >/dev/null; then
            printf '%s\n' "$candidate"
            return 0
        fi

        collision_hash=$(jq -r --arg id "$candidate" \
            '[.apps[] | select(.app_id == $id) | .target_sha256 // empty][0] // empty' \
            "$registry_source")
        if [[ -z "$collision_hash" ]]; then
            collision_manifest=$(jq -r --arg id "$candidate" \
                '[.apps[] | select(.app_id == $id) | .manifest][0] // empty' \
                "$registry_source")
            if [[ -n "$collision_manifest" && -f "$collision_manifest" ]]; then
                collision_hash=$(jq -r '.target.sha256 // empty' "$collision_manifest")
            fi
        fi
        if [[ "$collision_hash" == "$target_hash" ]]; then
            path_hash=$(_sha256_text "$canonical_path")
            suffix_length=12
            while (( suffix_length <= 64 )); do
                candidate="${safe_basename}-${target_hash:0:16}-${path_hash:0:suffix_length}"
                if jq -e --arg id "$candidate" '[.apps[].app_id] | index($id) == null' \
                    "$registry_source" >/dev/null; then
                    printf '%s\n' "$candidate"
                    return 0
                fi
                suffix_length=$((suffix_length + 4))
            done
            break
        fi
        prefix_length=$((prefix_length + 4))
    done

    path_hash=$(_sha256_text "$canonical_path")
    suffix_length=12
    while (( suffix_length <= 64 )); do
        candidate="${safe_basename}-${target_hash}-${path_hash:0:suffix_length}"
        if jq -e --arg id "$candidate" '[.apps[].app_id] | index($id) == null' \
            "$registry_source" >/dev/null; then
            printf '%s\n' "$candidate"
            return 0
        fi
        suffix_length=$((suffix_length + 4))
    done

    echo "[glibcx] Error: could not allocate a unique app ID for '$canonical_path'." >&2
    return 1
}

state_allocate_app_id_locked() {
    local canonical_path="$1" basename="$2" target_hash="$3" existing_id
    existing_id=$(jq -r --arg path "$canonical_path" '.apps[$path].app_id // empty' "$REGISTRY_FILE")
    if [[ -n "$existing_id" ]]; then
        printf '%s\n' "$existing_id"
        return 0
    fi
    _state_allocate_id_from_registry "$REGISTRY_FILE" "$basename" "$target_hash" "$canonical_path"
}

_state_migration_manifest() {
    local destination="$1" app_id="$2" target_path="$3" target_hash="$4"
    local legacy_json="$5" wrapper_path="$6" wrapper_hash="$7"
    local basename created_at fingerprint glibc_required target_size

    basename=$(basename "$target_path")
    created_at=$(jq -r '.patched_at // empty' <<<"$legacy_json")
    [[ -n "$created_at" ]] || created_at=$(_utc_timestamp)
    fingerprint=$(jq -r '.patched_fingerprint // "missing"' <<<"$legacy_json")
    glibc_required=$(jq -r '.glibc_required // "unknown"' <<<"$legacy_json")
    target_size=0
    [[ -f "$target_path" ]] && target_size=$(LC_ALL=C stat -c '%s' "$target_path")
    jq -n \
        --argjson schema "$STATE_SCHEMA" \
        --arg app_id "$app_id" \
        --arg created_at "$created_at" \
        --arg target_path "$target_path" \
        --arg basename "$basename" \
        --arg target_hash "$target_hash" \
        --argjson target_size "$target_size" \
        --arg fingerprint "$fingerprint" \
        --arg glibc_required "$glibc_required" \
        --arg wrapper_path "$wrapper_path" \
        --arg wrapper_hash "$wrapper_hash" \
        --argjson legacy "$legacy_json" \
        '{
            schema: $schema,
            generation: 1,
            app_id: $app_id,
            created_at: $created_at,
            target: {
                path: $target_path,
                basename: $basename,
                sha256: $target_hash,
                size: $target_size,
                drift_fingerprint: $fingerprint
            },
            elf: {
                class: null,
                machine: null,
                interpreter: null,
                abi_note: null,
                build_id: null,
                rpath: [],
                runpath: [],
                soname: null,
                glibc_required: $glibc_required,
                version_requirements: []
            },
            runtime: {
                profile_id: "system",
                manifest_sha256: null,
                loader_sha256: null,
                compatibility: "migration",
                selection_reason: "migrated from schema 2"
            },
            dependencies: [],
            repository: null,
            verification: {loader_list: null, loader_list_sha256: null, verified: false},
            wrapper: {
                path: $wrapper_path,
                sha256: (if $wrapper_hash == "" then null else $wrapper_hash end),
                abi_version: 2,
                library_path: null,
                proc_exe_mode: "off",
                tunables: []
            },
            status: {
                needs_repatch: true,
                target_drift: false,
                profile_drift: true,
                dependency_drift: true,
                wrapper_drift: false
            },
            migration: {from_schema: 2, legacy_entry: $legacy}
        }' >"$destination"
}

_state_migrate_v2_locked() {
    local backup_file migration_root staged_registry next_registry
    local target_path legacy_json target_hash basename app_id staged_app staged_generation final_app
    local old_wrapper staged_wrapper old_lib manifest_path migrated_wrapper_hash
    local published_app
    local published_apps=()

    backup_file="${CLI_STORAGE}/registry.v2.$(_timestamp_slug).$$.bak"
    cp -p "$REGISTRY_FILE" "$backup_file"
    chmod 600 "$backup_file"

    migration_root=$(mktemp -d "${APPS_DIR}/.migration.XXXXXX")
    staged_registry=$(mktemp "${CLI_STORAGE}/.registry.migration.XXXXXX")
    jq -n --argjson schema "$STATE_SCHEMA" '{schema: $schema, apps: {}}' >"$staged_registry"

    while IFS= read -r target_path; do
        if [[ "$target_path" != /* || "$target_path" == *$'\n'* || "$target_path" == *$'\r'* ]]; then
            echo "[glibcx] Error: schema-2 registry contains an unsupported target path." >&2
            rm -f "$staged_registry"
            rm -rf "${migration_root:?}"
            return 1
        fi

        legacy_json=$(jq -c --arg path "$target_path" '.[$path]' "$REGISTRY_FILE")
        target_hash=$(jq -r '.orig_hash // empty' <<<"$legacy_json")
        if [[ ! "$target_hash" =~ ^[0-9a-fA-F]{64}$ ]]; then
            echo "[glibcx] Error: schema-2 entry '$target_path' has no valid original hash." >&2
            rm -f "$staged_registry"
            rm -rf "${migration_root:?}"
            return 1
        fi
        target_hash=${target_hash,,}
        basename=$(basename "$target_path")
        app_id=$(_state_allocate_id_from_registry "$staged_registry" "$basename" "$target_hash" "$target_path")
        staged_app="${migration_root}/${app_id}"
        staged_generation="${staged_app}/generations/1"
        final_app="${APPS_DIR}/${app_id}"
        mkdir -p "${staged_generation}/lib"

        old_wrapper="${BIN_DIR}/${basename}"
        staged_wrapper="${staged_generation}/wrapper"
        if [[ -f "$old_wrapper" ]]; then
            cp -p "$old_wrapper" "$staged_wrapper"
        fi
        migrated_wrapper_hash=""
        [[ -f "$staged_wrapper" ]] && migrated_wrapper_hash=$(_sha256_file "$staged_wrapper")
        old_lib="${CLI_STORAGE}/lib/${basename}"
        if [[ -d "$old_lib" ]]; then
            cp -a "${old_lib}/." "${staged_generation}/lib/"
        fi

        _state_migration_manifest \
            "${staged_generation}/manifest.json" "$app_id" "$target_path" "$target_hash" \
            "$legacy_json" "${final_app}/current/wrapper" "$migrated_wrapper_hash"
        ln -s generations/1 "${staged_app}/current"

        next_registry=$(mktemp "${CLI_STORAGE}/.registry.step.XXXXXX")
        manifest_path="${final_app}/current/manifest.json"
        if ! jq --arg path "$target_path" --arg app_id "$app_id" --arg manifest "$manifest_path" \
            --arg target_hash "$target_hash" \
            '.apps[$path] = {app_id: $app_id, manifest: $manifest, target_sha256: $target_hash}' \
            "$staged_registry" >"$next_registry"; then
            rm -f "$next_registry" "$staged_registry"
            rm -rf "${migration_root:?}"
            return 1
        fi
        mv -f "$next_registry" "$staged_registry"
    done < <(jq -r 'keys[]' "$REGISTRY_FILE")

    # Resolve every destination conflict before publishing the first app.
    while IFS= read -r staged_app; do
        app_id=$(basename "$staged_app")
        final_app="${APPS_DIR}/${app_id}"
        if [[ -e "$final_app" ]]; then
            if ! jq -e --arg id "$app_id" '.app_id == $id' \
                "${final_app}/current/manifest.json" >/dev/null 2>&1; then
                echo "[glibcx] Error: migration destination already exists: $final_app" >&2
                rm -f "$staged_registry"
                rm -rf "${migration_root:?}"
                return 1
            fi
        fi
    done < <(find "$migration_root" -mindepth 1 -maxdepth 1 -type d -print)

    while IFS= read -r staged_app; do
        app_id=$(basename "$staged_app")
        final_app="${APPS_DIR}/${app_id}"
        if [[ -e "$final_app" ]]; then
            rm -rf "${staged_app:?}"
        else
            if ! mv "$staged_app" "$final_app"; then
                for published_app in "${published_apps[@]}"; do
                    rm -rf "${published_app:?}"
                done
                rm -f "$staged_registry"
                rm -rf "${migration_root:?}"
                return 1
            fi
            published_apps+=("$final_app")
        fi
    done < <(find "$migration_root" -mindepth 1 -maxdepth 1 -type d -print)

    rm -rf "${migration_root:?}"
    next_registry=$(mktemp "${CLI_STORAGE}/.registry.final.XXXXXX")
    if ! jq '.apps |= with_entries(.value |= del(.target_sha256))' \
        "$staged_registry" >"$next_registry"; then
        for published_app in "${published_apps[@]}"; do
            rm -rf "${published_app:?}"
        done
        rm -f "$next_registry" "$staged_registry"
        return 1
    fi
    mv -f "$next_registry" "$staged_registry"
    if ! _state_commit_temp "$staged_registry" "$REGISTRY_FILE"; then
        for published_app in "${published_apps[@]}"; do
            rm -rf "${published_app:?}"
        done
        rm -f "$staged_registry"
        return 1
    fi
    echo "[glibcx] Migrated registry schema 2 -> 3 (backup: $backup_file)."
}

_state_upgrade_flat_v3_locked() {
    local target_path app_id old_manifest app_root generation_dir current_link
    local staged_registry staged_generation wrapper_path
    staged_registry=$(mktemp "${CLI_STORAGE}/.registry.generations.XXXXXX")
    cp -p "$REGISTRY_FILE" "$staged_registry"

    while IFS= read -r target_path; do
        app_id=$(jq -r --arg path "$target_path" '.apps[$path].app_id' "$REGISTRY_FILE")
        old_manifest=$(jq -r --arg path "$target_path" '.apps[$path].manifest' "$REGISTRY_FILE")
        app_root=$(state_app_root "$app_id")
        if [[ "$old_manifest" == "${app_root}/current/manifest.json" ]]; then
            continue
        fi
        if [[ "$old_manifest" != "${app_root}/manifest.json" || ! -f "$old_manifest" ]]; then
            echo "[glibcx] Error: schema-3 app has an unsupported pre-generation layout." >&2
            rm -f "$staged_registry"
            return 1
        fi
        generation_dir="${app_root}/generations/1"
        current_link="${app_root}/current"
        if [[ -e "$current_link" && ! -L "$current_link" ]]; then
            echo "[glibcx] Error: cannot create current-generation link for '$app_id'." >&2
            rm -f "$staged_registry"
            return 1
        fi
        if [[ ! -d "$generation_dir" ]]; then
            staged_generation=$(mktemp -d "${app_root}/.generation-upgrade.XXXXXX")
            mkdir -p "${staged_generation}/lib"
            [[ -d "${app_root}/lib" ]] && cp -a "${app_root}/lib/." "${staged_generation}/lib/"
            for wrapper_path in wrapper resolution.txt resolver-packages.json; do
                [[ -f "${app_root}/${wrapper_path}" ]] \
                    && cp -p "${app_root}/${wrapper_path}" "${staged_generation}/${wrapper_path}"
            done
            if ! jq --arg wrapper "${app_root}/current/wrapper" '
                .wrapper.path = $wrapper
                | .generation = 1
                | .status.needs_repatch = true
                | .migration = ((.migration // {}) + {from_layout: "flat-schema-3"})
            ' "$old_manifest" >"${staged_generation}/manifest.json"; then
                rm -rf "${staged_generation:?}"
                rm -f "$staged_registry"
                return 1
            fi
            chmod 600 "${staged_generation}/manifest.json"
            mkdir -p "${app_root}/generations"
            mv "$staged_generation" "$generation_dir"
        fi
        _state_atomic_symlink generations/1 "$current_link"
        if ! jq --arg path "$target_path" \
            --arg manifest "${app_root}/current/manifest.json" \
            '.apps[$path].manifest = $manifest' "$staged_registry" \
            >"${staged_registry}.next"; then
            rm -f "${staged_registry}.next" "$staged_registry"
            return 1
        fi
        mv "${staged_registry}.next" "$staged_registry"
    done < <(jq -r '.apps | keys[]' "$REGISTRY_FILE")

    if ! cmp -s "$staged_registry" "$REGISTRY_FILE"; then
        _state_commit_temp "$staged_registry" "$REGISTRY_FILE"
        while IFS= read -r target_path; do
            state_refresh_aliases_locked "$(basename "$target_path")" false
        done < <(jq -r '.apps | keys[]' "$REGISTRY_FILE")
        echo "[glibcx] Upgraded schema-3 app state to atomic generations. Repatch is recommended."
    else
        rm -f "$staged_registry"
    fi
}

state_initialize() {
    local registry_lock registry_kind migrated_path
    lock_acquire registry_lock registry

    if [[ ! -e "$REGISTRY_FILE" ]]; then
        _state_new_registry_locked
        lock_release "$registry_lock"
        return 0
    fi

    registry_kind=$(_state_registry_kind)
    case "$registry_kind" in
        v3)
            if ! _state_upgrade_flat_v3_locked; then
                lock_release "$registry_lock"
                return 1
            fi
            if ! _state_validate_v3_locked; then
                echo "[glibcx] Error: schema-3 registry or app manifest validation failed." >&2
                lock_release "$registry_lock"
                return 1
            fi
            ;;
        v2)
            if ! _state_migrate_v2_locked; then
                lock_release "$registry_lock"
                return 1
            fi
            while IFS= read -r migrated_path; do
                state_refresh_aliases_locked "$(basename "$migrated_path")" false
            done < <(json_list_paths)
            ;;
        *)
            echo "[glibcx] Error: registry is invalid: $REGISTRY_FILE" >&2
            lock_release "$registry_lock"
            return 1
            ;;
    esac
    lock_release "$registry_lock"
}

state_get_app_id() {
    local canonical_path="$1"
    jq -r --arg path "$canonical_path" '.apps[$path].app_id // empty' "$REGISTRY_FILE" 2>/dev/null
}

state_get_manifest_path() {
    local canonical_path="$1"
    jq -r --arg path "$canonical_path" '.apps[$path].manifest // empty' "$REGISTRY_FILE" 2>/dev/null
}

state_register_app_locked() {
    local canonical_path="$1" app_id="$2" manifest_path="$3" registry_tmp
    registry_tmp=$(mktemp "${CLI_STORAGE}/.registry.update.XXXXXX")
    if ! jq --arg path "$canonical_path" --arg app_id "$app_id" --arg manifest "$manifest_path" \
        '.apps[$path] = {app_id: $app_id, manifest: $manifest}' \
        "$REGISTRY_FILE" >"$registry_tmp"; then
        rm -f "$registry_tmp"
        return 1
    fi
    _state_commit_temp "$registry_tmp" "$REGISTRY_FILE"
}

state_write_patch_manifest() {
    local destination="$1" app_id="$2" target_path="$3" target_hash="$4"
    local target_size="$5" fingerprint="$6" interpreter="$7" glibc_required="$8"
    local needed_libs="$9" wrapper_path="${10}" wrapper_hash="${11}" library_path="${12}"
    local inspection_json="${13}" profile_json="${14}" verification_json="${15}"
    local dependencies_json="${16}" repository_json="${17:-null}" proc_exe_mode="${18:-off}"
    local created_at loader_hash
    local profile_id profile_manifest_path profile_manifest_hash

    created_at=$(_utc_timestamp)
    profile_id=$(jq -r '.profile_id' <<<"$profile_json")
    profile_manifest_path=$(runtime_manifest_path "$profile_id")
    profile_manifest_hash=""
    [[ -f "$profile_manifest_path" ]] && profile_manifest_hash=$(_sha256_file "$profile_manifest_path")
    loader_hash=""
    [[ -f "$(jq -r '.loader' <<<"$profile_json")" ]] \
        && loader_hash=$(_sha256_file "$(jq -r '.loader' <<<"$profile_json")")

    jq -n \
        --argjson schema "$STATE_SCHEMA" \
        --arg app_id "$app_id" \
        --arg created_at "$created_at" \
        --arg target_path "$target_path" \
        --arg basename "$(basename "$target_path")" \
        --arg target_hash "$target_hash" \
        --argjson target_size "$target_size" \
        --arg fingerprint "$fingerprint" \
        --arg interpreter "$interpreter" \
        --arg glibc_required "$glibc_required" \
        --arg needed_libs "$needed_libs" \
        --arg loader_hash "$loader_hash" \
        --arg wrapper_path "$wrapper_path" \
        --arg wrapper_hash "$wrapper_hash" \
        --arg library_path "$library_path" \
        --argjson inspection "$inspection_json" \
        --argjson profile "$profile_json" \
        --argjson verification "$verification_json" \
        --argjson dependencies "$dependencies_json" \
        --argjson repository "$repository_json" \
        --arg profile_manifest_hash "$profile_manifest_hash" \
        --arg proc_exe_mode "$proc_exe_mode" \
        '{
            schema: $schema,
            app_id: $app_id,
            created_at: $created_at,
            target: {
                path: $target_path,
                basename: $basename,
                sha256: $target_hash,
                size: $target_size,
                drift_fingerprint: $fingerprint
            },
            elf: {
                class: $inspection.header.class,
                data: $inspection.header.data,
                type: $inspection.header.type,
                machine: $inspection.header.machine,
                interpreter: $interpreter,
                abi_note: $inspection.notes.abi,
                build_id: $inspection.notes.build_id,
                gnu_properties: $inspection.notes.gnu_properties,
                gnu_stack_flags: $inspection.program_headers.gnu_stack_flags,
                writable_executable_load: $inspection.program_headers.writable_executable_load,
                rpath: $inspection.dynamic.rpath,
                runpath: $inspection.dynamic.runpath,
                soname: $inspection.dynamic.soname,
                dynamic_flags: $inspection.dynamic.flags,
                audit_filter_tags: $inspection.dynamic.audit_filter_tags,
                text_relocations: $inspection.dynamic.text_relocations,
                glibc_required: $glibc_required,
                version_requirements: $inspection.version_requirements,
                warnings: $inspection.warnings
            },
            runtime: {
                profile_id: $profile.profile_id,
                kind: $profile.kind,
                manifest_sha256: (if $profile_manifest_hash == "" then null else $profile_manifest_hash end),
                loader_sha256: (if $loader_hash == "" then null else $loader_hash end),
                compatibility: $profile.compatibility,
                selection_reason: (if $profile.kind == "system"
                    then "explicit mutable system profile"
                    else "highest-priority compatible signed managed profile"
                    end)
            },
            dependencies: (if $verification.verified then $dependencies else
                ($needed_libs | split("\n") | map(select(length > 0) | {
                    soname: ., path: null, sha256: null, build_id: null,
                    source_package: null, package_version: null,
                    package_sha256: null, repository_snapshot_digest: null,
                    needed: [], status: "unresolved"
                }))
                end),
            repository: $repository,
            verification: $verification,
            wrapper: {
                path: $wrapper_path,
                sha256: $wrapper_hash,
                abi_version: 3,
                library_path: $library_path,
                proc_exe_mode: $proc_exe_mode,
                tunables: ($profile.allowed_tunables // [])
            },
            status: {
                needs_repatch: false,
                target_drift: false,
                profile_drift: false,
                dependency_drift: ($verification.verified | not),
                wrapper_drift: false
            }
        }' >"$destination"
}

state_delete_app_locked() {
    local canonical_path="$1" registry_tmp
    registry_tmp=$(mktemp "${CLI_STORAGE}/.registry.delete.XXXXXX")
    if ! jq --arg path "$canonical_path" 'del(.apps[$path])' \
        "$REGISTRY_FILE" >"$registry_tmp"; then
        rm -f "$registry_tmp"
        return 1
    fi
    _state_commit_temp "$registry_tmp" "$REGISTRY_FILE"
}

state_manifest_value() {
    local canonical_path="$1" jq_filter="$2" manifest_path
    manifest_path=$(state_get_manifest_path "$canonical_path")
    if [[ -n "$manifest_path" && -f "$manifest_path" ]]; then
        jq -r "$jq_filter // empty" "$manifest_path" 2>/dev/null
    fi
}

# Compatibility accessors used by existing providers while command code moves
# to the schema-3 manifest API.
json_get_val() {
    local canonical_path="$1" key="$2"
    case "$key" in
        app_id) state_get_app_id "$canonical_path" ;;
        orig_hash) state_manifest_value "$canonical_path" '.target.sha256' ;;
        patched_fingerprint) state_manifest_value "$canonical_path" '.target.drift_fingerprint' ;;
        glibc_required) state_manifest_value "$canonical_path" '.elf.glibc_required' ;;
        patched_at) state_manifest_value "$canonical_path" '.created_at' ;;
        *) state_manifest_value "$canonical_path" ".${key}" ;;
    esac
}

json_list_paths() {
    jq -r '.apps | keys[]' "$REGISTRY_FILE" 2>/dev/null || true
}

state_target_for_alias() {
    local alias_name="$1" target_path app_id
    local matches=()
    while IFS= read -r target_path; do
        app_id=$(state_get_app_id "$target_path")
        if [[ "$app_id" == "$alias_name" || "$(basename "$target_path")" == "$alias_name" ]]; then
            matches+=("$target_path")
        fi
    done < <(json_list_paths)

    if [[ ${#matches[@]} -eq 1 ]]; then
        printf '%s\n' "${matches[0]}"
        return 0
    fi
    return 1
}

_state_managed_symlink() {
    local link_path="$1" link_target
    [[ -L "$link_path" ]] || return 1
    link_target=$(readlink "$link_path")
    [[ "$link_target" == "${APPS_DIR}/"*"/current/wrapper" \
        || "$link_target" == "${APPS_DIR}/"*"/wrapper" ]]
}

_state_atomic_symlink() {
    local target="$1" link_path="$2" link_tmp
    link_tmp="${link_path}.tmp.$$"
    rm -f "$link_tmp"
    ln -s "$target" "$link_tmp"
    mv -Tf "$link_tmp" "$link_path"
}

state_refresh_aliases_locked() {
    local basename="$1" replace_legacy="${2:-false}"
    local target_path owner_id owner_wrapper app_alias short_alias
    local owners=()

    while IFS= read -r target_path; do
        [[ "$(basename "$target_path")" == "$basename" ]] && owners+=("$target_path")
    done < <(json_list_paths)

    # Preflight every required app-ID alias before changing any alias. The
    # caller publishes registry/current first and can roll both back if this
    # check fails, while an unmanaged short command is deliberately preserved.
    for target_path in "${owners[@]}"; do
        owner_id=$(state_get_app_id "$target_path")
        owner_wrapper=$(state_current_wrapper_path "$owner_id")
        app_alias="${BIN_DIR}/${owner_id}"
        if [[ ! -f "$owner_wrapper" ]]; then
            echo "[glibcx] Error: current wrapper is missing for '$owner_id'." >&2
            return 1
        fi
        if [[ -e "$app_alias" || -L "$app_alias" ]] && ! _state_managed_symlink "$app_alias"; then
            echo "[glibcx] Error: refusing to replace unmanaged alias '$app_alias'." >&2
            return 1
        fi
    done

    for target_path in "${owners[@]}"; do
        owner_id=$(state_get_app_id "$target_path")
        owner_wrapper=$(state_current_wrapper_path "$owner_id")
        app_alias="${BIN_DIR}/${owner_id}"
        if ! _state_atomic_symlink "$owner_wrapper" "$app_alias"; then
            echo "[glibcx] Error: failed to publish app-ID alias '$app_alias'." >&2
            return 1
        fi
    done

    short_alias="${BIN_DIR}/${basename}"
    if [[ ${#owners[@]} -eq 1 ]]; then
        owner_id=$(state_get_app_id "${owners[0]}")
        owner_wrapper=$(state_current_wrapper_path "$owner_id")
        [[ -f "$owner_wrapper" ]] || return 0
        if [[ ! -e "$short_alias" && ! -L "$short_alias" ]] \
            || _state_managed_symlink "$short_alias" \
            || [[ "$replace_legacy" == "true" && -f "$short_alias" && ! -L "$short_alias" ]]; then
            if ! _state_atomic_symlink "$owner_wrapper" "$short_alias"; then
                echo "[glibcx] Error: failed to publish short alias '$short_alias'." >&2
                return 1
            fi
        else
            echo "[glibcx] Warning: preserving unmanaged command '$short_alias'." >&2
        fi
    elif _state_managed_symlink "$short_alias"; then
        if ! rm -f "$short_alias"; then
            echo "[glibcx] Error: failed to remove ambiguous alias '$short_alias'." >&2
            return 1
        fi
        echo "[glibcx] Removed ambiguous short alias '$basename'; use an app-ID alias."
    fi
}

state_remove_app_files_locked() {
    local app_id="$1" app_dir="${APPS_DIR}/${1}" app_alias="${BIN_DIR}/${1}"
    if _state_managed_symlink "$app_alias"; then
        rm -f "$app_alias"
    fi
    if [[ -d "$app_dir" && "$app_dir" == "${APPS_DIR}/"* ]]; then
        rm -rf "${app_dir:?}"
    fi
}
