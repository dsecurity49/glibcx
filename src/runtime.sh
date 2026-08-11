_runtime_safe_relative_path() {
    local relative_path="$1"
    [[ -n "$relative_path" ]] || return 1
    [[ "$relative_path" != /* && "$relative_path" != "." && "$relative_path" != ".." ]] || return 1
    [[ "$relative_path" != ../* && "$relative_path" != */../* && "$relative_path" != */.. ]] || return 1
    [[ "$relative_path" != *$'\n'* && "$relative_path" != *$'\r'* && "$relative_path" != *$'\t'* ]] || return 1
}

_runtime_fetch_asset() {
    local asset_url="$1" destination="$2"
    if [[ "$RUNTIME_TEST_ALLOW_LOCAL_ASSETS" == true ]]; then
        case "$asset_url" in
            file://*) cp "${asset_url#file://}" "$destination"; return ;;
            /*) cp "$asset_url" "$destination"; return ;;
        esac
    fi
    case "$asset_url" in
        https://github.com/dsecurity49/glibcx/releases/download/*|https://github.com/dsecurity49/glibcx/releases/latest/download/*)
            curl -fsSL --proto '=https' --tlsv1.2 "$asset_url" -o "$destination"
            ;;
        *)
            echo "[glibcx] Error: release asset URL is outside the canonical release channel: $asset_url" >&2
            return 1
            ;;
    esac
}

_runtime_verify_signature() {
    local signed_file="$1" signature_file="$2"
    local status signer_fingerprint primary_fingerprint expected_fingerprint
    _require_command gpgv gnupg
    if [[ ! -f "$RUNTIME_RELEASE_KEYRING" ]]; then
        echo "[glibcx] Error: release keyring is not installed: $RUNTIME_RELEASE_KEYRING" >&2
        return 1
    fi
    expected_fingerprint=$(printf '%s' "$RUNTIME_RELEASE_PRIMARY_FINGERPRINT" | tr '[:lower:]' '[:upper:]')
    if [[ ! "$expected_fingerprint" =~ ^[0-9A-F]{40,64}$ ]]; then
        echo "[glibcx] Error: the production release-key fingerprint has not been provisioned." >&2
        return 1
    fi
    if ! status=$(LC_ALL=C gpgv --status-fd 1 --keyring "$RUNTIME_RELEASE_KEYRING" \
        "$signature_file" "$signed_file" 2>/dev/null); then
        echo "[glibcx] Error: OpenPGP signature verification failed for '$signed_file'." >&2
        return 1
    fi
    signer_fingerprint=$(awk '$2 == "VALIDSIG" {print $3; exit}' <<<"$status")
    primary_fingerprint=$(awk '$2 == "VALIDSIG" {print $NF; exit}' <<<"$status")
    signer_fingerprint=${signer_fingerprint^^}
    primary_fingerprint=${primary_fingerprint^^}
    if [[ "$signer_fingerprint" != "$expected_fingerprint" \
        && "$primary_fingerprint" != "$expected_fingerprint" ]]; then
        echo "[glibcx] Error: signature was valid but not rooted in the pinned release key." >&2
        return 1
    fi
    # Return the exact signing key, which may be the pinned primary itself or
    # a certified signing subkey.
    printf '%s\n' "$signer_fingerprint"
}

_runtime_version_at_least() {
    local current="${1%%[-+]*}" required="${2%%[-+]*}"
    local current_major current_minor current_patch required_major required_minor required_patch
    [[ "$current" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ \
        && "$required" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] || return 1
    IFS=. read -r current_major current_minor current_patch <<<"$current"
    IFS=. read -r required_major required_minor required_patch <<<"$required"
    current_major=$((10#$current_major))
    current_minor=$((10#$current_minor))
    current_patch=$((10#$current_patch))
    required_major=$((10#$required_major))
    required_minor=$((10#$required_minor))
    required_patch=$((10#$required_patch))
    (( current_major > required_major \
        || (current_major == required_major && current_minor > required_minor) \
        || (current_major == required_major && current_minor == required_minor \
            && current_patch >= required_patch) ))
}

_runtime_catalog_validate() {
    local catalog_file="$1" issued_at published_at published_epoch expires_at expires_epoch current_epoch
    local minimum_version
    if ! jq -e --argjson compatibility_schema "$PROFILE_COMPATIBILITY_SCHEMA" '
        .schema == 1
        and (.catalog_version | type) == "number"
        and (.catalog_version | floor) == .catalog_version
        and .catalog_version >= 1
        and (.issued_at | type) == "string"
        and (.published_at | type) == "string"
        and (.expires_at | type) == "string"
        and (.min_glibcx_version | test("^[0-9]+[.][0-9]+[.][0-9]+([+-][A-Za-z0-9._-]+)?$"))
        and (.signing_subkey_fingerprint | test("^[0-9A-Fa-f]{40,64}$"))
        and .profile_compatibility_schema == $compatibility_schema
        and (.profiles | type) == "array"
        and ([.profiles[].profile_id] | length) == ([.profiles[].profile_id] | unique | length)
        and all(.profiles[];
            (.profile_id | type) == "string"
            and (.profile_id | test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
            and .architecture == "aarch64"
            and (.priority | type) == "number"
            and (.security_state | IN("recommended", "supported", "deprecated", "revoked"))
            and (.bundle.url | type) == "string"
            and (.bundle.signature_url | type) == "string"
            and (.bundle.sha256 | test("^[0-9a-f]{64}$"))
            and (.manifest_sha256 | test("^[0-9a-f]{64}$"))
        )
    ' "$catalog_file" >/dev/null; then
        echo "[glibcx] Error: runtime catalog schema or values are invalid." >&2
        return 1
    fi
    minimum_version=$(jq -r '.min_glibcx_version' "$catalog_file")
    if ! _runtime_version_at_least "$GLIBCX_VERSION" "$minimum_version"; then
        echo "[glibcx] Error: catalog requires glibcx $minimum_version or newer (running $GLIBCX_VERSION)." >&2
        return 1
    fi
    if [[ "$RUNTIME_TEST_ALLOW_LOCAL_ASSETS" != true ]] && ! jq -e '
        all(.profiles[];
            (.bundle.url | test("^https://github[.]com/dsecurity49/glibcx/releases/download/[^/]+/[^/]+$"))
            and .bundle.signature_url == (.bundle.url + ".asc")
        )
    ' "$catalog_file" >/dev/null; then
        echo "[glibcx] Error: runtime catalog contains an unversioned or non-canonical bundle URL." >&2
        return 1
    fi
    issued_at=$(jq -r '.issued_at' "$catalog_file")
    published_at=$(jq -r '.published_at' "$catalog_file")
    expires_at=$(jq -r '.expires_at' "$catalog_file")
    if [[ "$issued_at" != "$published_at" ]] \
        || ! published_epoch=$(date -u -d "$published_at" '+%s' 2>/dev/null) \
        || ! expires_epoch=$(date -u -d "$expires_at" '+%s' 2>/dev/null); then
        echo "[glibcx] Error: runtime catalog has an invalid publication/expiry timestamp." >&2
        return 1
    fi
    current_epoch=$(date -u '+%s')
    if (( expires_epoch - published_epoch != 180 * 24 * 60 * 60 )); then
        echo "[glibcx] Error: runtime catalog validity must be exactly 180 days." >&2
        return 1
    fi
    if (( current_epoch < published_epoch )); then
        echo "[glibcx] Error: runtime catalog publication time is in the future." >&2
        return 1
    fi
    if (( current_epoch > expires_epoch )); then
        echo "[glibcx] Error: runtime catalog expired at $expires_at." >&2
        return 1
    fi
}

_runtime_catalog_refresh() {
    local catalog_lock stage_dir catalog_file signature_file signer_fingerprint
    local catalog_version catalog_digest current_version=0 current_digest="" generation_dir state_tmp
    lock_acquire catalog_lock runtime-catalog
    mkdir -p "${CACHE_DIR}/catalogs"
    stage_dir=$(mktemp -d "${CACHE_DIR}/.catalog.stage.XXXXXX")
    catalog_file="${stage_dir}/catalog.json"
    signature_file="${stage_dir}/catalog.json.asc"
    if ! _runtime_fetch_asset "$RUNTIME_CATALOG_URL" "$catalog_file" \
        || ! _runtime_fetch_asset "$RUNTIME_CATALOG_SIGNATURE_URL" "$signature_file" \
        || ! signer_fingerprint=$(_runtime_verify_signature "$catalog_file" "$signature_file") \
        || ! _runtime_catalog_validate "$catalog_file"; then
        rm -rf "${stage_dir:?}"
        lock_release "$catalog_lock"
        return 1
    fi
    if [[ "${signer_fingerprint^^}" != "$(jq -r '.signing_subkey_fingerprint | ascii_upcase' "$catalog_file")" ]]; then
        echo "[glibcx] Error: catalog signer does not match its signed signing-subkey fingerprint." >&2
        rm -rf "${stage_dir:?}"
        lock_release "$catalog_lock"
        return 1
    fi

    catalog_version=$(jq -r '.catalog_version' "$catalog_file")
    if [[ -f "${PROFILE_STATE_DIR}/catalog-state.json" ]]; then
        current_version=$(jq -r '.highest_catalog_version // 0' \
            "${PROFILE_STATE_DIR}/catalog-state.json" 2>/dev/null || echo 0)
        current_digest=$(jq -r '.catalog_sha256 // empty' \
            "${PROFILE_STATE_DIR}/catalog-state.json" 2>/dev/null || true)
    fi
    if (( catalog_version < current_version )); then
        echo "[glibcx] Error: catalog rollback refused ($catalog_version < $current_version)." >&2
        rm -rf "${stage_dir:?}"
        lock_release "$catalog_lock"
        return 1
    fi

    catalog_digest=$(_sha256_file "$catalog_file")
    if (( catalog_version == current_version )) && [[ -n "$current_digest" \
        && "$catalog_digest" != "$current_digest" ]]; then
        echo "[glibcx] Error: catalog version $catalog_version changed without a version increment." >&2
        rm -rf "${stage_dir:?}"
        lock_release "$catalog_lock"
        return 1
    fi
    generation_dir="${CACHE_DIR}/catalogs/${catalog_digest}"
    if [[ -e "$generation_dir" ]]; then
        rm -rf "${stage_dir:?}"
    else
        mv "$stage_dir" "$generation_dir"
    fi
    state_tmp=$(mktemp "${PROFILE_STATE_DIR}/.catalog-state.XXXXXX")
    jq -n \
        --argjson version "$catalog_version" \
        --arg digest "$catalog_digest" \
        --arg catalog "${generation_dir}/catalog.json" \
        --arg signature "${generation_dir}/catalog.json.asc" \
        --arg signer "$signer_fingerprint" \
        --arg accepted_at "$(_utc_timestamp)" \
        '{
            schema: 1,
            highest_catalog_version: $version,
            catalog_sha256: $digest,
            catalog: $catalog,
            signature: $signature,
            signing_fingerprint: $signer,
            accepted_at: $accepted_at
        }' >"$state_tmp"
    _state_commit_temp "$state_tmp" "${PROFILE_STATE_DIR}/catalog-state.json"
    lock_release "$catalog_lock"
    printf '%s\n' "${generation_dir}/catalog.json"
}

_runtime_catalog_cached() {
    local state_file="${PROFILE_STATE_DIR}/catalog-state.json" catalog_file signature_file expected_digest signer
    if [[ ! -f "$state_file" ]] || ! jq -e '
        .schema == 1
        and (.catalog | type) == "string"
        and (.signature | type) == "string"
        and (.catalog_sha256 | test("^[0-9a-f]{64}$"))
    ' "$state_file" >/dev/null; then
        echo "[glibcx] Error: no verified runtime catalog is cached." >&2
        return 1
    fi
    catalog_file=$(jq -r '.catalog' "$state_file")
    signature_file=$(jq -r '.signature' "$state_file")
    expected_digest=$(jq -r '.catalog_sha256' "$state_file")
    if [[ ! -f "$catalog_file" || ! -f "$signature_file" \
        || "$(_sha256_file "$catalog_file")" != "$expected_digest" ]]; then
        echo "[glibcx] Error: cached runtime catalog is incomplete or drifted." >&2
        return 1
    fi
    signer=$(_runtime_verify_signature "$catalog_file" "$signature_file") || return 1
    _runtime_catalog_validate "$catalog_file" || return 1
    if [[ "${signer^^}" != "$(jq -r '.signing_subkey_fingerprint | ascii_upcase' "$catalog_file")" ]]; then
        echo "[glibcx] Error: cached catalog signer does not match the signed catalog field." >&2
        return 1
    fi
    printf '%s\n' "$catalog_file"
}

_runtime_archive_validate() {
    local archive_file="$1" list_file verbose_file archive_path normalized_path
    list_file=$(mktemp "${TMP_DIR}/archive-list.XXXXXX")
    verbose_file=$(mktemp "${TMP_DIR}/archive-types.XXXXXX")
    if ! LC_ALL=C tar -tJf "$archive_file" >"$list_file" \
        || ! LC_ALL=C tar -tvJf "$archive_file" >"$verbose_file"; then
        echo "[glibcx] Error: runtime bundle is not a readable xz-compressed tar archive." >&2
        rm -f "$list_file" "$verbose_file"
        return 1
    fi
    while IFS= read -r archive_path; do
        normalized_path=${archive_path#./}
        [[ -z "$normalized_path" ]] && continue
        normalized_path=${normalized_path%/}
        if ! _runtime_safe_relative_path "$normalized_path"; then
            echo "[glibcx] Error: unsafe path in runtime bundle: '$archive_path'." >&2
            rm -f "$list_file" "$verbose_file"
            return 1
        fi
    done <"$list_file"
    if ! awk 'substr($0, 1, 1) !~ /^[-dl]$/ {exit 1}' "$verbose_file"; then
        echo "[glibcx] Error: runtime bundle contains a special file or hard link." >&2
        rm -f "$list_file" "$verbose_file"
        return 1
    fi
    rm -f "$list_file" "$verbose_file"
}

_runtime_profile_manifest_validate() {
    local profile_file="$1" expected_id="$2" expected_prefix="$3"
    jq -e --arg id "$expected_id" --arg prefix "$expected_prefix" \
        --argjson compatibility_schema "$PROFILE_COMPATIBILITY_SCHEMA" '
        def safe_relative:
            type == "string"
            and length > 0
            and (startswith("/") | not)
            and (test("[\\t\\r\\n]") | not)
            and (split("/") | all(. != "" and . != "." and . != ".."));
        def under_prefix:
            type == "string"
            and startswith($prefix + "/")
            and (.[($prefix | length) + 1:] | safe_relative);
        .schema == 1
        and .compatibility_schema == $compatibility_schema
        and .profile_id == $id
        and .kind == "managed"
        and .architecture == "aarch64"
        and .elf_class == "ELF64"
        and .endianness == "little-endian"
        and (.created_at | type) == "string"
        and .prefix == $prefix
        and (.loader | under_prefix)
        and (.library_dirs | type) == "array"
        and (.library_dirs | length) > 0
        and all(.library_dirs[]; under_prefix)
        and (.files | type) == "array"
        and ([.files[].path] | length) == ([.files[].path] | unique | length)
        and all(.files[];
            (.path | safe_relative)
            and (.type | IN("file", "symlink"))
            and (if .type == "file"
                 then (.sha256 | test("^[0-9a-f]{64}$")) and (.mode | test("^(644|755)$"))
                 else (.target | type) == "string"
                 end)
        )
        and (.loader as $loader
            | ($loader | ltrimstr($prefix + "/")) as $loader_path
            | any(.files[]; .type == "file" and .path == $loader_path and .mode == "755"))
        and (.provided_versions | type) == "array"
        and (.allowed_tunables | type) == "array"
        and all(.allowed_tunables[]; test("^[A-Za-z0-9_.-]+=[A-Za-z0-9_.-]+$"))
        and (.loader_audit.path | under_prefix)
        and (.loader_audit.sha256 | test("^[0-9a-f]{64}$"))
        and .loader_audit.protocol == 1
        and .loader_audit.fd == 198
        and ((.loader_audit.path | ltrimstr($prefix + "/")) as $audit_path
            | .loader_audit.sha256 as $audit_hash
            | any(.files[]; .type == "file" and .path == $audit_path
                and .sha256 == $audit_hash and .mode == "755"))
        and (.loader_policy.glibc_hwcaps_mask | type) == "string"
        and (.termux.package_name | type) == "string"
        and (.termux.prefix | type) == "string"
        and (.termux.package_revision | type) == "string"
        and (.glibc_version | type) == "string"
        and (.android.min_api | type) == "number"
        and (.android.min_api | floor) == .android.min_api
        and .android.min_api >= 31
        and (.android.max_api | type) == "number"
        and (.android.max_api | floor) == .android.max_api
        and .android.max_api >= .android.min_api
        and (.kernel_min | type) == "string"
        and (.build.source_url | startswith("https://"))
        and (.build.source_sha256 | test("^[0-9a-f]{64}$"))
        and (.build.termux_glibc_commit | test("^[0-9a-f]{40}$"))
        and (.build.corresponding_source_url | startswith("https://"))
        and (.build.toolchain | type) == "string"
        and (.build.toolchain | length) > 0
        and (.build.licenses | type) == "array"
        and (.build.licenses | length) > 0
        and (if has("proc_exe_shim") then
            (.proc_exe_shim.path | under_prefix)
            and (.proc_exe_shim.sha256 | test("^[0-9a-f]{64}$"))
            and ((.proc_exe_shim.path | ltrimstr($prefix + "/")) as $shim_path
                | .proc_exe_shim.sha256 as $shim_hash
                | any(.files[]; .type == "file" and .path == $shim_path
                    and .sha256 == $shim_hash))
            and ((.proc_exe_shim.auto_targets // []) | type) == "array"
          else true end)
        and (has("signature_verified") | not)
        and (has("signed_manifest_sha256") | not)
        and (has("catalog_sha256") | not)
    ' "$profile_file" >/dev/null
}

_runtime_inventory_verify() {
    local profile_root="$1" profile_file="$2"
    local record relative_path entry_type expected actual mode target resolved
    local expected_paths actual_paths
    expected_paths=$(mktemp "${TMP_DIR}/profile-expected.XXXXXX")
    actual_paths=$(mktemp "${TMP_DIR}/profile-actual.XXXXXX")
    jq -r '.files[].path' "$profile_file" | LC_ALL=C sort >"$expected_paths"

    while IFS= read -r record; do
        relative_path=$(jq -r '.path' <<<"$record")
        entry_type=$(jq -r '.type' <<<"$record")
        if ! _runtime_safe_relative_path "$relative_path" \
            || [[ "$relative_path" == "profile.json" || "$relative_path" == "profile.json.asc" \
                || "$relative_path" == "manifest.json" ]]; then
            echo "[glibcx] Error: unsafe managed-profile inventory path '$relative_path'." >&2
            rm -f "$expected_paths" "$actual_paths"
            return 1
        fi
        if [[ "$entry_type" == "file" ]]; then
            if [[ ! -f "${profile_root}/${relative_path}" || -L "${profile_root}/${relative_path}" ]]; then
                echo "[glibcx] Error: managed-profile file is missing: $relative_path" >&2
                rm -f "$expected_paths" "$actual_paths"
                return 1
            fi
            expected=$(jq -r '.sha256' <<<"$record")
            actual=$(_sha256_file "${profile_root}/${relative_path}")
            mode=$(LC_ALL=C stat -c '%a' "${profile_root}/${relative_path}")
            if [[ "$expected" != "$actual" || "$mode" != "$(jq -r '.mode' <<<"$record")" ]]; then
                echo "[glibcx] Error: managed-profile file drift: $relative_path" >&2
                echo "  expected sha256/mode: $expected $(jq -r '.mode' <<<"$record")" >&2
                echo "  observed sha256/mode: $actual $mode" >&2
                rm -f "$expected_paths" "$actual_paths"
                return 1
            fi
        else
            if [[ ! -L "${profile_root}/${relative_path}" ]]; then
                echo "[glibcx] Error: managed-profile symlink is missing: $relative_path" >&2
                rm -f "$expected_paths" "$actual_paths"
                return 1
            fi
            target=$(readlink "${profile_root}/${relative_path}")
            expected=$(jq -r '.target' <<<"$record")
            resolved=$(realpath -m "$(dirname "${profile_root}/${relative_path}")/${target}")
            if [[ "$target" != "$expected" || "$target" == /* \
                || "$target" == *$'\n'* || "$target" == *$'\r'* ]] \
                || [[ "$resolved" != "$profile_root" && "$resolved" != "${profile_root}/"* ]]; then
                echo "[glibcx] Error: unsafe or drifted managed-profile symlink: $relative_path" >&2
                rm -f "$expected_paths" "$actual_paths"
                return 1
            fi
        fi
    done < <(jq -c '.files[]' "$profile_file")

    find "$profile_root" \( -type f -o -type l \) -print \
        | sed "s|^${profile_root}/||" \
        | grep -vE '^(profile[.]json([.]asc)?|manifest[.]json)$' \
        | LC_ALL=C sort >"$actual_paths"
    if ! cmp -s "$expected_paths" "$actual_paths"; then
        echo "[glibcx] Error: managed-profile inventory has missing or unlisted files." >&2
        diff -u "$expected_paths" "$actual_paths" >&2 || true
        rm -f "$expected_paths" "$actual_paths"
        return 1
    fi
    actual=$(wc -l <"$actual_paths")
    rm -f "$expected_paths" "$actual_paths"
    printf '%s\n' "$actual"
}

_runtime_apply_inventory_modes() {
    local profile_root="$1" profile_file="$2" record relative_path
    while IFS= read -r record; do
        relative_path=$(jq -r '.path' <<<"$record")
        if [[ ! -f "${profile_root}/${relative_path}" \
            || -L "${profile_root}/${relative_path}" ]]; then
            echo "[glibcx] Error: refusing to chmod a missing or non-regular profile file: $relative_path" >&2
            return 1
        fi
        chmod "$(jq -r '.mode' <<<"$record")" "${profile_root}/${relative_path}"
    done < <(jq -c '.files[] | select(.type == "file")' "$profile_file")
}

_runtime_verify_managed_dir() {
    local profile_root="$1" profile_id="$2" signed_profile signature_file signed_hash expected_hash
    local installed_manifest catalog_hash catalog_file catalog_signature catalog_entry current_catalog
    local profile_signer installed_signer catalog_signature_signer catalog_signer
    signed_profile="${profile_root}/profile.json"
    signature_file="${profile_root}/profile.json.asc"
    [[ -f "$signed_profile" && -f "$signature_file" ]] || {
        echo "[glibcx] Error: managed profile lacks its signed inner manifest." >&2
        return 1
    }
    _runtime_profile_manifest_validate "$signed_profile" "$profile_id" "$profile_root" || {
        echo "[glibcx] Error: signed managed-profile manifest is invalid." >&2
        return 1
    }
    profile_signer=$(_runtime_verify_signature "$signed_profile" "$signature_file") || return 1
    installed_manifest="${profile_root}/manifest.json"
    installed_signer=$(jq -r '.signing_fingerprint // empty | ascii_upcase' "$installed_manifest")
    if [[ "${profile_signer^^}" != "$installed_signer" ]]; then
        echo "[glibcx] Error: installed runtime signer metadata does not match its signature." >&2
        return 1
    fi
    signed_hash=$(_sha256_file "$signed_profile")
    expected_hash=$(jq -r '.signed_manifest_sha256 // empty' "$installed_manifest")
    if [[ -n "$expected_hash" && "$signed_hash" != "$expected_hash" ]]; then
        echo "[glibcx] Error: signed managed-profile manifest drifted." >&2
        return 1
    fi
    if ! jq -e --slurpfile signed "$signed_profile" '
        del(
            .signature_verified,
            .signed_manifest_sha256,
            .signing_fingerprint,
            .catalog_version,
            .catalog_sha256,
            .recommended,
            .security_state,
            .revoked,
            .priority,
            .installed_at
        ) == $signed[0]
    ' "$installed_manifest" >/dev/null; then
        echo "[glibcx] Error: installed runtime manifest diverges from its signed profile." >&2
        return 1
    fi
    catalog_hash=$(jq -r '.catalog_sha256 // empty' "$installed_manifest")
    catalog_file="${CACHE_DIR}/catalogs/${catalog_hash}/catalog.json"
    catalog_signature="${catalog_file}.asc"
    if [[ ! "$catalog_hash" =~ ^[0-9a-f]{64}$ || ! -f "$catalog_file" \
        || ! -f "$catalog_signature" || "$(_sha256_file "$catalog_file")" != "$catalog_hash" ]]; then
        echo "[glibcx] Error: installed runtime's signed catalog record is unavailable or drifted." >&2
        return 1
    fi
    catalog_signature_signer=$(_runtime_verify_signature "$catalog_file" "$catalog_signature") || return 1
    catalog_signer=$(jq -r '.signing_subkey_fingerprint | ascii_upcase' "$catalog_file")
    if [[ "${catalog_signature_signer^^}" != "$catalog_signer" \
        || "$installed_signer" != "$catalog_signer" ]]; then
        echo "[glibcx] Error: runtime and catalog signatures do not use the declared signing subkey." >&2
        return 1
    fi
    catalog_entry=$(jq -c --arg id "$profile_id" '.profiles[] | select(.profile_id == $id)' "$catalog_file")
    if [[ -z "$catalog_entry" ]] || ! jq -e \
        --argjson entry "$catalog_entry" --arg hash "$signed_hash" '
        .catalog_version == input.catalog_version
        and .security_state == $entry.security_state
        and .priority == $entry.priority
        and .recommended == ($entry.security_state == "recommended")
        and $entry.manifest_sha256 == $hash
    ' "$installed_manifest" "$catalog_file" >/dev/null; then
        echo "[glibcx] Error: installed runtime trust state does not match its signed catalog." >&2
        return 1
    fi
    if [[ -f "${PROFILE_STATE_DIR}/catalog-state.json" ]]; then
        current_catalog=$(jq -r '.catalog // empty' "${PROFILE_STATE_DIR}/catalog-state.json")
        if [[ -f "$current_catalog" ]] && jq -e --arg id "$profile_id" '
            any(.profiles[]; .profile_id == $id and .security_state == "revoked")
        ' "$current_catalog" >/dev/null; then
            echo "[glibcx] Error: managed runtime '$profile_id' is revoked by the current catalog." >&2
            return 1
        fi
    fi
    _runtime_inventory_verify "$profile_root" "$signed_profile"
}

runtime_manifest_path() {
    local profile_id="$1"
    case "$profile_id" in
        system) printf '%s/system.json\n' "$PROFILE_STATE_DIR" ;;
        *[!A-Za-z0-9._-]*|""|.|..)
            echo "[glibcx] Error: invalid runtime profile ID '$profile_id'." >&2
            return 1
            ;;
        *) printf '%s/%s/manifest.json\n' "$RUNTIME_ROOT" "$profile_id" ;;
    esac
}

runtime_profile_load() {
    local profile_id="$1" output_mode="${2:-full}" manifest_path
    manifest_path=$(runtime_manifest_path "$profile_id") || return 1
    if [[ ! -f "$manifest_path" ]]; then
        echo "[glibcx] Error: runtime profile '$profile_id' is not installed." >&2
        return 1
    fi
    if ! jq -e --arg id "$profile_id" '
        .schema == 1
        and .profile_id == $id
        and (.prefix | type) == "string"
        and (.loader | type) == "string"
        and (.library_dirs | type) == "array"
        and (.files | type) == "array"
    ' "$manifest_path" >/dev/null; then
        echo "[glibcx] Error: runtime manifest is invalid: $manifest_path" >&2
        return 1
    fi
    if [[ "$output_mode" == "summary" ]]; then
        jq -c 'del(.files)' "$manifest_path"
    else
        jq -c . "$manifest_path"
    fi
}

_runtime_current_termux_package() {
    local current_prefix="${PREFIX:-/data/data/com.termux/files/usr}" package_path
    package_path=${current_prefix#/data/data/}
    if [[ "$package_path" != "$current_prefix" && "$package_path" == */files/usr ]]; then
        printf '%s\n' "${package_path%%/*}"
    else
        printf 'unknown\n'
    fi
}

