# Release-key ceremony

Run this ceremony on an offline machine controlled by the maintainer. Do not
run it in a network-connected environment, an automated workflow, or the
repository worktree. Keep the offline primary key, its passphrase, and
revocation certificate on encrypted offline media with a tested backup.

## 1. Create the offline keyring

Work outside the repository on an encrypted offline volume. Choose the
identity and expiry periods deliberately:

```bash
ceremony_root="$PWD/glibcx-key-ceremony"
mkdir -m 700 "$ceremony_root"
export GNUPGHOME="$ceremony_root/gnupg"
mkdir -m 700 "$GNUPGHOME"

KEY_IDENTITY='glibcx release <maintainer-address>'
PRIMARY_EXPIRY='2y'
SIGNING_EXPIRY='1y'

gpg --quick-gen-key "$KEY_IDENTITY" ed25519 cert "$PRIMARY_EXPIRY"
PRIMARY_FPR=$(LC_ALL=C gpg --batch --with-colons --list-secret-keys "$KEY_IDENTITY" \
  | LC_ALL=C awk -F: '$1 == "fpr" {print toupper($10); exit}')
printf 'Primary fingerprint: %s\n' "$PRIMARY_FPR"
```

Create a dedicated signing subkey and record its fingerprint:

```bash
gpg --quick-add-key "$PRIMARY_FPR" ed25519 sign "$SIGNING_EXPIRY"
SIGNING_FPR=$(LC_ALL=C gpg --batch --with-colons --list-secret-keys "$PRIMARY_FPR" \
  | LC_ALL=C awk -F: '$1 == "fpr" {count++; if (count == 2) {print toupper($10); exit}}')
printf 'Signing fingerprint: %s\n' "$SIGNING_FPR"
```

GnuPG asks for the key passphrase through pinentry. Do not place it in a shell
variable, command argument, transcript, or repository file.

## 2. Export and back up the key material

Create the revocation certificate interactively, then export the public key,
an armored public backup, and the encrypted signing-subkey bundle:

```bash
gpg --output "$ceremony_root/glibcx-primary-revocation.asc" \
  --gen-revoke "$PRIMARY_FPR"
gpg --output "$ceremony_root/glibcx-release.gpg" --export "$PRIMARY_FPR"
gpg --armor --output "$ceremony_root/glibcx-release-public.asc" \
  --export "$PRIMARY_FPR"
gpg --armor --output "$ceremony_root/glibcx-release-signing-subkeys.asc" \
  --export-secret-subkeys "$SIGNING_FPR!"
chmod 600 \
  "$ceremony_root/glibcx-primary-revocation.asc" \
  "$ceremony_root/glibcx-release.gpg" \
  "$ceremony_root/glibcx-release-public.asc" \
  "$ceremony_root/glibcx-release-signing-subkeys.asc"
```

The four deliverables are:

- binary public key: `glibcx-release.gpg`;
- armored public-key backup;
- encrypted secret-subkey export containing only the signing subkey and the
  primary-key stub; and
- primary-key revocation certificate.

Keep the offline keyring, revocation certificate, passphrase, and a tested
backup offline. Only the binary public key is committed.

## 3. Verify the public export independently

Use a separate empty keyring and compare both full fingerprints with the values
recorded above:

```bash
verify_home="$ceremony_root/verify-gnupg"
mkdir -m 700 "$verify_home"
GNUPGHOME="$verify_home" LC_ALL=C gpg --batch --show-keys --with-colons \
  "$ceremony_root/glibcx-release.gpg"
```

The first `fpr` record must equal the recorded primary fingerprint, and the
signing subkey's `fpr` record must equal the recorded signing fingerprint.

## 4. Add the public key to the repository

Only `glibcx-release.gpg` is committed. Set the same primary fingerprint in:

- `RUNTIME_RELEASE_PRIMARY_FINGERPRINT` in `src/common.sh`;
- `RELEASE_PRIMARY_FINGERPRINT` in `install.sh`; and
- the README trust section.

After updating the fingerprints, rebuild and verify the checked-in monolith:

```bash
./build.sh
mv glibcx-bin glibcx
chmod +x glibcx
./build.sh
cmp -s glibcx glibcx-bin
```

## 5. Set up the protected GitHub environment

Create the GitHub environment `production-release` with required maintainer
approval and restrict deployment to protected release tags. Set these
public repository variables:

- variable `GLIBCX_RELEASE_PRIMARY_FINGERPRINT`;
- variable `GLIBCX_RELEASE_SIGNING_FINGERPRINT`.

Set these environment secrets:

- secret `GLIBCX_RELEASE_SIGNING_SUBKEY_B64`, containing the base64 encoding of
  the encrypted secret-subkey export; and
- secret `GLIBCX_RELEASE_SIGNING_PASSPHRASE`.

Enter secrets through standard input or the GitHub UI so they do not appear in
shell history. `GLIBCX_RELEASE_SIGNING_SUBKEY_B64` is the base64 encoding of
the encrypted `glibcx-release-signing-subkeys.asc` export, with line breaks
removed. Delete online transfer copies after importing them, then rehearse the
complete signing and verification workflow with a fixture key before creating
a release tag.

Never upload the primary secret key, revocation certificate, plaintext
passphrase, or unencrypted signing subkey to GitHub or a release asset.
