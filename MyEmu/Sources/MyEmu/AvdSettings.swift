import Foundation

/// The AVD hardware MyEmu lets you change. It lives in the AVD's config.ini, so changes need an
/// engine restart (Android reads it at boot).
struct AvdSettings: Equatable, Sendable {
    var width: Int
    var height: Int
    var density: Int
    var cpuCores: Int
    var ramMB: Int

    static let sizeRange = 320...4096
    static let densityRange = 120...640
    static let minRamMB = 1024

    struct Invalid: LocalizedError {
        let errorDescription: String?
    }

    init(width: Int, height: Int, density: Int, cpuCores: Int, ramMB: Int) {
        self.width = width
        self.height = height
        self.density = density
        self.cpuCores = cpuCores
        self.ramMB = ramMB
    }

    init(config: [String: String]) throws {
        guard let width = config["hw.lcd.width"].flatMap(Int.init),
              let height = config["hw.lcd.height"].flatMap(Int.init) else {
            throw Invalid(errorDescription: "The AVD config has no screen size.")
        }
        self.init(width: width, height: height,
                  density: config["hw.lcd.density"].flatMap(Int.init) ?? 420,
                  cpuCores: config["hw.cpu.ncore"].flatMap(Int.init) ?? 2,
                  ramMB: config["hw.ramSize"].flatMap(parseMegabytes) ?? 2048)
    }

    var isLandscape: Bool { width > height }

    /// The config.ini lines these settings own.
    var configValues: [String: String] {
        ["hw.lcd.width": String(width), "hw.lcd.height": String(height), "hw.lcd.density": String(density),
         "hw.cpu.ncore": String(cpuCores), "hw.ramSize": "\(ramMB)M",
         "hw.initialOrientation": isLandscape ? "landscape" : "portrait"]
    }

    /// Nil when usable on this Mac, otherwise a message for the user.
    func problem(on host: HostLimits) -> String? {
        if !Self.sizeRange.contains(width) || !Self.sizeRange.contains(height) {
            return "Width and height must be between \(Self.sizeRange.lowerBound) and \(Self.sizeRange.upperBound)."
        }
        // The Metal texture reads rows straight from the engine's frame memory: 16-byte aligned rows.
        if width % 4 != 0 { return "Width must be a multiple of 4." }
        if height % 2 != 0 { return "Height must be an even number." }
        if !Self.densityRange.contains(density) {
            return "DPI must be between \(Self.densityRange.lowerBound) and \(Self.densityRange.upperBound)."
        }
        if !(1...host.maxCpuCores).contains(cpuCores) { return "CPU cores must be between 1 and \(host.maxCpuCores)." }
        if !(Self.minRamMB...host.maxRamMB).contains(ramMB) {
            return "Memory must be between \(Self.minRamMB / 1024) and \(host.maxRamMB / 1024) GB."
        }
        return nil
    }

    func with(_ preset: ResolutionPreset) -> AvdSettings {
        var copy = self
        (copy.width, copy.height, copy.density) = (preset.width, preset.height, preset.density)
        return copy
    }

    func with(_ preset: PerformancePreset) -> AvdSettings {
        var copy = self
        (copy.cpuCores, copy.ramMB) = (preset.cpuCores, preset.ramMB)
        return copy
    }

    /// A new instance's starting point: landscape, sized for this Mac.
    func forNewInstance(on host: HostLimits) -> AvdSettings {
        (isLandscape ? self : rotated()).with(PerformancePreset.suggested(for: host))
    }

    /// Portrait ↔ landscape.
    func rotated() -> AvdSettings {
        var copy = self
        (copy.width, copy.height) = (height, width)
        return copy
    }
}

/// How much of this Mac Android may use: all cores but leave half the memory to macOS.
struct HostLimits: Sendable {
    let maxCpuCores: Int
    let maxRamMB: Int
    /// Apple silicon's fast and efficiency cores (0 when unknown).
    var performanceCores = 0
    var efficiencyCores = 0

    static let current = HostLimits(
        maxCpuCores: ProcessInfo.processInfo.activeProcessorCount,
        maxRamMB: Int(ProcessInfo.processInfo.physicalMemory / 1024 / 1024 / 2),
        performanceCores: sysctlInt("hw.perflevel0.physicalcpu"),
        efficiencyCores: sysctlInt("hw.perflevel1.physicalcpu"))

    private static func sysctlInt(_ name: String) -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : 0
    }
}

