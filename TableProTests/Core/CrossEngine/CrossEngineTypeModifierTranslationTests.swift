//
//  CrossEngineTypeModifierTranslationTests.swift
//  TableProTests
//
//  A PostgreSQL column carries its length, precision and fractional seconds into another engine,
//  and a table that keeps them still fits the target's row limits.
//

@testable import TablePro
import XCTest

final class CrossEngineTypeModifierTranslationTests: XCTestCase {
    private func column(
        _ name: String,
        _ dataType: String,
        catalog: String? = nil,
        nullable: Bool = true,
        isPrimaryKey: Bool = false
    ) -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: UUID(),
            name: name,
            dataType: dataType,
            isNullable: nullable,
            defaultValue: nil,
            autoIncrement: false,
            unsigned: false,
            comment: nil,
            collation: nil,
            onUpdate: nil,
            charset: nil,
            extra: nil,
            isPrimaryKey: isPrimaryKey,
            ddlSpelling: catalog
        )
    }

    private func varchar(_ name: String, _ length: Int, isPrimaryKey: Bool = false) -> EditableColumnDefinition {
        column(
            name, "CHARACTER VARYING", catalog: "character varying(\(length))",
            nullable: !isPrimaryKey, isPrimaryKey: isPrimaryKey
        )
    }

    private func index(_ name: String, _ columns: [String]) -> EditableIndexDefinition {
        EditableIndexDefinition(
            id: UUID(), name: name, columns: columns, type: .btree, isUnique: false, isPrimary: false,
            comment: nil, columnPrefixes: [:], whereClause: nil
        )
    }

    private func foreignKey(_ columns: [String]) -> EditableForeignKeyDefinition {
        EditableForeignKeyDefinition(
            id: UUID(), name: "fk_\(columns.joined(separator: "_"))", columns: columns, referencedTable: "parent",
            referencedColumns: columns, referencedSchema: nil, onDelete: .noAction, onUpdate: .noAction
        )
    }

    private func translate(
        _ columns: [EditableColumnDefinition],
        indexes: [EditableIndexDefinition] = [],
        foreignKeys: [EditableForeignKeyDefinition] = [],
        to target: DatabaseType = .mysql,
        serverVersion: String? = nil
    ) -> CrossEngineStructureTranslator.Result {
        CrossEngineStructureTranslator.translate(
            TableStructureSnapshot(
                name: "orders", schema: "public", columns: columns, indexes: indexes, foreignKeys: foreignKeys
            ),
            from: .postgresql,
            to: target,
            targetServerVersion: serverVersion
        )
    }

    private func dataType(_ result: CrossEngineStructureTranslator.Result, _ name: String) -> String? {
        result.snapshot.columns.first { $0.name == name }?.dataType
    }

    private var bigintKey: EditableColumnDefinition {
        column("id", "BIGINT", catalog: "bigint", nullable: false, isPrimaryKey: true)
    }

    // MARK: - Modifiers

    func testTheCatalogSpellingsModifiersReachMySQL() {
        let result = translate([
            column("amount", "NUMERIC", catalog: "numeric(10,2)"),
            varchar("code", 50),
            column("made", "TIMESTAMP WITH TIME ZONE", catalog: "timestamp(3) with time zone"),
            column("flags", "BIT", catalog: "bit(8)")
        ])
        XCTAssertEqual(result.snapshot.columns.map(\.dataType), ["DECIMAL(10, 2)", "VARCHAR(50)", "DATETIME(3)", "BIT(8)"])
        XCTAssertFalse(result.notes.contains { $0.subject == "amount" || $0.subject == "code" || $0.subject == "flags" })
        XCTAssertTrue(result.notes.contains { $0.summary == "made: timestamp(3) with time zone → DATETIME(3)" })
        XCTAssertEqual(result.sourceKinds["amount"], .decimal(precision: 10, scale: 2))
    }

    /// A qualified spelling names nothing any family reads, so each column keeps the reading its
    /// display spelling gave it.
    func testAQualifiedCatalogSpellingKeepsTheColumnsClassification() {
        let result = translate(
            [
                column("shape", "geometry", catalog: "public.geometry(Point,4326)"),
                column("email", "citext", catalog: "public.citext", nullable: false, isPrimaryKey: true),
                column("mood", "ENUM", catalog: "public.mood")
            ],
            indexes: [index("shape_idx", ["shape"])]
        )
        XCTAssertEqual(result.snapshot.columns.map(\.dataType), ["LONGTEXT", "VARCHAR(255)", "LONGTEXT"])
        XCTAssertEqual(result.sourceKinds["shape"], .spatial)
        XCTAssertEqual(result.snapshot.indexes.first?.columnPrefixes["shape"], 255)
    }

    func testAnUnconstrainedNumericIsApproximatedAtMySQLsWidest() {
        let result = translate([column("total", "NUMERIC", catalog: "numeric")])
        XCTAssertEqual(dataType(result, "total"), "DECIMAL(65, 30)")
        XCTAssertTrue(result.notes.contains { $0.subject == "total" && $0.isLossy })
    }

    /// PostgreSQL 15 takes a scale below zero and above the precision, and MySQL takes neither
    /// spelling. `numeric(5,-2)` holds whole hundreds and `numeric(3,5)` fractions under 0.01.
    func testANumericScaleMySQLCannotSpellKeepsItsDigits() {
        let result = translate([
            column("rounded", "NUMERIC", catalog: "numeric(5,-2)"),
            column("tiny", "NUMERIC", catalog: "numeric(3,5)"),
            column("fine", "NUMERIC", catalog: "numeric(40,35)")
        ])
        XCTAssertEqual(result.snapshot.columns.map(\.dataType), ["DECIMAL(7, 0)", "DECIMAL(5, 5)", "DECIMAL(35, 30)"])
        XCTAssertTrue(result.notes.contains { $0.subject == "rounded" && $0.fidelity == .widened })
        XCTAssertTrue(result.notes.contains { $0.subject == "tiny" && $0.fidelity == .widened })
        XCTAssertTrue(result.notes.contains { $0.subject == "fine" && $0.isLossy })
    }

    /// Oracle reports an `INTEGER` as a bare `number`, which keeps the exact rendering it always had.
    func testABareOracleNumberCrossesAsItAlwaysDid() {
        let source = TableStructureSnapshot(name: "t", columns: [column("id", "number")])
        let toMySQL = CrossEngineStructureTranslator.translate(source, from: .oracle, to: .mysql)
        XCTAssertEqual(dataType(toMySQL, "id"), "DECIMAL(38)")
        XCTAssertTrue(toMySQL.notes.isEmpty)
        let toSQLServer = CrossEngineStructureTranslator.translate(source, from: .oracle, to: .mssql)
        XCTAssertEqual(dataType(toSQLServer, "id"), "DECIMAL(38)")
    }

    func testAppendingIntoATableReadsItsCatalogSpelling() {
        let existing = TableStructureSnapshot(name: "t", columns: [
            column("amount", "NUMERIC", catalog: "numeric(10,2)"),
            column("code", "character varying(20)")
        ])
        let kinds = CrossEngineStructureTranslator.kinds(of: existing, family: .postgres)
        XCTAssertEqual(kinds["amount"], .decimal(precision: 10, scale: 2))
        XCTAssertEqual(kinds["code"], .text(length: 20, isFixed: false))
    }

    // MARK: - MySQL rows

    /// Seventeen `VARCHAR(1000)` columns are 68,034 bytes, over the 65,535 a row may take on both
    /// servers, and one of them stored as `TEXT` brings the table under it.
    func testATableOverMySQLsRowLimitMovesItsWidestColumnOutOfTheRow() {
        let wide = (0..<17).map { varchar("c\($0)", 1_000) }
        let result = translate([bigintKey] + wide)
        let moved = result.snapshot.columns.filter { $0.dataType == "TEXT" }.map(\.name)
        XCTAssertEqual(moved, ["c0"])
        XCTAssertTrue(result.notes.contains { $0.subject == "c0" && $0.fidelity == .widened })
        XCTAssertEqual(result.targetKinds["c0"], .text(length: nil, isFixed: false))
    }

    /// MariaDB refused a `BIGINT` key with 41 `VARCHAR(50)` columns and created it with 40. The
    /// column an index covers is left whole while another can move.
    func testATableOverMariaDBsRecordLimitMovesAnUnindexedColumn() {
        let fits = translate([bigintKey] + (0..<40).map { varchar("c\($0)", 50) }, to: .mariadb)
        XCTAssertFalse(fits.snapshot.columns.contains { $0.dataType == "TEXT" })

        let over = translate(
            [bigintKey] + (0..<41).map { varchar("c\($0)", 50) },
            indexes: [index("c0_idx", ["c0"])],
            to: .mariadb
        )
        let moved = over.snapshot.columns.filter { $0.dataType == "TEXT" }.map(\.name)
        XCTAssertEqual(moved, ["c1"])
        XCTAssertEqual(over.snapshot.indexes.first?.columnPrefixes, [:])
    }

    /// MySQL 8.4 created the same 41 columns as declared, because it counts each as 41 bytes of the
    /// record rather than 201. A MySQL connection to a MariaDB server is read by its banner.
    func testMySQLKeepsAColumnMariaDBWouldMove() {
        let columns = [bigintKey] + (0..<41).map { varchar("c\($0)", 50) }
        XCTAssertFalse(translate(columns).snapshot.columns.contains { $0.dataType == "TEXT" })
        XCTAssertFalse(
            translate(columns, serverVersion: "8.4.11").snapshot.columns.contains { $0.dataType == "TEXT" }
        )
        XCTAssertTrue(
            translate(columns, serverVersion: "12.3.3-MariaDB").snapshot.columns.contains { $0.dataType == "TEXT" }
        )
    }

    /// A `BINARY(255)` is counted whole on both servers. Forty of them beside a `BIGINT` key were
    /// refused by MySQL 8.4; with 31 kept and 9 as `BLOB` MySQL still refused, and MariaDB created it.
    func testMySQLMovesTheColumnsItsOwnRecordCountsWhole() {
        let columns = [column("id", "BIGINT", nullable: false, isPrimaryKey: true)]
            + (0..<40).map { column("b\($0)", "BINARY(255)") }
        let source = TableStructureSnapshot(name: "blobs", columns: columns)
        let moved = { (serverVersion: String) in
            CrossEngineStructureTranslator.translate(source, from: .mssql, to: .mysql, targetServerVersion: serverVersion)
                .snapshot.columns.filter { $0.dataType == "BLOB" }.count
        }
        XCTAssertEqual(moved("8.4.11"), 10)
        XCTAssertEqual(moved("12.3.3-MariaDB"), 9)
    }

    /// A foreign key column cannot be a `TEXT`: MySQL refuses it with ERROR 1170 and MariaDB with
    /// errno 150. MariaDB refused this table as declared and created it with three `VARCHAR(50)`
    /// columns as `TEXT`, while `pcode` would have saved the most bytes on its own.
    func testAForeignKeyColumnNeverMovesOutOfTheRow() {
        let result = translate(
            [bigintKey] + (0..<41).map { varchar("c\($0)", 50) } + [varchar("pcode", 60)],
            foreignKeys: [foreignKey(["pcode"])],
            to: .mariadb
        )
        XCTAssertEqual(dataType(result, "pcode"), "VARCHAR(60)")
        XCTAssertEqual(result.snapshot.columns.filter { $0.dataType == "TEXT" }.count, 3)
    }

    func testOnlyMySQLMovesColumnsOutOfTheRow() {
        let wide = (0..<17).map { varchar("c\($0)", 1_000) }
        let result = translate(wide, to: .duckdb)
        XCTAssertFalse(result.snapshot.columns.contains { $0.dataType == "TEXT" })
    }

    // MARK: - SQL Server lengths

    /// One note for the table naming every column that kept its length, rather than one per column.
    func testSQLServerNamesTheColumnsWhoseLengthCountsUTF16Units() {
        let result = translate([varchar("name", 50), varchar("code", 10), column("body", "text")], to: .mssql)
        XCTAssertEqual(dataType(result, "name"), "NVARCHAR(50)")
        let lengthNotes = result.notes.filter { $0.subject.isEmpty }
        XCTAssertEqual(lengthNotes.count, 1)
        XCTAssertEqual(lengthNotes.first?.summary.contains("name, code"), true)
        XCTAssertEqual(lengthNotes.first?.summary.contains("body"), false)

        XCTAssertFalse(translate([varchar("name", 50)]).notes.contains { $0.subject.isEmpty })
    }
}
