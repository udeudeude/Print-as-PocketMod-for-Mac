#!/bin/zsh
set -euo pipefail

APP="$HOME/Applications/Print as PocketMod.app"
PLAIN="$HOME/Library/PDF Services/Print as PocketMod"
GUIDED="$HOME/Library/PDF Services/Print as PocketMod with Guides"

rm -f "$PLAIN" "$GUIDED"
rm -rf "$APP"

echo "Removed Print as PocketMod."

if [[ -t 0 && "${0:t}" == *.command ]]; then
  read -k 1 "?Press any key to close..."
  echo
fi
