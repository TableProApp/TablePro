//
//  TemporaryTableStore.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProSQLGrammar

@MainActor
protocol TemporaryTableSessionReading: AnyObject {
    func browseScope(for connectionId: UUID) -> DatabaseScope?
    func temporaryTableSession(for scope: DatabaseScope) -> ObjectIdentifier?
    func readTemporaryTables(in scope: DatabaseScope) async throws -> TemporaryTableListing
}

struct TemporaryTableListing: Sendable, Equatable {
    let tables: [TableInfo]
    let session: ObjectIdentifier
}

@MainActor
final class TemporaryTableStore: ObservableObject, CatalogChangeTarget {
    static let shared = TemporaryTableStore()

    struct Key: Hashable, Sendable {
        let connectionId: UUID
        let database: String
    }

    private struct Load {
        let token: UUID
        let task: Task<Void, Never>
    }

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "TemporaryTableStore")

    @Published private(set) var listings: [Key: TemporaryTableListing] = [:]
    private var loads: [UUID: Load] = [:]
    private var pendingReloads: Set<UUID> = []
    private let reader: () -> TemporaryTableSessionReading

    init(reader: (() -> TemporaryTableSessionReading)? = nil) {
        self.reader = reader ?? { DatabaseManager.shared }
    }

    func tables(connectionId: UUID, database: String) -> [TableInfo] {
        guard let listing = listings[Key(connectionId: connectionId, database: database)],
              isCurrent(listing, connectionId: connectionId, database: database)
        else { return [] }
        return listing.tables
    }

    // Asked on every read a tab makes, so the name is matched before the session is looked up.
    func holds(table: String, in scope: DatabaseScope) -> Bool {
        guard let listing = listings[Key(connectionId: scope.connectionId, database: scope.database)],
              listing.tables.contains(where: { $0.name == table && ($0.schema == nil || $0.schema == scope.schema) })
        else { return false }
        return isCurrent(listing, connectionId: scope.connectionId, database: scope.database)
    }

    // A listing read on a connection that has since been replaced names tables that went with it.
    private func isCurrent(_ listing: TemporaryTableListing, connectionId: UUID, database: String) -> Bool {
        listing.session == reader().temporaryTableSession(
            for: DatabaseScope(connectionId: connectionId, database: database, schema: nil)
        )
    }

    // A refresh asked for during a read runs once more after it: the statement that asked may have ended after the
    // read began.
    func refresh(connectionId: UUID) {
        guard loads[connectionId] == nil else {
            pendingReloads.insert(connectionId)
            return
        }
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.drain(connectionId, token: token)
        }
        loads[connectionId] = Load(token: token, task: task)
    }

    func waitUntilIdle(connectionId: UUID) async {
        while let load = loads[connectionId] {
            await load.task.value
        }
    }

    func removeConnection(_ connectionId: UUID) {
        loads.removeValue(forKey: connectionId)?.task.cancel()
        pendingReloads.remove(connectionId)
        listings = listings.filter { $0.key.connectionId != connectionId }
    }

    private func drain(_ connectionId: UUID, token: UUID) async {
        repeat {
            pendingReloads.remove(connectionId)
            await load(connectionId)
        } while !Task.isCancelled && pendingReloads.contains(connectionId)
        if loads[connectionId]?.token == token {
            loads.removeValue(forKey: connectionId)
        }
    }

    private func load(_ connectionId: UUID) async {
        let reader = reader()
        guard let scope = reader.browseScope(for: connectionId),
              reader.temporaryTableSession(for: scope) != nil
        else { return }
        let key = Key(connectionId: connectionId, database: scope.database)
        do {
            let listing = try await reader.readTemporaryTables(in: scope)
            let stored = listing.tables.isEmpty ? nil : listing
            guard !Task.isCancelled, listings[key] != stored else { return }
            listings[key] = stored
        } catch {
            guard !DatabaseCancellationDiagnosis.isCancellation(error) else { return }
            Self.logger.warning("Temporary table read failed: \(error.publicLogShape, privacy: .public)")
        }
    }

    // MARK: - CatalogChangeTarget

    // Not awaited by the catalog drain: the read waits for the session's turn, which a long query can hold.
    func refreshCatalog(for change: CatalogChange) async {
        guard change.kinds.contains(.tables) else { return }
        refresh(connectionId: change.connectionId)
    }
}

extension DatabaseManager: TemporaryTableSessionReading {
    func temporaryTableSession(for scope: DatabaseScope) -> ObjectIdentifier? {
        guard let driver = sessionDriver(holding: scope), driver.listsTemporaryTables else { return nil }
        return ObjectIdentifier(driver)
    }

    func readTemporaryTables(in scope: DatabaseScope) async throws -> TemporaryTableListing {
        try await withMetadataDriver(scope: scope.sessionBound) { driver in
            TemporaryTableListing(tables: try await driver.fetchTemporaryTables(), session: ObjectIdentifier(driver))
        }
    }
}
