//
//  MetadataConnectionPool.swift
//  TablePro
//

import Foundation

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

    @MainActor
    private final class Entry {
        let driver: DatabaseDriver
        var lastUsed: Date
        var inFlightCount: Int
        var closeWhenIdle: Bool
        private var tail: Task<Void, Never> = Task {}

        init(driver: DatabaseDriver) {
            self.driver = driver
            self.lastUsed = Date()
            self.inFlightCount = 0
            self.closeWhenIdle = false
        }

        func runSerially<T: Sendable>(
            _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
        ) async throws -> T {
            let previous = tail
            let driver = self.driver
            let work = Task { @MainActor () async throws -> T in
                await previous.value
                return try await body(driver)
            }
            tail = Task { @MainActor in _ = try? await work.value }
            return try await work.value
        }
    }

    private var entries: [Key: Entry] = [:]
    private var pending: [Key: Task<Void, Error>] = [:]
    private let maxPerConnection = 6
    private let connectTimeoutSeconds: UInt64 = 15

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
        return try await entry.runSerially(body)
    }

    func closeAll(connectionId: UUID) {
        for key in pending.keys where key.connectionId == connectionId {
            pending[key]?.cancel()
            pending.removeValue(forKey: key)
        }
        for key in entries.keys where key.connectionId == connectionId {
            closeOrDeferEntry(forKey: key)
        }
    }

    private func releaseEntry(_ entry: Entry) {
        entry.inFlightCount -= 1
        if entry.inFlightCount == 0, entry.closeWhenIdle {
            entry.driver.disconnect()
        }
    }

    private func closeOrDeferEntry(forKey key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        if entry.inFlightCount == 0 {
            entry.driver.disconnect()
        } else {
            entry.closeWhenIdle = true
        }
    }

    private func acquireEntry(
        connectionId: UUID,
        database: String,
        schema: String?,
        workload: Workload
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
        defer { if pending[key] == task { pending.removeValue(forKey: key) } }
        try await task.value

        guard let entry = entries[key] else { throw DatabaseError.notConnected }
        return entry
    }

    private func openEntry(key: Key) async throws -> Entry {
        guard let session = DatabaseManager.shared.session(for: key.connectionId) else {
            throw DatabaseError.notConnected
        }
        var connection = session.effectiveConnection ?? session.connection
        connection.database = key.database

        let driver = try await DatabaseDriverFactory.createDriver(
            for: connection,
            passwordOverride: session.cachedPassword,
            awaitPlugins: true
        )
        do {
            try await connectWithTimeout(driver: driver, database: key.database)
            try? await driver.applyQueryTimeout(AppSettingsManager.shared.general.queryTimeoutSeconds)
            await DatabaseManager.shared.executeStartupCommands(
                session.connection.startupCommands, on: driver, connectionName: session.connection.name
            )
            if let schema = key.schema, let switchable = driver as? SchemaSwitchable {
                try await switchable.switchSchema(to: schema)
            }
        } catch {
            driver.disconnect()
            throw error
        }
        return Entry(driver: driver)
    }

    private func connectWithTimeout(driver: DatabaseDriver, database: String) async throws {
        let timeoutNanos = connectTimeoutSeconds * 1_000_000_000
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await driver.connect() }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanos)
                throw DatabaseError.connectionFailed(
                    String(format: String(localized: "Connecting to '%@' timed out."), database)
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
        let oldestIdle = live
            .filter { $0.value.inFlightCount == 0 }
            .min { $0.value.lastUsed < $1.value.lastUsed }
        guard let oldestIdle else { return }
        oldestIdle.value.driver.disconnect()
        entries.removeValue(forKey: oldestIdle.key)
    }
}
