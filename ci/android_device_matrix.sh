#!/usr/bin/env bash
# Run the release-relevant glibcx checks on a real Termux device and create a
# sanitized report suitable for a GitHub issue.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: bash ci/android_device_matrix.sh [output-directory]

Run this from the root of a clean glibcx checkout. The optional output
directory defaults to the repository root.
USAGE
}

[[ $# -le 1 ]] || { usage >&2; exit 2; }

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"
output_dir="${1:-$repo_root}"
mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd)

required_commands=(
    awk bash clang cmp curl dpkg-query file find getprop git gpg gzip
    gpgv jq patchelf readelf sed sha256sum tar termux-info timeout uname xz
)
missing_commands=()
for command_name in "${required_commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || missing_commands+=("$command_name")
done
if (( ${#missing_commands[@]} > 0 )); then
    printf '[device-test] Missing commands:' >&2
    printf ' %s' "${missing_commands[@]}" >&2
    printf '\nSee docs/device-testing.md for the Termux package command.\n' >&2
    exit 2
fi

[[ "$(LC_ALL=C uname -o 2>/dev/null || true)" == Android ]] \
    || { echo '[device-test] This test must run inside Termux on Android.' >&2; exit 2; }
[[ "$(LC_ALL=C getprop ro.product.cpu.abi)" == arm64-v8a ]] \
    || { echo '[device-test] This release targets arm64-v8a devices.' >&2; exit 2; }
[[ -n "${PREFIX:-}" && -d "$PREFIX" ]] \
    || { echo '[device-test] PREFIX does not identify a Termux installation.' >&2; exit 2; }
[[ -x "${PREFIX}/glibc/lib/ld-linux-aarch64.so.1" ]] \
    || { echo '[device-test] glibc-runner is not installed.' >&2; exit 2; }
git diff --quiet && git diff --cached --quiet \
    || { echo '[device-test] Commit or stash tracked changes before testing.' >&2; exit 2; }

work_dir=$(mktemp -d)
cleanup() { rm -rf "${work_dir:?}"; }
trap cleanup EXIT
report_root="${work_dir}/report"
raw_log_dir="${work_dir}/raw-logs"
log_dir="${report_root}/logs"
mkdir -p "$raw_log_dir" "$log_dir"

read_page_size() {
    if command -v getconf >/dev/null 2>&1; then
        LC_ALL=C getconf PAGE_SIZE
        return
    fi
    local source_file="${work_dir}/page-size.c"
    local probe="${work_dir}/page-size"
    printf '%s\n' \
        '#include <stdio.h>' \
        '#include <unistd.h>' \
        'int main(void) {' \
        '    long value = sysconf(_SC_PAGESIZE);' \
        '    if (value <= 0) return 1;' \
        '    printf("%ld\n", value);' \
        '    return 0;' \
        '}' >"$source_file"
    clang -O2 -Wall -Wextra -Werror "$source_file" -o "$probe"
    LC_ALL=C "$probe"
}

replace_paths() {
    LC_ALL=C awk \
        -v home_path="${HOME:-}" \
        -v prefix_path="${PREFIX:-}" \
        -v repository_path="$repo_root" '
        function replace_all(line, from, to, position) {
            if (from == "") return line
            while ((position = index(line, from)) != 0)
                line = substr(line, 1, position - 1) to substr(line, position + length(from))
            return line
        }
        {
            line = replace_all($0, repository_path, "<REPOSITORY>")
            line = replace_all(line, prefix_path, "<PREFIX>")
            line = replace_all(line, home_path, "<HOME>")
            gsub(/gh[pousr]_[A-Za-z0-9_]+/, "<REDACTED_GITHUB_TOKEN>", line)
            gsub(/github_pat_[A-Za-z0-9_]+/, "<REDACTED_GITHUB_TOKEN>", line)
            print line
        }
    '
}

tests_json='[]'
overall=pass
run_test() {
    local test_id="$1" description="$2" timeout_value="$3"
    shift 3
    local raw_log="${raw_log_dir}/${test_id}.log"
    local clean_log="${log_dir}/${test_id}.log"
    local exit_code status
    printf '[device-test] %-24s ' "$description"
    if timeout "$timeout_value" "$@" >"$raw_log" 2>&1; then
        exit_code=0
        status=pass
        printf 'PASS\n'
    else
        exit_code=$?
        status=fail
        overall=fail
        printf 'FAIL (exit %s)\n' "$exit_code"
    fi
    replace_paths <"$raw_log" >"$clean_log"
    tests_json=$(jq -c \
        --arg id "$test_id" \
        --arg description "$description" \
        --arg status "$status" \
        --argjson exit_code "$exit_code" \
        --arg log "logs/${test_id}.log" \
        '. + [{id: $id, description: $description, status: $status,
               exit_code: $exit_code, log: $log}]' <<<"$tests_json")
}

selinux_state=unknown
if [[ -x /system/bin/getenforce ]]; then
    observed_selinux=$(LC_ALL=C /system/bin/getenforce 2>/dev/null || true)
    case "${observed_selinux,,}" in
        enforcing|permissive|disabled) selinux_state=${observed_selinux,,} ;;
    esac
fi
if [[ "$selinux_state" == unknown && -r /sys/fs/selinux/enforce ]]; then
    case "$(LC_ALL=C cat /sys/fs/selinux/enforce 2>/dev/null || true)" in
        1) selinux_state=enforcing ;;
        0) selinux_state=permissive ;;
    esac
