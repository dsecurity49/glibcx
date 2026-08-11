_resolver_repository_keyring() {
    local destination="${CACHE_DIR}/apt/termux-glibc-keyring.gpg" fingerprints
    _require_command gpg gnupg
    if [[ ! -f "$TERMUX_GLIBC_KEYRING" ]]; then
        echo "[glibcx] Error: Termux repository key is unavailable: $TERMUX_GLIBC_KEYRING" >&2
        return 1
    fi
    fingerprints=$(LC_ALL=C gpg --batch --show-keys --with-colons "$TERMUX_GLIBC_KEYRING" 2>/dev/null \
        | awk -F: '$1 == "fpr" {print toupper($10)}')
    if ! grep -qx "$TERMUX_GLIBC_KEY_FINGERPRINT" <<<"$fingerprints"; then
        echo "[glibcx] Error: Termux repository keyring does not contain the pinned key." >&2
        return 1
    fi
    mkdir -p "${CACHE_DIR}/apt"
    if [[ ! -f "$destination" || "$(_sha256_file "$destination")" != "$(_sha256_file "$TERMUX_GLIBC_KEYRING")" ]]; then
        cp "$TERMUX_GLIBC_KEYRING" "$destination"
        chmod 644 "$destination"
    fi
    printf '%s\n' "$destination"
}

