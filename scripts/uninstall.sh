#!/bin/zsh
set -euo pipefail

APP="$HOME/Applications/Print as PocketMod.app"
SUPPORT="$HOME/Library/Application Support/Print as PocketMod"
PLAIN="$HOME/Library/PDF Services/Print as PocketMod"
GUIDED="$HOME/Library/PDF Services/Print as PocketMod with Guides"

rm -f "$PLAIN" "$GUIDED"
rm -rf "$APP" "$SUPPORT"

echo "Removed Print as PocketMod."
