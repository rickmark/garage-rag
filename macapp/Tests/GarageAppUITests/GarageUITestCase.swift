import AppKit
import Darwin
import XCTest

/// Base for the XCUITests: every test launches the real app on its own throwaway `--data-directory`,
/// so it gets a new cluster, config and models folder and never touches the real corpus.
///
/// Launch arguments set the launch-time preferences in the argument domain, which overrides
/// UserDefaults for that run without writing them. A test that clicks a control that saves a
/// preference (the splash's "Show this window at launch", the setup assistant's Finish or Skip)
/// does write the real `me.rickmark.garage-rag` domain, so tests leave those controls alone or
/// only reach states they already have.
///
/// The app's Postgres uses the fixed port 14824 and its quit path stops XPC services by executable
/// name, so a test refuses to run while another Garage is running or its ports are taken.
class GarageUITestCase: XCTestCase {
    static let bundleIdentifier = "me.rickmark.garage-rag"
    static let postgresPort: UInt16 = 14824
    static let grpcPort: UInt16 = 50051
    static let servicePorts: [UInt16] = [14824, 8787, 8790, 50051]

    private(set) var dataDirectory: URL!
    private(set) var app: XCUIApplication!
    var launchedPIDs: Set<pid_t> = []

    var pgdata: URL { dataDirectory.appendingPathComponent("pgdata", isDirectory: true) }

    override func setUpWithError() throws {
        continueAfterFailure = false

        let running = Self.runningGarageInstances()
        try XCTSkipUnless(
            running.isEmpty,
            "Quit Garage first (pids \(running.map(\.processIdentifier))): this test would share its port and its quit path kills XPC services by name."
        )
        for port in Self.servicePorts {
            try XCTSkipIf(Self.isListening(on: port), "Something already listens on 127.0.0.1:\(port).")
        }

        dataDirectory = try makeDataDirectoryParent()
            .appendingPathComponent("GarageUITest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        // The app and its gRPC server look for ./garage.json in the data folder before ~/.garage.json,
        // and write sources to the file they found. An empty config here keeps a test from reading or
        // editing the real one.
        try Data("{}\n".utf8).write(to: configFile)
        addTeardownBlock { [weak self] in self?.cleanUp() }
    }

    var configFile: URL { dataDirectory.appendingPathComponent("garage.json", isDirectory: false) }

    /// The folder this test's data folder is made in. A subclass whose app cannot reach the
    /// temporary folder (the sandboxed App Store build) overrides it.
    func makeDataDirectoryParent() throws -> URL {
        FileManager.default.temporaryDirectory
    }

    /// The app under test: the test target's host app unless a subclass launches another bundle.
    func makeApplication() throws -> XCUIApplication {
        XCUIApplication()
    }

    // MARK: - Launching

    /// Launches Garage on this test's data folder and waits for its main window (or, with
    /// `firstRunCompleted: false`, the setup assistant).
    @discardableResult
    func launchApp(showSplash: Bool = false, firstRunCompleted: Bool = true, automaticMaintenance: Bool = false) throws -> XCUIApplication {
        let app = try makeApplication()
        app.launchArguments = [
            "--data-directory", dataDirectory.path,
            "-garage.splash.showAtLaunch", showSplash ? "YES" : "NO",
            "-garage.firstRun.completed", firstRunCompleted ? "YES" : "NO",
            // Off unless a test is about it: adding a source then starts a scan and ingest of every
            // source, which makes the source a test just added busy (not removable) until it ends.
            "-scheduledMaintenanceEnabled", automaticMaintenance ? "YES" : "NO",
            // Start from a clean window each time rather than the last run's restored state.
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        self.app = app

        let pid = try XCTUnwrap(waitForSingleInstance(timeout: 30), "Garage did not start")
        launchedPIDs.insert(pid)
        return app
    }

    /// The pid of the one running Garage, which `launchApp` checked is the one it launched.
    var appPID: pid_t? {
        let pids = Self.runningGarageInstances().map(\.processIdentifier)
        return pids.count == 1 ? pids[0] : nil
    }

    /// Waits until Postgres serves this test's cluster and the gRPC service the pages' operations
    /// go through is listening.
    func waitForBackend(timeout: TimeInterval = 120, file: StaticString = #filePath, line: UInt = #line) {
        guard let owner = appPID else {
            XCTFail("no single Garage instance to wait on", file: file, line: line)
            return
        }
        XCTAssertTrue(
            waitUntil(timeout: timeout) { self.postgresIsServing(from: owner) && Self.isListening(on: Self.grpcPort) },
            "Postgres and gRPC did not come up on the test folder",
            file: file,
            line: line
        )
    }

    /// Quits Garage the way a person does (⌘Q), so its quit path stops Postgres and the XPC
    /// services, and waits for the process to exit.
    func quitApp(file: StaticString = #filePath, line: UInt = #line) {
        guard let pid = appPID else { return }
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(waitUntil(timeout: 30) { !Self.isAlive(pid) }, "Garage (pid \(pid)) did not quit", file: file, line: line)
        _ = waitUntil(timeout: 15) { !Self.isListening(on: Self.postgresPort) }
    }

    // MARK: - UI

    func dismissSplash() {
        let dismiss = app.buttons["splash.continue"]
        if dismiss.waitForExistence(timeout: 10) {
            dismiss.click()
        }
    }

    /// Clicks the sidebar row for `section` (the `AppSection` case name, e.g. `"mcp"`).
    func open(section: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = element(identifier: "sidebar.\(section)")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "no sidebar row sidebar.\(section)", file: file, line: line)
        row.click()
    }

    func element(identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Any element whose label, title, value or placeholder is exactly `text`: static texts, group
    /// box titles, buttons and text fields all surface it differently.
    func element(text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ OR title == %@ OR value == %@ OR placeholderValue == %@", text, text, text, text)
        ).firstMatch
    }

    func element(textContaining fragment: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", fragment, fragment)
        ).firstMatch
    }

