# GitHub release-platform contract

OpenPGP is the mandatory release trust root. GitHub immutable releases,
release attestations, and artifact attestations are supplementary evidence.
They do not replace the pinned primary fingerprint, signed catalog, exact
catalog signing-subkey fingerprint, bundle signatures, or hashes.

GitHub immutable releases are enabled for `dsecurity49/glibcx`, and
`bash ci/release_platform_probe.sh` passes as of 2026-08-09. Archive that probe
output with the release evidence. This configuration check does not replace
the protected publication dry run below.

The protected dry run must create a draft, attach every final asset, publish
the test release, confirm it is reported immutable, and verify a real
attestation against the expected repository and commit. Only then may these
GitHub features become hard platform gates. The release remains blocked if
they are intended as required evidence but the dry run has not proved them.
