import Foundation

/// Databend's tokenizer, `src/query/ast/src/parser/token.rs`, as `Tokenizer::next` hands tokens to the parser: blanks
/// and comments dropped, and a hint dropped unless the token before it is a statement word that takes one.
///
/// The reading stops where the server meets text it cannot tokenize and refuses the statement. A name that starts with
/// a non-ASCII scalar runs through any other, and a control character is a token of its own: the server either reads
/// them so or refuses, and before 1.2.888 it refuses every non-ASCII scalar outside a literal. A name that starts in
/// ASCII ends at its first non-ASCII scalar, where a keyword ends on the server, so `TABLE中` is TABLE and then 中; any
/// other ASCII start is read as a name of its own too, which moves no placeholder or hint. ``Rules`` holds each other
/// rule a release since 1.2.473 changed.
public enum DatabendTokenizer {
    public enum Kind: Sendable, Hashable {
        case name, variable, quoted, codeString, stageName, number, placeholder, hintPrefix, hintSuffix, symbol
    }

    public struct Token: Sendable, Hashable {
        public let kind: Kind
        /// Offsets into the scalars read.
        public let range: Range<Int>
    }

    public struct Reading: Sendable, Hashable {
        public let tokens: [Token]
        /// False when the server stops before the end and refuses the statement.
        public let isComplete: Bool
    }

    public struct Rules: Sendable, Hashable {
        /// Before 1.2.884 a block comment is `/\*[^\+]([^\*]|(\*[^/]))*\*/`, so `**/` and `/**/` leave it open.
        public var pairsStarsInBlockComments: Bool
        /// A stage name such as `@s` ran on through a comma until October 2025.
        public var commaContinuesStageNames: Bool
        /// `!*` was an operator until July 2026, so `!*/*` opened a comment.
        public var bangStarIsAnOperator: Bool
        /// A hint after MERGE was skipped like one in any other wrong place until April 2026.
        public var mergeTakesHints: Bool

        public static let current = Rules(
            pairsStarsInBlockComments: false, commaContinuesStageNames: false, bangStarIsAnOperator: false,
            mergeTakesHints: true
        )

        /// The current rules first, then each older set the text can tell apart.
        public static func readings(of scalars: [Unicode.Scalar]) -> [Rules] {
            let pairs = zip(scalars, scalars.dropFirst())
            var readings = [current]
            if pairs.contains(where: { $0 == "/" && $1 == "*" }) {
                readings += readings.map { var rules = $0; rules.pairsStarsInBlockComments = true; return rules }
            }
            if scalars.contains("@") {
                readings += readings.map { var rules = $0; rules.commaContinuesStageNames = true; return rules }
            }
            if pairs.contains(where: { $0 == "!" && $1 == "*" }) {
                readings += readings.map { var rules = $0; rules.bangStarIsAnOperator = true; return rules }
            }
            if zip(pairs, scalars.dropFirst(2)).contains(where: { $0.0 == "/" && $0.1 == "*" && $1 == "+" }) {
                readings += readings.map { var rules = $0; rules.mergeTakesHints = false; return rules }
            }
            return readings
        }
    }

    public static func read(_ scalars: [Unicode.Scalar], rules: Rules = .current) -> Reading {
        Reader(scalars: scalars, rules: rules).read()
    }

    /// Where each `?` the parser reads as a placeholder stands, up to the point the server stops reading.
    public static func placeholders(in scalars: [Unicode.Scalar], rules: Rules = .current) -> [Int] {
        read(scalars, rules: rules).tokens.compactMap { $0.kind == .placeholder ? $0.range.lowerBound : nil }
    }
}

private struct Reader {
    let scalars: [Unicode.Scalar]
    let rules: DatabendTokenizer.Rules

    private typealias Kind = DatabendTokenizer.Kind

    private static let operators: [[Unicode.Scalar]] = [
        "!~*", "#>>", "->>", "<+>", "<->", "<=>", "||/",
        "!!", "!=", "!~", "#-", "#>", "*/", "->", "//", "::", ":=", "<<", "<=", "<>", "<@", "=>", "==", ">=", ">>",
        "?&", "?|", "@>", "@?", "@@", "|/", "||", "~*",
    ].map { Array($0.unicodeScalars) }

    private static let operatorStarts = Set(operators.compactMap(\.first))

    private static let hintTakers: Set<String> = ["INSERT", "SELECT", "REPLACE", "UPDATE", "DELETE", "COPY"]

