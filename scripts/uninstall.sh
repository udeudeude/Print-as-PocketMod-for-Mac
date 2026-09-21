#!/bin/zsh
set -euo pipefail

APP="$HOME/Applications/Print as PocketMod.app"
PLAIN="$HOME/Library/PDF Services/Print as PocketMod"
GUIDED="$HOME/Library/PDF Services/Print as PocketMod with Guides"
LOG="$HOME/Library/Logs/Print-as-PocketMod.log"

is_interactive_command() {
  [[ -t 0 && "${0:t}" == *.command ]]
}

show_dialog() {
  local title="$1"
  local message="$2"
  /usr/bin/osascript - "$title" "$message" <<'APPLESCRIPT'
on run argv
    display dialog (item 2 of argv) buttons {"OK"} default button "OK" with title (item 1 of argv)
end run
APPLESCRIPT
}

rm -f "$PLAIN" "$GUIDED" "$LOG"
rm -rf "$APP"
rm -rf "${TMPDIR:-/tmp}/PrintAsPocketMod" "${TMPDIR:-/tmp}/PrintAsPocketModInput"

echo "Removed Print as PocketMod."

if is_interactive_command; then
  show_dialog "Print as PocketMod" "Print as PocketMod has been removed."
fi
