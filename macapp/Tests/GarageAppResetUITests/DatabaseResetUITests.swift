import AppKit
import Darwin
import XCTest

/// Drives Database → Reset Database… → Reset and Relaunch in the real app, on a throwaway data
/// folder (`--data-directory`), and checks the handoff between the instance that deletes the
/// database and the one it relaunches.
///
/// Manual only, never part of `aspect test //...`:
/// - It launches Garage, whose Postgres uses the fixed port 14824, and whose quit path stops XPC
///   services by executable name. So it refuses to run while any other Garage is running.
/// - The test runner needs Accessibility / UI automation permission on this Mac.
/// - Run it from the generated Xcode project (`aspect run //:xcodeproj`, scheme
///   `GarageAppResetUITests`). rules_apple's default macOS runner has no UI-test mode.
final class DatabaseResetUITests: XCTestCase {
    private static let bundleIdentifier = "me.rickmark.garage-rag"
    private static let postgresPort: UInt16 = 14824
    private static let servicePorts: [UInt16] = [14824, 8787, 8790, 50051]

    private var dataDirectory: URL!
    private var launchedPIDs: Set<pid_t> = []

    private var pgdata: URL { dataDirectory.appendingPathComponent("pgdata", isDirectory: true) }

    override func setUpWithError() throws {
        continueAfterFailure = true

        let running = Self.runningGarageInstances()
        try XCTSkipUnless(
            running.isEmpty,
            "Quit Garage first (pids \(running.map(\.processIdentifier))): this test would share its port and its quit path kills XPC services by name."
        )
        for port in Self.servicePorts {
            try XCTSkipIf(Self.isListening(on: port), "Something already listens on 127.0.0.1:\(port).")
        }

        dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GarageResetUITest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        addTeardownBlock { [weak self] in self?.cleanUp() }
    }

    func testResetHandsOverToTheRelaunchedInstance() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--data-directory", dataDirectory.path]
        app.launch()

        let oldPID = try XCTUnwrap(waitForSingleInstance(timeout: 30), "Garage did not start")
        launchedPIDs.insert(oldPID)
        dismissSplash(in: app)

        // The first cluster, which the reset must replace.
        XCTAssertTrue(waitUntil(timeout: 90) { self.postgresIsServing(from: oldPID) }, "Postgres never came up on the test folder")
        let firstCluster = try clusterIdentity()

        open(section: "database", in: app)
        let reset = app.buttons["database.reset"]
        XCTAssertTrue(reset.waitForExistence(timeout: 10), "no Reset Database… button")
        XCTAssertTrue(waitUntil(timeout: 30) { reset.isEnabled }, "Reset Database… stayed disabled")
        reset.click()

