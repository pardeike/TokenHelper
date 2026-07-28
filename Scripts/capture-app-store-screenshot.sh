#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

BUNDLE_ID="${TOKENCOFFEE_BUNDLE_ID:-com.pardeike.TokenCoffee}"
APP_PATH="${TOKENCOFFEE_APP_PATH:-$PWD/.build/DerivedData/Build/Products/Release/Token Coffee.app}"
MENU_BAR_INDEX="${TOKENCOFFEE_MENU_BAR_INDEX:-0}"
SCREENSHOT_MODE="${TOKENCOFFEE_SCREENSHOT_MODE:-demo}"
OUTPUT="$PWD/Screenshot.png"
PIXEL_WIDTH=1280
PIXEL_HEIGHT=800

command -v brrainztools >/dev/null 2>&1 || {
  printf 'error: brrainztools is required on PATH\n' >&2
  exit 1
}

osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
sleep 0.4

case "$SCREENSHOT_MODE" in
  demo)
    if [ -d "$APP_PATH" ]; then
      open -n "$APP_PATH" --args --demo
    else
      open -n -b "$BUNDLE_ID" --args --demo
    fi
    ;;
  real)
    if [ -d "$APP_PATH" ]; then
      open -n "$APP_PATH"
    else
      open -n -b "$BUNDLE_ID"
    fi
    ;;
  *)
    printf 'error: TOKENCOFFEE_SCREENSHOT_MODE must be demo or real\n' >&2
    exit 1
    ;;
esac

osascript -e "tell application id \"$BUNDLE_ID\" to activate" >/dev/null 2>&1 || true

attempts=0
while ! brrainztools --app "$BUNDLE_ID" --list-menu-bar-items >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  if [ "$attempts" -ge 20 ]; then
    printf 'error: %s did not expose a menu bar item in time\n' "$BUNDLE_ID" >&2
    exit 1
  fi
  sleep 0.25
done

if brrainztools --app "$BUNDLE_ID" --list-elements >/dev/null 2>&1; then
  brrainztools --app "$BUNDLE_ID" --menu-bar-index "$MENU_BAR_INDEX" --press >/dev/null
  sleep 0.2
fi

brrainztools --app "$BUNDLE_ID" --menu-bar-index "$MENU_BAR_INDEX" --press >/dev/null
sleep 0.4

brrainztools --app "$BUNDLE_ID" --list-elements >/dev/null 2>&1 || {
  printf 'error: %s panel did not open\n' "$BUNDLE_ID" >&2
  exit 1
}

RECT=$(
  osascript \
    -e 'use framework "AppKit"' \
    -e 'set pixelWidth to 1280' \
    -e 'set pixelHeight to 800' \
    -e 'set screenFrame to frame() of mainScreen() of NSScreen of current application' \
    -e 'set screenScale to backingScaleFactor() of mainScreen() of NSScreen of current application' \
    -e 'set pointWidth to pixelWidth / screenScale' \
    -e 'set pointHeight to pixelHeight / screenScale' \
    -e 'if (NSWidth(screenFrame) of current application) < pointWidth or (NSHeight(screenFrame) of current application) < pointHeight then error "main screen is too small for 1280x800 screenshot"' \
    -e 'set captureX to (NSMaxX(screenFrame) of current application) - pointWidth' \
    -e 'set captureY to 0' \
    -e 'return ((captureX div 1) as integer as text) & " " & ((captureY div 1) as integer as text) & " " & ((pointWidth div 1) as integer as text) & " " & ((pointHeight div 1) as integer as text)'
)

set -- $RECT
rm -f "$OUTPUT"
brrainztools "$1" "$2" "$3" "$4" --output "$OUTPUT" >/dev/null

ACTUAL_WIDTH=$(sips -g pixelWidth "$OUTPUT" 2>/dev/null | awk '/pixelWidth:/ { print $2 }')
ACTUAL_HEIGHT=$(sips -g pixelHeight "$OUTPUT" 2>/dev/null | awk '/pixelHeight:/ { print $2 }')

if [ "$ACTUAL_WIDTH" != "$PIXEL_WIDTH" ] || [ "$ACTUAL_HEIGHT" != "$PIXEL_HEIGHT" ]; then
  printf 'error: expected %sx%s screenshot, got %sx%s\n' \
    "$PIXEL_WIDTH" "$PIXEL_HEIGHT" "$ACTUAL_WIDTH" "$ACTUAL_HEIGHT" >&2
  exit 1
fi

printf '%s\n' "$OUTPUT"
