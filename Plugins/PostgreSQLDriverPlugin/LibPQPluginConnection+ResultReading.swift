//
//  LibPQPluginConnection+ResultReading.swift
//  PostgreSQLDriverPlugin
//

import CLibPQ
import Foundation
import OSLog
import TableProPluginKit

internal extension LibPQPluginConnection {
    struct ColumnMetadata {
        let columns: [String]
        let columnOids: [UInt32]
        let columnTypeNames: [String]
    }

    func readColumnMetadata(from result: OpaquePointer) -> ColumnMetadata {
        let numFields = Int(PQnfields(result))
        var columns: [String] = []
        var columnOids: [UInt32] = []
        var columnTypeNames: [String] = []
        columns.reserveCapacity(numFields)
        columnOids.reserveCapacity(numFields)
        columnTypeNames.reserveCapacity(numFields)

        for i in 0..<numFields {
            if let namePtr = PQfname(result, Int32(i)) {
                columns.append(String(cString: namePtr))
            } else {
                columns.append("column_\(i)")
            }
            let oid = UInt32(PQftype(result, Int32(i)))
            columnOids.append(oid)
            columnTypeNames.append(typeNames.name(for: oid))
        }
        return ColumnMetadata(columns: columns, columnOids: columnOids, columnTypeNames: columnTypeNames)
    }

    func fetchResults(
        from result: OpaquePointer,
        conn: OpaquePointer,
        generation: Int
    ) throws -> LibPQPluginQueryResult {
        preconditionOnQueue()
        let metadata = resolvingUnknownTypes(readColumnMetadata(from: result), conn: conn)
        let parsed = try parseRows(
            from: result,
            columns: metadata.columns,
            columnOids: metadata.columnOids,
            columnTypeNames: metadata.columnTypeNames,
            generation: generation
        )

        return applySpatialRendering(to: parsed)
    }

    static func decodeCell(
        from result: OpaquePointer,
        row: Int32,
        column: Int32,
        oid: UInt32
    ) -> PluginCellValue {
        guard PQgetisnull(result, row, column) != 1,
              let valuePtr = PQgetvalue(result, row, column) else {
            return .null
        }

        let length = Int(PQgetlength(result, row, column))
        return LibPQCellDecoding.value(from: UnsafeRawBufferPointer(start: valuePtr, count: length), oid: oid)
    }

    private func parseRows(
        from result: OpaquePointer,
        columns: [String],
        columnOids: [UInt32],
        columnTypeNames: [String],
        generation: Int
    ) throws -> LibPQPluginQueryResult {
        let numFields = columns.count
        let numRows = Int(PQntuples(result))

        let maxRows = PluginRowLimits.emergencyMax
        let effectiveRowCount = min(numRows, maxRows)
        let truncated = numRows > maxRows

        var rows: [[PluginCellValue]] = []
        rows.reserveCapacity(effectiveRowCount)

        for rowIndex in 0..<effectiveRowCount {
            if cancellationGate.isCancelled(generation) {
                throw CancellationError()
            }

            var row: [PluginCellValue] = []
            row.reserveCapacity(numFields)

            for colIndex in 0..<numFields {
                row.append(Self.decodeCell(
                    from: result,
                    row: Int32(rowIndex),
                    column: Int32(colIndex),
                    oid: columnOids[colIndex]
                ))
            }
            rows.append(row)
        }

        if truncated {
            Self.logger.warning("Result set truncated at \(maxRows) rows")
        }

        return LibPQPluginQueryResult(
            columns: columns,
            columnOids: columnOids,
            columnTypeNames: columnTypeNames,
            rows: rows,
            affectedRows: numRows,
            commandTag: getCommandTag(from: result),
            isTruncated: truncated
        )
    }

    func getResultError(from result: OpaquePointer) -> LibPQPluginError {
        var message = "Unknown error"
        if let msgPtr = PQresultErrorMessage(result) {
            message = String(cString: msgPtr).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return LibPQPluginError(message: message) { field in
            PQresultErrorField(result, field).map { String(cString: $0) }
        }
    }

    func getAffectedRows(from result: OpaquePointer) -> Int {
        if let affectedPtr = PQcmdTuples(result), affectedPtr.pointee != 0 {
            return Int(String(cString: affectedPtr)) ?? 0
        }
        return 0
    }

    func getCommandTag(from result: OpaquePointer) -> String? {
        if let tagPtr = PQcmdStatus(result), tagPtr.pointee != 0 {
            return String(cString: tagPtr)
        }
        return nil
    }
}
