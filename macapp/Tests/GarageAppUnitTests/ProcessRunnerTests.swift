import XCTest
@testable import GarageApp

final class ProcessRunnerTests: XCTestCase {

    func testLogLineInitialization() {
        let line = LogLine(
            stream: .stdout,
            text: "test message",
            source: "tester"
        )

        XCTAssertEqual(line.stream, .stdout)
        XCTAssertEqual(line.text, "test message")
        XCTAssertEqual(line.source, "tester")
        XCTAssertFalse(line.id.uuidString.isEmpty)
        XCTAssertLessThanOrEqual(line.date.timeIntervalSinceNow, 1.0)
    }

    func testLogLineStderrStream() {
        let line = LogLine(
            stream: .stderr,
            text: "error occurred",
            source: "tester"
        )

        XCTAssertEqual(line.stream, .stderr)
        XCTAssertEqual(line.text, "error occurred")
        XCTAssertEqual(line.source, "tester")
    }

    func testProcessRunnerRunSyncSuccess() {
        let result = ProcessRunner.runSync(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello", "world"]
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("hello world"))
    }

    func testProcessRunnerRunSyncFailureExitCode() {
        let result = ProcessRunner.runSync(
            executable: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: []
        )

        XCTAssertNotEqual(result.status, 0)
    }

    func testProcessRunnerRunSyncInvalidExecutable() {
        let result = ProcessRunner.runSync(
            executable: URL(fileURLWithPath: "/nonexistent/binary/path"),
            arguments: []
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("failed to launch"))
    }

    func testProcessRunnerAsyncExecution() throws {
        let runner = ProcessRunner()
        let expectation = XCTestExpectation(description: "Process completes and logs lines")
        var collectedLines: [LogLine] = []

        let process = try runner.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["streaming", "test"],
            source: "echo_test"
        ) { line in
            collectedLines.append(line)
        }

        process.terminationHandler = { _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertFalse(runner.isRunning)
        XCTAssertTrue(collectedLines.contains { $0.text.contains("streaming test") })
    }

    func testProcessRunnerTermination() throws {
        let runner = ProcessRunner()
        let expectation = XCTestExpectation(description: "Process terminated")

        let process = try runner.run(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"],
            source: "sleep_test"
        ) { _ in }

        XCTAssertTrue(runner.isRunning)

        process.terminationHandler = { _ in
            expectation.fulfill()
        }

        runner.terminate()
        wait(for: [expectation], timeout: 5.0)
        XCTAssertFalse(runner.isRunning)
    }
}
