#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$repo"
if command -v cmake >/dev/null 2>&1; then cmake=cmake
elif [ -x local/pake-tools/bin/cmake ]; then cmake=local/pake-tools/bin/cmake
else echo '需要 CMake；可先运行 scripts/build-pake.sh macos' >&2; exit 1
fi

revision=47f688ed6bb637ab8b7f4b36864734b2b1f69b6b
if [ ! -d local/libASPL/.git ]; then
    git clone --depth 1 --branch v3.1.2 https://github.com/gavv/libASPL.git local/libASPL
fi
if [ "$(git -C local/libASPL rev-parse HEAD)" != "$revision" ]; then
    echo 'local/libASPL 版本不符；请移走该本地目录后重试' >&2
    exit 1
fi

sdk=$(xcrun --sdk macosx --show-sdk-path)
prefix="$repo/local/libASPL-prefix"
"$cmake" -S local/libASPL -B local/libASPL-build -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_INSTALL_PREFIX="$prefix"
"$cmake" --build local/libASPL-build -j 4
"$cmake" --install local/libASPL-build
"$cmake" -S Driver -B local/DriverBuild -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_OSX_SYSROOT="$sdk" -DASPL_PREFIX="$prefix"
"$cmake" --build local/DriverBuild -j 4
local/DriverBuild/ShenglinDriverTests
driver="$repo/local/DriverBuild/ShenglinDriver.driver"
if [ -n "${SHENGLIN_SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --sign "$SHENGLIN_SIGN_IDENTITY" "$driver"
    codesign --verify --strict "$driver"
fi
echo "已生成 ${driver}（未安装）"
