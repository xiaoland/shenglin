#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$repo"
scripts/build-pake.sh ios
xcodebuild -project iPad/ShenglinPad.xcodeproj -scheme ShenglinPad \
    -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath local/iPadReleaseDerived CODE_SIGNING_ALLOWED=NO build
app='local/iPadReleaseDerived/Build/Products/Debug-iphoneos/ShenglinPad.app'
test -f "$app/ShenglinPad"
test ! -e "$app/embedded.mobileprovision"
if codesign --verify "$app" >/dev/null 2>&1; then
    echo '拒绝打包带有本机开发签名的 iPad App' >&2
    exit 1
fi
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/Payload"
ditto "$app" "$stage/Payload/ShenglinPad.app"
mkdir -p dist
output="$repo/dist/Shenglin-iPadOS-unsigned.ipa"
rm -f "$output"
(cd "$stage" && ditto -c -k --sequesterRsrc --keepParent Payload "$output")
unzip -tq "$output" >/dev/null
echo "已生成 ${output}；安装者必须用自己的账号签名"
