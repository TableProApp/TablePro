//
//  CatalogTableListingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("CatalogTableListing")
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
