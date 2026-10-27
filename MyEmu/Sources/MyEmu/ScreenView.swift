import AppKit
import Synchronization
import Metal
import os
import QuartzCore
import SwiftUI

private let log = Logger(subsystem: "MyEmu", category: "screen")
private let frameLog = Logger(subsystem: "MyEmu", category: "frames")

/// Hands "a new frame is in shared memory" from the gRPC thread to the display link, lock-free.
/// Only the newest frame matters: the shared memory always holds the latest pixels.
final class FrameSignal: Sendable {
    private let pending = Atomic(false)
    private let packedSize = Atomic<UInt64>(0)

    func post(width: Int, height: Int) {
        packedSize.store(UInt64(width) << 32 | UInt64(height), ordering: .relaxed)
        pending.store(true, ordering: .releasing)
    }

    /// The newest frame's size if one arrived since the last call.
    func take() -> (width: Int, height: Int)? {
        guard pending.exchange(false, ordering: .acquiring) else { return nil }
        let packed = packedSize.load(ordering: .relaxed)
        return (Int(packed >> 32), Int(packed & 0xFFFF_FFFF))
    }
}

/// Draws engine frames with Metal straight from the shared frame memory (aspect-fit), shows an
/// FPS counter, and turns mouse, trackpad and keyboard into Android input.
final class ScreenView: NSView {
    var client: EmulatorClient?
    let frameSignal = FrameSignal()
    var deviceSize: DeviceSize? {
        didSet { needsLayout = true }
    }
    /// 1 = Android's colors exactly; lower blends toward gray for a softer picture.
    var colorIntensity: Float = 1 {
        didSet { applyColorIntensity() }
    }
    /// Mac key codes Android has been told are pressed and not yet released.
    private var keysHeldInAndroid: Set<UInt16> = []
    var showsFPS = true {
        didSet { fpsLabel.isHidden = !showsFPS }
    }
    var gameKeys: GameKeys? {
        didSet {
            overlay.gameKeys = gameKeys
            gameKeys?.onChange = { [weak self] in self?.overlay.needsDisplay = true }
        }
    }

    /// Mouse-wheel line → view points of finger travel.
    /// shortcut: fixed value picked by feel, make it a setting if wheels scroll too fast/slow.
    private static let pointsPerWheelLine: CGFloat = 40
    /// A wheel has no "gesture ended" phase, so lift the virtual finger after this much quiet.
    private static let wheelLiftDelay: TimeInterval = 0.12

    private let device = MTLCreateSystemDefaultDevice()
    private let queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private var frames: SharedFrameBuffer?
    private var frameMetalBuffer: MTLBuffer?
    private var texture: MTLTexture?
    /// The engine's own Metal layer showing Android (MuMu-style direct display), when available.
    private var hostLayer: CALayer?
    private var directDisplay: DirectDisplay?
    private var lastPresents: UInt64 = 0
    private var lastSlowPresents: UInt64 = 0

    private let overlay = KeymapOverlayView()
    private let autoPotsOverlay = AutoPotsOverlayView()
    var autoPots: AutoPots? {
        didSet {
            autoPotsOverlay.autoPots = autoPots
            autoPots?.onChange = { [weak self] in self?.autoPotsOverlay.needsDisplay = true }
        }
    }
    /// An AutoPots box, dot or trigger being dragged in its editor.
    private var autoPotsGrab: AutoPots.Grab?
    /// The mouse is holding a tap trigger (its taps replace the mouse's own touch).
    private var holdingTrigger = false
    private let fpsLabel = NSTextField(labelWithString: "")
    private var framesThisSecond = 0
    private var fpsTimer: Timer?
    private var displayLink: CADisplayLink?

    private var mouseIsDown = false
    /// The key or joystick being dragged in the editor.
    private var draggedBinding: BindingRef?
    /// Scrolling is a virtual finger drag (the phone image has no wheel device); view coordinates.
    private var scrollFinger: (start: CGPoint, current: CGPoint)?
    private var scrollLiftTimer: Timer?

