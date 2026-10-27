import Foundation
import Testing
@testable import MyEmu

private let device = DeviceSize(width: 1000, height: 2000)
private let fire = KeyTap(keyCode: 49, label: "Space", position: NormalizedPoint(x: 0.9, y: 0.8))

@Test func tapKeyHoldsAFingerUntilReleasedAndIgnoresRepeats() {
    var mapper = KeyTouchMapper(keymap: Keymap(taps: [fire]), device: device)
    #expect(mapper.handle(keyCode: 49, down: true) == [TouchPoint(id: 2, x: 900, y: 1600, pressed: true)])
    #expect(mapper.handle(keyCode: 49, down: true) == []) // auto-repeat
    #expect(mapper.handle(keyCode: 49, down: false) == [TouchPoint(id: 2, x: 900, y: 1600, pressed: false)])
    #expect(mapper.handle(keyCode: 49, down: false) == [])
    #expect(mapper.handle(keyCode: 12, down: true) == nil) // unmapped → normal key
}

@Test func wasdPushesTheJoystickThumbAndLiftsWhenReleased() {
    let keymap = Keymap(joystick: Joystick(center: NormalizedPoint(x: 0.2, y: 0.7), radius: 0.1))
    var mapper = KeyTouchMapper(keymap: keymap, device: device)
    // W: thumb goes down at the center, then up by radius (0.1 × 1000 px).
    #expect(mapper.handle(keyCode: 13, down: true) == [
        TouchPoint(id: 1, x: 200, y: 1400, pressed: true), TouchPoint(id: 1, x: 200, y: 1300, pressed: true),
    ])
    // W+D: diagonal at the same reach.
    #expect(mapper.handle(keyCode: 2, down: true) == [TouchPoint(id: 1, x: 270, y: 1329, pressed: true)])
    #expect(mapper.handle(keyCode: 13, down: false) == [TouchPoint(id: 1, x: 300, y: 1400, pressed: true)])
    #expect(mapper.handle(keyCode: 2, down: false) == [TouchPoint(id: 1, x: 200, y: 1400, pressed: false)])
}

@Test func wasdAreNormalKeysWithoutAJoystick() {
    var mapper = KeyTouchMapper(keymap: Keymap(taps: [fire]), device: device)
    #expect(mapper.handle(keyCode: 13, down: true) == nil)
}

@Test func releaseAllLiftsEveryHeldFinger() {
    let keymap = Keymap(taps: [fire], joystick: Joystick(center: NormalizedPoint(x: 0.5, y: 0.5)))
    var mapper = KeyTouchMapper(keymap: keymap, device: device)
    _ = mapper.handle(keyCode: 49, down: true)
    _ = mapper.handle(keyCode: 0, down: true)
    let lifts = mapper.releaseAll()
    #expect(Set(lifts.map(\.id)) == [1, 2])
    #expect(lifts.allSatisfy { !$0.pressed })
    #expect(mapper.releaseAll() == [])
}

