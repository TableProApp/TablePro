//
//  CrossEngineTypeModifierTranslationTests.swift
//  TableProTests
//
//  A PostgreSQL column carries its length, precision and fractional seconds into another engine,
//  and a table that keeps them still fits the target's key and row limits.
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

    private func index(_ name: String, _ columns: [String], unique: Bool = false) -> EditableIndexDefinition {
        EditableIndexDefinition(
            id: UUID(), name: name, columns: columns, type: .btree, isUnique: unique, isPrimary: false,
            comment: nil, columnPrefixes: [:], whereClause: nil
        )
    }

    private func translate(
        _ columns: [EditableColumnDefinition],
        indexes: [EditableIndexDefinition] = [],
        to target: DatabaseType = .mysql
    ) -> CrossEngineStructureTranslator.Result {
        CrossEngineStructureTranslator.translate(
            TableStructureSnapshot(name: "orders", schema: "public", columns: columns, indexes: indexes),
            from: .postgresql,
            to: target
        )
    }

    private func dataType(_ result: CrossEngineStructureTranslator.Result, _ name: String) -> String? {
        result.snapshot.columns.first { $0.name == name }?.dataType
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

    // MARK: - MySQL keys

    func testAMySQLPrimaryKeyKeepsALengthThatFits() {
        let result = translate([varchar("code", 300, isPrimaryKey: true)])
        XCTAssertEqual(dataType(result, "code"), "VARCHAR(300)")
        XCTAssertTrue(result.notes.isEmpty)
    }

    /// `VARCHAR(1000)` is 4,000 bytes, past the 3,072 an InnoDB key takes, and `VARCHAR(5000)` would
    /// have been a `LONGTEXT` key, which MySQL refuses outright.
    func testAMySQLPrimaryKeyTooWideIsCutTo255() {
        for length in [1_000, 5_000] {
            let result = translate([varchar("code", length, isPrimaryKey: true)])
            XCTAssertEqual(dataType(result, "code"), "VARCHAR(255)", "\(length)")
            XCTAssertTrue(result.notes.contains { $0.subject == "code" && $0.isLossy }, "\(length)")
        }
    }

    /// The widest part is cut first, and only until the key fits.
    func testACompositeMySQLKeyCutsItsWidestPartFirst() {
        let result = translate([varchar("a", 600, isPrimaryKey: true), varchar("b", 200, isPrimaryKey: true)])
        XCTAssertEqual(dataType(result, "a"), "VARCHAR(255)")
        XCTAssertEqual(dataType(result, "b"), "VARCHAR(200)")

        let fits = translate([
            varchar("a", 766, isPrimaryKey: true),
            column("b", "BIGINT", catalog: "bigint", nullable: false, isPrimaryKey: true)
        ])
        XCTAssertEqual(dataType(fits, "a"), "VARCHAR(766)")

        let over = translate([
            varchar("a", 767, isPrimaryKey: true),
            column("b", "BIGINT", catalog: "bigint", nullable: false, isPrimaryKey: true)
        ])
        XCTAssertEqual(dataType(over, "a"), "VARCHAR(255)")
    }

    func testASQLServerKeyIsBoundedOnTheTypeItIsWrittenAs() {
        let result = translate([varchar("code", 5_000, isPrimaryKey: true)], to: .mssql)
        XCTAssertEqual(dataType(result, "code"), "NVARCHAR(450)")
    }

    func testAnOracleKeyIsBoundedOnTheTypeItIsWrittenAs() {
        let result = translate([varchar("code", 2_000, isPrimaryKey: true), varchar("name", 50)], to: .oracle)
        XCTAssertEqual(dataType(result, "code"), "VARCHAR2(2000)")
        XCTAssertEqual(dataType(result, "name"), "VARCHAR2(50 CHAR)")
    }

    // MARK: - MySQL indexes

    func testAMySQLIndexCutsOnlyAsMuchAsItNeeds() {
        let result = translate(
            [varchar("a", 500), varchar("b", 500), varchar("c", 320)],
            indexes: [index("ab_idx", ["a", "b"]), index("c_idx", ["c"])]
        )
        let prefixes = Dictionary(uniqueKeysWithValues: result.snapshot.indexes.map { ($0.name, $0.columnPrefixes) })
        XCTAssertEqual(prefixes["ab_idx"], ["a": 255])
        XCTAssertEqual(prefixes["c_idx"], [:])
        XCTAssertTrue(result.notes.isEmpty)
    }

    func testAUniqueMySQLIndexCutToAPrefixIsReported() {
        let result = translate([varchar("email", 1_000)], indexes: [index("email_key", ["email"], unique: true)])
        XCTAssertEqual(result.snapshot.indexes.first?.columnPrefixes, ["email": 255])
        XCTAssertTrue(result.notes.contains { $0.subject == "email_key" && $0.isLossy })
    }

    /// Four unbounded parts at 255 characters each are 4,080 bytes, and none can be cut shorter.
    func testAMySQLIndexNoPrefixCanFitIsLeftOut() {
        let result = translate(
            [column("a", "text"), column("b", "text"), column("c", "text"), column("d", "text")],
            indexes: [index("wide_idx", ["a", "b", "c", "d"])]
        )
        XCTAssertTrue(result.snapshot.indexes.isEmpty)
        XCTAssertTrue(result.notes.contains { $0.subject == "wide_idx" && $0.isLossy })
    }

    // MARK: - MySQL rows

    /// Seventeen `VARCHAR(1000)` columns are 68,034 bytes, over the 65,535 a row may take, and one of
    /// them stored as `TEXT` brings the table under it.
    func testATableOverMySQLsRowLimitMovesItsWidestColumnOutOfTheRow() {
        let key = column("id", "BIGINT", catalog: "bigint", nullable: false, isPrimaryKey: true)
        let wide = (0..<17).map { varchar("c\($0)", 1_000) }
        let result = translate([key] + wide)
        let moved = result.snapshot.columns.filter { $0.dataType == "TEXT" }.map(\.name)
        XCTAssertEqual(moved, ["c0"])
        XCTAssertTrue(result.notes.contains { $0.subject == "c0" && $0.fidelity == .widened })
        XCTAssertEqual(result.targetKinds["c0"], .text(length: nil, isFixed: false))
    }

    /// Forty-one `VARCHAR(50)` columns pass the 8,126 bytes InnoDB keeps in one record, where forty
    /// do not. The column an index covers is left whole while another can move.
    func testATableOverInnoDBsRecordLimitMovesAnUnindexedColumn() {
        let key = column("id", "BIGINT", catalog: "bigint", nullable: false, isPrimaryKey: true)
        let fits = translate([key] + (0..<40).map { varchar("c\($0)", 50) })
        XCTAssertFalse(fits.snapshot.columns.contains { $0.dataType == "TEXT" })

        let over = translate(
            [key] + (0..<41).map { varchar("c\($0)", 50) },
            indexes: [index("c0_idx", ["c0"])]
        )
        let moved = over.snapshot.columns.filter { $0.dataType == "TEXT" }.map(\.name)
        XCTAssertEqual(moved, ["c1"])
        XCTAssertEqual(over.snapshot.indexes.first?.columnPrefixes, [:])
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
