//
//  CopilotSchemaContext.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

/// Builds a schema preamble (SQL comments with table/column info) to prepend
/// to document text sent to the Copilot language server. Pure data, no LSP concerns.
@MainActor
final class CopilotSchemaContext {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CopilotSchemaContext")

    /// Directory for query document URIs
    static let contextDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("TablePro/copilot-context", isDirectory: true)
    }()

    /// The schema preamble text (SQL comments with table/column info)
    private(set) var preamble: String = ""

    /// Number of newline characters in the preamble (for cursor offset adjustment)
    private(set) var preambleLineCount: Int = 0

    /// Build the preamble from cached schema data
    func buildPreamble(
        schemaProvider: SQLSchemaProvider,
        databaseName: String,
        databaseType: DatabaseType
    ) async {
        try? FileManager.default.createDirectory(at: Self.contextDirectory, withIntermediateDirectories: true)

        let tables = await schemaProvider.getTables()
        guard !tables.isEmpty else {
            preamble = ""
            preambleLineCount = 0
            return
        }

        var columnsByTable: [String: [ColumnInfo]] = [:]
        for table in tables {
            let columns = await schemaProvider.getColumns(for: table.name)
            if !columns.isEmpty {
                columnsByTable[table.name.lowercased()] = columns
            }
        }

        var lines: [String] = []
        lines.append("-- Database: \(databaseName)")
        lines.append("-- Dialect: \(databaseType.rawValue): use \(databaseType.rawValue) syntax only")
        lines.append("--")

        for table in tables {
            let columns = columnsByTable[table.name.lowercased()] ?? []
            guard !columns.isEmpty else { continue }

            let colDefs = columns.map { col -> String in
                var parts = ["\(col.name) \(col.dataType)"]
                if col.isPrimaryKey { parts.append("PK") }
                if !col.isNullable { parts.append("NOT NULL") }
                return parts.joined(separator: " ")
            }
            lines.append("-- \(table.name)(\(colDefs.joined(separator: ", ")))")
        }

        lines.append("")

        preamble = lines.joined(separator: "\n")
        preambleLineCount = lines.count - 1

        Self.logger.info("Copilot schema preamble: \(tables.count) tables, \(self.preambleLineCount) lines")
    }

    /// Prepend the preamble to user text for sending to Copilot
    func prependToText(_ text: String) -> String {
        guard !preamble.isEmpty else { return text }
        return preamble + text
    }
}
