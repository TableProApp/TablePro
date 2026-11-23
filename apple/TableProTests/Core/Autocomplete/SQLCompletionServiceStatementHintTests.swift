import Foundation
@testable import TablePro
import TableProAutocomplete
import TableProPluginKit
import TableProSQLGrammar
import Testing

@MainActor
struct SQLCompletionServiceStatementHintTests {
    private struct Summary: Equatable {
        let labels: [String]
        let replacementRange: NSRange
    }

    private func summary(_ session: QueryCompletionSession?) -> Summary? {
        session.map { Summary(labels: $0.items.map(\.label), replacementRange: $0.replacementRange) }
    }

    // With no database type the editor's band splits as MySQL and completion as ANSI.
    @Test
    func aHintSplitWithAnotherGrammarGivesTheSessionNoHintGives() async throws {
        let text = "SELECT 1 # note ; FROM t\nSELECT * FROM or" as NSString
        let caret = text.length
        let mysql = DatabaseType.mysql.lexicalGrammar
        let mysqlStatement = SQLStatementScanner.locatedStatementAtCursor(in: text as String, cursorPosition: caret, grammar: mysql)
        let ansiStatement = SQLStatementScanner.locatedStatementAtCursor(in: text as String, cursorPosition: caret, grammar: .ansi)
        try #require(mysqlStatement.range != ansiStatement.range)
        let service = SQLCompletionService(schemaProvider: nil, databaseType: nil)

        let hinted = await service.completions(
            in: text,
            at: caret,
            statement: QueryStatementHint(range: mysqlStatement.range, grammar: mysql),
            isManualTrigger: true
        )
        let plain = await service.completions(in: text, at: caret, statement: nil, isManualTrigger: true)

        #expect(summary(hinted) == summary(plain))
    }

    @Test(
        arguments: [
            ("SELECT 1;\nSELECT * FROM or", -1),
            ("SELECT id, na FROM users WHERE id = 1;\nSELECT 2;", 12),
            ("SELECT 'a;b' AS x;\nUPDATE t SET c = 1 WHERE ", -1),
            ("CREATE FUNCTION f() RETURNS int AS $$ SELECT 1; $$ LANGUAGE sql;\nSELECT * FROM ", -1),
            ("/* ; */ SELECT * FROM t JOIN ", -1),
            ("SELECT 1; -- done\n", -1),
        ]
    )
    func aMatchingHintGivesTheSessionNoHintGives(script: String, caretOrEnd: Int) async {
        let text = script as NSString
        let caret = caretOrEnd < 0 ? text.length : caretOrEnd
        let grammar = DatabaseType.postgresql.lexicalGrammar
        let statement = SQLStatementScanner.locatedStatementAtCursor(in: script, cursorPosition: caret, grammar: grammar)
        let service = SQLCompletionService(schemaProvider: nil, databaseType: .postgresql)

        let hinted = await service.completions(
            in: text,
            at: caret,
            statement: QueryStatementHint(range: statement.range, grammar: grammar),
            isManualTrigger: true
        )
        let plain = await service.completions(in: text, at: caret, statement: nil, isManualTrigger: true)

        #expect(summary(hinted) == summary(plain))
    }
}
