//
//  DatabaseTreeFilterMemoTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

// A filter pass, a listing scan and a row's id are worked out once per input, not once per reload.
@MainActor
struct DatabaseTreeFilterMemoTests {
    private func table(_ name: String, _ schema: String? = nil, comment: String? = nil) -> TableInfo {
        TableInfo(name: name, type: .table, rowCount: nil, schema: schema, comment: comment)
    }

    private func source(_ tables: [TableInfo], searchText: String = "") -> DatabaseTreeBucketSource {
        DatabaseTreeBucketSource(
            tables: tables, routines: [], triggers: [], userTypes: [], searchText: searchText, database: "shop"
        )
    }

    private func tableBucket(_ buckets: DatabaseTreeObjectBuckets) -> SameRows<TableInfo> {
        SameRows(rows: buckets.tables[.table] ?? [])
    }

    // MARK: - Rows

    @Test("Rows compare by storage, since TableInfo equality leaves out the comment a row draws")
    func sameRowsComparesStorage() {
        let rows = [table("orders", comment: "old")]
        let edited = [table("orders", comment: "new")]
        #expect(rows == edited)
        #expect(SameRows(rows: rows) != SameRows(rows: edited))
        let held = SameRows(rows: rows)
        #expect(held == SameRows(rows: rows))
        #expect(SameRows<TableInfo>(rows: []) == SameRows(rows: []))
    }

    // MARK: - Container filter

    @Test("A container's filter pass is reused until its rows or its search move")
    func bucketMemoReusesUnchangedPass() {
        var memo = DatabaseTreeBucketMemo<String>()
        let tables = [table("orders"), table("order_lines"), table("users")]

        let first = memo.buckets(for: "shop", source: source(tables))
        let again = memo.buckets(for: "shop", source: source(tables))
        let reread = memo.buckets(for: "shop", source: source(tables.map { $0 }))
        let searched = memo.buckets(for: "shop", source: source(tables, searchText: "order"))

        #expect(tableBucket(first) == tableBucket(again))
        #expect(tableBucket(reread) != tableBucket(first))
        #expect(searched.tables[.table]?.map { $0.name } == ["orders", "order_lines"])
    }

    @Test("A container nobody asked for since the last drop lets go of its pass")
    func bucketMemoDropsUnaskedContainers() {
        var memo = DatabaseTreeBucketMemo<String>()
        let attendance = source([table("timesheet")])
        let payroll = source([table("salary")])

        _ = memo.buckets(for: "attendance", source: attendance)
        let payrollFirst = memo.buckets(for: "payroll", source: payroll)
        memo.dropUnused()
        let attendanceKept = memo.buckets(for: "attendance", source: attendance)
        let payrollKept = memo.buckets(for: "payroll", source: payroll)
        memo.dropUnused()
        _ = memo.buckets(for: "attendance", source: attendance)
        memo.dropUnused()
        let payrollAfterDrop = memo.buckets(for: "payroll", source: payroll)

        #expect(tableBucket(payrollKept) == tableBucket(payrollFirst))
        #expect(tableBucket(payrollAfterDrop) != tableBucket(payrollFirst))
        #expect(attendanceKept.tables[.table]?.map { $0.name } == ["timesheet"])
    }

    // MARK: - Listing scan

    @Test("A listing scan is shared until the listing, the search or the covered schemas move")
    func listingMemoSharedUntilInputsMove() {
        var memo = DatabaseTreeFilter.SchemaListingMatchesMemo()
        let listing = CatalogTableListing.Result(
            tables: [table("timesheet", "attendance"), table("timesheet", "payroll"), table("orders", "sales")],
            unlistedSchemas: []
        )

        let first = memo.matches(listing: listing, database: "shop", searchText: "timesheet", covered: nil)
        let again = memo.matches(listing: listing, database: "shop", searchText: "timesheet", covered: nil)
        let narrowed = memo.matches(listing: listing, database: "shop", searchText: "timesheet", covered: ["payroll"])
        let reread = memo.matches(
            listing: CatalogTableListing.Result(tables: listing.tables.map { $0 }, unlistedSchemas: []),
            database: "shop", searchText: "timesheet", covered: ["payroll"]
        )
        let other = memo.matches(listing: listing, database: "shop", searchText: "orders", covered: nil)

        #expect(first.matched == ["attendance", "payroll"])
        #expect(SameRows(rows: first.rowsBySchema["attendance"] ?? []) == SameRows(rows: again.rowsBySchema["attendance"] ?? []))
        #expect(narrowed.covered == ["payroll"])
        #expect(SameRows(rows: reread.rowsBySchema["payroll"] ?? []) != SameRows(rows: narrowed.rowsBySchema["payroll"] ?? []))
        #expect(other.matched == ["sales"])
    }

