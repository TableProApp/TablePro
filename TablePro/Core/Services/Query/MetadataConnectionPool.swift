//
//  MetadataConnectionPool.swift
//  TablePro
//

import Foundation
import os

@MainActor
final class MetadataConnectionPool {
    static let shared = MetadataConnectionPool()

    enum Workload: Hashable, Sendable {
        case interactive
        case bulk
    }

    private struct Key: Hashable, Sendable {
        let connectionId: UUID
        let database: String
        let schema: String?
        let workload: Workload
    }

    private final class Entry {
        let driver: DatabaseDriver
        var lastUsed: Date
        var inFlightCount: Int
        var closeWhenIdle: Bool
        var tail: Task<Void, Never>

        init(driver: DatabaseDriver) {
            self.driver = driver
            self.lastUsed = Date()
            self.inFlightCount = 0
            self.closeWhenIdle = false
            self.tail = Task {}
        }
    }

    private var entries: [Key: Entry] = [:]
    private var pending: [Key: Task<Void, Error>] = [:]
    private let maxPerConnection = 6
    private let connectTimeoutSeconds: UInt64 = 15
    private static let logger = Logger(subsystem: "com.TablePro", category: "MetadataConnectionPool")

    private init() {}

    func withDriver<T: Sendable>(
        connectionId: UUID,
        database: String,
        schema: String? = nil,
        workload: Workload = .interactive,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        let entry = try await acquireEntry(
            connectionId: connectionId, database: database, schema: schema, workload: workload
        )
        entry.inFlightCount += 1
        entry.lastUsed = Date()
        defer { releaseEntry(entry) }

        let previous = entry.tail
        let driver = entry.driver
        let work = Task { @MainActor () async throws -> T in
            await previous.value
            return try await body(driver)
        }
        entry.tail = Task { @MainActor in _ = try? await work.value }
        return try await work.value
    }

    private func releaseEntry(_ entry: Entry) {
        entry.inFlightCount -= 1
        guard entry.inFlightCount == 0, entry.closeWhenIdle else { return }
        entry.driver.disconnect()
    }

    func invalidate(connectionId: UUID, database: String) {
        let matching = Set(entries.keys.filter { $0.connectionId == connectionId && $0.database == database })
            .union(pending.keys.filter { $0.connectionId == connectionId && $0.database == database })
        for key in matching {
            pending[key]?.cancel()
            pending.removeValue(forKey: key)
            closeOrDeferEntry(forKey: key)
        }
    }

    func closeAll(connectionId: UUID) {
        for key in pending.keys.filter({ $0.connectionId == connectionId }) {
            pending[key]?.cancel()
            pending.removeValue(forKey: key)
        }
        let keys = entries.keys.filter { $0.connectionId == connectionId }
        for key in keys {
            closeOrDeferEntry(forKey: key)
        }
        if !keys.isEmpty {
            Self.logger.info(
                "[metadata-pool] closed all connId=\(connectionId, privacy: .public) count=\(keys.count, privacy: .public)"
            )
        }
    }

    private func closeOrDeferEntry(forKey key: Key) {
        guard let entry = entries[key] else { return }
        entries.removeValue(forKey: key)
        if entry.inFlightCount == 0 {
            entry.driver.disconnect()
        } else {
            entry.closeWhenIdle = true
        }
    }

    private func acquireEntry(
        connectionId: UUID, database: String, schema: String?, workload: Workload
    ) async throws -> Entry {
        let key = Key(connectionId: connectionId, database: database, schema: schema, workload: workload)
        if let entry = entries[key], entry.driver.status == .connected {
            return entry
        }

        if let inFlight = pending[key] {
            try await inFlight.value
            guard let entry = entries[key] else { throw DatabaseError.notConnected }
            return entry
        }

        guard DatabaseManager.shared.session(for: connectionId) != nil else {
            throw DatabaseError.notConnected
        }

        evictIdleIfNeeded(for: connectionId)

        let task = Task<Void, Error> { [self] in
            let entry = try await openEntry(key: key)
            if Task.isCancelled {
                entry.driver.disconnect()
                return
            }
            entries[key] = entry
        }
        pending[key] = task
        do {
            try await task.value
        } catch {
            if pending[key] == task { pending.removeValue(forKey: key) }
            throw error
        }
        if pending[key] == task { pending.removeValue(forKey: key) }

        guard let entry = entries[key] else { throw DatabaseError.notConnected }
        return entry
    }

    private func openEntry(key: Key) async throws -> Entry {
        guard let session = DatabaseManager.shared.session(for: key.connectionId) else {
            throw DatabaseError.notConnected
        }
        let baseConnection = session.effectiveConnection ?? session.connection
        var cloned = baseConnection
        cloned.database = key.database

        let driver = try await DatabaseDriverFactory.createDriver(
            for: cloned,
            passwordOverride: session.cachedPassword,
            awaitPlugins: true
        )
        do {
            try await connectWithTimeout(driver: driver, database: key.database)
            do {
                try await driver.applyQueryTimeout(AppSettingsManager.shared.general.queryTimeoutSeconds)
            } catch {
                Self.logger.warning(
                    "[metadata-pool] query timeout not applied connId=\(key.connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
            await DatabaseManager.shared.executeStartupCommands(
                session.connection.startupCommands, on: driver, connectionName: session.connection.name
            )
            if let schema = key.schema, let switchable = driver as? SchemaSwitchable {
                do {
                    try await switchable.switchSchema(to: schema)
                } catch {
                    Self.logger.warning(
                        "[metadata-pool] schema switch failed, discarding connection connId=\(key.connectionId, privacy: .public) schema=\(schema, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                    throw error
                }
            }
        } catch {
            driver.disconnect()
            throw error
        }
        Self.logger.info(
            "[metadata-pool] opened connId=\(key.connectionId, privacy: .public) db=\(key.database, privacy: .public)"
        )
        return Entry(driver: driver)
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

    private func evictIdleIfNeeded(for connectionId: UUID) {
        let live = entries.filter { $0.key.connectionId == connectionId }
        let pendingCount = pending.keys.filter { $0.connectionId == connectionId }.count
        guard live.count + pendingCount >= maxPerConnection else { return }
        let idle = live.filter { $0.value.inFlightCount == 0 }
        guard let oldest = idle.min(by: { $0.value.lastUsed < $1.value.lastUsed }) else { return }
        entries[oldest.key]?.driver.disconnect()
        entries.removeValue(forKey: oldest.key)
        Self.logger.info(
            "[metadata-pool] evicted connId=\(connectionId, privacy: .public) db=\(oldest.key.database, privacy: .public)"
        )
    }
}
