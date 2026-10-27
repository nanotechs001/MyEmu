import Testing
@testable import MyEmu

@Test func presetsAndStockAreSafeToWrite() {
    #expect(DeviceIdentity.stock.problem == nil)
    for preset in DevicePreset.all { #expect(preset.identity.problem == nil, "\(preset.id)") }
}

@Test func rejectsValuesThatCouldBreakTheScript() {
    var identity = DevicePreset.all[0].identity
    identity.model = "SM-S928B\"; reboot"
    #expect(identity.problem != nil)
    identity.model = "a/b"
    #expect(identity.problem != nil)
    identity.model = " "
    #expect(identity.problem == "Model can't be empty.")
    identity.model = String(repeating: "x", count: 41)
    #expect(identity.problem != nil)
}

@Test func scriptRewritesEveryPartitionFromTheBackup() {
    let script = identityScript(for: DevicePreset.all[0].identity)
    for file in ["/system/build.prop", "/vendor/build.prop", "/product/etc/build.prop", "/odm/etc/build.prop"] {
        #expect(script.contains("cp -p \(file).myemu-orig \(file)"))
    }
    #expect(script.contains("\\1=SM-S928B/"))
    #expect(script.contains("\\1=samsung/"))
    #expect(!script.contains("settings")) // set after boot instead: a pre-reboot write can be lost
}

@Test func stockOnlyRestoresTheOriginals() {
    let script = identityScript(for: .stock)
    #expect(script.contains("cp -p /vendor/build.prop.myemu-orig /vendor/build.prop"))
    #expect(!script.contains("sed"))
}

@Test func profilesUseSeparateAvdsAndImages() {
    #expect(DeviceProfile.playStore.avd != DeviceProfile.customModel.avd)
    #expect(DeviceProfile.playStore.imageConfig["PlayStore.enabled"] == "yes")
    #expect(DeviceProfile.customModel.imageConfig["image.sysdir.1"]!.contains("/google_apis/"))
    #expect(DeviceProfile.customModel.needsWritableSystem && !DeviceProfile.playStore.needsWritableSystem)
}
