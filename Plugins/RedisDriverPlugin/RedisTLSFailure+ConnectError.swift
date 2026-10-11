import Foundation
import TableProPluginKit

extension RedisTLSFailure {
    var connectError: any Error {
        switch self {
        case .contextRejected(let code):
            return RedisPluginError(code: code, message: "Failed to create SSL context (error \(code))")
        case .certificateNameMismatch(let message):
            return SSLHandshakeError.hostnameMismatch(serverMessage: message)
        case .handshakeFailed(let message):
            if let classified = RedisSSLClassifier.classifySSLError(message) {
                return classified
            }
            return RedisPluginError(code: -1, message: "SSL handshake failed: \(message)")
        }
    }
}
