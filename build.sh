#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
BUILD_ROOT="${1:-$SCRIPT_DIR/build}"
APP_DIR="$BUILD_ROOT/Discipline.app"
CONTENTS="$APP_DIR/Contents"

mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
mkdir -p "$BUILD_ROOT/module-cache"

CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/module-cache" xcrun swiftc \
  -swift-version 5 \
  -O \
  -target arm64-apple-macosx13.0 \
  -module-cache-path "$BUILD_ROOT/module-cache" \
  -framework AppKit \
  -framework CryptoKit \
  -framework Security \
  -framework WebKit \
  "$SCRIPT_DIR/Sources/Discipline/MobileSync.swift" \
  "$SCRIPT_DIR/Sources/Discipline/main.swift" \
  -o "$CONTENTS/MacOS/Discipline"

cp "$SCRIPT_DIR/Info.plist" "$CONTENTS/Info.plist"
cp -R "$SCRIPT_DIR/Resources/." "$CONTENTS/Resources/"

/usr/bin/codesign --force --sign - --timestamp=none "$APP_DIR"

echo "$APP_DIR"
