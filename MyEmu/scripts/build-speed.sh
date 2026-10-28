#!/bin/bash
# Builds Android/speed/myemu_speed.c into Assets/libmyemuspeed.so (arm64 Android), which
# build-app.sh bundles. Needs the Android NDK: sdkmanager --install "ndk;30.0.16248370".
set -euo pipefail
cd "$(dirname "$0")/.."

NDK=${ANDROID_NDK:-$(ls -d "$HOME/Library/Android/sdk/ndk/"* 2>/dev/null | sort -V | tail -1)}
CC="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android29-clang"
[ -x "$CC" ] || { echo "✘ Android NDK not found (set ANDROID_NDK)" >&2; exit 1; }

"$CC" -shared -fPIC -O2 -Wall -Werror -Wl,-z,max-page-size=16384 -Wl,--gc-sections -s \
    -o Assets/libmyemuspeed.so Android/speed/myemu_speed.c
echo "✔ Built Assets/libmyemuspeed.so"
