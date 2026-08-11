#!/usr/bin/env bash
# Reproducible managed-runtime payload preparation and inventory tests.
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

TMP_DIR="${TEST_TMP_DIR}/tmp"
mkdir -p "$TMP_DIR"

if [[ -x "${PREFIX:-/nonexistent}/glibc/lib/ld-linux-aarch64.so.1" ]]; then
    source_loader="${PREFIX}/glibc/lib/ld-linux-aarch64.so.1"
    source_libc="${PREFIX}/glibc/lib/libc.so.6"
else
    source_loader=$(find /lib /usr/lib -name ld-linux-aarch64.so.1 -type f -print -quit 2>/dev/null)
    source_libc=$(find /lib /usr/lib -name libc.so.6 -type f -print -quit 2>/dev/null)
fi
[[ -n "$source_loader" && -n "$source_libc" ]] \
    || fail "AArch64 glibc fixture is unavailable"

if [[ -d "${PREFIX:-/nonexistent}/glibc/include" ]]; then
    shim_sysroot="${PREFIX}/glibc"
else
    shim_sysroot=/
fi
proc_shim="${TEST_TMP_DIR}/proc-exe-shim.so"
bash profiles/build-proc-exe-shim.sh \
    "$shim_sysroot" profiles/proc-exe-shim.c "$proc_shim" \
    || fail "proc-exe shim fixture build failed"
loader_audit="${TEST_TMP_DIR}/loader-audit.so"
bash profiles/build-loader-audit.sh \
    "$shim_sysroot" profiles/loader-audit.c "$loader_audit" \
    || fail "loader-audit fixture build failed"

prepared_tree="${TEST_TMP_DIR}/prepared"
mkdir -p "${prepared_tree}/lib" "${prepared_tree}/share/glibcx"
cp "$source_loader" "${prepared_tree}/lib/ld-linux-aarch64.so.1"
cp "$source_libc" "${prepared_tree}/lib/libc.so.6"
printf 'not shipped\n' >"${prepared_tree}/lib/libc.a"
printf '#!/bin/sh\nexit 0\n' >"${prepared_tree}/share/glibcx/helper"
chmod 755 "${prepared_tree}/share/glibcx/helper"
ln -s libc.so.6 "${prepared_tree}/lib/libc-fixture.so"

final_prefix="${TEST_TMP_DIR}/installed/builder-fixture"
build_payload() {
    local output_dir="$1" input_tree="${2:-$prepared_tree}"
    env \
        GLIBC_VERSION=2.42 \
        TERMUX_PACKAGE_REVISION=fixture-1 \
        TERMUX_GLIBC_COMMIT=0000000000000000000000000000000000000000 \
        BUILD_SOURCE_URL=https://example.invalid/glibc-2.42.tar.xz \
        BUILD_SOURCE_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
        CORRESPONDING_SOURCE_URL=https://example.invalid/glibc-2.42-source.tar.xz \
        TOOLCHAIN_DESCRIPTION=ubuntu-26.04-arm-clang \
        PROC_SHIM_BINARY="$proc_shim" \
        LOADER_AUDIT_BINARY="$loader_audit" \
        TERMUX_INSTALL_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}" \
        SOURCE_DATE_EPOCH=1767225600 \
        bash profiles/prepare-profile.sh \
            builder-fixture "$input_tree" "$final_prefix" "$output_dir" >/dev/null
}

build_payload "${TEST_TMP_DIR}/first" \
    || fail "first profile payload preparation failed"
build_payload "${TEST_TMP_DIR}/second" \
    || fail "second profile payload preparation failed"
first_payload="${TEST_TMP_DIR}/first/builder-fixture.payload"
second_payload="${TEST_TMP_DIR}/second/builder-fixture.payload"

cmp "${first_payload}/profile.json" "${second_payload}/profile.json" >/dev/null \
    || fail "identical inputs did not produce an identical profile manifest"
[[ ! -e "${first_payload}/lib/libc.a" ]] || fail "SDK archive leaked into runtime payload"
[[ "$(stat -c '%a' "${first_payload}/share/glibcx/helper")" == 755 ]] \
    || fail "executable payload mode was not preserved"
[[ -f "${first_payload}/lib/glibcx-proc-exe-shim.so" ]] \
    || fail "proc-exe shim was not included in the payload"
jq -e '.proc_exe_shim.path
        | endswith("/lib/glibcx-proc-exe-shim.so")' \
    "${first_payload}/profile.json" >/dev/null \
    || fail "proc-exe shim was not recorded in the profile"
[[ -f "${first_payload}/lib/glibcx-loader-audit.so" ]] \
    || fail "loader-audit module was not included in the payload"
jq -e '.compatibility_schema == 2
        and .loader_audit.protocol == 1
        and .loader_audit.fd == 198
        and (.loader_audit.path | endswith("/lib/glibcx-loader-audit.so"))' \
    "${first_payload}/profile.json" >/dev/null \
    || fail "loader-audit policy was not recorded in the profile"
pass "deterministic manifest and runtime-only payload"

_runtime_profile_manifest_validate \
    "${first_payload}/profile.json" builder-fixture "$final_prefix" \
    || fail "prepared profile failed schema validation"
checked=$(_runtime_inventory_verify "$first_payload" "${first_payload}/profile.json") \
    || fail "prepared profile inventory failed verification"
[[ "$checked" -ge 4 ]] || fail "prepared profile inventory was unexpectedly small"
pass "profile schema and complete inventory"

unsafe_tree="${TEST_TMP_DIR}/unsafe"
cp -a "$prepared_tree" "$unsafe_tree"
ln -s /etc/passwd "${unsafe_tree}/lib/escape.so"
if build_payload "${TEST_TMP_DIR}/unsafe-output" "$unsafe_tree" 2>/dev/null; then
    fail "absolute symlink target was accepted"
fi
pass "unsafe symlink rejection"

printf '\nAll profile builder tests passed.\n'
