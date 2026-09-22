import XCTest
@testable import LlamaClient

final class LlamaClientTests: XCTestCase {
    var engine: LlamaServerEngine!
    var client: LlamaClient!

    override func setUp() {
        super.setUp()
        engine = LlamaServerEngine(modelPath: "/tmp/mock-model.gguf", modelAlias: "test-model", totalSlots: 2)
        client = LlamaClient(inProcessEngine: engine)
    }

    func testPing() async throws {
        let ping = try await client.ping()
        XCTAssertTrue(ping.contains("pong"))
    }

    func testHealth() async throws {
        let health = try await client.health()
        XCTAssertEqual(health.status, "ok")
        XCTAssertEqual(health.slotsIdle, 2)
        XCTAssertEqual(health.slotsProcessing, 0)
    }

    func testProps() async throws {
        let props = try await client.props()
        XCTAssertEqual(props.modelAlias, "test-model")
        XCTAssertEqual(props.totalSlots, 2)
        XCTAssertTrue(props.modalCapabilities?.contains("completion") == true)
        XCTAssertTrue(props.modalCapabilities?.contains("chat") == true)
        XCTAssertTrue(props.modalCapabilities?.contains("embeddings") == true)
    }

    func testListModels() async throws {
        let modelsResp = try await client.listModels()
        XCTAssertEqual(modelsResp.object, "list")
        XCTAssertEqual(modelsResp.data.count, 1)
        XCTAssertEqual(modelsResp.data[0].id, "test-model")
    }

    func testCompletion() async throws {
        let resp = try await client.complete(prompt: "Why is the sky blue?", maxTokens: 64)
        XCTAssertFalse(resp.content.isEmpty)
        XCTAssertEqual(resp.stop, true)
        XCTAssertEqual(resp.model, "test-model")
        XCTAssertGreaterThan(resp.tokensPredicted ?? 0, 0)
    }

    func testChatCompletion() async throws {
        let messages = [
            LlamaChatMessage(role: "system", content: "You are a helpful assistant."),
            LlamaChatMessage(role: "user", content: "Hello!")
        ]
        let resp = try await client.chat(messages: messages, maxTokens: 100)
        XCTAssertEqual(resp.object, "chat.completion")
        XCTAssertEqual(resp.choices.count, 1)
        XCTAssertEqual(resp.choices[0].message.role, "assistant")
        XCTAssertFalse(resp.choices[0].message.content.isEmpty)
        XCTAssertGreaterThan(resp.usage?.totalTokens ?? 0, 0)
    }

