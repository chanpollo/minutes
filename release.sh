#!/bin/bash
# Builds dist/Minutes-<version>.dmg for the team: a universal Minutes.app that carries whisper-cli and the
# sherpa-onnx diarizer. Models are downloaded by the app on first launch.
#
#   CODESIGN_IDENTITY  signing identity (default: Developer ID Application, else Apple Development, else ad-hoc)
#   NOTARY_PROFILE     notarytool keychain profile; when set the app and dmg are notarised and stapled
set -euo pipefail
cd "$(dirname "$0")"

MIN_MACOS=14.2
ARCHS=(arm64 x86_64)
WHISPER_TAG=v1.9.5
SHERPA=sherpa-onnx-v2.0.1-osx-universal2-shared-no-tts
SHERPA_URL=https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/$SHERPA.tar.bz2
SHERPA_SHA256=9021b6f33e8d1657fe5ae7a13e83fc948707f86b749dc7b775680db6451cc2b8
# Shipped next to the binaries they cover. The tarball has none; onnxruntime is the version sherpa-onnx v2.0.1 links.
LICENSES=(
  "sherpa-onnx-LICENSE https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v2.0.1/LICENSE cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"
  "onnxruntime-LICENSE https://raw.githubusercontent.com/microsoft/onnxruntime/v1.28.2/LICENSE 2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c"
  "onnxruntime-ThirdPartyNotices.txt https://raw.githubusercontent.com/microsoft/onnxruntime/v1.28.2/ThirdPartyNotices.txt 0e07b95f3a8d6230037707c5c4a2b554d12c4cb67369669ac255635528ffcee2"
)

CACHE=build/release
# The version and build of the last ./build.sh, so the team gets the build that was tried here.
VERSION=$(tr -d '[:space:]' < VERSION)
BUILD_NUMBER=$(tr -d '[:space:]' < BUILD_NUMBER)
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo none)
[ -z "$(git status --porcelain -- . ':!BUILD_NUMBER' 2>/dev/null)" ] || COMMIT="$COMMIT+"
BUILD_DATE=$(date +%Y-%m-%dT%H:%M:%S%z | sed -E 's/([0-9]{2})$/:\1/')
STAGE=$CACHE/dmg
APP=$STAGE/Minutes.app
DMG=dist/Minutes-$VERSION.dmg

command -v cmake >/dev/null || { echo "cmake not found; brew install cmake" >&2; exit 1; }
mkdir -p "$CACHE" dist

IDENTITY=${CODESIGN_IDENTITY:-}
find_identity() { security find-identity -v -p codesigning | awk -F'"' -v kind="$1" 'index($2, kind) == 1 { print $2; exit }'; }
# The certificate name for a name, part of one or a SHA-1 hash, as codesign matches them.
identity_name() {
  security find-identity -v -p codesigning |
    awk -F'"' -v id="$1" '{ split($1, f, " ") } f[2] == toupper(id) || index($2, id) { print $2; exit }'
}
[ -n "$IDENTITY" ] || IDENTITY=$(find_identity "Developer ID Application")
[ -n "$IDENTITY" ] || IDENTITY=$(find_identity "Apple Development")
[ -n "$IDENTITY" ] || IDENTITY=-
DEVELOPER_ID=false
[ "$IDENTITY" != - ] && [[ $(identity_name "$IDENTITY") == "Developer ID Application"* ]] && DEVELOPER_ID=true
if [ -n "${NOTARY_PROFILE:-}" ] && ! $DEVELOPER_ID; then
  echo "NOTARY_PROFILE is set but $IDENTITY is not a Developer ID Application identity" >&2
  exit 1
fi

# whisper-cli from source: static, Metal shaders inside the binary, one build per arch (ggml picks SIMD flags per arch).
WHISPER_SRC=$CACHE/whisper.cpp-$WHISPER_TAG
[ -d "$WHISPER_SRC" ] || git clone -q --depth 1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp "$WHISPER_SRC"
whisper_slices=()
for arch in "${ARCHS[@]}"; do
  out=$CACHE/whisper-$WHISPER_TAG-$arch
  cmake -S "$WHISPER_SRC" -B "$out" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_NATIVE=OFF \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_OPENMP=OFF \
    -DGGML_CCACHE=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_SERVER=OFF >/dev/null
  cmake --build "$out" --config Release --target whisper-cli -j "$(sysctl -n hw.ncpu)" >/dev/null
  whisper_slices+=("$out/bin/whisper-cli")
done

# sherpa-onnx ships universal2 binaries.
SHERPA_TAR=$CACHE/$SHERPA.tar.bz2
if [ ! -s "$SHERPA_TAR" ]; then
  curl -fL --retry 3 -o "$SHERPA_TAR.part" "$SHERPA_URL"
  mv "$SHERPA_TAR.part" "$SHERPA_TAR"
fi
echo "$SHERPA_SHA256  $SHERPA_TAR" | shasum -a 256 -c --status || { echo "$SHERPA_TAR: checksum mismatch" >&2; exit 1; }
[ -d "$CACHE/$SHERPA" ] || tar -xjf "$SHERPA_TAR" -C "$CACHE"

mkdir -p "$CACHE/licenses"
for entry in "${LICENSES[@]}"; do
  read -r name url sha <<<"$entry"
  file=$CACHE/licenses/$name
  [ -s "$file" ] || curl -fsSL --retry 3 -o "$file" "$url"
  echo "$sha  $file" | shasum -a 256 -c --status || { echo "$file: checksum mismatch" >&2; rm -f "$file"; exit 1; }
