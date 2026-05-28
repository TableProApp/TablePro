//
//  PostGISSpatialRewriteTests.swift
//  TableProTests
//

import Foundation
import Testing

@Suite("PostGISSpatialRewrite.quoteIdentifier")
struct PostGISSpatialRewriteQuoteIdentifierTests {
    @Test("Plain ASCII identifier wraps in double quotes")
    func plainAscii() {
        #expect(PostGISSpatialRewrite.quoteIdentifier("geom") == "\"geom\"")
    }

    @Test("Embedded double quote is doubled")
    func embeddedQuote() {
        #expect(PostGISSpatialRewrite.quoteIdentifier("na\"me") == "\"na\"\"me\"")
    }

    @Test("Multiple embedded quotes are all doubled")
    func multipleEmbeddedQuotes() {
        #expect(PostGISSpatialRewrite.quoteIdentifier("\"hi\"") == "\"\"\"hi\"\"\"")
    }

    @Test("Empty string yields empty quoted identifier")
    func emptyString() {
        #expect(PostGISSpatialRewrite.quoteIdentifier("") == "\"\"")
    }

    @Test("Mixed case preserved")
    func mixedCase() {
        #expect(PostGISSpatialRewrite.quoteIdentifier("MyColumn") == "\"MyColumn\"")
    }
}

@Suite("PostGISSpatialRewrite.hasUniqueColumnNames")
struct PostGISSpatialRewriteUniqueColumnsTests {
    @Test("All unique returns true")
    func allUnique() {
        #expect(PostGISSpatialRewrite.hasUniqueColumnNames(["id", "name", "geom"]))
    }

    @Test("Empty list is trivially unique")
    func emptyIsUnique() {
        #expect(PostGISSpatialRewrite.hasUniqueColumnNames([]))
    }

    @Test("Single element is unique")
    func singleElement() {
        #expect(PostGISSpatialRewrite.hasUniqueColumnNames(["geom"]))
    }

    @Test("Duplicate names returns false")
    func duplicateFails() {
        #expect(!PostGISSpatialRewrite.hasUniqueColumnNames(["id", "name", "id"]))
    }

    @Test("Case-sensitive: id and ID are distinct")
    func caseSensitive() {
        #expect(PostGISSpatialRewrite.hasUniqueColumnNames(["id", "ID"]))
    }
}

@Suite("PostGISSpatialRewrite.startsWithSelectWithOrValues")
struct PostGISSpatialRewriteLeadingKeywordTests {
    @Test("SELECT accepted")
    func selectAccepted() {
        #expect(PostGISSpatialRewrite.startsWithSelectWithOrValues("SELECT 1"))
    }

    @Test("Lowercase select accepted")
    func lowercaseSelect() {
        #expect(PostGISSpatialRewrite.startsWithSelectWithOrValues("select 1"))
    }

    @Test("WITH cte accepted")
    func withCte() {
        #expect(PostGISSpatialRewrite.startsWithSelectWithOrValues("WITH cte AS (SELECT 1) SELECT * FROM cte"))
    }

    @Test("VALUES accepted")
    func valuesAccepted() {
        #expect(PostGISSpatialRewrite.startsWithSelectWithOrValues("VALUES (1, 2, 3)"))
    }

    @Test("Leading whitespace tolerated")
    func leadingWhitespace() {
        #expect(PostGISSpatialRewrite.startsWithSelectWithOrValues("   \n\t SELECT 1"))
    }

    @Test("Leading line comment tolerated")
    func leadingLineComment() {
        #expect(PostGISSpatialRewrite.startsWithSelectWithOrValues("-- comment\nSELECT 1"))
    }

    @Test("Leading block comment tolerated")
    func leadingBlockComment() {
        #expect(PostGISSpatialRewrite.startsWithSelectWithOrValues("/* hi */ SELECT 1"))
    }

    @Test("Nested block comment tolerated")
    func nestedBlockComment() {
        #expect(PostGISSpatialRewrite.startsWithSelectWithOrValues("/* outer /* inner */ outer */ SELECT 1"))
    }

    @Test("INSERT rejected")
    func insertRejected() {
        #expect(!PostGISSpatialRewrite.startsWithSelectWithOrValues("INSERT INTO foo VALUES (1)"))
    }

    @Test("UPDATE rejected")
    func updateRejected() {
        #expect(!PostGISSpatialRewrite.startsWithSelectWithOrValues("UPDATE foo SET x = 1"))
    }

    @Test("DELETE rejected")
    func deleteRejected() {
        #expect(!PostGISSpatialRewrite.startsWithSelectWithOrValues("DELETE FROM foo"))
    }

