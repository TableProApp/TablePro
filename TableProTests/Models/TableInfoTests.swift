//
//  TableInfoTests.swift
//  TableProTests
//
//  Tests for TableInfo struct identity, equality, and hashing behavior.
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("TableInfo")
struct TableInfoTests {

    // MARK: - Identifiable

    @Test("id returns name_TABLE for a table")
    func testIdForTable() {
        let info = TableInfo(name: "users", type: .table, rowCount: 100)
        #expect(info.id == "users_TABLE")
    }

    @Test("id returns name_VIEW for a view")
    func testIdForView() {
        let info = TableInfo(name: "my_view", type: .view, rowCount: nil)
        #expect(info.id == "my_view_VIEW")
    }

    @Test("id returns name_SYSTEM TABLE for a system table")
    func testIdForSystemTable() {
        let info = TableInfo(name: "sys", type: .systemTable, rowCount: nil)
        #expect(info.id == "sys_SYSTEM TABLE")
    }

    @Test("Same name and type produce same id")
    func testSameNameTypeSameId() {
        let a = TableInfo(name: "orders", type: .table, rowCount: 10)
        let b = TableInfo(name: "orders", type: .table, rowCount: 999)
        #expect(a.id == b.id)
    }

    @Test("Different types produce different id")
    func testDifferentTypesDifferentId() {
        let table = TableInfo(name: "items", type: .table, rowCount: nil)
        let view = TableInfo(name: "items", type: .view, rowCount: nil)
        #expect(table.id != view.id)
    }

    // MARK: - Equatable

    @Test("Same name and type are equal even with different rowCount")
    func testEqualSameNameType() {
        let a = TableInfo(name: "users", type: .table, rowCount: 100)
        let b = TableInfo(name: "users", type: .table, rowCount: 0)
        #expect(a == b)
    }

    @Test("Different names are not equal")
    func testNotEqualDifferentNames() {
        let a = TableInfo(name: "users", type: .table, rowCount: nil)
        let b = TableInfo(name: "orders", type: .table, rowCount: nil)
        #expect(a != b)
    }

    @Test("Different types are not equal with same name")
    func testNotEqualDifferentTypes() {
        let table = TableInfo(name: "items", type: .table, rowCount: nil)
        let view = TableInfo(name: "items", type: .view, rowCount: nil)
        #expect(table != view)
    }

    @Test("Separately created instances for same table are equal")
    func testSeparateInstancesEqual() {
        let a = TableInfo(name: "products", type: .table, rowCount: 50)
        let b = TableInfo(name: "products", type: .table, rowCount: 50)
        #expect(a == b)
    }

    // MARK: - Hashable

    @Test("Same name and type produce same hash")
    func testSameHash() {
        let a = TableInfo(name: "users", type: .table, rowCount: 10)
        let b = TableInfo(name: "users", type: .table, rowCount: 999)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("Can be stored in a Set and looked up")
    func testSetLookup() {
        let info = TableInfo(name: "users", type: .table, rowCount: 100)
        let set: Set<TableInfo> = [info]
        #expect(set.contains(info))
    }

    @Test("Set contains works across separate instances")
    func testSetContainsSeparateInstances() {
        let a = TableInfo(name: "users", type: .table, rowCount: 100)
        let set: Set<TableInfo> = [a]

        let b = TableInfo(name: "users", type: .table, rowCount: 200)
        #expect(set.contains(b))
    }

    @Test("Inserting duplicate does not increase set count")
    func testSetDeduplication() {
        let a = TableInfo(name: "orders", type: .view, rowCount: nil)
        let b = TableInfo(name: "orders", type: .view, rowCount: 42)
        var set: Set<TableInfo> = [a]
        set.insert(b)
        #expect(set.count == 1)
    }

    // MARK: - Set behavior (selection use case)

    @Test("Set correctly deduplicates by name and type")
    func testSetDeduplicatesByNameAndType() {
        let items: [TableInfo] = [
            TableInfo(name: "users", type: .table, rowCount: 10),
            TableInfo(name: "users", type: .table, rowCount: 20),
            TableInfo(name: "orders", type: .table, rowCount: 5),
        ]
        let set = Set(items)
        #expect(set.count == 2)
    }

    @Test("Set contains works for separately created instances")
    func testSetContainsForSeparateInstances() {
        let selected: Set<TableInfo> = [
            TableInfo(name: "users", type: .table, rowCount: nil),
            TableInfo(name: "orders", type: .view, rowCount: nil),
        ]

        let lookup = TableInfo(name: "users", type: .table, rowCount: 999)
        #expect(selected.contains(lookup))
    }

    @Test("Subtracting sets works correctly")
    func testSetSubtraction() {
        let all: Set<TableInfo> = [
            TableInfo(name: "users", type: .table, rowCount: nil),
            TableInfo(name: "orders", type: .table, rowCount: nil),
            TableInfo(name: "products", type: .view, rowCount: nil),
        ]
        let toRemove: Set<TableInfo> = [
            TableInfo(name: "orders", type: .table, rowCount: 42),
        ]

        let result = all.subtracting(toRemove)
        #expect(result.count == 2)
        #expect(!result.contains(TableInfo(name: "orders", type: .table, rowCount: nil)))
        #expect(result.contains(TableInfo(name: "users", type: .table, rowCount: nil)))
        #expect(result.contains(TableInfo(name: "products", type: .view, rowCount: nil)))
    }
}
