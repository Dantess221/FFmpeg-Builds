#!/bin/bash
# Hovermate: one static ffmpeg.exe (LGPL-2.1-or-later) with only the protocols, formats, codecs and filters
# the product runs. The expected component lists are hovermate/required/*.txt (checked in CI).
# External libraries are listed in scripts.d/zz-final.sh (Hovermate branch). Build with hovermate/build.sh: it adds
# the 8.1 addin (library versions for FFmpeg 8.1) and builds the tag in GIT_BRANCH below.

# Software H.264 through Cisco's libopenh264. Off: a binary we build ourselves is not covered by Cisco's
# H.264 patent licence, so software H.264 goes through h264_mf (Media Foundation) next to nvenc, amf and qsv.
# To bring it back set 1 here and add "libopenh264" to hovermate/required/encoders.txt.
HOVERMATE_LIBOPENH264=0

FF_CONFIGURE="--disable-debug --disable-autodetect --disable-everything --disable-doc --disable-network"
FF_CONFIGURE+=" --disable-ffplay --disable-ffprobe --disable-shared --enable-static"
FF_CONFIGURE+=" --enable-protocol=file,pipe"
FF_CONFIGURE+=" --enable-demuxer=mpegts,mov,wav,concat --enable-indev=lavfi"
FF_CONFIGURE+=" --enable-muxer=mp4,mov,matroska,webm,gif,wav,image2,null"
FF_CONFIGURE+=" --enable-parser=h264,hevc,aac"
FF_CONFIGURE+=" --enable-decoder=h264,hevc,aac,pcm_s16le"
FF_CONFIGURE+=" --enable-encoder=aac,prores_ks,gif,mjpeg,pcm_s16le,libvpx_vp9,libopus"
FF_CONFIGURE+=",h264_nvenc,hevc_nvenc,h264_amf,hevc_amf,h264_qsv,hevc_qsv,h264_mf,hevc_mf"
if [[ $HOVERMATE_LIBOPENH264 == 1 ]]; then FF_CONFIGURE+=",libopenh264"; fi
FF_CONFIGURE+=" --enable-filter=scale,fps,format,aformat,null,anull,split,asplit,amix,alimiter,alphamerge,overlay"
FF_CONFIGURE+=",palettegen,paletteuse,tpad,unpremultiply,color,aresample"
FF_CONFIGURE+=" --enable-bsf=extract_extradata,h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc,vp9_superframe,null"
# Autodetected system features stay off (--disable-autodetect) unless named here. The external libraries
# (--enable-libvpx, --enable-libopus, --enable-ffnvcodec, --enable-amf, --enable-libvpl) come from their stages.
FF_CONFIGURE+=" --enable-nvenc --enable-mediafoundation --enable-d3d11va --enable-dxva2"
FF_CFLAGS=""
FF_CXXFLAGS=""
FF_LDFLAGS=""
GIT_BRANCH="n8.1.3"
LICENSE_FILE="COPYING.LGPLv2.1"

package_variant() {
    IN="$1"
    OUT="$2"

    mkdir -p "$OUT"
    cp "$IN"/bin/ffmpeg.exe "$OUT"/

    # Build records for the source archive (build.sh runs from the repository root and removes ffbuild afterwards).
    cp ffbuild/ffmpeg/ffbuild/config.log "$OUT"/config.log
    cp ffbuild/ffmpeg/config_components.h "$OUT"/config_components.h
    git -C ffbuild/ffmpeg rev-parse HEAD > "$OUT"/FFMPEG_COMMIT
    git -C ffbuild/ffmpeg archive --format=tar --prefix="ffmpeg-$GIT_BRANCH/" HEAD | xz -T0 > "$OUT"/ffmpeg-source.tar.xz
}
