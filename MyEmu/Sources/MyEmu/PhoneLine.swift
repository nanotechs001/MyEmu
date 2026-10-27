import Foundation

/// The SIM's phone number and the modem's IMEI on the custom-model profile (MuMu's Device tab).
/// Empty means the engine's default. Both are set when the engine starts.
struct PhoneLine: Codable, Equatable, Sendable {
    var phoneNumber = ""
    var imei = ""

    static let imeiLength = 15

    /// Nil when usable, otherwise a message for the user.
    var problem: String? {
        // The engine refuses anything but digits ("+" included) and then won't start.
        if !phoneNumber.isEmpty, !(3...15).contains(phoneNumber.count) || !phoneNumber.allSatisfy(\.isASCIIDigit) {
            return "Phone number: 3–15 digits, no + or spaces (country code first, e.g. 15550101234)."
        }
        if !imei.isEmpty {
            guard imei.count == Self.imeiLength, imei.allSatisfy(\.isASCIIDigit) else { return "IMEI must be 15 digits." }
            guard Self.luhnValid(imei) else { return "That IMEI's last digit (checksum) is wrong." }
        }
        return nil
    }

    /// The Luhn checksum every real IMEI's 15th digit satisfies.
    static func luhnValid(_ digits: String) -> Bool {
        luhnCheckDigit(String(digits.dropLast())) == digits.last?.wholeNumberValue
    }

    static func luhnCheckDigit(_ payload: String) -> Int {
        let sum = payload.reversed().enumerated().reduce(0) { sum, item in
            let digit = item.element.wholeNumberValue ?? 0
            let value = item.offset.isMultiple(of: 2) ? digit * 2 : digit // doubles every second digit from the right
            return sum + (value > 9 ? value - 9 : value)
        }
        return (10 - sum % 10) % 10
    }

    /// A valid-looking IMEI: "35" (a common GSMA reporting body) + 12 random digits + checksum.
    static func randomIMEI() -> String {
        let payload = "35" + (0..<12).map { _ in String(Int.random(in: 0...9)) }.joined()
        return payload + String(luhnCheckDigit(payload))
    }
}

/// Android 15's radio library (Google's reference RIL, `RefRadioModem::getImei`) answers the IMEI
/// request with "867400022047199" built from instruction immediates, not from the modem. Each of
/// these MOVZ/MOVK instructions carries two IMEI characters (little-endian) in bits 5–20.
enum GuestIMEI {
    static let slots: [(instruction: UInt32, characters: Range<Int>)] = [
        (0x5286_c708, 0..<2), (0x72a6_86e8, 2..<4), (0x5286_0688, 3..<5), (0x72a6_0608, 5..<7),
        (0xd286_4648, 7..<9), (0xf2a6_8608, 9..<11), (0xf2c6_26e8, 11..<13), (0xf2e7_2728, 13..<15)]
    /// The instructions sit within this many bytes of the first one.
    private static let window = 0x100

    /// The stock library with `imei` written in; nil when its code isn't laid out as expected.
    static func patched(_ stock: Data, imei: String) -> Data? {
        let digits = Array(imei.utf8)
        guard digits.count == PhoneLine.imeiLength,
              let first = offsets(of: slots[0].instruction, in: stock).first else { return nil }
        var result = stock
        var searchFrom = first
        for slot in slots {
            guard let offset = offsets(of: slot.instruction, in: stock, from: searchFrom, limit: first + window).first
            else { return nil }
            let pair = slot.characters.map { UInt32(digits[$0]) }
            let word = slot.instruction & ~(0xFFFF << 5) | (pair[0] | pair[1] << 8) << 5
            withUnsafeBytes(of: word.littleEndian) { result.replaceSubrange(offset..<offset + 4, with: $0) }
            searchFrom = offset + 4
        }
        return result
    }

    private static func offsets(of instruction: UInt32, in data: Data, from start: Int = 0, limit: Int? = nil) -> [Int] {
        let needle = withUnsafeBytes(of: instruction.littleEndian) { Data($0) }
        let end = min(limit ?? data.count, data.count)
        return stride(from: start, to: end - 3, by: 4).filter { data.subdata(in: $0..<$0 + 4) == needle }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// Android's built-in display-cutout emulations (MuMu: Settings → Display → Screen cutout).
enum CutoutStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, punchHole, notch, corner, doubleNotch, waterfall

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .punchHole: "Center punch hole"
        case .notch: "Center notch"
        case .corner: "Corner notch"
        case .doubleNotch: "Top and bottom notch"
        case .waterfall: "Curved edges (waterfall)"
        }
    }

    private static let overlayPrefix = "com.android.internal.display.cutout.emulation."

    private var overlay: String? {
        switch self {
        case .none: nil
        case .punchHole: "hole"
        case .notch: "tall"
        case .corner: "corner"
        case .doubleNotch: "double"
        case .waterfall: "waterfall"
        }
    }

    /// Shell command that switches Android to this style (no restart; Android remembers it).
    var command: String {
        if let overlay {
            return "cmd overlay enable-exclusive --category \(Self.overlayPrefix)\(overlay)"
        }
        return ["hole", "tall", "corner", "double", "waterfall", "emu01"]
            .map { "cmd overlay disable \(Self.overlayPrefix)\($0)" }.joined(separator: "; ")
    }
}
