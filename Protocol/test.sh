#!/bin/zsh
set -euo pipefail

PROTOCOL_DIR="${0:A:h}"
BUILD_DIR="$PROTOCOL_DIR/.build"

mkdir -p "$BUILD_DIR"
xcrun swiftc \
  -swift-version 5 \
  -O \
  -module-cache-path "$BUILD_DIR/module-cache" \
  "$PROTOCOL_DIR/Tests/ProtocolSelfTest.swift" \
  -o "$BUILD_DIR/protocol-self-test"

"$BUILD_DIR/protocol-self-test"
