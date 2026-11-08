# MyEmu for Windows — handoff for the agent on the Windows PC

Status (2026-11-07): **no Windows app code exists yet.** Only the phase-0 test script is here.
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
- **Speed hook:** the guest-side library is Android code, so it ports — `MyEmu/Assets/libmyemuspeed.so`
  (source `MyEmu/Android/speed/`) is arm64; build an **x86_64** variant too for the x86_64 image
  (check which one the translated game actually loads). Patched-APK route: `MyEmu/Android/speedmod/`
  (`patch-xerion.sh` is bash; run it in Git Bash/WSL or port to PowerShell). Mac-side DYLD
  injection becomes DLL injection if anything host-side is still needed.
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
  system image), `libmyemuspeed.so`, and the icon from `MyEmu/Assets/AppIcon.png`.
  Expect ~2–3 GB. The app must use the bundled SDK path, not `%LOCALAPPDATA%\Android\Sdk`.
- Installer checks: Windows 10 2004+ x64; Windows Hypervisor Platform enabled (offer to enable —
  needs admin + reboot).
- Show Google's Android SDK license in the installer so the user accepts it there.

## Working rules for this repo

- Commits: conventional (`feat:`, `fix:` …). Small, verified steps; test in Xerion.
- Don't commit phase-0 reports, build output, or signing keys (see `.gitignore`).
