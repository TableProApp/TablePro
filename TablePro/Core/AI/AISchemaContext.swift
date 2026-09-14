//
//  AISchemaContext.swift
//  TablePro
//
//  Builds AI system prompt context from current database connection schema.
//

import Foundation
import TableProPluginKit

/// One table as the schema context describes it. The producer joins each table to its own columns
/// and foreign keys, because a lookup by name cannot tell two schemas' tables of the same name apart.
struct AISchemaTable: Sendable {
    let table: TableInfo
    let columns: [ColumnInfo]
    let foreignKeys: [ForeignKeyInfo]

    init(table: TableInfo, columns: [ColumnInfo] = [], foreignKeys: [ForeignKeyInfo] = []) {
        self.table = table
        self.columns = columns
        self.foreignKeys = foreignKeys
    }
}

/// Builds schema context for AI system prompts
struct AISchemaContext {
    // MARK: - Public

    /// Build a system prompt including database context
    static func buildSystemPrompt(
        databaseType: DatabaseType,
        databaseName: String,
        tables: [AISchemaTable],
        defaultSchema: String?,
        currentQuery: String?,
        queryResults: String?,
        settings: AISettings,
        identifierQuote: String = "\"",
        editorLanguage: EditorLanguage,
        queryLanguageName: String,
        connectionRules: String? = nil
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
                defaultSchema: defaultSchema,
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
            let lang = editorLanguage.codeBlockTag
            let maxQueryLength = 2_000
            let nsQuery = query as NSString
            let truncated = nsQuery.length > maxQueryLength
                ? nsQuery.substring(to: maxQueryLength) + "\n-- ... truncated"
                : query
            parts.append("\n## Current Query\n```\(lang)\n\(truncated)\n```")
        }

        if settings.includeQueryResults,
           let results = queryResults,
           !results.isEmpty {
            parts.append("\n## Recent Query Results\n\(results)")
        }

        if let rules = connectionRules?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rules.isEmpty {
            parts.append("\n## Connection-Specific Rules\n\(rules)")
        }

        let langTag = editorLanguage.codeBlockTag

        switch editorLanguage {
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
                "\nProvide \(queryLanguageName) queries using `\(langTag)` fenced code blocks."
            )
            parts.append(
                "Use \(queryLanguageName) syntax, not SQL."
            )
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Private

    /// A table outside `defaultSchema` is named with its schema, so two tables that share a name
    /// read as two tables rather than one listed twice.
    static func buildSchemaSection(
        tables: [AISchemaTable],
        defaultSchema: String?,
        maxTables: Int,
        identifierQuote: String
    ) -> String {
        let selectedTables = tables.prefix(maxTables)
        guard !selectedTables.isEmpty else { return "" }

        var lines: [String] = []
        let q = identifierQuote

        for entry in selectedTables {
            let tableName = SchemaQualifiedName.render(
                name: entry.table.name,
                schema: entry.table.schema,
                implicitSchemaName: defaultSchema,
                quote: { "\(q)\($0)\(q)" }
            )
            var tableLine = "- \(tableName)"
            if let rowCount = entry.table.rowCount {
                tableLine += " (~\(rowCount) rows)"
            }
            lines.append(tableLine)

            for column in entry.columns {
                var colDesc = "  - \(column.name) \(column.dataType)"
                if column.isPrimaryKey { colDesc += " PK" }
                if !column.isNullable { colDesc += " NOT NULL" }
                if let def = column.defaultValue {
                    colDesc += " DEFAULT \(def)"
                }
                lines.append(colDesc)
            }

            for fk in entry.foreignKeys {
                lines.append(
                    "  FK: \(fk.column) -> "
                    + "\(fk.referencedTable).\(fk.referencedColumn)"
                )
            }
        }

        if tables.count > maxTables {
            lines.append(
                "\n… and \(tables.count - maxTables) more tables (not shown)"
            )
        }

        return lines.joined(separator: "\n")
    }
}
