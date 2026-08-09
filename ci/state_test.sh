#!/usr/bin/env bash
# Focused schema-3 state, migration, identity, and alias tests.
set -euo pipefail

pass() { printf '  PASS %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*" >&2; exit 1; }

TEST_TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "${TEST_TMP_DIR:?}"; }
trap cleanup EXIT

# shellcheck source=../src/common.sh
source src/common.sh
# shellcheck source=../src/lock.sh
source src/lock.sh
# shellcheck source=../src/state.sh
source src/state.sh

registry_lock=""

set_state_root() {
    local state_root="$1"
    CLI_STORAGE="$state_root"
    REGISTRY_FILE="${CLI_STORAGE}/registry.json"
    APPS_DIR="${CLI_STORAGE}/apps"
    BIN_DIR="${CLI_STORAGE}/bin"
    CACHE_DIR="${CLI_STORAGE}/cache"
    LOCK_DIR="${CLI_STORAGE}/locks"
    LOG_DIR="${CLI_STORAGE}/logs"
    TMP_DIR="${CLI_STORAGE}/tmp"
    PROFILE_STATE_DIR="${CLI_STORAGE}/profiles"
    RUNTIME_ROOT="${CLI_STORAGE}/managed-runtimes"
}

make_fake_app_locked() {
    local target_path="$1" target_hash="$2" app_id="$3"
    local app_dir="${APPS_DIR}/${app_id}" generation_dir="${APPS_DIR}/${app_id}/generations/1"
    mkdir -p "${generation_dir}/lib"
    printf '#!/usr/bin/env bash\nexit 0\n' >"${generation_dir}/wrapper"
    chmod 700 "${generation_dir}/wrapper"
    jq -n \
        --argjson schema "$STATE_SCHEMA" \
        --arg app_id "$app_id" \
        --arg path "$target_path" \
        --arg hash "$target_hash" \
        '{schema: $schema, generation: 1, app_id: $app_id,
          target: {path: $path, sha256: $hash}}' \
        >"${generation_dir}/manifest.json"
    ln -s generations/1 "${app_dir}/current"
    state_register_app_locked "$target_path" "$app_id" "${app_dir}/current/manifest.json"
}

# Fresh state is schema 3 and uses private state directories.
set_state_root "${TEST_TMP_DIR}/fresh"
init_env
jq -e '.schema == 3 and .apps == {}' "$REGISTRY_FILE" >/dev/null \
    || fail "fresh registry did not use schema 3"
[[ -d "$APPS_DIR" && -d "$LOCK_DIR" && -d "${CACHE_DIR}/packages" ]] \
    || fail "fresh state directories are incomplete"
pass "fresh schema-3 initialization"

# A schema-2 registry is backed up and converted without modifying its target
# or deleting the working legacy wrapper.
set_state_root "${TEST_TMP_DIR}/migration"
mkdir -p "$BIN_DIR" "${CLI_STORAGE}/lib/tool"
target_path="${TEST_TMP_DIR}/legacy/tool"
mkdir -p "$(dirname "$target_path")"
printf 'legacy-target\n' >"$target_path"
target_hash=$(_sha256_file "$target_path")
printf '#!/usr/bin/env bash\nexit 0\n' >"${BIN_DIR}/tool"
chmod 700 "${BIN_DIR}/tool"
printf 'legacy-lib\n' >"${CLI_STORAGE}/lib/tool/libexample.so.1"
jq -n \
    --arg path "$target_path" \
    --arg hash "$target_hash" \
    '{($path): {
        orig_hash: $hash,
        patched_fingerprint: "1_2_3_4_5",
        glibc_required: "GLIBC_2.17",
        patched_at: "2026-01-01T00:00:00Z"
    }}' >"$REGISTRY_FILE"

init_env
jq -e --arg path "$target_path" \
    '.schema == 3 and (.apps[$path].app_id | length) > 0' "$REGISTRY_FILE" >/dev/null \
    || fail "schema-2 registry was not migrated"
app_id=$(state_get_app_id "$target_path")
manifest_path=$(state_get_manifest_path "$target_path")
[[ -f "$manifest_path" ]] || fail "migration manifest is missing"
jq -e '.status.needs_repatch == true and .migration.from_schema == 2' \
    "$manifest_path" >/dev/null || fail "migration status is incomplete"
[[ -f "${APPS_DIR}/${app_id}/current/lib/libexample.so.1" ]] \
    || fail "legacy vendored library was not preserved"
[[ -L "${BIN_DIR}/${app_id}" ]] || fail "app-ID alias was not created"
[[ -f "${BIN_DIR}/tool" && ! -L "${BIN_DIR}/tool" ]] \
    || fail "legacy short wrapper was not preserved"
backup_count=$(find "$CLI_STORAGE" -maxdepth 1 -name 'registry.v2.*.bak' -type f | wc -l)
[[ "$backup_count" -eq 1 ]] || fail "migration backup was not created exactly once"
init_env
backup_count=$(find "$CLI_STORAGE" -maxdepth 1 -name 'registry.v2.*.bak' -type f | wc -l)
[[ "$backup_count" -eq 1 ]] || fail "schema-3 initialization repeated migration"
pass "recoverable schema-2 migration"

