#!/usr/bin/env bash
# Build the Android-patched Termux glibc recipe for a final managed prefix.
set -euo pipefail

usage() {
    echo "Usage: profiles/build-managed-runtime.sh <profile-id> <release-tag> <glibcx-commit> <builder-image@sha256:digest> <output-dir>" >&2
    exit 1
}

[[ $# -eq 5 ]] || usage
PROFILE_ID="$1"
RELEASE_TAG="$2"
GLIBCX_COMMIT="$3"
BUILDER_IMAGE="$4"
OUTPUT_DIR="$5"
LOCK_FILE="profiles/runtime-source.lock.json"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-}"

[[ "$PROFILE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || usage
[[ "$RELEASE_TAG" =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]] || usage
[[ "$GLIBCX_COMMIT" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "$BUILDER_IMAGE" =~ ^ghcr[.]io/termux/package-builder-cgct@sha256:[0-9a-f]{64}$ ]] || usage
[[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] || usage
[[ -f "$LOCK_FILE" && ! -e "$OUTPUT_DIR" ]] || usage

for command_name in bsdtar curl docker git jq sha256sum; do
    command -v "$command_name" >/dev/null 2>&1 \
        || { echo "[profile-build] Error: missing command '$command_name'." >&2; exit 1; }
done

read_lock() { jq -er ".$1" "$LOCK_FILE"; }
glibc_repository=$(read_lock glibc_packages_repository)
glibc_commit=$(read_lock glibc_packages_commit)
termux_repository=$(read_lock termux_packages_repository)
termux_commit=$(read_lock termux_packages_commit)
glibc_version=$(read_lock glibc_version)
package_revision=$(read_lock termux_package_revision)
source_url=$(read_lock source_url)
source_sha256=$(read_lock source_sha256)

[[ "$glibc_commit" =~ ^[0-9a-f]{40}$ && "$termux_commit" =~ ^[0-9a-f]{40}$ \
    && "$source_sha256" =~ ^[0-9a-f]{64}$ ]] \
    || { echo "[profile-build] Error: invalid pinned source lock." >&2; exit 1; }

output_parent=$(dirname "$OUTPUT_DIR")
output_name=$(basename "$OUTPUT_DIR")
mkdir -p "$output_parent"
build_root=$(mktemp -d "${output_parent}/.managed-runtime.XXXXXX")
cleanup() { rm -rf "${build_root:?}"; }
trap cleanup EXIT

clone_pinned() {
    local repository="$1" commit="$2" destination="$3"
    git init -q "$destination"
    git -C "$destination" remote add origin "$repository"
    git -C "$destination" fetch -q --depth 1 origin "$commit"
    git -C "$destination" -c advice.detachedHead=false checkout -q FETCH_HEAD
    [[ "$(git -C "$destination" rev-parse HEAD)" == "$commit" ]]
}

glibc_tree="${build_root}/glibc-packages"
termux_tree="${build_root}/termux-packages"
clone_pinned "$glibc_repository" "$glibc_commit" "$glibc_tree"
clone_pinned "$termux_repository" "$termux_commit" "$termux_tree"

for build_item in build-package.sh clean.sh packages x11-packages root-packages scripts ndk-patches; do
    [[ -e "${termux_tree}/${build_item}" ]] \
        || { echo "[profile-build] Error: missing upstream build item '$build_item'." >&2; exit 1; }
    cp -a "${termux_tree}/${build_item}" "$glibc_tree/"
done

final_prefix="/data/data/com.termux/files/usr/opt/glibcx/runtimes/${PROFILE_ID}"
properties_file="${glibc_tree}/scripts/properties.sh"
grep -Fqx 'TERMUX__PREFIX_GLIBC_SUBDIR="glibc"' "$properties_file" \
    || { echo "[profile-build] Error: upstream glibc-prefix property changed." >&2; exit 1; }
sed -i "s|^TERMUX__PREFIX_GLIBC_SUBDIR=\"glibc\"$|TERMUX__PREFIX_GLIBC_SUBDIR=\"opt/glibcx/runtimes/${PROFILE_ID}\"|" \
    "$properties_file"

recipe="${glibc_tree}/gpkg/glibc/build.sh"
grep -Fqx "TERMUX_PKG_VERSION=${glibc_version}" "$recipe"
grep -Fqx "TERMUX_PKG_REVISION=${package_revision}" "$recipe"
grep -Fqx "TERMUX_PKG_SRCURL=https://ftp.gnu.org/gnu/libc/glibc-\$TERMUX_PKG_VERSION.tar.xz" "$recipe"
grep -Fqx "TERMUX_PKG_SHA256=${source_sha256}" "$recipe"

(
    cd "$glibc_tree"
    TERMUX_BUILDER_IMAGE_NAME="$BUILDER_IMAGE" \
        ./scripts/run-docker.sh ./build-package.sh \
            -a aarch64 --format pacman --library glibc glibc
)

package_root="${build_root}/package-root"
mkdir -p "$package_root"
package_count=0
while IFS= read -r -d '' package_file; do
    bsdtar -xf "$package_file" -C "$package_root"
    package_count=$((package_count + 1))
done < <(find "${glibc_tree}/output" -maxdepth 1 -type f \
    \( -name '*.pkg.tar.xz' -o -name '*.pkg.tar.zst' \) -print0 | LC_ALL=C sort -z)
(( package_count > 0 )) \
    || { echo "[profile-build] Error: Termux build produced no package archives." >&2; exit 1; }

prepared_tree="${package_root}/${final_prefix#/}"
[[ -f "${prepared_tree}/lib/ld-linux-aarch64.so.1" \
    && -f "${prepared_tree}/lib/libc.so.6" ]] \
    || { echo "[profile-build] Error: built package lacks the final-prefix loader/libc pair." >&2; exit 1; }

source_tree="${build_root}/corresponding-source"
mkdir -p "${source_tree}/build-material"
source_archive="${source_tree}/glibc-${glibc_version}.tar.xz"
curl -fsSL --proto '=https' --tlsv1.2 "$source_url" -o "$source_archive"
printf '%s  %s\n' "$source_sha256" "${source_archive##*/}" \
    | (cd "$source_tree" && LC_ALL=C sha256sum -c - >/dev/null)
# Corresponding source includes every build script and package recipe available
# to the exact build invocation, not merely links to moving upstream branches.
(
    cd "$glibc_tree"
    LC_ALL=C tar -cf - \
        build-package.sh clean.sh repo.json big-pkgs.list \
        scripts ndk-patches packages gpkg/glibc
) | (cd "${source_tree}/build-material" && LC_ALL=C tar -xf -)
cp "${glibc_tree}/LICENSE.md" "${source_tree}/glibc-packages-LICENSE.md"
cp "${termux_tree}/LICENSE.md" "${source_tree}/termux-packages-LICENSE.md"
cp "$LOCK_FILE" "${source_tree}/runtime-source.lock.json"
cp profiles/README.md "${source_tree}/BUILDING.md"

payload_root="${build_root}/payload"
corresponding_source_url="https://github.com/dsecurity49/glibcx/releases/download/${RELEASE_TAG}/glibcx-runtime-${PROFILE_ID}-source.tar.xz"
env \
    GLIBC_VERSION="$glibc_version" \
    TERMUX_PACKAGE_REVISION="$package_revision" \
    TERMUX_GLIBC_COMMIT="$glibc_commit" \
    BUILD_SOURCE_URL="$source_url" \
    BUILD_SOURCE_SHA256="$source_sha256" \
    CORRESPONDING_SOURCE_URL="$corresponding_source_url" \
    TOOLCHAIN_DESCRIPTION="$BUILDER_IMAGE; termux-packages@$termux_commit" \
    SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    bash profiles/prepare-profile.sh \
        "$PROFILE_ID" "$prepared_tree" "$final_prefix" "$payload_root"

stage="${build_root}/${output_name}"
mkdir -p "$stage/payload"
mv "${payload_root}/${PROFILE_ID}.payload" "$stage/payload/"
mv "$source_tree" "$stage/corresponding-source"
jq -n \
    --arg profile_id "$PROFILE_ID" \
    --arg release_tag "$RELEASE_TAG" \
    --arg glibcx_commit "$GLIBCX_COMMIT" \
    --arg glibc_packages_commit "$glibc_commit" \
    --arg termux_packages_commit "$termux_commit" \
    --arg source_sha256 "$source_sha256" \
    --arg builder_image "$BUILDER_IMAGE" \
    --argjson source_date_epoch "$SOURCE_DATE_EPOCH" \
    '{
        schema: 1,
        profile_id: $profile_id,
        release_tag: $release_tag,
        glibcx_commit: $glibcx_commit,
        glibc_packages_commit: $glibc_packages_commit,
        termux_packages_commit: $termux_packages_commit,
        source_sha256: $source_sha256,
        builder_image: $builder_image,
        source_date_epoch: $source_date_epoch
    }' >"${stage}/build-metadata.json"

mv "$stage" "$OUTPUT_DIR"
printf '[profile-build] Prepared release artifact: %s\n' "$OUTPUT_DIR"
