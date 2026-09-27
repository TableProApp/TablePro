//
//  MQLExportPlugin.swift
//  MQLExportPlugin
//

import Combine
import Foundation
import SwiftUI
import TableProPluginKit

final class MQLExportPlugin: ObservableObject, ExportFormatPlugin, SettablePlugin, @unchecked Sendable {
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

    @Published var settings = MQLExportOptions() {
        didSet { saveSettings() }
    }

    required init() { loadSettings() }

    func defaultTableOptionValues() -> [Bool] {
        [true, true, true]
    }

    func isTableExportable(optionValues: [Bool]) -> Bool {
        optionValues.contains(true)
    }

    @MainActor
    func settingsView() -> AnyView? {
        AnyView(MQLExportOptionsView(plugin: self))
    }

    func resetSettingsToDefaults() {
        settings = MQLExportOptions()
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
            let databaseHeader = MQLExportHelpers.headerComment(label: "Database", name: dbName)
            try fileHandle.write(contentsOf: "\(databaseHeader)\n".toUTF8Data())
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
            let collectionHeader = MQLExportHelpers.headerComment(label: "Collection", name: table.name)

            try fileHandle.write(contentsOf: "\(collectionHeader)\n".toUTF8Data())

            if includeDrop {
                try fileHandle.write(contentsOf: "\(collectionAccessor).drop();\n".toUTF8Data())
            }

            if includeData {
                var columns: [String] = []
                var columnTypeNames: [String] = []
                var documentBatch: [String] = []

                let stream = dataSource.streamRows(table: table.name, databaseName: table.databaseName)
                for try await element in stream {
                    try progress.checkCancellation()

                    switch element {
                    case .header(let header):
                        columns = header.columns
                        columnTypeNames = header.columnTypeNames
                    case .rows(let rows):
                        for row in rows {
                            var fields: [(name: String, value: String)] = []
                            for (colIndex, column) in columns.enumerated() {
                                guard colIndex < row.count else { continue }
                                let cell = row[colIndex]
                                let typeName = colIndex < columnTypeNames.count ? columnTypeNames[colIndex] : ""
                                let jsonValue: String
                                switch cell {
                                case .null:
                                    continue
                                case .bytes(let data):
                                    jsonValue = MQLExportHelpers.mqlBinaryValue(
                                        for: data,
                                        subtype: MongoDBUuidCodec.binarySubtype(fromColumnTypeName: typeName)
                                    )
                                case .text(let value):
                                    jsonValue = MQLExportHelpers.mqlTextValue(
                                        for: value, columnTypeName: typeName
                                    )
                                }
                                fields.append((name: column, value: jsonValue))
                            }
                            documentBatch.append(MQLExportHelpers.documentLiteral(fields))

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
        dataSource: any PluginExportDataSource,
        to fileHandle: FileHandle
    ) async throws {
        let ddl = try await dataSource.fetchTableDDL(
            table: collection,
            databaseName: databaseName
        )
        let script = MQLCollectionDefinition.script(fromDDL: ddl, collection: collection)
        guard !script.isEmpty else { return }
        try fileHandle.write(contentsOf: "\(script)\n".toUTF8Data())
    }
}
