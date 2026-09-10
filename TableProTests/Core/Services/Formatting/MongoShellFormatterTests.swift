//
//  MongoShellFormatterTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("MongoShellFormatter")
struct MongoShellFormatterTests {
    private func formatted(_ text: String) throws -> String {
        try MongoShellFormatter().format(text, cursorOffset: nil).text
    }

    @Test("A regular expression is left exactly as written")
    func regexIsAtomic() throws {
        // `{2,3}` is a quantifier. Reflowing it to `{2, 3}` is a different pattern.
        #expect(try formatted("db.c.find({x: /a{2,3}/})").contains("/a{2,3}/"))
        #expect(try formatted("db.c.find({x: /[,{}]/i})").contains("/[,{}]/i"))
    }

    @Test("Division is still formatted as an operator")
    func divisionIsNotRegex() throws {
        let output = try formatted("db.c.find({x: total / 2})")
        #expect(output.contains("total / 2"))
    }

    @Test("A line comment survives with its text intact")
    func lineCommentIsAtomic() throws {
        #expect(try formatted("db.c.find({}) // one, two").contains("// one, two"))
    }

    @Test("A block comment survives with its text intact")
    func blockCommentIsAtomic() throws {
        #expect(try formatted("db.c.find(/* one, two */ {})").contains("/* one, two */"))
    }

    @Test("A brace inside a string is not structure")
    func stringsAreAtomic() throws {
        #expect(try formatted("db.c.find({note: \"a, b\"})").contains("\"a, b\""))
    }

    @Test("An ordinary query still reflows")
    func plainQueryFormats() throws {
        let output = try formatted("db.c.find({a:1,b:2})")
        #expect(output.contains("a"))
        #expect(output.contains("b"))
    }
}
