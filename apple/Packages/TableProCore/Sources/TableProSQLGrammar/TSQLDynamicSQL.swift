import Foundation

// Where T-SQL runs text: `EXEC ('...')`, `EXEC (@text)`, `EXEC @name` and the procedures that run an argument.
public enum TSQLDynamicSQL {
    public static func textOffsets(in statement: String, grammar: SQLLexicalGrammar) -> [Int] {
        guard grammar.contains(.unterminatedStatements) else { return [] }
        return Reader(text: statement as NSString, grammar: grammar).textOffsets
    }

    // `{call name (...)}` is ODBC's spelling of EXEC.
    private static let executeKeywords: Set<String> = ["EXEC", "EXECUTE", "CALL"]

    private static let textRunningProcedures: Set<String> = [
        "SP_EXECUTESQL", "SP_SQLEXEC", "SP_EXECRESULTSET", "SP_PREPARE", "SP_PREPEXEC", "SP_CURSOROPEN",
        "SP_CURSORPREPARE", "SP_CURSORPREPEXEC", "SP_MSFOREACHTABLE", "SP_MSFOREACHDB", "SP_MSFOREACH_WORKER",
        "SP_EXECUTE_REMOTE", "SP_EXECUTE_EXTERNAL_SCRIPT", "XP_CMDSHELL", "SP_OACREATE",
    ]

    private static let at = UInt16(UnicodeScalar("@").value)
    private static let period = UInt16(UnicodeScalar(".").value)
    private static let equals = UInt16(UnicodeScalar("=").value)

    private struct Reader {
        let text: NSString
        let grammar: SQLLexicalGrammar
        let tokens: [TSQLTokens.Token]

        init(text: NSString, grammar: SQLLexicalGrammar) {
            self.text = text
            self.grammar = grammar
            self.tokens = TSQLTokens.read(text, grammar: grammar)
        }

        // A batch's first statement may call a procedure by its name alone.
        var textOffsets: [Int] {
            let keywords = tokens.indices.filter { tokens[$0].word.map(executeKeywords.contains) == true }
            return [textOffset(ofProcedureAt: 0)].compactMap { $0 } + keywords.compactMap { textOffset(after: $0) }
        }

        private func textOffset(after keyword: Int) -> Int? {
            let callee = pastAssignment(at: keyword + 1)
            guard tokens.indices.contains(callee) else { return nil }
            if tokens[callee].kind == .open { return tokens[callee].location + 1 }
            if isVariable(callee) { return tokens[callee].location }
            return textOffset(ofProcedureAt: callee)
        }

        private func textOffset(ofProcedureAt start: Int) -> Int? {
            var cursor = start
            guard let procedure = procedureName(at: &cursor), textRunningProcedures.contains(procedure) else {
                return nil
            }
            cursor = pastAssignment(at: cursor)
            return tokens.indices.contains(cursor) ? tokens[cursor].location : text.length
        }

        private func pastAssignment(at index: Int) -> Int {
            isVariable(index) && isSymbol(equals, at: index + 1) ? index + 2 : index
        }

        private func isVariable(_ index: Int) -> Bool {
            tokens.indices.contains(index) && text.character(at: tokens[index].location) == at
        }

        private func isSymbol(_ unit: UInt16, at index: Int) -> Bool {
            guard tokens.indices.contains(index), tokens[index].kind == .other else { return false }
            return text.character(at: tokens[index].location) == unit
        }

        private func procedureName(at cursor: inout Int) -> String? {
            var name: String?
            var awaitsPart = true
            while tokens.indices.contains(cursor) {
                if isSymbol(period, at: cursor) {
                    awaitsPart = true
                } else if awaitsPart, let part = namePart(at: cursor) {
                    name = part
                    awaitsPart = false
                } else {
                    break
                }
                cursor += 1
            }
            return name
        }

        // Folded as the loosest collation compares names: fullwidth and accented letters match the plain one.
        private func namePart(at index: Int) -> String? {
            let start = tokens[index].location
            let spelling: String
            switch tokens[index].kind {
            case .word(let word):
                return word
            case .name:
                var end = start
                while end < text.length, SQLNonCodeSpan.isWordUnit(text.character(at: end)) {
                    end += 1
                }
                spelling = text.substring(with: NSRange(location: start, length: end - start))
            case .quoted:
                guard let span = SQLNonCodeSpan.span(at: start, in: text, grammar: grammar) else { return nil }
                let bodyStart = min(start + 1, span.contentEnd)
                spelling = text.substring(with: NSRange(location: bodyStart, length: span.contentEnd - bodyStart))
            default:
                return nil
            }
            return StatementBlank.trimming(spelling)
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                .uppercased()
        }
    }
}
