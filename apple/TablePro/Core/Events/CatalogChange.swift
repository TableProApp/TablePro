//
//  CatalogChange.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

/// What part of a connection's catalog may no longer match what the app has loaded.
///
/// A nil database reaches every database of the connection, and a nil schema every schema of the
/// database. Statement text can name another database or switch to one mid-script, so a change
/// derived from SQL is always connection-wide; only an operation that knows its own target narrows it.
struct CatalogChange: Sendable, Equatable {
    let connectionId: UUID
    let database: String?
    let schema: String?
    let kinds: SQLCatalogObjectKinds

    init(connectionId: UUID, database: String? = nil, schema: String? = nil, kinds: SQLCatalogObjectKinds) {
        self.connectionId = connectionId
        self.database = database?.nilIfEmpty
        self.schema = self.database == nil ? nil : schema?.nilIfEmpty
        self.kinds = kinds
    }

    func reaches(database candidate: String) -> Bool {
        guard let database else { return true }
        return database == candidate
    }

    func reaches(database candidate: String, schema candidateSchema: String?) -> Bool {
        guard reaches(database: candidate) else { return false }
        guard let schema else { return true }
        return schema == candidateSchema?.nilIfEmpty
    }

    func merging(_ other: CatalogChange) -> CatalogChange {
        let sharedDatabase = database == other.database ? database : nil
        let sharedSchema = sharedDatabase != nil && schema == other.schema ? schema : nil
        return CatalogChange(
            connectionId: connectionId,
            database: sharedDatabase,
            schema: sharedSchema,
            kinds: kinds.union(other.kinds)
        )
    }
}

/// Something that happened to a connection's catalog, as the caller that caused it knows it.
enum CatalogEvent: Sendable {
    case statementsRan(connectionId: UUID, statements: [String], databaseType: DatabaseType)
    case statementsSucceeded(SucceededStatements)
    case transactionEnded(connectionId: UUID)
    case tablesDropped([DatabaseTreeTableRef], connectionId: UUID)
    case tableRenamed(DatabaseTreeTableRef, to: String, connectionId: UUID)
    case containerDropped(DatabaseContainerRef, connectionId: UUID)
    case containerRenamed(DatabaseContainerRef, to: String, connectionId: UUID)
    case changed(CatalogChange)

    var connectionId: UUID {
        switch self {
        case .statementsRan(let connectionId, _, _),
             .transactionEnded(let connectionId),
             .tablesDropped(_, let connectionId),
             .tableRenamed(_, _, let connectionId),
             .containerDropped(_, let connectionId),
             .containerRenamed(_, _, let connectionId):
            return connectionId
        case .statementsSucceeded(let succeeded):
            return succeeded.scope.connectionId
        case .changed(let change):
            return change.connectionId
        }
    }
}

/// A database or schema that was dropped or renamed, for the tabs every window holds inside it.
struct DatabaseContainerChange: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case dropped
        case renamed(to: String)
    }

    let connectionId: UUID
    let container: DatabaseContainerRef
    let kind: Kind
}
