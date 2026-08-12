#!/usr/bin/env bash
# Read-only release-platform capability gate. Requires an authenticated gh user
# that can inspect repository administration settings.
set -euo pipefail

repo="${GLIBCX_GITHUB_REPOSITORY:-dsecurity49/glibcx}"
dry_run_tag="v0.3.0-dry-run.2"
for command_name in gh jq; do
    command -v "$command_name" >/dev/null 2>&1 \
        || { echo "FAIL: required command '$command_name' is unavailable." >&2; exit 1; }
done

immutable_json=$(gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
    "repos/${repo}/immutable-releases") \
    || { echo "FAIL: immutable-release capability could not be inspected." >&2; exit 1; }
jq -e '.enabled == true' <<<"$immutable_json" >/dev/null \
    || {
        echo "FAIL: immutable releases are available but not enabled for ${repo}." >&2
        echo "Enable them in repository settings before the protected release dry run." >&2
        exit 1
    }
echo "PASS: immutable releases are enabled for ${repo}."

if ! gh attestation --help >/dev/null 2>&1; then
    echo "FAIL: this GitHub CLI cannot verify artifact attestations." >&2
    exit 1
fi
echo "PASS: GitHub CLI exposes artifact-attestation verification."

dry_run=$(gh api \
    -H 'X-GitHub-Api-Version: 2026-03-10' \
    "repos/${repo}/releases/tags/${dry_run_tag}") \
    || { echo "FAIL: protected dry-run release is unavailable." >&2; exit 1; }
if ! jq -e '
    .draft == false
    and .prerelease == true
    and .immutable == true
    and (.assets | length) == 10
' <<<"$dry_run" >/dev/null; then
    echo "FAIL: protected dry-run release is not immutable and complete." >&2
    exit 1
fi
gh release verify "$dry_run_tag" --repo "$repo" >/dev/null \
    || { echo "FAIL: protected dry-run release attestation did not verify." >&2; exit 1; }
echo "PASS: ${dry_run_tag} is immutable with ten attested assets."