    override var isFlipped: Bool { true } // top-left origin, same as Android
    override var acceptsFirstResponder: Bool { true }
    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    override init(frame: NSRect) {
        queue = device?.makeCommandQueue()
        do {
            pipeline = try device.map(Self.makePipeline)
        } catch {
            log.error("Metal pipeline failed: \(error.localizedDescription)")
            pipeline = nil
        }
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        addSubview(overlay)
        addSubview(autoPotsOverlay)
        fpsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        fpsLabel.textColor = .white
        fpsLabel.drawsBackground = true
        fpsLabel.backgroundColor = NSColor.black.withAlphaComponent(0.5)
        fpsLabel.stringValue = pipeline == nil ? "Metal unavailable" : ""
        addSubview(fpsLabel)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.framebufferOnly = true
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }

    /// Wraps the shared frame memory in a Metal buffer once; textures are views onto it.
    func attach(_ frames: SharedFrameBuffer) {
        self.frames = frames
        frameMetalBuffer = device?.makeBuffer(bytesNoCopy: frames.base, length: frames.length,
                                              options: .storageModeShared, deallocator: nil)
        texture = nil
        if frameMetalBuffer == nil { log.error("Could not wrap shared frame memory in a Metal buffer") }
    }

    /// Shows the engine's screen layer (Core Animation context `contextId`) instead of streamed
    /// frames; nil goes back to streamed frames.
    func showDirect(contextId: UInt32?, display: DirectDisplay?) {
        hostLayer?.removeFromSuperlayer()
        hostLayer = nil
        directDisplay = display
        lastPresents = display?.presents ?? 0
        lastSlowPresents = display?.slowPresents ?? 0
        guard let contextId, let hostClass = NSClassFromString("CALayerHost") as? CALayer.Type else { return }
        let host = hostClass.init()
        host.setValue(contextId, forKey: "contextId")
        host.anchorPoint = .zero
        layerUsesCoreImageFilters = true
        layer?.insertSublayer(host, at: 0) // under the game-key overlay
        hostLayer = host
        texture = nil
        applyColorIntensity()
        needsLayout = true
    }

    /// Same look as the shader's blend toward gray, done by the window server on the hosted layer.
    private func applyColorIntensity() {
        hostLayer?.filters = colorIntensity < 1
            ? [CIFilter(name: "CIColorControls", parameters: ["inputSaturation": colorIntensity])].compactMap { $0 }
            : nil
    }

    /// Runs once per refresh of the screen the window is on; draws only if a new frame arrived.
    @objc private func displayRefresh(_ link: CADisplayLink) {
        guard let size = frameSignal.take() else { return }
        showFrame(width: size.width, height: size.height)
    }

