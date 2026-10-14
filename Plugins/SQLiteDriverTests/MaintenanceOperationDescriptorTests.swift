//
//  MaintenanceOperationDescriptorTests.swift
//  SQLiteDriverTests
//
//  Maintenance used to be a list of bare operation names, so the app offered every one of them on
//  every object. The kind sets below are what SQLite 3.54.0 actually answered.
//

import Foundation
import TableProPluginKit
import Testing

struct MaintenanceOperationDescriptorTests {
    private func sqlite(_ name: String) throws -> PluginMaintenanceOperation {
        try #require(SQLiteMaintenance.operations.first { $0.name == name })
    }

    @Test("SQLite VACUUM and Integrity Check name no object and ignore one")
    func sqliteDatabaseScoped() throws {
        let vacuum = try sqlite("VACUUM")
        let integrity = try sqlite("Integrity Check")

        #expect(vacuum.scope == .database)
        #expect(integrity.scope == .database)
        #expect(vacuum.appliesTo.isEmpty)
        #expect(integrity.appliesTo.isEmpty)
        #expect(vacuum.target("orders") == nil)
        #expect(integrity.target("orders") == nil)
        #expect(SQLiteMaintenance.statements(operation: "VACUUM", table: "orders") == ["VACUUM"])
        #expect(SQLiteMaintenance.statements(operation: "Integrity Check", table: "orders") == ["PRAGMA integrity_check"])
    }

    @Test("SQLite ANALYZE and REINDEX are offered on a table and not on a view")
    func sqliteObjectScoped() throws {
        for name in ["ANALYZE", "REINDEX"] {
            let operation = try sqlite(name)
            #expect(operation.applies(to: .table))
            #expect(!operation.applies(to: .view))
            #expect(operation.scope == .objectOrDatabase)
        }
        #expect(SQLiteMaintenance.statements(operation: "ANALYZE", table: "orders") == ["ANALYZE `orders`"])
        #expect(SQLiteMaintenance.statements(operation: "REINDEX", table: nil) == ["REINDEX"])
    }

    @Test("A backtick in a SQLite object name is doubled")
    func sqliteQuoting() {
        #expect(SQLiteMaintenance.statements(operation: "ANALYZE", table: "or`ders") == ["ANALYZE `or``ders`"])
    }
}
