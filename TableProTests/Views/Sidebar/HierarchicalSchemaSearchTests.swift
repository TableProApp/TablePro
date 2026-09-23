//
//  HierarchicalSchemaSearchTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

/// Oracle, Snowflake, BigQuery and the other engines grouped by hierarchical schema list every
/// schema of the database, and the sidebar filter judges each one without reading it.
@Suite("Hierarchical schema search")
struct HierarchicalSchemaSearchTests {
    private func table(_ name: String, _ schema: String) -> TableInfo {
        TableInfo(name: name, type: .table, rowCount: nil, schema: schema)
    }

    private func procedure(_ name: String, _ schema: String) -> RoutineInfo {
        RoutineInfo(name: name, kind: .procedure, schema: schema)
    }

    private func listing(
        _ tables: [TableInfo],
        unlisted: Set<String> = [],
        searchText: String
    ) -> DatabaseTreeFilter.SchemaListingMatches {
        DatabaseTreeFilter.SchemaListingMatches(
            listing: CatalogTableListing.Result(tables: tables, unlistedSchemas: unlisted),
            database: "",
            searchText: searchText
        )
    }

    private func content(
        tables: [TableInfo] = [],
        routines: [RoutineInfo] = [],
        settled: Bool = true,
        current: Bool,
        searchText: String
    ) -> DatabaseTreeFilter.LoadedSchemaContent {
        DatabaseTreeFilter.LoadedSchemaContent(
            buckets: DatabaseTreeFilter.objectBuckets(
                tables: tables,
                routines: routines,
                triggers: [],
                searchText: searchText
            ),
            isSettled: settled,
            isCurrent: current
        )
    }

    private func verdict(
        _ schema: String,
        searchText: String,
        content: DatabaseTreeFilter.LoadedSchemaContent? = nil,
        listing: DatabaseTreeFilter.SchemaListingMatches? = nil,
        coveredByListing: Bool = true
    ) -> DatabaseTreeFilter.SchemaSearchVerdict {
        DatabaseTreeFilter.hierarchicalSchemaSearchVerdict(
            schema: schema,
            database: nil,
            searchText: searchText,
            loadedContent: content,
            listingMatches: listing,
            listingCoversSchema: coveredByListing
        )
    }

    @Test("An unread schema whose tables the listing shows match nothing is hidden")
    func listedWithoutAMatchIsHidden() {
        let matches = listing([table("EMPLOYEES", "HR")], searchText: "invoice")
        #expect(verdict("HR", searchText: "invoice", listing: matches) == .noMatch)
    }

    @Test("An unread schema holding a matching table in the listing is a match")
    func listedWithAMatchIsAMatch() {
        let matches = listing([table("INVOICES", "BILLING")], searchText: "invoice")
        #expect(verdict("BILLING", searchText: "invoice", listing: matches) == .match)
    }

    @Test("An unread schema stays on screen, collapsed, until the listing arrives")
    func noListingYetIsUnknown() {
        #expect(verdict("HR", searchText: "invoice") == .unknown)
    }

    @Test("A schema the listing could not read stays on screen")
    func unlistedSchemaIsUnknown() {
        let matches = listing([table("INVOICES", "BILLING")], unlisted: ["HR"], searchText: "invoice")
        #expect(verdict("HR", searchText: "invoice", listing: matches) == .unknown)
    }

    @Test("An unread schema with no tables in the listing is hidden")
    func emptySchemaIsHidden() {
        let matches = listing([table("INVOICES", "BILLING")], searchText: "invoice")
        #expect(verdict("SCRATCH", searchText: "invoice", listing: matches) == .noMatch)
    }

    /// The listing holds tables alone, so a procedure is found only in a schema whose objects have
    /// been read. Reading every schema to find one is the load the listing replaced.
    @Test("A procedure in a schema nothing has read is not found")
    func procedureInAnUnreadSchemaIsNotFound() {
        let matches = listing([table("PAYROLL", "HR")], searchText: "raise_salary")
        #expect(verdict("HR", searchText: "raise_salary", listing: matches) == .noMatch)
    }

