import CryptoKit
import Foundation

extension Engine {
    private static let bootWait = "while [ \"$(getprop sys.boot_completed)\" != 1 ]; do sleep 1; done"
    /// Android takes a moment to go down after `adb reboot`; checking sooner sees the old boot.
    private static let rebootSettle: Duration = .seconds(6)
    private static let rootAttempts = 20

    static var avdRoot: URL { home.appending(path: ".android/avd") }

    /// Copies a stopped AVD, Android data included, under a new name. An APFS clone: instant, and
    /// it shares disk space with the original until either changes. A source that was never
    /// created (that profile unused) is skipped. Returns whether it copied. `root` is for tests.
    static func cloneAvd(_ source: String, to target: String, root: URL = avdRoot) throws -> Bool {
        let fm = FileManager.default
        let sourceDir = root.appending(path: "\(source).avd"), targetDir = root.appending(path: "\(target).avd")
        guard fm.fileExists(atPath: sourceDir.path) else { return false }
        guard !fm.fileExists(atPath: targetDir.path) else { throw CocoaError(.fileWriteFileExists) }
        try fm.copyItem(at: sourceDir, to: targetDir)
        // Lock files belong to the original's runs.
        for name in try fm.contentsOfDirectory(atPath: targetDir.path) where name.hasSuffix(".lock") {
            try fm.removeItem(at: targetDir.appending(path: name))
        }
        let ini = "avd.ini.encoding=UTF-8\npath=\(targetDir.path)\npath.rel=avd/\(target).avd\ntarget=android-35\n"
        try ini.write(to: root.appending(path: "\(target).ini"), atomically: true, encoding: .utf8)
        return true
    }

    /// Creates `avd` the first time, as a copy of `templateAvd` (same screen, CPU, memory) on the
    /// profile's system image. Its Android data starts fresh on first boot.
    static func ensureAvd(_ avd: String, profile: DeviceProfile, templateAvd: String) throws {
        let iniURL = avdRoot.appending(path: "\(avd).ini")
        guard !FileManager.default.fileExists(atPath: iniURL.path) else { return }
        let avdDir = avdRoot.appending(path: "\(avd).avd")
        try FileManager.default.createDirectory(at: avdDir, withIntermediateDirectories: true)
        let templateConfig = try String(contentsOf: configURL(avd: templateAvd), encoding: .utf8)
        // New instances start in landscape, with CPU and memory suggested for this Mac.
        let starting = (try? AvdSettings(config: parseIni(templateConfig)))?.forNewInstance(on: .current)
        try updatingIni(templateConfig, with: profile.imageConfig.merging(starting?.configValues ?? [:]) { $1 })
            .write(to: configURL(avd: avd), atomically: true, encoding: .utf8)
        let ini = "avd.ini.encoding=UTF-8\npath=\(avdDir.path)\npath.rel=avd/\(avd).avd\ntarget=android-35\n"
        try ini.write(to: iniURL, atomically: true, encoding: .utf8)
    }

