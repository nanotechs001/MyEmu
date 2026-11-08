import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MyEmu

private func dispatcher(_ call: @escaping @Sendable (String, JSON) async throws -> [MCPContent] = { _, _ in [.text("ok")] }) -> MCPDispatcher {
    MCPDispatcher(serverName: "MyEmu", serverVersion: "test", instructions: "Use it.",
                  tools: [MCPToolInfo(name: "echo", description: "Echoes", inputSchema: ["type": "object"])], call: call)
}

private func send(_ message: JSON, to dispatcher: MCPDispatcher) async throws -> JSON? {
    guard let reply = await dispatcher.handle(message.encoded()) else { return nil }
    return try JSONDecoder().decode(JSON.self, from: reply)
}

@Test func initializeAgreesOnAKnownProtocolVersion() async throws {
    let known = try await send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                "params": ["protocolVersion": "2025-03-26"]], to: dispatcher())
    #expect(known?["result"]?["protocolVersion"] == "2025-03-26")
    #expect(known?["result"]?["capabilities"]?["tools"] != nil)
    #expect(known?["id"] == 1)
    let unknown = try await send(["jsonrpc": "2.0", "id": "a", "method": "initialize",
                                  "params": ["protocolVersion": "1999-01-01"]], to: dispatcher())
    #expect(unknown?["result"]?["protocolVersion"] == .string(MCPDispatcher.protocolVersions[0]))
}

@Test func notificationsGetNoReply() async throws {
    #expect(try await send(["jsonrpc": "2.0", "method": "notifications/initialized"], to: dispatcher()) == nil)
}

@Test func toolsAreListedAndCalled() async throws {
    let list = try await send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], to: dispatcher())
    #expect(list?["result"]?["tools"] == [["name": "echo", "description": "Echoes", "inputSchema": ["type": "object"]]])
    let called = try await send(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "echo"]], to: dispatcher())
    #expect(called?["result"]?["content"] == [["type": "text", "text": "ok"]])
    #expect(called?["result"]?["isError"] == false)
}

@Test func failuresAreReportedTheWayMCPSays() async throws {
    let failing = dispatcher { name, _ in
        if name == "echo" { throw MCPToolError("Not running.") }
        throw MCPCallError.unknownTool(name)
    }
    let toolError = try await send(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "echo"]], to: failing)
    #expect(toolError?["result"]?["isError"] == true) // a tool's own failure is a result the AI reads
    #expect(toolError?["result"]?["content"] == [["type": "text", "text": "Not running."]])
    let unknownTool = try await send(["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "nope"]], to: failing)
    #expect(unknownTool?["error"]?["code"] == -32602)
    let unknownMethod = try await send(["jsonrpc": "2.0", "id": 6, "method": "resources/list"], to: dispatcher())
    #expect(unknownMethod?["error"]?["code"] == -32601)
    let garbage = await dispatcher().handle(Data("{not json".utf8)).flatMap { try? JSONDecoder().decode(JSON.self, from: $0) }
    #expect(garbage?["error"]?["code"] == -32700)
}

@Test func onlyLocalPagesMayCall() {
    #expect(MCPHTTPServer.isLocal(origin: "http://localhost:6274"))
    #expect(MCPHTTPServer.isLocal(origin: "http://127.0.0.1"))
    #expect(!MCPHTTPServer.isLocal(origin: "https://evil.example"))
    #expect(!MCPHTTPServer.isLocal(origin: "null"))
}

@MainActor
@Test func typedTextIsQuotedForAndroidsShell() throws {
    #expect(try MyEmuMCP.inputTextCommand("hello world") == "input text 'hello%sworld'")
    #expect(try MyEmuMCP.inputTextCommand("it's $HOME; rm") == "input text 'it'\\''s%s$HOME;%srm'")
    #expect(throws: MCPToolError.self) { try MyEmuMCP.inputTextCommand("") }
    #expect(throws: MCPToolError.self) { try MyEmuMCP.inputTextCommand("two\nlines") }
    #expect(throws: MCPToolError.self) { try MyEmuMCP.inputTextCommand("café") }
}

@MainActor
@Test func everyToolNeedsAnInstanceExceptTheList() {
    for tool in MyEmuMCP.tools where tool.name != "list_instances" {
        #expect(tool.inputSchema["required"]?.array?.contains("instance") == true, "\(tool.name)")
    }
    #expect(Set(MyEmuMCP.tools.map(\.name)).count == MyEmuMCP.tools.count) // no duplicates
}

@Test func screenshotsShrinkToFitAndKeepTheScale() throws {
    let png = try solidPNG(width: 2400, height: 1080)
    let shot = try Screenshot(png: png, maxSide: 1280)
    #expect((shot.width, shot.height) == (1280, 576))
    #expect((shot.screenWidth, shot.screenHeight) == (2400, 1080))
    #expect(abs(shot.scale - 1280.0 / 2400.0) < 0.001)
    let small = try Screenshot(png: try solidPNG(width: 800, height: 600), maxSide: 1280)
    #expect((small.width, small.height) == (800, 600)) // never enlarged
}

private func solidPNG(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private extension JSON {
    var array: [JSON]? { if case let .array(value) = self { value } else { nil } }
}
