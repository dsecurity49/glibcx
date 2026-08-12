#!/usr/bin/env bash
# Authoritative readelf-based inspection tests.
set -euo pipefail

pass() { printf '  PASS %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*" >&2; exit 1; }

# shellcheck source=../src/common.sh
source src/common.sh
# shellcheck source=../src/elf.sh
source src/elf.sh

if [[ -x "${PREFIX:-/nonexistent}/glibc/bin/bash" ]]; then
    glibc_target="${PREFIX}/glibc/bin/bash"
else
    glibc_target="/bin/bash"
fi

inspection=$(elf_inspect "$glibc_target")
jq -e '
    .valid == true
    and .header.class == "ELF64"
    and .header.machine == "AArch64"
    and .program_headers.interpreter_count == 1
    and (.dynamic.needed | index("libc.so.6")) != null
' <<<"$inspection" >/dev/null || fail "valid AArch64 glibc target was rejected"
[[ "$(elf_max_glibc_requirement <<<"$inspection")" == GLIBC_* ]] \
    || fail "maximum GLIBC requirement was not extracted"
pass "AArch64 glibc target inspection"

if [[ -x "${PREFIX:-/nonexistent}/glibc/lib/ld-linux-aarch64.so.1" ]]; then
    no_interpreter_target="${PREFIX}/glibc/lib/ld-linux-aarch64.so.1"
else
    no_interpreter_target=$(find /lib /usr/lib -name ld-linux-aarch64.so.1 \
        -type f -print -quit 2>/dev/null)
fi
[[ -n "$no_interpreter_target" && -f "$no_interpreter_target" ]] \
    || fail "no PT_INTERP fixture is unavailable"
no_interpreter_inspection=$(elf_inspect "$no_interpreter_target")
jq -e '
    .valid == false
    and any(.errors[]; contains("exactly one PT_INTERP"))
' <<<"$no_interpreter_inspection" >/dev/null \
    || fail "target without a normal interpreter pipeline was accepted"
pass "no-PT_INTERP target rejection"

TEST_TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "${TEST_TMP_DIR:?}"; }
trap cleanup EXIT
printf 'not an elf\n' >"${TEST_TMP_DIR}/plain-file"
invalid_inspection=$(elf_inspect "${TEST_TMP_DIR}/plain-file")
jq -e '.valid == false and (.errors | index("not a readable ELF file")) != null' \
    <<<"$invalid_inspection" >/dev/null || fail "non-ELF input did not fail closed"
pass "non-ELF rejection"

pyinstaller_fixture="${TEST_TMP_DIR}/pyinstaller-fixture"
plain_fixture="${TEST_TMP_DIR}/plain-fixture"
cp "$glibc_target" "$pyinstaller_fixture"
cp "$glibc_target" "$plain_fixture"
printf 'MEI\014\013\012\013\016fixture-cookie' >>"$pyinstaller_fixture"
elf_has_pyinstaller_archive "$pyinstaller_fixture" \
    || fail "PyInstaller archive cookie was not detected"
if elf_has_pyinstaller_archive "$plain_fixture"; then
    fail "plain ELF was misidentified as a PyInstaller executable"
fi
pass "PyInstaller archive detection"

if command -v patchelf >/dev/null 2>&1; then
    runpath_target="${TEST_TMP_DIR}/runpath-target"
    rpath_target="${TEST_TMP_DIR}/rpath-target"
    cp "$glibc_target" "$runpath_target"
    cp "$glibc_target" "$rpath_target"
    patchelf --set-rpath '$ORIGIN/runpath-fixture' "$runpath_target"
    patchelf --force-rpath --set-rpath '$ORIGIN/rpath-fixture' "$rpath_target"
    runpath_inspection=$(elf_inspect "$runpath_target")
    rpath_inspection=$(elf_inspect "$rpath_target")
    jq -e '
        (.dynamic.runpath | index("$ORIGIN/runpath-fixture")) != null
        and (.dynamic.rpath | length) == 0
    ' <<<"$runpath_inspection" >/dev/null || fail "DT_RUNPATH was not distinguished"
    jq -e '
        (.dynamic.rpath | index("$ORIGIN/rpath-fixture")) != null
        and (.dynamic.runpath | length) == 0
    ' <<<"$rpath_inspection" >/dev/null || fail "legacy DT_RPATH was not distinguished"
    pass "RPATH and RUNPATH distinction"

    for unsafe_rpath in 'libs' ':$ORIGIN' '$ORIGIN:' '$ORIGIN/../escape'; do
        unsafe_target="${TEST_TMP_DIR}/unsafe-rpath-$(_sha256_text "$unsafe_rpath")"
        cp "$glibc_target" "$unsafe_target"
        patchelf --set-rpath "$unsafe_rpath" "$unsafe_target"
        unsafe_inspection=$(elf_inspect "$unsafe_target")
        jq -e '.valid == false
            and any(.errors[];
                contains("RPATH/RUNPATH") or contains("ORIGIN RPATH/RUNPATH escapes"))' \
            <<<"$unsafe_inspection" >/dev/null \
            || fail "unsafe RPATH/RUNPATH was accepted: $unsafe_rpath"
    done
    pass "CWD-dependent and escaping search-path rejection"

    path_needed_target="${TEST_TMP_DIR}/path-needed-target"
    cp "$glibc_target" "$path_needed_target"
    patchelf --add-needed '../libglibcx-escape.so' "$path_needed_target"
    path_needed_inspection=$(elf_inspect "$path_needed_target")
    jq -e '.valid == false
        and any(.errors[]; contains("DT_NEEDED entry contains a path"))' \
        <<<"$path_needed_inspection" >/dev/null \
        || fail "path-bearing DT_NEEDED entry was accepted"
    pass "path-bearing DT_NEEDED rejection"
else
    echo "  SKIP RPATH/RUNPATH fixture (patchelf unavailable)"
fi

native_bash=$(command -v bash)
native_inspection=$(elf_inspect "$native_bash")
native_interpreter=$(jq -r '.program_headers.interpreter // empty' <<<"$native_inspection")
if [[ "$(basename "$native_interpreter")" == "linker64" ]]; then
    jq -e '
        .valid == false
        and any(.errors[]; contains("unsupported dynamic interpreter"))
    ' <<<"$native_inspection" >/dev/null || fail "Bionic interpreter was not rejected"
    pass "Bionic target rejection"
else
    echo "  SKIP Bionic target fixture is unavailable on this host"
fi

printf '\nAll ELF inspection tests passed.\n'
