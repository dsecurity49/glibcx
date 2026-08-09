#!/usr/bin/env bash
# Sanitized dynamic-loader verification tests.
set -euo pipefail

pass() { printf '  PASS %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*" >&2; exit 1; }

command -v patchelf >/dev/null 2>&1 || {
    echo "SKIP: patchelf is unavailable."
    exit 0
}

TEST_TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "${TEST_TMP_DIR:?}"; }
trap cleanup EXIT

# shellcheck source=../src/common.sh
source src/common.sh
# shellcheck source=../src/elf.sh
source src/elf.sh
# shellcheck source=../src/wrapper.sh
source src/wrapper.sh
# shellcheck source=../src/resolver.sh
source src/resolver.sh

TMP_DIR="${TEST_TMP_DIR}/state-tmp"
mkdir -p "$TMP_DIR"

if [[ -x "${PREFIX:-/nonexistent}/glibc/lib/ld-linux-aarch64.so.1" ]]; then
    loader="${PREFIX}/glibc/lib/ld-linux-aarch64.so.1"
    library_dir="${PREFIX}/glibc/lib"
    target="${PREFIX}/glibc/bin/bash"
else
    loader=$(find /lib /usr/lib -name ld-linux-aarch64.so.1 -type f -print -quit 2>/dev/null)
    library_dir=$(dirname "$loader")
    target="/bin/bash"
fi
[[ -x "$loader" && -x "$target" ]] || fail "AArch64 loader fixture is unavailable"

profile=$(jq -n --arg loader "$loader" --arg lib "$library_dir" '{
    profile_id: "fixture", kind: "system", loader: $loader, library_dirs: [$lib]
}')
mkdir -p "${TEST_TMP_DIR}/app/lib" "${TEST_TMP_DIR}/final/lib"
inspection=$(elf_inspect "$target")
verified=$(loader_verify_target "$profile" "${TEST_TMP_DIR}/app/lib" \
    "${TEST_TMP_DIR}/final/lib" "$target" "$inspection")
jq -e '
    .verified == true
    and .verify.exit_code == 0
    and .list.exit_code == 0
    and .unexpected_resolutions == []
    and (.list_sha256 | test("^[0-9a-f]{64}$"))
' <<<"$verified" >/dev/null || fail "valid startup closure did not verify"
pass "sanitized loader verification"

dependencies=$(resolver_manifest_dependencies "$verified" "$profile" \
    "${TEST_TMP_DIR}/app/lib" "${TEST_TMP_DIR}/final/lib")
jq -e '
    length > 0
    and any(.[]; .soname == "libc.so.6" and (.sha256 | test("^[0-9a-f]{64}$")))
    and all(.[]; .status == "resolved" and (.needed | type) == "array")
' <<<"$dependencies" >/dev/null || fail "dependency lock is incomplete"
pass "direct/transitive dependency lock"

broken_target="${TEST_TMP_DIR}/broken-target"
cp "$target" "$broken_target"
patchelf --add-needed libglibcx-definitely-missing.so.0 "$broken_target"
broken_inspection=$(elf_inspect "$broken_target")
broken_result=$(loader_verify_target "$profile" "${TEST_TMP_DIR}/app/lib" \
    "${TEST_TMP_DIR}/final/lib" "$broken_target" "$broken_inspection")
jq -e '.verified == false and .list.exit_code != 0' <<<"$broken_result" >/dev/null \
    || fail "missing startup dependency did not fail verification"
pass "missing dependency rejection"

printf '\nAll loader verification tests passed.\n'
