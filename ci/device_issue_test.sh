#!/usr/bin/env bash
# Fixture tests for untrusted device-report archive validation.
set -euo pipefail

TEST_TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "${TEST_TMP_DIR:?}"; }
trap cleanup EXIT

pass() { printf '  PASS %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*" >&2; exit 1; }

fixture="${TEST_TMP_DIR}/fixture"
mkdir -p "${fixture}/logs"
cp docs/device-results/android14-xiaomi-22101316i-4k-df9b687.json "${fixture}/report.json"
jq '.issue_url = null' "${fixture}/report.json" >"${fixture}/report.tmp"
mv "${fixture}/report.tmp" "${fixture}/report.json"
for log_name in build integration proc_exe repository state; do
    printf 'fixture log for %s\n' "$log_name" >"${fixture}/logs/${log_name}.log"
done
tar -czf "${TEST_TMP_DIR}/valid.tar.gz" -C "$fixture" report.json logs
bash ci/validate-device-archive.sh "${TEST_TMP_DIR}/valid.tar.gz" "${TEST_TMP_DIR}/valid-output"
jq -e '.device.sdk == 34' "${TEST_TMP_DIR}/valid-output/report.json" >/dev/null
pass "valid upload"

cp "${TEST_TMP_DIR}/valid.tar.gz" "${TEST_TMP_DIR}/extra.tar.gz"
printf 'unexpected\n' >"${fixture}/extra"
tar -czf "${TEST_TMP_DIR}/extra.tar.gz" -C "$fixture" report.json logs extra
if bash ci/validate-device-archive.sh \
    "${TEST_TMP_DIR}/extra.tar.gz" "${TEST_TMP_DIR}/extra-output" >/dev/null 2>&1; then
    fail "extra archive member accepted"
fi
pass "extra archive member rejection"

rm "${fixture}/extra"
tar -cf "${TEST_TMP_DIR}/trailing.tar" -C "$fixture" report.json logs
printf 'hidden trailing payload\n' >>"${TEST_TMP_DIR}/trailing.tar"
gzip "${TEST_TMP_DIR}/trailing.tar"
if bash ci/validate-device-archive.sh \
    "${TEST_TMP_DIR}/trailing.tar.gz" "${TEST_TMP_DIR}/trailing-output" >/dev/null 2>&1; then
    fail "payload after the tar end marker accepted"
fi
pass "trailing payload rejection"

rm "${fixture}/logs/build.log"
ln -s /etc/passwd "${fixture}/logs/build.log"
tar -czf "${TEST_TMP_DIR}/symlink.tar.gz" -C "$fixture" report.json logs
if bash ci/validate-device-archive.sh \
    "${TEST_TMP_DIR}/symlink.tar.gz" "${TEST_TMP_DIR}/symlink-output" >/dev/null 2>&1; then
    fail "symlink archive member accepted"
fi
pass "symlink member rejection"

rm "${fixture}/logs/build.log"
printf 'fixture log\n' >"${fixture}/logs/build.log"
truncate -s 11M "${fixture}/logs/state.log"
tar -czf "${TEST_TMP_DIR}/expansion.tar.gz" -C "$fixture" report.json logs
if bash ci/validate-device-archive.sh \
    "${TEST_TMP_DIR}/expansion.tar.gz" "${TEST_TMP_DIR}/expansion-output" >/dev/null 2>&1; then
    fail "excessively expanding archive accepted"
fi
pass "decompression-bomb rejection"

truncate -s 5M "${fixture}/logs/state.log"
tar --sparse -czf "${TEST_TMP_DIR}/sparse.tar.gz" -C "$fixture" report.json logs
if bash ci/validate-device-archive.sh \
    "${TEST_TMP_DIR}/sparse.tar.gz" "${TEST_TMP_DIR}/sparse-output" >/dev/null 2>&1; then
    fail "oversized sparse archive member accepted"
fi
pass "sparse size-bomb rejection"

printf 'fixture log for state\n' >"${fixture}/logs/state.log"
printf 'bad\001control\n' >"${fixture}/logs/build.log"
tar -czf "${TEST_TMP_DIR}/control.tar.gz" -C "$fixture" report.json logs
if bash ci/validate-device-archive.sh \
    "${TEST_TMP_DIR}/control.tar.gz" "${TEST_TMP_DIR}/control-output" >/dev/null 2>&1; then
    fail "control characters in log accepted"
fi
pass "control-character rejection"

printf '/data/data/com.termux/files/home/private\n' >"${fixture}/logs/build.log"
tar -czf "${TEST_TMP_DIR}/private.tar.gz" -C "$fixture" report.json logs
if bash ci/validate-device-archive.sh \
    "${TEST_TMP_DIR}/private.tar.gz" "${TEST_TMP_DIR}/private-output" >/dev/null 2>&1; then
    fail "private report data accepted"
fi
pass "private data rejection"

printf 'fixture log\n' >"${fixture}/logs/build.log"
jq '.device.model = "model`|injection"' \
    "${fixture}/report.json" >"${fixture}/report.tmp"
mv "${fixture}/report.tmp" "${fixture}/report.json"
tar -czf "${TEST_TMP_DIR}/markup.tar.gz" -C "$fixture" report.json logs
if bash ci/validate-device-archive.sh \
    "${TEST_TMP_DIR}/markup.tar.gz" "${TEST_TMP_DIR}/markup-output" >/dev/null 2>&1; then
    fail "markup-bearing report field accepted"
fi
pass "issue-markup rejection"

jq '.device.model = "22101316I"' \
    "${fixture}/report.json" >"${fixture}/report.tmp"
mv "${fixture}/report.tmp" "${fixture}/report.json"
jq '.overall = "fail" | .tests[0].status = "fail" | .tests[0].exit_code = 1' \
    "${fixture}/report.json" >"${fixture}/report.tmp"
mv "${fixture}/report.tmp" "${fixture}/report.json"
tar -czf "${TEST_TMP_DIR}/test-failure.tar.gz" -C "$fixture" report.json logs
bash ci/validate-device-archive.sh \
    "${TEST_TMP_DIR}/test-failure.tar.gz" "${TEST_TMP_DIR}/test-failure-output"
jq -e '.overall == "fail"' "${TEST_TMP_DIR}/test-failure-output/report.json" >/dev/null
pass "well-formed failing test accepted"

jq '.tests[0].status = "fail" | .tests[0].exit_code = 0' \
    "${fixture}/report.json" >"${fixture}/report.tmp"
mv "${fixture}/report.tmp" "${fixture}/report.json"
tar -czf "${TEST_TMP_DIR}/inconsistent.tar.gz" -C "$fixture" report.json logs
if bash ci/validate-device-archive.sh \
    "${TEST_TMP_DIR}/inconsistent.tar.gz" "${TEST_TMP_DIR}/inconsistent-output" >/dev/null 2>&1; then
    fail "inconsistent test result accepted"
fi
pass "inconsistent result rejection"

printf '\nAll device issue tests passed.\n'
