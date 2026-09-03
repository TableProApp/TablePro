//
//  PostgreSQLTypeDefinitionTests.swift
//  TableProTests
//
//  PostgreSQL has no pg_get_typedef, so the CREATE statement the viewer shows is rebuilt from the
//  catalog row. These pin the shape of every statement and of the row parsing behind it.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("PostgreSQL type definitions")
struct PostgreSQLTypeDefinitionTests {
    private func record(
        name: String = "mood",
        kind: PostgreSQLUserDefinedTypeRecord.Kind,
        enumLabels: [String] = [],
        fields: [PluginUserDefinedTypeField] = [],
        baseType: String? = nil,
        isNotNull: Bool = false,
        defaultValue: String? = nil,
        constraints: [PostgreSQLDomainConstraint] = [],
        rangeSubtype: String? = nil,
        rangeCanonical: String? = nil,
        rangeSubtypeDiff: String? = nil,
        rangeOpclass: String? = nil,
        rangeCollation: String? = nil,
        rangeMultirange: String? = nil
    ) -> PostgreSQLUserDefinedTypeRecord {
        PostgreSQLUserDefinedTypeRecord(
            identity: "16387",
            name: name,
            schema: "app",
            kind: kind,
            owner: "postgres",
            comment: nil,
            enumLabels: enumLabels,
            fields: fields,
            baseType: baseType,
            isNotNull: isNotNull,
            defaultValue: defaultValue,
            constraints: constraints,
            rangeSubtype: rangeSubtype,
            rangeCanonical: rangeCanonical,
            rangeSubtypeDiff: rangeSubtypeDiff,
            rangeOpclass: rangeOpclass,
            rangeCollation: rangeCollation,
            rangeMultirange: rangeMultirange
        )
    }