    @Test("Empty string rejected")
    func emptyRejected() {
        #expect(!PostGISSpatialRewrite.startsWithSelectWithOrValues(""))
    }

    @Test("Whitespace-only rejected")
    func whitespaceOnlyRejected() {
        #expect(!PostGISSpatialRewrite.startsWithSelectWithOrValues("   "))
    }

    @Test("Comments-only rejected")
    func commentsOnlyRejected() {
        #expect(!PostGISSpatialRewrite.startsWithSelectWithOrValues("-- only a comment"))
    }
}

@Suite("PostGISSpatialRewrite.hasTopLevelStatementSeparator")
struct PostGISSpatialRewriteSeparatorTests {
    @Test("No semicolon is single statement")
    func noSemicolon() {
        #expect(!PostGISSpatialRewrite.hasTopLevelStatementSeparator("SELECT 1"))
    }

    @Test("Trailing semicolon only is single statement")
    func trailingSemicolon() {
        #expect(!PostGISSpatialRewrite.hasTopLevelStatementSeparator("SELECT 1;"))
    }

    @Test("Trailing semicolon with whitespace is single statement")
    func trailingSemicolonWithSpace() {
        #expect(!PostGISSpatialRewrite.hasTopLevelStatementSeparator("SELECT 1;   \n  "))
    }

    @Test("Real multi-statement is detected")
    func realMultiStatement() {
        #expect(PostGISSpatialRewrite.hasTopLevelStatementSeparator("SELECT 1; SELECT 2"))
    }

    @Test("Semicolon inside single-quoted string is ignored")
    func semicolonInStringLiteral() {
        #expect(!PostGISSpatialRewrite.hasTopLevelStatementSeparator("SELECT 'a;b' FROM foo"))
    }

    @Test("Escaped quote in string keeps string open across embedded semicolons")
    func escapedQuoteInString() {
        #expect(!PostGISSpatialRewrite.hasTopLevelStatementSeparator("SELECT 'it''s; fine' FROM foo"))
    }

    @Test("Semicolon inside double-quoted identifier is ignored")
    func semicolonInIdentifier() {
        #expect(!PostGISSpatialRewrite.hasTopLevelStatementSeparator("SELECT \"co;l\" FROM foo"))
    }

    @Test("Escaped double quote in identifier handled")
    func escapedDoubleQuote() {
        #expect(!PostGISSpatialRewrite.hasTopLevelStatementSeparator("SELECT \"co\"\"l;n\" FROM foo"))
    }

    @Test("Semicolon inside line comment is ignored")
    func semicolonInLineComment() {
        #expect(!PostGISSpatialRewrite.hasTopLevelStatementSeparator("SELECT 1 -- ;\nFROM foo"))
    }

    @Test("Semicolon inside block comment is ignored")
    func semicolonInBlockComment() {
        #expect(!PostGISSpatialRewrite.hasTopLevelStatementSeparator("SELECT 1 /* ; */ FROM foo"))
    }

    @Test("Semicolon inside nested block comment is ignored")
    func semicolonInNestedBlockComment() {
        #expect(!PostGISSpatialRewrite.hasTopLevelStatementSeparator("SELECT 1 /* /* ; */ */ FROM foo"))
    }

    @Test("Semicolon inside dollar quote is ignored")
    func semicolonInDollarQuote() {
        #expect(!PostGISSpatialRewrite.hasTopLevelStatementSeparator("SELECT $$a;b$$ FROM foo"))
    }

    @Test("Semicolon inside tagged dollar quote is ignored")
    func semicolonInTaggedDollarQuote() {
        #expect(!PostGISSpatialRewrite.hasTopLevelStatementSeparator("SELECT $tag$a;b$tag$ FROM foo"))
    }

    @Test("Dollar prefix that is not a dollar quote does not consume the rest of the query")
    func bareDollarTreatedAsLiteral() {
        #expect(PostGISSpatialRewrite.hasTopLevelStatementSeparator("SELECT $1; SELECT 2"))
    }

    @Test("Dollar quote tag starting with digit is rejected (not a valid tag)")
    func dollarTagStartingWithDigit() {
        #expect(PostGISSpatialRewrite.hasTopLevelStatementSeparator("SELECT $1$; SELECT 2"))
    }

    @Test("Two trailing semicolons still single statement")
    func twoTrailingSemicolons() {
        #expect(!PostGISSpatialRewrite.hasTopLevelStatementSeparator("SELECT 1;;"))
    }

    @Test("Statement after trailing whitespace and second semicolon is multi")
    func contentAfterDoubleSemicolons() {
        #expect(PostGISSpatialRewrite.hasTopLevelStatementSeparator("SELECT 1; ; SELECT 2"))
    }
}

