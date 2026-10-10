//
//  UserDefinedTypeSuggestionsLoadTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// Locked rather than isolated: the fallback reads every schema from concurrent child tasks.
private final class FakeTypeCatalog: UserDefinedTypeCatalogReading, @unchecked Sendable {
    private let schemas: [String]
    private let answersSchemaSets: Bool
    private let lock = NSLock()
    private var readLog: [String] = []

    init(schemas: [String], answersSchemaSets: Bool = true) {
        self.schemas = schemas
        self.answersSchemaSets = answersSchemaSets
    }

    var reads: [String] {
        lock.withLock { readLog }
    }

    private func record(_ read: String) {
        lock.withLock { readLog.append(read) }
    }

    func fetchSchemas() async throws -> [String] {
        record("schemas")
        return schemas
    }

    func fetchUserDefinedTypes(schema: String?) async throws -> [UserDefinedTypeInfo] {
        record("types:\(schema ?? "")")
        return [Self.type(in: schema)]
    }

    func fetchUserDefinedTypes(inSchemas schemas: [String]) async throws -> [UserDefinedTypeInfo]? {
        record("typesIn:\(schemas.joined(separator: ","))")
        guard answersSchemaSets else { return nil }
        return schemas.map { Self.type(in: $0) }
    }

    private static func type(in schema: String?) -> UserDefinedTypeInfo {
        UserDefinedTypeInfo(name: "status", kind: .enumeration, schema: schema)
    }
}

struct UserDefinedTypeSuggestionsLoadTests {
    private func fetch(
        _ catalog: FakeTypeCatalog,
        tableSchema: String? = "public",
        systemSchemas: Set<String> = ["pg_catalog", "information_schema"],
        schemaFilter: Set<String> = []
    ) async throws -> [UserDefinedTypeInfo] {
        try await UserDefinedTypeSuggestions.fetchTypes(
            from: catalog,
            tableSchema: tableSchema,
            systemSchemas: systemSchemas,
            schemaFilter: schemaFilter
        )
    }

    @Test("Every offered schema's types come from one read, with system schemas left out")
    func offeredSchemasReadInOneStatement() async throws {
        let catalog = FakeTypeCatalog(schemas: ["pg_catalog", "public", "sales", "information_schema"])

        let types = try await fetch(catalog)

        #expect(catalog.reads == ["schemas", "typesIn:public,sales"])
        #expect(types.compactMap(\.schema) == ["public", "sales"])
    }

    @Test("An engine with no set read is asked once per offered schema")
    func noSetReadFallsBackPerSchema() async throws {
        let catalog = FakeTypeCatalog(schemas: ["public", "sales"], answersSchemaSets: false)

        let types = try await fetch(catalog)

        let reads = catalog.reads
        #expect(Array(reads.prefix(2)) == ["schemas", "typesIn:public,sales"])
        #expect(Set(reads.dropFirst(2)) == ["types:public", "types:sales"])
        #expect(reads.count == 4)
        #expect(Set(types.compactMap(\.schema)) == ["public", "sales"])
    }

    @Test("The schema filter skips hidden schemas but keeps the table's own")
    func schemaFilterKeepsTheTableSchema() async throws {
        let catalog = FakeTypeCatalog(schemas: ["archive", "public", "sales"])

        _ = try await fetch(catalog, tableSchema: "public", schemaFilter: ["sales"])

        let reads = catalog.reads
        #expect(reads == ["schemas", "typesIn:public,sales"])
        #expect(!reads.contains { $0.contains("archive") })
    }

    @Test("The table's schema is read even when the schema list leaves it out")
    func tableSchemaMissingFromTheListIsRead() async throws {
        let catalog = FakeTypeCatalog(schemas: ["sales"])

        _ = try await fetch(catalog, tableSchema: "staging")

        #expect(catalog.reads == ["schemas", "typesIn:sales,staging"])
    }

    @Test("An engine that lists no schemas is asked about the table's own schema alone")
    func noListedSchemasReadsTheTableSchema() async throws {
        let catalog = FakeTypeCatalog(schemas: [])

        _ = try await fetch(catalog, tableSchema: "public")

        #expect(catalog.reads == ["schemas", "types:public"])
    }

    @Test("Offered schemas keep the server's order")
    func offeredSchemasKeepServerOrder() {
        let offered = UserDefinedTypeSuggestions.offeredSchemas(
            listed: ["zeta", "alpha", "pg_catalog", "mid"],
            tableSchema: "alpha",
            systemSchemas: ["pg_catalog"],
            schemaFilter: []
        )
        #expect(offered == ["zeta", "alpha", "mid"])
    }

    @Test("A system schema is never offered, even as the table's own")
    func systemTableSchemaIsNotOffered() {
        let offered = UserDefinedTypeSuggestions.offeredSchemas(
            listed: ["public"],
            tableSchema: "pg_catalog",
            systemSchemas: ["pg_catalog"],
            schemaFilter: []
        )
        #expect(offered == ["public"])
    }
}
