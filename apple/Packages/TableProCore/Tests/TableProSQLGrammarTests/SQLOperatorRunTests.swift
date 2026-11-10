import Foundation
import TableProSQLGrammar
import Testing

struct SQLOperatorRunTests {
    private static let postgreSQL = SQLLexicalReadings.resolve(databaseTypeId: "PostgreSQL", declared: nil, session: nil)
        .execution
    private static let mySQL = SQLLexicalReadings.resolve(databaseTypeId: "MySQL", declared: nil, session: nil)
        .execution

    private func run(_ text: String, at index: Int = 1, _ grammar: SQLLexicalGrammar = postgreSQL) -> String? {
        let source = text as NSString
        return SQLOperatorRun.end(at: index, in: source, grammar: grammar).map {
            source.substring(with: NSRange(location: index, length: $0 - index))
        }
    }

    @Test(
        "A run of operator characters is one operator",
        arguments: ["<#>", "<%", "%>", "&&&", "?-|", "<<|", "@-@", "#>>", "||", "=", "-"]
    )
    func wholeRun(symbol: String) {
        #expect(run("a\(symbol)b") == symbol)
    }

    @Test("A trailing sign is dropped unless the run holds a character that keeps it")
    func trailingSign() {
        #expect(run("a=-1") == "=")
        #expect(run("a>=+-1") == ">=")
        #expect(run("a@-b") == "@-")
        #expect(run("a|-b") == "|-")
    }

    @Test("A comment opener ends the run")
    func commentEndsTheRun() {
        #expect(run("a+-- c") == "+")
        #expect(run("a</* c */b") == "<")
        #expect(run("a-- c") == nil)
    }

    @Test("Only a grammar that lexes as PostgreSQL does has the rule, and a word starts no run")
    func otherGrammars() {
        #expect(run("a<#>b", Self.mySQL) == nil)
        #expect(run("a<#>b", .ansi) == nil)
        #expect(run("ab") == nil)
        #expect(run("a::b") == nil)
    }
}
