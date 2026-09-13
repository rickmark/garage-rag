import XCTest
@testable import GarageApp
import IngestClient

final class IngestClientTests: XCTestCase {

    func testIngestProgressUpdateModel() throws {
        let update = IngestProgressUpdate(
            source: "documents",
            phase: "ingest",
            seen: 50,
            totalItems: 100,
            indexed: 45,
            skipped: 5,
            failed: 0,
            placeholders: 2,
            chunksWritten: 90,
            itemType: "documents",
            progress: 0.5,
            message: "Halfway done",
            error: nil,
            currentItem: "report.docx"
        )

        let engine = IngestEngine.shared
        guard let json = engine.serialize(update) else {
            XCTFail("Failed to serialize IngestProgressUpdate")
            return
        }

        let decoded = try engine.deserialize(IngestProgressUpdate.self, from: json)
        XCTAssertEqual(decoded.source, "documents")
        XCTAssertEqual(decoded.phase, "ingest")
        XCTAssertEqual(decoded.seen, 50)
        XCTAssertEqual(decoded.totalItems, 100)
        XCTAssertEqual(decoded.indexed, 45)
        XCTAssertEqual(decoded.placeholders, 2)
        XCTAssertEqual(decoded.chunksWritten, 90)
        XCTAssertEqual(decoded.itemType, "documents")
        XCTAssertEqual(decoded.progress, 0.5)
        XCTAssertEqual(decoded.message, "Halfway done")
        XCTAssertNil(decoded.error)
        XCTAssertEqual(decoded.currentItem, "report.docx")
        XCTAssertEqual(decoded.formattedPercent, "50%")
        XCTAssertFalse(decoded.isComplete)
        XCTAssertFalse(decoded.isError)
    }

    func testIngestOptionsModel() throws {
        let options = IngestOptions(
            includeCode: true,
            limit: 25,
            force: true,
            grpcHost: "127.0.0.1",
            grpcPort: 50051,
            extraArguments: ["--custom-flag", "custom_val", "--verbose"],
            databaseUrl: "postgresql://localhost:5432/testdb",
            lmStudioApiToken: "test-token-123"
        )
        let engine = IngestEngine.shared
        guard let json = engine.serialize(options) else {
            XCTFail("Failed to serialize IngestOptions")
            return
        }

        let decoded = try engine.deserialize(IngestOptions.self, from: json)
        XCTAssertTrue(decoded.includeCode)
        XCTAssertEqual(decoded.limit, 25)
        XCTAssertTrue(decoded.force)
        XCTAssertEqual(decoded.grpcHost, "127.0.0.1")
        XCTAssertEqual(decoded.grpcPort, 50051)
        XCTAssertEqual(decoded.extraArguments, ["--custom-flag", "custom_val", "--verbose"])
        XCTAssertEqual(decoded.databaseUrl, "postgresql://localhost:5432/testdb")
        XCTAssertEqual(decoded.lmStudioApiToken, "test-token-123")
    }

    func testCommandLineParser() {
        // Empty string
        XCTAssertEqual(CommandLineParser.splitArguments(""), [])
        XCTAssertEqual(CommandLineParser.splitArguments("   "), [])

        // Basic flags and values
        let args1 = CommandLineParser.splitArguments("--source apple-sms --limit 10 --force")
        XCTAssertEqual(args1, ["--source", "apple-sms", "--limit", "10", "--force"])

        // Quotes handling
        let args2 = CommandLineParser.splitArguments("--source \"My Documents\" --option 'single quoted value' --flag")
        XCTAssertEqual(args2, ["--source", "My Documents", "--option", "single quoted value", "--flag"])

        // Escaped whitespace
        let args3 = CommandLineParser.splitArguments("--path /Library/Application\\ Support/Garage --flag")
        XCTAssertEqual(args3, ["--path", "/Library/Application Support/Garage", "--flag"])
    }

    func testIngestExecutionModeEnumCases() {
        XCTAssertEqual(IngestExecutionMode.allCases.count, 2)
        XCTAssertEqual(IngestExecutionMode.xpcService.rawValue, "xpc")
        XCTAssertEqual(IngestExecutionMode.cliProcess.rawValue, "cli_process")

        XCTAssertEqual(IngestExecutionMode.cliProcess.shortTitle, "CLI Process")
        XCTAssertTrue(IngestExecutionMode.cliProcess.title.contains("CLI"))
        XCTAssertTrue(IngestExecutionMode.cliProcess.modeDescription.contains("garage ingest"))
    }

