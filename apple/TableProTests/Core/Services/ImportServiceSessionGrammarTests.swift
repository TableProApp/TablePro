//
//  ImportServiceSessionGrammarTests.swift
//  TableProTests
//
//  A SQL file is split the way the connection's session lexes, so a KingbaseES cluster in Oracle mode gets a
//  PL/SQL block whole and its `/` line is never sent.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class SessionGrammarDriver: PluginDriverStub, @unchecked Sendable {
    let sessionLexicalState: PluginSessionLexicalState?
    private let lock = NSLock()
    private var executed: [String] = []

    init(sessionLexicalState: PluginSessionLexicalState?) {
        self.sessionLexicalState = sessionLexicalState
    }

    var statements: [String] {
        lock.withLock { executed }
    }

    func execute(query: String) async throws -> PluginQueryResult {
        lock.withLock { executed.append(query) }
        return .empty
    }
}

/// Sends every statement the source reads, as the SQL import does.
private final class ForwardingImportPlugin: ImportFormatPlugin {
    static let pluginName = "Forwarding Import"
    static let pluginVersion = "1.0"
    static let pluginDescription = "An import format that sends each statement its source reads"
    static let formatId = "tablepro-tests-forwarding-import"
    static let formatDisplayName = "Forwarding"
    static let acceptedFileExtensions = ["sql"]
    static let iconName = "doc"
    static let requiresTargetTable = false

    required init() {}

    func performImport(
        source: any PluginImportSource,
        sink: any PluginImportDataSink,
        progress: PluginImportProgress
    ) async throws -> PluginImportResult {
        var count = 0
        for try await (statement, line) in try await source.statements() {
            try await sink.execute(statement: statement, line: line)
            count += 1
        }
        return PluginImportResult(executedStatements: count, executionTime: 0)
    }
}

private actor DiscardingHistory: QueryHistoryRecording {
    func record(_ request: QueryHistoryRecordRequest) async -> Bool { true }
}

@MainActor
struct ImportServiceSessionGrammarTests {
    private static let file = "BEGIN x := 1; y := 2; END;\n/\nSELECT 2;\n"

    private func importFile(on driver: SessionGrammarDriver) async throws -> [String] {
        let connection = TestFixtures.makeConnection(database: "app", type: .kingbasees)
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: driver)
        )
        session.browseDatabase = "app"
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let formatId = "\(ForwardingImportPlugin.formatId)-\(UUID().uuidString)"
        PluginManager.shared.importPlugins[formatId] = ForwardingImportPlugin()
        defer { PluginManager.shared.importPlugins[formatId] = nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-grammar-import-\(UUID().uuidString)")
            .appendingPathExtension("sql")
        try Data(Self.file.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let service = ImportService(connection: connection, historyRecorder: DiscardingHistory(), gate: AlwaysAllowGate())
        _ = try await service.importFile(
            from: url,
            formatId: formatId,
            encoding: .utf8,
            scope: DatabaseScope(connectionId: connection.id, database: "app", schema: nil)
        )
        return driver.statements
    }

    @Test("An Oracle-mode session gets a PL/SQL block whole, and the / line that ends it is not sent")
    func oracleModeSessionKeepsTheBlockWhole() async throws {
        let sent = try await importFile(on: SessionGrammarDriver(sessionLexicalState: TestGrammar.kingbaseESOracleSession))

        #expect(sent == ["BEGIN x := 1; y := 2; END;", "SELECT 2"])
    }

    @Test("Without a session that says otherwise the file splits as PostgreSQL does")
    func defaultGrammarSplitsAtEverySemicolon() async throws {
        let sent = try await importFile(on: SessionGrammarDriver(sessionLexicalState: nil))

        #expect(sent.first == "BEGIN x := 1")
    }
}
