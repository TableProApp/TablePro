//
//  NewTableImportPlannerTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

/// A failed row import into a new table leaves that table behind, so the retry finds the name
/// taken. Creating again fails on the name; importing into it as it stands writes the rows the
/// first attempt kept a second time.
@Suite("New table import planning")
struct NewTableImportPlannerTests {
    private let createSQL = "CREATE TABLE people (name TEXT)"

    @Test("A table this sheet has not created is created")
    func firstAttemptCreates() {
        #expect(
            NewTableImportPlanner.plan(
                forTable: "people", createTableSQL: createSQL, alreadyCreated: [:]
            ) == .create
        )
    }

    /// The retry the fix exists for: same name, same columns, so the table is ours and clearing it
    /// can lose nothing but the failed attempt's own rows.
    @Test("A retry with the same columns reuses the table after clearing it")
    func retryReusesAfterClearing() {
        #expect(
            NewTableImportPlanner.plan(
                forTable: "people", createTableSQL: createSQL, alreadyCreated: ["people": createSQL]
            ) == .reuseAfterClearing
        )
    }

    /// Editing the column list between attempts means the table we made is not the table being
    /// asked for. Importing anyway would insert against the old shape and fail on the missing
    /// columns, so the name is reported instead.
    @Test("A retry after editing the columns refuses the name")
    func retryAfterEditingColumnsRefusesTheName() {
        #expect(
            NewTableImportPlanner.plan(
                forTable: "people",
                createTableSQL: "CREATE TABLE people (name TEXT, email TEXT)",
                alreadyCreated: ["people": createSQL]
            ) == .nameTakenWithDifferentColumns
        )
    }

    /// Renaming away and back is the case a single remembered name gets wrong: `t1` is still ours.
    @Test("A name created earlier is still recognised after other names were used")
    func earlierNameIsStillRecognised() {
        let created = [
            "t1": "CREATE TABLE t1 (a TEXT)",
            "t2": "CREATE TABLE t2 (a TEXT)",
        ]
        #expect(
            NewTableImportPlanner.plan(
                forTable: "t1", createTableSQL: "CREATE TABLE t1 (a TEXT)", alreadyCreated: created
            ) == .reuseAfterClearing
        )
    }

    @Test("A name this sheet never created is created even when others were")
    func unseenNameIsCreated() {
        #expect(
            NewTableImportPlanner.plan(
                forTable: "t3",
                createTableSQL: "CREATE TABLE t3 (a TEXT)",
                alreadyCreated: ["t1": "CREATE TABLE t1 (a TEXT)"]
            ) == .create
        )
    }
}