    @Test("A procedure in a schema that was read is found")
    func procedureInAReadSchemaIsFound() {
        let read = content(routines: [procedure("RAISE_SALARY", "HR")], current: true, searchText: "raise_salary")
        let matches = listing([table("PAYROLL", "HR")], searchText: "raise_salary")
        #expect(verdict("HR", searchText: "raise_salary", content: read, listing: matches) == .match)
    }

    @Test("A schema read since the last change answers for itself over the listing")
    func currentReadAnswersFirst() {
        let read = content(tables: [table("PAYROLL", "HR")], current: true, searchText: "invoice")
        let matches = listing([table("INVOICES", "HR")], searchText: "invoice")
        #expect(verdict("HR", searchText: "invoice", content: read, listing: matches) == .noMatch)
    }

    /// `INVOICES` was created after the last read of `BILLING`, and the listing was asked for again.
    @Test("A schema read before the last change yields to the listing for its tables")
    func staleReadYieldsToTheListing() {
        let read = content(tables: [table("PAYROLL", "BILLING")], current: false, searchText: "invoice")
        let matches = listing([table("PAYROLL", "BILLING"), table("INVOICES", "BILLING")], searchText: "invoice")
        #expect(verdict("BILLING", searchText: "invoice", content: read, listing: matches) == .match)
    }

    @Test("A schema read before the last change keeps its procedure match")
    func staleReadKeepsAProcedureMatch() {
        let read = content(routines: [procedure("CLOSE_INVOICE", "BILLING")], current: false, searchText: "invoice")
        let matches = listing([table("PAYROLL", "BILLING")], searchText: "invoice")
        #expect(verdict("BILLING", searchText: "invoice", content: read, listing: matches) == .match)
    }

    @Test("A schema read before the last change that nothing matches is hidden")
    func staleReadWithoutAMatchIsHidden() {
        let read = content(tables: [table("PAYROLL", "HR")], current: false, searchText: "invoice")
        #expect(verdict("HR", searchText: "invoice", content: read) == .noMatch)
        let matches = listing([table("PAYROLL", "HR")], searchText: "invoice")
        #expect(verdict("HR", searchText: "invoice", content: read, listing: matches) == .noMatch)
    }

    /// A kind whose fetch failed has not answered, and the object searched for may be the one it
    /// could not list.
    @Test("A schema whose procedures failed to load stays on screen when its tables do not match")
    func unsettledReadIsUnknown() {
        let read = content(tables: [table("PAYROLL", "HR")], settled: false, current: true, searchText: "invoice")
        let matches = listing([table("PAYROLL", "HR")], searchText: "invoice")
        #expect(verdict("HR", searchText: "invoice", content: read, listing: matches) == .unknown)
    }

    @Test("A system schema nothing has read is hidden")
    func unreadSystemSchemaIsHidden() {
        let matches = listing([table("INVOICES", "BILLING")], searchText: "invoice")
        #expect(verdict("SYS", searchText: "invoice", listing: matches, coveredByListing: false) == .noMatch)
    }

    @Test("A schema whose own name matches is a match with nothing read")
    func schemaNameMatch() {
        let matches = listing([table("PAYROLL", "HR")], searchText: "hr")
        #expect(verdict("HR", searchText: "hr", listing: matches) == .match)
    }

    @Test("A hierarchical search asks for the browsed database's listing, named or not")
    func hierarchicalSearchAsksForTheBrowsedDatabase() {
        let named = SidebarViewModel.databasesListedForSearch(
            grouping: .hierarchicalSchema, browsedDatabase: "SALES", databasesWithSchemaLists: ["OTHER"]
        )
        let unnamed = SidebarViewModel.databasesListedForSearch(
            grouping: .hierarchicalSchema, browsedDatabase: "", databasesWithSchemaLists: []
        )
        let disconnected = SidebarViewModel.databasesListedForSearch(
            grouping: .hierarchicalSchema, browsedDatabase: nil, databasesWithSchemaLists: []
        )
        #expect(named == ["SALES"])
        #expect(unnamed == [""])
        #expect(disconnected.isEmpty)
    }

