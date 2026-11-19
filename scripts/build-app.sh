#!/usr/bin/env bash
# Builds build/Tern.app from the Swift package. Run on a Mac with Xcode 16 or newer.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/Tern.app"

swift build -c "$CONFIG" --product Tern
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Tern"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Tern"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon from assets/AppIcon.png (1024x1024).
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature so macOS runs it locally and the keychain can tell it apart.
codesign --force --sign - --timestamp=none "$APP"

echo "Built $APP"
echo "Run it with: open $APP"
