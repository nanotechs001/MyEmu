# MyEmu for Windows — handoff for the agent on the Windows PC

Status (2026-11-08, branch `windows-autopots`):
- **Phase 0 is done and failed the gate:** Xerion runs at 7–9 fps on Google's engine (every image/renderer/core
  setup) vs 35 fps in MuMu 12. Details and open questions: `PLAN.md` → "Windows phase 0". Step 1 below
  (full app on Google's engine) is on hold until that gap is closed or the user picks another route.
- **Interim:** `AutoPots/` — a .NET 8 WPF app that runs AutoPots beside a MuMu instance through
  MuMu's own SDK (`external_renderer_ipc.dll`) and MuMuManager. Test on MuMu instance 1.
- **Step 1 started (branch `windows-app`, user's call: our own app, not a MuMu add-on):** `MyEmu/` — .NET 8 WPF.
  `MyEmu.exe` starts Google's engine headless (instance 1, AVD `myemu`) with gRPC (same flags as the Mac), shows Android's
  screen in its window, mouse → touch, keyboard → Android (Windows scan codes), Back/Home/Recents, and
  shuts Android down on close. Tested with the phase-0 AVD `myemu`: Xerion starts and runs in the window.
  - Frames: gRPC `streamScreenshot` with the MMAP transport. On Windows the handle must be
    `file://C:\...` (the engine strips `file://`), the file must not be DeleteOnClose, and the engine's
    writes are only visible through a freshly opened handle (not a mapped view, not a kept handle), so
    each frame is read back (~1 ms per 1600×900 frame).
  - Drawing: `D3DScreen` — a child HWND with a D3D11 flip-model swap chain (RGBA, frame-sized, DXGI
    stretches it; the window is kept at Android's aspect ratio). Each frame is uploaded and presented
    from the frame thread, so every frame Android sends is shown. WPF's WriteableBitmap couldn't: WPF
    redraws at most ~60 Hz and the copy cost ~10 ms per frame (46 sent → 24 shown). Clicks pass
    through the child window to WPF (HTTRANSPARENT).
  - Xerion's start screen: Android itself presents ~33 fps (SurfaceFlinger timestats), and the window
    shows all of them.
  - Options panel (port of `AndroidOptions.swift` + the apply/watch parts of `EmulatorModel`), saved in
    `%LOCALAPPDATA%\MyEmu\settings.json`: frame-rate limit, 30 fps when minimized, game render scale,
    Super Light, Lightweight (debloat), PC keyboard only, renderer (Vulkan/OpenGL, next start). Applied
    at boot and live; a foreground-app watch (logcat `wm_set_resumed_activity`) re-applies the game's
    own game mode on every app switch. Checked in Xerion: game mode fps 165 / scale 0.85 (its override
    was 55), Super Light → 30 / 0.1 / animations off, minimized → 30, restored → 165.
  - Later: gfxstream's render window inside ours (no readback at all) — see "Display" below.
  - Game keys (port of Keymap/GameKeys/KeymapOverlayView/editor bar): per-game
    `%LOCALAPPDATA%\MyEmu\keymaps\<package>.json` in the Mac's exact JSON, with Mac key codes
    (`MacKeys` maps Windows keys; modifiers aren't mappable, as on the Mac). Hold/Burst keys, WASD
    joystick, editor (click a spot + key, drag, right-click/Delete, Alt-click joystick), Ctrl+Shift+K
    edit/save, Ctrl+Shift+G on/off, paused while a text field has the keyboard (ImeTracker watch).
    The keys are drawn by `KeymapOverlay`, a transparent owned window over the screen (WPF can't draw
    over the D3D child): click-through while playing, takes clicks while editing, never takes focus.
    Checked in Xerion: N mapped onto Notice opens it; clicks still reach the game through the overlay.
  - AutoPots: the MuMu app's `Detection.cs`, `Rules.cs`, `Runner.cs` and `Calibration.cs` are linked
    into MyEmu (one copy; `Runner` now takes any frame source + touch sink). `AutoPotsController` reads
    MyEmu's own frames (RGBA, read in place) and taps with finger 9 (the Mac's potion finger). Options
    panel: Start/Stop (F8, global), Auto-detect, Adjust on screen (drag the box, click the potion; drawn
    by `KeymapOverlay`), Orb/Simple view, tuning. Setups: `%APPDATA%\MyEmu\autopots\<package>.json`,
    the MuMu app's file. ponytail: coordinates are screen pixels, so a setup made in MuMu (1280×860)
    is wrong in MyEmu (1600×900) — re-run Auto-detect; store the screen size if both stay in use.
  - Display and CPU & memory (port of `AvdSettings`/`DisplayDrawer`/the CPU & memory section): presets,
    orientation, typed W/H/DPI, cores/memory with a suggestion, written to the AVD's config.ini by
    **Apply & Restart** — an in-app Android restart (also applies a renderer change). Checked: 1600×900 →
    1280×720 → 1600×900 in Xerion's AVD.
  - AI control (port of `MCPProtocol`/`MCPServer`/`MyEmuMCP`): Options → "Allow AI control (MCP)" serves
    `http://127.0.0.1:8765/mcp` (Kestrel, loopback, Origin-checked), same tools and JSON as the Mac; one instance, id `main` / "Android 1". `stop_instance` stops Android, the window
    stays. Screenshots come from MyEmu's own frames. Add it to Claude Code with
    `claude mcp add --transport http myemu http://127.0.0.1:8765/mcp`.
  - Instances (port of `Instances`/`InstanceManager`/`InstancesDrawer`): one process, one window per
    instance; `%LOCALAPPDATA%\MyEmu\instances.json` in the Mac's JSON; instance 1 = AVD `myemu`, port 8554,
    instance n = `myemu-<n>`, port 8554 + 2(n−1). New = fresh Android from instance 1's config (landscape,
    suggested CPU/memory); Clone = a plain copy of a stopped AVD (NTFS has no clones; the dead RAM
    snapshot, locks and run files are skipped); Delete clears read-only files (`pstore.bin`) first.
    Options are app-wide (a change applies to every window); MCP addresses every instance. Checked: a
    second instance ran beside instance 1 (emulator-5556), was stopped, cloned (2.2 GB, ~5 s), the copy
    started over MCP, both deleted. ponytail: F8 (AutoPots) registers for the first window only.
  - Device (port of `DeviceProfile`/`DeviceDrawer`/the identity + Play Store parts of `Engine+Device`):
    per-instance `%LOCALAPPDATA%\MyEmu\device\<id>.json` (profile, identity, phoneLine — the Mac's JSON).
    Custom model = AVD `myemu-custom[-n]` on Google's `google_apis` x86_64 Android 15 image (r09, SHA-1
    `0103e6dab21290c4b9d16550a3ce99476f884eef`, unpacked into `Sdk\system-images\android-35\google_apis\x86_64`;
    the installer must bundle it), booted `-writable-system` (+ `-phone-number`). After boot: Google's Play apps
    copied once from the Play Store AVD (read-only boot on port 5680), then the model written into the
    build.props (one reboot each), then the Settings name. **Windows difference:** the x86_64 image's
    writable-system overlay is only ~80 MB (its spare super space), the Play apps ~320 MB, so they're stored
    in `/data/myemu-play` (labelled `apk_data_file`) with symlinks at the `/product`/`/system_ext` paths —
    Android scans them as privileged system apps. Checked: fresh Custom model → Galaxy S24 Ultra
    (samsung/SM-S928B, About shows the name), Google Play opens to sign-in, ~105 s; back to Play Store keeps Xerion.
  - Game speed (Custom model; Options → Game speed, MCP `set_game_speed`; per instance in
    `device\<id>.json` as `gameSpeed`). The Mac's LD_PRELOAD route fails here: a `wrap.<pkg>` launch
    starts without the ARM translator (Xerion's arm64 libs fail to load), and zygote ignores LD_PRELOAD
    (secure exec). Instead `Android/speed/gpu_tls_bridge.c` (build: `Android/speed/build.ps1`, needs the
    NDK; output `MyEmu/Assets/libgpu_tls.so`, committed) is installed as the native bridge
    (`ro.dalvik.vm.native.bridge=libgpu_tls.so` in `/system/build.prop`, kept by the model script). It
    loads `libndk_translation.so` and patches its `dlsym`/`clock_gettime`/`syscall` imports: the guest
    libc reaches the host clock through trampolines found with dlsym (~4000 reads/s in Xerion). Speed
    and game: `debug.gpu.tls` / `debug.gpu.tlsp`, set when a game (per `cmd game`) comes to the front.
    Checked: Xerion's login animation loop 13.1 s at 1× → 4.36 s at 3×, same fps. Unlike the Mac, every
    ARM library in the game is scaled (incl. its anti-cheat/SDKs); playing logged in at speed not tested.
  - Not yet: IMEI (the Mac patches arm64 code in the radio library and injects into the engine; the x86_64
    image needs its own patch), installer.
The Mac app in `MyEmu/` is Swift/AppKit/Metal and cannot be compiled for Windows — the Windows
version is a new native app that reuses MyEmu's file formats, engine commands and test fixtures.

Goal: a Windows MyEmu (same features as the Mac app) shipped as an **offline installer .exe**
that installs without internet (engine, adb and the Android image bundled).

## Target machine

Laptop "K": Intel Core i5-14500HX (6 P + 8 E cores, 20 threads), 32 GB RAM,
NVIDIA RTX 4050 Laptop 6 GB + Intel iGPU (hybrid), Windows x64.

## Step 0 — run phase 0 first (do not write app code before this)

```powershell
cd MyEmuWindows\phase0
powershell -ExecutionPolicy Bypass -File .\Test-MyEmuWindows.ps1
powershell -ExecutionPolicy Bypass -File .\Test-MyEmuWindows.ps1 -Renderer OpenGL
```

It checks Windows Hypervisor Platform, downloads Google's pinned packages (below), creates a test
AVD, boots it, checks ARM translation, and measures fps/stutter/CPU/GPU while the user plays.
Output: `phase0-report-*.txt` (gitignored). Read it before deciding anything.

**Biggest risk:** the test game Xerion Online (`com.com.Xerion`, always test in this one, not
Conquer) is ARM-only (`lib/arm64-v8a`, `armeabi-v7a`). Intel Windows runs the x86_64 Android image,
so the game runs through Google's ARM→x86 translation. If fps is bad there, stop and report to the
user before building the app.

Pinned Google packages (same versions the Mac app is tested with):

| Package | File | SHA-1 |
|---|---|---|
| emulator 37.2.12 | `emulator-windows_x64-16428233.zip` | `488ed747e82de7e9bb5247becd1ac043c7e5e85d` |
| platform-tools 37.0.1 | `platform-tools_r37.0.1-win.zip` | `e03e78b1d80b396f1c3358e31251cb31740e1110` |
| Android 15 Play x86_64 | `sys-img/google_apis_playstore/x86_64-35_r09.zip` | `2f0054868e6aab3c098acd3decba17a82aed4176` |

## Step 1 — the app (after phase 0 passes)

Agreed stack: **C# / .NET (WPF or WinUI 3), native Windows app** in `MyEmuWindows/`.
No shared cross-language core — share formats and fixtures instead.

### Ports directly (read the Swift source, re-implement in C#)

| Feature | Mac source (`MyEmu/Sources/MyEmu/`) |
|---|---|
| Start/stop engine, CLI flags (`-grpc`, `-gpu host`, `-vsync-rate`, …) | `Engine.swift`, `Engine+Device.swift` |
| gRPC control (screenshots, touch, keys) — same proto | `emulator_controller.proto`, `EmulatorClient.swift` |
| AVD `config.ini` editing, resolution/CPU/RAM presets | `AvdSettings.swift`, `DisplayDrawer.swift`, `PerformanceDrawer.swift` |
| Device model spoofing (build.prop) | `DeviceProfile.swift`, `DeviceDrawer.swift` |
| Multi-instance (AVD names, port 8554 + 2(n−1), max 8) | `Instances.swift`, `InstanceManager.swift` |
| Keymaps (`keymaps/<package>.json`), key editor, translation | `Keymap.swift`, `GameKeys.swift`, `KeyTranslation.swift` |
| AutoPots (HP detection + taps) and its JSON | `AutoPots*.swift` |
| Foreground-app watch, game fps/render scale, debloat, game speed | `AndroidWatch.swift`, `AndroidOptions.swift` |
| APK install | `ApkInstall.swift` |
| MCP endpoint for AI apps | `MCPServer.swift`, `MCPProtocol.swift`, `MyEmuMCP.swift` |
| Settings migration | `SettingsMigration.swift` |

Keep the JSON formats identical so keymaps/AutoPots files move between Mac and Windows.
Port the tests in `MyEmu/Tests/MyEmuTests/` with them; the AutoPots screenshot fixtures in
`Tests/MyEmuTests/Resources/autopots/` must give the same detection results on Windows.

### Needs a Windows-specific replacement

- **Display:** Mac uses CAContext/CALayerHost (`DirectDisplay.swift`) and a Metal fallback
  (`SharedFrameBuffer.swift`, `ScreenView.swift`). Windows: put gfxstream's render subwindow
  into our HWND as a child window; fallback = gRPC/shared-memory frames drawn with D3D11.
- **Speed hook:** done as a native bridge, see Status (the Mac's arm64 preload can't load here).
- **VPN per instance:** the macOS mechanism doesn't port; redo with Windows routing later.
- **Emulator-detection spoofing:** apply the same spoofed props as the Mac code
  (`Engine+Device.swift`) on the x86_64 image and recheck — x86 images expose extra tells
  (`ro.product.cpu.abi`, ARM-translation libs).

### Windows-only requirements from the user

- **GPU priority toggle**, shown only when a dedicated GPU exists (DXGI adapters: non-software,
  dedicated VRAM; hybrid laptops count). Default ON. When on: register MyEmu + `emulator.exe`
  as "High performance" in `HKCU\Software\Microsoft\DirectX\UserGpuPreferences`, make the
  renderer pick that adapter (check `ANGLE_PREFERRED_DEVICE` / Vulkan device selection in phase 0),
  raise GPU scheduling priority (`D3DKMTSetProcessSchedulingPriorityClass`) and CPU priority.
  Off restores defaults.
- Optimisations: engine threads opted out of power throttling/EcoQoS (keep them on P-cores),
  `timeBeginPeriod(1)` for precise AutoPots taps, vCPUs = P-core count, per-game Vulkan/OpenGL
  choice (measured in phase 0).

## Step 2 — offline installer

- Build: `dotnet publish -c Release -r win-x64 --self-contained` (no .NET install needed on the PC).
- Installer: **Inno Setup** (`iscc`) script in `MyEmuWindows/installer/`, bundling the published
  app, the three Google packages above extracted into `{app}\sdk\` (emulator, platform-tools,
  system image), and the icon from `MyEmu/Assets/AppIcon.png`.
  Expect ~2–3 GB. The app must use the bundled SDK path, not `%LOCALAPPDATA%\Android\Sdk`.
- Installer checks: Windows 10 2004+ x64; Windows Hypervisor Platform enabled (offer to enable —
  needs admin + reboot).
- Show Google's Android SDK license in the installer so the user accepts it there.

## Working rules for this repo

- Commits: conventional (`feat:`, `fix:` …). Small, verified steps; test in Xerion.
- Don't commit phase-0 reports, build output, or signing keys (see `.gitignore`).
