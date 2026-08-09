#!/usr/bin/env bash
# Validate accepted, sanitized community device reports.
set -euo pipefail

results_dir="${1:-docs/device-results}"
[[ -d "$results_dir" ]] || { echo "Missing device-results directory: $results_dir" >&2; exit 1; }

report_count=0
while IFS= read -r -d '' report; do
    report_count=$((report_count + 1))
    case "${report##*/}" in
        *[!a-z0-9._-]*|.*|*..*)
            echo "Invalid device-result filename: ${report##*/}" >&2
            exit 1
            ;;
    esac
    jq -e '
        .schema == 1
        and (.tested_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
        and (.overall | IN("pass", "fail"))
        and (.source.commit | test("^[0-9a-f]{40}$"))
        and .source.tracked_changes == false
        and (.device.android_release | type == "string" and length > 0)
        and (.device.sdk | type == "number" and floor == . and . >= 21 and . <= 100)
        and (.device.manufacturer | type == "string" and length > 0 and length <= 80)
        and (.device.model | type == "string" and length > 0 and length <= 120)
        and .device.abi == "arm64-v8a"
        and (.device.kernel_release | type == "string" and length > 0 and length <= 160)
        and (.device.page_size | IN(4096, 16384, 65536))
        and (.device.selinux | IN("enforcing", "permissive", "disabled", "unknown"))
        and (.termux.apk_release | IN("F_DROID", "GITHUB", "GOOGLE_PLAY_STORE", "unknown"))
        and (.termux.version | type == "string" and length > 0 and length <= 80)
        and (.termux.target_sdk | type == "number" and floor == . and . >= 0 and . <= 100)
        and (.termux.termux_tools_version | type == "string" and length > 0 and length <= 80)
        and (.termux.glibc_runner_version | type == "string" and length > 0 and length <= 80)
        and (.termux.ld_preload_name | type == "string" and length <= 160)
        and (.tests | type == "array" and length == 5)
        and ([.tests[].id] | sort == ["build", "integration", "proc_exe", "repository", "state"])
        and all(.tests[];
            (.description | type == "string" and length > 0 and length <= 120)
            and (.status | IN("pass", "fail"))
            and (.exit_code | type == "number" and floor == . and . >= 0 and . <= 255)
            and (.log | test("^logs/[a-z0-9_-]+[.]log$"))
        )
        and ((.overall == "pass") == all(.tests[]; .status == "pass"))
        and (.issue_url == null or (.issue_url | test("^https://github[.]com/dsecurity49/glibcx/issues/[1-9][0-9]*$")))
    ' "$report" >/dev/null || { echo "Invalid device report: $report" >&2; exit 1; }
    if LC_ALL=C grep -Eqi \
        '/data/(data|user)/|TERMUX__UID|TERMUX_APP__PID|APK_FILE=|(^|[^A-Za-z])(gh[pousr]_|github_pat_)' \
        "$report"; then
        echo "Device report contains private or unnecessary runtime data: $report" >&2
        exit 1
    fi
done < <(find "$results_dir" -maxdepth 1 -type f -name '*.json' -print0 | LC_ALL=C sort -z)

printf 'Validated %d accepted device report(s).\n' "$report_count"
