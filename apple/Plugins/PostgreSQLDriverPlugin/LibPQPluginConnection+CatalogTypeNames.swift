//
//  LibPQPluginConnection+CatalogTypeNames.swift
//  PostgreSQLDriverPlugin
//

import CLibPQ
import Foundation
import TableProPostgreSQLCore

internal extension LibPQPluginConnection {
    // A type created after connect has an oid the connect-time probe never saw. A failed lookup is asked again with the
    // next result, unless it will fail the same way again.
    func learnTypeNames(for oids: [UInt32], conn: OpaquePointer) {
        preconditionOnQueue()
        guard let query = PostgreSQLCatalogTypeNames.lookupQuery(oids: oids) else { return }
        let result = pinnedCatalogSideQueryOnQueue(query, conn: conn)
        guard let result else { return }
        defer { PQclear(result) }
        guard PQresultStatus(result) == PGRES_TUPLES_OK else {
            if givesUpLookup(after: getResultError(from: result).sqlState) {
                typeNames.merge(PostgreSQLCatalogTypeNames.names(for: oids, rows: []))
            }
            return
        }
        typeNames.merge(PostgreSQLCatalogTypeNames.names(for: oids, rows: Self.textRows(from: result)))
    }

    // Pinned, a failed lookup is scoped by a savepoint, so only a refusal the catalog will repeat is final. Unpinned
    // (Redshift, CockroachDB) it fails inside the user's transaction, so anything but a cancel or an aborted block is.
    private func givesUpLookup(after sqlState: String?) -> Bool {
        guard let sqlState else { return false }
        if pinsCatalogSearchPath { return sqlState.hasPrefix("42") || sqlState == "0A000" }
        return sqlState != "57014" && sqlState != "25P02"
    }

    // A streaming result sends its header with its first row, before a lookup can run, so a new enum or a PostGIS
    // installed in this session is probed when the statement that made it reports its tag.
    func noteCommandTag(_ tag: String?, conn: OpaquePointer) {
        preconditionOnQueue()
        switch tag {
        case Self.createTypeCommandTag:
            guard let rows = sideQueryRows(PostgreSQLSchemaQueries.enumTypeOidQuery, conn: conn) else { return }
            typeNames.merge(PostgreSQLCatalogTypeNames.enumProbeNames(rows: rows))
        // Only the connections that probe PostGIS at connect; unpinned the probe would run in the user's transaction.
        case Self.createExtensionCommandTag where pinsCatalogSearchPath:
            guard let rows = sideQueryRows(PostGISTypes.probeQuery, conn: conn) else { return }
            typeNames.setPostgisTypes(PostGISTypes.names(fromProbeRows: rows))
        default:
            return
        }
    }

    private func sideQueryRows(_ query: String, conn: OpaquePointer) -> [[String?]]? {
        guard let result = pinnedCatalogSideQueryOnQueue(query, conn: conn) else { return nil }
        defer { PQclear(result) }
        guard PQresultStatus(result) == PGRES_TUPLES_OK else { return nil }
        return Self.textRows(from: result)
    }

    private static func textRows(from result: OpaquePointer) -> [[String?]] {
        let numRows = Int(PQntuples(result))
        let numFields = Int(PQnfields(result))
        var rows: [[String?]] = []
        rows.reserveCapacity(numRows)
        for rowIndex in 0..<numRows {
            rows.append((0..<numFields).map { fieldIndex in
                guard PQgetisnull(result, Int32(rowIndex), Int32(fieldIndex)) == 0,
                      let valuePtr = PQgetvalue(result, Int32(rowIndex), Int32(fieldIndex)) else { return nil }
                return String(cString: valuePtr)
            })
        }
        return rows
    }

    private static let createTypeCommandTag = "CREATE TYPE"
    private static let createExtensionCommandTag = "CREATE EXTENSION"

    func resolvingUnknownTypes(
        _ metadata: ColumnMetadata,
        conn: OpaquePointer
    ) -> ColumnMetadata {
        preconditionOnQueue()
        let missing = typeNames.unresolvedOids(in: metadata.columnOids)
        guard !missing.isEmpty else { return metadata }
        learnTypeNames(for: missing, conn: conn)
        return ColumnMetadata(
            columns: metadata.columns,
            columnOids: metadata.columnOids,
            columnTypeModifiers: metadata.columnTypeModifiers,
            columnTypeNames: zip(metadata.columnOids, metadata.columnTypeModifiers).map(typeNames.name(for:modifier:))
        )
    }
}
