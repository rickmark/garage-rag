import XCTest
import PythonXPCService
@testable import GarageApp

final class StatusPagePresentationTests: XCTestCase {

    // MARK: - Health

    func testEverythingRunningIsAllSystemsGo() {
        let health = StatusHealth(database: .running, mcp: .running(clients: 2), sourceCount: 1, embeddingModelCount: 1)
        XCTAssertTrue(health.isHealthy)
        XCTAssertEqual(health.summary.title, "All systems go")
        XCTAssertEqual(health.summary.detail, "Database and MCP running · 2 clients")
    }

    func testStartingServicesAreNotAProblem() {
        let health = StatusHealth(database: .starting, sourceCount: 1, embeddingModelCount: 1)
        XCTAssertTrue(health.isHealthy)
        XCTAssertEqual(health.summary.title, "Starting up…")
    }

    func testDatabaseProblemsComeWithTheirFix() throws {
        let failed = StatusHealth(database: .failed("port 14824 already in use\nmore"), sourceCount: 1, embeddingModelCount: 1)
        let problem = try XCTUnwrap(failed.problems.first)
        XCTAssertEqual(problem.title, "Database couldn't start")
        XCTAssertEqual(problem.detail, "port 14824 already in use")
        XCTAssertTrue(problem.detailIsError)
        XCTAssertEqual(problem.fix, .startDatabase)
        XCTAssertEqual(problem.fixLabel, "Try Again")
        XCTAssertEqual(problem.severity, .critical)
        XCTAssertEqual(problem.section, .database)

        let stopped = StatusHealth(database: .stopped, sourceCount: 1, embeddingModelCount: 1)
        XCTAssertEqual(stopped.problems.map(\.title), ["Database stopped"])
        XCTAssertEqual(stopped.problems.first?.fixLabel, "Start")

        let migration = StatusHealth(database: .needsMigration, sourceCount: 1, embeddingModelCount: 1)
        XCTAssertEqual(migration.problems.first?.title, "Database needs a schema update")
        XCTAssertEqual(migration.problems.first?.fix, .applyMigrations)
    }

    func testMCPProblemsAreListedOnlyWhileTheDatabaseRuns() {
        let down = StatusHealth(database: .stopped, mcp: .failed("boom"), sourceCount: 1, embeddingModelCount: 1)
        XCTAssertEqual(down.problems.map(\.id), ["database"])

        let up = StatusHealth(database: .running, mcp: .failed("boom"), sourceCount: 1, embeddingModelCount: 1)
        XCTAssertEqual(up.problems.map(\.id), ["mcp"])
        XCTAssertEqual(up.problems.first?.title, "MCP server failed")
        XCTAssertEqual(up.problems.first?.fixLabel, "Try Again")

        let stopped = StatusHealth(database: .running, mcp: .stopped, sourceCount: 1, embeddingModelCount: 1)
        XCTAssertEqual(stopped.problems.first?.title, "MCP server not running")
        XCTAssertEqual(stopped.problems.first?.fix, .startMCP)

        let notAnswering = StatusHealth(database: .running, mcp: .running(clients: 1), mcpCheckFailure: "HTTP 500", sourceCount: 1, embeddingModelCount: 1)
        XCTAssertEqual(notAnswering.problems.first?.title, "MCP server isn't answering")
        XCTAssertEqual(notAnswering.problems.first?.fix, .testMCP)
    }

    func testCriticalProblemsComeFirst() {
        let health = StatusHealth(
            database: .running,
            mcp: .stopped,
            sourceAccess: [.init(slug: "apple-sms", name: "Messages", path: "/Users/rick/Library/Messages", needsPermission: true)],
            sourceCount: 1,
            embeddingModelCount: 0,
            llamaError: "Couldn't communicate with a helper application."
        )
        XCTAssertEqual(health.problems.map(\.id), ["llama", "mcp", "source.apple-sms", "models"])
        XCTAssertEqual(health.problems[2].title, "Messages needs permission")
        XCTAssertEqual(health.problems[2].fix, .grantFolder(slug: "apple-sms", path: "/Users/rick/Library/Messages"))
        XCTAssertEqual(health.problems[3].title, "No embedding model")
        XCTAssertNil(health.problems[3].fix)
    }

