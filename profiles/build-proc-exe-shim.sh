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

header_root=""
for include_root in "${sysroot}/include" "${sysroot}/usr/include"; do
    if [[ -f "${include_root}/stdio.h" ]]; then
        header_root="$include_root"
        break
    fi
done
[[ -n "$header_root" ]] || {
    echo "[proc-shim] Error: incomplete glibc sysroot (missing stdio.h)." >&2
    exit 1
}
libc_path=""
for library_root in "${sysroot}/lib" "${sysroot}/usr/lib"; do
    [[ -d "$library_root" ]] || continue
    libc_path=$(find -H "$library_root" -name libc.so.6 \
        \( -type f -o -type l \) -print -quit 2>/dev/null) || true
    [[ -n "$libc_path" ]] && break
done
[[ -n "$libc_path" ]] || {
    echo "[proc-shim] Error: incomplete glibc sysroot (missing libc.so.6)." >&2
    exit 1
}
[[ -f "$source_file" ]] \
    || { echo "[proc-shim] Error: source file is missing." >&2; exit 1; }
if command -v clang >/dev/null 2>&1; then
    compiler=(clang --target=aarch64-linux-gnu)
elif command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    compiler=(aarch64-linux-gnu-gcc)
elif [[ -x "${CGCT_DIR:-/data/data/com.termux/cgct}/aarch64/bin/aarch64-linux-gnu-gcc" ]]; then
    compiler=("${CGCT_DIR:-/data/data/com.termux/cgct}/aarch64/bin/aarch64-linux-gnu-gcc")
else
    echo "[proc-shim] Error: no AArch64 C compiler is available." >&2
    exit 1
fi

"${compiler[@]}" --sysroot="$sysroot" \
    -isystem "$header_root" \
    -shared -fPIC -nostdlib -O2 -Wall -Wextra -Werror \
    "$source_file" "$libc_path" \
    -Wl,-soname,glibcx-proc-exe-shim.so -o "$output_file"

LC_ALL=C readelf -W -h "$output_file" | awk -F: '
    /Class:/{if ($2 !~ /ELF64/) bad=1}
    /Machine:/{if ($2 !~ /AArch64/) bad=1; found=1}
    END {exit bad || !found}'
LC_ALL=C readelf -W -d "$output_file" | grep -q 'libc[.]so[.]6'
