#!/usr/bin/env bash
# Provider asset downloads must recover from transient transport failures.
set -euo pipefail

TEST_TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "${TEST_TMP_DIR:?}"; }
trap cleanup EXIT

pass() { printf '  PASS %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*" >&2; exit 1; }

ARGS_FILE="${TEST_TMP_DIR}/curl-args"
curl() { printf '%s\n' "$@" >"$ARGS_FILE"; }

# shellcheck source=../src/providers/fetch.sh
source src/providers/fetch.sh

_fetch_download \
    https://example.invalid/tool.tar.gz "${TEST_TMP_DIR}/tool.tar.gz"

for expected in \
    --retry 5 \
    --retry-all-errors \
    --retry-delay 2 \
    --retry-max-time 120; do
    grep -Fxq -- "$expected" "$ARGS_FILE" \
        || fail "curl asset download omitted '$expected'"
done

pass "provider asset download retries transient failures"
printf '\nAll provider download tests passed.\n'
