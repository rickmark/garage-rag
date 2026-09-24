import AppKit
import SwiftUI

/// The main window's size follows what it shows. The setup assistant opens at `assistantSize`, also
/// when it opens in a window of another size (the relaunch after "Reset Database", which restores the
/// last frame, or "Setup Assistant…"). When it closes the window grows (animated) to `workingSize` if
/// it is smaller than that.
enum MainWindowSizing {
    /// The smallest content size the window allows, on any page.
    static let minimumSize = NSSize(width: 760, height: 520)

    /// The setup assistant's content size, between the minimum and 1.5× it: wide enough for three
    /// columns of locations on the data page (220-point step rail, 32-point page padding, three cards
    /// of at least 200 points, `FirstRunSelectDataPage.columns`), and tall enough to show each page
    /// without clipping at the bottom.
    static let assistantSize = NSSize(width: 920, height: 650)

    /// Roomy enough for Sources, Documents and Search side by side with the sidebar.
    static let workingSize = NSSize(width: 1100, height: 760)

    /// The frame to grow to from `current`, or nil when the window is already at least that big.
    /// The window keeps its centre where it can, never shrinks, and stays inside `visible` (the
    /// screen's visible frame, in the same coordinates).
    static func frameAfterFirstRun(current: NSRect, visible: NSRect, target: NSSize = workingSize) -> NSRect? {
        let width = min(max(current.width, target.width), visible.width)
        let height = min(max(current.height, target.height), visible.height)
        guard width > current.width || height > current.height else { return nil }
        return centred(width: width, height: height, around: current, in: visible)
    }

    /// The frame for the setup assistant from `current` (a frame size, title bar included), or nil when
    /// the window is already that size. The window keeps its centre and stays inside `visible`, which
    /// also caps the size on a small screen.
    static func frameForFirstRun(current: NSRect, visible: NSRect, target: NSSize) -> NSRect? {
        let width = min(target.width, visible.width)
        let height = min(target.height, visible.height)
        guard abs(width - current.width) >= 1 || abs(height - current.height) >= 1 else { return nil }
        return centred(width: width, height: height, around: current, in: visible)
    }

    @MainActor
    static func growAfterFirstRun(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen), !window.isZoomed,
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame,
              let frame = frameAfterFirstRun(current: window.frame, visible: visible)
        else { return }
        window.setFrame(frame, display: true, animate: true)
    }

    @MainActor
    static func sizeForFirstRun(_ window: NSWindow) {
        // `assistantSize` is a content size; the frame adds the title bar.
        let target = window.frameRect(forContentRect: NSRect(origin: .zero, size: assistantSize)).size
        guard !window.styleMask.contains(.fullScreen),
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame,
              let frame = frameForFirstRun(current: window.frame, visible: visible, target: target)
        else { return }
        window.setFrame(frame, display: true, animate: true)
    }

    private static func centred(width: CGFloat, height: CGFloat, around current: NSRect, in visible: NSRect) -> NSRect {
        var frame = NSRect(x: current.midX - width / 2, y: current.midY - height / 2, width: width, height: height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - height)
        return frame
    }
}

/// Hands the enclosing `NSWindow` to `onResolve` once the view is in a window.
struct WindowReader: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window {
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
