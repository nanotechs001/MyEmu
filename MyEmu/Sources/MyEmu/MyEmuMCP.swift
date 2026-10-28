import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

private let log = Logger(subsystem: "MyEmu", category: "mcp")

/// What an AI can do over MCP: what you do in MyEmu's windows — start and stop Androids, look at a
/// screen, tap, swipe, type, press keys, open apps and set game speed.
@MainActor
final class MyEmuMCP {
    /// Screenshots are scaled to fit this, small enough for an AI to read quickly.
    nonisolated static let maxScreenshotSide = 1280
    static let defaultLongPressMs = 800.0
    static let defaultSwipeMs = 300.0
    static let maxGestureMs = 10_000.0
    static let maxTextLength = 1000

    private let manager: InstanceManager
    /// Each instance's last screenshot scale (image pixels per screen pixel): taps use the
    /// coordinates the AI saw.
    private var screenshotScale: [String: Double] = [:]

    init(manager: InstanceManager) {
        self.manager = manager
    }

    var dispatcher: MCPDispatcher {
        MCPDispatcher(serverName: "MyEmu",
                      serverVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                      instructions: Self.instructions, tools: Self.tools,
                      call: { name, arguments in try await self.call(name, arguments) })
    }

    static let instructions = """
        Controls MyEmu, an Android emulator on this Mac, the way a person uses its windows. \
        Call list_instances first. Start an instance and poll list_instances until it's ready. \
        Take a screenshot to see the screen, then tap, long_press or swipe using that screenshot's \
        pixel coordinates, and take a new screenshot to check what happened.
        """

    // MARK: Tools

    private static let instanceArgument: JSON = ["type": "string", "description": "Instance id or name, from list_instances"]
    private static func number(_ description: String) -> JSON { ["type": "number", "description": .string(description)] }

    private static func tool(_ name: String, _ description: String, _ properties: [String: JSON] = [:],
                             required: [String] = []) -> MCPToolInfo {
        MCPToolInfo(name: name, description: description,
                    inputSchema: ["type": "object", "properties": .object(properties), "required": .array(required.map(JSON.string))])
    }

    private static func onInstance(_ name: String, _ description: String, _ properties: [String: JSON] = [:],
                                   required: [String] = []) -> MCPToolInfo {
        tool(name, description, properties.merging(["instance": instanceArgument]) { $1 }, required: ["instance"] + required)
    }

    /// Android key names the press_key tool takes, and their key codes.
    static let keys = [
        "back": "KEYCODE_BACK", "home": "KEYCODE_HOME", "recents": "KEYCODE_APP_SWITCH", "enter": "KEYCODE_ENTER",
        "delete": "KEYCODE_DEL", "tab": "KEYCODE_TAB", "escape": "KEYCODE_ESCAPE", "space": "KEYCODE_SPACE",
        "up": "KEYCODE_DPAD_UP", "down": "KEYCODE_DPAD_DOWN", "left": "KEYCODE_DPAD_LEFT", "right": "KEYCODE_DPAD_RIGHT",
        "volume_up": "KEYCODE_VOLUME_UP", "volume_down": "KEYCODE_VOLUME_DOWN",
    ]

