#!/usr/bin/env bash
# glibc-runner must not be resolved before glibc-repo is active and refreshed.
set -euo pipefail

pass() { printf '  PASS %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*" >&2; exit 1; }

assert_bootstrap_order() {
    local file="$1" repo_line runner_line refresh_line
    repo_line=$(LC_ALL=C grep -nE '^[[:space:]]*pkg[[:space:]]+install([[:space:]]+-[^[:space:]]+)*[[:space:]].*\<glibc-repo\>' "$file" \
        | cut -d: -f1 | sed -n '1p')
    runner_line=$(LC_ALL=C grep -nE '^[[:space:]]*pkg[[:space:]]+install([[:space:]]+-[^[:space:]]+)*[[:space:]].*\<glibc-runner\>' "$file" \
        | cut -d: -f1 | sed -n '1p')
    [[ -n "$repo_line" && -n "$runner_line" && "$repo_line" -lt "$runner_line" ]] \
        || fail "$file does not install glibc-repo before glibc-runner"

    refresh_line=$(awk -v repo="$repo_line" -v runner="$runner_line" \
        'NR > repo && NR < runner && /^[[:space:]]*pkg[[:space:]]+update([[:space:]]|$)/ {print NR; exit}' "$file")
    [[ -n "$refresh_line" ]] \
        || fail "$file does not refresh metadata after enabling glibc-repo"
    pass "$file enables and refreshes glibc-repo before glibc-runner"
}

assert_bootstrap_order install.sh
assert_bootstrap_order src/setup.sh

printf '\nAll install bootstrap tests passed.\n'
