#!/bin/bash
# Builds the installer: build.noindex/MyEmu-<version>.dmg with MyEmu.app, an Applications shortcut to
# drag it onto, "Set Up Android.command" (downloads Google's engine and Android 15, see
# setup-android.sh) and a short read-me.
# Usage: scripts/make-dmg.sh             small installer; each Mac downloads Android from Google
#        scripts/make-dmg.sh --offline   also carries this Mac's Android files (~7 GB), no internet needed
#        (VERSION=0.2.0 scripts/make-dmg.sh to stamp a version)
set -euo pipefail
cd "$(dirname "$0")/.."

OFFLINE=false
case "${1:-}" in
    --offline) OFFLINE=true ;;
    "") ;;
    *) echo "Unknown option: $1 (use --offline)" >&2; exit 2 ;;
esac

VERSION="${VERSION:-0.1.0}"
STAGE="build.noindex/dmg-staging"
DMG="build.noindex/MyEmu-$VERSION$($OFFLINE && echo -offline || true).dmg"
SDK="$HOME/Library/Android/sdk"
REPO="https://dl.google.com/android/repository"
# The same packages setup-android.sh installs (the versions MyEmu is tested with).
ANDROID_FOLDERS=(platform-tools emulator
    system-images/android-35/google_apis_playstore/arm64-v8a
    system-images/android-35/google_apis/arm64-v8a)

VERSION="$VERSION" scripts/build-app.sh

echo "▸ Staging installer contents…"
rm -rf "$STAGE" # only our own staging folder
mkdir -p "$STAGE"
ditto build.noindex/MyEmu.app "$STAGE/MyEmu.app"
ln -s /Applications "$STAGE/Applications"
cp scripts/setup-android.sh "$STAGE/Set Up Android.command"
chmod +x "$STAGE/Set Up Android.command"

if $OFFLINE; then
    echo "▸ Adding this Mac's Android files…"
    for folder in "${ANDROID_FOLDERS[@]}"; do
        [ -f "$SDK/$folder/source.properties" ] || { echo "✘ $SDK/$folder is missing; run Set Up Android first." >&2; exit 1; }
        mkdir -p "$(dirname "$STAGE/Android/$folder")"
        cp -c -R "$SDK/$folder" "$STAGE/Android/$folder" # APFS clone: instant, no extra disk space
    done
    # Google's license terms travel with the files; Set Up Android shows them before installing.
    curl -fsSL "$REPO/repository2-3.xml" -o "$STAGE/repo.xml"
    curl -fsSL "$REPO/sys-img/google_apis/sys-img2-3.xml" -o "$STAGE/sysimg.xml"
    license() { xmllint --xpath "string(//*[local-name()='license'][@id='$2'])" "$1"; }
    {
        echo "=== Android SDK License ==="; license "$STAGE/repo.xml" android-sdk-license
        echo; echo "=== Android SDK Preview License ==="; license "$STAGE/repo.xml" android-sdk-preview-license
        echo; echo "=== Android SDK ARM System Image License ==="; license "$STAGE/sysimg.xml" android-sdk-arm-dbt-license
    } > "$STAGE/Android/licenses.txt"
    rm "$STAGE/repo.xml" "$STAGE/sysimg.xml"
fi

if $OFFLINE; then
    SETUP_STEP="Double-click \"Set Up Android\" (first time only). It copies Google's Android
   emulator engine and Android 15 from this installer (no internet needed), shows
   Google's license terms for you to accept, and creates your first Android. On a
   Mac that already has them it skips everything.

   This installer contains Google's Android SDK files: for your own Macs only, do not
   share it (Google's SDK license allows copies only for backup)."
else
    SETUP_STEP="Double-click \"Set Up Android\" (first time only). It downloads Google's Android
   emulator engine and Android 15 (about 4 GB) straight from Google, shows Google's
   license terms for you to accept, and creates your first Android. On a Mac that
   already has them it skips everything."
fi
cat > "$STAGE/Read Me First.txt" <<README
MyEmu $VERSION — Android emulator for gaming on Mac

Needs: a Mac with Apple silicon (M1 or newer), macOS 15 or later, about 15 GB free.

1. Drag MyEmu onto the Applications folder.
2. $SETUP_STEP
3. Open MyEmu from Applications.

If macOS says MyEmu or "Set Up Android" can't be opened because Apple can't check it:
open System Settings → Privacy & Security, scroll down, click "Open Anyway", then
open it again. (MyEmu isn't signed with an Apple Developer ID.)
README

echo "▸ Creating ${DMG}…"
rm -f "$DMG" # the previous build of this version
# LZFSE: much faster than zlib on gigabytes of Android files, and decompresses faster too.
hdiutil create -volname "MyEmu" -srcfolder "$STAGE" -fs HFS+ -format ULFO -quiet "$DMG"
rm -rf "$STAGE"
echo "✔ Built $(pwd)/$DMG ($(du -h "$DMG" | cut -f1))"
