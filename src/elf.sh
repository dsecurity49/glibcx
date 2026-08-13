elf_has_pyinstaller_archive() {
    local target="$1" trailer
    [[ -f "$target" ]] || return 1
    trailer=$(tail -c 8192 "$target" 2>/dev/null \
        | LC_ALL=C od -An -v -tx1 \
        | LC_ALL=C tr -d ' \n')
    [[ "$trailer" == *4d45490c0b0a0b0e* ]]
}

_elf_lines_to_json() {
    jq -Rsc 'split("\n") | map(select(length > 0))'
}

_elf_core_repair_message() {
    echo "[glibcx] Error: the glibcx ELF core is missing or incompatible." >&2
    echo "[glibcx] Repair the installation with: pkg reinstall glibcx" >&2
}

_elf_core_handshake() {
    local handshake
    [[ -x "$GLIBCX_CORE_BIN" ]] || {
        _elf_core_repair_message
        return 1
    }
    if ! handshake=$("$GLIBCX_CORE_BIN" handshake 2>/dev/null) \
        || ! jq -e --argjson protocol "$GLIBCX_CORE_PROTOCOL" \
            --arg version "$GLIBCX_VERSION" \
            '.protocol == $protocol and .version == $version' \
            <<<"$handshake" >/dev/null; then
        _elf_core_repair_message
        return 1
    fi
}

# elf_inspect <path> [target|dso]
#
# The Rust core owns all ELF parsing. Bash deliberately retains only the
# stable command-facing JSON interface and must not fall back to readelf.
elf_inspect() {
    local elf_path="${1:-}" inspection_mode="${2:-target}" inspection
    if [[ -z "$elf_path" || ! -f "$elf_path" ]]; then
        echo "[glibcx] Error: ELF file not found: ${elf_path:-<none>}" >&2
        return 1
    fi
    if [[ "$elf_path" == *$'\n'* || "$elf_path" == *$'\r'* ]]; then
        echo "[glibcx] Error: paths containing newlines are unsupported." >&2
        return 1
    fi
    _require_command jq jq
    _elf_core_handshake || return 1
    if ! inspection=$("$GLIBCX_CORE_BIN" inspect "$inspection_mode" "$elf_path"); then
        echo "[glibcx] Error: glibcx ELF core inspection failed." >&2
        return 1
    fi
    if ! jq -e '
        (.path | type) == "string"
        and (.valid | type) == "boolean"
        and (.errors | type) == "array"
        and (if .valid then (.warnings | type) == "array" else true end)
    ' <<<"$inspection" >/dev/null; then
        echo "[glibcx] Error: glibcx ELF core returned an invalid inspection result." >&2
        return 1
    fi
    printf '%s\n' "$inspection"
}

elf_max_glibc_requirement() {
    local requirements
    requirements=$(jq -r '.version_requirements[] | select(test("^GLIBC_[0-9]"))')
    if [[ -z "$requirements" ]]; then
        printf 'unknown\n'
    else
        LC_ALL=C sort -V <<<"$requirements" | tail -n 1
    fi
}

elf_print_errors() {
    jq -r '.errors[] | "[glibcx] Error: " + .' >&2
}
