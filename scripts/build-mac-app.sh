#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
if [ ! -d "$repo/.git" ]; then
    echo '请只在主仓库打包 声邻；工作树可以编译，但不要生成可运行的第二份 App。' >&2
    exit 1
fi
cd "$repo"
scripts/build-pake.sh macos
xcodebuild -project MacGUI/ShenglinMac.xcodeproj -scheme ShenglinMac \
    -configuration Release -sdk macosx -destination 'generic/platform=macOS' \
    -derivedDataPath local/MacDerived CODE_SIGNING_ALLOWED=NO build
mkdir -p dist
staging=$(mktemp -d dist/.shenglin.XXXXXX)
trap 'rm -rf "$staging"' EXIT
ditto 'local/MacDerived/Build/Products/Release/声邻.app' "$staging/声邻.app"
driver='local/DriverBuild/ShenglinDriver.driver'
if [ ! -d "$driver" ] || ! codesign --verify --strict "$driver"; then
    echo '请先构建并签名 HAL 驱动：SHENGLIN_SIGN_IDENTITY="Apple Development" scripts/build-driver.sh' >&2
    exit 1
fi
ditto "$driver" "$staging/声邻.app/Contents/Resources/ShenglinDriver.driver"
cp scripts/install-mac-driver.sh "$staging/声邻.app/Contents/Resources/install-mac-driver.sh"
mkdir -p "$staging/声邻.app/Contents/Library/LaunchAgents"
cp MacGUI/local.shenglin.microphone.plist "$staging/声邻.app/Contents/Library/LaunchAgents/"
codesign --force --deep --options runtime --entitlements MacGUI/Shenglin.entitlements --sign "${SHENGLIN_SIGN_IDENTITY:-Apple Development}" "$staging/声邻.app"
codesign --verify --strict --deep "$staging/声邻.app"
# Hardened Runtime 缺少此公开声明时，系统会拒绝输入且可能不显示授权项。
codesign --display --entitlements - --xml "$staging/声邻.app" > "$staging/entitlements.plist"
if [ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$staging/entitlements.plist")" != true ]; then
    echo '签名缺少 Audio Input 权限，保留旧版应用' >&2
    exit 1
fi
if [ -x 'dist/声邻.app/Contents/MacOS/声邻' ]; then
    for pid in $(lsof -t 'dist/声邻.app/Contents/MacOS/声邻' 2>/dev/null | sort -u); do
        case "$(ps -p "$pid" -o args=)" in
            *--microphone-agent*) ;;
            *) echo '声邻 GUI 正在运行；请正常退出后再替换签名应用' >&2; exit 1 ;;
        esac
    done
    'dist/声邻.app/Contents/MacOS/声邻' --microphone-agent-stop
fi
if lsof -nP 'dist/声邻.app/Contents/MacOS/声邻' 2>/dev/null |
   awk '$4 == "txt" { found = 1 } END { exit !found }'; then
    echo '声邻 后台麦克风服务正在运行；请先停止服务再替换应用' >&2
    exit 1
fi
rm -rf 'dist/声邻.app'
mv "$staging/声邻.app" 'dist/声邻.app'
lsregister='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
"$lsregister" -u "$repo/local/MacDerived/Build/Products/Release/声邻.app" || true
rm -rf 'local/MacDerived/Build/Products/Release/声邻.app'
"$lsregister" -f "$repo/dist/声邻.app"
echo "已生成 $repo/dist/声邻.app"
