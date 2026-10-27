import Foundation

/// A running instance of Google's emulator engine (QEMU + HVF + gfxstream), headless with gRPC.
struct EngineInstance: Sendable {
    let port: Int
    let token: String
    /// adb serial, e.g. "emulator-5554".
    let serial: String
    let deviceSize: DeviceSize
    let process: Process
}

enum EngineError: LocalizedError {
    case notInstalled(String)
    case exited(Int32)
    case noToken
    case adbFailed(Int32, output: String = "")

    var errorDescription: String? {
        switch self {
        case .notInstalled(let path): "Emulator engine not found at \(path). Install it with sdkmanager \"emulator\"."
        case .exited(let code): "Emulator engine exited during startup (code \(code))."
        case .noToken: "Emulator engine started but never published its gRPC token."
        case .adbFailed(let code, let output):
            // adb's last line says why, e.g. "Failure [INSTALL_FAILED_NO_MATCHING_ABIS: …]".
            output.split(whereSeparator: \.isNewline).last.map(String.init) ?? "adb exited with code \(code)."
        }
    }
}

enum Engine {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let sdk = home.appending(path: "Library/Android/sdk")
    /// Where the engine writes pid_<pid>.ini discovery files (port, token, ...).
    static let discoveryDir = home.appending(path: "Library/Caches/TemporaryItems/avd/running")

    /// The engine's command line. Guest ANGLE turns games' OpenGL ES into Vulkan inside Android, which
    /// the engine runs on Metal; the default path translates through macOS's old OpenGL instead.
    /// Measured on Conquer Online at 180 fps: ~40% less engine CPU and ~20% less GPU with ANGLE.
    static func arguments(avd: String, port: Int, refreshRate: Int, writableSystem: Bool, guestAngle: Bool,
                          phoneNumber: String = "") -> [String] {
        ["-avd", avd, "-no-window", "-gpu", "host",
         "-feature", guestAngle ? "GuestAngle" : "-GuestAngle",
         "-grpc", String(port), "-grpc-use-token",
         "-vsync-rate", String(refreshRate),
         "-no-boot-anim", "-no-snapshot-save"] + (writableSystem ? ["-writable-system"] : [])
            + (phoneNumber.isEmpty ? [] : ["-phone-number", phoneNumber])
    }

    /// AVD settings MyEmu always runs with:
    /// - no named device profile: "pixel_7" makes the engine re-enable that phone's fake camera hole
    ///   after boot, and MyEmu sets its own screen size anyway;
    /// - the ASG graphics transport: Android hands graphics commands over through a shared-memory ring
    ///   instead of a pipe that stops the virtual CPU for every batch. Conquer Online's busiest map:
    ///   53–54 fps → 66–80 fps.
    static let enforcedConfig = ["hw.device.name": "", "hw.gltransport": "asg"]

    /// The enforced settings an AVD's config doesn't have yet.
    static func enforcedConfigChanges(_ config: [String: String]) -> [String: String] {
        enforcedConfig.filter { config[$0.key] != $0.value }
    }

    static func start(avd: String, port: Int, refreshRate: Int, writableSystem: Bool,
                      guestAngle: Bool, display: DirectDisplay?, phoneLine: PhoneLine = PhoneLine()) async throws -> EngineInstance {
        let exe = sdk.appending(path: "emulator/emulator")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            throw EngineError.notInstalled(exe.path)
        }
        var config = try String(contentsOf: configURL(avd: avd), encoding: .utf8)
        let changes = enforcedConfigChanges(parseIni(config))
        if !changes.isEmpty {
            config = updatingIni(config, with: changes)
            try config.write(to: configURL(avd: avd), atomically: true, encoding: .utf8)
        }
        let deviceSize = try DeviceSize(avdConfig: parseIni(config))

        let launchedAt = Date()
        let process = Process()
        process.executableURL = exe
        // -no-window: fully headless, still on the host GPU. (-qt-hide-window builds Google's hidden Qt
        // window, whose setup can deadlock the VM's main loop, which froze Android after a restart.)
        process.arguments = arguments(avd: avd, port: port, refreshRate: refreshRate,
                                      writableSystem: writableSystem, guestAngle: guestAngle,
                                      phoneNumber: phoneLine.phoneNumber)
        process.standardInput = FileHandle.nullDevice // the engine must not read your Terminal
        if let library = DirectDisplay.library {
            var extra = display?.environment(library: library, size: deviceSize) ?? [:]
            if !phoneLine.imei.isEmpty { // the library swaps it into the engine's modem
                extra["DYLD_INSERT_LIBRARIES"] = library.path
                extra["MYEMU_IMEI"] = phoneLine.imei
            }
            if !extra.isEmpty { process.environment = ProcessInfo.processInfo.environment.merging(extra) { $1 } }
        }
        try process.run()

