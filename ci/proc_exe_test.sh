#!/usr/bin/env bash
# glibc proc-exe shim interface and self-reexec fixture.
set -euo pipefail

pass() { printf '  PASS %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*" >&2; exit 1; }

TEST_TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "${TEST_TMP_DIR:?}"; }
trap cleanup EXIT

loader_dirs=(/lib /usr/lib)
if [[ -n "${PREFIX:-}" && -d "${PREFIX}/glibc/lib" ]]; then
    loader_dirs=("${PREFIX}/glibc/lib" "${loader_dirs[@]}")
fi
loader=$(find "${loader_dirs[@]}" -name ld-linux-aarch64.so.1 -type f -print -quit 2>/dev/null)
[[ -n "$loader" ]] || fail "AArch64 glibc loader was not found"

if [[ "$(uname -o 2>/dev/null || true)" == Android ]]; then
    glibc_sysroot="${PREFIX:-/data/data/com.termux/files/usr}/glibc"
    [[ -f "${glibc_sysroot}/lib/Scrt1.o" && -f "${glibc_sysroot}/include/stdio.h" ]] \
        || fail "installed glibc development sysroot is incomplete"
    glibc_libc=$(find -H "${glibc_sysroot}/lib" "${glibc_sysroot}/usr/lib" \
        -name libc.so.6 -type f -print -quit 2>/dev/null) || true
    [[ -n "$glibc_libc" ]] || fail "installed glibc development sysroot is missing libc.so.6"
else
    glibc_sysroot=/
fi
bash profiles/build-proc-exe-shim.sh "$glibc_sysroot" \
    profiles/proc-exe-shim.c "${TEST_TMP_DIR}/proc-exe-shim.so"

cat >"${TEST_TMP_DIR}/fixture.c" <<'C_CODE'
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

extern char **environ;

int main(int argc, char **argv) {
    const char *target = getenv("GLIBCX_REAL_EXE");
    char link_value[4096];
    struct stat opened_stat, target_stat;
    ssize_t length;
    int descriptor;
    if (argc > 1 && strcmp(argv[1], "child") == 0) {
        puts("child-ok");
        return 0;
    }
    if (target == NULL) return 10;
    length = readlink("/proc/self/exe", link_value, sizeof(link_value) - 1);
    if (length < 0) return 11;
    link_value[length] = '\0';
    if (strcmp(link_value, target) != 0) return 12;
    length = readlinkat(AT_FDCWD, "/proc/self/exe", link_value, sizeof(link_value) - 1);
    if (length < 0) return 17;
    link_value[length] = '\0';
    if (strcmp(link_value, target) != 0) return 18;
    errno = 0;
    if (readlink("/proc/self/exe", link_value, 0) != -1 || errno != EINVAL) return 19;
    descriptor = open("/proc/self/exe", O_RDONLY);
    if (descriptor < 0) return 13;
    if (fstat(descriptor, &opened_stat) != 0 || stat(target, &target_stat) != 0) return 14;
    close(descriptor);
    if (opened_stat.st_dev != target_stat.st_dev || opened_stat.st_ino != target_stat.st_ino) return 15;
    descriptor = openat(AT_FDCWD, "/proc/self/exe", O_RDONLY);
    if (descriptor < 0 || fstat(descriptor, &opened_stat) != 0) return 20;
    close(descriptor);
    if (opened_stat.st_dev != target_stat.st_dev || opened_stat.st_ino != target_stat.st_ino) return 21;
    descriptor = open64("/proc/self/exe", O_RDONLY);
    if (descriptor < 0 || fstat(descriptor, &opened_stat) != 0) return 22;
    close(descriptor);
    if (opened_stat.st_dev != target_stat.st_dev || opened_stat.st_ino != target_stat.st_ino) return 23;
    {
        char *child_argv[] = {argv[0], (char *)"child", NULL};
        execve("/proc/self/exe", child_argv, environ);
    }
    perror("execve");
    return errno == 0 ? 16 : errno;
}
C_CODE
if [[ "$(uname -o 2>/dev/null || true)" == Android ]]; then
    clang --target=aarch64-linux-gnu --sysroot="$glibc_sysroot" \
        -nostdlib -fPIE -pie -O2 -Wall -Wextra -Werror \
        "${glibc_sysroot}/lib/Scrt1.o" "${glibc_sysroot}/lib/crti.o" \
        "${TEST_TMP_DIR}/fixture.c" "$glibc_libc" \
        "${glibc_sysroot}/lib/crtn.o" \
        -Wl,--dynamic-linker,"$loader" -o "${TEST_TMP_DIR}/fixture"
else
    clang -O2 -Wall -Wextra -Werror \
        "${TEST_TMP_DIR}/fixture.c" -o "${TEST_TMP_DIR}/fixture"
fi

host_bash=$(command -v bash)
cat >"${TEST_TMP_DIR}/wrapper" <<WRAPPER
#!${host_bash}
printf '%s\n' invoked >"${TEST_TMP_DIR}/wrapper-invoked"
exec env -u LD_PRELOAD "$loader" --preload "${TEST_TMP_DIR}/proc-exe-shim.so" \
    "${TEST_TMP_DIR}/fixture" "\$@"
WRAPPER
chmod 755 "${TEST_TMP_DIR}/wrapper"

output=$(env \
    -u LD_PRELOAD \
    -u LD_LIBRARY_PATH \
    -u GLIBC_LD_LIBRARY_PATH \
    GLIBCX_REAL_EXE="${TEST_TMP_DIR}/fixture" \
    GLIBCX_WRAPPER_EXE="${TEST_TMP_DIR}/wrapper" \
    GLIBCX_PROC_EXE_MODE=on \
    "$loader" --preload "${TEST_TMP_DIR}/proc-exe-shim.so" \
    "${TEST_TMP_DIR}/fixture")
[[ "$output" == child-ok ]] || fail "proc-exe self-reexec fixture returned '$output'"
[[ "$(cat "${TEST_TMP_DIR}/wrapper-invoked")" == invoked ]] \
    || fail "proc-exe self-reexec did not route through the wrapper"
pass "read/open target view and wrapper-routed self-reexec"

printf '\nAll proc-exe shim tests passed.\n'
