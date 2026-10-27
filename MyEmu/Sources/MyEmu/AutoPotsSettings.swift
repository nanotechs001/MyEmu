import AppKit

/// The key (with modifiers) that switches AutoPots on and off; one for every game.
struct AutoPotsHotkey: Codable, Equatable, Sendable {
    var keyCode: UInt16
    /// Command / Option / Control / Shift, as NSEvent.ModifierFlags raw bits.
    var modifiers: UInt
    var label: String

    static let standard = AutoPotsHotkey(keyCode: 35, modifiers: NSEvent.ModifierFlags.command.rawValue, label: "⌘P")
    static let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    private static let defaultsKey = "autoPotsHotkey"
    private static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 49: "Space", 36: "↩", 48: "⇥"]

    var hasModifiers: Bool { modifiers != 0 }

    func matches(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        keyCode == self.keyCode && flags.intersection(Self.relevantModifiers).rawValue == modifiers
    }

    /// The hotkey for a pressed key, labelled the way macOS menus show shortcuts.
    static func recorded(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> AutoPotsHotkey {
        let mods = flags.intersection(relevantModifiers)
        var label = ""
        if mods.contains(.control) { label += "⌃" }
        if mods.contains(.option) { label += "⌥" }
        if mods.contains(.shift) { label += "⇧" }
        if mods.contains(.command) { label += "⌘" }
        label += functionKeys[keyCode] ?? (characters?.uppercased() ?? "Key \(keyCode)")
        return AutoPotsHotkey(keyCode: keyCode, modifiers: mods.rawValue, label: label)
    }

    static var saved: AutoPotsHotkey {
        UserDefaults.standard.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode(AutoPotsHotkey.self, from: $0) } ?? .standard
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }
}

/// A point or rectangle in Android screen pixels.
struct PixelPoint: Codable, Equatable, Sendable {
    var x: Int
    var y: Int
}

struct PixelRect: Codable, Equatable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    func contains(_ p: PixelPoint) -> Bool { p.x >= x && p.x < x + width && p.y >= y && p.y < y + height }
}

/// A turbo tap button placed over a game button: click it to tap there once, hold it to tap
/// repeatedly (autopotsCO's tap triggers, Trigger.kt).
struct TapTrigger: Codable, Equatable, Identifiable, Sendable {
    static let maxCount = 5
    static let rates = 1...10                 // taps per second
    static let sizes = 32...160               // diameter in Android px
    static let holdDelays = 0...1000          // ms held before turbo starts
    static let transparencies = 0...100       // percent see-through

    var id: Int                                // 1…5, shown on the button
    var center: PixelPoint
    var size = 48
    var rate = 10
    var transparency = 40
    /// Lock: once turbo starts it keeps going after release, until the button is clicked again.
    var lock = false
    var holdMs = 250

    func contains(_ p: PixelPoint) -> Bool {
        let dx = p.x - center.x, dy = p.y - center.y
        return dx * dx + dy * dy <= (size / 2) * (size / 2)
    }
}

/// AutoPots settings for one game (saved per Android package, like key mappings).
struct AutoPotsSettings: Codable, Equatable, Sendable {
    enum GameView: String, Codable, CaseIterable, Sendable {
        /// The default HUD: the red/blue HP/MP orb at the bottom.
        case orb
        /// The game's simple view: "HP: 100%" text at the top left.
        case simple
    }

    static let confirmRange = 1...10
    static let tapRandomRange = 0...80
    static let pressRange = 0...2000
    static let burstRange = 1...10
    static let darkMaxRange = 100...230

