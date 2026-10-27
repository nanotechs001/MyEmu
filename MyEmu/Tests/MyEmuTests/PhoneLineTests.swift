import Foundation
import Testing
@testable import MyEmu

@Test func imeiChecksumMatchesRealIMEIs() {
    #expect(PhoneLine.luhnValid("867400022047199")) // the engine's stock IMEI
    #expect(PhoneLine.luhnValid("490154203237518")) // GSMA's documented example
    #expect(!PhoneLine.luhnValid("490154203237519"))
}

@Test func randomIMEIsAreValid() {
    for _ in 0..<50 {
        let imei = PhoneLine.randomIMEI()
        #expect(imei.count == 15)
        #expect(PhoneLine(imei: imei).problem == nil)
    }
}

@Test func phoneLineRejectsBadInput() {
    #expect(PhoneLine().problem == nil) // both default
    #expect(PhoneLine(phoneNumber: "15550101234").problem == nil)
    #expect(PhoneLine(phoneNumber: "+15550101234").problem != nil) // the engine won't start with "+"
    #expect(PhoneLine(phoneNumber: "555-0101").problem != nil)
    #expect(PhoneLine(phoneNumber: "12").problem != nil)
    #expect(PhoneLine(imei: "86740002204719").problem != nil) // 14 digits
    #expect(PhoneLine(imei: "867400022047198").problem != nil) // bad checksum
}

/// A stand-in for the radio library: the eight IMEI instructions with other code between them.
private func fakeRadioLibrary() -> Data {
    var data = Data(repeating: 0, count: 64) // code before getImei
    for (index, slot) in GuestIMEI.slots.enumerated() {
        withUnsafeBytes(of: slot.instruction.littleEndian) { data.append(contentsOf: $0) }
        if index.isMultiple(of: 2) { data.append(contentsOf: [0x1f, 0x20, 0x03, 0xd5]) } // nop
    }
    return data
}

@Test func guestIMEIPatchRoundTripsTheStockValue() throws {
    let stock = fakeRadioLibrary()
    #expect(GuestIMEI.patched(stock, imei: "867400022047199") == stock) // the slots decode to the stock IMEI
    let patched = try #require(GuestIMEI.patched(stock, imei: "352099001761481"))
    #expect(patched.count == stock.count)
    #expect(patched != stock)
    // Patching the patched copy back to stock gives nil: its instructions no longer match the originals.
    #expect(GuestIMEI.patched(patched, imei: "867400022047199") == nil)
    #expect(GuestIMEI.patched(Data(repeating: 0, count: 64), imei: "352099001761481") == nil)
}

@Test func cutoutCommandsPickOneOverlayOrClearThemAll() {
    #expect(CutoutStyle.punchHole.command
        == "cmd overlay enable-exclusive --category com.android.internal.display.cutout.emulation.hole")
    let none = CutoutStyle.none.command
    #expect(none.contains("disable com.android.internal.display.cutout.emulation.tall"))
    #expect(none.contains("disable com.android.internal.display.cutout.emulation.emu01"))
    #expect(!none.contains("enable"))
}