        let confirm = app.buttons["reset.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "the reset sheet did not open")
        // The sheet names the folder it deletes: the test's own, never the familiar real one.
        let pathNote = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", pgdata.path)).firstMatch
        XCTAssertTrue(pathNote.exists, "the reset sheet does not name \(pgdata.path)")
        let clickedAt = Date()
        confirm.click()

        // 1. The instance that reset must quit on its own. Before b107e82 it deadlocked in `terminate:`
        //    (called from inside a main-actor job, it waited for a reply scheduled as another one), so
        //    the relaunched instance could only time out of its 30s wait.
        let oldExited = waitUntil(timeout: 20) { !Self.isAlive(oldPID) }
        XCTAssertTrue(oldExited, "the old instance (pid \(oldPID)) was still running 20s after Reset and Relaunch")

        // 2. Exactly one new instance, launched with the reset flag.
        let newPID = try XCTUnwrap(
            waitUntilValue(timeout: 30) { Self.runningGarageInstances().map(\.processIdentifier).first { $0 != oldPID } },
            "no relaunched instance appeared"
        )
        launchedPIDs.insert(newPID)
        XCTAssertTrue(Self.arguments(of: newPID).contains("--after-database-reset"), "the relaunch did not carry --after-database-reset")
        XCTAssertTrue(Self.arguments(of: newPID).contains(dataDirectory.path), "the relaunch did not carry --data-directory")

        // 3. A new cluster in the test folder, served by the new instance.
        XCTAssertTrue(
            waitUntil(timeout: 90) { self.postgresIsServing(from: newPID) && (try? self.clusterIdentity()) != firstCluster },
            "no new cluster served by the relaunched instance"
        )
        if let created = try? clusterIdentity().created {
            XCTAssertGreaterThan(created, clickedAt.addingTimeInterval(-1), "PG_VERSION predates the reset")
        }

        // 4. It keeps serving once the old instance is gone (its quit path stops Postgres by pid file).
        if oldExited {
            XCTAssertTrue(
                holds(for: 10) { self.postgresIsServing(from: newPID) },
                "the relaunched instance's Postgres did not survive the old instance's quit"
            )
        }
        XCTAssertEqual(Self.runningGarageInstances().map(\.processIdentifier), [newPID], "more than one Garage is running")

        // 5. The second half of the reset ran and said so.
        guard oldExited else { return }
        let relaunched = XCUIApplication(bundleIdentifier: Self.bundleIdentifier)
        relaunched.activate()
        XCTAssertFalse(relaunched.buttons["splash.continue"].waitForExistence(timeout: 3), "the relaunched instance showed the splash")
        open(section: "database", in: relaunched)
        // No garage.json in the test folder, so no sources come back, and the message says so.
        let message = relaunched.staticTexts
            .matching(NSPredicate(format: "value BEGINSWITH %@", "Database reset: a new"))
            .firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 30), "finishDatabaseReset did not report a new database")
        XCTAssertTrue((message.value as? String ?? "").contains("declares no sources"), "the message does not say that no sources came back")
    }

    // MARK: - UI

    private func dismissSplash(in app: XCUIApplication) {
        let dismiss = app.buttons["splash.continue"]
        if dismiss.waitForExistence(timeout: 10) {
            dismiss.click()
        }
    }

    private func open(section: String, in app: XCUIApplication) {
        let row = app.descendants(matching: .any).matching(identifier: "sidebar.\(section)").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no sidebar row sidebar.\(section)")
        row.click()
    }

    // MARK: - Processes and Postgres

    private static func runningGarageInstances() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).filter { !$0.isTerminated }
    }

    private func waitForSingleInstance(timeout: TimeInterval) -> pid_t? {
        waitUntilValue(timeout: timeout) {
            let pids = Self.runningGarageInstances().map(\.processIdentifier)
            return pids.count == 1 ? pids[0] : nil
        }
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// The process's argv, from `KERN_PROCARGS2`.
    private static func arguments(of pid: pid_t) -> [String] {
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

    private static func isListening(on port: UInt16) -> Bool {
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

    private func postmasterPID() -> pid_t? {
        let pidFile = pgdata.appendingPathComponent("postmaster.pid")
        guard let content = try? String(contentsOf: pidFile, encoding: .utf8),
              let first = content.split(separator: "\n").first,
              let pid = pid_t(first.trimmingCharacters(in: .whitespaces)), pid > 0 else {
            return nil
        }
        return pid
    }

    /// True when a postmaster the instance `owner` started serves this test's cluster on 14824.
    private func postgresIsServing(from owner: pid_t) -> Bool {
        guard let postmaster = postmasterPID(), Self.isAlive(postmaster),
              Self.parent(of: postmaster) == owner else {
            return false
        }
        return Self.isListening(on: Self.postgresPort)
    }

    private struct ClusterIdentity: Equatable {
        let inode: UInt64
        let created: Date
    }

    private func clusterIdentity() throws -> ClusterIdentity {
        let attributes = try FileManager.default.attributesOfItem(atPath: pgdata.appendingPathComponent("PG_VERSION").path)
        return ClusterIdentity(
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            created: attributes[.creationDate] as? Date ?? .distantPast
        )
    }

    // MARK: - Waiting

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        waitUntilValue(timeout: timeout) { condition() ? true : nil } ?? false
    }

    private func waitUntilValue<T>(timeout: TimeInterval, _ value: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let result = value() { return result }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return value()
    }

    /// True when `condition` holds on every check for `duration` seconds.
    private func holds(for duration: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            guard condition() else { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return true
    }

    // MARK: - Cleanup

    /// Kills what this test started, by pid, and only processes whose arguments name this test's
    /// folder (never by name: that could reach a real Garage), then deletes the folder. The Keychain
    /// item `com.rickmark.garage.postgres.isolated` stays.
    private func cleanUp() {
        guard let dataDirectory else { return }
        let ours: (pid_t) -> Bool = { Self.isAlive($0) && Self.arguments(of: $0).contains(dataDirectory.path) }
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
