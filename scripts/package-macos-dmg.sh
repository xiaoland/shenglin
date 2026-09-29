#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
app="$repo/dist/Shenglin.app"
output="$repo/dist/Shenglin-macOS-arm64.dmg"

test -d "$app" || { echo '请先运行 scripts/build-mac-app.sh' >&2; exit 1; }
codesign --verify --strict --deep "$app"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Shenglin.app"
ln -s /Applications "$stage/Applications"
rm -f "$output"
hdiutil create -quiet -volname '声邻' -srcfolder "$stage" -format UDZO "$output"
hdiutil verify -quiet "$output"
echo "已生成 $output"
