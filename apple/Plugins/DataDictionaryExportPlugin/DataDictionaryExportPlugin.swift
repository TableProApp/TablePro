//
//  DataDictionaryExportPlugin.swift
//  DataDictionaryExportPlugin
//

import Combine
import Foundation
import SwiftUI
import TableProPluginKit

final class DataDictionaryExportPlugin: ObservableObject, ExportFormatPlugin, SettablePlugin, @unchecked Sendable {
    static let pluginName = "Data Dictionary Export"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Describe every table and column as Markdown or HTML"
    static let formatId = "datadict"
    static var formatDisplayName: String { String(localized: "Data Dictionary", bundle: .main) }
    static let defaultFileExtension = "md"
    static let iconName = "book.closed"
    static let supportedObjectKinds: [PluginExportObjectKind] = [.table, .view, .materializedView, .foreignTable]
    // Both read items to list a table's fields, though their snapshots do not mark the columns as sampled.
    static let excludedDatabaseTypeIds = ["DynamoDB", "SurrealDB"]

    typealias Settings = DataDictionaryExportOptions
    static let settingsStorageId = "datadict"

    @Published var settings = DataDictionaryExportOptions() {
        didSet { saveSettings() }
    }

    required init() { loadSettings() }

    @MainActor
    func settingsView() -> AnyView? {
        AnyView(DataDictionaryExportOptionsView(plugin: self))
    }

    func resetSettingsToDefaults() {
        settings = DataDictionaryExportOptions()
    }

    var currentFileExtension: String {
        settings.fileType.fileExtension
    }

    func readsRows(optionValues: [Bool], kind: PluginExportObjectKind) -> Bool {
        false
    }

    func export(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        destination: URL,
        progress: PluginExportProgress
    ) async throws -> ExportFormatResult {
        // Read once: every window shares this instance, and another one's options pane can write it.
        let fileType = settings.fileType
        var failures = DataDictionaryReadFailures()
        var objects: [DataDictionaryObject] = []
        objects.reserveCapacity(tables.count)
        for (index, table) in tables.enumerated() {
            try progress.checkCancellation()
            progress.setCurrentTable(table.qualifiedName, index: index + 1)
            objects.append(try await DataDictionaryReader.read(table, from: dataSource, progress: progress, failures: &failures))
        }
        try progress.checkCancellation()

        let document = DataDictionaryDocument(
            title: destination.deletingPathExtension().lastPathComponent,
            databaseTypeId: dataSource.databaseTypeId,
            generatedAt: Date(),
            objects: objects
        )
        let text = switch fileType {
        case .markdown: DataDictionaryMarkdownRenderer.render(document)
        case .html: DataDictionaryHTMLRenderer.render(document)
        }

        let (fileHandle, tempURL) = try PluginExportUtilities.beginAtomicWrite(for: destination)
        var committed = false
        defer {
            if !committed { PluginExportUtilities.rollbackAtomicWrite(at: tempURL) }
        }
        try fileHandle.write(contentsOf: text.toUTF8Data())
        try fileHandle.close()
        try PluginExportUtilities.commitAtomicWrite(from: tempURL, to: destination)
        committed = true
        progress.finalizeTable()
        return ExportFormatResult(warnings: failures.warnings)
    }
}

struct DataDictionaryReadFailures {
    var columns: [String] = []
    var indexes: [String] = []
    var foreignKeys: [String] = []
    var comments: [String] = []

    var warnings: [String] {
        var warnings: [String] = []
        if !columns.isEmpty {
            warnings.append(String(
                format: String(localized: "Could not fetch table structure for: %@", bundle: .main),
                columns.joined(separator: ", ")))
        }
        if !indexes.isEmpty {
            warnings.append(String(
                format: String(localized: "Could not fetch indexes for: %@", bundle: .main),
                indexes.joined(separator: ", ")))
        }
        if !foreignKeys.isEmpty {
            warnings.append(String(
                format: String(localized: "Could not fetch foreign keys for: %@", bundle: .main),
                foreignKeys.joined(separator: ", ")))
        }
        if !comments.isEmpty {
            warnings.append(String(
                format: String(localized: "Could not fetch comments for: %@", bundle: .main),
                comments.joined(separator: ", ")))
        }
        return warnings
    }
}

// Catalog reads only. A failed read is named in the summary and in the file, never left as a gap
// that reads like an object with no indexes or no comment.
enum DataDictionaryReader {
    static func read(
        _ table: PluginExportTable,
        from dataSource: any PluginExportDataSource,
        progress: PluginExportProgress,
        failures: inout DataDictionaryReadFailures
    ) async throws -> DataDictionaryObject {
        var object = DataDictionaryObject(name: table.name, container: table.containerName, kind: table.kind)
        do {
            object.columns = try await dataSource.fetchColumns(table: table.name, databaseName: table.databaseName)
        } catch {
            try rethrowIfCancelled(error, progress: progress)
            object.columnsError = error.localizedDescription
            failures.columns.append(table.qualifiedName)
        }

        // Every kind, as the Structure tab reads them: SQL Server indexes a view.
        do {
            object.indexes = try await dataSource.fetchIndexes(table: table.name, databaseName: table.databaseName)
        } catch {
            try rethrowIfCancelled(error, progress: progress)
            object.indexesError = error.localizedDescription
            failures.indexes.append(table.qualifiedName)
        }

        if table.kind == .table {
            do {
                object.foreignKeys = try await dataSource.fetchForeignKeys(table: table.name, databaseName: table.databaseName)
            } catch {
                try rethrowIfCancelled(error, progress: progress)
                object.foreignKeysError = error.localizedDescription
                failures.foreignKeys.append(table.qualifiedName)
            }
        }

        do {
            object.comment = try await dataSource.fetchObjectComment(table)
        } catch {
            try rethrowIfCancelled(error, progress: progress)
            object.commentError = error.localizedDescription
            failures.comments.append(table.qualifiedName)
        }
        return object
    }

    private static func rethrowIfCancelled(_ error: Error, progress: PluginExportProgress) throws {
        if error is CancellationError || error is PluginExportCancellationError { throw error }
        try progress.checkCancellation()
    }
}
