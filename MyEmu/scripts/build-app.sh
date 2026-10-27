#!/bin/bash
# Builds build.noindex/MyEmu.app: release binary + Info.plist + icon, signed for this Mac.
# Usage: scripts/build-app.sh             build only
#        scripts/build-app.sh --install   build, then update /Applications/MyEmu.app
#        (VERSION=0.2.0 scripts/build-app.sh to stamp a version)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUNDLE_ID="com.myemu.MyEmu"
# ".noindex": Spotlight and Launchpad skip this folder, so only the installed copy shows up in search.
APP="build.noindex/MyEmu.app"
INSTALLED="/Applications/MyEmu.app"
INSTALL=false
case "${1:-}" in
    --install) INSTALL=true ;;
    "") ;;
    *) echo "Unknown option: $1 (use --install)" >&2; exit 2 ;;
esac

echo "▸ Building release binary…"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "▸ Assembling ${APP}…"
rm -rf "$APP" # only the previous build of this bundle
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/MyEmu" "$APP/Contents/MacOS/MyEmu"
# Loaded into the emulator engine so gfxstream presents straight into MyEmu's window.
cp "$BIN_DIR/libMyEmuDisplay.dylib" "$APP/Contents/Frameworks/"
# SwiftPM resource bundles (if any dependency ships one) go where Bundle.module looks in an app.
find "$BIN_DIR" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;

[ -f Assets/AppIcon.icns ] || swift scripts/make-icon.swift Assets
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Optional splash screen shown while Android starts (Assets/Splash.png, .jpg or .webp).
for ext in png jpg jpeg webp; do
    [ -f "Assets/Splash.$ext" ] && cp "Assets/Splash.$ext" "$APP/Contents/Resources/Splash.$ext"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MyEmu</string>
    <key>CFBundleDisplayName</key><string>MyEmu</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>MyEmu</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "▸ Signing (ad-hoc: runs on this Mac)…"
codesign --force --sign - "$APP/Contents/Frameworks/libMyEmuDisplay.dylib"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "✔ Built $(pwd)/$APP ($VERSION)"

if $INSTALL; then
    if [ -e "$INSTALLED" ]; then
        # Only ever replace our own app, never something else that happens to be called MyEmu.
        existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED/Contents/Info.plist" 2>/dev/null || true)"
        if [ "$existing_id" != "$BUNDLE_ID" ]; then
            echo "✘ $INSTALLED exists but isn't MyEmu (bundle ID '${existing_id:-unknown}'); not touching it." >&2
            exit 1
        fi
        rm -rf "$INSTALLED" # our previous install
    fi
    ditto "$APP" "$INSTALLED"
    codesign --verify --strict "$INSTALLED"
    echo "✔ Installed $INSTALLED"
    if pgrep -f "$INSTALLED/Contents/MacOS/MyEmu" >/dev/null; then
        echo "  MyEmu from Applications is running: quit and reopen it to use this build."
    fi
fi
