#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/Resources/Info.plist"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$PLIST")"
BUILD="${POCKETMOD_BUILD:-$ROOT/.build/release/PocketModApp}"
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
mkdir -p "$APP/Contents/MacOS"
cp "$BUILD" "$APP/Contents/MacOS/PocketModApp"
cp "$PLIST" "$APP/Contents/Info.plist"
chmod 755 "$APP/Contents/MacOS/PocketModApp"
/usr/bin/plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Ad-hoc signing keeps the bundle internally consistent. It is still not
# notarized, so downloaded copies may require right-click -> Open.
if [[ -x /usr/bin/codesign ]]; then
  /usr/bin/codesign --force --deep --sign - "$APP"
fi

cp "$ROOT/scripts/install.sh" "$DIST/Install.command"
cp "$ROOT/scripts/uninstall.sh" "$DIST/Uninstall.command"
chmod 755 "$DIST/Install.command" "$DIST/Uninstall.command"
/bin/zsh -n "$DIST/Install.command"
/bin/zsh -n "$DIST/Uninstall.command"

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

cd "$ROOT/dist"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$DIST_NAME" "$DIST_NAME.zip"
echo "$ZIP"
