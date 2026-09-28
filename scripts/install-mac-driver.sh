#!/bin/sh
set -eu

test "$(id -u)" -eq 0
resources=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
source="$resources/NearbyAudioDriver.driver"
target='/Library/Audio/Plug-Ins/HAL/NearbyAudioDriver.driver'
parent='/Library/Audio/Plug-Ins'
staging=$(mktemp -d "$parent/.nearbyaudio-install.XXXXXX")
trap 'rm -rf "$staging"' EXIT

test -d "$source"
/usr/bin/codesign --verify --strict "$source"
/usr/bin/ditto "$source" "$staging/NearbyAudioDriver.driver"
/usr/sbin/chown -R root:wheel "$staging/NearbyAudioDriver.driver"
/usr/bin/codesign --verify --strict "$staging/NearbyAudioDriver.driver"

if [ -e "$target" ]; then
    previous=$(mktemp -d "$parent/.nearbyaudio-previous.XXXXXX")
    /bin/mv "$target" "$previous/NearbyAudioDriver.driver"
fi
if ! /bin/mv "$staging/NearbyAudioDriver.driver" "$target"; then
    if [ -n "${previous:-}" ]; then /bin/mv "$previous/NearbyAudioDriver.driver" "$target"; fi
    exit 1
fi
/usr/bin/killall coreaudiod
