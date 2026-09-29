//
//  TableEditDialect.swift
//  TablePro
//

import Foundation

/// How one engine names a table in `DROP` and rename statements, and whether such a statement is
/// final the moment it succeeds.
///
/// Only engines whose rules are known are covered. Everything else answers nil and a statement
/// run on it changes nothing the app keeps about its tables, because a name resolved the wrong way
/// would take one table's saved settings from another that still exists.
struct TableEditDialect: Sendable, Equatable {
    enum Folding: Sendable, Equatable {
        case lowercase
        case uppercase
        case preserve
    }

    /// What the first part of a two-part name is.
    enum TwoPartQualifier: Sendable, Equatable {
        case schema
        case database
        /// The engine tries more than one reading, so the name cannot be placed.
        case ambiguous
    }

    let folding: Folding
    /// Whether the app's scope keys a table by schema as well as by database.
    let keysBySchema: Bool
    /// Whether a bare name can be placed in the scope the statement ran in. SQL Server resolves one
    /// against the login's default schema, which the app does not track. PostgreSQL and DuckDB
    /// resolve one through a search path and a temporary namespace that a function, `set_config`
    /// or `SELECT ... INTO TEMP` can change without the text saying so, and the driver re-pins the
    /// schema only when its own record of it differs. On all three only a qualified name is placed.
    let resolvesUnqualifiedNames: Bool
    let twoPartQualifier: TwoPartQualifier
    let acceptsDatabaseSchemaTable: Bool
    /// MySQL, MariaDB, Oracle and ClickHouse commit DDL as it runs, so a `ROLLBACK` cannot bring a
    /// dropped table back there.
    let commitsDDLImplicitly: Bool
    let endCommits: Bool
    /// `USE x` moves the connection onto database `x`, rather than onto a catalog or a schema that
    /// a single name cannot tell apart.
    let useSelectsDatabase: Bool
    /// PostgreSQL, SQLite, Oracle, DuckDB and SQL Server's `sp_rename` keep a renamed table in its
    /// schema and take a bare new name. MySQL and ClickHouse resolve the new name like any other,
    /// which can move the table.
    let renameKeepsContainer: Bool
    /// MySQL's `ALTER TABLE a RENAME b`, with neither `TO` nor `AS`.
    let renamesWithoutTo: Bool
    /// A MySQL temporary table hides the real one under its qualified name too, so `DROP TABLE
    /// shop.people` drops the temporary `people` created in `shop`.
    let temporaryTablesShadowQualifiedNames: Bool
    /// Whether a temporary table here shadows a real one of the same name. An Oracle global
    /// temporary table is a permanent object with temporary rows, and shadows nothing.
    let temporaryTablesShadowRealOnes: Bool
    /// The containers that hold a session's own temporary objects, `pg_temp` and `pg_temp_3` or
    /// `temp`. A name inside one is never a table the app keeps settings for.
    let temporaryContainers: Set<String>
    /// SQL Server runs a batch whole, and T-SQL's `IF`, `GOTO` and `TRY...CATCH` can skip a statement
    /// inside it or swallow its error, so a batch that succeeded is not a list of statements that did.
    let branchesInsideBatches: Bool

    static func of(_ type: DatabaseType) -> TableEditDialect? {
        if type == .clickhouse { return .clickHouse }
        switch TransactionEngineFamily.of(type) {
        case .postgres, .redshift:
            return .postgreSQL
        case .mysql:
            return .mySQL
        case .sqlite:
            return .sqlite
        case .duckdb:
            return .duckDB
        case .sqlServer:
            return .sqlServer
        case .oracle:
            return .oracle
        case .cockroach, .redis, .other:
            return nil
        }
    }

    /// A bare word holding `@` is a variable or an Oracle database link, never a table here.
    func folded(_ part: SQLNamePart) -> String? {
        guard !part.text.isEmpty else { return nil }
        guard !part.isQuoted else { return part.text }
        guard !part.text.contains("@") else { return nil }
        switch folding {
        case .preserve:
            return part.text
        case .lowercase, .uppercase:
            /// A server folds only ASCII letters for certain; what it does with the rest depends on
            /// its encoding and locale, so such a name is left unplaced.
            guard part.text.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
            return folding == .lowercase ? part.text.lowercased() : part.text.uppercased()
        }
    }

    func namesTemporaryContainer(_ container: String) -> Bool {
        let lowered = container.lowercased()
        return temporaryContainers.contains { base in
            guard lowered != base else { return true }
            guard lowered.hasPrefix(base + "_") else { return false }
            let suffix = lowered.dropFirst(base.count + 1)
            return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
        }
    }

    func resolve(_ name: SQLObjectName, in context: TableNameContext) -> TablePlacement? {
        let parts = name.parts.compactMap(folded)
        guard parts.count == name.parts.count, let table = parts.last else { return nil }
        guard !parts.dropLast().contains(where: namesTemporaryContainer) else { return nil }
        switch parts.count {
        case 1:
            guard resolvesUnqualifiedNames, let database = context.database else { return nil }
            guard keysBySchema else { return TablePlacement(database: database, schema: nil, name: table) }
            guard let schema = context.schema else { return nil }
            return TablePlacement(database: database, schema: schema, name: table)
        case 2:
            switch twoPartQualifier {
            case .schema:
                guard let database = context.database else { return nil }
                return TablePlacement(database: database, schema: parts[0], name: table)
            case .database:
                return TablePlacement(database: parts[0], schema: nil, name: table)
            case .ambiguous:
                return nil
            }
        case 3:
            guard acceptsDatabaseSchemaTable else { return nil }
            return TablePlacement(database: parts[0], schema: parts[1], name: table)
        default:
            return nil
        }
    }

