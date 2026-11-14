#!/bin/bash
# Builds Hovermate's ffmpeg.exe into out/build: the build images (base, win64 toolchain, the libraries of
# scripts.d/zz-final.sh) from this repository, then FFmpeg itself. Needs Linux with Docker and buildx.
# Output: out/build/{ffmpeg.exe,LICENSE.txt,config.log,config_components.h,FFMPEG_COMMIT,ffmpeg-source.tar.xz,
# Dockerfile,SOURCES}; hovermate/package.sh turns it into the release assets.
set -xeo pipefail
cd "$(dirname "$0")/.."

TARGET=win64
VARIANT=lgpl-hovermate
# The 8.1 addin selects the library versions BtbN pairs with FFmpeg 8.1 (nv-codec-headers SDK 13.0 and so on).
ADDIN=8.1
# The FFmpeg tag comes from the variant (the addin alone would build the release/8.1 branch head).
export GIT_BRANCH_OVERRIDE="$(source "variants/${TARGET}-${VARIANT}.sh" && echo "$GIT_BRANCH")"

# Fetch only the library sources this variant's Dockerfile mounts.
./generate.sh "$TARGET" "$VARIANT" "$ADDIN"
SOURCES="$(sed -n 's|.*--mount=src=\(\.cache/downloads/[^,]*\.tar\.xz\),.*|\1|p' Dockerfile | sort -u)"
[[ -n "$SOURCES" ]]
export FFBUILD_DL_STAGES="$(basename -a $SOURCES | sed 's/_[0-9a-f]\{64\}\.tar\.xz$//' | xargs)"

./makeimage.sh "$TARGET" "$VARIANT" "$ADDIN"

rm -rf out/build
FFBUILD_OUTPUT_DIR="$PWD/out/build" ./build.sh "$TARGET" "$VARIANT" "$ADDIN"

# The generated Dockerfile and the library source archives it used, for the source archive.
cp Dockerfile out/build/Dockerfile
echo "$SOURCES" > out/build/SOURCES
ls -la out/build
