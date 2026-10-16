//
//  RowChangeStatementFactoryExpressionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class ExpressionRecordingDriver: PluginDriverStub, @unchecked Sendable {
    let capabilities: PluginCapabilities
    private(set) var changes: [PluginRowChange] = []

    init(capabilities: PluginCapabilities) {
        self.capabilities = capabilities
    }

    func generateRowWrites(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>,
        context: PluginRowWriteContext
    ) throws -> [PluginRowWrite]? {
        if !changes.contains(where: { $0.cellChanges.isEmpty && $0.type == .update }) {
            self.changes = changes
        }
        return [PluginRowWrite(statement: "WRITE", rowIndices: changes.map(\.rowIndex))]
    }

    func quoteIdentifier(_ name: String) -> String { "[\(name)]" }
}

@MainActor
struct RowChangeStatementFactoryExpressionTests {
    private let columns = ["id", "name", "stamped_at"]

    private func factory(
        databaseType: DatabaseType = .postgresql,
        driver: (any PluginDatabaseDriver)? = nil
    ) -> RowChangeStatementFactory {
        RowChangeStatementFactory(
            tableName: "events",
            schemaName: nil,
            columns: columns,
            primaryKeyColumns: ["id"],
            databaseType: databaseType,
            pluginDriver: driver
        )
    }

    private func edit(to value: PluginCellValue, isExpression: Bool = true, column: Int = 2) -> RowChange {
        RowChange(
            rowID: .existing(0),
            type: .update,
            cellChanges: [
                CellChange(
                    columnIndex: column, columnName: columns[column], oldValue: "2026-01-01", newValue: value,
                    newIsExpression: isExpression
                ),
            ],
            originalRow: ["1", "Ada", "2026-01-01"]
        )
    }

    private func refusal(_ body: () throws -> Void) -> (kind: RowWriteKind?, reason: String)? {
        do {
            try body()
            return nil
        } catch let DataWriteError.changeRefused(_, kind, reason) {
            return (kind, reason)
        } catch {
            Issue.record("Unexpected error: \(error)")
            return nil
        }
    }

    @Test("A marked cell whose text is not the engine's own spelling is refused, naming the column")
    func nonCanonicalTextIsRefused() {
        let refused = refusal { _ = try factory().statements(for: [edit(to: "NOW()")]) }
        #expect(refused?.kind == .update)
        #expect(refused?.reason.contains("stamped_at") == true)

        let injected = refusal { _ = try factory().statements(for: [edit(to: "now(); DROP TABLE events")]) }
        #expect(injected != nil)
    }

    @Test("A new row's marked cell is checked the same way")
    func nonCanonicalInsertIsRefused() {
        let rowID = RowID.inserted(UUID())
        let change = RowChange(rowID: rowID, type: .insert, expressionColumns: [2])
        let refused = refusal {
            _ = try factory().statements(
                for: [change], insertedRowData: [rowID: ["1", "Ada", "1 + 1"]], insertedRowIDs: [rowID]
            )
        }
        #expect(refused?.kind == .insert)
    }

    @Test("An unmarked change in a column another change marks is checked, since a driver reads the mark by column")
    func unmarkedChangeInMarkedColumnIsRefused() {
        let change = RowChange(
            rowID: .existing(0),
            type: .update,
            cellChanges: [
                CellChange(
                    columnIndex: 2, columnName: "stamped_at", oldValue: "2026-01-01", newValue: "now()",
                    newIsExpression: true
                ),
                CellChange(columnIndex: 2, columnName: "stamped_at", oldValue: "now()", newValue: "1); DROP TABLE x; --"),
            ],
            originalRow: ["1", "Ada", "2026-01-01"]
        )
        let driver = ExpressionRecordingDriver(capabilities: [.cellExpressions])
        let refused = refusal { _ = try factory(databaseType: .postgresql, driver: driver).statements(for: [change]) }
        #expect(refused?.kind == .update)
        #expect(driver.changes.isEmpty)
    }