    static let tools: [MCPToolInfo] = [
        tool("list_instances", "Every Android in MyEmu: id, name, whether it's running and ready, and for running ones their status, profile, app in front and game speed."),
        onInstance("start_instance", "Starts an instance by opening its window. Android takes a minute or so: poll list_instances until ready is true."),
        onInstance("stop_instance", "Stops an instance by closing its window."),
        onInstance("screenshot", "The instance's screen as an image. tap, long_press and swipe take x/y in this image's pixels."),
        onInstance("tap", "Taps the screen at x, y (pixels of the latest screenshot).",
                   ["x": number("Pixels from the left"), "y": number("Pixels from the top")], required: ["x", "y"]),
        onInstance("long_press", "Touches and holds at x, y (pixels of the latest screenshot).",
                   ["x": number("Pixels from the left"), "y": number("Pixels from the top"),
                    "duration_ms": number("How long to hold; default 800")], required: ["x", "y"]),
        onInstance("swipe", "Drags a finger from x1, y1 to x2, y2 (pixels of the latest screenshot). Swipe up to scroll down.",
                   ["x1": number("Start, from the left"), "y1": number("Start, from the top"),
                    "x2": number("End, from the left"), "y2": number("End, from the top"),
                    "duration_ms": number("How long the drag takes; default 300")], required: ["x1", "y1", "x2", "y2"]),
        onInstance("type_text", "Types text into the focused text field (tap it first). ASCII only, one line; use press_key enter to submit.",
                   ["text": ["type": "string"]], required: ["text"]),
        onInstance("press_key", "Presses an Android key, e.g. back or home.",
                   ["key": ["type": "string", "enum": .array(keys.keys.sorted().map(JSON.string))]], required: ["key"]),
        onInstance("list_apps", "Apps installed on the instance (package names), for launch_app.",
                   ["include_system": ["type": "boolean", "description": "Also list Android's own apps; default false"]]),
        onInstance("launch_app", "Opens an app by its package name.", ["package": ["type": "string"]], required: ["package"]),
        onInstance("set_game_speed", "Sets how fast games run on this instance (Custom model profile only). It takes effect when the game next starts; after that, changes apply live.",
                   ["speed": ["type": "number", "enum": .array(AndroidOptions.gameSpeeds.map(JSON.number))]], required: ["speed"]),
    ]

    func call(_ name: String, _ arguments: JSON) async throws -> [MCPContent] {
        log.info("MCP tool \(name, privacy: .public)")
        switch name {
        case "list_instances": return [.text(listInstances())]
        case "start_instance": return [.text(try start(arguments))]
        case "stop_instance": return [.text(try stop(arguments))]
        case "screenshot": return try await screenshot(arguments)
        case "tap":
            let (instance, serial) = try readyInstance(arguments)
            let (x, y) = try point(arguments, "x", "y", on: instance)
            return [.text(try await shell(serial, "input tap \(x) \(y)", done: "Tapped \(x), \(y) on screen."))]
        case "long_press":
            let (instance, serial) = try readyInstance(arguments)
            let (x, y) = try point(arguments, "x", "y", on: instance)
            let ms = try duration(arguments, default: Self.defaultLongPressMs)
            return [.text(try await shell(serial, "input swipe \(x) \(y) \(x) \(y) \(ms)", done: "Held \(x), \(y) for \(ms) ms."))]
        case "swipe":
            let (instance, serial) = try readyInstance(arguments)
            let (x1, y1) = try point(arguments, "x1", "y1", on: instance)
            let (x2, y2) = try point(arguments, "x2", "y2", on: instance)
            let ms = try duration(arguments, default: Self.defaultSwipeMs)
            return [.text(try await shell(serial, "input swipe \(x1) \(y1) \(x2) \(y2) \(ms)", done: "Swiped."))]
        case "type_text":
            let (_, serial) = try readyInstance(arguments)
            let command = try Self.inputTextCommand(arguments["text"]?.string ?? "")
            return [.text(try await shell(serial, command, done: "Typed."))]
        case "press_key":
            let (_, serial) = try readyInstance(arguments)
            guard let key = arguments["key"]?.string, let code = Self.keys[key] else {
                throw MCPToolError("key must be one of: \(Self.keys.keys.sorted().joined(separator: ", ")).")
            }
            return [.text(try await shell(serial, "input keyevent \(code)", done: "Pressed \(key)."))]
        case "list_apps": return [.text(try await listApps(arguments))]
        case "launch_app": return [.text(try await launchApp(arguments))]
        case "set_game_speed": return [.text(try setGameSpeed(arguments))]
        default: throw MCPCallError.unknownTool(name)
        }
    }

    // MARK: Instances

