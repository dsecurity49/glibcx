# Device testing

glibcx crosses two libc environments: Termux starts on Android's Bionic libc,
then the wrapper hands a Linux binary to an Android-patched glibc loader. A
normal Linux CI runner cannot reproduce Android's linker environment, SELinux
policy, seccomp filters, or vendor kernel.

## Can you help test glibcx?

I only have access to a limited number of Android devices, so results from other
phones are genuinely useful. Repeated Android versions and phone models are
useful too; vendors ship different kernels and security policies.

From a clean checkout of the commit you want to test, install the test tools:

```bash
pkg update
pkg install git clang jq curl file binutils nodejs util-linux gnupg xz-utils \
  patchelf gzip glibc-repo glibc-runner
```

Then run:

```bash
bash ci/android_device_matrix.sh
```

The command builds glibcx, checks that the generated executable matches the
checked-in one, runs the Android-relevant integration tests, and creates a
`glibcx-device-report-*.tar.gz` archive. It does not install glibcx globally or
modify the binaries used as fixtures.

The report replaces home, Termux-prefix, and repository paths in logs. It does
not include device serial numbers, IP addresses, Android IDs, usernames, UIDs,
PIDs, or SSH keys. You can inspect the archive before sharing it:

```bash
tar -tzf glibcx-device-report-*.tar.gz
tar -xzf glibcx-device-report-*.tar.gz
```

Attach the archive to a device-test issue. A failed run is useful: include the
archive and say what you were doing when it failed. If you also have a fix, open
a PR and link it to the issue.

## Accepted results

Reviewed reports are stored as small JSON records in `docs/device-results/`.
Raw logs remain on the linked issue. CI validates the report schema and rejects
common private runtime fields before a result can be merged.

| Android | Device | Kernel | Page size | Termux | Commit | Result | Issue |
|---|---|---|---:|---|---|---|---|
| 12 (API 31) | vivo V2022 | 4.14.180-perf+ | 4 KB | F-Droid 0.119.0-beta.3 | `aa1fd46` | Pass | Maintainer test |

This table records where glibcx has actually been exercised. It is evidence,
not a promise that every binary will work on every device.
