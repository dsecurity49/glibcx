# Managed runtime build inputs

Production runtime assets must be built from the Android-patched
`termux-pacman/glibc-packages` recipe for their final absolute prefix:

```text
$PREFIX/opt/glibcx/runtimes/<profile-id>
```

Copying an existing glibc tree to that path is not a production build because
glibc embeds its prefix, loader path, system directories, and configuration
paths. The release build must retain the upstream source archive, the exact
glibc-packages commit and patches, compiler/toolchain provenance, licenses, and
the corresponding-source bundle.

Each bundle root contains signed `profile.json`/`profile.json.asc` plus every
file listed by the manifest. Regular file modes are restricted to `0644` and
`0755`; all symlinks must remain inside the profile. The optional shim is built
as a glibc DSO from `proc-exe-shim.c`, listed in `files`, and described by:

```json
{
  "proc_exe_shim": {
    "path": "/absolute/profile/lib/glibcx-proc-exe-shim.so",
    "sha256": "...",
    "auto_targets": [
      {"basename": "tool", "sha256": "optional exact target hash"}
    ]
  }
}
```

The offline primary key ceremony is a maintainer action. CI may use only the
dedicated release-signing subkey supplied by the protected release environment;
it must never generate or retain the production primary key.

`prepare-profile.sh` creates the unsigned, inventoried payload.
`package-release.sh` consumes that payload plus its corresponding-source tree
and assembles the complete immutable asset set. It requires an already
provisioned signing key and full primary/signing fingerprints; it never creates
or imports key material. The protected release workflow may call it only after
the maintainer provisions the release-signing subkey.

## Production workflow

`runtime-source.lock.json` pins the glibc-packages recipe, the Termux build
framework, the GNU glibc source archive, and its digest. Review and increment
those values explicitly when creating a new profile; never follow a moving
branch during a release build.

After the candidate commit passes the device gates and has an annotated
production tag, dispatch `.github/workflows/runtime-profile.yml`. Supply:

- the existing production tag;
- a new immutable profile ID;
- the tag timestamp as `source_date_epoch`; and
- `ghcr.io/termux/package-builder-cgct` pinned by a full `sha256` digest.

The workflow rebuilds the Android-patched recipe for the profile's final
absolute prefix, downloads and verifies the corresponding GNU source, records
both upstream commits and the builder-image digest, prepares the inventory, and
uploads `glibcx-runtime-profile`. Never use a `latest` container reference.

Then dispatch `.github/workflows/release.yml` with the successful profile-build
run ID, its artifact name, a strictly increasing catalog version, and the same
source timestamp. Leave `publish` false for the first run. The protected job:

1. verifies the annotated tag, exact checked-in version, public key, pinned
   fingerprints, profile provenance, and source presence;
2. imports only the encrypted release-signing subkey from the protected
   environment;
3. signs and independently verifies all ten assets;
4. creates GitHub artifact attestations and a fully populated draft; and
5. compares every uploaded asset digest with the locally verified bytes.

After reviewing the successful draft run, repeat with a new tag if any bytes
must change. A run with `publish` true publishes the already verified draft,
requires GitHub to report it immutable, and verifies the release attestation
and every local asset against that attestation.

The repository must define public variables
`GLIBCX_RELEASE_PRIMARY_FINGERPRINT` and
`GLIBCX_RELEASE_SIGNING_FINGERPRINT`. The `production-release` environment
must define secrets
`GLIBCX_RELEASE_SIGNING_SUBKEY_B64` and
`GLIBCX_RELEASE_SIGNING_PASSPHRASE`. See `keys/CEREMONY.md`.
