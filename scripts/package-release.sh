#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/Resources/Info.plist"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$PLIST")"
BUILD="$ROOT/.build/release/PocketModApp"
DIST_NAME="Print-as-PocketMod-for-Mac-v$VERSION"
DIST="$ROOT/dist/$DIST_NAME"
ZIP="$ROOT/dist/$DIST_NAME.zip"
APP="$DIST/Print as PocketMod.app"

if [[ ! -x "$BUILD" ]]; then
  echo "Release binary not found at $BUILD"
  echo "Run: swift build -c release --product PocketModApp"
  exit 1
fi

rm -rf "$ROOT/dist"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD" "$APP/Contents/MacOS/PocketModApp"
cp "$PLIST" "$APP/Contents/Info.plist"
chmod 755 "$APP/Contents/MacOS/PocketModApp"
/usr/bin/plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Ad-hoc signing keeps the bundle internally consistent. It is still not
# notarized, so downloaded copies may require right-click -> Open.
if [[ -x /usr/bin/codesign ]]; then
  /usr/bin/codesign --force --deep --sign - "$APP"
fi

cat > "$DIST/Install.command" <<'INSTALL_EOF'
#!/bin/zsh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCE_APP="$HERE/Print as PocketMod.app"
APP="$HOME/Applications/Print as PocketMod.app"
SERVICES="$HOME/Library/PDF Services"
PLAIN="$SERVICES/Print as PocketMod"
GUIDED="$SERVICES/Print as PocketMod with Guides"

mkdir -p "$HOME/Applications" "$SERVICES"
rm -rf "$APP"
cp -R "$SOURCE_APP" "$APP"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
fi

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

exec /usr/bin/open -n -a "$APP" "$PDF" --args "$MODE"
SERVICE_EOF
  } > "$target"

  chmod 755 "$target"
  /bin/zsh -n "$target"
}

write_service "$PLAIN" "--plain"
write_service "$GUIDED" "--guides"

echo
echo "Installed Print as PocketMod."
echo "Look under File -> Print -> PDF."
read -k 1 "?Press any key to close..."
echo
INSTALL_EOF

cat > "$DIST/Uninstall.command" <<'UNINSTALL_EOF'
#!/bin/zsh
set -euo pipefail

rm -f "$HOME/Library/PDF Services/Print as PocketMod"
rm -f "$HOME/Library/PDF Services/Print as PocketMod with Guides"
rm -rf "$HOME/Applications/Print as PocketMod.app"

echo "Removed Print as PocketMod."
read -k 1 "?Press any key to close..."
echo
UNINSTALL_EOF

cat > "$DIST/README.txt" <<README_EOF
Print as PocketMod for Mac v$VERSION

INSTALL
1. Double-click Install.command.
2. If macOS blocks it because the release is not notarized, right-click Install.command and choose Open.
3. In any application's Print dialog, open the PDF menu.
4. Choose either:
   - Print as PocketMod
   - Print as PocketMod with Guides

The generated PocketMod opens in Preview and is temporary unless you explicitly save it.
README_EOF

chmod 755 "$DIST/Install.command" "$DIST/Uninstall.command"
/bin/zsh -n "$DIST/Install.command"
/bin/zsh -n "$DIST/Uninstall.command"

cd "$ROOT/dist"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$DIST_NAME" "$DIST_NAME.zip"
echo "$ZIP"