    func testEmptyCorpusProblemsNeedARunningDatabase() {
        let stopped = StatusHealth(database: .stopped)
        XCTAssertEqual(stopped.problems.map(\.id), ["database"])

        let running = StatusHealth(database: .running, mcp: .running(clients: 0))
        XCTAssertEqual(running.problems.map(\.id), ["sources", "models"])
    }

    func testAFailedIngestIsListedOnlyWhileIdle() {
        let idle = StatusHealth(database: .running, mcp: .running(clients: 0), sourceCount: 1, embeddingModelCount: 1, lastIngestError: "notes: permission denied")
        XCTAssertEqual(idle.problems.map(\.id), ["ingest"])
        XCTAssertEqual(idle.problems.first?.detail, "notes: permission denied")

        let busy = StatusHealth(database: .running, mcp: .running(clients: 0), sourceCount: 1, embeddingModelCount: 1, lastIngestError: "notes: permission denied", isPipelineBusy: true)
        XCTAssertTrue(busy.isHealthy)
    }

    func testDiskAccessProblems() {
        let denied = StatusHealth(database: .running, mcp: .running(clients: 0), diskAccess: .denied(reason: "no bookmark"), sourceCount: 1, embeddingModelCount: 1)
        XCTAssertEqual(denied.problems.first?.title, "Garage can't read your disk")
        XCTAssertEqual(denied.problems.first?.severity, .critical)
        XCTAssertEqual(denied.problems.first?.fix, .chooseDisk)

        let stale = StatusHealth(database: .running, mcp: .running(clients: 0), diskAccess: .stale(path: "/Volumes/Data"), sourceCount: 1, embeddingModelCount: 1)
        XCTAssertEqual(stale.problems.first?.title, "Disk access needs renewing")
        XCTAssertEqual(stale.problems.first?.severity, .warning)
    }

    // MARK: - Indexing

    private func stats(
        documents: Int, expected: Int = 0, chunks: Int = 0, embedded: [Int] = [], distilled: Int = 0, facts: Int = 0, failed: Int = 0
    ) -> CorpusStats {
        CorpusStats(
            sourcesCount: 1,
            documentsCount: documents,
            documentsOkCount: documents - failed,
            documentsFailedCount: failed,
            totalChunks: chunks,
            embeddedChunks: embedded.first ?? 0,
            totalExpectedElements: expected,
            modelStats: embedded.enumerated().map {
                CorpusStats.ModelEmbeddingStats(slug: "m\($0.offset)", tableName: "emb_m\($0.offset)", isDefault: $0.offset == 0, embeddedCount: $0.element)
            },
            factsCount: facts,
            documentsDistilledCount: distilled,
            lastUpdated: Date()
        )
    }

    func testNoSourcesHasNothingToIndex() {
        let indexing = IndexingPresentation(stats: CorpusStats(), sourceCount: 0, modelCount: 0, distillsFacts: false)
        XCTAssertEqual(indexing.headline.title, "Nothing to index yet")
        XCTAssertEqual(indexing.action, .addSource)
        XCTAssertNil(indexing.headline.progress)
    }

    func testSourcesNeverScannedAreNotIndexedYet() {
        let indexing = IndexingPresentation(stats: CorpusStats(sourcesCount: 2), sourceCount: 2, modelCount: 1, distillsFacts: false)
        XCTAssertEqual(indexing.headline.title, "Not indexed yet")
        XCTAssertEqual(indexing.headline.detail, "2 sources · Update Everything scans, ingests, embeds and distills them.")
        XCTAssertEqual(indexing.action, .updateEverything(enabled: true))
    }

    func testUpToDateNamesTheCorpus() {
        let indexing = IndexingPresentation(
            stats: stats(documents: 1234, expected: 1234, chunks: 100, embedded: [100, 100], distilled: 1234, facts: 4000),
            sourceCount: 3, modelCount: 2, distillsFacts: true
        )
        XCTAssertEqual(indexing.headline.title, "Up to date")
        XCTAssertEqual(indexing.headline.detail, "1,234 documents in 3 sources · embedded under 2 models · facts distilled")
        XCTAssertEqual(indexing.headline.tint, .green)
        XCTAssertNil(indexing.headline.progress)
        XCTAssertEqual(indexing.fraction, 1)
    }

