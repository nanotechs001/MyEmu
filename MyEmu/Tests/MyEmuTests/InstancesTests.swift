import Foundation
import Testing
@testable import MyEmu

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
