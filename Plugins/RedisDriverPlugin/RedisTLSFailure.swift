import Foundation

nonisolated enum RedisTLSFailure: Error, Equatable {
    case contextRejected(code: Int)
    case handshakeFailed(String)
    case certificateNameMismatch(String)
}
