import Foundation
import Testing
@testable import MyEmu

private func file(_ name: String) -> URL { URL(filePath: "/Users/me/Downloads/\(name)") }

@Test func separateApksInstallOneAtATime() {
    let batches = ApkInstall.batches([file("game.apk"), file("Tool.APK"), file("notes.txt")])
    #expect(batches == [[file("game.apk")], [file("Tool.APK")]])
}

@Test func splitApksInstallTogetherWithTheirBase() {
    let files = [file("base.apk"), file("split_config.arm64_v8a.apk"), file("split_config.hdpi.apk")]
    #expect(ApkInstall.batches(files) == [files])
}

@Test func nonApkFilesAreIgnored() {
    #expect(ApkInstall.batches([file("game.xapk"), file("photo.png")]).isEmpty)
}

@Test func adbInstallArgumentsReplaceExistingApps() {
    #expect(ApkInstall.adbArguments([file("my game.apk")]) == ["install", "-r", "/Users/me/Downloads/my game.apk"])
    #expect(ApkInstall.adbArguments([file("base.apk"), file("split_a.apk")])
            == ["install-multiple", "-r", "/Users/me/Downloads/base.apk", "/Users/me/Downloads/split_a.apk"])
}

@Test func googleAppsAreOnlyReadyAsTheMatchingSetWithoutThePlaceholder() {
    let check = Engine.playAppsReadyCheck(hashes: ["aa11", "bb22", "cc33"])
    // Play services and its Services Framework must match Play Store's key, not just Play Store exist.
    #expect(check.contains("sha256sum /product/priv-app/Phonesky/Phonesky.apk 2>/dev/null | grep -q ^aa11"))
    #expect(check.contains("sha256sum /product/priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk 2>/dev/null | grep -q ^bb22"))
    #expect(check.contains("GoogleServicesFramework.apk 2>/dev/null | grep -q ^cc33"))
    // Google's placeholder would still compete for Play Store's updates.
    #expect(check.contains("test ! -e /product/app/LicenseChecker"))
    #expect(check.hasSuffix("echo ready"))
}
