#!/usr/bin/env bash
# Compila el binario de release, genera el icono, ensambla un .app, lo
# firma ad-hoc y lo instala en /Applications. Pensado para ejecutarse
# desde la raíz del repo: `./scripts/install-mac-app.sh`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="/Applications/ScreenMirror.app"
BUILD_DIR="$REPO_ROOT/mac/.build/arm64-apple-macosx/release"
ICON_TMP="/tmp/smir-icon"

echo "==> Compilando release…"
( cd "$REPO_ROOT/mac" && swift build -c release )

echo "==> Generando icono…"
rm -rf "$ICON_TMP"
mkdir -p "$ICON_TMP/AppIcon.iconset"
xcrun swift "$REPO_ROOT/scripts/generate_icon.swift" "$ICON_TMP/icon_1024.png"

# sips reescala; iconutil sólo acepta los nombres exactos abajo.
for s in 16 32 64 128 256 512 1024; do
    sips -Z $s "$ICON_TMP/icon_1024.png" --out "$ICON_TMP/AppIcon.iconset/_${s}.png" >/dev/null
done
cp "$ICON_TMP/AppIcon.iconset/_16.png"   "$ICON_TMP/AppIcon.iconset/icon_16x16.png"
cp "$ICON_TMP/AppIcon.iconset/_32.png"   "$ICON_TMP/AppIcon.iconset/icon_16x16@2x.png"
cp "$ICON_TMP/AppIcon.iconset/_32.png"   "$ICON_TMP/AppIcon.iconset/icon_32x32.png"
cp "$ICON_TMP/AppIcon.iconset/_64.png"   "$ICON_TMP/AppIcon.iconset/icon_32x32@2x.png"
cp "$ICON_TMP/AppIcon.iconset/_128.png"  "$ICON_TMP/AppIcon.iconset/icon_128x128.png"
cp "$ICON_TMP/AppIcon.iconset/_256.png"  "$ICON_TMP/AppIcon.iconset/icon_128x128@2x.png"
cp "$ICON_TMP/AppIcon.iconset/_256.png"  "$ICON_TMP/AppIcon.iconset/icon_256x256.png"
cp "$ICON_TMP/AppIcon.iconset/_512.png"  "$ICON_TMP/AppIcon.iconset/icon_256x256@2x.png"
cp "$ICON_TMP/AppIcon.iconset/_512.png"  "$ICON_TMP/AppIcon.iconset/icon_512x512.png"
cp "$ICON_TMP/AppIcon.iconset/_1024.png" "$ICON_TMP/AppIcon.iconset/icon_512x512@2x.png"
rm "$ICON_TMP/AppIcon.iconset/_"*.png
iconutil -c icns -o "$ICON_TMP/AppIcon.icns" "$ICON_TMP/AppIcon.iconset"

echo "==> Ensamblando $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/ScreenMirrorServer" "$APP/Contents/MacOS/ScreenMirror"
cp "$ICON_TMP/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$REPO_ROOT/mac/Resources/Info.plist" "$APP/Contents/Info.plist"

echo "==> Firmando ad-hoc…"
codesign --force --deep --sign - "$APP"

echo "==> Listo. Abre con:  open $APP"
