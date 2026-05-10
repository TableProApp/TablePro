//
//  SQLStatementGeneratorBinaryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("SQL Statement Generator - binary cells")
struct SQLStatementGeneratorBinaryTests {
    private func makeGenerator(
        databaseType: DatabaseType = .postgresql
    ) throws -> SQLStatementGenerator {
        try SQLStatementGenerator(
            tableName: "documents",
            columns: ["id", "payload"],
            primaryKeyColumns: ["id"],
            databaseType: databaseType,
            dialect: nil
        )
    }

    @Test("UPDATE with .bytes newValue emits Data parameter, not String")
    func updatePreservesBinaryParameter() throws {
        let generator = try makeGenerator()
        let bytes = Data([0xD3, 0x8C, 0xE5, 0x66, 0xB9, 0x67, 0x52, 0x0C])
        let change = RowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                CellChange(
                    rowIndex: 0,
                    columnIndex: 1,
                    columnName: "payload",
                    oldValue: .null,
                    newValue: .bytes(bytes)
                )
            ],
            originalRow: [.text("42"), .null]
        )
        guard let stmt = generator.generateUpdateSQL(for: change) else {
            Issue.record("UPDATE statement was not generated")
            return
        }
        guard stmt.parameters.count == 2 else {
            Issue.record("Expected 2 parameters (payload + pk), got \(stmt.parameters.count)")
            return
        }
        guard let payload = stmt.parameters[0] as? Data else {
            Issue.record("First parameter is not Data: \(String(describing: stmt.parameters[0]))")
            return
        }
        #expect(payload == bytes)
        #expect(stmt.parameters[1] as? String == "42")
    }

    @Test("INSERT with .bytes newValue emits Data parameter")
    func insertPreservesBinaryParameter() throws {
        let generator = try makeGenerator()
        let bytes = Data([0xFF, 0x00, 0x7F, 0x80])
        let change = RowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [
                CellChange(
                    rowIndex: 0,
                    columnIndex: 1,
                    columnName: "payload",
                    oldValue: .null,
                    newValue: .bytes(bytes)
                )
            ]
        )
        let statements = generator.generateStatements(
            from: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )
        guard let stmt = statements.first else {
            Issue.record("INSERT statement was not generated")
            return
        }
        guard let payload = stmt.parameters.first as? Data else {
            Issue.record("First parameter is not Data: \(String(describing: stmt.parameters.first ?? nil))")
            return
        }
        #expect(payload == bytes)
    }

    @Test("Issue #1188 exact value survives UPDATE round-trip as Data")
    func issue1188WriteRoundTrip() throws {
        let generator = try makeGenerator()
        let bytes = Data([
            0xD3, 0x8C, 0xE5, 0x66, 0xB9, 0x67, 0x52, 0x0C,
            0xAF, 0x46, 0x17, 0x47, 0xAB, 0xC7, 0x7D, 0x27,
            0x5F, 0x08, 0x4F, 0x60, 0x16, 0x97, 0xD1, 0xEA,
            0x13, 0x5B, 0x03, 0x61, 0xCA, 0xBB, 0x53, 0x4F,
            0x70, 0x22, 0x02, 0xB9, 0x52, 0xE0, 0x04, 0x47,
            0xB6, 0x75, 0x68, 0x7A, 0xF8, 0xF5, 0xD4, 0x3B
        ])
        let change = RowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                CellChange(
                    rowIndex: 0,
                    columnIndex: 1,
                    columnName: "payload",
                    oldValue: .null,
                    newValue: .bytes(bytes)
                )
            ],
            originalRow: [.text("42"), .null]
        )
        guard let stmt = generator.generateUpdateSQL(for: change) else {
            Issue.record("UPDATE statement was not generated")
            return
        }
        guard let payload = stmt.parameters.first as? Data else {
            Issue.record("First parameter is not Data")
            return
        }
        #expect(payload.count == 48)
        #expect(payload == bytes)
        #expect(payload.first == 0xD3)
    }

    @Test("INSERT via lazy insertedRowData with .bytes emits Data parameter")
    func insertViaLazyDataPreservesBinaryParameter() throws {
        let generator = try makeGenerator()
        let bytes = Data([0xCA, 0xFE, 0xBA, 0xBE, 0xDE, 0xAD])
        let change = RowChange(
            rowIndex: 7,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )
        let statements = generator.generateStatements(
            from: [change],
            insertedRowData: [7: [.text("99"), .bytes(bytes)]],
            deletedRowIndices: [],
            insertedRowIndices: [7]
        )
        guard let stmt = statements.first else {
            Issue.record("INSERT statement not generated for lazy path")
            return
        }
        guard stmt.parameters.count == 2 else {
            Issue.record("Expected 2 parameters, got \(stmt.parameters.count)")
            return
        }
        #expect(stmt.parameters[0] as? String == "99")
        #expect(stmt.parameters[1] as? Data == bytes)
    }

    @Test(".null parameters bind as NSNull/nil, not String")
    func nullParameterIsNotString() throws {
        let generator = try makeGenerator()
        let change = RowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                CellChange(
                    rowIndex: 0,
                    columnIndex: 1,
                    columnName: "payload",
                    oldValue: .text("old"),
                    newValue: .null
                )
            ],
            originalRow: [.text("42"), .text("old")]
        )
        guard let stmt = generator.generateUpdateSQL(for: change) else {
            Issue.record("UPDATE statement was not generated")
            return
        }
        let firstParam = stmt.parameters.first
        #expect(firstParam == nil || firstParam.flatMap { $0 } == nil)
    }
}
