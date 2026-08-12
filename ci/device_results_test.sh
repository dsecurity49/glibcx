#!/usr/bin/env bash
# Schema and privacy checks for accepted community device reports.
set -euo pipefail

pass() { printf '  PASS %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*" >&2; exit 1; }

TEST_TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "${TEST_TMP_DIR:?}"; }
trap cleanup EXIT

valid_dir="${TEST_TMP_DIR}/valid"
invalid_dir="${TEST_TMP_DIR}/invalid"
mkdir -p "$valid_dir" "$invalid_dir"

jq -n '
    {
        schema: 1,
        tested_at: "2026-08-09T16:00:00Z",
        overall: "pass",
        source: {
            commit: "0123456789abcdef0123456789abcdef01234567",
            tracked_changes: false
        },
        device: {
            android_release: "16",
            sdk: 36,
            manufacturer: "vivo",
            model: "V2541",
            abi: "arm64-v8a",
            kernel_release: "5.15.197-android13-8",
            page_size: 4096,
            selinux: "enforcing"
        },
        termux: {
            apk_release: "F_DROID",
            version: "0.119.0-beta.3",
            target_sdk: 28,
            termux_tools_version: "1.45.0",
            glibc_runner_version: "2.0-3",
            ld_preload_name: "libtermux-exec-ld-preload.so"
        },
        tests: [
            {id: "build", description: "source build", status: "pass", exit_code: 0, log: "logs/build.log"},
            {id: "state", description: "atomic state and wrapper", status: "pass", exit_code: 0, log: "logs/state.log"},
            {id: "integration", description: "AArch64 integration", status: "pass", exit_code: 0, log: "logs/integration.log"},
            {id: "proc_exe", description: "proc-exe compatibility", status: "pass", exit_code: 0, log: "logs/proc_exe.log"},
            {id: "repository", description: "live repository contract", status: "pass", exit_code: 0, log: "logs/repository.log"}
        ],
        issue_url: "https://github.com/dsecurity49/glibcx/issues/12"
    }
' >"${valid_dir}/android-36-vivo-v2541-4k.json"

bash ci/validate-device-results.sh "$valid_dir" >/dev/null \
    || fail "valid device report was rejected"
pass "valid report"

jq '.device.model = "/data/data/com.termux/private"' \
    "${valid_dir}/android-36-vivo-v2541-4k.json" \
    >"${invalid_dir}/private-path.json"
if bash ci/validate-device-results.sh "$invalid_dir" >/dev/null 2>&1; then
    fail "private runtime path was accepted"
fi
pass "private runtime path rejection"

jq '.tests[0].status = "fail" | .tests[0].exit_code = 1' \
    "${valid_dir}/android-36-vivo-v2541-4k.json" \
    >"${invalid_dir}/inconsistent-status.json"
rm -f "${invalid_dir}/private-path.json"
if bash ci/validate-device-results.sh "$invalid_dir" >/dev/null 2>&1; then
    fail "inconsistent overall status was accepted"
fi
pass "inconsistent result rejection"

jq '.tests[0].exit_code = 1' \
    "${valid_dir}/android-36-vivo-v2541-4k.json" \
    >"${invalid_dir}/pass-with-error.json"
rm -f "${invalid_dir}/inconsistent-status.json"
if bash ci/validate-device-results.sh "$invalid_dir" >/dev/null 2>&1; then
    fail "passing status with non-zero exit code was accepted"
fi

jq '.tests[0].status = "fail"' \
    "${valid_dir}/android-36-vivo-v2541-4k.json" \
    >"${invalid_dir}/fail-with-success.json"
rm -f "${invalid_dir}/pass-with-error.json"
if bash ci/validate-device-results.sh "$invalid_dir" >/dev/null 2>&1; then
    fail "failing status with zero exit code was accepted"
fi
pass "status and exit-code consistency rejection"

printf '\nAll device-result tests passed.\n'
