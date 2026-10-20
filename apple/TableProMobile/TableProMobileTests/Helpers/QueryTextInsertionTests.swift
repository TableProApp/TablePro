import Foundation
@testable import TableProMobile
import TableProModels
import TableProQuery
import Testing

struct QueryTextInsertionTests {
    private func added(_ query: String, to text: String, _ type: DatabaseType = .postgresql) -> (String, NSRange) {
        let edit = QueryTextInsertion.edit(adding: query, to: text, databaseType: type)
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
