import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import os

private let log = Logger(subsystem: "MyEmu", category: "mcp")

typealias MCPConnection = NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>
typealias MCPListener = NIOAsyncChannel<MCPConnection, Never>

/// MCP's Streamable HTTP transport, the simple way: each POST to /mcp carries one JSON-RPC message
/// and gets one JSON reply (no server-sent event stream, no sessions). Loopback only.
enum MCPHTTPServer {
    static let path = "/mcp"
    /// MCP requests are small; anything bigger is refused.
    static let maxBodyBytes = 1 << 20

    static func bind(port: Int) async throws -> MCPListener {
        try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    return try MCPConnection(wrappingChannelSynchronously: channel)
                }
            }
    }

    /// Serves until the listener closes, then drops open connections.
    static func serve(_ listener: MCPListener, dispatcher: MCPDispatcher) async {
        do {
            try await withThrowingDiscardingTaskGroup { group in
                try await listener.executeThenClose { inbound in
                    for try await connection in inbound {
                        group.addTask { await handle(connection, dispatcher: dispatcher) }
                    }
                }
                group.cancelAll() // keep-alive clients would otherwise hold the server open
            }
        } catch {
            log.error("MCP server stopped: \(error.localizedDescription)")
        }
    }

    private static func handle(_ connection: MCPConnection, dispatcher: MCPDispatcher) async {
        do {
            try await connection.executeThenClose { inbound, outbound in
                var head: HTTPRequestHead?
                var body = ByteBuffer()
                var tooBig = false
                for try await part in inbound {
                    switch part {
                    case let .head(requestHead):
                        (head, body, tooBig) = (requestHead, ByteBuffer(), false)
                    case var .body(chunk):
                        if body.readableBytes + chunk.readableBytes > maxBodyBytes { tooBig = true }
                        else { body.writeBuffer(&chunk) }
                    case .end:
                        guard let head else { continue }
                        let (status, reply) = tooBig ? (.payloadTooLarge, nil)
                            : await respond(to: head, body: Data(body.readableBytesView), dispatcher: dispatcher)
                        try await write(status, reply, version: head.version, to: outbound)
                    }
                }
            }
        } catch {
            log.debug("MCP connection ended: \(error.localizedDescription)")
        }
    }

    /// Routing and the browser guard; the dispatcher does the rest.
    static func respond(to head: HTTPRequestHead, body: Data, dispatcher: MCPDispatcher) async -> (HTTPResponseStatus, Data?) {
        // A web page can reach a localhost port through DNS rebinding; MCP says to check Origin.
        if let origin = head.headers.first(name: "Origin"), !isLocal(origin: origin) { return (.forbidden, nil) }
        guard head.uri.split(separator: "?").first == Substring(path) else { return (.notFound, nil) }
        guard head.method == .POST else { return (.methodNotAllowed, nil) } // no event stream (GET), no sessions (DELETE)
        guard let reply = await dispatcher.handle(body) else { return (.accepted, nil) }
        return (.ok, reply)
    }

    static func isLocal(origin: String) -> Bool {
        guard let host = URL(string: origin)?.host() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    private static func write(_ status: HTTPResponseStatus, _ body: Data?, version: HTTPVersion,
                              to outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>) async throws {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: String(body?.count ?? 0))
        if body != nil { headers.add(name: "Content-Type", value: "application/json") }
        if status == .methodNotAllowed { headers.add(name: "Allow", value: "POST") }
        try await outbound.write(.head(HTTPResponseHead(version: version, status: status, headers: headers)))
        if let body { try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: body)))) }
        try await outbound.write(.end(nil))
    }
}

/// The launcher's "Allow AI control" switch: the MCP server runs while it's on.
@MainActor
@Observable
final class AIControl {
    static let port = 8765
    static var url: String { "http://127.0.0.1:\(port)\(MCPHTTPServer.path)" }
    private static let enabledKey = "aiControlEnabled"

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? start() : stop()
        }
    }
    /// Why the server isn't running although it's switched on (e.g. the port is taken).
    private(set) var problem: String?

    @ObservationIgnored private let tools: MyEmuMCP
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var listener: (any Channel)?

    init(manager: InstanceManager) {
        tools = MyEmuMCP(manager: manager)
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey) // off unless chosen
        if isEnabled { start() }
    }

    /// After a failure, switching off and on again retries.
    private func start() {
        guard task == nil else { return }
        problem = nil
        let dispatcher = tools.dispatcher
        task = Task {
            do {
                let server = try await MCPHTTPServer.bind(port: Self.port)
                listener = server.channel
                log.info("MCP server listening on \(Self.url, privacy: .public)")
                await MCPHTTPServer.serve(server, dispatcher: dispatcher)
            } catch {
                problem = "Couldn't start on port \(Self.port): \(error.localizedDescription)"
                log.error("MCP server failed to start: \(error.localizedDescription)")
            }
        }
    }

    private func stop() {
        listener?.close(promise: nil)
        task?.cancel()
        (task, listener, problem) = (nil, nil, nil)
    }
}
