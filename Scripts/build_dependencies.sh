#!/usr/bin/env bash
#
# Builds glslang and SPIRV-Cross as static libraries into ThirdParty/.
# All static libs are merged into ThirdParty/lib/libShaderDeps.a, which the
# app target links against.
#
# Environment overrides:
#   ARCHS              CMake OSX architectures (default: "arm64;x86_64")
#   DEPLOYMENT_TARGET  macOS deployment target (default: 14.0)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
THIRD="$ROOT/ThirdParty"
SRC="$THIRD/src"
PREFIX="$THIRD"

GLSLANG_TAG="vulkan-sdk-1.4.357.0"
SPIRV_CROSS_TAG="vulkan-sdk-1.4.357.0"

ARCHS="${ARCHS:-arm64;x86_64}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-14.0}"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 8)"

mkdir -p "$SRC" "$PREFIX/lib" "$PREFIX/include"

clone() { # <dir> <url> <tag>
    local dir="$1" url="$2" tag="$3"
    if [ ! -d "$SRC/$dir/.git" ]; then
        echo "==> Cloning $dir @ $tag"
        git clone --depth 1 --branch "$tag" "$url" "$SRC/$dir"
    else
        echo "==> $dir already cloned"
    fi
}

build() { # <dir> [extra cmake args...]
    local dir="$1"; shift
    echo "==> Configuring $dir"
    cmake -S "$SRC/$dir" -B "$SRC/$dir/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_OSX_ARCHITECTURES="$ARCHS" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DCMAKE_CXX_STANDARD=17 \
        -DBUILD_SHARED_LIBS=OFF \
        "$@"
    echo "==> Building $dir"
    cmake --build "$SRC/$dir/build" -j "$JOBS"
    echo "==> Installing $dir"
    cmake --install "$SRC/$dir/build"
}

clone glslang     https://github.com/KhronosGroup/glslang.git     "$GLSLANG_TAG"
clone SPIRV-Cross https://github.com/KhronosGroup/SPIRV-Cross.git "$SPIRV_CROSS_TAG"

build glslang \
    -DENABLE_OPT=OFF \
    -DENABLE_HLSL=OFF \
    -DENABLE_GLSLANG_BINARIES=OFF \
    -DGLSLANG_TESTS=OFF

build SPIRV-Cross \
    -DSPIRV_CROSS_CLI=OFF \
    -DSPIRV_CROSS_ENABLE_TESTS=OFF \
    -DSPIRV_CROSS_SHARED=OFF \
    -DSPIRV_CROSS_STATIC=ON \
    -DSPIRV_CROSS_ENABLE_HLSL=OFF \
    -DSPIRV_CROSS_ENABLE_CPP=OFF \
    -DSPIRV_CROSS_ENABLE_REFLECT=OFF \
    -DSPIRV_CROSS_ENABLE_UTIL=OFF \
    -DSPIRV_CROSS_ENABLE_C_API=OFF

echo "==> Merging static libraries into libShaderDeps.a"
rm -f "$PREFIX/lib/libShaderDeps.a"
LIBS=()
while IFS= read -r -d '' lib; do
    LIBS+=("$lib")
done < <(find "$PREFIX/lib" -name 'lib*.a' ! -name 'libShaderDeps.a' -print0)
libtool -static -o "$PREFIX/lib/libShaderDeps.a" "${LIBS[@]}"

echo "==> Done. Libraries in $PREFIX/lib, headers in $PREFIX/include"
