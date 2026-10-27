import AppKit

/// Draws AutoPots over the game: the HP box and potion dot while calibrating, and the tap triggers.
/// Clicks go to the screen view, which hands them to AutoPots (editor or trigger presses).
final class AutoPotsOverlayView: NSView {
    weak var autoPots: AutoPots?
    var deviceSize: DeviceSize?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static let triggerColors: [NSColor] = [
        NSColor(red: 1, green: 0.35, blue: 0.37, alpha: 1), NSColor(red: 0.24, green: 0.86, blue: 0.59, alpha: 1),
        NSColor(red: 0.3, green: 0.64, blue: 1, alpha: 1), NSColor(red: 1, green: 0.76, blue: 0.28, alpha: 1),
        NSColor(red: 0.73, green: 0.49, blue: 1, alpha: 1)]

    static func color(forTrigger id: Int) -> NSColor { triggerColors[(id - 1) % triggerColors.count] }

    override func draw(_ dirtyRect: NSRect) {
        guard let autoPots, let deviceSize, deviceSize.width > 0 else { return }
        let scale = bounds.width / CGFloat(deviceSize.width)
        let settings = autoPots.settings
        if autoPots.editing == .calibration {
            if let box = settings.view == .orb ? settings.orbBox : settings.simpleBox {
                drawBox(box, scale: scale, orb: settings.view == .orb)
            }
            if let potion = settings.potion { drawPotion(potion, scale: scale) }
        }
        let editingTriggers = autoPots.editing == .triggers
        guard settings.showTriggers || editingTriggers, autoPots.editing != .calibration else { return }
        for trigger in settings.triggers {
            drawTrigger(trigger, scale: scale, selected: editingTriggers && autoPots.selectedTrigger == trigger.id,
                        active: autoPots.latchedTrigger == trigger.id, editing: editingTriggers)
        }
    }

    private func rect(_ r: PixelRect, _ scale: CGFloat) -> CGRect {
        CGRect(x: CGFloat(r.x) * scale, y: CGFloat(r.y) * scale, width: CGFloat(r.width) * scale, height: CGFloat(r.height) * scale)
    }

    private func drawBox(_ box: PixelRect, scale: CGFloat, orb: Bool) {
        let r = rect(box, scale)
        // The orb box covers the red half: drawn as autopotsCO's half-ellipse; text is a plain box.
        let path = orb ? halfEllipse(in: r) : NSBezierPath(rect: r)
        NSColor.systemRed.withAlphaComponent(0.18).setFill()
        path.fill()
        NSColor.systemRed.setStroke()
        path.lineWidth = 2
        path.stroke()
        // Resize handle at the bottom right.
        let handle = NSBezierPath(ovalIn: CGRect(x: r.maxX - 6, y: r.maxY - 6, width: 12, height: 12))
        NSColor.white.setFill()
        handle.fill()
        NSColor.systemRed.setStroke()
        handle.stroke()
    }

    /// The left half of an ellipse filling `r` (the orb's red half).
    private func halfEllipse(in r: CGRect) -> NSBezierPath {
        let path = NSBezierPath()
        let steps = 24
        for i in 0...steps {
            let angle = CGFloat.pi / 2 + CGFloat.pi * CGFloat(i) / CGFloat(steps) // top → left → bottom
            let p = CGPoint(x: r.maxX + cos(angle) * r.width, y: r.midY - sin(angle) * r.height / 2)
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        path.close()
        return path
    }

    private func drawPotion(_ p: PixelPoint, scale: CGFloat) {
        let c = CGPoint(x: CGFloat(p.x) * scale, y: CGFloat(p.y) * scale)
        let dot = NSBezierPath(ovalIn: CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18))
        NSColor.systemGreen.withAlphaComponent(0.85).setFill()
        dot.fill()
        NSColor.white.setStroke()
        dot.lineWidth = 2
        dot.stroke()
    }

    private func drawTrigger(_ t: TapTrigger, scale: CGFloat, selected: Bool, active: Bool, editing: Bool) {
        let d = CGFloat(t.size) * scale
        let r = CGRect(x: CGFloat(t.center.x) * scale - d / 2, y: CGFloat(t.center.y) * scale - d / 2, width: d, height: d)
        // Transparency applies while playing; while editing, every trigger stays clearly visible.
        let alpha = editing ? 0.85 : max(1 - CGFloat(t.transparency) / 100, 0.04)
        let color = Self.color(forTrigger: t.id)
        let circle = NSBezierPath(ovalIn: r)
        color.withAlphaComponent(alpha * (active ? 0.7 : 0.35)).setFill()
        circle.fill()
        (selected ? NSColor.white : color).withAlphaComponent(alpha).setStroke()
        circle.lineWidth = selected ? 3 : 2
        circle.stroke()
        let label = NSAttributedString(string: "\(t.id)", attributes: [
            .font: NSFont.systemFont(ofSize: max(d * 0.38, 10), weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha)])
        let size = label.size()
        label.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
    }
}

/// Dragging the HP box, potion dot and triggers (screen view mouse events, in Android pixels).
extension AutoPots {
    private static let handleRadius = 14
    private static let potionRadius = 14

    enum Grab: Equatable {
        case moveBox(dx: Int, dy: Int)
        case resizeBox
        case potion
        case trigger(id: Int, dx: Int, dy: Int)
    }

    /// Starts a drag if the press hits something being edited. Nil when not editing or nothing hit.
    func editorPress(at p: PixelPoint) -> Grab? {
        switch editing {
        case .calibration:
            if let potion = settings.potion, abs(p.x - potion.x) <= Self.potionRadius, abs(p.y - potion.y) <= Self.potionRadius {
                return .potion
            }
            guard let box = currentBox else { return nil }
            if abs(p.x - (box.x + box.width)) <= Self.handleRadius, abs(p.y - (box.y + box.height)) <= Self.handleRadius {
                return .resizeBox
            }
            return box.contains(p) ? .moveBox(dx: p.x - box.x, dy: p.y - box.y) : nil
        case .triggers:
            guard let t = settings.triggers.last(where: { $0.contains(p) }) else {
                selectedTrigger = nil
                return nil
            }
            selectedTrigger = t.id
            return .trigger(id: t.id, dx: p.x - t.center.x, dy: p.y - t.center.y)
        case nil:
            return nil
        }
    }

    func editorDrag(_ grab: Grab, to p: PixelPoint) {
        switch grab {
        case .potion:
            if settings.view == .orb { settings.orbPotion = p } else { settings.simplePotion = p }
        case .moveBox(let dx, let dy):
            guard var box = currentBox else { return }
            (box.x, box.y) = (p.x - dx, p.y - dy)
            currentBox = box
        case .resizeBox:
            guard var box = currentBox else { return }
            box.width = max(p.x - box.x, 12) // autopotsCO's minimum region size
            box.height = max(p.y - box.y, 12)
            currentBox = box
        case .trigger(let id, let dx, let dy):
            updateTrigger(id) { $0.center = PixelPoint(x: p.x - dx, y: p.y - dy) }
        }
    }

    /// After a box moved by hand in simple view, the old "100%" template no longer fits.
    func editorRelease(_ grab: Grab) {
        if settings.view == .simple, grab == .resizeBox || { if case .moveBox = grab { true } else { false } }() {
            message = "Box moved: with HP full, click \"Retake HP template\"."
        }
    }

    private var currentBox: PixelRect? {
        get { settings.view == .orb ? settings.orbBox : settings.simpleBox }
        set { if settings.view == .orb { settings.orbBox = newValue } else { settings.simpleBox = newValue } }
    }
}
