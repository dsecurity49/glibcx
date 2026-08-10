# Release-key provisioning

`glibcx-release.gpg` is the production public key exported by the offline
ceremony in [`CEREMONY.md`](CEREMONY.md). Its primary fingerprint
(`EB13 DBFA 9354 A552 85CF 4B03 B525 5ACD 0708 C45E`) and release-signing
subkey fingerprint (`2D0A D952 32D1 E58A D13E 6B23 C49A 0B44 BF9F 2613`) are
pinned in `src/common.sh`, `install.sh`, and `README.md`.

Private keys, revocation certificates, and passphrases do not belong in the
repository. CI creates short-lived fixture keys in temporary directories; they
are test data, not release keys.

CI creates short-lived fixture keys in temporary directories. They are test
data, not release keys.
