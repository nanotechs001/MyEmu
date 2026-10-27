import Testing
@testable import MyEmu

@Test func aIsSentAsLinuxKeyBecauseMacCodeZeroLooksUnset() {
    #expect(KeyTranslation.code(forMacKey: 0) == (.evdev, 30))
    #expect(KeyTranslation.code(forMacKey: 11) == (.mac, 11)) // B
    #expect(KeyTranslation.code(forMacKey: 49) == (.mac, 49)) // Space
}

@Test func tracksEachShiftSideSeparately() {
    let leftShift: UInt = 0x0002, rightShift: UInt = 0x0004
    #expect(KeyTranslation.modifierIsDown(keyCode: 56, modifierFlags: leftShift) == true)
    // Right Shift released while left is still held: right is up, even though "Shift" is still on.
    #expect(KeyTranslation.modifierIsDown(keyCode: 60, modifierFlags: leftShift) == false)
    #expect(KeyTranslation.modifierIsDown(keyCode: 60, modifierFlags: leftShift | rightShift) == true)
    #expect(KeyTranslation.modifierIsDown(keyCode: 58, modifierFlags: 0x0020) == true) // Option
}

@Test func plainShiftFlagWorksWithoutSideBits() {
    #expect(KeyTranslation.modifierIsDown(keyCode: 56, modifierFlags: 0x20000) == true) // Shift flag only
    #expect(KeyTranslation.modifierIsDown(keyCode: 56, modifierFlags: 0) == false)
    #expect(KeyTranslation.modifierIsDown(keyCode: 58, modifierFlags: 0x80000) == true) // Option flag only
}

@Test func commandAndCapsLockAreNotHeldModifiers() {
    #expect(KeyTranslation.modifierIsDown(keyCode: 55, modifierFlags: 0x0008) == nil) // ⌘ stays with macOS
    #expect(KeyTranslation.modifierIsDown(keyCode: KeyTranslation.capsLock, modifierFlags: 0) == nil) // a toggle
}
