//
//  MySQLPluginDriver+StarRocks.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProMySQLCore
import TableProPluginKit

extension MySQLPluginDriver {
    /// No transactions: before 3.5 StarRocks has none across statements, and an external catalog has
    /// none at all. Compare, routines and accounts read MySQL catalogs StarRocks does not keep, and
    /// prepared statements are left off because a frontend before 3.2 refuses `COM_STMT_PREPARE`.
    static let starrocksCapabilities: PluginCapabilities = [
        .cancelQuery,
    ]

    /// Enters the catalog and database the session belongs in, on a connection that has just come up
    /// in `default_catalog` with no database.
    ///
    /// A name without a dot is first tried as a catalog, because a pooled metadata connection carries
    /// the browsed catalog in that field. A server that has no such catalog takes it as a database of
    /// `default_catalog`, which is what a connection typed by hand means by it.
    func enterStarRocksSessionScope(on conn: MariaDBPluginConnection, deadline: MySQLConnectDeadline) async throws {
        let database = activeDatabaseName
        if let catalog = activeCatalogName {
            _ = try await conn.executeConnectQuery(StarRocksCatalog.setCatalog(catalog), deadline: deadline)
            if !database.isEmpty {
                _ = try await conn.executeConnectQuery(StarRocksCatalog.useDatabase(database), deadline: deadline)
            }
            adoptStarRocksScope(catalog: catalog, database: database)
            return
        }
        guard !database.isEmpty else {
            adoptStarRocksScope(catalog: StarRocksCatalog.defaultCatalog, database: "")
            return
        }
        do {
            _ = try await conn.executeConnectQuery(StarRocksCatalog.setCatalog(database), deadline: deadline)
            adoptStarRocksScope(catalog: database, database: "")
        } catch let error as MariaDBPluginError where error.isConnectionTimeout {
            throw error
        } catch {
            _ = try await conn.executeConnectQuery(StarRocksCatalog.useDatabase(database), deadline: deadline)
            adoptStarRocksScope(catalog: StarRocksCatalog.defaultCatalog, database: database)
        }
    }

    /// `SHOW FULL TABLES` tells views apart, but a connector behind an external catalog may refuse
    /// it, and plain `SHOW TABLES` still lists what is there. It types a materialized view as `VIEW`,
    /// so those are named from `information_schema.materialized_views`.
    func starrocksTables(database: String) async throws -> [PluginTableInfo] {
        let source = mysqlQuoteIdentifier(database)
        let rows: [[PluginCellValue]]
        do {
            rows = try await execute(query: "SHOW FULL TABLES FROM \(source)").rows
        } catch let error as MariaDBPluginError where error.isConnectionTimeout {
            throw error
        } catch {
            rows = try await execute(query: "SHOW TABLES FROM \(source)").rows
        }
        let tables = MySQLTableListing.tables(from: rows, listsSequencesAsTables: false)
        let materialized = try await starrocksCatalogRead(fallback: []) {
            StarRocksCatalog.names(from: try await self.execute(
                ownStatement: StarRocksCatalog.materializedViewNames(database: database)
            ).rows)
        }
        return StarRocksCatalog.markingMaterializedViews(Set(materialized), in: tables)
    }

    /// Keyed by table. An external catalog's `SHOW FULL COLUMNS` adds the connector's `_file` and
    /// `_pos`, which `SELECT *` never returns; `information_schema.columns` lists what the table holds.
    func starrocksColumns(database: String, table: String?) async throws -> [String: [PluginColumnInfo]] {
        let rows = try await execute(
            ownStatement: StarRocksCatalog.columns(database: database, table: table)
        ).rows
        return StarRocksCatalog.columnsByTable(from: rows)
    }

    /// `information_schema.tables_config`, `materialized_views` and the table status of an external
    /// catalog are missing or empty, so a refusal there reads as nothing to report.
    func starrocksCatalogRead<T>(fallback: T, _ read: () async throws -> T) async throws -> T {
        do {
            return try await read()
        } catch let error as MariaDBPluginError
            where !error.isConnectionTimeout && MySQLTableListing.showFullTablesSettlesCatalogFailure(code: error.code) {
            return fallback
        }
    }
}
