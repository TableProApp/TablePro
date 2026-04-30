//
//  RowTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("RowID")
struct RowIDTests {
    @Test("Two inserted RowIDs have different UUIDs")
    func insertedFactoriesProduceDistinctUUIDs() {
        let first = RowID.inserted(UUID())
        let second = RowID.inserted(UUID())
        #expect(first != second)
    }

    @Test("Existing RowIDs with the same ordinal compare equal")
    func existingFactoriesEqualForSameOrdinal() {
        let lhs = RowID.existing(5)
        let rhs = RowID.existing(5)
        let other = RowID.existing(6)
        #expect(lhs == rhs)
        #expect(lhs != other)
    }

    @Test("isInserted is true for inserted, false for existing")
    func isInsertedReportsCase() {
        #expect(RowID.inserted(UUID()).isInserted == true)
        #expect(RowID.existing(0).isInserted == false)
    }
}

@Suite("Row")
struct RowTests {
    @Test("Subscript returns the cell at a valid column")
    func subscriptReadsValidColumn() {
        let row = Row(id: .existing(0), values: ["a", "b", nil])
        #expect(row[0] == "a")
        #expect(row[1] == "b")
        #expect(row[2] == nil)
    }

    @Test("Subscript get returns nil for out-of-bounds column")
    func subscriptOutOfBoundsReturnsNil() {
        let row = Row(id: .existing(0), values: ["a"])
        #expect(row[5] == nil)
        #expect(row[-1] == nil)
    }

    @Test("Subscript set on a valid column updates the value")
    func subscriptWriteValidColumn() {
        var row = Row(id: .existing(0), values: ["a", "b"])
        row[1] = "z"
        #expect(row.values == ["a", "z"])
    }

    @Test("Subscript set on an out-of-bounds column is a no-op")
    func subscriptWriteOutOfBoundsIsNoOp() {
        var row = Row(id: .existing(0), values: ["a"])
        row[5] = "x"
        row[-1] = "y"
        #expect(row.values == ["a"])
    }

    @Test("Equality requires both id and values to match")
    func equalityRequiresIDAndValues() {
        let lhs = Row(id: .existing(1), values: ["a", "b"])
        let rhs = Row(id: .existing(1), values: ["a", "b"])
        let differentValues = Row(id: .existing(1), values: ["a", "c"])
        let differentID = Row(id: .existing(2), values: ["a", "b"])
        #expect(lhs == rhs)
        #expect(lhs != differentValues)
        #expect(lhs != differentID)
    }

    @Test("Rows with same values but different inserted UUIDs are not equal")
    func equalitySensitiveToInsertedUUID() {
        let lhs = Row(id: .inserted(UUID()), values: ["a"])
        let rhs = Row(id: .inserted(UUID()), values: ["a"])
        #expect(lhs != rhs)
    }
}
