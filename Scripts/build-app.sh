#!/bin/bash
# Builds EdgeDial.app. Pass --install to also copy it into /Applications.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/EdgeDial.app"
VERSION="1.0.0"
BUNDLE_ID="com.diegohermosillo.edgedial"

echo "==> Building release binary"
swift build -c release

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/EdgeDial" "$APP/Contents/MacOS/EdgeDial"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>EdgeDial</string>
    <key>CFBundleDisplayName</key><string>EdgeDial</string>
    <key>CFBundleExecutable</key><string>EdgeDial</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

echo "==> Rendering icon"
if swift "$ROOT/Scripts/make-icon.swift" >/dev/null 2>&1 \
   && iconutil -c icns "$ROOT/build/AppIcon.iconset" \
        -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
    echo "    icon ok"
else
    echo "    icon skipped (not fatal)"
fi

echo "==> Signing"
# A real signing identity keeps macOS from forgetting the app across rebuilds.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Apple Development" | head -1 | awk '{print $2}')
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
    echo "    signed with $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "    ad-hoc signed (no Apple Development identity found)"
fi
codesign --verify --verbose "$APP" 2>&1 | sed 's/^/    /'

echo "==> Built $APP"

if [ "${1:-}" = "--install" ]; then
    DEST="/Applications"
    [ -w "$DEST" ] || DEST="$HOME/Applications"
    mkdir -p "$DEST"
    echo "==> Installing to $DEST"
    pkill -x EdgeDial 2>/dev/null || true
    sleep 0.5
    rm -rf "$DEST/EdgeDial.app"
    cp -R "$APP" "$DEST/EdgeDial.app"
    echo "==> Installed $DEST/EdgeDial.app"
fi