    @Test("An enum lists its labels in server order, one per line, quoted as literals")
    func enumDDL() {
        let ddl = PostgreSQLTypeDefinition.ddl(for: record(kind: .enumeration, enumLabels: ["sad", "ok", "it's"]))
        #expect(ddl == """
            CREATE TYPE "app"."mood" AS ENUM (
                'sad',
                'ok',
                'it''s'
            );
            """)
    }

    @Test("A composite quotes every field name and keeps the formatted type")
    func compositeDDL() {
        let fields = [
            PluginUserDefinedTypeField(name: "x", type: "double precision"),
            PluginUserDefinedTypeField(name: "label text", type: "character varying(20)")
        ]
        let ddl = PostgreSQLTypeDefinition.ddl(for: record(name: "point", kind: .composite, fields: fields))
        #expect(ddl == """
            CREATE TYPE "app"."point" AS (
                "x" double precision,
                "label text" character varying(20)
            );
            """)
    }

    @Test("A domain carries its default, NOT NULL and every CHECK in that order")
    func domainDDL() {
        let ddl = PostgreSQLTypeDefinition.ddl(for: record(
            name: "email",
            kind: .domain,
            baseType: "text",
            isNotNull: true,
            defaultValue: "'nobody@example.com'::text",
            constraints: [
                PostgreSQLDomainConstraint(name: "email_check", definition: "CHECK ((VALUE ~ '@'::text))"),
                PostgreSQLDomainConstraint(name: "email_check1", definition: "CHECK ((length(VALUE) < 200))")
            ]
        ))
        #expect(ddl == """
            CREATE DOMAIN "app"."email" AS text
                DEFAULT 'nobody@example.com'::text
                NOT NULL
                CONSTRAINT "email_check" CHECK ((VALUE ~ '@'::text))
                CONSTRAINT "email_check1" CHECK ((length(VALUE) < 200));
            """)
    }

    @Test("A bare domain is one line")
    func bareDomainDDL() {
        let ddl = PostgreSQLTypeDefinition.ddl(for: record(name: "score", kind: .domain, baseType: "integer"))
        #expect(ddl == "CREATE DOMAIN \"app\".\"score\" AS integer;")
    }

    /// A domain over a collatable base type may carry its own collation, and a definition that
    /// drops it rebuilds a domain that sorts and compares differently.
    @Test("A domain keeps a collation of its own")
    func domainCollationDDL() {
        let ddl = PostgreSQLTypeDefinition.ddl(for: PostgreSQLUserDefinedTypeRecord(
            identity: "1", name: "ci_text", schema: "app", kind: .domain,
            baseType: "text", collation: "pg_catalog.\"C\"", isNotNull: true
        ))
        #expect(ddl == """
            CREATE DOMAIN "app"."ci_text" AS text COLLATE pg_catalog."C"
                NOT NULL;
            """)
    }

    @Test("A range names its subtype and only the options that were set")
    func rangeDDL() {
        let ddl = PostgreSQLTypeDefinition.ddl(for: record(
            name: "floatrange",
            kind: .range,
            rangeSubtype: "double precision",
            rangeSubtypeDiff: "float8mi",
            rangeMultirange: "app.floatmultirange"
        ))
        #expect(ddl == """
            CREATE TYPE "app"."floatrange" AS RANGE (
                subtype = double precision,
                subtype_diff = float8mi
            );
            """)
    }

    /// A collation, a non-default operator class and a chosen multirange name each change how the
    /// range behaves, so a definition that dropped them would rebuild a different type.
    @Test("A range keeps its collation, its operator class and a multirange name of its own")
    func rangeOptionsDDL() {
        let ddl = PostgreSQLTypeDefinition.ddl(for: record(
            name: "r2",
            kind: .range,
            rangeSubtype: "text",
            rangeOpclass: "pg_catalog.text_pattern_ops",
            rangeCollation: "pg_catalog.\"C\"",
            rangeMultirange: "app.r2_multi"
        ))
        #expect(ddl == """
            CREATE TYPE "app"."r2" AS RANGE (
                subtype = text,
                subtype_opclass = pg_catalog.text_pattern_ops,
                collation = pg_catalog."C",
                multirange_type_name = app.r2_multi
            );
            """)
    }

    @Test("PostgreSQL's default multirange name replaces a trailing range or appends one")
    func defaultMultirangeName() {
        #expect(PostgreSQLTypeDefinition.defaultMultirangeName(for: "floatrange") == "floatmultirange")
        #expect(PostgreSQLTypeDefinition.defaultMultirangeName(for: "r2") == "r2_multirange")
        #expect(PostgreSQLTypeDefinition.defaultMultirangeName(for: "range_of_ranges") == "range_of_multiranges")
    }

    @Test("A composite keeps a field's own collation")
    func compositeCollationDDL() {
        let ddl = PostgreSQLTypeDefinition.ddl(for: record(
            name: "ci",
            kind: .composite,
            fields: [
                PluginUserDefinedTypeField(name: "name", type: "text", collation: "pg_catalog.\"C\""),
                PluginUserDefinedTypeField(name: "n", type: "integer")
            ]
        ))
        #expect(ddl == """
            CREATE TYPE "app"."ci" AS (
                "name" text COLLATE pg_catalog."C",
                "n" integer
            );
            """)
    }

    @Test("A schema or type name with a quote is doubled inside its identifier")
    func identifierQuoting() {
        let ddl = PostgreSQLTypeDefinition.ddl(for: PostgreSQLUserDefinedTypeRecord(
            identity: "1", name: "Weird \"Name\"", schema: "my schema", kind: .enumeration, enumLabels: ["x"]
        ))
        #expect(ddl.hasPrefix("CREATE TYPE \"my schema\".\"Weird \"\"Name\"\"\" AS ENUM ("))
    }

    @Test("A catalog row parses by projection position, JSON columns included")
    func rowParsing() throws {
        var row = [PluginCellValue](repeating: .null, count: PostgreSQLTypeDefinition.Column.allCases.count)
        row[PostgreSQLTypeDefinition.Column.identity.rawValue] = .text("16397")
        row[PostgreSQLTypeDefinition.Column.name.rawValue] = .text("email")
        row[PostgreSQLTypeDefinition.Column.schema.rawValue] = .text("app")
        row[PostgreSQLTypeDefinition.Column.kind.rawValue] = .text("d")
        row[PostgreSQLTypeDefinition.Column.owner.rawValue] = .text("postgres")
        row[PostgreSQLTypeDefinition.Column.comment.rawValue] = .text("Mail")
        row[PostgreSQLTypeDefinition.Column.baseType.rawValue] = .text("text")
        row[PostgreSQLTypeDefinition.Column.collation.rawValue] = .text("pg_catalog.\"C\"")
        row[PostgreSQLTypeDefinition.Column.isNotNull.rawValue] = .text("true")
        row[PostgreSQLTypeDefinition.Column.defaultValue.rawValue] = .text("'x'::text")
        row[PostgreSQLTypeDefinition.Column.constraints.rawValue] = .text(
            #"[{"name" : "email_check", "definition" : "CHECK ((VALUE ~ '@'::text))"}]"#
        )

        let parsed = try #require(PostgreSQLTypeDefinition.record(from: row))
        #expect(parsed.kind == .domain)
        #expect(parsed.baseType == "text")
        #expect(parsed.collation == "pg_catalog.\"C\"")
        #expect(parsed.isNotNull)
        #expect(parsed.defaultValue == "'x'::text")
        #expect(parsed.constraints == [
            PostgreSQLDomainConstraint(name: "email_check", definition: "CHECK ((VALUE ~ '@'::text))")
        ])
        #expect(parsed.comment == "Mail")
    }

    @Test("Enum labels and composite fields parse from their JSON aggregates in order")
    func jsonAggregatesParse() throws {
        var enumRow = [PluginCellValue](repeating: .null, count: PostgreSQLTypeDefinition.Column.allCases.count)
        enumRow[PostgreSQLTypeDefinition.Column.identity.rawValue] = .text("1")
        enumRow[PostgreSQLTypeDefinition.Column.name.rawValue] = .text("mood")
        enumRow[PostgreSQLTypeDefinition.Column.schema.rawValue] = .text("app")
        enumRow[PostgreSQLTypeDefinition.Column.kind.rawValue] = .text("e")
        enumRow[PostgreSQLTypeDefinition.Column.enumLabels.rawValue] = .text(#"["sad", "ok", "it's"]"#)
        let parsedEnum = try #require(PostgreSQLTypeDefinition.record(from: enumRow))
        #expect(parsedEnum.enumLabels == ["sad", "ok", "it's"])

        var compositeRow = enumRow
        compositeRow[PostgreSQLTypeDefinition.Column.kind.rawValue] = .text("c")
        compositeRow[PostgreSQLTypeDefinition.Column.enumLabels.rawValue] = .null
        compositeRow[PostgreSQLTypeDefinition.Column.fields.rawValue] = .text(
            #"[{"name" : "x", "type" : "text", "collation" : "pg_catalog.\"C\""}, {"name" : "y", "type" : "integer", "collation" : null}]"#
        )
        compositeRow[PostgreSQLTypeDefinition.Column.spelling.rawValue] = .text("app.\"Mood\"")
        let parsedComposite = try #require(PostgreSQLTypeDefinition.record(from: compositeRow))
        #expect(parsedComposite.fields == [
            PluginUserDefinedTypeField(name: "x", type: "text", collation: "pg_catalog.\"C\""),
            PluginUserDefinedTypeField(name: "y", type: "integer")
        ])
        #expect(parsedComposite.spelling == "app.\"Mood\"")
        #expect(PostgreSQLTypeDefinition.info(from: parsedComposite).columnTypeSpelling == "app.\"Mood\"")
    }

    @Test("A row of an unknown kind is skipped rather than mislabelled")
    func unknownKindIsSkipped() {
        var row = [PluginCellValue](repeating: .null, count: PostgreSQLTypeDefinition.Column.allCases.count)
        row[PostgreSQLTypeDefinition.Column.identity.rawValue] = .text("1")
        row[PostgreSQLTypeDefinition.Column.name.rawValue] = .text("m")
        row[PostgreSQLTypeDefinition.Column.schema.rawValue] = .text("app")
        row[PostgreSQLTypeDefinition.Column.kind.rawValue] = .text("m")
        #expect(PostgreSQLTypeDefinition.record(from: row) == nil)
    }

    @Test("The transfer type carries the definition, the labels and the attributes the viewer shows")
    func infoMapping() {
        let info = PostgreSQLTypeDefinition.info(from: PostgreSQLUserDefinedTypeRecord(
            identity: "7", name: "mood", schema: "app", kind: .enumeration,
            owner: "postgres", comment: "How someone feels", enumLabels: ["sad", "ok"]
        ))
        #expect(info.kind == .enumeration)
        #expect(info.identity == "7")
        #expect(info.schema == "app")
        #expect(info.enumLabels == ["sad", "ok"])
        #expect(info.definition?.hasPrefix("CREATE TYPE \"app\".\"mood\" AS ENUM") == true)
        #expect(info.attributes.map(\.label) == ["Owner", "Comment"])
    }

    @Test("A domain reports its base type and a range its subtype through one field")
    func baseTypeMapping() {
        let domain = PostgreSQLTypeDefinition.info(from: record(kind: .domain, baseType: "integer"))
        #expect(domain.baseType == "integer")
        #expect(domain.attributes.first?.label == "Base Type")

        let range = PostgreSQLTypeDefinition.info(from: record(kind: .range, rangeSubtype: "numeric"))
        #expect(range.baseType == "numeric")
        #expect(range.attributes.first?.label == "Subtype")
    }
}