struct ResolutionPreset: Identifiable, Equatable, Sendable {
    let name: String
    let width: Int
    let height: Int
    let density: Int
    var id: String { name }

    /// MuMu-style choices: phone portrait sizes and landscape tablet sizes.
    static let all = [
        ResolutionPreset(name: "Phone 1080 × 2400", width: 1080, height: 2400, density: 420),
        ResolutionPreset(name: "Phone 1080 × 1920", width: 1080, height: 1920, density: 480),
        ResolutionPreset(name: "Phone 900 × 1600", width: 900, height: 1600, density: 320),
        ResolutionPreset(name: "Phone 720 × 1280", width: 720, height: 1280, density: 320),
        ResolutionPreset(name: "Tablet 2560 × 1440", width: 2560, height: 1440, density: 400),
        ResolutionPreset(name: "Tablet 1920 × 1080", width: 1920, height: 1080, density: 280),
        ResolutionPreset(name: "Tablet 1600 × 900", width: 1600, height: 900, density: 240),
        ResolutionPreset(name: "Tablet 1280 × 720", width: 1280, height: 720, density: 240),
    ]

    static func matching(_ settings: AvdSettings) -> ResolutionPreset? {
        list(landscape: settings.isLandscape)
            .first { $0.width == settings.width && $0.height == settings.height && $0.density == settings.density }
    }

    /// Every size turned to one orientation (phones and tablets both work either way).
    static func list(landscape: Bool) -> [ResolutionPreset] {
        all.map { $0.oriented(landscape: landscape) }
    }

    func oriented(landscape: Bool) -> ResolutionPreset {
        guard (width > height) != landscape else { return self }
        let kind = name.split(separator: " ").first.map(String.init) ?? ""
        return ResolutionPreset(name: "\(kind) \(height) × \(width)", width: height, height: width, density: density)
    }
}

struct PerformancePreset: Identifiable, Equatable, Sendable {
    let name: String
    let cpuCores: Int
    let ramMB: Int
    var id: String { name }

    static let all = [
        PerformancePreset(name: "Low", cpuCores: 2, ramMB: 2048),
        PerformancePreset(name: "Medium", cpuCores: 4, ramMB: 4096),
        PerformancePreset(name: "High", cpuCores: 6, ramMB: 6144),
        PerformancePreset(name: "Ultra", cpuCores: 8, ramMB: 8192),
    ]

    /// Presets this Mac can run.
    static func available(on host: HostLimits) -> [PerformancePreset] {
        all.filter { $0.cpuCores <= host.maxCpuCores && $0.ramMB <= host.maxRamMB }
    }

    /// MyEmu's suggestion for one Android on this Mac: every performance core plus half the
    /// efficiency cores (2–8), and a quarter of the Mac's memory (2–8 GB), leaving room for macOS.
    static func suggested(for host: HostLimits) -> PerformancePreset {
        let cores = host.performanceCores > 0
            ? host.performanceCores + host.efficiencyCores / 2
            : host.maxCpuCores / 2
        let cpu = min(max(cores, 2), min(8, host.maxCpuCores))
        let quarterOfMacGB = host.maxRamMB * 2 / 1024 / 4 // maxRamMB is half the Mac's memory
        let ramGB = min(max(quarterOfMacGB, 2), min(8, host.maxRamMB / 1024))
        return PerformancePreset(name: "Suggested", cpuCores: cpu, ramMB: ramGB * 1024)
    }

    static func matching(_ settings: AvdSettings) -> PerformancePreset? {
        all.first { $0.cpuCores == settings.cpuCores && $0.ramMB == settings.ramMB }
    }
}

/// "4G", "228M" or a plain number of megabytes → megabytes.
func parseMegabytes(_ text: String) -> Int? {
    let value = text.trimmingCharacters(in: .whitespaces).uppercased()
    if value.hasSuffix("G") { return Int(value.dropLast()).map { $0 * 1024 } }
    if value.hasSuffix("M") { return Int(value.dropLast()) }
    return Int(value)
}

/// Rewrites `key=value` lines in place, appends missing keys, and leaves every other line alone.
func updatingIni(_ text: String, with values: [String: String]) -> String {
    var remaining = values
    var lines = text.components(separatedBy: "\n").map { line -> String in
        let key = line.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key, let value = remaining.removeValue(forKey: key) else { return line }
        return "\(key)=\(value)"
    }
    if lines.last == "" { lines.removeLast() }
    lines += remaining.keys.sorted().map { "\($0)=\(remaining[$0]!)" }
    return lines.joined(separator: "\n") + "\n"
}
