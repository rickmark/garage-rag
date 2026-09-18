import XCTest
import IngestClient
import PythonXPCService_static
@testable import GarageApp

final class MockXPCLogReceiver: NSObject, GarageXPCLogReceiverProtocol {
    var receivedStdout: [String] = []
    var receivedStderr: [String] = []
    var receivedLogs: [(source: String, level: String, message: String, timestamp: Double)] = []

    func didReceiveStdout(_ text: String) {
        receivedStdout.append(text)
    }

    func didReceiveStderr(_ text: String) {
        receivedStderr.append(text)
    }

    func didReceiveLog(source: String, level: String, message: String, timestamp: Double) {
        receivedLogs.append((source, level, message, timestamp))
    }
}

final class MockCommonXPCService: NSObject, GarageCommonXPCServiceProtocol {
    var pingResponse = "pong from MockCommonXPCService"
    var logsStdout = "sample stdout line 1\nsample stdout line 2\n"
    var logsStderr = "sample stderr error 1\n"
    var didClearLogs = false
    var receivedAppBundleURL: URL?

    func ping(with reply: @escaping (String) -> Void) {
        reply(pingResponse)
    }

    func getServiceInfo(with reply: @escaping (String, Int32, Double, String?) -> Void) {
        reply("MockCommonXPCService", 12345, 99.5, "ready")
    }

    func setAppBundleReference(_ bundleURL: URL, with reply: @escaping (Bool, String?) -> Void) {
        receivedAppBundleURL = bundleURL
        XPCDyldDiagnostics.setMainAppBundleURL(bundleURL)
        reply(true, "Main app bundle configured: \(bundleURL.path)")
    }

    func fetchLogs(with reply: @escaping (String?, String?) -> Void) {
        reply(logsStdout, logsStderr)
    }

    func fetchBufferedOutput(clearBuffer: Bool, with reply: @escaping (String?, String?, Error?) -> Void) {
        let out = logsStdout
        let err = logsStderr
        if clearBuffer {
            logsStdout = ""
            logsStderr = ""
            didClearLogs = true
        }
        reply(out, err, nil)
    }

    func clearLogs(with reply: @escaping (Bool) -> Void) {
        logsStdout = ""
        logsStderr = ""
        didClearLogs = true
        reply(true)
    }

    func handleGRPCCall(service: String, method: String, payload: Data, with reply: @escaping (Data?, String?, Error?) -> Void) {
        GarageGRPCOverXPCDispatcher.shared.dispatchGRPCCall(service: service, method: method, payload: payload, completion: reply)
    }

    func handleRPC(method: String, requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        GarageGRPCOverXPCDispatcher.shared.dispatchRPC(method: method, requestJson: requestJson, completion: reply)
    }
}

final class GarageCommonXPCProtocolTests: XCTestCase {

    func testOutputCaptureBufferingAndClearing() {
        let capture = GarageXPCOutputCapture(maxBufferSize: 4096)
        let mockReceiver = MockXPCLogReceiver()
        capture.logReceiver = mockReceiver

        capture.appendCustomLog(stream: "stdout", message: "Hello standard output")
        capture.appendCustomLog(stream: "stderr", message: "Warning alert")

        let (out1, err1) = capture.fetchLogs(clearBuffer: false)
        XCTAssertTrue(out1.contains("Hello standard output"))
        XCTAssertTrue(err1.contains("Warning alert"))
        XCTAssertEqual(mockReceiver.receivedStdout.count, 1)
        XCTAssertEqual(mockReceiver.receivedStderr.count, 1)

        // Clear buffer
        let (out2, err2) = capture.fetchLogs(clearBuffer: true)
        XCTAssertTrue(out2.contains("Hello standard output"))
        XCTAssertTrue(err2.contains("Warning alert"))

        let (out3, err3) = capture.fetchLogs(clearBuffer: false)
        XCTAssertEqual(out3, "")
        XCTAssertEqual(err3, "")
    }

