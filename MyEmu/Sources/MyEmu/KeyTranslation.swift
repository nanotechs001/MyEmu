/// Mac keyboard → what the emulator's sendKey understands.
enum KeyTranslation {
    enum CodeType: Equatable { case mac, evdev }

    static let macKeyA: UInt16 = 0
    static let linuxKeyA: Int32 = 30
    static let capsLock: UInt16 = 57

    /// Mac key codes go through as-is, except A: its Mac code is 0, which is protobuf's "unset",
    /// so the emulator dropped it. Send Linux's KEY_A for it instead.
    static func code(forMacKey keyCode: UInt16) -> (type: CodeType, code: Int32) {
        keyCode == macKeyA ? (.evdev, linuxKeyA) : (.mac, Int32(keyCode))
    }

    /// A modifier key: its side-specific (device-dependent) bit, both sides' bits, and the plain
    /// device-independent flag (Shift 0x20000, Control 0x40000, Option 0x80000).
    private struct Modifier { let sideBit: UInt; let bothSides: UInt; let flag: UInt }

    /// ⌘ and fn are left out on purpose: they stay with macOS for its shortcuts.
    private static let modifiers: [UInt16: Modifier] = [
        56: Modifier(sideBit: 0x0002, bothSides: 0x0006, flag: 0x20000), // left Shift
        60: Modifier(sideBit: 0x0004, bothSides: 0x0006, flag: 0x20000), // right Shift
        59: Modifier(sideBit: 0x0001, bothSides: 0x2001, flag: 0x40000), // left Control
        62: Modifier(sideBit: 0x2000, bothSides: 0x2001, flag: 0x40000), // right Control
        58: Modifier(sideBit: 0x0020, bothSides: 0x0060, flag: 0x80000), // left Option (Android Alt)
        61: Modifier(sideBit: 0x0040, bothSides: 0x0060, flag: 0x80000), // right Option
    ]

    /// Modifier keys only arrive as "flags changed" events. Returns whether the key is now held,
    /// or nil for keys MyEmu doesn't forward this way. Some keyboards and remote/remapping tools
    /// send only the plain flag without side bits; then the plain flag decides.
    static func modifierIsDown(keyCode: UInt16, modifierFlags: UInt) -> Bool? {
        guard let modifier = modifiers[keyCode] else { return nil }
        if modifierFlags & modifier.bothSides != 0 { return modifierFlags & modifier.sideBit != 0 }
        return modifierFlags & modifier.flag != 0
    }
}