    func testVolumeAccessTestRequestAndResult() throws {
        let req = VolumeAccessTestRequest(
            rootBookmarkData: nil,
            sourceBookmarks: ["/tmp/test": Data("bm".utf8)],
            sourcePaths: [SourcePathTestItem(slug: "test-slug", root: "/tmp/test")]
        )

        let engine = IngestEngine.shared
        guard let json = engine.serialize(req) else {
            XCTFail("Failed to serialize VolumeAccessTestRequest")
            return
        }

        let decodedReq = try engine.deserialize(VolumeAccessTestRequest.self, from: json)
        XCTAssertEqual(decodedReq.sourcePaths.count, 1)
        XCTAssertEqual(decodedReq.sourcePaths[0].slug, "test-slug")

        let result = engine.testVolumeAccess(request: decodedReq)
        XCTAssertFalse(result.testedPath.isEmpty)

        guard let resultJson = engine.serialize(result) else {
            XCTFail("Failed to serialize IngestVolumeAccessTestResult")
            return
        }

        let decodedResult = try engine.deserialize(IngestVolumeAccessTestResult.self, from: resultJson)
        XCTAssertEqual(decodedResult.testedPath, result.testedPath)
        XCTAssertEqual(decodedResult.sourcePathResults.count, 1)
    }

    func testIngestEngineBookmarkLifecycle() {
        let engine = IngestEngine()
        let fakeBookmarkData = Data("sample_bookmark_data".utf8)

        // Setting an invalid mock bookmark in unit test returns false safely
        let rootRes = engine.setRootVolumeBookmark(fakeBookmarkData)
        XCTAssertFalse(rootRes.success)

        let srcRes = engine.setSourceBookmark(path: "/tmp/source", bookmarkData: fakeBookmarkData)
        XCTAssertFalse(srcRes.success)

        engine.revokeAccess()
    }

    func testIngestClientInit() {
        let client = IngestClient()
        _ = client
        let customClient = IngestClient(serviceName: "custom.service")
        _ = customClient
    }

