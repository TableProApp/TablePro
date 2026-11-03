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
        // The DROP statement, left untranslated: the catalog's "Drop" is the verb that deletes a table.
        PluginExportOptionColumn(id: "drop", label: "Drop", width: 44),
        PluginExportOptionColumn(id: "indexes", label: String(localized: "Indexes", bundle: .main), width: 44),
        PluginExportOptionColumn(id: "data", label: String(localized: "Data", bundle: .main), width: 44)
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

    // Without it, Data off still counts every collection's rows and the progress sits at 0 of N.
    func readsRows(optionValues: [Bool], kind: PluginExportObjectKind) -> Bool {
        optionValues.count <= 2 || optionValues[2]
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
                var documentBatch = MQLDocumentBatch(countLimit: batchSize)

                let stream = dataSource.streamExportRows(for: table)
                for try await element in stream {
                    try progress.checkCancellation()

                    switch element {
                    case .header:
                        break
                    case .rows(let rows, let documents):
                        guard let documents, documents.count == rows.count else {
                            throw PluginExportError.exportFailed(String(
                                localized: "No typed documents. Update the database driver, save changes and reload before exporting MQL.",
                                bundle: .main
                            ))
                        }
                        for document in documents {
                            let literal = try MQLExportHelpers.documentLiteral(document)
                            let ready = documentBatch.append(literal, bsonSizeUpperBound: document.bsonSizeUpperBound)
                            for batch in ready {
                                try writeMQLInsertMany(collection: table.name, documents: batch, to: fileHandle)
                            }

                            progress.incrementRow()
                        }
                    @unknown default:
                        throw PluginExportError.encodingFailed
                    }
                }

                let remaining = documentBatch.finish()
                if !remaining.isEmpty {
                    try writeMQLInsertMany(collection: table.name, documents: remaining, to: fileHandle)
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
        let statement = MQLExportHelpers.insertCommand(collection: collection, documents: documents)
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
