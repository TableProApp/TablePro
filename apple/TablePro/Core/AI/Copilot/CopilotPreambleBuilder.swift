//
//  CopilotPreambleBuilder.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit
import TableProSQLGrammar

@MainActor
final class CopilotPreambleBuilder {
    struct Source {
        let schemaProvider: SQLSchemaProvider
        let databaseName: String
        let databaseType: DatabaseType
        let grammar: SQLLexicalGrammar
        let budget: Int
    }

    struct Rebuilt {
        let preamble: String
        let lineCount: Int
        fileprivate let describedTables: [TableKey]
        fileprivate let inputs: Source
        fileprivate let revision: Int
    }

    fileprivate struct TableKey: Hashable {
        let name: String
        let schema: String?

        init(_ table: TableInfo) {
            name = table.name
            schema = table.schema
        }
    }

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "CopilotPreambleBuilder")

    static let contextDirectory: URL = {
        let appSupport = AppStorageEnvironment.shared.applicationSupportRoot
        return appSupport.appendingPathComponent("TablePro/copilot-context", isDirectory: true)
    }()

    private(set) var preamble: String = ""

    private(set) var preambleLineCount: Int = 0

    private var inputs: Source?
    // Every table whose columns were read, with or without any, so a table that has none is not read on every request.
    private var describedTables: [TableKey] = []
    private var revision = 0

    func buildPreamble(
        schemaProvider: SQLSchemaProvider,
        databaseName: String,
        databaseType: DatabaseType,
        referencing documentText: String? = nil,
        grammar: SQLLexicalGrammar? = nil,
        maxTables: Int = AppSettingsManager.shared.ai.maxSchemaTables
    ) async {
        try? FileManager.default.createDirectory(at: Self.contextDirectory, withIntermediateDirectories: true)

        let inputs = Source(
            schemaProvider: schemaProvider,
            databaseName: databaseName,
            databaseType: databaseType,
            grammar: grammar ?? databaseType.lexicalGrammar,
            budget: max(maxTables, 0)
        )
        self.inputs = inputs
        let tables = await schemaProvider.getTables()
        let defaultSchema = await schemaProvider.getDefaultSchema()
        var first: [Int] = []
        if tables.count > inputs.budget, let documentText {
            first = await Self.referencedTableIndices(
                in: documentText,
                cursorOffset: nil,
                grammar: inputs.grammar,
                tables: tables,
                defaultSchema: defaultSchema
            )
        }
        let picked = Self.budgeted(tables, first: first, keeping: [], budget: inputs.budget)
        guard let rendered = await Self.render(
            picked, catalogCount: tables.count, inputs: inputs, defaultSchema: defaultSchema
        ) else { return }
        apply(rendered)

        Self.logger.info("Copilot schema preamble: \(tables.count) tables, \(self.preambleLineCount) lines")
    }

    // A tab moved to another database scope names that scope's tables, so a new scope starts the preamble over, as
    // does an editor that had no schema when Copilot started.
    func rebuiltPreamble(forStatementAt cursorOffset: Int, in text: String, from source: Source) async -> Rebuilt? {
        let base = revision
        // A lower "Max schema tables" has to take effect on the next request, as it does in the chat.
        let startsOver = inputs.map {
            $0.schemaProvider !== source.schemaProvider || $0.databaseName != source.databaseName
                || $0.budget != source.budget || $0.databaseType != source.databaseType || $0.grammar != source.grammar
        } ?? true
        let target = startsOver ? source : inputs ?? source
        let kept = startsOver ? [] : describedTables
        let described = Set(kept)
        let tables = await target.schemaProvider.getTables()
        if !startsOver, tables.count <= target.budget, tables.allSatisfy({ described.contains(TableKey($0)) }) {
            return nil
        }
        let defaultSchema = await target.schemaProvider.getDefaultSchema()
        let referenced = await Self.referencedTableIndices(
            in: text,
            cursorOffset: cursorOffset,
            grammar: target.grammar,
            tables: tables,
            defaultSchema: defaultSchema
        ).prefix(target.budget)
        guard startsOver || referenced.contains(where: { !described.contains(TableKey(tables[$0])) }) else { return nil }
        let picked = Self.budgeted(tables, first: Array(referenced), keeping: kept, budget: target.budget)
        guard let rendered = await Self.render(
            picked, catalogCount: tables.count, inputs: target, defaultSchema: defaultSchema
        ) else { return nil }
        return Rebuilt(
            preamble: rendered.preamble,
            lineCount: rendered.lineCount,
            describedTables: rendered.describedTables,
            inputs: target,
            revision: base
        )
    }

    // A rebuild that started before another build landed describes a preamble the sync no longer has.
    func adopt(_ rebuilt: Rebuilt) -> Bool {
        guard rebuilt.revision == revision else { return false }
        apply(rebuilt)
        return true
    }

    func prependToText(_ text: String) -> String {
        guard !preamble.isEmpty else { return text }
        return preamble + text
    }

    private func apply(_ rebuilt: Rebuilt) {
        preamble = rebuilt.preamble
        preambleLineCount = rebuilt.lineCount
        describedTables = rebuilt.describedTables
        inputs = rebuilt.inputs
        revision += 1
    }

    private static func budgeted(_ tables: [TableInfo], first: [Int], keeping kept: [TableKey], budget: Int) -> [TableInfo] {
        var catalog: [TableKey: TableInfo] = [:]
        for table in tables where catalog[TableKey(table)] == nil {
            catalog[TableKey(table)] = table
        }
        var picked: [TableInfo] = []
        var seen = Set<TableKey>()
        for table in first.map({ tables[$0] }) + kept.compactMap({ catalog[$0] }) + tables {
            guard picked.count < budget else { break }
            if seen.insert(TableKey(table)).inserted {
                picked.append(table)
            }
        }
        return picked
    }

    private static func render(
        _ picked: [TableInfo],
        catalogCount: Int,
        inputs: Source,
        defaultSchema: String?
    ) async -> Rebuilt? {
        guard catalogCount > 0 else {
            return Rebuilt(preamble: "", lineCount: 0, describedTables: [], inputs: inputs, revision: 0)
        }

        let dialect = singleLine(inputs.databaseType.rawValue)
        var lines: [String] = []
        lines.append("-- Database: \(singleLine(inputs.databaseName))")
        lines.append("-- Dialect: \(dialect): use \(dialect) syntax only")
        lines.append("--")

        for table in picked {
            guard !Task.isCancelled else { return nil }
            let columns = await inputs.schemaProvider.getColumns(for: table.name, schema: table.schema)
            guard !columns.isEmpty else { continue }

            let colDefs = columns.map { col -> String in
                var parts = ["\(singleLine(col.name)) \(singleLine(col.dataType))"]
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
            lines.append("-- \(singleLine(tableName))(\(colDefs.joined(separator: ", ")))")
        }

        if catalogCount > picked.count {
            lines.append("-- … and \(catalogCount - picked.count) more tables")
        }

        lines.append("")
        return Rebuilt(
            preamble: lines.joined(separator: "\n"),
            lineCount: lines.count - 1,
            describedTables: picked.map(TableKey.init),
            inputs: inputs,
            revision: 0
        )
    }

    // The document sync places edits by line number, so a name must not add a line break.
    private static func singleLine(_ name: String) -> String {
        name.replacingOccurrences(of: "\r", with: " ", options: .literal)
            .replacingOccurrences(of: "\n", with: " ", options: .literal)
    }

    // Scanning a large script takes too long for the main actor.
    @concurrent
    nonisolated private static func referencedTableIndices(
        in text: String,
        cursorOffset: Int?,
        grammar: SQLLexicalGrammar,
        tables: [TableInfo],
        defaultSchema: String?
    ) async -> [Int] {
        let scope = cursorOffset.map {
            SQLStatementScanner.statementAtCursor(in: text, cursorPosition: $0, grammar: grammar)
        } ?? text
        return AISchemaContext.indices(
            of: AISchemaContext.referencedTables(in: scope, grammar: grammar),
            in: tables,
            defaultSchema: defaultSchema
        )
    }
}
