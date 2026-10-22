//
//  UnloadedValueReader.swift
//  TablePro
//

import Foundation
import TableProPluginKit

@MainActor
struct UnloadedValueReader {
    struct Request: Equatable, Sendable {
        let key: [PluginCellValue]
        let byteCount: Int
    }

    let tableName: String
    let schemaName: String?
    let keyColumns: [String]
    let databaseType: DatabaseType
    let parameterStyle: ParameterStyle
    let quote: (String) -> String
    let run: (ParameterizedStatement) async throws -> [[PluginCellValue]]

    nonisolated static let maxKeysPerStatement = 100
    // A statement's result is held in memory whole, so a batch of large values stops at this size.
    nonisolated static let maxBytesPerStatement = 32 * 1_024 * 1_024

    func read(columns: [String], requests: [Request]) async throws -> [[PluginCellValue]: [PluginCellValue]] {
        var values: [[PluginCellValue]: [PluginCellValue]] = [:]
        for batch in Self.batches(of: requests) {
            guard let statement = statement(columns: columns, keys: batch.map(\.key)) else { continue }
            for row in try await run(statement) where row.count >= keyColumns.count {
                values[Array(row.prefix(keyColumns.count))] = Array(row.dropFirst(keyColumns.count))
            }
        }
        return values
    }

    nonisolated static func batches(of requests: [Request]) -> [[Request]] {
        var batches: [[Request]] = []
        var current: [Request] = []
        var bytes = 0
        for request in requests {
            if !current.isEmpty,
               current.count >= maxKeysPerStatement || bytes + request.byteCount > maxBytesPerStatement {
                batches.append(current)
                current = []
                bytes = 0
            }
            current.append(request)
            bytes += request.byteCount
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    func statement(columns: [String], keys: [[PluginCellValue]]) -> ParameterizedStatement? {
        guard !columns.isEmpty, !keyColumns.isEmpty, !keys.isEmpty,
              keys.allSatisfy({ $0.count == keyColumns.count }) else { return nil }
        let table = SchemaQualifiedName.render(name: tableName, schema: schemaName, databaseType: databaseType, quote: quote)
        let projection = (keyColumns + columns).map(quote).joined(separator: ", ")
        var parameters: [Any?] = []
        func placeholder(for value: PluginCellValue) -> String {
            parameters.append(value.asAny)
            switch parameterStyle {
            case .dollar: return "$\(parameters.count)"
            case .questionMark: return "?"
            }
        }

        let condition: String
        if keyColumns.count == 1 {
            let list = keys.map { placeholder(for: $0[0]) }.joined(separator: ", ")
            condition = "\(quote(keyColumns[0])) IN (\(list))"
        } else {
            condition = keys.map { key in
                let terms = zip(keyColumns, key).map { "\(quote($0)) = \(placeholder(for: $1))" }
                return "(\(terms.joined(separator: " AND ")))"
            }.joined(separator: " OR ")
        }
        return ParameterizedStatement(
            sql: "SELECT \(projection) FROM \(table) WHERE \(condition)",
            parameters: parameters
        )
    }
}

typealias UnloadedValueFill = @MainActor @Sendable ([Row]) async throws -> [RowID: [Int: PluginCellValue]]

struct UnloadedValueRead {
    var values: [RowID: [Int: PluginCellValue]] = [:]
    var isComplete = true
}

enum UnloadedValueError: LocalizedError {
    case rowsNotFound

    var errorDescription: String? {
        String(localized: "Some rows are no longer in the table, so their values could not be read.")
    }
}

enum UnloadedValueText {
    static func size(byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    static func notLoaded(byteCount: Int) -> String {
        String(format: String(localized: "Not loaded, %@"), size(byteCount: byteCount))
    }
}
