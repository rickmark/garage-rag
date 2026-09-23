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
        XCTAssertEqual(line.level, .error)
    }

    func testLogLineInferLevelForPythonCLIStderrInfo() {
        let pythonLogLine = LogLine(
            stream: .stderr,
            text: "INFO garage_rag.cli: starting garage CLI",
            source: "garage"
        )
        XCTAssertEqual(pythonLogLine.level, .info)

        let pythonServerLine = LogLine(
            stream: .stderr,
            text: "INFO garage_rag.service.server: Server started on port 14824",
            source: "garage-grpc"
        )
        XCTAssertEqual(pythonServerLine.level, .info)

        let defaultPythonLine = LogLine(
            stream: .stderr,
            text: "INFO:root:Connected to database",
            source: "garage"
        )
        XCTAssertEqual(defaultPythonLine.level, .info)

        let uvicornLine = LogLine(
            stream: .stderr,
            text: "INFO:     Started server process [12345]",
            source: "garage-mcp"
        )
        XCTAssertEqual(uvicornLine.level, .info)

        let timestampedLine = LogLine(
            stream: .stderr,
            text: "2026-09-13 12:34:56,789 INFO garage_rag.cli: database ready",
            source: "garage"
        )
        XCTAssertEqual(timestampedLine.level, .info)

        let hyphenatedLine = LogLine(
            stream: .stderr,
            text: "2026-09-13 12:34:56,789 - garage_rag - INFO - Starting server...",
            source: "garage"
        )
        XCTAssertEqual(hyphenatedLine.level, .info)

        let bracketedLine = LogLine(
            stream: .stderr,
            text: "[INFO] Ready for connections",
            source: "garage"
        )
        XCTAssertEqual(bracketedLine.level, .info)
    }

    func testLogLineInferLevelForOtherLevelsOnStderr() {
        let debugLine = LogLine(
            stream: .stderr,
            text: "DEBUG garage_rag.db: database connection opened",
            source: "garage"
        )
        XCTAssertEqual(debugLine.level, .debug)

        let warnLine = LogLine(
            stream: .stderr,
            text: "WARNING garage_rag.attribute: file skipped",
            source: "garage"
        )
        XCTAssertEqual(warnLine.level, .warning)

        let errorLine = LogLine(
            stream: .stderr,
            text: "ERROR garage_rag.ingest: failed to read file",
            source: "garage"
        )
        XCTAssertEqual(errorLine.level, .error)

        let criticalLine = LogLine(
            stream: .stderr,
            text: "CRITICAL garage_rag.main: fatal error occurred",
            source: "garage"
        )
        XCTAssertEqual(criticalLine.level, .error)
    }

    func testLogLineInferLevelStructuredJsonAndKeyValue() {
        let jsonInfo = LogLine(
            stream: .stderr,
            text: "{\"level\": \"info\", \"message\": \"server up\"}",
            source: "garage"
        )
        XCTAssertEqual(jsonInfo.level, .info)

        let jsonWarn = LogLine(
            stream: .stderr,
            text: "{\"level\":\"warning\",\"message\":\"low memory\"}",
            source: "garage"
        )
        XCTAssertEqual(jsonWarn.level, .warning)

        let jsonError = LogLine(
            stream: .stderr,
            text: "{\"level\": \"error\", \"message\": \"failed\"}",
            source: "garage"
        )
        XCTAssertEqual(jsonError.level, .error)

        let logfmtInfo = LogLine(
            stream: .stderr,
            text: "level=info msg=\"starting service\"",
            source: "garage"
        )
        XCTAssertEqual(logfmtInfo.level, .info)
    }

    func testLogLineInferLevelFallback() {
        let genericStderr = LogLine(
            stream: .stderr,
            text: "Unrecognized stderr output",
            source: "garage"
        )
        XCTAssertEqual(genericStderr.level, .error)

        let genericStdout = LogLine(
            stream: .stdout,
            text: "Regular standard output",
            source: "garage"
        )
        XCTAssertEqual(genericStdout.level, .info)
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
        let expectation = XCTestExpectation(description: "Process completes")
        // Lines reach main from the pipe's readability handler, independently of the exit:
        // on a loaded machine the termination hop can land first, so wait for the line too.
        let lineExpectation = XCTestExpectation(description: "Process logs its line")
        var collectedLines: [LogLine] = []

        let process = try runner.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["streaming", "test"],
            source: "echo_test"
        ) { line in
            collectedLines.append(line)
            if line.text.contains("streaming test") {
                lineExpectation.fulfill()
            }
        }

        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                expectation.fulfill()
            }
        }

        wait(for: [expectation, lineExpectation], timeout: 5.0)
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

    func testProcessRunnerHighVolumeOutputThreadSafety() throws {
        let runner = ProcessRunner()
        let expectation = XCTestExpectation(description: "High volume output completed without crash")
        let lineCount = 500
        var linesReceived = 0
        let lock = NSLock()

        let script = "for i in $(seq 1 \(lineCount)); do echo \"stdout line $i\"; echo \"stderr line $i\" >&2; done"
        let process = try runner.run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", script],
            source: "volume_test"
        ) { line in
            lock.lock()
            linesReceived += 1
            lock.unlock()
        }

        process.terminationHandler = { _ in
            // Give brief window for trailing asynchronous readability delivery
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 10.0)
        lock.lock()
        let total = linesReceived
        lock.unlock()
        XCTAssertGreaterThan(total, 0)
    }
}
