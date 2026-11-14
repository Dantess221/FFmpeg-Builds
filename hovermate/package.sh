#!/bin/bash
# Turns out/build (hovermate/build.sh) into the release assets in out/release:
#   hovermate-ffmpeg-<version>-win64-lgpl.zip   ffmpeg.exe, LICENSE.txt, THIRD_PARTY_LICENSES.txt, BUILDINFO.txt, SOURCE.txt
#   hovermate-ffmpeg-<version>-win64-lgpl.zip.sha256
#   hovermate-ffmpeg-<version>-source.tar.xz    FFmpeg, every library at its pinned commit, these build scripts,
#                                               the generated Dockerfile, config.log and config_components.h
#   manifest.json
# Usage: hovermate/package.sh <version>   (version: e.g. n8.1.3-1 for tag hovermate-n8.1.3-1)
set -eo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?version}"
TAG="hovermate-$VERSION"
BUILD="out/build"
OUT="out/release"
NAME="hovermate-ffmpeg-$VERSION"
SERVER="${GITHUB_SERVER_URL:-https://github.com}"
REPOSITORY="${GITHUB_REPOSITORY:-$(git remote get-url origin | sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##')}"
REPO_URL="$SERVER/$REPOSITORY"
BUILD_COMMIT="$(git rev-parse HEAD)"
FFMPEG_TAG="$(source variants/win64-lgpl-hovermate.sh && echo "$GIT_BRANCH")"
FFMPEG_COMMIT="$(cat "$BUILD/FFMPEG_COMMIT")"
CONFIGURE="$(head -n 1 "$BUILD/config.log" | sed 's/^# //')"

for file in ffmpeg.exe LICENSE.txt config.log config_components.h FFMPEG_COMMIT ffmpeg-source.tar.xz Dockerfile SOURCES; do
    [[ -s "$BUILD/$file" ]] || { echo "Missing build output: $file" >&2; exit 1; }
done
grep -q 'GNU LESSER GENERAL PUBLIC LICENSE' "$BUILD/LICENSE.txt" && grep -q 'Version 2.1' "$BUILD/LICENSE.txt"
if grep -Eq -- '--enable-(gpl|nonfree|version3)' <<<"$CONFIGURE"; then
    echo "The configuration is not LGPL-2.1-or-later: $CONFIGURE" >&2
    exit 1
fi

rm -rf "$OUT" out/package
mkdir -p "$OUT" out/package
WORK="$(realpath out/package)"
SRC="$WORK/$NAME-source"
BIN="$WORK/bin"
mkdir -p "$SRC/libraries" "$BIN"

# Library sources: one archive per build stage (the download cache the Dockerfile mounted).
declare -A STAGE_FILES
while read -r archive; do
    [[ -n "$archive" ]] || continue
    stage="$(basename "$archive" | sed 's/_[0-9a-f]\{64\}\.tar\.xz$//')"
    STAGE_FILES[$stage]="$archive"
    mkdir -p "$SRC/libraries/$stage"
    tar -xJf "$archive" -C "$SRC/libraries/$stage"
done < "$BUILD/SOURCES"

stage_repo() { ( source "scripts.d/$1.sh" && echo "${!2}" ); }

# name | stage | licence | repository variable | commit variable (ffnvcodec: the SDK 13.0 checkout the 8.1 addin builds)
COMPONENTS=(
    "libvpx|50-libvpx|BSD-3-Clause|SCRIPT_REPO|SCRIPT_COMMIT"
    "libopus|50-libopus|BSD-3-Clause|SCRIPT_REPO|SCRIPT_COMMIT"
    "libvpl (oneVPL dispatcher)|50-onevpl|MIT|SCRIPT_REPO|SCRIPT_COMMIT"
    "nv-codec-headers|50-ffnvcodec|MIT|SCRIPT_REPO2|SCRIPT_COMMIT2"
    "AMF headers|50-amf|MIT|SCRIPT_REPO|SCRIPT_COMMIT"
    "mingw-w64 runtime and winpthreads|10-mingw|ZPL-2.1 AND MIT|SCRIPT_REPO|SCRIPT_COMMIT"
)

