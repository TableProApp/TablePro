//
//  LibPQPluginConnection+CatalogTypeNames.swift
//  PostgreSQLDriverPlugin
//

import CLibPQ
import Foundation

internal extension LibPQPluginConnection {
    /// A type created after connect has an oid the connect-time probe never saw, so its columns
    /// came back as text until the next reconnect. The oids a result leaves unresolved are looked
    /// up on the same connection once the result is fully read, which is the only moment libpq
    /// allows another statement, and remembered for every later result. An oid the catalog does
    /// not know is remembered as unresolved for the same reason. A lookup that fails inside an
    /// aborted transaction remembers nothing, because it will succeed after the rollback.
    func learnTypeNames(for oids: [UInt32], conn: OpaquePointer) {
        preconditionOnQueue()
        guard let query = PostgreSQLCatalogTypeNames.lookupQuery(oids: oids) else { return }
        let result: OpaquePointer? = query.withCString { PQexec(conn, $0) }
        guard let result else { return }
        defer { PQclear(result) }

        guard PQresultStatus(result) == PGRES_TUPLES_OK else {
            guard getResultError(from: result).sqlState != Self.transactionAbortedSQLState else { return }
            typeNames.merge(PostgreSQLCatalogTypeNames.names(for: oids, rows: []))
            return
        }
        typeNames.merge(PostgreSQLCatalogTypeNames.names(for: oids, rows: Self.textRows(from: result)))
    }

    /// A streaming result sends its header with the first row, before anything could be looked
    /// up, so a `SELECT` run right after a `CREATE TYPE` in the same tab would still read the new
    /// enum as text once. The statement's own command tag says a type was just created, and one
    /// enum probe there puts the oid in place before the next statement is sent.
    func noteCommandTag(_ tag: String?, conn: OpaquePointer) {
        preconditionOnQueue()
        guard tag == Self.createTypeCommandTag else { return }
        let query = PostgreSQLSchemaQueries.enumTypeOidQuery
        let result: OpaquePointer? = query.withCString { PQexec(conn, $0) }
        guard let result else { return }
        defer { PQclear(result) }
        guard PQresultStatus(result) == PGRES_TUPLES_OK else { return }
        typeNames.merge(PostgreSQLCatalogTypeNames.enumProbeNames(rows: Self.textRows(from: result)))
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

    private static let transactionAbortedSQLState = "25P02"
    private static let createTypeCommandTag = "CREATE TYPE"

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
            columnTypeNames: metadata.columnOids.map(typeNames.name(for:))
        )
    }
}