_resolver_apt_configure() {
    local apt_root="${CACHE_DIR}/apt/client" keyring="$1"
    local source_file="${apt_root}/sources.list" config_file="${apt_root}/apt.conf"
    if [[ "$TERMUX_GLIBC_REPOSITORY" != https://* ]]; then
        if [[ "$RESOLVER_TEST_ALLOW_LOCAL_REPOSITORY" != true \
            || "$TERMUX_GLIBC_REPOSITORY" != file://* ]]; then
            echo "[glibcx] Error: Termux glibc repository must use HTTPS." >&2
            return 1
        fi
    fi
    mkdir -p "${apt_root}/state/lists/partial" "${apt_root}/cache/archives/partial" "${apt_root}/etc"
    : >"${apt_root}/state/status"
    printf 'deb [arch=aarch64 signed-by=%s] %s %s %s\n' \
        "$keyring" "$TERMUX_GLIBC_REPOSITORY" "$TERMUX_GLIBC_DISTRIBUTION" \
        "$TERMUX_GLIBC_COMPONENT" >"$source_file"
    printf '%s\n' \
        "Dir::State \"${apt_root}/state\";" \
        "Dir::State::lists \"${apt_root}/state/lists\";" \
        "Dir::State::status \"${apt_root}/state/status\";" \
        "Dir::Cache \"${apt_root}/cache\";" \
        "Dir::Cache::archives \"${apt_root}/cache/archives\";" \
        "Dir::Etc::sourcelist \"${source_file}\";" \
        'Dir::Etc::sourceparts "-";' \
        "Dir::Etc::trusted \"${keyring}\";" \
        'Dir::Etc::trustedparts "-";' \
        'APT::Architecture "aarch64";' \
        'Acquire::Languages "none";' \
        'Acquire::AllowInsecureRepositories "false";' \
        'Acquire::AllowDowngradeToInsecureRepositories "false";' \
        'Acquire::Check-Valid-Until "true";' \
        'Acquire::GzipIndexes "false";' >"$config_file"
    printf '%s\n' "$config_file"
}

_resolver_verify_inrelease() {
    local inrelease_file="$1" keyring="$2" status signer primary expected
    expected=${TERMUX_GLIBC_KEY_FINGERPRINT^^}
    if ! status=$(LC_ALL=C gpgv --status-fd 1 --keyring "$keyring" "$inrelease_file" 2>/dev/null); then
        echo "[glibcx] Error: Termux glibc InRelease signature verification failed." >&2
        return 1
    fi
    signer=$(awk '$2 == "VALIDSIG" {print toupper($3); exit}' <<<"$status")
    primary=$(awk '$2 == "VALIDSIG" {print toupper($NF); exit}' <<<"$status")
    if [[ "$signer" != "$expected" && "$primary" != "$expected" ]]; then
        echo "[glibcx] Error: InRelease was not signed by the pinned Termux repository key." >&2
        return 1
    fi
    printf '%s\n' "$expected"
}

_resolver_release_hash_record() {
    local inrelease_file="$1" wanted_path="$2"
    awk -v wanted="$wanted_path" '
        $1 == "SHA256:" {inside=1; next}
        inside && /^[A-Za-z][A-Za-z0-9-]*:/ {exit}
        inside && $3 == wanted {print $1 "\t" $2; exit}
    ' "$inrelease_file"
}

_resolver_fetch_repository_file() {
    local relative_path="$1" destination="$2"
    if [[ "$RESOLVER_TEST_ALLOW_LOCAL_REPOSITORY" == true \
        && "$TERMUX_GLIBC_REPOSITORY" == file://* ]]; then
        cp "${TERMUX_GLIBC_REPOSITORY#file://}/${relative_path}" "$destination"
    else
        curl -fsSL --proto '=https' --tlsv1.2 \
            "${TERMUX_GLIBC_REPOSITORY}/${relative_path}" -o "$destination"
    fi
}

_resolver_repository_refresh() {
    local repository_lock keyring apt_config apt_lists inrelease packages
    local package_relative="${TERMUX_GLIBC_COMPONENT}/binary-aarch64/Packages"
    local contents_relative="${TERMUX_GLIBC_COMPONENT}/Contents-aarch64.gz"
    local package_record contents_record expected_hash expected_size signer
    local stage_dir contents_gz contents_file snapshot_digest snapshot_dir metadata_tmp state_tmp
    local repository_origin repository_suite apt_log
    lock_acquire repository_lock repository-metadata
    keyring=$(_resolver_repository_keyring) || { lock_release "$repository_lock"; return 1; }
    apt_config=$(_resolver_apt_configure "$keyring") || { lock_release "$repository_lock"; return 1; }
    apt_lists="${CACHE_DIR}/apt/client/state/lists"
    find "$apt_lists" -mindepth 1 -maxdepth 1 ! -name partial -delete
    apt_log=$(mktemp "${TMP_DIR}/apt-refresh.XXXXXX")
    if ! LC_ALL=C apt-get -c "$apt_config" update >"$apt_log" 2>&1; then
        echo "[glibcx] Error: isolated Termux glibc repository refresh failed." >&2
        tail -n 30 "$apt_log" >&2
        rm -f "$apt_log"
        lock_release "$repository_lock"
        return 1
    fi
    rm -f "$apt_log"
    inrelease=$(find "$apt_lists" -maxdepth 1 \( -type f -o -type l \) -name '*_InRelease' \
        | LC_ALL=C sort | sed -n '1p')
    packages=$(find "$apt_lists" -maxdepth 1 \( -type f -o -type l \) -name '*_Packages' \
        | LC_ALL=C sort | sed -n '1p')
    if [[ -z "$inrelease" || -z "$packages" ]]; then
        echo "[glibcx] Error: isolated APT refresh did not publish InRelease and Packages." >&2
        find "$apt_lists" -maxdepth 1 \( -type f -o -type l \) -printf '  %f\n' >&2 || true
        lock_release "$repository_lock"
        return 1
    fi
    signer=$(_resolver_verify_inrelease "$inrelease" "$keyring") \
        || { lock_release "$repository_lock"; return 1; }
    repository_origin=$(awk -F': ' '$1 == "Origin" {print $2; exit}' "$inrelease")
    repository_suite=$(awk -F': ' '$1 == "Suite" {print $2; exit}' "$inrelease")
    if [[ "$repository_origin" != "termux-glibc glibc" \
        || "$repository_suite" != "$TERMUX_GLIBC_DISTRIBUTION" ]]; then
        echo "[glibcx] Error: authenticated repository identity is unexpected." >&2
        lock_release "$repository_lock"
        return 1
    fi
    package_record=$(_resolver_release_hash_record "$inrelease" "$package_relative")
    contents_record=$(_resolver_release_hash_record "$inrelease" "$contents_relative")
    if [[ -z "$package_record" || -z "$contents_record" ]]; then
        echo "[glibcx] Error: InRelease does not authenticate required AArch64 indexes." >&2
        lock_release "$repository_lock"
        return 1
    fi
    expected_hash=${package_record%%$'\t'*}
    expected_size=${package_record#*$'\t'}
    if [[ "$(_sha256_file "$packages")" != "$expected_hash" \
        || "$(LC_ALL=C stat -Lc '%s' "$packages")" != "$expected_size" ]]; then
        echo "[glibcx] Error: APT Packages digest does not match InRelease." >&2
        echo "  expected: $expected_hash $expected_size" >&2
        echo "  observed: $(_sha256_file "$packages") $(LC_ALL=C stat -Lc '%s' "$packages")" >&2
        lock_release "$repository_lock"
        return 1
    fi

    mkdir -p "${CACHE_DIR}/apt/snapshots"
    stage_dir=$(mktemp -d "${CACHE_DIR}/apt/snapshots/.stage.XXXXXX")
    contents_gz="${stage_dir}/Contents-aarch64.gz"
    contents_file="${stage_dir}/Contents-aarch64"
    if ! _resolver_fetch_repository_file \
        "dists/${TERMUX_GLIBC_DISTRIBUTION}/${contents_relative}" "$contents_gz"; then
        rm -rf "${stage_dir:?}"
        lock_release "$repository_lock"
        return 1
    fi
    expected_hash=${contents_record%%$'\t'*}
    expected_size=${contents_record#*$'\t'}
    if [[ "$(_sha256_file "$contents_gz")" != "$expected_hash" \
        || "$(LC_ALL=C stat -c '%s' "$contents_gz")" != "$expected_size" ]]; then
        echo "[glibcx] Error: Contents digest does not match InRelease." >&2
        rm -rf "${stage_dir:?}"
        lock_release "$repository_lock"
        return 1
    fi
    gzip -dc "$contents_gz" >"$contents_file"
    cp "$inrelease" "${stage_dir}/InRelease"
    cp "$packages" "${stage_dir}/Packages"
    snapshot_digest=$(_sha256_file "${stage_dir}/InRelease")
    metadata_tmp="${stage_dir}/repository.json"
    jq -n \
        --arg origin "$repository_origin" \
        --arg suite "$repository_suite" \
        --arg architecture aarch64 \
        --arg inrelease_sha256 "$snapshot_digest" \
        --arg packages_sha256 "$(_sha256_file "${stage_dir}/Packages")" \
        --arg contents_sha256 "$(_sha256_file "$contents_file")" \
        --arg contents_archive_sha256 "$(_sha256_file "$contents_gz")" \
        --arg signer "$signer" \
        --arg accepted_at "$(_utc_timestamp)" \
        '{
            schema: 1,
            origin: $origin,
            suite: $suite,
            architecture: $architecture,
            inrelease_sha256: $inrelease_sha256,
            packages_sha256: $packages_sha256,
            contents_sha256: $contents_sha256,
            contents_archive_sha256: $contents_archive_sha256,
            signing_fingerprint: $signer,
            accepted_at: $accepted_at
        }' >"$metadata_tmp"
    snapshot_dir="${CACHE_DIR}/apt/snapshots/${snapshot_digest}"
    if [[ -d "$snapshot_dir" ]]; then
        rm -rf "${stage_dir:?}"
    else
        mv "$stage_dir" "$snapshot_dir"
    fi
    state_tmp=$(mktemp "${CACHE_DIR}/apt/.repository-state.XXXXXX")
    jq -n --arg digest "$snapshot_digest" --arg path "$snapshot_dir" \
        --arg updated_at "$(_utc_timestamp)" \
        '{schema: 1, snapshot_digest: $digest, path: $path, updated_at: $updated_at}' >"$state_tmp"
    _state_commit_temp "$state_tmp" "${CACHE_DIR}/apt/repository-state.json"
    lock_release "$repository_lock"
    printf '%s\n' "$snapshot_dir"
}

_resolver_repository_cached() {
    local state_file="${CACHE_DIR}/apt/repository-state.json" snapshot_dir metadata_file keyring signer
    [[ -f "$state_file" ]] || {
        echo "[glibcx] Error: no authenticated Termux glibc repository snapshot is cached." >&2
        return 1
    }
    snapshot_dir=$(jq -r '.path // empty' "$state_file")
    metadata_file="${snapshot_dir}/repository.json"
    if [[ "$snapshot_dir" != "${CACHE_DIR}/apt/snapshots/"* \
        || ! -f "$metadata_file" || ! -f "${snapshot_dir}/InRelease" \
        || ! -f "${snapshot_dir}/Packages" || ! -f "${snapshot_dir}/Contents-aarch64" ]]; then
        echo "[glibcx] Error: cached repository snapshot is incomplete." >&2
        return 1
    fi
    if [[ "$(_sha256_file "${snapshot_dir}/InRelease")" \
            != "$(jq -r '.inrelease_sha256' "$metadata_file")" \
        || "$(_sha256_file "${snapshot_dir}/Packages")" \
            != "$(jq -r '.packages_sha256' "$metadata_file")" \
        || "$(_sha256_file "${snapshot_dir}/Contents-aarch64")" \
            != "$(jq -r '.contents_sha256' "$metadata_file")" ]]; then
        echo "[glibcx] Error: cached repository snapshot drifted." >&2
        return 1
    fi
    keyring=$(_resolver_repository_keyring) || return 1
    signer=$(_resolver_verify_inrelease "${snapshot_dir}/InRelease" "$keyring") || return 1
    if [[ "$signer" != "$(jq -r '.signing_fingerprint' "$metadata_file")" ]]; then
        echo "[glibcx] Error: cached repository signer metadata drifted." >&2
        return 1
    fi
    printf '%s\n' "$snapshot_dir"
}

_resolver_repository_snapshot() {
    local offline="$1" refresh="$2"
    if [[ "$offline" == true ]]; then
        _resolver_repository_cached
    elif [[ "$refresh" == true || ! -f "${CACHE_DIR}/apt/repository-state.json" ]]; then
        _resolver_repository_refresh
    else
        _resolver_repository_cached
    fi
}

_resolver_contents_provider() {
    local contents_file="$1" soname="$2" providers provider_count
    providers=$(awk -v wanted="$soname" '
        {
            path=$1
            packages=$NF
            canonical_lib="/glibc/lib/" wanted
            canonical_usr_lib="/glibc/usr/lib/" wanted
            exact_lib=(length(path) >= length(canonical_lib) &&
                substr(path, length(path) - length(canonical_lib) + 1) == canonical_lib)
            exact_usr_lib=(length(path) >= length(canonical_usr_lib) &&
                substr(path, length(path) - length(canonical_usr_lib) + 1) == canonical_usr_lib)
            if (!exact_lib && !exact_usr_lib) next
            count=split(packages, names, ",")
            for (item_index=1; item_index<=count; item_index++) {
                name=names[item_index]
                sub(/^.*\//, "", name)
                if (name != "") print name
            }
        }
    ' "$contents_file" | LC_ALL=C sort -u)
    provider_count=$(awk 'NF {count++} END {print count + 0}' <<<"$providers")
    if [[ "$provider_count" -eq 0 ]]; then
        echo "[glibcx] Error: no authenticated repository provider found for '$soname'." >&2
        return 1
    elif [[ "$provider_count" -ne 1 ]]; then
        echo "[glibcx] Error: ambiguous repository providers for '$soname':" >&2
        sed 's/^/  /' <<<"$providers" >&2
        return 1
    fi
    printf '%s\n' "$providers"
}

_resolver_package_metadata() {
    local packages_file="$1" wanted_package="$2" records_file
    local version filename hash size best_version="" best_filename="" best_hash="" best_size=""
    records_file=$(mktemp "${TMP_DIR}/package-records.XXXXXX")
    awk -v wanted="$wanted_package" 'BEGIN {RS=""; FS="\n"}
        {
            package=architecture=version=filename=hash=size=""
            for (field_index=1; field_index<=NF; field_index++) {
                line=$field_index
                key=line
                sub(/:.*/, "", key)
                value=line
                sub(/^[^:]+:[[:space:]]*/, "", value)
                if (key == "Package") package=value
                else if (key == "Architecture") architecture=value
                else if (key == "Version") version=value
                else if (key == "Filename") filename=value
                else if (key == "SHA256") hash=value
                else if (key == "Size") size=value
            }
            if (package == wanted && architecture == "aarch64")
                print version "\t" filename "\t" hash "\t" size
        }
    ' "$packages_file" >"$records_file"
    while IFS=$'\t' read -r version filename hash size; do
        [[ -n "$version" && "$hash" =~ ^[0-9a-f]{64}$ && "$size" =~ ^[0-9]+$ ]] || continue
        _runtime_safe_relative_path "$filename" || continue
        if [[ -z "$best_version" ]] \
            || LC_ALL=C dpkg --compare-versions "$version" gt "$best_version"; then
            best_version="$version"
            best_filename="$filename"
            best_hash="$hash"
            best_size="$size"
        fi
    done <"$records_file"
    rm -f "$records_file"
    if [[ -z "$best_version" ]]; then
        echo "[glibcx] Error: Packages has no valid AArch64 record for '$wanted_package'." >&2
        return 1
    fi
    jq -cn --arg package "$wanted_package" --arg version "$best_version" \
        --arg filename "$best_filename" --arg sha256 "$best_hash" --argjson size "$best_size" \
        '{package: $package, version: $version, filename: $filename, sha256: $sha256, size: $size}'
}

_resolver_download_package() {
    local package_json="$1" offline="$2" expected_hash expected_size package_name package_version
    local package_cache apt_keyring apt_config download_dir downloaded_file apt_log
    expected_hash=$(jq -r '.sha256' <<<"$package_json")
    expected_size=$(jq -r '.size' <<<"$package_json")
    package_name=$(jq -r '.package' <<<"$package_json")
    package_version=$(jq -r '.version' <<<"$package_json")
    package_cache="${CACHE_DIR}/packages/${expected_hash}.deb"
    if [[ -f "$package_cache" && "$(_sha256_file "$package_cache")" == "$expected_hash" \
        && "$(LC_ALL=C stat -c '%s' "$package_cache")" == "$expected_size" ]]; then
        printf '%s\n' "$package_cache"
        return 0
    fi
    if [[ "$offline" == true ]]; then
        echo "[glibcx] Error: package '$package_name=$package_version' is absent from the offline cache." >&2
        return 1
    fi
    apt_keyring=$(_resolver_repository_keyring) || return 1
    apt_config=$(_resolver_apt_configure "$apt_keyring") || return 1
    download_dir=$(mktemp -d "${TMP_DIR}/package-download.XXXXXX")
    apt_log=$(mktemp "${TMP_DIR}/apt-download.XXXXXX")
    if ! (cd "$download_dir" && LC_ALL=C apt-get -qq -c "$apt_config" download \
        "${package_name}=${package_version}" >"$apt_log" 2>&1); then
        echo "[glibcx] Error: isolated package download failed for '$package_name=$package_version'." >&2
        tail -n 30 "$apt_log" >&2
        rm -f "$apt_log"
        rm -rf "${download_dir:?}"
        return 1
    fi
    rm -f "$apt_log"
    downloaded_file=$(find "$download_dir" -maxdepth 1 -type f -name '*.deb' -print -quit)
    if [[ -z "$downloaded_file" || "$(_sha256_file "$downloaded_file")" != "$expected_hash" \
        || "$(LC_ALL=C stat -c '%s' "$downloaded_file")" != "$expected_size" ]]; then
        echo "[glibcx] Error: downloaded package hash/size does not match authenticated Packages." >&2
        rm -rf "${download_dir:?}"
        return 1
    fi
    mv "$downloaded_file" "$package_cache"
    rm -rf "${download_dir:?}"
    printf '%s\n' "$package_cache"
}

_resolver_package_archive_validate() {
    local package_file="$1" list_file verbose_file archive_path normalized_path
    list_file=$(mktemp "${TMP_DIR}/deb-list.XXXXXX")
    verbose_file=$(mktemp "${TMP_DIR}/deb-types.XXXXXX")
    if ! LC_ALL=C dpkg-deb --fsys-tarfile "$package_file" | LC_ALL=C tar -tf - >"$list_file" \
        || ! LC_ALL=C dpkg-deb --fsys-tarfile "$package_file" | LC_ALL=C tar -tvf - >"$verbose_file"; then
        echo "[glibcx] Error: invalid Debian package payload." >&2
        rm -f "$list_file" "$verbose_file"
        return 1
    fi
    while IFS= read -r archive_path; do
        normalized_path=${archive_path#./}
        [[ -z "$normalized_path" ]] && continue
        normalized_path=${normalized_path%/}
        if ! _runtime_safe_relative_path "$normalized_path"; then
            echo "[glibcx] Error: unsafe path in Debian package: '$archive_path'." >&2
            rm -f "$list_file" "$verbose_file"
            return 1
        fi
    done <"$list_file"
    if ! awk 'substr($0, 1, 1) !~ /^[-dl]$/ {exit 1}' "$verbose_file"; then
        echo "[glibcx] Error: Debian package contains a special file or hard link." >&2
        rm -f "$list_file" "$verbose_file"
        return 1
    fi
    rm -f "$list_file" "$verbose_file"
}

_resolver_copy_package_dso() {
    local package_file="$1" soname="$2" app_lib="$3" package_json="$4" snapshot_dir="$5"
    local extract_root candidate candidate_count target resolved final_source source_name destination
    local inspection provenance_file provenance_tmp repository_json entry_json index
    local chain_sources=() chain_names=()
    _resolver_package_archive_validate "$package_file" || return 1
    extract_root=$(mktemp -d "${TMP_DIR}/package-extract.XXXXXX")
    if ! LC_ALL=C dpkg-deb -x "$package_file" "$extract_root"; then
        rm -rf "${extract_root:?}"
        return 1
    fi
    candidate=$(find "$extract_root" \( -type f -o -type l \) -name "$soname" -print)
    candidate_count=$(awk 'NF {count++} END {print count + 0}' <<<"$candidate")
    if [[ "$candidate_count" -ne 1 ]]; then
        echo "[glibcx] Error: package contains $candidate_count candidates for '$soname'." >&2
        rm -rf "${extract_root:?}"
        return 1
    fi
    for ((index=0; index<32; index++)); do
        source_name=$(basename "$candidate")
        chain_sources+=("$candidate")
        chain_names+=("$source_name")
        [[ -L "$candidate" ]] || break
        target=$(readlink "$candidate")
        if [[ "$target" == /* ]]; then
            resolved=$(realpath -m "${extract_root}${target}")
        else
            resolved=$(realpath -m "$(dirname "$candidate")/${target}")
        fi
        if [[ "$resolved" != "$extract_root"/* ]]; then
            echo "[glibcx] Error: package symlink for '$soname' escapes its payload." >&2
            rm -rf "${extract_root:?}"
            return 1
        fi
        candidate="$resolved"
    done
    if [[ -L "$candidate" || ! -f "$candidate" ]]; then
        echo "[glibcx] Error: package symlink chain for '$soname' is invalid or too deep." >&2
        rm -rf "${extract_root:?}"
        return 1
    fi
    inspection=$(elf_inspect "$candidate" dso)
    if [[ "$(jq -r '.valid' <<<"$inspection")" != true ]]; then
        echo "[glibcx] Error: repository provider for '$soname' is not a valid AArch64 DSO." >&2
        rm -rf "${extract_root:?}"
        return 1
    fi
    mkdir -p "$app_lib"
    for ((index=${#chain_sources[@]}-1; index>=0; index--)); do
        source_name=${chain_names[$index]}
        destination="${app_lib}/${source_name}"
        if [[ -L "${chain_sources[$index]}" ]]; then
            target=${chain_names[$((index + 1))]}
            if [[ -e "$destination" || -L "$destination" ]]; then
                [[ -L "$destination" && "$(readlink "$destination")" == "$target" ]] || {
                    echo "[glibcx] Error: dependency collision at '$destination'." >&2
                    rm -rf "${extract_root:?}"
                    return 1
                }
            else
                ln -s "$target" "$destination"
            fi
        else
            if [[ -e "$destination" ]]; then
                [[ -f "$destination" && "$(_sha256_file "$destination")" \
                    == "$(_sha256_file "${chain_sources[$index]}")" ]] || {
                    echo "[glibcx] Error: dependency collision at '$destination'." >&2
                    rm -rf "${extract_root:?}"
                    return 1
                }
            else
                cp -p "${chain_sources[$index]}" "$destination"
            fi
        fi
    done
    final_source="${app_lib}/${chain_names[${#chain_names[@]}-1]}"
    repository_json=$(cat "${snapshot_dir}/repository.json")
    entry_json=$(jq -cn \
        --arg soname "$soname" \
        --arg relative_path "lib/${soname}" \
        --arg file_hash "$(_sha256_file "$final_source")" \
        --argjson package "$package_json" \
        --argjson repository "$repository_json" \
        '{soname: $soname, relative_path: $relative_path, sha256: $file_hash,
          package: $package, repository: $repository}')
    provenance_file="$(dirname "$app_lib")/resolver-packages.json"
    provenance_tmp=$(mktemp "$(dirname "$app_lib")/.resolver-packages.XXXXXX")
    if [[ -f "$provenance_file" ]]; then
        jq --argjson entry "$entry_json" \
            '.libraries = ((.libraries + [$entry]) | unique_by(.soname, .sha256))' \
            "$provenance_file" >"$provenance_tmp"
    else
        jq -n --argjson entry "$entry_json" --argjson repository "$repository_json" \
            '{schema: 1, repository: $repository, libraries: [$entry]}' >"$provenance_tmp"
    fi
    mv "$provenance_tmp" "$provenance_file"
    rm -rf "${extract_root:?}"
}

_resolver_expand_search_path() {
    local declared_path="$1" origin="$2"
    case "$declared_path" in
        '$ORIGIN') printf '%s\n' "$origin" ;;
        '$ORIGIN/'*) printf '%s/%s\n' "$origin" "${declared_path#\$ORIGIN/}" ;;
        '${ORIGIN}') printf '%s\n' "$origin" ;;
        '${ORIGIN}/'*) printf '%s/%s\n' "$origin" "${declared_path#\$\{ORIGIN\}/}" ;;
        /*) printf '%s\n' "$declared_path" ;;
    esac
}

_resolver_find_library() {
    local soname="$1" app_lib="$2" profile_json="$3" origin="$4" inspection="$5"
    local search_dir declared
    local search_dirs=()
    if [[ "$(jq '.dynamic.runpath | length' <<<"$inspection")" -eq 0 ]]; then
        while IFS= read -r declared; do
            search_dir=$(_resolver_expand_search_path "$declared" "$origin")
            [[ -n "$search_dir" ]] && search_dirs+=("$search_dir")
        done < <(jq -r '.dynamic.rpath[]' <<<"$inspection")
    fi
    search_dirs+=("$app_lib")
    while IFS= read -r search_dir; do search_dirs+=("$search_dir"); done \
        < <(jq -r '.library_dirs[]' <<<"$profile_json")
    while IFS= read -r declared; do
        search_dir=$(_resolver_expand_search_path "$declared" "$origin")
        [[ -n "$search_dir" ]] && search_dirs+=("$search_dir")
    done < <(jq -r '.dynamic.runpath[]' <<<"$inspection")
    for search_dir in "${search_dirs[@]}"; do
        if [[ -f "${search_dir}/${soname}" ]]; then
            realpath -m "${search_dir}/${soname}"
            return 0
        fi
    done
    return 1
}

# Resolve and vendor the startup DSO closure by repeatedly asking the selected
# loader what is missing. This preserves the loader's per-object RPATH/RUNPATH
# semantics instead of trying to duplicate them in Bash.
resolver_prepare_startup_closure() {
    local profile_json="$1" target_bin="$2" target_inspection="$3" app_lib="$4"
    local offline="$5" refresh="$6" no_resolve="$7"
    local proc_exe_mode="${8:-off}"
    local probe_json list_output soname snapshot_dir="" provider package_json package_file
    local iteration=0
    declare -A attempted=()
    while :; do
        probe_json=$(loader_verify_target "$profile_json" "$app_lib" "$app_lib" \
            "$target_bin" "$target_inspection" "$proc_exe_mode") || return 1
        if [[ "$(jq -r '.verified' <<<"$probe_json")" == true ]]; then
            break
        fi
        [[ "$no_resolve" == false ]] || break
        list_output=$(jq -r '.list.output' <<<"$probe_json")
        soname=$(LC_ALL=C sed -n \
            's/.*error while loading shared libraries: \([^:][^:]*\): cannot open shared object file.*/\1/p' \
            <<<"$list_output" | LC_ALL=C tail -n 1)
        if [[ -z "$soname" || "$soname" == */* ]]; then
            echo "[glibcx] Error: loader failed without a safe missing SONAME to resolve." >&2
            jq -r '
                if .verify.exit_code != 0 then "  --verify: " + .verify.output else empty end,
                if .list.exit_code != 0 then "  --list: " + .list.output else empty end,
                .unexpected_resolutions[]? | "  " + .
            ' <<<"$probe_json" >&2
            return 1
        fi
        if [[ -n "${attempted[$soname]:-}" ]]; then
            echo "[glibcx] Error: loader still cannot resolve '$soname' after it was vendored." >&2
            return 1
        fi
        attempted[$soname]=1
        iteration=$((iteration + 1))
        if (( iteration > 512 )); then
            echo "[glibcx] Error: dependency closure exceeds 512 fetched SONAMEs." >&2
            return 1
        fi
        if [[ -z "$snapshot_dir" ]]; then
            snapshot_dir=$(_resolver_repository_snapshot "$offline" "$refresh") || return 1
            refresh=false
        fi
        provider=$(_resolver_contents_provider "${snapshot_dir}/Contents-aarch64" "$soname") \
            || return 1
        package_json=$(_resolver_package_metadata "${snapshot_dir}/Packages" "$provider") \
            || return 1
        package_file=$(_resolver_download_package "$package_json" "$offline") || return 1
        _resolver_copy_package_dso "$package_file" "$soname" "$app_lib" \
            "$package_json" "$snapshot_dir" || return 1
        [[ -f "${app_lib}/${soname}" ]] || {
            echo "[glibcx] Error: repository package did not provide '$soname'." >&2
            return 1
        }
    done
    if [[ -f "$(dirname "$app_lib")/resolver-packages.json" ]]; then
        jq -c '.repository' "$(dirname "$app_lib")/resolver-packages.json"
    else
        printf 'null\n'
    fi
}

_resolver_loader_entries() {
    awk '
        /=>[[:space:]]*\// {
            soname=$1
            line=$0
            sub(/^.*=>[[:space:]]*/, "", line)
            sub(/[[:space:]].*$/, "", line)
            print soname "\t" line
            next
        }
        /^[[:space:]]*\// {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            sub(/[[:space:]].*$/, "", line)
            count=split(line, parts, "/")
            print parts[count] "\t" line
        }
    '
}

_resolver_package_for_path() {
    local library_path="$1" package_name package_version
    package_name=$(LC_ALL=C dpkg-query -S "$library_path" 2>/dev/null | sed -n '1s/: .*//p' || true)
    package_name=${package_name%%:*}
    package_version=""
    if [[ -n "$package_name" ]]; then
        package_version=$(LC_ALL=C dpkg-query -W -f='${Version}' "$package_name" 2>/dev/null || true)
    fi
    printf '%s\t%s\n' "$package_name" "$package_version"
}

# resolver_manifest_dependencies <verification-json> <profile-summary-json>
#                                <actual-app-lib> <manifest-app-lib>
resolver_manifest_dependencies() {
    local verification_json="$1" profile_json="$2" actual_app_lib="$3" manifest_app_lib="$4"
    local list_output soname manifest_path actual_path inspection package_record package_name package_version
    local source_kind file_hash build_id needed_json entry_file loader_entries_file provenance_file provenance_entry
    local package_sha256 repository_snapshot_digest
    local profile_roots=()

    if [[ "$(jq -r '.verified' <<<"$verification_json")" != "true" ]]; then
        printf '[]\n'
        return 0
    fi
    list_output=$(jq -r '.list.output' <<<"$verification_json")
    while IFS= read -r profile_root; do
        profile_roots+=("$(realpath -m "$profile_root")")
    done < <(jq -r '.library_dirs[]' <<<"$profile_json")

    entry_file=$(mktemp "${TMP_DIR}/dependency-lock.XXXXXX")
    loader_entries_file=$(mktemp "${TMP_DIR}/dependency-loader-entries.XXXXXX")
    provenance_file="$(dirname "$actual_app_lib")/resolver-packages.json"
    : >"$entry_file"
    : >"$loader_entries_file"
    if jq -e '.audit != null' <<<"$verification_json" >/dev/null; then
        while IFS= read -r actual_path; do
            [[ -n "$actual_path" ]] || continue
            [[ "$actual_path" != linux-vdso.so.* ]] || continue
            if [[ "$actual_path" != /* ]]; then
                echo "[glibcx] Error: audit reported a non-absolute loaded object: '$actual_path'." >&2
                rm -f "$entry_file" "$loader_entries_file"
                return 1
            fi
            manifest_path="$actual_path"
            if [[ "$actual_path" == "$actual_app_lib" || "$actual_path" == "${actual_app_lib}/"* ]]; then
                manifest_path="${manifest_app_lib}${actual_path#"$actual_app_lib"}"
            fi
            printf '%s\t%s\n' "$(basename "$actual_path")" "$manifest_path" \
                >>"$loader_entries_file"
        done < <(jq -r '.audit.opened[]
            | select(.lmid == "0000000000000000") | .path' <<<"$verification_json")
    else
        _resolver_loader_entries <<<"$list_output" >"$loader_entries_file"
    fi
    while IFS=$'\t' read -r soname manifest_path; do
        [[ -n "$soname" && -n "$manifest_path" ]] || continue
        actual_path="$manifest_path"
        if [[ "$manifest_path" == "$manifest_app_lib" || "$manifest_path" == "${manifest_app_lib}/"* ]]; then
            actual_path="${actual_app_lib}${manifest_path#"$manifest_app_lib"}"
        fi
        if [[ ! -f "$actual_path" ]]; then
            echo "[glibcx] Error: loader resolved '$soname' to missing file '$actual_path'." >&2
            rm -f "$entry_file" "$loader_entries_file"
            return 1
        fi

        inspection=$(elf_inspect "$actual_path" dso)
        if [[ "$(jq -r '.valid' <<<"$inspection")" != "true" ]]; then
            echo "[glibcx] Error: resolved dependency '$actual_path' is not a valid AArch64 DSO." >&2
            rm -f "$entry_file" "$loader_entries_file"
            return 1
        fi
        soname=$(jq -r --arg fallback "$(basename "$actual_path")" \
            '.dynamic.soname // $fallback' <<<"$inspection")
        file_hash=$(_sha256_file "$actual_path")
        build_id=$(jq -r '.notes.build_id // empty' <<<"$inspection")
        needed_json=$(jq -c '.dynamic.needed' <<<"$inspection")
        source_kind="outside-allowed-roots"
        if [[ "$actual_path" == "$actual_app_lib" || "$actual_path" == "${actual_app_lib}/"* ]]; then
            source_kind="app-vendored"
        elif _loader_path_is_allowed "$(realpath -m "$actual_path")" "${profile_roots[@]}"; then
            source_kind="runtime-profile"
        fi
        package_record=$(_resolver_package_for_path "$actual_path")
        package_name=${package_record%%$'\t'*}
        package_version=${package_record#*$'\t'}
        package_sha256=""
        repository_snapshot_digest=""
        if [[ "$source_kind" == "app-vendored" && -f "$provenance_file" ]]; then
            provenance_entry=$(jq -c --arg soname "$soname" --arg hash "$file_hash" \
                'first(.libraries[] | select(.soname == $soname and .sha256 == $hash)) // empty' \
                "$provenance_file")
            if [[ -n "$provenance_entry" ]]; then
                source_kind="repository-package"
                package_name=$(jq -r '.package.package' <<<"$provenance_entry")
                package_version=$(jq -r '.package.version' <<<"$provenance_entry")
                package_sha256=$(jq -r '.package.sha256' <<<"$provenance_entry")
                repository_snapshot_digest=$(jq -r '.repository.inrelease_sha256' <<<"$provenance_entry")
            fi
        fi

        jq -cn \
            --arg soname "$soname" \
            --arg path "$manifest_path" \
            --arg hash "$file_hash" \
            --arg build_id "$build_id" \
            --arg source_kind "$source_kind" \
            --arg package_name "$package_name" \
            --arg package_version "$package_version" \
            --arg package_sha256 "$package_sha256" \
            --arg repository_snapshot_digest "$repository_snapshot_digest" \
            --argjson needed "$needed_json" \
            '{
                soname: $soname,
                path: $path,
                sha256: $hash,
                build_id: (if $build_id == "" then null else $build_id end),
                source: $source_kind,
                source_package: (if $package_name == "" then null else $package_name end),
                package_version: (if $package_version == "" then null else $package_version end),
                package_sha256: (if $package_sha256 == "" then null else $package_sha256 end),
                repository_snapshot_digest: (if $repository_snapshot_digest == "" then null else $repository_snapshot_digest end),
                needed: $needed,
                status: "resolved"
            }' >>"$entry_file"
    done <"$loader_entries_file"

    jq -s 'unique_by(.path) | sort_by(.soname, .path)' "$entry_file"
    rm -f "$entry_file" "$loader_entries_file"
}

cmd_deps() {
    local target_bin="${1:-}"
    local refresh=false verbose=false
    [[ $# -gt 0 ]] && shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --refresh) refresh=true; shift ;;
            --verbose) verbose=true; shift ;;
            *) echo "Usage: glibcx deps <binary> [--refresh] [--verbose]" >&2; return 1 ;;
        esac
    done
    if [[ -z "$target_bin" ]]; then
        echo "Usage: glibcx deps <binary> [--refresh] [--verbose]" >&2
        return 1
    fi
    init_env
    target_bin=$(realpath "$target_bin" 2>/dev/null || echo "$target_bin")
    local manifest_path
    manifest_path=$(state_get_manifest_path "$target_bin")
    if [[ -z "$manifest_path" || ! -f "$manifest_path" ]]; then
        echo "[glibcx] Error: '$target_bin' is not registered; patch it first." >&2
        return 1
    fi
    if [[ "$refresh" == true ]]; then
        local recorded_runtime recorded_proc_exe_mode
        recorded_runtime=$(jq -r '.runtime.profile_id' "$manifest_path")
        recorded_proc_exe_mode=$(jq -r '.wrapper.proc_exe_mode // "off"' "$manifest_path")
        cmd_patch "$target_bin" --runtime "$recorded_runtime" \
            --proc-exe="$recorded_proc_exe_mode" --refresh
        manifest_path=$(state_get_manifest_path "$target_bin")
    fi
    echo "[glibcx] Locked startup dependencies for $target_bin:"
    if [[ "$(jq '.dependencies | length' "$manifest_path")" -eq 0 ]]; then
        echo "  No verified dependency lock is recorded."
        return 1
    fi
    if [[ "$verbose" == true ]]; then
        jq -r '.dependencies[] |
            "  \(.soname)\n    path    : \(.path)\n    source  : \(.source)\n    package : \(.source_package // "unknown") \(.package_version // "")\n    sha256  : \(.sha256)\n    needs   : \(.needed | join(", "))"' \
            "$manifest_path"
    else
        jq -r '.dependencies[] |
            "  \(.soname) → \(.path) [\(.source_package // .source // "local")]"' \
            "$manifest_path"
        echo "[glibcx] Use --verbose for hashes, versions, and transitive NEEDED edges."
    fi
}
