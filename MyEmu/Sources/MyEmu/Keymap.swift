import Foundation

/// A screen position as a fraction (0...1) of the device's width and height.
struct NormalizedPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
}

enum TapMode: String, Codable, CaseIterable, Sendable {
    /// The finger stays down while the key is held.
    case hold
    /// Holding the key taps the spot repeatedly at the keymap's burst rate.
    case burst
}

/// A keyboard key that touches one spot while pressed.
struct KeyTap: Codable, Equatable, Sendable {
    var keyCode: UInt16
    var label: String
    var position: NormalizedPoint
    var mode: TapMode = .hold
}

extension KeyTap {
    private enum CodingKeys: String, CodingKey { case keyCode, label, position, mode }

    /// Keymaps saved before burst mode existed have no "mode": they are hold keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decode(UInt16.self, forKey: .keyCode)
        label = try c.decode(String.self, forKey: .label)
        position = try c.decode(NormalizedPoint.self, forKey: .position)
        mode = try c.decodeIfPresent(TapMode.self, forKey: .mode) ?? .hold
    }
}

/// Timing for burst keys.
enum Burst {
    static let rateRange = 2.0...20.0
    static let defaultRate = 10.0
    /// Long enough for games that poll input once per frame to see the touch.
    static let maxPress = 0.03

    /// How long each tap holds the finger down, then how long it waits before the next tap.
    static func timing(rate: Double) -> (press: Duration, release: Duration) {
        let period = 1 / min(max(rate, rateRange.lowerBound), rateRange.upperBound)
        let press = min(maxPress, period / 2)
        return (.seconds(press), .seconds(period - press))
    }
}

/// WASD drives a virtual thumb on an on-screen joystick.
struct Joystick: Codable, Equatable, Sendable {
    static let defaultRadius = 0.08

    var center: NormalizedPoint
    /// How far the thumb travels, as a fraction of the screen width.
    var radius = Joystick.defaultRadius
}

/// One thing on the map: a key's tap spot, or the WASD joystick.
enum BindingRef: Equatable, Sendable {
    case tap(keyCode: UInt16)
    case joystick
}

struct Keymap: Codable, Equatable, Sendable {
    static let opacityRange = 0.1...1.0
    static let defaultOpacity = 0.6
    static let joystickRadiusRange = 0.04...0.2

    var taps: [KeyTap] = []
    var joystick: Joystick?
    /// Taps per second for burst keys.
    var burstRate = Burst.defaultRate
    /// How visible the keys are drawn over the game while playing.
    var opacity = Keymap.defaultOpacity

    var isEmpty: Bool { taps.isEmpty && joystick == nil }

    static let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/MyEmu")
    /// The one mapping from before mappings were per game; offered for copying into a game.
    static let legacyFileURL = supportDirectory.appending(path: "keymap.json")

    /// Each game (Android package) has its own mapping. `package` must pass `AndroidWatch.isValidPackage`.
    static func fileURL(forApp package: String) -> URL {
        supportDirectory.appending(path: "keymaps/\(package).json")
    }

