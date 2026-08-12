# glibcx

[![CI](https://github.com/dsecurity49/glibcx/actions/workflows/ci.yml/badge.svg)](https://github.com/dsecurity49/glibcx/actions/workflows/ci.yml)

Some command-line projects publish Linux AArch64 binaries but no Android
build. The processor is right for an ARM64 phone, but the binary still expects
glibc while Termux normally uses Android's Bionic libc.

I wrote glibcx to run those binaries without setting up a complete Linux
distribution. It leaves the original executable alone, builds a small native
wrapper, and runs the program with the Android-patched glibc from the Termux
glibc repository.

This is useful for self-contained command-line tools. It is not a container or
a Linux root filesystem. Programs that need system services, Linux users,
special device layouts, or undeclared data files may still be better served by
PRoot or another full environment.

## Installing

The signed installation format begins with v0.3.1. The commands below will
work once that release appears on the
[release page](https://github.com/dsecurity49/glibcx/releases). They download
the installer and public key from one versioned release, compare the key with a
fingerprint kept outside the download, verify the installer, and only then run
it.

```bash
pkg install -y curl gnupg

tag=v0.3.1
base="https://github.com/dsecurity49/glibcx/releases/download/${tag}"
curl -fLO "$base/glibcx-release.gpg"
curl -fLO "$base/install.sh"
curl -fLO "$base/install.sh.asc"

expected_fingerprint=EB13DBFA9354A55285CF4B03B5255ACD0708C45E
observed_fingerprint=$(LC_ALL=C gpg --batch --show-keys --with-colons \
  glibcx-release.gpg | LC_ALL=C awk -F: '$1 == "fpr" {print toupper($10); exit}')

verification=$(LC_ALL=C gpgv --status-fd 1 --keyring ./glibcx-release.gpg \
  install.sh.asc install.sh) \
  && signer=$(LC_ALL=C awk '$2 == "VALIDSIG" {print toupper($3); exit}' \
    <<<"$verification") \
  && primary=$(LC_ALL=C awk '$2 == "VALIDSIG" {print toupper($NF); exit}' \
    <<<"$verification") \
  && test "$observed_fingerprint" = "$expected_fingerprint" \
  && { test "$signer" = "$expected_fingerprint" \
    || test "$primary" = "$expected_fingerprint"; } \
  && bash install.sh
```

Restart the shell when the installer finishes, or reload its configuration.
Then install the signed runtime selected for this version:

```bash
source ~/.bashrc
glibcx runtime install recommended
```

Use a versioned release as the installer source, not a copy from `main`. The
`v0.3.0-dry-run.2` prerelease was made with a fixture key while testing the
release machinery. It is deliberately not trusted by glibcx.

## Patching a binary

Given a dynamically linked Linux ARM64 executable, `patch` inspects its ELF
metadata, resolves its startup libraries, and creates a registered wrapper:

```bash
glibcx patch ./tool-linux-arm64
~/.glibcx/bin/tool-linux-arm64 --help
```

`run` finds that registered wrapper without depending on
`~/.glibcx/bin` being in `PATH`:

```bash
glibcx run ./tool-linux-arm64 -- --help
```

The wrapper records enough information to notice when the original file has
changed. After an upstream self-update, publish a new generation with
`upgrade`. If that generation is bad, switch back to an older one:

```bash
glibcx upgrade ./tool-linux-arm64
glibcx rollback ./tool-linux-arm64
```

## Downloading a tool

The provider commands find a likely executable and then use the same patching
path:

```bash
glibcx gh install sharkdp/fd
glibcx npm install @anthropic-ai/claude-code
glibcx fetch https://example.com/tool-linux-arm64.tar.gz
glibcx intercept 'curl -fsSL https://example.com/install.sh | bash'
```

The NPM provider verifies the tarball against the SHA-512 integrity value from
the registry. The GitHub provider uses release assets over HTTPS, but glibcx
cannot know each upstream project's signing policy. `gh install` is a
downloader, not independent verification of the upstream release. The same
applies to URLs and installer commands passed to `fetch` and `intercept`.

## Commands worth knowing

```text
glibcx patch <path>                 inspect, resolve, verify, and register
glibcx run <path> -- <args>         run through the registered wrapper
glibcx upgrade <path>               patch a changed target into a new generation
glibcx rollback <path> [generation] activate a retained generation
glibcx restore <path>               remove glibcx state; leave the target alone
glibcx list                         list registered targets and drift
glibcx info <path>                  show one registry record
glibcx doctor <path>                diagnose ELF, runtime, and loader problems
glibcx deps <path>                  show the locked startup dependency graph
glibcx trace-libs <path> -- <args>  observe libraries loaded while running
glibcx vendor <path> <library>      add a DSO and rebuild the dependency lock
glibcx runtime list                 list installed runtime profiles
glibcx runtime verify <profile>     verify a runtime profile's inventory
glibcx clean                        remove stale registrations
glibcx self-update                  install the latest verified release
```

`glibcx help` has the complete list. Useful `patch` options include
`--dry-run`, `--offline`, `--verbose`, `--runtime <profile>`, and
`--proc-exe=auto|on|off`.

## Compatibility

The v0.3 managed runtime is built for Termux on AArch64, Android 12 through 16
(API 31 through 36), and Linux 4.14 or newer. A target must be a dynamically
linked, 64-bit little-endian AArch64 ELF using `ld-linux-aarch64.so.1` or
`ld.so` as its interpreter.

Static executables, Android/Bionic executables, other architectures, setuid
programs, and unknown interpreters are rejected. A valid ELF can still require
a newer glibc symbol than the selected runtime provides. Verification covers
the libraries loaded at startup; it cannot predict a later plugin, raw syscall,
or application-specific operation.

Physical-device reports currently cover Android 12, 14, and 16 on vivo and
Xiaomi phones with 4 KB pages. They show what passed on those exact devices and
commits, not what every Android build will do. The
[device-testing guide](docs/device-testing.md) contains the records and the
script for adding another result.

Older application results and benchmark measurements are kept in
[How glibcx works](docs/how-it-works.md). They record exact v0.2 tests rather
than making claims about current upstream versions.

## When something fails

Start with `glibcx doctor <path>`. It reads the target, runtime, dependency
lock, and loader result without running the program or changing its state.

If Termux cannot find `glibc-runner`, enable its repository before trying to
install it:

```bash
pkg install -y glibc-repo
pkg update -y
pkg install -y glibc-runner
```

An error containing `libc.so.6: version 'LIBC' not found` usually means that a
Bionic preload reached glibc. v0.3 removes Termux's inherited loader variables
in both the shell handoff and native wrapper. If the error returns, include the
`doctor` output and device details in the bug report.

PyInstaller and some other programs inspect `/proc/self/exe` for data appended
to their executable. The default `--proc-exe=auto` enables the managed
runtime's compatibility shim only for recognized targets. Turning it off can
be useful while diagnosing a problem, but may make such a program inspect the
wrapper instead of its original file.

Offline mode can use installed profiles and previously verified cache entries.
It cannot supply a runtime, repository index, or library that has never been
downloaded.

## Trust model

The release key is stored at
[`keys/glibcx-release.gpg`](keys/glibcx-release.gpg).

- Primary fingerprint: `EB13 DBFA 9354 A552 85CF 4B03 B525 5ACD 0708 C45E`
- Signing subkey: `2D0A D952 32D1 E58A D13E 6B23 C49A 0B44 BF9F 2613`

The primary fingerprint is pinned in the installer and client. This matters
because a key downloaded next to a signature cannot authenticate itself.
OpenPGP signatures are the release trust root. Checksums, GitHub attestations,
and immutable releases add useful evidence, but do not replace the pinned key.

Runtime dependency downloads use an isolated APT configuration and the pinned
Termux glibc repository key. `--force` does not disable signatures or hash
checks. [How glibcx works](docs/how-it-works.md) describes the resolver,
wrapper, state publication, and the limits of those checks.

## Building from source

The checked-in `glibcx` file is assembled from the modules under `src/`.
`build.sh` writes `glibcx-bin` without replacing it.

```bash
pkg update -y
pkg install -y git clang jq curl file binutils nodejs util-linux gnupg \
  xz-utils patchelf gzip glibc-repo
pkg update -y
pkg install -y glibc-runner

git clone https://github.com/dsecurity49/glibcx.git
cd glibcx
./build.sh
cmp -s glibcx glibcx-bin && echo 'Source build matches.'
```

For development, the package-managed Termux glibc tree can be imported as the
explicitly mutable `system` profile:

```bash
./glibcx runtime import-system
./glibcx patch ./tool-linux-arm64 --runtime system
```

That profile is a reference to files managed by `pkg`, not a signed immutable
runtime. A package update can make its recorded inventory stale.

## Documentation

- [How glibcx works](docs/how-it-works.md)
- [Testing on Android](docs/device-testing.md)
- [Release procedure](docs/releasing.md)
- [Version history](CHANGELOG.md)

## License

[MIT](LICENSE)
