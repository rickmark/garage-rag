import XCTest
import SwiftUI
import LlamaClient
import LlamaTestSupport
@testable import GarageApp

final class LlamaServiceTests: XCTestCase {

    @MainActor
    func testInitialServiceState() {
        let engine = MockLlamaServerEngine(modelPath: nil, modelAlias: "test-model", totalSlots: 2)
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
        let engine = MockLlamaServerEngine(modelPath: "/tmp/fake.gguf", modelAlias: "llama-3.2-1b", totalSlots: 2)
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
        let engine = MockLlamaServerEngine(modelPath: nil, modelAlias: "initial-model", totalSlots: 1)
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
        let engine = MockLlamaServerEngine(modelPath: "/tmp/model.gguf", modelAlias: "slot-test", totalSlots: 1)
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
        let engine = MockLlamaServerEngine(modelPath: "/tmp/model.gguf", modelAlias: "play-model", totalSlots: 1)
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
