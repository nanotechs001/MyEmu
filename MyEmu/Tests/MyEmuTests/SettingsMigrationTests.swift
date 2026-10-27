import Foundation
import Testing
@testable import MyEmu

@Test func copiesTerminalBuildSettingsIntoTheAppOnceAndNeverOverwrites() {
    let defaults = UserDefaults.standard
    let bundleID = "com.myemu.tests.\(UUID().uuidString)"
    let legacyBefore = defaults.persistentDomain(forName: SettingsMigration.legacyDomain)
    defer {
        defaults.removePersistentDomain(forName: bundleID)
        if let legacyBefore { defaults.setPersistentDomain(legacyBefore, forName: SettingsMigration.legacyDomain) }
        else { defaults.removePersistentDomain(forName: SettingsMigration.legacyDomain) }
    }
    defaults.setPersistentDomain(["fpsCap": 120, "macKeyboardOnly": true], forName: SettingsMigration.legacyDomain)

    SettingsMigration.copyLegacySettings(into: defaults, bundleID: bundleID)
    #expect(defaults.persistentDomain(forName: bundleID)?["fpsCap"] as? Int == 120)

    // Once the app has its own settings, a later run leaves them alone.
    defaults.setPersistentDomain(["fpsCap": 60], forName: bundleID)
    SettingsMigration.copyLegacySettings(into: defaults, bundleID: bundleID)
    #expect(defaults.persistentDomain(forName: bundleID)?["fpsCap"] as? Int == 60)

    // Run from Terminal (no bundle ID, or the legacy name itself): nothing to do.
    SettingsMigration.copyLegacySettings(into: defaults, bundleID: nil)
    SettingsMigration.copyLegacySettings(into: defaults, bundleID: SettingsMigration.legacyDomain)
}
