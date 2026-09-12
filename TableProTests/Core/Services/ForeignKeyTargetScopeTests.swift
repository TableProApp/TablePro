//
//  ForeignKeyTargetScopeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Foreign key target scope")
struct ForeignKeyTargetScopeTests {
    private let connectionId = UUID()

    private func origin(database: String = "shop", schema: String? = nil) -> DatabaseScope {
        DatabaseScope(connectionId: connectionId, database: database, schema: schema)
    }

    // MARK: - Slot

    @Test("An engine with schemas qualifies by schema, one without qualifies by database")
    func slotFollowsCapabilities() {
        #expect(EngineNamespaceSlot(supportsSchemas: true, supportsDatabases: true) == .schema)
        #expect(EngineNamespaceSlot(supportsSchemas: true, supportsDatabases: false) == .schema)
        #expect(EngineNamespaceSlot(supportsSchemas: false, supportsDatabases: true) == .database)
        #expect(EngineNamespaceSlot(supportsSchemas: false, supportsDatabases: false) == .unqualified)
    }

    // MARK: - Resolution

    /// DuckDB, Trino, BigQuery, SurrealDB and CloudflareR2SQL all declare schemas and never report a
    /// referenced one, so the origin has to supply it. Dropping this arm breaks all five.
    @Test("A reference that names nothing keeps the origin untouched", arguments: [String?.none, ""])
    func absentReferenceKeepsOrigin(referenced: String?) {
        let source = origin(schema: "public")
        for slot in [EngineNamespaceSlot.schema, .database, .unqualified] {
            #expect(
                ForeignKeyTargetScope.resolve(
                    origin: source, referencedSchema: referenced, slot: slot
                ) == source
            )
        }
    }

    @Test("A schema engine puts the reference in the schema slot and stays on the database")
    func schemaEngineKeepsDatabase() {
        let resolved = ForeignKeyTargetScope.resolve(
            origin: origin(schema: "public"), referencedSchema: "audit", slot: .schema
        )
        #expect(resolved.database == "shop")
        #expect(resolved.schema == "audit")
    }

    /// MySQL reports `REFERENCED_TABLE_SCHEMA`, which names the referenced database.
    @Test("A schema-less engine puts the reference in the database slot and clears the schema")
    func schemaLessEngineMovesToDatabase() {
        let resolved = ForeignKeyTargetScope.resolve(
            origin: origin(), referencedSchema: "warehouse", slot: .database
        )
        #expect(resolved.database == "warehouse")
        #expect(resolved.schema == nil)
    }

    @Test("A reference to the origin's own database resolves back to the origin")
    func sameDatabaseReferenceResolvesToOrigin() {
        let source = origin()
        #expect(
            ForeignKeyTargetScope.resolve(
                origin: source, referencedSchema: "shop", slot: .database
            ) == source
        )
    }

    @Test("An engine with no containers at all drops the reference rather than inventing a database")
    func containerlessEngineDropsTheReference() {
        let resolved = ForeignKeyTargetScope.resolve(
            origin: origin(), referencedSchema: "ignored", slot: .unqualified
        )
        #expect(resolved.database == "shop")
        #expect(resolved.schema == nil)
    }

    // MARK: - A referenced database

    /// Snowflake names objects in three parts, so a key can point outside the database it was read
    /// from. Only the schema arm can carry one: the other two already hold a database in that slot.
    @Test("A schema engine follows a reference into another database")
    func schemaEngineFollowsAReferencedDatabase() {
        let resolved = ForeignKeyTargetScope.resolve(
            origin: origin(database: "analytics", schema: "public"),
            referencedDatabase: "raw",
            referencedSchema: "events",
            slot: .schema
        )
        #expect(resolved.database == "raw")
        #expect(resolved.schema == "events")
    }

    @Test("A referenced database with no schema of its own keeps the origin's")
    func referencedDatabaseAloneKeepsTheOriginSchema() {
        let resolved = ForeignKeyTargetScope.resolve(
            origin: origin(database: "analytics", schema: "public"),
            referencedDatabase: "raw",
            referencedSchema: nil,
            slot: .schema
        )
        #expect(resolved.database == "raw")
        #expect(resolved.schema == "public")
    }

    /// An engine with no schema layer already names its referenced database in the schema slot, so
    /// a second one would be two answers to one question. MySQL cannot move.
    @Test("A schema-less engine ignores a referenced database", arguments: [EngineNamespaceSlot.database, .unqualified])
    func schemaLessEngineIgnoresAReferencedDatabase(slot: EngineNamespaceSlot) {
        let resolved = ForeignKeyTargetScope.resolve(
            origin: origin(),
            referencedDatabase: "ignored",
            referencedSchema: "warehouse",
            slot: slot
        )
        #expect(resolved.database == (slot == .database ? "warehouse" : "shop"))
        #expect(resolved.schema == nil)
    }

    @Test("A reference naming neither container still keeps the origin untouched")
    func neitherContainerKeepsOrigin() {
        let source = origin(schema: "public")
        #expect(
            ForeignKeyTargetScope.resolve(
                origin: source, referencedDatabase: nil, referencedSchema: nil, slot: .schema
            ) == source
        )
    }

    // MARK: - Agreement with the canonical table scope

    /// The invariant #2768 broke. A foreign key label, a filter, a column layout, a highlight rule
    /// and a Display As format all hang on a `TableScope`, so the scope the picker writes under has
    /// to be the one the tab builds and the one a rename moves. Comparing them directly is the
    /// guard: a second scope-building function that disagrees fails here rather than shipping.
    @Test("The referenced table's scope is the scope its own tab would build, on both engine families")
    func referencedScopeMatchesTheTabScope() throws {
        let schemaLess = ForeignKeyTargetScope.tableScope(
            origin: origin(), referencedSchema: "shop", referencedTable: "users", slot: .database
        )
        #expect(try schemaLess == tabScope(database: "shop", schema: nil, table: "users"))

        let crossDatabase = ForeignKeyTargetScope.tableScope(
            origin: origin(), referencedSchema: "warehouse", referencedTable: "users", slot: .database
        )
        #expect(try crossDatabase == tabScope(database: "warehouse", schema: nil, table: "users"))

        let schemaful = ForeignKeyTargetScope.tableScope(
            origin: origin(schema: "public"),
            referencedSchema: "audit",
            referencedTable: "users",
            slot: .schema
        )
        #expect(crossDatabase != schemaLess)
        #expect(try schemaful == tabScope(database: "shop", schema: "audit", table: "users"))
    }

    @Test("A table scope from an unbound connection carries no database rather than an empty one")
    func unboundConnectionCarriesNoDatabase() {
        let scope = ForeignKeyTargetScope.tableScope(
            origin: origin(database: ""), referencedSchema: nil, referencedTable: "users", slot: .database
        )
        #expect(scope.database == nil)
        #expect(scope.schema == nil)
    }

    /// The canonical builder itself, not a copy of it: a divergence only counts if it is measured
    /// against what the tab really writes.
    private func tabScope(database: String, schema: String?, table: String) throws -> TableScope {
        var context = TabTableContext()
        context.tableName = table
        context.databaseName = database
        context.schemaName = schema
        return try #require(context.scope(connectionId: connectionId))
    }
}