    func testUpToDateWithoutAModelOrFactsSaysOnlyWhatIsThere() {
        let indexing = IndexingPresentation(stats: stats(documents: 2, expected: 2, chunks: 10), sourceCount: 1, modelCount: 0, distillsFacts: false)
        XCTAssertEqual(indexing.headline.title, "Up to date")
        XCTAssertEqual(indexing.headline.detail, "2 documents in 1 source")
        XCTAssertNil(indexing.remaining.embeddingsToGo, "no model registered: nothing to embed with")
        XCTAssertNil(indexing.remaining.documentsToDistill)
    }

    func testBehindCountsEveryStageAndAveragesTheBar() throws {
        let indexing = IndexingPresentation(
            stats: stats(documents: 1180, expected: 1204, chunks: 10_000, embedded: [9_120], distilled: 880),
            sourceCount: 1, modelCount: 1, distillsFacts: true
        )
        XCTAssertEqual(indexing.remaining, IndexingPresentation.Remaining(documentsToIngest: 24, embeddingsToGo: 880, documentsToDistill: 300))
        XCTAssertEqual(indexing.headline.title, "1,204 items to index")
        XCTAssertEqual(indexing.headline.detail, "24 documents to ingest · 880 embeddings to go · 300 documents to distill")
        XCTAssertEqual(indexing.headline.tint, .orange)
        let expected = (1180.0 / 1204.0 + 9_120.0 / 10_000.0 + 880.0 / 1180.0) / 3
        XCTAssertEqual(try XCTUnwrap(indexing.headline.progress), expected, accuracy: 0.0001)
        XCTAssertEqual(indexing.headline.percent, MenuBarStatus.percent(expected))
        XCTAssertEqual(indexing.action, .updateEverything(enabled: true))
    }

    func testOneEmbeddingToGoIsSingular() {
        let indexing = IndexingPresentation(stats: stats(documents: 1, expected: 1, chunks: 1, embedded: [0]), sourceCount: 1, modelCount: 1, distillsFacts: false)
        XCTAssertEqual(indexing.headline.title, "1 item to index")
        XCTAssertEqual(indexing.headline.detail, "1 embedding to go")
    }

    func testTheLastRunsErrorReplacesTheLine() {
        let indexing = IndexingPresentation(
            stats: stats(documents: 2, expected: 2), sourceCount: 1, modelCount: 0, distillsFacts: false,
            lastRunError: "notes: permission denied\nstack"
        )
        XCTAssertEqual(indexing.headline.title, "Up to date")
        XCTAssertEqual(indexing.headline.detail, "notes: permission denied")
        XCTAssertTrue(indexing.headline.detailIsError)
    }

    func testAStoppedDatabaseHasNoAction() {
        let indexing = IndexingPresentation(stats: CorpusStats(), sourceCount: 2, modelCount: 1, distillsFacts: false, databaseIsRunning: false)
        XCTAssertEqual(indexing.headline.title, "Database stopped")
        XCTAssertEqual(indexing.action, .updateEverything(enabled: false))
    }

