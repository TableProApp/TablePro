//
//  PostGISSpatialRewriteTests.swift
//  TableProTests
//

import Foundation
import Testing

@Suite("PostGISSpatialRewrite.conversionQuery")
struct PostGISConversionQueryTests {
    private let geometry = PostGISType(name: "geometry", schema: "public")
    private let geography = PostGISType(name: "geography", schema: "gis")

    @Test("geometry casts each element to the probed geometry type")
    func geometryQuery() throws {
        let query = try #require(PostGISSpatialRewrite.conversionQuery(for: geometry))
        #expect(query.contains("\"public\".ST_AsEWKT(($1::text[])[i]::\"public\".\"geometry\")"))
    }

    @Test("geography casts each element to the probed geography type")
    func geographyQuery() throws {
        let query = try #require(PostGISSpatialRewrite.conversionQuery(for: geography))
        #expect(query.contains("\"gis\".ST_AsEWKT(($1::text[])[i]::\"gis\".\"geography\")"))
    }

    @Test("Unknown type name returns nil")
    func unknown() {
        #expect(PostGISSpatialRewrite.conversionQuery(for: PostGISType(name: "text", schema: "public")) == nil)
        #expect(PostGISSpatialRewrite.conversionQuery(for: PostGISType(name: "raster", schema: "public")) == nil)
        #expect(PostGISSpatialRewrite.conversionQuery(for: PostGISType(name: "", schema: "public")) == nil)
    }

    @Test("Elements are walked by generate_subscripts, which 9.1 has, in array order")
    func portableOrdering() throws {
        let query = try #require(PostGISSpatialRewrite.conversionQuery(for: geometry))
        #expect(query.contains("pg_catalog.generate_subscripts($1::text[], 1) AS i ORDER BY i"))
        #expect(!query.contains("WITH ORDINALITY"))
        #expect(!query.contains("unnest"))
    }

    @Test("A schema name is quoted as an identifier, not interpolated")
    func schemaIsQuoted() throws {
        let query = try #require(
            PostGISSpatialRewrite.conversionQuery(for: PostGISType(name: "geometry", schema: "we\"ird"))
        )
        #expect(query.contains("\"we\"\"ird\".\"geometry\""))
    }

    @Test("Conversion query reads a single bound parameter, never the user statement")
    func singleParameter() throws {
        let query = try #require(PostGISSpatialRewrite.conversionQuery(for: geometry))
        #expect(query.contains("$1"))
        #expect(!query.contains("$2"))
    }

    @Test("The savepoint that isolates the conversion inside a transaction is released on both paths")
    func savepointStatements() {
        #expect(PostGISSpatialRewrite.savepoint == "SAVEPOINT tablepro_spatial_render")
        #expect(PostGISSpatialRewrite.rollbackToSavepoint == "ROLLBACK TO SAVEPOINT tablepro_spatial_render")
        #expect(PostGISSpatialRewrite.releaseSavepoint == "RELEASE SAVEPOINT tablepro_spatial_render")
    }

    @Test("The probe reads each spatial type's namespace")
    func probeReadsNamespace() {
        #expect(PostGISSpatialRewrite.probeQuery.contains("n.nspname"))
        #expect(PostGISSpatialRewrite.probeQuery.contains("JOIN pg_catalog.pg_namespace n"))
    }
}

@Suite("PostGISSpatialRewrite.arrayLiteral")
struct PostGISArrayLiteralTests {
    @Test("Single hex value is quoted")
    func singleValue() {
        #expect(PostGISSpatialRewrite.arrayLiteral(from: ["0101"]) == "{\"0101\"}")
    }

    @Test("Multiple values are comma-separated and order-preserved")
    func multipleValues() {
        #expect(PostGISSpatialRewrite.arrayLiteral(from: ["AA", "BB", "CC"]) == "{\"AA\",\"BB\",\"CC\"}")
    }

    @Test("Nil becomes an unquoted NULL element")
    func nullElement() {
        #expect(PostGISSpatialRewrite.arrayLiteral(from: ["AA", nil, "CC"]) == "{\"AA\",NULL,\"CC\"}")
    }

    @Test("All-nil values produce an all-NULL literal")
    func allNull() {
        #expect(PostGISSpatialRewrite.arrayLiteral(from: [nil, nil]) == "{NULL,NULL}")
    }

    @Test("Empty input is an empty array literal")
    func empty() {
        #expect(PostGISSpatialRewrite.arrayLiteral(from: []) == "{}")
    }

    @Test("Embedded double quote is backslash-escaped")
    func embeddedQuote() {
        #expect(PostGISSpatialRewrite.arrayLiteral(from: ["a\"b"]) == "{\"a\\\"b\"}")
    }

    @Test("Embedded backslash is doubled")
    func embeddedBackslash() {
        #expect(PostGISSpatialRewrite.arrayLiteral(from: ["a\\b"]) == "{\"a\\\\b\"}")
    }
}
