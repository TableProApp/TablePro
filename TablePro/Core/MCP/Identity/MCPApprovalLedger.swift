import Foundation

/// Remembers which connections a client may reach.
///
/// Two tiers, because they answer to different lifetimes. A durable grant is a decision the user
/// made and belongs to a `MCPGrantSubject`, so it survives the server teardown that any settings
/// edit triggers, and a relaunch. A session approval is what a caller with no durable identity gets
/// instead: an anonymous loopback caller cannot be told apart from the next one, so remembering its
/// answer past this session would approve a process the user never saw.
public actor MCPApprovalLedger {
    public struct Key: Sendable, Equatable, Hashable {
        public let principalKey: String
        public let connectionId: UUID

        public init(principalKey: String, connectionId: UUID) {
            self.principalKey = principalKey
            self.connectionId = connectionId
        }
    }

    /// Long enough that a model retrying a refused call gives up before the user is asked twice,
    /// short enough that a user who meant to allow it can simply ask the client to try again.
    static let denialCoolOff: TimeInterval = 60

    private let ttl: Duration
    private let clock: any MCPClock
    private let store: any MCPApprovalStoring
    private var approvals: [Key: Date] = [:]
    private var denials: [Key: Date] = [:]

    public init(ttl: Duration = .seconds(1_800), clock: any MCPClock = MCPSystemClock()) {
        self.init(ttl: ttl, clock: clock, store: MCPApprovalStore.shared)
    }

    init(
        ttl: Duration = .seconds(1_800),
        clock: any MCPClock = MCPSystemClock(),
        store: any MCPApprovalStoring
    ) {
        self.ttl = ttl
        self.clock = clock
        self.store = store
    }

    public func isApproved(principal: MCPPrincipal, connectionId: UUID) async -> Bool {
        if let subject = principal.grantSubject {
            let granted = await store.grants().contains {
                $0.subject == subject.storageKey && $0.connectionId == connectionId
            }
            if granted { return true }
        }
        let now = await clock.now()
        prune(now: now)
        let key = Key(principalKey: principal.ledgerKey, connectionId: connectionId)
        guard let expiresAt = approvals[key] else { return false }
        return expiresAt > now
    }

    /// `remember` is the user's setting speaking. At Ask Every Time nothing is written, so the next
    /// call asks again; anything else would make the level a lie.
    public func record(
        principal: MCPPrincipal,
        connectionId: UUID,
        approved: Bool,
        remember: Bool = true
    ) async {
        let now = await clock.now()
        prune(now: now)
        let key = Key(principalKey: principal.ledgerKey, connectionId: connectionId)
        guard approved else {
            approvals.removeValue(forKey: key)
            if let subject = principal.grantSubject {
                await store.revoke(subject: subject.storageKey, connectionId: connectionId)
            }
            await recordDenial(principal: principal, connectionId: connectionId, now: now)
            return
        }
        guard remember else { return }
        if let subject = principal.grantSubject {
            await store.record(
                MCPConnectionGrant(subject: subject.storageKey, connectionId: connectionId, grantedAt: now)
            )
            return
        }
        approvals[key] = now.addingTimeInterval(Self.seconds(of: ttl))
    }

    /// How long a refusal stands before the client may raise the question with the user again.
    ///
    /// A caller with no durable identity still gets one, in memory: without it an unauthenticated
    /// local process that retries a refused call raises a fresh focus-stealing alert every time,
    /// which is the whole reason the cool-off exists.
    public func denialExpiry(principal: MCPPrincipal, connectionId: UUID) async -> Date? {
        let now = await clock.now()
        guard let subject = principal.grantSubject else {
            let key = Key(principalKey: principal.ledgerKey, connectionId: connectionId)
            denials = denials.filter { $0.value > now }
            return denials[key]
        }
        return await store.denial(subject: subject.storageKey, connectionId: connectionId, now: now)
    }

    /// Drops the approvals a revoked token was carrying. Rotating the bridge credential is not a
    /// revocation: the bridge re-mints itself roughly every 45 minutes and deletes the token it
    /// replaces, so treating that as the user withdrawing consent re-asks them all day.
    func clear(subject: MCPGrantSubject?) async {
        guard let subject else {
            approvals = approvals.filter { !$0.key.principalKey.hasPrefix("anon:") }
            return
        }
        await store.revokeAll(subject: subject.storageKey)
        if case .token(let tokenId) = subject {
            approvals = approvals.filter { $0.key.principalKey != tokenId.uuidString }
        }
    }

    public func revoke(subject: String, connectionId: UUID) async {
        await store.revoke(subject: subject, connectionId: connectionId)
        approvals = approvals.filter {
            !($0.key.principalKey == subject && $0.key.connectionId == connectionId)
        }
    }

    /// Ends the session's own approvals. Durable grants are untouched, because a server restart is
    /// not the user changing their mind.
    public func clearSessionApprovals() async {
        approvals.removeAll()
        denials.removeAll()
    }

    public func forgetEveryGrant() async {
        approvals.removeAll()
        denials.removeAll()
        await store.revokeEverything()
    }

    func grants() async -> [MCPConnectionGrant] {
        await store.grants()
    }

    public func approvedConnectionIds(principal: MCPPrincipal) async -> Set<UUID> {
        let now = await clock.now()
        prune(now: now)
        let principalKey = principal.ledgerKey
        var ids = Set(
            approvals
                .filter { $0.key.principalKey == principalKey && $0.value > now }
                .map(\.key.connectionId)
        )
        if let subject = principal.grantSubject {
            let durable = await store.grants()
                .filter { $0.subject == subject.storageKey }
                .map(\.connectionId)
            ids.formUnion(durable)
        }
        return ids
    }

    private func recordDenial(principal: MCPPrincipal, connectionId: UUID, now: Date) async {
        let expiresAt = now.addingTimeInterval(Self.denialCoolOff)
        guard let subject = principal.grantSubject else {
            denials[Key(principalKey: principal.ledgerKey, connectionId: connectionId)] = expiresAt
            return
        }
        await store.record(
            MCPConnectionDenial(
                subject: subject.storageKey,
                connectionId: connectionId,
                expiresAt: expiresAt
            )
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
