import Foundation
import Testing
@testable import MyEmu

@Test func cloneCopiesAnAvdWithItsDataButNotItsLocks() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "clone-test-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let source = root.appending(path: "myemu.avd")
    try fm.createDirectory(at: source.appending(path: "multiinstance.lock"), withIntermediateDirectories: true)
    try "hw.cpu.ncore=4\n".write(to: source.appending(path: "config.ini"), atomically: true, encoding: .utf8)
    try "game data".write(to: source.appending(path: "userdata-qemu.img.qcow2"), atomically: true, encoding: .utf8)

    #expect(try Engine.cloneAvd("myemu", to: "myemu-3", root: root))
    let copy = root.appending(path: "myemu-3.avd")
    #expect(try String(contentsOf: copy.appending(path: "userdata-qemu.img.qcow2"), encoding: .utf8) == "game data")
    #expect(try String(contentsOf: copy.appending(path: "config.ini"), encoding: .utf8) == "hw.cpu.ncore=4\n")
    #expect(!fm.fileExists(atPath: copy.appending(path: "multiinstance.lock").path))
    #expect(fm.fileExists(atPath: source.appending(path: "multiinstance.lock").path)) // original untouched
    let ini = try String(contentsOf: root.appending(path: "myemu-3.ini"), encoding: .utf8)
    #expect(ini.contains("path=\(copy.path)\n") && ini.contains("path.rel=avd/myemu-3.avd"))

    #expect(try !Engine.cloneAvd("myemu-custom", to: "myemu-custom-3", root: root)) // profile never used
    #expect(throws: CocoaError.self) { try Engine.cloneAvd("myemu", to: "myemu-3", root: root) } // never overwrites
}

@MainActor
@Test func cloneCarriesTheInstanceSettingsAndCapsTheName() throws {
    let defaults = try #require(UserDefaults(suiteName: "clone-test-\(UUID().uuidString)"))
    var list = InstanceList()
    let added = (list.add(), list.add(name: String(repeating: "x", count: 60)))
    let source = try #require(added.0), copy = try #require(added.1)
    #expect(copy.name.count == InstanceList.maxNameLength)
    defaults.set("customModel", forKey: source.defaultsKey("deviceProfile"))
    defaults.set("punchHole", forKey: source.defaultsKey("cutout"))
    EmulatorModel.copySettings(from: source, to: copy, defaults: defaults)
    #expect(defaults.string(forKey: copy.defaultsKey("deviceProfile")) == "customModel")
    #expect(defaults.string(forKey: copy.defaultsKey("cutout")) == "punchHole")
    #expect(defaults.object(forKey: copy.defaultsKey("phoneLine")) == nil) // nothing to copy stays unset
}

@Test func instanceOneKeepsTheOriginalAvdsPortAndSettings() {
    #expect(Instance.main.avd(for: .playStore) == "myemu")
    #expect(Instance.main.avd(for: .customModel) == "myemu-custom")
    #expect(Instance.main.grpcPort == 8554)
    #expect(Instance.main.defaultsKey("deviceProfile") == "deviceProfile")
}

@Test func newInstancesGetTheirOwnAvdsPortsAndSettings() throws {
    var list = InstanceList()
    let added = list.add(id: "B")
    let second = try #require(added)
    #expect(second.name == "Android 2" && second.number == 2)
    #expect(second.avd(for: .playStore) == "myemu-2" && second.avd(for: .customModel) == "myemu-custom-2")
    #expect(second.grpcPort == 8556)
    #expect(second.defaultsKey("deviceProfile") == "deviceProfile-B")
    let addedThird = list.add(id: "C")
    let third = try #require(addedThird)
    #expect(third.number == 3 && third.grpcPort == 8558)
}

@Test func instanceOneCannotBeRemovedAndTheListIsCapped() {
    var list = InstanceList()
    list.remove(id: "main")
    #expect(list.instances == [.main])
    for _ in 1..<InstanceList.maxCount { _ = list.add() }
    #expect(!list.canAdd && list.add() == nil)
}

@Test func renameTrimsAndIgnoresEmptyNames() {
    var list = InstanceList()
    list.rename(id: "main", to: "  Farming  ")
    #expect(list.instances[0].name == "Farming")
    list.rename(id: "main", to: "   ")
    #expect(list.instances[0].name == "Farming")
    list.rename(id: "main", to: String(repeating: "x", count: 60))
    #expect(list.instances[0].name.count == InstanceList.maxNameLength)
}

@Test func roundTripsThroughDefaultsAndFallsBackToInstanceOne() throws {
    let defaults = try #require(UserDefaults(suiteName: "myemu-tests-\(UUID().uuidString)"))
    #expect(InstanceList.load(from: defaults) == InstanceList())
    var list = InstanceList()
    _ = list.add(id: "B")
    list.save(to: defaults)
    #expect(InstanceList.load(from: defaults) == list)
    defaults.set(Data("junk".utf8), forKey: "instances")
    #expect(InstanceList.load(from: defaults) == InstanceList())
}

@Test func findsLeftoverEnginesForExactlyThisAvd() throws {
    let pattern = try NSRegularExpression(pattern: Engine.previousEnginePattern(avd: "myemu"))
    func matches(_ line: String) -> Bool {
        pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }
    let sdk = "/Users/x/Library/Android/sdk/emulator/qemu/darwin-aarch64/"
    #expect(matches(sdk + "qemu-system-aarch64-headless -avd myemu -no-window -gpu host")) // headless (current)
    #expect(matches(sdk + "qemu-system-aarch64 -avd myemu -qt-hide-window"))
    #expect(!matches(sdk + "qemu-system-aarch64-headless -avd myemu-2 -no-window")) // another instance
    #expect(!matches(sdk + "qemu-system-aarch64-headless -avd myemu-custom -no-window"))
}
