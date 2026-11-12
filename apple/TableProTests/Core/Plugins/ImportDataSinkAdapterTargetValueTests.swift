//
//  ImportDataSinkAdapterTargetValueTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private struct WrittenStatement {
    let sql: String
    let parameters: [PluginCellValue]
}

private final class TypedTableDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private let columns: [PluginColumnInfo]
    private var written: [WrittenStatement] = []

    init(columns: [(String, String)], generated: Set<String> = []) {
        self.columns = columns.map { PluginColumnInfo(name: $0.0, dataType: $0.1, isGenerated: generated.contains($0.0)) }
    }

    var statements: [WrittenStatement] { lock.withLock { written } }

    func quoteIdentifier(_ name: String) -> String { "\"\(name)\"" }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { columns }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        lock.withLock { written.append(WrittenStatement(sql: query, parameters: parameters)) }
        return .empty
    }
}

// A file holds text; what it stands for depends on the column it lands in.
struct ImportDataSinkAdapterTargetValueTests {
    private func sink(
        _ driver: TypedTableDriver,
        type: DatabaseType,
        mapping: [String],
        binaryText: ImportBinaryText? = nil,
        rowWriting: ImportRowWriting = .insert
    ) -> ImportDataSinkAdapter {
        ImportDataSinkAdapter(
            driver: PluginDriverAdapter(connection: TestFixtures.makeConnection(type: type), pluginDriver: driver),
            databaseType: type,
            targetTable: "t",
            columnMapping: Dictionary(uniqueKeysWithValues: mapping.map { ($0, $0) }),
            sourceFields: Set(mapping),
            rowWriting: rowWriting,
            binaryText: binaryText
        )
    }

