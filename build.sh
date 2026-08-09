#!/data/data/com.termux/files/usr/bin/env bash
set -euo pipefail

OUT="glibcx-bin"
echo "#!/data/data/com.termux/files/usr/bin/env bash" > "$OUT"
echo "# glibcx - Universal Native-Speed glibc Binary Runner & Patcher" >> "$OUT"
echo "set -euo pipefail" >> "$OUT"
echo "" >> "$OUT"

# Concatenate modules (ensure newline between modules to avoid token merging)
modules=(
    src/common.sh \
    src/lock.sh \
    src/state.sh \
    src/elf.sh \
    src/runtime.sh \
    src/wrapper.sh \
    src/resolver.sh \
    src/setup.sh \
    src/patch.sh \
    src/doctor.sh \
    src/trace.sh \
    src/bench.sh \
    src/providers/fetch.sh \
    src/providers/npm.sh \
    src/providers/github.sh \
    src/providers/intercept.sh \
    src/providers/vendor.sh \
    src/providers/selfupdate.sh \
    src/main.sh
)
for index in "${!modules[@]}"; do
    mod="${modules[$index]}"
    cat "$mod" >> "$OUT"
    if (( index < ${#modules[@]} - 1 )); then
        printf '\n' >> "$OUT"
    fi
done

chmod +x "$OUT"
echo "Build complete: $OUT"