    @Test("A new search over the same listing keeps its grouping, and a new listing groups again")
    func listingGroupingOutlivesTheSearch() {
        var memo = DatabaseTreeFilter.SchemaListingMatchesMemo()
        let listing = CatalogTableListing.Result(
            tables: [table("timesheet", "attendance"), table("orders", "sales"), table("refunds", "sales")],
            unlistedSchemas: []
        )

        let first = memo.matches(listing: listing, database: "shop", searchText: "time", covered: nil)
        let refined = memo.matches(listing: listing, database: "shop", searchText: "ref", covered: nil)
        let reread = memo.matches(
            listing: CatalogTableListing.Result(tables: listing.tables.map { $0 }, unlistedSchemas: []),
            database: "shop", searchText: "ref", covered: nil
        )

        #expect(first.matched == ["attendance"])
        #expect(refined.matched == ["sales"])
        #expect(refined.listed == ["attendance", "sales"])
        #expect(SameRows(rows: refined.rowsBySchema["sales"] ?? []) == SameRows(rows: first.rowsBySchema["sales"] ?? []))
        #expect(SameRows(rows: reread.rowsBySchema["sales"] ?? []) != SameRows(rows: refined.rowsBySchema["sales"] ?? []))
        #expect(reread.matched == ["sales"])
    }

    // MARK: - Outline

    private struct Fixture {
        let connection: DatabaseConnection
        let coordinator: DatabaseTreeOutlineCoordinator
        let viewModel: SidebarViewModel
        let scrollView: NSScrollView
    }

    // A PGlite session, so every read stays on the injected driver.
    private func makeFixture(searchText: String) async throws -> Fixture {
        let connection = TestFixtures.makeConnection(database: "shop", type: .pglite)
        let driver = MockDatabaseDriver(connection: connection)
        let rows: [String: [TableInfo]] = [
            "public": [table("users", "public")],
            "attendance": [table("timesheet", "attendance"), table("shift", "attendance")],
            "payroll": [table("timesheet", "payroll"), table("salary", "payroll")]
        ]
        driver.databasesToReturn = ["shop"]
        driver.schemasToReturn = ["public", "attendance", "payroll"]
        driver.schemaTablesToReturn = rows
        driver.allSchemaTablesToReturn = ["public", "attendance", "payroll"].flatMap { rows[$0] ?? [] }
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        session.browseSchema = "public"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        let service = DatabaseTreeMetadataService.shared
        await service.loadSchemas(connectionId: connection.id, database: "shop")
        await service.loadAllSchemaTables(connectionId: connection.id, database: "shop")
        await service.loadObjects(connectionId: connection.id, database: "shop", schema: "attendance")

        let scrollView = SidebarOutlineScaffold.makeScrollView(
            outlineView: NSOutlineView(),
            configuration: SidebarOutlineScaffold.Configuration(
                columnIdentifier: "FilterMemoColumn",
                allowsMultipleSelection: true,
                rowSizePreference: .medium
            )
        )
        scrollView.frame = NSRect(x: 0, y: 0, width: 280, height: 800)
        let outlineView = try #require(scrollView.documentView as? NSOutlineView)
        let sidebarState = SharedSidebarState.forConnection(connection.id)
        sidebarState.sidebarLayout = .flat
        let viewModel = SidebarViewModel(
            selectedTables: .constant([]),
            pendingTruncates: .constant([]),
            pendingDeletes: .constant([]),
            tableOperationOptions: .constant([:]),
            databaseType: .pglite,
            connectionId: connection.id
        )
        let coordinator = DatabaseTreeOutlineCoordinator()
        coordinator.connectionId = connection.id
        coordinator.databaseType = .pglite
        coordinator.sidebarState = sidebarState
        coordinator.windowState = WindowSidebarState()
        coordinator.viewModel = viewModel
        coordinator.activeDatabase = "shop"
        coordinator.activeSchema = "public"
        coordinator.showRecentTables = false
        coordinator.searchText = searchText
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        coordinator.attach(outlineView: outlineView)
        coordinator.refresh()
        return Fixture(connection: connection, coordinator: coordinator, viewModel: viewModel, scrollView: scrollView)
    }

