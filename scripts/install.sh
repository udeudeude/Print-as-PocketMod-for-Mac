#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/Print as PocketMod.app"
SUPPORT="$HOME/Library/Application Support/Print as PocketMod"
CLI="$SUPPORT/PocketModCLI"
SERVICES="$HOME/Library/PDF Services"
PLAIN="$SERVICES/Print as PocketMod"
GUIDED="$SERVICES/Print as PocketMod with Guides"

echo "Building Print as PocketMod..."
cd "$ROOT"
/usr/bin/swift build -c release --product PocketModApp
/usr/bin/swift build -c release --product PocketModCLI

echo "Installing helper app and direct converter..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$SUPPORT"
cp "$ROOT/.build/release/PocketModApp" "$APP/Contents/MacOS/PocketModApp"
cp "$ROOT/.build/release/PocketModCLI" "$CLI"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
chmod 755 "$APP/Contents/MacOS/PocketModApp" "$CLI"

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
  local guided="$2"

  {
    print -r -- '#!/bin/zsh'
    print -r -- 'set -u'
    printf 'GUIDED=%q\n' "$guided"
    cat <<'SERVICE_EOF'

CLI="$HOME/Library/Application Support/Print as PocketMod/PocketModCLI"
PDF="${3:-}"

if [[ -z "$PDF" || ! -f "$PDF" ]]; then
  PDF=""
  for candidate in "$@"; do
    if [[ -f "$candidate" && "${candidate:l}" == *.pdf ]]; then
      PDF="$candidate"
    fi
  done
fi

[[ -n "$PDF" && -f "$PDF" ]] || exit 0
[[ -x "$CLI" ]] || exit 1

WORK_DIR="$(/usr/bin/mktemp -d /tmp/PrintAsPocketMod.XXXXXX)" || exit 1
OUTPUT="$WORK_DIR/PocketMod.pdf"

if [[ "$GUIDED" == "yes" ]]; then
  "$CLI" "$PDF" "$OUTPUT" --guides || exit $?
else
  "$CLI" "$PDF" "$OUTPUT" || exit $?
fi

exec /usr/bin/open -a Preview "$OUTPUT"
SERVICE_EOF
  } > "$target"

  chmod 755 "$target"
  /bin/zsh -n "$target"
}

write_service "$PLAIN" "no"
write_service "$GUIDED" "yes"

echo
echo "Installed:"
echo "  File -> Print -> PDF -> Print as PocketMod"
echo "  File -> Print -> PDF -> Print as PocketMod with Guides"