    /// A missing file means no mapping yet; an unreadable one is reported to the caller.
    static func load(from url: URL) throws -> Keymap {
        guard FileManager.default.fileExists(atPath: url.path) else { return Keymap() }
        return try JSONDecoder().decode(Keymap.self, from: Data(contentsOf: url))
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Binds `key` at `position`, replacing whatever that key did before.
    func binding(_ key: KeyTap) -> Keymap {
        var copy = self
        copy.taps = taps.filter { $0.keyCode != key.keyCode } + [key]
        return copy
    }

    func settingMode(_ mode: TapMode, forKey keyCode: UInt16) -> Keymap {
        var copy = self
        copy.taps = taps.map { tap in
            var changed = tap
            if tap.keyCode == keyCode { changed.mode = mode }
            return changed
        }
        return copy
    }

    func settingBurstRate(_ rate: Double) -> Keymap {
        var copy = self
        copy.burstRate = min(max(rate, Burst.rateRange.lowerBound), Burst.rateRange.upperBound)
        return copy
    }

    func removingTap(forKey keyCode: UInt16) -> Keymap {
        var copy = self
        copy.taps = taps.filter { $0.keyCode != keyCode }
        return copy
    }

    func removingJoystick() -> Keymap {
        var copy = self
        copy.joystick = nil
        return copy
    }

    func settingOpacity(_ value: Double) -> Keymap {
        var copy = self
        copy.opacity = min(max(value, Self.opacityRange.lowerBound), Self.opacityRange.upperBound)
        return copy
    }

    func settingJoystickRadius(_ radius: Double) -> Keymap {
        var copy = self
        copy.joystick?.radius = min(max(radius, Self.joystickRadiusRange.lowerBound), Self.joystickRadiusRange.upperBound)
        return copy
    }

    /// Moves a key or the joystick, kept on the screen.
    func moving(_ binding: BindingRef, to point: NormalizedPoint) -> Keymap {
        let clamped = NormalizedPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        var copy = self
        switch binding {
        case .joystick:
            copy.joystick?.center = clamped
        case .tap(let keyCode):
            copy.taps = taps.map { tap in
                var moved = tap
                if tap.keyCode == keyCode { moved.position = clamped }
                return moved
            }
        }
        return copy
    }

    func removing(_ binding: BindingRef) -> Keymap {
        switch binding {
        case .joystick: removingJoystick()
        case .tap(let keyCode): removingTap(forKey: keyCode)
        }
    }

    /// Gives a key's spot to a different keyboard key (the editor's "click a key, press a new one").
    func rebinding(_ keyCode: UInt16, to newKey: UInt16, label: String) -> Keymap {
        guard let tap = taps.first(where: { $0.keyCode == keyCode }) else { return self }
        var replacement = tap
        replacement.keyCode = newKey
        replacement.label = label
        var copy = self
        copy.taps = taps.filter { $0.keyCode != keyCode && $0.keyCode != newKey } + [replacement]
        return copy
    }

    /// The key or joystick under `point`. `keyRadius` is a key's size in normalized units per axis
    /// (screens aren't square); the joystick counts within its own radius.
    func binding(at point: NormalizedPoint, keyRadius: (x: Double, y: Double), aspect: Double) -> BindingRef? {
        func keyDistance(_ p: NormalizedPoint) -> Double {
            hypot((p.x - point.x) / keyRadius.x, (p.y - point.y) / keyRadius.y)
        }
        let nearest = taps.min { keyDistance($0.position) < keyDistance($1.position) }
        if let nearest, keyDistance(nearest.position) <= 1 { return .tap(keyCode: nearest.keyCode) }
        if let joystick {
            // Radius is a fraction of the width; measure in width units on both axes.
            let dx = point.x - joystick.center.x, dy = (point.y - joystick.center.y) / aspect
            if hypot(dx, dy) <= joystick.radius { return .joystick }
        }
        return nil
    }

    func withJoystick(at center: NormalizedPoint) -> Keymap {
        var copy = self
        copy.joystick = Joystick(center: center, radius: joystick?.radius ?? Joystick.defaultRadius)
        return copy
    }

}

extension Keymap {
    private enum CodingKeys: String, CodingKey { case taps, joystick, burstRate, opacity }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taps = try c.decodeIfPresent([KeyTap].self, forKey: .taps) ?? []
        joystick = try c.decodeIfPresent(Joystick.self, forKey: .joystick)
        burstRate = try c.decodeIfPresent(Double.self, forKey: .burstRate) ?? Burst.defaultRate
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? Keymap.defaultOpacity
    }
}

/// One finger to put down, move, or lift, in device pixels.
struct TouchPoint: Equatable, Sendable {
    let id: Int32
    let x: Int32
    let y: Int32
    let pressed: Bool
}

/// Turns key presses into touches for a keymap. Pure logic: the screen view sends the result.
struct KeyTouchMapper {
    static let mouseFingerID: Int32 = 0
    static let joystickFingerID: Int32 = 1
    static let firstTapFingerID: Int32 = 2

