#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$repo"
command -v rsvg-convert >/dev/null || { echo '重新生成图标需要 librsvg（brew install librsvg）' >&2; exit 1; }
icons='local/MacIcon.iconset'
mkdir -p "$icons"
# Legacy ICNS needs transparent margins. Match the system's optical sizing:
# 824 px artwork on a 1024 px canvas, with less padding at 16/32 px.
sed 's/translate(122.4609375 122.4609375) scale(0.8046875)/translate(78.375 78.375) scale(0.875)/' \
    Design/AppIcon.svg > local/MacIcon-small.svg
for entry in '16x16:16' '16x16@2x:32' '32x32:32' '32x32@2x:64' \
             '128x128:128' '128x128@2x:256' '256x256:256' '256x256@2x:512' \
             '512x512:512' '512x512@2x:1024'; do
    name=${entry%:*}
    pixels=${entry#*:}
    source='Design/AppIcon.svg'
    if [ "$pixels" -le 32 ]; then source='local/MacIcon-small.svg'; fi
    rsvg-convert -w "$pixels" -h "$pixels" "$source" -o "$icons/icon_$name.png"
done
cp "$icons/icon_512x512@2x.png" MacGUI/AppIcon.png
iconutil -c icns "$icons" -o MacGUI/AppIcon.icns
