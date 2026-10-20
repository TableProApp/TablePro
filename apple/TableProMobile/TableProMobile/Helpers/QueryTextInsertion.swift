import Foundation
import TableProModels
import TableProQuery
import TableProSQLGrammar

// A template or a history entry added to the editor: it becomes the text of an empty editor and is appended to any
// other as a statement of its own, so nothing typed is lost and Run at Cursor runs it alone.
nonisolated enum QueryTextInsertion {
    nonisolated struct Edit: Equatable {
        let range: NSRange
        let text: String
        let selection: NSRange
    }

    static func edit(
        adding query: String,
        to text: String,
        databaseType: DatabaseType,
        session: SQLSessionLexicalFacts? = nil
    ) -> Edit {
        let source = text as NSString
        // Redis-aware: a backslash there escapes a trailing blank that belongs to the last argument.
        let added = databaseType == .redis
            ? QueryScript.trimmed(query, databaseType: databaseType)
            : StatementBlank.trimming(query)
        let grammar = SQLLexicalReadings.resolve(
            databaseTypeId: databaseType.rawValue, declared: nil, session: session
        ).execution
        guard StatementBlank.hasContent(text) else {
            let whole = NSRange(location: 0, length: source.length)
            let chosen = databaseType.speaksSQL
                ? selection(of: NSRange(location: 0, length: (added as NSString).length), added, grammar)
                : caret(after: added, at: 0)
            return Edit(range: whole, text: added, selection: chosen)
        }

        let end = NSRange(location: source.length, length: 0)
        let start = NSRange(location: 0, length: 0)
        let opensLine = text.hasSuffix("\n") || text.hasSuffix("\r")
        guard databaseType.speaksSQL else {
            let inserted = (opensLine ? "" : "\n") + added
            let appended = Edit(range: end, text: inserted, selection: caret(after: inserted, at: source.length))
            // An open quote or a trailing backslash carries the last command on into the added one.
            guard databaseType == .redis, !redisCommandStandsAlone(appended, in: text) else { return appended }
            return Edit(range: start, text: added + "\n", selection: caret(after: added, at: 0))
        }

        let statement = terminated(added, grammar: grammar)
        let length = (statement as NSString).length
        // SQL Server needs a batch line: a CREATE PROCEDURE must start its batch, and one before would swallow the query.
        let batchLine = databaseType == .mssql ? "GO\n" : ""
        // On a line of its own, so a trailing line comment cannot swallow it.
        let closesLast = endsInOpenStatement(text, grammar: grammar) ? "\n;" : ""
        let lead: String
        if batchLine.isEmpty {
            lead = closesLast + (closesLast.isEmpty && opensLine ? "\n" : "\n\n")
        } else {
            lead = closesLast + (closesLast.isEmpty && opensLine ? "" : "\n") + batchLine + "\n"
        }
        let target = NSRange(location: source.length + (lead as NSString).length, length: length)
        let appended = Edit(range: end, text: lead + statement, selection: selection(of: target, statement, grammar))
        if statementStandsAlone(appended, at: target.location, in: text, grammar: grammar) { return appended }
        // A string, comment or procedural block the text leaves open would take it in, so it goes first instead.
        let first = NSRange(location: 0, length: length)
        let inserted = statement + "\n" + batchLine + "\n"
        return Edit(range: start, text: inserted, selection: selection(of: first, statement, grammar))
    }

    static func applying(_ edit: Edit, to text: String) -> String {
        (text as NSString).replacingCharacters(in: edit.range, with: edit.text)
    }

    private static func caret(after inserted: String, at location: Int) -> NSRange {
        NSRange(location: location + (inserted as NSString).length, length: 0)
    }

    // A history entry of several statements is selected, so Run runs all of it rather than its last statement. One
    // statement gets the caret at its own end, before a comment after it, where Run would find nothing.
    private static func selection(of target: NSRange, _ statement: String, _ grammar: SQLLexicalGrammar) -> NSRange {
        let statements = SQLStatementScanner.navigableStatements(in: statement, grammar: grammar)
        if statements.count > 1 { return target }
        guard let only = statements.first else { return NSRange(location: NSMaxRange(target), length: 0) }
        return NSRange(location: target.location + NSMaxRange(only.contentRange), length: 0)
    }

    private static func endsInOpenStatement(_ text: String, grammar: SQLLexicalGrammar) -> Bool {
        guard let last = SQLStatementScanner.locatedStatements(in: text, grammar: grammar).last, last.hasContent else {
            return false
        }
        let code = StatementBlank.trimming(SQLCodeProjection.code(of: last.sql, grammar: grammar))
        return !code.isEmpty && !code.hasSuffix(";")
    }

    // After a trailing line comment a `;` would be part of the comment, so it goes on a line of its own.
    private static func terminated(_ statement: String, grammar: SQLLexicalGrammar) -> String {
        guard endsInOpenStatement(statement, grammar: grammar) else { return statement }
        return statement + (trailingSpan(of: statement, grammar: grammar)?.kind == .lineComment ? "\n;" : ";")
    }

    // Alone when the statement holding it takes no code from the text before it; a comment there is only trivia.
    private static func statementStandsAlone(
        _ edit: Edit,
        at location: Int,
        in text: String,
        grammar: SQLLexicalGrammar
    ) -> Bool {
        let result = applying(edit, to: text)
        let holder = SQLStatementScanner.navigableStatements(in: result, grammar: grammar).first {
            NSLocationInRange(location, $0.contentRange)
        }
        guard let start = holder?.contentRange.location else { return false }
        guard start < edit.range.location else { return true }
        let code = SQLCodeProjection.code(of: result, grammar: grammar) as NSString
        let borrowed = code.substring(with: NSRange(location: start, length: edit.range.location - start))
        return !StatementBlank.hasContent(borrowed)
    }

    private static func redisCommandStandsAlone(_ edit: Edit, in text: String) -> Bool {
        guard let last = RedisCommandSplitter.commands(in: applying(edit, to: text)).last else { return false }
        return last.range.location >= edit.range.location
    }

    // The comment, string or quoted name that runs to the end of the text, if any.
    private static func trailingSpan(of text: String, grammar: SQLLexicalGrammar) -> SQLNonCodeSpan.Span? {
        let source = text as NSString
        var index = SQLStatementScanner.locatedStatements(in: text, grammar: grammar).last?.offset ?? 0
        while index < source.length {
            guard let span = SQLNonCodeSpan.span(at: index, in: source, grammar: grammar) else {
                index += 1
                continue
            }
            if span.end >= source.length { return span }
            index = max(span.end, index + 1)
        }
        return nil
    }
}
