#!/usr/bin/env bash
# Build the AArch64 glibc DSO used by proc-exe compatibility mode.
set -euo pipefail

[[ $# -eq 3 ]] || {
    echo "Usage: profiles/build-proc-exe-shim.sh <glibc-sysroot> <source.c> <output.so>" >&2
    exit 1
}

sysroot="$1"
source_file="$2"
output_file="$3"

[[ -f "${sysroot}/include/stdio.h" || -f "${sysroot}/usr/include/stdio.h" ]] || {
    echo "[proc-shim] Error: incomplete glibc sysroot (missing stdio.h)." >&2
    exit 1
}
libc_path=""
for library_root in "${sysroot}/lib" "${sysroot}/usr/lib"; do
    [[ -d "$library_root" ]] || continue
    libc_path=$(find -L "$library_root" -name libc.so.6 -type f -print 2>/dev/null \
        | LC_ALL=C sed -n '1p')
    [[ -n "$libc_path" ]] && break
done
[[ -n "$libc_path" ]] || {
    echo "[proc-shim] Error: incomplete glibc sysroot (missing libc.so.6)." >&2
    exit 1
}
[[ -f "$source_file" ]] \
    || { echo "[proc-shim] Error: source file is missing." >&2; exit 1; }
command -v clang >/dev/null 2>&1 \
    || { echo "[proc-shim] Error: clang is missing from the builder." >&2; exit 1; }

clang --target=aarch64-linux-gnu --sysroot="$sysroot" \
    -shared -fPIC -nostdlib -O2 -Wall -Wextra -Werror \
    "$source_file" -L"${sysroot}/lib" \
    -Wl,-soname,glibcx-proc-exe-shim.so -lc -o "$output_file"

LC_ALL=C readelf -W -h "$output_file" | awk -F: '
    /Class:/{if ($2 !~ /ELF64/) bad=1}
    /Machine:/{if ($2 !~ /AArch64/) bad=1; found=1}
    END {exit bad || !found}'
LC_ALL=C readelf -W -d "$output_file" | grep -q 'libc[.]so[.]6'
