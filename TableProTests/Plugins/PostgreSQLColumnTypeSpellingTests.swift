//
//  PostgreSQLColumnTypeSpellingTests.swift
//  TableProTests
//
//  Which spelling a PostgreSQL column shows and which one the app classifies it by.
//

import Foundation
import TableProPluginKit
import Testing

@Suite("PostgreSQLColumnTypeSpelling")
struct PostgreSQLColumnTypeSpellingTests {
    private func resolve(
        declared: String?,
        informationSchema: String,
        domain: String? = nil,
        udtSchema: String? = "pg_catalog",
        resolvedType: String,
        allowedValues: [String]? = nil
    ) -> PostgreSQLColumnTypeSpelling.Resolution {
        PostgreSQLColumnTypeSpelling.resolve(
            declaredType: declared,
            informationSchemaType: informationSchema,
            domainName: domain,
            udtSchema: udtSchema,
            resolved: PostgresColumnTypeResolver.Resolution(
                dataType: resolvedType, allowedValues: allowedValues
            )
        )
    }

    @Test("A pg_catalog type shows its declared spelling and needs no classification hint")
    func builtInTypeKeepsFormatType() {
        let spelling = resolve(
            declared: "character varying(50)",
            informationSchema: "character varying",
            resolvedType: "CHARACTER VARYING"
        )
        #expect(spelling.dataType == "character varying(50)")
        #expect(spelling.classificationTypeName == nil)
    }

    @Test("An enum column shows the enum's name and is classified as an enum")
    func enumKeepsItsName() {
        let spelling = resolve(
            declared: "status",
            informationSchema: "USER-DEFINED",
            udtSchema: "public",
            resolvedType: "ENUM",
            allowedValues: ["new", "done"]
        )
        #expect(spelling.dataType == "status")
        #expect(spelling.classificationTypeName == "ENUM")
    }

    @Test("An array of enums keeps the array hint")
    func enumArrayKeepsItsHint() {
        let spelling = resolve(
            declared: "status[]",
            informationSchema: "ARRAY",
            udtSchema: "public",
            resolvedType: "ENUM[]",
            allowedValues: ["new", "done"]
        )
        #expect(spelling.dataType == "status[]")
        #expect(spelling.classificationTypeName == "ENUM[]")
    }

    @Test("A domain shows the domain's name and is classified by its base type")
    func domainKeepsItsName() {
        let spelling = resolve(
            declared: "posint",
            informationSchema: "integer",
            domain: "posint",
            resolvedType: "INTEGER"
        )
        #expect(spelling.dataType == "posint")
        #expect(spelling.classificationTypeName == "INTEGER")
    }

    @Test("A PostGIS column shows its qualified spelling with the SRID and is classified as geometry")
    func extensionTypeKeepsItsQualifiedSpelling() {
        let spelling = resolve(
            declared: "public.geometry(Point,4326)",
            informationSchema: "USER-DEFINED",
            udtSchema: "public",
            resolvedType: "geometry"
        )
        #expect(spelling.dataType == "public.geometry(Point,4326)")
        #expect(spelling.classificationTypeName == "geometry")
    }

    @Test("An array of a pg_catalog base type needs no hint, because the element classifies the same")
    func catalogArrayNeedsNoHint() {
        let spelling = resolve(
            declared: "character varying(20)[]",
            informationSchema: "ARRAY",
            resolvedType: "varchar[]"
        )
        #expect(spelling.dataType == "character varying(20)[]")
        #expect(spelling.classificationTypeName == nil)
    }

    @Test("An array the resolver could not name an element for keeps its ARRAY hint")
    func arrayWithoutABaseElementKeepsTheResolverName() {
        let spelling = resolve(
            declared: "int4range[]",
            informationSchema: "ARRAY",
            resolvedType: "ARRAY"
        )
        #expect(spelling.dataType == "int4range[]")
        #expect(spelling.classificationTypeName == "ARRAY")
    }

    @Test("A row with no declared spelling falls back to the classified name for both")
    func missingDeclaredSpellingFallsBack() {
        for declared in [nil, ""] {
            let spelling = resolve(
                declared: declared,
                informationSchema: "USER-DEFINED",
                udtSchema: "public",
                resolvedType: "ENUM",
                allowedValues: ["new"]
            )
            #expect(spelling.dataType == "ENUM")
            #expect(spelling.classificationTypeName == nil)
        }
    }
}

@Suite("PostgreSQLSchemaQueries schema-relative read")
struct PostgreSQLSchemaRelativeReadTests {
    @Test("The prefix narrows the path to pg_catalog and the schema, with the identifier quoted")
    func prefixQuotesTheSchema() {
        #expect(
            PostgreSQLSchemaQueries.schemaRelativeReadPrefix(schema: "sales")
                == "SET LOCAL search_path = pg_catalog, \"sales\"; "
        )
        #expect(
            PostgreSQLSchemaQueries.schemaRelativeReadPrefix(schema: "Weird \"Schema\"")
                == "SET LOCAL search_path = pg_catalog, \"Weird \"\"Schema\"\"\"; "
        )
    }

    @Test("A type an extension owns is qualified, taken from the element type for an array")
    func extensionTypesAreQualified() {
        let expression = PostgreSQLSchemaQueries.declaredType(attribute: "a")
        #expect(expression.contains("pg_catalog.format_type(a.atttypid, a.atttypmod)"))
        #expect(expression.contains("dd.deptype = 'e'"))
        #expect(expression.contains("pg_catalog.pg_type_is_visible(dt.oid)"))
        #expect(expression.contains("dtn.nspname <> 'pg_catalog'"))
        let collapsed = expression.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(collapsed.contains(
            "dd.objid = CASE WHEN dt.typlen = -1 AND dt.typelem <> 0 THEN dt.typelem ELSE dt.oid END"
        ))
        #expect(expression.contains("pg_catalog.quote_ident(dtn.nspname) || '.'"))
    }
}
