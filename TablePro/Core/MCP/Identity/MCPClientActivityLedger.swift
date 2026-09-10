import Foundation

public actor MCPClientActivityLedger {
    public struct Entry: Sendable, Identifiable, Equatable {
        public let id: String
        public let clientName: String
        public let clientVersion: String?
        public let tokenId: UUID?
        public let tokenName: String?
        public let address: String
        public let firstSeenAt: Date
        public let lastSeenAt: Date

        public init(
            id: String,
            clientName: String,
            clientVersion: String?,
            tokenId: UUID?,
            tokenName: String?,
            address: String,
            firstSeenAt: Date,
            lastSeenAt: Date
        ) {
            self.id = id
            self.clientName = clientName
            self.clientVersion = clientVersion
            self.tokenId = tokenId
            self.tokenName = tokenName
            self.address = address
            self.firstSeenAt = firstSeenAt
            self.lastSeenAt = lastSeenAt
        }
    }

    private let idleTimeout: Duration
    private let maxEntries: Int
    private var entries: [String: Entry] = [:]

    public init(idleTimeout: Duration = .seconds(300), maxEntries: Int = 200) {
        self.idleTimeout = idleTimeout
        self.maxEntries = maxEntries
    }

    public func record(
        meta: MCPRequestMeta,
        principal: MCPPrincipal,
        address: MCPClientAddress,
        at timestamp: Date
    ) async {
        let identity = MCPClientIdentity(meta: meta, principal: principal, address: address)
        record(identity: identity, at: timestamp)
    }

    public func record(identity: MCPClientIdentity, at timestamp: Date) {
        pruneIdle(now: timestamp)
        let existing = entries[identity.id]
        entries[identity.id] = Entry(
            id: identity.id,
            clientName: identity.clientName,
            clientVersion: identity.clientVersion,
            tokenId: identity.tokenId,
            tokenName: identity.tokenName,
            address: identity.addressDisplayValue,
            firstSeenAt: existing?.firstSeenAt ?? timestamp,
            lastSeenAt: timestamp
        )
        evictOverflow()
    }

    public func snapshot(now: Date) async -> [Entry] {
        pruneIdle(now: now)
        return entries.values.sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    public func prune(now: Date) async {
        pruneIdle(now: now)
    }

    public func forget(id: String) async {
        entries.removeValue(forKey: id)
    }

    public func forget(tokenId: UUID) async {
        entries = entries.filter { $0.value.tokenId != tokenId }
    }

    public func clearAll() async {
        entries.removeAll()
    }

    public func count(now: Date) async -> Int {
        pruneIdle(now: now)
        return entries.count
    }

    private func pruneIdle(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.seconds(of: idleTimeout))
        entries = entries.filter { $0.value.lastSeenAt > cutoff }
    }

    private func evictOverflow() {
        guard entries.count > maxEntries else { return }
        let ordered = entries.values.sorted { $0.lastSeenAt > $1.lastSeenAt }
        entries = Dictionary(uniqueKeysWithValues: ordered.prefix(maxEntries).map { ($0.id, $0) })
    }

    private static func seconds(of duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1.0e18
    }
}
