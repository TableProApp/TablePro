import Foundation

public actor MCPApprovalLedger {
    public struct Key: Sendable, Equatable, Hashable {
        public let principalKey: String
        public let connectionId: UUID

        public init(principalKey: String, connectionId: UUID) {
            self.principalKey = principalKey
            self.connectionId = connectionId
        }
    }

    private let ttl: Duration
    private let clock: any MCPClock
    private var approvals: [Key: Date] = [:]

    public init(ttl: Duration = .seconds(1_800), clock: any MCPClock = MCPSystemClock()) {
        self.ttl = ttl
        self.clock = clock
    }

    public func isApproved(principal: MCPPrincipal, connectionId: UUID) async -> Bool {
        let now = await clock.now()
        prune(now: now)
        let key = Key(principalKey: principal.ledgerKey, connectionId: connectionId)
        guard let expiresAt = approvals[key] else { return false }
        return expiresAt > now
    }

    public func record(principal: MCPPrincipal, connectionId: UUID, approved: Bool) async {
        let now = await clock.now()
        prune(now: now)
        let key = Key(principalKey: principal.ledgerKey, connectionId: connectionId)
        guard approved else {
            approvals.removeValue(forKey: key)
            return
        }
        approvals[key] = now.addingTimeInterval(Self.seconds(of: ttl))
    }

    public func clear(tokenId: UUID?) async {
        guard let tokenId else {
            approvals = approvals.filter { !$0.key.principalKey.hasPrefix("anon:") }
            return
        }
        let principalKey = tokenId.uuidString
        approvals = approvals.filter { $0.key.principalKey != principalKey }
    }

    public func clearAll() async {
        approvals.removeAll()
    }

    public func approvedConnectionIds(principal: MCPPrincipal) async -> Set<UUID> {
        let now = await clock.now()
        prune(now: now)
        let principalKey = principal.ledgerKey
        return Set(
            approvals
                .filter { $0.key.principalKey == principalKey && $0.value > now }
                .map(\.key.connectionId)
        )
    }

    private func prune(now: Date) {
        approvals = approvals.filter { $0.value > now }
    }

    private static func seconds(of duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1.0e18
    }
}
