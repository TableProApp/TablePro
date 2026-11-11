//
//  RedisColumnDefaultTests.swift
//  RedisDriverTests
//

import Foundation
import TableProPluginKit
import Testing

struct RedisColumnDefaultTests {
    private let driver = RedisPluginDriver(config: DriverConnectionConfig(
        host: "127.0.0.1", port: 6_379, username: "", password: "", database: "0"
    ))

    private func valueEdit(to value: PluginCellValue, isDefault: Bool) -> PluginRowChange {
        var change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 1, columnName: "Value", oldValue: "old", newValue: value)],
            originalRow: ["session:abc", "old", "-1"]
        )
        if isDefault { change.defaultColumns = [1] }
        return change
    }

    private func writes(_ change: PluginRowChange) throws -> [String] {
        try driver.generateRowWrites(
            table: "", schema: nil, columns: ["Key", "Value", "TTL"], primaryKeyColumns: ["Key"],
            changes: [change], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        )?.map(\.statement) ?? []
    }

    @Test("The driver declares that it reads the default mark")
    func declaresTheMark() {
        #expect(driver.capabilities.contains(.columnDefaultMarks))
    }

    @Test("The text __DEFAULT__ is written as the value")
    func defaultLookingTextIsAValue() throws {
        let statements = try writes(valueEdit(to: "__DEFAULT__", isDefault: false))
        #expect(statements.contains { $0.contains("__DEFAULT__") })
    }

    @Test("A cell left to a default is refused, since Redis has none")
    func markedDefaultIsRefused() {
        #expect(throws: PluginRowWriteRefusal.self) {
            _ = try writes(valueEdit(to: "__DEFAULT__", isDefault: true))
        }
    }
}
