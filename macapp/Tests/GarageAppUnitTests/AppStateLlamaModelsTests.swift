import XCTest
import LlamaClient
import LlamaModelLoader
import LlamaTestSupport
@testable import GarageApp

final class AppStateLlamaModelsTests: XCTestCase {
    /// Records every alias the loader was asked to load; nothing is ever resident.
    private final class LoadRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var aliases: [String] = []

        var loaded: [String] {
            lock.lock()
            defer { lock.unlock() }
            return aliases
        }

        func record(_ alias: String) {
            lock.lock()
            aliases.append(alias)
            lock.unlock()
        }
    }

    private func model(_ slug: String, provider: String = "llama_xpc", isDefault: Bool = false) -> RegisteredModel {
        RegisteredModel(
            slug: slug, provider: provider, modelRef: slug, dims: 1024, storedDims: 1024,
            storageKind: "vector", indexKind: "hnsw", tableName: "emb_\(slug)", isDefault: isDefault
        )
    }

    @MainActor
    private func makeState(recorder: LoadRecorder) -> AppState {
        let loader = LlamaModelLoader(
            service: LlamaModelLoader.Service(
                residentAliases: { [] },
                ensure: { plan in
                    recorder.record(plan.alias)
                    return "loaded \(plan.alias)"
                }
            ),
            resolve: { LlamaModelLoadPlan(alias: $0, displayName: $0, path: "/tmp/\($0).gguf") }
        )
        let engine = MockLlamaServerEngine(modelPath: nil, modelAlias: "test-model", totalSlots: 1)
        let llama = LlamaService(client: LlamaClient(inProcessEngine: engine), modelLoader: loader)
        return AppState(llama: llama)
    }

    @MainActor
    func testDefaultEmbeddingModelPrefersTheFlaggedModel() {
        let state = makeState(recorder: LoadRecorder())
        state.setRegisteredModelsForTesting([model("nomic-embed"), model("bge-m3-q8", isDefault: true)])
        XCTAssertEqual(state.defaultEmbeddingModel?.slug, "bge-m3-q8")
    }

    @MainActor
    func testPreloadLoadsTheDefaultModelOncePerLaunch() async {
        let recorder = LoadRecorder()
        let state = makeState(recorder: recorder)
        state.setRegisteredModelsForTesting([model("nomic-embed"), model("bge-m3-q8", isDefault: true)])

        await state.preloadDefaultEmbeddingModel()
        await state.preloadDefaultEmbeddingModel()
        XCTAssertEqual(recorder.loaded, ["bge-m3-q8"])

        // A new default loads too.
        state.setRegisteredModelsForTesting([model("nomic-embed", isDefault: true), model("bge-m3-q8")])
        await state.preloadDefaultEmbeddingModel()
        XCTAssertEqual(recorder.loaded, ["bge-m3-q8", "nomic-embed"])
    }

    @MainActor
    func testPreloadSkipsModelsServedElsewhere() async {
        let recorder = LoadRecorder()
        let state = makeState(recorder: recorder)
        state.setRegisteredModelsForTesting([model("bge-m3", provider: "ollama", isDefault: true)])

        await state.preloadDefaultEmbeddingModel()
        XCTAssertTrue(recorder.loaded.isEmpty)
    }
}