done
[ -s "$WHISPER_SRC/LICENSE" ] || { echo "$WHISPER_SRC/LICENSE missing" >&2; exit 1; }

swift build -c release --arch arm64 --arch x86_64 --quiet

rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$APP/Contents/Resources/sherpa-onnx/bin" "$APP/Contents/Resources/sherpa-onnx/lib" "$APP/Contents/Resources/Licenses"
cp .build/apple/Products/Release/Minutes "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 14.2 \
  --app-icon AppIcon --output-partial-info-plist "$STAGE/AppIcon.plist" >/dev/null
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD_NUMBER" \
  -c "Add :MinutesBuildDate string $BUILD_DATE" -c "Add :MinutesCommit string $COMMIT" "$APP/Contents/Info.plist"
cp docs/CHANGELOG.md "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/Licenses/Minutes-LICENSE"
cp .build/checkouts/Sparkle/LICENSE "$APP/Contents/Resources/Licenses/Sparkle-LICENSE"
lipo -create "${whisper_slices[@]}" -output "$APP/Contents/Resources/bin/whisper-cli"
cp "$CACHE/$SHERPA/bin/sherpa-onnx-offline-speaker-diarization" "$APP/Contents/Resources/sherpa-onnx/bin/"
cp "$CACHE/$SHERPA/lib/libonnxruntime.dylib" "$APP/Contents/Resources/sherpa-onnx/lib/"
cp "$WHISPER_SRC/LICENSE" "$APP/Contents/Resources/Licenses/whisper.cpp-LICENSE"
cp "$CACHE"/licenses/* "$APP/Contents/Resources/Licenses/"

machos=()
while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q Mach-O; then machos+=("$f"); fi
done < <(find "$APP" -type f -print0)

newer() { awk -v a="$1" -v b="$2" 'BEGIN { split(a, x, "."); split(b, y, "."); for (i = 1; i <= 3; i++) if (x[i] + 0 != y[i] + 0) exit !(x[i] + 0 > y[i] + 0); exit 1 }'; }
for f in "${machos[@]}"; do
  archs=$(lipo -archs "$f")
  for arch in "${ARCHS[@]}"; do
    [[ " $archs " == *" $arch "* ]] || { echo "${f#$STAGE/}: no $arch slice ($archs)" >&2; exit 1; }
  done
  minos=$(vtool -show-build "$f" | awk '$1 == "minos" { print $2 }')
  [ -n "$minos" ] || { echo "${f#$STAGE/}: no build version" >&2; exit 1; }
  for v in $minos; do
    if newer "$v" "$MIN_MACOS"; then echo "${f#$STAGE/}: needs macOS $v, the app promises $MIN_MACOS" >&2; exit 1; fi
  done
done

# Notarisation needs a secure timestamp; other identities skip the round trip to Apple.
TIMESTAMP=--timestamp=none
$DEVELOPER_ID && TIMESTAMP=--timestamp
sign() { codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$@"; }

DIARIZER=$APP/Contents/Resources/sherpa-onnx/bin/sherpa-onnx-offline-speaker-diarization
DIARIZER_ENTITLEMENTS=()
if [ "$IDENTITY" = - ]; then
  # Ad-hoc signatures carry no Team ID, so library validation would refuse the diarizer's own libonnxruntime.
  cat > "$CACHE/adhoc.entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.cs.disable-library-validation</key>
	<true/>
</dict>
</plist>
EOF
  DIARIZER_ENTITLEMENTS=(--entitlements "$CACHE/adhoc.entitlements")
fi

# Inside out: the app's seal covers the nested binaries' signatures.
for f in "${machos[@]}"; do
  if [ "$f" = "$DIARIZER" ]; then
    sign ${DIARIZER_ENTITLEMENTS[@]+"${DIARIZER_ENTITLEMENTS[@]}"} "$f"
  elif [ "$f" != "$APP/Contents/MacOS/Minutes" ]; then
    sign "$f"
  fi
done
bash Tools/embed-sparkle.sh "$APP" "$IDENTITY" "$TIMESTAMP"
sign --entitlements Resources/Minutes.entitlements "$APP"
codesign --verify --deep --strict "$APP"
# A signing mistake shows up only when the helpers start, e.g. a dylib refused by library validation.
for tool in "$APP/Contents/Resources/bin/whisper-cli" "$DIARIZER"; do
  "$tool" --help >/dev/null 2>&1 || { echo "${tool#$STAGE/} does not start once signed" >&2; exit 1; }
done

notarise() {
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

if [ -n "${NOTARY_PROFILE:-}" ]; then
  # The app gets its own ticket so it still opens offline once copied out of the dmg.
  ZIP=$CACHE/Minutes.zip
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarise "$ZIP"
  xcrun stapler staple "$APP"
fi

ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname Minutes -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG"

if $DEVELOPER_ID; then
  codesign --force "$TIMESTAMP" --sign "$IDENTITY" "$DMG"
fi
if [ -n "${NOTARY_PROFILE:-}" ]; then
  notarise "$DMG"
  xcrun stapler staple "$DMG"
  echo "$DMG ($VERSION, build $BUILD_NUMBER), notarised"
else
  echo "$DMG ($VERSION, build $BUILD_NUMBER), signed by ${IDENTITY/#-/ad-hoc}"
  echo "Not notarised: recipients open it with System Settings › Privacy & Security › Open Anyway (right-click › Open on macOS 14), or run xattr -dr com.apple.quarantine /Applications/Minutes.app"
fi
