import Testing
@testable import MyEmu

@Test func debloatNeverTouchesProtectedApps() {
    #expect(Set(Debloat.packages).isDisjoint(with: Debloat.protected))
    #expect(Set(Debloat.packages).count == Debloat.packages.count) // no duplicates
    #expect(Debloat.packages.allSatisfy(AndroidWatch.isValidPackage)) // safe in a shell command
}

@Test func lightweightCommandDisablesOrRestoresEveryApp() {
    let off = AndroidCommands.lightweight(true), on = AndroidCommands.lightweight(false)
    for package in Debloat.packages {
        #expect(off.contains("pm disable-user --user 0 \(package) "))
        #expect(on.contains("pm enable --user 0 \(package) "))
    }
    #expect(off.hasSuffix("; true")) // an app missing on one image doesn't fail the rest
}

@Test func keyboardOnlyFlipsTheHardwareKeyboardSetting() {
    #expect(AndroidCommands.keyboardOnly(true) == "settings put secure show_ime_with_hard_keyboard 0")
    #expect(AndroidCommands.keyboardOnly(false) == "settings put secure show_ime_with_hard_keyboard 1")
}

@MainActor
@Test func gameModeSetsFpsAndRenderScaleForGamesOnly() {
    let scaled = AndroidCommands.gameMode(fps: 180, renderScale: 0.85, package: "com.Tq.CQ2ClientAndroid")
    #expect(scaled == "cmd game list-modes com.Tq.CQ2ClientAndroid | grep -q 'available game modes: \\[[a-z]' && cmd game set --fps 180 --downscale 0.85 com.Tq.CQ2ClientAndroid; true")
    #expect(AndroidCommands.gameMode(fps: 60, renderScale: 1, package: "a.b").contains("--downscale disable"))
    #expect(AndroidCommands.gameMode(fps: 60, renderScale: 0.1, package: "a.b").contains("--fps 60 --downscale 0.10 a.b"))
    #expect(AndroidOptions.renderScales.last == 0.1)
    #expect(AndroidOptions.renderScales.contains(AndroidOptions.superLightRenderScale))
    #expect(AndroidCommands.animations(false) == "settings put global window_animation_scale 0; "
        + "settings put global transition_animation_scale 0; settings put global animator_duration_scale 0")
    #expect(AndroidCommands.animations(true).hasSuffix("animator_duration_scale 1"))
}

@Test func gameSpeedWrapsOnlyWhenNotNormalAndSetsTheLiveProperty() {
    let fast = AndroidCommands.gameSpeed(2.0, package: "com.com.Xerion")
    #expect(fast == "setprop wrap.com.com.Xerion LD_PRELOAD=/system/lib64/libmyemuspeed.so; setprop debug.myemu.speed 2.00")
    let normal = AndroidCommands.gameSpeed(1.0, package: "com.com.Xerion")
    #expect(normal == "setprop wrap.com.com.Xerion ''; setprop debug.myemu.speed 1.00") // clears the wrapper
    #expect(AndroidCommands.gameSpeed(1.5, package: "a.b").hasSuffix("debug.myemu.speed 1.50"))
    #expect(AndroidOptions.gameSpeeds.first == 1.0) // normal is always offered
    #expect(AndroidOptions.gameSpeeds.allSatisfy { $0 >= 0.1 && $0 <= 10 }) // within the library's clamp
}

@Test func engineArgumentsPickTheRenderer() {
    let angle = Engine.arguments(avd: "myemu", port: 8554, refreshRate: 180, writableSystem: false, guestAngle: true)
    let openGL = Engine.arguments(avd: "myemu", port: 8554, refreshRate: 180, writableSystem: true, guestAngle: false)
    #expect(angle.contains("GuestAngle") && !angle.contains("-GuestAngle"))
    #expect(openGL.contains("-GuestAngle") && openGL.last == "-writable-system")
    #expect(Array(angle.prefix(6)) == ["-avd", "myemu", "-no-window", "-gpu", "host", "-feature"])
    #expect(angle.contains("-grpc-use-token") && angle.contains("180"))
}

@Test func angleWorkaroundEnablesOnlyTheCheapClearFix() {
    #expect(AndroidCommands.angleWorkarounds == "setprop debug.angle.feature_overrides_enabled preferDrawClearOverVkCmdClearAttachments")
    #expect(!AndroidCommands.angleWorkarounds.contains("forceRobustResourceInit")) // fixed it too, but cost fps
}

@Test func avdsAreMovedToAsgAndOffNamedDeviceProfiles() {
    let stock = ["hw.device.name": "pixel_7", "hw.gltransport": "pipe", "hw.lcd.width": "1080"]
    #expect(Engine.enforcedConfigChanges(stock) == ["hw.device.name": "", "hw.gltransport": "asg"])
    let done = ["hw.device.name": "", "hw.gltransport": "asg"]
    #expect(Engine.enforcedConfigChanges(done).isEmpty) // nothing rewritten on later launches
    #expect(Engine.enforcedConfigChanges([:]) == Engine.enforcedConfig) // keys missing entirely
}

@Test func navigationKeysAndOrientationLock() {
    #expect(EmulatorModel.NavigationKey.back.rawValue == 158 && EmulatorModel.NavigationKey.home.rawValue == 172)
    #expect(AndroidCommands.keepScreenOrientation.hasPrefix("wm set-ignore-orientation-request true"))
    #expect(AndroidCommands.keepScreenOrientation.contains("accelerometer_rotation 0"))
}
