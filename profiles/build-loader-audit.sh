#!/usr/bin/env bash
# Build the dependency-free AArch64 glibc loader-audit module.
set -euo pipefail

[[ $# -eq 3 ]] || {
    echo "Usage: profiles/build-loader-audit.sh <glibc-sysroot> <source.c> <output.so>" >&2
    exit 1
}

sysroot="$1"
source_file="$2"
output_file="$3"

[[ -f "${sysroot}/include/link.h" || -f "${sysroot}/usr/include/link.h" ]] || {
    echo "[loader-audit] Error: incomplete glibc sysroot (missing link.h)." >&2
    exit 1
}
[[ -f "$source_file" ]] \
    || { echo "[loader-audit] Error: source file is missing." >&2; exit 1; }
command -v clang >/dev/null 2>&1 \
    || { echo "[loader-audit] Error: clang is missing from the builder." >&2; exit 1; }

object_file=$(mktemp "${TMPDIR:-/tmp}/glibcx-loader-audit.XXXXXX.o")
cleanup() { rm -f "${object_file:?}"; }
trap cleanup EXIT

clang --target=aarch64-linux-gnu --sysroot="$sysroot" \
    -fPIC -ffreestanding -fno-stack-protector -O2 -Wall -Wextra -Werror \
    -c "$source_file" -o "$object_file"
clang --target=aarch64-linux-gnu --sysroot="$sysroot" \
    -shared -nostdlib -Wl,-z,defs -Wl,-soname,glibcx-loader-audit.so \
    "$object_file" -o "$output_file"

LC_ALL=C readelf -W -h "$output_file" | awk -F: '
    /Class:/{if ($2 !~ /ELF64/) bad=1}
    /Machine:/{if ($2 !~ /AArch64/) bad=1; found=1}
    END {exit bad || !found}'
if LC_ALL=C readelf -W -d "$output_file" | grep -q '(NEEDED)'; then
    echo "[loader-audit] Error: audit module must not have DT_NEEDED entries." >&2
    exit 1
fi
