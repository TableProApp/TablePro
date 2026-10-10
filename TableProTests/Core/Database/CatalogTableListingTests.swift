//
//  CatalogTableListingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct CatalogTableListingTests {
    private struct ListingFailed: Error {}

    private let scope = DatabaseScope(connectionId: UUID(), database: "shop", schema: nil)

    private func table(_ name: String, _ schema: String) -> TableInfo {
        TestFixtures.makeTableInfo(name: name, schema: schema)
    }

    @Test("A single call answers for every schema, less the excluded ones")
    func singleCall() async throws {
        let driver = MockDatabaseDriver()
        driver.allSchemaTablesToReturn = [table("users", "public"), table("pg_class", "pg_catalog")]
        let metadata = RecordingMetadataProvider(driver: driver)

        let listing = try await CatalogTableListing.tables(in: scope, excludingSchemas: ["pg_catalog"], metadata: metadata)

        #expect(listing.tables.map(\.name) == ["users"])
        #expect(listing.unlistedSchemas.isEmpty)
        #expect(driver.fetchSchemasCallCount == 0)
    }

    /// A scope per schema would open a pooled connection per schema, one for every schema of a
    /// database with hundreds of them.
    @Test("Every per-schema read goes through the one scope it was given")
    func perSchemaReadsShareOneScope() async throws {
        let driver = MockDatabaseDriver()
        driver.schemasToReturn = ["public", "attendance", "sales"]
        driver.schemaTablesToReturn = [
            "public": [table("users", "public")],
            "attendance": [table("timesheet", "attendance")],
            "sales": [table("orders", "sales")]
        ]
        let metadata = RecordingMetadataProvider(driver: driver)

        let listing = try await CatalogTableListing.tables(in: scope, excludingSchemas: ["sales"], metadata: metadata)

        #expect(listing.tables.map(\.name) == ["users", "timesheet"])
        #expect(driver.fetchSchemaTablesCalls == ["public", "attendance"])
        #expect(Set(metadata.requestedScopes) == [scope])
        #expect(metadata.requestedWorkloads.allSatisfy { $0 == .bulk })
    }

    @Test("A schema whose read fails is named, not read as empty")
    func failedSchemaIsNamed() async throws {
        let driver = MockDatabaseDriver()
        driver.schemasToReturn = ["public", "attendance"]
        driver.schemaTablesToReturn = ["public": [table("users", "public")]]
        driver.schemaTablesErrors = ["attendance": ListingFailed()]

        let listing = try await CatalogTableListing.tables(
            in: scope, excludingSchemas: [], metadata: RecordingMetadataProvider(driver: driver)
        )

        #expect(listing.tables.map(\.name) == ["users"])
        #expect(listing.unlistedSchemas == ["attendance"])
    }

    @Test("A second read of unlisted schemas folds in what it listed and keeps what it could not")
    func mergingARetry() {
        let first = CatalogTableListing.Result(
            tables: [table("users", "public")],
            unlistedSchemas: ["attendance", "payroll"]
        )
        let retry = CatalogTableListing.Result(
            tables: [table("timesheet", "attendance")],
            unlistedSchemas: ["payroll"]
        )

        let merged = first.merging(retry, retried: ["attendance", "payroll"])

        #expect(merged.tables.map(\.name) == ["users", "timesheet"])
        #expect(merged.unlistedSchemas == ["payroll"])
    }

    @Test("A retry that still cannot read a schema keeps what was known of it")
    func mergingARetryThatFailsAgain() {
        let first = CatalogTableListing.Result(
            tables: [table("users", "public"), table("payslips", "payroll")],
            unlistedSchemas: ["payroll"]
        )
        let retry = CatalogTableListing.Result(tables: [], unlistedSchemas: ["payroll"])

        let merged = first.merging(retry, retried: ["payroll"])

        #expect(merged.tables.map(\.name) == ["users", "payslips"])
        #expect(merged.unlistedSchemas == ["payroll"])
    }

    @Test("A refresh that cannot read a schema carries that schema's earlier rows over")
    func keepingRowsFromAnEarlierListing() {
        let earlier = CatalogTableListing.Result(
            tables: [table("users", "public"), table("timesheet", "attendance")],
            unlistedSchemas: []
        )
        let refresh = CatalogTableListing.Result(tables: [table("orders", "public")], unlistedSchemas: ["attendance"])

        let kept = refresh.keepingRows(from: earlier)

        #expect(kept.tables.map(\.name) == ["orders", "timesheet"])
        #expect(kept.unlistedSchemas == ["attendance"])
    }

    @Test("A lost connection fails the whole listing rather than reading as empty")
    func lostConnectionFailsTheListing() async {
        let driver = MockDatabaseDriver()
        driver.schemasToReturn = ["public", "attendance"]
        driver.schemaTablesErrors = ["attendance": DatabaseError.notConnected]

        await #expect(throws: DatabaseError.self) {
            try await CatalogTableListing.tables(
                in: scope, excludingSchemas: [], metadata: RecordingMetadataProvider(driver: driver)
            )
        }
    }

    @Test("Every schema failing fails the whole listing")
    func everySchemaFailingFailsTheListing() async {
        let driver = MockDatabaseDriver()
        driver.schemasToReturn = ["public", "attendance"]
        driver.schemaTablesErrors = ["public": ListingFailed(), "attendance": ListingFailed()]

        await #expect(throws: ListingFailed.self) {
            try await CatalogTableListing.tables(
                in: scope, excludingSchemas: [], metadata: RecordingMetadataProvider(driver: driver)
            )
        }
    }

    @Test("A failed schema list fails the whole listing")
    func failedSchemaListThrows() async {
        let driver = MockDatabaseDriver()
        driver.fetchSchemasError = ListingFailed()

        await #expect(throws: ListingFailed.self) {
            try await CatalogTableListing.tables(
                in: scope, excludingSchemas: [], metadata: RecordingMetadataProvider(driver: driver)
            )
        }
    }
}