    @Test("A schema-grouped search asks for the browsed database and every one the tree shows")
    func schemaGroupedSearchAsksForShownDatabases() {
        let requested = SidebarViewModel.databasesListedForSearch(
            grouping: .bySchema, browsedDatabase: "shop", databasesWithSchemaLists: ["blog"]
        )
        let unnamed = SidebarViewModel.databasesListedForSearch(
            grouping: .bySchema, browsedDatabase: "", databasesWithSchemaLists: ["blog"]
        )
        let byDatabase = SidebarViewModel.databasesListedForSearch(
            grouping: .byDatabase, browsedDatabase: "shop", databasesWithSchemaLists: ["blog"]
        )
        #expect(requested == ["shop", "blog"])
        #expect(unnamed == ["blog"])
        #expect(byDatabase.isEmpty)
    }
}

/// The measured case behind the change: a search over 200 schemas, three of which hold a match.
/// Before it, the first keystroke loaded every schema, two queries each here and three on Oracle.
@Suite("Hierarchical schema search cost")
@MainActor
struct HierarchicalSchemaSearchCostTests {
    private let connectionId = UUID()
    private let searchText = "invoice"

    private var connection: DatabaseConnection {
        TestFixtures.makeConnection(id: connectionId, type: .oracle)
    }

    private var scope: DatabaseScope {
        DatabaseScope(connectionId: connectionId, database: "ORCL", schema: "S0")
    }

    private func catalog(listsInOneCall: Bool) -> (schemas: [String], driver: CatalogReadCountingDriver) {
        let schemas = (0..<200).map { "S\($0)" }
        let driver = CatalogReadCountingDriver(connection: connection)
        driver.schemasToReturn = schemas
        var all: [TableInfo] = []
        for (index, schema) in schemas.enumerated() {
            var tables = [TableInfo(name: "\(schema)_ORDERS", type: .table, rowCount: nil, schema: schema)]
            if index % 70 == 1 {
                tables.append(TableInfo(name: "\(schema)_INVOICES", type: .table, rowCount: nil, schema: schema))
            }
            driver.tablesBySchema[schema] = tables
            all += tables
        }
        driver.allSchemaTables = listsInOneCall ? all : nil
        return (schemas, driver)
    }

    private func search(_ schemas: [String], driver: CatalogReadCountingDriver) async throws -> [String] {
        let listing = try await CatalogTableListing.tables(
            in: scope,
            excludingSchemas: [],
            metadata: SingleDriverMetadataProvider(driver: driver, scope: scope)
        )
        let listingMatches = DatabaseTreeFilter.SchemaListingMatches(
            listing: listing,
            database: scope.database,
            searchText: searchText
        )
        let matched = schemas.filter { schema in
            DatabaseTreeFilter.hierarchicalSchemaSearchVerdict(
                schema: schema,
                database: scope.database,
                searchText: searchText,
                loadedContent: nil,
                listingMatches: listingMatches,
                listingCoversSchema: true
            ) == .match
        }
        let service = SchemaService()
        for schema in matched {
            await service.loadSchemaObjects(schema: schema, in: scope, driver: driver)
        }
        return matched
    }

    @Test("An engine that lists every table in one call costs one query plus the matches")
    func singleCallListing() async throws {
        let (schemas, driver) = catalog(listsInOneCall: true)

        let matched = try await search(schemas, driver: driver)

        #expect(matched == ["S1", "S71", "S141"])
        #expect(driver.reads.filter { $0 == "allSchemaTables" }.count == 1)
        let matchReads = 3 * 2
        #expect(driver.reads.count == 1 + matchReads)
    }

    @Test("An engine listed schema by schema costs one table read per schema plus the matches")
    func perSchemaListing() async throws {
        let (schemas, driver) = catalog(listsInOneCall: false)

        let matched = try await search(schemas, driver: driver)

        let listingReads = 1 + 1 + 200
        let matchReads = 3 * 2
        #expect(matched == ["S1", "S71", "S141"])
        #expect(driver.reads.filter { $0.hasPrefix("routines") }.count == 3)
        #expect(driver.reads.count == listingReads + matchReads)
    }
}
