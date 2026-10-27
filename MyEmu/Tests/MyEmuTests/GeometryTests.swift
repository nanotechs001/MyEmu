import CoreGraphics
import Foundation
import Testing
@testable import MyEmu

@Test func parsesIniAndIgnoresJunk() {
    let values = parseIni("hw.lcd.width=1080\nhw.lcd.height = 2400\nnot a pair\ncmdline=\"a=b\"\n")
    #expect(values["hw.lcd.width"] == "1080")
    #expect(values["hw.lcd.height"] == "2400")
    #expect(values["cmdline"] == "\"a=b\"") // only the first '=' splits
    #expect(values.count == 3)
}

@Test func deviceSizeRequiresLcdKeys() throws {
    #expect(try DeviceSize(avdConfig: ["hw.lcd.width": "1080", "hw.lcd.height": "2400"]) == DeviceSize(width: 1080, height: 2400))
    #expect(throws: DeviceSize.Missing.self) { try DeviceSize(avdConfig: ["hw.lcd.width": "1080"]) }
}

@Test func mapsViewPointsThroughLetterbox() {
    let device = DeviceSize(width: 1080, height: 2400)
    // A view twice as wide as needed: 450x1000 screen centered with 225 pt bars left and right.
    let view = CGSize(width: 900, height: 1000)
    #expect(device.devicePoint(for: CGPoint(x: 225, y: 0), in: view)! == (0, 0))
    #expect(device.devicePoint(for: CGPoint(x: 450, y: 500), in: view)! == (540, 1200))
    #expect(device.devicePoint(for: CGPoint(x: 100, y: 500), in: view) == nil) // in the bar
    #expect(device.devicePoint(for: CGPoint(x: 675, y: 500), in: view) == nil) // right edge is outside
}

@Test func aspectFitLetterboxesAndCenters() {
    #expect(aspectFitRect(content: CGSize(width: 1080, height: 2400), in: CGSize(width: 900, height: 1000))
            == CGRect(x: 225, y: 0, width: 450, height: 1000))
    #expect(aspectFitRect(content: CGSize(width: 100, height: 100), in: CGSize(width: 200, height: 50))
            == CGRect(x: 75, y: 0, width: 50, height: 50))
    #expect(aspectFitRect(content: .zero, in: CGSize(width: 10, height: 10)) == .zero)
}

@Test func sharedFrameBufferIsPageAlignedAndCleansUp() throws {
    var buffer: SharedFrameBuffer? = try SharedFrameBuffer(capacity: 1080 * 2400 * 4)
    let path = try #require(buffer?.path)
    let page = Int(getpagesize())
    #expect(buffer!.length >= 1080 * 2400 * 4)
    #expect(buffer!.length % page == 0)
    #expect(Int(bitPattern: buffer!.base) % page == 0)
    #expect(buffer!.handle == "file://" + path)
    buffer!.base.storeBytes(of: 0xAB, as: UInt8.self) // writable
    buffer = nil
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func releasingAnOldFrameBufferKeepsTheNewOnesFile() throws {
    // An in-app restart creates the new buffer before the old one is released.
    var old: SharedFrameBuffer? = try SharedFrameBuffer(capacity: 4096)
    let new = try SharedFrameBuffer(capacity: 4096)
    let oldPath = try #require(old?.path)
    #expect(oldPath != new.path)
    old = nil
    #expect(!FileManager.default.fileExists(atPath: oldPath))
    #expect(FileManager.default.fileExists(atPath: new.path)) // the engine opens this by name
}

@Test func resizingKeepsTheAndroidAreaAtTheScreenShape() {
    let chrome = CGSize(width: 53, height: 28) // sidebar + title bar
    let current = CGSize(width: 53 + 450, height: 28 + 1000) // 1080×2400 phone → 0.45
    func lock(_ proposed: CGSize, start: CGSize = current, aspect: CGFloat = 0.45) -> CGSize {
        aspectLockedSize(proposed: proposed, current: current, start: start, chrome: chrome,
                         aspect: aspect, minScreenHeight: 300)
    }
    // Right edge wider: height follows, no bars.
    #expect(lock(CGSize(width: 53 + 540, height: 1028)) == CGSize(width: 53 + 540, height: 28 + 1200))
    // Bottom edge shorter: width follows.
    #expect(lock(CGSize(width: 503, height: 28 + 800)) == CGSize(width: 53 + 360, height: 28 + 800))
    // Never smaller than the minimum.
    let tiny = lock(CGSize(width: 60, height: 100), aspect: 16.0 / 9.0)
    #expect(tiny.height == 28 + 300 && tiny.width == 53 + 533)
}

@Test func cornerDragsDecideFromTheDragStartSoTheyDontJitter() {
    let chrome = CGSize(width: 53, height: 28)
    let start = CGSize(width: 53 + 450, height: 28 + 1000)
    // Mid-drag, this step moved the mouse mostly vertically (+2 wide, −33 tall), but since the drag
    // began the width scaled more (×1.338 vs ×1.30): width keeps driving instead of flipping.
    let current = CGSize(width: 53 + 600, height: 28 + 1333)
    let proposed = CGSize(width: 53 + 602, height: 28 + 1300)
    let size = aspectLockedSize(proposed: proposed, current: current, start: start, chrome: chrome,
                                aspect: 0.45, minScreenHeight: 300)
    #expect(size == CGSize(width: 53 + 602, height: 28 + 1338))
}

@Test func staleFrameFilesFromDeadRunsAreRemoved() throws {
    let dir = FileManager.default.temporaryDirectory
    let deadPid = 999_999 // above macOS's pid range, so never running
    let old = dir.appending(path: "myemu-frames-\(deadPid).rgba")
    let new = dir.appending(path: "myemu-frames-\(deadPid)-ABC.rgba")
    let live = try SharedFrameBuffer(capacity: 4096) // ours: must survive
    for url in [old, new] { FileManager.default.createFile(atPath: url.path, contents: Data()) }
    SharedFrameBuffer.removeStaleFiles()
    #expect(!FileManager.default.fileExists(atPath: old.path))
    #expect(!FileManager.default.fileExists(atPath: new.path))
    #expect(FileManager.default.fileExists(atPath: live.path))
}
