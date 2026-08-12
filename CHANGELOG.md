# Changelog

All notable changes to this project will be documented in this file.

## [v0.3.0] - 2026-08-12

### Highlights

- Added signed, reproducible glibc runtimes and authenticated dependency
  downloads from the Termux glibc repository.
- Added per-app generations with atomic upgrades, rollback, isolated libraries,
  and migration from v0.2 state.
- Reworked dependency resolution to follow the selected glibc loader's real
  RPATH/RUNPATH behavior and lock the files it opens.
- Added `doctor`, `trace-libs`, managed-runtime commands, device-report tooling,
  and quieter default patch output.
- Added compatibility support for PyInstaller and other recognized
  self-inspecting executables.

### Safety and fixes

- Release installation and self-update now require trusted signatures and
  checksums.
- Android loader variables such as `LD_PRELOAD` are removed before glibc starts.
- Unsafe ELF paths, loader results, archives, packages, and symlinks are
  rejected.
- App-bundled libraries are found only through loader-visible paths such as
  `$ORIGIN`; the executable directory is no longer searched implicitly.
- Wrapper loading now accounts for the device page size and performs stricter
  mapping, alignment, entry-point, and argument validation.
- Setup no longer changes Android's phantom-process limit automatically; it
  asks first, defaults to no, and skips the option outside an interactive
  Android 12-or-newer Shizuku session.

## [v0.2.0] - 2026-08-08
### Added
- Added `glibcx vendor`, `self-update`, and `unpatch` as a `restore` alias.
- Added release checksum verification and SHA-512 verification for NPM downloads.

### Fixed
- Improved provider safety, explicit runtime selection, architecture checks, and
  handling of duplicate binary names.
- Rejected static and Bionic-linked targets before wrapper creation.
- Made wrapper loading page-size aware and protected generated C paths from
  unsafe input.
- Strengthened target drift detection and dependency classification.
- Fixed `restore` so it removes glibcx state without replacing the original
  binary.
- Stopped setup from modifying package-managed `glibc-runner` files.
- Added release build-drift checks and fixed benchmark and module-build issues.

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
