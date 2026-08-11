#!/usr/bin/env bash
# ci/integration_test.sh — end-to-end integration test for glibcx C wrapper
# Runs on ubuntu-26.04-arm (real AArch64, glibc present at standard paths).
# Usage: bash ci/integration_test.sh
set -euo pipefail

pass() { printf '\033[1;32m  PASS\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m  FAIL\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[1;34m  ----\033[0m %s\n' "$*"; }
cleanup() { rm -rf "${TEST_TMP_DIR:?}"; }
c_bytes() {
  printf '%s' "$1" | LC_ALL=C od -An -v -t u1 | awk '
    { for (i = 1; i <= NF; i++) printf "0x%02x, ", $i }
    END { print "0x00" }
  '
}

# ── 1. Locate system glibc loader ────────────────────────────────────────────
info "Locating glibc dynamic linker..."
loader_dirs=(/lib /usr/lib)
if [[ -n "${PREFIX:-}" && -d "${PREFIX}/glibc/lib" ]]; then
  loader_dirs=("${PREFIX}/glibc/lib" "${loader_dirs[@]}")
fi
LDSO=$(find "${loader_dirs[@]}" -name "ld-linux-aarch64.so.1" -type f -print -quit 2>/dev/null || true)
[[ -n "$LDSO" ]] || fail "ld-linux-aarch64.so.1 not found on this system"
LIBDIR=$(dirname "$LDSO")
info "ld.so   : $LDSO"
info "lib dir : $LIBDIR"

# ── 2. Download fd ───────────────────────────────────────────────────────────
info "Fetching latest fd release info..."
RELEASE=$(curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
  https://api.github.com/repos/sharkdp/fd/releases/latest)
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

TEST_TMP_DIR=$(mktemp -d)
trap cleanup EXIT

curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
  "$URL" -o "$TEST_TMP_DIR/fd.tar.gz"
tar -xzf "$TEST_TMP_DIR/fd.tar.gz" -C "$TEST_TMP_DIR"
FD_BIN=$(find "$TEST_TMP_DIR" -name "fd" -type f -executable -print -quit || true)
[[ -n "$FD_BIN" ]] || fail "fd binary not found in tarball"
TARGET="$TEST_TMP_DIR/fd-test\\name"
cp "$FD_BIN" "$TARGET"
chmod +x "$TARGET"
info "fd binary: $(file "$TARGET")"

# ── 3. Verify it's AArch64 glibc ELF ─────────────────────────────────────────
file "$TARGET" | grep -q "ELF 64-bit" || fail "Not a 64-bit ELF"
file "$TARGET" | grep -qiE "aarch64|arm64"  || fail "Not AArch64"
pass "Binary is AArch64 ELF"

# ── 4. Extract and compile C wrapper ─────────────────────────────────────────
info "Extracting C wrapper template from src/patch.sh..."
FP=$(stat -c '%d_%i_%s_%Y_%Z' "$TARGET")
TARGET_BYTES=$(c_bytes "$TARGET")
LDSO_BYTES=$(c_bytes "$LDSO")
LIBRARY_PATH_BYTES=$(c_bytes "$LIBDIR")

# The C code lives between the first '#include <stdio.h>' line and 'C_CODE' heredoc terminator
awk '/^#include <stdio\.h>/{found=1} found && /^C_CODE$/{exit} found{print}' src/patch.sh \
  | sed \
      -e "s|\${target_c_bytes}|${TARGET_BYTES}|g" \
      -e "s|\${patched_fp}|${FP}|g" \
      -e "s|\${ldso_c_bytes}|${LDSO_BYTES}|g" \
      -e "s|\${library_path_c_bytes}|${LIBRARY_PATH_BYTES}|g" \
      -e 's|\${hwcaps_mask_c_bytes}|0x00|g' \
      -e 's|\${hwcaps_policy_c}|0|g' \
      -e 's|\${ssl_cert_path_c_bytes}|0x2f, 0x6e, 0x6f, 0x6e, 0x65, 0x00|g' \
      -e 's|\${env_real_c_bytes}|0x58, 0x3d, 0x31, 0x00|g' \
      -e 's|\${env_wrapper_c_bytes}|0x58, 0x3d, 0x31, 0x00|g' \
      -e 's|\${env_app_c_bytes}|0x58, 0x3d, 0x31, 0x00|g' \
      -e 's|\${env_mode_c_bytes}|0x58, 0x3d, 0x31, 0x00|g' \
      -e 's|\${env_tunables_c_bytes}|0x58, 0x3d, 0x31, 0x00|g' \
      -e 's|\${env_ssl_cert_c_bytes}|0x58, 0x3d, 0x31, 0x00|g' \
      -e 's|\${trace_marker_c_bytes}|0x58, 0x3d, 0x31, 0x00|g' \
      -e 's|\${proc_exe_shim_c_bytes}|0x00|g' \
  > "$TEST_TMP_DIR/fd_wrapper.c"

LINES=$(wc -l < "$TEST_TMP_DIR/fd_wrapper.c")
info "Extracted ${LINES} lines of C"
[[ "$LINES" -gt 50 ]] || fail "C extraction produced too few lines — sed anchor may be broken"

info "Compiling wrapper with clang..."
clang -O2 "$TEST_TMP_DIR/fd_wrapper.c" -o "$TEST_TMP_DIR/fd_wrapper"
pass "Wrapper compiled: $(file "$TEST_TMP_DIR/fd_wrapper")"

# ── 5. Run: version check ─────────────────────────────────────────────────────
info "Running fd through wrapper: --version"
OUT=$("$TEST_TMP_DIR/fd_wrapper" --version 2>&1 || true)
info "Output: $OUT"
echo "$OUT" | grep -qE "[0-9]+\.[0-9]+\.[0-9]+" || fail "No version string in output: '$OUT'"
pass "fd --version: $OUT"

# ── 6. Run: real file search ──────────────────────────────────────────────────
info "Running fd through wrapper: find .sh files"
COUNT=$("$TEST_TMP_DIR/fd_wrapper" -e sh . 2>/dev/null | wc -l)
info "Found $COUNT .sh files"
[[ "$COUNT" -ge 5 ]] || fail "fd found too few .sh files ($COUNT) — expected ≥5"
pass "fd -e sh found $COUNT files"

# ── 7. Controlled loader tracing ─────────────────────────────────────────────
info "Running fd through the wrapper's internal trace channel"
TRACE_OUT=$("$TEST_TMP_DIR/fd_wrapper" X=1 --version 2>&1 || true)
echo "$TRACE_OUT" | grep -qE 'file=|find library=' \
  || fail "Internal trace channel did not enable loader diagnostics"
echo "$TRACE_OUT" | grep -qE '^fd [0-9]+\.[0-9]+\.[0-9]+' \
  || fail "fd --version output was missing from controlled trace run"
pass "controlled LD_DEBUG trace enabled and marker stripped"

# ── 8. Drift detection ────────────────────────────────────────────────────────
info "Testing drift detection (touch binary to change mtime)..."
sleep 1
touch "$TARGET"
DRIFT_OUT=$("$TEST_TMP_DIR/fd_wrapper" --version 2>&1 || true)
info "Drift output: $DRIFT_OUT"
echo "$DRIFT_OUT" | grep -q "changed since patching" || \
  fail "Drift detection did not trigger after mtime change. Got: '$DRIFT_OUT'"
pass "Drift detection correctly blocked execution"

echo ""
echo "All integration tests passed."
