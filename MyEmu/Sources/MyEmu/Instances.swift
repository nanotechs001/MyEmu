import Foundation

/// One Android you can run in its own window, with its own apps and data. Instance 1 is the
/// original MyEmu setup and keeps its AVDs and settings.
struct Instance: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    /// Fixed for the instance's life: picks its AVDs and gRPC port.
    let number: Int

    static let main = Instance(id: "main", name: "Android 1", number: 1)
    static let baseGrpcPort = 8554

    /// Instance 1 keeps the original AVD names; the others get a suffix.
    func avd(for profile: DeviceProfile) -> String {
        number == 1 ? profile.avd : "\(profile.avd)-\(number)"
    }

    /// Two apart, like the engine's own console/adb port pairs.
    var grpcPort: Int { Self.baseGrpcPort + (number - 1) * 2 }

    /// A UserDefaults key for a setting that belongs to this instance (instance 1 keeps the old key).
    func defaultsKey(_ base: String) -> String {
        number == 1 ? base : "\(base)-\(id)"
    }
}

struct InstanceList: Codable, Equatable, Sendable {
    /// Each one is a full Android with its own CPU, memory and several GB of disk.
    static let maxCount = 8
    static let maxNameLength = 40

    private(set) var instances: [Instance] = [.main]

    var canAdd: Bool { instances.count < Self.maxCount }

    func instance(id: String) -> Instance? {
        instances.first { $0.id == id }
    }

    /// Adds "Android <n>" (or `name`) with the next unused number; nil at the limit.
    mutating func add(id: String = UUID().uuidString, name: String? = nil) -> Instance? {
        guard canAdd else { return nil }
        let number = (instances.map(\.number).max() ?? 0) + 1
        let instance = Instance(id: id, name: name.map { String($0.prefix(Self.maxNameLength)) } ?? "Android \(number)",
                                number: number)
        instances.append(instance)
        return instance
    }

    /// Instance 1 can't be removed.
    mutating func remove(id: String) {
        instances.removeAll { $0.id == id && $0.number != 1 }
    }

    mutating func rename(id: String, to name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxNameLength))
        guard !trimmed.isEmpty, let index = instances.firstIndex(where: { $0.id == id }) else { return }
        instances[index].name = trimmed
    }

    private static let defaultsKey = "instances"

    static func load(from defaults: UserDefaults = .standard) -> InstanceList {
        guard let data = defaults.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode(InstanceList.self, from: data), // unreadable → just instance 1
              list.instances.contains(where: { $0.number == 1 }) else { return InstanceList() }
        return list
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
