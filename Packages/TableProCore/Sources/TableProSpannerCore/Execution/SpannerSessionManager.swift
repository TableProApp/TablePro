import Foundation
import os

internal actor SpannerSessionManager {
    static let maximumIdleWriteSessions = 4

    private static let logger = Logger(subsystem: "com.TablePro", category: "SpannerSessionManager")

    private let client: SpannerRESTClient
    private var readSession: String?
    private var readSessionCreation: Task<String, Error>?
    private var idleWriteSessions: [String] = []
    private var ownedRegularSessions: Set<String> = []
    private var isShutDown = false

    init(client: SpannerRESTClient) {
        self.client = client
    }

    func readSessionName() async throws -> String {
        try ensureRunning()
        if let readSession {
            return readSession
        }
        if let readSessionCreation {
            return try await readSessionCreation.value
        }
        let creation = Task { try await self.createReadSession() }
        readSessionCreation = creation
        defer { readSessionCreation = nil }
        let name = try await creation.value
        try ensureRunning()
        readSession = name
        return name
    }

    func discardReadSession(_ name: String) {
        guard readSession == name else { return }
        readSession = nil
        ownedRegularSessions.remove(name)
    }

    func leaseWriteSession() async throws -> String {
        try ensureRunning()
        if let idle = idleWriteSessions.popLast() {
            return idle
        }
        let name = try await client.createSession(multiplexed: false)
        ownedRegularSessions.insert(name)
        guard !isShutDown else {
            ownedRegularSessions.remove(name)
            try? await client.deleteSession(name)
            throw SpannerExecutionError.closed
        }
        return name
    }

    func releaseWriteSession(_ name: String) async {
        guard !isShutDown, idleWriteSessions.count < Self.maximumIdleWriteSessions else {
            ownedRegularSessions.remove(name)
            try? await client.deleteSession(name)
            return
        }
        idleWriteSessions.append(name)
    }

    func discardWriteSession(_ name: String) {
        ownedRegularSessions.remove(name)
        for idle in idleWriteSessions {
            ownedRegularSessions.remove(idle)
        }
        idleWriteSessions.removeAll()
    }

    func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        readSessionCreation?.cancel()
        let owned = ownedRegularSessions
        ownedRegularSessions.removeAll()
        idleWriteSessions.removeAll()
        readSession = nil
        for name in owned {
            do {
                try await client.deleteSession(name)
            } catch {
                Self.logger.debug("Deleting a Spanner session during shutdown failed")
            }
        }
    }

    private func createReadSession() async throws -> String {
        do {
            return try await client.createSession(multiplexed: true)
        } catch let error as SpannerAPIError where Self.multiplexedUnsupported(error) {
            Self.logger.info("Multiplexed sessions unavailable, reading through a regular session")
            let name = try await client.createSession(multiplexed: false)
            ownedRegularSessions.insert(name)
            return name
        }
    }

    private func ensureRunning() throws {
        if isShutDown {
            throw SpannerExecutionError.closed
        }
    }

    private static func multiplexedUnsupported(_ error: SpannerAPIError) -> Bool {
        error.isInvalidArgument || error.status == "UNIMPLEMENTED" || error.code == 12 || error.httpStatus == 501
    }
}
