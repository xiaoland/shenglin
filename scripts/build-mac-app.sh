#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
if [ ! -d "$repo/.git" ]; then
    echo '请只在主仓库打包 声邻；工作树可以编译，但不要生成可运行的第二份 App。' >&2
    exit 1
fi
cd "$repo"
lsregister='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
# 暂存目录不参与应用索引；失败也清除 Xcode 生成的第二份 App。
staging=$(mktemp -d /Applications/.shenglin.XXXXXX)
mv "$staging" "$staging.noindex"
staging="$staging.noindex"
derived='local/MacDerived.noindex'
cleanup() {
    "$lsregister" -u "$repo/$derived/Build/Products/Release/声邻.app" || true
    rm -rf "$derived/Build/Products/Release/声邻.app"
    if [ -e "$staging/previous.app" ]; then
        echo "安装回滚失败，旧版应用保留在 $staging/previous.app" >&2
    else
        rm -rf "$staging"
    fi
}
trap cleanup EXIT
scripts/build-rust-core.sh macos
xcodebuild -project MacGUI/ShenglinMac.xcodeproj -scheme ShenglinMac \
    -configuration Release -sdk macosx -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO build
app='Shenglin.app'
target="/Applications/$app"
ditto "$derived/Build/Products/Release/声邻.app" "$staging/$app"
driver='local/DriverBuild/ShenglinDriver.driver'
if [ ! -d "$driver" ] || ! codesign --verify --strict "$driver"; then
    echo '请先构建并签名 HAL 驱动：SHENGLIN_SIGN_IDENTITY="Apple Development" scripts/build-driver.sh' >&2
    exit 1
fi
ditto "$driver" "$staging/$app/Contents/Resources/ShenglinDriver.driver"
cp scripts/install-mac-driver.sh "$staging/$app/Contents/Resources/install-mac-driver.sh"
mkdir -p "$staging/$app/Contents/Library/LaunchAgents"
cp MacGUI/local.shenglin.microphone.plist "$staging/$app/Contents/Library/LaunchAgents/"
codesign --force --deep --options runtime --entitlements MacGUI/Shenglin.entitlements --sign "${SHENGLIN_SIGN_IDENTITY:-Apple Development}" "$staging/$app"
codesign --verify --strict --deep "$staging/$app"
# Hardened Runtime 缺少此公开声明时，系统会拒绝输入且可能不显示授权项。
codesign --display --entitlements - --xml "$staging/$app" > "$staging/entitlements.plist"
if [ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$staging/entitlements.plist")" != true ]; then
    echo '签名缺少 Audio Input 权限，保留旧版应用' >&2
    exit 1
fi
if [ -x "$target/Contents/MacOS/声邻" ]; then
    for pid in $(lsof -t "$target/Contents/MacOS/声邻" 2>/dev/null | sort -u); do
        case "$(ps -p "$pid" -o args=)" in
            *--microphone-agent*) ;;
            *) echo '声邻 GUI 正在运行；请正常退出后再替换签名应用' >&2; exit 1 ;;
        esac
    done
    if lsof -nP "$target/Contents/MacOS/声邻" 2>/dev/null |
       awk '$4 == "txt" { found = 1 } END { exit !found }'; then
        "$target/Contents/MacOS/声邻" --microphone-agent-stop
    fi
fi
if lsof -nP "$target/Contents/MacOS/声邻" 2>/dev/null |
   awk '$4 == "txt" { found = 1 } END { exit !found }'; then
    echo '声邻后台麦克风服务正在运行；请先停止服务再替换应用' >&2
    exit 1
fi
if [ -e "$target" ]; then mv "$target" "$staging/previous.app"; fi
if ! mv "$staging/$app" "$target"; then
    if [ -e "$staging/previous.app" ]; then mv "$staging/previous.app" "$target"; fi
    exit 1
fi
rm -rf "$staging/previous.app"
"$lsregister" -f "$target"
echo "已更新唯一安装 $target"
