import Foundation

public protocol MCPMessageTransport: AnyObject, Sendable {
    var inbound: AsyncThrowingStream<JsonRpcMessage, Error> { get }
    func send(_ message: JsonRpcMessage) async throws
    func close() async
}

public enum MCPTransportError: Error, Sendable, Equatable {
    case closed
    case malformedFrame(detail: String)
    case writeFailed(detail: String)
    case readFailed(detail: String)
    case invalidEndpoint
    case authentication(httpStatus: Int, message: String)
    case sessionExpired
    case timeout
}
