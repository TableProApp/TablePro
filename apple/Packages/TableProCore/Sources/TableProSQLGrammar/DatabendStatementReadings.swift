import Foundation

/// What a Databend server parses from a text, written out for a gate that reads it with a lexical grammar.
///
/// The app sends a text one statement at a time, cut where the grammar cuts it, and the server tokenizes each statement
/// alone, so each reading of ``DatabendTokenizer/Rules`` gives the tokens of every statement, joined by `;`, and those
/// of the whole text. A token is written so the Databend grammar lexes it alone: a hint, a comment or a blank is
/// dropped, and a `$` or a quote that would open a literal the server does not read is spelled `_`.
enum DatabendStatementReadings {
    static func texts(of text: String, grammar: SQLLexicalGrammar) -> [String] {
        let scalars = Array(text.unicodeScalars)
        let statements = SQLStatementScanner.executableStatements(in: text, grammar: grammar)
        var seen: Set<String> = [text]
        var texts: [String] = []
        for rules in DatabendTokenizer.Rules.readings(of: scalars) {
            var candidates = [code(of: scalars, rules: rules)]
            if statements.count > 1 {
                let pieces = statements.map { code(of: Array($0.sql.unicodeScalars), rules: rules) }
                candidates.append(pieces.joined(separator: " ;\n"))
            }
            for candidate in candidates where seen.insert(candidate).inserted {
                texts.append(candidate)
            }
        }
        return texts
    }

    // A hint the parser takes holds settings, never a statement, so it is dropped with the rest.
    static func code(of scalars: [Unicode.Scalar], rules: DatabendTokenizer.Rules) -> String {
        var words: [String] = []
        var insideHint = false
        for token in DatabendTokenizer.read(scalars, rules: rules).tokens {
            if insideHint {
                insideHint = token.kind != .hintSuffix
                continue
            }
            let spelling = scalars[token.range]
            switch token.kind {
            case .hintPrefix:
                insideHint = true
            case .name:
                words += nameWords(spelling)
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

    // A keyword wins over the name that would run on past it into a non-ASCII scalar, so the server reads `TABLE中` as
    // TABLE and then 中. The ASCII start is written apart, which keeps every keyword the server could read there.
    private static func nameWords(_ spelling: ArraySlice<Unicode.Scalar>) -> [String] {
        let asciiEnd = spelling.firstIndex { !$0.isASCII } ?? spelling.endIndex
        let parts = [spelling[..<asciiEnd], spelling[asciiEnd...]].filter { !$0.isEmpty }
        return parts.map { part in word(part) { $0 == "$" ? "_" : $0 } }
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
