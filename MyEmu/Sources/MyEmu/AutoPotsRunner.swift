import Foundation
import os
import Synchronization

private let log = Logger(subsystem: "MyEmu", category: "autopots")

/// AutoPots' fast path, off the main thread. The engine pushes every new frame (half size) into
/// shared memory; the HP is read inside that callback and the potion is tapped right away, timed on
/// a high-priority queue. Latency from Android drawing a frame to the tap: about one frame.
final class AutoPotsRunner: Sendable {
    struct Config: Sendable {
        var settings: AutoPotsSettings
        /// Running, the game is in front and nothing is being adjusted (otherwise readings only).
        var tapping: Bool
    }

    /// When potions were tapped; tap triggers yield to them.
    struct PotionClock: Sendable {
        var busyUntil = ContinuousClock.now
        var lastTap = ContinuousClock.now - .seconds(60)
    }

    let config: Mutex<Config>
    let potionClock = Mutex(PotionClock())
    /// Frames are read at 1/scale of Android's size (half on most screens: a quarter of the pixels).
    let scale: Int

    private let client: EmulatorClient
    private let frameSize: DeviceSize
    private let onReading: @Sendable (Float?) -> Void
    private let state = Mutex(State())
    private static let tapQueue = DispatchQueue(label: "MyEmu.autopots.taps", qos: .userInteractive)
    /// The drawer's HP readout is refreshed at most this often.
    private static let publishInterval: Duration = .milliseconds(100)

    private struct State {
        var lowStreak = 0
        var stuckGuard = StuckGuard()
        var lastProcessed: ContinuousClock.Instant?
        var lastPublished: ContinuousClock.Instant?
    }

    /// The orb reader is validated at half scale (autopotsCO's tests); bigger screens shrink more.
    static func scale(for device: DeviceSize) -> Int {
        max(AutoPotsRules.captureScale(width: device.width, height: device.height), 2)
    }

    init(client: EmulatorClient, device: DeviceSize, config: Config, onReading: @escaping @Sendable (Float?) -> Void) {
        self.client = client
        scale = Self.scale(for: device)
        frameSize = DeviceSize(width: device.width / scale, height: device.height / scale)
        self.config = Mutex(config)
        self.onReading = onReading
    }

    /// Streams frames until cancelled (reconnecting if the stream drops).
    func run() async {
        let buffer: SharedFrameBuffer
        do {
            buffer = try SharedFrameBuffer(capacity: frameSize.width * frameSize.height * 4)
        } catch {
            log.error("AutoPots frame memory failed: \(error.localizedDescription)")
            return
        }
        while !Task.isCancelled {
            do {
                try await client.streamFrames(into: buffer, size: frameSize) { [self] width, height in
                    process(buffer, width: width, height: height)
                }
            } catch {
                log.info("AutoPots frame stream ended, retrying: \(error.localizedDescription)")
            }
            try? await Task.sleep(for: .milliseconds(500)) // cancellation also ends the loop
        }
    }

    /// One new frame: read HP, decide, tap. Runs on the stream's thread, a fraction of a millisecond.
    private func process(_ buffer: SharedFrameBuffer, width: Int, height: Int) {
        guard width == frameSize.width, height == frameSize.height else { return } // rotated mid-change
        let config = self.config.withLock { $0 }
        let now = ContinuousClock.now
        let interval = config.settings.scanIntervalMs
        let due = state.withLock { s in
            if interval > 0, let last = s.lastProcessed, now - last < .milliseconds(interval) { return false }
            s.lastProcessed = now
            return true
        }
        guard due else { return }

        let frame = RGBAFrame(width: width, height: height,
                              pixels: UnsafeRawBufferPointer(start: buffer.base, count: width * height * 4))
        let value = Self.read(frame, config.settings, scale: scale)
        let busyUntil = potionClock.withLock { $0.busyUntil }
        let (fire, publish) = state.withLock { s -> (Bool, Bool) in
            var fire = false
            if let value, value < AutoPotsRules.triggerLevel {
                s.lowStreak += 1
                let firing = config.tapping && s.lowStreak >= config.settings.confirmReadings
                let stuck = s.stuckGuard.isStuck(reading: value, now: now, tapping: firing)
                fire = firing && !stuck && now >= busyUntil
            } else {
                s.lowStreak = 0
                s.stuckGuard.reset()
            }
            let publish = s.lastPublished.map { now - $0 >= Self.publishInterval } ?? true
            if publish { s.lastPublished = now }
            return (fire, publish)
        }
        if fire, let potion = config.settings.potion { tapPotion(at: potion, config.settings) }
        if publish { onReading(value) }
    }

    /// Remaining HP (0…1) in the configured view, or nil when it can't be read.
    static func read<F: PixelFrame>(_ frame: F, _ settings: AutoPotsSettings, scale: Int) -> Float? {
        let value: Float
        switch settings.view {
        case .orb:
            guard let box = settings.orbBox else { return nil }
            value = HpDetector.hpFractionArc(frame, box.x / scale, box.y / scale, box.width / scale, box.height / scale,
                                             darkMax: settings.customDarkMax ?? HpDetector.darkMax)
        case .simple:
            guard let box = settings.simpleBox, let signature = SimpleHp.decode(settings.simpleSignature) else { return nil }
            value = SimpleHp.match(frame, box.x, box.y, box.width, box.height, scale: scale, signature: signature,
                                   signatureWidth: box.width / scale, signatureHeight: box.height / scale)
        }
        return value < 0 ? nil : value
    }

    /// The potion burst: the first press goes out immediately, the rest are timed on the tap queue.
    private func tapPotion(at potion: PixelPoint, _ settings: AutoPotsSettings) {
        let count = min(max(settings.clicksPerBurst, 1), AutoPotsSettings.burstRange.upperBound)
        let press = AutoPotsRules.pressMs(settings.pressMs)
        let now = ContinuousClock.now
        potionClock.withLock {
            $0.lastTap = now
            $0.busyUntil = now + .milliseconds(AutoPotsRules.burstBusyMs(count: count, pressMs: press))
        }
        let client = self.client
        let start = DispatchTime.now()
        for i in 0..<count {
            let r = settings.tapRandomPx
            let x = Int32(potion.x + (r > 0 ? Int.random(in: -r...r) : 0))
            let y = Int32(potion.y + (r > 0 ? Int.random(in: -r...r) : 0))
            let downAt = start + .milliseconds(i * (press + AutoPotsRules.burstGapMs))
            let down = InputEvent.touch(TouchPoint(id: AutoPots.potionFingerID, x: x, y: y, pressed: true))
            let up = InputEvent.touch(TouchPoint(id: AutoPots.potionFingerID, x: x, y: y, pressed: false))
            if i == 0 { client.send(down) } else { Self.tapQueue.asyncAfter(deadline: downAt) { client.send(down) } }
            Self.tapQueue.asyncAfter(deadline: downAt + .milliseconds(press)) { client.send(up) }
        }
    }
}
