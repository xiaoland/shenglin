#!/bin/sh
set -eu

test "$(id -u)" -eq 0
resources=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
source="$resources/ShenglinDriver.driver"
target='/Library/Audio/Plug-Ins/HAL/ShenglinDriver.driver'
parent='/Library/Audio/Plug-Ins'
staging=$(mktemp -d "$parent/.shenglin-install.XXXXXX")
trap 'rm -rf "$staging"' EXIT

test -d "$source"
/usr/bin/codesign --verify --strict "$source"
/usr/bin/ditto "$source" "$staging/ShenglinDriver.driver"
/usr/sbin/chown -R root:wheel "$staging/ShenglinDriver.driver"
/usr/bin/codesign --verify --strict "$staging/ShenglinDriver.driver"

if [ -e "$target" ]; then
    previous=$(mktemp -d "$parent/.shenglin-previous.XXXXXX")
    /bin/mv "$target" "$previous/ShenglinDriver.driver"
fi
if ! /bin/mv "$staging/ShenglinDriver.driver" "$target"; then
    if [ -n "${previous:-}" ]; then /bin/mv "$previous/ShenglinDriver.driver" "$target"; fi
    exit 1
fi
/usr/bin/killall coreaudiod
