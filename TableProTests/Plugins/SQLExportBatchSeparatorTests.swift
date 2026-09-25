//
//  SQLExportBatchSeparatorTests.swift
//  TableProTests
//
//  SQL Server's client runs a script in batches cut at lines holding only `GO`, and SQL Server refuses a view, a
//  routine or a trigger that is not the first statement of its batch with Msg 111. A dump written with only `;`
//  between statements is one batch, so its first view failed the whole batch in sqlcmd and in SQL Server Management
//  Studio.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSQLGrammar
import Testing

/// Holds an export inside its first table definition fetch until the test lets it go, so a second export can run to
/// its end on the same plugin in between.
private actor ExportPause {
    private var reached = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var released = false
    private var release: CheckedContinuation<Void, Never>?

    func hold() async {
        reached = true
        arrival?.resume()
        arrival = nil
        guard !released else { return }
        await withCheckedContinuation { release = $0 }
    }

    func untilReached() async {
        guard !reached else { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func resume() {
        released = true
        release?.resume()
        release = nil
    }
}

struct SQLExportBatchSeparatorTests {
    private final class ServerDataSource: PluginExportDataSource, @unchecked Sendable {
        let databaseTypeId: String
        let lexicalFeatures: SQLLexicalFeatures
        private let scriptTextOwner: SQLScriptText
        private let pause: ExportPause?

        init(databaseType: DatabaseType, pause: ExportPause? = nil) {
            self.databaseTypeId = databaseType.rawValue
            self.lexicalFeatures = databaseType.lexicalGrammar.pluginFeatures
            self.scriptTextOwner = SQLScriptText(databaseType: databaseType)
            self.pause = pause
        }

        func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.header(PluginStreamHeader(columns: ["id", "name"], columnTypeNames: ["INT", "NVARCHAR"])))
                continuation.yield(.rows([[.text("1"), .text("a")], [.text("2"), .text("b")]]))
                continuation.finish()
            }
        }

        func fetchAllColumns(databaseName: String) async throws -> [String: [PluginColumnInfo]] {
            [
                "orders": [
                    PluginColumnInfo(name: "id", dataType: "INT", isNullable: false, identityKind: .byDefault),
                    PluginColumnInfo(name: "name", dataType: "NVARCHAR"),
                ],
            ]
        }

        func fetchTableDDL(table: String, databaseName: String) async throws -> String {
            await pause?.hold()
            return "CREATE TABLE [orders] ([id] INT IDENTITY(1,1) NOT NULL, [name] NVARCHAR(10) NULL)"
        }

        func fetchObjectDDL(_ object: PluginExportTable) async throws -> String {
            switch object.kind {
            case .view:
                return "CREATE VIEW [v_orders] AS SELECT id FROM orders"
            case .routine:
                return "CREATE PROCEDURE [p_orders] AS SET NOCOUNT ON; SELECT 1;"
            default:
                return try await fetchTableDDL(table: object.name, databaseName: object.databaseName)
            }
        }

        func scriptText(for ddl: String) -> String {
            scriptTextOwner.scriptText(forDriverText: ddl)
        }

        func execute(query: String) async throws -> PluginQueryResult {
            PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
        }

        func quoteIdentifier(_ identifier: String) -> String {
            "[\(identifier.replacingOccurrences(of: "]", with: "]]"))]"
        }

        func escapeStringLiteral(_ value: String) -> String {
            value.replacingOccurrences(of: "'", with: "''")
        }

        func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }
    }

    private func object(_ name: String, kind: PluginExportObjectKind) -> PluginExportTable {
        PluginExportTable(
            name: name,
            databaseName: "",
            tableType: kind.rawValue,
            optionValues: [true, true, true],
            schema: nil,
            kind: kind)
    }

    private var objects: [PluginExportTable] {
        [
            object("orders", kind: .table),
            object("v_orders", kind: .view),
            object("p_orders", kind: .routine),
        ]
    }

    private func dump(_ databaseType: DatabaseType) async throws -> String {
        try await SQLExportHarness.shared.dump(
            tables: objects,
            dataSource: ServerDataSource(databaseType: databaseType)
        ).text
    }

    private func goLines(in dump: String) -> Int {
        dump.components(separatedBy: "\n").filter { $0 == "GO" }.count
    }

    /// What SQL Server's client would send, with the comment lines the dump writes around each statement set aside.
    private func batches(of dump: String) async throws -> [String] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sql")
        try dump.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        var batches: [String] = []
        for try await (batch, _) in SQLFileParser().parseFile(url: url, encoding: .utf8, grammar: TestGrammar.sqlServer) {
            let code = batch
                .components(separatedBy: "\n")
                .filter { !$0.hasPrefix("--") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            batches.append(code)
        }
        return batches
    }

    @Test("The dump source reports SQL Server's GO lines, and no other engine's")
    func adapterReportsBatchLines() {
        let sqlServer = ExportDataSourceAdapter(driver: MockDatabaseDriver(), databaseType: .mssql)
        let mysql = ExportDataSourceAdapter(driver: MockDatabaseDriver(), databaseType: .mysql)
        #expect(sqlServer.lexicalFeatures.contains(.batchSeparatorLines))
        #expect(!mysql.lexicalFeatures.contains(.batchSeparatorLines))
    }

    @Test("Every statement of a SQL Server dump is a batch of its own, the view and the routine first in theirs")
    func everyStatementIsItsOwnBatch() async throws {
        let batches = try await batches(of: try await dump(.mssql))

        #expect(batches.contains("CREATE VIEW [v_orders] AS SELECT id FROM orders;"))
        #expect(batches.contains("CREATE PROCEDURE [p_orders] AS SET NOCOUNT ON; SELECT 1;"))
        #expect(batches.contains("CREATE TABLE [orders] ([id] INT IDENTITY(1,1) NOT NULL, [name] NVARCHAR(10) NULL);"))
        #expect(batches.contains("SET IDENTITY_INSERT [orders] ON;"))
        #expect(batches.contains("SET IDENTITY_INSERT [orders] OFF;"))
        #expect(batches.contains { $0.hasPrefix("INSERT INTO [orders]") && $0.hasSuffix(";") })
        #expect(batches.filter { $0.hasPrefix("DROP ") }.count == 3)
    }

    @Test("A SQL Server dump ends each statement on a GO line, as SQL Server Management Studio writes one")
    func goLinesFollowStatements() async throws {
        let dump = try await dump(.mssql)
        #expect(dump.contains("SET IDENTITY_INSERT [orders] ON;\nGO\nINSERT INTO [orders]"))
        #expect(dump.contains(");\nGO\n\nSET IDENTITY_INSERT [orders] OFF;\nGO\n"))
        #expect(dump.contains("CREATE VIEW [v_orders] AS SELECT id FROM orders;\nGO\n"))
    }

    @Test("An engine without batches gets no GO line")
    func otherEnginesGetNoGoLine() async throws {
        let dump = try await dump(.mysql)
        #expect(!dump.components(separatedBy: "\n").contains("GO"))
    }

    /// Every window gets the same plugin instance, so an export can start while another is still writing. Its engine
    /// must not change how the first one ends its statements: a SQL Server dump that lost its GO lines partway fails
    /// its first view on restore with Msg 111, and a MySQL dump that gained them fails at the first `GO`.
    @Test("Two exports on one plugin each end their statements the way their own engine reads them")
    func exportsSharingThePluginKeepTheirOwnStatementEnds() async throws {
        let expectedGoLines = [
            DatabaseType.mssql: goLines(in: try await dump(.mssql)),
            DatabaseType.mysql: goLines(in: try await dump(.mysql)),
        ]
        #expect(expectedGoLines[.mssql, default: 0] > 0)

        for (heldType, otherType) in [(DatabaseType.mssql, DatabaseType.mysql), (.mysql, .mssql)] {
            let pause = ExportPause()
            let tables = objects
            let (held, other) = try await SQLExportHarness.shared.withPlugin { plugin in
                async let held = SQLExportHarness.dump(
                    on: plugin, tables: tables, dataSource: ServerDataSource(databaseType: heldType, pause: pause)
                )
                await pause.untilReached()
                let other = try await SQLExportHarness.dump(
                    on: plugin, tables: tables, dataSource: ServerDataSource(databaseType: otherType)
                )
                await pause.resume()
                return (try await held, other)
            }
            #expect(goLines(in: held) == expectedGoLines[heldType], "\(heldType.rawValue) held while another ran")
            #expect(goLines(in: other) == expectedGoLines[otherType], "\(otherType.rawValue) run during another")
        }
    }
}
