//
//  PostGISSpatialRewriteTests.swift
//  TableProTests
//

import Foundation
import Testing

@Suite("PostGISSpatialRewrite.conversionQuery")
struct PostGISConversionQueryTests {
    @Test("geometry maps to the geometry conversion query")
    func geometry() {
        #expect(PostGISSpatialRewrite.conversionQuery(forTypeName: "geometry")
            == PostGISSpatialRewrite.geometryConversionQuery)
    }

    @Test("geography maps to the geography conversion query")
    func geography() {
        #expect(PostGISSpatialRewrite.conversionQuery(forTypeName: "geography")
            == PostGISSpatialRewrite.geographyConversionQuery)
    }

    @Test("Unknown type name returns nil")
    func unknown() {
        #expect(PostGISSpatialRewrite.conversionQuery(forTypeName: "text") == nil)
        #expect(PostGISSpatialRewrite.conversionQuery(forTypeName: "raster") == nil)
        #expect(PostGISSpatialRewrite.conversionQuery(forTypeName: "") == nil)
    }

    @Test("geometry query applies ST_AsEWKT over a text array parameter cast per element")
    func geometryQueryShape() {
        let query = PostGISSpatialRewrite.geometryConversionQuery
        #expect(query.contains("ST_AsEWKT(t::geometry)"))
        #expect(query.contains("unnest($1::text[])"))
        #expect(query.contains("ORDER BY ord"))
    }

    @Test("geography query casts each element to geography")
    func geographyQueryShape() {
        let query = PostGISSpatialRewrite.geographyConversionQuery
        #expect(query.contains("ST_AsEWKT(t::geography)"))
        #expect(query.contains("unnest($1::text[])"))
    }

    @Test("Conversion query reads a single bound parameter, never the user statement")
    func singleParameter() {
        #expect(PostGISSpatialRewrite.geometryConversionQuery.contains("$1"))
        #expect(!PostGISSpatialRewrite.geometryConversionQuery.contains("$2"))
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