    private func showFrame(width: Int, height: Int) {
        guard let device, let frameMetalBuffer else { return }
        if texture?.width != width || texture?.height != height {
            let bytesPerRow = width * 4
            guard bytesPerRow % device.minimumLinearTextureAlignment(for: .rgba8Unorm) == 0 else {
                log.error("Frame width \(width) breaks Metal row alignment; skipping")
                return
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = .shaderRead
            texture = frameMetalBuffer.makeTexture(descriptor: descriptor, offset: 0, bytesPerRow: bytesPerRow)
        }
        framesThisSecond += 1
        render()
    }

    private func render() {
        guard let metalLayer, let texture, let pipeline, let queue,
              metalLayer.drawableSize.width > 0,
              let drawable = metalLayer.nextDrawable(),
              let commands = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        let fit = aspectFitRect(content: CGSize(width: texture.width, height: texture.height),
                                in: metalLayer.drawableSize)
        encoder.setViewport(MTLViewport(originX: fit.minX, originY: fit.minY, width: fit.width,
                                        height: fit.height, znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        var intensity = colorIntensity
        encoder.setFragmentBytes(&intensity, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        if metalLayer.presentsWithTransaction {
            // Live resize: show the frame in the same Core Animation transaction as the new window size.
            commands.commit()
            commands.waitUntilScheduled()
            drawable.present()
        } else {
            commands.present(drawable)
            commands.commit()
        }
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        metalLayer?.contentsScale = scale
        metalLayer?.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        overlay.frame = deviceSize.map {
            aspectFitRect(content: CGSize(width: $0.width, height: $0.height), in: bounds.size)
        } ?? bounds
        autoPotsOverlay.frame = overlay.frame
        autoPotsOverlay.deviceSize = deviceSize
        if let hostLayer, let deviceSize { // the engine's layer is Android-sized, one point per pixel
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostLayer.position = overlay.frame.origin
            hostLayer.transform = CATransform3DMakeScale(overlay.frame.width / CGFloat(deviceSize.width),
                                                         overlay.frame.height / CGFloat(deviceSize.height), 1)
            CATransaction.commit()
        }
        let labelSize = fpsLabel.intrinsicContentSize
        fpsLabel.frame = CGRect(x: bounds.width - labelSize.width - 8, y: 8,
                                width: labelSize.width, height: labelSize.height)
        render()
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        metalLayer?.presentsWithTransaction = true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        metalLayer?.presentsWithTransaction = false
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        if let newWindow {
            // A key released while another window has focus never reaches us: lift game-key fingers now.
            NotificationCenter.default.addObserver(self, selector: #selector(windowLostFocus),
                                                   name: NSWindow.didResignKeyNotification, object: newWindow)
        }
    }

    @objc private func windowLostFocus() {
        gameKeys?.releaseAll()
        if holdingTrigger { autoPots?.releaseTrigger(); holdingTrigger = false }
        // Same for keys sent to Android: ⌘⇧4 handed the Shift release to the screenshot tool, and
        // Android kept Shift held, so everything typed came out in capitals and symbols.
        keysHeldInAndroid.forEach { client?.send(.key(macKeyCode: $0, down: false)) }
        keysHeldInAndroid = []
    }

    /// The AutoPots hotkey works anywhere in this window, also while a drawer has the keyboard.
    private var hotkeyMonitor: Any?

    private func watchAutoPotsHotkey() {
        if let hotkeyMonitor { NSEvent.removeMonitor(hotkeyMonitor) }
        hotkeyMonitor = nil
        guard window != nil else { return }
        hotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window, !event.isARepeat,
                  let autoPots = self.autoPots else { return event }
            let typing = window.firstResponder is NSText // a text field in MyEmu's own panels
            let used = autoPots.handleKey(keyCode: event.keyCode, flags: event.modifierFlags,
                                          characters: event.charactersIgnoringModifiers, typingInMac: typing)
            return used ? nil : event
        }
    }

    override func viewDidMoveToWindow() {
        watchAutoPotsHotkey()
        window?.makeFirstResponder(self)
        displayLink?.invalidate()
        displayLink = nil
        if window != nil {
            // Follows the window across screens, so it ticks at 180 Hz on a 180 Hz monitor.
            let link = displayLink(target: self, selector: #selector(displayRefresh))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        guard window != nil, fpsTimer == nil else { return }
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFPS() }
        }
    }

    /// Android only sends frames when the screen changes, so a still screen reads 0 fps.
    private func updateFPS() {
        guard pipeline != nil else { return }
        if let directDisplay {
            let presents = directDisplay.presents, slow = directDisplay.slowPresents
            framesThisSecond = Int(presents &- lastPresents)
            // Same log line the stream path writes, so scripts/stress-test.sh keeps counting them.
            for _ in 0..<(slow &- lastSlowPresents) { frameLog.debug("slow frame: present gap ≥ 40 ms") }
            (lastPresents, lastSlowPresents) = (presents, slow)
        }
        fpsLabel.stringValue = " \(framesThisSecond) fps "
        autoPotsOverlay.needsDisplay = true // trigger lock state changes without a settings change
        framesThisSecond = 0
        needsLayout = true
    }

    // MARK: Input

    private var isEditingKeys: Bool { gameKeys?.isEditing == true }

    /// The event's position in Android screen pixels.
    private func devicePixel(_ event: NSEvent, clamped: Bool = false) -> PixelPoint? {
        guard let deviceSize, let p = normalizedPoint(event, clamped: clamped) else { return nil }
        return PixelPoint(x: Int(p.x * Double(deviceSize.width)), y: Int(p.y * Double(deviceSize.height)))
    }

    /// AutoPots gets the click first: its editor while adjusting, or a tap trigger under the mouse.
    private func autoPotsMouseDown(_ event: NSEvent) -> Bool {
        guard let autoPots, !isEditingKeys else { return false }
        if autoPots.editing != nil {
            autoPotsGrab = devicePixel(event).flatMap { autoPots.editorPress(at: $0) }
            return true // while adjusting, clicks never reach the game
        }
        guard let p = devicePixel(event), let trigger = autoPots.trigger(at: p) else { return false }
        autoPots.pressTrigger(trigger)
        holdingTrigger = true
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self) // take keys back from the settings panel
        if autoPotsMouseDown(event) { return }
        guard isEditingKeys else { return sendMouse(event, pressed: true) }
        guard let keys = gameKeys, let point = normalizedPoint(event) else { return }
        let placeJoystick = event.modifierFlags.contains(.option)
        let hit = binding(at: point)
        keys.editorPress(at: point, on: hit, placeJoystick: placeJoystick)
        draggedBinding = placeJoystick ? .joystick : hit // press on a key and drag to move it
    }

    override func mouseDragged(with event: NSEvent) {
        if let autoPotsGrab {
            if let p = devicePixel(event, clamped: true) { autoPots?.editorDrag(autoPotsGrab, to: p) }
            return
        }
        if holdingTrigger || autoPots?.editing != nil { return }
        guard isEditingKeys else { return sendMouse(event, pressed: true) }
        if let draggedBinding, let point = normalizedPoint(event, clamped: true) {
            gameKeys?.editorDrag(draggedBinding, to: point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let grab = autoPotsGrab {
            autoPots?.editorRelease(grab)
            autoPotsGrab = nil
            return
        }
        if holdingTrigger {
            autoPots?.releaseTrigger()
            holdingTrigger = false
            return
        }
        if autoPots?.editing != nil { return }
        guard isEditingKeys else { return sendMouse(event, pressed: false) }
        draggedBinding = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isEditingKeys, let point = normalizedPoint(event) else { return super.rightMouseDown(with: event) }
        if let hit = binding(at: point) { gameKeys?.editorRemove(hit) }
    }

    /// The key or joystick drawn under a point (keys are a fixed size on screen).
    private func binding(at point: NormalizedPoint) -> BindingRef? {
        let frame = overlay.frame
        guard frame.width > 0, frame.height > 0 else { return nil }
        let radius = KeymapOverlayView.keyRadius
        return gameKeys?.shownKeymap.binding(at: point, keyRadius: (radius / frame.width, radius / frame.height),
                                             aspect: frame.width / frame.height)
    }

    override func keyDown(with event: NSEvent) {
        if gameKeys?.handleKey(event, down: true) == true { return }
        sendKey(event.keyCode, down: true)
    }

    override func keyUp(with event: NSEvent) {
        if gameKeys?.handleKey(event, down: false) == true { return }
        sendKey(event.keyCode, down: false)
    }

    /// Remembers what Android has held, so `windowLostFocus` can let go of it.
    private func sendKey(_ keyCode: UInt16, down: Bool) {
        guard let client else { return }
        client.send(.key(macKeyCode: keyCode, down: down))
        if down { keysHeldInAndroid.insert(keyCode) } else { keysHeldInAndroid.remove(keyCode) }
    }

    /// Shift, Control, Option and Caps Lock never come as key presses on the Mac, only as this.
    override func flagsChanged(with event: NSEvent) {
        guard let client, gameKeys?.isEditing != true else { return }
        if event.keyCode == KeyTranslation.capsLock {
            // Each change is one press of the key; Android toggles its own Caps Lock on it.
            client.send(.key(macKeyCode: event.keyCode, down: true))
            client.send(.key(macKeyCode: event.keyCode, down: false))
        } else if let down = KeyTranslation.modifierIsDown(keyCode: event.keyCode,
                                                          modifierFlags: event.modifierFlags.rawValue) {
            sendKey(event.keyCode, down: down)
        }
    }

    /// The event's position as a fraction of the Android screen; outside it, nil (or the nearest
    /// edge when `clamped`, so a dragged key stops at the edge).
    private func normalizedPoint(_ event: NSEvent, clamped: Bool = false) -> NormalizedPoint? {
        let p = convert(event.locationInWindow, from: nil)
        let frame = overlay.frame
        guard frame.width > 0, frame.height > 0, clamped || frame.contains(p) else { return nil }
        let x = (p.x - frame.minX) / frame.width, y = (p.y - frame.minY) / frame.height
        return NormalizedPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    override func scrollWheel(with event: NSEvent) {
        guard !mouseIsDown, !isEditingKeys else { return }
        if event.phase == .ended || event.phase == .cancelled {
            liftScrollFinger() // lift while still moving so Android flings on its own
            return
        }
        guard event.momentumPhase.isEmpty else { return } // ignore macOS momentum; Android does its own
        let precise = event.hasPreciseScrollingDeltas
        let step = precise ? 1 : Self.pointsPerWheelLine
        // macOS deltas already point the way content should move, which is the way a finger drags.
        let delta = CGPoint(x: event.scrollingDeltaX * step, y: event.scrollingDeltaY * step)
        guard delta != .zero else { return }

        if scrollFinger == nil {
            let start = convert(event.locationInWindow, from: nil)
            guard sendTouch(at: start, pressed: true) else { return }
            scrollFinger = (start, start)
        }
        guard var finger = scrollFinger else { return }
        finger.current.x += delta.x
        finger.current.y += delta.y
        if !sendTouch(at: finger.current, pressed: true) {
            // Ran off the screen edge: lift and keep scrolling with a fresh finger from the start point.
            liftScrollFinger()
            guard sendTouch(at: finger.start, pressed: true) else { return }
            finger.current = finger.start
        }
        scrollFinger = finger

        if !precise {
            scrollLiftTimer?.invalidate()
            scrollLiftTimer = Timer.scheduledTimer(withTimeInterval: Self.wheelLiftDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.liftScrollFinger() }
            }
        }
    }

    private func liftScrollFinger() {
        scrollLiftTimer?.invalidate()
        scrollLiftTimer = nil
        guard let finger = scrollFinger else { return }
        scrollFinger = nil
        if !sendTouch(at: finger.current, pressed: false) {
            liftMouseFinger()
        }
    }

    private func liftMouseFinger() {
        client?.send(.touch(TouchPoint(id: KeyTouchMapper.mouseFingerID, x: 0, y: 0, pressed: false)))
    }

    /// Sends a touch at a view point; false when the point is outside the Android screen.
    @discardableResult
    private func sendTouch(at point: CGPoint, pressed: Bool) -> Bool {
        guard let client, let p = deviceSize?.devicePoint(for: point, in: bounds.size) else { return false }
        client.send(.touch(TouchPoint(id: KeyTouchMapper.mouseFingerID, x: p.x, y: p.y, pressed: pressed)))
        return true
    }

    private func sendMouse(_ event: NSEvent, pressed: Bool) {
        liftScrollFinger()
        mouseIsDown = pressed
        guard !sendTouch(at: convert(event.locationInWindow, from: nil), pressed: pressed), !pressed else { return }
        // Released outside the screen: still lift the finger so Android doesn't see a stuck touch.
        liftMouseFinger()
    }

    // MARK: Metal pipeline

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position [[position]]; float2 uv; };
    vertex Vertex screen_vertex(uint id [[vertex_id]]) {
        float2 p = float2((id & 1) ? 1.0 : -1.0, (id & 2) ? -1.0 : 1.0); // strip: TL, TR, BL, BR
        Vertex out;
        out.position = float4(p, 0.0, 1.0);
        out.uv = float2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);
        return out;
    }
    fragment float4 screen_fragment(Vertex in [[stage_in]], texture2d<float> frame [[texture(0)]],
                                    constant float &intensity [[buffer(0)]]) {
        constexpr sampler linear(filter::linear, address::clamp_to_edge);
        float3 color = frame.sample(linear, in.uv).rgb;
        float luma = dot(color, float3(0.2126, 0.7152, 0.0722)); // Rec. 709 / sRGB brightness
        return float4(mix(float3(luma), color, intensity), 1.0);
    }
    """

    private static func makePipeline(device: MTLDevice) throws -> MTLRenderPipelineState {
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "screen_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "screen_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}

struct ScreenRepresentable: NSViewRepresentable {
    let view: ScreenView
    func makeNSView(context: Context) -> ScreenView { view }
    func updateNSView(_ nsView: ScreenView, context: Context) {}
}
