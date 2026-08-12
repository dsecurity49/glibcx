#!/usr/bin/env bash
# Verify that setup changes Android's phantom-process limit only after consent.
set -euo pipefail

TEST_TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "${TEST_TMP_DIR:?}"; }
trap cleanup EXIT

pass() { printf '  PASS %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*" >&2; exit 1; }

mock_bin="${TEST_TMP_DIR}/bin"
harness="${TEST_TMP_DIR}/harness.sh"
record="${TEST_TMP_DIR}/rish-record"
mkdir -p "$mock_bin"

cat >"${mock_bin}/getprop" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_SDK:-}"
MOCK
chmod +x "${mock_bin}/getprop"

cat >"$harness" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$PWD/src/setup.sh"
_setup_offer_phantom_process_limit
EOF
chmod +x "$harness"

output=$(PATH="$mock_bin:$PATH" MOCK_SDK=36 bash "$harness")
[[ -z "$output" ]] || fail "missing rish produced setup output"
pass "missing rish is skipped silently"

cat >"${mock_bin}/rish" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$RISH_RECORD"
MOCK
chmod +x "${mock_bin}/rish"

output=$(PATH="$mock_bin:$PATH" MOCK_SDK=36 RISH_RECORD="$record" bash "$harness")
[[ -z "$output" && ! -e "$record" ]] \
    || fail "non-interactive setup offered or changed the Android setting"
pass "non-interactive setup is skipped silently"

PATH="$mock_bin:$PATH" MOCK_SDK=30 RISH_RECORD="$record" \
    script -qefc "bash '$harness'" /dev/null </dev/null >"${TEST_TMP_DIR}/api30-output"
[[ ! -e "$record" && ! -s "${TEST_TMP_DIR}/api30-output" ]] \
    || fail "pre-Android-12 setup offered or changed the setting"
pass "Android below API 31 is skipped silently"

printf 'n\n' | PATH="$mock_bin:$PATH" MOCK_SDK=36 RISH_RECORD="$record" \
    script -qefc "bash '$harness'" /dev/null >"${TEST_TMP_DIR}/decline-output"
[[ ! -e "$record" ]] || fail "declining the prompt changed the Android setting"
grep -Fq 'Raise the phantom-process limit? [y/N]' "${TEST_TMP_DIR}/decline-output" \
    || fail "interactive consent prompt was not shown"
pass "default-No prompt respects refusal"

printf 'yes\n' | PATH="$mock_bin:$PATH" MOCK_SDK=36 RISH_RECORD="$record" \
    script -qefc "bash '$harness'" /dev/null >"${TEST_TMP_DIR}/accept-output"
grep -Fqx -- '-c device_config put activity_manager max_phantom_processes 2147483647' "$record" \
    || fail "consent did not run the exact intended rish command"
grep -Fq 'device_config delete activity_manager max_phantom_processes' \
    "${TEST_TMP_DIR}/accept-output" || fail "restore command was not shown"
pass "explicit consent raises the limit and prints the restore command"

printf '\nAll setup consent tests passed.\n'