    func testGRPCOverXPCDefaultHandlers() async throws {
        let dispatcher = GarageGRPCOverXPCDispatcher()

        // Test default ping JSON-RPC
        let pingExpectation = expectation(description: "ping response")
        dispatcher.dispatchRPC(method: "ping", requestJson: "{}") { resultJson, error in
            XCTAssertNil(error)
            XCTAssertNotNil(resultJson)
            XCTAssertTrue(resultJson!.contains("pong"))
            pingExpectation.fulfill()
        }
        await fulfillment(of: [pingExpectation], timeout: 2.0)

        // Test default getstatus JSON-RPC
        let statusExpectation = expectation(description: "status response")
        dispatcher.dispatchRPC(method: "getstatus", requestJson: "{}") { resultJson, error in
            XCTAssertNil(error)
            XCTAssertNotNil(resultJson)
            XCTAssertTrue(resultJson!.contains("version"))
            XCTAssertTrue(resultJson!.contains("is_ready"))
            statusExpectation.fulfill()
        }
        await fulfillment(of: [statusExpectation], timeout: 2.0)

        // Test default getversion JSON-RPC
        let versionExpectation = expectation(description: "version response")
        dispatcher.dispatchRPC(method: "getversion", requestJson: "{}") { resultJson, error in
            XCTAssertNil(error)
            XCTAssertNotNil(resultJson)
            XCTAssertTrue(resultJson!.contains("0.9"))
            versionExpectation.fulfill()
        }
        await fulfillment(of: [versionExpectation], timeout: 2.0)
    }

    func testGRPCOverXPCCustomHandlerRegistration() async throws {
        let dispatcher = GarageGRPCOverXPCDispatcher()

        dispatcher.registerHandler(service: "garage.test", method: "Calculate") { payload in
            let text = String(data: payload, encoding: .utf8) ?? "0"
            let num = (Int(text) ?? 0) * 2
            let responseData = "\(num)".data(using: .utf8)
            return (responseData, "Calculation finished: \(num)")
        }

        let expectation = expectation(description: "custom binary gRPC dispatch")
        let requestPayload = "21".data(using: .utf8)!

        dispatcher.dispatchGRPCCall(service: "garage.test", method: "Calculate", payload: requestPayload) { data, message, error in
            XCTAssertNil(error)
            XCTAssertNotNil(data)
            XCTAssertEqual(String(data: data!, encoding: .utf8), "42")
            XCTAssertEqual(message, "Calculation finished: 42")
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2.0)
    }

    func testGRPCOverXPCUnimplementedMethodError() async throws {
        let dispatcher = GarageGRPCOverXPCDispatcher()
        let expectation = expectation(description: "unimplemented method error")

        dispatcher.dispatchGRPCCall(service: "nonexistent", method: "nonexistentMethod", payload: Data()) { data, message, error in
            XCTAssertNotNil(error)
            XCTAssertNil(data)
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2.0)
    }

    func testMockCommonXPCServiceProtocolConformance() async throws {
        let mockService = MockCommonXPCService()

        let pingExpectation = expectation(description: "ping")
        mockService.ping { response in
            XCTAssertEqual(response, "pong from MockCommonXPCService")
            pingExpectation.fulfill()
        }

        let infoExpectation = expectation(description: "serviceInfo")
        mockService.getServiceInfo { name, pid, uptime, status in
            XCTAssertEqual(name, "MockCommonXPCService")
            XCTAssertEqual(pid, 12345)
            XCTAssertEqual(uptime, 99.5)
            XCTAssertEqual(status, "ready")
            infoExpectation.fulfill()
        }

        let logsExpectation = expectation(description: "fetchLogs")
        mockService.fetchBufferedOutput(clearBuffer: true) { out, err, error in
            XCTAssertNil(error)
            XCTAssertTrue(out!.contains("sample stdout"))
            XCTAssertTrue(err!.contains("sample stderr"))
            logsExpectation.fulfill()
        }

        await fulfillment(of: [pingExpectation, infoExpectation, logsExpectation], timeout: 2.0)
        XCTAssertTrue(mockService.didClearLogs)
    }

    func testPortNumberFormattingWithoutCommas() {
        let ports = [80, 443, 5432, 8080, 50051, 65535]
        for port in ports {
            let formattedString = "\(port)"
            XCTAssertFalse(formattedString.contains(","), "Port \(port) string representation should not have commas: \(formattedString)")

            // Test integer format style grouping never
            let numberFormatted = port.formatted(.number.grouping(.never))
            XCTAssertFalse(numberFormatted.contains(","), "Port \(port) number formatted grouping never should not have commas: \(numberFormatted)")
            XCTAssertEqual(numberFormatted, "\(port)")
        }
    }

