import Foundation

/// How picked or dropped files become adb installs.
enum ApkInstall {
    /// Each APK is its own app, except split APKs ("split_*.apk", as one app's pieces) which install
    /// together with their base. Anything that isn't an .apk is ignored.
    static func batches(_ files: [URL]) -> [[URL]] {
        let apks = files.filter { $0.pathExtension.lowercased() == "apk" }
        let hasSplits = apks.contains { $0.lastPathComponent.lowercased().hasPrefix("split_") }
        return hasSplits ? [apks] : apks.map { [$0] }
    }

    /// `-r` reinstalls over an existing copy, keeping its data (an update).
    static func adbArguments(_ batch: [URL]) -> [String] {
        (batch.count == 1 ? ["install", "-r"] : ["install-multiple", "-r"]) + batch.map(\.path)
    }
}
