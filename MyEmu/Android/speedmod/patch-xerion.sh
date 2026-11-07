#!/usr/bin/env bash
# patch-xerion.sh — inject MyEmu game-speed into Xerion's OWN apk (no root, no virtualization).
# It repackages the apk so the game loads libspeedhook.so on launch, then RE-SIGNS it.
# Re-signing changes the signature, so Xerion's server-side integrity check may flag the client.
# Use a throwaway account for the first run.
#
#   ./patch-xerion.sh Xerion.apk [out.apk]
#
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
LIBS_DIR="$SELF_DIR/libs/arm64-v8a"            # libspeedhook.so + libbytehook.so staged here
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BUILD_TOOLS="$(ls -d "$SDK"/build-tools/* 2>/dev/null | sort -V | tail -1)"
KEYSTORE="$SELF_DIR/patch.keystore"            # throwaway key, created on first run

export JAVA_HOME="$(/usr/libexec/java_home -v 17 2>/dev/null || echo /opt/homebrew/opt/openjdk@17)"
export PATH="$JAVA_HOME/bin:$PATH"

IN_APK="${1:-}"
OUT_APK="${2:-${IN_APK%.apk}-speed.apk}"
[ -f "$IN_APK" ] || { echo "usage: $0 Xerion.apk [out.apk]"; exit 1; }
command -v apktool >/dev/null || { echo "need apktool: brew install apktool"; exit 1; }
[ -f "$LIBS_DIR/libspeedhook.so" ] || { echo "missing $LIBS_DIR/libspeedhook.so"; exit 1; }
[ -n "$BUILD_TOOLS" ] || { echo "no Android build-tools under $SDK"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

echo "[1/5] decoding"
apktool d -f -o "$WORK/app" "$IN_APK" >/dev/null

echo "[2/5] adding native libs"
install -d "$WORK/app/lib/arm64-v8a"
cp "$LIBS_DIR"/*.so "$WORK/app/lib/arm64-v8a/"   # speedhook + its deps (bytehook, shadowhook)

echo "[3/5] injecting loader into the launcher activity"
python3 "$SELF_DIR/patch_smali.py" "$WORK/app"

echo "[4/5] rebuilding + aligning"
apktool b -o "$WORK/unsigned.apk" "$WORK/app" >/dev/null
"$BUILD_TOOLS/zipalign" -p -f 4 "$WORK/unsigned.apk" "$WORK/aligned.apk"

echo "[5/5] signing"
if [ ! -f "$KEYSTORE" ]; then
  keytool -genkeypair -v -keystore "$KEYSTORE" -alias patch -keyalg RSA -keysize 2048 \
    -validity 10000 -storepass android -keypass android -dname "CN=MyEmu" >/dev/null 2>&1
fi
"$BUILD_TOOLS/apksigner" sign --ks "$KEYSTORE" --ks-pass pass:android --out "$OUT_APK" "$WORK/aligned.apk"

echo "done -> $OUT_APK"
echo "install:  adb uninstall com.com.Xerion ; adb install \"$OUT_APK\""
echo "speed:    adb shell setprop debug.gpu.tls 3   (defaults to 2x if unset)"
