//
//  MySQLPluginDriver+StarRocks.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProMySQLCore
import TableProPluginKit

extension MySQLPluginDriver {
    /// No transactions, because a StarRocks transaction is bound to one table's load and the grid's
    /// `BEGIN` would not group its edits. No MySQL catalogs either: an external catalog answers
    /// `information_schema` for itself, so compare, routines and accounts are left off.
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
    /// it, and plain `SHOW TABLES` still lists what is there.
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
        return MySQLTableListing.tables(from: rows, listsSequencesAsTables: false)
    }
}
