//
//  MSSQLPluginDriverDMLTests.swift
//  TableProTests
//
//  Pins the MSSQL plugin's UPDATE/DELETE statement generation to the PK-aware
//  contract introduced with PluginKit ABI 11. When the framework passes a
//  non-empty `primaryKeyColumns`, WHERE filters by PK only (and `TOP (1)` is
//  omitted because the PK uniquely identifies one row). When the framework
//  passes an empty array, WHERE falls back to all columns plus `TOP (1)`.
//

import Foundation
@testable import MSSQLDriver
import TableProPluginKit
import Testing

@Suite("MSSQLPluginDriver DML")
struct MSSQLPluginDriverDMLTests {
    private func makeDriver() -> MSSQLPluginDriver {
        MSSQLPluginDriver(config: DriverConnectionConfig(
            host: "localhost",
            port: 1433,
            username: "SA",
            password: "irrelevant",
            database: "Sales"
        ))
    }

    private func makeUpdateChange(
        oldCustomerId: String = "2",
        newCustomerId: String = "3",
        originalRow: [String?] = ["2", "2", "19.99", "May 10 2026  7:58:53:2960999AM"]
    ) -> PluginRowChange {
        PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(1, "CustomerId", oldCustomerId, newCustomerId)],
            originalRow: originalRow
        )
    }

    // MARK: - UPDATE with PK

    @Test("UPDATE with primary key uses PK-only WHERE and drops TOP (1)")
    func updateWithPrimaryKeyUsesPKOnly() {
        let driver = makeDriver()
        let columns = ["Id", "CustomerId", "Total", "PlacedAt"]
        let change = makeUpdateChange()

        let result = driver.generateStatements(
            table: "Orders",
            columns: columns,
            primaryKeyColumns: ["Id"],
            changes: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(result?.count == 1)
        let sql = result?.first?.statement ?? ""
        #expect(sql == "UPDATE [Orders] SET [CustomerId] = ? WHERE [Id] = ?")
        // Two parameters: new value plus PK lookup.
        #expect(result?.first?.parameters == ["3", "2"])
    }

    @Test("UPDATE without primary key falls back to all-columns WHERE plus TOP (1)")
    func updateWithoutPrimaryKeyUsesAllColumns() {
        let driver = makeDriver()
        let columns = ["Number", "Amount"]
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(1, "Amount", "100.00", "150.00")],
            originalRow: ["INV-0001", "100.00"]
        )

        let result = driver.generateStatements(
            table: "Invoices",
            columns: columns,
            primaryKeyColumns: [],
            changes: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        let sql = result?.first?.statement ?? ""
        #expect(sql == "UPDATE TOP (1) [Invoices] SET [Amount] = ? WHERE [Number] = ? AND [Amount] = ?")
        #expect(result?.first?.parameters == ["150.00", "INV-0001", "100.00"])
    }

    @Test("UPDATE with composite primary key emits both PK columns in WHERE")
    func updateWithCompositePrimaryKey() {
        let driver = makeDriver()
        let columns = ["TenantId", "OrderId", "Status"]
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(2, "Status", "PENDING", "SHIPPED")],
            originalRow: ["T-1", "O-100", "PENDING"]
        )

        let result = driver.generateStatements(
            table: "Orders",
            columns: columns,
            primaryKeyColumns: ["TenantId", "OrderId"],
            changes: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        let sql = result?.first?.statement ?? ""
        #expect(sql == "UPDATE [Orders] SET [Status] = ? WHERE [TenantId] = ? AND [OrderId] = ?")
        #expect(result?.first?.parameters == ["SHIPPED", "T-1", "O-100"])
    }

    @Test("UPDATE with NULL original-row PK column emits IS NULL")
    func updateWithNullPKValueUsesIsNull() {
        let driver = makeDriver()
        let columns = ["Code", "Label"]
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(1, "Label", "old", "new")],
            originalRow: [nil, "old"]
        )

        let result = driver.generateStatements(
            table: "Tags",
            columns: columns,
            primaryKeyColumns: ["Code"],
            changes: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        let sql = result?.first?.statement ?? ""
        #expect(sql == "UPDATE [Tags] SET [Label] = ? WHERE [Code] IS NULL")
        #expect(result?.first?.parameters == ["new"])
    }

    @Test("Identifier with closing bracket is escaped as ]]")
    func identifierBracketEscaping() {
        let driver = makeDriver()
        let columns = ["weird]col", "Id"]
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(0, "weird]col", "a", "b")],
            originalRow: ["a", "1"]
        )

        let result = driver.generateStatements(
            table: "weird]table",
            columns: columns,
            primaryKeyColumns: ["Id"],
            changes: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        let sql = result?.first?.statement ?? ""
        #expect(sql.contains("[weird]]table]"))
        #expect(sql.contains("[weird]]col]"))
    }

    // MARK: - DELETE with PK

    @Test("DELETE with primary key uses PK-only WHERE and drops TOP (1)")
    func deleteWithPrimaryKeyUsesPKOnly() {
        let driver = makeDriver()
        let columns = ["Id", "CustomerId"]
        let change = PluginRowChange(
            rowIndex: 0,
            type: .delete,
            cellChanges: [],
            originalRow: ["2", "2"]
        )

        let result = driver.generateStatements(
            table: "Orders",
            columns: columns,
            primaryKeyColumns: ["Id"],
            changes: [change],
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        let sql = result?.first?.statement ?? ""
        #expect(sql == "DELETE FROM [Orders] WHERE [Id] = ?")
        #expect(result?.first?.parameters == ["2"])
    }

    @Test("DELETE without primary key uses all-columns WHERE plus TOP (1)")
    func deleteWithoutPrimaryKeyUsesAllColumns() {
        let driver = makeDriver()
        let columns = ["Number", "Amount"]
        let change = PluginRowChange(
            rowIndex: 0,
            type: .delete,
            cellChanges: [],
            originalRow: ["INV-0001", "100.00"]
        )

        let result = driver.generateStatements(
            table: "Invoices",
            columns: columns,
            primaryKeyColumns: [],
            changes: [change],
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        let sql = result?.first?.statement ?? ""
        #expect(sql == "DELETE TOP (1) FROM [Invoices] WHERE [Number] = ? AND [Amount] = ?")
        #expect(result?.first?.parameters == ["INV-0001", "100.00"])
    }

    // MARK: - INSERT skips IDENTITY columns

    @Test("INSERT skips IDENTITY columns when the cache has observed them")
    func insertSkipsIdentityColumn() {
        let driver = makeDriver()
        driver.setIdentityColumnsForTesting(["Id"], table: "Customers")

        let columns = ["Id", "Name", "City", "CreatedAt"]
        let insertChange = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )
        let insertedValues: [String?] = ["4", "Acme", "Hanoi", "2026-05-10 07:58:53.2840598"]

        let result = driver.generateStatements(
            table: "Customers",
            columns: columns,
            primaryKeyColumns: ["Id"],
            changes: [insertChange],
            insertedRowData: [0: insertedValues],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        let sql = result?.first?.statement ?? ""
        #expect(sql == "INSERT INTO [Customers] ([Name], [City], [CreatedAt]) VALUES (?, ?, ?)")
        #expect(result?.first?.parameters == ["Acme", "Hanoi", "2026-05-10 07:58:53.2840598"])
    }

    @Test("INSERT includes all columns when no IDENTITY columns are cached")
    func insertIncludesAllWithoutIdentityCache() {
        let driver = makeDriver()
        // Note: no setIdentityColumnsForTesting call; the cache is empty for this table.
        let columns = ["Number", "Amount"]
        let insertChange = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )
        let insertedValues: [String?] = ["INV-9999", "42.00"]

        let result = driver.generateStatements(
            table: "Invoices",
            columns: columns,
            primaryKeyColumns: [],
            changes: [insertChange],
            insertedRowData: [0: insertedValues],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        let sql = result?.first?.statement ?? ""
        #expect(sql == "INSERT INTO [Invoices] ([Number], [Amount]) VALUES (?, ?)")
        #expect(result?.first?.parameters == ["INV-9999", "42.00"])
    }

    @Test("INSERT skips multiple IDENTITY columns and the __DEFAULT__ sentinel")
    func insertSkipsIdentityAndDefaults() {
        let driver = makeDriver()
        driver.setIdentityColumnsForTesting(["Id", "RowVersion"], table: "Audit")

        let columns = ["Id", "RowVersion", "Action", "CreatedAt"]
        let insertChange = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )
        let insertedValues: [String?] = ["1", "X", "DELETE", "__DEFAULT__"]

        let result = driver.generateStatements(
            table: "Audit",
            columns: columns,
            primaryKeyColumns: ["Id"],
            changes: [insertChange],
            insertedRowData: [0: insertedValues],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        let sql = result?.first?.statement ?? ""
        #expect(sql == "INSERT INTO [Audit] ([Action]) VALUES (?)")
        #expect(result?.first?.parameters == ["DELETE"])
    }

    @Test("cachedIdentityColumns returns empty set for unobserved table")
    func cachedIdentityColumnsEmptyByDefault() {
        let driver = makeDriver()
        #expect(driver.cachedIdentityColumns(for: "NeverFetched") == [])
    }

    @Test("cachedIdentityColumns returns the seeded set after seeding")
    func cachedIdentityColumnsRoundTrip() {
        let driver = makeDriver()
        driver.setIdentityColumnsForTesting(["Id", "Version"], table: "T")
        #expect(driver.cachedIdentityColumns(for: "T") == ["Id", "Version"])
    }
}
