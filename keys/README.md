# Release-key provisioning

`glibcx-release.gpg` has not been added yet. It is created during the offline
production-key ceremony in [`CEREMONY.md`](CEREMONY.md).

The ceremony exports the public key into this directory and pins its primary
fingerprint in `src/common.sh`, `install.sh`, and `README.md`. Private keys,
revocation certificates, and passphrases do not belong in the repository.

CI creates short-lived fixture keys in temporary directories. They are test
data, not release keys.
