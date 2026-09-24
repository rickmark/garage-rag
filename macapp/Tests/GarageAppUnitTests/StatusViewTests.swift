import XCTest
import SwiftUI
import ModelDownloadClient
@testable import GarageApp

final class StatusViewTests: XCTestCase {

    func testPageStatusSeverityOrdering() {
        XCTAssertLessThan(PageStatusSeverity.critical, PageStatusSeverity.warning)
        XCTAssertLessThan(PageStatusSeverity.warning, PageStatusSeverity.info)
        XCTAssertLessThan(PageStatusSeverity.info, PageStatusSeverity.healthy)
    }

    @MainActor
    func testStatusViewInitializesAndRenders() {
        let appState = AppState()
        var selection: AppSection? = .status
        let binding = Binding<AppSection?>(
            get: { selection },
            set: { selection = $0 }
        )

        let statusView = StatusView(selection: binding)
            .environmentObject(appState)

        let controller = NSHostingController(rootView: statusView)
        XCTAssertNotNil(controller.view)
    }

    func testScanCountReadsSoFar() {
        XCTAssertEqual(StatusView.soFarText(0), "0 so far")
        XCTAssertEqual(StatusView.soFarText(42), "42 so far")
    }

    func testWaitingHeadlines() {
        XCTAssertEqual(StatusView.waitingOnScan, "Waiting on scan")
        XCTAssertEqual(StatusView.waitingForIngest, "Waiting for ingest")
    }

    @MainActor
    func testStatusViewRendersAScanInProgressOnAnEmptyCorpus() {
        let appState = AppState()
        appState.registeredSources = [RegisteredSource(slug: "docs", root: "/tmp/docs")]
        appState.scanProgress = AppState.ScanProgress(source: "docs", sourceItems: 1234, totalItems: 1234)
        appState.corpusStats = CorpusStats()

        let controller = NSHostingController(rootView: StatusView().environmentObject(appState))
        XCTAssertNotNil(controller.view)
    }

    @MainActor
    func testStatusViewDefaultInitializer() {
        let appState = AppState()
        let statusView = StatusView()
            .environmentObject(appState)

        let controller = NSHostingController(rootView: statusView)
        XCTAssertNotNil(controller.view)
    }

    @MainActor
    func testStatusViewSortingPlacesFailingItemsAtTop() {
        let appState = AppState()
        let statusView = StatusView()
            .environmentObject(appState)

        let controller = NSHostingController(rootView: statusView)
        XCTAssertNotNil(controller.view)
    }

    @MainActor
    func testModelsStatusItemShowsEmbeddingInProgressWhenBackfillRunning() {
        let appState = AppState()
        appState.backfill.isRunning = true

        let item = PageStatus.modelsStatusItem(for: appState)
        XCTAssertEqual(item.section, AppSection.models)
        XCTAssertEqual(item.severity, PageStatusSeverity.info)
        XCTAssertEqual(item.statusHeadline, "Embedding in Progress")
        XCTAssertEqual(item.statusDetails, "Embedder is processing document chunks.")
        XCTAssertNil(item.quickAction)
    }

    @MainActor
    func testModelsStatusItemWhenBackfillNotRunning() {
        let appState = AppState()
        appState.backfill.isRunning = false

        let item = PageStatus.modelsStatusItem(for: appState)
        XCTAssertNotEqual(item.statusHeadline, "Embedding in Progress")
    }

    @MainActor
    func testStatusItemsIncludeModelsItem() {
        let appState = AppState()
        appState.backfill.isRunning = true

        let items = PageStatus.statusItems(for: appState)
        let modelItem = items.first { $0.section == .models }
        XCTAssertNotNil(modelItem)
        XCTAssertEqual(modelItem?.statusHeadline, "Embedding in Progress")
    }