    var view = GameView.orb
    var orbBox: PixelRect?
    var orbPotion: PixelPoint?
    var simpleBox: PixelRect?
    var simplePotion: PixelPoint?
    /// The "100%" template (SimpleHp.encode), taken at full HP.
    var simpleSignature = ""
    /// Readings below the trigger level in a row before potting (filters skill flashes).
    var confirmReadings = 2
    /// Minimum gap between readings; 0 reads every frame Android draws (fastest).
    var scanIntervalMs = 0
    /// Each potion tap lands up to this many px from the point.
    var tapRandomPx = 0
    /// How long each potion tap is held down.
    var pressMs = 0
    /// Taps fired back to back before HP is read again.
    var clicksPerBurst = 1
    /// nil = the detector's tuned darkness threshold.
    var customDarkMax: Int?
    var triggers: [TapTrigger] = []
    var showTriggers = true

    var potion: PixelPoint? { view == .orb ? orbPotion : simplePotion }

    var isCalibrated: Bool {
        switch view {
        case .orb: orbBox != nil && orbPotion != nil
        case .simple: simpleBox != nil && simplePotion != nil && SimpleHp.decode(simpleSignature) != nil
        }
    }

    /// Lowest free trigger number, or nil when all five are placed.
    var nextTriggerID: Int? { (1...TapTrigger.maxCount).first { id in !triggers.contains { $0.id == id } } }

    // MARK: Storage

    static func fileURL(forApp package: String) -> URL {
        Keymap.supportDirectory.appending(path: "autopots/\(package).json")
    }

    /// A missing file means not set up yet; an unreadable one is reported to the caller.
    static func load(from url: URL) throws -> AutoPotsSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return AutoPotsSettings() }
        return try JSONDecoder().decode(AutoPotsSettings.self, from: Data(contentsOf: url))
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// autopotsCO's runtime rules (OverlayService.kt), as pure functions so they're tested directly.
enum AutoPotsRules {
    /// Fire below 90% HP, in both views (autopotsCO's fixed trigger level).
    static let triggerLevel: Float = 0.90
    /// A low reading that doesn't move more than this for `stuckWindowMs` after tapping means the
    /// taps do nothing (dead, out of potions): stop until it moves or HP is full again.
    static let stuckEpsilon: Float = 0.03
    static let stuckWindowMs = 3000
    /// After a multi-tap burst the HP bar needs a moment before it reflects the potions.
    static let burstSettleMs = 90
    static let burstGapMs = 1
    /// Simple view reads below this as "HP 0%" in the readout.
    static let simpleEmptyLevel: Float = 0.70

    /// The capture is shrunk on big screens, as autopotsCO does (its detectors are tuned for it).
    static func captureScale(width: Int, height: Int) -> Int { min(max(min(width, height) / 540, 1), 4) }

    static func pressMs(_ setting: Int) -> Int { max(min(setting, AutoPotsSettings.pressRange.upperBound), 1) }

    /// How long a burst of `count` taps occupies the potion button, settle time included.
    static func burstBusyMs(count: Int, pressMs: Int) -> Int {
        count > 1 ? (count - 1) * (pressMs + burstGapMs) + pressMs + burstSettleMs : pressMs
    }

    /// Turbo taps are short so a fast rate still registers as separate taps.
    static func turboPressMs(rate: Int, pressSetting: Int) -> Int { max(min(pressSetting, 30, 1000 / rate / 3), 1) }

    /// Within this long of a potion tap, turbo slows to at most 3 taps per second.
    static let potionPriorityMs = 400
    static let slowedTurboIntervalMs = 333
}

/// The futile-tap guard: remembers the reading when tapping began and reports when it hasn't
/// moved for `stuckWindowMs`.
struct StuckGuard {
    private var baseline: Float?
    private var since: ContinuousClock.Instant?

    mutating func reset() { (baseline, since) = (nil, nil) }

    /// Call with each low reading; true means stop tapping for now.
    mutating func isStuck(reading: Float, now: ContinuousClock.Instant, tapping: Bool) -> Bool {
        guard let base = baseline, let start = since else {
            if tapping { (baseline, since) = (reading, now) }
            return false
        }
        if abs(reading - base) > AutoPotsRules.stuckEpsilon {
            (baseline, since) = (reading, now) // it moved: the taps work
            return false
        }
        return now - start >= .milliseconds(AutoPotsRules.stuckWindowMs)
    }
}
