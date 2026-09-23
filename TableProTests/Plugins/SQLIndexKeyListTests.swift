//
//  SQLIndexKeyListTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("SQL index key list")
struct SQLIndexKeyListTests {
    private static let sqlite = SQLiteIndexCatalog.lexicalFeatures

    @Test("A stored CREATE INDEX gives its key list, its keys and its predicate")
    func statementParts() throws {
        let statement = try #require(SQLIndexKeyList.statement(
            "CREATE UNIQUE INDEX [i (x)] ON \"t (y)\" (a, coalesce(b, ')'), [c,d]) WHERE a > ',' ;",
            lexicalFeatures: Self.sqlite
        ))
        #expect(statement.keyList == "a, coalesce(b, ')'), [c,d]")
        #expect(statement.keyParts == ["a", "coalesce(b, ')')", "[c,d]"])
        #expect(statement.predicate == "a > ','")
    }

    @Test("A statement with no key list reads as nothing")
    func noKeyList() {
        #expect(SQLIndexKeyList.statement("CREATE INDEX i ON t", lexicalFeatures: Self.sqlite) == nil)
        #expect(SQLIndexKeyList.statement("CREATE INDEX i ON t (a", lexicalFeatures: Self.sqlite) == nil)
    }

    @Test("Comments and strings never end a key")
    func commentsAndStrings() {
        #expect(
            SQLIndexKeyList.parts(of: "a /* x, y */, 'p,q' || b, -- c, d\n e", lexicalFeatures: Self.sqlite)
                == ["a /* x, y */", "'p,q' || b", "-- c, d\n e"]
        )
    }

    @Test("A trailing sort order comes off a key; one inside a string or a call does not")
    func sortOrder() {
        let strip = { SQLIndexKeyList.withoutSortOrder($0, lexicalFeatures: Self.sqlite) }
        #expect(strip("lower(v) COLLATE NOCASE DESC") == "lower(v) COLLATE NOCASE")
        #expect(strip("v asc") == "v")
        #expect(strip("'DESC'") == "'DESC'")
        #expect(strip("f(DESC)") == "f(DESC)")
        #expect(strip("DESC") == "DESC")
    }

    @Test("One pair of wrapping parentheses comes off, and only a pair that wraps the whole key")
    func unwrapping() {
        let unwrap = { SQLIndexKeyList.unwrapped($0, lexicalFeatures: Self.sqlite) }
        #expect(unwrap("((a || b))") == "(a || b)")
        #expect(unwrap("(a) + (b)") == nil)
        #expect(unwrap("a") == nil)
        #expect(unwrap("(')')") == "')'")
    }

    @Test("A key that is one quoted identifier is read as its name")
    func quotedIdentifiers() {
        let name = { SQLIndexKeyList.quotedIdentifier($0, lexicalFeatures: Self.sqlite) }
        #expect(name(#""a ""b""""#) == #"a "b""#)
        #expect(name("`a``b`") == "a`b")
        #expect(name("[a b]") == "a b")
        #expect(name("'a'") == nil)
        #expect(name(#""a" || b"#) == nil)
    }
}