/// A kept set is the schema list, so no read asks the server for one.
@MainActor
struct CatalogTableListingSelectionTests {
    private struct ListingFailed: Error {}

    private let connectionId = UUID()

    private var scope: DatabaseScope {
        DatabaseScope(connectionId: connectionId, database: "shop", schema: nil)
    }

    private func table(_ name: String, _ schema: String) -> TableInfo {
        TestFixtures.makeTableInfo(name: name, schema: schema)
    }

    private func driver() -> CatalogReadCountingDriver {
        let driver = CatalogReadCountingDriver(connection: TestFixtures.makeConnection(id: connectionId, type: .postgresql))
        driver.schemasToReturn = ["a", "b", "c"]
        driver.tablesBySchema = [
            "a": [table("orders", "a")],
            "b": [table("invoices", "b")],
            "c": [table("payslips", "c")]
        ]
        return driver
    }

    private func listing(
        _ selection: CatalogTableListing.SchemaSelection,
        excluding excluded: Set<String> = [],
        on driver: CatalogReadCountingDriver
    ) async throws -> CatalogTableListing.Result {
        try await CatalogTableListing.tables(
            in: scope,
            selection: selection,
            excludingSchemas: excluded,
            metadata: SingleDriverMetadataProvider(driver: driver, scope: scope)
        )
    }

    @Test("A kept set is read in one call when the engine answers it")
    func keptSetInOneCall() async throws {
        let driver = driver()
        driver.answersTablesInSchemas = true

        let result = try await listing(.only(["b", "a"]), on: driver)

        #expect(driver.reads == ["tablesIn(a,b)"])
        #expect(result.tables.map(\.name) == ["orders", "invoices"])
        #expect(result.unlistedSchemas.isEmpty)
    }

