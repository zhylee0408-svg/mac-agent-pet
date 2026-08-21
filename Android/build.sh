#!/bin/zsh
set -euo pipefail

ANDROID_DIR="${0:A:h}"
PROJECT_DIR="$ANDROID_DIR/DisciplineMobile"
SDK_DIR="$ANDROID_DIR/.sdk"
APK_SOURCE="$PROJECT_DIR/app/build/outputs/apk/debug/app-debug.apk"
APK_OUTPUT="$ANDROID_DIR/Discipline-local-preview.apk"

if [[ ! -x "$SDK_DIR/platform-tools/adb" ]]; then
  print -u2 "Android SDK is missing. Restore Android/.sdk before building."
  exit 1
fi

export ANDROID_HOME="$SDK_DIR"
export ANDROID_USER_HOME="$ANDROID_DIR/.android-user"
export GRADLE_USER_HOME="$ANDROID_DIR/.gradle-home"

"$PROJECT_DIR/gradlew" -p "$PROJECT_DIR" testDebugUnitTest lintDebug assembleDebug
cp -f "$APK_SOURCE" "$APK_OUTPUT"

print "Built: $APK_OUTPUT"
shasum -a 256 "$APK_OUTPUT"
