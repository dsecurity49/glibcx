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
