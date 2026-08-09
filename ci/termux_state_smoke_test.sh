#!/usr/bin/env bash
# Device-only smoke test for schema-3 patching and same-basename aliases.
set -euo pipefail

pass() { printf '  PASS %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*" >&2; exit 1; }

TERMUX_GLIBC_BASH="${PREFIX:-/data/data/com.termux/files/usr}/glibc/bin/bash"
GLIBCX_UNDER_TEST="${GLIBCX_UNDER_TEST:-./glibcx-bin}"
[[ -x "$GLIBCX_UNDER_TEST" ]] || GLIBCX_UNDER_TEST=./glibcx
if [[ ! -x "$TERMUX_GLIBC_BASH" ]]; then
    echo "SKIP: Termux glibc bash is not installed."
    exit 0
fi

TEST_TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "${TEST_TMP_DIR:?}"; }
trap cleanup EXIT

mkdir -p "${TEST_TMP_DIR}/home" "${TEST_TMP_DIR}/one" "${TEST_TMP_DIR}/two"
cp "$TERMUX_GLIBC_BASH" "${TEST_TMP_DIR}/one/bash"
cp "$TERMUX_GLIBC_BASH" "${TEST_TMP_DIR}/two/bash"
first_target="${TEST_TMP_DIR}/one/bash"
second_target="${TEST_TMP_DIR}/two/bash"
first_hash=$(sha256sum "$first_target" | awk '{print $1}')

HOME="${TEST_TMP_DIR}/home" "$GLIBCX_UNDER_TEST" runtime import-system
system_profile="${TEST_TMP_DIR}/home/.glibcx/profiles/system.json"
profile_tmp="${system_profile}.test"
jq '.allowed_tunables = ["glibc.malloc.check=0"]' "$system_profile" >"$profile_tmp"
mv "$profile_tmp" "$system_profile"
HOME="${TEST_TMP_DIR}/home" "$GLIBCX_UNDER_TEST" patch "$first_target" --runtime system
HOME="${TEST_TMP_DIR}/home" "$GLIBCX_UNDER_TEST" patch "$second_target" --runtime system

registry="${TEST_TMP_DIR}/home/.glibcx/registry.json"
jq -e '.schema == 3 and (.apps | length) == 2' "$registry" >/dev/null \
    || fail "two patched targets were not registered"
first_id=$(jq -r --arg path "$first_target" '.apps[$path].app_id' "$registry")
second_id=$(jq -r --arg path "$second_target" '.apps[$path].app_id' "$registry")
[[ "$first_id" != "$second_id" ]] || fail "identical targets received the same app ID"
[[ -L "${TEST_TMP_DIR}/home/.glibcx/bin/${first_id}" ]] \
    || fail "first app-ID alias is missing"
[[ -L "${TEST_TMP_DIR}/home/.glibcx/bin/${second_id}" ]] \
    || fail "second app-ID alias is missing"
[[ ! -e "${TEST_TMP_DIR}/home/.glibcx/bin/bash" ]] \
    || fail "ambiguous short alias still exists"

first_version=$(HOME="${TEST_TMP_DIR}/home" \
    "${TEST_TMP_DIR}/home/.glibcx/bin/${first_id}" --version | sed -n '1p')
[[ "$first_version" == *"GNU bash"* ]] || fail "first wrapper did not execute glibc bash"
run_version=$(HOME="${TEST_TMP_DIR}/home" \
    "$GLIBCX_UNDER_TEST" run "$first_target" -- --version | sed -n '1p')
[[ "$run_version" == *"GNU bash"* ]] || fail "glibcx run did not use the registered wrapper"
[[ "$(sha256sum "$first_target" | awk '{print $1}')" == "$first_hash" ]] \
    || fail "patching modified the target"
pass "same-basename wrappers execute without modifying targets"

first_app_root="${TEST_TMP_DIR}/home/.glibcx/apps/${first_id}"
first_generation_hash=$(sha256sum "${first_app_root}/generations/1/manifest.json" | awk '{print $1}')
HOME="${TEST_TMP_DIR}/home" "$GLIBCX_UNDER_TEST" patch "$first_target" --runtime system \
    >"${TEST_TMP_DIR}/repatch.out"
[[ "$(readlink "${first_app_root}/current")" == generations/2 \
    && -f "${first_app_root}/generations/2/manifest.json" ]] \
    || fail "repatch did not atomically activate generation 2"
[[ "$(sha256sum "${first_app_root}/generations/1/manifest.json" | awk '{print $1}')" \
    == "$first_generation_hash" ]] || fail "repatch changed the previous generation"
pass "atomic generation switch preserves rollback state"
HOME="${TEST_TMP_DIR}/home" "$GLIBCX_UNDER_TEST" rollback "$first_target" \
    >"${TEST_TMP_DIR}/rollback.out"
