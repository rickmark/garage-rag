import XCTest
import SwiftUI
import LlamaClient
@testable import GarageApp

final class LlamaServiceTests: XCTestCase {

    @MainActor
    func testInitialServiceState() {
        let engine = LlamaServerEngine(modelPath: nil, modelAlias: "test-model", totalSlots: 2)
        let client = LlamaClient(inProcessEngine: engine)
        let service = LlamaService(client: client)

        XCTAssertFalse(service.isConnected)
        XCTAssertEqual(service.statusMessage, "Not connected")
        XCTAssertNil(service.health)
        XCTAssertNil(service.props)
        XCTAssertTrue(service.models.isEmpty)
        XCTAssertTrue(service.slots.isEmpty)
        XCTAssertEqual(service.statusColor, .secondary)
    }

    @MainActor
    func testPingAndRefreshStatus() async {
        let engine = LlamaServerEngine(modelPath: "/tmp/fake.gguf", modelAlias: "llama-3.2-1b", totalSlots: 2)
        let client = LlamaClient(inProcessEngine: engine)
        let service = LlamaService(client: client)

        let pingSuccess = await service.ping()
        XCTAssertTrue(pingSuccess)
        XCTAssertTrue(service.isConnected)
        XCTAssertEqual(service.statusMessage, "pong (in-process)")
        XCTAssertEqual(service.lastSuccess, "pong (in-process)")

        await service.refreshStatus()
        XCTAssertTrue(service.isConnected)
        XCTAssertNotNil(service.health)
        XCTAssertEqual(service.health?.status, "ok")
        XCTAssertEqual(service.statusColor, .green)
        XCTAssertNotNil(service.props)
        XCTAssertEqual(service.props?.modelAlias, "llama-3.2-1b")
        XCTAssertEqual(service.models.count, 1)
        XCTAssertEqual(service.models.first?.id, "llama-3.2-1b")
        XCTAssertEqual(service.activeModelId, "llama-3.2-1b")
        XCTAssertEqual(service.slots.count, 2)
    }

    @MainActor
    func testLoadAndUnloadModel() async {
        let engine = LlamaServerEngine(modelPath: nil, modelAlias: "initial-model", totalSlots: 1)
        let client = LlamaClient(inProcessEngine: engine)
        let service = LlamaService(client: client)

        // Loading empty path should fail with validation error
        let emptyPathResult = await service.loadModel(path: "   ")
        XCTAssertFalse(emptyPathResult)
        XCTAssertEqual(service.lastError, "Model path cannot be empty.")

        // Load valid path
        let loadResult = await service.loadModel(
            path: "/path/to/my-custom-model.gguf",
            alias: "my-custom-model",
            config: ["n_ctx": 4096, "n_gpu_layers": 33]
        )
        XCTAssertTrue(loadResult)
        XCTAssertNotNil(service.lastSuccess)
        XCTAssertEqual(service.activeModelId, "my-custom-model")

        // Unload model
        let unloadResult = await service.unloadModel()
        XCTAssertTrue(unloadResult)
        XCTAssertEqual(service.health?.status, "no_model_loaded")
        XCTAssertEqual(service.statusMessage, "No model loaded")
    }

    @MainActor
    func testSlotActions() async {
        let engine = LlamaServerEngine(modelPath: "/tmp/model.gguf", modelAlias: "slot-test", totalSlots: 1)
        let client = LlamaClient(inProcessEngine: engine)
        let service = LlamaService(client: client)

        await service.refreshStatus()
        XCTAssertEqual(service.slots.count, 1)

        let eraseResult = await service.performSlotAction(slotId: 0, action: "erase")
        XCTAssertTrue(eraseResult)
        XCTAssertEqual(service.lastSuccess, "Slot 0 action 'erase' completed.")

        let releaseResult = await service.performSlotAction(slotId: 0, action: "release")
        XCTAssertTrue(releaseResult)
        XCTAssertEqual(service.lastSuccess, "Slot 0 action 'release' completed.")
    }

    @MainActor
    func testCompletionAndTokenizePlayground() async {
        let engine = LlamaServerEngine(modelPath: "/tmp/model.gguf", modelAlias: "play-model", totalSlots: 1)
        let client = LlamaClient(inProcessEngine: engine)
        let service = LlamaService(client: client)

        // Test empty prompt validation
        let emptyPrompt = await service.testCompletion(prompt: "   ")
        XCTAssertFalse(emptyPrompt)
        XCTAssertEqual(service.lastError, "Prompt cannot be empty.")

        // Test valid completion
        let completionResult = await service.testCompletion(prompt: "Hello world!", maxTokens: 32)
        XCTAssertTrue(completionResult)
        XCTAssertNotNil(service.testOutput)
        XCTAssertTrue(service.testOutput?.contains("Processed response for:") == true)

        // Test empty tokenize validation
        let emptyTokenize = await service.testTokenize(text: "")
        XCTAssertFalse(emptyTokenize)
        XCTAssertEqual(service.lastError, "Text to tokenize cannot be empty.")

        // Test valid tokenize
        let tokenizeResult = await service.testTokenize(text: "Hello world")
        XCTAssertTrue(tokenizeResult)
        XCTAssertNotNil(service.testOutput)
        XCTAssertTrue(service.testOutput?.contains("Tokens (") == true)
    }

