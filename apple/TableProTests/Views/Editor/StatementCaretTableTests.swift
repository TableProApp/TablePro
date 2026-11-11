import AppKit
import Foundation
@testable import TablePro
import TableProEditorKit
import TableProGrammars
import TableProSQLGrammar
import TableProTextEngine
import Testing

private let caretTableMongoScript = """
db.users.find({ name: "a;b" });
// note

for (var i = 0; i < 3; i++) {
  print(i);
}
db.orders.insertOne({ total: 1 })
db.orders.find()
// trailing
"""

private let caretTableRedisScript = "GET a; GET b\n\nSET k \"a\nb\"\nGET c  \n  "

@MainActor
struct StatementCaretTableTests {
    private struct Resolved: Equatable {
        let offset: Int
        let sql: String
        let hasContent: Bool
        let contentRange: NSRange

        init(_ statement: SQLStatementScanner.LocatedStatement) {
            offset = statement.offset
            sql = statement.sql
            hasContent = statement.hasContent
            contentRange = statement.contentRange
        }
    }

    @Test("Every caret resolves to what a scan of the whole document resolves to", arguments: [
        (QueryStatementModel.javascript, caretTableMongoScript),
        (QueryStatementModel.redis, caretTableRedisScript),
        (QueryStatementModel.javascript, ""),
        (QueryStatementModel.redis, ""),
    ])
    func everyCaretMatchesAFullScan(model: QueryStatementModel, text: String) throws {
        let table = try #require(QueryStatementCaretTable(text: text, model: model))
        for caret in -1...((text as NSString).length + 1) {
            let fresh = QueryStatementScanner.locatedStatementAtCursor(
                in: text, cursorPosition: caret, model: model, grammar: .ansi
            )
            #expect(Resolved(table.statement(atCursor: caret)) == Resolved(fresh), "caret \(caret)")
        }
    }

    @Test("A SQL document has no table, since it resumes through its own index")
    func sqlHasNoTable() {
        #expect(QueryStatementCaretTable(text: "SELECT 1;", model: .sql) == nil)
    }

    private func makeController(text: String) -> TextViewController {
        let configuration = SourceEditorConfiguration(
            appearance: .init(
                theme: ThemeEngine.shared.makeEditorTheme(),
                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                wrapLines: false
            ),
            peripherals: EditorPeripherals.editor(lineNumbers: true, folding: true, statementRunControls: true)
        )
        let controller = TextViewController(string: text, language: .sql, configuration: configuration, cursorPositions: [])
        controller.loadView()
        return controller
    }

    private func band(at caret: Int, in controller: TextViewController, subject: StatementRunController) -> NSRange? {
        controller.setCursorPositions([CursorPosition(range: NSRange(location: caret, length: 0))])
        subject.refreshHighlight(in: controller)
        return controller.highlightedStatementRange
    }

    private func freshBand(at caret: Int, in controller: TextViewController) -> NSRange? {
        let statement = QueryStatementScanner.locatedStatementAtCursor(
            in: controller.textView.string, cursorPosition: caret, model: .javascript, grammar: .ansi
        )
        guard statement.hasContent, statement.contentRange.length > 0 else { return nil }
        return statement.contentRange
    }

    @Test("Caret moves through a MongoDB script read it once, and an edit reads it again")
    func caretMovesReadTheScriptOnce() {
        let script = String(repeating: "db.orders.find({ total: 1 });\n", count: 2_000)
        let controller = makeController(text: script)
        let subject = StatementRunController()
        subject.statementModel = .javascript
        subject.install(on: controller)
        let readsAtInstall = subject.caretTableReads

        for caret in stride(from: 59_000, to: 58_000, by: -7) {
            #expect(band(at: caret, in: controller, subject: subject) == freshBand(at: caret, in: controller))
        }
        #expect(subject.caretTableReads <= readsAtInstall + 1)

        controller.textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: "db.a.find();\n")
        let afterEdit = subject.caretTableReads
        #expect(band(at: 100, in: controller, subject: subject) == freshBand(at: 100, in: controller))
        #expect(band(at: 58_013, in: controller, subject: subject) == freshBand(at: 58_013, in: controller))
        #expect(subject.caretTableReads == afterEdit + 1)
    }
}
