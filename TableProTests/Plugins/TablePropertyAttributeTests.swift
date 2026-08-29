//
//  TablePropertyAttributeTests.swift
//  TableProTests
//
//  The driver-supplied properties the Properties tab renders verbatim.
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("Plugin Table Metadata Coding")
struct PluginTableMetadataCodingTests {

    /// Swift's synthesized `Decodable` does not fall back to an initializer's default value, so a
    /// payload written before `attributes` existed throws `keyNotFound` unless the decoder spells
    /// the fallback out. Measured, not assumed.
    @Test("Decodes a payload written before attributes existed")
    func decodesWithoutAttributes() throws {
        let json = Data(#"{"tableName":"orders","comment":"hi"}"#.utf8)

        let metadata = try JSONDecoder().decode(PluginTableMetadata.self, from: json)

        #expect(metadata.tableName == "orders")
        #expect(metadata.comment == "hi")
        #expect(metadata.attributes.isEmpty)
        #expect(metadata.commentIsReadOnly)
    }

    @Test("Round-trips the attributes it was given")
    func roundTripsAttributes() throws {
        let original = PluginTableMetadata(
            tableName: "orders",
            attributes: [PluginObjectAttribute(label: "Owner", value: "app")]
        )

        let decoded = try JSONDecoder().decode(
            PluginTableMetadata.self, from: JSONEncoder().encode(original))

        #expect(decoded.attributes == original.attributes)
    }

    /// The pre-`attributes` initializer keeps its exact signature so already-built plugins keep
    /// their symbol. It has to stay callable, and it has to produce an empty attribute list.
    @Test("The original initializer still compiles and reports no attributes")
    func originalInitializerStillWorks() {
        let metadata = PluginTableMetadata(tableName: "orders", engine: "InnoDB")

        #expect(metadata.engine == "InnoDB")
        #expect(metadata.attributes.isEmpty)
        #expect(metadata.commentIsReadOnly)
    }
}

@Suite("PostgreSQL Comment Literal")
struct PostgreSQLDollarQuotedLiteralTests {

    @Test("Wraps the value in a dollar-quoted body")
    func wrapsValue() {
        #expect(PostgreSQLObjectQueries.dollarQuoted("hello") == "$tablepro$hello$tablepro$")
    }

    /// The whole point of dollar quoting: neither an apostrophe nor a backslash is scanned inside
    /// the body, so `standard_conforming_strings` cannot change where the literal ends.
    @Test("Leaves quotes and backslashes exactly as typed")
    func leavesEscapesAlone() {
        let payload = #"\'; DROP TABLE users; --"#

        let literal = PostgreSQLObjectQueries.dollarQuoted(payload)

        #expect(literal == "$tablepro$\(payload)$tablepro$")
        #expect(literal.hasSuffix("$tablepro$"))
    }

    /// A body holding the tag would close the literal early, which is the one way dollar quoting
    /// can be escaped from.
    @Test("Grows the tag until the body cannot close it")
    func growsTagOnCollision() {
        let literal = PostgreSQLObjectQueries.dollarQuoted("a $tablepro$ b")

        #expect(literal == "$tablepro_$a $tablepro$ b$tablepro_$")
    }

    @Test("Grows the tag again when the body holds the grown one too")
    func growsTagRepeatedly() {
        let literal = PostgreSQLObjectQueries.dollarQuoted("$tablepro$ $tablepro_$")

        #expect(literal.hasPrefix("$tablepro__$"))
        #expect(literal.hasSuffix("$tablepro__$"))
    }

    /// PostgreSQL rejects a NUL in any text value, dollar-quoted or not.
    @Test("Drops a NUL the server would refuse")
    func dropsNul() {
        #expect(PostgreSQLObjectQueries.dollarQuoted("a\0b") == "$tablepro$ab$tablepro$")
    }
}

@Suite("PostgreSQL Table Attributes")
struct PostgreSQLTableAttributeTests {

    /// An ordinary table is the assumption, so naming its kind adds a row that changes nothing.
    @Test("Names owner, tablespace and persistence, and leaves an ordinary table unlabelled")
    func fullSet() {
        let attributes = PostgreSQLTableAttributes.build(
            owner: "app",
            tablespace: "pg_default",
            persistence: "p",
            relkind: "r"
        )

        #expect(attributes.map(\.value) == ["app", "pg_default", "Permanent"])
    }

    @Test("Omits every property the catalog left blank")
    func blanksOmitted() {
        let attributes = PostgreSQLTableAttributes.build(
            owner: nil,
            tablespace: "",
            persistence: nil,
            relkind: nil
        )

        #expect(attributes.isEmpty)
    }

    /// An unfamiliar `relkind` is left off rather than shown as a raw letter, so a future relation
    /// kind reads as absent instead of as a one-character property.
    @Test("Drops an unrecognised relkind and persistence")
    func unknownCodesDropped() {
        let attributes = PostgreSQLTableAttributes.build(
            owner: "app",
            tablespace: nil,
            persistence: "z",
            relkind: "I"
        )

        #expect(attributes.map(\.value) == ["app"])
    }

