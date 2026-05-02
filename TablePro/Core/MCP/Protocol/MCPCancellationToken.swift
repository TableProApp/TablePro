import Foundation

public actor MCPCancellationToken {
    private var cancelled: Bool = false
    private var handlers: [@Sendable () async -> Void] = []

    public init() {}

    public func cancel() async {
        guard !cancelled else { return }
        cancelled = true
        let toRun = handlers
        handlers.removeAll()
        for handler in toRun {
            await handler()
        }
    }

    public func isCancelled() async -> Bool {
        cancelled
    }

    public func onCancel(_ handler: @Sendable @escaping () async -> Void) async {
        if cancelled {
            await handler()
            return
        }
        handlers.append(handler)
    }

    public func throwIfCancelled() async throws {
        if cancelled {
            throw CancellationError()
        }
    }
}
