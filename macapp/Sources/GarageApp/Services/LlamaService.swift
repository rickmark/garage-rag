import Foundation
import SwiftUI
import LlamaClient

/// Service managing the state and operations of the local Llama XPC service.
@MainActor
final class LlamaService: ObservableObject {
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var statusMessage: String = "Not connected"
    @Published private(set) var health: LlamaHealthResponse?
    @Published private(set) var props: LlamaPropsResponse?
    @Published private(set) var models: [LlamaModel] = []
    @Published private(set) var slots: [LlamaSlot] = []
    @Published private(set) var isBusy: Bool = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastSuccess: String?
    @Published private(set) var logs: [LogLine] = []
    @Published private(set) var testOutput: String?

    let client: LlamaClient
    private let maxLogLines = 2000

    init(client: LlamaClient = LlamaClient()) {
        self.client = client
    }

    var statusColor: Color {
        if !isConnected {
            return .secondary
        }
        if let health = health, health.status == "ok" {
            return .green
        }
        return .yellow
    }

    var activeModelId: String? {
        models.first?.id ?? props?.modelAlias
    }

    func appendLog(_ text: String, stream: LogLine.Stream = .stdout) {
        logs.append(LogLine(stream: stream, text: text, source: "llama-xpc"))
        if logs.count > maxLogLines {
            logs.removeFirst(logs.count - maxLogLines)
        }
    }

    func clearMessages() {
        lastError = nil
        lastSuccess = nil
    }