    @Test("Every cell change of a new row's marked column is checked, not only the first")
    func everyInsertCellChangeInMarkedColumnIsChecked() {
        let rowID = RowID.inserted(UUID())
        let change = RowChange(
            rowID: rowID,
            type: .insert,
            cellChanges: [
                CellChange(columnIndex: 2, columnName: "stamped_at", oldValue: .null, newValue: "now()", newIsExpression: true),
                CellChange(columnIndex: 2, columnName: "stamped_at", oldValue: "now()", newValue: "1 + 1"),
            ],
            expressionColumns: [2]
        )
        let refused = refusal { _ = try factory().statements(for: [change], insertedRowIDs: [rowID]) }
        #expect(refused?.kind == .insert)
    }

    @Test("The engine's own spelling goes through")
    func canonicalTextIsWritten() throws {
        let statements = try factory().statements(for: [edit(to: "now()")])
        #expect(statements.first?.sql.contains("\"stamped_at\" = now()") == true)
    }

    @Test("A driver that writes its own statements and does not read the mark is not handed one")
    func pluginWithoutCapabilityIsRefused() {
        let driver = ExpressionRecordingDriver(capabilities: [])
        let refused = refusal {
            _ = try factory(databaseType: .mssql, driver: driver).statements(for: [edit(to: "GETDATE()")])
        }
        #expect(refused?.kind == .update)
        #expect(driver.changes.isEmpty)
    }

    @Test("A driver that reads the mark is handed the marked columns")
    func pluginWithCapabilityGetsExpressionColumns() throws {
        let driver = ExpressionRecordingDriver(capabilities: [.cellExpressions])
        let rowID = RowID.inserted(UUID())
        _ = try factory(databaseType: .mssql, driver: driver).statements(
            for: [
                edit(to: "GETDATE()"),
                RowChange(rowID: rowID, type: .insert, expressionColumns: [2], sequence: 1),
            ],
            insertedRowData: [rowID: ["2", "Grace", "SYSDATETIME()"]],
            insertedRowIDs: [rowID]
        )

        #expect(driver.changes.count == 2)
        #expect(driver.changes.first { $0.type == .update }?.expressionColumns == [2])
        #expect(driver.changes.first { $0.type == .insert }?.expressionColumns == [2])
    }

    @Test("A change with no marked cell hands the driver nil")
    func noMarksIsNil() throws {
        let driver = ExpressionRecordingDriver(capabilities: [.cellExpressions])
        _ = try factory(databaseType: .mssql, driver: driver).statements(
            for: [edit(to: "Grace", isExpression: false, column: 1)]
        )
        #expect(driver.changes.first?.expressionColumns == nil)
    }

    @Test("A text value that reads like a function reaches a driver as text, whatever it declares")
    func unmarkedTextNeedsNoCapability() throws {
        let driver = ExpressionRecordingDriver(capabilities: [])
        _ = try factory(databaseType: .mssql, driver: driver).statements(
            for: [edit(to: "GETDATE()", isExpression: false, column: 1)]
        )
        #expect(driver.changes.count == 1)
    }

    @Test("SQLite refuses DEFAULT on a saved row, naming the column")
    func sqliteDefaultUpdateIsRefused() {
        let change = edit(to: .text(PluginCellValue.defaultMarkerText), isExpression: false, column: 1)
        let refused = refusal { _ = try factory(databaseType: .sqlite).statements(for: [change]) }
        #expect(refused?.kind == .update)
        #expect(refused?.reason.contains("name") == true)
    }

    @Test("A new SQLite row still leaves a defaulted column out")
    func sqliteDefaultInsertIsWritten() throws {
        let rowID = RowID.inserted(UUID())
        let statements = try factory(databaseType: .sqlite).statements(
            for: [RowChange(rowID: rowID, type: .insert)],
            insertedRowData: [rowID: ["1", .text(PluginCellValue.defaultMarkerText), "2026-01-01"]],
            insertedRowIDs: [rowID]
        )
        #expect(statements.count == 1)
        #expect(statements.first?.parameters.count == 2)
    }

    @Test("PostgreSQL takes DEFAULT on a saved row")
    func postgresDefaultUpdate() throws {
        let change = edit(to: .text(PluginCellValue.defaultMarkerText), isExpression: false, column: 1)
        let statements = try factory().statements(for: [change])
        #expect(statements.first?.sql.contains("\"name\" = DEFAULT") == true)
    }
}
