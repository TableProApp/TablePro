//
//  SQLExportCraftedNameTests.swift
//  FormatPluginTests
//

import Foundation
import TableProPluginKit
import Testing

struct SQLExportCraftedNameTests {
    private final class StubExportDataSource: PluginExportDataSource, @unchecked Sendable {
        let databaseTypeId = "PostgreSQL"
        let sequenceName: String
        let typeName: String

        init(sequenceName: String = "orders_id_seq", typeName: String = "mood") {
            self.sequenceName = sequenceName
            self.typeName = typeName
        }

        func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.header(PluginStreamHeader(columns: ["id"], columnTypeNames: ["INTEGER"])))
                continuation.finish()
            }
        }

        func fetchTableDDL(table: String, databaseName: String) async throws -> String {
            "CREATE TABLE \(quoteIdentifier(table)) (id INTEGER)"
        }

        func fetchDependentSequences(table: String, databaseName: String) async throws -> [PluginSequenceInfo] {
            [PluginSequenceInfo(name: sequenceName, ddl: "CREATE SEQUENCE \(quoteIdentifier(sequenceName))")]
        }

        func fetchDependentTypes(table: String, databaseName: String) async throws -> [PluginEnumTypeInfo] {
            [PluginEnumTypeInfo(name: typeName, labels: ["happy"])]
        }

        func execute(query: String) async throws -> PluginQueryResult {
            PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
        }

        func quoteIdentifier(_ identifier: String) -> String {
            "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\"", options: .literal))\""
        }

        func escapeStringLiteral(_ value: String) -> String {
            value.replacingOccurrences(of: "'", with: "''", options: .literal)
        }

        func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }
    }

    private func table(_ name: String) -> PluginExportTable {
        PluginExportTable(
            name: name,
            databaseName: "",
            tableType: PluginExportObjectKind.table.rawValue,
            optionValues: [true, true, true],
            schema: nil,
            kind: .table
        )
    }

    private func lines(of dump: String) -> [[Unicode.Scalar]] {
        dump.unicodeScalars.split(separator: "\n").map(Array.init)
    }

    @Test("A sequence or enum type name with a quote a combining mark follows stays one identifier")
    func dependentNamesStayOneIdentifier() async throws {
        let source = StubExportDataSource(
            sequenceName: "s\"\u{301}; DROP TABLE victims; --",
            typeName: "e\"\u{301}; DROP TABLE victims; --"
        )
        let dump = try await SQLExportHarness.shared.dump(tables: [table("orders")], dataSource: source).text
        let sequenceDrop = Array("DROP SEQUENCE IF EXISTS \"s\"\"\u{301}; DROP TABLE victims; --\"".unicodeScalars)
        let typeDrop = Array("DROP TYPE IF EXISTS \"e\"\"\u{301}; DROP TABLE victims; --\"".unicodeScalars)

        #expect(lines(of: dump).contains { $0.starts(with: sequenceDrop) })
        #expect(lines(of: dump).contains { $0.starts(with: typeDrop) })
    }

    @Test("A table name with a line break a combining mark follows stays inside its comment")
    func tableCommentStaysOnOneLine() async throws {
        let dump = try await SQLExportHarness.shared.dump(
            tables: [table("x\n\u{301}; DELETE FROM accounts;")], dataSource: StubExportDataSource()
        ).text

        #expect(lines(of: dump).contains(Array("-- Table: x \u{301}; DELETE FROM accounts;".unicodeScalars)))
    }
}
