#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
# Xcode 启动时可能没有继承终端中 mise 的 PATH。
export PATH="$HOME/.local/share/mise/shims:/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v pnpm >/dev/null 2>&1 || [ ! -x "$repo/BrowserExtension/node_modules/.bin/wxt" ]; then
    echo '请先安装 Node.js 22.12+，安装 pnpm 11.20.0，再运行 pnpm --dir BrowserExtension install --frozen-lockfile。' >&2
    exit 1
fi
pnpm --dir "$repo/BrowserExtension" run build
if [ "$#" -eq 1 ]; then
    destination=$1
    rm -rf "$destination"
    mkdir -p "$destination"
    ditto "$repo/BrowserExtension/.output/chrome-mv3" "$destination"
elif [ "$#" -ne 0 ]; then
    echo '用法：build-browser-extension.sh [App 内的 BrowserExtension 目标目录]' >&2
    exit 1
fi