    func testEmbeddings() async throws {
        let texts = ["Hello world", "Swift XPC client for llama-server"]
        let embeddings = try await client.embed(texts: texts, model: "test-model", dimensions: 128)
        XCTAssertEqual(embeddings.count, 2)
        XCTAssertEqual(embeddings[0].count, 128)
        XCTAssertEqual(embeddings[1].count, 128)

        // Verify L2 normalized
        let norm0 = sqrt(embeddings[0].reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(norm0, 1.0, accuracy: 1e-4)
    }

    func testTokenizeAndDetokenize() async throws {
        let text = "Hello Llama!"
        let tokResp = try await client.tokenize(content: text, withPieces: true)
        XCTAssertFalse(tokResp.tokens.isEmpty)
        XCTAssertEqual(tokResp.pieces?.count, tokResp.tokens.count)

        let detok = try await client.detokenize(tokens: tokResp.tokens)
        XCTAssertEqual(detok, text)
    }

    func testRerank() async throws {
        let docs = ["Swift programming", "Cooking pizza recipe", "iOS development with XPC"]
        let resp = try await client.rerank(query: "Apple Swift and iOS", documents: docs, topN: 2)
        XCTAssertEqual(resp.results.count, 2)
        XCTAssertGreaterThanOrEqual(resp.results[0].relevanceScore, resp.results[1].relevanceScore)
    }

    func testInfill() async throws {
        let resp = try await client.infill(prefix: "def hello():", suffix: "return True")
        XCTAssertFalse(resp.content.isEmpty)
    }

    func testSlotsAndSlotAction() async throws {
        let slots = try await client.slots()
        XCTAssertEqual(slots.count, 2)

        let actionRes = try await client.slotAction(slotId: 0, action: "erase")
        XCTAssertEqual(actionRes["status"] as? String, "ok")
    }

    func testGenericServerRequest() async throws {
        // Test health endpoint
        let (code1, body1) = try await client.handleServerRequest(endpoint: "/health", method: "GET")
        XCTAssertEqual(code1, 200)
        XCTAssertTrue(body1.contains("ok"))

        // Test chat completions HTTP endpoint
        let chatPayload = "{\"messages\": [{\"role\": \"user\", \"content\": \"test message\"}]}"
        let (code2, body2) = try await client.handleServerRequest(endpoint: "/v1/chat/completions", method: "POST", jsonBody: chatPayload)
        XCTAssertEqual(code2, 200)
        XCTAssertTrue(body2.contains("chat.completion"))

        // Test non-existent endpoint returns 404
        let (code3, _) = try await client.handleServerRequest(endpoint: "/unknown_route", method: "GET")
        XCTAssertEqual(code3, 404)
    }

    func testModelLoadAndUnload() async throws {
        let loadMsg = try await client.loadModel(path: "/models/llama-3.gguf", alias: "llama-3")
        XCTAssertTrue(loadMsg.contains("loaded"))

        let models = try await client.listModels()
        XCTAssertEqual(models.data[0].id, "llama-3")

        let unloaded = try await client.unloadModel()
        XCTAssertTrue(unloaded)

        let health = try await client.health()
        XCTAssertEqual(health.status, "no_model_loaded")
    }

    func testLoadBgeM3ModelAndEmbeddings() async throws {
        let modelPath = "/Users/rickmark/Desktop/bge-m3-Q8_0.gguf"
        let loadMsg = try await client.loadModel(path: modelPath, alias: "bge-m3")
        XCTAssertTrue(loadMsg.contains("loaded successfully"))

        let models = try await client.listModels()
        XCTAssertEqual(models.data.first?.id, "bge-m3")

        let texts = [
            "Text representation for multi-lingual information retrieval",
            "Dense retrieval with BGE-M3 model"
        ]

        // 1. Explicit dimensions 1024
        let embeddings1024 = try await client.embed(texts: texts, model: "bge-m3", dimensions: 1024)
        XCTAssertEqual(embeddings1024.count, 2)
        XCTAssertEqual(embeddings1024[0].count, 1024)
        XCTAssertEqual(embeddings1024[1].count, 1024)

        let norm0 = sqrt(embeddings1024[0].reduce(0) { $0 + $1 * $1 })
        let norm1 = sqrt(embeddings1024[1].reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(norm0, 1.0, accuracy: 1e-4)
        XCTAssertEqual(norm1, 1.0, accuracy: 1e-4)

        // 2. Full request object endpoint testing with token usage verification
        let req = LlamaEmbeddingRequest(input: texts, model: "bge-m3", dimensions: 1024)
        let resp = try await client.embed(req)
        XCTAssertEqual(resp.object, "list")
        XCTAssertEqual(resp.data.count, 2)
        XCTAssertEqual(resp.data[0].embedding.count, 1024)
        XCTAssertEqual(resp.data[1].embedding.count, 1024)
        XCTAssertGreaterThan(resp.usage.totalTokens, 0)
    }

    func testLlamaClientSurfacesUnreachableHelper() async throws {
        // A client pointed at a helper that does not exist must fail every call: nothing answers from an
        // in-process engine, so a dead or crashed helper can never look healthy to the app.
        let disconnectedClient = LlamaClient(serviceName: "me.rickmark.nonexistent.llama-xpc")

        func expectServiceError(_ label: String, _ body: () async throws -> Void) async {
            do {
                try await body()
                XCTFail("\(label) should throw when the helper is unreachable")
            } catch {
                XCTAssertTrue(error is LlamaClientError, "\(label) threw \(type(of: error)), expected LlamaClientError")
            }
        }

        await expectServiceError("ping()") { _ = try await disconnectedClient.ping() }
        await expectServiceError("health()") { _ = try await disconnectedClient.health() }
        await expectServiceError("props()") { _ = try await disconnectedClient.props() }
        await expectServiceError("listModels()") { _ = try await disconnectedClient.listModels() }
        await expectServiceError("complete()") { _ = try await disconnectedClient.complete(prompt: "Hello", maxTokens: 10) }
        await expectServiceError("embed()") { _ = try await disconnectedClient.embed(texts: ["Hello"]) }
        await expectServiceError("unloadModel()") { _ = try await disconnectedClient.unloadModel() }
    }
}
