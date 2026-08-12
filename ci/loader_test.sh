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
    audit_sysroot="${PREFIX}/glibc"
else
    loader=$(find /lib /usr/lib -name ld-linux-aarch64.so.1 -type f -print -quit 2>/dev/null)
    library_dir=$(dirname "$loader")
    target="/bin/bash"
    audit_sysroot=/
fi
[[ -x "$loader" && -x "$target" ]] || fail "AArch64 loader fixture is unavailable"

audit_module="${TEST_TMP_DIR}/loader-audit.so"
bash profiles/build-loader-audit.sh \
    "$audit_sysroot" profiles/loader-audit.c "$audit_module" \
    || fail "loader-audit fixture build failed"
profile=$(jq -n --arg loader "$loader" --arg lib "$library_dir" --arg audit "$audit_module" '{
    profile_id: "fixture", kind: "system", loader: $loader, library_dirs: [$lib],
    loader_audit: {path: $audit, protocol: 1, fd: 198},
    loader_policy: {glibc_hwcaps_mask: ""}
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
    and .audit.protocol == 1
    and .audit.complete == true
    and any(.audit.opened[]; .path | endswith("/libc.so.6"))
    and (.list_sha256 | test("^[0-9a-f]{64}$"))
' <<<"$verified" >/dev/null || fail "valid startup closure did not verify"
pass "sanitized loader verification"

incomplete_audit=$(jq '.audit.opened |= map(select(.path | endswith("/libc.so.6") | not))
    | .audit' <<<"$verified")
if _loader_audit_matches_list "$incomplete_audit" "$(jq -r '.list.output' <<<"$verified")"; then
    fail "truncated audit stream matched the complete loader listing"
fi
relative_list_line=$'libglibcx-relative.so => libs/libglibcx-relative.so (0x1)'
[[ "$(_loader_list_paths <<<"$relative_list_line")" == libs/libglibcx-relative.so ]] \
    || fail "relative loader result was silently skipped"
pass "audit completeness and relative-result enforcement"

order_root="${TEST_TMP_DIR}/order"
order_app_lib="${order_root}/app-lib"
order_rpath_lib="${order_root}/rpath-lib"
mkdir -p "$order_app_lib" "$order_rpath_lib"
cp "$library_dir/libc.so.6" "${order_app_lib}/libglibcx-order.so"
cp "$library_dir/libc.so.6" "${order_rpath_lib}/libglibcx-order.so"

rpath_target="${order_root}/rpath-target"
cp "$target" "$rpath_target"
patchelf --add-needed libglibcx-order.so "$rpath_target"
patchelf --force-rpath --set-rpath "$order_rpath_lib" "$rpath_target"
rpath_result=$(loader_verify_target "$profile" "$order_app_lib" "$order_app_lib" \
    "$rpath_target" "$(elf_inspect "$rpath_target")")
jq -e --arg expected "${order_rpath_lib}/libglibcx-order.so" '
    .verified == true and any(.audit.opened[]; .path == $expected)
' <<<"$rpath_result" >/dev/null || fail "legacy RPATH did not precede --library-path"

runpath_target="${order_root}/runpath-target"
cp "$target" "$runpath_target"
patchelf --add-needed libglibcx-order.so "$runpath_target"
patchelf --set-rpath "$order_rpath_lib" "$runpath_target"
runpath_result=$(loader_verify_target "$profile" "$order_app_lib" "$order_app_lib" \
    "$runpath_target" "$(elf_inspect "$runpath_target")")
jq -e --arg expected "${order_app_lib}/libglibcx-order.so" '
    .verified == true and any(.audit.opened[]; .path == $expected)
' <<<"$runpath_result" >/dev/null || fail "--library-path did not precede RUNPATH"
pass "real loader RPATH/RUNPATH precedence"

adjacent_target="${order_root}/adjacent-target"
cp "$target" "$adjacent_target"
patchelf --add-needed libglibcx-adjacent.so "$adjacent_target"
cp "$library_dir/libc.so.6" "${order_root}/libglibcx-adjacent.so"
adjacent_result=$(loader_verify_target "$profile" "${TEST_TMP_DIR}/app/lib" \
    "${TEST_TMP_DIR}/final/lib" "$adjacent_target" "$(elf_inspect "$adjacent_target")")
jq -e '.verified == false and (.list.output | contains("libglibcx-adjacent.so"))' \
    <<<"$adjacent_result" >/dev/null \
    || fail "undeclared executable-directory lookup was assumed"
pass "no implicit executable-directory search"

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
