import Foundation

public struct MCPInflightKey: Sendable, Hashable {
    // The bridge credential rotates while its requests run, so a cancellation sent with the renewed
    // one has to find a request started with the old one.
    public static let bridgeCredentialFingerprint = "stdio-bridge"

    public let clientFingerprint: String
    // Only for stdio without a bridge instance: stdio clients share one credential, so the sender's identity splits them.
    public let clientId: String
    // The whole stdio sender, since a request may carry clientInfo its cancellation lacks; Disconnect uses the entry's clientId.
    public let bridgeInstance: String
    public let requestId: JsonRpcId

    public init(clientFingerprint: String, clientId: String = "", bridgeInstance: String = "", requestId: JsonRpcId) {
        self.clientFingerprint = clientFingerprint
        self.clientId = clientId
        self.bridgeInstance = bridgeInstance
        self.requestId = requestId
    }

    public init(principal: MCPPrincipal, requestId: JsonRpcId) {
        self.init(clientFingerprint: principal.tokenFingerprint, requestId: requestId)
    }

    public init(bridgeInstance: String, requestId: JsonRpcId) {
        self.init(clientFingerprint: Self.bridgeCredentialFingerprint, bridgeInstance: bridgeInstance, requestId: requestId)
    }

    // A token one client holds ignores bridgeInstance: the field only splits requests of one stdio client kind.
    public init(client: MCPClientIdentity, bridgeInstance: String? = nil, requestId: JsonRpcId) {
        switch client.transport {
        case .stdioBridge:
            if let bridgeInstance, !bridgeInstance.isEmpty {
                self.init(bridgeInstance: bridgeInstance, requestId: requestId)
            } else {
                self.init(clientFingerprint: Self.bridgeCredentialFingerprint, clientId: client.id, requestId: requestId)
            }
        case .http:
            self.init(clientFingerprint: client.principalFingerprint, requestId: requestId)
        }
    }
}

public actor MCPInflightRegistry {
    private struct Entry {
        let token: MCPCancellationToken
        let tokenId: UUID?
        let clientId: String?
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
        clientId: String? = nil,
        method: String,
        startedAt: Date
    ) -> Bool {
        let displaced = entries[key] != nil
        entries[key] = Entry(token: token, tokenId: tokenId, clientId: clientId, method: method, startedAt: startedAt)
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
    public func cancelAll(matchingClientId clientId: String, reason: MCPCancellationReason) async -> Int {
        await cancelMatching(reason: reason) { _, entry in entry.clientId == clientId }
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
