import Foundation

nonisolated public enum RedisTLSFailure: Error, Equatable {
    case contextRejected(code: Int)
    case handshakeFailed(String)
    case certificateNameMismatch(String)
}
