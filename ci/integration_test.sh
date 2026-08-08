#!/usr/bin/env bash
# ci/integration_test.sh — end-to-end integration test for glibcx C wrapper
# Runs on ubuntu-26.04-arm (real AArch64, glibc present at standard paths).
# Usage: bash ci/integration_test.sh
set -euo pipefail

pass() { printf '\033[1;32m  PASS\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m  FAIL\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[1;34m  ----\033[0m %s\n' "$*"; }

# ── 1. Locate system glibc loader ────────────────────────────────────────────
info "Locating glibc dynamic linker..."
LDSO=$(find /lib /usr/lib -name "ld-linux-aarch64.so.1" 2>/dev/null | head -1)
[[ -n "$LDSO" ]] || fail "ld-linux-aarch64.so.1 not found on this system"
LIBDIR=$(dirname "$LDSO")
info "ld.so   : $LDSO"
info "lib dir : $LIBDIR"

# ── 2. Download fd ───────────────────────────────────────────────────────────
info "Fetching latest fd release info..."
RELEASE=$(curl -fsSL https://api.github.com/repos/sharkdp/fd/releases/latest)
URL=$(echo "$RELEASE" | jq -r '
  .assets[]
  | select(
      (.name | ascii_downcase | test("aarch64.*linux.*gnu|linux.*aarch64.*gnu"))
      and (.name | ascii_downcase | test("musl|android|deb|rpm|\\.sha|\\.sig") | not)
      and (.name | test("\\.tar\\.gz$"))
    )
  | .browser_download_url' | head -1)

[[ -n "$URL" ]] || fail "Could not find fd glibc AArch64 asset"
info "Downloading: $URL"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

curl -fsSL "$URL" -o "$TMPDIR/fd.tar.gz"
tar -xzf "$TMPDIR/fd.tar.gz" -C "$TMPDIR"
FD_BIN=$(find "$TMPDIR" -name "fd" -type f -executable | head -1)
[[ -n "$FD_BIN" ]] || fail "fd binary not found in tarball"
cp "$FD_BIN" /tmp/fd-test-bin
chmod +x /tmp/fd-test-bin
info "fd binary: $(file /tmp/fd-test-bin)"

# ── 3. Verify it's AArch64 glibc ELF ─────────────────────────────────────────
file /tmp/fd-test-bin | grep -q "ELF 64-bit" || fail "Not a 64-bit ELF"
file /tmp/fd-test-bin | grep -qiE "aarch64|arm64"  || fail "Not AArch64"
pass "Binary is AArch64 ELF"

# ── 4. Extract and compile C wrapper ─────────────────────────────────────────
info "Extracting C wrapper template from src/patch.sh..."
TARGET=/tmp/fd-test-bin
FP=$(stat -c '%Y_%s' "$TARGET")

# The C code lives between the first '#include <stdio.h>' line and 'C_CODE' heredoc terminator
awk '/^#include <stdio\.h>/{found=1} found && /^C_CODE$/{exit} found{print}' src/patch.sh \
  | sed \
      -e "s|\${target_bin}|${TARGET}|g" \
      -e "s|\${patched_fp}|${FP}|g" \
      -e "s|\${GLIBC_INTERPRETER}|${LDSO}|g" \
      -e "s|\${GLIBC_LIB_DIR}|${LIBDIR}|g" \
  > /tmp/fd_wrapper.c

LINES=$(wc -l < /tmp/fd_wrapper.c)
info "Extracted ${LINES} lines of C"
[[ "$LINES" -gt 50 ]] || fail "C extraction produced too few lines — sed anchor may be broken"

info "Compiling wrapper with clang..."
clang -O2 /tmp/fd_wrapper.c -o /tmp/fd_wrapper
pass "Wrapper compiled: $(file /tmp/fd_wrapper)"

# ── 5. Run: version check ─────────────────────────────────────────────────────
info "Running fd through wrapper: --version"
OUT=$(/tmp/fd_wrapper --version 2>&1 || true)
info "Output: $OUT"
echo "$OUT" | grep -qE "[0-9]+\.[0-9]+\.[0-9]+" || fail "No version string in output: '$OUT'"
pass "fd --version: $OUT"

# ── 6. Run: real file search ──────────────────────────────────────────────────
info "Running fd through wrapper: find .sh files"
COUNT=$(/tmp/fd_wrapper -e sh . 2>/dev/null | wc -l)
info "Found $COUNT .sh files"
[[ "$COUNT" -ge 5 ]] || fail "fd found too few .sh files ($COUNT) — expected ≥5"
pass "fd -e sh found $COUNT files"

# ── 7. Drift detection ────────────────────────────────────────────────────────
info "Testing drift detection (touch binary to change mtime)..."
sleep 1
touch /tmp/fd-test-bin
DRIFT_OUT=$(/tmp/fd_wrapper --version 2>&1 || true)
info "Drift output: $DRIFT_OUT"
echo "$DRIFT_OUT" | grep -q "changed since patching" || \
  fail "Drift detection did not trigger after mtime change. Got: '$DRIFT_OUT'"
pass "Drift detection correctly blocked execution"

echo ""
echo "All integration tests passed."