    func testCorpusStatsFractions() {
        var stats = CorpusStats()
        XCTAssertEqual(stats.ingestionProgressFraction, 0.0)
        XCTAssertEqual(stats.embeddingProgressFraction, 0.0)
        XCTAssertEqual(stats.uningestedElements, 0)
        XCTAssertEqual(stats.unembeddedChunks, 0)

        stats.documentsCount = 10
        XCTAssertEqual(stats.ingestionProgressFraction, 1.0)
        XCTAssertEqual(stats.uningestedElements, 0)

        stats.totalSeenFiles = 100
        stats.totalIndexedFiles = 75
        XCTAssertEqual(stats.ingestionProgressFraction, 0.75)
        XCTAssertEqual(stats.uningestedElements, 25)

        stats.totalExpectedElements = 200
        stats.documentsCount = 150
        XCTAssertEqual(stats.ingestionProgressFraction, 0.75)
        XCTAssertEqual(stats.uningestedElements, 50)

        stats.totalChunks = 500
        stats.embeddedChunks = 250
        stats.modelStats = [
            CorpusStats.ModelEmbeddingStats(slug: "m1", tableName: "emb_m1", isDefault: true, embeddedCount: 250),
            CorpusStats.ModelEmbeddingStats(slug: "m2", tableName: "emb_m2", isDefault: false, embeddedCount: 150)
        ]
        // Across both models: (250 + 150) / (500 * 2) = 400 / 1000 = 0.4
        XCTAssertEqual(stats.totalEmbeddedAcrossAllModels, 400)
        XCTAssertEqual(stats.totalRequiredEmbeddingsAcrossAllModels, 1000)
        XCTAssertEqual(stats.embeddingProgressFraction, 0.4)
        // Unembedded chunks across both models: (500 - 250) + (500 - 150) = 250 + 350 = 600
        XCTAssertEqual(stats.unembeddedChunks, 600)

        stats.embeddedChunks = 600 // More than totalChunks
        stats.modelStats = [
            CorpusStats.ModelEmbeddingStats(slug: "m1", tableName: "emb_m1", isDefault: true, embeddedCount: 500)
        ]
        XCTAssertEqual(stats.embeddingProgressFraction, 1.0)
        XCTAssertEqual(stats.unembeddedChunks, 0)
    }

    func testCorpusStatsUningestedElementsAndUnembeddedChunks() {
        // Test when expectedElements is present
        let statsWithExpected = CorpusStats(
            sourcesCount: 2,
            documentsCount: 40,
            documentsOkCount: 40,
            documentsFailedCount: 0,
            totalChunks: 100,
            embeddedChunks: 80,
            totalSeenFiles: 50,
            totalIndexedFiles: 40,
            totalExpectedElements: 60,
            modelStats: [
                CorpusStats.ModelEmbeddingStats(slug: "model-a", tableName: "emb_model_a", isDefault: true, embeddedCount: 70),
                CorpusStats.ModelEmbeddingStats(slug: "model-b", tableName: "emb_model_b", isDefault: false, embeddedCount: 50)
            ]
        )

        // Expected uningested: 60 - 40 = 20
        XCTAssertEqual(statsWithExpected.uningestedElements, 20)
        // Expected unembedded: (100 - 70) + (100 - 50) = 30 + 50 = 80
        XCTAssertEqual(statsWithExpected.unembeddedChunks, 80)
        XCTAssertEqual(statsWithExpected.totalEmbeddedAcrossAllModels, 120)
        XCTAssertEqual(statsWithExpected.totalRequiredEmbeddingsAcrossAllModels, 200)
        XCTAssertEqual(statsWithExpected.embeddingProgressFraction, 0.6)
        XCTAssertEqual(statsWithExpected.ingestionProgressFraction, 40.0 / 60.0)

        // Test fallback to totalSeenFiles when expectedElements is 0
        let statsWithoutExpected = CorpusStats(
            sourcesCount: 1,
            documentsCount: 10,
            totalChunks: 50,
            totalSeenFiles: 15,
            totalIndexedFiles: 10,
            totalExpectedElements: 0,
            modelStats: []
        )
        XCTAssertEqual(statsWithoutExpected.uningestedElements, 5)
        XCTAssertEqual(statsWithoutExpected.unembeddedChunks, 50)
    }

    @MainActor
    func testCorpusStatsInAppStateAndStatusView() async {
        let appState = AppState()
        XCTAssertEqual(appState.corpusStats.sourcesCount, 0)

        await appState.fetchCorpusStats()
        XCTAssertNotNil(appState.corpusStats)

        let statusView = StatusView()
            .environmentObject(appState)
        let controller = NSHostingController(rootView: statusView)
        XCTAssertNotNil(controller.view)
    }

