import Foundation
import IngestClient

/// Objective-C protocol exposed by `LlamaXPCService` over NSXPC.
@objc(LlamaXPCServiceProtocol)
public protocol LlamaXPCServiceProtocol: GarageCommonXPCServiceProtocol {
    /// Server health check matching GET /health
    func health(with reply: @escaping (String?, Error?) -> Void)

    /// Server properties and default generation parameters matching GET /props
    func props(with reply: @escaping (String?, Error?) -> Void)

    /// Models list matching GET /v1/models
    func models(with reply: @escaping (String?, Error?) -> Void)

    /// Text completion matching POST /completion and POST /v1/completions
    func completion(requestJson: String, with reply: @escaping (String?, Error?) -> Void)

    /// Chat completion matching POST /v1/chat/completions and POST /chat/completions
    func chatCompletion(requestJson: String, with reply: @escaping (String?, Error?) -> Void)

    /// Text embeddings matching POST /v1/embeddings and POST /embeddings
    func embeddings(requestJson: String, with reply: @escaping (String?, Error?) -> Void)

    /// Tokenize content matching POST /tokenize
    func tokenize(requestJson: String, with reply: @escaping (String?, Error?) -> Void)

    /// Detokenize tokens matching POST /detokenize
    func detokenize(requestJson: String, with reply: @escaping (String?, Error?) -> Void)

    /// Document rerank matching POST /v1/rerank and POST /rerank
    func rerank(requestJson: String, with reply: @escaping (String?, Error?) -> Void)

    /// Infill / fill-in-the-middle matching POST /infill
    func infill(requestJson: String, with reply: @escaping (String?, Error?) -> Void)

    /// Inspect server slots matching GET /slots
    func slots(with reply: @escaping (String?, Error?) -> Void)

    /// Manage a slot matching POST /slots/{id}?action=...
    func slotAction(slotId: Int, action: String, requestJson: String, with reply: @escaping (String?, Error?) -> Void)

    /// Generic HTTP server protocol replacement endpoint matching any HTTP method and route
    func handleServerRequest(endpoint: String, method: String, jsonBody: String?, with reply: @escaping (Int, String?, String?) -> Void)

    /// Load / configure a model in the XPC service
    func loadModel(modelPath: String, alias: String?, configJson: String?, with reply: @escaping (Bool, String?, Error?) -> Void)

    /// Unload current model
    func unloadModel(with reply: @escaping (Bool, Error?) -> Void)
}

public enum LlamaXPCConstants {
    public static let serviceName = "me.rickmark.garage-rag.llama-xpc"
    public static let machServiceName = "me.rickmark.garage-rag.llama-xpc"
}