    func testRunningStagesShowTheirBarsAndStop() throws {
        let base = stats(documents: 10, expected: 20, chunks: 100, embedded: [50], distilled: 0)

        let scanning = IndexingPresentation(stats: base, sourceCount: 1, modelCount: 1, distillsFacts: true, activity: .scanning(source: "*", itemsSoFar: 1234))
        XCTAssertEqual(scanning.headline.title, "Scanning all sources…")
        XCTAssertEqual(scanning.headline.detail, "1,234 items so far")
        XCTAssertTrue(scanning.headline.isIndeterminate)
        XCTAssertEqual(scanning.headline.stage, .scan)
        XCTAssertEqual(scanning.action, .stop(isStopping: false))
        XCTAssertEqual(scanning.stageTrail, MenuBarStatus.Stage.allCases)

        let ingesting = IndexingPresentation(
            stats: base, sourceCount: 1, modelCount: 1, distillsFacts: true,
            activity: .ingesting(.init(subject: "notes", processed: 1204, total: 2860, indexed: 1180, skipped: 24, currentItem: "/Users/rick/Notes/retro.md"))
        )
        XCTAssertEqual(ingesting.headline.title, "Ingesting notes")
        XCTAssertEqual(ingesting.headline.percent, "42%")
        XCTAssertEqual(ingesting.headline.detail, "1,204 of 2,860 documents · 1,180 indexed · 24 skipped")
        XCTAssertEqual(ingesting.headline.stage, .ingest)
        XCTAssertEqual(try XCTUnwrap(ingesting.headline.progress), 1204.0 / 2860.0, accuracy: 0.0001)

        let embedding = IndexingPresentation(stats: base, sourceCount: 1, modelCount: 1, distillsFacts: true, activity: .embedding(model: "bge-m3", embedded: 9120, total: 10_000))
        XCTAssertEqual(embedding.headline.title, "Embedding with bge-m3")
        XCTAssertEqual(embedding.headline.percent, "91%")
        XCTAssertEqual(embedding.headline.detail, "9,120 of 10,000 chunks")
        XCTAssertEqual(embedding.headline.stage, .embed)

        let unsized = IndexingPresentation(stats: base, sourceCount: 1, modelCount: 1, distillsFacts: true, activity: .embedding(model: nil, embedded: 0, total: 0))
        XCTAssertEqual(unsized.headline.title, "Embedding new chunks")
        XCTAssertTrue(unsized.headline.isIndeterminate)

        let distilling = IndexingPresentation(stats: base, sourceCount: 1, modelCount: 1, distillsFacts: true, activity: .distilling(index: 30, total: 1000, document: "file:///Users/rick/Notes/a.md"))
        XCTAssertEqual(distilling.headline.title, "Gleaning facts")
        XCTAssertEqual(distilling.headline.percent, "3%")
        XCTAssertEqual(distilling.headline.detail, "30 of 1,000 documents")
        XCTAssertEqual(distilling.headline.stage, .distill)
        XCTAssertEqual(distilling.stageTrail, MenuBarStatus.Stage.allCases)

        let stopping = IndexingPresentation(stats: base, sourceCount: 1, modelCount: 1, distillsFacts: true, activity: .scanning(source: "*", itemsSoFar: 0), isStopping: true)
        XCTAssertEqual(stopping.headline.title, "Stopping…")
        XCTAssertEqual(stopping.action, .stop(isStopping: true))
    }

    func testFiguresCarryTheirNotes() {
        let indexing = IndexingPresentation(
            stats: stats(documents: 1234, expected: 1234, chunks: 56_789, embedded: [56_789, 50_000], distilled: 1200, facts: 4120, failed: 12),
            sourceCount: 3, modelCount: 2, distillsFacts: true
        )
        let figures = indexing.figures
        XCTAssertEqual(figures.map(\.label), ["Sources", "Documents", "Chunks", "Embedded", "Facts"])
        XCTAssertEqual(figures[0].value, "3")
        XCTAssertEqual(figures[1].value, "1,234")
        XCTAssertEqual(figures[1].note, "12 failed")
        XCTAssertTrue(figures[1].noteIsWarning)
        XCTAssertEqual(figures[2].value, "56,789")
        XCTAssertEqual(figures[3].value, "94%")
        XCTAssertEqual(figures[3].note, "2 models")
        XCTAssertEqual(figures[4].value, "4,120")
        XCTAssertEqual(figures[4].note, "from 1,200 documents")

        let noModel = IndexingPresentation(stats: stats(documents: 2, expected: 2), sourceCount: 1, modelCount: 0, distillsFacts: false)
        XCTAssertEqual(noModel.figures.map(\.label), ["Sources", "Documents", "Chunks", "Embedded"])
        XCTAssertEqual(noModel.figures[3].value, "–")
        XCTAssertEqual(noModel.figures[3].note, "no model")
    }

    // MARK: - Helper services

