# Release key files

[`glibcx-release.gpg`](glibcx-release.gpg) is the public key produced by the
offline procedure in [`CEREMONY.md`](CEREMONY.md).

- Primary fingerprint: `EB13 DBFA 9354 A552 85CF 4B03 B525 5ACD 0708 C45E`
- Release-signing subkey: `2D0A D952 32D1 E58A D13E 6B23 C49A 0B44 BF9F 2613`

The primary fingerprint is pinned in `src/common.sh`, `install.sh`, and the
top-level README. The signed runtime catalog also binds every release to the
expected signing-subkey fingerprint.

Only the public key belongs here. Private keys, revocation certificates, and
passphrases stay outside the repository. CI creates temporary fixture keys for
tests; glibcx does not trust them for releases.
