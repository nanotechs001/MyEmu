import Foundation
import os

private let log = Logger(subsystem: "MyEmu", category: "display")

/// How Android's frames reach MyEmu's window.
enum DisplayPath: Sendable {
    /// gfxstream presents into the window's hosted layer (MuMu's way): no copy, no extra wait.
    case direct
    /// Fallback: every frame is read back from the GPU and copied through shared memory.
    case stream
}

/// MuMu-style display: libMyEmuDisplay, loaded into the engine, has gfxstream present Android's
/// frames straight into a Metal layer and shares that layer with MyEmu (ScreenView hosts it).
/// This is MyEmu's end of their shared state file; layout in Sources/MyEmuDisplay/include/MyEmuDisplay.h.
final class DirectDisplay: @unchecked Sendable { // the mapping never changes; only the engine writes the fields
    static let libraryName = "libMyEmuDisplay.dylib"
    private static let stateSize = 4096

    let path: String
    private let base: UnsafeMutableRawPointer

    /// The library inside the app (Contents/Frameworks) or next to a `swift build` binary.
    static var library: URL? {
        [Bundle.main.privateFrameworksURL, Bundle.main.executableURL?.deletingLastPathComponent()]
            .compactMap { $0?.appending(path: libraryName) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// nil when the state file can't be made; MyEmu then streams frames.
    init?() {
        path = FileManager.default.temporaryDirectory
            .appending(path: "myemu-display-\(getpid())-\(UUID().uuidString).state").path
        let fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard ftruncate(fd, off_t(Self.stateSize)) == 0,
              let mapped = mmap(nil, Self.stateSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
              mapped != MAP_FAILED else {
            unlink(path)
            return nil
        }
        base = mapped
    }

    deinit {
        munmap(base, Self.stateSize)
        unlink(path)
    }

    /// What the engine needs to load the library and find this state.
    func environment(library: URL, size: DeviceSize) -> [String: String] {
        ["DYLD_INSERT_LIBRARIES": library.path, "MYEMU_DISPLAY_STATE": path,
         "MYEMU_DISPLAY_SIZE": "\(size.width)x\(size.height)"]
    }

    /// The Core Animation context showing Android's screen; 0 until the engine's renderer is up.
    var contextId: UInt32 { base.load(fromByteOffset: 0, as: UInt32.self) }
    var presents: UInt64 { base.load(fromByteOffset: 8, as: UInt64.self) }
    /// Presents that came ≥ 40 ms after the previous one.
    var slowPresents: UInt64 { base.load(fromByteOffset: 16, as: UInt64.self) }

    func waitForContext(timeout: Duration) async -> UInt32? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if contextId != 0 { return contextId }
            try? await Task.sleep(for: .milliseconds(100))
        }
        log.error("The engine never shared its screen; falling back to the screenshot stream")
        return nil
    }
}
