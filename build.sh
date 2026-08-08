#!/data/data/com.termux/files/usr/bin/env bash
set -euo pipefail

OUT="glibcx-bin"
echo "#!/data/data/com.termux/files/usr/bin/env bash" > "$OUT"
echo "# glibcx - Universal Native-Speed glibc Binary Runner & Patcher" >> "$OUT"
echo "set -euo pipefail" >> "$OUT"
echo "" >> "$OUT"

# Concatenate modules
cat src/common.sh \
    src/setup.sh \
    src/patch.sh \
    src/bench.sh \
    src/providers/fetch.sh \
    src/providers/npm.sh \
    src/providers/github.sh \
    src/providers/intercept.sh \
    src/providers/vendor.sh \
    src/providers/selfupdate.sh \
    src/main.sh >> "$OUT"

chmod +x "$OUT"
echo "Build complete: $OUT"