    @MainActor
    func testLoadBgeM3ModelAndRunEmbeddings() async throws {
        let modelPath = "/Users/rickmark/Desktop/bge-m3-Q8_0.gguf"
        let engine = LlamaServerEngine(modelPath: nil, modelAlias: "initial", totalSlots: 1)
        let client = LlamaClient(inProcessEngine: engine)
        let service = LlamaService(client: client)

        // 1. Load BGE-M3 model into LlamaService
        let loadSuccess = await service.loadModel(
            path: modelPath,
            alias: "bge-m3",
            config: ["n_ctx": 8192, "n_gpu_layers": 33]
        )
        XCTAssertTrue(loadSuccess)
        XCTAssertEqual(service.activeModelId, "bge-m3")
        XCTAssertNotNil(service.lastSuccess)
        XCTAssertEqual(service.health?.status, "ok")

        // 2. Test empty embedding text validation
        let emptyEmbed = await service.testEmbedding(text: "   ")
        XCTAssertFalse(emptyEmbed)
        XCTAssertEqual(service.lastError, "Text to embed cannot be empty.")

        // 3. Test interactive embedding verification via testEmbedding
        let embedPlaygroundSuccess = await service.testEmbedding(text: "BGE-M3 dense multilingual semantic embeddings")
        XCTAssertTrue(embedPlaygroundSuccess)
        XCTAssertNotNil(service.testOutput)
        XCTAssertTrue(service.testOutput?.contains("1024 dimensions") == true)
        XCTAssertEqual(service.lastSuccess, "Embedding generated (1024 dims).")

        // 3b. Test embedding with explicit model selection
        let embedExplicitModelSuccess = await service.testEmbedding(text: "BGE-M3 model explicit", model: "bge-m3")
        XCTAssertTrue(embedExplicitModelSuccess)
        XCTAssertNotNil(service.testOutput)
        XCTAssertTrue(service.testOutput?.contains("model: bge-m3") == true)
        XCTAssertEqual(service.lastSuccess, "Embedding generated (1024 dims, model: bge-m3).")

        // 4. Test programmatic batch embedding via service.embed
        let texts = [
            "What is the airspeed velocity of an unladen swallow?",
            "Garage local RAG and semantic search indexing engine."
        ]
        let embeddings = try await service.embed(texts: texts, dimensions: 1024)
        XCTAssertEqual(embeddings.count, 2)
        XCTAssertEqual(embeddings[0].count, 1024)
        XCTAssertEqual(embeddings[1].count, 1024)

        // 5. Verify L2 normalization
        let norm0 = sqrt(embeddings[0].reduce(0) { $0 + $1 * $1 })
        let norm1 = sqrt(embeddings[1].reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(norm0, 1.0, accuracy: 1e-4)
        XCTAssertEqual(norm1, 1.0, accuracy: 1e-4)

        // 6. Verify vectors are non-zero and distinct
        XCTAssertNotEqual(embeddings[0], embeddings[1])
    }

    @MainActor
    func testLoadBgeM3DefaultAliasInferenceAndEmbeddings() async throws {
        let modelPath = "/Users/rickmark/Desktop/bge-m3-Q8_0.gguf"
        let engine = LlamaServerEngine(modelPath: nil, modelAlias: "initial", totalSlots: 1)
        let client = LlamaClient(inProcessEngine: engine)
        let service = LlamaService(client: client)

        // Load without explicit alias - should infer "bge-m3-Q8_0"
        let loadSuccess = await service.loadModel(path: modelPath)
        XCTAssertTrue(loadSuccess)
        XCTAssertEqual(service.activeModelId, "bge-m3-Q8_0")

        // Embedding with default inferred dimensions should produce 1024-dim vectors
        let embeddings = try await service.embed(texts: ["Evaluating embedding inference without explicit dimensions"])
        XCTAssertEqual(embeddings.count, 1)
        XCTAssertEqual(embeddings[0].count, 1024)
    }

    @MainActor
    func testLogAppending() {
        let service = LlamaService()
        XCTAssertTrue(service.logs.isEmpty)

        service.appendLog("Started XPC service")
        service.appendLog("Error occurred", stream: .stderr)

        XCTAssertEqual(service.logs.count, 2)
        XCTAssertEqual(service.logs[0].text, "Started XPC service")
        XCTAssertEqual(service.logs[0].stream, .stdout)
        XCTAssertEqual(service.logs[0].source, "llama-xpc")
        XCTAssertEqual(service.logs[1].text, "Error occurred")
        XCTAssertEqual(service.logs[1].stream, .stderr)
    }
}
