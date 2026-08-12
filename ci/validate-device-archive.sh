#!/usr/bin/env bash
# Validate an untrusted archive uploaded through the device-test issue form.
set -euo pipefail

usage() {
    echo "Usage: bash ci/validate-device-archive.sh <archive.tar.gz> <output-directory>" >&2
    exit 2
}

archive=${1:-}
output_dir=${2:-}
[[ $# -eq 2 && -f "$archive" && -n "$output_dir" && ! -e "$output_dir" ]] || usage

for command_name in grep gzip jq sha256sum stat tar timeout tr wc; do
    command -v "$command_name" >/dev/null 2>&1 \
        || { echo "Required command is unavailable: $command_name" >&2; exit 1; }
done

archive_size=$(LC_ALL=C stat -c '%s' "$archive")
if (( archive_size == 0 || archive_size > 5 * 1024 * 1024 )); then
    echo "Archive must be between 1 byte and 5 MiB." >&2
    exit 1
fi

work_dir=$(mktemp -d)
cleanup() { rm -rf "${work_dir:?}"; }
trap cleanup EXIT
expanded_tar="${work_dir}/report.tar"
extract_dir="${work_dir}/extract"
validation_dir="${work_dir}/validation"
mkdir -p "$extract_dir" "$validation_dir"

# Bound the decompressed input before tar sees it. A valid report is far below
# this limit; the extra byte distinguishes an exact 10 MiB file from overflow.
set +e
set +o pipefail
timeout 30s gzip -cd "$archive" | head -c 10485761 >"$expanded_tar"
decompress_status=("${PIPESTATUS[@]}")
set -o pipefail
set -e
expanded_size=$(LC_ALL=C stat -c '%s' "$expanded_tar")
if (( expanded_size == 0 || expanded_size > 10 * 1024 * 1024 )); then
    echo "Archive expands beyond the 10 MiB review limit." >&2
    exit 1
fi
if (( decompress_status[0] != 0 || decompress_status[1] != 0 )); then
    echo "Attachment is not a complete gzip archive." >&2
    exit 1
fi
if (( expanded_size % 512 != 0 )); then
    echo "Tar data has a trailing partial block." >&2
    exit 1
fi

expected_members=$(printf '%s\n' \
    logs/ \
    logs/build.log \
    logs/integration.log \
    logs/proc_exe.log \
    logs/repository.log \
    logs/state.log \
    report.json | LC_ALL=C sort)
if ! observed_members=$(timeout 30s tar --ignore-zeros -tf "$expanded_tar"); then
    echo "Attachment does not contain a readable tar archive." >&2
    exit 1
fi
if [[ "$(printf '%s\n' "$observed_members" | LC_ALL=C sort)" != "$expected_members" ]]; then
    echo "Archive must contain only report.json and the five expected files under logs/." >&2
    exit 1
fi

while IFS= read -r listing; do
    permissions=${listing%% *}
    member=${listing##* }
    case "$member:$permissions" in
        logs/:d*) ;;
        report.json:-*|logs/build.log:-*|logs/integration.log:-*|logs/proc_exe.log:-*|logs/repository.log:-*|logs/state.log:-*) ;;
        *)
            echo "Archive contains a link, device, or unexpected member type: $member" >&2
            exit 1
            ;;
    esac
done < <(LC_ALL=C timeout 30s tar --ignore-zeros -tvf "$expanded_tar")

# Do not let the archive choose filesystem paths. Stream each already-vetted
# regular member into a filename selected here, and cap its logical size. This
# also rejects sparse members whose expanded contents exceed the limit.
extract_member() {
    local member="$1" destination="$2" limit="$3"
    local -a pipeline_status
    local extracted_size

    set +e
    set +o pipefail
    LC_ALL=C timeout 30s tar -xOf "$expanded_tar" "$member" \
        | head -c "$((limit + 1))" >"$destination"
    pipeline_status=("${PIPESTATUS[@]}")
    set -o pipefail
    set -e

    extracted_size=$(LC_ALL=C stat -c '%s' "$destination")
    if (( extracted_size > limit )); then
        echo "Archive member exceeds its size limit: $member" >&2
        exit 1
    fi
    if (( pipeline_status[0] != 0 || pipeline_status[1] != 0 )); then
        echo "Archive member could not be read safely: $member" >&2
        exit 1
    fi
}

extract_member report.json "${extract_dir}/report.json" $((256 * 1024))
for log_name in build integration proc_exe repository state; do
    extract_member "logs/${log_name}.log" \
        "${extract_dir}/${log_name}.log" $((4 * 1024 * 1024))
done
cp "${extract_dir}/report.json" "${validation_dir}/submitted.json"

if ! bash ci/validate-device-results.sh "$validation_dir" >/dev/null; then
    echo "report.json does not match the accepted device-report schema." >&2
    exit 1
fi
if ! jq -e '.issue_url == null' "${extract_dir}/report.json" >/dev/null; then
    echo "Uploaded report.json must have issue_url set to null." >&2
    exit 1
fi

if ! jq -e '
    ([.tests[] | {id, description, log}] | sort_by(.id)) == [
        {id: "build", description: "source build", log: "logs/build.log"},
        {id: "integration", description: "AArch64 integration", log: "logs/integration.log"},
        {id: "proc_exe", description: "proc-exe compatibility", log: "logs/proc_exe.log"},
        {id: "repository", description: "live repository contract", log: "logs/repository.log"},
        {id: "state", description: "atomic state and wrapper", log: "logs/state.log"}
    ]
    and all([
        .device.android_release,
        .device.manufacturer,
        .device.model,
        .device.kernel_release,
        .termux.version,
        .termux.termux_tools_version,
        .termux.glibc_runner_version,
        .termux.ld_preload_name
    ][]; test("^[^\u0000-\u001f\u007f`|]*$"))
' "${extract_dir}/report.json" >/dev/null; then
    echo "Report fields do not match the device-test generator output." >&2
    exit 1
fi

for log_file in "${extract_dir}"/*.log; do
    control_count=$(LC_ALL=C tr -d '\11\12\15\33\40-\176\200-\377' \
        <"$log_file" | LC_ALL=C wc -c)
    if (( control_count != 0 )); then
        echo "Report logs contain unsupported control characters." >&2
        exit 1
    fi
done

if LC_ALL=C grep -Eaiq \
    '/data/(data|user)/|TERMUX__UID|TERMUX_APP__PID|APK_FILE=|(^|[^A-Za-z])(gh[pousr]_|github_pat_)|u[0-9]+_a[0-9]+|-----BEGIN [A-Z ]*PRIVATE KEY-----|ssh-(rsa|ed25519)[[:space:]]+[A-Za-z0-9+/=]+' \
    "${extract_dir}/report.json" "${extract_dir}"/*.log; then
    echo "Archive contains a recognized private path, identifier, token, or key." >&2
    exit 1
fi

mkdir -p "$output_dir"
cp "${extract_dir}/report.json" "${output_dir}/report.json"
LC_ALL=C sha256sum "$archive" | LC_ALL=C awk '{print $1}' >"${output_dir}/archive.sha256"
printf '%s\n' "${archive##*/}" >"${output_dir}/archive-name.txt"