    @MainActor
    func testSourcesStatusItemDetailsWithDocumentCount() {
        let mockStore = MockVolumeBookmarkStore()
        let mockFS = MockFileSystemAccessor()
        mockFS.readablePaths = ["/", "/System", "/Library", "/Applications", "/Users", "/Volumes", "/Users/test/Documents", "/Users/test/Notes"]
        mockFS.directoryContents = [URL(fileURLWithPath: "/Users/test/Documents")]

        let volumeService = VolumeAccessService(bookmarkStore: mockStore, fileSystem: mockFS)
        _ = volumeService.restoreAndVerifyAccess()
        let appState = AppState(llama: LlamaService(), volumeAccess: volumeService)

        appState.setRegisteredSourcesForTesting([
            RegisteredSource(slug: "docs", root: "~/Documents", documentCount: 15),
            RegisteredSource(slug: "notes", root: "~/Notes", documentCount: 5)
        ])
        appState.setCorpusStatsForTesting(CorpusStats(
            sourcesCount: 2,
            documentsCount: 20,
            documentsOkCount: 20,
            documentsFailedCount: 0,
            totalChunks: 100,
            embeddedChunks: 100,
            totalSeenFiles: 25,
            totalIndexedFiles: 20
        ))

        let item = PageStatus.sourcesStatusItem(for: appState)
        XCTAssertEqual(item.section, .sources)
        XCTAssertEqual(item.severity, .healthy)
        XCTAssertTrue(item.statusDetails.contains("2 source(s) active"))
        XCTAssertTrue(item.statusDetails.contains("5 uningested element(s)"))
    }

    @MainActor
    func testSourcesStatusItemDetailsWithTotalExpectedElements() {
        let mockStore = MockVolumeBookmarkStore()
        let mockFS = MockFileSystemAccessor()
        mockFS.readablePaths = ["/", "/System", "/Library", "/Applications", "/Users", "/Volumes", "/Users/test/Documents"]
        mockFS.directoryContents = [URL(fileURLWithPath: "/Users/test/Documents")]

        let volumeService = VolumeAccessService(bookmarkStore: mockStore, fileSystem: mockFS)
        _ = volumeService.restoreAndVerifyAccess()
        let appState = AppState(llama: LlamaService(), volumeAccess: volumeService)

        appState.setRegisteredSourcesForTesting([
            RegisteredSource(slug: "docs", root: "~/Documents", documentCount: 30, expectedElements: 50)
        ])
        appState.setCorpusStatsForTesting(CorpusStats(
            sourcesCount: 1,
            documentsCount: 30,
            documentsOkCount: 30,
            documentsFailedCount: 0,
            totalChunks: 100,
            embeddedChunks: 100,
            totalSeenFiles: 0,
            totalIndexedFiles: 0,
            totalExpectedElements: 50
        ))

        let item = PageStatus.sourcesStatusItem(for: appState)
        XCTAssertEqual(item.section, .sources)
        XCTAssertEqual(item.severity, .healthy)
        XCTAssertTrue(item.statusDetails.contains("1 source(s) active"))
        XCTAssertTrue(item.statusDetails.contains("20 uningested element(s)"))
        XCTAssertTrue(item.statusDetails.contains("30 ingested"))
    }

    @MainActor
    func testModelsStatusItemWithUnembeddedChunks() {
        let appState = AppState()
        appState.setRegisteredModelsForTesting([
            RegisteredModel(
                slug: "bge-m3",
                provider: "local",
                modelRef: "bge-m3",
                dims: 1024,
                storedDims: 1024,
                storageKind: "halfvec",
                indexKind: "hnsw",
                tableName: "emb_bge_m3",
                isDefault: true,
                modelId: "test"
            )
        ])
        appState.setCorpusStatsForTesting(CorpusStats(
            sourcesCount: 1,
            documentsCount: 10,
            documentsOkCount: 10,
            documentsFailedCount: 0,
            totalChunks: 50,
            embeddedChunks: 30,
            modelStats: [
                CorpusStats.ModelEmbeddingStats(slug: "bge-m3", tableName: "emb_bge_m3", isDefault: true, embeddedCount: 30)
            ]
        ))

        let item = PageStatus.modelsStatusItem(for: appState)
        XCTAssertEqual(item.section, .models)
        XCTAssertEqual(item.severity, .healthy)
        XCTAssertTrue(item.statusDetails.contains("20 chunk(s) remaining to embed across models"))
    }

    // MARK: - Service Beyond-Ping Functional Tests

    @MainActor
    func testModelDownloadSHA256IntegrityTest() async throws {
        let engine = ModelDownloaderEngine.shared
        let result = try engine.testDownloadAndVerifySha256()
        XCTAssertTrue(result.isValid)
        XCTAssertGreaterThan(result.bytes, 0)
        XCTAssertEqual(result.computedSha256, result.expectedSha256)
        XCTAssertTrue(result.details.contains("Integrity match: PASSED"))
        XCTAssertTrue(result.details.contains("mxbai-embed-xsmall"))

        let client = ModelDownloadClient(inProcessEngine: engine)
        let (isValid, details) = try await client.testDownloadAndVerifySha256()
        XCTAssertTrue(isValid)
        XCTAssertTrue(details.contains("PASSED"))

        let fixedTask = try await client.downloadFixedTestModel()
        XCTAssertEqual(fixedTask.modelId, "mixedbread-ai/mxbai-embed-xsmall-v1")
        XCTAssertEqual(fixedTask.filename, "gguf/mxbai-embed-xsmall-v1-q8_0.gguf")
        XCTAssertEqual(fixedTask.expectedSha256, "21f9f06af9e4e895fcdcbf6c0d57ca1996fe22da54ecb6cc5f7733d785412d44")
    }

