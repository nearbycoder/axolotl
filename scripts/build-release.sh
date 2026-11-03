#!/usr/bin/env bash
# Builds release artifacts into dist/:
#   Axolotl-macOS.zip / .dmg   universal, ad-hoc signed
#   Axolotl-iOS.ipa            unsigned, for sideloading (AltStore, SideStore, Sideloadly)
set -euo pipefail
cd "$(dirname "$0")/.."

DD=build/release
DIST=dist
rm -rf "$DIST" && mkdir -p "$DIST"

command -v xcodegen >/dev/null && xcodegen generate --quiet

echo "▸ macOS"
xcodebuild -project Axolotl.xcodeproj -scheme Axolotl-macOS -configuration Release \
  -derivedDataPath "$DD" -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  build -quiet
APP="$DD/Build/Products/Release/Axolotl.app"
codesign --force --deep --sign - "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/Axolotl-macOS.zip"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Axolotl -srcfolder "$STAGE" -ov -format UDZO "$DIST/Axolotl-macOS.dmg" >/dev/null
rm -rf "$STAGE"

echo "▸ iOS"
xcodebuild -project Axolotl.xcodeproj -scheme Axolotl-iOS -configuration Release \
  -derivedDataPath "$DD" -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  build -quiet
PAYLOAD=$(mktemp -d)
mkdir -p "$PAYLOAD/Payload"
cp -R "$DD/Build/Products/Release-iphoneos/Axolotl.app" "$PAYLOAD/Payload/"
(cd "$PAYLOAD" && zip -qr -y Axolotl-iOS.ipa Payload)
mv "$PAYLOAD/Axolotl-iOS.ipa" "$DIST/"
rm -rf "$PAYLOAD"

(cd "$DIST" && shasum -a 256 * > SHA256SUMS.txt)
ls -lh "$DIST"
