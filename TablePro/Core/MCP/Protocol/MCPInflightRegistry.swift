import Foundation

public struct MCPInflightKey: Sendable, Hashable {
    public let clientFingerprint: String
    public let requestId: JsonRpcId

    public init(clientFingerprint: String, requestId: JsonRpcId) {
        self.clientFingerprint = clientFingerprint
        self.requestId = requestId
    }

    public init(principal: MCPPrincipal, requestId: JsonRpcId) {
        self.init(clientFingerprint: principal.tokenFingerprint, requestId: requestId)
    }
}

public actor MCPInflightRegistry {
    private struct Entry {
        let token: MCPCancellationToken
        let tokenId: UUID?
        let method: String
        let startedAt: Date
    }

    private var entries: [MCPInflightKey: Entry] = [:]

    public init() {}

    @discardableResult
    public func register(
        key: MCPInflightKey,
        token: MCPCancellationToken,
        tokenId: UUID?,
        method: String,
        startedAt: Date
    ) -> Bool {
        let displaced = entries[key] != nil
        entries[key] = Entry(token: token, tokenId: tokenId, method: method, startedAt: startedAt)
        return !displaced
    }

    public func remove(key: MCPInflightKey, token: MCPCancellationToken) {
        guard let entry = entries[key], entry.token === token else { return }
        entries.removeValue(forKey: key)
    }

    @discardableResult
    public func cancel(key: MCPInflightKey, reason: MCPCancellationReason) async -> Bool {
        guard let entry = entries.removeValue(forKey: key) else { return false }
        await entry.token.cancel(reason: reason)
        return true
    }

    @discardableResult
    public func cancelAll(matchingTokenId tokenId: UUID, reason: MCPCancellationReason) async -> Int {
        await cancelMatching(reason: reason) { _, entry in entry.tokenId == tokenId }
    }

    @discardableResult
    public func cancelAll(matchingFingerprint fingerprint: String, reason: MCPCancellationReason) async -> Int {
        await cancelMatching(reason: reason) { key, _ in key.clientFingerprint == fingerprint }
    }

    @discardableResult
    public func cancelAll(reason: MCPCancellationReason) async -> Int {
        await cancelMatching(reason: reason) { _, _ in true }
    }

    public func contains(key: MCPInflightKey) -> Bool {
        entries[key] != nil
    }

    public func count() -> Int {
        entries.count
    }

    private func cancelMatching(
        reason: MCPCancellationReason,
        where predicate: (MCPInflightKey, Entry) -> Bool
    ) async -> Int {
        let matching = entries.filter { predicate($0.key, $0.value) }
        for (key, entry) in matching {
            entries.removeValue(forKey: key)
            await entry.token.cancel(reason: reason)
        }
        return matching.count
    }
}
