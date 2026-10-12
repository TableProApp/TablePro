//
//  CrossEngineKeyTranslationTests.swift
//  TableProTests
//
//  A primary key, a foreign key or an index that keeps the lengths its source declared still fits
//  the target's index entries. The MySQL boundaries were measured on MySQL 8.4.11 and MariaDB
//  12.3.3; the SQL Server and Oracle ones are those engines' documented limits.
//

@testable import TablePro
import XCTest

final class CrossEngineKeyTranslationTests: XCTestCase {
    private func column(
        _ name: String,
        _ dataType: String,
        catalog: String? = nil,
        isPrimaryKey: Bool = false
    ) -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: UUID(),
            name: name,
            dataType: dataType,
            isNullable: !isPrimaryKey,
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
        column(name, "CHARACTER VARYING", catalog: "character varying(\(length))", isPrimaryKey: isPrimaryKey)
    }

    private func character(_ name: String, _ length: Int, isPrimaryKey: Bool = false) -> EditableColumnDefinition {
        column(name, "CHARACTER", catalog: "character(\(length))", isPrimaryKey: isPrimaryKey)
    }

    private func bigint(_ name: String, isPrimaryKey: Bool = false) -> EditableColumnDefinition {
        column(name, "BIGINT", catalog: "bigint", isPrimaryKey: isPrimaryKey)
    }

    private func index(_ name: String, _ columns: [String], unique: Bool = false) -> EditableIndexDefinition {
        EditableIndexDefinition(
            id: UUID(), name: name, columns: columns, type: .btree, isUnique: unique, isPrimary: false,
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
        to target: DatabaseType = .mysql
    ) -> CrossEngineStructureTranslator.Result {
        CrossEngineStructureTranslator.translate(
            TableStructureSnapshot(
                name: "orders", schema: "public", columns: columns, indexes: indexes, foreignKeys: foreignKeys
            ),
            from: .postgresql,
            to: target
        )
    }

    private func dataType(_ result: CrossEngineStructureTranslator.Result, _ name: String) -> String? {
        result.snapshot.columns.first { $0.name == name }?.dataType
    }

    private func dataTypes(_ result: CrossEngineStructureTranslator.Result, _ names: [String]) -> [String] {
        names.compactMap { dataType(result, $0) }.sorted()
    }

    private func hasKeyNote(_ result: CrossEngineStructureTranslator.Result, _ subject: String) -> Bool {
        result.notes.contains { $0.subject == subject && $0.isLossy }
    }

    // MARK: - MySQL primary keys

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
            XCTAssertTrue(hasKeyNote(result, "code"), "\(length)")
        }
    }

    /// The widest part is cut first, and only until the key fits.
    func testACompositeMySQLKeyCutsItsWidestPartFirst() {
        let result = translate([varchar("a", 600, isPrimaryKey: true), varchar("b", 200, isPrimaryKey: true)])
        XCTAssertEqual(dataType(result, "a"), "VARCHAR(255)")
        XCTAssertEqual(dataType(result, "b"), "VARCHAR(200)")

        let fits = translate([varchar("a", 766, isPrimaryKey: true), bigint("b", isPrimaryKey: true)])
        XCTAssertEqual(dataType(fits, "a"), "VARCHAR(766)")

        let over = translate([varchar("a", 767, isPrimaryKey: true), bigint("b", isPrimaryKey: true)])
        XCTAssertEqual(dataType(over, "a"), "VARCHAR(255)")
    }

    /// Four `VARCHAR(200)` parts are 3,200 bytes and none is longer than 255. Four `VARCHAR(192)` were
    /// created and `VARCHAR(193)` beside three of them refused with ERROR 1071; with a `BIGINT` part as
    /// well, four `VARCHAR(191)` were created.
    func testAMySQLKeyWithNoPartLongerThan255SharesTheBytes() {
        let names = ["a", "b", "c", "d"]
        let result = translate(names.map { varchar($0, 200, isPrimaryKey: true) })
        XCTAssertEqual(dataTypes(result, names), Array(repeating: "VARCHAR(192)", count: 4))
        XCTAssertTrue(names.allSatisfy { hasKeyNote(result, $0) })

        let withInteger = translate(names.map { varchar($0, 200, isPrimaryKey: true) } + [bigint("e", isPrimaryKey: true)])
        let bytes = names.compactMap { name in
            withInteger.targetKinds[name].flatMap { MySQLStorageWidth.keyBytes($0) }
        }.reduce(8, +)
        XCTAssertLessThanOrEqual(bytes, MySQLStorageWidth.maximumKeyBytes)
        XCTAssertTrue(dataTypes(withInteger, names).allSatisfy { $0 == "VARCHAR(191)" || $0 == "VARCHAR(192)" })
    }

    // MARK: - MySQL foreign keys

    /// A foreign key is indexed like any other key: a `TEXT` column in one was refused with ERROR 1170,
    /// a `VARCHAR(769)` with ERROR 1071 and two `VARCHAR(500)` with ERROR 1071, where `VARCHAR(768)`
    /// and two `VARCHAR(384)` were created.
    func testAMySQLForeignKeyIsBoundedLikeAKey() {
        let result = translate(
            [
                bigint("id", isPrimaryKey: true),
                column("note", "text", catalog: "text"),
                varchar("code", 1_000),
                varchar("fits", 768),
                varchar("a", 500),
                varchar("b", 500)
            ],
            foreignKeys: [foreignKey(["note"]), foreignKey(["code"]), foreignKey(["fits"]), foreignKey(["a", "b"])]
        )
        XCTAssertEqual(dataType(result, "note"), "VARCHAR(255)")
        XCTAssertEqual(dataType(result, "code"), "VARCHAR(255)")
        XCTAssertEqual(dataType(result, "fits"), "VARCHAR(768)")
        XCTAssertEqual(dataTypes(result, ["a", "b"]), ["VARCHAR(255)", "VARCHAR(500)"])
        XCTAssertTrue(hasKeyNote(result, "note"))
        XCTAssertTrue(hasKeyNote(result, "code"))
        XCTAssertFalse(result.notes.contains { $0.subject == "fits" })
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
        XCTAssertTrue(hasKeyNote(result, "email_key"))
    }

    /// Four unbounded parts at 255 characters each are 4,080 bytes, and none can be cut shorter.
    func testAMySQLIndexNoPrefixCanFitIsLeftOut() {
        let result = translate(
            [column("a", "text"), column("b", "text"), column("c", "text"), column("d", "text")],
            indexes: [index("wide_idx", ["a", "b", "c", "d"])]
        )
        XCTAssertTrue(result.snapshot.indexes.isEmpty)
        XCTAssertTrue(hasKeyNote(result, "wide_idx"))
    }

    // MARK: - SQL Server

    func testASQLServerKeyIsBoundedOnTheTypeItIsWrittenAs() {
        let result = translate([varchar("code", 5_000, isPrimaryKey: true)], to: .mssql)
        XCTAssertEqual(dataType(result, "code"), "NVARCHAR(450)")
        XCTAssertTrue(hasKeyNote(result, "code"))
    }

    /// An `NVARCHAR(1000)` key is 2,000 bytes against a clustered key's 900, so a key over 450
    /// characters is refused on insert either way, and the cut says so before the copy runs.
    func testASQLServerKeyPastItsLimitIsCutTo450() {
        let result = translate([varchar("code", 1_000, isPrimaryKey: true)], to: .mssql)
        XCTAssertEqual(dataType(result, "code"), "NVARCHAR(450)")
        XCTAssertTrue(hasKeyNote(result, "code"))
    }

    /// SQL Server refuses a key whose fixed-length columns pass 900 bytes with Msg 1944, and creates
    /// one of longer variable columns, refusing only the row whose key is longer.
    func testAFixedLengthSQLServerKeyPastItsLimitBecomesVariable() {
        let single = translate([character("code", 500, isPrimaryKey: true)], to: .mssql)
        XCTAssertEqual(dataType(single, "code"), "NVARCHAR(450)")

        let pair = translate(
            [character("a", 300, isPrimaryKey: true), character("b", 300, isPrimaryKey: true)], to: .mssql
        )
        XCTAssertEqual(dataTypes(pair, ["a", "b"]), ["NCHAR(300)", "NVARCHAR(300)"])

        let variable = translate(
            [varchar("a", 300, isPrimaryKey: true), varchar("b", 300, isPrimaryKey: true)], to: .mssql
        )
        XCTAssertEqual(dataTypes(variable, ["a", "b"]), ["NVARCHAR(300)", "NVARCHAR(300)"])
        XCTAssertFalse(hasKeyNote(variable, "a") || hasKeyNote(variable, "b"))
    }

    /// An index has 1,700 bytes, and only fixed-length columns past them refuse it.
    func testASQLServerIndexWhoseFixedColumnsPassItsLimitIsLeftOut() {
        let result = translate(
            [character("a", 450), character("b", 450), varchar("body", 1_000)],
            indexes: [index("ab_idx", ["a", "b"]), index("body_idx", ["body"])],
            to: .mssql
        )
        XCTAssertEqual(result.snapshot.indexes.map(\.name), ["body_idx"])
        XCTAssertTrue(hasKeyNote(result, "ab_idx"))
    }

    /// SQL Server builds no index for a foreign key, so only a column no key can hold is bounded.
    func testASQLServerForeignKeyIsBoundedOnlyWhereItHasNoLength() {
        let result = translate(
            [bigint("id", isPrimaryKey: true), column("note", "text", catalog: "text"), varchar("code", 1_000)],
            foreignKeys: [foreignKey(["note"]), foreignKey(["code"])],
            to: .mssql
        )
        XCTAssertEqual(dataType(result, "note"), "NVARCHAR(450)")
        XCTAssertEqual(dataType(result, "code"), "NVARCHAR(1000)")
    }

    // MARK: - Oracle

    /// A `varchar(2000)` is past what a `VARCHAR2` holds in characters, so it is written as a `CLOB`,
    /// which Oracle cannot key. The key is then counted in characters like every other length.
    func testAnOracleKeyIsBoundedOnTheTypeItIsWrittenAs() {
        let result = translate([varchar("code", 2_000, isPrimaryKey: true), varchar("name", 50)], to: .oracle)
        XCTAssertEqual(dataType(result, "code"), "VARCHAR2(1000 CHAR)")
        XCTAssertEqual(dataType(result, "name"), "VARCHAR2(50 CHAR)")
        XCTAssertTrue(result.notes.contains { $0.subject == "code" && $0.reason.contains("CLOB") })
    }

    /// Oracle counts two `VARCHAR2(1000 CHAR)` parts at 4,000 bytes each plus one a part, 8,002 bytes
    /// against 6,398, and refuses the key with ORA-01450. One of them fits.
    func testACompositeOracleKeyPastItsLimitSharesTheBytes() {
        let pair = translate(
            [varchar("a", 1_000, isPrimaryKey: true), varchar("b", 1_000, isPrimaryKey: true)], to: .oracle
        )
        XCTAssertEqual(dataTypes(pair, ["a", "b"]), ["VARCHAR2(799 CHAR)", "VARCHAR2(800 CHAR)"])
        XCTAssertTrue(hasKeyNote(pair, "a") && hasKeyNote(pair, "b"))

        let single = translate([varchar("code", 1_000, isPrimaryKey: true)], to: .oracle)
        XCTAssertEqual(dataType(single, "code"), "VARCHAR2(1000 CHAR)")
        XCTAssertTrue(single.notes.isEmpty)
    }

    /// Oracle has no key prefixes, so an index past 6,398 bytes can only be left out.
    func testAnOracleIndexPastItsLimitIsLeftOut() {
        let columns = ["a", "b", "c", "d"].map { varchar($0, 500) }
        let result = translate(
            columns,
            indexes: [index("four_idx", ["a", "b", "c", "d"]), index("three_idx", ["a", "b", "c"])],
            to: .oracle
        )
        XCTAssertEqual(result.snapshot.indexes.map(\.name), ["three_idx"])
        XCTAssertTrue(hasKeyNote(result, "four_idx"))
    }

    func testAnOracleForeignKeyIsBoundedOnlyWhereItHasNoLength() {
        let result = translate(
            [bigint("id", isPrimaryKey: true), column("note", "text", catalog: "text"), varchar("a", 1_000), varchar("b", 1_000)],
            foreignKeys: [foreignKey(["note"]), foreignKey(["a", "b"])],
            to: .oracle
        )
        XCTAssertEqual(dataType(result, "note"), "VARCHAR2(1000 CHAR)")
        XCTAssertEqual(dataTypes(result, ["a", "b"]), ["VARCHAR2(1000 CHAR)", "VARCHAR2(1000 CHAR)"])
    }

    func testAnEngineWithoutKeyLimitsKeepsEveryLength() {
        let result = translate(
            [varchar("a", 5_000, isPrimaryKey: true), varchar("b", 5_000, isPrimaryKey: true)],
            indexes: [index("ab_idx", ["a", "b"])],
            to: .duckdb
        )
        XCTAssertEqual(dataTypes(result, ["a", "b"]), ["VARCHAR(5000)", "VARCHAR(5000)"])
        XCTAssertEqual(result.snapshot.indexes.count, 1)
    }
}
