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

Installs prerequisites via `pkg`, downloads the latest release binary, and configures your PATH.

**Prerequisites (installed automatically):** `glibc-runner`, `clang`, `jq`, `curl`, `file`, `binutils`, `nodejs`

**Compatibility:** Manually tested on a non-rooted Android 12 Termux device.
This is not a guarantee for every Android, Termux, glibc, or target-binary version.

## Limitations / Scope

- **Not a PRoot replacement.** This provides no isolated rootfs, no fake `/dev`, `/proc`, or `/sys`. It is strictly a glibc dynamic loader wrapper.
- **Does not fetch external dependencies.** glibcx only resolves the glibc loader itself. Other non-glibc shared libraries (e.g., `libxml2` for hurl) are never downloaded automatically — they are flagged as warnings at patch time, and you must supply them yourself via `glibcx vendor <binary> <lib1.so> [lib2.so...]`, which copies them into the wrapper's library path (`~/.glibcx/lib/<binary>`). Without them the binary fails at runtime.
- **Glibc version mismatches.** If a binary requires a newer `GLIBC_2.XX` symbol than what the Termux `glibc-repo` ships, it will fail at runtime. This is flagged at patch time.
- **Path resolution.** Programs locating their assets relative to `/proc/self/exe` will resolve against the wrapper directory (`~/.glibcx/bin/`), not the real binary path, because the loader is entered in-process (no `execve`).

## Features

* **Direct execution:** Calls the glibc dynamic linker in-process and does not use PRoot-style ptrace/syscall interception.
* **Clear scope:** Does not rely on PRoot's ptrace mechanism; Android and target-binary compatibility still varies by device and release.
* **Strict target checks:** Refuses static, non-AArch64, and Android/Bionic binaries; native Bionic binaries should run directly.
* **Drift detection:** Re-patch warnings if a binary is replaced or modified, even when an updater preserves its mtime.
* **Page-size aware:** The launcher uses the device's runtime page size rather than assuming 4 KB. It is designed for 4 KB and 16 KB-page ARM64 devices; real 16 KB-device validation is still pending.
* **Dep advisories:** Audits GLIBC version requirements and flags missing external shared libraries.

## Usage

### GitHub Releases

```bash
glibcx gh install sharkdp/fd
glibcx gh install dandavison/delta
glibcx gh install ast-grep/ast-grep
glibcx gh install alexpasmantier/television
```

Checks for a native `android-arm64` release asset first and symlinks it directly if found. Otherwise, fetches the Linux `aarch64-linux-gnu` glibc asset and patches it, skipping musl, deb, rpm, and signature variants.

### NPM packages

```bash
glibcx npm install @anthropic-ai/claude-code
```

Downloads the tarball directly to bypass npm's OS restrictions, verifies its registry-provided SHA-512 integrity before extraction, and checks for a native `android-arm64` optional dependency first.

### Direct URL

```bash
glibcx fetch https://example.com/tool-linux-arm64.tar.gz
```

### Install script interception

Monitors common binary directories (`~/.local/bin`, `~/bin`, `~/.bun/bin`, `~/.cargo/bin`, `~/.deno/bin`, `$PREFIX/bin`) during any install script and auto-patches new or replaced glibc binaries while ignoring Bionic/native ones:

```bash
glibcx intercept 'curl -fsSL https://bun.sh/install | bash'
```

### Manual patch

```bash
glibcx patch ./my-binary          # audit, register, compile wrapper
glibcx run ./my-binary -- --help  # ephemeral trial run, no file changes
```

### Management

```bash
glibcx list               # all managed binaries with drift/version status
glibcx info <path>        # full registry entry
glibcx restore <path>     # remove the wrapper and registry entry (alias: unpatch; the original binary is never modified)
glibcx vendor <bin> <lib> # copy external .so files into the wrapper's library path
glibcx upgrade <path>     # re-patch after a self-update
glibcx clean              # remove registry entries for deleted binaries
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
