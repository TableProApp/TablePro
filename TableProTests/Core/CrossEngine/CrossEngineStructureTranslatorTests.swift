//
//  CrossEngineStructureTranslatorTests.swift
//  TableProTests
//

import TableProPluginKit
import XCTest
@testable import TablePro

final class CrossEngineStructureTranslatorTests: XCTestCase {
    private func column(
        _ name: String,
        _ type: String,
        nullable: Bool = true,
        defaultValue: String? = nil,
        autoIncrement: Bool = false,
        unsigned: Bool = false,
        charset: String? = nil,
        collation: String? = nil,
        onUpdate: String? = nil,
        extra: String? = nil,
        generation: String? = nil,
        isPrimaryKey: Bool = false
    ) -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: UUID(),
            name: name,
            dataType: type,
            isNullable: nullable,
            defaultValue: defaultValue,
            autoIncrement: autoIncrement,
            unsigned: unsigned,
            comment: nil,
            collation: collation,
            onUpdate: onUpdate,
            charset: charset,
            extra: extra,
            generationExpression: generation,
            generationKind: generation == nil ? nil : .stored,
            isPrimaryKey: isPrimaryKey
        )
    }

    private func index(
        _ name: String,
        _ columns: [String],
        type: EditableIndexDefinition.IndexType = .btree,
        unique: Bool = false,
        primary: Bool = false,
        whereClause: String? = nil
    ) -> EditableIndexDefinition {
        EditableIndexDefinition(
            id: UUID(),
            name: name,
            columns: columns,
            type: type,
            isUnique: unique,
            isPrimary: primary,
            comment: nil,
            columnPrefixes: [:],
            whereClause: whereClause
        )
    }

    private func snapshot(
        columns: [EditableColumnDefinition],
        indexes: [EditableIndexDefinition] = []
    ) -> TableStructureSnapshot {
        TableStructureSnapshot(
            name: "orders",
            schema: "public",
            columns: columns,
            indexes: indexes,
            engine: "InnoDB",
            charset: "utf8mb4",
            collation: "utf8mb4_0900_ai_ci"
        )
    }

    // MARK: - Same family

    /// The one guarantee that lets a change this wide be trusted: a copy that already worked runs
    /// the path it always ran, byte for byte.
    func testASameEngineCopyIsUntouched() {
        let source = snapshot(columns: [column("id", "INT", autoIncrement: true, isPrimaryKey: true)])
        let result = CrossEngineStructureTranslator.translate(source, from: .mysql, to: .mysql)
        XCTAssertFalse(result.translated)
        XCTAssertTrue(result.notes.isEmpty)
        XCTAssertEqual(result.snapshot.columns.map(\.dataType), ["INT"])
        XCTAssertEqual(result.snapshot.engine, "InnoDB")
        XCTAssertEqual(result.snapshot.charset, "utf8mb4")
    }

    func testTwoEnginesOfOneFamilyAreUntouched() {
        let source = snapshot(columns: [column("id", "INT")])
        XCTAssertFalse(
            CrossEngineStructureTranslator.translate(source, from: .mysql, to: .mariadb).translated
        )
    }

    // MARK: - Types

    func testTypesAreSaidInTheTargetsOwnWords() {
        let source = snapshot(columns: [
            column("id", "INT", autoIncrement: true, isPrimaryKey: true),
            column("flag", "TINYINT(1)"),
            column("body", "LONGTEXT"),
            column("made", "DATETIME(6)")
        ])
        let result = CrossEngineStructureTranslator.translate(source, from: .mysql, to: .postgresql)
        XCTAssertTrue(result.translated)
        XCTAssertEqual(
            result.snapshot.columns.map(\.dataType),
            ["INTEGER", "BOOLEAN", "TEXT", "TIMESTAMP(6)"]
        )
    }

    /// All three name something on the source's side and are rejected outright by every other
    /// engine's `CREATE TABLE`.
    func testMySQLOnlyAttributesAreDropped() {
        let source = snapshot(columns: [
            column("made", "TIMESTAMP", onUpdate: "CURRENT_TIMESTAMP", extra: "on update CURRENT_TIMESTAMP"),
            column("name", "VARCHAR(20)", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci")
        ])
        let result = CrossEngineStructureTranslator.translate(source, from: .mysql, to: .postgresql)
        XCTAssertNil(result.snapshot.columns[0].onUpdate)
        XCTAssertNil(result.snapshot.columns[0].extra)
        XCTAssertNil(result.snapshot.columns[1].charset)
        XCTAssertNil(result.snapshot.columns[1].collation)
        XCTAssertNil(result.snapshot.engine)
        XCTAssertNil(result.snapshot.charset)
        XCTAssertNil(result.snapshot.collation)
    }

    /// `UNSIGNED` is written by the MySQL driver from the attribute, so it survives into a MySQL
    /// target and is dropped for every other one, where it would be a syntax error.
    func testUnsignedFollowsTheTarget() {
        let source = snapshot(columns: [column("count", "INT UNSIGNED", unsigned: true)])
        let toPostgres = CrossEngineStructureTranslator.translate(source, from: .mysql, to: .postgresql)
        XCTAssertFalse(toPostgres.snapshot.columns[0].unsigned)
        XCTAssertEqual(toPostgres.snapshot.columns[0].dataType, "BIGINT")

        let fromPostgres = snapshot(columns: [column("count", "bigint")])
        let toMySQL = CrossEngineStructureTranslator.translate(fromPostgres, from: .postgresql, to: .mysql)
        XCTAssertFalse(toMySQL.snapshot.columns[0].unsigned)
    }

    // MARK: - Defaults

    /// A `SERIAL` is an integer whose default calls a sequence written in PostgreSQL's own DDL.
    /// Carried over as text the target either rejects it or stores the literal string; carried as
    /// the target's own generated key it means what the source meant.
    func testASequenceDefaultBecomesAutoIncrement() {
        let source = snapshot(columns: [
            column("id", "integer", defaultValue: "nextval('orders_id_seq'::regclass)", isPrimaryKey: true)
        ])
        let result = CrossEngineStructureTranslator.translate(source, from: .postgresql, to: .mysql)
        XCTAssertTrue(result.snapshot.columns[0].autoIncrement)
        XCTAssertNil(result.snapshot.columns[0].defaultValue)
    }

    func testTheCurrentTimestampDefaultSurvives() {
        let source = snapshot(columns: [column("made", "timestamp", defaultValue: "now()")])
        let result = CrossEngineStructureTranslator.translate(source, from: .postgresql, to: .mysql)
        XCTAssertEqual(result.snapshot.columns[0].defaultValue, "CURRENT_TIMESTAMP")
    }

    /// The target's DDL writer quotes whatever it does not recognise, so a default it cannot read
    /// would become the literal string `'uuid_generate_v4()'` in every row.
    func testAnUntranslatableDefaultIsDroppedWithAReason() {
        let source = snapshot(columns: [column("id", "uuid", defaultValue: "uuid_generate_v4()")])
        let result = CrossEngineStructureTranslator.translate(source, from: .postgresql, to: .mysql)
        XCTAssertNil(result.snapshot.columns[0].defaultValue)
        XCTAssertTrue(result.notes.contains { $0.subject == "id" && $0.isLossy })
    }

    func testAPostgresCastIsStrippedFromALiteralDefault() {
        let source = snapshot(columns: [column("state", "character varying(10)", defaultValue: "'new'::character varying")])
        let result = CrossEngineStructureTranslator.translate(source, from: .postgresql, to: .mysql)
        XCTAssertEqual(result.snapshot.columns[0].defaultValue, "'new'")
    }

    func testABooleanDefaultFollowsTheTargetsSpelling() {
        let source = snapshot(columns: [column("live", "boolean", defaultValue: "false")])
        XCTAssertEqual(
            CrossEngineStructureTranslator.translate(source, from: .postgresql, to: .mysql)
                .snapshot.columns[0].defaultValue,
            "0"
        )
        let mysqlSource = snapshot(columns: [column("live", "TINYINT(1)", defaultValue: "1")])
        XCTAssertEqual(
            CrossEngineStructureTranslator.translate(mysqlSource, from: .mysql, to: .postgresql)
                .snapshot.columns[0].defaultValue,
            "TRUE"
        )
    }

    // MARK: - Generated columns

    /// The expression is the source's own SQL and nothing parses it, so the column is created as
    /// an ordinary one. That is what lets its values be copied instead of arriving empty.
    func testAComputedColumnBecomesAnOrdinaryOne() {
        let source = snapshot(columns: [
            column("total", "DECIMAL(10,2)", generation: "price * quantity")
        ])
        let result = CrossEngineStructureTranslator.translate(source, from: .mysql, to: .postgresql)
        XCTAssertNil(result.snapshot.columns[0].generationExpression)
        XCTAssertNil(result.snapshot.columns[0].generationKind)
        XCTAssertTrue(result.notes.contains { $0.subject == "total" })
    }

    // MARK: - Keys and indexes

    /// MySQL refuses a `PRIMARY KEY` on a `LONGTEXT` outright, and the whole `CREATE TABLE` fails
    /// with it rather than the copy losing anything.
    func testAKeyColumnIsBoundedWhereTheEngineNeedsIt() {
        let source = snapshot(columns: [column("code", "text", isPrimaryKey: true)])
        let result = CrossEngineStructureTranslator.translate(source, from: .postgresql, to: .mysql)
        XCTAssertEqual(result.snapshot.columns[0].dataType, "VARCHAR(255)")
        XCTAssertTrue(result.notes.contains { $0.subject == "code" })
    }

    func testAKeyColumnIsLeftUnboundedWhereTheEngineAllowsIt() {
        let source = snapshot(columns: [column("code", "LONGTEXT", isPrimaryKey: true)])
        let result = CrossEngineStructureTranslator.translate(source, from: .mysql, to: .postgresql)
        XCTAssertEqual(result.snapshot.columns[0].dataType, "TEXT")
    }

    /// A `GIN` index reaches MySQL as a plain `INDEX` over a column that is now `JSON`, and MySQL
    /// refuses the whole table for it.
    func testAnIndexTheTargetCannotBuildIsLeftOut() {
        let source = snapshot(
            columns: [column("doc", "jsonb")],
            indexes: [index("doc_gin", ["doc"], type: .gin)]
        )
        let result = CrossEngineStructureTranslator.translate(source, from: .postgresql, to: .mysql)
        XCTAssertTrue(result.snapshot.indexes.isEmpty)
        XCTAssertTrue(result.notes.contains { $0.subject == "doc_gin" })
    }

    /// MySQL indexes an unbounded text column only with a key length, and refuses it without one.
    func testAnIndexOnUnboundedTextGetsAKeyPrefixOnMySQL() {
        let source = snapshot(
            columns: [column("body", "text")],
            indexes: [index("body_idx", ["body"])]
        )
        let result = CrossEngineStructureTranslator.translate(source, from: .postgresql, to: .mysql)
        XCTAssertEqual(result.snapshot.indexes.first?.columnPrefixes["body"], 255)
    }

    func testAPartialIndexLosesItsClauseWhereTheEngineHasNone() {
        let source = snapshot(
            columns: [column("state", "text")],
            indexes: [index("live_idx", ["state"], whereClause: "state = 'live'")]
        )
        let result = CrossEngineStructureTranslator.translate(source, from: .postgresql, to: .mysql)
        XCTAssertNil(result.snapshot.indexes.first?.whereClause)
        XCTAssertTrue(result.notes.contains { $0.subject == "live_idx" })
    }

    func testThePrimaryKeyIndexIsKeptForTheTargetToWrite() {
        let source = snapshot(
            columns: [column("id", "INT", isPrimaryKey: true)],
            indexes: [index("PRIMARY", ["id"], unique: true, primary: true)]
        )
        let result = CrossEngineStructureTranslator.translate(source, from: .mysql, to: .postgresql)
        XCTAssertEqual(result.snapshot.primaryKeyColumns, ["id"])
    }

    // MARK: - Value kinds

    func testTheTargetKindsDescribeEveryColumn() {
        let source = snapshot(columns: [column("flag", "TINYINT(1)"), column("made", "DATETIME")])
        let result = CrossEngineStructureTranslator.translate(source, from: .mysql, to: .postgresql)
        XCTAssertEqual(result.targetKinds["flag"], .boolean)
        XCTAssertEqual(result.targetKinds["made"], .timestamp(precision: nil, hasTimeZone: false))
    }

    /// The kinds describe what was written, not what was read. Carrying the source's answer over
    /// told the coercer a MySQL `DATETIME` still had the time zone its PostgreSQL source declared,
    /// so the offset it exists to strip was left on every value, and an array bound for a `JSON`
    /// column was not recognised as needing conversion at all.
    func testTheTargetKindsFollowWhatTheRendererWroteRatherThanTheSource() {
        let source = snapshot(columns: [
            column("made", "timestamptz"),
            column("tags", "integer[]"),
            column("live", "boolean")
        ])
        let result = CrossEngineStructureTranslator.translate(source, from: .postgresql, to: .mysql)

        XCTAssertEqual(result.snapshot.columns.map(\.dataType), ["DATETIME", "JSON", "TINYINT(1)"])
        XCTAssertEqual(result.targetKinds["made"], .timestamp(precision: nil, hasTimeZone: false))
        XCTAssertEqual(result.targetKinds["tags"], .json)
        XCTAssertEqual(result.targetKinds["live"], .boolean)

        XCTAssertEqual(result.sourceKinds["made"], .timestamp(precision: nil, hasTimeZone: true))
        XCTAssertEqual(result.sourceKinds["tags"], .array(element: .integer(bytes: 4)))
        XCTAssertEqual(result.sourceKinds["live"], .boolean)
    }

    /// A cut precision loses digits, so it is a conversion the review step has to name.
    func testAClampedDecimalPrecisionIsReported() {
        let source = snapshot(columns: [column("amount", "DECIMAL(65,30)")])
        let result = CrossEngineStructureTranslator.translate(source, from: .mysql, to: .mssql)
        XCTAssertEqual(result.snapshot.columns[0].dataType, "DECIMAL(38, 30)")
        XCTAssertTrue(result.notes.contains { $0.subject == "amount" && $0.isLossy })
    }

    /// A prefix on a unique index is a weaker constraint than the source had, and the copy fails on
    /// the first pair of rows that agree for 255 characters.
    func testAUniqueIndexCutToAPrefixIsReported() {
        let source = snapshot(
            columns: [column("body", "text")],
            indexes: [index("body_unique", ["body"], unique: true)]
        )
        let result = CrossEngineStructureTranslator.translate(source, from: .postgresql, to: .mysql)
        XCTAssertEqual(result.snapshot.indexes.first?.columnPrefixes["body"], 255)
        XCTAssertTrue(result.notes.contains { $0.subject == "body_unique" && $0.isLossy })
    }
}
