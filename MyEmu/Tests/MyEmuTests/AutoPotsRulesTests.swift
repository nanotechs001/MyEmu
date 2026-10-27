import Foundation
import Testing
@testable import MyEmu

@Test func captureIsShrunkOnlyOnBigScreens() {
    #expect(AutoPotsRules.captureScale(width: 1280, height: 720) == 1)
    #expect(AutoPotsRules.captureScale(width: 1600, height: 900) == 1)
    #expect(AutoPotsRules.captureScale(width: 2400, height: 1080) == 2)
    #expect(AutoPotsRules.captureScale(width: 7680, height: 4320) == 4) // capped
}

@Test func newGamesReadEveryFrame() {
    #expect(AutoPotsSettings().scanIntervalMs == 0)
    #expect(AutoPotsRunner.scale(for: DeviceSize(width: 1280, height: 860)) == 2) // half size: ¼ of the pixels
    #expect(AutoPotsRunner.scale(for: DeviceSize(width: 2400, height: 1080)) == 2)
    #expect(AutoPotsRunner.scale(for: DeviceSize(width: 3840, height: 2160)) == 4)
}

@Test func burstAndTurboTiming() {
    #expect(AutoPotsRules.pressMs(0) == 1) // "instant" is the shortest real press
    #expect(AutoPotsRules.pressMs(5000) == 2000)
    #expect(AutoPotsRules.burstBusyMs(count: 1, pressMs: 1) == 1)
    #expect(AutoPotsRules.burstBusyMs(count: 3, pressMs: 10) == 2 * 11 + 10 + 90) // gaps + last press + settle
    #expect(AutoPotsRules.turboPressMs(rate: 10, pressSetting: 0) == 1)
    #expect(AutoPotsRules.turboPressMs(rate: 10, pressSetting: 500) == 30) // a third of 100 ms, at most 30
    #expect(AutoPotsRules.turboPressMs(rate: 2, pressSetting: 20) == 20)
}

@Test func stuckGuardStopsFutileTapsAndResumesWhenHPMoves() {
    var guardState = StuckGuard()
    let t0 = ContinuousClock.now
    func stuck(_ reading: Float, after ms: Int, tapping: Bool = true) -> Bool {
        guardState.isStuck(reading: reading, now: t0 + .milliseconds(ms), tapping: tapping)
    }
    let notTapping = stuck(0.5, after: 0, tapping: false)  // not tapping yet: no baseline
    let firstTap = stuck(0.5, after: 0)                    // the first tap sets the baseline
    let justBefore = stuck(0.52, after: 2999)
    let atWindow = stuck(0.51, after: 3000)
    let moved = stuck(0.6, after: 3100)                    // moved: the taps work
    #expect(!notTapping && !firstTap && !justBefore && atWindow && !moved)
    guardState.reset()
    let afterReset = stuck(0.6, after: 10_000)
    #expect(!afterReset)
}

@Test func hotkeyRecordsLabelsAndMatchesExactly() {
    let f5 = AutoPotsHotkey.recorded(keyCode: 96, flags: [], characters: nil)
    #expect(f5.label == "F5" && !f5.hasModifiers)
    let optA = AutoPotsHotkey.recorded(keyCode: 0, flags: [.option, .capsLock], characters: "a")
    #expect(optA.label == "⌥A")
    #expect(optA.matches(keyCode: 0, flags: [.option, .capsLock])) // caps lock doesn't count
    #expect(!optA.matches(keyCode: 0, flags: [.option, .shift]))   // extra modifiers do
    #expect(!optA.matches(keyCode: 0, flags: []))
    #expect(AutoPotsHotkey.standard.label == "⌘P")
    #expect(AutoPotsHotkey.standard.matches(keyCode: 35, flags: .command))
}

@Test func triggerHitIsTheCircle() {
    let t = TapTrigger(id: 1, center: PixelPoint(x: 100, y: 100), size: 40)
    #expect(t.contains(PixelPoint(x: 100, y: 100)))
    #expect(t.contains(PixelPoint(x: 119, y: 100)))
    #expect(!t.contains(PixelPoint(x: 116, y: 116))) // inside the square, outside the circle
}

@Test func settingsRoundTripAndReportCalibration() throws {
    var s = AutoPotsSettings()
    #expect(!s.isCalibrated)
    s.orbBox = PixelRect(x: 587, y: 599, width: 44, height: 92)
    s.orbPotion = PixelPoint(x: 553, y: 668)
    #expect(s.isCalibrated && s.potion == PixelPoint(x: 553, y: 668))
    s.view = .simple
    #expect(!s.isCalibrated) // simple view needs its own box, potion and template
    s.simpleBox = PixelRect(x: 91, y: 6, width: 51, height: 16)
    s.simplePotion = PixelPoint(x: 139, y: 83)
    s.simpleSignature = "2:0121"
    #expect(s.isCalibrated)
    s.triggers = [TapTrigger(id: 1, center: PixelPoint(x: 1, y: 2)), TapTrigger(id: 3, center: PixelPoint(x: 3, y: 4))]
    #expect(s.nextTriggerID == 2)

    let url = FileManager.default.temporaryDirectory.appending(path: "autopots-test-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try s.save(to: url)
    #expect(try AutoPotsSettings.load(from: url) == s)
    #expect(try AutoPotsSettings.load(from: url.appendingPathExtension("missing")) == AutoPotsSettings())
}
