import XCTest
import AppKit
@testable import GarageApp

final class AppDelegateTests: XCTestCase {

    @MainActor
    func testApplicationShouldTerminateAfterLastWindowClosed() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(app))
    }

    @MainActor
    func testAppStateResolution() {
        let delegate = AppDelegate()
        let state = AppState()
        XCTAssertNotNil(delegate.appState)
        XCTAssertTrue(delegate.appState === state)

        let customState = AppState()
        delegate.appState = customState
        XCTAssertTrue(delegate.appState === customState)
    }

    @MainActor
    func testApplicationShouldTerminateReturnsTerminateLater() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        let state = AppState()
        delegate.appState = state

        let reply = delegate.applicationShouldTerminate(app)
        XCTAssertEqual(reply, .terminateLater)

        // Re-entrant / duplicate invocation should also return .terminateLater
        let secondReply = delegate.applicationShouldTerminate(app)
        XCTAssertEqual(secondReply, .terminateLater)
    }

    @MainActor
    func testApplicationShouldTerminateWithoutExplicitAppState() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegate.appState = nil

        let reply = delegate.applicationShouldTerminate(app)
        XCTAssertEqual(reply, .terminateLater)
    }

    @MainActor
    func testApplicationWillTerminateExecutesCleanly() {
        let delegate = AppDelegate()
        let state = AppState()
        delegate.appState = state

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertEqual(state.mcp.status, .stopping)
        XCTAssertEqual(state.grpc.status, .stopping)

        // terminateImmediately() is idempotent: a second quit path must not re-run the shutdown.
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        // Also test when appState is nil
        delegate.appState = nil
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    }

    @MainActor
    func testStopAnyRunningInstancesAreNoOpsInTests() async {
        // Both scan for / signal the developer's live processes; under XCTest they must return without acting.
        await PostgresService.stopAnyRunningInstance()
        PostgresService.stopAnyRunningInstanceSync()
        XPCServiceManager.stopAnyRunningInstances()
    }
}
