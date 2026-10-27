import Foundation
import Testing
@testable import MyEmu

@Test func parsesForegroundAppSwitches() {
    #expect(AndroidWatch.foregroundPackage(fromEvent: "[0,com.supercell.clashroyale/.GameApp,realStartActivityLocked - onActivityStateChanged]")
            == "com.supercell.clashroyale")
    #expect(AndroidWatch.foregroundPackage(fromEvent: "[0,com.google.android.apps.nexuslauncher/.NexusLauncherActivity,resumeTopActivity]")
            == "com.google.android.apps.nexuslauncher")
    #expect(AndroidWatch.foregroundPackage(fromEvent: "--------- beginning of events") == nil)
    #expect(AndroidWatch.foregroundPackage(fromEvent: "[0,../../etc/x/.A,reason]") == nil) // never a path
}

@Test func keyboardRequestsTriggerATextFieldCheck() {
    // Requests only say "something changed": games send hide requests Android refuses while the box stays open.
    #expect(AndroidWatch.isKeyboardRequest("I/ImeTracker( 1336): com.Tq.CQ2ClientAndroid:9c6bd392: onRequestShow at ORIGIN_CLIENT reason SHOW_SOFT_INPUT fromUser false"))
    #expect(AndroidWatch.isKeyboardRequest("I/ImeTracker(  641): com.Tq.CQ2ClientAndroid:c716153f: onRequestHide at ORIGIN_SERVER reason HIDE_UNSPECIFIED_WINDOW fromUser false"))
    #expect(!AndroidWatch.isKeyboardRequest("I/ImeTracker( 2876): com.Tq.CQ2ClientAndroid:783ad349: onCancelled at PHASE_CLIENT_APPLY_ANIMATION"))
    #expect(!AndroidWatch.isKeyboardRequest("--------- beginning of main"))
}

@Test func detectsAFocusedTextField() {
    #expect(AndroidWatch.isTyping(from: "inputType=0x100001") == true) // search box
    #expect(AndroidWatch.isTyping(from: "inputType=0x21\r") == true) // email field
    #expect(AndroidWatch.isTyping(from: "inputType=0x0") == false) // home screen / game surface
    #expect(AndroidWatch.isTyping(from: "inputType=0x10000") == false) // flags only, no text class
    #expect(AndroidWatch.isTyping(from: "garbage") == nil)
}

@Test func validatesPackageNames() {
    #expect(AndroidWatch.isValidPackage("com.example.game_2"))
    #expect(!AndroidWatch.isValidPackage(""))
    #expect(!AndroidWatch.isValidPackage("com/evil"))
    #expect(!AndroidWatch.isValidPackage(".hidden"))
}

@Test func splitsStreamOutputIntoWholeLines() {
    var buffer = Data("first line\nsecond".utf8)
    #expect(AndroidWatch.takeLines(from: &buffer) == ["first line"])
    #expect(buffer == Data("second".utf8)) // the partial line waits for the rest
    buffer.append(Data(" half\n\nthird\n".utf8))
    #expect(AndroidWatch.takeLines(from: &buffer) == ["second half", "", "third"])
    #expect(buffer.isEmpty)
}
