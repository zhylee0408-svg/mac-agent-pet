#!/bin/zsh
set -euo pipefail

RELAY_DIR="${0:A:h}"
NODE_EXECUTABLE="${NODE_EXECUTABLE:-$(command -v node)}"
SQLITE_EXECUTABLE="${SQLITE_EXECUTABLE:-$(command -v sqlite3)}"

if [[ -z "$NODE_EXECUTABLE" ]]; then
  print -u2 "Relay self-test requires Node.js 22 or newer"
  exit 1
fi

if [[ -z "$SQLITE_EXECUTABLE" ]]; then
  print -u2 "Relay self-test requires sqlite3"
  exit 1
fi

"$SQLITE_EXECUTABLE" :memory: < "$RELAY_DIR/migrations/0001_initial.sql"
"$NODE_EXECUTABLE" "$RELAY_DIR/Tests/RelaySelfTest.mjs"
"$NODE_EXECUTABLE" "$RELAY_DIR/Tests/WorkerSelfTest.mjs"
