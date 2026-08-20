import Foundation
import os

public enum MCPLegacySessionLookup: Sendable {
    case found(MCPLegacySession)
    case unknown
    case principalMismatch
}

public actor MCPLegacySessionStore {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.LegacySession")

    private let policy: MCPLegacySessionPolicy
    private let clock: any MCPClock

    private var sessions: [MCPLegacySessionId: MCPLegacySession] = [:]
    private var sweepTask: Task<Void, Never>?

    public init(policy: MCPLegacySessionPolicy = .standard, clock: any MCPClock = MCPSystemClock()) {
        self.policy = policy
        self.clock = clock
    }

    public func establish(
        owner: MCPLegacySessionOwner,
        protocolVersion: MCPProtocolVersion,
        clientInfo: MCPImplementation?,
        clientCapabilities: MCPClientCapabilities
    ) async -> MCPLegacySessionId {
        let now = await clock.now()

        if let reusable = reusableSessionId(owner: owner, protocolVersion: protocolVersion, clientInfo: clientInfo) {
            sessions[reusable]?.recordHandshake(
                protocolVersion: protocolVersion,
                clientInfo: clientInfo,
                clientCapabilities: clientCapabilities,
                now: now
            )
            Self.logger.info("Legacy session reused: \(reusable.redacted, privacy: .public)")
            return reusable
        }

        await evictUntilBelowCapacity()

        let session = MCPLegacySession(
            id: .generate(),
            owner: owner,
            protocolVersion: protocolVersion,
            clientInfo: clientInfo,
            clientCapabilities: clientCapabilities,
            createdAt: now
        )
        sessions[session.id] = session
        Self.logger.info(
            "Legacy session created: \(session.id.redacted, privacy: .public) version=\(protocolVersion.rawValue, privacy: .public)"
        )
        return session.id
    }

    public func lookup(id: MCPLegacySessionId, presentedBy principal: MCPPrincipal) async -> MCPLegacySessionLookup {
        let now = await clock.now()
        guard id.isWellFormed, var session = sessions[id] else {
            return .unknown
        }
        guard session.owner.owns(principal) else {
            return .principalMismatch
        }
        session.touch(now: now)
        sessions[id] = session
        return .found(session)
    }

    public func trackInFlight(id: MCPLegacySessionId, requestId: JsonRpcId, token: MCPCancellationToken) async {
        let now = await clock.now()
        sessions[id]?.trackInFlight(requestId: requestId, token: token)
        sessions[id]?.touch(now: now)
    }

    public func releaseInFlight(id: MCPLegacySessionId, requestId: JsonRpcId) async {
        let now = await clock.now()
        sessions[id]?.releaseInFlight(requestId: requestId)
        sessions[id]?.touch(now: now)
    }

    public func terminate(id: MCPLegacySessionId, reason: MCPLegacySessionTerminationReason) async {
        guard var session = sessions.removeValue(forKey: id) else { return }
        let pending = session.drainInFlight()
        Self.logger.info(
            "Legacy session terminated: \(id.redacted, privacy: .public) reason=\(reason.description, privacy: .public) cancelled=\(pending.count, privacy: .public)"
        )
        for token in pending {
            await token.cancel(reason: reason.cancellationReason)
        }
    }

    public func terminateAll(
        ownedByTokenId tokenId: UUID,
        reason: MCPLegacySessionTerminationReason
    ) async -> [MCPLegacySessionId] {
        let matching = sessions.filter { $0.value.owner.tokenId == tokenId }.map(\.key)
        for id in matching {
            await terminate(id: id, reason: reason)
        }
        return matching
    }

    public func count() -> Int {
        sessions.count
    }

    public func snapshots() -> [MCPLegacySessionSnapshot] {
        sessions.values.map(\.snapshot).sorted { $0.createdAt < $1.createdAt }
    }

    public func startIdleSweep() {
        guard sweepTask == nil else { return }
        let interval = policy.sweepInterval
        let sweepClock = clock
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await sweepClock.sleep(for: interval)
                } catch {
                    return
                }
                guard let self else { return }
                await self.runIdleSweep()
            }
        }
    }

    public func stopIdleSweep() {
        sweepTask?.cancel()
        sweepTask = nil
    }

    public func runIdleSweep() async {
        let now = await clock.now()
        let cutoff = now.addingTimeInterval(-policy.idleTimeoutSeconds)
        let expired = sessions.filter { $0.value.isIdle(at: cutoff) }.map(\.key)
        for id in expired {
            await terminate(id: id, reason: .idleTimeout)
        }
        if !expired.isEmpty {
            Self.logger.info("Idle sweep terminated \(expired.count, privacy: .public) legacy session(s)")
        }
    }

    public func shutdown(reason: MCPLegacySessionTerminationReason = .serverShutdown) async {
        stopIdleSweep()
        for id in Array(sessions.keys) {
            await terminate(id: id, reason: reason)
        }
    }

    private func reusableSessionId(
        owner: MCPLegacySessionOwner,
        protocolVersion: MCPProtocolVersion,
        clientInfo: MCPImplementation?
    ) -> MCPLegacySessionId? {
        sessions.first { entry in
            entry.value.owner == owner
                && entry.value.matchesHandshake(protocolVersion: protocolVersion, clientInfo: clientInfo)
        }?.key
    }

    private func evictionCandidate() -> MCPLegacySessionId? {
        let idle = sessions.filter { $0.value.inFlightRequestCount == 0 }
        let pool = idle.isEmpty ? sessions : idle
        return pool.min { $0.value.lastActivityAt < $1.value.lastActivityAt }?.key
    }

    private func evictUntilBelowCapacity() async {
        while sessions.count >= policy.maxSessions {
            guard let leastRecent = evictionCandidate() else {
                return
            }
            Self.logger.warning(
                "Legacy session capacity \(self.policy.maxSessions, privacy: .public) reached; evicting \(leastRecent.redacted, privacy: .public)"
            )
            await terminate(id: leastRecent, reason: .capacityEvicted)
        }
    }
}

public extension MCPProtocolError {
    static func sessionNotFound(message: String = "Session not found") -> Self {
        Self(code: JsonRpcErrorCode.sessionNotFound, message: message, httpStatus: .notFound)
    }
}
