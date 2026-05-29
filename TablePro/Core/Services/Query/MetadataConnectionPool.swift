//
//  MetadataConnectionPool.swift
//  TablePro
//

import Foundation
import os

@MainActor
final class MetadataConnectionPool {
    static let shared = MetadataConnectionPool()

    private struct Key: Hashable {
        let connectionId: UUID
        let database: String
    }

    private final class Entry {
        let driver: DatabaseDriver
        var lastUsed: Date
        var inFlightCount: Int

        init(driver: DatabaseDriver) {
            self.driver = driver
            self.lastUsed = Date()
            self.inFlightCount = 0
        }
    }

    private var entries: [Key: Entry] = [:]
    private let maxPerConnection = 4
    private let connectTimeoutSeconds: UInt64 = 15
    private static let logger = Logger(subsystem: "com.TablePro", category: "MetadataConnectionPool")

    private init() {}

    func withDriver<T: Sendable>(
        connectionId: UUID,
        database: String,
        _ body: @Sendable (DatabaseDriver) async throws -> T
    ) async throws -> T {
        let entry = try await acquireEntry(connectionId: connectionId, database: database)
        entry.inFlightCount += 1
        entry.lastUsed = Date()
        defer { entry.inFlightCount -= 1 }
        return try await body(entry.driver)
    }

    func invalidate(connectionId: UUID, database: String) {
        let key = Key(connectionId: connectionId, database: database)
        entries[key]?.driver.disconnect()
        entries.removeValue(forKey: key)
    }

    func closeAll(connectionId: UUID) {
        let keys = entries.keys.filter { $0.connectionId == connectionId }
        for key in keys {
            entries[key]?.driver.disconnect()
            entries.removeValue(forKey: key)
        }
        if !keys.isEmpty {
            Self.logger.info(
                "[metadata-pool] closed all connId=\(connectionId, privacy: .public) count=\(keys.count, privacy: .public)"
            )
        }
    }

    private func acquireEntry(connectionId: UUID, database: String) async throws -> Entry {
        let key = Key(connectionId: connectionId, database: database)
        if let entry = entries[key], entry.driver.status == .connected {
            return entry
        }

        guard let session = DatabaseManager.shared.session(for: connectionId) else {
            throw DatabaseError.notConnected
        }

        evictIfNeeded(for: connectionId)

        let baseConnection = session.effectiveConnection ?? session.connection
        var cloned = baseConnection
        cloned.database = database

        let driver = try await DatabaseDriverFactory.createDriver(
            for: cloned,
            passwordOverride: session.cachedPassword,
            awaitPlugins: true
        )
        try await connectWithTimeout(driver: driver, database: database)
        let entry = Entry(driver: driver)
        entries[key] = entry
        Self.logger.info(
            "[metadata-pool] opened connId=\(connectionId, privacy: .public) db=\(database, privacy: .public)"
        )
        return entry
    }

    private func connectWithTimeout(driver: DatabaseDriver, database: String) async throws {
        let timeoutNanos = connectTimeoutSeconds * 1_000_000_000
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await driver.connect()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanos)
                throw NSError(
                    domain: "MetadataConnectionPool",
                    code: NSURLErrorTimedOut,
                    userInfo: [NSLocalizedDescriptionKey: String(
                        format: String(localized: "Connecting to '%@' timed out."), database
                    )]
                )
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func evictIfNeeded(for connectionId: UUID) {
        let mine = entries.filter { $0.key.connectionId == connectionId }
        guard mine.count >= maxPerConnection else { return }
        let idleEntries = mine.filter { $0.value.inFlightCount == 0 }
        let pool = idleEntries.isEmpty ? mine : idleEntries
        guard let oldest = pool.min(by: { $0.value.lastUsed < $1.value.lastUsed }) else { return }
        if idleEntries.isEmpty {
            Self.logger.warning(
                "[metadata-pool] cap reached but all in-flight; evicting busy connId=\(connectionId, privacy: .public) db=\(oldest.key.database, privacy: .public)"
            )
        }
        entries[oldest.key]?.driver.disconnect()
        entries.removeValue(forKey: oldest.key)
        Self.logger.info(
            "[metadata-pool] evicted connId=\(connectionId, privacy: .public) db=\(oldest.key.database, privacy: .public)"
        )
    }
}