fi

termux_info_file="${work_dir}/termux-info"
LC_ALL=C termux-info >"$termux_info_file" 2>/dev/null || true
termux_version=$(LC_ALL=C sed -n 's/^TERMUX_VERSION=//p' "$termux_info_file" | head -n 1)
termux_release=$(LC_ALL=C sed -n 's/^TERMUX_APP__APK_RELEASE=//p' "$termux_info_file" | head -n 1)
termux_target_sdk=$(LC_ALL=C sed -n 's/^TERMUX_APP__TARGET_SDK=//p' "$termux_info_file" | head -n 1)
[[ -n "$termux_version" ]] || termux_version=unknown
case "$termux_release" in
    F_DROID|GITHUB|GOOGLE_PLAY_STORE) ;;
    *) termux_release=unknown ;;
esac
[[ "$termux_target_sdk" =~ ^[0-9]+$ ]] || termux_target_sdk=0

glibc_runner_version=$(LC_ALL=C dpkg-query -W -f='${Version}' glibc-runner 2>/dev/null || true)
termux_tools_version=$(LC_ALL=C dpkg-query -W -f='${Version}' termux-tools 2>/dev/null || true)
commit=$(LC_ALL=C git rev-parse HEAD)
tested_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
sdk=$(LC_ALL=C getprop ro.build.version.sdk)
android_release=$(LC_ALL=C getprop ro.build.version.release)
manufacturer=$(LC_ALL=C getprop ro.product.manufacturer)
model=$(LC_ALL=C getprop ro.product.model)
abi=$(LC_ALL=C getprop ro.product.cpu.abi)
kernel_release=$(LC_ALL=C uname -r)
page_size=$(read_page_size)
ld_preload_name="${LD_PRELOAD:-}"
ld_preload_name=${ld_preload_name##*/}
[[ "$sdk" =~ ^[0-9]+$ && "$page_size" =~ ^[0-9]+$ ]] \
    || { echo '[device-test] Android SDK or page size could not be read.' >&2; exit 2; }

run_test build 'source build' 5m bash -c 'bash build.sh && cmp -s glibcx glibcx-bin'
run_test state 'atomic state and wrapper' 15m bash ci/termux_state_smoke_test.sh
run_test integration 'AArch64 integration' 15m bash ci/integration_test.sh
run_test proc_exe 'proc-exe compatibility' 10m bash ci/proc_exe_test.sh
run_test repository 'live repository contract' 15m bash ci/live_repository_probe.sh

jq -n \
    --arg tested_at "$tested_at" \
    --arg overall "$overall" \
    --arg commit "$commit" \
    --arg android_release "$android_release" \
    --argjson sdk "$sdk" \
    --arg manufacturer "$manufacturer" \
    --arg model "$model" \
    --arg abi "$abi" \
    --arg kernel_release "$kernel_release" \
    --argjson page_size "$page_size" \
    --arg selinux "$selinux_state" \
    --arg termux_release "$termux_release" \
    --arg termux_version "$termux_version" \
    --argjson termux_target_sdk "$termux_target_sdk" \
    --arg termux_tools_version "$termux_tools_version" \
    --arg glibc_runner_version "$glibc_runner_version" \
    --arg ld_preload_name "$ld_preload_name" \
    --argjson tests "$tests_json" '
    {
        schema: 1,
        tested_at: $tested_at,
        overall: $overall,
        source: {commit: $commit, tracked_changes: false},
        device: {
            android_release: $android_release,
            sdk: $sdk,
            manufacturer: $manufacturer,
            model: $model,
            abi: $abi,
            kernel_release: $kernel_release,
            page_size: $page_size,
            selinux: $selinux
        },
        termux: {
            apk_release: $termux_release,
            version: $termux_version,
            target_sdk: $termux_target_sdk,
            termux_tools_version: $termux_tools_version,
            glibc_runner_version: $glibc_runner_version,
            ld_preload_name: $ld_preload_name
        },
        tests: $tests,
        issue_url: null
    }' >"${report_root}/report.json"

slug=$(printf '%s-%s' "$manufacturer" "$model" \
    | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C sed 's/[^a-z0-9._-]/-/g; s/--*/-/g; s/^-//; s/-$//')
[[ -n "$slug" ]] || slug=unknown-device
timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
archive="${output_dir}/glibcx-device-report-api${sdk}-${slug}-${page_size}-${timestamp}.tar.gz"
LC_ALL=C tar -czf "$archive" -C "$report_root" report.json logs
archive_hash=$(LC_ALL=C sha256sum "$archive" | LC_ALL=C awk '{print $1}')

printf '\n[device-test] Result: %s\n' "${overall^^}"
printf '[device-test] Report: %s\n' "$archive"
printf '[device-test] SHA-256: %s\n' "$archive_hash"
if [[ "$overall" == fail ]]; then
    printf '[device-test] Attach the report to a device-test issue; failures are useful too.\n'
    exit 1
fi
printf '[device-test] Attach the report to a device-test issue or include report.json in a PR.\n'
