# Plan: own Android emulator app on Google's engine

Goal: a macOS app (your own window and UI) that runs Android as smoothly as MuMu Pro,
reusing the same engine stack (QEMU + Hypervisor.framework + gfxstream/MoltenVK).

## Architecture

```
MyEmu.app (SwiftUI, built with SwiftPM, no Xcode needed)
 ├─ EngineProcess   starts `emulator -avd <name> -qt-hide-window -gpu host -grpc <port>`
 │                  (engine renders on the real GPU, its own window stays hidden)
 ├─ EmulatorClient  gRPC client for emulator_controller.proto (shipped with the engine)
 │                  streamScreenshot → frames, sendMouse/sendKey → input
 └─ ScreenView      draws frames, turns clicks/drags/keys into Android input
```

## Milestones

1. ✅ **Toolchain**: JDK 21 + Android command-line tools (Homebrew), then via sdkmanager:
   platform-tools, emulator, `system-images;android-35;google_apis;arm64-v8a`. Create AVD `myemu`.
   Done when the stock engine boots Android with `-gpu host`.
2. ✅ **App MVP** (`MyEmu/`): SwiftPM app that starts/stops the engine, shows the live screen,
   mouse = touch, keyboard = typing. Done when you can open Settings and type in a search box.
3. ✅ **Performance**: shared-memory (MMAP) frames sampled by Metal in place (zero CPU copies),
   FPS counter (60 fps while animating), scrolling as a virtual finger drag (the phone image has no
   wheel device, so `injectWheel` does nothing there).
