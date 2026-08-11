# Building and signing a managed runtime

This directory contains the scripts, contracts, and pinned inputs used to build
a managed glibcx runtime and attach it to a signed release.

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
The dependency-free loader-audit module is built there too. Compatibility
schema 2 records its signed path, hash, protocol, reserved descriptor, and the
runtime's glibc-hwcaps policy. Older or incomplete profiles fail validation.

`prepare-profile.sh` inventories an unsigned payload. `package-release.sh`
adds corresponding source and assembles the twelve release assets; the binary,
installer, catalog, runtime bundle, and source bundle each receive detached signatures.
Neither script creates or imports real release key material.

## Keep the primary key offline

Create the primary release key offline by following
[`keys/CEREMONY.md`](../keys/CEREMONY.md). GitHub receives only the encrypted
release-signing subkey and its passphrase. The offline primary key and
revocation certificate never enter CI.

## Build the runtime

After the commit intended for the tag passes CI and the physical-device check,
dispatch `.github/workflows/runtime-profile.yml` with:

- the intended release tag;
- the candidate's full 40-character commit in `candidate_commit`;
- a new profile ID;
- a fixed reproducible timestamp as `source_date_epoch`; and
- the builder image already pinned in `runtime-source.lock.json`.

For example:

```bash
tag=v0.3.0
candidate_commit=$(git rev-parse HEAD)
profile_id=glibcx-glibc-2.43-1
source_date_epoch=$(git show -s --format=%ct "$candidate_commit")
builder_image=$(jq -r '.builder_image' profiles/runtime-source.lock.json)

gh workflow run runtime-profile.yml \
  -f tag="$tag" \
  -f candidate_commit="$candidate_commit" \
  -f profile_id="$profile_id" \
  -f source_date_epoch="$source_date_epoch" \
  -f builder_image="$builder_image"
```

The workflow builds directly for the final install prefix, verifies the GNU
source archive, records every pinned input, and uploads the
`glibcx-runtime-profile` artifact. Inspect the completed run before creating an
annotated tag at the same commit. The release workflow rejects an artifact or
tag that points elsewhere. Reuse the same source timestamp for publication.

For a deliberate post-tag rebuild, leave `candidate_commit` empty; the workflow
then requires the named tag to be annotated.

Before tagging, run `bash ci/android_device_matrix.sh` on at least one physical
AArch64 Termux device available to the maintainer. Additional Android versions,
vendors, and page sizes are useful evidence, not release blockers.

## Stage and publish the release

Create and push the annotated tag only after the profile build succeeds. Then
dispatch `.github/workflows/release.yml` with that build's run ID, the next
monotonically increasing catalog version, and the same timestamp:

```bash
git tag -a "$tag" "$candidate_commit" -m "glibcx ${tag#v}"
git push origin "$tag"

gh workflow run release.yml \
  -f tag="$tag" \
  -f profile_run_id='<successful-run-id>' \
  -f profile_artifact=glibcx-runtime-profile \
  -f catalog_version='<next-integer>' \
  -f source_date_epoch="$source_date_epoch" \
  -f publish=true
```

For a real release, use one `publish=true` dispatch. A rehearsal cannot be
turned into a release later.

The protected jobs then:

1. check the tag, version, public key, fingerprints, source, and provenance;
2. import the protected signing subkey;
3. build all twelve assets, sign the five release payloads, and verify the
   complete set independently;
4. create attestations and upload a complete draft release; and
5. compare the uploaded digests with the verified local files.

After verification, the publish job waits for a second `production-release`
environment approval. That pause is the point to inspect the draft and either
approve it or stop the release.

If any asset needs to change, reject publication and make a new version and
tag; do not replace an asset in place. Publication checks that GitHub locked the
release and that every asset still matches its attestation. Use `publish=false`
only for workflow rehearsals whose draft and tag will not be reused.

Required repository variables:

- `GLIBCX_RELEASE_PRIMARY_FINGERPRINT`
- `GLIBCX_RELEASE_SIGNING_FINGERPRINT`

Required `production-release` environment secrets:

- `GLIBCX_RELEASE_SIGNING_SUBKEY_B64`
- `GLIBCX_RELEASE_SIGNING_PASSPHRASE`
