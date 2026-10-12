//
//  OracleTypeCatalogTests.swift
//  TableProTests
//
//  The Oracle plugin's one type list, and what it knows about a type from its name. Every spelling below was measured
//  against Oracle 23ai.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct OracleTypeCatalogTests {
    private static let legacyDataTypes = [
        "NUMBER", "INTEGER", "SMALLINT", "FLOAT", "BINARY_FLOAT", "BINARY_DOUBLE",
        "CHAR", "VARCHAR2", "NCHAR", "NVARCHAR2", "CLOB", "NCLOB", "LONG",
        "BLOB", "RAW", "LONG RAW", "BFILE",
        "DATE", "TIMESTAMP", "TIMESTAMP WITH TIME ZONE", "TIMESTAMP WITH LOCAL TIME ZONE",
        "INTERVAL YEAR TO MONTH", "INTERVAL DAY TO SECOND",
        "BOOLEAN", "ROWID", "UROWID", "XMLTYPE", "SDO_GEOMETRY"
    ]

    @Test("The picker offers BOOLEAN, JSON and VECTOR")
    func pickerOffersNewTypes() {
        #expect(OracleTypeCatalog.columnTypesByCategory["Boolean"] == ["BOOLEAN"])
        #expect(OracleTypeCatalog.columnTypesByCategory["JSON"] == ["JSON"])
        #expect(OracleTypeCatalog.columnTypesByCategory["Vector"] == ["VECTOR"])
    }

    @Test("The picker keeps every category it had")
    func pickerKeepsCategories() {
        let categories = OracleTypeCatalog.columnTypesByCategory
        #expect(categories["Integer"] == ["NUMBER", "INTEGER", "INT", "SMALLINT"])
        #expect(categories["String"] == ["VARCHAR2", "NVARCHAR2", "CHAR", "NCHAR", "CLOB", "NCLOB", "LONG"])
        #expect(categories["XML"] == ["XMLTYPE"])
        #expect(categories["Spatial"] == ["SDO_GEOMETRY"])
        #expect(categories["Other"] == ["ROWID", "UROWID"])
    }

    @Test("Completion types are the picker's types and keep every earlier entry")
    func dataTypesDeriveFromCategories() {
        let dataTypes = OracleTypeCatalog.dataTypes
        #expect(dataTypes == Set(OracleTypeCatalog.columnTypesByCategory.values.flatMap { $0 }))
        #expect(Set(Self.legacyDataTypes).isSubset(of: dataTypes))
        #expect(dataTypes.isSuperset(of: ["INT", "DECIMAL", "NUMERIC", "REAL", "DOUBLE PRECISION", "JSON", "VECTOR"]))
        #expect(dataTypes.count == 35)
    }

    @Test("A type name matches on its base with every modifier removed")
    func baseTypeName() {
        #expect(OracleTypeCatalog.baseTypeName("TIMESTAMP(6) WITH TIME ZONE") == "TIMESTAMP WITH TIME ZONE")
        #expect(OracleTypeCatalog.baseTypeName("timestamp with local time zone") == "TIMESTAMP WITH LOCAL TIME ZONE")
        #expect(OracleTypeCatalog.baseTypeName("INTERVAL DAY(2) TO SECOND(6)") == "INTERVAL DAY TO SECOND")
        #expect(OracleTypeCatalog.baseTypeName("VARCHAR2(50 BYTE)") == "VARCHAR2")
        #expect(OracleTypeCatalog.baseTypeName("NUMBER(*,2)") == "NUMBER")
        #expect(OracleTypeCatalog.baseTypeName("date") == "DATE")
    }

    @Test("A DATE result column classifies as TIMESTAMP(0), nothing else gets a hint")
    func resultHints() {
        #expect(OracleTypeCatalog.resultClassificationTypeName(forHeaderType: "date") == "TIMESTAMP(0)")
        #expect(OracleTypeCatalog.resultClassificationTypeName(forHeaderType: "timestamp") == nil)
        #expect(OracleTypeCatalog.resultClassificationTypeName(forHeaderType: "varchar2") == nil)

        let meta = OracleTypeCatalog.resultColumnMeta(columns: ["ID", "CREATED"], typeNames: ["number", "date"])
        #expect(meta?.map(\.classificationTypeName) == [nil, "TIMESTAMP(0)"])
        #expect(meta?.map(\.dataType) == ["number", "date"])
        #expect(OracleTypeCatalog.resultColumnMeta(columns: ["ID"], typeNames: ["number"]) == nil)
        #expect(OracleTypeCatalog.resultColumnMeta(columns: ["A", "B"], typeNames: ["date"]) == nil)
    }

    @Test("A bounded result gains the hints the stream header could not carry")
    func boundedResultHints() {
        let result = PluginQueryResult(
            columns: ["D"], columnTypeNames: ["date"], rows: [[.text("2026-10-06 15:22:20")]],
            rowsAffected: 0, timing: PluginQueryTiming(total: 1), isTruncated: true
        )
        let hinted = result.withOracleClassificationHints()
        #expect(hinted.columnMeta?.first?.classificationTypeName == "TIMESTAMP(0)")
        #expect(hinted.isTruncated)
        #expect(hinted.rows.count == 1)

        let plain = PluginQueryResult(
            columns: ["N"], columnTypeNames: ["number"], rows: [], rowsAffected: 0, timing: PluginQueryTiming(total: 0)
        )
        #expect(plain.withOracleClassificationHints().columnMeta == nil)
    }

    @Test("Only an owner-qualified, quoted or REF type gets its own DDL spelling")
    func ddlSpelling() {
        #expect(OracleTypeCatalog.ddlSpelling(forDeclaredType: "\"SYS\".\"XMLTYPE\"") == "\"SYS\".\"XMLTYPE\"")
        #expect(OracleTypeCatalog.ddlSpelling(forDeclaredType: "\"Hunt_Mixed\"") == "\"Hunt_Mixed\"")
        #expect(OracleTypeCatalog.ddlSpelling(forDeclaredType: "REF HUNT_ADDR") == "REF HUNT_ADDR")
        #expect(OracleTypeCatalog.ddlSpelling(forDeclaredType: "VARCHAR2(50 CHAR)") == nil)
        #expect(OracleTypeCatalog.ddlSpelling(forDeclaredType: "HUNT_ADDR") == nil)
    }
}