    func testGRPCRowReadsItsState() {
        let running = ServiceRowPresentation.grpc(status: .running, host: "127.0.0.1", port: 50051, lastTest: nil)
        XCTAssertEqual(running.name, "Index Manager")
        XCTAssertEqual(running.state, .running)
        XCTAssertEqual(running.stateTitle, "Running")
        XCTAssertTrue(running.detail.hasPrefix("On 127.0.0.1:50051 · "), running.detail)
        XCTAssertEqual(running.tint, .green)

        let tested = ServiceRowPresentation.grpc(status: .running, host: "127.0.0.1", port: 50051, lastTest: (isSuccess: true, summary: "5 queries"))
        XCTAssertEqual(tested.detail, "On 127.0.0.1:50051 · test passed")

        let failedTest = ServiceRowPresentation.grpc(status: .running, host: "127.0.0.1", port: 50051, lastTest: (isSuccess: false, summary: "GetStats: unavailable"))
        XCTAssertEqual(failedTest.detail, "GetStats: unavailable")
        XCTAssertTrue(failedTest.detailIsError)

        let failed = ServiceRowPresentation.grpc(status: .failed("bind: address in use"), host: "127.0.0.1", port: 50051, lastTest: nil)
        XCTAssertEqual(failed.state, .unreachable)
        XCTAssertEqual(failed.detail, "bind: address in use")
        XCTAssertTrue(failed.detailIsError)

        let stopped = ServiceRowPresentation.grpc(status: .stopped, host: "127.0.0.1", port: 50051, lastTest: nil)
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertEqual(stopped.stateTitle, "Stopped")
    }

    func testXPCRowReadsPingReportAndTest() {
        let service = XPCServiceInfo(
            id: "garage-xpc", name: "Garage Core Backend Helper", bundleId: "me.rickmark.garage-rag.xpc", serviceDescription: "",
            state: .running(pid: 42, latencyMs: 12.4, response: "pong")
        )
        let plain = ServiceRowPresentation.xpc(service, report: nil, test: nil)
        XCTAssertEqual(plain.name, "Garage Backend")
        XCTAssertEqual(plain.detail, "Running · 12 ms")
        XCTAssertFalse(plain.detailIsError)

        let python = GarageXPCPythonStatus(state: "ready")
        let report = GarageXPCStatusReport(
            serviceName: "garage", bundleIdentifier: service.bundleId, pid: 42, uptimeSeconds: 10, lifecycle: "ready", python: python,
            tests: [
                GarageXPCTestResult(name: "Python Runtime", testDescription: "", status: .passed, durationMs: 1, summary: "ok", details: ""),
                GarageXPCTestResult(name: "Llama Loader", testDescription: "", status: .failed, durationMs: 1, summary: "no reply", details: "", errorMessage: "timeout"),
            ]
        )
        let reported = ServiceRowPresentation.xpc(service, report: report, test: nil)
        XCTAssertEqual(reported.detail, "Running · 12 ms · 1 of 2 self tests passed")
        XCTAssertTrue(reported.detailIsError, "a failed self test colours the line")

        let failedTest = ServiceDiagnosticTestResult(
            serviceId: "garage-xpc", testName: "Self Tests", testDescription: "", isSuccess: false, durationMs: 3,
            summary: "1 of 2 self tests failed", details: ""
        )
        let tested = ServiceRowPresentation.xpc(service, report: report, test: failedTest)
        XCTAssertEqual(tested.detail, "1 of 2 self tests failed")
        XCTAssertTrue(tested.detailIsError)

        let unreachable = XPCServiceInfo(id: "llama-xpc", name: "", bundleId: "", serviceDescription: "", state: .unreachable(error: "Couldn't communicate with a helper application.\ndetails"))
        let down = ServiceRowPresentation.xpc(unreachable, report: nil, test: nil)
        XCTAssertEqual(down.name, "Inference")
        XCTAssertEqual(down.state, .unreachable)
        XCTAssertEqual(down.detail, "Can't be reached: Couldn't communicate with a helper application.")
        XCTAssertEqual(down.tint, .red)

        let checking = XPCServiceInfo(id: "embed-xpc", name: "", bundleId: "", serviceDescription: "", state: .checking)
        XCTAssertTrue(ServiceRowPresentation.xpc(checking, report: nil, test: nil).isBusy)
    }
}
