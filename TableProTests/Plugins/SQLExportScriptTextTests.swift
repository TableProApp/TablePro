//
//  SQLExportScriptTextTests.swift
//  TableProTests
//
//  A dump is a script for the engine's own client. Written with a bare `;` after every
//  definition, an Oracle dump buffered every statement after the first procedure in SQL*Plus and
//  a MySQL dump broke its routine at the first `;` inside the body.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("SQL export script text")
struct SQLExportScriptTextTests {
    private final class DefinitionDataSource: PluginExportDataSource, @unchecked Sendable {
        let databaseTypeId: String
        let tableDDL: String
        let routineDDL: String
        private let scriptTextOwner: SQLScriptText

        init(databaseType: DatabaseType, tableDDL: String, routineDDL: String) {
            self.databaseTypeId = databaseType.rawValue
            self.tableDDL = tableDDL
            self.routineDDL = routineDDL
            self.scriptTextOwner = SQLScriptText(databaseType: databaseType)
        }

        func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func fetchTableDDL(table: String, databaseName: String) async throws -> String { tableDDL }

        func fetchObjectDDL(_ object: PluginExportTable) async throws -> String {
            object.kind == .routine ? routineDDL : tableDDL
        }

        func scriptText(for ddl: String) -> String {
            scriptTextOwner.scriptText(forDriverText: ddl)
        }

        func execute(query: String) async throws -> PluginQueryResult {
            PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
        }

        func quoteIdentifier(_ identifier: String) -> String {
            "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
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
            optionValues: [true, false, false],
            schema: nil,
            kind: kind)
    }

    private func dump(_ source: DefinitionDataSource) async throws -> String {
        try await SQLExportHarness.shared.dump(
            tables: [object("T", kind: .table), object("P", kind: .routine)],
            dataSource: source
        ).text
    }

    @Test("An Oracle dump ends a unit on a / line and splits a table from its index")
    func oracleDump() async throws {
        let procedure = "CREATE OR REPLACE PROCEDURE P IS\nBEGIN\n  NULL;\nEND;"
        let dump = try await dump(DefinitionDataSource(
            databaseType: .oracle,
            tableDDL: "CREATE TABLE \"T\" (\n  \"A\" NUMBER\n);\n\nCREATE INDEX \"I\" ON \"T\" (\"A\");",
            routineDDL: procedure
        ))

        #expect(dump.contains("\(procedure)\n/\n"))
        #expect(dump.contains("CREATE TABLE \"T\" (\n  \"A\" NUMBER\n);\nCREATE INDEX \"I\" ON \"T\" (\"A\");"))
    }

    @Test("A MySQL dump puts a routine body in a DELIMITER block")
    func mysqlDump() async throws {
        let routine = "CREATE PROCEDURE `P`()\nBEGIN\n  SELECT 1;\n  SELECT 2;\nEND"
        let dump = try await dump(DefinitionDataSource(
            databaseType: .mysql,
            tableDDL: "CREATE TABLE `T` (`a` int)",
            routineDDL: routine
        ))

        #expect(dump.contains("DELIMITER //\n\(routine) //\nDELIMITER ;"))
        #expect(dump.contains("CREATE TABLE `T` (`a` int);"))
    }
}
