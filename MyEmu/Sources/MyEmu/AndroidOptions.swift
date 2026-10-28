import Foundation

/// App-wide Android tweaks, applied to every instance at boot and to open ones when changed.
@MainActor
@Observable
final class AndroidOptions {
    static let shared = AndroidOptions()

    // Android's help lists 0.3 as its lowest, but its game mode takes 0.1 (checked on Android 15).
    static let renderScales = [1.0, 0.9, 0.85, 0.75, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1]
    /// Saves Mac GPU time with a barely softer image (85% measured ≈ 10% less GPU at the same fps).
    static let defaultRenderScale = 0.85

    private enum Key {
        static let renderScale = "renderScale", lightweight = "lightweightAndroid", keyboardOnly = "macKeyboardOnly"
        static let guestAngle = "guestAngle", superLight = "superLight", gameSpeed = "gameSpeed"
    }

    /// Offered time-scaling steps; the native library clamps to 0.1–10. 1.0 is normal speed.
    static let gameSpeeds = [1.0, 1.5, 2.0, 3.0, 5.0]

    /// Super Light: games as light as possible, looks don't matter (farming, many instances).
    static let superLightRenderScale = 0.1
    static let superLightFPS = 30

    /// Games draw at 10%, 30 fps, no Android animations, unused apps off. Your own render scale,
    /// frame rate and Lightweight setting come back when it's turned off.
    var superLight: Bool {
        didSet { save(superLight, Key.superLight) }
    }

    var effectiveRenderScale: Double { superLight ? Self.superLightRenderScale : renderScale }
    var effectiveLightweight: Bool { superLight || lightweight }

    /// Games draw at this fraction of the screen and Android scales them up (MuMu-style).
    var renderScale: Double {
        didSet { save(renderScale, Key.renderScale) }
    }
    /// Unused Google apps (see `Debloat.packages`) are switched off.
    var lightweight: Bool {
        didSet { save(lightweight, Key.lightweight) }
    }
    /// Android's on-screen keyboard stays hidden; you type with the Mac keyboard.
    var macKeyboardOnly: Bool {
        didSet { save(macKeyboardOnly, Key.keyboardOnly) }
    }

    /// Games' OpenGL ES runs as Vulkan on Metal (fast) instead of through macOS's old OpenGL.
    /// Takes effect when Android restarts.
    var guestAngle: Bool {
        didSet { save(guestAngle, Key.guestAngle) }
    }

    /// How fast the current game's own clock runs (1.0 = normal). Injected per game; custom-model
    /// profile only. Takes effect when the game next starts, then changes apply live.
    var gameSpeed: Double {
        didSet { save(gameSpeed, Key.gameSpeed) }
    }

    /// Told after any change so open instances can apply it.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Key.renderScale: Self.defaultRenderScale, Key.lightweight: true,
                                     Key.keyboardOnly: true, Key.guestAngle: true])
        let saved = defaults.double(forKey: Key.renderScale)
        renderScale = Self.renderScales.contains(saved) ? saved : Self.defaultRenderScale
        lightweight = defaults.bool(forKey: Key.lightweight)
        macKeyboardOnly = defaults.bool(forKey: Key.keyboardOnly)
        guestAngle = defaults.bool(forKey: Key.guestAngle)
        superLight = defaults.bool(forKey: Key.superLight) // off unless chosen
        let savedSpeed = defaults.double(forKey: Key.gameSpeed)
        gameSpeed = Self.gameSpeeds.contains(savedSpeed) ? savedSpeed : 1.0
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
        onChange?()
    }
}

/// Android commands for the options. Run with adb once Android has booted.
enum AndroidCommands {
    /// Android's window, transition and animator animations off (0) or back to normal (1).
    static func animations(_ on: Bool) -> String {
        ["window_animation_scale", "transition_animation_scale", "animator_duration_scale"]
            .map { "settings put global \($0) \(on ? 1 : 0)" }.joined(separator: "; ")
    }

    /// Hides (or shows again) the on-screen keyboard whenever a hardware keyboard is present.
    static func keyboardOnly(_ on: Bool) -> String {
        "settings put secure show_ime_with_hard_keyboard \(on ? 0 : 1)"
    }

    /// Switches the unused apps off (`pm disable-user`, reversible) or back on. Apps an image
    /// doesn't have are skipped.
    static func lightweight(_ on: Bool) -> String {
        let action = on ? "disable-user --user 0" : "enable --user 0"
        return Debloat.packages.map { "pm \(action) \($0) >/dev/null 2>&1" }.joined(separator: "; ") + "; true"
    }

    /// ANGLE on Apple's Vulkan (MoltenVK) left black rectangles in Conquer Online's maps; drawing
    /// clears instead of using vkCmdClearAttachments fixes that at no visible fps cost. (Also tried
    /// forceRobustResourceInit: it fixed them too but cost fps.) Games read it when they start.
    static let angleWorkarounds = "setprop debug.angle.feature_overrides_enabled preferDrawClearOverVkCmdClearAttachments"

