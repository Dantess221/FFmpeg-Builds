#!/bin/bash

SCRIPT_SKIP="1"

ffbuild_depends() {
    if [[ $VARIANT == *hovermate* ]]; then
        # Hovermate links only these (licences: MIT, MIT, BSD-3-Clause, BSD-3-Clause, MIT).
        # libopenh264 (BSD-2-Clause) is opt-in through HOVERMATE_LIBOPENH264 in the variant.
        source "variants/${TARGET}-${VARIANT}.sh"
        echo amf
        echo ffnvcodec
        echo libopus
        echo libvpx
        echo onevpl
        if [[ $HOVERMATE_LIBOPENH264 == 1 ]]; then echo openh264; fi
        return 0
    fi

    echo libiconv
    echo zlib
    echo fribidi
    echo gmp
    echo libxml2
    echo openssl
    echo xz
    echo fonts
    echo lcevcdec
    echo lcms2
    echo libvorbis
    echo opencl
    echo pulseaudio
    echo vmaf
    echo x11
    echo vulkan
    echo amf
    echo aom
    echo avisynth
    echo chromaprint
    echo dav1d
    echo davs2
    echo dvd
    echo fdk-aac
    echo ffnvcodec
    echo frei0r
    echo gme
    echo kvazaar
    echo libaribb24
    echo libaribcaption
    echo libass
    echo libbluray
    echo libcurl
    echo libjxl
    echo libmp3lame
    echo libopus
    echo libplacebo
    echo libpng
    echo librist
    echo librsvg
    echo libssh
    echo libtheora
    echo libvpx
    echo libwebp
    echo libzmq
    echo lilv
    echo onevpl
    echo openal
    echo openapv
    echo opencore-amr
    echo openh264
    echo openjpeg
    echo openmpt
    echo rav1e
    echo rubberband
    echo rustdedup
    echo schannel
    echo sdl
    echo snappy
    echo soxr
    echo srt
    echo svtav1
    echo twolame
    echo uavs3d
    echo vaapi
    echo vapoursynth
    echo vidstab
    echo vvenc
    echo whisper
    echo x264
    echo x265
    echo xavs2
    echo xvid
    echo zimg
    echo zvbi
}

ffbuild_enabled() {
    return 0
}

ffbuild_dockerfinal() {
    return 0
}

ffbuild_dockerdl() {
    return 0
}

ffbuild_dockerlayer() {
    return 0
}

ffbuild_dockerstage() {
    return 0
}

ffbuild_dockerbuild() {
    return 0
}

ffbuild_ldexeflags() {
    return 0
}
