#!/bin/bash
# Run after release.sh. The private update key stays in the login Keychain.
set -euo pipefail
cd "$(dirname "$0")/.."
TOOLS=${SPARKLE_TOOLS:?Set SPARKLE_TOOLS to Sparkle 2.10.1 distribution's bin directory}
VERSION=$(tr -d '[:space:]' < VERSION)
ARCHIVES=build/appcast
mkdir -p "$ARCHIVES"
cp "dist/Minutes-$VERSION.dmg" "$ARCHIVES/"
"$TOOLS/generate_appcast" --maximum-deltas 0 --maximum-versions 1 \
    --download-url-prefix "https://github.com/chanpollo/minutes/releases/download/v$VERSION/" \
    --link https://github.com/chanpollo/minutes "$ARCHIVES"
cp "$ARCHIVES/appcast.xml" dist/appcast.xml