@Test func editingReplacesRemovesAndRoundTrips() throws {
    let moved = KeyTap(keyCode: 49, label: "Space", position: NormalizedPoint(x: 0.1, y: 0.1))
    var keymap = Keymap(taps: [fire]).binding(moved).withJoystick(at: NormalizedPoint(x: 0.3, y: 0.7))
    #expect(keymap.taps == [moved]) // same key rebinds instead of duplicating
    keymap = keymap.removing(.joystick)
    #expect(keymap.joystick == nil && keymap.taps == [moved])

    let url = FileManager.default.temporaryDirectory.appending(path: "keymap-test-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try Keymap.load(from: url) == Keymap()) // missing file → empty
    try keymap.save(to: url)
    #expect(try Keymap.load(from: url) == keymap)
    try Data("not json".utf8).write(to: url)
    #expect(throws: DecodingError.self) { try Keymap.load(from: url) }
}

@Test func oldKeymapFilesDecodeAsHoldKeysAtTheDefaultRate() throws {
    let json = #"{"taps":[{"keyCode":38,"label":"J","position":{"x":0.5,"y":0.5}}]}"#
    let keymap = try JSONDecoder().decode(Keymap.self, from: Data(json.utf8))
    #expect(keymap.taps.first?.mode == .hold)
    #expect(keymap.burstRate == Burst.defaultRate)
    #expect(keymap.joystick == nil)
}

@Test func burstSettingsEditAndRoundTrip() throws {
    let keymap = Keymap(taps: [fire]).settingMode(.burst, forKey: 49).settingBurstRate(15)
    #expect(keymap.taps.first?.mode == .burst)
    #expect(keymap.burstRate == 15)
    #expect(Keymap().settingBurstRate(100).burstRate == Burst.rateRange.upperBound) // clamped
    #expect(try JSONDecoder().decode(Keymap.self, from: JSONEncoder().encode(keymap)) == keymap)
    #expect(keymap.removingTap(forKey: 49).taps.isEmpty)
}

@Test func burstTimingFitsTheRate() {
    func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
    func near(_ a: Duration, _ b: Duration) -> Bool { Swift.abs(ms(a) - ms(b)) < 0.001 } // seconds are Doubles
    let ten = Burst.timing(rate: 10) // 100 ms period: 30 ms down, 70 ms up
    #expect(near(ten.press, .milliseconds(30)) && near(ten.release, .milliseconds(70)))
    let fast = Burst.timing(rate: 50) // clamped to 20/s: 50 ms period, 25 ms down
    #expect(near(fast.press, .milliseconds(25)) && near(fast.press + fast.release, .milliseconds(50)))
    let slow = Burst.timing(rate: 0) // clamped to 2/s
    #expect(near(slow.press + slow.release, .milliseconds(500)))
}

@Test func editorMovesRebindsAndRemoves() {
    let keymap = Keymap(taps: [fire]).withJoystick(at: NormalizedPoint(x: 0.2, y: 0.7))
    let moved = keymap.moving(.tap(keyCode: 49), to: NormalizedPoint(x: 1.4, y: 0.3))
    #expect(moved.taps[0].position == NormalizedPoint(x: 1, y: 0.3)) // kept on screen
    #expect(keymap.moving(.joystick, to: NormalizedPoint(x: 0.5, y: 0.5)).joystick?.center == NormalizedPoint(x: 0.5, y: 0.5))
    let rebound = keymap.rebinding(49, to: 38, label: "J")
    #expect(rebound.taps.map(\.keyCode) == [38] && rebound.taps[0].position == fire.position)
    #expect(keymap.removing(.joystick).joystick == nil && keymap.removing(.tap(keyCode: 49)).taps.isEmpty)
}

@Test func findsTheKeyOrJoystickUnderThePointer() {
    let keymap = Keymap(taps: [fire]).withJoystick(at: NormalizedPoint(x: 0.2, y: 0.7)).settingJoystickRadius(0.1)
    let radius = (x: 0.03, y: 0.015), aspect = 0.5 // portrait: width ÷ height
    #expect(keymap.binding(at: NormalizedPoint(x: 0.91, y: 0.805), keyRadius: radius, aspect: aspect) == .tap(keyCode: 49))
    #expect(keymap.binding(at: NormalizedPoint(x: 0.25, y: 0.72), keyRadius: radius, aspect: aspect) == .joystick)
    #expect(keymap.binding(at: NormalizedPoint(x: 0.5, y: 0.2), keyRadius: radius, aspect: aspect) == nil)
}

@Test func opacityAndJoystickSizeStayInRange() {
    #expect(Keymap().settingOpacity(5).opacity == 1 && Keymap().settingOpacity(0).opacity == 0.1)
    let keymap = Keymap().withJoystick(at: NormalizedPoint(x: 0.5, y: 0.5))
    #expect(keymap.settingJoystickRadius(1).joystick?.radius == 0.2)
    #expect(try! JSONDecoder().decode(Keymap.self, from: Data("{}".utf8)).opacity == Keymap.defaultOpacity)
}
