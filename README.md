# glibcx

[![CI](https://github.com/dsecurity49/glibcx/actions/workflows/ci.yml/badge.svg)](https://github.com/dsecurity49/glibcx/actions/workflows/ci.yml)

Termux can already do a lot. I kept finding useful command-line tools that
published Linux AArch64 binaries but no Android build, even though the programs
themselves worked fine with glibc.

glibcx grew out of fixing that gap for Termux users. It runs those binaries
directly in Termux without making everyone set up a full PRoot distribution.

The original binary is never modified. glibcx builds a small AArch64 wrapper
that loads the Termux glibc runtime in the same process and hands control to the
target program.

## Current state

`v0.2.0` is the latest tagged version. It predates the v0.3 signing system and
is available from the
[GitHub release page](https://github.com/dsecurity49/glibcx/releases/tag/v0.2.0).

v0.3 is being tested now. The current `install.sh` expects the signed v0.3
asset set and cannot install the older v0.2 files. Until v0.3 is tagged, use the
source instructions below. The release instructions will use a versioned,
signed installer asset rather than piping the mutable `main` branch to Bash.

For a tagged release, download and verify the installer before executing it:

```bash
pkg install -y curl gnupg
tag=v0.3.0
base="https://github.com/dsecurity49/glibcx/releases/download/${tag}"
curl -fLO "$base/glibcx-release.gpg"
curl -fLO "$base/install.sh"
curl -fLO "$base/install.sh.asc"
expected_fingerprint=EB13DBFA9354A55285CF4B03B5255ACD0708C45E
observed_fingerprint=$(LC_ALL=C gpg --batch --show-keys --with-colons glibcx-release.gpg \
  | LC_ALL=C awk -F: '$1 == "fpr" {print toupper($10); exit}')
test "$observed_fingerprint" = "$expected_fingerprint" \
  && gpgv --keyring glibcx-release.gpg install.sh.asc install.sh \
  && bash install.sh
```

Before trusting a release for the first time, compare the primary fingerprint
shown below with the key you downloaded. Replace `v0.3.0` with the exact tag
you intend to install; do not replace it with `main`.

The immutable `v0.3.0-dry-run.2` release only proves the release workflow. It
uses a fixture key and glibcx does not trust it.

## Test v0.3 from source

Enable the glibc repository before installing `glibc-runner`:

```bash
pkg update -y
pkg install -y git clang jq curl file binutils nodejs util-linux gnupg \
  xz-utils patchelf gzip glibc-repo
pkg update -y
pkg install -y glibc-runner

git clone https://github.com/dsecurity49/glibcx.git
cd glibcx
./build.sh
cmp -s glibcx glibcx-bin && echo 'Source build matches the checked-in executable.'
```

Use the checked-in `./glibcx` from the repository. Nothing is installed
globally.

## Quick start

From a v0.3 source checkout, import the glibc installation provided by
`glibc-runner`, then select it explicitly:

```bash
./glibcx runtime import-system
./glibcx patch ./tool-linux-arm64 --runtime system
./glibcx run ./tool-linux-arm64 -- --help
```

The `system` runtime uses the local `glibc-runner` files and can change when its
packages change. It is the right choice while testing from source. Signed v0.3
runtimes will be inventoried and selected automatically.

glibcx can also find binaries from common package sources:

```bash
./glibcx gh install sharkdp/fd --runtime system
./glibcx npm install @anthropic-ai/claude-code --runtime system
./glibcx fetch https://example.com/tool-linux-arm64.tar.gz --runtime system
./glibcx intercept 'curl -fsSL https://example.com/install.sh | bash' --runtime system
```

For GitHub releases, glibcx prefers a native Android ARM64 asset. If one is not
available, it looks for a Linux AArch64 glibc build and ignores musl builds,
packages, checksums, and signatures. NPM tarballs are checked against the
registry's SHA-512 integrity value before extraction.

GitHub release assets are selected over HTTPS, but glibcx does not have an
upstream signing key or trusted digest for every third-party project. Treat
`glibcx gh install` as a convenience downloader, not as cryptographic
verification of another project's release. Use an upstream verification method
when that assurance matters.

## How it works

`glibcx patch` inspects the ELF without running it, then asks the selected glibc
loader to resolve its startup libraries. If a library is missing, glibcx can
fetch the matching package from the authenticated Termux glibc repository and
ask the loader again.

With a signed managed runtime, glibcx records the files the loader actually
opens, checks that they belong to the app or runtime, and stores their hashes
and package sources in the dependency lock. CWD-dependent library paths are
rejected because they could resolve differently the next time the tool runs.

The wrapper and libraries are stored in a new generation under
`~/.glibcx/apps/<app-id>/generations/`. Repatching switches one `current`
symlink, which keeps the previous working generation available for rollback.
The original target binary is never changed.

## Useful commands

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
- `clean --cache` previews cached data before asking for confirmation.

Run `glibcx help` for the complete command and option list. Add `--verbose` to
`patch` when you want the full ELF, symbol-version, and dependency audit.
`patch` also accepts `--dry-run`, `--offline`, `--runtime <profile>`, and
`--proc-exe=auto|on|off`. Proc-exe compatibility is automatic for recognized
PyInstaller executables. Its shim comes from the verified managed runtime.

The lock covers startup libraries only. Plugins or libraries loaded later with
`dlopen()` are observations, not automatically trusted additions; use
`trace-libs` to investigate them.

## Troubleshooting

- If Termux cannot find `glibc-runner`, install `glibc-repo`, run `pkg update`,
  and then install `glibc-runner` in a separate command.
- If a registered target changed after updating itself, run
  `glibcx upgrade <path>` to create a new generation.
- If startup resolution fails, run `glibcx doctor <path>` first. Use
  `glibcx deps <path> --refresh` only when you want to refresh authenticated
  repository metadata.
- `--offline` never downloads missing indexes, packages, profiles, or keys. A
  clean offline cache can therefore fail even when online resolution works.
- `libc.so.6: version 'LIBC' not found` usually means a Bionic preload reached
  glibc. v0.3 scrubs Termux loader variables automatically; include the
  `doctor` output and device report when reporting a recurrence.
- For a self-inspecting executable, leave `--proc-exe=auto` enabled. Forcing it
  off is useful for diagnosis but may break PyInstaller-style bundles.

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
- Android behavior varies by version, device vendor, kernel, and Termux build.
  A successful report for one device is evidence, not a guarantee for every
  device.

## Termux community testing

I am building glibcx to make more software usable for the Termux community. I
do not have a device lab, and Android behavior changes across vendors, kernels,
versions, and page sizes. Real phones catch things ordinary Linux CI cannot.

There is no unimportant report here. A different phone, another Android
version, a 16 KB page-size device, a repeated pass, or a new failure all add to
what the project actually knows.

The device test builds the checked-out commit, runs the Android-relevant test
suite, and creates a sanitized report:

```bash
bash ci/android_device_matrix.sh
```

If you want to add your device, the generated archive can be attached to a
device-test issue. Setup, privacy details, and reviewed results are in the
[device-testing guide](docs/device-testing.md).

Device reports are only one way to contribute. Compatibility notes, bug
reports, documentation fixes, repository research, and focused PRs all help.
When a particular Linux AArch64 tool fails, `glibcx doctor <path>` is a useful
starting point for an issue. If you also find the fix, linking the issue and PR
keeps the investigation easy for everyone to follow.

## Verification

Signed v0.3 releases and managed runtimes are checked against a pinned OpenPGP
key. Checksums, GitHub attestations, and immutable releases add evidence but do
not replace that key. `--force` does not bypass signature or hash checks.

Dependency downloads use an isolated APT configuration and the pinned Termux
glibc repository key. Offline mode uses only previously verified files and does
not access the network.

The glibcx release key is published at
[`keys/glibcx-release.gpg`](keys/glibcx-release.gpg). Its pinned primary
fingerprint is `EB13 DBFA 9354 A552 85CF 4B03 B525 5ACD 0708 C45E`; the release
signing subkey fingerprint is
`2D0A D952 32D1 E58A D13E 6B23 C49A 0B44 BF9F 2613`. Release details are in
the [key ceremony](keys/CEREMONY.md) and
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
| hurl 8.0.1 | GLIBC 2.34 | Needs `libxml2.so.2` and the transitive `libicuuc`/`libicudata` pair |

## Historical benchmark data

These measurements came from one Android 12 phone running v0.2. They are kept
as a reproducible reference, not as a general performance claim. Phone,
filesystem, cache, tool version, and workload all change the result; use
`glibcx benchmark` for a comparison on your own device.

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
