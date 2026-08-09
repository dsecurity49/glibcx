#!/usr/bin/env bash
# Read-only release-platform capability gate. Requires an authenticated gh user
# that can inspect repository administration settings.
set -euo pipefail

repo="${GLIBCX_GITHUB_REPOSITORY:-dsecurity49/glibcx}"
command -v gh >/dev/null 2>&1 \
    || { echo "FAIL: GitHub CLI is required." >&2; exit 1; }

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
echo "NOTE: the protected dry run must still create and verify a real attestation."
