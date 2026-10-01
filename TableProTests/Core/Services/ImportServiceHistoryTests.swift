//
//  ImportServiceHistoryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class UnusedImportPlugin: ImportFormatPlugin {
    static let pluginName = "Unused Import"
    static let pluginVersion = "1.0"
    static let pluginDescription = "An import format whose import never starts"
    static let formatId = "tablepro-tests-unused-import"
    static let formatDisplayName = "Unused"
    static let acceptedFileExtensions = ["csv"]
    static let iconName = "tablecells"
    static let requiresTargetTable = true

    required init() {}

    func performImport(
        source: any PluginImportSource,
        sink: any PluginImportDataSink,
        progress: PluginImportProgress
    ) async throws -> PluginImportResult {
        PluginImportResult(executedStatements: 0, executionTime: 0)
    }
}

private actor RecordingHistory: QueryHistoryRecording {
    private(set) var requests: [QueryHistoryRecordRequest] = []

    func record(_ request: QueryHistoryRecordRequest) async -> Bool {
        requests.append(request)
        return true
    }
}

/// An import runs in the scope it was handed, and its history row has to name that database. Reading
/// the browse database when the import ended named wherever another window had moved the connection
/// in the meantime.
@MainActor
struct ImportServiceHistoryTests {
    @Test("An import is recorded under the database it ran in, not the one the connection browses")
    func historyNamesTheScopeDatabase() async throws {
        let formatId = UnusedImportPlugin.formatId
        PluginManager.shared.importPlugins[formatId] = UnusedImportPlugin()
        defer { PluginManager.shared.importPlugins[formatId] = nil }

        let connection = TestFixtures.makeConnection(database: "shop")
        let history = RecordingHistory()
        let service = ImportService(connection: connection, historyRecorder: history)
        let scope = DatabaseScope(connectionId: connection.id, database: "archive", schema: nil)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-history-\(UUID().uuidString)")
            .appendingPathExtension("csv")
        try Data("id\n1\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        await #expect(throws: (any Error).self) {
            try await service.importFile(
                from: file,
                formatId: formatId,
                encoding: .utf8,
                scope: scope,
                targetTable: "orders"
            )
        }

        #expect(await history.requests.map(\.databaseName) == ["archive"])
    }
}
