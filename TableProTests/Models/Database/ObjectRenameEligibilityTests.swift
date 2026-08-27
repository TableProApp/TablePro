//
//  ObjectRenameEligibilityTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Object rename eligibility")
struct ObjectRenameEligibilityTests {
    private func context(
        activeDatabase: String? = "app",
        activeSchema: String? = "public",
        table: Bool = true,
        view: Bool = true,
        database: Bool = true,
        schema: Bool = true,
        isReadOnly: Bool = false
    ) -> ObjectRenameEligibility.Context {
        ObjectRenameEligibility.Context(
            activeDatabase: activeDatabase,
            activeSchema: activeSchema,
            supportsRenameTable: table,
            supportsRenameView: view,
            supportsRenameDatabase: database,
            supportsRenameSchema: schema,
            isReadOnly: isReadOnly
        )
    }

    private func table(_ name: String, type: TableInfo.TableType = .table) -> TableInfo {
        TableInfo(name: name, type: type, rowCount: nil, schema: "public")
    }

    // MARK: - Tables

    @Test("A table on an engine that can rename one offers it")
    func tableOffersRename() {
        #expect(ObjectRenameEligibility.canRename(table: table("orders"), context: context()))
    }

    @Test("An engine with no table rename never offers it")
    func engineWithoutRenameNeverOffers() {
        #expect(!ObjectRenameEligibility.canRename(table: table("orders"), context: context(table: false)))
    }

    @Test("Read-only safe mode hides rename with the rest of the writes")
    func readOnlyHidesRename() {
        #expect(!ObjectRenameEligibility.canRename(table: table("orders"), context: context(isReadOnly: true)))
    }

    /// A system table belongs to the engine, and renaming one breaks the catalogue it is part of.
    @Test("A system table is never renameable")
    func systemTableIsNotRenameable() {
        #expect(!ObjectRenameEligibility.canRename(table: table("pg_stats", type: .systemTable), context: context()))
    }

    @Test("A view is renameable where the engine renames one")
    func viewIsRenameable() {
        #expect(ObjectRenameEligibility.canRename(table: table("active_users", type: .view), context: context()))
    }

    /// SQLite's one rename statement refuses a view, and the engines built on it inherit that.
    /// Offering the item there guarantees a failure alert for something the menu promised.
    @Test("An engine that renames tables but not views omits it on a view")
    func viewIsNotRenameableWhereTheEngineRefusesOne() {
        #expect(!ObjectRenameEligibility.canRename(
            table: table("active_users", type: .view), context: context(view: false)
        ))
        #expect(ObjectRenameEligibility.canRename(table: table("orders"), context: context(view: false)))
    }

    // MARK: - Containers

    @Test("A database the connection is not on is renameable")
    func inactiveDatabaseIsRenameable() {
        let target = DatabaseContainerRef.database("archive", isSystem: false)
        #expect(ObjectRenameEligibility.renameable([target], context: context()) == target)
    }

    /// Several engines refuse outright, PostgreSQL among them, and the ones that allow it leave
    /// the session pointing at a name that has gone. Drop already asks the user to switch away.
    @Test("The database the connection is on is never renameable")
    func activeDatabaseIsNotRenameable() {
        let target = DatabaseContainerRef.database("app", isSystem: false)
        #expect(ObjectRenameEligibility.renameable([target], context: context()) == nil)
    }

    @Test("A system database is never renameable")
    func systemDatabaseIsNotRenameable() {
        let target = DatabaseContainerRef.database("mysql", isSystem: true)
        #expect(ObjectRenameEligibility.renameable([target], context: context()) == nil)
    }

    @Test("An engine with no database rename never offers it")
    func engineWithoutDatabaseRenameNeverOffers() {
        let target = DatabaseContainerRef.database("archive", isSystem: false)
        #expect(ObjectRenameEligibility.renameable([target], context: context(database: false)) == nil)
    }

    @Test("A schema outside the active database is renameable")
    func schemaInAnotherDatabaseIsRenameable() {
        let target = DatabaseContainerRef.schema(database: "archive", schema: "public", isSystem: false)
        #expect(ObjectRenameEligibility.renameable([target], context: context()) == target)
    }

    @Test("The schema the connection is on is never renameable")
    func activeSchemaIsNotRenameable() {
        let target = DatabaseContainerRef.schema(database: "app", schema: "public", isSystem: false)
        #expect(ObjectRenameEligibility.renameable([target], context: context()) == nil)
    }

    /// A rename names one new name, so a multi-row selection has nothing to apply. Offering the
    /// item over one would silently act on a row the user did not mean.
    @Test("A selection of several containers offers no rename")
    func multipleContainersOfferNoRename() {
        let targets = [
            DatabaseContainerRef.database("archive", isSystem: false),
            DatabaseContainerRef.database("staging", isSystem: false),
        ]
        #expect(ObjectRenameEligibility.renameable(targets, context: context()) == nil)
    }

    @Test("Read-only safe mode hides container rename too")
    func readOnlyHidesContainerRename() {
        let target = DatabaseContainerRef.database("archive", isSystem: false)
        #expect(ObjectRenameEligibility.renameable([target], context: context(isReadOnly: true)) == nil)
    }
}
