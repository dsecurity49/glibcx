# glibcx

A native-speed `glibc` binary runner and patcher for Termux.

`glibcx` makes unmodified Linux `glibc`-linked ARM64 binaries run natively on Android's Bionic libc environment — **no PRoot**, no `ptrace`, no syscall interception overhead.

## How it works

1. **`patchelf --set-interpreter`** redirects the binary's ELF interpreter to Termux's glibc (`ld-linux-aarch64.so.1`)
2. **`patchelf --set-rpath`** redirects library resolution to `$PREFIX/glibc/lib`
3. A **compiled C wrapper** (userland-exec, not bash) is generated via `mmap` + inline assembly, which ensures `/proc/self/exe` survives — critical for self-restarting apps like Claude Code, Bun, or Node

## Features

* **Native execution** — no PRoot, no isolation, no phantom-process-killer battles (with Shizuku)
* **`/proc/self/exe` preserved** — C wrappers use `mmap` + inline assembly instead of `exec`, so the kernel always reports the correct executable path
* **Smart providers** — one command to install from GitHub Releases, NPM, arbitrary URLs, or intercepted install scripts
* **Drift detection** — wrappers check `mtime + size` against the registered fingerprint on every invocation; if the binary self-updated, you get a clear error
* **GLIBC version audit** — warns if a binary requires a newer glibc than what Termux's glibc-repo provides
* **Non-glibc dep advisory** — flags `NEEDED` libraries outside glibc (e.g. `libxml2.so.2`) before they fail at runtime

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/dsecurity49/glibcx/main/install.sh | bash
```

## Usage

### Smart Installation (GitHub Releases)

Automatically finds the correct `aarch64-unknown-linux-gnu` asset, excludes musl/deb/rpm/sig files:

```bash
glibcx gh install dandavison/delta              # git diff pager
glibcx gh install ast-grep/ast-grep            # structural code search
glibcx gh install alexpasmantier/television    # fuzzy finder TUI
```

### NPM Packages

Bypasses npm OS-restrictions by downloading the tarball directly. If a native `android-arm64` optional dependency exists, uses npm directly:

```bash
glibcx npm install @anthropic-ai/claude-code   # Claude Code CLI
```

### Direct URL Fetch

```bash
glibcx fetch https://example.com/tool-linux-arm64.tar.gz
```

### Install Script Interception

Monitors `$PATH` directories while running any `curl | bash` script, automatically patching new glibc binaries:

```bash
glibcx intercept 'curl -fsSL https://bun.sh/install | bash'
```

### Manual Patching

```bash
# Test without modifying the file:
glibcx run ./my-binary -- --version

# Permanently patch + install wrapper:
glibcx patch ./my-binary
~/.glibcx/bin/my-binary --version
```

### Management

```bash
glibcx list        # Show all patched binaries with drift/version status
glibcx info <path> # Show full registry entry
glibcx restore <path>  # Undo patch, restore original binary
glibcx upgrade <path>  # Re-patch after binary self-update
glibcx clean       # Remove stale entries for deleted binaries
```

### Benchmark

Installs 11 popular glibc-linked binaries absent from Termux repos, then runs a three-way speed comparison (glibcx vs Termux native vs proot-distro) across three dataset sizes:

```bash
glibcx benchmark
```

## Verified binaries

| Binary | GLIBC req | Status |
|---|---|---|
| Claude Code 2.1.224 | GLIBC_2.17 | Full auto-restart (self-spawn via `/proc/self/exe`) |
| Deno 2.9.5 | GLIBC_2.27 | Self-spawn works (no bash wrapper) |
| fd 10.4.2 | GLIBC_2.18 | Runs natively |
| ripgrep 15.2.0 | GLIBC_2.18 | Runs natively |
| bottom 0.14.7 | GLIBC_2.34 | Runs natively |
| delta 0.19.2 | GLIBC_2.34 | Runs natively |
| hurl 8.0.1 | GLIBC_2.34 | Requires vendoring `libxml2.so.2` (external dep) |
| jnv 0.7.1 | GLIBC_2.34 | Runs natively |
| ast-grep 0.45.0 | GLIBC_2.17 | Runs natively |
| cargo-llvm-cov 0.8.7 | GLIBC_2.34 | Runs natively |
| cargo-binstall 1.21.1 | GLIBC_2.34 | Runs natively |
| television 0.15.9 | GLIBC_2.18 | Runs natively |
| xplr 1.1.0 | GLIBC_2.34 | Runs natively |

## Performance benchmark

Three-way comparison: **glibcx** (glibc wrapper, zero ptrace) vs **Termux native rg** (Bionic, baseline) vs **proot-distro rg** (ptrace interception). Pattern: `MATCHME`, 3-run average including cold-cache run 1.

Datasets: `benchdata` (1,000 uniform 4KB files), `benchdata_large` (200 × 300-line stress files), and `benchdata_real` (2,164 files, 24 MB, realistic source-like mix of `.rs/.toml/.md/.json` from 100B–32KB, only ~8% containing the pattern — so `rg` has to scan file contents, not just the filesystem).

### `rg -l` (list matching files)

| Dataset | glibcx | Termux native | proot-distro | glibcx vs proot |
|---|---|---|---|---|
| benchdata (1,000 files, 4 MB) | 0.084s | 0.079s | 1.008s | **12.0× faster** |
| benchdata_large (200 files, 6 MB) | 0.079s | 0.079s | 0.987s | **12.5× faster** |
| benchdata_real (2,164 files, 24 MB, 8% hit) | 0.086s | 0.087s | 1.238s | **14.4× faster** |

### `fd -t f` (recursive file find)

| Dataset | fd | Termux native fd | proot-distro | glibcx vs proot |
|---|---|---|---|---|
| benchdata (1,000 files, 4 MB) | 0.091s | 0.086s | 0.882s | **9.7× faster** |
| benchdata_large (200 files, 6 MB) | 0.082s | 0.071s | 0.848s | **10.3× faster** |
| benchdata_real (2,164 files, 24 MB) | 0.086s | 0.084s | 0.893s | **10.4× faster** |

**glibcx overhead vs Termux native: 0.99–1.15× (pure run-to-run noise)**  
**proot-distro overhead vs glibcx: 10–14× regardless of dataset shape**

The gap is stable across every dataset because proot-distro intercepts each `open()`, `read()`, `stat()`, and `getdents()` call via `ptrace`. On a few thousand files that's tens of thousands of intercepted syscalls, each ~1ms of trapped overhead. glibcx binaries issue glibc syscalls directly to the real kernel — the identical path Bionic uses — so measured overhead vs Termux's own compiled binaries is statistically zero.

The `glibcx` C wrapper adds a single `mmap` of `ld-linux-aarch64.so.1` (stays in page cache after first run) plus a few segment maps and an inline `br` — no `exec`, no `ptrace`, no filesystem virtualization.

## License

This project is licensed under the [MIT License](LICENSE).