# A conflicting destination aborts migration without replacing the legacy
# registry, target, or wrapper, and without leaving partial migration state.
set_state_root "${TEST_TMP_DIR}/migration-failure"
mkdir -p "$BIN_DIR"
first_failed_target="${TEST_TMP_DIR}/aaa-legacy/alpha"
failed_target="${TEST_TMP_DIR}/legacy-failure/tool"
mkdir -p "$(dirname "$first_failed_target")" "$(dirname "$failed_target")"
printf 'first-legacy-target\n' >"$first_failed_target"
printf 'legacy-target\n' >"$failed_target"
first_failed_hash=$(_sha256_file "$first_failed_target")
failed_hash=$(_sha256_file "$failed_target")
printf '#!/usr/bin/env bash\nexit 0\n' >"${BIN_DIR}/alpha"
printf '#!/usr/bin/env bash\nexit 0\n' >"${BIN_DIR}/tool"
chmod 700 "${BIN_DIR}/alpha" "${BIN_DIR}/tool"
jq -n --arg first_path "$first_failed_target" --arg first_hash "$first_failed_hash" \
    --arg path "$failed_target" --arg hash "$failed_hash" \
    '{($first_path): {orig_hash: $first_hash, patched_fingerprint: "1_2_3_4_5"},
      ($path): {orig_hash: $hash, patched_fingerprint: "1_2_3_4_5"}}' \
    >"$REGISTRY_FILE"
failed_registry_hash=$(_sha256_file "$REGISTRY_FILE")
first_failed_id="alpha-${first_failed_hash:0:16}"
failed_id="tool-${failed_hash:0:16}"
mkdir -p "${APPS_DIR}/${failed_id}"
printf 'conflicting-state\n' >"${APPS_DIR}/${failed_id}/manifest.json"
if init_env >/dev/null 2>&1; then
    fail "conflicting migration destination did not abort"
fi
[[ "$(_sha256_file "$REGISTRY_FILE")" == "$failed_registry_hash" ]] \
    || fail "failed migration replaced the legacy registry"
[[ "$(cat "$failed_target")" == legacy-target \
    && -f "${BIN_DIR}/tool" ]] || fail "failed migration changed legacy files"
[[ ! -e "${APPS_DIR}/${first_failed_id}" ]] \
    || fail "destination preflight left an earlier app partially published"
if find "$APPS_DIR" -maxdepth 1 -name '.migration.*' -print -quit | grep -q .; then
    fail "failed migration left a partial staging directory"
fi
pass "interrupted/conflicting migration rollback"

# Development schema-3 state from before generation support is upgraded
# additively; the old flat files stay available until a successful repatch.
set_state_root "${TEST_TMP_DIR}/flat-v3"
mkdir -p "$BIN_DIR"
flat_target="${TEST_TMP_DIR}/flat-target/tool"
mkdir -p "$(dirname "$flat_target")"
printf 'flat-target\n' >"$flat_target"
flat_hash=$(_sha256_file "$flat_target")
flat_id="tool-${flat_hash:0:16}"
flat_root="${APPS_DIR}/${flat_id}"
mkdir -p "${flat_root}/lib"
printf '#!/usr/bin/env bash\nexit 0\n' >"${flat_root}/wrapper"
chmod 700 "${flat_root}/wrapper"
jq -n --argjson schema "$STATE_SCHEMA" --arg id "$flat_id" --arg path "$flat_target" \
    --arg wrapper "${flat_root}/wrapper" \
    '{schema: $schema, app_id: $id, target: {path: $path}, wrapper: {path: $wrapper},
      status: {needs_repatch: false}}' >"${flat_root}/manifest.json"
jq -n --argjson schema "$STATE_SCHEMA" --arg path "$flat_target" --arg id "$flat_id" \
    --arg manifest "${flat_root}/manifest.json" \
    '{schema: $schema, apps: {($path): {app_id: $id, manifest: $manifest}}}' >"$REGISTRY_FILE"
ln -s "${flat_root}/wrapper" "${BIN_DIR}/${flat_id}"
init_env
[[ -L "${flat_root}/current" \
    && "$(readlink "${flat_root}/current")" == generations/1 \
    && -f "${flat_root}/current/manifest.json" \
    && -f "${flat_root}/manifest.json" ]] || fail "flat schema-3 state was not upgraded additively"
jq -e --arg manifest "${flat_root}/current/manifest.json" --arg path "$flat_target" '
    .apps[$path].manifest == $manifest
' "$REGISTRY_FILE" >/dev/null || fail "flat schema-3 registry did not switch to current"
jq -e '.generation == 1 and .status.needs_repatch == true
       and .migration.from_layout == "flat-schema-3"' \
    "${flat_root}/current/manifest.json" >/dev/null || fail "flat upgrade did not request repatch"
