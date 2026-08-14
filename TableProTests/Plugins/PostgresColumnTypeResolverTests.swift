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

    @Test("An enum with no catalog entry keeps the existing named fallback")
    func fallsBackForUnknownEnum() {
        let resolution = resolve("USER-DEFINED", schema: "app", udt: "nope")
        #expect(resolution.dataType == "ENUM(nope)")
        #expect(resolution.allowedValues == nil)
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
