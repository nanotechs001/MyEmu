import AppKit

/// The window size nearest `proposed` whose Android area has `aspect` (width ÷ height).
/// `chrome` is the rest of the window (sidebar, drawer, title bar). Dragging a side edge or the
/// bottom edge drives that dimension. On a corner, the dimension that has changed more since the
/// drag `start` drives, measured from the start so the choice can't flip-flop mid-drag (jitter).
func aspectLockedSize(proposed: CGSize, current: CGSize, start: CGSize, chrome: CGSize, aspect: CGFloat,
                      minScreenHeight: CGFloat) -> CGSize {
    let draggingWidth: Bool
    if proposed.height == current.height {
        draggingWidth = true // side edge: the system keeps our last height
    } else if proposed.width == current.width {
        draggingWidth = false // top/bottom edge
    } else {
        // Compare how much the Android area would scale each way (the sidebar doesn't scale).
        let widthScale = (proposed.width - chrome.width) / max(start.width - chrome.width, 1)
        let heightScale = (proposed.height - chrome.height) / max(start.height - chrome.height, 1)
        draggingWidth = abs(widthScale - 1) >= abs(heightScale - 1)
    }
    let screenHeight = max(draggingWidth ? (proposed.width - chrome.width) / aspect : proposed.height - chrome.height,
                           minScreenHeight)
    return CGSize(width: (screenHeight * aspect).rounded() + chrome.width,
                  height: screenHeight.rounded() + chrome.height)
}

/// Keeps the Android area at the screen's shape while the window is resized or zoomed, so there
/// are no black bars. Sits in front of SwiftUI's own window delegate and forwards everything else.
@MainActor
final class AspectLockingWindowDelegate: NSObject, NSWindowDelegate {
    /// Tall enough for the sidebar icons.
    static let minScreenHeight: CGFloat = 300

    /// Strong on purpose: a window holds its delegate weakly, and we replace SwiftUI's.
    nonisolated(unsafe) private let swiftUIDelegate: (any NSWindowDelegate)?
    private weak var screenView: NSView?
    /// Android screen width ÷ height; nil leaves resizing alone.
    var aspect: CGFloat?
    /// The window size when the current drag began.
    private var dragStart: CGSize?

    init(window: NSWindow, screenView: NSView) {
        swiftUIDelegate = window.delegate
        self.screenView = screenView
        super.init()
        window.delegate = self
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let proposed = swiftUIDelegate?.windowWillResize?(sender, to: frameSize) ?? frameSize
        guard let aspect, let chrome = chrome(of: sender) else { return proposed }
        return aspectLockedSize(proposed: proposed, current: sender.frame.size, start: dragStart ?? sender.frame.size,
                                chrome: chrome, aspect: aspect, minScreenHeight: Self.minScreenHeight)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        dragStart = (notification.object as? NSWindow)?.frame.size
        swiftUIDelegate?.windowWillStartLiveResize?(notification)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        dragStart = nil
        swiftUIDelegate?.windowDidEndLiveResize?(notification)
    }

    /// The green zoom button: the largest bar-free size that fits the screen.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        let standard = swiftUIDelegate?.windowWillUseStandardFrame?(window, defaultFrame: newFrame) ?? newFrame
        guard let aspect, let chrome = chrome(of: window) else { return standard }
        let room = CGSize(width: standard.width - chrome.width, height: standard.height - chrome.height)
        let screen = aspectFitRect(content: CGSize(width: aspect, height: 1), in: room).size
        let size = CGSize(width: screen.width + chrome.width, height: screen.height + chrome.height)
        return NSRect(x: standard.midX - size.width / 2, y: standard.maxY - size.height,
                      width: size.width, height: size.height)
    }

    private func chrome(of window: NSWindow) -> CGSize? {
        guard let screenView, screenView.bounds.height > 0 else { return nil }
        return CGSize(width: window.frame.width - screenView.bounds.width,
                      height: window.frame.height - screenView.bounds.height)
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || swiftUIDelegate?.responds(to: aSelector) == true
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        swiftUIDelegate?.responds(to: aSelector) == true ? swiftUIDelegate : super.forwardingTarget(for: aSelector)
    }
}