    @MainActor
    func testVolumeAccessServiceViaXPCThrowsWhenHelperUnavailable() async {
        let mockStore = MockVolumeBookmarkStore()
        let tempDir = NSTemporaryDirectory()
        let client = IngestClient(serviceName: "me.rickmark.nonexistent.helper")

        let service = VolumeAccessService(
            bookmarkStore: mockStore,
            fileSystem: DefaultFileSystemAccessor(),
            ingestClient: client
        )

        do {
            _ = try await service.testFullVolumeAccessViaXPC(sourcePaths: [
                (slug: "temp", root: tempDir)
            ])
            XCTFail("Expected XPC error when helper is unavailable")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    @MainActor
    func testIngestServiceProgressHandling() async throws {
        let service = IngestService()

        XCTAssertFalse(service.isRunning)
        XCTAssertNil(service.currentSource)

        let update = IngestProgressUpdate(
            source: "my-docs",
            phase: "complete",
            seen: 10,
            totalItems: 10,
            indexed: 10,
            progress: 1.0,
            message: "Finished"
        )
        service.handleProgress(update)

        XCTAssertEqual(service.latestProgress?.source, "my-docs")
        XCTAssertEqual(service.latestProgress?.phase, "complete")
        XCTAssertFalse(service.logs.isEmpty)
    }

    @MainActor
    func testIngestServiceCancellation() async throws {
        let service = IngestService()

        XCTAssertFalse(service.isRunning)
        XCTAssertFalse(service.isCancelling)

        // Cancel when not running returns false safely
        let cancelNotRunning = await service.cancel()
        XCTAssertFalse(cancelNotRunning)
    }

    func testIngestClientWhenHelperUnavailable() async throws {
        // Test client configured with non-existent helper service name
        let client = IngestClient(serviceName: "me.rickmark.nonexistent.helper")

        final class ProgressCollector: @unchecked Sendable {
            var updates: [IngestProgressUpdate] = []
            private let lock = NSLock()
            func add(_ u: IngestProgressUpdate) {
                lock.lock()
                defer { lock.unlock() }
                updates.append(u)
            }
        }
        let collector = ProgressCollector()
        let ingestResult = try await client.ingest(slug: "test-source") { progress in
            collector.add(progress)
        }
        XCTAssertFalse(ingestResult.succeeded)
        XCTAssertTrue(collector.updates.contains(where: { $0.isError }))
    }

    func testXPCDyldDiagnosticsReportGeneration() {
        let report = XPCDyldDiagnostics.diagnoseService(
            bundleId: "me.rickmark.garage-rag.ingest-xpc",
            executableName: "GarageIngestXPCService"
        )
        XCTAssertEqual(report.serviceIdentifier, "me.rickmark.garage-rag.ingest-xpc")
        XCTAssertFalse(report.formattedSummary.isEmpty)
        XCTAssertFalse(report.shortSummary.isEmpty)
        XCTAssertTrue(report.formattedSummary.contains("Diagnostic Report"))
    }

    func testXPCDyldDiagnosticsErrorEnrichment() {
        let originalError = NSError(domain: "NSCocoaErrorDomain", code: 4097, userInfo: [NSLocalizedDescriptionKey: "connection interrupted"])
        let enriched = XPCDyldDiagnostics.enrichXPCError(originalError, forServiceBundleId: "me.rickmark.garage-rag.ingest-xpc")

        XCTAssertTrue(enriched.localizedDescription.contains("connection interrupted"))
        XCTAssertTrue(enriched.localizedDescription.contains("XPC Diagnostics"))
        XCTAssertNotNil(enriched.userInfo["XPCDiagnosticReport"])
        XCTAssertNotNil(enriched.userInfo["XPCDiagnosticShortSummary"])
    }

    func testXPCDyldDiagnosticsPythonCandidateInspection() {
        let nonExistentPath = "/path/to/nonexistent/Python"
        let (selected, diagnostics) = XPCDyldDiagnostics.diagnosePythonLibraryLoading(candidatePaths: [nonExistentPath])
        XCTAssertNil(selected)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertTrue(diagnostics[0].contains("NOT FOUND"))

        let candidates = XPCDyldDiagnostics.defaultPythonCandidatePaths()
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.contains(where: { $0.contains("Python.framework") }))

        let (libPaths, spPaths) = XPCDyldDiagnostics.getPythonLibAndSitePackagesPaths()
        _ = libPaths
        _ = spPaths
    }

    func testXPCDyldDiagnosticsEnsurePsycopgDatabaseURL() {
        XCTAssertEqual(
            XPCDyldDiagnostics.ensurePsycopgDatabaseURL("postgresql://user:pass@localhost:5432/garage-rag"),
            "postgresql+psycopg://user:pass@localhost:5432/garage-rag"
        )
        XCTAssertEqual(
            XPCDyldDiagnostics.ensurePsycopgDatabaseURL("postgres://user:pass@localhost:5432/garage-rag"),
            "postgresql+psycopg://user:pass@localhost:5432/garage-rag"
        )
        XCTAssertEqual(
            XPCDyldDiagnostics.ensurePsycopgDatabaseURL("postgresql+psycopg://user:pass@localhost:5432/garage-rag"),
            "postgresql+psycopg://user:pass@localhost:5432/garage-rag"
        )
        XCTAssertEqual(
            XPCDyldDiagnostics.ensurePsycopgDatabaseURL(""),
            ""
        )
        XCTAssertEqual(
            XPCDyldDiagnostics.ensurePsycopgDatabaseURL("   "),
            ""
        )
    }

    func testIngestProgressScanVsIngestCounts() {
        let update = IngestProgressUpdate(
            source: "books",
            phase: "ingest",
            seen: 150,
            totalItems: 300,
            indexed: 120,
            skipped: 25,
            failed: 5,
            placeholders: 0,
            chunksWritten: 480,
            itemType: "files",
            progress: 0.5,
            message: "[150/300 scanned 50.0%] books: 120 ingested (25 skipped, 5 failed) - chapter1.pdf",
            error: nil,
            currentItem: "chapter1.pdf"
        )
        XCTAssertEqual(update.seen, 150)
        XCTAssertEqual(update.totalItems, 300)
        XCTAssertEqual(update.indexed, 120)
        XCTAssertEqual(update.skipped, 25)
        XCTAssertEqual(update.failed, 5)
        XCTAssertEqual(update.formattedPercent, "50%")
        XCTAssertTrue(update.message.contains("150/300 scanned"))
        XCTAssertTrue(update.message.contains("120 ingested"))
    }
}
