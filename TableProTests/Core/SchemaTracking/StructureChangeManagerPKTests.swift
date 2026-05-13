//
//  StructureChangeManagerPKTests.swift
//  TableProTests
//
//  Tests for S-03: Primary key detection should work across all database types.
//  The loadSchema method receives primary key info and must correctly track it.
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("Structure Change Manager Primary Key Detection")
struct StructureChangeManagerPKTests {

    // MARK: - Helpers

    @MainActor private func makeManager() -> StructureChangeManager {
        StructureChangeManager()
    }

    private func sampleColumns() -> [ColumnInfo] {
        [
            ColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true,
                       defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil),
            ColumnInfo(name: "name", dataType: "VARCHAR(255)", isNullable: true, isPrimaryKey: false,
                       defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil)
        ]
    }

    private func sampleColumnsNoPK() -> [ColumnInfo] {
        [
            ColumnInfo(name: "id", dataType: "INTEGER", isNullable: false, isPrimaryKey: false,
                       defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil),
            ColumnInfo(name: "name", dataType: "VARCHAR(255)", isNullable: true, isPrimaryKey: false,
                       defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil)
        ]
    }

    private func sampleIndexes(withPrimary: Bool = true) -> [IndexInfo] {
        var indexes: [IndexInfo] = []
        if withPrimary {
            indexes.append(IndexInfo(name: "PRIMARY", columns: ["id"], isUnique: true,
                                     isPrimary: true, type: "BTREE"))
        }
        return indexes
    }

    // MARK: - MySQL PK Detection (via ColumnInfo.isPrimaryKey)

    @Test("MySQL columns carry isPrimaryKey correctly")
    @MainActor func mysqlPKFromColumns() {
        let manager = makeManager()
        manager.loadSchema(
            tableName: "users",
            columns: sampleColumns(),
            indexes: sampleIndexes(),
            foreignKeys: [],
            primaryKey: ["id"],
            databaseType: .mysql
        )

        let idCol = manager.workingColumns.first { $0.name == "id" }
        #expect(idCol?.isPrimaryKey == true)

        let nameCol = manager.workingColumns.first { $0.name == "name" }
        #expect(nameCol?.isPrimaryKey == false)

        #expect(manager.workingPrimaryKey == ["id"])
    }

    // MARK: - PostgreSQL PK Detection

    @Test("PostgreSQL PK detected from primaryKey parameter even when isPrimaryKey is false")
    @MainActor func postgresqlPKFromParameter() {
        let manager = makeManager()

        // PostgreSQL columns come with isPrimaryKey: false (the bug in S-03)
        // But we pass primaryKey: ["id"] explicitly
        manager.loadSchema(
            tableName: "users",
            columns: sampleColumnsNoPK(),
            indexes: sampleIndexes(),
            foreignKeys: [],
            primaryKey: ["id"],
            databaseType: .postgresql
        )

        // The working columns should have isPrimaryKey set based on the primaryKey parameter
        let idCol = manager.workingColumns.first { $0.name == "id" }
        #expect(idCol?.isPrimaryKey == true)

        let nameCol = manager.workingColumns.first { $0.name == "name" }
        #expect(nameCol?.isPrimaryKey == false)

        #expect(manager.workingPrimaryKey == ["id"])
    }

    @Test("PostgreSQL composite PK detected from primaryKey parameter")
    @MainActor func postgresqlCompositePK() {
        let manager = makeManager()

        let columns: [ColumnInfo] = [
            ColumnInfo(name: "tenant_id", dataType: "INTEGER", isNullable: false, isPrimaryKey: false,
                       defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil),
            ColumnInfo(name: "user_id", dataType: "INTEGER", isNullable: false, isPrimaryKey: false,
                       defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil),
            ColumnInfo(name: "role", dataType: "VARCHAR(50)", isNullable: true, isPrimaryKey: false,
                       defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil)
        ]

        manager.loadSchema(
            tableName: "user_roles",
            columns: columns,
            indexes: [],
            foreignKeys: [],
            primaryKey: ["tenant_id", "user_id"],
            databaseType: .postgresql
        )

        let tenantCol = manager.workingColumns.first { $0.name == "tenant_id" }
        #expect(tenantCol?.isPrimaryKey == true)

        let userCol = manager.workingColumns.first { $0.name == "user_id" }
        #expect(userCol?.isPrimaryKey == true)

        let roleCol = manager.workingColumns.first { $0.name == "role" }
        #expect(roleCol?.isPrimaryKey == false)

        #expect(manager.workingPrimaryKey == ["tenant_id", "user_id"])
    }

    @Test("Empty primaryKey parameter means no PK columns")
    @MainActor func emptyPrimaryKey() {
        let manager = makeManager()

        manager.loadSchema(
            tableName: "logs",
            columns: sampleColumnsNoPK(),
            indexes: [],
            foreignKeys: [],
            primaryKey: [],
            databaseType: .postgresql
        )

        for col in manager.workingColumns {
            #expect(col.isPrimaryKey == false)
        }
        #expect(manager.workingPrimaryKey.isEmpty)
    }
}
