# glibcx

[![CI](https://github.com/dsecurity49/glibcx/actions/workflows/ci.yml/badge.svg)](https://github.com/dsecurity49/glibcx/actions/workflows/ci.yml)

glibcx runs Linux AArch64 command-line tools inside Termux without a PRoot
container. It is meant for tools that publish glibc builds but no native
Android build.

The original binary is never modified. glibcx builds a small AArch64 wrapper
that loads the Termux glibc runtime in the same process and hands control to the
target program.

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/dsecurity49/glibcx/main/install.sh | bash
```

This installs the latest published release and the Termux packages it needs.
`v0.2.0` is the current stable release. The v0.3 development branch will not
install itself as a release until its production signing key and runtime assets
have been published.

## Quick start

During v0.3 development, import the glibc installation already provided by
`glibc-runner`:

```bash
glibcx runtime import-system
glibcx patch ./tool-linux-arm64 --runtime system
glibcx run ./tool-linux-arm64 -- --help
```

The `system` runtime is a development and recovery option. Stable automatic
installs will use signed managed runtimes instead of silently depending on a
mutable system installation.

glibcx can also find binaries from common package sources:

```bash
glibcx gh install sharkdp/fd --runtime system
glibcx npm install @anthropic-ai/claude-code --runtime system
glibcx fetch https://example.com/tool-linux-arm64.tar.gz --runtime system
glibcx intercept 'curl -fsSL https://example.com/install.sh | bash' --runtime system
```

For GitHub releases, glibcx prefers a native Android ARM64 asset. If none is
available, it looks for a Linux AArch64 glibc build and ignores musl, package,
checksum, and signature files. NPM tarballs are checked against the registry's
SHA-512 integrity value before extraction.

## Everyday commands

```bash
glibcx list
glibcx info <path>
glibcx doctor <path>
glibcx deps <path>
glibcx trace-libs <path> -- --help
glibcx upgrade <path>
glibcx rollback <path> [generation]
glibcx restore <path>
glibcx vendor <binary> <library>
glibcx runtime list
glibcx runtime verify <profile>
glibcx runtime install recommended
glibcx runtime remove <profile>
glibcx clean
glibcx clean --cache
glibcx self-update
```

- `doctor` reports target, runtime, wrapper, and dependency drift without
  changing state.
- `trace-libs` runs the target with loader tracing and saves observations; it
  does not add libraries to the dependency lock.
- `rollback` switches to a retained generation without rebuilding it.
- `restore` removes glibcx state and aliases. The target itself was never
  replaced.
- `clean --cache` shows what it will delete and asks for confirmation.

Run `glibcx help` for the complete command and option list. Add `--verbose` to
`patch` when you want the full ELF, symbol-version, and dependency audit.
`patch` also accepts `--dry-run`, `--offline`, `--runtime <profile>`, and
`--proc-exe=auto|on|off`. Proc-exe compatibility is automatic for recognized
PyInstaller executables. Its shim comes from the verified managed runtime.

The dependency lock covers libraries loaded by the ELF loader at startup. A
program may load more libraries later through its own plugin or extraction
logic; use `trace-libs` when that distinction matters.

## What v0.3 changes

- Each patched target gets its own app ID, so unrelated tools with the same
  filename no longer share wrappers or libraries.
- Repatching creates a new generation and changes one `current` symlink. An
  interrupted repatch cannot expose half-written state.
- Startup libraries are resolved from the signed Termux glibc repository,
  checked, and recorded with the app.
- Managed runtimes are verified with the glibcx release key before they become
  active.
- Both `glibcx run` and the native wrapper remove Android `LD_PRELOAD`,
  loader paths, and other unsafe loader variables before glibc starts.
- The launcher uses the device's actual page size and is designed for both
  4 KB and 16 KB AArch64 systems.

## Limits

- glibcx is not a container or a root filesystem. It does not emulate `/dev`,
  `/proc`, `/sys`, users, or services.
- It locks the libraries needed at startup. Plugins loaded later with `dlopen`,
  certificate stores, schemas, and other application data may still need manual
  setup.
- A binary that requires a newer glibc symbol than the selected runtime
  provides will not run.
- The wrapper remains `/proc/self/exe` by default. A signed runtime can provide
  a compatibility shim for known programs, but raw syscalls bypass that shim.
- Android behavior varies by version, phone vendor, kernel, and Termux build.
  A successful report for one device is evidence, not a guarantee for every
  device.

## Can you help test v0.3?

I only have access to a limited number of Android devices, so I’d appreciate
results from other phones. Every report helps, including repeated Android
versions and device models—vendors ship different kernels and security
policies.

The device test builds the checked-out commit, runs the Android-relevant test
suite, and creates a sanitized report:

```bash
bash ci/android_device_matrix.sh
```

If you have time to try it, attach the report to a device-test issue. Failed
tests are useful too. The setup steps, privacy details, and reviewed results are
in [the device-testing guide](docs/device-testing.md).

## Trust and release safety

Releases and managed runtimes are checked against a pinned OpenPGP key.
Checksums, GitHub attestations, and immutable releases provide additional
evidence but do not replace that key. `--force` does not bypass signature or
hash checks.

Dependency downloads use an isolated APT configuration and the pinned Termux
glibc repository key. Offline mode uses only previously verified files and does
not access the network.

The production release key is published at
[`keys/glibcx-release.gpg`](keys/glibcx-release.gpg). Its pinned primary
fingerprint is `EB13 DBFA 9354 A552 85CF 4B03 B525 5ACD 0708 C45E`; the release
signing subkey fingerprint is
`2D0A D952 32D1 E58A D13E 6B23 C49A 0B44 BF9F 2613`. Release-maintainer details
are in the [key ceremony](keys/CEREMONY.md) and
[managed-runtime build guide](profiles/README.md).

## Reported compatibility

These are historical results for the exact versions shown, not promises about
the latest release of each tool.

| Binary | Required glibc | Notes |
|---|---|---|
| Claude Code 2.1.224 | GLIBC 2.17 | Auto-restart tested on v0.2 |
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
| hurl 8.0.1 | GLIBC 2.34 | Needs `libxml2.so.2`, `libicuuc.so.72`, and `libicudata.so.72` |

## Benchmark note

On one Android 12 phone, v0.2 ran the tested `rg` and `fd` workloads close to
native Termux speed. Starting the same commands through Debian PRoot was much
slower in that setup. Results depend on the phone, filesystem, cache, tool
versions, and workload, so run `glibcx benchmark` on the device that matters to
you.

<details>
<summary>Measured v0.2 results from that phone</summary>

The phone was a vivo V2022 on Android 12/API 31. Each value is the average of
three trials; output went to `/dev/null`, and the PRoot measurements include
`proot-distro login` startup.

| Dataset and command | glibcx | Native Termux | Debian PRoot |
|---|---:|---:|---:|
| 1,000 files / 4.1 MB — `rg -l MATCHME` | 0.149s | 0.149s | 2.283s |
| 1,000 files / 4.1 MB — `fd -t f` | 0.116s | 0.121s | 1.029s |
| 200 files / 5.9 MB — `rg -l MATCHME` | 0.082s | 0.084s | 0.893s |
| 200 files / 5.9 MB — `fd -t f` | 0.083s | 0.076s | 0.724s |
| 2,164 files / 23.7 MB — `rg -l MATCHME` | 0.112s | 0.113s | 1.310s |
| 2,164 files / 23.7 MB — `fd -t f` | 0.098s | 0.080s | 0.756s |

</details>

## License

[MIT](LICENSE)
