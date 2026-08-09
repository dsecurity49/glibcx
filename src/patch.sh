# Known glibc-provided libraries — anything outside this set is a non-glibc dep.
# A version suffix is required so Android's bare libc.so is never misclassified.
_GLIBC_LIBS_RE="^(ld-linux-aarch64\.so\.1|ld\.so|lib(c|m|dl|pthread|rt|util|resolv|nsl|crypt|anl|nss_|gcc_s|stdc\+\+)\.so\.[0-9]+)$"

# Emit a NUL-terminated C byte array. This keeps quotes and backslashes out of
# generated C string literals.
_c_byte_array() {
    printf '%s' "$1" | LC_ALL=C od -An -v -t u1 | awk '
        {
            for (i = 1; i <= NF; i++) {
                printf "0x%02x, ", $i
            }
        }
        END { print "0x00" }
    '
}

cmd_patch() {
    local target_bin="" runtime_request="" no_verify=false dry_run=false
    local offline=false refresh=false no_resolve=false proc_exe_mode=auto force=false verbose=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --runtime)
                [[ $# -ge 2 ]] || { echo "[glibcx] Error: --runtime requires a profile ID." >&2; exit 1; }
                runtime_request="$2"
                shift 2
                ;;
            --runtime=*) runtime_request="${1#*=}"; shift ;;
            --no-verify) no_verify=true; shift ;;
            --dry-run) dry_run=true; shift ;;
            --offline) offline=true; shift ;;
            --refresh) refresh=true; shift ;;
            --no-resolve) no_resolve=true; shift ;;
            --force) force=true; shift ;;
            --verbose) verbose=true; shift ;;
            --proc-exe=*)
                proc_exe_mode="${1#*=}"
                case "$proc_exe_mode" in
                    auto|on|off) ;;
                    *)
                        echo "[glibcx] Error: --proc-exe must be auto, on, or off." >&2
                        exit 1
                        ;;
                esac
                shift
                ;;
            --*)
                echo "[glibcx] Error: unsupported patch option '$1' in this milestone." >&2
                exit 1
                ;;
            *)
                if [[ -n "$target_bin" ]]; then
                    echo "[glibcx] Error: patch accepts exactly one target binary." >&2
                    exit 1
                fi
                target_bin="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$target_bin" || ! -f "$target_bin" ]]; then
        echo "[glibcx] Error: File '${target_bin:-<none>}' not found." >&2
        echo "Usage: glibcx patch <binary> [--runtime <profile>] [--offline|--refresh] [--verbose]" >&2
        exit 1
    fi

    target_bin="$(realpath "$target_bin")"
    if [[ "$target_bin" == *$'\n'* || "$target_bin" == *$'\r'* ]]; then
        echo "[glibcx] Error: paths containing newlines are unsupported." >&2
        exit 1
    fi
    if [[ "$offline" == true && "$refresh" == true ]]; then
        echo "[glibcx] Error: --offline and --refresh cannot be combined." >&2
        exit 1
    fi
    if [[ "$dry_run" == true && "$refresh" == true ]]; then
        echo "[glibcx] Error: --dry-run cannot refresh mutable repository state." >&2
        exit 1
    fi
    if [[ "$force" == true ]]; then
        echo "[glibcx] Notice: --force permits republishing unchanged state; trust checks remain mandatory."
    fi
    if [[ -z "$runtime_request" && -f "$REGISTRY_FILE" ]] \
        && jq -e '.schema == 3 and (.apps | type) == "object"' "$REGISTRY_FILE" >/dev/null 2>&1; then
        local existing_manifest
        existing_manifest=$(jq -r --arg path "$target_bin" '.apps[$path].manifest // empty' "$REGISTRY_FILE")
        if [[ -n "$existing_manifest" && -f "$existing_manifest" ]]; then
            runtime_request=$(jq -r '.runtime.profile_id // empty' "$existing_manifest")
            [[ -n "$runtime_request" && "$verbose" == true ]] \
                && echo "[glibcx] Reusing recorded runtime '$runtime_request' for this app."
        fi
    fi

    local inspection interpreter needed_libs max_req_glibc profile_json
    local runtime_id runtime_loader profile_lib_path runtime_libc
    inspection=$(elf_inspect "$target_bin")
    if [[ "$(jq -r '.valid' <<<"$inspection")" != "true" ]]; then
        elf_print_errors <<<"$inspection"
        exit 1
    fi
    interpreter=$(jq -r '.program_headers.interpreter' <<<"$inspection")
    needed_libs=$(jq -r '.dynamic.needed[]' <<<"$inspection")
    max_req_glibc=$(elf_max_glibc_requirement <<<"$inspection")
    if [[ -z "$runtime_request" \
        && -z "$(find "$RUNTIME_ROOT" -mindepth 2 -maxdepth 2 -name manifest.json -type f -print -quit 2>/dev/null)" ]]; then
        if [[ "$dry_run" == true || "$offline" == true ]]; then
            echo "[glibcx] Error: no managed runtime is installed and this mode forbids installation." >&2
            exit 1
        fi
        cmd_runtime_install recommended || exit 1
    fi
    profile_json=$(runtime_profile_select "$runtime_request" "$inspection") || exit 1
    runtime_id=$(jq -r '.profile_id' <<<"$profile_json")
    runtime_loader=$(jq -r '.loader' <<<"$profile_json")
    profile_lib_path=$(jq -r '.library_dirs | join(":")' <<<"$profile_json")
    runtime_libc=$(jq -r '.library_dirs[]' <<<"$profile_json" \
        | while IFS= read -r runtime_lib_dir; do
            if [[ -f "${runtime_lib_dir}/libc.so.6" ]]; then
                printf '%s/libc.so.6\n' "$runtime_lib_dir"
                break
            fi
        done)
    if [[ ! -x "$runtime_loader" || -z "$runtime_libc" ]]; then
        echo "[glibcx] Error: runtime '$runtime_id' has no usable loader/libc pair." >&2
        exit 1
    fi

    local bin_name
    bin_name="$(basename "$target_bin")"

    local needed_count
    needed_count=$(jq '.dynamic.needed | length' <<<"$inspection")
    echo "[glibcx] Preparing '$bin_name' · runtime $runtime_id · $needed_count startup DSO(s)"
    if [[ "$(jq '.warnings | length' <<<"$inspection")" -gt 0 ]]; then
        jq -r '.warnings[] | "[glibcx] WARNING: " + .' <<<"$inspection"
    fi

    # --- 1. NEEDED library audit ------------------------------------------------
    [[ "$verbose" == true ]] && echo "[glibcx] Needed shared libraries:"
    if [[ -z "$needed_libs" ]]; then
        [[ "$verbose" == true ]] && echo "  (none — unusual dynamically linked binary)"
    else
        local non_glibc=()
        while IFS= read -r lib; do
            if echo "$lib" | grep -qE "$_GLIBC_LIBS_RE"; then
                [[ "$verbose" == true ]] && echo "  [glibc] $lib"
            else
                [[ "$verbose" == true ]] && echo "  [DSO]   $lib"
                non_glibc+=("$lib")
            fi
        done <<< "$needed_libs"
        if [[ "$verbose" == true && ${#non_glibc[@]} -gt 0 ]]; then
            echo "[glibcx] Auditing ${#non_glibc[@]} non-core DSO dependency/dependencies."
        fi
    fi

    # --- 2. GLIBC version audit -------------------------------------------------
    local have_glibc
    have_glibc=$(LC_ALL=C strings "$runtime_libc" 2>/dev/null \
        | LC_ALL=C grep -oE "GLIBC_[0-9]+\.[0-9]+" \
        | LC_ALL=C sort -V | LC_ALL=C tail -n1 || echo "unknown")

    if [[ "$verbose" == true ]]; then
        echo "[glibcx] GLIBC required/provided: $max_req_glibc / $have_glibc"
    fi

    if [[ "$max_req_glibc" != "unknown" && "$have_glibc" != "unknown" ]]; then
        # Compare versions — sort -V, pick highest; if req > have, warn
        local highest
        highest=$(printf '%s\n%s\n' "$max_req_glibc" "$have_glibc" \
            | LC_ALL=C sort -V | LC_ALL=C tail -n1)
        if [[ "$highest" == "$max_req_glibc" && "$max_req_glibc" != "$have_glibc" ]]; then
            echo "[glibcx] WARNING: binary requires $max_req_glibc but installed glibc only provides $have_glibc."
            echo "[glibcx]   Symbol resolution may fail at runtime."
        fi
    fi

    # --- 3. Hash & Fingerprint (identity + metadata drift detection) ------------
    local orig_hash
    orig_hash=$(_sha256_file "$target_bin")
    local patched_fp
    patched_fp=$(_fingerprint "$target_bin")
    if [[ "$proc_exe_mode" == auto ]]; then
        local needs_proc_exe=false
        if elf_has_pyinstaller_archive "$target_bin"; then
            needs_proc_exe=true
        elif jq -e --arg basename "$bin_name" --arg hash "$orig_hash" '
            (.proc_exe_shim.path // "") != ""
            and ((.proc_exe_shim.auto_targets // [])
                | any(.basename == $basename and (.sha256 == null or .sha256 == $hash)))
        ' <<<"$profile_json" >/dev/null; then
            needs_proc_exe=true
        fi
        if [[ "$needs_proc_exe" == true ]]; then
            if [[ "$(jq -r '.kind' <<<"$profile_json")" != managed ]] \
                || [[ -z "$(jq -r '.proc_exe_shim.path // empty' <<<"$profile_json")" ]]; then
                echo "[glibcx] Error: this self-inspecting binary requires a managed runtime with proc-exe support." >&2
                echo "[glibcx] Install a current managed runtime, or use --proc-exe=off only for diagnosis." >&2
                exit 1
            fi
            proc_exe_mode=on
        else
            proc_exe_mode=off
        fi
    fi
    local proc_exe_shim=""
    if [[ "$proc_exe_mode" == on ]]; then
        if [[ "$(jq -r '.kind' <<<"$profile_json")" != managed ]]; then
            echo "[glibcx] Error: proc-exe mode requires a signed managed runtime profile." >&2
            exit 1
        fi
        proc_exe_shim=$(jq -r '.proc_exe_shim.path // empty' <<<"$profile_json")
        if [[ -z "$proc_exe_shim" || ! -f "$proc_exe_shim" ]]; then
            echo "[glibcx] Error: selected runtime has no verified proc-exe shim." >&2
            exit 1
        fi
    fi

    if [[ "$dry_run" == true ]]; then
        local preview_app_id preview_app_lib preview_verification
        preview_app_id="$(_sanitize_basename "$bin_name")-${orig_hash:0:16}"
        preview_app_lib="${APPS_DIR}/${preview_app_id}/current/lib"
        if [[ "$no_verify" == true ]]; then
            echo "[glibcx] Dry run: loader verification would be skipped by explicit request."
        else
            preview_verification=$(loader_verify_target "$profile_json" "$preview_app_lib" \
                "$preview_app_lib" "$target_bin" "$inspection" "$proc_exe_mode")
            echo "[glibcx] Dry run loader verification: $(jq -r '.verified' <<<"$preview_verification")"
            if [[ "$(jq -r '.verified' <<<"$preview_verification")" != "true" ]]; then
                jq -r '.list.output, .unexpected_resolutions[]?' <<<"$preview_verification" >&2
                return 1
            fi
        fi
        echo "[glibcx] Dry run app ID candidate : $preview_app_id"
        echo "[glibcx] Dry run runtime profile  : $runtime_id"
        echo "[glibcx] No locks were acquired and no files were changed."
        return 0
    fi

    init_env

    local target_lock registry_lock app_lock app_id
    local app_root generations_dir staging_dir generation_dir generation_number
    local current_link current_dir previous_current="" registry_snapshot
    local replace_legacy_alias=false
    local wrapper_c wrapper_bin library_path

    lock_acquire target_lock "$(lock_target_name "$target_bin")"
    lock_acquire registry_lock registry
    app_id=$(state_allocate_app_id_locked "$target_bin" "$bin_name" "$orig_hash")
    lock_acquire app_lock "$(lock_app_name "$app_id")"

    app_root=$(state_app_root "$app_id")
    generations_dir="${app_root}/generations"
    current_link="${app_root}/current"
    mkdir -p "$generations_dir"
    if [[ -L "$current_link" ]]; then
        previous_current=$(readlink "$current_link")
        if [[ ! "$previous_current" =~ ^generations/[1-9][0-9]*$ \
            || ! -d "${app_root}/${previous_current}" ]]; then
            echo "[glibcx] Error: app current-generation link is invalid." >&2
            lock_release "$app_lock"
            lock_release "$registry_lock"
            lock_release "$target_lock"
            exit 1
        fi
        current_dir="${app_root}/${previous_current}"
        if [[ -f "${BIN_DIR}/${bin_name}" && ! -L "${BIN_DIR}/${bin_name}" \
            && -f "${current_dir}/manifest.json" ]] \
            && jq -e '.migration.from_schema == 2 and (.wrapper.sha256 | type) == "string"' \
                "${current_dir}/manifest.json" >/dev/null 2>&1 \
            && [[ "$(_sha256_file "${BIN_DIR}/${bin_name}")" \
                == "$(jq -r '.wrapper.sha256' "${current_dir}/manifest.json")" ]]; then
            replace_legacy_alias=true
        fi
    elif [[ -e "$current_link" ]]; then
        echo "[glibcx] Error: app current-generation path is not a symlink." >&2
        lock_release "$app_lock"
        lock_release "$registry_lock"
        lock_release "$target_lock"
        exit 1
    else
        current_dir=""
    fi
    local final_wrapper
    final_wrapper=$(state_current_wrapper_path "$app_id")
    staging_dir=$(mktemp -d "${generations_dir}/.stage.XXXXXX")
    mkdir -p "${staging_dir}/lib"
    if [[ -n "$current_dir" && -d "${current_dir}/lib" ]]; then
        cp -a "${current_dir}/lib/." "${staging_dir}/lib/"
    fi

    local verification_json dependencies_json repository_json
    if ! repository_json=$(resolver_prepare_startup_closure "$profile_json" "$target_bin" \
        "$inspection" "${staging_dir}/lib" "$offline" "$refresh" "$no_resolve"); then
        rm -rf "${staging_dir:?}"
        lock_release "$app_lock"
        lock_release "$registry_lock"
        lock_release "$target_lock"
        exit 1
    fi
    if [[ "$no_verify" == true ]]; then
        verification_json=$(jq -n '{
            verified: false,
            scope: "skipped-by-user",
            verify: {exit_code: null, output: ""},
            list: {exit_code: null, output: ""},
            list_sha256: null,
            library_path: null,
            unexpected_resolutions: []
        }')
        echo "[glibcx] WARNING: loader verification was explicitly skipped."
    else
        verification_json=$(loader_verify_target "$profile_json" "${staging_dir}/lib" \
            "$(state_current_lib_path "$app_id")" "$target_bin" "$inspection" "$proc_exe_mode")
        if [[ "$(jq -r '.verified' <<<"$verification_json")" != "true" ]]; then
            echo "[glibcx] Error: loader verification failed." >&2
            jq -r '
                if .verify.output != "" then "  --verify: " + .verify.output else empty end,
                if .list.output != "" then "  --list: " + .list.output else empty end,
                .unexpected_resolutions[]? | "  unexpected resolution: " + .
            ' <<<"$verification_json" >&2
            rm -rf "${staging_dir:?}"
            lock_release "$app_lock"
            lock_release "$registry_lock"
            lock_release "$target_lock"
            exit 1
        fi
        echo "[glibcx] Startup closure verified."
    fi
    if [[ "$(jq -r '.verified' <<<"$verification_json")" == "true" ]]; then
        jq -r '.list.output' <<<"$verification_json" >"${staging_dir}/resolution.txt"
        chmod 600 "${staging_dir}/resolution.txt"
        if ! dependencies_json=$(resolver_manifest_dependencies "$verification_json" "$profile_json" \
            "${staging_dir}/lib" "$(state_current_lib_path "$app_id")"); then
            rm -rf "${staging_dir:?}"
            lock_release "$app_lock"
            lock_release "$registry_lock"
            lock_release "$target_lock"
            exit 1
        fi
    else
        : >"${staging_dir}/resolution.txt"
        chmod 600 "${staging_dir}/resolution.txt"
        dependencies_json='[]'
    fi

    # --- 4. Compile C userland-exec wrapper ------------------------------------
    wrapper_c="${staging_dir}/wrapper.c"
    wrapper_bin="${staging_dir}/wrapper"
    local target_c_bytes ldso_c_bytes library_path_c_bytes
    local env_real_c_bytes env_wrapper_c_bytes env_app_c_bytes env_mode_c_bytes env_tunables_c_bytes
    local trace_marker_c_bytes proc_exe_shim_c_bytes
    target_c_bytes=$(_c_byte_array "$target_bin")
    ldso_c_bytes=$(_c_byte_array "$runtime_loader")
    library_path="$(state_current_lib_path "$app_id"):${profile_lib_path}"
    library_path_c_bytes=$(_c_byte_array "$library_path")
    env_real_c_bytes=$(_c_byte_array "GLIBCX_REAL_EXE=${target_bin}")
    env_wrapper_c_bytes=$(_c_byte_array "GLIBCX_WRAPPER_EXE=${final_wrapper}")
    env_app_c_bytes=$(_c_byte_array "GLIBCX_APP_ID=${app_id}")
    env_mode_c_bytes=$(_c_byte_array "GLIBCX_PROC_EXE_MODE=${proc_exe_mode}")
    env_tunables_c_bytes=$(_c_byte_array \
        "GLIBC_TUNABLES=$(jq -r '.allowed_tunables // [] | join(":")' <<<"$profile_json")")
    trace_marker_c_bytes=$(_c_byte_array "--glibcx-internal-trace=${app_id}")
    proc_exe_shim_c_bytes=$(_c_byte_array "$proc_exe_shim")

    cat << C_CODE > "$wrapper_c"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <elf.h>
#include <errno.h>
#include <limits.h>

#define MAX_ARGS 4096
#define MAX_ENV  4096

void die(const char *msg) { perror(msg); exit(1); }

static void invalid_elf(const char *msg) { errno = EINVAL; die(msg); }

static size_t page_size(void) {
    long value = sysconf(_SC_PAGESIZE);
    if (value <= 0 || ((size_t)value & ((size_t)value - 1)) != 0)
        invalid_elf("invalid system page size");
    return (size_t)value;
}

static size_t page_down(size_t value, size_t page) {
    return value & ~(page - 1);
}

static size_t page_up(size_t value, size_t page) {
    if (value > SIZE_MAX - (page - 1)) invalid_elf("ELF size overflow");
    return (value + page - 1) & ~(page - 1);
}

static int is_power_of_two(size_t value) {
    return value && !(value & (value - 1));
}

static const char target_bin[] = { ${target_c_bytes} };
static const char ldso_path[] = { ${ldso_c_bytes} };
static const char library_path[] = { ${library_path_c_bytes} };
static const char env_real_exe[] = { ${env_real_c_bytes} };
static const char env_wrapper_exe[] = { ${env_wrapper_c_bytes} };
static const char env_app_id[] = { ${env_app_c_bytes} };
static const char env_proc_mode[] = { ${env_mode_c_bytes} };
static const char env_tunables[] = { ${env_tunables_c_bytes} };
static const char trace_marker[] = { ${trace_marker_c_bytes} };
static const char proc_exe_shim[] = { ${proc_exe_shim_c_bytes} };

static int has_env_name(const char *entry, const char *name) {
    size_t length = strlen(name);
    return strncmp(entry, name, length) == 0 && entry[length] == '=';
}

static void fill_secure_random(uint8_t *buffer, size_t length) {
    int random_fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (random_fd < 0) die("open /dev/urandom");
    size_t offset = 0;
    while (offset < length) {
        ssize_t count = read(random_fd, buffer + offset, length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            close(random_fd);
            errno = EIO;
            die("read /dev/urandom");
        }
        offset += (size_t)count;
    }
    if (close(random_fd) != 0) die("close /dev/urandom");
}

unsigned long getauxval_from_envp(const char **envp, unsigned long type) {
    const char **p = envp;
    while (*p) p++;
    p++;
    unsigned long *auxv = (unsigned long *)p;
    for (; auxv[0] != AT_NULL; auxv += 2)
        if (auxv[0] == type) return auxv[1];
    return 0;
}

/* Drift check: identity and metadata must match what glibcx recorded. */
static void check_drift(void) {
    const char *target = target_bin;
    const char *recorded_fp = "${patched_fp}";
    struct stat st;
    if (stat(target, &st) != 0) {
        fprintf(stderr, "[glibcx] Error: target binary missing: %s\n", target);
        exit(1);
    }
    char fp[192];
    snprintf(fp, sizeof(fp), "%llu_%llu_%lld_%lld_%lld",
        (unsigned long long)st.st_dev, (unsigned long long)st.st_ino,
        (long long)st.st_size, (long long)st.st_mtime, (long long)st.st_ctime);
    if (strcmp(fp, recorded_fp) != 0) {
        fprintf(stderr,
            "[glibcx] '%s' changed since patching (self-update detected).\n"
            "[glibcx] Re-run: glibcx patch %s\n", target, target);
        exit(1);
    }
}

int main(int argc, const char **argv, const char **envp) {
    check_drift();

    const char *target_exe = target_bin;
    const char *ldso       = ldso_path;

    int fd = open(ldso, O_RDONLY);
    if (fd < 0) die("open ld.so");

    struct stat st;
    if (fstat(fd, &st) != 0) die("fstat ld.so");
    if (st.st_size < (off_t)sizeof(Elf64_Ehdr)) invalid_elf("ld.so too small");
    uint8_t *fdata = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (fdata == MAP_FAILED) die("mmap ld.so");

    const Elf64_Ehdr *eh = (const Elf64_Ehdr *)fdata;
    if (memcmp(eh->e_ident, ELFMAG, SELFMAG) != 0 ||
        eh->e_ident[EI_CLASS] != ELFCLASS64 || eh->e_ident[EI_DATA] != ELFDATA2LSB ||
        eh->e_machine != EM_AARCH64 || eh->e_type != ET_DYN ||
        eh->e_phentsize != sizeof(Elf64_Phdr) || eh->e_phnum == 0 ||
        eh->e_phoff > (size_t)st.st_size ||
        eh->e_phnum > ((size_t)st.st_size - eh->e_phoff) / sizeof(Elf64_Phdr))
        invalid_elf("invalid ld.so ELF header");

    size_t page = page_size();
    size_t vmin = (size_t)-1, vmax = 0, max_align = page;
    int entry_in_executable_segment = 0;
    const Elf64_Phdr *first_load = NULL;
    for (int i = 0; i < eh->e_phnum; i++) {
        const Elf64_Phdr *ph = (const Elf64_Phdr *)(fdata + eh->e_phoff + i * eh->e_phentsize);
        if (ph->p_type == PT_LOAD) {
            if (ph->p_memsz < ph->p_filesz || ph->p_offset > (size_t)st.st_size ||
                ph->p_filesz > (size_t)st.st_size - ph->p_offset ||
                ph->p_vaddr > SIZE_MAX - ph->p_memsz)
                invalid_elf("invalid ld.so load segment");
            if ((ph->p_flags & PF_W) && (ph->p_flags & PF_X))
                invalid_elf("writable-executable ld.so load segment");
            if (ph->p_align > 1 &&
                (!is_power_of_two(ph->p_align) ||
                 ((ph->p_vaddr - ph->p_offset) & (ph->p_align - 1)) != 0))
                invalid_elf("invalid ld.so segment alignment");
            if (((ph->p_vaddr - ph->p_offset) & (page - 1)) != 0)
                invalid_elf("ld.so segment is not page-congruent");
            if ((ph->p_flags & PF_X) && eh->e_entry >= ph->p_vaddr &&
                eh->e_entry - ph->p_vaddr < ph->p_memsz)
                entry_in_executable_segment = 1;
            if (!first_load) first_load = ph;
            if (ph->p_vaddr < vmin) vmin = ph->p_vaddr;
            size_t e = ph->p_vaddr + ph->p_memsz;
            if (e > vmax) vmax = e;
            if (is_power_of_two(ph->p_align) && ph->p_align > max_align)
                max_align = ph->p_align;
        }
    }
    if (!first_load || vmax <= vmin) invalid_elf("ld.so has no loadable segments");
    if (!entry_in_executable_segment) invalid_elf("ld.so entry is not executable");
    vmin = page_down(vmin, page);
    vmax = page_up(vmax, page);
    if (vmax <= vmin || vmax - vmin > SIZE_MAX - max_align)
        invalid_elf("ld.so mapping size overflow");

    uint8_t *reservation = mmap(NULL, (vmax - vmin) + max_align, PROT_NONE,
                                MAP_PRIVATE | MAP_ANON, -1, 0);
    if (reservation == MAP_FAILED) die("reserve");
    size_t base_addr = page_up((size_t)reservation - vmin, max_align);
    uint8_t *base = (uint8_t *)(base_addr + vmin);

    for (int i = 0; i < eh->e_phnum; i++) {
        const Elf64_Phdr *ph = (const Elf64_Phdr *)(fdata + eh->e_phoff + i * eh->e_phentsize);
        if (ph->p_type != PT_LOAD) continue;
        size_t off_a = page_down(ph->p_offset, page);
        size_t va_a  = page_down(ph->p_vaddr, page);
        size_t diff  = ph->p_offset - off_a;
        if (ph->p_filesz > SIZE_MAX - diff)
            invalid_elf("ld.so segment map size overflow");
        size_t mapsz = page_up(ph->p_filesz + diff, page);
        int prot = 0;
        if (ph->p_flags & PF_R) prot |= PROT_READ;
        if (ph->p_flags & PF_W) prot |= PROT_WRITE;
        if (ph->p_flags & PF_X) prot |= PROT_EXEC;
        void *seg;
        if (ph->p_memsz == 0) continue;
        if (ph->p_filesz == 0) {
            size_t anon_size = page_up(ph->p_memsz + (ph->p_vaddr - va_a), page);
            seg = mmap(base + va_a - vmin, anon_size, prot,
                       MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
        } else {
            seg = mmap(base + va_a - vmin, mapsz, prot,
                       MAP_PRIVATE | MAP_FIXED, fd, off_a);
        }
        if (seg == MAP_FAILED) die("segment map");
        if (ph->p_filesz > 0 && ph->p_memsz > ph->p_filesz) {
            if (!(prot & PROT_WRITE)) invalid_elf("non-writable ld.so BSS");
            uint8_t *bss  = base + (ph->p_vaddr - vmin) + ph->p_filesz;
            size_t   bsz  = ph->p_memsz - ph->p_filesz;
            size_t in_pg  = page_up((size_t)bss, page) - (size_t)bss;
            if (in_pg > bsz) in_pg = bsz;
            memset(bss, 0, in_pg);
            if (bsz > in_pg) {
                void *bss_map = mmap(bss + in_pg, page_up(bsz - in_pg, page), prot,
                                     MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
                if (bss_map == MAP_FAILED) die("BSS map");
            }
        }
    }

    size_t entry     = base_addr + eh->e_entry;
    size_t phdr_addr = 0;
    for (int i = 0; i < eh->e_phnum; i++) {
        const Elf64_Phdr *ph = (const Elf64_Phdr *)(fdata + eh->e_phoff + i * eh->e_phentsize);
        if (ph->p_type == PT_PHDR) { phdr_addr = base_addr + ph->p_vaddr; break; }
    }
    if (!phdr_addr) {
        for (int i = 0; i < eh->e_phnum; i++) {
            const Elf64_Phdr *ph = (const Elf64_Phdr *)(fdata + eh->e_phoff + i * eh->e_phentsize);
            if (ph->p_type == PT_LOAD && ph->p_offset <= eh->e_phoff &&
                eh->e_phoff + (size_t)eh->e_phnum * sizeof(Elf64_Phdr) <= ph->p_offset + ph->p_filesz) {
                phdr_addr = base_addr + ph->p_vaddr + (eh->e_phoff - ph->p_offset);
                break;
            }
        }
    }
    if (!phdr_addr) invalid_elf("ld.so program headers are not mapped");
    uint16_t phnum = eh->e_phnum, phent = eh->e_phentsize;
    munmap(fdata, st.st_size); close(fd);

    size_t  stksz = 16 * 1024 * 1024;
    uint8_t *stk  = mmap(NULL, stksz, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANON | MAP_STACK, -1, 0);
    if (stk == MAP_FAILED) die("stack");
    uint8_t *sp = stk + stksz;

#define STACK_NEEDS(n) do { if ((size_t)(sp - stk) < (n)) die("stack overflow"); } while(0)
#define PUSH_STR(s) ({ size_t _l = strlen(s)+1; STACK_NEEDS(_l); sp -= _l; memcpy(sp,(s),_l); (size_t)sp; })
#define PUSH_BYTES(src,n) do { STACK_NEEDS(n); sp -= (n); memcpy(sp,(src),(n)); } while(0)

    size_t plat_addr = PUSH_STR("aarch64");
    uint8_t rnd[16];
    fill_secure_random(rnd, sizeof(rnd));
    PUSH_BYTES(rnd, sizeof(rnd)); size_t rnd_addr = (size_t)sp;

    size_t envc = 0;
    while (envp[envc]) {
        if (envc >= MAX_ENV) die("environment too large (limit 4096)");
        envc++;
    }
    int trace_mode = argc > 1 && strcmp(argv[1], trace_marker) == 0;
    size_t user_arg_start = trace_mode ? 2 : 1;
    size_t user_arg_count = (size_t)argc - user_arg_start;
    int use_proc_exe_shim = proc_exe_shim[0] != '\0';
    size_t new_argc = 5 + (use_proc_exe_shim ? 2 : 0) + user_arg_count;

    if (new_argc >= MAX_ARGS) {
        die("too many arguments (limit 4096)");
    }
    if (envc >= MAX_ENV) {
        die("environment too large (limit 4096)");
    }

    size_t argv_a[MAX_ARGS];
    size_t argv_out = 0;
    argv_a[argv_out++] = PUSH_STR(ldso);
    argv_a[argv_out++] = PUSH_STR("--inhibit-cache");
    argv_a[argv_out++] = PUSH_STR("--library-path");
    argv_a[argv_out++] = PUSH_STR(library_path);
    if (use_proc_exe_shim) {
        argv_a[argv_out++] = PUSH_STR("--preload");
        argv_a[argv_out++] = PUSH_STR(proc_exe_shim);
    }
    argv_a[argv_out++] = PUSH_STR(target_exe);
    size_t execfn = argv_a[argv_out - 1];
    for (size_t i = 0; i < user_arg_count; i++)
        argv_a[argv_out++] = PUSH_STR(argv[i + user_arg_start]);
    if (argv_out != new_argc) invalid_elf("synthetic argv count mismatch");

    size_t envp_a[MAX_ENV];
    size_t env_out = 0;
    for (size_t i = 0; i < envc; i++) {
        if (has_env_name(envp[i], "LD_PRELOAD") ||
            has_env_name(envp[i], "LD_LIBRARY_PATH") ||
            has_env_name(envp[i], "GLIBC_LD_LIBRARY_PATH") ||
            has_env_name(envp[i], "LD_AUDIT") ||
            has_env_name(envp[i], "LD_DEBUG") ||
            has_env_name(envp[i], "LD_DEBUG_OUTPUT") ||
            has_env_name(envp[i], "LD_PROFILE") ||
            has_env_name(envp[i], "GLIBC_TUNABLES") ||
            strncmp(envp[i], "GLIBCX_", 7) == 0)
            continue;
        if (env_out >= MAX_ENV) die("environment too large (limit 4096)");
        envp_a[env_out++] = PUSH_STR(envp[i]);
    }
    const char *internal_env[] = {
        env_real_exe, env_wrapper_exe, env_app_id, env_proc_mode, env_tunables
    };
    for (size_t i = 0; i < sizeof(internal_env) / sizeof(internal_env[0]); i++) {
        if (env_out >= MAX_ENV) die("environment too large (limit 4096)");
        envp_a[env_out++] = PUSH_STR(internal_env[i]);
    }
    if (trace_mode) {
        if (env_out >= MAX_ENV) die("environment too large (limit 4096)");
        envp_a[env_out++] = PUSH_STR("LD_DEBUG=libs,files,versions");
    }

    /* Build auxv first so auxc is known for alignment calculation */
    size_t auxv[][2] = {
        {AT_PHDR,   phdr_addr}, {AT_PHENT, phent},   {AT_PHNUM, phnum},
        {AT_PAGESZ, page},      {AT_BASE,  base_addr},{AT_FLAGS, 0},
        {AT_ENTRY,  entry},     {AT_UID,   getuid()}, {AT_EUID,  geteuid()},
        {AT_GID,    getgid()},  {AT_EGID,  getegid()},
        {AT_HWCAP,  getauxval_from_envp(envp, AT_HWCAP)},
        {AT_HWCAP2, getauxval_from_envp(envp, AT_HWCAP2)},
        {AT_CLKTCK, (size_t)sysconf(_SC_CLK_TCK)},
        {AT_RANDOM, rnd_addr},
        {AT_SECURE, getauxval_from_envp(envp, AT_SECURE)},
        {AT_SYSINFO_EHDR, getauxval_from_envp(envp, AT_SYSINFO_EHDR)},
        {AT_EXECFN, execfn}, {AT_PLATFORM, plat_addr},
        {AT_NULL, 0},
    };
    size_t auxc = sizeof(auxv) / sizeof(auxv[0]);

    /* AArch64 ABI: sp must be 16-byte aligned at the synthetic entry point.
       Pre-align sp so that after all pushes sp ends up on a 16-byte boundary. */
    {
        size_t n_ptrs = 1               /* argc */
                      + new_argc + 1   /* argv + NULL */
                      + env_out + 1    /* envp + NULL */
                      + auxc * 2;      /* auxv pairs */
        size_t byte_total = n_ptrs * 8;
        /* align down so (sp - byte_total) is 16-byte aligned */
        sp = (uint8_t *)(((size_t)sp - byte_total) & ~(size_t)15) + byte_total;
    }

    PUSH_BYTES(auxv, auxc * 16);
    size_t zero = 0; PUSH_BYTES(&zero, 8);
    for (int i = (int)env_out - 1; i >= 0; i--) PUSH_BYTES(&envp_a[i], 8);
    PUSH_BYTES(&zero, 8);
    for (int i = (int)new_argc - 1; i >= 0; i--) PUSH_BYTES(&argv_a[i], 8);
    PUSH_BYTES(&new_argc, 8);
    if (((size_t)sp & 15) != 0) invalid_elf("synthetic AArch64 stack is misaligned");

    __asm__ volatile(
        "mov sp, %[sp]\n"
        "mov x0, sp\n"
        "mov x1, xzr\n"
        "mov x2, xzr\n"
        "mov x3, xzr\n"
        "mov x4, xzr\n"
        "mov x5, xzr\n"
        "mov x30, xzr\n"
        "br  %[entry]\n"
        : : [sp] "r"(sp), [entry] "r"(entry)
        : "x0","x1","x2","x3","x4","x5","x30","memory"
    );
    __builtin_unreachable();
}
C_CODE

    if [[ "$verbose" == true ]]; then
        echo "[glibcx] Compiling native Bionic-linked userland-exec wrapper."
    fi
    if ! clang -O2 -Wall -Wextra -Werror -fstack-protector-strong \
        "$wrapper_c" -o "$wrapper_bin" 2>&1; then
        echo "[glibcx] Error: Compilation failed. Is 'clang' installed?" >&2
        rm -rf "${staging_dir:?}"
        lock_release "$app_lock"
        lock_release "$registry_lock"
        lock_release "$target_lock"
        exit 1
    fi
    rm -f "$wrapper_c"
    chmod 700 "$wrapper_bin"

    local wrapper_hash target_size manifest_with_generation
    wrapper_hash=$(_sha256_file "$wrapper_bin")
    target_size=$(LC_ALL=C stat -c '%s' "$target_bin")
    if ! state_write_patch_manifest \
        "${staging_dir}/manifest.json" "$app_id" "$target_bin" "$orig_hash" \
        "$target_size" "$patched_fp" "$interpreter" "$max_req_glibc" \
        "$needed_libs" "$final_wrapper" "$wrapper_hash" "$library_path" "$inspection" \
        "$profile_json" "$verification_json" "$dependencies_json" "$repository_json" \
        "$proc_exe_mode"; then
        echo "[glibcx] Error: failed to create the app manifest." >&2
        rm -rf "${staging_dir:?}"
        lock_release "$app_lock"
        lock_release "$registry_lock"
        lock_release "$target_lock"
        exit 1
    fi
    chmod 600 "${staging_dir}/manifest.json"

    # Publish an immutable generation, then switch only the current symlink.
    # The previous generation remains intact and is restored on any later
    # publication failure.
    generation_number=$(state_next_generation_locked "$app_id")
    manifest_with_generation=$(mktemp "${staging_dir}/.manifest.generation.XXXXXX")
    if ! jq --argjson generation "$generation_number" '.generation = $generation' \
        "${staging_dir}/manifest.json" >"$manifest_with_generation"; then
        rm -f "$manifest_with_generation"
        rm -rf "${staging_dir:?}"
        lock_release "$app_lock"
        lock_release "$registry_lock"
        lock_release "$target_lock"
        echo "[glibcx] Error: failed to finalize the app generation manifest." >&2
        exit 1
    fi
    mv "$manifest_with_generation" "${staging_dir}/manifest.json"
    chmod 600 "${staging_dir}/manifest.json"
    generation_dir="${generations_dir}/${generation_number}"
    if ! mv "$staging_dir" "$generation_dir"; then
        lock_release "$app_lock"
        lock_release "$registry_lock"
        lock_release "$target_lock"
        echo "[glibcx] Error: failed to publish app generation." >&2
        exit 1
    fi
    registry_snapshot=$(mktemp "${CLI_STORAGE}/.registry.rollback.XXXXXX")
    cp -p "$REGISTRY_FILE" "$registry_snapshot"
    if ! _state_atomic_symlink "generations/${generation_number}" "$current_link"; then
        rm -rf "${generation_dir:?}"
        rm -f "$registry_snapshot"
        lock_release "$app_lock"
        lock_release "$registry_lock"
        lock_release "$target_lock"
        echo "[glibcx] Error: failed to activate app generation." >&2
        exit 1
    fi

    if ! state_register_app_locked "$target_bin" "$app_id" "$(state_current_manifest_path "$app_id")"; then
        if [[ -n "$previous_current" ]]; then
            _state_atomic_symlink "$previous_current" "$current_link" || true
        else
            rm -f "$current_link"
        fi
        rm -rf "${generation_dir:?}"
        rm -f "$registry_snapshot"
        lock_release "$app_lock"
        lock_release "$registry_lock"
        lock_release "$target_lock"
        echo "[glibcx] Error: failed to update the registry." >&2
        exit 1
    fi
    if ! state_refresh_aliases_locked "$bin_name" "$replace_legacy_alias"; then
        _state_commit_temp "$registry_snapshot" "$REGISTRY_FILE"
        registry_snapshot=""
        if [[ -n "$previous_current" ]]; then
            _state_atomic_symlink "$previous_current" "$current_link" || true
        else
            rm -f "$current_link"
        fi
        rm -rf "${generation_dir:?}"
        state_refresh_aliases_locked "$bin_name" false || true
        lock_release "$app_lock"
        lock_release "$registry_lock"
        lock_release "$target_lock"
        echo "[glibcx] Error: app state was published, but aliases could not be refreshed." >&2
        exit 1
    fi
    rm -f "$registry_snapshot"

    lock_release "$app_lock"
    lock_release "$registry_lock"
    lock_release "$target_lock"

    echo "[glibcx] Ready · $bin_name → $app_id · generation $generation_number"
    if [[ "$verbose" == true ]]; then
        echo "[glibcx] Wrapper: $final_wrapper (run 'glibcx setup' if ~/.glibcx/bin is not on PATH)"
    fi
}

cmd_rollback() {
    local target_bin="${1:-}" requested_generation="${2:-}"
    [[ -n "$target_bin" ]] || {
        echo "Usage: glibcx rollback <binary_path> [generation]" >&2
        return 1
    }
    init_env
    target_bin="$(realpath "$target_bin" 2>/dev/null || echo "$target_bin")"
    if [[ "$target_bin" == "${BIN_DIR}/"* ]]; then
        local alias_target
        alias_target=$(state_target_for_alias "$(basename "$target_bin")" 2>/dev/null || true)
        [[ -n "$alias_target" ]] && target_bin="$alias_target"
    fi

    local app_id app_root current_link current_target generation_number generation_dir
    local target_lock registry_lock app_lock registry_snapshot bin_name
    app_id=$(state_get_app_id "$target_bin")
    [[ -n "$app_id" ]] || {
        echo "[glibcx] Error: '$target_bin' is not registered." >&2
        return 1
    }
    bin_name=$(basename "$target_bin")
    app_root=$(state_app_root "$app_id")
    current_link="${app_root}/current"

    lock_acquire target_lock "$(lock_target_name "$target_bin")"
    lock_acquire registry_lock registry
    lock_acquire app_lock "$(lock_app_name "$app_id")"
    current_target=$(readlink "$current_link" 2>/dev/null || true)
    if [[ ! "$current_target" =~ ^generations/[1-9][0-9]*$ ]]; then
        echo "[glibcx] Error: current app generation is invalid." >&2
        lock_release "$app_lock"; lock_release "$registry_lock"; lock_release "$target_lock"
        return 1
    fi

    if [[ -n "$requested_generation" ]]; then
        [[ "$requested_generation" =~ ^[1-9][0-9]*$ ]] || {
            echo "[glibcx] Error: generation must be a positive integer." >&2
            lock_release "$app_lock"; lock_release "$registry_lock"; lock_release "$target_lock"
            return 1
        }
        generation_number=$((10#$requested_generation))
    else
        generation_number=$(find "${app_root}/generations" -mindepth 1 -maxdepth 1 -type d \
            -printf '%f\n' | awk -v current="${current_target##*/}" \
                '/^[1-9][0-9]*$/ && ($0 + 0) < (current + 0) {print}' \
            | LC_ALL=C sort -nr | sed -n '1p')
    fi
    generation_dir="${app_root}/generations/${generation_number}"
    if [[ -z "$generation_number" || ! -d "$generation_dir" \
        || "generations/${generation_number}" == "$current_target" \
        || ! -x "${generation_dir}/wrapper" ]] \
        || ! jq -e --arg id "$app_id" --arg path "$target_bin" \
            --argjson generation "$generation_number" '
                .schema == 3 and .generation == $generation
                and .app_id == $id and .target.path == $path
            ' "${generation_dir}/manifest.json" >/dev/null 2>&1; then
        echo "[glibcx] Error: no valid non-current generation '${generation_number:-<none>}' is available." >&2
        lock_release "$app_lock"; lock_release "$registry_lock"; lock_release "$target_lock"
        return 1
    fi

    registry_snapshot=$(mktemp "${CLI_STORAGE}/.registry.rollback.XXXXXX")
    cp -p "$REGISTRY_FILE" "$registry_snapshot"
    if ! _state_atomic_symlink "generations/${generation_number}" "$current_link" \
        || ! state_register_app_locked "$target_bin" "$app_id" "$(state_current_manifest_path "$app_id")" \
        || ! state_refresh_aliases_locked "$bin_name" false; then
        _state_atomic_symlink "$current_target" "$current_link" || true
        _state_commit_temp "$registry_snapshot" "$REGISTRY_FILE"
        registry_snapshot=""
        state_refresh_aliases_locked "$bin_name" false || true
        lock_release "$app_lock"; lock_release "$registry_lock"; lock_release "$target_lock"
        echo "[glibcx] Error: rollback publication failed; the previous generation was restored." >&2
        return 1
    fi
    rm -f "$registry_snapshot"
    lock_release "$app_lock"; lock_release "$registry_lock"; lock_release "$target_lock"
    echo "[glibcx] Rolled back '$bin_name' to generation $generation_number."
}

cmd_restore() {
    init_env
    local target_bin="${1:-}"
    if [[ -z "$target_bin" ]]; then
        echo "Usage: glibcx restore <binary_path>" >&2
        exit 1
    fi
    target_bin="$(realpath "$target_bin" 2>/dev/null || echo "$target_bin")"

    local app_id
    app_id=$(state_get_app_id "$target_bin")
    if [[ -z "$app_id" ]]; then
        echo "[glibcx] Error: '$target_bin' is not in the registry." >&2
        exit 1
    fi

    local bin_name
    bin_name="$(basename "$target_bin")"
    local target_lock registry_lock app_lock short_alias app_wrapper
    lock_acquire target_lock "$(lock_target_name "$target_bin")"
    lock_acquire registry_lock registry
    lock_acquire app_lock "$(lock_app_name "$app_id")"

    # Recheck after acquiring locks in case another process removed it first.
    if [[ "$(state_get_app_id "$target_bin")" != "$app_id" ]]; then
        lock_release "$app_lock"
        lock_release "$registry_lock"
        lock_release "$target_lock"
        echo "[glibcx] Error: registry entry changed while waiting for its lock." >&2
        exit 1
    fi

    short_alias="${BIN_DIR}/${bin_name}"
    app_wrapper=$(state_current_wrapper_path "$app_id")
    if [[ -f "$short_alias" && ! -L "$short_alias" && -f "$app_wrapper" ]] \
        && [[ "$(_sha256_file "$short_alias")" == "$(_sha256_file "$app_wrapper")" ]]; then
        rm -f "$short_alias"
    fi

    state_delete_app_locked "$target_bin"
    state_remove_app_files_locked "$app_id"
    state_refresh_aliases_locked "$bin_name" false

    lock_release "$app_lock"
    lock_release "$registry_lock"
    lock_release "$target_lock"
    echo "[glibcx] Unpatched '$target_bin' by removing its wrapper."
}

cmd_list() {
    init_env
    echo "[glibcx] Managed Binaries Registry:"
    local count=0
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        count=$((count + 1))
        local glibc patched_at fp current_fp status
        glibc=$(json_get_val "$path" "glibc_required")
        patched_at=$(json_get_val "$path" "patched_at")
        fp=$(json_get_val "$path" "patched_fingerprint")
        current_fp=$(_fingerprint "$path")
        if [[ ! -f "$path" ]]; then
            status="MISSING"
        elif [[ "$current_fp" != "$fp" ]]; then
            status="DRIFT (re-run: glibcx patch $path)"
        else
            status="OK"
        fi
        echo "  $path"
        echo "    status         : $status"
        echo "    glibc required : $glibc"
        echo "    patched at     : $patched_at"
    done < <(json_list_paths)
    if [[ "$count" -eq 0 ]]; then
        echo "  No patched binaries registered."
    fi
}

cmd_clean() {
    init_env
    if [[ "${1:-}" == "--cache" ]]; then
        local cache_entry confirmation cache_entries
        echo "[glibcx] Package-cache deletion set:"
        cache_entries=$(find "${CACHE_DIR}/apt" "${CACHE_DIR}/packages" \
            -mindepth 1 -maxdepth 1 -print 2>/dev/null || true)
        if [[ -z "$cache_entries" ]]; then
            echo "  (empty)"
            return 0
        fi
        sed 's/^/  /' <<<"$cache_entries"
        printf "[glibcx] Delete this cache? Type 'yes' to confirm: "
        if ! read -r confirmation; then
            echo
            echo "[glibcx] Cache deletion cancelled (no confirmation input)."
            return 1
        fi
        if [[ "$confirmation" != "yes" ]]; then
            echo "[glibcx] Cache deletion cancelled."
            return 1
        fi
        while IFS= read -r cache_entry; do
            [[ "$cache_entry" == "${CACHE_DIR}/apt/"* \
                || "$cache_entry" == "${CACHE_DIR}/packages/"* ]] || continue
            rm -rf "${cache_entry:?}"
        done <<<"$cache_entries"
        echo "[glibcx] Package cache removed. Active app state was not changed."
        return 0
    elif [[ $# -gt 0 ]]; then
        echo "Usage: glibcx clean [--cache]" >&2
        return 1
    fi
    echo "[glibcx] Scanning registry for stale entries..."
    local stale=0
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        if [[ ! -f "$path" ]]; then
            local bin_name
            bin_name="$(basename "$path")"
            echo "[glibcx] Removing stale entry: $path"
            cmd_restore "$path"
            stale=$((stale + 1))
        fi
    done < <(json_list_paths)
    if [[ "$stale" -eq 0 ]]; then
        echo "[glibcx] Registry is clean."
    else
        echo "[glibcx] Removed $stale stale entries."
    fi
}

cmd_info() {
    init_env
    local target_bin="${1:-}"
    if [[ -z "$target_bin" ]]; then
        echo "Usage: glibcx info <binary_path>" >&2
        exit 1
    fi
    target_bin="$(realpath "$target_bin" 2>/dev/null || echo "$target_bin")"
    local manifest_path
    manifest_path=$(state_get_manifest_path "$target_bin")
    if [[ -z "$manifest_path" || ! -f "$manifest_path" ]]; then
        echo "[glibcx] Error: '$target_bin' is not in the registry." >&2
        exit 1
    fi
    jq . "$manifest_path"
}

cmd_upgrade() {
    init_env
    local target_bin="${1:-}"
    if [[ -z "$target_bin" ]]; then
        echo "Usage: glibcx upgrade <binary_path>" >&2
        exit 1
    fi
    target_bin="$(realpath "$target_bin" 2>/dev/null || echo "$target_bin")"
    local manifest_path profile_id proc_exe_mode
    manifest_path=$(state_get_manifest_path "$target_bin")
    if [[ -z "$manifest_path" || ! -f "$manifest_path" ]]; then
        echo "[glibcx] Error: '$target_bin' is not in the registry. Use 'glibcx patch' first." >&2
        exit 1
    fi
    profile_id=$(jq -r '.runtime.profile_id' "$manifest_path")
    proc_exe_mode=$(jq -r '.wrapper.proc_exe_mode // "off"' "$manifest_path")
    echo "[glibcx] Re-patching '$target_bin'..."
    cmd_patch "$target_bin" --runtime "$profile_id" --proc-exe="$proc_exe_mode"
}

cmd_run() {
    local target_bin="${1:-}"
    if [[ -z "$target_bin" ]]; then
        echo "Usage: glibcx run <binary> [-- args...]" >&2
        exit 1
    fi
    shift
    [[ "${1:-}" == "--" ]] && shift
    target_bin=$(realpath "$target_bin" 2>/dev/null || echo "$target_bin")
    local app_id manifest_path wrapper_path
    if [[ ! -f "$REGISTRY_FILE" ]] \
        || ! jq -e '.schema == 3 and (.apps | type) == "object"' \
            "$REGISTRY_FILE" >/dev/null 2>&1; then
        echo "[glibcx] Error: no valid schema-3 registry; patch the target first." >&2
        exit 1
    fi
    app_id=$(state_get_app_id "$target_bin")
    manifest_path=$(state_get_manifest_path "$target_bin")
    if [[ -z "$app_id" || -z "$manifest_path" || ! -f "$manifest_path" ]]; then
        echo "[glibcx] Error: '$target_bin' is not registered; patch it first." >&2
        exit 1
    fi
    wrapper_path=$(jq -r '.wrapper.path // empty' "$manifest_path")
    if [[ ! -x "$wrapper_path" ]]; then
        echo "[glibcx] Error: registered wrapper is missing or not executable." >&2
        exit 1
    fi
    exec env \
        -u LD_PRELOAD \
        -u LD_LIBRARY_PATH \
        -u GLIBC_LD_LIBRARY_PATH \
        -u LD_AUDIT \
        -u LD_DEBUG \
        -u LD_DEBUG_OUTPUT \
        -u LD_PROFILE \
        -u GLIBC_TUNABLES \
        "$wrapper_path" "$@"
}
