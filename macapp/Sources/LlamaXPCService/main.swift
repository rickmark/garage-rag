import Foundation
import LlamaClient

final class LlamaXPCServiceDelegate: NSObject, NSXPCListenerDelegate, LlamaXPCServiceProtocol {
    private let engine = LlamaServerEngine.shared

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: LlamaXPCServiceProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func ping(with reply: @escaping (String) -> Void) {
        reply("pong from LlamaXPCService")
    }

    func health(with reply: @escaping (String?, Error?) -> Void) {
        let dict = engine.handleHealth()
        let json = engine.serializeJson(dict)
        reply(json, nil)
    }

    func props(with reply: @escaping (String?, Error?) -> Void) {
        let dict = engine.handleProps()
        let json = engine.serializeJson(dict)
        reply(json, nil)
    }

    func models(with reply: @escaping (String?, Error?) -> Void) {
        let dict = engine.handleModels()
        let json = engine.serializeJson(dict)
        reply(json, nil)
    }

    func completion(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        do {
            let dict = try engine.handleCompletion(jsonString: requestJson)
            let json = engine.serializeJson(dict)
            reply(json, nil)
        } catch {
            reply(nil, error)
        }
    }

    func chatCompletion(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        do {
            let dict = try engine.handleChatCompletion(jsonString: requestJson)
            let json = engine.serializeJson(dict)
            reply(json, nil)
        } catch {
            reply(nil, error)
        }
    }

    func embeddings(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        do {
            let dict = try engine.handleEmbeddings(jsonString: requestJson)
            let json = engine.serializeJson(dict)
            reply(json, nil)
        } catch {
            reply(nil, error)
        }
    }

    func tokenize(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        do {
            let dict = try engine.handleTokenize(jsonString: requestJson)
            let json = engine.serializeJson(dict)
            reply(json, nil)
        } catch {
            reply(nil, error)
        }
    }

    func detokenize(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        do {
            let dict = try engine.handleDetokenize(jsonString: requestJson)
            let json = engine.serializeJson(dict)
            reply(json, nil)
        } catch {
            reply(nil, error)
        }
    }

    func rerank(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        do {
            let dict = try engine.handleRerank(jsonString: requestJson)
            let json = engine.serializeJson(dict)
            reply(json, nil)
        } catch {
            reply(nil, error)
        }
    }

    func infill(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        do {
            let dict = try engine.handleInfill(jsonString: requestJson)
            let json = engine.serializeJson(dict)
            reply(json, nil)
        } catch {
            reply(nil, error)
        }
    }

    func slots(with reply: @escaping (String?, Error?) -> Void) {
        let dict = engine.handleSlots()
        let json = engine.serializeJson(dict)
        reply(json, nil)
    }

    func slotAction(slotId: Int, action: String, requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        do {
            let dict = try engine.handleSlotAction(slotId: slotId, action: action, jsonString: requestJson)
            let json = engine.serializeJson(dict)
            reply(json, nil)
        } catch {
            reply(nil, error)
        }
    }

    func handleServerRequest(endpoint: String, method: String, jsonBody: String?, with reply: @escaping (Int, String?, String?) -> Void) {
        let result = engine.handleRoute(endpoint: endpoint, method: method, jsonBody: jsonBody)
        reply(result.statusCode, result.responseBody, nil)
    }

    func loadModel(modelPath: String, alias: String?, configJson: String?, with reply: @escaping (Bool, String?, Error?) -> Void) {
        let res = engine.loadModel(path: modelPath, alias: alias, configJson: configJson)
        reply(res.success, res.message, nil)
    }

    func unloadModel(with reply: @escaping (Bool, Error?) -> Void) {
        let res = engine.unloadModel()
        reply(res, nil)
    }
}

let delegate = LlamaXPCServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
