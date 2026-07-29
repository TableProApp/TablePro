//
//  DatabaseTreeSelectionTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Database Tree Selection Identity")
struct DatabaseTreeSelectionTests {
    private func makeTable(_ name: String, schema: String? = nil) -> TableInfo {
        TableInfo(name: name, type: .table, rowCount: nil, schema: schema)
    }

    @Test("Same table name in different databases produces distinct refs")
    func sameNameDifferentDatabaseIsDistinct() {
        let table = makeTable("users")
        let inDb1 = DatabaseTreeTableRef(database: "db1", schema: nil, table: table)
        let inDb2 = DatabaseTreeTableRef(database: "db2", schema: nil, table: table)

        #expect(inDb1 != inDb2)
        #expect(inDb1.id != inDb2.id)
        #expect(Set([inDb1, inDb2]).count == 2)
    }

    @Test("Same public schema in different databases produces distinct refs")
    func samePublicSchemaDifferentDatabaseIsDistinct() {
        let table = makeTable("users", schema: "public")
        let inDb1 = DatabaseTreeTableRef(database: "db1", schema: "public", table: table)
        let inDb2 = DatabaseTreeTableRef(database: "db2", schema: "public", table: table)

        #expect(inDb1 != inDb2)
        #expect(Set([inDb1, inDb2]).count == 2)
    }

    @Test("Identical database, schema, and table are equal")
    func identicalRefsAreEqual() {
        let lhs = DatabaseTreeTableRef(database: "db1", schema: "public", table: makeTable("users", schema: "public"))
        let rhs = DatabaseTreeTableRef(database: "db1", schema: "public", table: makeTable("users", schema: "public"))

        #expect(lhs == rhs)
        #expect(lhs.hashValue == rhs.hashValue)
    }
}

@Suite("Selection Delta")
struct SelectionDeltaTests {
    @Test("Single addition is detected")
    func singleAdditionDetected() {
        let old: Set<Int> = [1, 2]
        let new: Set<Int> = [1, 2, 3]
        #expect(SelectionDelta.singleAddition(old: old, new: new) == 3)
    }

    @Test("No addition returns nil")
    func noAdditionReturnsNil() {
        let set: Set<Int> = [1, 2]
        #expect(SelectionDelta.singleAddition(old: set, new: set) == nil)
    }

    @Test("Removal returns nil")
    func removalReturnsNil() {
        let old: Set<Int> = [1, 2, 3]
        let new: Set<Int> = [1, 2]
        #expect(SelectionDelta.singleAddition(old: old, new: new) == nil)
    }

    @Test("Multiple additions return nil")
    func multipleAdditionsReturnNil() {
        let old: Set<Int> = [1]
        let new: Set<Int> = [1, 2, 3]
        #expect(SelectionDelta.singleAddition(old: old, new: new) == nil)
    }
}
