//
//  CloudflareR2SQLPluginDriver+Query.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProR2SQLCore

extension CloudflareR2SQLPluginDriver {
    func execute(query: String) async throws -> PluginQueryResult {
        let started = Date()
        let mapped = R2SQLRowMapper.map(try await run(sql: query))
        return PluginQueryResult(
            columns: mapped.columns,
            columnTypeNames: mapped.columnTypeNames,
            rows: mapped.rows.map { $0.map(Self.cellValue) },
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(started),
            statusMessage: Self.ceilingMessage(rowCount: mapped.rows.count)
        )
    }

    /// A result as long as the engine's ceiling cannot say whether more rows exist, so it says
    /// where it stopped instead of passing for the whole answer.
    static func ceilingMessage(rowCount: Int) -> String? {
        guard rowCount >= CloudflareR2SQLMetadata.maximumRows else { return nil }
        return String(
            format: String(localized: "Stopped at %lld rows, the most R2 SQL returns from one query."),
            CloudflareR2SQLMetadata.maximumRows
        )
    }

    private static func cellValue(_ value: R2SQLValue) -> PluginCellValue {
        switch value {
        case .null:
            return .null
        case .text(let text):
            return .text(text)
        case .bytes(let bytes):
            return .bytes(Data(bytes))
        }
    }
}
