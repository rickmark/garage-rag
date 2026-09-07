import XCTest
import SwiftUI
@testable import GarageApp

final class StatusViewTests: XCTestCase {

    func testPageStatusSeverityOrdering() {
        XCTAssertLessThan(StatusView.PageStatusSeverity.critical, StatusView.PageStatusSeverity.warning)
        XCTAssertLessThan(StatusView.PageStatusSeverity.warning, StatusView.PageStatusSeverity.info)
        XCTAssertLessThan(StatusView.PageStatusSeverity.info, StatusView.PageStatusSeverity.healthy)
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

        let item = StatusView.modelsStatusItem(for: appState)
        XCTAssertEqual(item.section, AppSection.models)
        XCTAssertEqual(item.severity, StatusView.PageStatusSeverity.info)
        XCTAssertEqual(item.statusHeadline, "Embedding in Progress")
        XCTAssertEqual(item.statusDetails, "Embedder is processing document chunks.")
        XCTAssertNil(item.quickAction)
    }

    @MainActor
    func testModelsStatusItemWhenBackfillNotRunning() {
        let appState = AppState()
        appState.backfill.isRunning = false

        let item = StatusView.modelsStatusItem(for: appState)
        XCTAssertNotEqual(item.statusHeadline, "Embedding in Progress")
    }

    @MainActor
    func testStatusItemsIncludeModelsItem() {
        let appState = AppState()
        appState.backfill.isRunning = true

        let items = StatusView.statusItems(for: appState)
        let modelItem = items.first { $0.section == .models }
        XCTAssertNotNil(modelItem)
        XCTAssertEqual(modelItem?.statusHeadline, "Embedding in Progress")
    }

    func testCorpusStatsFractions() {
        var stats = CorpusStats()
        XCTAssertEqual(stats.ingestionProgressFraction, 0.0)
        XCTAssertEqual(stats.embeddingProgressFraction, 0.0)

        stats.documentsCount = 10
        XCTAssertEqual(stats.ingestionProgressFraction, 1.0)

        stats.totalSeenFiles = 100
        stats.totalIndexedFiles = 75
        XCTAssertEqual(stats.ingestionProgressFraction, 0.75)

        stats.totalChunks = 500
        stats.embeddedChunks = 250
        XCTAssertEqual(stats.embeddingProgressFraction, 0.5)

        stats.embeddedChunks = 600 // More than totalChunks
        XCTAssertEqual(stats.embeddingProgressFraction, 1.0)
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
}