    @Test("A filtered listing never calls fetchTablesInAllSchemas, even on an engine that answers it")
    func filteredListingNeverReadsEverySchema() async throws {
        let driver = driver()
        driver.allSchemaTables = [table("orders", "a"), table("invoices", "b"), table("payslips", "c")]

        let result = try await listing(.only(["a", "c"]), on: driver)

        #expect(!driver.reads.contains("allSchemaTables"))
        #expect(driver.perSchemaReads == ["tables:a", "tables:c"])
        #expect(result.tables.map(\.name) == ["orders", "payslips"])
    }

    @Test("A kept set on an engine without a set read reads its schemas one by one, and no schema list")
    func keptSetSchemaBySchema() async throws {
        let driver = driver()

        let result = try await listing(.only(["b", "a"]), on: driver)

        #expect(driver.reads == ["tables:a", "tables:b"])
        #expect(result.tables.map(\.name) == ["orders", "invoices"])
    }

    @Test("A kept schema whose read fails is named, and the other kept schemas still list")
    func keptSchemaFailureIsNamed() async throws {
        let driver = MockDatabaseDriver()
        driver.allSchemaTablesToReturn = [table("users", "public"), table("timesheet", "attendance")]
        driver.schemaTablesToReturn = ["public": [table("users", "public")]]
        driver.schemaTablesErrors = ["attendance": ListingFailed()]

        let result = try await CatalogTableListing.tables(
            in: scope,
            selection: .only(["public", "attendance"]),
            excludingSchemas: [],
            metadata: RecordingMetadataProvider(driver: driver)
        )

        #expect(result.tables.map(\.name) == ["users"])
        #expect(result.unlistedSchemas == ["attendance"])
        #expect(driver.fetchTablesInAllSchemasCallCount == 0)
        #expect(driver.fetchSchemasCallCount == 0)
    }

    @Test("An empty kept set, or one of excluded schemas only, reads nothing")
    func emptyKeptSetReadsNothing() async throws {
        let driver = driver()
        driver.answersTablesInSchemas = true

        let empty = try await listing(.only([]), on: driver)
        let excluded = try await listing(.only(["pg_catalog"]), excluding: ["pg_catalog"], on: driver)

        #expect(driver.reads.isEmpty)
        #expect(empty.tables.isEmpty)
        #expect(excluded.tables.isEmpty)
    }

    @Test("Restricting a listing keeps the kept schemas' rows and unlisted names only")
    func restrictingAListing() {
        let listing = CatalogTableListing.Result(
            tables: [table("orders", "a"), table("invoices", "b"), TestFixtures.makeTableInfo(name: "loose")],
            unlistedSchemas: ["b", "c"]
        )

        let restricted = listing.restricted(to: .only(["b"]))

        #expect(restricted.tables.map(\.name) == ["invoices", "loose"])
        #expect(restricted.unlistedSchemas == ["b"])
        #expect(listing.restricted(to: .all) == listing)
    }

    @Test("Two selections meet in the schemas both keep")
    func selectionsIntersect() {
        #expect(CatalogTableListing.SchemaSelection.all.intersection(.all) == .all)
        #expect(CatalogTableListing.SchemaSelection.all.intersection(.only(["a"])) == .only(["a"]))
        #expect(CatalogTableListing.SchemaSelection.only(["a", "b"]).intersection(.all) == .only(["a", "b"]))
        #expect(CatalogTableListing.SchemaSelection.only(["a", "b"]).intersection(.only(["b", "c"])) == .only(["b"]))
    }
}

@MainActor
private final class RecordingMetadataProvider: ScopedMetadataProviding {
    private let driver: MockDatabaseDriver
    private(set) var requestedScopes: [DatabaseScope] = []
    private(set) var requestedWorkloads: [MetadataConnectionPool.Workload] = []

    init(driver: MockDatabaseDriver) {
        self.driver = driver
    }

    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        requestedScopes.append(scope)
        requestedWorkloads.append(workload)
        return try await body(driver)
    }

    func browseScope(for connectionId: UUID) -> DatabaseScope? { nil }
}
