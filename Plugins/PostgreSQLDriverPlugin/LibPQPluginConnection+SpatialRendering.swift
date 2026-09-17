//
//  LibPQPluginConnection+SpatialRendering.swift
//  PostgreSQLDriverPlugin
//

import CLibPQ
import Foundation
import OSLog
import TableProPluginKit

internal extension LibPQPluginConnection {
    func applySpatialRendering(to result: LibPQPluginQueryResult) -> LibPQPluginQueryResult {
        preconditionOnQueue()
        let oidMap = typeNames.postgisTypes
        guard !oidMap.isEmpty else { return result }

        let spatialColumns = result.columnOids.enumerated().compactMap { index, oid -> (index: Int, type: PostGISType)? in
            guard let type = oidMap[oid] else { return nil }
            return (index, type)
        }
        guard !spatialColumns.isEmpty else { return result }

        return renderSpatialColumns(result, spatialColumns: spatialColumns)
    }

    private func renderSpatialColumns(
        _ result: LibPQPluginQueryResult,
        spatialColumns: [(index: Int, type: PostGISType)]
    ) -> LibPQPluginQueryResult {
        var rows = result.rows
        var columnTypeNames = result.columnTypeNames

        var pending: [(index: Int, query: String, hexValues: [String?])] = []
        for column in spatialColumns {
            if column.index < columnTypeNames.count {
                columnTypeNames[column.index] = column.type.name
            }

            guard let query = PostGISSpatialRewrite.conversionQuery(for: column.type) else { continue }

            let hexValues: [String?] = rows.map { row in
                guard column.index < row.count, case let .text(hex) = row[column.index] else { return nil }
                return hex
            }
            guard hexValues.contains(where: { $0 != nil }) else { continue }
            pending.append((index: column.index, query: query, hexValues: hexValues))
        }

        if !pending.isEmpty, let scope = SpatialRenderScope(connection: self) {
            for column in pending {
                guard let converted = scope.convert(column.hexValues, query: column.query),
                      converted.count == column.hexValues.count else {
                    Self.logger.warning("PostGIS value conversion failed for column \(column.index); keeping raw hex")
                    continue
                }

                for (rowIndex, value) in converted.enumerated()
                    where column.hexValues[rowIndex] != nil && column.index < rows[rowIndex].count {
                    rows[rowIndex][column.index] = value
                }
            }
            scope.finish()
        }

        return LibPQPluginQueryResult(
            columns: result.columns,
            columnOids: result.columnOids,
            columnTypeNames: columnTypeNames,
            rows: rows,
            affectedRows: result.affectedRows,
            commandTag: result.commandTag,
            isTruncated: result.isTruncated,
            firstRowTime: result.firstRowTime
        )
    }

    /// One savepoint for a whole rendering pass rather than one per column: the conversion is a
    /// side query on the user's own session, and an open transaction must survive a PostGIS error
    /// (an older server has no ST_AsEWKT at all) without costing three round trips per column.
    private final class SpatialRenderScope {
        private let conn: OpaquePointer
        private let isInsideTransaction: Bool

        init?(connection: LibPQPluginConnection) {
            guard let handle = connection.connectionHandle else { return nil }
            self.conn = handle
            switch PQtransactionStatus(handle) {
            case PQTRANS_IDLE:
                isInsideTransaction = false
            case PQTRANS_INTRANS:
                guard LibPQPluginConnection.runCommand(PostGISSpatialRewrite.savepoint, on: handle) else {
                    return nil
                }
                isInsideTransaction = true
            default:
                return nil
            }
        }

        func convert(_ hexValues: [String?], query: String) -> [PluginCellValue]? {
            let arrayLiteral = PostGISSpatialRewrite.arrayLiteral(from: hexValues)
            guard let paramCStr = strdup(arrayLiteral) else { return nil }
            defer { free(paramCStr) }

            let paramValues: [UnsafePointer<CChar>?] = [UnsafePointer(paramCStr)]
            let result = query.withCString { queryPtr in
                PQexecParams(conn, queryPtr, 1, nil, paramValues, nil, nil, 0)
            }
            guard let result, PQresultStatus(result) == PGRES_TUPLES_OK else {
                if let result { PQclear(result) }
                rollback()
                return nil
            }
            defer { PQclear(result) }
            return LibPQPluginConnection.textColumn(from: result)
        }

        func finish() {
            guard isInsideTransaction else { return }
            _ = LibPQPluginConnection.runCommand(PostGISSpatialRewrite.releaseSavepoint, on: conn)
        }

        private func rollback() {
            guard isInsideTransaction else { return }
            _ = LibPQPluginConnection.runCommand(PostGISSpatialRewrite.rollbackToSavepoint, on: conn)
        }
    }

    private static func textColumn(from result: OpaquePointer) -> [PluginCellValue] {
        let rowCount = Int(PQntuples(result))
        var converted: [PluginCellValue] = []
        converted.reserveCapacity(rowCount)
        for rowIndex in 0..<rowCount {
            if PQgetisnull(result, Int32(rowIndex), 0) == 1 {
                converted.append(.null)
            } else if let valuePtr = PQgetvalue(result, Int32(rowIndex), 0) {
                let length = Int(PQgetlength(result, Int32(rowIndex), 0))
                let bufferPtr = UnsafeRawBufferPointer(start: valuePtr, count: length)
                converted.append(.text(LibPQCellDecoding.text(from: bufferPtr)))
            } else {
                converted.append(.null)
            }
        }
        return converted
    }

    private static func runCommand(_ command: String, on conn: OpaquePointer) -> Bool {
        guard let result = command.withCString({ PQexec(conn, $0) }) else { return false }
        defer { PQclear(result) }
        return PQresultStatus(result) == PGRES_COMMAND_OK
    }
}
