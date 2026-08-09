# Building a managed runtime

This directory contains the scripts and pinned inputs used to build a glibcx
runtime release.

## Why the final path matters

The runtime comes from the Android-patched
`termux-pacman/glibc-packages` recipe. It is built directly for:

```text
$PREFIX/opt/glibcx/runtimes/<profile-id>
```

glibc stores its prefix, loader location, system directories, and configuration
paths at build time. Copying an existing glibc tree into that directory does not
produce the same runtime.

`runtime-source.lock.json` pins the glibc recipe, Termux build framework, GNU
glibc source archive, and source hash. Update those values deliberately for a
new profile; do not build a release from a moving branch or container tag.

## What the build keeps

The release artifact includes:

- the runtime payload and complete file inventory;
- the exact upstream source archive and hash;
- the pinned Termux and glibc-packages commits and patches;
- the builder image digest and toolchain description;
- applicable licenses; and
- enough source and build material to reproduce the package.

Regular files in a profile use mode `0644` or `0755`. Symlinks must resolve
inside the profile. The `/proc/self/exe` shim is built as a glibc DSO in the
same pinned builder as glibc and included in the signed inventory. It supports
self-inspecting executables such as PyInstaller bundles.

`prepare-profile.sh` inventories an unsigned payload. `package-release.sh`
adds the corresponding-source bundle and creates the ten signed release assets.
Neither script creates or imports production key material.

## Key boundary

Create the primary release key offline by following
[`keys/CEREMONY.md`](../keys/CEREMONY.md). GitHub receives only the encrypted
release-signing subkey and its passphrase. The offline primary key and
revocation certificate never enter CI.

## Build the runtime

After the final candidate passes CI, dispatch
`.github/workflows/runtime-profile.yml` with:

- the intended production tag;
- the candidate's full 40-character commit in `candidate_commit`;
- a new profile ID;
- a fixed reproducible timestamp as `source_date_epoch`; and
- the builder image already pinned in `runtime-source.lock.json`.

The workflow builds for the final prefix, verifies the GNU source archive,
records its inputs, prepares the inventory, and uploads the
`glibcx-runtime-profile` artifact. This pre-tag build prevents a broken
runtime build from consuming a production version. After it succeeds, create
the annotated tag at that exact commit. The protected release workflow rejects
the artifact if the tag points anywhere else. Reuse the same source timestamp
when dispatching the protected release.

For a deliberate post-tag rebuild, leave `candidate_commit` empty; the workflow
then requires the named tag to be annotated.

Before tagging, the final candidate must pass `ci/android_device_matrix.sh` on
at least one physical AArch64 Termux device available to the maintainer.
Additional Android versions, vendors, and page sizes are valuable published
evidence, not mandatory release blockers.

## Stage and publish the release

Dispatch `.github/workflows/release.yml` with the successful profile-build run
ID, artifact name, next catalog version, and the same source timestamp. For a
production release, set `publish` to `true` in this single dispatch.

The protected jobs then:

1. check the tag, version, public key, fingerprints, source, and provenance;
2. import the protected signing subkey;
3. build, sign, and independently verify all ten assets;
4. create attestations and upload a complete draft release; and
5. compare the uploaded digests with the verified local files.

After verification, the publish job waits for a second `production-release`
environment approval. Inspect the complete draft at that pause, then approve or
reject publication. Do not try to resume a `publish=false` run with a second
dispatch: the new run correctly refuses to replace the existing draft.

If any asset needs to change, reject publication and make a new version and
tag; do not replace an asset in place. Publication checks that GitHub locked the
release and that every asset still matches its attestation. `publish=false`
exists only for non-production workflow rehearsals whose draft and tag will not
be reused.

The repository variables are:

- `GLIBCX_RELEASE_PRIMARY_FINGERPRINT`
- `GLIBCX_RELEASE_SIGNING_FINGERPRINT`

The `production-release` environment secrets are:

- `GLIBCX_RELEASE_SIGNING_SUBKEY_B64`
- `GLIBCX_RELEASE_SIGNING_PASSPHRASE`
