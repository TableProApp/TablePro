import Foundation
@testable import TableProAutocomplete
import TableProSQLGrammar
import Testing

struct SQLContextAnalyzerLexicalTests {
    private let analyzer = SQLContextAnalyzer()

    private func context(_ query: String, on engine: String, cursor: Int? = nil) -> SQLContext {
        analyzer.analyze(
            query: query,
            cursorPosition: cursor ?? (query as NSString).length,
            grammar: .engine(engine)
        )
    }

    // An apostrophe in a comment once opened a string that ran to the cursor, so nothing after it completed.
    @Test(
        "A quote inside a comment opens nothing",
        arguments: [
            ("-- last week's orders\nSELECT * FROM or", "SQLite"),
            ("-- last week's orders\nSELECT * FROM or", "PostgreSQL"),
            ("SELECT * /* it's */ FROM or", "PostgreSQL"),
            ("SELECT * /* it's */ FROM or", "SQL Server"),
            ("/* a /* b */ 'c */ SELECT * FROM or", "PostgreSQL")
        ]
    )
    func quoteInACommentOpensNothing(query: String, engine: String) {
        let result = context(query, on: engine)
        #expect(!result.isInsideString)
        #expect(!result.isInsideComment)
        #expect(result.clauseType == .from)
        #expect(result.prefix == "or")
    }

    @Test(
        "An alias after a commented line still resolves",
        arguments: [
            ("SELECT * FROM orders o -- don't\nWHERE o.", "SQLite"),
            ("SELECT * FROM orders o # don't\nWHERE o.", "MySQL")
        ]
    )
    func aliasAfterACommentResolves(query: String, engine: String) {
        let result = context(query, on: engine)
        #expect(!result.isInsideString)
        #expect(result.dotPrefix == "o")
        #expect(result.tableReferences.contains { $0.tableName == "orders" && $0.alias == "o" })
    }

    // A backslash is literal on these engines, so `'C:\'` is a closed string.
    @Test(
        "A trailing backslash closes the string where the engine says so",
        arguments: ["SQLite", "PostgreSQL", "SQL Server", "Oracle", "DuckDB"]
    )
    func literalBackslashClosesTheString(engine: String) {
        let result = context("SELECT * FROM files f WHERE f.path = 'C:\\' AND f.", on: engine)
        #expect(!result.isInsideString)
        #expect(result.dotPrefix == "f")
        #expect(result.tableReferences.contains { $0.tableName == "files" && $0.alias == "f" })
    }

    @Test("An escaped backslash closes the string on MySQL")
    func escapedBackslashClosesTheStringOnMySQL() {
        let result = context("SELECT * FROM files f WHERE f.path = 'C:\\\\' AND f.", on: "MySQL")
        #expect(!result.isInsideString)
        #expect(result.dotPrefix == "f")
    }

    @Test("An escaped quote keeps the string open on MySQL")
    func escapedQuoteKeepsTheStringOpenOnMySQL() {
        let result = context("SELECT * FROM t WHERE x = 'it\\'s AND ", on: "MySQL")
        #expect(result.isInsideString)
    }

    @Test("A dollar-quoted body is one literal on PostgreSQL")
    func dollarQuotedBodyIsOneLiteral() {
        let query = "SELECT $$it's$$, o. FROM orders o"
        let result = context(query, on: "PostgreSQL", cursor: 19)
        #expect(!result.isInsideString)
        #expect(result.dotPrefix == "o")
        #expect(result.tableReferences.contains { $0.tableName == "orders" && $0.alias == "o" })
    }

    @Test("A doubled quote stays inside the literal")
    func doubledQuoteStaysInside() {
        let result = context("SELECT * FROM t WHERE x = 'it''s' AND ", on: "SQLite")
        #expect(!result.isInsideString)
        #expect(result.clauseType == .and)
        #expect(result.tableReferences.contains { $0.tableName == "t" })
    }

    @Test(
        "An open string is silent on every engine",
        arguments: ["SQLite", "PostgreSQL", "SQL Server", "Oracle", "DuckDB", "MySQL"]
    )
    func openStringIsSilent(engine: String) {
        let result = context("SELECT * FROM users WHERE name = 'jo", on: engine)
        #expect(result.isInsideString)
        #expect(result.prefix.isEmpty)
    }

    @Test("A cursor inside a comment is silent", arguments: ["SQLite", "PostgreSQL", "MySQL"])
    func cursorInACommentIsSilent(engine: String) {
        let result = context("SELECT * FROM orders -- or", on: engine)
        #expect(result.isInsideComment)
    }

    @Test("A comment in an earlier statement does not reach the next one")
    func earlierStatementCommentStaysThere() {
        let result = context("-- don't\nSELECT 1;\nSELECT * FROM or", on: "SQLite")
        #expect(result.clauseType == .from)
        #expect(result.prefix == "or")
    }

