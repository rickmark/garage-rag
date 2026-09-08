import XCTest
import SwiftUI
import AppKit
@testable import GarageApp

final class GarageViewTests: XCTestCase {

    @MainActor
    func testContentViewHosting() {
        let appState = AppState()
        let contentView = ContentView()
            .environmentObject(appState)
        let hostingController = NSHostingController(rootView: contentView)
        XCTAssertNotNil(hostingController.view)
    }

    @MainActor
    func testStatusViewHosting() {
        let appState = AppState()
        let statusView = StatusView()
            .environmentObject(appState)
        let hostingController = NSHostingController(rootView: statusView)
        XCTAssertNotNil(hostingController.view)
    }

    @MainActor
    func testDatabaseViewHosting() {
        let appState = AppState()
        let databaseView = DatabaseView()
            .environmentObject(appState)
        let hostingController = NSHostingController(rootView: databaseView)
        XCTAssertNotNil(hostingController.view)
    }

    @MainActor
    func testDatabaseViewHostingWithPendingMigrations() {
        let appState = AppState()
        appState.postgres.setPendingMigrationsForTesting(["001_extensions.sql", "002_types.sql", "003_hybrid_search.sql"])
        let databaseView = DatabaseView()
            .environmentObject(appState)
        let hostingController = NSHostingController(rootView: databaseView)
        XCTAssertNotNil(hostingController.view)
    }

    @MainActor
    func testSourcesViewHosting() {
        let appState = AppState()
        let sourcesView = SourcesView()
            .environmentObject(appState)
        let hostingController = NSHostingController(rootView: sourcesView)
        XCTAssertNotNil(hostingController.view)
    }

    @MainActor
    func testSourcesViewHostingWithRegisteredSources() {
        let appState = AppState()
        appState.setRegisteredSourcesForTesting([
            RegisteredSource(slug: "docs", root: "~/Documents", includeCode: true, documentCount: 25, expectedElements: 30),
            RegisteredSource(slug: "notes", root: "~/Notes", documentCount: 5, expectedElements: 0)
        ])

        let sourcesView = SourcesView()
            .environmentObject(appState)
        let hostingController = NSHostingController(rootView: sourcesView)
        XCTAssertNotNil(hostingController.view)
    }

    @MainActor
    func testModelsViewHosting() {
        let appState = AppState()
        let modelsView = ModelsView()
            .environmentObject(appState)
        let hostingController = NSHostingController(rootView: modelsView)
        XCTAssertNotNil(hostingController.view)
    }

    @MainActor
    func testEmbeddingModelsViewHosting() {
        let appState = AppState()
        let embeddingModelsView = EmbeddingModelsView()
            .environmentObject(appState)
        let hostingController = NSHostingController(rootView: embeddingModelsView)
        XCTAssertNotNil(hostingController.view)
    }

    @MainActor
    func testLlamaModelsViewHosting() {
        let appState = AppState()
        let llamaModelsView = LlamaModelsView()
            .environmentObject(appState)
        let hostingController = NSHostingController(rootView: llamaModelsView)
        XCTAssertNotNil(hostingController.view)
    }

    @MainActor
    func testMCPServerViewHosting() {
        let appState = AppState()
        let mcpServerView = MCPServerView()
            .environmentObject(appState)
        let hostingController = NSHostingController(rootView: mcpServerView)
        XCTAssertNotNil(hostingController.view)
    }

    @MainActor
    func testSearchViewHosting() {
        let appState = AppState()
        let searchView = SearchView()
            .environmentObject(appState)
        let hostingController = NSHostingController(rootView: searchView)
        XCTAssertNotNil(hostingController.view)
    }

    @MainActor
    func testLogsViewHosting() {
        let appState = AppState()
        let logsView = LogsView()
            .environmentObject(appState)
        let hostingController = NSHostingController(rootView: logsView)
        XCTAssertNotNil(hostingController.view)
    }

    @MainActor
    func testMenuBarViewHosting() {
        let appState = AppState()
        let menuBarView = MenuBarView()
            .environmentObject(appState)
        let hostingController = NSHostingController(rootView: menuBarView)
        XCTAssertNotNil(hostingController.view)
    }

    func testLogSourceCases() {
        let cases = LogsView.LogSource.allCases
        XCTAssertEqual(cases.count, 7)
        XCTAssertEqual(cases.map(\.rawValue), ["Postgres", "garage CLI", "Ingest", "Backfill", "MCP Server", "gRPC Server", "Llama Service"])
    }
}
