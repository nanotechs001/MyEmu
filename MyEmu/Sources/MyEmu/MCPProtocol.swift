import Foundation

/// A JSON value: MCP's JSON-RPC params and results are free-form.
enum JSON: Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSON]), object([String: JSON])

    subscript(key: String) -> JSON? {
        if case let .object(fields) = self { return fields[key] }
        return nil
    }

    var string: String? { if case let .string(value) = self { value } else { nil } }
    var number: Double? { if case let .number(value) = self { value } else { nil } }
    var bool: Bool? { if case let .bool(value) = self { value } else { nil } }
}

extension JSON: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSON].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8) // every case is encodable
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSON)...) { self = .object(Dictionary(elements) { $1 }) }
}

/// One piece of a tool's answer.
enum MCPContent: Sendable, Equatable {
    case text(String)
    case image(Data, mimeType: String)

    var json: JSON {
        switch self {
        case let .text(text): ["type": "text", "text": .string(text)]
        case let .image(data, mimeType): ["type": "image", "data": .string(data.base64EncodedString()), "mimeType": .string(mimeType)]
        }
    }
}

struct MCPToolInfo: Sendable {
    let name: String
    let description: String
    let inputSchema: JSON
}

/// A tool that failed in a way the AI should read (sent as a tool result, not a protocol error).
struct MCPToolError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

enum MCPCallError: Error {
    case unknownTool(String)
}

/// Answers MCP's JSON-RPC messages: the handshake, ping, and listing and calling tools.
struct MCPDispatcher: Sendable {
    /// Newest first; a client asking for one of these gets it, anything else gets the newest.
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    let serverName: String
    let serverVersion: String
    let instructions: String
    let tools: [MCPToolInfo]
    let call: @Sendable (_ name: String, _ arguments: JSON) async throws -> [MCPContent]

    /// The reply to a JSON-RPC message (or batch); nil when there's nothing to answer (a
    /// notification or a response), which HTTP sends as 202 Accepted.
    func handle(_ body: Data) async -> Data? {
        guard let message = try? JSONDecoder().decode(JSON.self, from: body) else {
            return Self.error(id: .null, code: -32700, "Parse error").encoded()
        }
        guard case let .array(batch) = message else { return await reply(to: message)?.encoded() }
        var replies: [JSON] = []
        for item in batch {
            if let reply = await reply(to: item) { replies.append(reply) }
        }
        return replies.isEmpty ? nil : JSON.array(replies).encoded()
    }

    func reply(to message: JSON) async -> JSON? {
        guard let method = message["method"]?.string else { return nil } // a response from the client
        guard let id = message["id"] else { return nil } // a notification, e.g. notifications/initialized
        let params = message["params"] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.string
            let version = asked.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0]
            return Self.result(id, ["protocolVersion": .string(version),
                                    "capabilities": ["tools": ["listChanged": false]],
                                    "serverInfo": ["name": .string(serverName), "version": .string(serverVersion)],
                                    "instructions": .string(instructions)])
        case "ping":
            return Self.result(id, [:])
        case "tools/list":
            return Self.result(id, ["tools": .array(tools.map {
                ["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.inputSchema]
            })])
        case "tools/call":
            guard let name = params["name"]?.string else { return Self.error(id: id, code: -32602, "Missing tool name") }
            do {
                let content = try await call(name, params["arguments"] ?? [:])
                return Self.result(id, ["content": .array(content.map(\.json)), "isError": false])
            } catch MCPCallError.unknownTool(let name) {
                return Self.error(id: id, code: -32602, "Unknown tool: \(name)")
            } catch {
                return Self.result(id, ["content": [MCPContent.text(error.localizedDescription).json], "isError": true])
            }
        default:
            return Self.error(id: id, code: -32601, "Method not found: \(method)")
        }
    }

    private static func result(_ id: JSON, _ result: JSON) -> JSON {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSON, code: Int, _ message: String) -> JSON {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }
}