    @Test(
        "An open double quote is a name where the engine quotes identifiers with it",
        arguments: ["PostgreSQL", "SQLite", "Oracle", "SQL Server", "DuckDB"]
    )
    func openDoubleQuoteIsAnIdentifier(engine: String) {
        let result = context("SELECT * FROM \"Inv", on: engine)
        #expect(!result.isInsideString)
        #expect(result.clauseType == .from)
        #expect(result.expectsObjectName)
        #expect(result.prefix == "Inv")
        #expect(result.prefixRange == 14..<18)
    }

    @Test("An open double quote is a string on MySQL")
    func openDoubleQuoteIsAStringOnMySQL() {
        #expect(context("SELECT * FROM \"Inv", on: "MySQL").isInsideString)
    }

    // ClickHouse quotes identifiers with `"`, but its grammar carries the backslash flag the analyzer reads as "a
    // double quote is a string". This pins today's silence there.
    @Test("An open double quote stays silent on ClickHouse")
    func openDoubleQuoteStaysSilentOnClickHouse() {
        #expect(context("SELECT * FROM \"Inv", on: "ClickHouse").isInsideString)
    }

    @Test("A string's parenthesis opens no subquery or call")
    func parenthesisInAStringIsText() {
        let result = context("SELECT * FROM orders o WHERE o.note = '(' AND o.", on: "PostgreSQL")
        #expect(result.nestingLevel == 0)
        #expect(result.currentFunction == nil)
        #expect(result.dotPrefix == "o")
    }

    @Test("A keyword inside a string does not change the clause")
    func keywordInAStringIsText() {
        let result = context("SELECT * FROM users WHERE name = 'x FROM y' AND ", on: "SQLite")
        #expect(result.clauseType == .and)
        #expect(!result.tableReferences.contains { $0.tableName == "y" })
    }

    // These grammars set backslash escapes in `"`, which the analyzer reads as a string, yet the engines quote names
    // with it.
    @Test("A closed double-quoted table still becomes a reference", arguments: ["ClickHouse", "DynamoDB"])
    func doubleQuotedTableUnderABackslashGrammar(engine: String) {
        let query = "SELECT o. FROM \"orders\" o"
        let result = context(query, on: engine, cursor: 9)
        #expect(result.dotPrefix == "o")
        #expect(result.tableReferences.contains { $0.tableName == "orders" && $0.alias == "o" })
    }

    @Test("The quoted name at the cursor is reported with its close once there is one")
    func quotedNameAtTheCursor() {
        let closed = context("SELECT * FROM [Order Det]", on: "SQL Server", cursor: 24)
        #expect(closed.quotedName == SQLQuotedName(open: 14, close: 24))
        #expect(closed.clauseType == .from)

        let open = context("SELECT * FROM [Order Det", on: "SQL Server")
        #expect(open.quotedName == SQLQuotedName(open: 14, close: nil))

        let afterStatement = context("SELECT 1; SELECT * FROM \"Ord\"", on: "PostgreSQL", cursor: 28)
        #expect(afterStatement.quotedName == SQLQuotedName(open: 24, close: 28))

        #expect(context("SELECT * FROM ord", on: "PostgreSQL").quotedName == nil)
    }

    // A quote typed before later names pairs with the next quote, which belongs to that later text.
    @Test("A close that leaves the rest of the statement unbalanced is not the name's")
    func laterCloseIsNotTheName() {
        let doubleQuoted = context("SELECT * FROM \"Ord WHERE \"status\" = 1", on: "PostgreSQL", cursor: 18)
        #expect(doubleQuoted.quotedName == SQLQuotedName(open: 14, close: nil))

        let bracketed = context("SELECT * FROM [Ord WHERE [status] = 1", on: "SQL Server", cursor: 18)
        #expect(bracketed.quotedName == SQLQuotedName(open: 14, close: nil))

        let spaced = context("SELECT * FROM \"Order Det\" WHERE \"status\" = 1", on: "PostgreSQL", cursor: 18)
        #expect(spaced.quotedName == SQLQuotedName(open: 14, close: 24))
    }

    // A walk back from the caret stops at the space, so the prefix was `Det` and the accepted name replaced only it.
    @Test(
        "A quoted name with a space is the whole prefix",
        arguments: [
            ("SELECT * FROM [Order Det]", "SQL Server", 15..<24),
            ("SELECT * FROM [Order Det", "SQL Server", 14..<24),
            ("SELECT * FROM \"Order Det\"", "PostgreSQL", 15..<24),
            ("SELECT * FROM `Order Det", "MySQL", 14..<24)
        ]
    )
    func quotedNameWithASpaceIsThePrefix(query: String, engine: String, range: Range<Int>) {
        let result = context(query, on: engine, cursor: 24)
        #expect(result.prefix == "Order Det")
        #expect(result.prefixRange == range)
        #expect(result.clauseType == .from)
        #expect(result.expectsObjectName)
    }

    @Test("A qualified quoted column with a space keeps its qualifier")
    func qualifiedQuotedColumnWithASpace() {
        let result = context("SELECT o.\"Unit Pr\" FROM orders o", on: "PostgreSQL", cursor: 17)
        #expect(result.dotPrefix == "o")
        #expect(result.prefix == "Unit Pr")
        #expect(result.prefixRange == 10..<17)
    }
}
