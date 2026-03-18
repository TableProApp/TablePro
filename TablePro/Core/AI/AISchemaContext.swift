//
//  AISchemaContext.swift
//  TablePro
//
//  Builds AI system prompt context from current database connection schema.
//

import Foundation
import os
import TableProPluginKit

/// Builds schema context for AI system prompts
struct AISchemaContext {
    private static let logger = Logger(
        subsystem: "com.TablePro",
        category: "AISchemaContext"
    )

    // MARK: - Public

    /// Build a system prompt including database context
    @MainActor static func buildSystemPrompt(
        databaseType: DatabaseType,
        databaseName: String,
        tables: [TableInfo],
        columnsByTable: [String: [ColumnInfo]],
        foreignKeys: [String: [ForeignKeyInfo]],
        currentQuery: String?,
        queryResults: String?,
        settings: AISettings,
        identifierQuote: String = "\""
    ) -> String {
        var parts: [String] = []

        parts.append(
            "You are a helpful database assistant for TablePro, a macOS database client."
        )
        parts.append(
            "The user is connected to a \(databaseType.rawValue) database"
            + " named \"\(databaseName)\"."
        )

        if settings.includeSchema {
            let schemaContext = buildSchemaSection(
                tables: tables,
                columnsByTable: columnsByTable,
                foreignKeys: foreignKeys,
                maxTables: settings.maxSchemaTables,
                identifierQuote: identifierQuote
            )
            if !schemaContext.isEmpty {
                parts.append("\n## Database Schema\n\(schemaContext)")
            }
        }

        if settings.includeCurrentQuery,
           let query = currentQuery,
           !query.isEmpty {
            let lang = PluginManager.shared.editorLanguage(for: databaseType).codeBlockTag
            parts.append("\n## Current Query\n```\(lang)\n\(query)\n```")
        }

        if settings.includeQueryResults,
           let results = queryResults,
           !results.isEmpty {
            parts.append("\n## Recent Query Results\n\(results)")
        }

        let editorLang = PluginManager.shared.editorLanguage(for: databaseType)
        let langName = PluginManager.shared.queryLanguageName(for: databaseType)
        let langTag = editorLang.codeBlockTag

        switch editorLang {
        case .sql:
            parts.append(
                "\nProvide SQL queries appropriate for"
                + " \(databaseType.rawValue) syntax when applicable."
            )
            parts.append(
                "When writing SQL, use the correct identifier quoting"
                + " for \(databaseType.rawValue)."
            )
        default:
            parts.append(
                "\nProvide \(langName) queries using `\(langTag)` fenced code blocks."
            )
            parts.append(
                "Use \(langName) syntax, not SQL."
            )
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Private

    private static func buildSchemaSection(
        tables: [TableInfo],
        columnsByTable: [String: [ColumnInfo]],
        foreignKeys: [String: [ForeignKeyInfo]],
        maxTables: Int,
        identifierQuote: String
    ) -> String {
        let selectedTables = Array(tables.prefix(maxTables))
        guard !selectedTables.isEmpty else { return "" }

        var lines: [String] = []
        let q = identifierQuote

        for table in selectedTables {
            var tableLine = "- \(q)\(table.name)\(q)"
            if let rowCount = table.rowCount {
                tableLine += " (~\(rowCount) rows)"
            }
            lines.append(tableLine)

            // Add columns
            if let columns = columnsByTable[table.name] {
                for column in columns {
                    var colDesc = "  - \(column.name) \(column.dataType)"
                    if column.isPrimaryKey { colDesc += " PK" }
                    if !column.isNullable { colDesc += " NOT NULL" }
                    if let def = column.defaultValue {
                        colDesc += " DEFAULT \(def)"
                    }
                    lines.append(colDesc)
                }
            }

            // Add foreign keys
            if let fks = foreignKeys[table.name], !fks.isEmpty {
                for fk in fks {
                    lines.append(
                        "  FK: \(fk.column) -> "
                        + "\(fk.referencedTable).\(fk.referencedColumn)"
                    )
                }
            }
        }

        if tables.count > maxTables {
            lines.append(
                "\n... and \(tables.count - maxTables) more tables (not shown)"
            )
        }

        return lines.joined(separator: "\n")
    }
}