    /// Deletes an AVD and all its Android data. Missing AVDs are fine.
    static func deleteAvd(_ avd: String) throws {
        for url in [avdRoot.appending(path: "\(avd).avd"), avdRoot.appending(path: "\(avd).ini")]
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Makes Android report `identity`. Needs the custom-model profile (root + writable system).
    /// Returns true when it changed something; Android then reboots once to load it.
    static func applyIdentity(_ identity: DeviceIdentity, serial: String) async throws -> Bool {
        let current = try await adb(serial: serial, ["wait-for-device", "shell",
            "\(bootWait); getprop ro.product.brand; getprop ro.product.manufacturer; getprop ro.product.model"])
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard current != [identity.brand, identity.manufacturer, identity.model] else { return false }

        try await remountSystem(serial: serial)
        _ = try await adb(serial: serial, ["shell", identityScript(for: identity)])
        _ = try await adb(serial: serial, ["reboot"])
        return true
    }

    private static let radioLibrary = "/vendor/lib64/libril-modem-lib.so"

    /// Writes `imei` (validated, or empty for stock) into Android's radio library, which answers
    /// Settings' IMEI request itself (see `GuestIMEI`). Custom-model profile only; the original is
    /// kept once as `.myemu-orig`. Returns true when it changed something (the radio restarts).
    static func applyGuestIMEI(_ imei: String, serial: String) async throws -> Bool {
        let original = radioLibrary + ".myemu-orig"
        // As root: the shell user can't look into /vendor/lib64.
        let hasBackup = try await adb(serial: serial, ["shell", "su 0 test -f \(original) && echo yes || true"]).contains("yes")
        if imei.isEmpty && !hasBackup { return false } // never touched
        try await remountSystem(serial: serial)
        _ = try await adb(serial: serial, ["shell", "test -f \(original) || cp -p \(radioLibrary) \(original)"])

        let work = FileManager.default.temporaryDirectory.appending(path: "myemu-ril-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let stockFile = work.appending(path: "stock.so"), currentFile = work.appending(path: "current.so")
        _ = try await adb(serial: serial, ["pull", original, stockFile.path])
        _ = try await adb(serial: serial, ["pull", radioLibrary, currentFile.path])
        let stock = try Data(contentsOf: stockFile)
        guard let wanted = imei.isEmpty ? stock : GuestIMEI.patched(stock, imei: imei) else {
            throw EngineError.adbFailed(-1, output: "This Android's radio library is laid out differently; IMEI unchanged.")
        }
        guard wanted != (try Data(contentsOf: currentFile)) else { return false }
        let staged = work.appending(path: "staged.so")
        try wanted.write(to: staged)
        let temp = "/data/local/tmp/myemu-ril.so"
        _ = try await adb(serial: serial, ["push", staged.path, temp])
        // cat keeps the library's file (and SELinux label); then reload the radio and the phone app.
        _ = try await adb(serial: serial, ["shell",
            "cat \(temp) > \(radioLibrary) && rm \(temp) && setprop ctl.restart vendor.ril-daemon && sleep 2 && kill $(pidof com.android.phone)"])
        return true
    }

    /// `package` must pass `AndroidWatch.isValidPackage` (it goes into a shell command).
    static func setGameMode(fps: Int, renderScale: Double, package: String, serial: String) async throws {
        _ = try await adb(serial: serial, ["shell", AndroidCommands.gameMode(fps: fps, renderScale: renderScale, package: package)])
    }

    /// The game-speed library bundled in the app (absent when run as `swift run`, not an app bundle).
    static var speedLibraryFile: URL? { Bundle.main.url(forResource: "libmyemuspeed", withExtension: "so") }

    /// Installs the game-speed library into the guest's system lib dir, where an app may load it under
    /// enforcing SELinux (unlike /data/local/tmp). Custom-model profile only (writable system). Pushes
    /// only when the file differs. Returns false when the library isn't bundled.
    static func installSpeedLibrary(serial: String) async throws -> Bool {
        guard let lib = speedLibraryFile else { return false }
        let want = SHA256.hash(data: try Data(contentsOf: lib)).map { String(format: "%02x", $0) }.joined()
        if try await adb(serial: serial, ["shell", "sha256sum \(AndroidCommands.speedLibrary) 2>/dev/null"]).contains(want) {
            return true
        }
        try await remountSystem(serial: serial)
        _ = try await adb(serial: serial, ["push", lib.path, AndroidCommands.speedLibrary])
        _ = try await adb(serial: serial, ["shell",
            "chmod 644 \(AndroidCommands.speedLibrary) && chcon u:object_r:system_lib_file:s0 \(AndroidCommands.speedLibrary)"])
        return true
    }

    /// Preloads the speed library into `package` for its next launch and sets the live speed.
    /// `package` must pass `AndroidWatch.isValidPackage` (it goes into a shell command).
    static func setGameSpeed(_ speed: Double, package: String, serial: String) async throws {
        _ = try await adb(serial: serial, ["shell", AndroidCommands.gameSpeed(speed, package: package)])
    }

    /// The phone name shown in Android's Settings. `name` must be a validated `DeviceIdentity.marketName`.
    static func setDeviceName(_ name: String, serial: String) async throws {
        _ = try await adb(serial: serial, ["wait-for-device", "shell",
            "\(bootWait); settings put global device_name \"\(name)\""])
    }

    /// An engine still running this AVD (MyEmu reopened quickly, or left over from a crash) makes
    /// the new one refuse to start. Give it time to close, then stop it.
    static func waitForPreviousEngine(avd: String) async {
        for _ in 0..<previousEngineGraceSeconds {
            guard !previousEngines(avd: avd).isEmpty else { return }
            try? await Task.sleep(for: .seconds(1))
        }
        previousEngines(avd: avd).forEach { kill($0, SIGTERM) }
        for _ in 0..<previousEngineGraceSeconds {
            guard !previousEngines(avd: avd).isEmpty else { return }
            try? await Task.sleep(for: .seconds(1))
        }
        previousEngines(avd: avd).forEach { kill($0, SIGKILL) }
    }

    private static let previousEngineGraceSeconds = 15

    /// Matches the engine's command line for exactly this AVD. The binary is
    /// `qemu-system-aarch64-headless` with -no-window, plain `qemu-system-aarch64` otherwise.
    static func previousEnginePattern(avd: String) -> String {
        "qemu-system-aarch64(-headless)? .*-avd \(avd)( |$)"
    }

    /// PIDs of engines running exactly this AVD.
    private static func previousEngines(avd: String) -> [pid_t] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", previousEnginePattern(avd: avd)]
        let output = Pipe()
        pgrep.standardOutput = output
        pgrep.standardInput = FileHandle.nullDevice
        do { try pgrep.run() } catch { return [] }
        pgrep.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
    }

    /// Google's Play Store app, copied once from the Play Store system image. Both images are the same
    /// Android 15 build, and the custom one already has Play Store's permission files; only the app is missing.
    /// Google's built-in apps as the Play Store image has them. They only work as a set: Google sign-in in
    /// apps rejects Play services unless Play Store has the same original signing key ("…signature doesn't
    /// match that of Google Play services", error 9), and Play services shares its Android user, so its key,
    /// with the Services Framework. The custom-model image's own pair is signed with a different Google key.
    static let playGoogleApps = [
        "/product/priv-app/Phonesky/Phonesky.apk",
        "/product/priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk",
        "/system_ext/priv-app/GoogleServicesFramework/GoogleServicesFramework.apk"]
    static var playAppsFolder: URL { home.appending(path: "Library/Application Support/MyEmu/playstore") }
    static func localCopy(of path: String) -> URL { playAppsFolder.appending(path: (path as NSString).lastPathComponent) }
    /// adb console port for the one-off copy, clear of the instances' 5554, 5556, …
    private static let extractionPort = 5680
    private static let extractionBootSeconds = 180

    /// Makes a custom-model Android's Google apps the Play Store image's. Returns true when it changed
    /// them; Android has then rebooted once to load them.
    static func ensurePlayStore(serial: String, sourceAvd: String) async throws -> Bool {
        if !playGoogleApps.allSatisfy({ FileManager.default.fileExists(atPath: localCopy(of: $0).path) }) {
            try await copyPlayApps(fromAvd: sourceAvd)
        }
        let hashes = try playGoogleApps.map { SHA256.hash(data: try Data(contentsOf: localCopy(of: $0)))
            .map { String(format: "%02x", $0) }.joined() }
        let state = try await adb(serial: serial, ["wait-for-device", "shell",
            "\(bootWait); \(playAppsReadyCheck(hashes: hashes)) || true"])
        guard !state.contains("ready") else { return false }
        try await remountSystem(serial: serial)
        // An update of the image's own Play services in /data is signed with the other key; drop it.
        _ = try await adb(serial: serial, ["shell", "cmd package uninstall-system-updates com.google.android.gms || true"])
        for path in playGoogleApps {
            let dir = (path as NSString).deletingLastPathComponent
            // The precompiled code next to the APK belongs to the old one; Android recompiles.
            _ = try await adb(serial: serial, ["shell", "mkdir -p \(dir) && chmod 755 \(dir) && rm -rf \(dir)/oat"])
            _ = try await adb(serial: serial, ["push", localCopy(of: path).path, path])
            _ = try await adb(serial: serial, ["shell", "chmod 644 \(path) && chcon -R u:object_r:system_file:s0 \(dir)"])
        }
        _ = try await adb(serial: serial, ["shell", "rm -rf \(licenseCheckerDir)"])
        try await reboot(serial: serial)
        return true
    }

    /// Google's placeholder app under Play Store's package name (the Play Store image has none). With
    /// both built in, Android picks either as the base of Play Store's self-updates; on the placeholder
    /// the update lacks its privileged permissions and crashes ("Google Play Store keeps stopping").
    private static let licenseCheckerDir = "/product/app/LicenseChecker"
    /// Prints "ready" when each Google app is the Play Store image's (same SHA-256 as `hashes`, in
    /// `playGoogleApps` order) and the placeholder is gone.
    static func playAppsReadyCheck(hashes: [String]) -> String {
        zip(playGoogleApps, hashes).map { "sha256sum \($0) 2>/dev/null | grep -q ^\($1)" }
            .joined(separator: " && ") + " && test ! -e \(licenseCheckerDir) && echo ready"
    }

    /// Boots the Play Store AVD read-only (nothing it does is kept) just long enough to copy its Google apps out.
    private static func copyPlayApps(fromAvd avd: String) async throws {
        let process = Process()
        process.executableURL = sdk.appending(path: "emulator/emulator")
        process.arguments = ["-avd", avd, "-read-only", "-no-window", "-gpu", "host", "-no-snapshot",
                             "-no-boot-anim", "-port", String(extractionPort)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let serial = "emulator-\(extractionPort)"
        defer {
            Task { _ = try? await adb(serial: serial, ["emu", "kill"]) }
            process.terminate()
        }
        var booted = false
        for _ in 0..<extractionBootSeconds where !booted {
            guard process.isRunning else { throw EngineError.exited(process.terminationStatus) }
            booted = (try? await adb(serial: serial, ["shell", "getprop sys.boot_completed"]))?.contains("1") == true
            if !booted { try await Task.sleep(for: .seconds(1)) }
        }
        guard booted else { throw EngineError.adbFailed(-1, output: "The Play Store image didn't finish starting.") }
        try FileManager.default.createDirectory(at: playAppsFolder, withIntermediateDirectories: true)
        for path in playGoogleApps {
            let copy = localCopy(of: path)
            let partial = copy.appendingPathExtension("partial") // never leave half a file as the real one
            try? FileManager.default.removeItem(at: partial)
            _ = try await adb(serial: serial, ["pull", path, partial.path])
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.moveItem(at: partial, to: copy)
        }
    }

    /// Root, and system partitions writable (custom-model profile only).
    private static func remountSystem(serial: String) async throws {
        try await becomeRoot(serial: serial)
        if try await adb(serial: serial, ["remount"]).contains("reboot") {
            // First time only: the writable overlay exists after one reboot.
            try await reboot(serial: serial)
            try await becomeRoot(serial: serial)
            _ = try await adb(serial: serial, ["remount"])
        }
    }

    private static func becomeRoot(serial: String) async throws {
        _ = try await adb(serial: serial, ["root"])
        for _ in 0..<rootAttempts { // adbd restarts as root; wait until it's back
            if (try? await adb(serial: serial, ["wait-for-device", "shell", "id -u"]))?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "0" { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw EngineError.adbFailed(-1)
    }

    private static func reboot(serial: String) async throws {
        _ = try await adb(serial: serial, ["reboot"])
        try await Task.sleep(for: rebootSettle)
        _ = try await adb(serial: serial, ["wait-for-device", "shell", bootWait])
    }
}
