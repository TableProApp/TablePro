//
//  ForeignKeyDialect.swift
//  TablePro
//

import Foundation

/// What each engine's `FOREIGN KEY` clause actually accepts.
///
/// Curated in the app and keyed by database type, the shape `ColumnDefaultVocabulary` already uses,
/// and for the same reason: the answer differs between two engines that share one plugin, and a
/// driver static cannot be added without a PluginKit ABI bump.
///
/// The grid used to offer `ReferentialAction.allCases` to every engine, so a DuckDB user picking
/// CASCADE got `Parser Error: FOREIGN KEY constraints cannot use CASCADE, SET NULL or SET DEFAULT`
/// from the server, and an Oracle user picking any ON UPDATE got a statement Oracle has no grammar
/// for. Every list here is measured against the engine or taken from its own grammar, and an engine
/// nobody has checked keeps the full set rather than being given another engine's answer.
struct ForeignKeyDialect: Equatable, Sendable {
    typealias Action = EditableForeignKeyDefinition.ReferentialAction

    /// What may follow `ON DELETE`. Empty means the engine has no `ON DELETE` clause.
    let deleteActions: [Action]
    /// What may follow `ON UPDATE`. Empty means the engine has no `ON UPDATE` clause, which is
    /// Oracle's and Dameng's case.
    let updateActions: [Action]
    /// Whether the referenced table may name a schema or database of its own. SQLite has no
    /// cross-schema foreign key, and DuckDB answers one with
    /// `Binder Error: Creating foreign keys across different schemas or catalogs is not supported`.
    let allowsQualifiedReferencedTable: Bool
    /// Whether the referenced column list may be left out, which means "the parent's primary key".
    /// Where it may not, an empty list is an issue rather than a `REFERENCES "t" ()` the server
    /// rejects.
    let allowsOmittedReferencedColumns: Bool

    private static let everyAction = Action.allCases

    static func forType(_ databaseType: DatabaseType) -> ForeignKeyDialect {
        switch databaseType {
        case .sqlite, .libsql, .turso, .cloudflareD1:
            return ForeignKeyDialect(
                deleteActions: everyAction,
                updateActions: everyAction,
                allowsQualifiedReferencedTable: false,
                allowsOmittedReferencedColumns: true
            )
        case .mysql, .mariadb:
            return ForeignKeyDialect(
                deleteActions: [.noAction, .restrict, .cascade, .setNull],
                updateActions: [.noAction, .restrict, .cascade, .setNull],
                allowsQualifiedReferencedTable: true,
                allowsOmittedReferencedColumns: false
            )
        case .postgresql, .pglite, .cockroachdb, .redshift:
            return ForeignKeyDialect(
                deleteActions: everyAction,
                updateActions: everyAction,
                allowsQualifiedReferencedTable: true,
                allowsOmittedReferencedColumns: true
            )
        case .duckdb:
            return ForeignKeyDialect(
                deleteActions: [.noAction, .restrict],
                updateActions: [.noAction, .restrict],
                allowsQualifiedReferencedTable: false,
                allowsOmittedReferencedColumns: true
            )
        case .mssql:
            return ForeignKeyDialect(
                deleteActions: [.noAction, .cascade, .setNull, .setDefault],
                updateActions: [.noAction, .cascade, .setNull, .setDefault],
                allowsQualifiedReferencedTable: true,
                allowsOmittedReferencedColumns: false
            )
        case .oracle, .dameng:
            return ForeignKeyDialect(
                deleteActions: [.noAction, .cascade, .setNull],
                updateActions: [],
                allowsQualifiedReferencedTable: true,
                allowsOmittedReferencedColumns: true
            )
        case .snowflake:
            return ForeignKeyDialect(
                deleteActions: everyAction,
                updateActions: everyAction,
                allowsQualifiedReferencedTable: true,
                allowsOmittedReferencedColumns: false
            )
        case .teradata:
            return ForeignKeyDialect(
                deleteActions: [.noAction],
                updateActions: [],
                allowsQualifiedReferencedTable: true,
                allowsOmittedReferencedColumns: false
            )
        default:
            return ForeignKeyDialect(
                deleteActions: everyAction,
                updateActions: everyAction,
                allowsQualifiedReferencedTable: true,
                allowsOmittedReferencedColumns: false
            )
        }
    }

    /// `NO ACTION` is the absence of a clause rather than a clause of its own, so it is accepted
    /// everywhere. Every driver omits `ON DELETE`/`ON UPDATE` entirely for it, and testing it as a
    /// listed action rejected every foreign key on the three engines whose `updateActions` is empty
    /// by design: an untouched row starts at `.noAction`.
    func supportsDelete(_ action: Action) -> Bool {
        action == .noAction || deleteActions.contains(action)
    }

    func supportsUpdate(_ action: Action) -> Bool {
        action == .noAction || updateActions.contains(action)
    }
}