    private func listInstances() -> String {
        let rows: [JSON] = manager.list.instances.map { instance in
            let running = manager.openIDs.contains(instance.id)
            var row: [String: JSON] = ["id": .string(instance.id), "name": .string(instance.name), "running": .bool(running)]
            guard running, let model = manager.model(for: instance.id) else { return .object(row.merging(["ready": false]) { $1 }) }
            row["ready"] = .bool(model.androidReady)
            row["status"] = .string(model.status)
            row["profile"] = .string(model.profile.rawValue)
            row["gameSpeed"] = .number(model.gameSpeed)
            if let app = model.gameKeys.currentApp { row["foregroundApp"] = .string(app) }
            return .object(row)
        }
        return String(decoding: JSON.array(rows).encoded(), as: UTF8.self)
    }

    private func instance(_ arguments: JSON) throws -> Instance {
        guard let key = arguments["instance"]?.string else {
            throw MCPToolError("Pass instance: an id or name from list_instances.")
        }
        let all = manager.list.instances
        if let match = all.first(where: { $0.id == key })
            ?? all.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) {
            return match
        }
        throw MCPToolError("No instance \"\(key)\". Call list_instances for the ids.")
    }

    private func runningModel(_ arguments: JSON) throws -> (Instance, EmulatorModel) {
        let instance = try instance(arguments)
        guard manager.openIDs.contains(instance.id), let model = manager.model(for: instance.id) else {
            throw MCPToolError("\(instance.name) isn't running. Call start_instance first.")
        }
        return (instance, model)
    }

    /// A running instance whose Android has finished starting, with its adb serial.
    private func readyInstance(_ arguments: JSON) throws -> (Instance, String) {
        let (instance, model) = try runningModel(arguments)
        guard model.androidReady, let serial = model.adbSerial else {
            throw MCPToolError("\(instance.name) is still starting (\(model.status)). Try again in a few seconds.")
        }
        return (instance, serial)
    }

    private func start(_ arguments: JSON) throws -> String {
        let instance = try instance(arguments)
        if manager.openIDs.contains(instance.id) { return "\(instance.name) is already running." }
        guard let open = manager.openInstance else {
            throw MCPToolError("MyEmu has no window to start it from yet; open MyEmu's window once.")
        }
        open(instance.id)
        return "Starting \(instance.name). Poll list_instances until ready is true."
    }

    private func stop(_ arguments: JSON) throws -> String {
        let (instance, _) = try runningModel(arguments)
        manager.stop(instance.id)
        screenshotScale[instance.id] = nil
        return "Stopping \(instance.name)."
    }

    // MARK: Screen and input

    private func screenshot(_ arguments: JSON) async throws -> [MCPContent] {
        let (instance, serial) = try readyInstance(arguments)
        let shot = try await Self.captureScreen(serial: serial)
        screenshotScale[instance.id] = shot.scale
        return [.image(shot.jpeg, mimeType: "image/jpeg"),
                .text("\(instance.name): a \(shot.width)×\(shot.height) image of its \(shot.screenWidth)×\(shot.screenHeight) screen. Give tap, long_press and swipe this image's pixel coordinates.")]
    }

    nonisolated static func captureScreen(serial: String) async throws -> Screenshot {
        let remote = "/data/local/tmp/myemu-mcp-screen.png"
        let local = FileManager.default.temporaryDirectory.appending(path: "myemu-mcp-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: local) }
        // Through a file: adb's output comes back as text, which would mangle the PNG.
        _ = try await Engine.adb(serial: serial, ["shell", "screencap -p \(remote)"])
        _ = try await Engine.adb(serial: serial, ["pull", remote, local.path])
        return try Screenshot(png: Data(contentsOf: local), maxSide: maxScreenshotSide)
    }

    /// Screen pixels for x/y given in the latest screenshot's pixels.
    private func point(_ arguments: JSON, _ xKey: String, _ yKey: String, on instance: Instance) throws -> (Int, Int) {
        guard let x = arguments[xKey]?.number, let y = arguments[yKey]?.number, x >= 0, y >= 0 else {
            throw MCPToolError("\(xKey) and \(yKey) must be numbers of 0 or more.")
        }
        let scale = screenshotScale[instance.id] ?? 1 // no screenshot yet: screen pixels
        return (Int((x / scale).rounded()), Int((y / scale).rounded()))
    }

    private func duration(_ arguments: JSON, default value: Double) throws -> Int {
        guard let ms = arguments["duration_ms"]?.number ?? Optional(value), ms >= 1, ms <= Self.maxGestureMs else {
            throw MCPToolError("duration_ms must be between 1 and \(Int(Self.maxGestureMs)).")
        }
        return Int(ms)
    }

    /// Android's `input text`, quoted for its shell. Spaces become %s, which is how it types a space.
    static func inputTextCommand(_ text: String) throws -> String {
        guard !text.isEmpty, text.count <= maxTextLength else {
            throw MCPToolError("text must be 1 to \(maxTextLength) characters.")
        }
        guard text.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 && $0.value != 0x7F }) else {
            throw MCPToolError("type_text takes plain ASCII on one line (Android's input command can't type other characters). Use press_key enter for a new line.")
        }
        let quoted = text.replacingOccurrences(of: " ", with: "%s").replacingOccurrences(of: "'", with: "'\\''")
        return "input text '\(quoted)'"
    }

    private func shell(_ serial: String, _ command: String, done: String) async throws -> String {
        _ = try await Engine.adb(serial: serial, ["shell", command])
        return done
    }

    // MARK: Apps and game speed

    private func listApps(_ arguments: JSON) async throws -> String {
        let (_, serial) = try readyInstance(arguments)
        let flag = arguments["include_system"]?.bool == true ? "" : " -3" // -3: apps you installed
        let output = try await Engine.adb(serial: serial, ["shell", "pm list packages\(flag)"])
        let packages = output.split(whereSeparator: \.isNewline)
            .compactMap { $0.hasPrefix("package:") ? String($0.dropFirst("package:".count)).trimmingCharacters(in: .whitespaces) : nil }
            .sorted()
        return packages.isEmpty ? "No apps found." : packages.joined(separator: "\n")
    }

    private func launchApp(_ arguments: JSON) async throws -> String {
        let (_, serial) = try readyInstance(arguments)
        guard let package = arguments["package"]?.string, AndroidWatch.isValidPackage(package) else {
            throw MCPToolError("package must be an Android package name, e.g. com.android.settings (see list_apps).")
        }
        let output = try await Engine.adb(serial: serial, ["shell", "monkey -p \(package) -c android.intent.category.LAUNCHER 1"])
        if output.contains("No activities found") { throw MCPToolError("\(package) isn't installed or has nothing to open.") }
        return "Opened \(package)."
    }

    private func setGameSpeed(_ arguments: JSON) throws -> String {
        let (instance, model) = try runningModel(arguments)
        guard model.profile == .customModel else {
            throw MCPToolError("Game speed needs the Custom model profile; \(instance.name) runs \(model.profile.title).")
        }
        guard let speed = arguments["speed"]?.number, AndroidOptions.gameSpeeds.contains(speed) else {
            throw MCPToolError("speed must be one of \(AndroidOptions.gameSpeeds.map { String($0) }.joined(separator: ", ")).")
        }
        model.gameSpeed = speed
        return "\(instance.name)'s game speed is \(speed)×. It takes effect when the game next starts; after that, changes apply live."
    }
}

/// A screen capture scaled down for an AI to read, with the sizes to map its coordinates back.
struct Screenshot: Sendable {
    let jpeg: Data
    let width: Int, height: Int
    let screenWidth: Int, screenHeight: Int
    /// Image pixels per screen pixel.
    var scale: Double { Double(width) / Double(screenWidth) }

    init(png: Data, maxSide: Int) throws {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let fullWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let fullHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: min(maxSide, max(fullWidth, fullHeight)), // never enlarge
              ] as CFDictionary) else {
            throw MCPToolError("Couldn't read the screenshot.")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw MCPToolError("Couldn't encode the screenshot.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MCPToolError("Couldn't encode the screenshot.") }
        (jpeg, width, height, screenWidth, screenHeight) = (output as Data, image.width, image.height, fullWidth, fullHeight)
    }
}
