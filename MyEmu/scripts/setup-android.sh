#!/bin/bash
# Installs what MyEmu runs on, straight from Google: the Android emulator engine, adb, and Android 15
# (Google Play image + Google APIs image for the Custom model profile), then creates MyEmu's first
# Android device. Shipped in the installer DMG as "Set Up Android.command". Safe to run again: anything
# already installed is skipped. Apple Silicon only (the engine runs Android on Apple's Hypervisor).
set -euo pipefail

SDK="$HOME/Library/Android/sdk"
# The offline installer carries the packages and their licenses in "Android" next to this script.
LOCAL="$(cd "$(dirname "$0")" && pwd)/Android"
AVD_HOME="$HOME/.android/avd"
REPO="https://dl.google.com/android/repository"
NEEDED_GB=15 # ~4 GB of downloads unpacking to ~8 GB, plus room for Android's own data

# name | SHA-1 (from Google's SDK index) | folder in the SDK | URL. Pinned to the versions MyEmu is tested with.
PACKAGES=(
    "adb (platform-tools 37.0.1)|6ae73f4de6452dc57e62ec02b68eed92a4c21661|platform-tools|$REPO/platform-tools_r37.0.1-darwin.zip"
    "Android emulator engine 37.2.12|3af4fe44ce82b3d88ae5678a53735f27ad729c15|emulator|$REPO/emulator-darwin_aarch64-16428233.zip"
    "Android 15 with Google Play|b01416bc0bca12a85295dad179f9b8a1cae3d1e6|system-images/android-35/google_apis_playstore/arm64-v8a|$REPO/sys-img/google_apis_playstore/arm64-v8a-35_r09.zip"
    "Android 15 with Google APIs|16f5bceca236b2737008977c4aaf826e46a8de7d|system-images/android-35/google_apis/arm64-v8a|$REPO/sys-img/google_apis/arm64-v8a-35_r09.zip"
)

fail() { echo "✘ $*" >&2; exit 1; }

[ "$(uname -m)" = arm64 ] || fail "MyEmu needs a Mac with Apple silicon (M1 or newer)."

work="$(mktemp -d -t myemu-setup)"
trap 'rm -rf "$work"' EXIT

missing=()
for entry in "${PACKAGES[@]}"; do
    IFS='|' read -r name _ folder _ <<< "$entry"
    if [ -f "$SDK/$folder/source.properties" ]; then echo "✔ $name already installed"; else missing+=("$entry"); fi
done

