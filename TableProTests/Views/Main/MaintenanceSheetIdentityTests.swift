//
//  MaintenanceSheetIdentityTests.swift
//  TableProTests
//
//  A maintenance request is identified by the object it names, database included. Without the
//  database it is the same request in every database that holds a table by that name, which is
//  how the command came to run against whichever one the connection happened to be on.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Maintenance sheet identity")
struct MaintenanceSheetIdentityTests {
    private func operation(_ name: String) -> PluginMaintenanceOperation {
        PluginMaintenanceOperation(name: name, appliesTo: [.table], scope: .object)
    }

    @Test("The same table in two databases is two different requests")
    func distinguishesTwoDatabases() {
        let online = ActiveSheet.maintenance(
            operation: operation("OPTIMIZE TABLE"),
            tableName: "role_ability",
            database: "banshi_online",
            schema: nil
        )
        let test = ActiveSheet.maintenance(
            operation: operation("OPTIMIZE TABLE"),
            tableName: "role_ability",
            database: "banshi_test",
            schema: nil
        )

        #expect(online.id != test.id)
    }

    @Test("The same table in two schemas of one database is two different requests")
    func distinguishesTwoSchemas() {
        let publicSchema = ActiveSheet.maintenance(
            operation: operation("VACUUM"), tableName: "orders", database: "app", schema: "public"
        )
        let reporting = ActiveSheet.maintenance(
            operation: operation("VACUUM"), tableName: "orders", database: "app", schema: "reporting"
        )

        #expect(publicSchema.id != reporting.id)
    }

    @Test("The same object is the same request")
    func matchesTheSameObject() {
        let first = ActiveSheet.maintenance(
            operation: operation("ANALYZE TABLE"), tableName: "orders", database: "app", schema: "public"
        )
        let second = ActiveSheet.maintenance(
            operation: operation("ANALYZE TABLE"), tableName: "orders", database: "app", schema: "public"
        )

        #expect(first.id == second.id)
    }

    @Test("A request that names no database is not the same as one that does")
    func distinguishesAnUnnamedDatabase() {
        let named = ActiveSheet.maintenance(
            operation: operation("OPTIMIZE TABLE"), tableName: "orders", database: "app", schema: nil
        )
        let unnamed = ActiveSheet.maintenance(
            operation: operation("OPTIMIZE TABLE"), tableName: "orders", database: nil, schema: nil
        )

        #expect(named.id != unnamed.id)
    }

    /// The identity keys on the operation's name, so two requests that differ only in the options the
    /// descriptor declares are the same sheet. The sheet seeds its own state from those options.
    @Test("Two descriptors with the same name are the same request")
    func ignoresDescriptorShape() {
        let plain = ActiveSheet.maintenance(
            operation: PluginMaintenanceOperation(name: "VACUUM", appliesTo: [.table], scope: .object),
            tableName: "orders",
            database: "app",
            schema: "public"
        )
        let withOptions = ActiveSheet.maintenance(
            operation: PluginMaintenanceOperation(
                name: "VACUUM",
                appliesTo: [.table, .materializedView],
                scope: .objectOrDatabase,
                options: [PluginMaintenanceOption(key: "full", label: "FULL", defaultValue: "false")]
            ),
            tableName: "orders",
            database: "app",
            schema: "public"
        )

        #expect(plain.id == withOptions.id)
    }
}