    /// The guest graphics driver (MESA) logs two lines per frame from the game's render thread;
    /// warnings and errors still get through.
    static let quietGraphicsLog = "setprop log.tag.MESA W"

    /// Apps that insist on portrait (or landscape) are letterboxed with black bars instead of turning
    /// the whole screen sideways inside MyEmu's fixed window; auto-rotate is off for the same reason.
    static let keepScreenOrientation = "wm set-ignore-orientation-request true; settings put system accelerometer_rotation 0; "
        + "settings put system user_rotation 0; wm set-letterbox-style --backgroundType solid_color --backgroundColor '#000000'"

    /// Android 15 holds games at 60 fps by default (`ro.surface_flinger.game_default_frame_rate_override`);
    /// a game's own game-mode settings take precedence, so set its fps and render scale there.
    /// Apps Android doesn't treat as games list no game modes and are left alone.
    static func gameMode(fps: Int, renderScale: Double, package: String) -> String {
        let scale = renderScale >= 1 ? "disable" : String(format: "%.2f", renderScale)
        return "cmd game list-modes \(package) | grep -q 'available game modes: \\[[a-z]' && "
            + "cmd game set --fps \(fps) --downscale \(scale) \(package); true"
    }

    /// The game-speed library, in a system lib dir so an app can load it under enforcing SELinux.
    static let speedLibrary = "/system/lib64/libmyemuspeed.so"
    /// Live speed every preloaded game reads (see Android/speed/myemu_speed.c).
    static let speedProperty = "debug.myemu.speed"

    /// Preloads the speed library into `package` for its next launch (unless at normal speed, when it
    /// clears the wrapper), then sets the live speed. The library scales only the game's own clock and
    /// is dormant at 1.0. `package` must pass `AndroidWatch.isValidPackage`.
    /// shortcut: Android caps property names at 92 chars, so a package over ~86 chars can't be wrapped;
    /// real game packages are far shorter, so the `setprop` just fails harmlessly if one ever is.
    static func gameSpeed(_ speed: Double, package: String) -> String {
        let wrap = speed == 1.0 ? "setprop wrap.\(package) ''"
                                : "setprop wrap.\(package) LD_PRELOAD=\(speedLibrary)"
        return "\(wrap); setprop \(speedProperty) \(String(format: "%.2f", speed))"
    }
}

/// Google apps an emulator for games doesn't need. Measured: about 640 MB less RAM in use, no
/// crashes after a reboot, Play Store / sign-in / keyboard / games unaffected.
enum Debloat {
    static let packages = [
        "com.google.android.apps.wellbeing",        // Digital Wellbeing (172 MB resident)
        "com.google.android.googlequicksearchbox",  // Google app / Assistant (≈210 MB)
        "com.google.android.apps.messaging",        // Messages
        "com.google.android.as",                    // Android System Intelligence
        "com.google.android.as.oss",                // Private Compute Services
        "com.google.android.tts",                   // Speech services
        "com.google.android.apps.safetyhub",
        "com.google.android.apps.restore",          // setup-time restore
        "com.google.android.marvin.talkback",
        "com.google.android.apps.wallpaper",
        "com.android.wallpaper.livepicker",
        "com.google.android.apps.customization.pixel",
        "com.google.android.dialer",                // Phone app (the phone service itself stays)
        "com.google.android.contacts",              // Contacts app (the contacts data provider stays)
        "com.android.camera2",
        "com.android.cameraextensions",
        "com.google.android.calendar",
        "com.google.android.gm",                    // Gmail
        "com.google.android.youtube",
        "com.google.android.apps.youtube.music",
        "com.google.android.apps.photos",
        "com.google.android.apps.maps",
        "com.google.android.apps.docs",             // Drive
        "com.google.android.deskclock",
        "com.google.android.projection.gearhead",   // Android Auto
        "com.google.android.feedback",
        "com.android.printspooler",
        "com.android.bips",                         // print service
        "com.android.emergency",
        "com.android.musicfx",
    ]

    /// Never switched off: Play Store and sign-in, the browser some games log in through, the
    /// keyboard, launcher, system UI and phone/telephony core.
    static let protected = [
        "com.google.android.gms", "com.google.android.gsf", "com.android.vending", "com.android.chrome",
        "com.google.android.webview", "com.google.android.inputmethod.latin",
        "com.google.android.apps.nexuslauncher", "com.android.systemui", "com.android.settings",
        "com.android.phone", "com.google.android.documentsui", "com.google.android.permissioncontroller",
        "com.google.android.packageinstaller", "com.android.providers.contacts", "com.android.providers.calendar",
    ]
}