    enum MacKey {
        static let w: UInt16 = 13, a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2
        static let wasd: Set<UInt16> = [w, a, s, d]
    }

    let keymap: Keymap
    let device: DeviceSize
    private var heldTaps: Set<UInt16> = []
    private var heldDirections: Set<UInt16> = []

    init(keymap: Keymap, device: DeviceSize) {
        self.keymap = keymap
        self.device = device
    }

    /// Touches for a key change, `[]` for a repeat or stray release, nil when the key isn't mapped
    /// (it should then reach Android as a normal key).
    mutating func handle(keyCode: UInt16, down: Bool) -> [TouchPoint]? {
        if let joystick = keymap.joystick, MacKey.wasd.contains(keyCode) {
            return moveJoystick(joystick, keyCode: keyCode, down: down)
        }
        guard let index = keymap.taps.firstIndex(where: { $0.keyCode == keyCode }) else { return nil }
        let changed = down ? heldTaps.insert(keyCode).inserted : heldTaps.remove(keyCode) != nil
        guard changed else { return [] }
        let (x, y) = device.pixel(keymap.taps[index].position)
        return [TouchPoint(id: Self.firstTapFingerID + Int32(index), x: x, y: y, pressed: down)]
    }

    /// Lifts every finger this mapper holds down (window lost focus, mapping turned off).
    mutating func releaseAll() -> [TouchPoint] {
        var lifts: [TouchPoint] = []
        for keyCode in heldTaps {
            if let lift = handle(keyCode: keyCode, down: false) { lifts += lift }
        }
        if let joystick = keymap.joystick, !heldDirections.isEmpty {
            let (x, y) = device.pixel(joystick.center)
            heldDirections = []
            lifts.append(TouchPoint(id: Self.joystickFingerID, x: x, y: y, pressed: false))
        }
        return lifts
    }

    private mutating func moveJoystick(_ joystick: Joystick, keyCode: UInt16, down: Bool) -> [TouchPoint] {
        let wasActive = !heldDirections.isEmpty
        let changed = down ? heldDirections.insert(keyCode).inserted : heldDirections.remove(keyCode) != nil
        guard changed else { return [] }
        let (cx, cy) = device.pixel(joystick.center)
        guard !heldDirections.isEmpty else {
            return [TouchPoint(id: Self.joystickFingerID, x: cx, y: cy, pressed: false)]
        }
        var dx = 0.0, dy = 0.0
        if heldDirections.contains(MacKey.w) { dy -= 1 }
        if heldDirections.contains(MacKey.s) { dy += 1 }
        if heldDirections.contains(MacKey.a) { dx -= 1 }
        if heldDirections.contains(MacKey.d) { dx += 1 }
        let length = hypot(dx, dy) // 0 when opposite keys cancel: thumb rests at the center
        let reach = joystick.radius * Double(device.width)
        let tx = length == 0 ? Double(cx) : Double(cx) + dx / length * reach
        let ty = length == 0 ? Double(cy) : Double(cy) + dy / length * reach
        let (x, y) = device.clamped(x: tx, y: ty)
        let thumb = TouchPoint(id: Self.joystickFingerID, x: x, y: y, pressed: true)
        // shortcut: down and move go out back to back; games with "floating" sticks may want a
        // frame between them. Add a short delay if a game ignores the first push.
        return wasActive ? [thumb] : [TouchPoint(id: Self.joystickFingerID, x: cx, y: cy, pressed: true), thumb]
    }
}

extension DeviceSize {
    /// A normalized screen position in device pixels, kept on the screen.
    func pixel(_ point: NormalizedPoint) -> (x: Int32, y: Int32) {
        clamped(x: point.x * Double(width), y: point.y * Double(height))
    }

    func clamped(x: Double, y: Double) -> (x: Int32, y: Int32) {
        (Int32(min(max(x, 0), Double(width - 1))), Int32(min(max(y, 0), Double(height - 1))))
    }
}