@Suite("PostGISSpatialRewrite.isSafeToWrap")
struct PostGISSpatialRewriteSafeToWrapTests {
    @Test("Simple SELECT with unique columns is safe")
    func simpleSelectSafe() {
        #expect(PostGISSpatialRewrite.isSafeToWrap(query: "SELECT id, geom FROM places", columns: ["id", "geom"]))
    }

    @Test("Duplicate columns blocks wrap")
    func duplicateColumnsUnsafe() {
        #expect(!PostGISSpatialRewrite.isSafeToWrap(
            query: "SELECT a.id, b.id FROM a JOIN b ON true",
            columns: ["id", "id"]
        ))
    }

    @Test("INSERT statement blocks wrap")
    func insertUnsafe() {
        #expect(!PostGISSpatialRewrite.isSafeToWrap(
            query: "INSERT INTO foo VALUES (1) RETURNING geom",
            columns: ["geom"]
        ))
    }

    @Test("Multi-statement blocks wrap")
    func multiStatementUnsafe() {
        #expect(!PostGISSpatialRewrite.isSafeToWrap(
            query: "SELECT geom FROM a; SELECT geom FROM b",
            columns: ["geom"]
        ))
    }

    @Test("WITH cte SELECT is safe")
    func cteSafe() {
        #expect(PostGISSpatialRewrite.isSafeToWrap(
            query: "WITH cte AS (SELECT geom FROM a) SELECT * FROM cte",
            columns: ["geom"]
        ))
    }
}

@Suite("PostGISSpatialRewrite.buildWrappedQuery")
struct PostGISSpatialRewriteBuildWrappedQueryTests {
    @Test("Single spatial column wraps with ST_AsEWKT")
    func singleSpatial() {
        let sql = PostGISSpatialRewrite.buildWrappedQuery(
            originalQuery: "SELECT id, geom FROM places",
            columns: ["id", "geom"],
            spatialIndices: [1]
        )
        #expect(sql == "SELECT \"id\", ST_AsEWKT(\"geom\") AS \"geom\" FROM (SELECT id, geom FROM places) AS _tp_rewrite")
    }

    @Test("Multiple spatial columns each wrapped")
    func multipleSpatial() {
        let sql = PostGISSpatialRewrite.buildWrappedQuery(
            originalQuery: "SELECT a, b, c FROM t",
            columns: ["a", "b", "c"],
            spatialIndices: [0, 2]
        )
        #expect(sql == "SELECT ST_AsEWKT(\"a\") AS \"a\", \"b\", ST_AsEWKT(\"c\") AS \"c\" FROM (SELECT a, b, c FROM t) AS _tp_rewrite")
    }

    @Test("Zero spatial columns still wraps but only with identifiers")
    func zeroSpatial() {
        let sql = PostGISSpatialRewrite.buildWrappedQuery(
            originalQuery: "SELECT id, name FROM t",
            columns: ["id", "name"],
            spatialIndices: []
        )
        #expect(sql == "SELECT \"id\", \"name\" FROM (SELECT id, name FROM t) AS _tp_rewrite")
    }

    @Test("Trailing semicolon stripped from inner query")
    func trailingSemicolonStripped() {
        let sql = PostGISSpatialRewrite.buildWrappedQuery(
            originalQuery: "SELECT geom FROM places;",
            columns: ["geom"],
            spatialIndices: [0]
        )
        #expect(sql == "SELECT ST_AsEWKT(\"geom\") AS \"geom\" FROM (SELECT geom FROM places) AS _tp_rewrite")
    }

    @Test("Trailing semicolon plus whitespace stripped")
    func trailingSemicolonWithWhitespace() {
        let sql = PostGISSpatialRewrite.buildWrappedQuery(
            originalQuery: "SELECT geom FROM places;   \n  ",
            columns: ["geom"],
            spatialIndices: [0]
        )
        #expect(sql == "SELECT ST_AsEWKT(\"geom\") AS \"geom\" FROM (SELECT geom FROM places) AS _tp_rewrite")
    }

    @Test("Column name with embedded quote is doubled in projection")
    func embeddedQuoteInColumnName() {
        let sql = PostGISSpatialRewrite.buildWrappedQuery(
            originalQuery: "SELECT * FROM weird",
            columns: ["he said \"hi\""],
            spatialIndices: [0]
        )
        #expect(sql == "SELECT ST_AsEWKT(\"he said \"\"hi\"\"\") AS \"he said \"\"hi\"\"\" FROM (SELECT * FROM weird) AS _tp_rewrite")
    }
}
