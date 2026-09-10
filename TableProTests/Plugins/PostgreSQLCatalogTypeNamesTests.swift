//
//  PostgreSQLCatalogTypeNamesTests.swift
//  TableProTests
//

import Foundation
import Testing

@Suite("PostgreSQL catalog type names")
struct PostgreSQLCatalogTypeNamesTests {
    private func row(
        oid: UInt32 = 16_385,
        name: String = "mood",
        kind: Character = "b",
        domainBase: String? = nil,
        elementName: String? = nil,
        elementKind: Character? = nil,
        elementDomainBase: String? = nil
    ) -> PostgreSQLCatalogTypeNames.Row {
        PostgreSQLCatalogTypeNames.Row(
            oid: oid,
            name: name,
            kind: kind,
            domainBase: domainBase,
            elementName: elementName,
            elementKind: elementKind,
            elementDomainBase: elementDomainBase
        )
    }

    @Test("An enum and an enum array spell the way the connect-time probe does")
    func enumSpellings() {
        #expect(PostgreSQLCatalogTypeNames.typeName(for: row(name: "mood", kind: "e")) == "ENUM(mood)")
        #expect(
            PostgreSQLCatalogTypeNames.typeName(for: row(name: "_mood", elementName: "mood", elementKind: "e"))
                == "ENUM[](mood)"
        )
        #expect(PostgreSQLCatalogTypeNames.enumTypeName("mood") == "ENUM(mood)")
        #expect(PostgreSQLCatalogTypeNames.enumArrayTypeName("mood") == "ENUM[](mood)")
    }

    @Test("A domain reads as its base type, alone and in an array")
    func domainSpellings() {
        #expect(PostgreSQLCatalogTypeNames.typeName(for: row(name: "positive", kind: "d", domainBase: "integer")) == "integer")
        let array = row(name: "_positive", elementName: "positive", elementKind: "d", elementDomainBase: "integer")
        #expect(PostgreSQLCatalogTypeNames.typeName(for: array) == "integer[]")
    }

    @Test("A composite, a range and an unlisted base type keep their own name")
    func ownNameSpellings() {
        #expect(PostgreSQLCatalogTypeNames.typeName(for: row(name: "point3d", kind: "c")) == "point3d")
        #expect(PostgreSQLCatalogTypeNames.typeName(for: row(name: "floatrange", kind: "r")) == "floatrange")
        #expect(PostgreSQLCatalogTypeNames.typeName(for: row(name: "money", kind: "b")) == "money")
        #expect(PostgreSQLCatalogTypeNames.typeName(for: row(name: "_point3d", elementName: "point3d", elementKind: "c")) == "point3d[]")
    }

    @Test("The lookup lists each oid once, in order, and tells an array by its element and length")
    func lookupQueryShape() throws {
        let sql = try #require(PostgreSQLCatalogTypeNames.lookupQuery(oids: [16_390, 16_385, 16_390]))
        #expect(sql.contains("WHERE t.oid IN (16385, 16390)"))
        #expect(sql.contains("LEFT JOIN pg_catalog.pg_type el ON el.oid = t.typelem AND t.typlen = -1"))
        #expect(sql.contains("pg_catalog.format_type(t.typbasetype, t.typtypmod)"))
        #expect(!sql.contains("typcategory"))
        #expect(PostgreSQLCatalogTypeNames.lookupQuery(oids: []) == nil)
    }

    @Test("A lookup row parses from its text columns and a short or oid-less row is skipped")
    func rowParsing() {
        let parsed = PostgreSQLCatalogTypeNames.row(fromColumns: ["16385", "mood", "e", nil, nil, nil, nil])
        #expect(parsed == row(kind: "e"))
        #expect(PostgreSQLCatalogTypeNames.row(fromColumns: [nil, "mood", "e", nil, nil, nil, nil]) == nil)
        #expect(PostgreSQLCatalogTypeNames.row(fromColumns: ["16385", "mood"]) == nil)
    }

    @Test("The enum probe maps a scalar and its array oid, and skips a server that gives no array oid")
    func enumProbeNames() {
        let names = PostgreSQLCatalogTypeNames.enumProbeNames(rows: [
            ["16385", "16384", "mood"],
            ["16390", "0", "status"],
            [nil, "1", "broken"]
        ])
        #expect(names == [16_385: "ENUM(mood)", 16_384: "ENUM[](mood)", 16_390: "ENUM(status)"])
    }

    /// An oid the catalog does not answer for is remembered as unresolved, or every later result
    /// with that column would ask again.
    @Test("Every oid asked about gets a name, resolved or not")
    func namesCoverEveryOid() {
        let names = PostgreSQLCatalogTypeNames.names(
            for: [16_385, 16_386, 99_999],
            rows: [
                ["16385", "mood", "e", nil, nil, nil, nil],
                ["16386", "_mood", "b", nil, "mood", "e", nil]
            ]
        )
        #expect(names == [16_385: "ENUM(mood)", 16_386: "ENUM[](mood)", 99_999: "unknown"])
        #expect(PostgreSQLCatalogTypeNames.names(for: [7], rows: []) == [7: PostgreSQLCatalogTypeNames.unresolved])
    }
}
