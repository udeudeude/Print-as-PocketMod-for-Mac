#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLED_APP="$SCRIPT_DIR/Print as PocketMod.app"
APP="$HOME/Applications/Print as PocketMod.app"
SERVICES="$HOME/Library/PDF Services"
PLAIN="$SERVICES/Print as PocketMod"
GUIDED="$SERVICES/Print as PocketMod with Guides"

mkdir -p "$HOME/Applications"

if [[ -d "$BUNDLED_APP" ]]; then
  echo "Installing prebuilt Print as PocketMod..."
  rm -rf "$APP"
  cp -R "$BUNDLED_APP" "$APP"
else
  echo "Building Print as PocketMod..."
  cd "$ROOT"
  /usr/bin/swift build -c release --product PocketModApp

  echo "Installing helper app..."
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS"
  cp "$ROOT/.build/release/PocketModApp" "$APP/Contents/MacOS/PocketModApp"
  cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
  chmod 755 "$APP/Contents/MacOS/PocketModApp"
fi

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

if [[ -z "$PDF" || ! -f "$PDF" ]]; then
  PDF=""
  for candidate in "$@"; do
    if [[ -f "$candidate" && "${candidate:l}" == *.pdf ]]; then
      PDF="$candidate"
    fi
  done
fi

[[ -n "$PDF" && -f "$PDF" ]] || exit 0

# Keep the PDF Service minimal. LaunchServices hands the spool PDF from
# printtool.agent to the normal helper-app process.
exec /usr/bin/open -n -a "$APP" "$PDF" --args "$MODE"
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

if [[ -t 0 && "${0:t}" == *.command ]]; then
  read -k 1 "?Press any key to close..."
  echo
fi
