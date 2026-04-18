//
//  MQLExportPlugin.swift
//  MQLExportPlugin
//

import Foundation
import SwiftUI
import TableProPluginKit

@Observable
final class MQLExportPlugin: ExportFormatPlugin, SettablePlugin {
    static let pluginName = "MQL Export"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Export data to MongoDB Query Language format"
    static let formatId = "mql"
    static let formatDisplayName = "MQL"
    static let defaultFileExtension = "js"
    static let iconName = "leaf"
    static let supportedDatabaseTypeIds = ["MongoDB"]

    static let perTableOptionColumns: [PluginExportOptionColumn] = [
        PluginExportOptionColumn(id: "drop", label: "Drop", width: 44),
        PluginExportOptionColumn(id: "indexes", label: "Indexes", width: 44),
        PluginExportOptionColumn(id: "data", label: "Data", width: 44)
    ]

    typealias Settings = MQLExportOptions
    static let settingsStorageId = "mql"

    var settings = MQLExportOptions() {
        didSet { saveSettings() }
    }

    required init() { loadSettings() }

    func defaultTableOptionValues() -> [Bool] {
        [true, true, true]
    }

    func isTableExportable(optionValues: [Bool]) -> Bool {
        optionValues.contains(true)
    }

    func settingsView() -> AnyView? {
        AnyView(MQLExportOptionsView(plugin: self))
    }

    func export(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        destination: URL,
        progress: PluginExportProgress
    ) async throws -> ExportFormatResult {
        let (fileHandle, tempURL) = try PluginExportUtilities.beginAtomicWrite(for: destination)
        var committed = false
        defer {
            if !committed {
                PluginExportUtilities.rollbackAtomicWrite(at: tempURL)
            }
        }

        let dateFormatter = ISO8601DateFormatter()
        try fileHandle.write(contentsOf: "// TablePro MQL Export\n".toUTF8Data())
        try fileHandle.write(contentsOf: "// Generated: \(dateFormatter.string(from: Date()))\n".toUTF8Data())

        let dbName = tables.first?.databaseName ?? ""
        if !dbName.isEmpty {
            try fileHandle.write(contentsOf: "// Database: \(PluginExportUtilities.sanitizeForSQLComment(dbName))\n".toUTF8Data())
        }
        try fileHandle.write(contentsOf: "\n".toUTF8Data())

        let batchSize = settings.batchSize

        for (index, table) in tables.enumerated() {
            try progress.checkCancellation()

            progress.setCurrentTable(table.qualifiedName, index: index + 1)

            let includeDrop = optionValue(table, at: 0)
            let includeIndexes = optionValue(table, at: 1)
            let includeData = optionValue(table, at: 2)

            let collectionAccessor = MQLExportHelpers.collectionAccessor(for: table.name)

            try fileHandle.write(contentsOf: "// Collection: \(PluginExportUtilities.sanitizeForSQLComment(table.name))\n".toUTF8Data())

            if includeDrop {
                try fileHandle.write(contentsOf: "\(collectionAccessor).drop();\n".toUTF8Data())
            }

            if includeData {
                var columns: [String] = []
                var documentBatch: [String] = []

                let stream = dataSource.streamRows(table: table.name, databaseName: table.databaseName)
                for try await element in stream {
                    try progress.checkCancellation()

                    switch element {
                    case .header(let header):
                        columns = header.columns
                    case .rows(let rows):
                        for row in rows {
                            var fields: [String] = []
                            for (colIndex, column) in columns.enumerated() {
                                guard colIndex < row.count else { continue }
                                guard let value = row[colIndex] else { continue }
                                let jsonValue = MQLExportHelpers.mqlJsonValue(for: value)
                                fields.append("\"\(PluginExportUtilities.escapeJSONString(column))\": \(jsonValue)")
                            }
                            documentBatch.append("  {\(fields.joined(separator: ", "))}")

                            if documentBatch.count >= batchSize {
                                try writeMQLInsertMany(
                                    collection: table.name,
                                    documents: documentBatch,
                                    to: fileHandle
                                )
                                documentBatch.removeAll(keepingCapacity: true)
                            }

                            progress.incrementRow()
                        }
                    }
                }

                if !documentBatch.isEmpty {
                    try writeMQLInsertMany(
                        collection: table.name,
                        documents: documentBatch,
                        to: fileHandle
                    )
                }
            }

            if includeIndexes {
                try await writeMQLIndexes(
                    collection: table.name,
                    databaseName: table.databaseName,
                    collectionAccessor: collectionAccessor,
                    dataSource: dataSource,
                    to: fileHandle
                )
            }

            if index < tables.count - 1 {
                try fileHandle.write(contentsOf: "\n".toUTF8Data())
            }
        }

        try progress.checkCancellation()
        try fileHandle.close()
        try PluginExportUtilities.commitAtomicWrite(from: tempURL, to: destination)
        committed = true
        progress.finalizeTable()
        return ExportFormatResult()
    }

    // MARK: - Private

    private func optionValue(_ table: PluginExportTable, at index: Int) -> Bool {
        guard index < table.optionValues.count else { return true }
        return table.optionValues[index]
    }

    private func writeMQLInsertMany(
        collection: String,
        documents: [String],
        to fileHandle: FileHandle
    ) throws {
        let collectionAccessor = MQLExportHelpers.collectionAccessor(for: collection)
        var statement = "\(collectionAccessor).insertMany([\n"
        statement += documents.joined(separator: ",\n")
        statement += "\n]);\n"
        try fileHandle.write(contentsOf: statement.toUTF8Data())
    }

    private func writeMQLIndexes(
        collection: String,
        databaseName: String,
        collectionAccessor: String,
        dataSource: any PluginExportDataSource,
        to fileHandle: FileHandle
    ) async throws {
        let ddl = try await dataSource.fetchTableDDL(
            table: collection,
            databaseName: databaseName
        )

        let lines = ddl.components(separatedBy: "\n")
        var indexLines: [String] = []
        var foundHeader = false

        for line in lines {
            if line.hasPrefix("// Collection:") {
                foundHeader = true
                continue
            }
            if foundHeader {
                var processedLine = line
                let escapedForDDL = collection.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                let ddlAccessor = "db[\"\(escapedForDDL)\"]"
                if processedLine.hasPrefix(ddlAccessor) {
                    processedLine = collectionAccessor + String(processedLine.dropFirst(ddlAccessor.count))
                }
                indexLines.append(processedLine)
            }
        }

        let indexContent = indexLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !indexContent.isEmpty {
            try fileHandle.write(contentsOf: "\(indexContent)\n".toUTF8Data())
        }
    }
}