    // Tokenizer::next skips a hint unless the token before it takes one, and a hint skipped inside another takes its
    // own `*/`. Every token it reads moves the token before, skipped ones too.
    func read() -> DatabendTokenizer.Reading {
        var tokens: [DatabendTokenizer.Token] = []
        var index = 0
        var previousTakesHint = false
        var skippedHints = 0
        while index < scalars.count {
            guard let (end, kind) = token(at: index) else {
                return DatabendTokenizer.Reading(tokens: tokens, isComplete: false)
            }
            switch kind {
            case nil:
                break
            case .hintPrefix? where !previousTakesHint:
                skippedHints += 1
            case .hintSuffix? where skippedHints > 0:
                skippedHints -= 1
                previousTakesHint = false
            case let kind?:
                if skippedHints == 0 {
                    tokens.append(DatabendTokenizer.Token(kind: kind, range: index..<end))
                }
                previousTakesHint = kind == .name && takesHint(index..<end)
            }
            index = end
        }
        return DatabendTokenizer.Reading(tokens: tokens, isComplete: true)
    }

    private func takesHint(_ range: Range<Int>) -> Bool {
        guard (4...7).contains(range.count), scalars[range].allSatisfy(\.isASCII) else { return false }
        let word = String(String.UnicodeScalarView(scalars[range])).uppercased()
        return Self.hintTakers.contains(word) || (rules.mergeTakesHints && word == "MERGE")
    }

    // Past the token at `index` and its kind, nil for a blank or a comment; nil when the server stops reading there.
    private func token(at index: Int) -> (end: Int, kind: Kind?)? {
        let scalar = scalars[index]
        let next = peek(index + 1)
        switch scalar {
        case " ", "\t", "\r", "\n", "\u{0C}":
            return (index + 1, nil)
        case "-" where next == "-":
            var end = index + 2
            while end < scalars.count, scalars[end] != "\n", scalars[end] != "\u{0C}" {
                end += 1
            }
            return (end, nil)
        case "/" where next == "*":
            if peek(index + 2) == "+" { return (index + 3, .hintPrefix) }
            let end = rules.pairsStarsInBlockComments ? pairedStarCommentEnd(at: index) : firstCloseCommentEnd(at: index)
            return end.map { ($0, nil) }
        case "'", "\"":
            return stringEnd(at: index, quote: scalar).map { ($0, .quoted) }
        case "`":
            return backtickNameEnd(at: index).map { ($0, .quoted) }
        case "$":
            return dollarToken(at: index)
        case "@":
            let end = stageNameEnd(at: index)
            // `@>`, `@?` and `@@` alone are operators, which win a tie with a stage name.
            if end > index + 2 || (end == index + 2 && !Self.operators.contains([scalar, scalars[index + 1]])) {
                return (end, .stageName)
            }
        case "0"..."9":
            return (numberEnd(at: index), .number)
        case "." where next.map(Self.isDigit) == true:
            return (numberEnd(at: index), .number)
        default:
            if Self.startsName(scalar) { return (nameEnd(from: index + 1, asciiOnly: scalar.isASCII), .name) }
        }
        if Self.operatorStarts.contains(scalar), let symbol = Self.operators.first(where: { matches($0, at: index) }) {
            return (index + symbol.count, symbol == ["*", "/"] ? .hintSuffix : .symbol)
        }
        if rules.bangStarIsAnOperator, matches(["!", "*"], at: index) {
            return (index + 2, .symbol)
        }
        return (index + 1, scalar == "?" ? .placeholder : .symbol)
    }

    private func peek(_ index: Int) -> Unicode.Scalar? {
        index < scalars.count ? scalars[index] : nil
    }

    private func matches(_ symbol: [Unicode.Scalar], at index: Int) -> Bool {
        index + symbol.count <= scalars.count && scalars[index..<(index + symbol.count)].elementsEqual(symbol)
    }

    private func firstCloseCommentEnd(at index: Int) -> Int? {
        var cursor = index + 2
        while cursor + 1 < scalars.count {
            if scalars[cursor] == "*", scalars[cursor + 1] == "/" { return cursor + 2 }
            cursor += 1
        }
        return nil
    }

    private func pairedStarCommentEnd(at index: Int) -> Int? {
        var cursor = index + 3
        while cursor < scalars.count {
            guard scalars[cursor] == "*" else {
                cursor += 1
                continue
            }
            guard cursor + 1 < scalars.count else { return nil }
            if scalars[cursor + 1] == "/" { return cursor + 2 }
            cursor += 2
        }
        return nil
    }

