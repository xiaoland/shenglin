#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output="$PWD/local/AndroidBLEPeripheral.noindex"
app="$output/ShenglinBLEProbe.app"
mkdir -p "$app/Contents/MacOS"
scripts/build-rust-core.sh macos
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.shenglin.android-ble-peripheral-probe</string>
<key>CFBundleExecutable</key><string>ShenglinBLEProbe</string>
<key>CFBundleName</key><string>声邻蓝牙互操作探针</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>仅用于与测试手机验证已配对设备的蓝牙通信。</string>
<key>NSLocalNetworkUsageDescription</key><string>仅用于测试设备的局域网配对与通信。</string>
<key>NSBonjourServices</key><array><string>_shenglin._tcp</string><string>_shenglin-pair4._tcp</string></array>
</dict></plist>
PLIST
swiftc -parse-as-library -I local/rust-bindings/swift local/rust-bindings/swift/ShenglinRust.swift \
    Shared/Protocol.swift Shared/PeerState.swift Shared/PairingProtocol.swift Shared/WiFiPeer.swift Shared/WiFiPairing.swift \
    scripts/test-android-ble-peripheral.swift local/rust-target/aarch64-apple-darwin/release/libshenglin_core.a \
    -lc++ -o "$app/Contents/MacOS/ShenglinBLEProbe"
codesign --force --sign - "$app"
# 默认输出已通过局域网和 BLE 实测的命令行路径；直接执行测试 bundle 在此环境未发布 Bonjour。
cp "$app/Contents/MacOS/ShenglinBLEProbe" "$output/ble-peripheral-cli"
printf '%s\n' "$output/ble-peripheral-cli"
