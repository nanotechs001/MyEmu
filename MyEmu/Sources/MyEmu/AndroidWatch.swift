import Foundation

/// Follows the Android state game keys depend on: which app is in front, and whether a text
/// field has the keyboard up. Each watch is one long-running `adb shell` streaming lines.
enum AndroidWatch {
    /// Event-driven: Android logs one line per app switch. `-T 1` only skips old lines: the newest
    /// line in the buffer is almost always another tag, which `-s` then drops, so nothing replays.
    static let foregroundCommand = "logcat -b events -v raw -T 1 -s wm_set_resumed_activity"
    /// Android 15 logs each keyboard show/hide *request* (also when no on-screen keyboard is drawn
    /// because you type on the Mac). Requests aren't the state (games send hide requests Android
    /// refuses while their text box stays open), so each one only triggers a `typingProbe`. Requests
    /// sent before the stream attaches are missed, so app switches and stream starts trigger one too.
    static let keyboardEventsCommand = "logcat -v brief -T 1 -s ImeTracker:I"
    /// The input type of the editor connected to the keyboard: a text type whenever a text field has
    /// focus. Costly (~750 KB of text built inside Android, including a dump of the game's process),
    /// so it runs only after keyboard requests, never on a timer: polling it twice a second caused
    /// frame-time spikes.
    static let typingProbe =
        "dumpsys input_method 2>/dev/null | grep -m1 -A1 'mCurrentEditorInfo:' | grep -o 'inputType=0x[0-9a-f]*'"
    /// Android updates the editor a moment after the request; the second look catches slow apps.
    static let typingProbeDelays: [Duration] = [.milliseconds(200), .seconds(1)]

    /// "[0,com.example.game/.MainActivity,reason]" → "com.example.game".
    static func foregroundPackage(fromEvent line: String) -> String? {
        let fields = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] \r\n")).split(separator: ",")
        guard fields.count >= 2, let slash = fields[1].firstIndex(of: "/") else { return nil }
        let package = String(fields[1][..<slash])
        return isValidPackage(package) ? package : nil
    }

    /// "I/ImeTracker(…): <app>:<id>: onRequestShow …" or "… onRequestHide …".
    static func isKeyboardRequest(_ line: String) -> Bool {
        line.contains(": onRequestShow ") || line.contains(": onRequestHide ")
    }

    /// "inputType=0x100001" → true (a text field has focus); "inputType=0x0" → false.
    static func isTyping(from line: String) -> Bool? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("inputType=0x"), let type = UInt32(text.dropFirst("inputType=0x".count), radix: 16) else {
            return nil
        }
        return type & typeClassMask != 0 // the class bits are 0 (TYPE_NULL) when nothing takes text
    }

    /// Android's InputType.TYPE_MASK_CLASS.
    private static let typeClassMask: UInt32 = 0xF

    /// Android package names: letters, digits, "_" and "." only. Also keeps them safe as file names.
    static func isValidPackage(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 255 && !name.hasPrefix(".")
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }
    }

    private static let readChunkSize = 4096

    /// Removes and returns the complete lines at the front of `buffer`; a partial last line stays.
    static func takeLines(from buffer: inout Data) -> [String] {
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }

    /// Lines printed by `command` in Android, until the command ends or the task is cancelled.
    static func lines(serial: String, command: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = Engine.sdk.appending(path: "platform-tools/adb")
            process.arguments = ["-s", serial, "wait-for-device", "shell", command]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            // adb forwards its stdin to Android; two watchers sharing MyEmu's stdin stalled the second.
            process.standardInput = FileHandle.nullDevice
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() } // its output then ends, which ends the reader
            }
            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
                return
            }
            // A plain thread, not Swift's async pool: FileHandle.bytes parked a pool thread in read() for
            // the stream's whole life, which starved the rest of MyEmu's async work (typing checks, app
            // switches, watch restarts) until mapped keys stopped typing in Conquer.
            let descriptor = output.fileHandleForReading.fileDescriptor
            DispatchQueue.global(qos: .userInitiated).async {
                var pending = Data()
                var chunk = [UInt8](repeating: 0, count: readChunkSize)
                while true {
                    let count = read(descriptor, &chunk, chunk.count)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { break } // end of output (process ended) or a read error
                    pending.append(contentsOf: chunk[..<count])
                    takeLines(from: &pending).forEach { continuation.yield($0) }
                }
                continuation.finish()
            }
        }
    }
}
