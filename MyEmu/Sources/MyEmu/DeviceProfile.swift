import Foundation

/// Google's Play Store images are locked (signed, no root), so the device model can only be changed
/// on the root-capable google_apis image. MyEmu keeps one AVD for each, with separate Android data.
enum DeviceProfile: String, CaseIterable, Identifiable, Sendable {
    case playStore, customModel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playStore: "Play Store"
        case .customModel: "Custom model"
        }
    }

    var avd: String {
        switch self {
        case .playStore: "myemu"
        case .customModel: "myemu-custom"
        }
    }

    /// config.ini lines that select this profile's system image.
    var imageConfig: [String: String] {
        switch self {
        case .playStore:
            ["image.sysdir.1": "system-images/android-35/google_apis_playstore/arm64-v8a/",
             "tag.id": "google_apis_playstore", "tag.ids": "google_apis_playstore",
             "tag.display": "Google Play", "tag.displaynames": "Google Play", "PlayStore.enabled": "yes"]
        case .customModel:
            ["image.sysdir.1": "system-images/android-35/google_apis/arm64-v8a/",
             "tag.id": "google_apis", "tag.ids": "google_apis",
             "tag.display": "Google APIs", "tag.displaynames": "Google APIs", "PlayStore.enabled": "no"]
        }
    }

    /// Lets root write the model into Android's (otherwise read-only) property files.
    var needsWritableSystem: Bool { self == .customModel }
}

/// What apps see as Build.BRAND / MANUFACTURER / MODEL, plus the name shown in Android's Settings.
struct DeviceIdentity: Codable, Equatable, Sendable {
    var brand: String
    var manufacturer: String
    var model: String
    var marketName: String

    /// What Google's emulator image reports out of the box.
    static let stock = DeviceIdentity(brand: "google", manufacturer: "Google", model: "sdk_gphone64_arm64",
                                      marketName: "sdk_gphone64_arm64")
    static let maxLength = 40

    /// Nil when safe to write into Android, otherwise a message for the user.
    var problem: String? {
        for (field, value) in [("Brand", brand), ("Manufacturer", manufacturer), ("Model", model), ("Name", marketName)] {
            if value.trimmingCharacters(in: .whitespaces).isEmpty { return "\(field) can't be empty." }
            if value.count > Self.maxLength { return "\(field) must be at most \(Self.maxLength) characters." }
            // These values go into Android's property files through a shell script: keep them plain.
            if !value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || " ._-()+".contains($0)) }) {
                return "\(field) may only use letters, digits, spaces and . _ - ( ) +"
            }
        }
        return nil
    }
}

struct DevicePreset: Identifiable, Equatable, Sendable {
    let identity: DeviceIdentity
    var id: String { identity.marketName }

    /// Popular gaming phones; some games pick higher graphics settings for these.
    static let all: [DevicePreset] = [
        .init("samsung", "samsung", "SM-S928B", "Galaxy S24 Ultra"),
        .init("samsung", "samsung", "SM-S911B", "Galaxy S23"),
        .init("samsung", "samsung", "SM-X916B", "Galaxy Tab S9 Ultra"),
        .init("Xiaomi", "Xiaomi", "24030PN60G", "Xiaomi 14 Ultra"),
        .init("OnePlus", "OnePlus", "CPH2581", "OnePlus 12"),
        .init("asus", "asus", "ASUS_AI2401_A", "ROG Phone 8 Pro"),
        .init("nubia", "nubia", "NX769J", "RedMagic 9 Pro"),
        .init("google", "Google", "Pixel 8 Pro", "Pixel 8 Pro"),
    ]

    private init(_ brand: String, _ manufacturer: String, _ model: String, _ marketName: String) {
        identity = DeviceIdentity(brand: brand, manufacturer: manufacturer, model: model, marketName: marketName)
    }
}

/// Android property files that each carry a `ro.product.<partition>.*` copy of the identity.
private let buildPropFiles = ["/system/build.prop", "/system_ext/etc/build.prop", "/vendor/build.prop",
                              "/product/etc/build.prop", "/odm/etc/build.prop", "/vendor/odm/etc/build.prop"]

/// Shell script (run as root on a remounted system) that writes `identity` into every property
/// file, starting from a one-time backup of the original so repeated changes don't pile up.
/// `identity` must have no `problem`. Android picks the new values up on its next boot.
/// (The Settings name is set separately once Android is up: settings written right before a
/// reboot can be lost.)
func identityScript(for identity: DeviceIdentity) -> String {
    let restoreOnly = identity == .stock
    let perFile = buildPropFiles.map { file in
        var steps = "if [ -f \(file) ]; then [ -f \(file).myemu-orig ] || cp -p \(file) \(file).myemu-orig; "
            + "cp -p \(file).myemu-orig \(file)"
        if !restoreOnly {
            steps += " && sed -i -E"
                + " -e \"s/^(ro\\.product\\.[a-z_]+\\.brand)=.*/\\1=\(identity.brand)/\""
                + " -e \"s/^(ro\\.product\\.[a-z_]+\\.manufacturer)=.*/\\1=\(identity.manufacturer)/\""
                + " -e \"s/^(ro\\.product\\.[a-z_]+\\.model)=.*/\\1=\(identity.model)/\" \(file)"
        }
        return steps + " || exit 1; fi"
    }
    return perFile.joined(separator: "; ")
}
