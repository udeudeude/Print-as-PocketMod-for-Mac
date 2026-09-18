#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/Print as PocketMod.app"
SERVICES="$HOME/Library/PDF Services"
SERVICE="$SERVICES/Print as PocketMod"

echo "Building Print as PocketMod..."
cd "$ROOT"
/usr/bin/swift build -c release --product PocketModApp

echo "Installing helper app..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/PocketModApp" "$APP/Contents/MacOS/PocketModApp"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
chmod 755 "$APP/Contents/MacOS/PocketModApp"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
fi

echo "Installing Print-dialog PDF Service..."
mkdir -p "$SERVICES"
cat > "$SERVICE" <<'SERVICE_EOF'
#!/bin/zsh
set -u

APP="$HOME/Applications/Print as PocketMod.app"
PDF="${3:-}"

# Core Printing invokes executable workflow items as:
#   title, CUPS options, PDF path
# Fall back to any existing PDF argument in case the invocation changes.
if [[ -z "$PDF" || ! -f "$PDF" ]]; then
  for candidate in "$@"; do
    if [[ -f "$candidate" && "${candidate:l}" == *.pdf ]]; then
      PDF="$candidate"
    fi
  done
fi

[[ -n "$PDF" && -f "$PDF" ]] || exit 0

# Keep the PDF Service tiny. Current macOS runs it inside printtool's sandbox;
# hand the actual PDF work to a normal user-session app.
exec /usr/bin/open -a "$APP" "$PDF"
SERVICE_EOF

chmod 755 "$SERVICE"

echo
echo "Installed."
echo "Use: File -> Print -> PDF -> Print as PocketMod"
echo "The imposed PDF will open in your default PDF viewer."
