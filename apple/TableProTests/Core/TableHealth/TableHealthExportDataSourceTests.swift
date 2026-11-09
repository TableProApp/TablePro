import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct TableHealthExportDataSourceTests {
    private static let epoch = Date(timeIntervalSince1970: 0)

    private static func missingKeyRow(status: TableHealthRowStatus = .new) -> TableHealthFindingRow {
        let finding = TableHealthFinding(
            kind: .missingPrimaryKey,
            schema: "public",
            table: "logs",
            objectName: nil,
            detail: "No primary key.",
            sizeBytes: 1_048_576,
            metrics: [TableHealthMetric.estimatedRows(42)],
            fixSQL: "ALTER TABLE \"public\".\"logs\" ADD PRIMARY KEY (column_name);"
        )
        return TableHealthFindingRow(
            finding: finding,
            checkTitle: "Tables Without a Primary Key",
            checkOrder: 1,
            status: status,
            firstSeen: epoch,
            lastSeen: Date(timeIntervalSince1970: 86_400 + 3_661)
        )
    }

    private static func bloatRow() -> TableHealthFindingRow {
        let finding = TableHealthFinding(
            kind: .bloat,
            schema: "public",
            table: "events",
            objectName: nil,
            detail: "Dead rows.",
            metrics: [
                TableHealthMetric(id: "dead_percent", label: "Dead", value: .percent(0.25)),
                TableHealthMetric(id: "last_vacuum", label: "Last Vacuum", value: .date(epoch)),
                TableHealthMetric(id: "next_value", label: "Next Value", value: .bigCount(UInt64.max)),
                TableHealthMetric(id: "cycles", label: "Cycles", value: .flag(true)),
                TableHealthMetric(id: "column_type", label: "Type", value: .text("int")),
                TableHealthMetric(id: "ratio", label: "Ratio", value: .percent(.nan)),
            ],
            fixSQL: nil
        )
        return TableHealthFindingRow(
            finding: finding,
            checkTitle: "Bloated Tables",
            checkOrder: 0,
            status: .seen,
            firstSeen: nil,
            lastSeen: nil
        )
    }

    private static func stream(_ source: TableHealthExportDataSource) async throws -> (PluginStreamHeader?, [PluginRow]) {
        var header: PluginStreamHeader?
        var rows: [PluginRow] = []
        for try await element in source.streamRows(table: "findings", databaseName: "") {
            switch element {
            case .header(let first): header = first
            case .rows(let batch): rows.append(contentsOf: batch)
            }
        }
        return (header, rows)
    }

    @Test("Columns are the fixed set, then one per metric id in the order the checks run, each typed")
    func typedColumnsInCheckOrder() async throws {
        let source = TableHealthExportDataSource(database: "shop", rows: [Self.missingKeyRow(), Self.bloatRow()])

        let (header, rows) = try await Self.stream(source)

        let fixed = ["database", "check", "schema", "table", "object", "status", "size_bytes", "detail",
                     "first_seen", "last_seen", "fix_sql"]
        let metrics = ["dead_percent", "last_vacuum", "next_value", "cycles", "column_type", "ratio", "estimated_rows"]
        #expect(header?.columns == fixed + metrics)
        #expect(header?.columnTypeNames == [
            "varchar", "varchar", "varchar", "varchar", "varchar", "varchar", "bigint", "varchar",
            "timestamp", "timestamp", "varchar",
            "double", "timestamp", "decimal(20,0)", "boolean", "varchar", "double", "bigint",
        ])
        #expect(header?.estimatedRowCount == 2)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.count == fixed.count + metrics.count })
    }

    @Test("Cells are machine formatted: POSIX numbers, UTC timestamps, null for what is missing")
    func machineFormattedCells() async throws {
        let source = TableHealthExportDataSource(database: "shop", rows: [Self.missingKeyRow(), Self.bloatRow()])

        let (header, rows) = try await Self.stream(source)
        let columns = try #require(header?.columns)
        func cell(_ row: Int, _ name: String) throws -> PluginCellValue {
            let index = try #require(columns.firstIndex(of: name))
            return rows[row][index]
        }

        #expect(try cell(0, "database") == .text("shop"))
        #expect(try cell(0, "check") == .text("Tables Without a Primary Key"))
        #expect(try cell(0, "object") == .null)
        #expect(try cell(0, "status") == .text("new"))
        #expect(try cell(0, "size_bytes") == .text("1048576"))
        #expect(try cell(0, "first_seen") == .text("1970-01-01 00:00:00"))
        #expect(try cell(0, "last_seen") == .text("1970-01-02 01:01:01"))
        #expect(try cell(0, "estimated_rows") == .text("42"))
        #expect(try cell(0, "dead_percent") == .null)

        #expect(try cell(1, "status") == .null)
        #expect(try cell(1, "size_bytes") == .null)
        #expect(try cell(1, "fix_sql") == .null)
        #expect(try cell(1, "dead_percent") == .text("0.25"))
        #expect(try cell(1, "last_vacuum") == .text("1970-01-01 00:00:00"))
        #expect(try cell(1, "next_value") == .text("18446744073709551615"))
        #expect(try cell(1, "cycles") == .text("true"))
        #expect(try cell(1, "ratio") == .null)
    }

    // The SQL export writes a value bare when its column type reads as numeric and the value parses as a number.
    @Test("Every numeric cell is one the SQL export can write unquoted, and text columns stay quoted")
    func numericCellsSurviveTheSQLExport() async throws {
        let source = TableHealthExportDataSource(database: "shop", rows: [Self.missingKeyRow(), Self.bloatRow()])

        let (header, rows) = try await Self.stream(source)
        let types = try #require(header?.columnTypeNames)

        for (index, type) in types.enumerated() where PluginExportUtilities.isNumericColumnType(type) {
            for row in rows {
                if case .text(let value) = row[index] {
                    #expect(PluginNumericLiteral.isValid(value), "\(value) in a \(type) column")
                }
            }
        }
        #expect(!PluginExportUtilities.isNumericColumnType("varchar"))
        #expect(!PluginExportUtilities.isNumericColumnType("timestamp"))
        #expect(PluginExportUtilities.isNumericColumnType("decimal(20,0)"))
    }

    @Test("Parquet reads the same column types from fetchColumns as the header carries")
    func fetchColumnsMatchesTheHeader() async throws {
        let source = TableHealthExportDataSource(database: "shop", rows: [Self.missingKeyRow(), Self.bloatRow()])

        let (header, _) = try await Self.stream(source)
        let columns = try await source.fetchColumns(table: "anything", databaseName: "anywhere")

        #expect(columns.map { $0.name } == header?.columns)
        #expect(columns.map { $0.typeNameForClassification } == header?.columnTypeNames)
    }

    @Test("The source counts its rows, writes no DDL and runs no query")
    func noQueriesNoDDL() async throws {
        let source = TableHealthExportDataSource(database: "shop", rows: [Self.missingKeyRow()])

        #expect(source.databaseTypeId == DataSourceExportRequest.dataFileTypeId)
        #expect(try await source.fetchApproximateRowCount(table: "", databaseName: "") == 1)
        #expect(try await source.fetchTableDDL(table: "", databaseName: "").isEmpty)
        await #expect(throws: (any Error).self) {
            _ = try await source.execute(query: "SELECT 1")
        }
    }

    @Test("Copy keeps one line per row when a field holds tabs or line breaks")
    func copyFlattensFields() {
        let finding = TableHealthFinding(
            kind: .missingPrimaryKey,
            schema: "public",
            table: "x\tDROP\nTABLE",
            objectName: nil,
            detail: "line one\r\nline two",
            fixSQL: nil
        )
        let row = TableHealthFindingRow(
            finding: finding,
            checkTitle: "Tables Without a Primary Key",
            checkOrder: 0,
            status: .seen,
            firstSeen: nil,
            lastSeen: nil
        )

        let text = TableHealthTSV.text([row], columns: TableHealthColumn.findings)
        let lines = text.components(separatedBy: "\n")

        #expect(lines.count == 2)
        #expect(lines[1].components(separatedBy: "\t").count == TableHealthColumn.findings.count)
    }
}