    private func tearDown(_ fixture: Fixture) async {
        await DatabaseTreeMetadataService.shared.handleDisconnect(connectionId: fixture.connection.id)
        ExternalSchemaTracker.shared.reset(connectionId: fixture.connection.id)
        DatabaseManager.shared.removeSession(for: fixture.connection.id)
        SharedSidebarState.removeConnection(fixture.connection.id)
        _ = fixture.scrollView
        _ = fixture.viewModel
    }

    @Test("A container's filtered rows survive a reload that changed nothing it reads")
    func containerPassSurvivesReload() async throws {
        let fixture = try await makeFixture(searchText: "")
        let before = fixture.coordinator.objectBuckets(database: "shop", schema: "attendance")

        fixture.coordinator.refresh()
        let after = fixture.coordinator.objectBuckets(database: "shop", schema: "attendance")

        #expect(before.tables[.table]?.map { $0.name } == ["timesheet", "shift"])
        #expect(tableBucket(before) == tableBucket(after))
        await tearDown(fixture)
    }

    @Test("The outline and the view model judge schemas against one listing scan, kept across reloads")
    func listingScanIsShared() async throws {
        let fixture = try await makeFixture(searchText: "timesheet")
        let key = DatabaseTreeContainerKey(database: "shop", schema: nil, searchText: "timesheet")
        let drawn = try #require(fixture.coordinator.listingMatchesCache[key])
        let shared = try #require(fixture.viewModel.schemaListingMatches(database: "shop", searchText: "timesheet"))

        fixture.coordinator.refresh()
        let redrawn = try #require(fixture.coordinator.listingMatchesCache[key])

        #expect(drawn.matched == ["attendance", "payroll"])
        #expect(SameRows(rows: drawn.rowsBySchema["payroll"] ?? []) == SameRows(rows: shared.rowsBySchema["payroll"] ?? []))
        #expect(SameRows(rows: redrawn.rowsBySchema["payroll"] ?? []) == SameRows(rows: drawn.rowsBySchema["payroll"] ?? []))
        await tearDown(fixture)
    }

    // MARK: - Row ids

    @Test("A table row's id is the escaped spelling whether or not a part needs escaping")
    func tableIdMatchesEscapedSpelling() {
        let names = ["orders", "a.b", "pipe|name", "back\\slash", "café", ""]
        let schemas: [String?] = [nil, "", "public", "s.t", "x|y", "z\\w"]
        let databases: [String?] = [nil, "", "shop", "a|b", "c\\d", "e.f"]
        for name in names {
            for tableSchema in schemas {
                for type in TableInfo.TableType.allCases {
                    for isTemporary in [false, true] {
                        let table = TableInfo(
                            name: name, type: type, rowCount: nil, schema: tableSchema, isTemporary: isTemporary
                        )
                        for database in databases {
                            for rowSchema in schemas {
                                let ref = DatabaseTreeTableRef(database: database, schema: rowSchema, table: table)
                                #expect(DatabaseTreeNode.tableId(ref) == "table\u{1}\(ref.id)")
                            }
                        }
                    }
                }
            }
        }
    }
}