    /// The tab already labels the schema it was opened on, so a second copy under the driver's own
    /// name would print the same value twice.
    @Test("Never names the schema")
    func schemaNeverNamed() {
        let attributes = PostgreSQLTableAttributes.build(
            owner: "app",
            tablespace: "pg_default",
            persistence: "p",
            relkind: "p"
        )

        #expect(attributes.contains { $0.label == "Schema" } == false)
    }

    /// `COMMENT ON TABLE` is refused on anything else, and each of the rest has its own keyword the
    /// app has no way to ask for, so the relation itself has to say the comment is read-only.
    @Test("Only an ordinary or partitioned table takes a writable comment", arguments: [
        ("r", false), ("p", false), ("v", true), ("m", true), ("f", true), ("I", true)
    ])
    func commentWritability(relkind: String, readOnly: Bool) {
        #expect(PostgreSQLTableAttributes.commentIsReadOnly(relkind: relkind) == readOnly)
    }

    @Test("An unreadable relkind is treated as read-only")
    func missingRelkindIsReadOnly() {
        #expect(PostgreSQLTableAttributes.commentIsReadOnly(relkind: nil))
    }

    @Test("Names an unlogged partitioned table by both codes")
    func unloggedPartitioned() {
        let attributes = PostgreSQLTableAttributes.build(
            owner: nil,
            tablespace: nil,
            persistence: "u",
            relkind: "p"
        )

        #expect(attributes.map(\.value) == ["Unlogged", "Partitioned table"])
    }
}

@Suite("MySQL Table Status")
struct MySQLTableStatusTests {

    /// `SHOW TABLE STATUS` in the documented column order: Name, Engine, Version, Row_format, Rows,
    /// Avg_row_length, Data_length, Max_data_length, Index_length, Data_free, Auto_increment,
    /// Create_time, Update_time, Check_time, Collation, Checksum, Create_options, Comment.
    private func statusRow(
        comment: String = "orders",
        collation: String = "utf8mb4_unicode_ci"
    ) -> [PluginCellValue] {
        [
            .text("orders"), .text("InnoDB"), .text("10"), .text("Dynamic"), .text("42"),
            .text("128"), .text("16384"), .text("0"), .text("32768"), .text("0"), .text("99"),
            .text("2026-08-29 10:11:12"), .text("2026-08-29 11:12:13"), .null,
            .text(collation), .null, .text("row_format=DYNAMIC"), .text(comment)
        ]
    }

    @Test("Reads every column the Properties tab shows")
    func readsAllColumns() {
        let status = MySQLTableStatus(row: statusRow())

        #expect(status.engine == "InnoDB")
        #expect(status.rowFormat == "Dynamic")
        #expect(status.rowCount == 42)
        #expect(status.avgRowLength == 128)
        #expect(status.dataSize == 16_384)
        #expect(status.indexSize == 32_768)
        #expect(status.autoIncrement == 99)
        #expect(status.collation == "utf8mb4_unicode_ci")
        #expect(status.comment == "orders")
    }

    @Test("Parses the create and update timestamps")
    func parsesTimestamps() {
        let status = MySQLTableStatus(row: statusRow())

        var components = DateComponents()
        components.year = 2_026
        components.month = 8
        components.day = 29
        components.hour = 10
        components.minute = 11
        components.second = 12
        let expected = Calendar.current.date(from: components)

        #expect(status.createTime == expected)
        #expect(status.updateTime != nil)
    }

    /// MySQL reports no comment as the empty string, and an empty string here would stage a change
    /// against a table that never had one.
    @Test("An empty comment reads as absent")
    func emptyCommentIsNil() {
        let status = MySQLTableStatus(row: statusRow(comment: ""))

        #expect(status.comment == nil)
    }

    @Test("A short row reads every missing column as absent")
    func shortRowIsSafe() {
        let status = MySQLTableStatus(row: [.text("orders"), .text("InnoDB")])

        #expect(status.engine == "InnoDB")
        #expect(status.comment == nil)
        #expect(status.rowCount == nil)
        #expect(status.createTime == nil)
    }

    /// `SHOW TABLE STATUS` answers for a view with every storage column NULL, so a row that names
    /// no engine is a view and MySQL has no `COMMENT` form for one.
    @Test("A row with no engine is a view and keeps its comment read-only")
    func viewCommentIsReadOnly() {
        #expect(MySQLTableStatus(row: [.text("orders"), .null]).commentIsReadOnly)
        #expect(MySQLTableStatus(row: statusRow()).commentIsReadOnly == false)
    }

    @Test("Publishes row format, auto increment and create options as attributes")
    func attributes() {
        let status = MySQLTableStatus(row: statusRow())

        #expect(status.attributes.map(\.value) == ["Dynamic", "99", "row_format=DYNAMIC"])
    }
}
