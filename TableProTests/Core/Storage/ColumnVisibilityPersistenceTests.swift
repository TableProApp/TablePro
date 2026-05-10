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

    @Test("loadHiddenColumns returns an empty set when no value is stored")
    func loadReturnsEmptyByDefault() {
        let defaults = makeDefaults()
        let result = ColumnVisibilityPersistence.loadHiddenColumns(
            for: "users",
            connectionId: UUID(),
            defaults: defaults
        )
        #expect(result.isEmpty)
    }

    @Test("saveHiddenColumns then loadHiddenColumns round-trips the set")
    func roundTripsAcrossSaveAndLoad() {
        let defaults = makeDefaults()
        let connectionId = UUID()
        ColumnVisibilityPersistence.saveHiddenColumns(
            ["email", "phone"],
            for: "users",
            connectionId: connectionId,
            defaults: defaults
        )

        let result = ColumnVisibilityPersistence.loadHiddenColumns(
            for: "users",
            connectionId: connectionId,
            defaults: defaults
        )
        #expect(result == ["email", "phone"])
    }

    @Test("Different tables under the same connection store independent sets")
    func tablesAreScopedSeparately() {
        let defaults = makeDefaults()
        let connectionId = UUID()
        ColumnVisibilityPersistence.saveHiddenColumns(
            ["a"],
            for: "users",
            connectionId: connectionId,
            defaults: defaults
        )
        ColumnVisibilityPersistence.saveHiddenColumns(
            ["b"],
            for: "orders",
            connectionId: connectionId,
            defaults: defaults
        )

        #expect(
            ColumnVisibilityPersistence.loadHiddenColumns(
                for: "users",
                connectionId: connectionId,
                defaults: defaults
            ) == ["a"]
        )
        #expect(
            ColumnVisibilityPersistence.loadHiddenColumns(
                for: "orders",
                connectionId: connectionId,
                defaults: defaults
            ) == ["b"]
        )
    }

    @Test("Different connections store independent sets for the same table name")
    func connectionsAreScopedSeparately() {
        let defaults = makeDefaults()
        let connectionA = UUID()
        let connectionB = UUID()
        ColumnVisibilityPersistence.saveHiddenColumns(
            ["x"],
            for: "users",
            connectionId: connectionA,
            defaults: defaults
        )
        ColumnVisibilityPersistence.saveHiddenColumns(
            ["y"],
            for: "users",
            connectionId: connectionB,
            defaults: defaults
        )

        #expect(
            ColumnVisibilityPersistence.loadHiddenColumns(
                for: "users",
                connectionId: connectionA,
                defaults: defaults
            ) == ["x"]
        )
        #expect(
            ColumnVisibilityPersistence.loadHiddenColumns(
                for: "users",
                connectionId: connectionB,
                defaults: defaults
            ) == ["y"]
        )
    }

    @Test("saveHiddenColumns with an empty set persists as an empty array")
    func savingEmptySetClearsState() {
        let defaults = makeDefaults()
        let connectionId = UUID()
        ColumnVisibilityPersistence.saveHiddenColumns(
            ["leftover"],
            for: "users",
            connectionId: connectionId,
            defaults: defaults
        )
        ColumnVisibilityPersistence.saveHiddenColumns(
            [],
            for: "users",
            connectionId: connectionId,
            defaults: defaults
        )

        let result = ColumnVisibilityPersistence.loadHiddenColumns(
            for: "users",
            connectionId: connectionId,
            defaults: defaults
        )
        #expect(result.isEmpty)
    }

    @Test("Storage key encodes connection id and table name")
    func keyFormat() {
        let connectionId = UUID()
        let key = ColumnVisibilityPersistence.key(tableName: "users", connectionId: connectionId)
        #expect(key == "com.TablePro.columns.hiddenColumns.\(connectionId.uuidString).users")
    }
}
