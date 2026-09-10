import Foundation

public enum MCPCancellationReason: Sendable, Equatable {
    case clientRequested(String?)
    case clientDisconnected
    case deadlineExceeded
    case credentialRevoked
    case serverShuttingDown

    public var label: String {
        switch self {
        case .clientRequested:
            return "client_requested"
        case .clientDisconnected:
            return "client_disconnected"
        case .deadlineExceeded:
            return "deadline_exceeded"
        case .credentialRevoked:
            return "credential_revoked"
        case .serverShuttingDown:
            return "server_shutting_down"
        }
    }
}

public actor MCPCancellationToken {
    public typealias CancellationHandler = @Sendable (MCPCancellationReason) async -> Void

    private var cancellation: MCPCancellationReason?
    private var handlers: [CancellationHandler] = []

    public init() {}

    public var isCancelled: Bool {
        cancellation != nil
    }

    public var reason: MCPCancellationReason? {
        cancellation
    }

    public func cancel(reason: MCPCancellationReason = .clientRequested(nil)) async {
        guard cancellation == nil else { return }
        cancellation = reason
        let pending = handlers
        handlers.removeAll()
        for handler in pending {
            await handler(reason)
        }
    }

    public func onCancel(_ handler: @escaping CancellationHandler) async {
        guard let cancellation else {
            handlers.append(handler)
            return
        }
        await handler(cancellation)
    }

    public func throwIfCancelled() throws {
        guard cancellation == nil else { throw CancellationError() }
    }
}
