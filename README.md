# glibcx

[![CI](https://github.com/dsecurity49/glibcx/actions/workflows/ci.yml/badge.svg)](https://github.com/dsecurity49/glibcx/actions/workflows/ci.yml)

Patches and runs glibc-linked Linux ARM64 CLI tools natively under Termux's Bionic environment.

## How it works

1. The original binary remains untouched.
2. A native AArch64 C wrapper is compiled that uses `mmap` to load the Termux glibc loader (`ld-linux-aarch64.so.1`).
3. It jumps to the loader via inline assembly within the same process. No `execve` is called.

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/dsecurity49/glibcx/main/install.sh | bash
```

This command installs the latest published release. The v0.3 development code
is not installable through it until the production release key and signed v0.3
assets are published; the installer intentionally fails closed when its trust
material is absent. Until then, `v0.2.0` remains the stable release.

For a published release, the installer adds prerequisites through `pkg`,
downloads the release binary, verifies its release assets, and configures your
PATH.

**Prerequisites (installed automatically):** `glibc-runner`, `clang`, `jq`, `curl`, `file`, `binutils`, `nodejs`, `util-linux`, `gnupg`

**Compatibility:** Manually tested on a non-rooted Android 12 Termux device.
This is not a guarantee for every Android, Termux, glibc, or target-binary version.

## Limitations / Scope

- **Not a PRoot replacement.** This provides no isolated rootfs, no fake `/dev`, `/proc`, or `/sys`. It is strictly a glibc dynamic loader wrapper.
- **Startup libraries only.** The authenticated resolver locks direct and transitive startup DSOs from the Termux-glibc repository. It cannot infer arbitrary plugins, later `dlopen` calls, certificate stores, schemas, or application data; use `glibcx vendor` for explicit additions.
- **Glibc version mismatches.** If a binary requires a newer `GLIBC_2.XX` symbol than what the Termux `glibc-repo` ships, it will fail at runtime. This is flagged at patch time.
- **Proc-exe limits.** Wrapper identity remains the default. Signed profiles may provide an optional libc-level shim for target-oriented `/proc/self/exe` reads and wrapper-routed self-reexec, but raw syscalls and static code bypass it.

## Features

* **Direct execution:** Calls the glibc dynamic linker in-process and does not use PRoot-style ptrace/syscall interception.
* **Clear scope:** Does not rely on PRoot's ptrace mechanism; Android and target-binary compatibility still varies by device and release.
* **Strict target checks:** Refuses static, non-AArch64, and Android/Bionic binaries; native Bionic binaries should run directly.
* **Drift detection:** Re-patch warnings if a binary is replaced or modified, even when an updater preserves its mtime.
* **Collision-safe state:** Wrappers, dependency locks, and vendored libraries are isolated by content-derived app ID, so binaries sharing a basename can coexist.
* **Loader verification:** `ld.so --verify` and `--list` validate the startup closure with a scrubbed environment and leak-resistant search path before state is published.
* **Authenticated dependencies:** Uses a dedicated isolated APT state, the pinned Termux repository key, InRelease-authenticated Packages/Contents indexes, exact package hashes, safe extraction, and a content-addressed offline cache.
* **Signed managed runtimes:** The client verifies a pinned OpenPGP signer, catalog expiry and rollback state, bundle and inner-manifest signatures, and every installed file before atomic publication.
* **Controlled tracing:** `trace-libs` executes only on explicit request, logs `LD_DEBUG=libs,files,versions` observations, and never silently adds them to the lock.
* **Page-size aware:** The launcher uses the device's runtime page size rather than assuming 4 KB. It is designed for 4 KB and 16 KB-page ARM64 devices; real 16 KB-device validation is still pending.
* **Dep advisories:** Audits GLIBC version requirements and flags missing external shared libraries.

## Usage

The managed-runtime client is implemented, but this development branch cannot
ship a production profile until the maintainer completes the offline release-key
ceremony and publishes signed runtime/source assets. Until then, local testing
uses `glibcx runtime import-system` plus an explicit `--runtime system`. Native
Android provider assets ignore that option.

### GitHub Releases

```bash
glibcx gh install sharkdp/fd --runtime system
glibcx gh install dandavison/delta --runtime system
glibcx gh install ast-grep/ast-grep --runtime system
glibcx gh install alexpasmantier/television --runtime system
```

Checks for a native `android-arm64` release asset first and symlinks it directly if found. Otherwise, fetches the Linux `aarch64-linux-gnu` glibc asset and patches it, skipping musl, deb, rpm, and signature variants.

### NPM packages

```bash
glibcx npm install @anthropic-ai/claude-code --runtime system
```

Downloads the tarball directly to bypass npm's OS restrictions, verifies its registry-provided SHA-512 integrity before extraction, and checks for a native `android-arm64` optional dependency first.

### Direct URL

```bash
glibcx fetch https://example.com/tool-linux-arm64.tar.gz --runtime system
```

### Install script interception

Monitors common binary directories (`~/.local/bin`, `~/bin`, `~/.bun/bin`, `~/.cargo/bin`, `~/.deno/bin`, `$PREFIX/bin`) during any install script and auto-patches new or replaced glibc binaries while ignoring Bionic/native ones:

```bash
glibcx intercept 'curl -fsSL https://bun.sh/install | bash' --runtime system
```

### Manual patch

```bash
glibcx runtime import-system                    # explicit mutable development profile
glibcx runtime install recommended              # signed production catalog/profile
glibcx runtime install <profile> --offline      # cached signed assets only
glibcx runtime verify system
glibcx patch ./my-binary --runtime system       # inspect, verify, register, compile
glibcx patch ./my-binary --runtime system --dry-run
glibcx patch ./my-binary --runtime system --offline
glibcx patch ./my-binary --runtime system --verbose # full dependency/version audit
glibcx run ./my-binary -- --help                # uses the registered runtime
glibcx doctor ./my-binary                       # read-only diagnostics
glibcx deps ./my-binary                         # locked transitive startup DSOs
glibcx deps ./my-binary --refresh               # authenticated metadata refresh + repatch
glibcx trace-libs ./my-binary -- --help         # executes and logs observed dynamic loads
```

The `system` runtime is intentionally classified as mutable development,
migration, and emergency state. Stable automatic patching installs/selects only
a compatible signed managed profile; it never silently falls back to `system`.
`--proc-exe=on` is accepted only when that signed profile contains its hashed
glibc shim; `auto` activates only a signed curated compatibility rule.

### Trust and offline behavior

Runtime releases and self-updates require the pinned glibcx release key; `--force`
never bypasses signatures or hashes. Dependency metadata trusts only the pinned
Termux-glibc repository key and an isolated source definition. Cached packages
are addressed by their authenticated SHA-256, and `--offline` performs no network
access. `clean --cache` displays and requires confirmation for the deletion set.

Repatches publish immutable numeric generations under each app ID, then
atomically switch its `current` symlink. Previous generations remain available
for `glibcx rollback`; routine patch output stays compact unless `--verbose` is
requested.

### Management

```bash
glibcx list               # all managed binaries with drift/version status
glibcx info <path>        # full registry entry
glibcx restore <path>     # remove the wrapper and registry entry (alias: unpatch; the original binary is never modified)
glibcx rollback <path> [generation] # activate the preceding or a named retained generation
glibcx vendor <bin> <lib> # vendor, hash, recursively inspect, and reverify a DSO
glibcx upgrade <path>     # re-patch after a self-update
glibcx clean              # remove registry entries for deleted binaries
glibcx clean --cache      # confirm removal of repository/package caches
glibcx benchmark          # download 11 binaries and run 3-way speed comparison
glibcx self-update [--force] # update glibcx to the latest release
```

## Reported compatibility

The entries below are historical manual test results for the listed versions,
not a guarantee for the latest release of each tool. A target can still fail if
it needs a newer glibc symbol or an external shared library.

| Binary | GLIBC req | Notes |
|---|---|---|
| Claude Code 2.1.224 | GLIBC_2.17 | Auto-restart tested and works via `/proc/self/exe` |
| Deno 2.9.5 | GLIBC_2.27 | Restart untested |
| fd 10.0.0 | GLIBC_2.18 | |
| ripgrep 15.2.0 | GLIBC_2.18 | |
| bat 0.26.1 | GLIBC_2.18 | |
| eza 0.23.5 | GLIBC_2.18 | |
| delta 0.19.2 | GLIBC_2.18 | |
| bottom 0.14.7 | GLIBC_2.34 | |
| ast-grep 0.45.0 | GLIBC_2.18 | |
| sg (ast-grep companion) | GLIBC_2.17 | |
| jnv 0.7.1 | GLIBC_2.34 | |
| television 0.15.9 | GLIBC_2.18 | |
| cargo-binstall 1.21.1 | GLIBC_2.17 | |
| cargo-llvm-cov 0.8.7 | GLIBC_2.34 | |
| xplr 1.1.0 | GLIBC_2.39 | |
| hurl 8.0.1 | GLIBC_2.34 | Requires vendoring `libxml2.so.2`, `libicuuc.so.72`, `libicudata.so.72` |

## Benchmarking

Run `glibcx benchmark` on your own device to compare compatible tools with
Termux-native and PRoot alternatives. Results depend on the phone, Android and
Termux versions, installed glibc, target tool, filesystem, dataset, and cache
state.

### Measured v0.2.0 result — one device

Measured on a vivo V2022 (Android 12 / API 31) with Termux packages
`ripgrep` 15.2.0, `fd` 10.4.2, `glibc-runner` 2.0-3 (GLIBC_2.43), and
`proot-distro` 5.5.0 running Debian 13. glibcx used Linux ARM64 builds of
ripgrep 15.2.0 and fd 10.4.2; Debian supplied ripgrep 14.1.1 and fdfind
10.2.0.

Each value is the average of three trials. Execution order rotated between
glibcx, native Termux, and PRoot for each trial. Commands wrote output to
`/dev/null`; the PRoot values include `proot-distro login` startup.

| Dataset / command | glibcx | Native Termux | Debian PRoot |
|---|---:|---:|---:|
| 1,000 files / 4.1 MB — `rg -l MATCHME` | 0.149s | 0.149s | 2.283s |
| 1,000 files / 4.1 MB — `fd -t f` | 0.116s | 0.121s | 1.029s |
| 200 files / 5.9 MB — `rg -l MATCHME` | 0.082s | 0.084s | 0.893s |
| 200 files / 5.9 MB — `fd -t f` | 0.083s | 0.076s | 0.724s |
| 2,164 files / 23.7 MB — `rg -l MATCHME` | 0.112s | 0.113s | 1.310s |
| 2,164 files / 23.7 MB — `fd -t f` | 0.098s | 0.080s | 0.756s |

This is a device-specific measurement, not a performance guarantee. Re-run
the benchmark on the target device and workload before making a deployment
decision.

## License

This project is licensed under the [MIT License](LICENSE).
