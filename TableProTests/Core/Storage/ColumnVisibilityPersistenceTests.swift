//
//  ColumnVisibilityPersistenceTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("ColumnVisibilityPersistence")
@MainActor
struct ColumnVisibilityPersistenceTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "ColumnVisibilityPersistenceTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create UserDefaults suite for tests")
        }
        return defaults
    }

    private func makeKey(
        table: String,
        connectionId: UUID = UUID(),
        database: String = "app",
        schema: String? = "public"
    ) -> ColumnLayoutTableKey {
        ColumnLayoutTableKey(
            connectionId: connectionId,
            databaseName: database,
            schemaName: schema,
            tableName: table
        )
    }

    @Test("loadHiddenColumns returns an empty set when no value is stored")
    func loadReturnsEmptyByDefault() {
        let defaults = makeDefaults()
        let result = ColumnVisibilityPersistence.loadHiddenColumns(for: makeKey(table: "users"), defaults: defaults)
        #expect(result.isEmpty)
    }

    @Test("saveHiddenColumns then loadHiddenColumns round-trips the set")
    func roundTripsAcrossSaveAndLoad() {
        let defaults = makeDefaults()
        let key = makeKey(table: "users")
        ColumnVisibilityPersistence.saveHiddenColumns(["email", "phone"], for: key, defaults: defaults)

        let result = ColumnVisibilityPersistence.loadHiddenColumns(for: key, defaults: defaults)
        #expect(result == ["email", "phone"])
    }

    @Test("Different tables under the same connection store independent sets")
    func tablesAreScopedSeparately() {
        let defaults = makeDefaults()
        let connectionId = UUID()
        let users = makeKey(table: "users", connectionId: connectionId)
        let orders = makeKey(table: "orders", connectionId: connectionId)
        ColumnVisibilityPersistence.saveHiddenColumns(["a"], for: users, defaults: defaults)
        ColumnVisibilityPersistence.saveHiddenColumns(["b"], for: orders, defaults: defaults)

        #expect(ColumnVisibilityPersistence.loadHiddenColumns(for: users, defaults: defaults) == ["a"])
        #expect(ColumnVisibilityPersistence.loadHiddenColumns(for: orders, defaults: defaults) == ["b"])
    }

    @Test("Different connections store independent sets for the same table name")
    func connectionsAreScopedSeparately() {
        let defaults = makeDefaults()
        let a = makeKey(table: "users", connectionId: UUID())
        let b = makeKey(table: "users", connectionId: UUID())
        ColumnVisibilityPersistence.saveHiddenColumns(["x"], for: a, defaults: defaults)
        ColumnVisibilityPersistence.saveHiddenColumns(["y"], for: b, defaults: defaults)

        #expect(ColumnVisibilityPersistence.loadHiddenColumns(for: a, defaults: defaults) == ["x"])
        #expect(ColumnVisibilityPersistence.loadHiddenColumns(for: b, defaults: defaults) == ["y"])
    }

    @Test("Same table name in different databases does not collide")
    func databasesAreScopedSeparately() {
        let defaults = makeDefaults()
        let connectionId = UUID()
        let sales = makeKey(table: "users", connectionId: connectionId, database: "sales")
        let hr = makeKey(table: "users", connectionId: connectionId, database: "hr")
        ColumnVisibilityPersistence.saveHiddenColumns(["salary"], for: sales, defaults: defaults)
        ColumnVisibilityPersistence.saveHiddenColumns(["ssn"], for: hr, defaults: defaults)

        #expect(ColumnVisibilityPersistence.loadHiddenColumns(for: sales, defaults: defaults) == ["salary"])
        #expect(ColumnVisibilityPersistence.loadHiddenColumns(for: hr, defaults: defaults) == ["ssn"])
    }

    @Test("Same table name in different schemas does not collide")
    func schemasAreScopedSeparately() {
        let defaults = makeDefaults()
        let connectionId = UUID()
        let publicUsers = makeKey(table: "users", connectionId: connectionId, schema: "public")
        let authUsers = makeKey(table: "users", connectionId: connectionId, schema: "auth")
        ColumnVisibilityPersistence.saveHiddenColumns(["a"], for: publicUsers, defaults: defaults)
        ColumnVisibilityPersistence.saveHiddenColumns(["b"], for: authUsers, defaults: defaults)

        #expect(ColumnVisibilityPersistence.loadHiddenColumns(for: publicUsers, defaults: defaults) == ["a"])
        #expect(ColumnVisibilityPersistence.loadHiddenColumns(for: authUsers, defaults: defaults) == ["b"])
    }

    @Test("Saving an empty set clears stored state")
    func savingEmptySetClearsState() {
        let defaults = makeDefaults()
        let key = makeKey(table: "users")
        ColumnVisibilityPersistence.saveHiddenColumns(["leftover"], for: key, defaults: defaults)
        ColumnVisibilityPersistence.saveHiddenColumns([], for: key, defaults: defaults)

        #expect(ColumnVisibilityPersistence.loadHiddenColumns(for: key, defaults: defaults).isEmpty)
    }

    @Test("Storage key carries the hidden-columns prefix and separates scopes")
    func keyFormat() {
        let connectionId = UUID()
        let publicKey = ColumnVisibilityPersistence.key(
            for: makeKey(table: "users", connectionId: connectionId, database: "app", schema: "public")
        )
        let authKey = ColumnVisibilityPersistence.key(
            for: makeKey(table: "users", connectionId: connectionId, database: "app", schema: "auth")
        )
        #expect(publicKey.hasPrefix("com.TablePro.columns.hiddenColumns."))
        #expect(publicKey != authKey)
    }
}
