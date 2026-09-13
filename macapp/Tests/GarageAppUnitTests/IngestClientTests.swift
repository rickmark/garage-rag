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
        let options = IngestOptions(includeCode: true, limit: 25, force: true)
        let engine = IngestEngine.shared
        guard let json = engine.serialize(options) else {
            XCTFail("Failed to serialize IngestOptions")
            return
        }

        let decoded = try engine.deserialize(IngestOptions.self, from: json)
        XCTAssertTrue(decoded.includeCode)
        XCTAssertEqual(decoded.limit, 25)
        XCTAssertTrue(decoded.force)
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

    func testIngestClientWithInProcessEngine() async throws {
        let engine = IngestEngine()
        let client = IngestClient(inProcessEngine: engine)

        let pingResult = try await client.ping()
        XCTAssertTrue(pingResult.contains("in-process"))

        let revokeResult = try await client.revokeAccess()
        XCTAssertTrue(revokeResult)

        let tempDir = NSTemporaryDirectory()
        let request = VolumeAccessTestRequest(
            rootBookmarkData: nil,
            sourceBookmarks: nil,
            sourcePaths: [SourcePathTestItem(slug: "temp", root: tempDir)]
        )

        let testResult = try await client.testVolumeAccess(request: request)
        XCTAssertTrue(testResult.isAccessible)
        XCTAssertEqual(testResult.sourcePathResults.count, 1)
        XCTAssertTrue(testResult.sourcePathResults[0].isAccessible)
        XCTAssertEqual(testResult.sourcePathResults[0].slug, "temp")
    }

    @MainActor
    func testVolumeAccessServiceViaXPC() async throws {
        let mockStore = MockVolumeBookmarkStore()
        let tempDir = NSTemporaryDirectory()
        let engine = IngestEngine()
        let client = IngestClient(inProcessEngine: engine)

        let service = VolumeAccessService(
            bookmarkStore: mockStore,
            fileSystem: DefaultFileSystemAccessor(),
            ingestClient: client
        )

        let result = try await service.testFullVolumeAccessViaXPC(sourcePaths: [
            (slug: "temp", root: tempDir)
        ])

        XCTAssertTrue(result.isAccessible)
        XCTAssertEqual(result.sourcePathResults.count, 1)
        XCTAssertTrue(result.sourcePathResults[0].isAccessible)
        XCTAssertEqual(result.sourcePathResults[0].slug, "temp")
        XCTAssertTrue(result.message.contains("XPC process"))
    }

    @MainActor
    func testIngestServiceProgressHandling() async throws {
        let engine = IngestEngine()
        let client = IngestClient(inProcessEngine: engine)
        let service = IngestService(client: client)

        XCTAssertFalse(service.isRunning)
        XCTAssertNil(service.currentSource)

        let result = await service.ingest(slug: "my-docs")
        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(service.isRunning)
        XCTAssertNil(service.currentSource)
        XCTAssertNotNil(service.latestProgress)
        XCTAssertEqual(service.latestProgress?.source, "my-docs")
        XCTAssertEqual(service.latestProgress?.phase, "complete")
        XCTAssertFalse(service.logs.isEmpty)
    }

    @MainActor
    func testIngestServiceCancellation() async throws {
        let engine = IngestEngine()
        let client = IngestClient(inProcessEngine: engine)
        let service = IngestService(client: client)

        XCTAssertFalse(service.isRunning)
        XCTAssertFalse(service.isCancelling)

        // Cancel when not running returns false safely
        let cancelNotRunning = await service.cancel()
        XCTAssertFalse(cancelNotRunning)

        let cancelClientResult = try await client.cancelIngest()
        XCTAssertTrue(cancelClientResult)
        XCTAssertTrue(engine.isCancelled)

        engine.resetCancel()
        XCTAssertFalse(engine.isCancelled)
    }

    func testIngestClientFallbackWhenHelperUnavailable() async throws {
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
        let ingestResult = try await client.ingest(slug: "fallback-source") { progress in
            collector.add(progress)
        }
        XCTAssertTrue(ingestResult.succeeded)
        // Verify XPC unavailable warning was logged into progress stream
        XCTAssertTrue(collector.updates.contains(where: { $0.message.contains("XPC helper unavailable") }))
    }

    @MainActor
    func testIngestEngineFailureLoggingAndPropagation() async throws {
        let engine = IngestEngine { slug, options, onProgress in
            let errorMsg = "Simulated disk failure during ingest of \(slug)"
            onProgress?(IngestProgressUpdate(
                source: slug,
                phase: "error",
                message: errorMsg,
                error: errorMsg
            ))
            return IngestResult(succeeded: false, message: errorMsg)
        }
        let client = IngestClient(inProcessEngine: engine)
        let service = IngestService(client: client)

        let result = await service.ingest(slug: "fail-docs")
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(service.lastError, "Simulated disk failure during ingest of fail-docs")
        XCTAssertTrue(service.logs.contains(where: { $0.stream == .stderr && $0.text.contains("Simulated disk failure") }))
        XCTAssertTrue(service.latestProgress?.isError ?? false)
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
    }

    func testIngestEngineAsyncIngest() async {
        let engine = IngestEngine()
        var updates: [IngestProgressUpdate] = []
        let result = await engine.ingestSourceAsync(slug: "test-slug") { update in
            updates.append(update)
        }
        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(updates.isEmpty)
        XCTAssertEqual(updates.last?.phase, "complete")
    }
}
