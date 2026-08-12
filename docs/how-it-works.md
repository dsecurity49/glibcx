# How glibcx works

Termux normally runs Android executables linked against Bionic. A Linux
AArch64 executable normally names the glibc dynamic linker in `PT_INTERP` and
expects glibc's library and syscall behavior. Matching the CPU architecture is
not enough to cross that boundary.

glibcx supplies an Android-patched glibc runtime and a small Bionic executable
that hands control to its loader. The original target stays untouched. This
document describes that handoff, the dependency record around it, and the
places where the result is still different from a Linux system.

## Inspecting a target

`glibcx patch` starts with `readelf -W` under `LC_ALL=C`. It checks the ELF
class, byte order, machine, interpreter, program headers, dynamic entries,
symbol-version requirements, RPATH, and RUNPATH. Static executables, Bionic
executables, non-AArch64 files, and objects without a supported interpreter are
rejected before a wrapper is built.

This inspection does not execute the target. The same is true of the loader's
`--verify` and `--list` modes later in the patch. Those calls show whether the
selected loader accepts the object and how it resolves the startup graph. They
do not run normal application logic, constructors, or later `dlopen()` calls.

## Runtime profiles

The managed runtime is built from the Android-patched
[`termux-pacman/glibc-packages`](https://github.com/termux-pacman/glibc-packages)
recipe. A generic Debian glibc tree is not substituted for it. The Termux
patches account for Android-specific syscall, filesystem, user, group, shared
memory, and other assumptions that ordinary distribution builds do not make.

glibc records several paths at build time, so a managed profile is built for
its final directory:

```text
$PREFIX/opt/glibcx/runtimes/<profile-id>
```

Copying an installed glibc tree to a different prefix is not equivalent. The
profile manifest records its exact loader and library directories, supported
symbol versions, Termux package identity, Android and kernel range, build
inputs, licenses, and a hash and mode for every file. Absolute symlinks and
links that escape the profile are rejected. Regular files use mode `0644` or
`0755`; other modes fail profile validation.

[`profiles/runtime-source.lock.json`](../profiles/runtime-source.lock.json)
pins the glibc source archive and checksum, Termux packaging commits, and
builder image digest. The corresponding source is published beside each
runtime bundle.

A source checkout can import `$PREFIX/glibc` as the `system` profile. That is a
reference to mutable package-managed files, not a copy. It is useful while
developing or diagnosing glibcx, but a Termux package update can invalidate its
recorded hashes. Automatic managed-runtime selection does not silently fall
back to it.

## Resolving startup libraries

The selected glibc loader is the final authority on search order. glibcx does
not assume that the executable's directory is searched, because glibc does not
do that unless an entry such as `$ORIGIN` makes it visible. It also does not
flatten RPATH and RUNPATH into one rule: legacy `DT_RPATH` can take precedence
over the supplied library path, while `DT_RUNPATH` is searched afterward.

Relative RPATH and RUNPATH entries depend on the process working directory.
That would let the same app generation load different bytes when started from
another directory, so glibcx rejects them. Absolute entries and `$ORIGIN`
expansions must remain inside the target, app, or profile roots allowed for the
generation.

When a startup SONAME is missing, the resolver reads the authenticated Termux
glibc repository metadata. The current repository identity is:

```text
URL:          https://packages-cf.termux.dev/apt/termux-glibc
Distribution: glibc
Component:    stable
Architecture: aarch64
Origin/Suite: termux-glibc glibc / glibc
Key:          CC72 CF8B A7DB FA01 8287 7D04 5A89 7D96 E57C F20C
```

The resolver verifies `InRelease`, then uses
`stable/binary-aarch64/Packages` and `stable/Contents-aarch64.gz` to find an
exact provider. Only canonical files below the repository's glibc `lib` and
`usr/lib` paths count. Prefixed lookalikes and ambiguous providers are
rejected. The downloaded `.deb` is checked against authenticated metadata and
extracted into app state; package maintainer scripts are not run.

The live repository check on 2026-08-09 exercised this distinction with
`libz.so.1`: the canonical rule selected `zlib-glibc` and ignored the unrelated
copy supplied by `box64-glibc`.

After each addition, glibcx asks the loader to list the graph again. Managed
profiles also supply a dependency-free loader-audit DSO. Its record of files
opened in the base namespace must agree with the loader listing, and every
resolved path must be absolute and inside an allowed root. The generation
stores file hashes, package provenance, repository metadata, and normalized
loader output. Compatibility schema 2 fixes the audit protocol at version 1
and reserves file descriptor 198 for that record; it also identifies the
proc-exe shim and glibc-hwcaps policy expected by the client.

This lock covers startup dependencies. A plugin chosen later from a config
file or loaded with `dlopen()` is outside it until it is examined and, when
appropriate, added with `glibcx vendor`. `trace-libs` can observe later loads,
but tracing alone does not change the lock.

## The native wrapper

Each app generation contains a Bionic-linked AArch64 wrapper generated by
`src/patch.sh`. It first checks the original target's device, inode, size, and
timestamps against the recorded drift fingerprint. A changed target is not run
until it has been patched again.

The wrapper then opens the profile's `ld.so`, validates its ELF layout, and maps
its loadable segments. It refuses malformed segments and writable-executable
loader mappings. It creates a new stack containing bounded copies of the
arguments and filtered environment, a fresh auxiliary vector, and fresh
`AT_RANDOM` bytes. The stack pointer is aligned to the AArch64 ABI before the
wrapper branches directly to the loader's entry point.

There is no `execve()` between the wrapper and `ld.so`. The loader receives
arguments equivalent to:

```text
ld.so --inhibit-cache --library-path <app-lib>:<profile-lib> [options] <target> ...
```

The optional arguments include the profile's glibc-hwcaps policy and, when
proc-exe compatibility is active, `--preload <profile-shim>`.

Before the branch, the wrapper discards inherited `LD_PRELOAD`,
`LD_LIBRARY_PATH`, `GLIBC_LD_LIBRARY_PATH`, `LD_AUDIT`, loader-debug variables,
`LD_PROFILE`, `GLIBC_TUNABLES`, and caller-supplied `GLIBCX_*` values. This is
necessary in Termux because a Bionic-linked preload such as
`libtermux-exec-ld-preload.so` cannot be loaded into glibc. Internal values and
profile-approved tunables are added after filtering.

## `/proc/self/exe` and self-inspecting programs

The wrapper and proc-exe shim coexist. They are not two versions of the same
implementation.

Since the wrapper branches to `ld.so` without replacing its process image, the
kernel's `/proc/self/exe` link normally names the wrapper. That behavior helps
programs which execute themselves: starting the wrapper again repeats the
controlled glibc handoff. It causes a different problem for self-inspecting
formats. A PyInstaller executable, for example, may open `/proc/self/exe` to
find an archive appended to the original target. The archive is not present in
the wrapper.

Managed profiles therefore include a glibc-linked interposition DSO. In
proc-exe mode it is passed directly to this loader invocation with
`ld.so --preload`; it is not inherited through ambient `LD_PRELOAD`. For the
exact `/proc/self/exe` and `/proc/<current-pid>/exe` paths, the shim currently
interposes the supported `readlink`, `open`, and `openat` families. Those calls
see the original target. If the program calls glibc `execve` or `execveat` on
that view or on the target path, the shim sends execution back through the
wrapper.

`--proc-exe=auto` enables this mode when glibcx finds a PyInstaller archive or
when the signed runtime profile names a matching target. Other binaries use
the wrapper-only behavior. `--proc-exe=on` requires a signed managed profile
with the verified shim; the mutable system profile is not accepted.

The shim is not a replacement for kernel behavior. A raw syscall, static code,
or an interface it does not interpose can still observe the wrapper. Auto mode
is deliberately narrow for that reason.

## App generations and rollback

State for a patched target is published as immutable numeric generations:

```text
~/.glibcx/apps/<app-id>/
├── generations/
│   ├── 1/
│   └── 2/
└── current -> generations/2
```

A new generation is built and verified in a private staging directory. glibcx
renames the completed directory into `generations/`, then atomically replaces
only the `current` symlink. The registry and command aliases are updated after
`current` points to valid state. If a later publication step fails, glibcx
restores the previous link and registry snapshot. This avoids trying to replace
a non-empty app directory and leaves the older generation available for
rollback.

Atomic rename prevents another process from observing a partly written
generation during normal operation. The project does not claim sudden-power-
loss durability. Bash has no native file-and-parent-directory `fsync`
operation, and glibcx does not include a native durability helper.

The app ID starts with a sanitized basename and a target-hash prefix. Every app
gets an unambiguous app-ID command. The short basename alias exists only while
one registered target owns that name.

## Release and runtime trust

The first installer command compares the downloaded public key with the
primary fingerprint printed in the README. Later release and catalog checks
use that pinned key. Accepting a key merely because it arrived beside a
signature would not authenticate either file.

Managed-runtime catalogs are signed and carry a monotonically increasing
catalog version, issue and expiry times, minimum glibcx version, signing-subkey
fingerprint, and profile compatibility schema. Runtime archives are signed as
whole files; their signed inner manifests provide the file inventory checked
after safe extraction. Installed profiles continue to work after a catalog
expires, but a network refresh fails until a newer valid catalog is available.

GitHub immutable releases, SHA-256 files, and artifact attestations make
accidental or unauthorized changes easier to detect. They are supplementary.
The pinned OpenPGP primary key and its certified signing subkey remain the
release trust root.

## Compatibility boundary

glibcx provides the loader, glibc runtime, and verified startup libraries. It
does not create Linux users, mount a different `/proc`, populate `/dev`, start
daemons, or install application data. Certificates, locale data, schemas,
plugins, and configuration must either exist in Termux or travel with the
program.

Android also remains the kernel. Seccomp filters, SELinux policy, vendor kernel
changes, and page size can affect a program after its loader checks pass.
Device tests are kept separately because ordinary Linux CI cannot reproduce
those conditions.

## Historical v0.2 results

These application results record the exact versions tested during v0.2. They
do not claim that a later release of the same program behaves identically.

| Binary | Required glibc | Notes |
|---|---|---|
| Claude Code 2.1.224 | GLIBC 2.17 | Auto-restart tested |
| Deno 2.9.5 | GLIBC 2.27 | Restart not tested |
| fd 10.0.0 | GLIBC 2.18 | |
| ripgrep 15.2.0 | GLIBC 2.18 | |
| bat 0.26.1 | GLIBC 2.18 | |
| eza 0.23.5 | GLIBC 2.18 | |
| delta 0.19.2 | GLIBC 2.18 | |
| bottom 0.14.7 | GLIBC 2.34 | |
| ast-grep 0.45.0 | GLIBC 2.18 | |
| sg (ast-grep companion) | GLIBC 2.17 | |
| jnv 0.7.1 | GLIBC 2.34 | |
| television 0.15.9 | GLIBC 2.18 | |
| cargo-binstall 1.21.1 | GLIBC 2.17 | |
| cargo-llvm-cov 0.8.7 | GLIBC 2.34 | |
| xplr 1.1.0 | GLIBC 2.39 | |
| hurl 8.0.1 | GLIBC 2.34 | Needs `libxml2`, `libicuuc`, and `libicudata` |

### Benchmark

This benchmark was run on one vivo V2022 with Android 12/API 31. Termux had
`ripgrep` 15.2.0, `fd` 10.4.2, `glibc-runner` 2.0-3 with glibc 2.43, and
`proot-distro` 5.5.0 running Debian 13. glibcx used the Linux ARM64 builds of
ripgrep 15.2.0 and fd 10.4.2; Debian supplied ripgrep 14.1.1 and fdfind 10.2.0.

Each value is the average of three trials. The execution order rotated between
glibcx, native Termux, and PRoot for each trial. Output was sent to `/dev/null`,
and the PRoot numbers include `proot-distro login` startup. Phone state,
storage, caches, tool versions, and workload all affect the result, so these
measurements establish only what happened in that test.

| Dataset and command | glibcx | Native Termux | Debian PRoot |
|---|---:|---:|---:|
| 1,000 files / 4.1 MB, `rg -l MATCHME` | 0.149s | 0.149s | 2.283s |
| 1,000 files / 4.1 MB, `fd -t f` | 0.116s | 0.121s | 1.029s |
| 200 files / 5.9 MB, `rg -l MATCHME` | 0.082s | 0.084s | 0.893s |
| 200 files / 5.9 MB, `fd -t f` | 0.083s | 0.076s | 0.724s |
| 2,164 files / 23.7 MB, `rg -l MATCHME` | 0.112s | 0.113s | 1.310s |
| 2,164 files / 23.7 MB, `fd -t f` | 0.098s | 0.080s | 0.756s |
