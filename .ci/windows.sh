#!/bin/sh -ex

mkdir -p build
cd build

if [ "$GITHUB_REF_TYPE" == "tag" ]; then
	export EXTRA_CMAKE_FLAGS=(-DENABLE_QT_UPDATE_CHECKER=ON)
fi

# FFmpeg 7.x is required but is not provisioned on these runners (the MSVC job has no
# FFmpeg at all, and MSYS2 ships a newer major version), so build without it.
# The MSYS2 toolchain is also missing the <vector> include in dynarmic.
if [ "$TARGET" = "msys2" ]; then
    EXTRA_CMAKE_FLAGS+=("-DCMAKE_CXX_FLAGS=-include vector")
    # Newer MSYS2 ships an endian.h without htobe32/htobe64, which makes LibreSSL skip its own
    # compat header. Force the compat one, as with older toolchains.
    EXTRA_CMAKE_FLAGS+=("-DHAVE_ENDIAN_H=0")
fi

# zlib for libzip, installed with vcpkg in the workflow.
if [ "$TARGET" = "msvc" ]; then
    EXTRA_CMAKE_FLAGS+=("-DZLIB_ROOT=C:/vcpkg/installed/x64-windows-static-md")
fi

cmake .. -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_FFMPEG=OFF \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    -DENABLE_QT_TRANSLATION=ON \
    -DUSE_DISCORD_PRESENCE=ON \
	"${EXTRA_CMAKE_FLAGS[@]}"
ninja
ninja bundle
strip -s bundle/*.exe

ccache -s -v

ctest -VV -C Release || echo "::error ::Test error occurred on Windows build"