    @Test("CSV and XLSX hex lands in a binary column as its bytes, and only there")
    func prefixedHexBecomesBytes() async throws {
        let driver = TypedTableDriver(columns: [("payload", "bytea"), ("note", "text")])
        let target = sink(driver, type: .postgresql, mapping: ["payload", "note"], binaryText: .prefixedHex)

        try await target.insertRows([
            ["payload": .text("0x89504E47"), "note": .text("0x41")],
            ["payload": .text("0x"), "note": .text("x")],
            ["payload": .text("plain"), "note": .text("y")],
        ])

        let parameters = try #require(driver.statements.first).parameters
        #expect(parameters == [
            .text("0x41"), .bytes(Data([0x89, 0x50, 0x4E, 0x47])),
            .text("x"), .bytes(Data()),
            .text("y"), .text("plain"),
        ])
    }

    @Test("Hex cut short fails the row and names the column")
    func brokenHexFailsTheRow() async throws {
        let driver = TypedTableDriver(columns: [("payload", "blob")])
        let target = sink(driver, type: .mysql, mapping: ["payload"], binaryText: .prefixedHex)

        let error = await #expect(throws: PluginImportError.self) {
            try await target.insertRow(["payload": .text("0x41…")])
        }
        #expect(error?.localizedDescription.contains("payload") == true)
        #expect(driver.statements.isEmpty)
    }

    @Test("JSON's base64 lands in a binary column as its bytes, and other text stays text")
    func base64BecomesBytes() async throws {
        let driver = TypedTableDriver(columns: [("payload", "bytea")])
        let target = sink(driver, type: .postgresql, mapping: ["payload"], binaryText: .base64)

        try await target.insertRow(["payload": .text(Data([0x00, 0xFF]).base64EncodedString())])
        try await target.insertRow(["payload": .text("hello world")])
        try await target.insertRow(["payload": .text("\\x4142")])

        #expect(driver.statements.map { $0.parameters } == [
            [.bytes(Data([0x00, 0xFF]))], [.text("hello world")], [.text("\\x4142")],
        ])
    }

    @Test("A format with no binary spelling, and rows in column order, keep the text")
    func noBinaryTextKeepsText() async throws {
        let driver = TypedTableDriver(columns: [("payload", "bytea")])

        try await sink(driver, type: .postgresql, mapping: ["payload"]).insertRow(["payload": .text("0x41")])
        try await sink(driver, type: .postgresql, mapping: ["payload"], binaryText: .prefixedHex)
            .insertRows(columns: ["payload"], values: [[.text("0x41")]])

        #expect(driver.statements.map { $0.parameters } == [[.text("0x41")], [.text("0x41")]])
    }

    @Test(
        "A boolean word becomes 1 or 0 where the engine writes booleans as numbers",
        arguments: [
            (DatabaseType.mysql, "tinyint(1)"),
            (DatabaseType.mssql, "bit"),
            (DatabaseType.sqlite, "BOOLEAN"),
        ]
    )
    func booleanWordsBecomeDigits(type: DatabaseType, column: String) async throws {
        let driver = TypedTableDriver(columns: [("active", column), ("label", "varchar(10)")])
        let target = sink(driver, type: type, mapping: ["active", "label"])

        try await target.insertRows(["true", "No", "T", "y", "1", " off ", "maybe"].map { word in
            ["active": .text(word), "label": .text(word)]
        })

        let parameters = try #require(driver.statements.first).parameters
        let active = stride(from: 0, to: parameters.count, by: 2).map { parameters[$0] }
        let labels = stride(from: 1, to: parameters.count, by: 2).map { parameters[$0] }
        #expect(active == ["1", "0", "1", "1", "1", "0", "maybe"])
        #expect(labels == ["true", "No", "T", "y", "1", " off ", "maybe"])
    }

    @Test("An engine that reads TRUE and FALSE gets the file's own words")
    func trueFalseEngineKeepsWords() async throws {
        let driver = TypedTableDriver(columns: [("active", "boolean")])

        try await sink(driver, type: .postgresql, mapping: ["active"]).insertRow(["active": .text("yes")])

        #expect(driver.statements.first?.parameters == [.text("yes")])
    }

    @Test("A row with no field is written as a row of defaults and counted")
    func emptyRowIsARowOfDefaults() async throws {
        let driver = TypedTableDriver(columns: [("id", "serial"), ("note", "text")])
        let target = sink(driver, type: .postgresql, mapping: ["note"])

        try await target.insertRows([["note": .text("a")], [:], [:]])
        try await target.insertRow([:])

        #expect(driver.statements.map { $0.sql } == [
            "INSERT INTO \"t\" (\"note\") VALUES ($1)",
            "INSERT INTO \"t\" DEFAULT VALUES",
            "INSERT INTO \"t\" DEFAULT VALUES",
            "INSERT INTO \"t\" DEFAULT VALUES",
        ])
        #expect(target.rowTally.inserted == 4)
    }

    @Test("Oracle's row of defaults names the first column that is not virtual")
    func oracleDefaultsNameAColumn() async throws {
        let driver = TypedTableDriver(columns: [("FULL_NAME", "VARCHAR2(41)"), ("ID", "NUMBER(19)")], generated: ["FULL_NAME"])

        try await sink(driver, type: .oracle, mapping: ["ID"]).insertRow([:])

        #expect(driver.statements.map { $0.sql } == ["INSERT INTO \"t\" (\"ID\") VALUES (DEFAULT)"])
    }

    @Test("An engine with no INSERT for a row of defaults fails the row and says why")
    func noDefaultsInsertSaysWhy() async throws {
        let driver = TypedTableDriver(columns: [("id", "UInt64")])

        let error = await #expect(throws: PluginImportError.self) {
            try await sink(driver, type: .clickhouse, mapping: ["id"]).insertRow([:])
        }
        #expect(error?.localizedDescription.contains("row of only defaults") == true)
    }

    @Test("A row with no field cannot be matched to an existing row")
    func emptyRowHasNoKeyToMatch() async throws {
        let driver = TypedTableDriver(columns: [("id", "int"), ("note", "text")])
        let target = sink(
            driver, type: .postgresql, mapping: ["id", "note"],
            rowWriting: ImportRowWriting(mode: .upsert, keyColumns: ["id"])
        )

        await #expect(throws: PluginImportError.self) {
            try await target.insertRows([[:]])
        }
        #expect(driver.statements.isEmpty)
    }
}

struct ImportBinaryTextTests {
    @Test("Each format reads bytes back the way its export wrote them")
    func formatIds() {
        #expect(ImportBinaryText(formatId: "csv") == .prefixedHex)
        #expect(ImportBinaryText(formatId: "xlsx") == .prefixedHex)
        #expect(ImportBinaryText(formatId: "json") == .base64)
        #expect(ImportBinaryText(formatId: "sql") == nil)
    }
}
