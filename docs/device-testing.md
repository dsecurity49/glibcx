# Testing glibcx on Android

GitHub Actions can exercise the loader and wrapper on native AArch64 Linux, but
it cannot reproduce the Bionic environment of a phone. Android's seccomp
filters, SELinux policy, vendor kernel, Termux build, and memory page size are
all capable of changing the result. For that reason the repository keeps small,
reviewed summaries from real devices.

There is no requirement to cover every Android release before glibcx can be
released. I only have direct access to some configurations. A report from any
AArch64 phone is useful, including another run on a model already listed and a
run that fails.

## Running the test

The test needs build tools, the Termux glibc repository, and `glibc-runner`.
`glibc-repo` must be installed before the second package refresh, otherwise
`glibc-runner` will not be visible to `pkg`.

```bash
pkg update -y
pkg install -y git clang jq curl file binutils nodejs util-linux gnupg \
  xz-utils patchelf gzip glibc-repo
pkg update -y
pkg install -y glibc-runner
```

Test an exact commit so the result can be compared with the code later:

```bash
git clone https://github.com/dsecurity49/glibcx.git
cd glibcx

tested_commit=0123456789abcdef0123456789abcdef01234567
git checkout "$tested_commit"
bash ci/android_device_matrix.sh
```

The tracked worktree must be clean. The script builds the monolithic file and
checks it against the committed copy, then runs the state, wrapper, proc-exe,
integration, and live-repository tests. It uses temporary state and does not
install glibcx globally.

## Sharing the result

The script writes a file named `glibcx-device-report-*.tar.gz`. It removes
known Termux paths, Android UIDs, tokens, common identifiers, and private-key
patterns, and refuses to create an archive when it recognizes sensitive data.
That filter cannot know everything private on a phone. List and extract the
archive before uploading it:

```bash
archive=glibcx-device-report-api31-example-4096-20260812T000000Z.tar.gz
tar -tzf "$archive"
mkdir glibcx-report-check
tar -xzf "$archive" -C glibcx-report-check
```

Use the filename printed by the script for `archive`. The example name above
is only a placeholder.

If the contents look safe, attach the archive to a
[device-test issue](https://github.com/dsecurity49/glibcx/issues/new?template=device-test.yml)
and check the privacy box. The form does not ask you to copy facts out of
`report.json`. After submission, a workflow checks the archive and posts the
commit, device details, test results, and SHA-256 on the issue.

The workflow treats every upload as untrusted. It accepts only the six files
written by the test script, limits both compressed and expanded sizes, and
streams those files into its own temporary names instead of extracting paths
chosen by the archive. The validation job cannot edit issues; a separate job
with that permission receives only the bounded review text. A malformed or
unsafe submission is closed with the reason it was rejected.

A well-formed report whose tests failed is accepted because that result is
useful evidence. When a failure leads to a fix, the pull request can link to
the issue so the original device evidence remains available.

Reviewed summaries are committed under [`device-results/`](device-results/).
Raw logs remain on the issue or with the tester. CI checks the JSON schema and
rejects several private runtime fields before accepting a summary.

## Results so far

| Android | Device | Kernel | Page size | Termux | Commit | Result | Report |
|---|---|---|---:|---|---|---|---|
| 12 (API 31) | vivo V2022 | 4.14.180-perf+ | 4 KB | F-Droid 0.119.0-beta.3 | `aa1fd46` | Pass | Local run |
| 12 (API 31) | vivo V2022 | 4.14.180-perf+ | 4 KB | F-Droid 0.119.0-beta.3 | `df9b687` | Pass | [Issue #5](https://github.com/dsecurity49/glibcx/issues/5) |
| 14 (API 34) | Xiaomi 22101316I | 4.19.191-gcc12432b279b | 4 KB | F-Droid 0.119.0-beta.3 | `df9b687` | Pass | [Issue #3](https://github.com/dsecurity49/glibcx/issues/3) |
| 16 (API 36) | vivo V2541 | 5.15.197-android13 | 4 KB | F-Droid 0.119.0-beta.3 | `df9b687` | Pass | [Issue #4](https://github.com/dsecurity49/glibcx/issues/4) |

Each row covers the tests recorded in its JSON file for one device and one
commit. It is not a general promise about that Android version or every Linux
binary.
