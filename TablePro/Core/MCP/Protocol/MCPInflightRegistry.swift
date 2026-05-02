import Foundation

actor MCPInflightRegistry {
    private struct Key: Hashable {
        let sessionId: MCPSessionId
        let requestId: JsonRpcId
    }

    private var entries: [Key: MCPCancellationToken] = [:]

    func register(requestId: JsonRpcId, sessionId: MCPSessionId, token: MCPCancellationToken) {
        entries[Key(sessionId: sessionId, requestId: requestId)] = token
    }

    func cancel(requestId: JsonRpcId, sessionId: MCPSessionId) async {
        let key = Key(sessionId: sessionId, requestId: requestId)
        guard let token = entries.removeValue(forKey: key) else { return }
        await token.cancel()
    }

    func remove(requestId: JsonRpcId, sessionId: MCPSessionId) {
        entries.removeValue(forKey: Key(sessionId: sessionId, requestId: requestId))
    }

    func count() -> Int {
        entries.count
    }
}