if [ ${#missing[@]} -gt 0 ]; then
    free_gb=$(df -g "$HOME" | awk 'NR==2 {print $4}')
    [ "$free_gb" -ge $NEEDED_GB ] || fail "Needs about $NEEDED_GB GB free on your Mac; $free_gb GB is free."

    if [ -f "$LOCAL/licenses.txt" ]; then
        cp "$LOCAL/licenses.txt" "$work/licenses.txt" # offline installer: the terms travel with it
    else
        # Google's license terms, from the same index sdkmanager uses.
        echo "▸ Fetching Google's license terms…"
        curl -fsSL "$REPO/repository2-3.xml" -o "$work/repo.xml"
        curl -fsSL "$REPO/sys-img/google_apis/sys-img2-3.xml" -o "$work/sysimg.xml"
        license() { xmllint --xpath "string(//*[local-name()='license'][@id='$2'])" "$1"; }
        {
            echo "=== Android SDK License ==="; license "$work/repo.xml" android-sdk-license
            echo; echo "=== Android SDK Preview License ==="; license "$work/repo.xml" android-sdk-preview-license
            echo; echo "=== Android SDK ARM System Image License ==="; license "$work/sysimg.xml" android-sdk-arm-dbt-license
        } > "$work/licenses.txt"
    fi
    more "$work/licenses.txt"
    echo
    read -r -p "Do you accept these Google license agreements? [y/N] " answer
    [[ "$answer" =~ ^[Yy] ]] || fail "Not accepted; nothing was installed."

    for entry in "${missing[@]}"; do
        IFS='|' read -r name sha1 folder url <<< "$entry"
        if [ -f "$LOCAL/$folder/source.properties" ]; then
            echo "▸ Copying ${name} from the installer…"
            mkdir -p "$(dirname "$SDK/$folder")"
            rm -rf "$SDK/$folder" # a half-finished earlier attempt (it had no source.properties)
            ditto "$LOCAL/$folder" "$SDK/$folder"
            echo "✔ $name installed"
            continue
        fi
        echo "▸ Downloading ${name}…" # braces: some locales read "…" as part of the variable name
        zip="$work/package.zip"
        curl -fL --progress-bar "$url" -o "$zip"
        [ "$(shasum -a 1 "$zip" | cut -d' ' -f1)" = "$sha1" ] || fail "$name: download is damaged (checksum mismatch). Run this again."
        echo "  Unpacking…"
        rm -rf "$work/unpacked" && mkdir "$work/unpacked"
        unzip -q "$zip" -d "$work/unpacked"
        rm "$zip"
        top=("$work/unpacked"/*) # each package unzips to one folder
        [ ${#top[@]} -eq 1 ] && [ -d "${top[0]}" ] || fail "$name: unexpected package layout."
        mkdir -p "$(dirname "$SDK/$folder")"
        rm -rf "$SDK/$folder" # a half-finished earlier attempt (it had no source.properties)
        mv "${top[0]}" "$SDK/$folder"
        echo "✔ $name installed"
    done
fi

# MyEmu's first Android: Play Store profile, landscape, CPU and memory sized for this Mac.
# MyEmu copies it for the Custom model profile and new instances.
if [ -f "$AVD_HOME/myemu.ini" ]; then
    echo "✔ Android device already set up"
else
    fast_cores=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo 4)
    cores=$(( fast_cores < 4 ? fast_cores : 4 ))
    ram_mb=$(( $(sysctl -n hw.memsize) / 1048576 / 4 ))
    ram_mb=$(( ram_mb < 4096 ? 4096 : (ram_mb > 8192 ? 8192 : ram_mb) ))
    mkdir -p "$AVD_HOME/myemu.avd"
    cat > "$AVD_HOME/myemu.ini" <<INI
avd.ini.encoding=UTF-8
path=$AVD_HOME/myemu.avd
path.rel=avd/myemu.avd
target=android-35
INI
    cat > "$AVD_HOME/myemu.avd/config.ini" <<CONFIG
PlayStore.enabled=yes
abi.type=arm64-v8a
avd.ini.encoding=UTF-8
disk.dataPartition.size=16G
fastboot.forceColdBoot=no
hw.audioInput=yes
hw.audioOutput=yes
hw.camera.back=emulated
hw.camera.front=none
hw.cpu.arch=arm64
hw.cpu.ncore=$cores
hw.device.manufacturer=Google
hw.device.name=
hw.gltransport=asg
hw.gpu.enabled=yes
hw.gpu.mode=host
hw.gsmModem=yes
hw.initialOrientation=landscape
hw.keyboard=yes
hw.lcd.density=240
hw.lcd.height=900
hw.lcd.width=1600
hw.mainKeys=no
hw.ramSize=${ram_mb}M
hw.sdCard=yes
image.sysdir.1=system-images/android-35/google_apis_playstore/arm64-v8a/
sdcard.size=512 MB
showDeviceFrame=no
tag.display=Google Play
tag.displaynames=Google Play
tag.id=google_apis_playstore
tag.ids=google_apis_playstore
target=android-35
vm.heapSize=228M
CONFIG
    echo "✔ Android device created ($cores CPU cores, $((ram_mb / 1024)) GB memory, 1600 × 900)"
fi

echo
echo "All set. Open MyEmu from your Applications folder."
