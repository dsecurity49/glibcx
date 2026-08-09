# GitHub release-platform contract

OpenPGP is the mandatory release trust root. GitHub immutable releases,
release attestations, and artifact attestations are supplementary evidence.
They do not replace the pinned primary fingerprint, signed catalog, exact
catalog signing-subkey fingerprint, bundle signatures, or hashes.

GitHub immutable releases are enabled for `dsecurity49/glibcx`, and
`bash ci/release_platform_probe.sh` passes as of 2026-08-09. The protected
publication dry run also passed on that date:

- tag and prerelease: `v0.3.0-dry-run.2`;
- candidate commit: `b825fb38061cf6c9f1eb812873fc3559e744a89f`;
- ten fixture-signed assets matched their uploaded SHA-256 digests;
- the tag CI run completed successfully;
- GitHub reported `immutable: true`; and
- `gh release verify` plus `gh release verify-asset` passed for every asset.

The prerelease is retained as auditable non-production evidence. The fixture
OpenPGP key is not production trust material. Production OpenPGP verification
remains mandatory even though immutable releases and GitHub release
attestations are now proven supplementary gates.
