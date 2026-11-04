import Foundation

/// What a Databend server parses from a text, written out for a gate that reads it with a lexical grammar.
///
/// The app sends a text one statement at a time, cut where the grammar cuts it, and the server tokenizes each statement
/// alone, so each reading of ``DatabendTokenizer/Rules`` gives the tokens of every statement, joined by `;`, and those
/// of the whole text. A token is written so the Databend grammar lexes it alone: a hint, a comment or a blank is
/// dropped, and a `$` or a quote that would open a literal the server does not read is spelled `_`. A statement opening
/// with `SETTINGS` and its optional `( ... )` runs the statement after them, so only that one is written.
enum DatabendStatementReadings {
    static func texts(of text: String, grammar: SQLLexicalGrammar) -> [String] {
        let scalars = Array(text.unicodeScalars)
        let statements = SQLStatementScanner.executableStatements(in: text, grammar: grammar)
        var seen: Set<String> = [text]
        var texts: [String] = []
        for rules in DatabendTokenizer.Rules.readings(of: scalars) {
            var candidates: [String] = []
            if let whole = code(of: scalars, rules: rules) {
                candidates.append(whole)
            }
            if statements.count > 1 {
                let pieces = statements.compactMap { code(of: Array($0.sql.unicodeScalars), rules: rules) }
                candidates.append(pieces.joined(separator: " ;\n"))
            }
            for candidate in candidates where seen.insert(candidate).inserted {
                texts.append(candidate)
            }
        }
        return texts
    }

    // Nil when the server refuses the text before it parses anything. A hint the parser takes holds settings, never a
    // statement, so it is dropped with the rest.
    static func code(of scalars: [Unicode.Scalar], rules: DatabendTokenizer.Rules) -> String? {
        let reading = DatabendTokenizer.read(scalars, rules: rules)
        let tokens = reading.tokens
        guard reading.isComplete || parsesWhatItRead(tokens, scalars: scalars) else { return nil }
        var words: [String] = []
        var insideHint = false
        var statementStart = true
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let spelling = scalars[token.range]
            index += 1
            if insideHint {
                insideHint = token.kind != .hintSuffix
                continue
            }
            if statementStart, token.kind == .name, String(String.UnicodeScalarView(spelling)).uppercased() == "SETTINGS" {
                index = settingsEnd(in: tokens, scalars: scalars, from: index)
                continue
            }
            statementStart = token.kind == .symbol && spelling.elementsEqual([";"])
            switch token.kind {
            case .hintPrefix:
                insideHint = true
            case .name:
                words.append(word(spelling) { $0 == "$" ? "_" : $0 })
            case .variable:
                words.append(word(spelling) { $0 == "$" || !isNameScalar($0) ? "_" : $0 })
            case .stageName:
                words.append("@" + word(spelling.dropFirst()) { isNameScalar($0) && $0.isASCII ? $0 : "_" })
            case .quoted, .codeString, .number, .placeholder, .hintSuffix:
                words.append(word(spelling) { $0 })
            case .symbol:
                let symbol = word(spelling) { (0x21...0x7E).contains($0.value) ? $0 : "_" }
                // `#` opens a line comment in a reading the grammar keeps in doubt.
                words.append(symbol.hasPrefix("#") ? symbol + "\n" : symbol)
            }
        }
        return words.joined(separator: " ")
    }

    // Planner::parse_sql_inner parses an INSERT, other than INSERT ALL or FIRST, and a REPLACE from the tokens before
    // the point the tokenizer stopped, and refuses any other statement it cannot tokenize whole.
    private static func parsesWhatItRead(_ tokens: [DatabendTokenizer.Token], scalars: [Unicode.Scalar]) -> Bool {
        let words = tokens.prefix(3).map { token in
            token.kind == .name ? String(String.UnicodeScalarView(scalars[token.range])).uppercased() : ""
        }
        switch words.first {
        case "REPLACE":
            return true
        case "INSERT":
            return !words.contains("ALL") && !words.contains("FIRST")
        default:
            return false
        }
    }

    // Past the `( ... )` that may follow `SETTINGS`, whose tokens start at `index`.
    private static func settingsEnd(
        in tokens: [DatabendTokenizer.Token],
        scalars: [Unicode.Scalar],
        from index: Int
    ) -> Int {
        var depth = 0
        for position in index..<tokens.count {
            let token = tokens[position]
            guard token.kind == .symbol else {
                if depth == 0 { return position }
                continue
            }
            switch scalars[token.range.lowerBound] {
            case "(":
                depth += 1
            case ")" where depth > 0:
                depth -= 1
                if depth == 0 { return position + 1 }
            default:
                if depth == 0 { return position }
            }
        }
        return tokens.count
    }

    private static func word(
        _ scalars: ArraySlice<Unicode.Scalar>,
        _ transform: (Unicode.Scalar) -> Unicode.Scalar
    ) -> String {
        var result = String.UnicodeScalarView()
        result.append(contentsOf: scalars.map(transform))
        return String(result)
    }

    private static func isNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || !scalar.isASCII || scalar.properties.isAlphabetic || ("0"..."9").contains(scalar)
    }
}
