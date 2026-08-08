# glibcx

[![CI](https://github.com/dsecurity49/glibcx/actions/workflows/ci.yml/badge.svg)](https://github.com/dsecurity49/glibcx/actions/workflows/ci.yml)

Run unmodified Linux glibc ARM64 binaries natively on Termux without PRoot, ptrace, or syscall interception overhead.

[Installation](#installation) • [Limitations / Scope](#limitations--scope) • [Usage](#usage) • [Verified binaries](#verified-binaries) • [Benchmark](#benchmark)

## How it works

1. The original binary remains untouched.
2. A native AArch64 C wrapper is compiled that uses `mmap` to load the Termux glibc loader (`ld-linux-aarch64.so.1`).
3. It jumps to the loader via inline assembly within the same process. No `execve` is called.

**The `/proc/self/exe` limitation:**
Because `execve` is never called, `/proc/self/exe` points to the compiled wrapper stub (`~/.glibcx/bin/<name>`), not the actual target binary. Re-executing `/proc/self/exe` still works in practice (e.g., Claude Code's auto-restart) because the wrapper is an idempotent entry point that re-runs the same load sequence. However, any program that resolves bundled resources or asset files relative to its binary directory will look in `~/.glibcx/bin/` and fail.

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/dsecurity49/glibcx/main/install.sh | bash
```

Installs prerequisites via `pkg`, downloads the latest release binary, and configures your PATH.

**Prerequisites (installed automatically):** `glibc-runner`, `patchelf`, `clang`, `jq`, `curl`, `file`, `binutils`, `xxd`, `nodejs`

**Compatibility:** Verified working on Android 12 (non-rooted, Termux).

## Limitations / Scope

- **Not a PRoot replacement.** This provides no isolated rootfs, no fake `/dev`, `/proc`, or `/sys`. It is strictly a glibc dynamic loader wrapper.
- **Does not vendor external dependencies.** glibcx resolves glibc. It does not resolve or fetch other non-glibc shared libraries (e.g., `libx264` for ffmpeg, `libxml2` for hurl). These are flagged as warnings at patch time but must be resolved manually.
- **Glibc version mismatches.** If a binary requires a newer `GLIBC_2.XX` symbol than what the Termux `glibc-repo` ships, it will fail at runtime. This is flagged at patch time.
- **Path resolution.** As noted above, programs locating assets relative to `/proc/self/exe` will resolve against the wrapper directory (`~/.glibcx/bin/`), not the real binary path.

## Features

* **Native execution.** Wrappers call the glibc dynamic linker directly with zero syscall interception.
* **Immune to Android 15 seccomp changes.** glibcx never uses `ptrace`. It is structurally unaffected by the Android 15 seccomp tightening (like `set_robust_list` filtering) that currently breaks `proot-distro` for many users.
* **Drift detection.** Every wrapper bakes in an `mtime+size` fingerprint. If the binary self-updates, you get a clear error instead of a silent crash.
* **Smart providers.** One command to install from GitHub Releases, NPM, arbitrary URLs, or intercepted install scripts.
* **GLIBC version audit.** Warns before patching if the binary requires a newer glibc than Termux provides.
* **Non-glibc dep advisory.** Flags external `NEEDED` libraries that will fail at runtime.

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

Downloads the tarball directly to bypass npm's OS restrictions. Checks for a native `android-arm64` optional dependency first and uses it if available.

### Direct URL

```bash
glibcx fetch https://example.com/tool-linux-arm64.tar.gz
```

### Install script interception

Monitors `$PATH` during any install script and auto-patches new glibc binaries:

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
glibcx restore <path>     # remove wrapper, restore original binary
glibcx upgrade <path>     # re-patch after a self-update
glibcx clean              # remove registry entries for deleted binaries
glibcx benchmark          # download 11 binaries and run 3-way speed comparison
```

## Verified binaries

| Binary | GLIBC req | Notes |
|---|---|---|
| Claude Code 2.1.224 | GLIBC_2.17 | Auto-restart tested and works via `/proc/self/exe` |
| Deno 2.9.5 | GLIBC_2.27 | Restart untested |
| fd 10.4.2 | GLIBC_2.18 | |
| ripgrep 15.2.0 | GLIBC_2.18 | |
| delta 0.19.2 | GLIBC_2.34 | |
| bottom 0.14.7 | GLIBC_2.34 | |
| ast-grep 0.45.0 | GLIBC_2.17 | |
| jnv 0.7.1 | GLIBC_2.34 | |
| television 0.15.9 | GLIBC_2.18 | |
| cargo-binstall 1.21.1 | GLIBC_2.34 | |
| cargo-llvm-cov 0.8.7 | GLIBC_2.34 | |
| xplr 1.1.0 | GLIBC_2.34 | |
| hurl 8.0.1 | GLIBC_2.34 | Requires vendoring `libxml2.so.2` |

## Benchmark

Three-way comparison: glibcx (glibc wrapper, zero ptrace) vs Termux native (Bionic, baseline) vs proot-distro (ptrace interception). Pattern: `MATCHME`, 3-run average including cold-cache run 1.

Datasets test different file-count and size profiles to rule out caching flukes: `benchdata` (1,000 uniform 4KB files), `benchdata_large` (200 x 300-line stress files), and `benchdata_real` (2,164 files, 24 MB, realistic mix of extensions from 100B to 32KB, ~8% match rate).

### `rg -l` (list matching files)

| Dataset | glibcx | Termux native | proot-distro | glibcx vs proot |
|---|---|---|---|---|
| benchdata (1,000 files, 4 MB) | 0.084s | 0.079s | 1.008s | **12.0x faster** |
| benchdata_large (200 files, 6 MB) | 0.079s | 0.079s | 0.987s | **12.5x faster** |
| benchdata_real (2,164 files, 24 MB, 8% hit) | 0.086s | 0.087s | 1.238s | **14.4x faster** |

### `fd -t f` (recursive file find)

| Dataset | fd | Termux native fd | proot-distro | glibcx vs proot |
|---|---|---|---|---|
| benchdata (1,000 files, 4 MB) | 0.091s | 0.086s | 0.882s | **9.7x faster** |
| benchdata_large (200 files, 6 MB) | 0.082s | 0.071s | 0.848s | **10.3x faster** |
| benchdata_real (2,164 files, 24 MB) | 0.086s | 0.084s | 0.893s | **10.4x faster** |

**glibcx overhead vs Termux native: statistically zero (0.99 to 1.15x).**  
**proot-distro overhead vs glibcx: 10 to 14x slower regardless of dataset shape.**

The gap is stable across all dataset shapes because `proot-distro` intercepts every `open()`, `read()`, `stat()`, and `getdents()` call via `ptrace`. For a few thousand files, this causes tens of thousands of intercepted syscalls. glibcx binaries syscall directly to the kernel, matching the path Bionic uses.

## License

This project is licensed under the [MIT License](LICENSE).
