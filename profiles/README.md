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

After the candidate passes its pre-tag gates and an annotated production tag
exists, dispatch `.github/workflows/runtime-profile.yml` with:

- the production tag;
- a new profile ID;
- the tag timestamp as `source_date_epoch`; and
- `ghcr.io/termux/package-builder-cgct` pinned by a full SHA-256 digest.

The workflow builds for the final prefix, verifies the GNU source archive,
records its inputs, prepares the inventory, and uploads the
`glibcx-runtime-profile` artifact.

## Stage and publish the release

Dispatch `.github/workflows/release.yml` with the successful profile-build run
ID, artifact name, next catalog version, and the same source timestamp. Keep
`publish` set to `false` on the first run.

The protected jobs then:

1. check the tag, version, public key, fingerprints, source, and provenance;
2. import the protected signing subkey;
3. build, sign, and independently verify all ten assets;
4. create attestations and upload a complete draft release; and
5. compare the uploaded digests with the verified local files.

Review that draft before dispatching the workflow with `publish` set to `true`.
If any asset needs to change, make a new version and tag; do not replace an
asset in place. Publication checks that GitHub locked the release and that every
asset still matches its attestation.

The repository variables are:

- `GLIBCX_RELEASE_PRIMARY_FINGERPRINT`
- `GLIBCX_RELEASE_SIGNING_FINGERPRINT`

The `production-release` environment secrets are:

- `GLIBCX_RELEASE_SIGNING_SUBKEY_B64`
- `GLIBCX_RELEASE_SIGNING_PASSPHRASE`