    // `'([^'\\]|\\.|'')*'`, where `.` is anything but a line feed.
    private func stringEnd(at index: Int, quote: Unicode.Scalar) -> Int? {
        var cursor = index + 1
        while cursor < scalars.count {
            switch scalars[cursor] {
            case "\\":
                guard let escaped = peek(cursor + 1), escaped != "\n" else { return nil }
                cursor += 2
            case quote where peek(cursor + 1) == quote:
                cursor += 2
            case quote:
                return cursor + 1
            default:
                cursor += 1
            }
        }
        return nil
    }

    // `` `([^`]|``)*` `` from 1.2.945. An older release ends the name at the doubled backtick and starts another right
    // after it, which moves no placeholder, hint or keyword, so one reading serves both.
    private func backtickNameEnd(at index: Int) -> Int? {
        var cursor = index + 1
        while cursor < scalars.count {
            guard scalars[cursor] == "`" else {
                cursor += 1
                continue
            }
            guard peek(cursor + 1) == "`" else { return cursor + 1 }
            cursor += 2
        }
        return nil
    }

    private func dollarToken(at index: Int) -> (end: Int, kind: Kind?)? {
        guard let next = peek(index + 1) else { return (index + 1, .symbol) }
        if next == "$" {
            var cursor = index + 2
            while cursor + 1 < scalars.count {
                if scalars[cursor] == "$", scalars[cursor + 1] == "$" { return (cursor + 2, .codeString) }
                cursor += 1
            }
            return nil
        }
        if Self.isDigit(next) { return (digitsEnd(from: index + 1), .variable) }
        if Self.startsName(next), next.isASCII { return (nameEnd(from: index + 2, asciiOnly: true), .variable) }
        return (index + 1, .symbol)
    }

    // `@([^\s,`;'"()]|\\\s|\\'|\\"|\\\\)+`: a space or a quote stays in the name only after a backslash.
    private func stageNameEnd(at index: Int) -> Int {
        var cursor = index + 1
        while cursor < scalars.count {
            let scalar = scalars[cursor]
            switch scalar {
            case "`", ";", "(", ")":
                return cursor
            case "," where !rules.commaContinuesStageNames:
                return cursor
            case "'", "\"":
                guard scalars[cursor - 1] == "\\" else { return cursor }
            default:
                if scalar.properties.isWhitespace, scalars[cursor - 1] != "\\" {
                    return cursor
                }
            }
            cursor += 1
        }
        return cursor
    }

    // The longest of `[0-9]+(_|[0-9])*`, the two float forms and `0[xX][a-fA-F0-9]+`.
    private func numberEnd(at index: Int) -> Int {
        let integerEnd = digitsEnd(from: index)
        var end = index + 1
        if integerEnd > index {
            var cursor = integerEnd
            while let scalar = peek(cursor), scalar == "_" || Self.isDigit(scalar) {
                cursor += 1
            }
            end = max(end, cursor)
            if let exponent = exponentEnd(from: integerEnd) { end = max(end, exponent) }
            if scalars[index] == "0", let marker = peek(index + 1), marker == "x" || marker == "X" {
                var cursor = index + 2
                while let scalar = peek(cursor), scalar.properties.isASCIIHexDigit {
                    cursor += 1
                }
                if cursor > index + 2 { end = max(end, cursor) }
            }
        }
        if peek(integerEnd) == "." {
            let fractionEnd = digitsEnd(from: integerEnd + 1)
            if integerEnd > index || fractionEnd > integerEnd + 1 {
                end = max(end, exponentEnd(from: fractionEnd) ?? fractionEnd)
            }
        }
        return end
    }

    private func exponentEnd(from index: Int) -> Int? {
        guard let marker = peek(index), marker == "e" || marker == "E" else { return nil }
        var cursor = index + 1
        if let sign = peek(cursor), sign == "+" || sign == "-" { cursor += 1 }
        let end = digitsEnd(from: cursor)
        return end > cursor ? end : nil
    }

    private func digitsEnd(from index: Int) -> Int {
        var cursor = index
        while let scalar = peek(cursor), Self.isDigit(scalar) {
            cursor += 1
        }
        return cursor
    }

    private func nameEnd(from index: Int, asciiOnly: Bool) -> Int {
        var cursor = index
        while let scalar = peek(cursor), Self.startsName(scalar) || Self.isDigit(scalar) || scalar == "$",
              scalar.isASCII || !asciiOnly {
            cursor += 1
        }
        return cursor
    }

    private static func startsName(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || !scalar.isASCII
    }

    static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }
}