    func testEmbedAndIngestGRPCOverXPCDispatch() async throws {
        let dispatcher = GarageGRPCOverXPCDispatcher()

        // Register mock Ingest RPC handler
        dispatcher.registerHandler(service: "garage.GarageService", method: "BeginIngestSession") { payload in
            let responsePayload = "{\"source_id\": 1, \"slug\": \"test-src\", \"run_id\": 99}".data(using: .utf8)
            return (responsePayload, "Ingest session began")
        }

        // Register mock Embed RPC handler
        dispatcher.registerHandler(service: "garage.GarageService", method: "GetEmbeddingBatches") { payload in
            let responsePayload = "{\"model_slug\": \"test-model\", \"chunks_count\": 2}".data(using: .utf8)
            return (responsePayload, "Embed batches retrieved")
        }

        // Test Ingest gRPC dispatch
        let ingestExpectation = expectation(description: "ingest gRPC call")
        dispatcher.dispatchGRPCCall(service: "garage.GarageService", method: "BeginIngestSession", payload: Data()) { data, message, error in
            XCTAssertNil(error)
            XCTAssertNotNil(data)
            XCTAssertEqual(message, "Ingest session began")
            let text = String(data: data!, encoding: .utf8) ?? ""
            XCTAssertTrue(text.contains("test-src"))
            ingestExpectation.fulfill()
        }

        // Test Embed gRPC dispatch
        let embedExpectation = expectation(description: "embed gRPC call")
        dispatcher.dispatchGRPCCall(service: "garage.GarageService", method: "GetEmbeddingBatches", payload: Data()) { data, message, error in
            XCTAssertNil(error)
            XCTAssertNotNil(data)
            XCTAssertEqual(message, "Embed batches retrieved")
            let text = String(data: data!, encoding: .utf8) ?? ""
            XCTAssertTrue(text.contains("test-model"))
            embedExpectation.fulfill()
        }

        await fulfillment(of: [ingestExpectation, embedExpectation], timeout: 2.0)
    }

    func testMockCommonXPCServiceSetAppBundleReference() async throws {
        defer { XPCDyldDiagnostics.resetMainAppBundleURL() }
        let mockService = MockCommonXPCService()
        let testBundleURL = URL(fileURLWithPath: "/Applications/Garage.app")
        let fileRefURL = (testBundleURL as NSURL).fileReferenceURL() ?? testBundleURL

        let expectation = expectation(description: "setAppBundleReference")
        mockService.setAppBundleReference(fileRefURL) { success, message in
            XCTAssertTrue(success)
            XCTAssertNotNil(message)
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertNotNil(mockService.receivedAppBundleURL)
        XCTAssertEqual(XPCDyldDiagnostics.resolveMainAppBundleURL().path, testBundleURL.path)
        XCTAssertEqual(ProcessInfo.processInfo.environment["GARAGE_APP_BUNDLE_PATH"], testBundleURL.path)
    }

    func testXPCDyldDiagnosticsAppBundleResolutionAndReference() {
        let tempBundleDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestGarage_\(UUID().uuidString).app")
        try? FileManager.default.createDirectory(at: tempBundleDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempBundleDir)
            XPCDyldDiagnostics.resetMainAppBundleURL()
        }

        XPCDyldDiagnostics.setMainAppBundleURL(tempBundleDir)

        let resolvedURL = XPCDyldDiagnostics.resolveMainAppBundleURL()
        XCTAssertEqual(resolvedURL.path, tempBundleDir.standardizedFileURL.resolvingSymlinksInPath().path)

        let fileRefURL = Bundle.main.bundleURL
        XCTAssertNotNil(fileRefURL)

        let candidates = XPCDyldDiagnostics.defaultPythonCandidatePaths()
        XCTAssertTrue(candidates.contains(where: { $0.contains(tempBundleDir.path) }))
    }

    func testGarageFileLoggerOperations() {
        let testLogName = "test-logger-\(UUID().uuidString).log"
        defer { GarageFileLogger.shared.clear(fileName: testLogName) }

        GarageFileLogger.shared.append(
            fileName: testLogName,
            text: "Initial message test line 1",
            stream: "stdout",
            level: "INFO",
            source: "TestFileLogger"
        )
        GarageFileLogger.shared.append(
            fileName: testLogName,
            text: "Error message test line 2",
            stream: "stderr",
            level: "ERROR",
            source: "TestFileLogger"
        )

        let contents = GarageFileLogger.shared.readLogs(fileName: testLogName)
        XCTAssertTrue(contents.contains("[INFO] [TestFileLogger] Initial message test line 1"))
        XCTAssertTrue(contents.contains("[ERROR] [TestFileLogger] Error message test line 2"))

        // Test clear
        GarageFileLogger.shared.clear(fileName: testLogName)
        let cleared = GarageFileLogger.shared.readLogs(fileName: testLogName)
        XCTAssertEqual(cleared, "")
    }

