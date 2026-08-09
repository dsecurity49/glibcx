#!/usr/bin/env bash
# Provider argument parsing must reject unknown input before touching user state
# or performing network/install actions.
set -euo pipefail

TEST_TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "${TEST_TMP_DIR:?}"; }
trap cleanup EXIT

pass() { printf '  PASS %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*" >&2; exit 1; }

assert_rejected_without_state() {
    local label="$1" expected="$2"
    shift 2
    local test_home="${TEST_TMP_DIR}/${label}" output="${TEST_TMP_DIR}/${label}.out"

    if HOME="$test_home" "$@" >"$output" 2>&1; then
        fail "$label accepted an unknown option"
    fi
    grep -Fq "$expected" "$output" || fail "$label returned the wrong diagnostic"
    [[ ! -e "${test_home}/.glibcx" ]] || fail "$label initialized state before rejecting input"
    pass "$label rejects unknown options without side effects"
}

assert_rejected_without_state gh "unknown gh option" \
    ./glibcx gh install owner/repo --unknown
assert_rejected_without_state npm "unknown npm option" \
    ./glibcx npm install package --unknown
assert_rejected_without_state fetch "unknown fetch option" \
    ./glibcx fetch https://example.invalid/tool --unknown
assert_rejected_without_state intercept "unknown intercept option" \
    ./glibcx intercept true --unknown

printf '\nAll provider argument tests passed.\n'
