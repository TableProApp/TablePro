import TableProSQLQuoting
import Testing

struct ConnectionStringQuotingTests {
    @Test("A libpq value escapes only the backslash and the quote, a quote a mark follows included", arguments: [
        ("sales", "'sales'"),
        ("a'b\\c", #"'a\'b\\c'"#),
        ("x' host='evil", #"'x\' host=\'evil'"#),
        ("'\u{301}", "'\\'\u{301}'"),
        ("", "''"),
    ])
    func libpqValue(input: String, expected: String) throws {
        #expect(try ConnectionStringQuoting.libpqValue(input) == expected)
    }

    @Test("An ADO.NET value stays one value however many separators it holds", arguments: [
        ("db", #""db""#),
        ("x;Server=evil.example", #""x;Server=evil.example""#),
        (#"x";Password=y"#, #""x"";Password=y""#),
        ("\"\u{301}", "\"\"\"\u{301}\""),
    ])
    func adoNetValue(input: String, expected: String) throws {
        #expect(try ConnectionStringQuoting.adoNetValue(input) == expected)
    }

    @Test("A psql pattern matches the one table, whatever its name holds")
    func psqlPattern() throws {
        #expect(try ConnectionStringQuoting.psqlPattern(schema: "app", name: "Orders") == #""app"."Orders""#)
        #expect(try ConnectionStringQuoting.psqlPattern(schema: nil, name: #"we"ird.t[1]*"#) == #""we""ird.t[1]*""#)
    }

    @Test("NUL is refused, never encoded, and a line break stays data")
    func refusesNUL() throws {
        #expect(throws: ConnectionStringQuoting.NULRefusal()) { try ConnectionStringQuoting.libpqValue("a\u{0}b") }
        #expect(throws: ConnectionStringQuoting.NULRefusal()) { try ConnectionStringQuoting.adoNetValue("a\u{0}b") }
        #expect(throws: ConnectionStringQuoting.NULRefusal()) { try ConnectionStringQuoting.psqlPattern(schema: "a\u{0}b", name: "t") }
        #expect(throws: ConnectionStringQuoting.NULRefusal()) { try ConnectionStringQuoting.psqlPattern(schema: nil, name: "a\u{0}b") }
        #expect(try ConnectionStringQuoting.libpqValue("a\nhost=evil") == "'a\nhost=evil'")
    }
}
