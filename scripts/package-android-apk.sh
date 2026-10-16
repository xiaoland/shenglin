#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$repo_dir/local/gradle-user-home}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
if [[ -z "${JAVA_HOME:-}" && -x /usr/libexec/java_home ]]; then
  export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
fi
signing_properties="${SHENGLIN_ANDROID_SIGNING_PROPERTIES:-$repo_dir/local/android-release/signing.properties}"
[[ -f "$signing_properties" ]] || { echo "Missing release signing properties: $signing_properties" >&2; exit 1; }
"$repo_dir/Android/gradlew" -p "$repo_dir/Android" --no-daemon assembleRelease
apk="$repo_dir/Android/app/build/outputs/apk/release/app-release.apk"
build_tools="$ANDROID_HOME/build-tools/36.0.0"
"$build_tools/apksigner" verify --verbose --print-certs "$apk"
python3 - "$apk" "$build_tools/aapt" <<'PY'
import subprocess, sys, zipfile
apk, aapt = sys.argv[1:]
info = subprocess.check_output([aapt, 'dump', 'badging', apk], text=True)
assert "package: name='local.shenglin' versionCode='2' versionName='0.2.0-beta.3'" in info, 'Unexpected package/version'
assert 'application-debuggable' not in info, 'Release must not be debuggable'
with zipfile.ZipFile(apk) as z:
    libs = [name for name in z.namelist() if name.startswith('lib/') and name.endswith('.so')]
    assert {name.split('/')[1] for name in libs} == {'arm64-v8a', 'armeabi-v7a'}, libs
    for abi in ('arm64-v8a', 'armeabi-v7a'):
        for library in ('libshenglin_core.so', 'libjnidispatch.so'):
            assert f'lib/{abi}/{library}' in libs, f'Missing {abi}/{library}'
print('Verified package/version, non-debuggable flag, ARM ABIs and Rust/JNA native libraries.')
PY
certificate="$("$build_tools/apksigner" verify --print-certs "$apk")"
if [[ "$certificate" == *"Android Debug"* ]]; then
  echo 'Refusing debug-signed release APK' >&2; exit 1
fi
mkdir -p "$repo_dir/dist"
cp "$apk" "$repo_dir/dist/Shenglin-Android-arm.apk"
shasum -a 256 "$repo_dir/dist/Shenglin-Android-arm.apk"
