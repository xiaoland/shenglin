#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
app='/Applications/Shenglin.app'
output="$repo/dist/Shenglin-macOS-arm64.dmg"

test -d "$app" || { echo '请先运行 scripts/build-mac-app.sh' >&2; exit 1; }
codesign --verify --strict --deep "$app"
mkdir -p "$repo/dist"
stage=$(mktemp -d "$repo/dist/.shenglin-dmg.XXXXXX")
mv "$stage" "$stage.noindex"
stage="$stage.noindex"
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/volume"
ditto "$app" "$stage/volume/Shenglin.app"
ln -s /Applications "$stage/volume/Applications"
hdiutil create -quiet -volname '声邻' -srcfolder "$stage/volume" -format UDZO "$stage/Shenglin.dmg"
hdiutil verify -quiet "$stage/Shenglin.dmg"
mv -f "$stage/Shenglin.dmg" "$output"
echo "已生成 $output"
