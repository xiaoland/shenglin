#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd -P)
export CARGO_HOME="$repo/local/cargo-home"
export CARGO_TARGET_DIR="$repo/local/rust-target"
export MACOSX_DEPLOYMENT_TARGET=14.0 IPHONEOS_DEPLOYMENT_TARGET=17.0
cd "$repo/Core"
mode=${1:-macos}
case "$mode" in macos|ios|both|android|android-libs|all|bindings|test) ;; *) echo '用法：build-rust-core.sh macos|ios|both|android|android-libs|all|bindings|test' >&2; exit 2;; esac
mkdir -p "$CARGO_HOME" "$CARGO_TARGET_DIR"
if [[ "$mode" != android-libs ]]; then
"$repo/scripts/build-pake.sh" macos
cargo build --locked --manifest-path "$repo/Core/Cargo.toml" --release --features bindgen --target aarch64-apple-darwin
for language in swift kotlin; do
 mkdir -p "$repo/local/rust-bindings/$language"
 "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/uniffi-bindgen" generate --library "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/libshenglin_core.dylib" --language "$language" --config "$repo/Core/uniffi.toml" --out-dir "$repo/local/rust-bindings/$language" --no-format
 done
# Keep binding-generator dependencies out of the library shipped to apps.
cargo build --locked --manifest-path "$repo/Core/Cargo.toml" --release --target aarch64-apple-darwin --lib
if [[ "$mode" == test ]]; then cargo test --locked --manifest-path "$repo/Core/Cargo.toml"; fi
cp "$repo/local/rust-bindings/swift/ShenglinRustFFI.modulemap" "$repo/local/rust-bindings/swift/module.modulemap"
fi
if [[ "$mode" == ios || "$mode" == both || "$mode" == all ]]; then
 "$repo/scripts/build-pake.sh" ios
 cargo build --locked --manifest-path "$repo/Core/Cargo.toml" --release --target aarch64-apple-ios --lib
fi
if [[ "$mode" == android || "$mode" == android-libs || "$mode" == all ]]; then
 "$repo/scripts/build-pake.sh" source
 ndk=${ANDROID_NDK_HOME:-/Volumes/WorkSSD/Android/sdk/ndk/30.0.14904198}
 toolchain="$ndk/toolchains/llvm/prebuilt/darwin-x86_64"
 cmake=$(command -v cmake || printf '%s' "$repo/local/pake-tools/bin/cmake")
 for abi in arm64-v8a armeabi-v7a x86 x86_64; do
  case "$abi" in
   arm64-v8a) triple=aarch64-linux-android; clang_triple=$triple ;;
   armeabi-v7a) triple=armv7-linux-androideabi; clang_triple=armv7a-linux-androideabi ;;
   x86) triple=i686-linux-android; clang_triple=$triple ;;
   x86_64) triple=x86_64-linux-android; clang_triple=$triple ;;
  esac
  crypto="$repo/local/boringssl-rust-$abi"
  if [[ ! -f "$crypto/libcrypto.a" ]] || ! cmp -s "$repo/local/boringssl/.shenglin-revision" "$crypto/.shenglin-revision"; then
   "$cmake" -S "$repo/local/boringssl" -B "$crypto" -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" -DANDROID_ABI="$abi" -DANDROID_PLATFORM=android-26 -DCMAKE_BUILD_TYPE=Release -DANDROID_STL=c++_static
   "$cmake" --build "$crypto" --target crypto -j 8
   cp "$repo/local/boringssl/.shenglin-revision" "$crypto/.shenglin-revision"
  fi
  upper=$(printf '%s' "$triple" | tr '[:lower:]-' '[:upper:]_')
  env "CARGO_TARGET_${upper}_LINKER=$toolchain/bin/${clang_triple}26-clang" "CC_${triple}=$toolchain/bin/${clang_triple}26-clang" "AR_${triple}=$toolchain/bin/llvm-ar" "SHENGLIN_CRYPTO_LIB_DIR=$crypto" cargo build --locked --manifest-path "$repo/Core/Cargo.toml" --release --target "$triple" --lib
 done
fi
