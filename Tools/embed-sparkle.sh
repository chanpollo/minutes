#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP=$1
IDENTITY=$2
STAMP=${3:---timestamp=none}
FRAMEWORK=.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
[ -d "$FRAMEWORK" ] || { echo "Sparkle framework missing; run swift build first" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
ditto "$FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
ROOT="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for bundle in "$ROOT/XPCServices/Installer.xpc" "$ROOT/XPCServices/Downloader.xpc" "$ROOT/Autoupdate" "$ROOT/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
    codesign --force --options runtime "$STAMP" --preserve-metadata=entitlements --sign "$IDENTITY" "$bundle"
done
codesign --verify --deep --strict "$APP/Contents/Frameworks/Sparkle.framework"