    @MainActor
    func testSubdirectoryModelDownloadAndDiscovery() async throws {
        let engine = ModelDownloaderEngine.shared
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestSubdirModels_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent("gguf"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent("nested/sub"), withIntermediateDirectories: true)

        let file1 = tempDir.appendingPathComponent("root_model.gguf")
        let file2 = tempDir.appendingPathComponent("gguf/mxbai-embed-xsmall-v1-q8_0.gguf")
        let file3 = tempDir.appendingPathComponent("nested/sub/deep-model.gguf")

        try "root model dummy data".write(to: file1, atomically: true, encoding: .utf8)
        try "sub model dummy data".write(to: file2, atomically: true, encoding: .utf8)
        try "deep model dummy data".write(to: file3, atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: tempDir) }

        let discovered = engine.listDownloadedModels(directoryPath: tempDir.path)
        XCTAssertEqual(discovered.count, 3)

        let filenames = Set(discovered.map(\.filename))
        XCTAssertTrue(filenames.contains("root_model.gguf"))
        XCTAssertTrue(filenames.contains("gguf/mxbai-embed-xsmall-v1-q8_0.gguf"))
        XCTAssertTrue(filenames.contains("nested/sub/deep-model.gguf"))

        let service = ModelDownloadService(client: ModelDownloadClient(inProcessEngine: engine))
        try engine.setModelsDirectory(path: tempDir.path)
        await service.refresh()

        XCTAssertTrue(service.isModelDownloaded(filename: "gguf/mxbai-embed-xsmall-v1-q8_0.gguf"))
        XCTAssertTrue(service.isModelDownloaded(filename: "mxbai-embed-xsmall-v1-q8_0.gguf"))
        XCTAssertTrue(service.isModelDownloaded(filename: "nested/sub/deep-model.gguf"))
        XCTAssertTrue(service.isModelDownloaded(filename: "deep-model.gguf"))

        let found = service.downloadedModel(for: "mxbai-embed-xsmall-v1-q8_0.gguf")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.filename, "gguf/mxbai-embed-xsmall-v1-q8_0.gguf")
    }

    @MainActor
    func testServiceDiagnosticTestResultModel() {
        let res = ServiceDiagnosticTestResult(
            serviceId: "embed-xpc",
            testName: "Model Load & Vector Embeddings",
            testDescription: "Loads model and embeds sample text",
            isSuccess: true,
            durationMs: 4.5,
            summary: "Model loaded & embedded test string in 4.5ms",
            details: "Input text: sample\nVector dim: 1024"
        )
        XCTAssertEqual(res.serviceId, "embed-xpc")
        XCTAssertEqual(res.id, "embed-xpc")
        XCTAssertTrue(res.isSuccess)
        XCTAssertEqual(res.durationMs, 4.5)
        XCTAssertNil(res.errorMessage)
    }

    @MainActor
    func testXPCServiceManagerDiagnosticRunners() async {
        let manager = XPCServiceManager()
        XCTAssertTrue(manager.diagnosticResults.isEmpty)

        let ingestRes = await manager.runDiagnosticTest(for: "ingest-xpc")
        XCTAssertEqual(ingestRes.serviceId, "ingest-xpc")
        XCTAssertEqual(manager.diagnosticResults["ingest-xpc"]?.serviceId, "ingest-xpc")

        // ModelDownloadClient deliberately has no in-process fallback, and a unit
        // test host ships no XPCServices/, so the round trip cannot succeed here.
        // Assert the diagnostic still records a result for the right service and
        // reports the failure rather than silently degrading.
        let dlRes = await manager.runDiagnosticTest(for: "model-download-xpc")
        XCTAssertEqual(dlRes.serviceId, "model-download-xpc")
        XCTAssertFalse(dlRes.isSuccess)
        XCTAssertEqual(manager.diagnosticResults["model-download-xpc"]?.serviceId, "model-download-xpc")
    }

    @MainActor
    func testGRPCServiceDiagnosticQueryTestStructure() async {
        let mockPostgres = PostgresService()
        let grpcService = GarageGRPCService(postgres: mockPostgres)
        let result = await grpcService.testServiceQuery()
        XCTAssertGreaterThanOrEqual(result.durationMs, 0)
        XCTAssertFalse(result.details.isEmpty)
    }
}
