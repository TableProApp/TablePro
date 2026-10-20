import Foundation
@testable import TableProMobile
import TableProModels
import TableProQuery
import TableProSQLGrammar
import Testing

struct QueryTextInsertionTests {
    private func added(
        _ query: String,
        to text: String,
        _ type: DatabaseType = .postgresql,
        session: SQLSessionLexicalFacts? = nil
    ) -> (String, NSRange) {
        let edit = QueryTextInsertion.edit(adding: query, to: text, databaseType: type, session: session)
        return (QueryTextInsertion.applying(edit, to: text), edit.selection)
    }

    @Test("An empty editor takes the query as its text")
    func emptyEditorTakesTheQuery() {
        let (text, selection) = added("SELECT * FROM orders LIMIT 100", to: "  \n")
        #expect(text == "SELECT * FROM orders LIMIT 100")
        #expect(selection == NSRange(location: 30, length: 0))
    }

    @Test("Text already typed stays, and the query follows as its own statement")
    func appendsAsItsOwnStatement() {
        let (text, _) = added("SELECT * FROM orders LIMIT 100", to: "SELECT 1;")
        #expect(text == "SELECT 1;\n\nSELECT * FROM orders LIMIT 100;")
    }

    @Test("An unterminated last statement is closed on a line of its own, past a trailing comment")
    func closesTheLastStatement() {
        let (text, _) = added("SELECT 2;", to: "SELECT 1 -- first")
        #expect(text == "SELECT 1 -- first\n;\n\nSELECT 2;")
    }

    @Test("A text ending in a line break gets one more, not two")
    func reusesTheTrailingLineBreak() {
        let (text, _) = added("SELECT 2", to: "SELECT 1;\n")
        #expect(text == "SELECT 1;\n\nSELECT 2;")
    }

    @Test("Run at Cursor at the new caret runs only the added query")
    func caretRunsTheAddedQuery() throws {
        let (text, selection) = added("SELECT * FROM orders LIMIT 100", to: "UPDATE orders SET total = 0")
        let target = QueryRunTarget.resolve(in: text, selection: selection, databaseType: .postgresql, session: nil)
        guard case .statement(let statement, _) = target else {
            Issue.record("expected a statement, got \(target)")
            return
        }
        #expect(statement == "SELECT * FROM orders LIMIT 100;" || statement == "SELECT * FROM orders LIMIT 100")
    }

    @Test("Redis commands go on a new line, with no semicolon")
    func redisGoesOnANewLine() {
        let (text, _) = added("GET session:1", to: "SET a 1", .redis)
        #expect(text == "SET a 1\nGET session:1")
    }

    @Test("A Redis key's escaped trailing blank stays with it")
    func redisKeepsAnEscapedTrailingBlank() {
        let (empty, _) = added("DEL victim\\ ", to: "", .redis)
        let (appended, _) = added("DEL victim\\ ", to: "GET a", .redis)
        #expect(empty == "DEL victim\\ ")
        #expect(appended == "GET a\nDEL victim\\ ")
    }

    @Test("An added query ending in a line comment is closed on a line of its own")
    func addedLineCommentIsClosedBelow() {
        let (first, _) = added("SELECT 2 -- note", to: "SELECT 'draft")
        let (last, _) = added("SELECT 2 -- note", to: "SELECT 1;")
        #expect(first == "SELECT 2 -- note\n;\n\nSELECT 'draft")
        #expect(last == "SELECT 1;\n\nSELECT 2 -- note\n;")
    }

    @Test("A semicolon inside a string does not count as the end")
    func semicolonInAStringIsNotTheEnd() {
        let (text, _) = added("SELECT 2", to: "SELECT ';'")
        #expect(text == "SELECT ';'\n;\n\nSELECT 2;")
    }

