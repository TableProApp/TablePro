//
//  DatabaseTreeSelectionTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

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
}

struct DatabaseTreeTemporarySelectionTests {
    @Test("A temporary row opens its table but hands the Table menu nothing to act on")
    func temporaryRowOpensButIsNotCommandable() {
        let table = TableInfo(name: "scratch", type: .table, rowCount: nil, schema: "pg_temp_3")
        let ref = DatabaseTreeTableRef(database: "app", schema: nil, table: table)
        let node = DatabaseTreeNode(id: DatabaseTreeNode.temporaryTableId(ref), kind: .temporaryTable(ref))

        #expect(DatabaseTreeSelection.isSelectable(node.kind))
        #expect(!DatabaseTreeSelection.isSelectable(.temporarySection))
        #expect(DatabaseTreeSelection.tableRef(of: node) == ref)
        #expect(DatabaseTreeSelection.openableRefs(of: [node]) == [ref])
        #expect(DatabaseTreeSelection.tableRefs(of: [node]).isEmpty)
    }
}

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

struct DatabaseTreeObjectsTargetTests {
    private func target(
        _ kinds: [DatabaseTreeNode.Kind],
        showsObjects: Bool = true,
        databaseHoldsSchemas: Bool = false
    ) -> DatabaseTreeObjectGroup? {
        DatabaseTreeSelection.selectionObjectsTarget(
            selectedNodes: kinds.map { DatabaseTreeNode(id: UUID().uuidString, kind: $0) },
            showsObjectsOnSelection: showsObjects,
            databaseHoldsSchemas: databaseHoldsSchemas,
            hierarchicalDatabase: "warehouse"
        )
    }

    @Test("With the setting off, selecting a database row lists nothing")
    func settingOffListsNothing() {
        #expect(target([.database(DatabaseMetadata.minimal(name: "shop"))], showsObjects: false) == nil)
    }

    @Test("A database, schema or group row lists its own container's objects")
    func containerRowsNameTheirContainer() {
        let group = DatabaseTreeObjectGroup(database: "shop", schema: "sales", kind: .function)

        #expect(target([.database(DatabaseMetadata.minimal(name: "shop"))])
            == DatabaseTreeObjectGroup(database: "shop", schema: nil, kind: .table))
        #expect(target([.schema(database: "archive", schema: "sales")])
            == DatabaseTreeObjectGroup(database: "archive", schema: "sales", kind: .table))
        #expect(target([.hierarchicalSchemaSection(schema: "SALES")])
            == DatabaseTreeObjectGroup(database: "warehouse", schema: "SALES", kind: .table))
        #expect(target([.containerObjectKindSection(group)]) == group)
    }

    @Test("A database row that holds schemas lists nothing itself")
    func databaseOfSchemasListsNothing() {
        #expect(target([.database(DatabaseMetadata.minimal(name: "shop"))], databaseHoldsSchemas: true) == nil)
    }

    @Test("Objects, section headers and a selection of two rows list nothing")
    func otherRowsListNothing() {
        let table = DatabaseTreeTableRef(
            database: "shop", schema: nil, table: TableInfo(name: "orders", type: .table, rowCount: nil)
        )

        #expect(target([.table(table)]) == nil)
        #expect(target([.objectKindSection(.view)]) == nil)
        #expect(target([.recentSection]) == nil)
        #expect(target([.schema(database: "shop", schema: "a"), .schema(database: "shop", schema: "b")]) == nil)
    }
}
