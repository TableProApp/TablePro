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
        var groups: [[UInt8]: DataDictionaryGroupReads] = [:]
        let groupSizes = Dictionary(grouping: tables) { PluginExportSpelling.key($0.databaseName) }.mapValues(\.count)
        for (index, table) in tables.enumerated() {
            try progress.checkCancellation()
            progress.setCurrentTable(table.qualifiedName, index: index + 1)
            let group = PluginExportSpelling.key(table.databaseName)
            if groups[group] == nil {
                groups[group] = try await DataDictionaryGroupReads.read(
                    databaseName: table.databaseName,
                    objectCount: groupSizes[group] ?? 0,
                    from: dataSource,
                    progress: progress
                )
            }
            objects.append(try await DataDictionaryReader.read(
                table, from: dataSource, group: groups[group], progress: progress, failures: &failures
            ))
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
        group: DataDictionaryGroupReads? = nil,
        progress: PluginExportProgress,
        failures: inout DataDictionaryReadFailures
    ) async throws -> DataDictionaryObject {
        var object = DataDictionaryObject(name: table.name, container: table.containerName, kind: table.kind)
        do {
            if let columns = group?.columns,
               case .answered(let answered) = PluginExportSpelling.entry(table.name, in: columns) {
                object.columns = answered
            } else {
                object.columns = try await dataSource.fetchColumns(table: table.name, databaseName: table.databaseName)
            }
        } catch {
            try rethrowIfCancelled(error, progress: progress)
            object.columnsError = error.localizedDescription
            failures.columns.append(table.qualifiedName)
        }

        // Every kind, as the Structure tab reads them: SQL Server indexes a view.
        do {
            object.indexes = try await answer(table.name, in: group?.indexes) {
                try await dataSource.fetchIndexes(table: table.name, databaseName: table.databaseName)
            }
        } catch {
            try rethrowIfCancelled(error, progress: progress)
            object.indexesError = error.localizedDescription
            failures.indexes.append(table.qualifiedName)
        }

        if table.kind == .table {
            do {
                object.foreignKeys = try await answer(table.name, in: group?.foreignKeys) {
                    try await dataSource.fetchForeignKeys(table: table.name, databaseName: table.databaseName)
                }
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

    // A table a group read leaves out has none of that kind; one it holds only in another spelling is read alone.
    private static func answer<Value>(
        _ name: String,
        in group: [String: [Value]]?,
        alone: () async throws -> [Value]
    ) async throws -> [Value] {
        guard let group else { return try await alone() }
        switch PluginExportSpelling.entry(name, in: group) {
        case .answered(let values): return values
        case .absent: return []
        case .otherSpelling: return try await alone()
        }
    }

    static func rethrowIfCancelled(_ error: Error, progress: PluginExportProgress) throws {
        if error is CancellationError || error is PluginExportCancellationError { throw error }
        try progress.checkCancellation()
    }
}

// One read per group for what the source answers group-wide. A table such a read leaves out has none of that kind, and
// a read that fails is nil, so each table is read alone and its own failure named.
struct DataDictionaryGroupReads {
    var columns: [String: [PluginColumnInfo]]?
    var foreignKeys: [String: [PluginForeignKeyInfo]]?
    var indexes: [String: [PluginIndexInfo]]?

    // A read that reached the row limit may have stopped inside a table, so it is not taken as that table's answer.
    static func read(
        databaseName: String,
        objectCount: Int,
        from dataSource: any PluginExportDataSource,
        progress: PluginExportProgress,
        rowLimit: Int = PluginRowLimits.emergencyMax
    ) async throws -> DataDictionaryGroupReads {
        var reads = DataDictionaryGroupReads()
        let bulk = dataSource.bulkReads
        guard objectCount > 1 else { return reads }
        if bulk.contains(.columns) {
            reads.columns = try await attempt(progress, rowLimit) {
                try await dataSource.fetchAllColumns(databaseName: databaseName)
            }
        }
        if bulk.contains(.indexes) {
            reads.indexes = try await attempt(progress, rowLimit) {
                try await dataSource.fetchAllIndexes(databaseName: databaseName)
            }
        }
        if bulk.contains(.foreignKeys) {
            reads.foreignKeys = try await attempt(progress, rowLimit) {
                try await dataSource.fetchAllForeignKeys(databaseName: databaseName)
            }
        }
        return reads
    }

    private static func attempt<Element>(
        _ progress: PluginExportProgress,
        _ rowLimit: Int,
        _ read: () async throws -> [String: [Element]]
    ) async throws -> [String: [Element]]? {
        do {
            let answer = try await read()
            return answer.values.reduce(0) { $0 + $1.count } < rowLimit ? answer : nil
        } catch {
            try DataDictionaryReader.rethrowIfCancelled(error, progress: progress)
            return nil
        }
    }
}
