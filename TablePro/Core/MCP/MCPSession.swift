import Foundation
import Network

actor MCPSession {
    let id: String
    let createdAt: ContinuousClock.Instant

    var lastActivityAt: ContinuousClock.Instant
    private(set) var phase: MCPSessionPhase = .created
    var clientInfo: MCPClientInfo?
    var sseConnection: NWConnection?
    var runningTasks: [JSONRPCId: Task<Void, Never>] = [:]
    private(set) var eventCounter: Int = 0
    private(set) var remoteAddress: String?

    var authenticatedTokenId: UUID? {
        if case .active(let tokenId, _) = phase { return tokenId }
        return nil
    }

    var tokenName: String? {
        if case .active(_, let tokenName) = phase { return tokenName }
        return nil
    }

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

    func transition(to next: MCPSessionPhase) throws {
        guard isValidTransition(from: phase, to: next) else {
            throw MCPError.invalidRequest(
                "Invalid session phase transition from \(phase) to \(next)"
            )
        }
        phase = next
    }

    private func isValidTransition(from current: MCPSessionPhase, to next: MCPSessionPhase) -> Bool {
        switch (current, next) {
        case (.created, .initializing),
             (.created, .active),
             (.created, .terminated),
             (.initializing, .active),
             (.initializing, .terminated),
             (.active, .terminated):
            return true
        default:
            return false
        }
    }

    func setClientInfo(_ info: MCPClientInfo?) {
        clientInfo = info
    }

    func setRemoteAddress(_ address: String?) {
        remoteAddress = address
    }

    func setSSEConnection(_ connection: NWConnection?) {
        sseConnection = connection
    }

    func cancelSSEConnection() {
        sseConnection?.cancel()
    }

    func addRunningTask(_ id: JSONRPCId, task: Task<Void, Never>) {
        runningTasks[id] = task
    }

    func removeRunningTask(_ id: JSONRPCId) -> Task<Void, Never>? {
        runningTasks.removeValue(forKey: id)
    }

    func nextEventId() -> String {
        eventCounter += 1
        return String(eventCounter)
    }
}
