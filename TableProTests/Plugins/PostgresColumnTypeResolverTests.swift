//
//  PostgresColumnTypeResolverTests.swift
//  TableProTests
//
//  Tests for resolving PostgreSQL column types to enum and array metadata.
//

import Foundation
import TableProPluginKit
import Testing

@Suite("Postgres Column Type Resolver")
struct PostgresColumnTypeResolverTests {
    private let enumLabels = [
        "app.mood": ["sad", "ok", "happy"],
        "public.status": ["on", "off"]
    ]

    private let arrayTypes: [String: PostgresArrayTypeInfo] = [
        "app._mood": PostgresArrayTypeInfo(elementTypeName: "mood", elementTypeKind: "e"),
        "pg_catalog._text": PostgresArrayTypeInfo(elementTypeName: "text", elementTypeKind: "b"),
        "pg_catalog._int4": PostgresArrayTypeInfo(elementTypeName: "int4", elementTypeKind: "b"),
        "public._pair": PostgresArrayTypeInfo(elementTypeName: "pair", elementTypeKind: "c")
    ]

    private func resolve(
        _ rawDataType: String,
        schema: String?,
        udt: String?
    ) -> PostgresColumnTypeResolver.Resolution {
        PostgresColumnTypeResolver.resolve(
            rawDataType: rawDataType,
            udtSchema: schema,
            udtName: udt,
            enumLabelsByQualifiedName: enumLabels,
            arrayTypesByQualifiedName: arrayTypes
        )
    }

    @Test("A scalar enum column carries its labels in declaration order")
    func resolvesScalarEnum() {
        let resolution = resolve("USER-DEFINED", schema: "app", udt: "mood")
        #expect(resolution.dataType == "ENUM")
        #expect(resolution.allowedValues == ["sad", "ok", "happy"])
    }

    @Test("An enum defined outside the table's schema still resolves")
    func resolvesEnumFromAnotherSchema() {
        let resolution = resolve("USER-DEFINED", schema: "public", udt: "status")
        #expect(resolution.dataType == "ENUM")
        #expect(resolution.allowedValues == ["on", "off"])
    }

    @Test("An array of an enum reports the element's labels")
    func resolvesEnumArray() {
        let resolution = resolve("ARRAY", schema: "app", udt: "_mood")
        #expect(resolution.dataType == "ENUM[]")
        #expect(resolution.allowedValues == ["sad", "ok", "happy"])
    }

    @Test("An array of a base type reports the element type name")
    func resolvesScalarArray() {
        #expect(resolve("ARRAY", schema: "pg_catalog", udt: "_text").dataType == "text[]")
        #expect(resolve("ARRAY", schema: "pg_catalog", udt: "_text").allowedValues == nil)
        #expect(resolve("ARRAY", schema: "pg_catalog", udt: "_int4").dataType == "int4[]")
    }

    @Test("An array the editor cannot represent falls back to today's behaviour")
    func leavesUnsupportedArraysAlone() {
        #expect(resolve("ARRAY", schema: "public", udt: "_pair").dataType == "ARRAY")
        #expect(resolve("ARRAY", schema: "public", udt: "_mystery").dataType == "ARRAY")
        #expect(resolve("ARRAY", schema: "public", udt: "_pair").allowedValues == nil)
    }

    /// A composite, a range and an extension's base type all reach the resolver as
    /// `USER-DEFINED`, exactly like an enum. Only an enum has a catalog entry, so a name without
    /// one is a type of another kind and is shown as itself rather than as an enum it is not.
    @Test("A user-defined type with no enum entry keeps its own name")
    func keepsNameForNonEnumUserType() {
        for udt in ["point3d", "floatrange", "hstore", "geometry"] {
            let resolution = resolve("USER-DEFINED", schema: "app", udt: udt)
            #expect(resolution.dataType == udt)
            #expect(resolution.allowedValues == nil)
        }
    }

    @Test("An enum declared with no labels is still an enum")
    func resolvesEmptyEnum() {
        let resolution = PostgresColumnTypeResolver.resolve(
            rawDataType: "USER-DEFINED",
            udtSchema: "app",
            udtName: "empty",
            enumLabelsByQualifiedName: ["app.empty": []],
            arrayTypesByQualifiedName: [:]
        )
        #expect(resolution.dataType == "ENUM")
        #expect(resolution.allowedValues?.isEmpty == true)
    }

    /// The catalog read has to list an enum with no labels, or the resolver could not tell it
    /// from a composite.
    @Test("The enum label query lists every enum, labels or not")
    func enumLabelQueryListsLabellessEnums() {
        let sql = PostgreSQLSchemaQueries.enumLabelQuery
        #expect(sql.contains("LEFT JOIN pg_catalog.pg_enum"))
        #expect(sql.contains("WHERE t.typtype = 'e'"))
    }

    @Test("Ordinary columns pass through unchanged")
    func passesThroughOrdinaryTypes() {
        #expect(resolve("text", schema: "pg_catalog", udt: "text").dataType == "TEXT")
        #expect(resolve("integer", schema: "pg_catalog", udt: "int4").dataType == "INTEGER")
        #expect(resolve("timestamp without time zone", schema: nil, udt: nil).dataType
            == "TIMESTAMP WITHOUT TIME ZONE")
        #expect(resolve("text", schema: "pg_catalog", udt: "text").allowedValues == nil)
    }

    @Test("Qualified names join schema and type, and tolerate a missing schema")
    func buildsQualifiedNames() {
        #expect(PostgresColumnTypeResolver.qualifiedName(schema: "app", name: "mood") == "app.mood")
        #expect(PostgresColumnTypeResolver.qualifiedName(schema: nil, name: "mood") == "mood")
        #expect(PostgresColumnTypeResolver.qualifiedName(schema: "", name: "mood") == "mood")
    }
}
