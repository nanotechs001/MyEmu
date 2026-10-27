import Foundation
import Testing
@testable import MyEmu

@Test func directDisplayReadsWhatTheEngineWrites() throws {
    let display = try #require(DirectDisplay())
    #expect(display.contextId == 0) // engine not attached yet

    // Write the way libMyEmuDisplay does (MyEmuDisplay.h layout), through a separate mapping.
    let file = try #require(FileHandle(forUpdatingAtPath: display.path))
    var state: (UInt32, UInt32, UInt64, UInt64) = (1_506_570_091, 0, 170, 3)
    try file.write(contentsOf: Data(bytes: &state, count: 24))
    try file.close()

    #expect(display.contextId == 1_506_570_091)
    #expect(display.presents == 170)
    #expect(display.slowPresents == 3)
}

@Test func directDisplayEnvironmentLoadsLibraryWithScreenSize() throws {
    let display = try #require(DirectDisplay())
    let env = display.environment(library: URL(fileURLWithPath: "/x/libMyEmuDisplay.dylib"),
                                  size: DeviceSize(width: 1280, height: 860))
    #expect(env == ["DYLD_INSERT_LIBRARIES": "/x/libMyEmuDisplay.dylib",
                    "MYEMU_DISPLAY_STATE": display.path, "MYEMU_DISPLAY_SIZE": "1280x860"])
}
