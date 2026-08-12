# Releasing glibcx

This is the release procedure I use for glibcx. It is kept in the repository
because the public key, runtime build, corresponding source, and release assets
need to remain reproducible even if I have not touched them for a while.

Key custody and release approval currently rest entirely with one maintainer.
If a second maintainer joins, the custody, recovery, and approval arrangement
needs to be reconsidered rather than copied unchanged.

## Release keys

The OpenPGP primary key stays offline and is used to certify or revoke signing
subkeys. GitHub Actions receives an encrypted export of the release-signing
subkey and its passphrase. The primary secret key and revocation certificate do
not enter GitHub, this repository, or a release asset.

The public identities currently pinned by glibcx are:

- Primary: `EB13 DBFA 9354 A552 85CF 4B03 B525 5ACD 0708 C45E`
- Signing subkey: `2D0A D952 32D1 E58A D13E 6B23 C49A 0B44 BF9F 2613`

Only [`keys/glibcx-release.gpg`](../keys/glibcx-release.gpg) belongs in the
repository. Fixture keys used by tests are never release keys.

### Creating the offline keyring

These commands are a record of the original setup and a usable procedure if a
new trust root is ever required. They run on encrypted offline storage, outside
the repository:

```bash
key_root="$PWD/glibcx-offline-key"
mkdir -m 700 "$key_root"
export GNUPGHOME="$key_root/gnupg"
mkdir -m 700 "$GNUPGHOME"

KEY_IDENTITY='glibcx release <maintainer-address>'
PRIMARY_EXPIRY='2y'
SIGNING_EXPIRY='1y'

gpg --quick-gen-key "$KEY_IDENTITY" ed25519 cert "$PRIMARY_EXPIRY"
PRIMARY_FPR=$(LC_ALL=C gpg --batch --with-colons --list-secret-keys \
  "$KEY_IDENTITY" | LC_ALL=C awk -F: '$1 == "fpr" {print toupper($10); exit}')
gpg --quick-add-key "$PRIMARY_FPR" ed25519 sign "$SIGNING_EXPIRY"
SIGNING_FPR=$(LC_ALL=C gpg --batch --with-colons --list-secret-keys \
  "$PRIMARY_FPR" | LC_ALL=C awk -F: \
  '$1 == "fpr" {count++; if (count == 2) {print toupper($10); exit}}')

printf 'Primary fingerprint: %s\n' "$PRIMARY_FPR"
printf 'Signing fingerprint: %s\n' "$SIGNING_FPR"
```

Pinentry collects the passphrase. Putting it in a variable, command argument,
transcript, or repository file would leave avoidable copies behind.

Generate the public material, signing-subkey export, and revocation
certificate while the offline keyring is open:

```bash
gpg --output "$key_root/glibcx-primary-revocation.asc" \
  --gen-revoke "$PRIMARY_FPR"
gpg --output "$key_root/glibcx-release.gpg" --export "$PRIMARY_FPR"
gpg --armor --output "$key_root/glibcx-release-public.asc" \
  --export "$PRIMARY_FPR"
gpg --armor --output "$key_root/glibcx-release-signing-subkeys.asc" \
  --export-secret-subkeys "$SIGNING_FPR!"

chmod 600 \
  "$key_root/glibcx-primary-revocation.asc" \
  "$key_root/glibcx-release.gpg" \
  "$key_root/glibcx-release-public.asc" \
  "$key_root/glibcx-release-signing-subkeys.asc"
```

The offline keyring, revocation certificate, passphrase, and a tested backup
remain on encrypted offline media. The encrypted signing-subkey export is the
only secret-key material copied to the protected GitHub environment.

Before publishing the public key, inspect it from an empty keyring rather than
trusting the source keyring's display:

```bash
verify_home="$key_root/verify-gnupg"
mkdir -m 700 "$verify_home"
GNUPGHOME="$verify_home" LC_ALL=C gpg --batch --show-keys --with-colons \
  "$key_root/glibcx-release.gpg"
```

The primary and signing-subkey `fpr` records must match the values printed by
the offline keyring.

### Places that pin the key

The primary fingerprint appears deliberately in `src/common.sh`, `install.sh`,
and the top-level README. A change to the trust root must update all three and
the checked-in public key. Since `glibcx` is assembled from `src/`, rebuild it
and confirm that a second build is identical:

```bash
./build.sh
mv glibcx-bin glibcx
chmod +x glibcx
./build.sh
cmp -s glibcx glibcx-bin
```

## GitHub configuration

The `production-release` environment is restricted to tags matching `v*` and
requires maintainer approval. It contains these secrets:

- `GLIBCX_RELEASE_SIGNING_SUBKEY_B64`, the encrypted armored signing-subkey
  export encoded as base64 without line breaks
- `GLIBCX_RELEASE_SIGNING_PASSPHRASE`, the subkey passphrase

The repository variables are:

- `GLIBCX_RELEASE_PRIMARY_FINGERPRINT`
- `GLIBCX_RELEASE_SIGNING_FINGERPRINT`

