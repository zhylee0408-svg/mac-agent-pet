#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
SOURCE_APP="$PROJECT_DIR/build/Discipline.app"
HIDDEN_APP="$HOME/Library/Application Support/Discipline/Discipline.app"

if [[ ! -d "$SOURCE_APP" ]]; then
  print -u2 "Missing build app: $SOURCE_APP"
  exit 1
fi

if [[ ! -d "$HIDDEN_APP" ]]; then
  print -u2 "Missing hidden installation: $HIDDEN_APP"
  exit 1
fi

/usr/bin/pkill -TERM -f "^$HIDDEN_APP/Contents/MacOS/Discipline$" 2>/dev/null || true
/usr/bin/ditto "$SOURCE_APP" "$HIDDEN_APP"
/usr/bin/codesign --verify --deep --strict "$HIDDEN_APP"
"$HIDDEN_APP/Contents/MacOS/Discipline" --self-test
/usr/bin/open -g "$HIDDEN_APP"

print "Updated hidden app: $HIDDEN_APP"
