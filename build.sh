#!/bin/bash
# Builds build/Minutes.app; "./build.sh install" also copies it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/Minutes.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Minutes "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"

# A stable identity keeps microphone and audio-capture permissions across rebuilds.
IDENTITY=${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}
codesign --force --sign "${IDENTITY:--}" "$APP"

if [ "${1:-}" = install ]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/Minutes.app
  cp -R "$APP" ~/Applications/
  echo "installed ~/Applications/Minutes.app"
fi