4. **MuMu-style features**:
   - ✅ **Icon sidebar** on the right (⌘1–3 open drawers, ⌘R restarts Android):
     - Display: MuMu-style phone/tablet resolution presets or custom width/height/DPI, rotate,
       Apply & Restart (rewrites only those keys in the AVD config.ini). Window reshapes to fit.
     - Performance: FPS limit (Max = screen refresh, applied live), FPS counter on/off, drop to
       30 fps when hidden, CPU & memory presets Low/Medium/High/Ultra or custom (capped to this Mac),
       host-GPU info.
     - Game Keys: switch (⌘G), editor (⌘K), per-key Hold/Burst, burst speed.
   - ✅ Frame rate up to the window's screen refresh (180 Hz monitor → 180 fps): engine
     `-vsync-rate`, Android `peak/min_refresh_rate` (its default caps rendering at 60), display-link drawing.
   - ✅ Per-game keymaps (`keymaps/<package>.json`, switched as the foreground app changes); game
     keys pause while a text field has focus (polled only while game keys are live).
   - ✅ Settings drawer (gear icon, ⌘4): **Play Store** profile (`myemu`, locked image) or **Custom model** profile
     (`myemu-custom`, root-capable google_apis image, `-writable-system`): pick a phone (Galaxy, Xiaomi,
     OnePlus, ROG, RedMagic, Pixel) or custom brand/maker/model; written into every partition's
     build.prop from a one-time backup, Android reboots once.
   - ✅ MEmu-style key-mapping editor: see-through keys over the game, floating toolbar with
     Save / Cancel (edits are a draft until saved), drag keys to move, click a key then press a new
     key to change it, right-click or ⌫ deletes, Add WASD Joystick + size, per-game key opacity.
   - ✅ Typing: "A" (Mac key code 0 = protobuf "unset") sent as Linux KEY_A; Shift / Control /
     Option / Caps Lock forwarded from modifier events (⌘ stays with macOS).
   - ✅ Games above 60 fps: Android 15 holds games at 60 (`ro.surface_flinger.game_default_frame_rate_override`).
     On each app switch MyEmu sets the game's game-mode FPS (`cmd game set --fps`, games only) to the
     Performance limit, which takes precedence. Conquer Online: 55 → 180 fps.
   - ✅ Multiple instances (Instances drawer, ⌘5): each instance is its own Android in its own window
     (AVDs `myemu-<n>` / `myemu-custom-<n>`, gRPC port 8554 + 2(n−1), own profile and model); closing
     a window stops it; New / Start / Stop / rename / Delete (removes its AVDs). Instance 1 keeps the
     original AVDs and settings. Up to 8. Game-key mappings are shared per game.
   - ✅ Game render scale (Performance): games draw at 100/90/85/75/70% via Android's game-mode
     downscaling (applied with the game's fps on app switch; takes effect at next game start).
     Measured on Conquer Online at 180 fps: Mac GPU ≈40% → 36% (85%) → 34% (70%), fps unchanged.
   - ✅ Lightweight Android (Performance, default on): `pm disable-user` on 30 unused Google apps
     (`Debloat.packages`; Play Store, Chrome, sign-in, keyboard, launcher, telephony core protected).
     Idle RAM in use 1.98 GB → 1.34 GB; reversible with the switch.
   - ✅ Mac keyboard only (Game Keys, default on): `show_ime_with_hard_keyboard=0` hides Android's
     on-screen keyboard; verified typing into text, web email, Wi-Fi name/password, number, URL,
     Compose search and an in-game multi-line box (mapped W/E typed as letters).
   - ✅ Graphics renderer (Performance, default Vulkan): `-feature GuestAngle` runs games' OpenGL ES as
     Vulkan on Metal (ANGLE, GLES 3.1) instead of the engine's OpenGL translator (GLES 3.0 over macOS
     OpenGL). Conquer Online start screen at 180 fps: engine CPU 114–129% → 70–72%, Mac GPU 40% → 31–34%.
   - ✅ ANGLE workaround at boot (Vulkan renderer): `debug.angle.feature_overrides_enabled=preferDrawClearOverVkCmdClearAttachments`
     fixes black rectangles in Conquer Online maps; `forceRobustResourceInit` also fixed them but cost fps.
   - ✅ ASG graphics transport enforced on every AVD (`hw.gltransport=asg`): Conquer Online's busiest map
     53–54 → 66–80 fps. Measured and rejected: the per-frame copy (pausing it changed no fps) and ANGLE
     async submission (no gain). The limit is the game's single render/logic thread inside Android.
   - ✅ Sidebar Back / Home / Recent apps (◁ ○ □): Back and App Switch as evdev key presses; Home via
     `input keyevent` (the engine drops KEY_HOMEPAGE).
   - ✅ Display drawer: Landscape / Portrait tabs, each listing its own sizes. New instances start in
     landscape with CPU / memory suggested for the Mac (fast cores + half the efficiency cores, ¼ RAM; 2–8).
   - ✅ Fixed orientation: `wm set-ignore-orientation-request true` at boot, so portrait-only apps are
     letterboxed (black bars) in landscape instead of turning the screen sideways.
   - ✅ Splash screen (`Assets/Splash.png`, copied into the app by the build script) covers the window
     with a status pill until Android has finished booting, also during restarts and model changes.
   - ✅ Restart (sidebar ↻ or ⌘R) asks for confirmation first.
   - ✅ Play Store on both profiles: on a custom-model Android without it, MyEmu adds Google's Play Store
     (`/product/priv-app/Phonesky`, privileged; the image already has its permission files). The APK is
     copied once into `~/Library/Application Support/MyEmu/playstore/` by booting the Play Store AVD
     read-only (console port 5680). Note: the image's LicenseChecker uses Play Store's package name.
   - ✅ Install APK (sidebar ↓ button, or drop .apk files on the window): `adb install -r`; split APKs
     (`split_*.apk`) go together with their base via `install-multiple`.
   - ✅ Frame spikes, round 1: typing detection no longer polls `dumpsys input_method` twice a second
     (~750 KB of text built inside Android each time, including a dump of the game's own process). It
     waits for Android's `ImeTracker` log (keyboard show/hide *requests*) and then checks the editor's
     input type once (0.2 s and 1 s later). Requests alone aren't the state: Conquer sends hide
     requests Android refuses while its chat box stays open, which made mapped keys stop typing.
     It also checks when the watch starts and on every app switch: a box that asks for the keyboard
     before the log stream attaches was missed (`-T 1` replays nothing: the newest buffer line is
     another tag, which `-s` drops). Verified: mapped keys typed "qwerasd1234" into a search box.
     Then still failing in Conquer: the log streams were read with `FileHandle.bytes`, which parks a
     Swift async-pool thread in a blocking read() for the stream's whole life; MyEmu's other async work
     (typing checks, app switches, watch restarts) starved (a `sample` showed it; a killed stream was
     never restarted). `AndroidWatch.lines` now reads each stream on its own GCD thread with read(2).
     Verified: 15/15 keyboard events handled over 5 min in Conquer; "qwerasd1234" typed after 7 min.
   - ✅ Stuck Shift: a key or modifier pressed in MyEmu whose release went to another window (⌘⇧4
     screenshots) stayed held in Android, so typing came out as capitals and symbols. ScreenView
     tracks keys held in Android and releases them when the window loses focus.
   - ✅ Play Store crash ("keeps stopping"): Play Store's self-update in /data could attach to Google's
     placeholder `/product/app/LicenseChecker` (same package) instead of the built-in Phonesky, losing
     its privileged permissions. MyEmu now deletes the placeholder when adding Play Store, and only
     counts Play Store as ready when Phonesky is present and the placeholder is gone. `log.tag.MESA=W` at boot stops the
     guest graphics driver logging 2 lines per frame from the game's render thread. Measured before:
     ~9 frames ≥ 44 ms and ~35 frames of 18–29 ms per 20 s in Conquer Online at 120 fps.
     Tried and reverted: launching the engine at user-interactive QoS (QEMU's vCPU threads stay at 31).
     Stress test (`scripts/stress-test.sh`, Conquer login screen at 180 fps, 8 busy threads on 6 vCPUs,
     3 × 20 s each): old conditions 7 spikes ≥ 40 ms (44–110 ms) + 15 frames of 25–39 ms; new build
     1 spike + 3. MyEmu's slow-frame debug log (category "frames") shows the delay is already in the
     engine's frame times, i.e. inside Android, not in MyEmu's display path.
   - ✅ Colors: MyEmu shows Android's sRGB frames exactly (measured on screen vs `screencap`). Display →
     Colors → Color intensity (60–100%, default 100%) blends toward gray in the shader for a softer look.
   - Considered, not worth it now: zero-copy frame display (MuMu shares the GPU image via IOSurface; MyEmu reads every frame
     back through the engine's screenshot stream), APK drag-and-drop install.

## How MuMu Pro gets its smoothness (static analysis of MuMuPlayer Pro 2.x, 2026-10-27)

Read from `/Applications/MuMuPlayer Pro.app` (binaries, linked libraries, ObjC metadata, disassembly,
the bundled Android image). MuMu was never observed running, so thread timings are inferred, not measured.

| | MuMu Pro | MyEmu today |
|---|---|---|
| Process layout | One process: `MuMu Android Device` loads QEMU (`libqemu-aarch64-softmmu.dylib`) and the GPU renderer (`libRenderer.dylib`) as libraries | Three: MyEmu ↔ gRPC ↔ `qemu-system-aarch64-headless` |
| Engine | NetEase fork of modern upstream QEMU (HVF, `hw/display/virtio-gpu`, custom `hw/pci/vaddress`) | Google emulator 37.2.12 (QEMU 2.12 fork) |
| Host renderer | Google's gfxstream host (`goldfish_vk`, `ColorBuffer`, `FrameBuffer`, `PostWorker`) + ANGLE + MoltenVK, all linked statically into `libRenderer` | Same gfxstream code, inside the engine process |
| Frame to screen | App's `RenderBridge` passes its NSView to the renderer (`createCanvasForParent:width:height:topBar:screenScale:`); gfxstream's post worker presents each guest frame into that view through a MoltenVK swapchain on a CAMetalLayer. No readback, no copy, no IPC. Config default `present_vsync_on: 0` (presents as soon as the guest posts) | Engine reads every frame back from the GPU into shared memory, signals over gRPC; MyEmu draws it on its next CADisplayLink tick (≥ 1 extra copy, up to 1 refresh of added latency) |
| Guest↔host graphics transport | Own PCI device `vaddress` with a dedicated ring thread (`VAddressRingThread`), plus `vkMapMemoryIntoAddressSpaceGOOGLE` | ASG (`hw.gltransport=asg`) |
| vCPU idle wake-up | Custom HVF option `ipi-poll-us` ("HVF ipi wait poll time in us"): a vCPU waiting for an interrupt spins briefly instead of sleeping, so the render thread's wake-ups don't pay a macOS thread wake | Not in Google's engine |
| Thread priority | `qemu_main_loop` calls `pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE)`; renderer queues use dispatch QoS | Engine threads at default QoS (tried user-interactive for the whole process, no gain) |
| CPU / memory | Default 4 vCPUs / 4 GB (presets 2–4 vCPUs) | 6 vCPUs; this Mac (M5) has 4 performance + 6 efficiency cores |
| Guest Android | Android 12, Google's gfxstream guest drivers (`libEGL_emulation`, `vulkan.ranchu`, `libvulkan_enc`), custom `/dev/nemu`; spoofs GPU as "Adreno (TM) 640" so games offer high-quality/high-fps options | Android 15, same guest drivers |
| Frame limits | `fps_limit` (default 60), `fps_limit_low` 15 when in background ("Dynamic Frame Rate") | FPS limit, 30 when hidden |

What MyEmu can reuse without its own engine build:
1. vCPUs = performance cores (4 on this Mac), like MuMu; vCPUs on efficiency cores are a likely
   source of the in-engine spikes the stress test shows. Cheap, measurable with `scripts/stress-test.sh`.
2. GPU name spoof (Adreno) for games that cap fps or quality by GPU. Game-side, not smoothness.

What needs a custom engine (large: build QEMU + gfxstream as libraries, embed them in MyEmu):
`ipi-poll-us`-style HVF polling, a dedicated transport ring thread.

✅ **Direct display (MuMu's frame path, built 2026-10-27)**: no custom engine needed after all. Google's
engine is signed with `allow-dyld-environment-variables` + `disable-library-validation`, so MyEmu loads
`libMyEmuDisplay.dylib` (Sources/MyEmuDisplay) into it with `DYLD_INSERT_LIBRARIES`. Inside the engine it
calls the exported `android_showOpenglesWindow` (gfxstream's subwindow mode, what Google's own UI uses)
with a stand-in window object (the headless engine never runs an AppKit event loop, so a real NSWindow is
impossible), gets gfxstream's `EmuGLViewWithMetal` CAMetalLayer, and shares it through `CAContext`; ScreenView
shows it with a `CALayerHost` (private Core Animation API that Chrome/WebKit rely on). Also as MuMu: display
sync off, QEMU main-loop thread and the presenting thread at user-interactive QoS. sRGB tagged; color
intensity becomes a `CIColorControls` saturation filter on the hosted layer; FPS counter and the "frames"
slow-frame log come from a present counter in a shared 4 KB state file. Falls back to the screenshot stream
if the engine doesn't share its screen within 60 s.
Verified: correct image, live, 139 presents/s scrolling Settings (not capped at 60), no frame file / readback.
Measured on the Xerion Online login screen (stress-test, GAME=com.com.Xerion), very noisy today:
old 43/39 fps idle, 6 fps with 8 busy threads; direct 62/135 fps idle (0 stalls ≥ 40 ms) and 18 fps busy in one
session, 32/32 idle and 6 busy in a repeat. The login screen mostly paces itself at ~30 fps either way, so the
fps difference is unproven; the frame-time limit is still inside Android, as found before.

✅ **Phone number / IMEI (Custom model → Phone) and screen cutout (Display → Screen cutout)**, 2026-10-27:
- Phone number: engine flag `-phone-number` (digits only; a "+" makes the engine refuse to start).
- IMEI has two sources. The engine's modem (`AT+CGSN`, Cuttlefish modem simulator) is patched in memory
  by libMyEmuDisplay (`MYEMU_IMEI`; note dyld image 0 is the inserted library, use `_NSGetMachExecuteHeader`).
  Android 15's Settings uses `DEVICE_IMEI`, answered by Google's reference RIL itself
  (`RefRadioModem::getImei` in `/vendor/lib64/libril-modem-lib.so`, built from 8 MOVZ/MOVK immediates);
  MyEmu patches those (one-time backup `.myemu-orig`, written with `cat` to keep the SELinux label, radio
  restarted). Clearing the IMEI restores the backup. Verified in About phone / SIM status both ways.
- Cutout: Android's own overlays (`cmd overlay enable-exclusive --category …cutout.emulation.<hole|tall|corner|double|waterfall>`), live.

**Smoothness investigation (Xerion Online, 2026-10-27)**: simpleperf on the game's busiest Android thread
(98% of a vCPU, Mac GPU only 25–40%): Vulkan renderer → ~80% graphics plumbing (ASG ping `writel` 22%,
waiting for the host to drain the ring ~14%, ANGLE 19%, Vulkan encoder 18%), game code 20%.
- Engine threads (QEMU's own + gfxstream's) now start at user-interactive QoS (pthread_create interposed in
  libMyEmuDisplay). No change idle; with 8 busy Mac processes stalls ≥ 40 ms per 20 s 13–17 → 0–2. Kept.
- Tried and rejected: `-feature VulkanBatchedDescriptorSetUpdate,AsyncComposeSupport` (no change).
- OpenGL renderer: login screen 32–41 → 180 fps, but in a crowded town 18 fps with the game thread ~68%
  waiting on host replies (`speculativeRead`, ring reads, `writel`); felt worse to the user. Vulkan stays default.
- What's left is the guest→host handoff itself (VM exits per ping, synchronous round trips); MuMu replaced it
  with its own `vaddress` ring device. Not reachable without our own engine build.
- Performance drawer shows an Engine section with live status (direct display / fallback, engine threads on fast cores).

## Requirements / risks
- Downloads ~3 GB from Homebrew and Google (dl.google.com); accepting the Android SDK license.
- Engine is Apache 2.0 / GPLv2 (QEMU) — fine for personal use; check licenses before distributing.
- The engine runs fully headless (`-no-window`): `-qt-hide-window` built a hidden Qt window whose setup
  could deadlock the VM after an in-app restart (engine hang detector then killed it).
- `hw.device.name` is cleared at launch: a named profile (pixel_7) makes the engine re-enable that
  phone's fake camera-hole overlay after boot. The app also disables the overlay once per boot.
- Window resizing is locked to the Android screen's aspect (no black bars); zoom fits the screen.
- Every adb/engine process MyEmu starts gets an empty stdin: sharing MyEmu's stdin stalled adb streams.
- With `-no-window` the engine binary is `qemu-system-aarch64-headless`; leftover-engine detection matches both.

## Run
Build the app (release binary + icon + Info.plist, ad-hoc signed) and open it:
```bash
cd MyEmu && scripts/build-app.sh && open build.noindex/MyEmu.app
```
Build and update the installed copy in /Applications (only ever replaces MyEmu itself):
```bash
cd MyEmu && scripts/build-app.sh --install
```
During development: `cd MyEmu && swift build && .build/debug/MyEmu`. The app (`com.myemu.MyEmu`)
copies the Terminal build's settings once on first launch. Temporary icon: `swift scripts/make-icon.swift Assets`
(or replace `Assets/AppIcon.png` + `AppIcon.icns`).
Tests: `swift test`. The engine binds gRPC on all interfaces; the app always launches it with
`-grpc-use-token` and only connects via 127.0.0.1.
