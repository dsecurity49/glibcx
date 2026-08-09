# Release-key provisioning

`glibcx-release.gpg` is intentionally absent until the maintainer completes the
offline production-key ceremony described in `blueprint.md` milestone 8.

The ceremony must export the public primary key here, then pin its full primary
fingerprint in `src/common.sh`, `install.sh`, and `README.md`. Private keys,
revocation certificates, and passphrases must never enter this repository.

CI tests generate short-lived fixture keys only inside private temporary
directories. Those keys are never release trust material.
