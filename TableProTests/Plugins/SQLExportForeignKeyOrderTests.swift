//
//  SQLExportForeignKeyOrderTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("SQL export foreign key ordering")
struct SQLExportForeignKeyOrderTests {
    private final class StubExportDataSource: PluginExportDataSource, @unchecked Sendable {
        let databaseTypeId: String
        let tableDDLIncludesForeignKeys: Bool
        let foreignKeys: [String: [PluginForeignKeyInfo]]
        let ddlByTable: [String: String]

        init(
            databaseTypeId: String,
            tableDDLIncludesForeignKeys: Bool,
            foreignKeys: [String: [PluginForeignKeyInfo]] = [:],
            ddlByTable: [String: String] = [:]
        ) {
            self.databaseTypeId = databaseTypeId
            self.tableDDLIncludesForeignKeys = tableDDLIncludesForeignKeys
            self.foreignKeys = foreignKeys
            self.ddlByTable = ddlByTable
        }

        func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.header(PluginStreamHeader(columns: ["id"], columnTypeNames: ["INTEGER"])))
                continuation.yield(.rows([[.text("1")]]))
                continuation.finish()
            }
        }

        func fetchTableDDL(table: String, databaseName: String) async throws -> String {
            ddlByTable[table] ?? "CREATE TABLE \(table) (id INTEGER)"
        }

        func execute(query: String) async throws -> PluginQueryResult {
            PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
        }

        func quoteIdentifier(_ identifier: String) -> String {
            "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
        }

        func escapeStringLiteral(_ value: String) -> String {
            value.replacingOccurrences(of: "'", with: "''")
        }

        func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }

        func fetchAllForeignKeys(databaseName: String) async throws -> [String: [PluginForeignKeyInfo]] {
            foreignKeys
        }
    }

    private func table(_ name: String) -> PluginExportTable {
        PluginExportTable(name: name, databaseName: "", tableType: "table", optionValues: [true, true, true], schema: nil)
    }

    private func foreignKey(_ name: String, from column: String, to referencedTable: String) -> PluginForeignKeyInfo {
        PluginForeignKeyInfo(
            name: name,
            column: column,
            referencedTable: referencedTable,
            referencedColumn: "id"
        )
    }

    private func runExport(
        tables: [PluginExportTable],
        dataSource: StubExportDataSource
    ) async throws -> (dump: String, result: ExportFormatResult) {
        let output = try await SQLExportHarness.shared.dump(tables: tables, dataSource: dataSource)
        return (output.text, output.result)
    }

    private func createOrder(in dump: String, of tables: [String]) -> [String] {
        tables
            .compactMap { name -> (String, Int)? in
                guard let range = dump.range(of: "-- Table: \(name)\n") else { return nil }
                return (name, dump.distance(from: dump.startIndex, to: range.lowerBound))
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    @Test("A parent's CREATE precedes its child's however the tree listed them")
    func parentIsCreatedBeforeChild() async throws {
        let source = StubExportDataSource(
            databaseTypeId: "PostgreSQL",
            tableDDLIncludesForeignKeys: false,
            foreignKeys: ["orders": [foreignKey("fk_orders_customer", from: "customer_id", to: "customers")]]
        )

        let (dump, _) = try await runExport(tables: [table("orders"), table("customers")], dataSource: source)

        #expect(createOrder(in: dump, of: ["orders", "customers"]) == ["customers", "orders"])
    }

    @Test("A child is dropped before the parent it references")
    func childIsDroppedBeforeParent() async throws {
        let source = StubExportDataSource(
            databaseTypeId: "PostgreSQL",
            tableDDLIncludesForeignKeys: false,
            foreignKeys: ["orders": [foreignKey("fk_orders_customer", from: "customer_id", to: "customers")]]
        )

        let (dump, _) = try await runExport(tables: [table("customers"), table("orders")], dataSource: source)

        let dropOrders = try #require(dump.range(of: "DROP TABLE IF EXISTS \"orders\""))
        let dropCustomers = try #require(dump.range(of: "DROP TABLE IF EXISTS \"customers\""))
        #expect(dropOrders.lowerBound < dropCustomers.lowerBound)
    }

    @Test("A dependency cycle is reported in the warnings and in the dump")
    func cycleIsReported() async throws {
        let source = StubExportDataSource(
            databaseTypeId: "PostgreSQL",
            tableDDLIncludesForeignKeys: false,
            foreignKeys: [
                "orders": [foreignKey("fk_orders_customer", from: "customer_id", to: "customers")],
                "customers": [foreignKey("fk_customers_order", from: "last_order_id", to: "orders")]
            ]
        )

        let (dump, result) = try await runExport(tables: [table("orders"), table("customers")], dataSource: source)

        #expect(result.warnings.contains { $0.contains("orders") && $0.contains("customers") })
        #expect(dump.contains("-- Warning: orders, customers reference each other."))
    }

    @Test("A cycle keeps the tables in the order the export listed them")
    func cycleFallsBackToTheGivenOrder() async throws {
        let source = StubExportDataSource(
            databaseTypeId: "PostgreSQL",
            tableDDLIncludesForeignKeys: false,
            foreignKeys: [
                "orders": [foreignKey("fk_orders_customer", from: "customer_id", to: "customers")],
                "customers": [foreignKey("fk_customers_order", from: "last_order_id", to: "orders")]
            ]
        )

        let (dump, _) = try await runExport(tables: [table("orders"), table("customers")], dataSource: source)

        #expect(createOrder(in: dump, of: ["orders", "customers"]) == ["orders", "customers"])
    }

    @Test("An acyclic export reports no warnings")
    func acyclicExportIsSilent() async throws {
        let source = StubExportDataSource(
            databaseTypeId: "PostgreSQL",
            tableDDLIncludesForeignKeys: false,
            foreignKeys: ["orders": [foreignKey("fk_orders_customer", from: "customer_id", to: "customers")]]
        )

        let (dump, result) = try await runExport(tables: [table("orders"), table("customers")], dataSource: source)

        #expect(result.warnings.isEmpty)
        #expect(!dump.contains("-- Warning:"))
    }

    @Test("A table that only descends from a cycle is not reported as part of it")
    func descendantOfACycleIsNotReportedAsACycleMember() async throws {
        let source = StubExportDataSource(
            databaseTypeId: "PostgreSQL",
            tableDDLIncludesForeignKeys: false,
            foreignKeys: [
                "orders": [foreignKey("fk_orders_customer", from: "customer_id", to: "customers")],
                "customers": [foreignKey("fk_customers_order", from: "last_order_id", to: "orders")],
                "audit": [foreignKey("fk_audit_order", from: "order_id", to: "orders")]
            ]
        )

        let (dump, result) = try await runExport(
            tables: [table("audit"), table("orders"), table("customers")], dataSource: source)

        #expect(result.warnings.contains { $0.contains("orders") && !$0.contains("audit") })
        #expect(createOrder(in: dump, of: ["audit", "orders", "customers"]).last == "audit")
    }

    @Test("A driver whose DDL omits foreign keys gets them back as ALTER TABLE")
    func deferredForeignKeysAreAdded() async throws {
        let source = StubExportDataSource(
            databaseTypeId: "PostgreSQL",
            tableDDLIncludesForeignKeys: false,
            foreignKeys: ["orders": [foreignKey("fk_orders_customer", from: "customer_id", to: "customers")]]
        )

        let (dump, _) = try await runExport(tables: [table("orders"), table("customers")], dataSource: source)

        #expect(dump.contains(
            "ALTER TABLE \"orders\" ADD CONSTRAINT \"fk_orders_customer\" "
                + "FOREIGN KEY (\"customer_id\") REFERENCES \"customers\" (\"id\");"))
    }

    @Test("A driver whose DDL carries foreign keys does not declare them a second time")
    func inlineForeignKeysAreNotDuplicated() async throws {
        let source = StubExportDataSource(
            databaseTypeId: "SQLite",
            tableDDLIncludesForeignKeys: true,
            foreignKeys: ["orders": [foreignKey("fk_orders_0", from: "customer_id", to: "customers")]],
            ddlByTable: [
                "orders": "CREATE TABLE orders (id INTEGER, customer_id INTEGER REFERENCES customers(id))"
            ]
        )

        let (dump, _) = try await runExport(tables: [table("orders"), table("customers")], dataSource: source)

        #expect(!dump.contains("ADD CONSTRAINT"))
        #expect(dump.contains("REFERENCES customers(id)"))
    }
}