    func element(textBeginningWith prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", prefix, prefix)
        ).firstMatch
    }

    func button(label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR title == %@", label, label)).firstMatch
    }

    /// Replaces a text field's contents. The field is scrolled into view and clicked until it holds
    /// keyboard focus: a click on a field at the edge of its scroll view lands on the edge instead,
    /// and typing then fails with "Neither element nor any descendant has keyboard focus".
    func replaceText(in field: XCUIElement, with text: String, file: StaticString = #filePath, line: UInt = #line) {
        let focused = waitUntil(timeout: 15) {
            reveal(field)
            field.click()
            return waitUntil(timeout: 1) { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        }
        XCTAssertTrue(focused, "\(field) never took keyboard focus", file: file, line: line)
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    /// Clicks `element` once it is scrolled into view.
    func click(_ element: XCUIElement) {
        reveal(element)
        element.click()
    }

    /// Scrolls the scroll view holding `element` until the element sits well inside its visible
    /// frame. macOS UI tests do not scroll before a click, and pages grow while they run (the
    /// Sources page's progress boxes push its form down), so an element can sit at or past the
    /// bottom edge. A no-op for an element that is not in a scroll view or is already in view.
    func reveal(_ element: XCUIElement) {
        let scrollView = app.scrollViews.containing(NSPredicate(format: "identifier == %@", element.identifier)).firstMatch
        guard !element.identifier.isEmpty, scrollView.exists else { return }
        let margin: CGFloat = 60
        var step: CGFloat = -120
        for _ in 0..<40 {
            let visible = scrollView.frame.insetBy(dx: 0, dy: min(margin, scrollView.frame.height / 4))
            let frame = element.frame
            let offset: CGFloat
            if frame.maxY > visible.maxY {
                offset = frame.maxY - visible.maxY
            } else if frame.minY < visible.minY {
                offset = frame.minY - visible.minY
            } else {
                return
            }
            // Which way a scroll delta moves content depends on the system's scrolling setting, so
            // learn it from the first step: flip the sign when the element moved the wrong way.
            let delta = offset > 0 ? step : -step
            scrollView.scroll(byDeltaX: 0, deltaY: delta)
            let moved = element.frame.minY - frame.minY
            if moved != 0, (moved > 0) == (offset > 0) {
                step = -step
            }
        }
    }

    func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval = 30) -> Bool {
        waitUntil(timeout: timeout) { element.exists && element.isEnabled }
    }

    // MARK: - Processes and Postgres

    static func runningGarageInstances() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).filter { !$0.isTerminated }
    }

    func waitForSingleInstance(timeout: TimeInterval) -> pid_t? {
        waitUntilValue(timeout: timeout) { self.appPID }
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// The process's argv, from `KERN_PROCARGS2`.
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        // argc, then the executable path, NUL padding, then argc NUL-terminated arguments.
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    static func isListening(on port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    func postmasterPID() -> pid_t? {
        let pidFile = pgdata.appendingPathComponent("postmaster.pid")
        guard let content = try? String(contentsOf: pidFile, encoding: .utf8),
              let first = content.split(separator: "\n").first,
              let pid = pid_t(first.trimmingCharacters(in: .whitespaces)), pid > 0 else {
            return nil
        }
        return pid
    }

    /// True when a postmaster the instance `owner` started serves this test's cluster on 14824.
    func postgresIsServing(from owner: pid_t) -> Bool {
        guard let postmaster = postmasterPID(), Self.isAlive(postmaster),
              Self.parent(of: postmaster) == owner else {
            return false
        }
        return Self.isListening(on: Self.postgresPort)
    }

    struct ClusterIdentity: Equatable {
        let inode: UInt64
        let created: Date
    }

    func clusterIdentity() throws -> ClusterIdentity {
        let attributes = try FileManager.default.attributesOfItem(atPath: pgdata.appendingPathComponent("PG_VERSION").path)
        return ClusterIdentity(
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            created: attributes[.creationDate] as? Date ?? .distantPast
        )
    }

    // MARK: - Waiting

    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        waitUntilValue(timeout: timeout) { condition() ? true : nil } ?? false
    }

    func waitUntilValue<T>(timeout: TimeInterval, _ value: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let result = value() { return result }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return value()
    }

    /// True when `condition` holds on every check for `duration` seconds.
    func holds(for duration: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            guard condition() else { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return true
    }

    // MARK: - Cleanup

    /// Quits what this test started through the app's own quit path, then kills anything left by pid,
    /// and only processes whose arguments name this test's folder (never by name: that could reach a
    /// real Garage), then deletes the folder, which holds the isolated cluster's password too
    /// (`GaragePostgresEndpoint.isolatedPasswordFile`).
    private func cleanUp() {
        guard let dataDirectory else { return }
        let ours: (pid_t) -> Bool = { Self.isAlive($0) && Self.arguments(of: $0).contains(dataDirectory.path) }
        for running in Self.runningGarageInstances() where ours(running.processIdentifier) {
            running.terminate()
        }
        _ = waitUntil(timeout: 20) { !Self.runningGarageInstances().contains { ours($0.processIdentifier) } }

        let postmaster = postmasterPID()
        for pid in launchedPIDs.union(Self.runningGarageInstances().map(\.processIdentifier)) where ours(pid) {
            kill(pid, SIGKILL)
        }
        // `postgres -D <folder>/pgdata`: the argument names the folder too.
        if let postmaster, Self.isAlive(postmaster),
           Self.arguments(of: postmaster).contains(where: { $0.hasPrefix(dataDirectory.path) }) {
            kill(postmaster, SIGKILL)
        }
        _ = waitUntil(timeout: 10) { !Self.isListening(on: Self.postgresPort) }
        try? FileManager.default.removeItem(at: dataDirectory)
    }
}
