#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLED_APP="$SCRIPT_DIR/.payload/Print as PocketMod.app"
[[ -d "$BUNDLED_APP" ]] || BUNDLED_APP="$SCRIPT_DIR/Print as PocketMod.app"

APP="$HOME/Applications/Print as PocketMod.app"
SERVICES="$HOME/Library/PDF Services"
PLAIN="$SERVICES/Print as PocketMod"
GUIDED="$SERVICES/Print as PocketMod with Guides"

is_interactive_command() {
  [[ -t 0 && "${0:t}" == *.command ]]
}

show_dialog() {
  local title="$1"
  local message="$2"
  /usr/bin/osascript - "$title" "$message" <<'APPLESCRIPT'
on run argv
    display dialog (item 2 of argv) buttons {"OK"} default button "OK" with title (item 1 of argv)
end run
APPLESCRIPT
}

on_exit() {
  local status=$?
  if (( status != 0 )) && is_interactive_command; then
    set +e
    show_dialog \
      "Print as PocketMod" \
      "Installation did not finish.

The Terminal window contains the error details." >/dev/null 2>&1
    print
    read -k 1 "?Press any key to close..."
    print
  fi
  return $status
}
trap on_exit EXIT

OS_MAJOR="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)"
if (( OS_MAJOR < 13 )); then
  echo "Print as PocketMod requires macOS 13 or later." >&2
  exit 1
fi

mkdir -p "$HOME/Applications"

install_binary() {
  local binary="$1"

  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS"
  cp "$binary" "$APP/Contents/MacOS/PocketModApp"
  cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
  chmod 755 "$APP/Contents/MacOS/PocketModApp"
}

if [[ -d "$BUNDLED_APP" ]]; then
  echo "Installing Print as PocketMod..."
  rm -rf "$APP"
  /usr/bin/ditto "$BUNDLED_APP" "$APP"
else
  BUILD="${POCKETMOD_BUILD:-}"

  if [[ -z "$BUILD" ]]; then
    echo "Building Print as PocketMod..."
    cd "$ROOT"
    /usr/bin/swift build -c release --product PocketModApp
    BUILD="$ROOT/.build/release/PocketModApp"
  else
    echo "Installing provided Print as PocketMod build..."
  fi

  [[ -x "$BUILD" ]] || {
    echo "PocketModApp binary not found at $BUILD" >&2
    exit 1
  }
  install_binary "$BUILD"
fi

/usr/bin/plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Running this installer is the user's explicit approval of the downloaded
# utility. Clear quarantine only from the installed helper copy so macOS does
# not ask the user to approve the same download a second time when printing.
/usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

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

STAGING="${TMPDIR:-/tmp}/PrintAsPocketModInput"
/bin/mkdir -p "$STAGING" || exit 1

PREFIX="plain"
[[ "$MODE" == "--guides" ]] && PREFIX="guides"

STAGED="$STAGING/$PREFIX-$(/usr/bin/uuidgen).pdf"
/bin/cp "$PDF" "$STAGED" || exit 1

/usr/bin/open -n -a "$APP" "$STAGED"
STATUS=$?
if (( STATUS != 0 )); then
  /bin/rm -f "$STAGED"
fi
exit $STATUS
SERVICE_EOF
  } > "$target"

  chmod 755 "$target"
  /bin/zsh -n "$target"
}

write_service "$PLAIN" "--plain"
write_service "$GUIDED" "--guides"

[[ -x "$APP/Contents/MacOS/PocketModApp" ]]
[[ -x "$PLAIN" ]]
[[ -x "$GUIDED" ]]

echo
echo "Print as PocketMod is installed."
echo "Use File -> Print -> PDF, then choose:"
echo "  Print as PocketMod"
echo "  Print as PocketMod with Guides"

if is_interactive_command; then
  show_dialog \
    "Print as PocketMod" \
    "Installation complete.

In any app, choose File > Print, open the PDF menu, then choose “Print as PocketMod” or “Print as PocketMod with Guides”."
fi
