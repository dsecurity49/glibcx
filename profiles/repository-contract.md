# Termux glibc repository release contract

The resolver constants are a prototype contract, not an assumed permanent
server layout:

- source: `https://packages-cf.termux.dev/apt/termux-glibc`
- distribution: `glibc`
- component: `stable`
- authenticated indexes: `stable/binary-aarch64/Packages` and
  `stable/Contents-aarch64.gz`
- expected signed identity: Origin `termux-glibc glibc`, Suite `glibc`
- pinned primary fingerprint: `CC72CF8BA7DBFA0182877D045A897D96E57CF20C`

Before any release candidate may enable dependency resolution, run
`bash ci/live_repository_probe.sh` on the actual supported Termux AArch64
environment. It verifies the signed metadata, exact index names and path shape,
an independently packaged runtime DSO (`libz.so.1` by default), an exact `.deb`
download, and `apt-get --download-only` with isolated state. Archive the output
with the release evidence. Fixture tests prove parser behavior only and do not
satisfy this live gate.

Contents lookup accepts only a DSO at the canonical top-level
`.../glibc/lib/<SONAME>` or `.../glibc/usr/lib/<SONAME>`. This deliberately
excludes compatibility payload copies such as
`.../glibc/lib/box64-i386-linux-gnu/libz.so.1`; on 2026-08-09 that rule selected
`zlib-glibc` instead of the unrelated `box64-glibc` copy. Multiple providers at
the same canonical tier still fail closed.
