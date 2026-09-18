#!/bin/zsh
set -euo pipefail

APP="$HOME/Applications/Print as PocketMod.app"
SERVICE="$HOME/Library/PDF Services/Print as PocketMod"

rm -f "$SERVICE"
rm -rf "$APP"

echo "Removed Print as PocketMod."
