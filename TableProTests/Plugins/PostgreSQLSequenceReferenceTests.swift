//
//  PostgreSQLSequenceReferenceTests.swift
//  TableProTests
//
//  The deparsed defaults below are what PostgreSQL 17.11 printed from pg_get_expr under
//  `SET LOCAL search_path = pg_catalog`, and each expected result is what it printed for the same
//  default under the table's own schema, apart from the names left qualified on purpose. The
//  malformed inputs are made up to reach the refusals.
//

import Foundation
import TableProPluginKit
import Testing

@Suite("PostgreSQLSequenceReference")
struct PostgreSQLSequenceReferenceTests {
    private let ordersSequence = PostgreSQLSequenceReference(
        qualifiedName: "sales.orders_id_seq", relativeName: "orders_id_seq"
    )

    private func relativize(
        _ expression: String,
        _ references: [PostgreSQLSequenceReference],
        standardConformingStrings: Bool? = true
    ) -> String? {
        PostgreSQLSequenceReference.relativize(
            expression, references: references, standardConformingStrings: standardConformingStrings
        )
    }

    @Test("A sequence beside the table goes relative while the function and type around it keep their schema")
    func relativizesOnlyTheRecreatedSequence() {
        #expect(
            relativize("sales.wrap(nextval('sales.orders_id_seq'::regclass))", [ordersSequence])
                == "sales.wrap(nextval('orders_id_seq'::regclass))"
        )
        #expect(
            relativize("(nextval('sales.orders_id_seq'::regclass))::sales.sid", [ordersSequence])
                == "(nextval('orders_id_seq'::regclass))::sales.sid"
        )
        #expect(
            relativize("app.make_id(currval('sales.orders_id_seq'::regclass))", [ordersSequence])
                == "app.make_id(currval('orders_id_seq'::regclass))"
        )
    }

    @Test("A sequence in another schema is not listed, so it stays qualified")
    func otherSchemaSequenceStaysQualified() {
        #expect(relativize("nextval('shared.global_seq'::regclass)", []) == "nextval('shared.global_seq'::regclass)")
    }

    @Test("Quoted, keyword, mixed-case and escaped names are replaced exactly as the server wrote them")
    func quotedNamesRelativizeExactly() throws {
        let references = try #require(PostgreSQLSequenceReference.references(
            qualified: #"{"sales.\"user\"","sales.\"UPPER\"","sales.\"Back\\slash'seq\""}"#,
            relative: #"{"\"user\"","\"UPPER\"","\"Back\\slash'seq\""}"#
        ))
        let expression = #"((app.make_id(nextval('sales."user"'::regclass)) + nextval('sales."UPPER"'::regclass))"#
            + #" + nextval('sales."Back\slash''seq"'::regclass))"#
        let expected = #"((app.make_id(nextval('"user"'::regclass)) + nextval('"UPPER"'::regclass))"#
            + #" + nextval('"Back\slash''seq"'::regclass))"#
        #expect(relativize(expression, references) == expected)
    }

    @Test("A schema with a space and a name with a quote and a double quote in it")
    func mixedSchemaRelativizes() throws {
        let references = try #require(PostgreSQLSequenceReference.references(
            qualified: #"{"\"Mixed Schema\".\"Weird'Seq\"\"Name\""}"#,
            relative: #"{"\"Weird'Seq\"\"Name\""}"#
        ))
        #expect(
            relativize(#"nextval('"Mixed Schema"."Weird''Seq""Name"'::regclass)"#, references)
                == #"nextval('"Weird''Seq""Name"'::regclass)"#
        )
    }

    @Test("With standard_conforming_strings off the server doubles a backslash, and so does the rewrite")
    func backslashFollowsTheSetting() throws {
        let references = try #require(PostgreSQLSequenceReference.references(
            qualified: #"{"sales.\"Back\\slash'seq\""}"#,
            relative: #"{"\"Back\\slash'seq\""}"#
        ))
        #expect(
            relativize(#"nextval('sales."Back\\slash''seq"'::regclass)"#, references, standardConformingStrings: false)
                == #"nextval('"Back\\slash''seq"'::regclass)"#
        )
        #expect(PostgreSQLSequenceReference.quotedLiteral(#"a\b'c"#, standardConformingStrings: true) == #"'a\b''c'"#)
        #expect(PostgreSQLSequenceReference.quotedLiteral(#"a\b'c"#, standardConformingStrings: false) == #"'a\\b''c'"#)
    }

    @Test("Every reference to a listed sequence is replaced, however many there are")
    func replacesEveryOccurrence() {
        #expect(
            relativize(
                "(nextval('sales.orders_id_seq'::regclass) + nextval('sales.orders_id_seq'::regclass))",
                [ordersSequence]
            ) == "(nextval('orders_id_seq'::regclass) + nextval('orders_id_seq'::regclass))"
        )
    }

    @Test("A string constant and a quoted identifier holding the same characters are left alone")
    func constantsAndIdentifiersAreNotTouched() {
        #expect(
            relativize(
                "('''sales.orders_id_seq''::regclass'::text || (nextval('sales.orders_id_seq'::regclass))::text)",
                [ordersSequence]
            ) == "('''sales.orders_id_seq''::regclass'::text || (nextval('orders_id_seq'::regclass))::text)"
        )
        #expect(
            relativize(
                #"sales."f'sales.orders_id_seq'::regclass"(nextval('sales.orders_id_seq'::regclass))"#,
                [ordersSequence]
            ) == #"sales."f'sales.orders_id_seq'::regclass"(nextval('orders_id_seq'::regclass))"#
        )
    }

    @Test("A name read as text rather than regclass records no dependency and is left as written")
    func textArgumentIsNotARegclassLiteral() {
        #expect(
            relativize("nextval(('orders_id_seq'::text)::regclass)", [])
                == "nextval(('orders_id_seq'::text)::regclass)"
        )
    }

    @Test("A literal cast to a type whose name only starts with regclass is not a sequence reference")
    func longerCastIsNotARegclassLiteral() {
        #expect(relativize("'sales.orders_id_seq'::regclass[]", [ordersSequence]) == nil)
        #expect(relativize("'sales.orders_id_seq'::regclass_alias", [ordersSequence]) == nil)
        #expect(relativize("'sales.orders_id_seq'::regclass", [ordersSequence]) == "'orders_id_seq'::regclass")
    }

    @Test("A listed sequence the text never names gives no spelling rather than one bound to the source")
    func unmatchedReferenceGivesNil() {
        #expect(relativize("nextval(('sales.orders_id_seq'::text)::regclass)", [ordersSequence]) == nil)
        let other = PostgreSQLSequenceReference(qualifiedName: "sales.other_seq", relativeName: "other_seq")
        #expect(relativize("nextval('sales.orders_id_seq'::regclass)", [ordersSequence, other]) == nil)
    }

    @Test("Text that does not lex, or an unknown quoting setting, gives no spelling")
    func unreadableInputGivesNil() {
        #expect(relativize("nextval('sales.orders_id_seq", [ordersSequence]) == nil)
        #expect(relativize(#"sales."wrap(nextval('sales.orders_id_seq'::regclass))"#, [ordersSequence]) == nil)
        #expect(
            relativize("nextval('sales.orders_id_seq'::regclass)", [ordersSequence], standardConformingStrings: nil)
                == nil
        )
        #expect(relativize("now()", [], standardConformingStrings: nil) == "now()")
    }

    @Test("The two arrays pair element for element, and anything unpaired or unreadable is refused")
    func arraysPairOrRefuse() {
        #expect(PostgreSQLSequenceReference.references(qualified: nil, relative: nil)?.isEmpty == true)
        #expect(
            PostgreSQLSequenceReference.references(qualified: "{sales.a,sales.b}", relative: "{a,b}")
                == [
                    PostgreSQLSequenceReference(qualifiedName: "sales.a", relativeName: "a"),
                    PostgreSQLSequenceReference(qualifiedName: "sales.b", relativeName: "b")
                ]
        )
        #expect(PostgreSQLSequenceReference.references(qualified: "{sales.a,sales.b}", relative: "{a}") == nil)
        #expect(PostgreSQLSequenceReference.references(qualified: "{sales.a}", relative: nil) == nil)
        #expect(PostgreSQLSequenceReference.references(qualified: "{sales.a", relative: "{a}") == nil)
        #expect(PostgreSQLSequenceReference.references(qualified: "{NULL}", relative: "{a}") == nil)
    }

    @Test("The setting is read only in the two spellings current_setting reports")
    func readsTheSetting() {
        #expect(PostgreSQLSequenceReference.standardConformingStrings("on") == true)
        #expect(PostgreSQLSequenceReference.standardConformingStrings("off") == false)
        #expect(PostgreSQLSequenceReference.standardConformingStrings(nil) == nil)
        #expect(PostgreSQLSequenceReference.standardConformingStrings("maybe") == nil)
    }

    @Test("A quote carrying a combining mark is still doubled")
    func quoteWithCombiningMarkIsDoubled() {
        #expect(
            PostgreSQLSequenceReference.quotedLiteral("a'\u{301}b", standardConformingStrings: true)
                == "'a''\u{301}b'"
        )
    }
}
