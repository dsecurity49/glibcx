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

for required_path in include/stdio.h lib/libc.so.6; do
    [[ -f "${sysroot}/${required_path}" ]] || {
        echo "[proc-shim] Error: incomplete glibc sysroot (missing $required_path)." >&2
        exit 1
    }
done
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
