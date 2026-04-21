import Foundation
import Network

final class MCPSession: Sendable {

    let id: String
    let createdAt: ContinuousClock.Instant

    // All mutable state is protected by MCPServer actor isolation.
    // Using nonisolated(unsafe) because MCPSession is only mutated
    // from within the MCPServer actor.
    nonisolated(unsafe) var lastActivityAt: ContinuousClock.Instant
    nonisolated(unsafe) var isInitialized: Bool = false
    nonisolated(unsafe) var clientInfo: MCPClientInfo?
    nonisolated(unsafe) var sseConnection: NWConnection?
    nonisolated(unsafe) var approvedConnectionIds: Set<UUID> = []
    nonisolated(unsafe) var runningTasks: [JSONRPCId: Task<Void, Never>] = [:]

    init() {
        self.id = UUID().uuidString
        let now = ContinuousClock.now
        self.createdAt = now
        self.lastActivityAt = now
    }

    func markActive() {
        lastActivityAt = .now
    }

    func cancelAllTasks() {
        for (_, task) in runningTasks {
            task.cancel()
        }
        runningTasks.removeAll()
    }
}
