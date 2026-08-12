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

_elf_dynamic_values() {
    local dynamic_text="$1" tag="$2"
    awk -v wanted="$tag" '
        index($0, "(" wanted ")") {
            if (match($0, /\[[^]]*\]/)) {
                print substr($0, RSTART + 1, RLENGTH - 2)
            }
        }
    ' <<<"$dynamic_text"
}

# elf_inspect <path>
#
# Emits a single JSON object. readelf output is forced to the C locale and no
# target-derived value is evaluated or sourced.
elf_inspect() {
    local elf_path="${1:-}"
    local inspection_mode="${2:-target}"
    local header_text program_text dynamic_text notes_text versions_text
    local elf_class data_encoding elf_type machine interpreter_lines interpreter_count interpreter
    local needed_lines soname rpath_lines runpath_lines rpath_raw runpath_raw dynamic_flags audit_tags
    local build_id abi_note version_lines gnu_properties
    local gnu_stack_flags="" has_dynamic=false text_relocations=false wx_load=false
    local valid=true
    local needed_json rpath_json runpath_json versions_json flags_json audit_json properties_json errors_json warnings_json
    local errors=() warnings=()

    if [[ -z "$elf_path" || ! -f "$elf_path" ]]; then
        echo "[glibcx] Error: ELF file not found: ${elf_path:-<none>}" >&2
        return 1
    fi
    if [[ "$elf_path" == *$'\n'* || "$elf_path" == *$'\r'* ]]; then
        echo "[glibcx] Error: paths containing newlines are unsupported." >&2
        return 1
    fi
    _require_command readelf binutils
    elf_path=$(realpath "$elf_path")

    if ! header_text=$(LC_ALL=C readelf -W -h "$elf_path" 2>/dev/null); then
        errors+=("not a readable ELF file")
        valid=false
        jq -n --arg path "$elf_path" --argjson valid "$valid" \
            --argjson errors "$(printf '%s\n' "${errors[@]}" | _elf_lines_to_json)" \
            '{path: $path, valid: $valid, errors: $errors}'
        return 0
    fi

    program_text=$(LC_ALL=C readelf -W -l "$elf_path" 2>/dev/null || true)
    dynamic_text=$(LC_ALL=C readelf -W -d "$elf_path" 2>/dev/null || true)
    notes_text=$(LC_ALL=C readelf -W -n "$elf_path" 2>/dev/null || true)
    versions_text=$(LC_ALL=C readelf -W -V "$elf_path" 2>/dev/null || true)

    elf_class=$(awk -F: '/^[[:space:]]*Class:/{sub(/^[[:space:]]+/, "", $2); print $2; exit}' <<<"$header_text")
    data_encoding=$(awk -F: '/^[[:space:]]*Data:/{sub(/^[[:space:]]+/, "", $2); print $2; exit}' <<<"$header_text")
    elf_type=$(awk -F: '/^[[:space:]]*Type:/{sub(/^[[:space:]]+/, "", $2); sub(/[[:space:]].*/, "", $2); print $2; exit}' <<<"$header_text")
    machine=$(awk -F: '/^[[:space:]]*Machine:/{sub(/^[[:space:]]+/, "", $2); print $2; exit}' <<<"$header_text")

    interpreter_lines=$(awk '
        /Requesting program interpreter:/ {
            line=$0
            sub(/^.*Requesting program interpreter:[[:space:]]*/, "", line)
            sub(/\].*$/, "", line)
            print line
        }
    ' <<<"$program_text")
    interpreter_count=$(awk 'NF {count++} END {print count + 0}' <<<"$interpreter_lines")
    interpreter=$(head -n 1 <<<"$interpreter_lines")
    if awk '$1 == "DYNAMIC" {found=1} END {exit !found}' <<<"$program_text"; then
        has_dynamic=true
    fi
    gnu_stack_flags=$(awk '$1 == "GNU_STACK" {for (i=7; i<NF; i++) printf "%s", $i; print ""; exit}' <<<"$program_text")
    if awk '
        $1 == "LOAD" {
            flags=""
            for (i=7; i<NF; i++) flags=flags $i
            if (flags ~ /W/ && flags ~ /E/) found=1
        }
        END {exit !found}
    ' <<<"$program_text"; then
        wx_load=true
        warnings+=("target contains a writable-executable PT_LOAD segment")
    fi
    if [[ "$gnu_stack_flags" == *E* ]]; then
        warnings+=("target requests an executable GNU stack")
    fi

    needed_lines=$(_elf_dynamic_values "$dynamic_text" NEEDED)
    soname=$(_elf_dynamic_values "$dynamic_text" SONAME | sed -n '1p')
    rpath_raw=$(_elf_dynamic_values "$dynamic_text" RPATH | sed -n '1p')
    runpath_raw=$(_elf_dynamic_values "$dynamic_text" RUNPATH | sed -n '1p')
    rpath_lines=$(tr ':' '\n' <<<"$rpath_raw")
    runpath_lines=$(tr ':' '\n' <<<"$runpath_raw")
    local declared_path expanded_path origin_path
    origin_path=$(realpath -m "$(dirname "$elf_path")")
    for declared_path in "$rpath_raw" "$runpath_raw"; do
        [[ -n "$declared_path" ]] || continue
        if [[ "$declared_path" == :* || "$declared_path" == *: || "$declared_path" == *::* ]]; then
            errors+=("RPATH/RUNPATH contains an empty current-directory entry")
            valid=false
        fi
    done
    while IFS= read -r declared_path; do
        [[ -n "$declared_path" ]] || continue
        expanded_path=""
        case "$declared_path" in
            /*) ;;
            '$ORIGIN'|'${ORIGIN}') ;;
            '$ORIGIN/'*) expanded_path="${origin_path}/${declared_path#\$ORIGIN/}" ;;
            '${ORIGIN}/'*) expanded_path="${origin_path}/${declared_path#\$\{ORIGIN\}/}" ;;
            *)
                errors+=("relative or unsupported RPATH/RUNPATH entry: $declared_path")
                valid=false
                continue
                ;;
        esac
        if [[ -n "${expanded_path:-}" ]]; then
            expanded_path=$(realpath -m "$expanded_path")
            if [[ "$expanded_path" != "$origin_path" \
                && "$expanded_path" != "${origin_path}/"* ]]; then
                errors+=("ORIGIN RPATH/RUNPATH escapes the declaring object directory: $declared_path")
                valid=false
            fi
            expanded_path=""
        fi
    done < <(printf '%s\n%s\n' "$rpath_lines" "$runpath_lines")
    while IFS= read -r declared_path; do
        if [[ "$declared_path" == */* ]]; then
            errors+=("DT_NEEDED entry contains a path: $declared_path")
            valid=false
        fi
    done <<<"$needed_lines"
    dynamic_flags=$(awk '/\((FLAGS|FLAGS_1)\)/ {sub(/^[[:space:]]*/, ""); print}' <<<"$dynamic_text")
    audit_tags=$(awk '/\((AUDIT|DEPAUDIT|FILTER|AUXILIARY)\)/ {sub(/^[[:space:]]*/, ""); print}' <<<"$dynamic_text")
    if grep -qE '\(TEXTREL\)|\(FLAGS\).*TEXTREL' <<<"$dynamic_text"; then
        text_relocations=true
        warnings+=("target declares text relocations")
    fi
    if [[ -n "$audit_tags" ]]; then
        warnings+=("target declares dynamic audit or filter tags")
    fi

    build_id=$(awk '/Build ID:/ {print $3; exit}' <<<"$notes_text")
    abi_note=$(awk '/OS:[[:space:]]*Linux,[[:space:]]*ABI:/ {sub(/^[[:space:]]*/, ""); print; exit}' <<<"$notes_text")
    gnu_properties=$(awk '
        /Properties:/ || /AArch64 feature:/ {
            sub(/^[[:space:]]*/, "")
            print
        }
    ' <<<"$notes_text")
    version_lines=$(awk '/Version needs section/{capture=1; next} capture' <<<"$versions_text" \
        | grep -oE 'GLIBC_ABI_[A-Za-z0-9_.]+|GLIBC_[0-9][A-Za-z0-9_.]*|GLIBCXX_[0-9][A-Za-z0-9_.]*|CXXABI_[0-9][A-Za-z0-9_.]*|GCC_[0-9][A-Za-z0-9_.]*' \
        | LC_ALL=C sort -uV || true)

    [[ "$elf_class" == "ELF64" ]] || { errors+=("unsupported ELF class: ${elf_class:-unknown}"); valid=false; }
    [[ "$data_encoding" == *"little endian"* ]] || { errors+=("unsupported ELF data encoding: ${data_encoding:-unknown}"); valid=false; }
    [[ "$machine" == "AArch64" ]] || { errors+=("unsupported ELF machine: ${machine:-unknown}"); valid=false; }
    [[ "$elf_type" == "DYN" || "$elf_type" == "EXEC" ]] \
        || { errors+=("unsupported ELF type: ${elf_type:-unknown}"); valid=false; }
    [[ "$has_dynamic" == true ]] || { errors+=("target has no PT_DYNAMIC segment"); valid=false; }
    if [[ "$inspection_mode" == "target" ]]; then
        if [[ "$interpreter_count" -ne 1 ]]; then
            errors+=("target must contain exactly one PT_INTERP entry (found $interpreter_count)")
            valid=false
        elif [[ "$(basename "$interpreter")" != "ld-linux-aarch64.so.1" \
            && "$(basename "$interpreter")" != "ld.so" ]]; then
            errors+=("unsupported dynamic interpreter: $interpreter")
            valid=false
        fi
    elif [[ "$inspection_mode" == "dso" ]]; then
        if [[ "$elf_type" != "DYN" ]]; then
            errors+=("shared library must have ELF type DYN")
            valid=false
        fi
    else
        errors+=("unknown ELF inspection mode: $inspection_mode")
        valid=false
    fi
    if grep -qx 'libc.so' <<<"$needed_lines" || [[ "$soname" == "libc.so" ]]; then
        errors+=("target links Android/Bionic libc.so instead of glibc libc.so.6")
        valid=false
    fi

    needed_json=$(printf '%s\n' "$needed_lines" | _elf_lines_to_json)
    rpath_json=$(printf '%s\n' "$rpath_lines" | _elf_lines_to_json)
    runpath_json=$(printf '%s\n' "$runpath_lines" | _elf_lines_to_json)
    versions_json=$(printf '%s\n' "$version_lines" | _elf_lines_to_json)
    flags_json=$(printf '%s\n' "$dynamic_flags" | _elf_lines_to_json)
    audit_json=$(printf '%s\n' "$audit_tags" | _elf_lines_to_json)
    properties_json=$(printf '%s\n' "$gnu_properties" | _elf_lines_to_json)
    errors_json=$(printf '%s\n' "${errors[@]}" | _elf_lines_to_json)
    warnings_json=$(printf '%s\n' "${warnings[@]}" | _elf_lines_to_json)

    jq -n \
        --arg path "$elf_path" \
        --arg inspection_mode "$inspection_mode" \
        --arg class "$elf_class" \
        --arg data "$data_encoding" \
        --arg type "$elf_type" \
        --arg machine "$machine" \
        --arg interpreter "$interpreter" \
        --argjson interpreter_count "$interpreter_count" \
        --argjson has_dynamic "$has_dynamic" \
        --arg gnu_stack "$gnu_stack_flags" \
        --argjson wx_load "$wx_load" \
        --argjson text_relocations "$text_relocations" \
        --arg soname "$soname" \
        --arg build_id "$build_id" \
        --arg abi_note "$abi_note" \
        --argjson needed "$needed_json" \
        --argjson rpath "$rpath_json" \
        --argjson runpath "$runpath_json" \
        --argjson versions "$versions_json" \
        --argjson dynamic_flags "$flags_json" \
        --argjson audit_tags "$audit_json" \
        --argjson gnu_properties "$properties_json" \
        --argjson valid "$valid" \
        --argjson errors "$errors_json" \
        --argjson warnings "$warnings_json" \
        '{
            path: $path,
            inspection_mode: $inspection_mode,
            valid: $valid,
            errors: $errors,
            warnings: $warnings,
            header: {class: $class, data: $data, type: $type, machine: $machine},
            program_headers: {
                interpreter: (if $interpreter == "" then null else $interpreter end),
                interpreter_count: $interpreter_count,
                has_dynamic: $has_dynamic,
                gnu_stack_flags: (if $gnu_stack == "" then null else $gnu_stack end),
                writable_executable_load: $wx_load
            },
            dynamic: {
                needed: $needed,
                soname: (if $soname == "" then null else $soname end),
                rpath: $rpath,
                runpath: $runpath,
                flags: $dynamic_flags,
                audit_filter_tags: $audit_tags,
                text_relocations: $text_relocations
            },
            notes: {
                build_id: (if $build_id == "" then null else $build_id end),
                abi: (if $abi_note == "" then null else $abi_note end),
                gnu_properties: $gnu_properties
            },
            version_requirements: $versions
        }'
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
