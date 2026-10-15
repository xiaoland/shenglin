#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$repo_dir/local/gradle-user-home}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
if [[ -z "${JAVA_HOME:-}" && -x /usr/libexec/java_home ]]; then
  export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
fi
cd "$repo_dir/Android"
./gradlew --no-daemon testDebugUnitTest assembleDebug "$@"