_runtime_profile_compatible() {
    local profile_json="$1" inspection_json="${2:-}" expected_prefix current_package
    local minimum_api maximum_api current_api minimum_kernel current_kernel lowest_kernel
    [[ "$(jq -r '.architecture' <<<"$profile_json")" == aarch64 ]] || return 1
    if [[ "$(jq -r '.kind' <<<"$profile_json")" == managed ]]; then
        expected_prefix=$(jq -r '.termux.prefix // empty' <<<"$profile_json")
        current_package=$(_runtime_current_termux_package)
        [[ "$expected_prefix" == "${PREFIX:-/data/data/com.termux/files/usr}" ]] || return 1
        if [[ "$current_package" != unknown ]]; then
            [[ "$(jq -r '.termux.package_name // empty' <<<"$profile_json")" \
                == "$current_package" ]] || return 1
        fi
        minimum_api=$(jq -r '.android.min_api' <<<"$profile_json")
        maximum_api=$(jq -r '.android.max_api' <<<"$profile_json")
        if command -v getprop >/dev/null 2>&1; then
            current_api=$(getprop ro.build.version.sdk 2>/dev/null || true)
            [[ "$current_api" =~ ^[0-9]+$ && "$current_api" -ge "$minimum_api" \
                && "$current_api" -le "$maximum_api" ]] || return 1
        fi
        minimum_kernel=$(jq -r '.kernel_min' <<<"$profile_json")
        current_kernel=$(uname -r 2>/dev/null | sed 's/[-+].*$//' || true)
        if [[ -n "$minimum_kernel" && -n "$current_kernel" ]]; then
            lowest_kernel=$(printf '%s\n%s\n' "$minimum_kernel" "$current_kernel" \
                | LC_ALL=C sort -V | head -n 1)
            [[ "$lowest_kernel" == "$minimum_kernel" ]] || return 1
        fi
    fi
    if [[ -n "$inspection_json" && "$(jq -r '.kind' <<<"$profile_json")" == managed ]]; then
        jq -e --argjson target "$inspection_json" '
            (.provided_versions // []) as $provided
            | all($target.version_requirements[]; . as $required | $provided | index($required) != null)
        ' <<<"$profile_json" >/dev/null || return 1
    fi
}

runtime_profile_select() {
    local requested_profile="${1:-}" inspection_json="${2:-}" profile_manifest profile_id
    if [[ -n "$requested_profile" ]]; then
        runtime_profile_verify "$requested_profile" >/dev/null || return 1
        profile_manifest=$(runtime_profile_load "$requested_profile" summary) || return 1
        if ! _runtime_profile_compatible "$profile_manifest" "$inspection_json"; then
            echo "[glibcx] Error: runtime '$requested_profile' is incompatible with this target or Termux prefix." >&2
            return 1
        fi
        if [[ "$(jq -r '.kind' <<<"$profile_manifest")" == "system" ]]; then
            echo "[glibcx] WARNING: using mutable development profile 'system'." >&2
        fi
        printf '%s\n' "$profile_manifest"
        return 0
    fi

    # Stable automatic selection considers only verified, recommended managed
    # profiles and walks them in deterministic catalog priority order.
    while IFS=$'\t' read -r _ profile_manifest_path; do
        if jq -e '
            .kind == "managed"
            and .signature_verified == true
            and .recommended == true
            and (.revoked // false | not)
        ' "$profile_manifest_path" >/dev/null 2>&1; then
            profile_id=$(jq -r '.profile_id' "$profile_manifest_path")
            if runtime_profile_verify "$profile_id" >/dev/null 2>&1; then
                profile_manifest=$(runtime_profile_load "$profile_id" summary)
                if _runtime_profile_compatible "$profile_manifest" "$inspection_json"; then
                    printf '%s\n' "$profile_manifest"
                    return 0
                fi
            fi
        fi
    done < <(find "$RUNTIME_ROOT" -mindepth 2 -maxdepth 2 -name manifest.json -type f -print0 2>/dev/null \
        | xargs -0 -r jq -r '[(.priority // 0), input_filename] | @tsv' \
        | sort -t $'\t' -k1,1nr -k2,2)

    echo "[glibcx] Error: no compatible signed managed runtime profile is installed." >&2
    echo "[glibcx] Development only: run 'glibcx runtime import-system', then patch with '--runtime system'." >&2
    return 1
}

_runtime_snapshot_files() {
    local profile_prefix="$1" output_file="$2" absolute_path relative_path file_hash link_target
    local hash_record record_file tab_file
    local inventory_roots=()
    local candidate_root

    for candidate_root in \
        "${profile_prefix}/lib" \
        "${profile_prefix}/etc" \
        "${profile_prefix}/share/i18n" \
        "${profile_prefix}/share/locale"; do
        [[ -d "$candidate_root" ]] && inventory_roots+=("$candidate_root")
    done
    [[ ${#inventory_roots[@]} -gt 0 ]] || return 1

    record_file=$(mktemp "${TMP_DIR}/system-hashes.XXXXXX")
    tab_file=$(mktemp "${TMP_DIR}/system-files-tab.XXXXXX")
    : >"$tab_file"

    find "${inventory_roots[@]}" -type f -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 -r sha256sum --zero >"$record_file"
    while IFS= read -r -d '' hash_record; do
        file_hash=${hash_record%%  *}
        absolute_path=${hash_record#*  }
        relative_path=${absolute_path#"${profile_prefix}/"}
        if [[ "$relative_path" == "$absolute_path" || "$relative_path" == /* \
            || "$relative_path" == ".." || "$relative_path" == ../* \
            || "$relative_path" == *$'\t'* || "$relative_path" == *$'\n'* \
            || "$relative_path" == *$'\r'* ]]; then
            echo "[glibcx] Error: unsafe runtime path '$absolute_path'." >&2
            rm -f "$record_file" "$tab_file"
            return 1
        fi
        printf '%s\tfile\t%s\n' "$relative_path" "$file_hash" >>"$tab_file"
    done <"$record_file"

    while IFS= read -r -d '' absolute_path; do
        relative_path=${absolute_path#"${profile_prefix}/"}
        if [[ "$relative_path" == "$absolute_path" || "$relative_path" == /* \
            || "$relative_path" == ".." || "$relative_path" == ../* \
            || "$relative_path" == *$'\t'* || "$relative_path" == *$'\n'* \
            || "$relative_path" == *$'\r'* ]]; then
            echo "[glibcx] Error: unsafe runtime symlink path '$absolute_path'." >&2
            rm -f "$record_file" "$tab_file"
            return 1
        fi
        if ! link_target=$(readlink "$absolute_path"); then
            echo "[glibcx] Error: cannot read runtime symlink '$absolute_path'." >&2
            rm -f "$record_file" "$tab_file"
            return 1
        fi
        if [[ "$link_target" == *$'\t'* || "$link_target" == *$'\n'* || "$link_target" == *$'\r'* ]]; then
            echo "[glibcx] Error: unsupported runtime symlink target in '$absolute_path'." >&2
            rm -f "$record_file" "$tab_file"
            return 1
        fi
        printf '%s\tsymlink\t%s\n' "$relative_path" "$link_target" >>"$tab_file"
    done < <(find "${inventory_roots[@]}" -type l -print0 | LC_ALL=C sort -z)

    jq -Rn '[
        inputs
        | split("\t")
        | if .[1] == "file"
          then {path: .[0], type: "file", sha256: .[2]}
          else {path: .[0], type: "symlink", target: .[2]}
          end
    ]' <"$tab_file" >"$output_file"
    rm -f "$record_file" "$tab_file"
}

cmd_runtime_import_system() {
    init_env
    if [[ ! -x "$GLIBC_INTERPRETER" || ! -d "$GLIBC_LIB_DIR" ]]; then
        echo "[glibcx] Error: Termux glibc is not installed at '$GLIBC_PREFIX'." >&2
        return 1
    fi
    if ! LC_ALL=C readelf -W -h "$GLIBC_INTERPRETER" 2>/dev/null \
        | awk -F: '/Machine:/{sub(/^[[:space:]]+/, "", $2); if ($2 == "AArch64") found=1} END {exit !found}'; then
        echo "[glibcx] Error: system glibc loader is not AArch64." >&2
        return 1
    fi

    local profile_lock snapshot_file manifest_tmp package_version created_at files_digest checked_count
    lock_acquire profile_lock runtime-system
    snapshot_file=$(mktemp "${TMP_DIR}/system-files.XXXXXX")
    manifest_tmp=$(mktemp "${PROFILE_STATE_DIR}/.system.XXXXXX")
    if ! _runtime_snapshot_files "$GLIBC_PREFIX" "$snapshot_file"; then
        rm -f "$snapshot_file" "$manifest_tmp"
        lock_release "$profile_lock"
        return 1
    fi

    package_version=$(LC_ALL=C dpkg-query -W -f='${Version}' glibc 2>/dev/null || echo unknown)
    created_at=$(_utc_timestamp)
    checked_count=$(jq 'length' "$snapshot_file")
    files_digest=$(jq -c . "$snapshot_file" \
        | LC_ALL=C sha256sum | LC_ALL=C awk '{print $1}')
    if ! jq -n \
        --arg created_at "$created_at" \
        --arg prefix "$GLIBC_PREFIX" \
        --arg loader "$GLIBC_INTERPRETER" \
        --arg lib_dir "$GLIBC_LIB_DIR" \
        --arg package_version "$package_version" \
        --arg files_digest "$files_digest" \
        --slurpfile file_arrays "$snapshot_file" \
        '{
            schema: 1,
            profile_id: "system",
            kind: "system",
            immutable: false,
            signature_verified: false,
            recommended: false,
            created_at: $created_at,
            architecture: "aarch64",
            prefix: $prefix,
            loader: $loader,
            library_dirs: [$lib_dir],
            package: {name: "glibc", version: $package_version},
            files_digest: $files_digest,
            inventory_roots: ["lib", "etc", "share/i18n", "share/locale"],
            files: $file_arrays[0],
            allowed_tunables: [],
            compatibility: {
                purpose: "development-migration-emergency",
                mutable: true
            }
        }' >"$manifest_tmp"; then
        rm -f "$snapshot_file" "$manifest_tmp"
        lock_release "$profile_lock"
        return 1
    fi
    rm -f "$snapshot_file"
    _state_commit_temp "$manifest_tmp" "${PROFILE_STATE_DIR}/system.json"
    lock_release "$profile_lock"
    echo "[glibcx] Imported mutable system profile · $checked_count entries · $package_version"
    echo "[glibcx] WARNING: system is for development, migration, and emergency use only."
}

runtime_profile_verify() {
    local profile_id="$1" profile_manifest prefix manifest_path snapshot_file
    local expected_digest actual_digest checked_count
    profile_manifest=$(runtime_profile_load "$profile_id") || return 1
    prefix=$(jq -r '.prefix' <<<"$profile_manifest")
    if [[ "$(jq -r '.kind' <<<"$profile_manifest")" == "managed" ]]; then
        checked_count=$(_runtime_verify_managed_dir "$prefix" "$profile_id") || return 1
        echo "[glibcx] Runtime '$profile_id' verified: $checked_count entries."
        return 0
    elif [[ "$(jq -r '.kind' <<<"$profile_manifest")" != "system" ]]; then
        echo "[glibcx] Error: unsupported runtime profile kind." >&2
        return 1
    fi

    snapshot_file=$(mktemp "${TMP_DIR}/verify-${profile_id}.XXXXXX")
    if ! _runtime_snapshot_files "$prefix" "$snapshot_file"; then
        rm -f "$snapshot_file"
        return 1
    fi
    expected_digest=$(jq -c '.files' <<<"$profile_manifest" \
        | LC_ALL=C sha256sum | LC_ALL=C awk '{print $1}')
    actual_digest=$(jq -c . "$snapshot_file" \
        | LC_ALL=C sha256sum | LC_ALL=C awk '{print $1}')
    checked_count=$(jq 'length' "$snapshot_file")
    if [[ "$expected_digest" != "$actual_digest" ]]; then
        manifest_path=$(runtime_manifest_path "$profile_id")
        echo "[glibcx] Runtime '$profile_id' drifted. First differing paths:" >&2
        jq -nr --slurpfile manifest "$manifest_path" --slurpfile actual "$snapshot_file" '
            def by_path: map({key: .path, value: .}) | from_entries;
            ($manifest[0].files | by_path) as $expected
            | ($actual[0] | by_path) as $observed
            | [((($expected | keys) + ($observed | keys)) | unique)[]
                | select($expected[.] != $observed[.])][0:20][]
        ' | sed 's/^/  /' >&2
        rm -f "$snapshot_file"
        return 1
    fi
    rm -f "$snapshot_file"
    echo "[glibcx] Runtime '$profile_id' verified: $checked_count entries."
}

cmd_runtime_list() {
    init_env
    local found=0 manifest_path
    echo "[glibcx] Runtime profiles:"
    if [[ -f "${PROFILE_STATE_DIR}/system.json" ]]; then
        jq -r '"  \(.profile_id) [\(.kind)] glibc=\(.package.version) mutable=\(.immutable | not)"' \
            "${PROFILE_STATE_DIR}/system.json"
        found=1
    fi
    while IFS= read -r manifest_path; do
        jq -r '"  \(.profile_id) [\(.kind)] recommended=\(.recommended // false) signed=\(.signature_verified // false)"' \
            "$manifest_path"
        found=1
    done < <(find "$RUNTIME_ROOT" -mindepth 2 -maxdepth 2 -name manifest.json -type f 2>/dev/null | LC_ALL=C sort)
    [[ "$found" -eq 1 ]] || echo "  No profiles installed."
}

cmd_runtime_remove() {
    local profile_id="${1:-}"
    [[ -n "$profile_id" ]] || { echo "Usage: glibcx runtime remove <profile>" >&2; return 1; }
    init_env
    local profile_lock references manifest_path
    references=$(while IFS= read -r target_path; do
        [[ "$(state_manifest_value "$target_path" '.runtime.profile_id')" == "$profile_id" ]] \
            && printf '%s\n' "$target_path"
    done < <(json_list_paths))
    if [[ -n "$references" ]]; then
        echo "[glibcx] Error: runtime '$profile_id' is referenced by registered apps:" >&2
        sed 's/^/  /' <<<"$references" >&2
        return 1
    fi
    lock_acquire profile_lock "runtime-$(_sha256_text "$profile_id")"
    manifest_path=$(runtime_manifest_path "$profile_id") || { lock_release "$profile_lock"; return 1; }
    if [[ "$profile_id" == "system" ]]; then
        rm -f "$manifest_path"
    else
        local profile_dir
        profile_dir=$(dirname "$manifest_path")
        if [[ "$profile_dir" != "$RUNTIME_ROOT"/* || "$profile_dir" == "$RUNTIME_ROOT" ]]; then
            echo "[glibcx] Error: refusing unsafe managed runtime path '$profile_dir'." >&2
            lock_release "$profile_lock"
            return 1
        fi
        rm -rf "${profile_dir:?}"
    fi
    lock_release "$profile_lock"
    echo "[glibcx] Removed runtime profile '$profile_id'."
}

cmd_runtime_install() {
    local requested_profile="${1:-}" offline=false
    [[ $# -gt 0 ]] && shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --offline) offline=true; shift ;;
            *) echo "Usage: glibcx runtime install <profile|recommended> [--offline]" >&2; return 1 ;;
        esac
    done
    [[ -n "$requested_profile" ]] || {
        echo "Usage: glibcx runtime install <profile|recommended> [--offline]" >&2
        return 1
    }
    init_env

    if [[ "$requested_profile" != "recommended" \
        && -f "${RUNTIME_ROOT}/${requested_profile}/manifest.json" ]]; then
        runtime_profile_verify "$requested_profile"
        echo "[glibcx] Runtime profile '$requested_profile' is already installed."
        return 0
    fi

    local catalog_file catalog_entry profile_id profile_lock bundle_url signature_url
    local bundle_hash manifest_hash catalog_version catalog_digest package_file signature_file
    local stage_dir final_dir signed_hash signer_fingerprint profile_signer catalog_signer
    local manifest_tmp checked_count
    if [[ "$offline" == true ]]; then
        catalog_file=$(_runtime_catalog_cached) || return 1
    else
        catalog_file=$(_runtime_catalog_refresh) || return 1
    fi
    if [[ "$requested_profile" == "recommended" ]]; then
        catalog_entry=$(jq -c '
            [.profiles[] | select(.security_state == "recommended")]
            | sort_by(-.priority, .profile_id)
            | .[0] // empty
        ' "$catalog_file")
    else
        catalog_entry=$(jq -c --arg id "$requested_profile" \
            '.profiles[] | select(.profile_id == $id)' "$catalog_file")
    fi
    if [[ -z "$catalog_entry" || "$catalog_entry" == "null" ]]; then
        echo "[glibcx] Error: runtime profile '$requested_profile' is not available in the signed catalog." >&2
        return 1
    fi
    if [[ "$(jq -r '.security_state' <<<"$catalog_entry")" == "revoked" ]]; then
        echo "[glibcx] Error: runtime profile '$requested_profile' is revoked." >&2
        return 1
    fi

    profile_id=$(jq -r '.profile_id' <<<"$catalog_entry")
    bundle_url=$(jq -r '.bundle.url' <<<"$catalog_entry")
    signature_url=$(jq -r '.bundle.signature_url' <<<"$catalog_entry")
    bundle_hash=$(jq -r '.bundle.sha256' <<<"$catalog_entry")
    manifest_hash=$(jq -r '.manifest_sha256' <<<"$catalog_entry")
    catalog_version=$(jq -r '.catalog_version' "$catalog_file")
    catalog_signer=$(jq -r '.signing_subkey_fingerprint | ascii_upcase' "$catalog_file")
    catalog_digest=$(_sha256_file "$catalog_file")
    final_dir="${RUNTIME_ROOT}/${profile_id}"

    lock_acquire profile_lock "runtime-$(_sha256_text "$profile_id")"
    if [[ -f "${final_dir}/manifest.json" ]]; then
        lock_release "$profile_lock"
        runtime_profile_verify "$profile_id"
        echo "[glibcx] Runtime profile '$profile_id' is already installed."
        return 0
    fi
    mkdir -p "$RUNTIME_ROOT" "${CACHE_DIR}/packages"
    package_file="${CACHE_DIR}/packages/${bundle_hash}.runtime.tar.xz"
    signature_file="${CACHE_DIR}/packages/${bundle_hash}.runtime.tar.xz.asc"
    if [[ ! -f "$package_file" || "$(_sha256_file "$package_file")" != "$bundle_hash" ]]; then
        if [[ "$offline" == true ]]; then
            echo "[glibcx] Error: runtime bundle '$profile_id' is not present in the offline cache." >&2
            lock_release "$profile_lock"
            return 1
        fi
        local package_tmp
        package_tmp=$(mktemp "${CACHE_DIR}/packages/.runtime.XXXXXX")
        if ! _runtime_fetch_asset "$bundle_url" "$package_tmp" \
            || [[ "$(_sha256_file "$package_tmp")" != "$bundle_hash" ]]; then
            echo "[glibcx] Error: runtime bundle hash verification failed." >&2
            rm -f "$package_tmp"
            lock_release "$profile_lock"
            return 1
        fi
        mv "$package_tmp" "$package_file"
    fi
    if [[ ! -f "$signature_file" ]]; then
        if [[ "$offline" == true ]]; then
            echo "[glibcx] Error: runtime bundle signature is not present in the offline cache." >&2
            lock_release "$profile_lock"
            return 1
        fi
        local signature_tmp
        signature_tmp=$(mktemp "${CACHE_DIR}/packages/.runtime-signature.XXXXXX")
        if ! _runtime_fetch_asset "$signature_url" "$signature_tmp"; then
            rm -f "$signature_tmp"
            lock_release "$profile_lock"
            return 1
        fi
        mv "$signature_tmp" "$signature_file"
    fi
    if ! signer_fingerprint=$(_runtime_verify_signature "$package_file" "$signature_file") \
        || ! _runtime_archive_validate "$package_file"; then
        lock_release "$profile_lock"
        return 1
    fi
    if [[ "${signer_fingerprint^^}" != "$catalog_signer" ]]; then
        echo "[glibcx] Error: runtime bundle was not signed by the catalog signing subkey." >&2
        lock_release "$profile_lock"
        return 1
    fi

    stage_dir=$(mktemp -d "${RUNTIME_ROOT}/.${profile_id}.stage.XXXXXX")
    if ! tar -xJf "$package_file" --no-same-owner --no-same-permissions -C "$stage_dir"; then
        rm -rf "${stage_dir:?}"
        lock_release "$profile_lock"
        return 1
    fi
    if [[ ! -f "${stage_dir}/profile.json" || ! -f "${stage_dir}/profile.json.asc" ]]; then
        echo "[glibcx] Error: runtime bundle lacks profile.json and its signature." >&2
        rm -rf "${stage_dir:?}"
        lock_release "$profile_lock"
        return 1
    fi
    signed_hash=$(_sha256_file "${stage_dir}/profile.json")
    profile_signer=$(_runtime_verify_signature \
        "${stage_dir}/profile.json" "${stage_dir}/profile.json.asc") || profile_signer=""
    if [[ "$signed_hash" != "$manifest_hash" \
        || "${profile_signer^^}" != "$catalog_signer" ]] \
        || ! _runtime_profile_manifest_validate "${stage_dir}/profile.json" "$profile_id" "$final_dir"; then
        echo "[glibcx] Error: signed runtime profile manifest verification failed." >&2
        rm -rf "${stage_dir:?}"
        lock_release "$profile_lock"
        return 1
    fi
    if ! _runtime_apply_inventory_modes "$stage_dir" "${stage_dir}/profile.json"; then
        rm -rf "${stage_dir:?}"
        lock_release "$profile_lock"
        return 1
    fi
    checked_count=$(_runtime_inventory_verify "$stage_dir" "${stage_dir}/profile.json") || {
        rm -rf "${stage_dir:?}"
        lock_release "$profile_lock"
        return 1
    }
    manifest_tmp="${stage_dir}/.manifest.json.tmp"
    jq \
        --arg signed_hash "$signed_hash" \
        --arg signer "$signer_fingerprint" \
        --argjson catalog_version "$catalog_version" \
        --arg catalog_digest "$catalog_digest" \
        --arg installed_at "$(_utc_timestamp)" \
        --argjson recommended "$(jq '.security_state == "recommended"' <<<"$catalog_entry")" \
        --arg security_state "$(jq -r '.security_state' <<<"$catalog_entry")" \
        --argjson priority "$(jq '.priority' <<<"$catalog_entry")" \
        '. + {
            signature_verified: true,
            signed_manifest_sha256: $signed_hash,
            signing_fingerprint: $signer,
            catalog_version: $catalog_version,
            catalog_sha256: $catalog_digest,
            recommended: $recommended,
            security_state: $security_state,
            revoked: ($security_state == "revoked"),
            priority: $priority,
            installed_at: $installed_at
        }' "${stage_dir}/profile.json" >"$manifest_tmp"
    mv "$manifest_tmp" "${stage_dir}/manifest.json"
    mv "$stage_dir" "$final_dir"
    lock_release "$profile_lock"
    echo "[glibcx] Installed signed managed runtime '$profile_id' ($checked_count files)."
}

cmd_runtime() {
    local subcommand="${1:-}"
    [[ $# -gt 0 ]] && shift
    case "$subcommand" in
        list) cmd_runtime_list ;;
        import-system) cmd_runtime_import_system ;;
        verify)
            init_env
            runtime_profile_verify "${1:-system}"
            ;;
        remove) cmd_runtime_remove "${1:-}" ;;
        install)
            cmd_runtime_install "$@"
            ;;
        *)
            echo "Usage: glibcx runtime list|import-system|verify [profile]|remove <profile>|install <profile>" >&2
            return 1
            ;;
    esac
}
