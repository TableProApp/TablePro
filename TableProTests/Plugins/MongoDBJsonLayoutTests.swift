//
//  MongoDBJsonLayoutTests.swift
//  TableProTests
//

import Foundation
import Testing

struct MongoDBJsonLayoutTests {
    @Test("Members keep their order, one per line, nested two spaces a level")
    func indentedKeepsOrder() {
        let text = MongoDBJsonLayout.indented("{ \"zeta\" : 1, \"alpha\" : { \"b\" : [ 1, 2 ] } }")

        #expect(text == """
            {
              "zeta": 1,
              "alpha": {
                "b": [
                  1,
                  2
                ]
              }
            }
            """)
    }

    @Test("Empty documents and arrays stay on one line")
    func emptyContainers() {
        #expect(MongoDBJsonLayout.indented("{ \"a\" : { }, \"b\" : [ ] }") == "{\n  \"a\": {},\n  \"b\": []\n}")
        #expect(MongoDBJsonLayout.indented("[ ]") == "[]")
    }

    @Test("Punctuation and escapes inside a string are left as they are")
    func stringsAreUntouched() {
        let text = MongoDBJsonLayout.indented("{ \"k\" : \"a, {b}: [c] \\\" d\" }")

        #expect(text == "{\n  \"k\": \"a, {b}: [c] \\\" d\"\n}")
    }

    @Test("A depth indents every line after the first for text that sits inside a statement")
    func depthOffsetsNesting() {
        #expect(MongoDBJsonLayout.indented("{ \"a\" : 1 }", depth: 1) == "{\n    \"a\": 1\n  }")
    }

    @Test("An object built from members uses libbson's own spacing")
    func objectSpacing() {
        #expect(MongoDBJsonLayout.object([(key: "name", value: "\"a_1\""), (key: "unique", value: "true")])
            == "{ \"name\" : \"a_1\", \"unique\" : true }")
        #expect(MongoDBJsonLayout.object([]) == "{ }")
    }

    @Test("A constructor call stays on one line, commas and braces inside it included")
    func constructorCallsStayWhole() {
        let text = MongoDBJsonLayout.indented(
            "[ { \"b\" : BinData(4, \"AA==\"), \"t\" : Timestamp(5, 6), \"c\" : Code(\"f()\", { \"x\" : 1 }) } ]"
        )

        #expect(text == """
            [
              {
                "b": BinData(4, "AA=="),
                "t": Timestamp(5, 6),
                "c": Code("f()", { "x" : 1 })
              }
            ]
            """)
    }

    @Test("A shell object writes __proto__ as a computed key, and an Extended JSON object as a plain one")
    func shellObjectKeepsProtoAMember() {
        let members = [(key: "__proto__", value: "1"), (key: "a", value: "2")]

        #expect(MongoDBJsonLayout.shellObject(members) == "{ [\"__proto__\"] : 1, \"a\" : 2 }")
        #expect(MongoDBJsonLayout.object(members) == "{ \"__proto__\" : 1, \"a\" : 2 }")
        #expect(MongoDBJsonLayout.shellObject([]) == "{ }")
    }

    @Test("A computed key stays on its line, and an array holding one string does not become one")
    func computedKeysStayWhole() {
        let text = MongoDBJsonLayout.indented(
            "{ [\"__proto__\"] : { [\"__pro\\\"to__\"] : 1 }, \"b\" : [ \"x\" ], \"c\" : [ \"y\" ] }"
        )

        #expect(text == """
            {
              ["__proto__"]: {
                ["__pro\\"to__"]: 1
              },
              "b": [
                "x"
              ],
              "c": [
                "y"
              ]
            }
            """)
    }

    @Test("new Date keeps the space between its two words")
    func newDateKeepsItsSpace() {
        #expect(MongoDBJsonLayout.indented("{ \"d\" : new Date(-62198755200000) }")
            == "{\n  \"d\": new Date(-62198755200000)\n}")
    }

    @Test("A collation keeps every member but the server's ICU version")
    func portableCollation() {
        #expect(MongoDBCollation.portable(
            "{ \"locale\" : \"en\", \"strength\" : { \"$numberInt\" : \"2\" }, \"version\" : \"57.1\" }"
        ) == "{ \"locale\" : \"en\", \"strength\" : { \"$numberInt\" : \"2\" } }")
    }
}
