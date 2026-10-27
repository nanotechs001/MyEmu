import Foundation

/// Run from Terminal, MyEmu stored its settings under its process name ("MyEmu"); as MyEmu.app they
/// live under the bundle ID. Copy them over once so instances, profiles and options carry across.
enum SettingsMigration {
    static let legacyDomain = "MyEmu"

    static func copyLegacySettings(into defaults: UserDefaults = .standard,
                                   bundleID: String? = Bundle.main.bundleIdentifier) {
        guard let bundleID, bundleID != legacyDomain,
              defaults.persistentDomain(forName: bundleID)?.isEmpty ?? true, // never overwrite the app's own
              let legacy = defaults.persistentDomain(forName: legacyDomain), !legacy.isEmpty else { return }
        defaults.setPersistentDomain(legacy, forName: bundleID)
    }
}
