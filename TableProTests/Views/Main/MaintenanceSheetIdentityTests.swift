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
import Testing

@Suite("Maintenance sheet identity")
struct MaintenanceSheetIdentityTests {
    @Test("The same table in two databases is two different requests")
    func distinguishesTwoDatabases() {
        let online = ActiveSheet.maintenance(
            operation: "OPTIMIZE TABLE", tableName: "role_ability", database: "banshi_online", schema: nil
        )
        let test = ActiveSheet.maintenance(
            operation: "OPTIMIZE TABLE", tableName: "role_ability", database: "banshi_test", schema: nil
        )

        #expect(online.id != test.id)
    }

    @Test("The same table in two schemas of one database is two different requests")
    func distinguishesTwoSchemas() {
        let publicSchema = ActiveSheet.maintenance(
            operation: "VACUUM", tableName: "orders", database: "app", schema: "public"
        )
        let reporting = ActiveSheet.maintenance(
            operation: "VACUUM", tableName: "orders", database: "app", schema: "reporting"
        )

        #expect(publicSchema.id != reporting.id)
    }

    @Test("The same object is the same request")
    func matchesTheSameObject() {
        let first = ActiveSheet.maintenance(
            operation: "ANALYZE TABLE", tableName: "orders", database: "app", schema: "public"
        )
        let second = ActiveSheet.maintenance(
            operation: "ANALYZE TABLE", tableName: "orders", database: "app", schema: "public"
        )

        #expect(first.id == second.id)
    }

    @Test("A request that names no database is not the same as one that does")
    func distinguishesAnUnnamedDatabase() {
        let named = ActiveSheet.maintenance(
            operation: "OPTIMIZE TABLE", tableName: "orders", database: "app", schema: nil
        )
        let unnamed = ActiveSheet.maintenance(
            operation: "OPTIMIZE TABLE", tableName: "orders", database: nil, schema: nil
        )

        #expect(named.id != unnamed.id)
    }
}