[[ "$(readlink "${first_app_root}/current")" == generations/1 \
    && -f "${first_app_root}/generations/2/manifest.json" ]] \
    || fail "rollback did not reactivate generation 1 or removed generation 2"
HOME="${TEST_TMP_DIR}/home" "$GLIBCX_UNDER_TEST" rollback "$first_target" 2 \
    >"${TEST_TMP_DIR}/rollforward.out"
[[ "$(readlink "${first_app_root}/current")" == generations/2 ]] \
    || fail "explicit generation activation failed"
pass "retained generations support atomic rollback"

environment_output=$(HOME="${TEST_TMP_DIR}/home" \
    LD_PRELOAD="${PREFIX}/lib/libtermux-exec-ld-preload.so" \
    LD_LIBRARY_PATH="${PREFIX}/lib" \
    LD_AUDIT=/does/not/exist.so \
    LD_DEBUG=all \
    LD_PROFILE=bad \
    GLIBC_TUNABLES=glibc.malloc.check=3 \
    GLIBCX_APP_ID=caller-controlled \
    "${TEST_TMP_DIR}/home/.glibcx/bin/${first_id}" -c \
    'printf "%s|%s|%s|%s|%s|%s" "${LD_PRELOAD-unset}" "${LD_LIBRARY_PATH-unset}" "${LD_AUDIT-unset}" "${LD_DEBUG-unset}" "${GLIBC_TUNABLES-unset}" "$GLIBCX_APP_ID"')
[[ "$environment_output" == "unset|unset|unset|unset|glibc.malloc.check=0|${first_id}" ]] \
    || fail "wrapper environment isolation failed: $environment_output"
run_environment_output=$(HOME="${TEST_TMP_DIR}/home" \
    LD_PRELOAD="${PREFIX}/lib/libtermux-exec-ld-preload.so" \
    LD_LIBRARY_PATH="${PREFIX}/lib" \
    "$GLIBCX_UNDER_TEST" run "$first_target" -- -c \
    'printf "%s|%s" "${LD_PRELOAD-unset}" "${LD_LIBRARY_PATH-unset}"')
[[ "$run_environment_output" == "unset|unset" ]] \
    || fail "glibcx run environment isolation failed: $run_environment_output"
first_manifest=$(jq -r --arg path "$first_target" '.apps[$path].manifest' "$registry")
jq -e '.wrapper.tunables == ["glibc.malloc.check=0"]' "$first_manifest" >/dev/null \
    || fail "profile tunable allowlist was not recorded in the app manifest"
pass "wrapper environment isolation"

registry_before=$(sha256sum "$registry" | awk '{print $1}')
HOME="${TEST_TMP_DIR}/home" "$GLIBCX_UNDER_TEST" doctor "$second_target" \
    >"${TEST_TMP_DIR}/doctor.out"
registry_after=$(sha256sum "$registry" | awk '{print $1}')
grep -q "Registry      : registered as $second_id" "${TEST_TMP_DIR}/doctor.out" \
    || fail "doctor did not report the registered app"
grep -q -- '--verify      : pass' "${TEST_TMP_DIR}/doctor.out" \
    || fail "doctor loader verification did not pass"
[[ "$registry_before" == "$registry_after" ]] || fail "doctor mutated registry state"
pass "read-only doctor and loader verification"

manifest_before=$(sha256sum "$first_manifest" | awk '{print $1}')
HOME="${TEST_TMP_DIR}/home" "$GLIBCX_UNDER_TEST" trace-libs "$first_target" -- --version \
    >"${TEST_TMP_DIR}/trace.out" 2>"${TEST_TMP_DIR}/trace.err"
grep -q 'GNU bash' "${TEST_TMP_DIR}/trace.out" || fail "trace-libs did not execute the target"
find "${TEST_TMP_DIR}/home/.glibcx/logs" -name "trace-${first_id}-*.log" -type f \
    -exec grep -lE 'file=|find library=' {} + | grep -q . \
    || fail "trace-libs did not retain loader observations"
[[ "$manifest_before" == "$(sha256sum "$first_manifest" | awk '{print $1}')" ]] \
    || fail "trace-libs changed the reproducible app lock"
pass "controlled trace-libs observations leave the lock unchanged"

HOME="${TEST_TMP_DIR}/home" "$GLIBCX_UNDER_TEST" restore "$first_target"
[[ -L "${TEST_TMP_DIR}/home/.glibcx/bin/bash" ]] \
    || fail "unique short alias was not restored"
remaining_version=$(HOME="${TEST_TMP_DIR}/home" \
    "${TEST_TMP_DIR}/home/.glibcx/bin/bash" --version | sed -n '1p')
[[ "$remaining_version" == *"GNU bash"* ]] || fail "restored short alias did not execute"
pass "restore repairs short aliases"

printf '\nTermux schema-3 smoke test passed.\n'
