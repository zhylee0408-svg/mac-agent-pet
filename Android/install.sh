#!/bin/zsh
set -euo pipefail

ANDROID_DIR="${0:A:h}"
ADB="$ANDROID_DIR/.sdk/platform-tools/adb"
APK="$ANDROID_DIR/Discipline-local-preview.apk"

if [[ ! -f "$APK" ]]; then
  "$ANDROID_DIR/build.sh"
fi

DEVICE_COUNT="$($ADB devices | awk 'NR > 1 && $2 == "device" { count += 1 } END { print count + 0 }')"
if [[ "$DEVICE_COUNT" -ne 1 ]]; then
  print -u2 "Expected exactly one authorized Android device, found $DEVICE_COUNT."
  print -u2 "Connect the phone with USB debugging enabled, accept its RSA prompt, then retry."
  "$ADB" devices -l
  exit 1
fi

"$ADB" install -r "$APK"
"$ADB" shell am start -n com.zhylee.discipline.mobile/.MainActivity
