//
//  CatalogChangeService.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProSQLGrammar

/// A store that describes some part of a connection's catalog and can bring that part up to date.
@MainActor
protocol CatalogChangeTarget: AnyObject, Sendable {
    func refreshCatalog(for change: CatalogChange) async
    /// Whether other stores derive what they refresh from this one's answer, so it has to finish
    /// first. The database list is the case: completion providers read it for their namespaces.
    func refreshesBeforeOtherTargets(for change: CatalogChange) -> Bool
}

extension CatalogChangeTarget {
    func refreshesBeforeOtherTargets(for change: CatalogChange) -> Bool {
        false
    }
}

/// The one place a change to a connection's catalog is reported.
///
/// What a change means for state the connection owns is applied at once, and exactly once however
/// many windows show the connection. The refetches that follow are merged per connection, so a burst
/// of statements costs the refresh already running plus one more, never one per statement.
@MainActor
final class CatalogChangeService {
    static let shared = CatalogChangeService()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "CatalogChangeService")

    private let targets: [any CatalogChangeTarget]
    private let adoption: CatalogEditAdoption
    private let isSessionLive: @MainActor (UUID) -> Bool
    private let startupCommands: @MainActor (UUID) -> String?

    private var pendingChanges: [UUID: CatalogChange] = [:]
    private var nameHazards: [UUID: TableNameHazards] = [:]
    private var drains: [UUID: Task<Void, Never>] = [:]

    init(
        targets: [any CatalogChangeTarget]? = nil,
        adoption: CatalogEditAdoption? = nil,
        isSessionLive: (@MainActor (UUID) -> Bool)? = nil,
        startupCommands: (@MainActor (UUID) -> String?)? = nil
    ) {
        self.targets = targets ?? [
            SchemaRefreshService.shared,
            DatabaseTreeMetadataService.shared,
            SchemaProviderRegistry.shared,
            QueryCompletionProfileRegistry.shared
        ]
        self.adoption = adoption ?? CatalogEditAdoption()
        self.isSessionLive = isSessionLive ?? { connectionId in
            guard let session = DatabaseManager.shared.session(for: connectionId) else { return false }
            return Self.acceptsChanges(from: session)
        }
        self.startupCommands = startupCommands ?? { connectionId in
            DatabaseManager.shared.session(for: connectionId)?.connection.startupCommands
        }
    }

    /// A session mid-way through a database switch reports `.connecting` while its driver still works,
    /// so that status is accepted. One that is disconnected, failed or unreachable has nothing a
    /// refresh could read, and a change reported for it is dropped rather than queued.
    nonisolated static func acceptsChanges(from session: ConnectionSession) -> Bool {
        guard session.driver != nil else { return false }
        if case .unreachable = session.liveness { return false }
        switch session.status {
        case .connected, .connecting:
            return true
        case .disconnected, .error:
            return false
        }
    }

    nonisolated static func post(_ event: CatalogEvent) {
        Task { @MainActor in
            shared.record(event)
        }
    }

    func record(_ event: CatalogEvent) {
        let connectionId = event.connectionId
        guard isSessionLive(connectionId) else { return }
        switch event {
        case .statementsRan(_, let statements, let databaseType):
            recordStatements(statements, databaseType: databaseType, connectionId: connectionId)
        case .statementsSucceeded(let succeeded):
            recordCommittedTableEdits(of: succeeded)
        case .transactionEnded:
            schedule(CatalogChange(connectionId: connectionId, kinds: Self.transactionEndKinds))
        case .tablesDropped(let refs, _):
            recordDroppedTables(refs, connectionId: connectionId)
        case .tableRenamed(let ref, let newName, _):
            recordRenamedTable(ref, to: newName, connectionId: connectionId)
        case .containerDropped(let container, _):
            adoption.adoptContainerDrop(container, connectionId: connectionId)
            if container.kind == .database, let database = container.database {
                SchemaService.shared.forget(database: database, connectionId: connectionId)
            }
            AppCommands.shared.containerChanged.send(
                DatabaseContainerChange(connectionId: connectionId, container: container, kind: .dropped)
            )
            schedule(Self.change(for: container, connectionId: connectionId))
        case .containerRenamed(let container, let newName, _):
            adoption.adoptContainerRename(container, to: newName, connectionId: connectionId)
            if container.kind == .database, let database = container.database {
                SchemaService.shared.forget(database: database, connectionId: connectionId)
            }
            AppCommands.shared.containerChanged.send(
                DatabaseContainerChange(connectionId: connectionId, container: container, kind: .renamed(to: newName))
            )
            schedule(Self.change(for: container, connectionId: connectionId))
        case .changed(let change):
            schedule(change)
        }
    }

    func waitUntilIdle(connectionId: UUID) async {
        while let drain = drains[connectionId] {
            await drain.value
        }
    }

    private func recordStatements(_ statements: [String], databaseType: DatabaseType, connectionId: UUID) {
        recordNameHazards(of: statements, databaseType: databaseType, connectionId: connectionId)
        let effect = CatalogChangeClassifier.effect(ofStatements: statements, databaseType: databaseType)
        var kinds = effect.kinds
        if effect.endsTransaction {
            kinds.formUnion(Self.transactionEndKinds)
        }
        guard !kinds.isEmpty else { return }
        schedule(CatalogChange(connectionId: connectionId, kinds: kinds))
    }

    /// A table dropped or renamed by SQL the user or an MCP client ran is adopted exactly as the
    /// sidebar's own Drop and Rename are, one edit at a time in the order they ran, so a rename
    /// chain and a drop of a name another statement just freed both land on the right table.
    private func recordCommittedTableEdits(of succeeded: SucceededStatements) {
        let connectionId = succeeded.scope.connectionId
        recordNameHazards(
            of: DatabaseManager.startupStatements(from: startupCommands(connectionId)),
            databaseType: succeeded.databaseType,
            connectionId: connectionId
        )
        let grammar = SQLLexicalResolver.executionGrammar(for: succeeded.databaseType, connectionId: connectionId)
        var hazards = nameHazards[connectionId] ?? TableNameHazards()
        let edits = CommittedTableEdits.edits(in: succeeded, grammar: grammar, hazards: &hazards)
        nameHazards[connectionId] = hazards
        guard !edits.isEmpty else { return }
        Self.logger.debug(
            "[catalog] adopting \(edits.count) table edit(s) from SQL connId=\(connectionId, privacy: .public)"
        )
        for edit in edits {
            switch edit {
            case .dropped(let table, let kind):
                recordDroppedTables(
                    [adoption.tableRef(for: table, kind: kind, connectionId: connectionId)],
                    connectionId: connectionId
                )
            case .renamed(let table, let newName, let kind):
                recordRenamedTable(
                    adoption.tableRef(for: table, kind: kind, connectionId: connectionId),
                    to: newName,
                    connectionId: connectionId
                )
            }
        }
    }

    /// Read from every statement that may have run, failed ones included, because a procedure that
    /// failed part way can have created a temporary table first. That includes the connection's
    /// startup commands, which run on every connect before anything here hears of the session.
    private func recordNameHazards(of statements: [String], databaseType: DatabaseType, connectionId: UUID) {
        guard let dialect = TableEditDialect.of(databaseType) else { return }
        let grammar = SQLLexicalResolver.executionGrammar(for: databaseType, connectionId: connectionId)
        var hazards = nameHazards[connectionId] ?? TableNameHazards()
        for statement in statements {
            hazards.record(TableEditStatementParser.parse(statement, dialect: dialect, grammar: grammar), dialect: dialect)
        }
        nameHazards[connectionId] = hazards
    }

    private func recordDroppedTables(_ refs: [DatabaseTreeTableRef], connectionId: UUID) {
        guard !refs.isEmpty else { return }
        adoption.adoptDroppedTables(refs, connectionId: connectionId)
        var databases: Set<String> = []
        for ref in refs {
            guard let scope = adoption.objectScope(for: ref, connectionId: connectionId) else { continue }
            databases.insert(scope.database)
            AppCommands.shared.objectChanged.send(
                DatabaseObjectChange(connectionId: connectionId, scope: scope, name: ref.table.name, kind: .dropped)
            )
        }
        let database = databases.count == 1 ? databases.first : nil
        schedule(CatalogChange(connectionId: connectionId, database: database, kinds: .tables))
    }

    private func recordRenamedTable(_ ref: DatabaseTreeTableRef, to newName: String, connectionId: UUID) {
        guard let scope = adoption.objectScope(for: ref, connectionId: connectionId) else { return }
        adoption.adoptTableRename(ref, to: newName, connectionId: connectionId)
        AppCommands.shared.objectChanged.send(
            DatabaseObjectChange(
                connectionId: connectionId, scope: scope, name: ref.table.name, kind: .renamed(to: newName)
            )
        )
        schedule(CatalogChange(connectionId: connectionId, database: scope.database, kinds: .tables))
    }

    /// DDL inside an open transaction is invisible to the connection a refresh reads through until the
    /// transaction ends, and the statement that ends it may run on a different driver of the same
    /// connection than the one that ran the DDL. Remembering which transaction held catalog changes
    /// cannot tell those drivers apart, so every transaction end refreshes the objects and schemas.
    private static let transactionEndKinds: CatalogObjectKinds = [.objects, .schemas]

    private static func change(for container: DatabaseContainerRef, connectionId: UUID) -> CatalogChange {
        switch container.kind {
        case .database:
            return CatalogChange(connectionId: connectionId, kinds: .databases)
        case .schema:
            return CatalogChange(connectionId: connectionId, database: container.database, kinds: [.schemas, .objects])
        }
    }

    private func schedule(_ change: CatalogChange) {
        let connectionId = change.connectionId
        pendingChanges[connectionId] = pendingChanges[connectionId].map { $0.merging(change) } ?? change
        guard drains[connectionId] == nil else { return }
        drains[connectionId] = Task { [weak self] in
            await self?.drain(connectionId)
        }
    }

    private func drain(_ connectionId: UUID) async {
        while let change = pendingChanges.removeValue(forKey: connectionId) {
            await run(change)
        }
        drains.removeValue(forKey: connectionId)
    }

    private func run(_ change: CatalogChange) async {
        guard isSessionLive(change.connectionId) else { return }
        Self.logger.debug(
            "[catalog] refresh connId=\(change.connectionId, privacy: .public) database=\(change.database ?? "*", privacy: .public) kinds=\(change.kinds.rawValue)"
        )
        SchemaForeignKeyStore.shared.invalidate(connectionId: change.connectionId)
        let leading = targets.filter { $0.refreshesBeforeOtherTargets(for: change) }
        let following = targets.filter { !$0.refreshesBeforeOtherTargets(for: change) }
        for target in leading {
            await target.refreshCatalog(for: change)
        }
        await withTaskGroup(of: Void.self) { group in
            for target in following {
                group.addTask { await target.refreshCatalog(for: change) }
            }
        }
        adoption.pruneStaleOperations(connectionId: change.connectionId)
        AppCommands.shared.catalogChanged.send(change)
    }
}
