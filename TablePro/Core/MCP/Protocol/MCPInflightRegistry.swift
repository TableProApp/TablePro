import Foundation

actor MCPInflightRegistry {
    private struct Key: Hashable {
        let sessionId: MCPSessionId
        let requestId: JsonRpcId
    }

    private struct Entry {
        let token: MCPCancellationToken
        let tokenId: UUID?
    }

    private var entries: [Key: Entry] = [:]

    func register(
        requestId: JsonRpcId,
        sessionId: MCPSessionId,
        token: MCPCancellationToken,
        tokenId: UUID? = nil
    ) {
        entries[Key(sessionId: sessionId, requestId: requestId)] = Entry(
            token: token,
            tokenId: tokenId
        )
    }

    func cancel(requestId: JsonRpcId, sessionId: MCPSessionId) async {
        let key = Key(sessionId: sessionId, requestId: requestId)
        guard let entry = entries.removeValue(forKey: key) else { return }
        await entry.token.cancel()
    }

    func cancelAll(matchingTokenId tokenId: UUID) async -> [MCPSessionId] {
        let matching = entries.filter { $0.value.tokenId == tokenId }
        for (key, entry) in matching {
            await entry.token.cancel()
            entries.removeValue(forKey: key)
        }
        return Array(Set(matching.map { $0.key.sessionId }))
    }

    func remove(requestId: JsonRpcId, sessionId: MCPSessionId) {
        entries.removeValue(forKey: Key(sessionId: sessionId, requestId: requestId))
    }

    func count() -> Int {
        entries.count
    }
}
