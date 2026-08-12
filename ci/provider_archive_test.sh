#!/usr/bin/env bash
# Archive-member and extracted-tree safety checks shared by fetch/NPM providers.
set -euo pipefail

pass() { printf '  PASS %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*" >&2; exit 1; }

TEST_TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "${TEST_TMP_DIR:?}"; }
trap cleanup EXIT

# shellcheck source=../src/common.sh
source src/common.sh
# shellcheck source=../src/runtime.sh
source src/runtime.sh
# shellcheck source=../src/providers/fetch.sh
source src/providers/fetch.sh
TMP_DIR="${TEST_TMP_DIR}/tmp"
mkdir -p "$TMP_DIR"

safe_source="${TEST_TMP_DIR}/safe-source"
safe_extract="${TEST_TMP_DIR}/safe-extract"
mkdir -p "${safe_source}/bin" "$safe_extract"
printf 'fixture\n' >"${safe_source}/bin/tool"
ln -s tool "${safe_source}/bin/tool-link"
tar -czf "${TEST_TMP_DIR}/safe.tar.gz" -C "$safe_source" .
_fetch_archive_validate "${TEST_TMP_DIR}/safe.tar.gz" tar \
    || fail "safe provider archive was rejected"
tar -xzf "${TEST_TMP_DIR}/safe.tar.gz" -C "$safe_extract"
_fetch_tree_validate "$safe_extract" || fail "safe extracted tree was rejected"
pass "safe archive and relative symlink"

printf 'unsafe\n' >"${TEST_TMP_DIR}/unsafe-member"
tar -czf "${TEST_TMP_DIR}/traversal.tar.gz" -C "$TEST_TMP_DIR" \
    --transform='s|^unsafe-member$|../escape|' unsafe-member
if _fetch_archive_validate "${TEST_TMP_DIR}/traversal.tar.gz" tar >/dev/null 2>&1; then
    fail "provider archive traversal was accepted"
fi
pass "archive traversal rejection"

escaping_tree="${TEST_TMP_DIR}/escaping-tree"
mkdir -p "$escaping_tree"
ln -s ../../outside "$escaping_tree/escape"
if _fetch_tree_validate "$escaping_tree" >/dev/null 2>&1; then
    fail "escaping provider symlink was accepted"
fi
pass "extracted symlink escape rejection"

hardlink_source="${TEST_TMP_DIR}/hardlink-source"
mkdir -p "$hardlink_source"
printf 'same inode\n' >"${hardlink_source}/one"
if ln "${hardlink_source}/one" "${hardlink_source}/two" 2>/dev/null; then
    tar -czf "${TEST_TMP_DIR}/hardlink.tar.gz" -C "$hardlink_source" .
    if _fetch_archive_validate "${TEST_TMP_DIR}/hardlink.tar.gz" tar >/dev/null 2>&1; then
        fail "provider hard-link member was accepted"
    fi
    pass "hard-link member rejection"
else
    echo "  SKIP hard-link archive fixture (filesystem does not permit hard links)"
fi

newline_source="${TEST_TMP_DIR}/newline-source"
newline_extract="${TEST_TMP_DIR}/newline-extract"
mkdir -p "$newline_source" "$newline_extract"
printf 'unsafe\n' >"${newline_source}/line
break"
tar -czf "${TEST_TMP_DIR}/newline.tar.gz" -C "$newline_source" .
tar -xzf "${TEST_TMP_DIR}/newline.tar.gz" -C "$newline_extract"
if _fetch_tree_validate "$newline_extract" >/dev/null 2>&1; then
    fail "newline-containing extracted path was accepted"
fi
pass "control-character path rejection"

printf '\nAll provider archive tests passed.\n'