    func testOutputCaptureMultiReceiverBroadcasting() {
        let capture = GarageXPCOutputCapture(maxBufferSize: 8192)
        capture.configure(serviceName: "TestBroadcasterService", logFileName: "test-broadcast-\(UUID().uuidString).log")
        defer { capture.clear() }

        let receiver1 = MockXPCLogReceiver()
        let receiver2 = MockXPCLogReceiver()

        capture.addReceiver(receiver1)
        capture.addReceiver(receiver2)

        capture.appendCustomLog(stream: "stdout", message: "Chunk test stdout line")
        capture.appendCustomLog(stream: "stderr", message: "Chunk test stderr line")
        capture.log(source: "TestSource", level: "WARN", message: "Structured warning message")

        XCTAssertEqual(receiver1.receivedStdout.count, 1)
        XCTAssertTrue(receiver1.receivedStdout[0].contains("Chunk test stdout line"))
        XCTAssertEqual(receiver2.receivedStdout.count, 1)
        XCTAssertTrue(receiver2.receivedStdout[0].contains("Chunk test stdout line"))

        XCTAssertEqual(receiver1.receivedStderr.count, 1)
        XCTAssertTrue(receiver1.receivedStderr[0].contains("Chunk test stderr line"))
        XCTAssertEqual(receiver2.receivedStderr.count, 1)
        XCTAssertTrue(receiver2.receivedStderr[0].contains("Chunk test stderr line"))

        XCTAssertEqual(receiver1.receivedLogs.count, 1)
        XCTAssertEqual(receiver1.receivedLogs[0].message, "Structured warning message")
        XCTAssertEqual(receiver1.receivedLogs[0].level, "WARN")
        XCTAssertEqual(receiver2.receivedLogs.count, 1)

        // Remove receiver2
        capture.removeReceiver(receiver2)
        capture.log(source: "TestSource", level: "INFO", message: "Second structured message")

        XCTAssertEqual(receiver1.receivedLogs.count, 2)
        XCTAssertEqual(receiver2.receivedLogs.count, 1)
    }

    @MainActor
    func testOSLogStreamServiceXPCAndFileIngestion() {
        let osLogService = OSLogStreamService()
        osLogService.clearLogs()

        // 1. Direct XPC stdout ingestion
        osLogService.receiveXPCStdout("Ingestion process started\nIngestion chunk 1", source: .ingest, pid: 9999)
        let ingestLogs = osLogService.logs(for: .ingest)
        XCTAssertTrue(ingestLogs.contains(where: { $0.text == "Ingestion process started" }))
        XCTAssertTrue(ingestLogs.contains(where: { $0.text == "Ingestion chunk 1" }))

        // 2. Direct XPC stderr ingestion
        osLogService.receiveXPCStderr("Failed to parse document index 42", source: .embed, pid: 8888)
        let embedLogs = osLogService.logs(for: .embed)
        XCTAssertTrue(embedLogs.contains(where: { $0.text == "Failed to parse document index 42" && $0.level == .error }))

        // 3. Direct XPC structured log ingestion
        osLogService.receiveXPCLog(source: .mcp, level: .warning, message: "MCP server received unsupported tool request", pid: 7777)
        let mcpLogs = osLogService.logs(for: .mcp)
        XCTAssertTrue(mcpLogs.contains(where: { $0.text == "MCP server received unsupported tool request" && $0.level == .warning }))

        // 4. File log ingestion
        let testLogFileName = "test-embed-file-\(UUID().uuidString).log"
        defer { GarageFileLogger.shared.clear(fileName: testLogFileName) }

        GarageFileLogger.shared.append(
            fileName: testLogFileName,
            text: "Batch embedding 128 vectors finished",
            stream: "stdout",
            level: "INFO",
            source: "EmbedService"
        )
        osLogService.loadLogsFromFile(fileName: testLogFileName, for: .embed)
        let reloadedEmbedLogs = osLogService.logs(for: .embed)
        XCTAssertTrue(reloadedEmbedLogs.contains(where: { $0.text.contains("Batch embedding 128 vectors finished") }))
    }
}
