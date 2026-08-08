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
    init_env
    local target_bin="${1:-}"
    if [[ -z "$target_bin" || ! -f "$target_bin" ]]; then
        echo "[glibcx] Error: File '${target_bin:-<none>}' not found." >&2
        echo "Usage: glibcx patch <binary>" >&2
        exit 1
    fi

    target_bin="$(realpath "$target_bin")"
    if [[ "$target_bin" == *$'\n'* || "$target_bin" == *$'\r'* ]]; then
        echo "[glibcx] Error: paths containing newlines are unsupported." >&2
        exit 1
    fi

    if ! _is_aarch64_elf "$target_bin"; then
        echo "[glibcx] Error: '$target_bin' is not a valid 64-bit AArch64 ELF binary." >&2
        exit 1
    fi

    local interpreter
    interpreter=$(readelf -l "$target_bin" 2>/dev/null \
        | grep -oP 'Requesting program interpreter: \K[^]]+' || true)
    if [[ -z "$interpreter" ]]; then
        echo "[glibcx] Error: '$target_bin' has no dynamic interpreter (it is static or unsupported)." >&2
        echo "[glibcx] Static binaries do not need glibcx wrappers." >&2
        exit 1
    fi
    case "$(basename "$interpreter")" in
        ld-linux-aarch64.so.1|ld.so) ;;
        *)
            echo "[glibcx] Error: '$target_bin' does not use a supported glibc loader:" >&2
            echo "  $interpreter" >&2
            exit 1
            ;;
    esac

    local needed_libs
    needed_libs=$(readelf -d "$target_bin" 2>/dev/null | grep NEEDED | grep -oP '\[\K[^\]]+' || true)
    if grep -qx 'libc.so' <<< "$needed_libs"; then
        echo "[glibcx] Error: '$target_bin' links Android/Bionic libc.so, not glibc libc.so.6." >&2
        echo "[glibcx] Bionic binaries run directly and must not be patched." >&2
        exit 1
    fi

    local bin_name
    bin_name="$(basename "$target_bin")"

    # Reject wrapper name collision: two binaries with the same basename cannot
    # share ~/.glibcx/bin/<name> (and the vendored-lib dir ~/.glibcx/lib/<name>).
    local other_path
    while IFS= read -r other_path; do
        [[ -z "$other_path" ]] && continue
        if [[ "$other_path" != "$target_bin" && "$(basename "$other_path")" == "$bin_name" ]]; then
            echo "[glibcx] Error: '$bin_name' is already registered for a different binary:" >&2
            echo "  $other_path" >&2
            echo "[glibcx] Wrappers are keyed by basename in ~/.glibcx/bin/, so two binaries" >&2
            echo "[glibcx] with the same name cannot be patched together." >&2
            echo "[glibcx] To fix this, run: glibcx restore $other_path" >&2
            exit 1
        fi
    done < <(json_list_paths)

    echo "[glibcx] Auditing '$bin_name'..."

    # --- 1. NEEDED library audit ------------------------------------------------
    echo "[glibcx] Needed shared libraries:"
    if [[ -z "$needed_libs" ]]; then
        echo "  (none — unusual dynamically linked binary)"
    else
        local non_glibc=()
        while IFS= read -r lib; do
            if echo "$lib" | grep -qE "$_GLIBC_LIBS_RE"; then
                echo "  [glibc]  $lib"
            else
                echo "  [EXTERN] $lib  <-- NOT resolved by glibcx"
                non_glibc+=("$lib")
            fi
        done <<< "$needed_libs"
        if [[ ${#non_glibc[@]} -gt 0 ]]; then
            echo "[glibcx] WARNING: ${#non_glibc[@]} non-glibc dep(s) detected."
            echo "[glibcx]   These will fail at runtime unless vendored manually beside the binary."
            echo "[glibcx]   Missing: ${non_glibc[*]}"
        fi
    fi

    # --- 2. GLIBC version audit -------------------------------------------------
    local max_req_glibc
    max_req_glibc=$(readelf -V "$target_bin" 2>/dev/null \
        | grep -oE "GLIBC_[0-9]+\.[0-9]+" | sort -V | tail -n1 || echo "unknown")

    local have_glibc
    have_glibc=$(strings "${GLIBC_LIB_DIR}/libc.so.6" 2>/dev/null \
        | grep -oE "GLIBC_[0-9]+\.[0-9]+" | sort -V | tail -n1 || echo "unknown")

    echo "[glibcx] Binary requires GLIBC up to : $max_req_glibc"
    echo "[glibcx] Installed glibc provides up to: $have_glibc"

    if [[ "$max_req_glibc" != "unknown" && "$have_glibc" != "unknown" ]]; then
        # Compare versions — sort -V, pick highest; if req > have, warn
        local highest
        highest=$(printf '%s\n%s\n' "$max_req_glibc" "$have_glibc" | sort -V | tail -n1)
        if [[ "$highest" == "$max_req_glibc" && "$max_req_glibc" != "$have_glibc" ]]; then
            echo "[glibcx] WARNING: binary requires $max_req_glibc but installed glibc only provides $have_glibc."
            echo "[glibcx]   Symbol resolution may fail at runtime."
        fi
    fi

    # --- 3. Hash & Fingerprint (identity + metadata drift detection) ------------
    local orig_hash
    orig_hash=$(sha256sum "$target_bin" | awk '{print $1}')
    local patched_fp
    patched_fp=$(_fingerprint "$target_bin")

    # --- 4. Compile C userland-exec wrapper ------------------------------------
    local wrapper_c="${CLI_STORAGE}/bin/${bin_name}.c"
    local wrapper_bin="${CLI_STORAGE}/bin/${bin_name}"
    local wrapper_tmp="${wrapper_bin}.tmp.$$"
    local target_c_bytes ldso_c_bytes library_path_c_bytes
    target_c_bytes=$(_c_byte_array "$target_bin")
    ldso_c_bytes=$(_c_byte_array "$GLIBC_INTERPRETER")
    library_path_c_bytes=$(_c_byte_array "${GLIBC_LIB_DIR}:${CLI_STORAGE}/lib/${bin_name}")

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
    const Elf64_Phdr *first_load = NULL;
    for (int i = 0; i < eh->e_phnum; i++) {
        const Elf64_Phdr *ph = (const Elf64_Phdr *)(fdata + eh->e_phoff + i * eh->e_phentsize);
        if (ph->p_type == PT_LOAD) {
            if (ph->p_memsz < ph->p_filesz || ph->p_offset > (size_t)st.st_size ||
                ph->p_filesz > (size_t)st.st_size - ph->p_offset ||
                ph->p_vaddr > SIZE_MAX - ph->p_memsz)
                invalid_elf("invalid ld.so load segment");
            if (!first_load) first_load = ph;
            if (ph->p_vaddr < vmin) vmin = ph->p_vaddr;
            size_t e = ph->p_vaddr + ph->p_memsz;
            if (e > vmax) vmax = e;
            if (is_power_of_two(ph->p_align) && ph->p_align > max_align)
                max_align = ph->p_align;
        }
    }
    if (!first_load || vmax <= vmin) invalid_elf("ld.so has no loadable segments");
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
    int ufd = open("/dev/urandom", O_RDONLY);
    if (ufd >= 0) { read(ufd, rnd, 16); close(ufd); } else memset(rnd, 0x42, 16);
    PUSH_BYTES(rnd, sizeof(rnd)); size_t rnd_addr = (size_t)sp;

    size_t envc    = 0; while (envp[envc]) envc++;
    size_t new_argc = (size_t)argc + 3;

    if (new_argc >= MAX_ARGS) {
        die("too many arguments (limit 4096)");
    }
    if (envc >= MAX_ENV) {
        die("environment too large (limit 4096)");
    }

    size_t argv_a[MAX_ARGS];
    argv_a[0] = PUSH_STR(ldso);
    argv_a[1] = PUSH_STR("--library-path");
    argv_a[2] = PUSH_STR(library_path);
    argv_a[3] = PUSH_STR(target_exe);
    for (size_t i = 1; i < (size_t)argc; i++) argv_a[i + 3] = PUSH_STR(argv[i]);
    size_t execfn = argv_a[3];

    size_t envp_a[MAX_ENV];
    size_t env_out = 0;
    for (size_t i = 0; i < envc; i++) {
        if (strncmp(envp[i], "LD_PRELOAD=", 11) == 0) continue;
        if (strncmp(envp[i], "LD_LIBRARY_PATH=", 16) == 0) continue;
        if (env_out >= MAX_ENV) die("environment too large (limit 4096)");
        envp_a[env_out++] = PUSH_STR(envp[i]);
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

    echo "[glibcx] Compiling native wrapper (C userland-exec, Bionic-linked)..."
    if ! clang -O2 "$wrapper_c" -o "$wrapper_tmp" 2>&1; then
        echo "[glibcx] Error: Compilation failed. Is 'clang' installed?" >&2
        rm -f "$wrapper_c"
        rm -f "$wrapper_tmp"
        exit 1
    fi
    rm -f "$wrapper_c"
    mv -f "$wrapper_tmp" "$wrapper_bin"

    # --- 5. Registry entry (keyed by full path) --------------------------------
    json_update_entry "$target_bin" "$orig_hash" "$patched_fp" "$max_req_glibc"

    echo "[glibcx] Registered '$bin_name'. Wrapper: $wrapper_bin"
    echo "[glibcx] Add ~/.glibcx/bin to PATH if not already (run 'glibcx setup')."
}

cmd_restore() {
    init_env
    local target_bin="${1:-}"
    if [[ -z "$target_bin" ]]; then
        echo "Usage: glibcx restore <binary_path>" >&2
        exit 1
    fi
    target_bin="$(realpath "$target_bin" 2>/dev/null || echo "$target_bin")"

    local orig_hash
    orig_hash=$(json_get_val "$target_bin" "orig_hash")
    if [[ -z "$orig_hash" ]]; then
        echo "[glibcx] Error: '$target_bin' is not in the registry." >&2
        exit 1
    fi

    local bin_name
    bin_name="$(basename "$target_bin")"

    rm -f "${CLI_STORAGE}/bin/${bin_name}"
    json_delete_entry "$target_bin"
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
    echo "[glibcx] Scanning registry for stale entries..."
    local stale=0
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        if [[ ! -f "$path" ]]; then
            local bin_name
            bin_name="$(basename "$path")"
            echo "[glibcx] Removing stale entry: $path"
            rm -f "${CLI_STORAGE}/bin/${bin_name}"
            json_delete_entry "$path"
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
    if command -v jq >/dev/null 2>&1; then
        jq --arg p "$target_bin" '.[$p] // empty' "$REGISTRY_FILE"
    else
        python3 -c '
import json, sys
f, path = sys.argv[1:3]
with open(f) as fh: data = json.load(fh)
import pprint; pprint.pprint(data.get(path, {}))
' "$REGISTRY_FILE" "$target_bin"
    fi
}

cmd_upgrade() {
    init_env
    local target_bin="${1:-}"
    if [[ -z "$target_bin" ]]; then
        echo "Usage: glibcx upgrade <binary_path>" >&2
        exit 1
    fi
    target_bin="$(realpath "$target_bin" 2>/dev/null || echo "$target_bin")"
    if [[ -z "$(json_get_val "$target_bin" "orig_hash")" ]]; then
        echo "[glibcx] Error: '$target_bin' is not in the registry. Use 'glibcx patch' first." >&2
        exit 1
    fi
    echo "[glibcx] Re-patching '$target_bin'..."
    cmd_patch "$target_bin"
}

cmd_run() {
    local target_bin="${1:-}"
    if [[ -z "$target_bin" ]]; then
        echo "Usage: glibcx run <binary> [-- args...]" >&2
        exit 1
    fi
    shift
    [[ "${1:-}" == "--" ]] && shift
    # Scrub Bionic-injected vars before handing off to the glibc loader.
    # LD_PRELOAD from Termux (libtermux-exec-ld-preload.so) is a Bionic
    # library — the glibc ld.so will crash with "version 'LIBC' not found"
    # if it tries to load it. Same for LD_LIBRARY_PATH pointing at Bionic dirs.
    exec env -u LD_PRELOAD -u LD_LIBRARY_PATH \
        "$GLIBC_INTERPRETER" --library-path "$GLIBC_LIB_DIR" "$target_bin" "$@"
}
