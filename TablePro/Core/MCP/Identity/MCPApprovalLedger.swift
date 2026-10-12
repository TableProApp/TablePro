import Foundation

/// Remembers which connections a client may reach. A grant is a decision the user made and belongs
/// to a `MCPGrantSubject`, so it survives the server teardown that a settings edit triggers, and a
/// relaunch.
public actor MCPApprovalLedger {
    /// Long enough that a model retrying a refused call gives up before the user is asked twice,
    /// short enough that a user who meant to allow it can simply ask the client to try again.
    static let denialCoolOff: TimeInterval = 60

    private let clock: any MCPClock
    private let store: any MCPApprovalStoring

    public init(clock: any MCPClock = MCPSystemClock()) {
        self.init(clock: clock, store: MCPApprovalStore.shared)
    }

    init(clock: any MCPClock = MCPSystemClock(), store: any MCPApprovalStoring) {
        self.clock = clock
        self.store = store
    }

    public func isApproved(principal: MCPPrincipal, connectionId: UUID) async -> Bool {
        let subject = principal.grantSubject.storageKey
        return await store.grants().contains { $0.subject == subject && $0.connectionId == connectionId }
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
        let subject = principal.grantSubject.storageKey
        guard approved else {
            await store.revoke(subject: subject, connectionId: connectionId)
            await store.record(
                MCPConnectionDenial(
                    subject: subject,
                    connectionId: connectionId,
                    expiresAt: now.addingTimeInterval(Self.denialCoolOff)
                )
            )
            return
        }
        guard remember else { return }
        await store.record(MCPConnectionGrant(subject: subject, connectionId: connectionId, grantedAt: now))
    }

    /// How long a refusal stands before the client may raise the question with the user again.
    public func denialExpiry(principal: MCPPrincipal, connectionId: UUID) async -> Date? {
        let now = await clock.now()
        return await store.denial(subject: principal.grantSubject.storageKey, connectionId: connectionId, now: now)
    }

    /// Drops the approvals a revoked token was carrying. Rotating the bridge credential is not a
    /// revocation: the bridge re-mints itself roughly every 45 minutes and deletes the token it
    /// replaces, so treating that as the user withdrawing consent re-asks them all day.
    func clear(subject: MCPGrantSubject) async {
        await store.revokeAll(subject: subject.storageKey)
    }

    public func revoke(subject: String, connectionId: UUID) async {
        await store.revoke(subject: subject, connectionId: connectionId)
    }

    public func forgetEveryGrant() async {
        await store.revokeEverything()
    }

    func grants() async -> [MCPConnectionGrant] {
        await store.grants()
    }

    public func approvedConnectionIds(principal: MCPPrincipal) async -> Set<UUID> {
        let subject = principal.grantSubject.storageKey
        return Set(await store.grants().filter { $0.subject == subject }.map(\.connectionId))
    }
}