        for _ in 0..<120 { // up to 60 s
            if let values = readDiscovery(port: port, newerThan: launchedAt), let token = values["grpc.token"] {
                let serial = "emulator-\(values["port.serial"] ?? "5554")"
                return EngineInstance(port: port, token: token, serial: serial, deviceSize: deviceSize, process: process)
            }
            guard process.isRunning else { throw EngineError.exited(process.terminationStatus) }
            try await Task.sleep(for: .milliseconds(500))
        }
        process.terminate()
        throw EngineError.noToken
    }

    /// Finds the discovery file for our port; ignores stale files left by earlier crashed runs.
    static func readDiscovery(port: Int, newerThan date: Date) -> [String: String]? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: discoveryDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "ini" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, modified >= date,
                  let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let values = parseIni(text)
            if values["grpc.port"] == String(port), values["grpc.token"]?.isEmpty == false {
                return values
            }
        }
        return nil
    }

    /// Lets Android render at `rate`. Android's built-in default caps rendering at 60 Hz; a user
    /// minimum above it overrides that cap.
    static func setAndroidRefreshRate(_ rate: Int, serial: String) async throws {
        try await adbShellAfterBoot(serial: serial,
            "settings put system peak_refresh_rate \(rate).0; settings put system min_refresh_rate \(rate).0")
    }

    /// The Pixel 7 device profile draws a fake camera hole and rounded corners; a game screen wants neither.
    static func hideCameraCutout(serial: String) async throws {
        try await adbShellAfterBoot(serial: serial,
            "cmd overlay disable com.android.internal.emulation.pixel_7; cmd overlay disable com.android.systemui.emulation.pixel_7")
    }

    private static let adbAttempts = 5

    /// Runs `command` in Android once it has finished booting (settings live in Android). Retries,
    /// because right after a first boot adb can briefly be unauthorized.
    static func adbShellAfterBoot(serial: String, _ command: String) async throws {
        for attempt in 1...adbAttempts {
            do {
                return try await adbShellOnce(serial: serial, command)
            } catch where attempt < adbAttempts {
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    private static func adbShellOnce(serial: String, _ command: String) async throws {
        let script = "while [ \"$(getprop sys.boot_completed)\" != 1 ]; do sleep 1; done; \(command)"
        _ = try await adb(serial: serial, ["wait-for-device", "shell", script])
    }

    /// Runs adb on the host and returns what it printed; throws if it fails.
    static func adb(serial: String, _ arguments: [String]) async throws -> String {
        let adb = sdk.appending(path: "platform-tools/adb")
        guard FileManager.default.isExecutableFile(atPath: adb.path) else { throw EngineError.notInstalled(adb.path) }
        let process = Process()
        process.executableURL = adb
        process.arguments = ["-s", serial] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output // remount reports through stderr
        process.standardInput = FileHandle.nullDevice // never read MyEmu's stdin (or your Terminal)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            // Off the cooperative pool: `wait-for-device` can block for as long as Android takes to boot.
            DispatchQueue.global().async {
                do {
                    try process.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let text = String(decoding: data, as: UTF8.self)
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: text)
                    } else {
                        continuation.resume(throwing: EngineError.adbFailed(process.terminationStatus, output: text))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func configURL(avd: String) -> URL {
        home.appending(path: ".android/avd/\(avd).avd/config.ini")
    }

    static func readSettings(avd: String) throws -> AvdSettings {
        try AvdSettings(config: parseIni(String(contentsOf: configURL(avd: avd), encoding: .utf8)))
    }

    /// Rewrites only the keys these settings own; everything else in config.ini stays as it was.
    static func write(_ settings: AvdSettings, avd: String) throws {
        let url = configURL(avd: avd)
        let text = try String(contentsOf: url, encoding: .utf8)
        try updatingIni(text, with: settings.configValues).write(to: url, atomically: true, encoding: .utf8)
    }
}
