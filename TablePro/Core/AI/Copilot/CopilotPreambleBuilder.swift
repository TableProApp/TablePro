//
//  CopilotPreambleBuilder.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

@MainActor
final class CopilotPreambleBuilder {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "CopilotPreambleBuilder")

    static let contextDirectory: URL = {
        let appSupport = AppStorageEnvironment.shared.applicationSupportRoot
        return appSupport.appendingPathComponent("TablePro/copilot-context", isDirectory: true)
    }()

    private(set) var preamble: String = ""

    private(set) var preambleLineCount: Int = 0

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

        let defaultSchema = await schemaProvider.getDefaultSchema()

        var lines: [String] = []
        lines.append("-- Database: \(databaseName)")
        lines.append("-- Dialect: \(databaseType.rawValue): use \(databaseType.rawValue) syntax only")
        lines.append("--")

        for table in tables {
            let columns = await schemaProvider.getColumns(for: table.name, schema: table.schema)
            guard !columns.isEmpty else { continue }

            let colDefs = columns.map { col -> String in
                var parts = ["\(col.name) \(col.dataType)"]
                if col.isPrimaryKey { parts.append("PK") }
                if !col.isNullable { parts.append("NOT NULL") }
                return parts.joined(separator: " ")
            }
            let tableName = SchemaQualifiedName.render(
                name: table.name,
                schema: table.schema,
                implicitSchemaName: defaultSchema,
                quote: { $0 }
            )
            lines.append("-- \(tableName)(\(colDefs.joined(separator: ", ")))")
        }

        lines.append("")

        preamble = lines.joined(separator: "\n")
        preambleLineCount = lines.count - 1

        Self.logger.info("Copilot schema preamble: \(tables.count) tables, \(self.preambleLineCount) lines")
    }

    func prependToText(_ text: String) -> String {
        guard !preamble.isEmpty else { return text }
        return preamble + text
    }
}
