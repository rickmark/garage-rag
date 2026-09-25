import XCTest
@testable import GarageApp

final class OperationRunnerTests: XCTestCase {

    @MainActor
    func testInitialState() {
        let runner = OperationRunner(label: "test")

        XCTAssertFalse(runner.isRunning)
        XCTAssertTrue(runner.logs.isEmpty)
        XCTAssertEqual(runner.label, "test")
    }

    @MainActor
    func testSuccessLogsEachLineOfTheOutput() async {
        let runner = OperationRunner(label: "test")

        let result = await runner.run { _ in "added source docs\n\nscanned 3 items" }

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.output, "added source docs\n\nscanned 3 items")
        XCTAssertEqual(runner.logs.map(\.text), ["added source docs", "scanned 3 items"])
        XCTAssertTrue(runner.logs.allSatisfy { $0.source == "test" && $0.stream == .stdout })
        XCTAssertFalse(runner.isRunning)
    }

    @MainActor
    func testFailureReportsTheErrorMessage() async {
        let runner = OperationRunner(label: "test")

        let result = await runner.run { _ in
            throw GarageGRPCError.rpcFailed("source 'nope' not found")
        }

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.output, "source 'nope' not found")
        XCTAssertEqual(runner.logs.last?.stream, .stderr)
        XCTAssertEqual(runner.logs.last?.text, "source 'nope' not found")
        XCTAssertFalse(runner.isRunning)
    }

    @MainActor
    func testStreamingOperationsLogThroughTheRunner() async {
        let runner = OperationRunner(label: "test")

        let result = await runner.run { runner in
            runner.appendLog("m: 2/4")
            runner.appendLog("m: 4/4")
            return ""
        }

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(runner.logs.map(\.text), ["m: 2/4", "m: 4/4"])
    }

    @MainActor
    func testRefusesASecondOperationWhileOneIsRunning() async {
        let runner = OperationRunner(label: "test")
        let started = expectation(description: "first operation started")

        let first = Task {
            await runner.run { _ in
                started.fulfill()
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return "done"
            }
        }
        await fulfillment(of: [started], timeout: 5)

        let second = await runner.run { _ in "should not run" }
        XCTAssertFalse(second.succeeded)
        XCTAssertEqual(second.output, "test is already running")

        runner.cancel()
        _ = await first.value
    }

    @MainActor
    func testCancelEndsTheOperation() async {
        let runner = OperationRunner(label: "test")
        let started = expectation(description: "operation started")

        let run = Task {
            await runner.run { _ in
                started.fulfill()
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return "finished"
            }
        }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(runner.isRunning)

        runner.cancel()
        let result = await run.value

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.output, "test cancelled")
        XCTAssertFalse(runner.isRunning)
        XCTAssertTrue(runner.logs.contains { $0.text == "Cancelling test..." })
    }

    @MainActor
    func testFullLogDropsAQuarterAtOnceRatherThanALinePerAppend() {
        let runner = OperationRunner(label: "test")

        for index in 0..<4000 {
            runner.appendLog("line \(index)")
        }
        XCTAssertEqual(runner.logs.count, 4000)

        runner.appendLog("line 4000")
        XCTAssertEqual(runner.logs.count, 3000)
        XCTAssertEqual(runner.logs.first?.text, "line 1001")

        // The next appends only add rows at the end; the oldest line on screen stays put.
        runner.appendLog("line 4001")
        XCTAssertEqual(runner.logs.count, 3001)
        XCTAssertEqual(runner.logs.first?.text, "line 1001")
    }
}
