#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/Print as PocketMod.app"
SERVICES="$HOME/Library/PDF Services"
PLAIN="$SERVICES/Print as PocketMod"
GUIDED="$SERVICES/Print as PocketMod with Guides"

echo "Building Print as PocketMod..."
cd "$ROOT"
/usr/bin/swift build -c release --product PocketModApp

echo "Installing helper app..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/PocketModApp" "$APP/Contents/MacOS/PocketModApp"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
chmod 755 "$APP/Contents/MacOS/PocketModApp"

/usr/bin/plutil -lint "$APP/Contents/Info.plist" >/dev/null

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
fi

echo "Installing Print-dialog PDF Services..."
mkdir -p "$SERVICES"
rm -f "$PLAIN" "$GUIDED"

write_service() {
  local target="$1"
  local mode="$2"

  {
    print -r -- '#!/bin/zsh'
    print -r -- 'set -u'
    printf 'MODE=%q\n' "$mode"
    cat <<'SERVICE_EOF'

APP="$HOME/Applications/Print as PocketMod.app"
PDF="${3:-}"

# Core Printing normally supplies: title, CUPS options, PDF path.
# Fall back to any PDF-looking existing argument if necessary.
if [[ -z "$PDF" || ! -f "$PDF" ]]; then
  PDF=""
  for candidate in "$@"; do
    if [[ -f "$candidate" && "${candidate:l}" == *.pdf ]]; then
      PDF="$candidate"
    fi
  done
fi

[[ -n "$PDF" && -f "$PDF" ]] || exit 0

exec /usr/bin/open -n -a "$APP" --args "$MODE" "$PDF"
SERVICE_EOF
  } > "$target"

  chmod 755 "$target"
  /bin/zsh -n "$target"
}

write_service "$PLAIN" "--plain"
write_service "$GUIDED" "--guides"

echo
echo "Installed:"
echo "  File -> Print -> PDF -> Print as PocketMod"
echo "  File -> Print -> PDF -> Print as PocketMod with Guides"
