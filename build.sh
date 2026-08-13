#!/data/data/com.termux/files/usr/bin/env bash
set -euo pipefail

OUT="glibcx-bin"
CORE_OUT="glibcx-core-bin"
PACKAGE_MANAGED="${GLIBCX_PACKAGE_MANAGED:-0}"
[[ "$PACKAGE_MANAGED" == 0 || "$PACKAGE_MANAGED" == 1 ]] || {
    echo "GLIBCX_PACKAGE_MANAGED must be 0 or 1." >&2
    exit 2
}
echo "#!/data/data/com.termux/files/usr/bin/env bash" > "$OUT"
echo "# glibcx - Universal Native-Speed glibc Binary Runner & Patcher" >> "$OUT"
echo "set -euo pipefail" >> "$OUT"
echo "GLIBCX_PACKAGE_MANAGED=$PACKAGE_MANAGED" >> "$OUT"
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
    src/patch.sh \
    src/doctor.sh \
    src/trace.sh \
    src/bench.sh \
    src/providers/fetch.sh \
    src/providers/npm.sh \
    src/providers/github.sh \
    src/providers/intercept.sh \
    src/providers/vendor.sh \
    src/main.sh
)
if [[ "$PACKAGE_MANAGED" != 1 ]]; then
    modules=(
        "${modules[@]:0:7}"
        src/setup.sh
        "${modules[@]:7:8}"
        src/providers/selfupdate.sh
        "${modules[@]:15}"
    )
fi
for index in "${!modules[@]}"; do
    mod="${modules[$index]}"
    cat "$mod" >> "$OUT"
    if (( index < ${#modules[@]} - 1 )); then
        printf '\n' >> "$OUT"
    fi
done

chmod +x "$OUT"
export CARGO_INCREMENTAL=0
cargo build --manifest-path core/Cargo.toml --release --locked
install -m 755 core/target/release/glibcx-core "$CORE_OUT"
echo "Build complete: $OUT"
echo "Core build complete: $CORE_OUT"