licence_text() {
    local root="$SRC/libraries/$1"
    case "$1" in
    50-libvpx) cat "$root/LICENSE"; echo; echo "Additional IP rights grant (patents):"; echo; cat "$root/PATENTS" ;;
    50-libopus) cat "$root/COPYING" ;;
    50-onevpl) cat "$root/LICENSE" ;;
    50-ffnvcodec) sed -n '1,/^ \*\//p' "$root/ffnvcodec2/include/ffnvcodec/nvEncodeAPI.h" ;;
    50-amf) cat "$root/LICENSE.txt" ;;
    10-mingw)
        cat "$root/mingw/COPYING.MinGW-w64-runtime/COPYING.MinGW-w64-runtime.txt"
        echo; echo "winpthreads:"; echo
        cat "$root/mingw/mingw-w64-libraries/winpthreads/COPYING" ;;
    *) echo "No licence mapping for $1" >&2; return 1 ;;
    esac
}

{
    echo "Third-party components statically linked into ffmpeg.exe"
    echo "FFmpeg itself is licensed under the GNU Lesser General Public License, version 2.1 or later (LICENSE.txt)."
    echo
    for entry in "${COMPONENTS[@]}"; do
        IFS='|' read -r label stage licence repo_var commit_var <<<"$entry"
        [[ -n "${STAGE_FILES[$stage]}" ]] || { echo "Stage $stage was not part of the build" >&2; exit 1; }
        echo "================================================================================"
        echo "$label ($licence)"
        echo "Source: $(stage_repo "$stage" "$repo_var") at $(stage_repo "$stage" "$commit_var")"
        echo "================================================================================"
        echo
        licence_text "$stage"
        echo
    done
    echo "================================================================================"
    echo "GCC runtime (libgcc, libstdc++; GPL-3.0-or-later WITH GCC-exception-3.1)"
    echo "================================================================================"
    echo
    echo "Parts of the GCC runtime are linked into ffmpeg.exe by the GCC toolchain (crosstool-ng configuration"
    echo "images/base-win64/ct-ng-config in the build scripts). The GCC Runtime Library Exception 3.1 permits"
    echo "distributing the resulting executable under terms of the distributor's choice."
} > "$BIN/THIRD_PARTY_LICENSES.txt"

LIBRARY_LINES="$(for entry in "${COMPONENTS[@]}"; do
    IFS='|' read -r label stage licence repo_var commit_var <<<"$entry"
    printf '  %s: %s @ %s (%s)\n' "$label" "$(stage_repo "$stage" "$repo_var")" "$(stage_repo "$stage" "$commit_var")" "$licence"
done)"

cat > "$BIN/BUILDINFO.txt" <<EOF
Hovermate FFmpeg $VERSION (win64, static, LGPL-2.1-or-later)

