# Device testing

glibcx crosses two libc environments: Termux starts on Android's Bionic libc,
then the wrapper hands a Linux binary to an Android-patched glibc loader.
Standard Linux CI cannot reproduce Android's linker environment, SELinux
policy, seccomp filters, page size, or vendor kernel.

## Add a device result

I can test only a few Android devices myself. Community reports are how this
matrix grows, and repeated Android versions or phone models still matter
because vendors ship different kernels and security policies.

No Android version is singled out as more important than another, and a version
without a community report does not block a release. The table says exactly
what has been tested instead of implying coverage we do not have.

Install the regular test tools and the repository-enabling package first:

```bash
pkg update -y
pkg install -y git clang jq curl file binutils nodejs util-linux gnupg xz-utils \
  patchelf gzip glibc-repo
pkg update -y
pkg install -y glibc-runner
```

The second `pkg update` is required on a fresh Termux installation:
`glibc-repo` adds the repository that contains `glibc-runner`.

Clone the repository, then check out the exact commit you want to report:

```bash
git clone https://github.com/dsecurity49/glibcx.git
cd glibcx
git checkout <full-commit-sha>
```

Then run:

```bash
bash ci/android_device_matrix.sh
```

The script requires a clean tracked worktree. It builds glibcx, compares the
generated executable with the checked-in one, runs the Android-relevant tests
and live repository probe, and creates a
`glibcx-device-report-*.tar.gz` archive. It does not install glibcx globally or
modify fixture binaries.

The report redacts known home, Termux-prefix, repository paths, GitHub tokens,
IPv4 addresses, Android UIDs, common identifiers, and private-key patterns.
It refuses to create an archive if a recognized local path, token, Android UID,
or private-key pattern remains. Inspect the archive before sharing it, especially
if a command printed unusual environment or network details:

```bash
tar -tzf glibcx-device-report-*.tar.gz
tar -xzf glibcx-device-report-*.tar.gz
```

The archive can be attached to a device-test issue. Failed runs belong in the
matrix discussion too; add a short note about what happened. If the report led
to a fix, link the PR so future readers can follow the whole story.

## Accepted results

Reviewed reports are stored as small JSON records in
[`docs/device-results/`](device-results/).
Raw logs remain on the linked issue. CI validates the report schema and rejects
common private runtime fields before a result can be merged.

| Android | Device | Kernel | Page size | Termux | Commit | Result | Source |
|---|---|---|---:|---|---|---|---|
| 12 (API 31) | vivo V2022 | 4.14.180-perf+ | 4 KB | F-Droid 0.119.0-beta.3 | `aa1fd46` | Pass | Local test |

This is a record of real runs, not a claim that every binary works everywhere.