    func ping() async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            let pingResp = try await client.ping()
            isConnected = true
            statusMessage = pingResp
            lastSuccess = pingResp
            appendLog("Ping reply: \(pingResp)")
            return true
        } catch {
            isConnected = false
            statusMessage = "Service unavailable"
            lastError = error.localizedDescription
            appendLog("Ping failed: \(error.localizedDescription)", stream: .stderr)
            return false
        }
    }

    func refreshStatus() async {
        isBusy = true
        defer { isBusy = false }

        do {
            let pingResp = try await client.ping()
            isConnected = true

            let healthResp = try await client.health()
            self.health = healthResp

            let propsResp = try await client.props()
            self.props = propsResp

            let modelsResp = try await client.listModels()
            self.models = modelsResp.data

            let slotsResp = try await client.slots()
            self.slots = slotsResp

            if healthResp.status == "ok" {
                statusMessage = "Ready (\(modelsResp.data.first?.id ?? "model loaded"))"
            } else if healthResp.status == "no_model_loaded" {
                statusMessage = "No model loaded"
            } else {
                statusMessage = healthResp.status
            }
            lastError = nil
            appendLog("Status refreshed successfully: \(statusMessage) [\(pingResp)]")
        } catch {
            isConnected = false
            statusMessage = "Service unavailable"
            lastError = error.localizedDescription
            appendLog("Status refresh failed: \(error.localizedDescription)", stream: .stderr)
        }
    }

    @discardableResult
    func loadModel(path: String, alias: String? = nil, config: [String: Any]? = nil) async -> Bool {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            lastError = "Model path cannot be empty."
            return false
        }

        let effectiveAlias = alias?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? alias?.trimmingCharacters(in: .whitespacesAndNewlines)
            : (URL(fileURLWithPath: trimmedPath).deletingPathExtension().lastPathComponent)

        isBusy = true
        defer { isBusy = false }
        lastError = nil
        lastSuccess = nil

        do {
            appendLog("Loading model from '\(trimmedPath)' with alias '\(effectiveAlias ?? "default")'...")
            let message = try await client.loadModel(path: trimmedPath, alias: effectiveAlias, config: config)
            lastSuccess = message
            appendLog("Model loaded: \(message)")
            await refreshStatus()
            return true
        } catch {
            lastError = error.localizedDescription
            appendLog("Failed to load model: \(error.localizedDescription)", stream: .stderr)
            return false
        }
    }

    @discardableResult
    func unloadModel() async -> Bool {
        isBusy = true
        defer { isBusy = false }
        lastError = nil
        lastSuccess = nil

        do {
            appendLog("Unloading active model...")
            let success = try await client.unloadModel()
            if success {
                lastSuccess = "Model unloaded successfully."
                appendLog("Model unloaded successfully.")
                await refreshStatus()
                return true
            } else {
                lastError = "Failed to unload model."
                appendLog("Failed to unload model.", stream: .stderr)
                return false
            }
        } catch {
            lastError = error.localizedDescription
            appendLog("Error unloading model: \(error.localizedDescription)", stream: .stderr)
            return false
        }
    }

    @discardableResult
    func performSlotAction(slotId: Int, action: String) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        lastError = nil
        lastSuccess = nil

        do {
            appendLog("Performing slot action '\(action)' on slot \(slotId)...")
            let result = try await client.slotAction(slotId: slotId, action: action)
            lastSuccess = "Slot \(slotId) action '\(action)' completed."
            appendLog("Slot \(slotId) action completed: \(result)")
            if let refreshedSlots = try? await client.slots() {
                self.slots = refreshedSlots
            }
            return true
        } catch {
            lastError = error.localizedDescription
            appendLog("Slot action failed: \(error.localizedDescription)", stream: .stderr)
            return false
        }
    }

    @discardableResult
    func testCompletion(prompt: String, maxTokens: Int = 64, temperature: Float = 0.7) async -> Bool {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            lastError = "Prompt cannot be empty."
            return false
        }

        isBusy = true
        defer { isBusy = false }
        lastError = nil
        testOutput = nil

        do {
            appendLog("Generating completion for prompt: \"\(trimmedPrompt)\" (max tokens: \(maxTokens))...")
            let resp = try await client.complete(prompt: trimmedPrompt, maxTokens: maxTokens, temperature: temperature)
            testOutput = resp.content
            let predicted = resp.tokensPredicted ?? 0
            lastSuccess = "Completion generated (\(predicted) tokens)."
            appendLog("Completion finished: \(resp.content)")
            return true
        } catch {
            lastError = error.localizedDescription
            appendLog("Completion test failed: \(error.localizedDescription)", stream: .stderr)
            return false
        }
    }

    @discardableResult
    func testTokenize(text: String) async -> Bool {
        guard !text.isEmpty else {
            lastError = "Text to tokenize cannot be empty."
            return false
        }

        isBusy = true
        defer { isBusy = false }
        lastError = nil
        testOutput = nil

        do {
            appendLog("Tokenizing text: \"\(text)\"...")
            let resp = try await client.tokenize(content: text, withPieces: true)
            let formattedTokens = resp.tokens.map(String.init).joined(separator: ", ")
            testOutput = "Tokens (\(resp.tokens.count)):\n[\(formattedTokens)]"
            lastSuccess = "Tokenized into \(resp.tokens.count) tokens."
            appendLog("Tokenize finished: \(resp.tokens.count) tokens")
            return true
        } catch {
            lastError = error.localizedDescription
            appendLog("Tokenize test failed: \(error.localizedDescription)", stream: .stderr)
            return false
        }
    }

    @discardableResult
    func embed(texts: [String], dimensions: Int? = nil) async throws -> [[Float]] {
        return try await client.embed(texts: texts, model: activeModelId, dimensions: dimensions)
    }

    @discardableResult
    func testEmbedding(text: String, dimensions: Int? = nil) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Text to embed cannot be empty."
            return false
        }

        isBusy = true
        defer { isBusy = false }
        lastError = nil
        testOutput = nil

        do {
            appendLog("Generating embeddings for text: \"\(trimmed)\"...")
            let vectors = try await client.embed(texts: [trimmed], model: activeModelId, dimensions: dimensions)
            guard let firstVec = vectors.first else {
                lastError = "No embedding returned."
                return false
            }
            testOutput = "Embedding vector (\(firstVec.count) dimensions):\n[\(firstVec.prefix(8).map { String(format: "%.4f", $0) }.joined(separator: ", "))...]"
            lastSuccess = "Embedding generated (\(firstVec.count) dims)."
            appendLog("Embedding finished with \(firstVec.count) dimensions")
            return true
        } catch {
            lastError = error.localizedDescription
            appendLog("Embedding test failed: \(error.localizedDescription)", stream: .stderr)
            return false
        }
    }
}
