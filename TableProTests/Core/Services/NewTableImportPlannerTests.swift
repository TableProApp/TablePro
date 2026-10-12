//
//  NewTableImportPlannerTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// A failed row import into a new table leaves that table behind, so the retry finds the name
/// taken. Creating again fails on the name; importing into it as it stands writes the rows the
/// first attempt kept a second time.
struct NewTableImportPlannerTests {
    private let createSQL = "CREATE TABLE people (name TEXT)"
    private let connectionId = UUID()

    private var shop: DatabaseScope {
        DatabaseScope(connectionId: connectionId, database: "shop", schema: nil)
    }

    private var archive: DatabaseScope {
        DatabaseScope(connectionId: connectionId, database: "archive", schema: nil)
    }

    private func planner(creating tables: [TableScope: String]) -> NewTableImportPlanner {
        var planner = NewTableImportPlanner()
        for (table, sql) in tables {
            planner.recordCreated(table, createTableSQL: sql)
        }
        return planner
    }

    @Test("A table this sheet has not created is created")
    func firstAttemptCreates() {
        #expect(
            NewTableImportPlanner().plan(forTable: TableScope(table: "people", in: shop), createTableSQL: createSQL)
                == .create
        )
    }

    /// The retry the fix exists for: same name, same columns, so the table is ours and clearing it
    /// can lose nothing but the failed attempt's own rows.
    @Test("A retry with the same columns reuses the table after clearing it")
    func retryReusesAfterClearing() {
        let people = TableScope(table: "people", in: shop)
        #expect(
            planner(creating: [people: createSQL]).plan(forTable: people, createTableSQL: createSQL)
                == .reuseAfterClearing
        )
    }

    /// Editing the column list between attempts means the table we made is not the table being
    /// asked for. Importing anyway would insert against the old shape and fail on the missing
    /// columns, so the name is reported instead.
    @Test("A retry after editing the columns refuses the name")
    func retryAfterEditingColumnsRefusesTheName() {
        let people = TableScope(table: "people", in: shop)
        #expect(
            planner(creating: [people: createSQL]).plan(
                forTable: people,
                createTableSQL: "CREATE TABLE people (name TEXT, email TEXT)"
            ) == .nameTakenWithDifferentColumns
        )
    }

    /// Renaming away and back is the case a single remembered name gets wrong: `t1` is still ours.
    @Test("A name created earlier is still recognised after other names were used")
    func earlierNameIsStillRecognised() {
        let first = TableScope(table: "t1", in: shop)
        let created = planner(creating: [
            first: "CREATE TABLE t1 (a TEXT)",
            TableScope(table: "t2", in: shop): "CREATE TABLE t2 (a TEXT)"
        ])
        #expect(created.plan(forTable: first, createTableSQL: "CREATE TABLE t1 (a TEXT)") == .reuseAfterClearing)
    }

    @Test("A name this sheet never created is created even when others were")
    func unseenNameIsCreated() {
        let created = planner(creating: [TableScope(table: "t1", in: shop): "CREATE TABLE t1 (a TEXT)"])
        #expect(
            created.plan(forTable: TableScope(table: "t3", in: shop), createTableSQL: "CREATE TABLE t3 (a TEXT)")
                == .create
        )
    }

    /// The table a failed import made in `shop` does not make `archive.people` the sheet's own. Keyed
    /// by name alone, the retry planned `reuseAfterClearing` for it and ran `DELETE FROM` on a table
    /// the user owns.
    @Test("A table created in one database does not make a same-named table in another ours")
    func sameNameInAnotherDatabaseIsNotOurs() {
        let created = planner(creating: [TableScope(table: "people", in: shop): createSQL])
        let archived = TableScope(table: "people", in: archive)

        #expect(created.plan(forTable: archived, createTableSQL: createSQL) == .create)
        #expect(!created.created(archived))
        #expect(created.created(TableScope(table: "people", in: shop)))
    }

    @Test("A table created in one schema does not make a same-named table in another ours")
    func sameNameInAnotherSchemaIsNotOurs() {
        let publicSchema = DatabaseScope(connectionId: connectionId, database: "shop", schema: "public")
        let staging = DatabaseScope(connectionId: connectionId, database: "shop", schema: "staging")
        let created = planner(creating: [TableScope(table: "people", in: publicSchema): createSQL])

        #expect(created.plan(forTable: TableScope(table: "people", in: staging), createTableSQL: createSQL) == .create)
    }

    @Test("Only the names created in the asked scope are listed")
    func createdNamesAreListedPerScope() {
        let created = planner(creating: [
            TableScope(table: "people", in: shop): createSQL,
            TableScope(table: "orders", in: shop): "CREATE TABLE orders (id INTEGER)",
            TableScope(table: "invoices", in: archive): "CREATE TABLE invoices (id INTEGER)"
        ])

        #expect(Set(created.createdTableNames(in: shop)) == ["people", "orders"])
        #expect(created.createdTableNames(in: archive) == ["invoices"])
        #expect(created.createdTableNames(in: DatabaseScope(connectionId: UUID(), database: "shop", schema: nil)).isEmpty)
    }
}
