import Foundation
import TableProModels
import TableProRedisCore
import TableProSQLGrammar

public enum QueryRunTarget: Sendable, Equatable {
    case selection(String)
    case statement(String, range: NSRange)
    case nothing

    public static func resolve(
        in text: String,
        selection: NSRange,
        databaseType: DatabaseType,
        session: SQLSessionLexicalFacts?
    ) -> QueryRunTarget {
        let source = text as NSString
        let selected = NSIntersectionRange(selection, NSRange(location: 0, length: source.length))
        if selected.length > 0 {
            return .selection(source.substring(with: selected))
        }
        let caret = min(max(selection.location, 0), source.length)

        if databaseType == .redis {
            guard let command = RedisCommandSplitter.command(at: caret, in: text) else { return .nothing }
            return .statement(command.text, range: command.range)
        }

        if databaseType == .mongodb {
            guard let statement = JavaScriptStatementScanner.statementAtCursor(in: text, cursorPosition: caret) else {
                return .nothing
            }
            let range = statement.contentRange
            guard range.length > 0 else { return .nothing }
            return .statement(source.substring(with: range), range: range)
        }

        // Not statementAtCursor: it returns a comment-only segment's text as a statement.
        let located = SQLStatementScanner.locatedStatementAtCursor(
            in: text,
            cursorPosition: caret,
            grammar: QueryScript.executionGrammar(for: databaseType, session: session)
        )
        guard located.hasContent, located.contentRange.length > 0 else { return .nothing }
        return .statement(source.substring(with: located.contentRange), range: located.contentRange)
    }
}
