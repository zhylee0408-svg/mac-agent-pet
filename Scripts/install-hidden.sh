#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SOURCE_APP="/Applications/Discipline.app"
HIDDEN_ROOT="$HOME/Library/Application Support/Discipline"
HIDDEN_APP="$HIDDEN_ROOT/Discipline.app"
COMMAND_TARGET="/opt/homebrew/bin/discipline"
TRASH_BACKUP="$HOME/.Trash/Discipline-Applications-backup-2026-08-18.app"

if [[ ! -d "$SOURCE_APP" ]]; then
  print -u2 "Missing source app: $SOURCE_APP"
  exit 1
fi

if [[ -e "$HIDDEN_APP" ]]; then
  print -u2 "Hidden app already exists: $HIDDEN_APP"
  exit 1
fi

if [[ -e "$TRASH_BACKUP" ]]; then
  print -u2 "Trash backup already exists: $TRASH_BACKUP"
  exit 1
fi

/usr/bin/pkill -TERM -f '^/Applications/Discipline.app/Contents/MacOS/Discipline$' 2>/dev/null || true
/bin/mkdir -p "$HIDDEN_ROOT"
/usr/bin/ditto "$SOURCE_APP" "$HIDDEN_APP"
/usr/bin/codesign --verify --deep --strict "$HIDDEN_APP"
"$HIDDEN_APP/Contents/MacOS/Discipline" --self-test
/usr/bin/install -m 755 "$SCRIPT_DIR/discipline" "$COMMAND_TARGET"
/bin/mv "$SOURCE_APP" "$TRASH_BACKUP"

print "Hidden app: $HIDDEN_APP"
print "Command: $COMMAND_TARGET"
print "Recoverable backup: $TRASH_BACKUP"