[[ "$(readlink "${BIN_DIR}/${flat_id}")" == "${flat_root}/current/wrapper" ]] \
    || fail "flat schema-3 app alias was not moved to current"
pass "flat schema-3 generation upgrade"

# Alias publication preflights every required app-ID alias. A later conflict
# cannot leave an earlier owner half-published.
set_state_root "${TEST_TMP_DIR}/alias-transaction"
init_env
alias_target_one="${TEST_TMP_DIR}/alias-one/same"
alias_target_two="${TEST_TMP_DIR}/alias-two/same"
mkdir -p "$(dirname "$alias_target_one")" "$(dirname "$alias_target_two")"
printf 'one\n' >"$alias_target_one"
printf 'two\n' >"$alias_target_two"
alias_hash_one=$(_sha256_file "$alias_target_one")
alias_hash_two=$(_sha256_file "$alias_target_two")
alias_id_one="same-${alias_hash_one:0:16}"
alias_id_two="same-${alias_hash_two:0:16}"
make_fake_app_locked "$alias_target_one" "$alias_hash_one" "$alias_id_one"
make_fake_app_locked "$alias_target_two" "$alias_hash_two" "$alias_id_two"
printf 'unmanaged\n' >"${BIN_DIR}/${alias_id_two}"
if state_refresh_aliases_locked same false >/dev/null 2>&1; then
    fail "alias refresh accepted an unmanaged app-ID conflict"
fi
[[ ! -e "${BIN_DIR}/${alias_id_one}" \
    && "$(cat "${BIN_DIR}/${alias_id_two}")" == unmanaged ]] \
    || fail "alias preflight left partial publication"
pass "alias transaction preflight"

# Different binaries with the same basename receive different app aliases and
# lose the now-ambiguous convenience alias.
set_state_root "${TEST_TMP_DIR}/collisions"
init_env
first_target="${TEST_TMP_DIR}/one/same"
second_target="${TEST_TMP_DIR}/two/same"
mkdir -p "$(dirname "$first_target")" "$(dirname "$second_target")"
printf 'first\n' >"$first_target"
printf 'second\n' >"$second_target"
first_hash=$(_sha256_file "$first_target")
second_hash=$(_sha256_file "$second_target")
lock_acquire registry_lock registry
first_id=$(state_allocate_app_id_locked "$first_target" same "$first_hash")
make_fake_app_locked "$first_target" "$first_hash" "$first_id"
state_refresh_aliases_locked same true
[[ -L "${BIN_DIR}/same" ]] || fail "unique short alias was not created"
second_id=$(state_allocate_app_id_locked "$second_target" same "$second_hash")
make_fake_app_locked "$second_target" "$second_hash" "$second_id"
state_refresh_aliases_locked same true
lock_release "$registry_lock"
[[ "$first_id" != "$second_id" ]] || fail "different targets received the same app ID"
[[ -L "${BIN_DIR}/${first_id}" && -L "${BIN_DIR}/${second_id}" ]] \
    || fail "collision-safe app aliases are missing"
[[ ! -e "${BIN_DIR}/same" && ! -L "${BIN_DIR}/same" ]] \
    || fail "ambiguous short alias was retained"
pass "same-basename collision handling"

# Identical content at different canonical paths gets a path-derived suffix,
# so each manifest remains authoritative for exactly one target.
set_state_root "${TEST_TMP_DIR}/identical"
init_env
identical_one="${TEST_TMP_DIR}/identical-one/tool"
identical_two="${TEST_TMP_DIR}/identical-two/tool"
mkdir -p "$(dirname "$identical_one")" "$(dirname "$identical_two")"
printf 'identical\n' >"$identical_one"
cp "$identical_one" "$identical_two"
identical_hash=$(_sha256_file "$identical_one")
lock_acquire registry_lock registry
identical_first_id=$(state_allocate_app_id_locked "$identical_one" tool "$identical_hash")
make_fake_app_locked "$identical_one" "$identical_hash" "$identical_first_id"
identical_second_id=$(state_allocate_app_id_locked "$identical_two" tool "$identical_hash")
lock_release "$registry_lock"
expected_path_prefix=$(_sha256_text "$identical_two")
[[ "$identical_second_id" == "tool-${identical_hash:0:16}-${expected_path_prefix:0:12}" ]] \
    || fail "identical-content path collision did not use the documented suffix"
pass "identical-content path disambiguation"

# Invalid state fails closed and is not rewritten.
set_state_root "${TEST_TMP_DIR}/invalid"
mkdir -p "$CLI_STORAGE"
printf 'not-json\n' >"$REGISTRY_FILE"
invalid_before=$(_sha256_file "$REGISTRY_FILE")
if init_env 2>/dev/null; then
    fail "invalid registry was accepted"
fi
invalid_after=$(_sha256_file "$REGISTRY_FILE")
[[ "$invalid_before" == "$invalid_after" ]] || fail "invalid registry was modified"
pass "invalid registry fail-closed behavior"

printf '\nAll state tests passed.\n'