    @Test("Text that ends inside an open string or comment gets the query in front of it")
    func openSpanGetsTheQueryFirst() {
        let (string, caretAfterString) = added("SELECT 2", to: "SELECT 'abc")
        let (comment, _) = added("SELECT 2", to: "SELECT 1; /* draft")

        #expect(string == "SELECT 2;\n\nSELECT 'abc")
        #expect(caretAfterString == NSRange(location: 9, length: 0))
        #expect(comment == "SELECT 2;\n\nSELECT 1; /* draft")
    }

    @Test("A comment after the last statement does not move the query to the front")
    func trailingCommentStillAppends() {
        let (text, _) = added("SELECT 2", to: "SELECT 1; -- note")
        #expect(text == "SELECT 1; -- note\n\nSELECT 2;")
    }

    @Test("An unfinished PL/SQL block gets the query in front of it")
    func openBlockGetsTheQueryFirst() {
        let (text, _) = added("SELECT 1 FROM dual", to: "BEGIN NULL;", .oracle)
        #expect(text == "SELECT 1 FROM dual;\n\nBEGIN NULL;")
    }

    @Test("The session's reading of backslashes decides whether the text ends inside a string")
    func sessionDecidesAnOpenString() {
        let escapes = SQLSessionLexicalFacts(
            determined: .backslashEscapesInSingleQuotes,
            enabled: .backslashEscapesInSingleQuotes
        )
        let (plain, _) = added("SELECT 2", to: "SELECT 'draft\\'")
        let (escaped, _) = added("SELECT 2", to: "SELECT 'draft\\'", session: escapes)

        #expect(plain == "SELECT 'draft\\'\n;\n\nSELECT 2;")
        #expect(escaped == "SELECT 2;\n\nSELECT 'draft\\'")
    }

    @Test("A Redis draft ending in an open quote or a backslash gets the command in front of it")
    func redisOpenArgumentGetsTheCommandFirst() {
        let (quote, _) = added("GET other", to: "GET \"key", .redis)
        let (backslash, _) = added("GET other", to: "GET key\\", .redis)

        #expect(quote == "GET other\nGET \"key")
        #expect(backslash == "GET other\nGET key\\")
    }

    @Test("Several statements added to an empty editor are selected too")
    func severalStatementsInAnEmptyEditor() {
        let (text, selection) = added("SELECT 2; SELECT 3", to: "")
        #expect(text == "SELECT 2; SELECT 3")
        #expect(selection == NSRange(location: 0, length: 18))
    }

    @Test("A comment after the added statement leaves the caret where Run finds the statement")
    func caretStopsBeforeATrailingComment() throws {
        let (text, selection) = added("SELECT 2; -- note", to: "SELECT 1;")
        #expect(text == "SELECT 1;\n\nSELECT 2; -- note")
        let target = QueryRunTarget.resolve(in: text, selection: selection, databaseType: .postgresql, session: nil)
        guard case .statement(let statement, _) = target else {
            Issue.record("expected a statement, got \(target)")
            return
        }
        #expect(statement.hasPrefix("SELECT 2"))
    }

    @Test("A history entry of several statements is selected, so Run runs all of it")
    func severalStatementsAreSelected() {
        let (text, selection) = added("SELECT 2; SELECT 3", to: "SELECT 1;")

        #expect(text == "SELECT 1;\n\nSELECT 2; SELECT 3;")
        #expect((text as NSString).substring(with: selection) == "SELECT 2; SELECT 3;")
    }

    @Test("On SQL Server the query starts a batch of its own")
    func sqlServerStartsABatch() {
        let (text, _) = added("CREATE PROCEDURE p AS SELECT 1", to: "SELECT 1;", .mssql)
        let (afterOpenEnd, _) = added("SELECT 2", to: "SELECT 1\n", .mssql)

        #expect(text == "SELECT 1;\nGO\n\nCREATE PROCEDURE p AS SELECT 1;")
        #expect(afterOpenEnd == "SELECT 1\n\n;\nGO\n\nSELECT 2;")
    }
}