FFmpeg: $FFMPEG_TAG, commit $FFMPEG_COMMIT (https://github.com/FFmpeg/FFmpeg), no source changes.
Build scripts: $REPO_URL, commit $BUILD_COMMIT
  (fork of BtbN/FFmpeg-Builds; variant win64-lgpl-hovermate with the 8.1 addin; hovermate/build.sh)
Libraries:
$LIBRARY_LINES

Configure:
$CONFIGURE
EOF

cat > "$BIN/SOURCE.txt" <<EOF
Hovermate FFmpeg $VERSION: source code

ffmpeg.exe is FFmpeg $FFMPEG_TAG built without source changes, licensed under the GNU Lesser General Public
License, version 2.1 or later (LICENSE.txt). The libraries linked into it are listed with their licences in
THIRD_PARTY_LICENSES.txt; the configure command is in BUILDINFO.txt.

Complete corresponding source (FFmpeg, every library at its pinned commit, the build scripts, the generated
Dockerfile, config.log):
  $REPO_URL/releases/download/$TAG/$NAME-source.tar.xz
Release: $REPO_URL/releases/tag/$TAG
Build scripts: $REPO_URL/tree/$BUILD_COMMIT
FFmpeg: https://github.com/FFmpeg/FFmpeg/tree/$FFMPEG_TAG (https://ffmpeg.org/download.html)
EOF

cp "$BUILD/ffmpeg.exe" "$BUILD/LICENSE.txt" "$BIN/"
for file in "$BIN"/*.txt; do sed -i 's/$/\r/' "$file"; done
(cd "$BIN" && TZ=UTC touch -d '2000-01-01 00:00:00' * && zip -X -9 -D "$WORK/$NAME-win64-lgpl.zip" ffmpeg.exe LICENSE.txt THIRD_PARTY_LICENSES.txt BUILDINFO.txt SOURCE.txt)
mv "$WORK/$NAME-win64-lgpl.zip" "$OUT/"
(cd "$OUT" && sha256sum "$NAME-win64-lgpl.zip" > "$NAME-win64-lgpl.zip.sha256")

# Source archive.
tar -xJf "$BUILD/ffmpeg-source.tar.xz" -C "$SRC"
mkdir -p "$SRC/build-scripts"
git archive --format=tar HEAD | tar -x -C "$SRC/build-scripts"
cp "$BUILD/Dockerfile" "$BUILD/config.log" "$BUILD/config_components.h" "$SRC/"
cp "$BIN/BUILDINFO.txt" "$BIN/THIRD_PARTY_LICENSES.txt" "$SRC/"
cp "$BUILD/LICENSE.txt" "$SRC/LICENSE.txt"
cat > "$SRC/README.txt" <<EOF
Source of Hovermate FFmpeg $VERSION ($REPO_URL/releases/tag/$TAG).

ffmpeg-$FFMPEG_TAG/  FFmpeg at commit $FFMPEG_COMMIT (unmodified)
libraries/<stage>/   each library and toolchain runtime source as the build fetched it (build-scripts/scripts.d/<stage>.sh)
build-scripts/       the build scripts at commit $BUILD_COMMIT; rebuild with build-scripts/hovermate/build.sh
Dockerfile           the generated build image definition
config.log           FFmpeg's configure log (first line: the configure command)
config_components.h  the FFmpeg components the configuration enabled
EOF
TZ=UTC tar --sort=name --mtime='2000-01-01 00:00:00' --owner=0 --group=0 --numeric-owner \
    -C "$WORK" -cf - "$NAME-source" | xz -T0 -9 > "$OUT/$NAME-source.tar.xz"

asset_json() {
    jq -n --arg name "$(basename "$1")" --arg sha256 "$(sha256sum "$1" | cut -d' ' -f1)" --argjson size "$(stat -c %s "$1")" \
        '{name: $name, sha256: $sha256, size: $size}'
}
COMPONENTS_JSON="$(for entry in "${COMPONENTS[@]}"; do
    IFS='|' read -r label stage licence repo_var commit_var <<<"$entry"
    jq -n --arg name "$label" --arg stage "$stage" --arg license "$licence" \
        --arg repository "$(stage_repo "$stage" "$repo_var")" --arg commit "$(stage_repo "$stage" "$commit_var")" \
        '{name: $name, stage: $stage, license: $license, repository: $repository, commit: $commit}'
done | jq -s .)"
jq -n \
    --arg version "$VERSION" --arg tag "$TAG" --arg release "$REPO_URL/releases/tag/$TAG" \
    --arg ffmpeg_tag "$FFMPEG_TAG" --arg ffmpeg_commit "$FFMPEG_COMMIT" \
    --arg build_repository "$REPO_URL" --arg build_commit "$BUILD_COMMIT" --arg configure "$CONFIGURE" \
    --argjson exe "$(asset_json "$BUILD/ffmpeg.exe")" \
    --argjson zip "$(asset_json "$OUT/$NAME-win64-lgpl.zip")" \
    --argjson source "$(asset_json "$OUT/$NAME-source.tar.xz")" \
    --argjson components "$COMPONENTS_JSON" \
    '{
        name: "hovermate-ffmpeg", version: $version, tag: $tag, release: $release,
        license: "LGPL-2.1-or-later", target: "win64", linkage: "static",
        ffmpeg: {tag: $ffmpeg_tag, commit: $ffmpeg_commit, repository: "https://github.com/FFmpeg/FFmpeg", patches: []},
        build: {repository: $build_repository, commit: $build_commit, variant: "win64-lgpl-hovermate", addin: "8.1", configure: $configure},
        components: $components,
        files: {"ffmpeg.exe": $exe},
        assets: [$zip, $source]
    }' > "$OUT/manifest.json"

rm -rf out/package
ls -la "$OUT"
cat "$OUT/$NAME-win64-lgpl.zip.sha256"
