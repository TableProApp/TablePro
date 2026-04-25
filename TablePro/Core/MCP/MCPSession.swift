import Foundation
import Network

actor MCPSession {
    let id: String
    let createdAt: ContinuousClock.Instant

    var lastActivityAt: ContinuousClock.Instant
    var isInitialized: Bool = false
    var clientInfo: MCPClientInfo?
    var sseConnection: NWConnection?
    var runningTasks: [JSONRPCId: Task<Void, Never>] = [:]
    private(set) var eventCounter: Int = 0
    private(set) var authenticatedTokenId: UUID?
    private(set) var tokenName: String?
    private(set) var remoteAddress: String?

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

    func setInitialized(_ value: Bool) {
        isInitialized = value
    }

    func setClientInfo(_ info: MCPClientInfo?) {
        clientInfo = info
    }

    func setAuthenticatedTokenId(_ id: UUID?) {
        authenticatedTokenId = id
    }

    func setTokenName(_ name: String?) {
        tokenName = name
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
