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
            executionTime: Date().timeIntervalSince(started)
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
