#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/Resources/Info.plist"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$PLIST")"
BUILD="${POCKETMOD_BUILD:-$ROOT/.build/release/PocketModApp}"
DIST_NAME="Print as PocketMod $VERSION"
DIST="$ROOT/dist/$DIST_NAME"
ZIP="$ROOT/dist/Print-as-PocketMod-for-Mac-v$VERSION.zip"
PAYLOAD="$DIST/.payload"
APP="$PAYLOAD/Print as PocketMod.app"
INSTALLER="$DIST/Install Print as PocketMod.command"
UNINSTALLER="$DIST/Uninstall Print as PocketMod.command"
START_HERE="$DIST/START HERE.html"

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

# Ad-hoc signing makes the bundle internally consistent. Without an Apple
# Developer account it cannot be Developer ID signed or notarized.
if [[ -x /usr/bin/codesign ]]; then
  /usr/bin/codesign --force --deep --sign - "$APP"
fi

cp "$ROOT/scripts/install.sh" "$INSTALLER"
cp "$ROOT/scripts/uninstall.sh" "$UNINSTALLER"
cp "$ROOT/LICENSE" "$DIST/LICENSE.txt"
chmod 755 "$INSTALLER" "$UNINSTALLER"
/bin/zsh -n "$INSTALLER"
/bin/zsh -n "$UNINSTALLER"

cat > "$START_HERE" <<HTML_EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Print as PocketMod $VERSION - Start Here</title>
<style>
  :root { color-scheme: light dark; }
  body {
    font: -apple-system-body;
    max-width: 760px;
    margin: 48px auto;
    padding: 0 24px 48px;
    line-height: 1.5;
  }
  h1 { font: -apple-system-title1; margin-bottom: 8px; }
  h2 { margin-top: 32px; }
  .lede { font-size: 1.15em; }
  .card {
    border: 1px solid color-mix(in srgb, currentColor 18%, transparent);
    border-radius: 12px;
    padding: 18px 22px;
    margin: 18px 0;
  }
  code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
</style>
</head>
<body>
<h1>Print as PocketMod $VERSION</h1>
<p class="lede">Adds two PocketMod choices to the PDF menu in the normal macOS Print dialog.</p>

<div class="card">
<h2>Install</h2>
<ol>
  <li>Double-click <strong>Install Print as PocketMod.command</strong>.</li>
  <li>If macOS says it cannot verify the developer, <strong>Control-click or right-click the installer</strong>, choose <strong>Open</strong>, then choose <strong>Open</strong> again.</li>
  <li>When the installation-complete message appears, close the Terminal window if it remains open.</li>
</ol>
<p>No administrator password is required. Everything is installed only for your user account.</p>
</div>

<h2>Use</h2>
<ol>
  <li>In any app, choose <strong>File &gt; Print</strong>.</li>
  <li>Open the <strong>PDF</strong> menu in the Print dialog.</li>
  <li>Choose <strong>Print as PocketMod</strong>, or <strong>Print as PocketMod with Guides</strong>.</li>
  <li>The imposed PDF opens in Preview. Print it at 100% / Actual Size unless your printer requires otherwise.</li>
</ol>

<h2>Compatibility</h2>
<p>Requires <strong>macOS 13 or later</strong>. The included app is universal and contains native code for both <strong>Intel</strong> and <strong>Apple Silicon</strong> Macs.</p>

<h2>What it installs</h2>
<p><code>~/Applications/Print as PocketMod.app</code><br>
<code>~/Library/PDF Services/Print as PocketMod</code><br>
<code>~/Library/PDF Services/Print as PocketMod with Guides</code></p>
<p>There is no always-running background service and no network access. The helper runs only when you choose one of the PocketMod items from the Print dialog.</p>

<h2>Uninstall</h2>
<p>Double-click <strong>Uninstall Print as PocketMod.command</strong>.</p>

<h2>If the Print-menu items do not appear</h2>
<p>Close the Print dialog and reopen it. If necessary, quit and reopen the app you are printing from, then try again.</p>

<h2>Why macOS may show a warning</h2>
<p>This free build is ad-hoc signed but is not Apple-notarized because the project does not use a paid Apple Developer account. The Control-click/right-click &gt; Open procedure is macOS's standard manual approval path for software from an unidentified developer.</p>
</body>
</html>
HTML_EOF

cd "$ROOT/dist"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$DIST_NAME" "$ZIP"
echo "$ZIP"
