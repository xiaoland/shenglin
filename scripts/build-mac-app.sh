#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
if [ ! -d "$repo/.git" ]; then
    echo '请只在主仓库打包 Nearby Audio；工作树可以编译，但不要生成可运行的第二份 App。' >&2
    exit 1
fi
cd "$repo"
scripts/build-pake.sh macos
xcodebuild -project MacGUI/NearbyAudioMac.xcodeproj -scheme NearbyAudioMac \
    -configuration Release -sdk macosx -destination 'generic/platform=macOS' \
    -derivedDataPath local/MacDerived CODE_SIGNING_ALLOWED=NO build
mkdir -p dist
staging=$(mktemp -d dist/.nearby-audio.XXXXXX)
trap 'rm -rf "$staging"' EXIT
ditto 'local/MacDerived/Build/Products/Release/Nearby Audio.app' "$staging/Nearby Audio.app"
driver='local/DriverBuild/NearbyAudioDriver.driver'
if [ ! -d "$driver" ] || ! codesign --verify --strict "$driver"; then
    echo '请先构建并签名 HAL 驱动：NEARBY_AUDIO_SIGN_IDENTITY="Apple Development" scripts/build-driver.sh' >&2
    exit 1
fi
ditto "$driver" "$staging/Nearby Audio.app/Contents/Resources/NearbyAudioDriver.driver"
cp scripts/install-mac-driver.sh "$staging/Nearby Audio.app/Contents/Resources/install-mac-driver.sh"
mkdir -p "$staging/Nearby Audio.app/Contents/Library/LaunchAgents"
cp MacGUI/local.nearbyaudio.microphone.plist "$staging/Nearby Audio.app/Contents/Library/LaunchAgents/"
codesign --force --deep --options runtime --entitlements MacGUI/NearbyAudio.entitlements --sign "${NEARBY_AUDIO_SIGN_IDENTITY:-Apple Development}" "$staging/Nearby Audio.app"
codesign --verify --strict --deep "$staging/Nearby Audio.app"
# Hardened Runtime 缺少此公开声明时，系统会拒绝输入且可能不显示授权项。
codesign --display --entitlements - --xml "$staging/Nearby Audio.app" > "$staging/entitlements.plist"
if [ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$staging/entitlements.plist")" != true ]; then
    echo '签名缺少 Audio Input 权限，保留旧版应用' >&2
    exit 1
fi
if [ -x 'dist/Nearby Audio.app/Contents/MacOS/Nearby Audio' ]; then
    for pid in $(lsof -t 'dist/Nearby Audio.app/Contents/MacOS/Nearby Audio' 2>/dev/null | sort -u); do
        case "$(ps -p "$pid" -o args=)" in
            *--microphone-agent*) ;;
            *) echo 'Nearby Audio GUI 正在运行；请正常退出后再替换签名应用' >&2; exit 1 ;;
        esac
    done
    'dist/Nearby Audio.app/Contents/MacOS/Nearby Audio' --microphone-agent-stop
fi
if lsof -nP 'dist/Nearby Audio.app/Contents/MacOS/Nearby Audio' 2>/dev/null |
   awk '$4 == "txt" { found = 1 } END { exit !found }'; then
    echo 'Nearby Audio 后台麦克风服务正在运行；请先停止服务再替换应用' >&2
    exit 1
fi
rm -rf 'dist/Nearby Audio.app'
mv "$staging/Nearby Audio.app" 'dist/Nearby Audio.app'
lsregister='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
"$lsregister" -u "$repo/local/MacDerived/Build/Products/Release/Nearby Audio.app" || true
rm -rf 'local/MacDerived/Build/Products/Release/Nearby Audio.app'
"$lsregister" -f "$repo/dist/Nearby Audio.app"
echo "已生成 $repo/dist/Nearby Audio.app"
