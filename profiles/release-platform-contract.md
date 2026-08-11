# Verified GitHub release setup

OpenPGP is the mandatory release trust root. GitHub immutable releases,
release attestations, and artifact attestations are supplementary evidence.
They do not replace the pinned primary fingerprint, signed catalog, exact
catalog signing-subkey fingerprint, bundle signatures, or hashes.

GitHub immutable releases are enabled for `dsecurity49/glibcx`.
`bash ci/release_platform_probe.sh` passed on 2026-08-09, along with the
protected publication rehearsal:

- tag and prerelease: `v0.3.0-dry-run.2`;
- candidate commit: `b825fb38061cf6c9f1eb812873fc3559e744a89f`;
- ten fixture-signed assets matched their uploaded SHA-256 digests;
- the tag CI run completed successfully;
- GitHub reported `immutable: true`; and
- `gh release verify` plus `gh release verify-asset` passed for every asset.

The prerelease remains available as historical test evidence. Its
fixture OpenPGP key is not trusted by glibcx. The rehearsal proves that GitHub's
immutable-release and attestation features work for this repository; a
real release must still pass the pinned OpenPGP checks.
