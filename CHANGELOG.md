# Changelog

All notable changes to this project will be documented in this file.

## [v0.2.0] - 2026-08-08
### Added
- **Dependency Vendoring (`glibcx vendor`):** New command to easily vendor missing non-glibc `.so` libraries for a specific binary. The C wrapper now dynamically includes `~/.glibcx/lib/<binary>` in its `LD_LIBRARY_PATH`.
- **Self-Update (`glibcx self-update`):** New command to seamlessly download and apply the latest `glibcx` release directly from GitHub over the current executable.
- **`unpatch` Alias:** Added `glibcx unpatch` as an intuitive alias for `glibcx restore`.
- **Release Checksums:** SHA256 checksums are now generated and uploaded as release assets for the compiled `glibcx` binary.

### Changed
- **README Updates:** Cleaned up documentation, moved `/proc/self/exe` notes purely into the Limitations section, streamlined the Features list, and removed redundant navigation links.

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
