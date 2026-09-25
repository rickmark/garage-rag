import AppKit
import SwiftUI

extension Notification.Name {
    /// Asks the main window to show a section. `object` is the `AppSection`; `userInfo["query"]`
    /// may carry a search string for the Search page.
    static let garageShowSection = Notification.Name("me.rickmark.garage-rag.showSection")
}

/// How the menu bar popover gets the user into the main window. The popover cannot host a sheet or
/// a page itself - it closes the moment focus moves - so every "open ..." ends here.
@MainActor
enum MenuBarNavigation {
    static let queryKey = "query"

    /// A query for the Search page that has not been run yet. The page may not exist when the
    /// notification goes out (another page was selected), so it also takes this as it appears.
    static var pendingSearchQuery: String?

    /// Hands the Search page its query once, whichever of the notification or its appearance
    /// gets there first.
    static func takePendingSearchQuery() -> String? {
        defer { pendingSearchQuery = nil }
        return pendingSearchQuery
    }

    /// Brings the main window forward, or opens a new one when a `--background` launch (by the
    /// `garage` and `garage-mcp` launchers) never showed it or the user closed it. Returns whether a
    /// window already existed, which decides whether a follow-up notification can be posted at once.
    @discardableResult
    static func openMainWindow(openWindow: OpenWindowAction) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let windows = NSApp.windows.filter { $0.title == "Garage" }
        if windows.isEmpty {
            openWindow(id: GarageApp.mainWindowID)
            return false
        }
        for window in windows {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    /// Opens the main window on `section`. A search query rides along for the Search page.
    static func show(_ section: AppSection, query: String? = nil, openWindow: OpenWindowAction) {
        var userInfo: [AnyHashable: Any] = [:]
        if let query, !query.isEmpty {
            userInfo[queryKey] = query
            pendingSearchQuery = query
        }
        post(.garageShowSection, object: section, userInfo: userInfo, openWindow: openWindow)
    }

    /// Brings the main window forward and asks it to put up a dialog (the splash, the bug reporter).
    static func present(_ notification: Notification.Name, openWindow: OpenWindowAction) {
        post(notification, object: nil, userInfo: nil, openWindow: openWindow)
    }

    private static func post(
        _ name: Notification.Name,
        object: Any?,
        userInfo: [AnyHashable: Any]?,
        openWindow: OpenWindowAction
    ) {
        let hadWindow = openMainWindow(openWindow: openWindow)
        if hadWindow {
            NotificationCenter.default.post(name: name, object: object, userInfo: userInfo)
        } else {
            // A new window's ContentView subscribes as it appears; give it a turn of the run loop.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: name, object: object, userInfo: userInfo)
            }
        }
    }
}
