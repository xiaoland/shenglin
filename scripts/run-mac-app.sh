#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
if [ ! -d "$repo/.git" ]; then
    echo '请从主仓库运行 声邻，不要启动工作树中的构建产物。' >&2
    exit 1
fi
app="$repo/dist/声邻.app"
codesign --verify --strict --deep "$app"

running=$(pgrep -fl '声邻.app/Contents/MacOS/声邻' || true)
unexpected=$(printf '%s\n' "$running" | grep -vF "$app/Contents/MacOS/声邻" || true)
if [ -n "$unexpected" ]; then
    echo "另一份 声邻 正在运行：$unexpected" >&2
    echo '请先正常退出它，再从主仓库启动签名版。' >&2
    exit 1
fi
open -g "$app"