    func context(afterUsing name: SQLObjectName?) -> TableNameContext {
        guard useSelectsDatabase, let name, name.parts.count == 1, let database = folded(name.parts[0]) else {
            return TableNameContext(database: nil, schema: nil)
        }
        return TableNameContext(database: database, schema: nil)
    }

    static let postgreSQL = TableEditDialect(
        folding: .lowercase, keysBySchema: true, resolvesUnqualifiedNames: false, twoPartQualifier: .schema,
        acceptsDatabaseSchemaTable: true, commitsDDLImplicitly: false, endCommits: true,
        useSelectsDatabase: false, renameKeepsContainer: true, renamesWithoutTo: false,
        temporaryTablesShadowQualifiedNames: false, temporaryTablesShadowRealOnes: true,
        temporaryContainers: ["pg_temp"], branchesInsideBatches: false
    )

    static let mySQL = TableEditDialect(
        folding: .preserve, keysBySchema: false, resolvesUnqualifiedNames: true, twoPartQualifier: .database,
        acceptsDatabaseSchemaTable: false, commitsDDLImplicitly: true, endCommits: false,
        useSelectsDatabase: true, renameKeepsContainer: false, renamesWithoutTo: true,
        temporaryTablesShadowQualifiedNames: true, temporaryTablesShadowRealOnes: true,
        temporaryContainers: [], branchesInsideBatches: false
    )

    static let clickHouse = TableEditDialect(
        folding: .preserve, keysBySchema: false, resolvesUnqualifiedNames: true, twoPartQualifier: .database,
        acceptsDatabaseSchemaTable: false, commitsDDLImplicitly: true, endCommits: false,
        useSelectsDatabase: true, renameKeepsContainer: false, renamesWithoutTo: false,
        temporaryTablesShadowQualifiedNames: false, temporaryTablesShadowRealOnes: true,
        temporaryContainers: [], branchesInsideBatches: false
    )

    /// An attached database is a schema to SQLite, and a bare name can resolve into one, so only a
    /// bare name is placed, on the connection's own file.
    static let sqlite = TableEditDialect(
        folding: .preserve, keysBySchema: false, resolvesUnqualifiedNames: true, twoPartQualifier: .ambiguous,
        acceptsDatabaseSchemaTable: false, commitsDDLImplicitly: false, endCommits: true,
        useSelectsDatabase: false, renameKeepsContainer: true, renamesWithoutTo: false,
        temporaryTablesShadowQualifiedNames: false, temporaryTablesShadowRealOnes: true,
        temporaryContainers: ["temp"], branchesInsideBatches: false
    )

    /// `a.b` is a schema in the current catalog or the default schema of catalog `a`, whichever
    /// exists, so a two-part name is not placed.
    static let duckDB = TableEditDialect(
        folding: .preserve, keysBySchema: true, resolvesUnqualifiedNames: false, twoPartQualifier: .ambiguous,
        acceptsDatabaseSchemaTable: true, commitsDDLImplicitly: false, endCommits: true,
        useSelectsDatabase: false, renameKeepsContainer: true, renamesWithoutTo: false,
        temporaryTablesShadowQualifiedNames: false, temporaryTablesShadowRealOnes: true,
        temporaryContainers: ["temp"], branchesInsideBatches: false
    )

    static let sqlServer = TableEditDialect(
        folding: .preserve, keysBySchema: true, resolvesUnqualifiedNames: false, twoPartQualifier: .schema,
        acceptsDatabaseSchemaTable: true, commitsDDLImplicitly: false, endCommits: false,
        useSelectsDatabase: true, renameKeepsContainer: true, renamesWithoutTo: false,
        temporaryTablesShadowQualifiedNames: false, temporaryTablesShadowRealOnes: true,
        temporaryContainers: ["tempdb"], branchesInsideBatches: true
    )

    static let oracle = TableEditDialect(
        folding: .uppercase, keysBySchema: true, resolvesUnqualifiedNames: true, twoPartQualifier: .schema,
        acceptsDatabaseSchemaTable: false, commitsDDLImplicitly: true, endCommits: false,
        useSelectsDatabase: false, renameKeepsContainer: true, renamesWithoutTo: false,
        temporaryTablesShadowQualifiedNames: false, temporaryTablesShadowRealOnes: false,
        temporaryContainers: [], branchesInsideBatches: false
    )
}

/// The database and schema a bare name resolves in. Nil means the statements before this one
/// moved it somewhere the text does not say.
struct TableNameContext: Sendable, Equatable {
    var database: String?
    var schema: String?
}

/// Where a statement's table lives, in the app's own terms.
struct TablePlacement: Hashable, Sendable {
    let database: String
    let schema: String?
    let name: String

    var container: TableNameContext {
        TableNameContext(database: database, schema: schema)
    }
}
