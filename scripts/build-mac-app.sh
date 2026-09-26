#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$repo"
scripts/build-pake.sh macos
xcodebuild -project MacGUI/NearbyAudioMac.xcodeproj -scheme NearbyAudioMac \
    -configuration Release -sdk macosx -destination 'generic/platform=macOS' \
    -derivedDataPath local/MacDerived CODE_SIGNING_ALLOWED=NO build
mkdir -p dist
staging=$(mktemp -d dist/.nearby-audio.XXXXXX)
trap 'rm -rf "$staging"' EXIT
ditto 'local/MacDerived/Build/Products/Release/Nearby Audio.app' "$staging/Nearby Audio.app"
codesign --force --deep --options runtime --sign "${NEARBY_AUDIO_SIGN_IDENTITY:-Apple Development}" "$staging/Nearby Audio.app"
codesign --verify --strict --deep "$staging/Nearby Audio.app"
rm -rf 'dist/Nearby Audio.app'
mv "$staging/Nearby Audio.app" 'dist/Nearby Audio.app'
rm -rf 'local/MacDerived/Build/Products/Release/Nearby Audio.app'
echo "已生成 $repo/dist/Nearby Audio.app"
