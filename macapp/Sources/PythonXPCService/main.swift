import Foundation
#if canImport(PythonKit)
import PythonKit
#endif

@objc public protocol PythonXPCServiceProtocol {
    func ping(with reply: @escaping (String) -> Void)
}

final class PythonXPCServiceDelegate: NSObject, NSXPCListenerDelegate, PythonXPCServiceProtocol {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: PythonXPCServiceProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func ping(with reply: @escaping (String) -> Void) {
        reply("pong from PythonXPCService")
    }
}

let delegate = PythonXPCServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
