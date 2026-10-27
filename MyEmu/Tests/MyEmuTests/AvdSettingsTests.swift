import Testing
@testable import MyEmu

private let host = HostLimits(maxCpuCores: 10, maxRamMB: 8192)
private let phone = AvdSettings(width: 1080, height: 2400, density: 420, cpuCores: 4, ramMB: 4096)

@Test func readsAvdConfigIncludingRamSuffixes() throws {
    let settings = try AvdSettings(config: parseIni("hw.lcd.width=1080\nhw.lcd.height=2400\nhw.lcd.density=420\nhw.cpu.ncore=4\nhw.ramSize=4G\n"))
    #expect(settings == phone)
    #expect(parseMegabytes("228M") == 228 && parseMegabytes("2048") == 2048 && parseMegabytes("x") == nil)
    #expect(throws: AvdSettings.Invalid.self) { try AvdSettings(config: [:]) }
}

@Test func validatesAgainstTheHostAndMetalAlignment() {
    #expect(phone.problem(on: host) == nil)
    #expect(AvdSettings(width: 1082, height: 2400, density: 420, cpuCores: 4, ramMB: 4096).problem(on: host) == "Width must be a multiple of 4.")
    #expect(phone.with(PerformancePreset(name: "x", cpuCores: 12, ramMB: 4096)).problem(on: host) != nil)
    #expect(phone.with(PerformancePreset(name: "x", cpuCores: 4, ramMB: 16384)).problem(on: host) != nil)
    #expect(AvdSettings(width: 100, height: 2400, density: 420, cpuCores: 4, ramMB: 4096).problem(on: host) != nil)
    for preset in ResolutionPreset.all { #expect(phone.with(preset).problem(on: host) == nil, "\(preset.name)") }
}

@Test func presetsRotateAndMatch() {
    let tablet = phone.with(ResolutionPreset.all[5])
    #expect(tablet.isLandscape && tablet.configValues["hw.initialOrientation"] == "landscape")
    #expect(ResolutionPreset.matching(tablet)?.name == "Tablet 1920 × 1080")
    #expect(tablet.rotated().width == 1080 && !tablet.rotated().isLandscape)
    #expect(PerformancePreset.matching(phone)?.name == "Medium")
    #expect(PerformancePreset.available(on: HostLimits(maxCpuCores: 10, maxRamMB: 6144)).map(\.name) == ["Low", "Medium", "High"])
}

@Test func updatesIniInPlaceAndKeepsOtherLines() {
    let text = "avd.ini.encoding=UTF-8\nhw.lcd.width=1080\nhw.ramSize=4G\n"
    let updated = updatingIni(text, with: ["hw.lcd.width": "1920", "hw.ramSize": "6144M", "hw.lcd.density": "280"])
    #expect(updated == "avd.ini.encoding=UTF-8\nhw.lcd.width=1920\nhw.ramSize=6144M\nhw.lcd.density=280\n")
}

@Test func suggestsCpuAndMemoryFromTheMac() {
    // M5-class: 4 fast + 6 efficiency cores, 16 GB (maxRamMB is half).
    let m5 = HostLimits(maxCpuCores: 10, maxRamMB: 8192, performanceCores: 4, efficiencyCores: 6)
    #expect(PerformancePreset.suggested(for: m5).cpuCores == 7 && PerformancePreset.suggested(for: m5).ramMB == 4096)
    // Big Mac: capped at 8 cores / 8 GB.
    let max = HostLimits(maxCpuCores: 24, maxRamMB: 65536, performanceCores: 16, efficiencyCores: 8)
    #expect(PerformancePreset.suggested(for: max).cpuCores == 8 && PerformancePreset.suggested(for: max).ramMB == 8192)
    // Small Mac: never below 2 / 2 GB, never above what the Mac allows.
    let small = HostLimits(maxCpuCores: 4, maxRamMB: 4096, performanceCores: 2, efficiencyCores: 2)
    #expect(PerformancePreset.suggested(for: small).cpuCores == 3 && PerformancePreset.suggested(for: small).ramMB == 2048)
    #expect(phone.with(PerformancePreset.suggested(for: m5)).problem(on: m5) == nil)
}

@Test func newInstancesStartInLandscapeSizedForTheMac() {
    let m5 = HostLimits(maxCpuCores: 10, maxRamMB: 8192, performanceCores: 4, efficiencyCores: 6)
    let fresh = phone.forNewInstance(on: m5)
    #expect(fresh.isLandscape && fresh.width == 2400 && fresh.height == 1080)
    #expect(fresh.cpuCores == 7 && fresh.ramMB == 4096)
    #expect(phone.rotated().forNewInstance(on: m5).width == 2400) // already landscape stays as is
}

@Test func resolutionTabsListOneOrientationEach() {
    let landscape = ResolutionPreset.list(landscape: true), portrait = ResolutionPreset.list(landscape: false)
    #expect(landscape.count == ResolutionPreset.all.count && portrait.count == ResolutionPreset.all.count)
    #expect(landscape.allSatisfy { $0.width > $0.height } && portrait.allSatisfy { $0.width < $0.height })
    #expect(portrait.contains { $0.name == "Tablet 1080 × 1920" } && landscape.contains { $0.name == "Phone 2400 × 1080" })
    #expect(ResolutionPreset.matching(phone.rotated())?.name == "Phone 2400 × 1080")
}
