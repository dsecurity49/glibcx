# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

- Added schema-3 state with immutable per-app generations, an atomically switched `current` symlink, rollback, content-derived app IDs, transaction-ordered collision-safe aliases, `flock` locking, atomic registry writes, and recoverable v0.2 migration.
- Added explicit mutable system runtime import/list/verify/remove commands; automatic selection no longer silently treats the system installation as a production profile.
- Replaced authoritative `file` parsing with a reusable `readelf -W` inspector and added read-only `doctor` diagnostics.
- Hardened the native wrapper with `--inhibit-cache`, broader environment isolation, checked secure random auxv data, W+X/alignment/entry validation, and stricter compiler warnings.
- Added sanitized loader `--verify`/`--list` gates, resolution-root enforcement, and hashed direct/transitive startup dependency locks.
- Moved wrappers and vendored DSOs into isolated app-ID state; identical or same-basename targets can coexist safely.
- Added fixture tests for state migration, ELF inspection, runtime drift, loader failure, dependency locking, and real Termux wrapper execution.
- Added signed managed-runtime catalog/install support with pinned OpenPGP trust, exact catalog signing-subkey binding, minimum-client and compatibility-schema gates, catalog expiry and rollback protection, dual bundle/manifest signatures, safe extraction, per-file verification, offline reuse, and atomic installation/removal.
- Added deterministic profile preparation and complete release-asset assembly (binary, nested runtime signatures, catalog, corresponding source, checksum, and exported public key) with ephemeral-key CI coverage; production publication remains disabled until maintainer key provisioning.
- Added an isolated authenticated Termux-glibc repository resolver using signed InRelease metadata, verified Packages/Contents indexes, deterministic SONAME lookup, exact `.deb` hashes, safe symlink-chain extraction, and package/repository provenance locks.
- Added optional profile-provided `/proc/self/exe` compatibility plumbing and a glibc shim source for read/open target views plus wrapper-routed self-reexecution.
- Added controlled `trace-libs` execution through an internal wrapper channel; caller-supplied loader debug variables remain scrubbed.
- Hardened provider extraction against traversal, hard links, special files, escaping symlinks, control-character paths, and NPM `bin` symlink escapes.
- Self-update and the bootstrap installer now require both checksums and signatures rooted in the pinned production key; `--force` cannot bypass trust checks.
- Added a separate live Termux repository contract probe and concise default patch output with a `--verbose` audit mode.

## [v0.2.0] - 2026-08-08
### Added
- **`glibcx vendor`:** copy external `.so` libs into `~/.glibcx/lib/<binary>`, which the C wrapper adds to `LD_LIBRARY_PATH`. Resolves wrapper paths, and refuses non-AArch64 / non-shared-object files.
- **`glibcx self-update [--force]`:** replaces the running executable with the latest release; `unpatch` added as a `restore` alias.
- **Release checksums:** CI uploads `glibcx.sha256`; both `install.sh` and `self-update` verify it before installing, and refuse unverified releases unless `--force` is passed (the flag is now actually parsed).
- **NPM tarball verification:** direct NPM downloads now require and verify the registry's SHA-512 `dist.integrity` value before extraction.

### Fixed
- **Interception:** Bionic binaries (bare `libc.so`) are no longer mistaken for glibc builds; snapshot lines include mtime, so replaced/updated executables are detected too.
- **Provider safety:** mixed-architecture downloads are skipped cleanly, and NPM package `bin` paths cannot escape the package installation directory.
- **Explicit provider runtimes:** `fetch`, `gh install`, `npm install`, and `intercept` forward `--runtime <id>` to every glibc binary they patch; native Android assets remain direct installs.
- **Name collisions:** patching two binaries with the same basename (shared `~/.glibcx/bin/<name>` and `~/.glibcx/lib/<name>`) is now rejected with a clear error.
- **Patch pipeline:** non-AArch64 ELF files are rejected up front, and registry entries are only written after the wrapper compiles successfully.
- **Target validation:** static executables and Bionic-linked Android binaries are refused instead of generating wrappers that cannot run.
- **Wrapper portability:** loader mappings use the runtime page size and ELF alignment, removing the former 4 KB-page assumption on ARM64 Android devices.
- **Wrapper safety:** paths are emitted as C byte arrays, so quotes and backslashes cannot corrupt generated C source; newline-containing paths are rejected explicitly.
- **Drift detection:** records device, inode, size, mtime, and ctime to catch in-place updates that preserve mtime.
- **Setup safety:** no longer alters the package-managed `glibc-runner` `libc.so` linker script.
- **Release integrity:** CI rebuilds `glibcx` from `src/` before publishing and rejects committed executables that are out of sync with source.
- **Audit accuracy:** the NEEDED-library classifier is anchored to real glibc names (no more `libcrypto`/`libmagic` false positives).
- **Restore semantics:** `glibcx restore` no longer copies a backup over the binary (it was never modified) — it just removes the wrapper and registry entry, so a self-updated binary can never be downgraded.
- **Benchmark:** 11-tool count now correct in banner/help; "Termux native" timings no longer measure the wrappers themselves; fixed the `proot-distro` presence check.
- **Build:** `build.sh` enforces a newline between modules to prevent token-merging syntax errors.

## [v0.1.2] - 2026-08-08
### Fixed
- **`cmd_gh` Asset Priority:** `glibcx gh install` now correctly prefers native `android-arm64` assets (bypassing the patch process) and only falls back to fetching and patching Linux `aarch64` glibc builds when a native build isn't found. This mirrors the `npm` provider logic.
- **C Loader Array Overflow:** Added strict bounds checking on `MAX_ARGS` and `MAX_ENV` (4096) before populating arrays. Exits cleanly with an error message instead of causing silent stack corruption if limits are exceeded.
- **Documentation:** Major rewrite of the README. Restored full 3-dataset benchmark tables for proof of consistency, corrected technical inaccuracies surrounding `execve` and `/proc/self/exe`, and clearly documented project limitations.

## [v0.1.1] - 2026-08-08
### Added
- **CI / GitHub Actions:** Automated shell linting (`shellcheck`, `bash -n`), C wrapper syntax checking, and a comprehensive end-to-end integration test (`fd` execution and drift detection) running on `ubuntu-26.04-arm`.
- **Release Automation:** CI now auto-publishes the `glibcx` binary on new tags. `install.sh` updated to download directly from release assets rather than raw source.

### Fixed
- **`cmd_run` Env Leak:** `glibcx run` now safely scrubs `LD_PRELOAD` and `LD_LIBRARY_PATH` to prevent Bionic library injection crashes.
- **Stack Alignment:** Fixed the math behind AArch64 ABI 16-byte stack alignment in the C wrapper.

## [v0.1.0] - 2026-08-07
- Initial release.
- Native C-wrapper (`mmap` + inline assembly) for Termux.
- Providers for `gh`, `npm`, `fetch`, and `intercept`.
- Complete test coverage for popular glibc binaries (`fd`, `rg`, `claude-code`, etc.).
