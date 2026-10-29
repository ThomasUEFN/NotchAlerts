#!/bin/bash
# Builds NotchAlerts.app with the Swift compiler — no Xcode project needed.
# Usage:  ./build.sh            build into ./build
#         ./build.sh --install  build, copy to /Applications and launch
set -euo pipefail
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Swift compiler not found. Install Xcode or run: xcode-select --install"
  exit 1
fi

APP="build/NotchAlerts.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

compile() { # $1 = arch, $2 = output
  xcrun -sdk macosx swiftc \
    -O -swift-version 5 \
    -target "$1-apple-macos14.0" \
    -o "$2" \
    Sources/*.swift Sources/Monitors/*.swift
}

echo "Compiling…"
if [[ "${UNIVERSAL:-}" == "1" ]]; then
  # One app that runs on both Apple Silicon and Intel Macs (used for releases).
  compile arm64 build/NotchAlerts-arm64
  compile x86_64 build/NotchAlerts-x86_64
  lipo -create build/NotchAlerts-arm64 build/NotchAlerts-x86_64 -output "$APP/Contents/MacOS/NotchAlerts"
  rm build/NotchAlerts-arm64 build/NotchAlerts-x86_64
else
  compile "$(uname -m)" "$APP/Contents/MacOS/NotchAlerts"
fi

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  # Quit the running copy and wait until it's really gone, or `open` fails with -600.
  pkill -x NotchAlerts 2>/dev/null || true
  for _ in {1..25}; do pgrep -x NotchAlerts >/dev/null || break; sleep 0.2; done
  rm -rf "/Applications/NotchAlerts.app"
  cp -R "$APP" /Applications/
  sleep 0.5
  open "/Applications/NotchAlerts.app"
  echo "Installed to /Applications and launched."
fi
