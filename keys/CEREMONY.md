# Production release-key ceremony

Run this ceremony on an offline machine controlled by the maintainer. Do not
run it in GitHub Actions, an AI-agent session, or the repository worktree. Keep
the offline primary key, its passphrase, and revocation certificate on encrypted
offline media with a tested backup.

## Offline creation

Use a fresh `GNUPGHOME` on the offline machine and create:

1. an Ed25519 certification-only primary key with a maintainer-selected expiry;
2. a dedicated Ed25519 signing subkey with a shorter expiry; and
3. a revocation certificate for the primary key.

Record the full primary and signing-subkey fingerprints from colon-formatted
GnuPG output. Export these four deliverables:

- binary public key: `glibcx-release.gpg`;
- armored public-key backup;
- encrypted secret-subkey export containing only the signing subkey and the
  primary-key stub; and
- primary-key revocation certificate.

Verify the binary public key on a second offline invocation:

```bash
LC_ALL=C gpg --batch --show-keys --with-colons glibcx-release.gpg
```

The first `fpr` record must equal the recorded primary fingerprint, and the
signing subkey's `fpr` record must equal the recorded signing fingerprint.

## Repository provisioning

Only `glibcx-release.gpg` is committed. Set the same primary fingerprint in:

- `RUNTIME_RELEASE_PRIMARY_FINGERPRINT` in `src/common.sh`;
- `RELEASE_PRIMARY_FINGERPRINT` in `install.sh`; and
- the README trust section.

Run `./build.sh`, deploy the resulting monolith as required by `AGENTS.md`, and
verify that the checked-in binary matches a clean rebuild.

## Protected environment provisioning

Create the GitHub environment `production-release` with required maintainer
approval and restrict deployment to protected production tags. Set these
public repository variables:

- variable `GLIBCX_RELEASE_PRIMARY_FINGERPRINT`;
- variable `GLIBCX_RELEASE_SIGNING_FINGERPRINT`;

Set these environment secrets:

- secret `GLIBCX_RELEASE_SIGNING_SUBKEY_B64`, containing the base64 encoding of
  the encrypted secret-subkey export; and
- secret `GLIBCX_RELEASE_SIGNING_PASSPHRASE`.

Enter secrets through standard input or the GitHub UI so they do not appear in
shell history. Delete online transfer copies after importing them, then perform
a signing and verification rehearsal with a non-production key before the
production tag is created.

Never upload the primary secret key, revocation certificate, plaintext
passphrase, or unencrypted signing subkey to GitHub or a release asset.
