//
//  MySQLPluginDriver+CatalogFallback.swift
//  MySQLDriverPlugin
//
//  What a whole-schema read does when `information_schema` does not describe the database it was
//  asked about.
//
//  A MySQL-protocol proxy answers the catalog from its own configuration. Measured: DBLE 3.23
//  answers every catalog read with no rows, MyCat 1.6.7.5 throws `ERROR 1064` for a logical schema,
//  and ShardingSphere-Proxy 5.5.3 answers zero rows for a logical database name. `SHOW FULL TABLES`,
//  `SHOW FULL COLUMNS`, `SHOW INDEX` and `SHOW CREATE TABLE` tell the truth through all three.
//

import Foundation
import os
import TableProPluginKit

internal extension MySQLPluginDriver {
    /// The catalog read, with the `SHOW` statements standing in for it where it is blind.
    ///
    /// A connection with no database selected has nothing to name in a `SHOW … FROM` clause, so it
    /// takes the catalog answer as it stands rather than falling back to a statement the server
    /// answers with `ERROR 1102`.
    func catalogOrShow<Value>(
        database: String,
        catalog: () async throws -> [String: Value],
        show: () async throws -> [String: Value]
    ) async throws -> [String: Value] {
        guard !database.isEmpty else { return try await catalog() }
        return try await MySQLCatalogFallback.read(
            database: database,
            ledger: catalogVisibility,
            catalog: catalog,
            settlesBlindness: Self.settlesBlindness,
            probe: { try await self.catalogDescribes(database) },
            show: show
        )
    }

    static func settlesBlindness(_ error: any Error) -> Bool {
        guard let error = error as? MariaDBPluginError else { return false }
        return MySQLCatalogVisibilityRule.settlesBlindness(code: error.code)
    }

    func catalogDescribes(_ database: String) async throws -> MySQLCatalogProbe {
        try await MySQLCatalogFallback.visibility(
            of: database,
            ledger: catalogVisibility,
            catalogTableCount: { try await self.catalogTableCount(database: database) },
            listedTableCount: { try await self.listedTableCount(database: database) }
        )
    }

    /// The two ways a count can fail to be a number are not the same signal. A read that answered
    /// without a row says the catalog is not speaking for this database, which only a proxy does. A
    /// read the server refused says nothing, because the query timeout refuses the same way.
    private func catalogTableCount(database: String) async throws -> MySQLCatalogCount {
        do {
            let query = MySQLObjectQueries.catalogTableCount(schema: database)
            let result = try await execute(ownStatement: query)
            guard let count = result.rows.first?[safe: 0]?.asText.flatMap(Int.init) else { return .noRow }
            return .counted(count)
        } catch let error as MariaDBPluginError
            where MySQLCatalogVisibilityRule.settlesBlindness(code: error.code) {
            Self.logger.warning(
                "information_schema table count refused code=\(error.code, privacy: .public) message=\(error.message)"
            )
            return .refused
        }
    }

    /// Nil where the server refused, which is what an account that may list a database but not open
    /// it gets: measured as `ERROR 1044` in #2950. That answer settles nothing, so the verdict stays
    /// unrecorded and the catalog's own empty answer stands.
    private func listedTableCount(database: String) async throws -> Int? {
        do {
            let query = MySQLObjectQueries.showFullTables(schema: database)
            return try await execute(query: query).rows.count
        } catch let error as MariaDBPluginError
            where MySQLCatalogVisibilityRule.settlesBlindness(code: error.code) {
            return nil
        }
    }

    // MARK: - The degraded reads

    func showColumnsByTable(database: String) async throws -> [String: [PluginColumnInfo]] {
        try await degradedRead(database: database) { table in
            try await self.fetchColumns(table: table.name, schema: database)
        }
    }

    func showIndexesByTable(database: String) async throws -> [String: [PluginIndexInfo]] {
        try await degradedRead(database: database) { table in
            try await self.fetchIndexes(table: table.name, schema: database)
        }
    }

    /// Base tables only: `SHOW CREATE TABLE` answers for a view with its `SELECT` and for a MariaDB
    /// sequence with the sequence's own table, neither of which can carry a constraint.
    func showForeignKeysByTable(database: String) async throws -> [String: [PluginForeignKeyInfo]] {
        let identity = serverIdentity
        let omittedAction = MySQLServerVersion.omittedForeignKeyAction(
            banner: identity.banner,
            flavor: identity.flavor
        )
        return try await degradedRead(database: database, baseTablesOnly: true) { table in
            try await self.ddlForeignKeys(table: table.name, database: database, omittedAction: omittedAction)
        }
    }

    func ddlForeignKeys(table: String, database: String, omittedAction: String) async throws -> [PluginForeignKeyInfo] {
        let ddl = try await fetchTableDDL(table: table, schema: database)
        return MySQLForeignKeyClause.parse(createTable: ddl, database: database, omittedAction: omittedAction)
    }

    /// Every table or none.
    ///
    /// A table whose statement fails takes the whole read with it rather than being skipped with a
    /// warning, because the map alone cannot say which of the two happened. `CompareMetadataService`
    /// only retries per table when the whole bulk read threw; a map that is merely missing one
    /// table's key reads as "this table has no indexes" and the sync script it writes offers to drop
    /// every index and foreign key the table really has.
    private func degradedRead<Value>(
        database: String,
        baseTablesOnly: Bool = false,
        of read: (PluginTableInfo) async throws -> [Value]
    ) async throws -> [String: [Value]] {
        var answer: [String: [Value]] = [:]
        for table in try await fetchTables(schema: database) {
            try Task.checkCancellation()
            guard !baseTablesOnly || Self.isBaseTable(table) else { continue }
            let values = try await read(table)
            guard !values.isEmpty else { continue }
            answer[table.name] = values
        }
        return answer
    }

    private static func isBaseTable(_ table: PluginTableInfo) -> Bool {
        let kind = table.type.uppercased()
        return !kind.contains("VIEW") && kind != "SEQUENCE"
    }
}
