import Foundation
import os

public enum MCPSessionStoreError: Error, Sendable, Equatable {
    case capacityExceeded(limit: Int)
    case sessionNotFound(MCPSessionId)
}

public actor MCPSessionStore {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Session")

    private let policy: MCPSessionPolicy
    private let clock: any MCPClock

    private var sessions: [MCPSessionId: MCPSession] = [:]
    private var eventSubscribers: [UUID: AsyncStream<MCPSessionEvent>.Continuation] = [:]
    private var cleanupTask: Task<Void, Never>?

    public init(policy: MCPSessionPolicy = .standard, clock: any MCPClock = MCPSystemClock()) {
        self.policy = policy
        self.clock = clock
    }

    public func create() async throws -> MCPSession {
        guard sessions.count < policy.maxSessions else {
            Self.logger.warning("Session capacity exceeded (limit \(self.policy.maxSessions))")
            throw MCPSessionStoreError.capacityExceeded(limit: policy.maxSessions)
        }

        let now = await clock.now()
        let session = MCPSession(now: now)
        sessions[session.id] = session
        Self.logger.info("Session created: \(session.id.rawValue, privacy: .public)")
        broadcast(.created(session.id))
        return session
    }

    public func session(id: MCPSessionId) async -> MCPSession? {
        sessions[id]
    }

    public func touch(id: MCPSessionId) async {
        guard let session = sessions[id] else { return }
        let now = await clock.now()
        await session.touch(now: now)
    }

    public func terminate(id: MCPSessionId, reason: MCPSessionTerminationReason) async {
        guard let session = sessions.removeValue(forKey: id) else { return }
        await session.terminate(reason: reason)
        Self.logger.info(
            "Session terminated: \(id.rawValue, privacy: .public) reason=\(reason.description, privacy: .public)"
        )
        broadcast(.terminated(id, reason: reason))
    }

    public func count() async -> Int {
        sessions.count
    }

    public func allSessions() async -> [MCPSession] {
        Array(sessions.values)
    }

    public func sessionIds(forPrincipalTokenId tokenId: UUID) async -> [MCPSessionId] {
        var matching: [MCPSessionId] = []
        for (sessionId, session) in sessions {
            let bound = await session.principalTokenId
            if bound == tokenId {
                matching.append(sessionId)
            }
        }
        return matching
    }

    public var events: AsyncStream<MCPSessionEvent> {
        let (stream, continuation) = AsyncStream<MCPSessionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        let subscriberId = UUID()
        eventSubscribers[subscriberId] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.removeSubscriber(subscriberId) }
        }
        return stream
    }

    public func startCleanup() async {
        guard cleanupTask == nil else { return }
        let interval = policy.cleanupInterval
        let clockRef = clock
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await clockRef.sleep(for: interval)
                } catch {
                    return
                }
                guard let self else { return }
                await self.runCleanupPass()
            }
        }
    }

    public func stopCleanup() async {
        cleanupTask?.cancel()
        cleanupTask = nil
    }

    public func runCleanupPass() async {
        let now = await clock.now()
        let idleSeconds = Self.seconds(of: policy.idleTimeout)
        let cutoff = now.addingTimeInterval(-idleSeconds)

        var expired: [MCPSessionId] = []
        for (sessionId, session) in sessions {
            let lastActivity = await session.lastActivityAt
            if lastActivity < cutoff {
                expired.append(sessionId)
            }
        }

        for sessionId in expired {
            await terminate(id: sessionId, reason: .idleTimeout)
        }

        if !expired.isEmpty {
            Self.logger.info("Idle cleanup terminated \(expired.count) session(s)")
        }
    }

    public func shutdown(reason: MCPSessionTerminationReason = .serverShutdown) async {
        await stopCleanup()
        let activeIds = Array(sessions.keys)
        for sessionId in activeIds {
            await terminate(id: sessionId, reason: reason)
        }
        for (_, continuation) in eventSubscribers {
            continuation.finish()
        }
        eventSubscribers.removeAll()
    }

    private func broadcast(_ event: MCPSessionEvent) {
        for (_, continuation) in eventSubscribers {
            continuation.yield(event)
        }
    }

    private func removeSubscriber(_ id: UUID) {
        eventSubscribers.removeValue(forKey: id)
    }

    private static func seconds(of duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1.0e18
    }
}
