import AppKit
import SwiftUI

/// The main window opens at its minimum size, which suits the setup assistant. When the assistant
/// closes, the window grows (animated) to a size the working pages are laid out for.
enum MainWindowSizing {
    /// Roomy enough for Sources, Documents and Search side by side with the sidebar.
    static let workingSize = NSSize(width: 1100, height: 760)

    /// The frame to grow to from `current`, or nil when the window is already at least that big.
    /// The window keeps its centre where it can, never shrinks, and stays inside `visible` (the
    /// screen's visible frame, in the same coordinates).
    static func frameAfterFirstRun(current: NSRect, visible: NSRect, target: NSSize = workingSize) -> NSRect? {
        let width = min(max(current.width, target.width), visible.width)
        let height = min(max(current.height, target.height), visible.height)
        guard width > current.width || height > current.height else { return nil }

        var frame = NSRect(x: current.midX - width / 2, y: current.midY - height / 2, width: width, height: height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - height)
        return frame
    }

    @MainActor
    static func growAfterFirstRun(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen), !window.isZoomed,
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame,
              let frame = frameAfterFirstRun(current: window.frame, visible: visible)
        else { return }
        window.setFrame(frame, display: true, animate: true)
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
