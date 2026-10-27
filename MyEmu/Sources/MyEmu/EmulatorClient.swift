import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import os
import SwiftProtobuf

private let frameLog = Logger(subsystem: "MyEmu", category: "frames")

typealias Controller = Android_Emulation_Control_EmulatorController.Client<HTTP2ClientTransport.Posix>

enum InputEvent: Sendable {
    case touch(TouchPoint)
    case key(macKeyCode: UInt16, down: Bool)
    /// A full press of an Android navigation key (Linux evdev code), e.g. Back or Home.
    case androidKey(evdevCode: Int32)
}

enum ClientError: LocalizedError {
    case sharedMemory(String)

    var errorDescription: String? {
        switch self {
        case .sharedMemory(let step): "Could not set up shared frame memory (\(step) failed: errno \(errno))."
        }
    }
}

private let log = Logger(subsystem: "MyEmu", category: "client")

/// Talks to the engine over gRPC: frames in through shared memory, input out in order.
final class EmulatorClient: Sendable {
    /// Mid-range of the guest touchscreen's 0...1024 pressure axis.
    private static let fingerPressure: Int32 = 512

    private let grpc: GRPCClient<HTTP2ClientTransport.Posix>
    private let controller: Controller
    private let metadata: Metadata
    private let input: AsyncStream<InputEvent>.Continuation
    private let inputEvents: AsyncStream<InputEvent>

    init(port: Int, token: String) throws {
        // Loopback only; the engine also requires our token on every call.
        let transport = try HTTP2ClientTransport.Posix(
            target: .ipv4(address: "127.0.0.1", port: port), transportSecurity: .plaintext)
        grpc = GRPCClient(transport: transport)
        controller = Controller(wrapping: grpc)
        metadata = ["authorization": "Bearer \(token)"]
        (inputEvents, input) = AsyncStream.makeStream(of: InputEvent.self)
    }

    /// Runs the connection and the input pump until cancelled.
    func run() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.grpc.runConnections() }
            group.addTask { await self.pumpInput() }
            try await group.next()
            group.cancelAll()
        }
    }

    func send(_ event: InputEvent) {
        input.yield(event)
    }

    func shutdown() {
        input.finish()
        grpc.beginGracefulShutdown()
    }

    /// A single consumer keeps down/drag/up events in order.
    private func pumpInput() async {
        for await event in inputEvents {
            do {
                switch event {
                case let .touch(point):
                    var touch = Android_Emulation_Control_Touch()
                    touch.identifier = point.id
                    touch.x = point.x
                    touch.y = point.y
                    // Pressure 0 lifts the finger. Unlifted fingers expire after the engine's 120 s default.
                    touch.pressure = point.pressed ? Self.fingerPressure : 0
                    var event = Android_Emulation_Control_TouchEvent()
                    event.touches = [touch]
                    _ = try await controller.sendTouch(event, metadata: metadata)
                case let .androidKey(code):
                    var key = Android_Emulation_Control_KeyboardEvent()
                    key.codeType = .evdev
                    key.keyCode = code
                    key.eventType = .keypress
                    _ = try await controller.sendKey(key, metadata: metadata)
                case let .key(code, down):
                    var key = Android_Emulation_Control_KeyboardEvent()
                    let translated = KeyTranslation.code(forMacKey: code)
                    key.codeType = translated.type == .mac ? .mac : .evdev
                    key.keyCode = translated.code
                    key.eventType = down ? .keydown : .keyup
                    _ = try await controller.sendKey(key, metadata: metadata)
                }
            } catch {
                log.error("Input event failed: \(error.localizedDescription)")
            }
        }
    }

    /// One frame of the Android screen, scaled by the engine to `width`×`height`, written as RGBA
    /// into `buffer`. Returns the delivered size (nil if the engine sent nothing usable).
    func screenshot(into buffer: SharedFrameBuffer, width: Int, height: Int) async throws -> (width: Int, height: Int)? {
        var format = Android_Emulation_Control_ImageFormat()
        format.format = .rgba8888
        format.width = UInt32(width)
        format.height = UInt32(height)
        format.transport.channel = .mmap
        format.transport.handle = buffer.handle
        let image = try await controller.getScreenshot(format, metadata: metadata)
        let w = Int(image.format.width), h = Int(image.format.height)
        let byteCount = w * h * 4
        guard w > 0, h > 0, byteCount <= buffer.length else { return nil }
        if !image.image.isEmpty { // sent over gRPC instead of the shared memory
            guard image.image.count >= byteCount else { return nil }
            image.image.withUnsafeBytes { buffer.base.copyMemory(from: $0.baseAddress!, byteCount: byteCount) }
        }
        return (w, h)
    }

    /// Streams frames until the stream ends. The engine writes pixels straight into `buffer`
    /// (what Android Studio does) instead of sending ~10 MB per frame over gRPC.
    private static let slowFrameMs: Int64 = 40

    func streamFrames(into buffer: SharedFrameBuffer, size: DeviceSize,
                      onFrame: @escaping @Sendable (_ width: Int, _ height: Int) -> Void) async throws {
        var format = Android_Emulation_Control_ImageFormat()
        format.format = .rgba8888
        format.width = UInt32(size.width)
        format.height = UInt32(size.height)
        format.transport.channel = .mmap
        format.transport.handle = buffer.handle

        try await controller.streamScreenshot(format, metadata: metadata) { response in
            var lastArrival = ContinuousClock.now, lastStamp: UInt64 = 0
            for try await frame in response.messages {
                // Stutter diagnosis: `log stream --level debug --predicate 'category == "frames"'`.
                // engine = gap between Android/engine frame times; arrival = gap seen by MyEmu.
                let arrival = ContinuousClock.now
                let arrivalMs = (arrival - lastArrival).components.attoseconds / 1_000_000_000_000_000
                    + (arrival - lastArrival).components.seconds * 1000
                let engineMs = lastStamp == 0 ? 0 : Int64(frame.timestampUs &- lastStamp) / 1000
                if arrivalMs >= Self.slowFrameMs || engineMs >= Self.slowFrameMs {
                    frameLog.debug("slow frame: engine \(engineMs) ms, arrival \(arrivalMs) ms")
                }
                (lastArrival, lastStamp) = (arrival, frame.timestampUs)
                let w = Int(frame.format.width), h = Int(frame.format.height)
                let byteCount = w * h * 4
                guard w > 0, h > 0, byteCount <= buffer.length else { continue }
                if !frame.image.isEmpty { // engine sent pixels over gRPC instead of the shared memory
                    guard frame.image.count >= byteCount else { continue }
                    frame.image.withUnsafeBytes { buffer.base.copyMemory(from: $0.baseAddress!, byteCount: byteCount) }
                }
                onFrame(w, h)
            }
        }
    }
}
