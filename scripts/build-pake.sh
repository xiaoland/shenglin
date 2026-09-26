#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
revision=e98a6564575520260ef95b2389e5d63a24917093
platform=${1:-both}
case "$platform" in macos|ios|both) ;; *) echo '用法：build-pake.sh macos|ios|both' >&2; exit 2 ;; esac
cd "$repo"
if ! command -v cmake >/dev/null 2>&1; then
    if [ ! -x local/pake-tools/bin/cmake ]; then
        python3 -m venv local/pake-tools
        local/pake-tools/bin/pip install 'cmake>=3.22,<5'
    fi
    cmake=$repo/local/pake-tools/bin/cmake
else
    cmake=$(command -v cmake)
fi
if [ ! -f local/boringssl/include/openssl/curve25519.h ]; then
    mkdir -p local/boringssl
    curl -fL --retry 3 "https://github.com/google/boringssl/archive/$revision.tar.gz" -o local/boringssl.tar.gz
    tar -xzf local/boringssl.tar.gz -C local/boringssl --strip-components=1
fi
build() {
    target=$1
    if [ "$target" = ios ]; then
        sysroot=iphoneos
        deployment=17.0
    else
        sysroot=macosx
        deployment=14.0
    fi
    if [ -f "local/boringssl-$target/libcrypto.a" ]; then return; fi
    "$cmake" -S local/boringssl -B "local/boringssl-$target" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_SYSROOT="$sysroot" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment"
    "$cmake" --build "local/boringssl-$target" --target crypto -j 8
}
case "$platform" in macos) build macos ;; ios) build ios ;; both) build macos; build ios ;; esac
