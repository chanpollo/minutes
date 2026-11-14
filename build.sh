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
mkdir -p "$APP/Contents/Resources"

# Version from VERSION, a build number that goes up by one per build, the time and the commit, stamped into the
# copied Info.plist only. The counter is BUILD_NUMBER because BUILD is build/ on a case-insensitive disk; it is left
# out of the dirty check, since every build changes it, and written once the app is signed, so a failed step does
# not use up a number.
VERSION=$(tr -d '[:space:]' < VERSION)
BUILD=$(( $(tr -d '[:space:]' < BUILD_NUMBER) + 1 ))
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo none)
[ -z "$(git status --porcelain -- . ':!BUILD_NUMBER' 2>/dev/null)" ] || COMMIT="$COMMIT+"
BUILD_DATE=$(date +%Y-%m-%dT%H:%M:%S%z | sed -E 's/([0-9]{2})$/:\1/')
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" \
  -c "Add :MinutesBuildDate string $BUILD_DATE" -c "Add :MinutesCommit string $COMMIT" "$APP/Contents/Info.plist"
cp docs/CHANGELOG.md "$APP/Contents/Resources/"
echo "Minutes $VERSION ($BUILD) $COMMIT"

# Assets.car carries the macOS 26 icon; AppIcon.icns covers macOS 14 and 15.
xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 14.2 \
  --app-icon AppIcon --output-partial-info-plist build/AppIcon.plist >/dev/null

# A stable identity keeps microphone and audio-capture permissions across rebuilds.
IDENTITY=${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "$BUILD" > BUILD_NUMBER

if [ "${1:-}" = install ]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/Minutes.app
  cp -R "$APP" ~/Applications/
  echo "installed ~/Applications/Minutes.app"
fi
