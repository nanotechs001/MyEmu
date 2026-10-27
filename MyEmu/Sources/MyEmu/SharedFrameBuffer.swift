import Foundation

/// Page-aligned shared memory: the engine writes frames into it (MMAP transport) and
/// Metal samples it in place, so pixels are never copied on the CPU.
final class SharedFrameBuffer: @unchecked Sendable { // Swift never mutates the pointer; the bytes belong to the engine and GPU
    let path: String
    let base: UnsafeMutableRawPointer
    let length: Int
    private let fd: Int32

    var handle: String { "file://" + path }

    init(capacity: Int) throws {
        let page = Int(getpagesize())
        length = (capacity + page - 1) / page * page // Metal's bytesNoCopy needs whole pages
        // Unique per buffer: on restart the old buffer is released after the new one exists, and its
        // deinit must not unlink the file the engine is about to open.
        path = FileManager.default.temporaryDirectory
            .appending(path: "myemu-frames-\(getpid())-\(UUID().uuidString).rgba").path
        fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw ClientError.sharedMemory("open") }
        guard ftruncate(fd, off_t(length)) == 0,
              let mapped = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
              mapped != MAP_FAILED else {
            close(fd)
            unlink(path)
            throw ClientError.sharedMemory("ftruncate/mmap")
        }
        base = mapped
    }

    /// Frame files left behind by MyEmu runs that crashed or were force-quit.
    static func removeStaleFiles() {
        let directory = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix("myemu-frames-") && name.hasSuffix(".rgba") {
            // "myemu-frames-<pid>-<uuid>.rgba", or "myemu-frames-<pid>.rgba" from older builds.
            let pid = pid_t(name.dropFirst("myemu-frames-".count).prefix { $0.isNumber })
            guard let pid, pid != getpid(), kill(pid, 0) != 0 else { continue } // owner still running
            try? FileManager.default.removeItem(at: directory.appending(path: name)) // best effort cleanup
        }
    }

    deinit {
        munmap(base, length)
        close(fd)
        unlink(path)
    }
}