Secrets are entered through the GitHub interface or standard input, not as
shell arguments. Any online transfer copy is removed after the environment has
been configured. Immutable releases must remain enabled for the repository.

## Preparing a release candidate

A release starts from one commit. Before building its runtime, check that the
monolithic script matches its modules and that CI passes. At least one current
physical AArch64 Termux report is required; missing access to a particular
Android version, vendor, or 16 KB device is recorded as a coverage gap rather
than treated as a veto.

Here, current means that the report covers the runtime behavior being released.
A later documentation-only or release-metadata commit does not invalidate a
device run when the tested `src/`, built `glibcx`, profile code, and installer
logic are unchanged. Any functional change after that run requires another
physical-device test.

The client version in `src/common.sh` must exactly match the intended tag
without the leading `v`. The release workflow rejects `0.3.0-dev` for a
`v0.3.0` tag.

Run the live repository probe on Termux AArch64 close to the release:

```bash
bash ci/live_repository_probe.sh
```

It verifies the pinned Termux repository identity, exact Packages and Contents
locations, a separately packaged shared library, an authenticated `.deb`, and
isolated `apt-get --download-only`. Keep its output with the release notes or
workflow evidence.

## Building the managed runtime

The runtime is built before the production tag so a failed runtime build does
not consume a version. Use one timestamp for the runtime and release workflows:

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

The `glibcx-runtime-profile` artifact contains the unsigned final-prefix
payload, its build metadata, and corresponding source. The workflow binds it to
the candidate commit, tag, timestamp, pinned packaging commits, source hash,
and builder image. Inspect the completed run and retain its run ID.

`profiles/prepare-profile.sh` inventories files only after the runtime has been
built for its final absolute prefix. It excludes SDK-only archives and object
files, rejects escaping symlinks, and records the loader-audit module and
proc-exe shim. Signing happens later in the protected workflow.

## Tagging and publishing

Create the annotated tag only after the runtime artifact has passed. It must
point to the same candidate commit recorded in that artifact:

```bash
git tag -a "$tag" "$candidate_commit" -m "glibcx ${tag#v}"
git push origin "$tag"
```

Start the protected release with the successful profile run ID and the next
unused catalog integer:

```bash
gh workflow run release.yml \
  -f tag="$tag" \
  -f profile_run_id='<successful-run-id>' \
  -f profile_artifact=glibcx-runtime-profile \
  -f catalog_version='<next-integer>' \
  -f source_date_epoch="$source_date_epoch" \
  -f publish=true
```

The first protected job imports the signing subkey, verifies that the runtime
artifact came from the tagged commit, and creates the signed release files. It
publishes a fully populated draft, then removes the imported private material.
A separate job checks the local and uploaded bytes, signatures, hashes,
catalog, profile, and corresponding source before publication is allowed.

The release contains these 12 assets:

```text
glibcx
glibcx.asc
glibcx.sha256
install.sh
install.sh.asc
glibcx-release.gpg
glibcx-profiles-v1.json
glibcx-profiles-v1.json.asc
glibcx-runtime-<profile-id>.tar.xz
glibcx-runtime-<profile-id>.tar.xz.asc
glibcx-runtime-<profile-id>-source.tar.xz
glibcx-runtime-<profile-id>-source.tar.xz.asc
```

The catalog includes its issue and expiry times, monotonically increasing
version, minimum client version, exact signing-subkey fingerprint, and profile
compatibility schema. The runtime and source archives have detached signatures;
the runtime also contains a signed file manifest.

Once the draft verification passes, the final protected job publishes it as
the latest release. It waits for GitHub to report the release immutable, then
runs `gh release verify` and `gh release verify-asset` for every asset. A bad or
incomplete release is corrected with a new version and tag. Assets are never
replaced under an existing release.

Use `publish=false` only for a rehearsal. A rehearsal tag, draft, catalog
version, or artifact is not reused for production.

## Platform rehearsal record

Immutable releases are enabled for `dsecurity49/glibcx`. The protected
fixture-key rehearsal was published on 2026-08-09 as prerelease
`v0.3.0-dry-run.2` at commit
`b825fb38061cf6c9f1eb812873fc3559e744a89f`. Its ten assets matched their
uploaded SHA-256 digests, tag CI passed, GitHub reported the release immutable,
and `gh release verify` plus every asset verification passed.

That prerelease records a test of an earlier asset layout and the GitHub
controls. Its fixture key is not trusted by glibcx and supplies no OpenPGP
evidence for a production release.

## Final checks

Before approving publication, confirm the following against the exact tag:

- the checked-in `glibcx` matches a clean build;
- shell syntax, ShellCheck, fixture tests, and native AArch64 integration pass;
- at least one current physical-device report passes and the tested coverage is
  stated plainly;
- direct patching, NPM, GitHub release, and manual-download paths have been
  exercised where relevant to the changes;
- the live Termux repository probe passes;
- the runtime artifact names the tagged commit and locked build inputs;
- the public key and both full fingerprints match their repository pins;
- every expected asset is present, signed where required, and byte-for-byte the
  asset checked by the verification job;
- the corresponding-source archive is present; and
- GitHub reports the published release immutable and verifies its attestations.
