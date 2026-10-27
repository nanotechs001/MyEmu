import AppKit

/// Draws the mapping over the Android screen as see-through MEmu-style keys, at the mapping's own
/// transparency. While editing: the selected key is highlighted and a "?" marks a spot awaiting a key.
final class KeymapOverlayView: NSView {
    static let keyRadius: CGFloat = 20
    /// While editing, keys stay visible enough to grab even at a very low transparency setting.
    private static let minEditingAlpha = 0.45

    weak var gameKeys: GameKeys? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // clicks go to the screen view

    override func draw(_ dirtyRect: NSRect) {
        guard let keys = gameKeys else { return }
        let editing = keys.isEditing
        guard editing || (keys.isEnabled && !keys.isTyping && !keys.keymap.isEmpty) else { return }
        let keymap = keys.shownKeymap
        let alpha = editing ? max(keymap.opacity, Self.minEditingAlpha) : keymap.opacity
        if editing {
            // A thin frame says "editing" without dimming the game underneath.
            NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
            let frame = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
            frame.lineWidth = 2
            frame.stroke()
        }
        if let joystick = keymap.joystick {
            drawJoystick(joystick, alpha: alpha, selected: editing && keys.selection == .joystick)
        }
        for tap in keymap.taps {
            drawKey(tap.label, at: point(tap.position), alpha: alpha, burst: tap.mode == .burst,
                    selected: editing && keys.selection == .tap(keyCode: tap.keyCode))
        }
        if editing, let pending = keys.pendingTap { drawPendingSpot(at: point(pending)) }
    }

    private func point(_ p: NormalizedPoint) -> CGPoint {
        CGPoint(x: p.x * bounds.width, y: p.y * bounds.height)
    }

    private func circle(_ center: CGPoint, _ radius: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private func drawKey(_ label: String, at center: CGPoint, alpha: CGFloat, burst: Bool, selected: Bool) {
        let key = circle(center, Self.keyRadius)
        (burst ? NSColor.systemOrange : NSColor.black).withAlphaComponent(0.45 * alpha).setFill()
        key.fill()
        (selected ? NSColor.controlAccentColor : NSColor.white).withAlphaComponent(selected ? 1 : 0.85 * alpha).setStroke()
        key.lineWidth = selected ? 3 : 1.5
        key.stroke()
        drawText(label, centeredAt: center, alpha: alpha)
        if burst { drawText("⚡︎", centeredAt: CGPoint(x: center.x, y: center.y + Self.keyRadius - 6), alpha: alpha, size: 8) }
    }

    private func drawJoystick(_ joystick: Joystick, alpha: CGFloat, selected: Bool) {
        let center = point(joystick.center)
        let radius = joystick.radius * bounds.width
        let ring = circle(center, radius)
        NSColor.black.withAlphaComponent(0.25 * alpha).setFill()
        ring.fill()
        (selected ? NSColor.controlAccentColor : NSColor.white).withAlphaComponent(selected ? 1 : 0.8 * alpha).setStroke()
        ring.lineWidth = selected ? 3 : 2
        ring.stroke()
        NSColor.white.withAlphaComponent(0.35 * alpha).setFill()
        circle(center, radius * 0.3).fill() // the thumb at rest
        for (label, dx, dy) in [("W", 0.0, -1.0), ("A", -1.0, 0.0), ("S", 0.0, 1.0), ("D", 1.0, 0.0)] {
            drawText(label, centeredAt: CGPoint(x: center.x + dx * radius * 0.68, y: center.y + dy * radius * 0.68), alpha: alpha)
        }
    }

    private func drawPendingSpot(at center: CGPoint) {
        let spot = circle(center, Self.keyRadius)
        NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
        spot.fill()
        NSColor.controlAccentColor.setStroke()
        spot.lineWidth = 2
        spot.setLineDash([4, 3], count: 2, phase: 0)
        spot.stroke()
        drawText("?", centeredAt: center, alpha: 1)
    }

    /// Dark halo so white labels read over bright game scenes too.
    private static let labelShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        return shadow
    }()

    private func drawText(_ text: String, centeredAt center: CGPoint, alpha: CGFloat, size: CGFloat? = nil) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size ?? (text.count > 2 ? 10 : 13), weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(max(alpha, 0.6)),
            .shadow: Self.labelShadow,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }
}
