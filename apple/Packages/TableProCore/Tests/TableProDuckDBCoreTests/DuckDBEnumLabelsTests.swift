import TableProDuckDBCore
import Testing

struct DuckDBEnumLabelsTests {
    @Test("labels keep their backslashes, blanks and commas, and a doubled quote reads as one")
    func labelsAsWritten() {
        #expect(DuckDBEnumLabels.labels(inType: #"ENUM('C:\temp', '  padded  ', 'it''s', 'a,b')"#)
            == [#"C:\temp"#, "  padded  ", "it's", "a,b"])
    }

    @Test("a LIST or ARRAY of an enum gives its elements' labels", arguments: [
        "ENUM('x', 'y')[]", "ENUM('x', 'y')[2]", "ENUM('x', 'y')[][]", "enum('x', 'y')[]"
    ])
    func listLabels(typeName: String) {
        #expect(DuckDBEnumLabels.labels(inType: typeName) == ["x", "y"])
    }

    @Test("a label holding a bracket or parenthesis stays whole")
    func bracketInLabel() {
        #expect(DuckDBEnumLabels.labels(inType: "ENUM('a)', 'b[]')[]") == ["a)", "b[]"])
    }

    @Test("a type that is not an enum or a list of one has no labels", arguments: [
        "VARCHAR", "STRUCT(k ENUM('u', 'v'))", "MAP(VARCHAR, ENUM('u'))", "ENUM('u')[x]", "ENUM()"
    ])
    func notAnEnum(typeName: String) {
        #expect(DuckDBEnumLabels.labels(inType: typeName) == nil)
    }
}
