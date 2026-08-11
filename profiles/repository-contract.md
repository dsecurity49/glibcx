# Verified Termux glibc repository layout

These values describe the repository layout verified for the current release
candidate. They are not assumptions about every future Termux repository:

- source: `https://packages-cf.termux.dev/apt/termux-glibc`
- distribution: `glibc`
- component: `stable`
- authenticated indexes: `stable/binary-aarch64/Packages` and
  `stable/Contents-aarch64.gz`
- expected signed identity: Origin `termux-glibc glibc`, Suite `glibc`
- pinned primary fingerprint: `CC72CF8BA7DBFA0182877D045A897D96E57CF20C`

For every release candidate, run `bash ci/live_repository_probe.sh` in the
supported Termux AArch64 environment. It verifies the signed metadata, exact
index names and paths, an independently packaged DSO (`libz.so.1` by default),
an exact `.deb` download, and `apt-get --download-only` with isolated state.
Keep its output with the release evidence. Fixture tests cover parser behavior
but do not replace this live check.

During patching, the selected loader—not a Bash approximation of `ld.so`
search order—identifies each missing SONAME. The resolver downloads that exact
provider and repeats the probe until the loader reports a complete startup
graph. Package and repository hashes are then recorded with the app generation.

Contents lookup accepts only a DSO at a canonical top-level
`.../glibc/lib/<SONAME>` or `.../glibc/usr/lib/<SONAME>`. This deliberately
excludes compatibility payload copies such as
`.../glibc/lib/box64-i386-linux-gnu/libz.so.1`; on 2026-08-09 that rule selected
`zlib-glibc` instead of the unrelated `box64-glibc` copy. Multiple providers at
the same canonical tier fail closed.
