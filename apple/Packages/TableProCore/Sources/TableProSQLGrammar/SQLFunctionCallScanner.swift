import Foundation

public enum SQLFunctionCallScanner {
    public enum Callee: Equatable {
        case unnamed
        case named(String, start: Int)
    }

    public struct Call: Equatable {
        public let callee: Callee
        public let parenthesis: Int
    }

    public static let openParenthesis = UInt16(UnicodeScalar("(").value)

    public static func calls(in source: NSString, code: NSString) -> [Call] {
        var calls: [Call] = []
        for index in 0..<code.length where code.character(at: index) == openParenthesis {
            guard let callee = callee(before: index, code: code, source: source) else { continue }
            if case .named(_, let start) = callee,
               declaresColumns(nameStart: start, parenthesis: index, code: code, source: source) {
                continue
            }
            calls.append(Call(callee: callee, parenthesis: index))
        }
        return calls
    }

    // DuckDB takes U+00A0 and U+200B before a call's parenthesis, as StatementBlank does.
    public static func isBlank(_ unit: UInt16) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return false }
        return StatementBlank.isBlank(scalar)
    }

    public static func isIdentifierUnit(_ unit: UInt16) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return true }
        guard !StatementBlank.isBlank(scalar) else { return false }
        return scalar == "_" || scalar == "$" || CharacterSet.alphanumerics.contains(scalar) || unit > 0x7F
    }

    // A blank outside the BMP, such as a tag character, is two units.
    private static func blankUnits(endingAt cursor: Int, in code: NSString) -> Int {
        let unit = code.character(at: cursor)
        if UTF16.isTrailSurrogate(unit), cursor > 0, UTF16.isLeadSurrogate(code.character(at: cursor - 1)) {
            return StatementBlank.blankLength(in: code, at: cursor - 1) == 2 ? 2 : 0
        }
        return isBlank(unit) ? 1 : 0
    }

    private static let quoteClosers: Set<UInt16> = [0x22, 0x60, 0x5D]
    private static let ampersand = UInt16(UnicodeScalar("&").value)
    private static let unicodeEscapeMarkers: Set<UInt16> = [
        UInt16(UnicodeScalar("U").value), UInt16(UnicodeScalar("u").value)
    ]
    private static let unicodeEscapeClause = "UESCAPE"

    /// What stands in front of the parenthesis at `index`. The projection has blanked comments,
    /// literals and quoted identifiers to spaces, so the source text over that blank stretch says
    /// whether a quoted name was there.
    private static func callee(before index: Int, code: NSString, source: NSString) -> Callee? {
        var cursor = index - 1
        while cursor >= 0, blankUnits(endingAt: cursor, in: code) > 0 {
            cursor -= blankUnits(endingAt: cursor, in: code)
        }
        let blankStart = cursor + 1
        if blankStart < index {
            let skipped = source.substring(with: NSRange(location: blankStart, length: index - blankStart))
            if skipped.utf16.contains(where: quoteClosers.contains) {
                let leading = skipped.utf16.prefix { isBlank($0) }.count
                guard !followsUnicodeEscapeMarker(cursor, code: code), let name = quotedName(in: skipped) else {
                    return .unnamed
                }
                return .named(name, start: blankStart + leading)
            }
        }
        guard cursor >= 0 else { return nil }
        if quoteClosers.contains(code.character(at: cursor)) {
            return quotedName(endingAt: cursor, in: code).map { .named($0.name, start: $0.start) } ?? .unnamed
        }
        guard isIdentifierUnit(code.character(at: cursor)) else { return nil }
        var start = cursor
        while start > 0, isIdentifierUnit(code.character(at: start - 1)), blankUnits(endingAt: start - 1, in: code) == 0 {
            start -= 1
        }
        let name = code.substring(with: NSRange(location: start, length: cursor - start + 1))
        guard name.uppercased() != unicodeEscapeClause else { return .unnamed }
        return .named(name, start: start)
    }

    private static func followsUnicodeEscapeMarker(_ cursor: Int, code: NSString) -> Bool {
        guard cursor >= 1, code.character(at: cursor) == ampersand else { return false }
        return unicodeEscapeMarkers.contains(code.character(at: cursor - 1))
    }

    /// The name inside the one quoted identifier a stretch holds, and nothing else but blanks and
    /// comments around it. Anything less certain is left unnamed.
    private static func quotedName(in stretch: String) -> String? {
        let trimmed = stretch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, let last = trimmed.last, trimmed.count >= 2 else { return nil }
        let pairs: [Character: Character] = ["\"": "\"", "`": "`", "[": "]"]
        guard pairs[first] == last else { return nil }
        let inner = String(trimmed.dropFirst().dropLast())
        let unescaped = first == "[" ? inner : inner.replacingOccurrences(of: "\(last)\(last)", with: "\(last)")
        guard !unescaped.contains(last) || first == "[" else { return nil }
        return unescaped
    }

    /// A quoted name a reading left as code, which happens for `[name]` under a grammar without
    /// bracket quoting.
    private static func quotedName(endingAt closer: Int, in code: NSString) -> (name: String, start: Int)? {
        let closing = code.character(at: closer)
        let opening = closing == 0x5D ? UInt16(UnicodeScalar("[").value) : closing
        var cursor = closer - 1
        while cursor >= 0, code.character(at: cursor) != opening, code.character(at: cursor) != openParenthesis {
            cursor -= 1
        }
        guard cursor >= 0, code.character(at: cursor) == opening,
              let name = quotedName(in: code.substring(with: NSRange(location: cursor, length: closer - cursor + 1)))
        else { return nil }
        return (name: name, start: cursor)
    }

    private struct Word {
        let text: String
        let start: Int
        let end: Int
    }

    private static let comma = UInt16(UnicodeScalar(",").value)
    private static let period = UInt16(UnicodeScalar(".").value)
    private static let closeParenthesis = UInt16(UnicodeScalar(")").value)
    private static let digits = UInt16(UnicodeScalar("0").value)...UInt16(UnicodeScalar("9").value)

    // A quote mark where the projection is blank: a string or a quoted name stands there, not just a comment.
    private static let quoteMarks = Set("'\"`[$".utf16)

    // A clause word before the alias says the AS is not in a FROM or JOIN list.
    private static let clausesOutsideTableLists: Set<String> = [
        "SELECT", "WHERE", "GROUP", "HAVING", "QUALIFY", "WINDOW", "ORDER", "LIMIT", "OFFSET", "UNION", "INTERSECT",
        "EXCEPT", "RETURNING", "SET", "VALUES", "INTO", "TABLE", "CREATE", "WITH", "DEFINE", "MEASURES",
    ]

    // `WITH name(a) AS (` declares a CTE's columns and `FROM t AS name(a)` an alias's: a call there is a parse error.
    private static func declaresColumns(nameStart: Int, parenthesis: Int, code: NSString, source: NSString) -> Bool {
        let before = lastUnit(before: nameStart, in: code)
        guard before >= 0, !holdsQuotedText(from: before + 1, to: nameStart, in: source) else { return false }
        if code.character(at: before) == comma {
            return endsCommonTableExpression(separator: before, code: code)
                && opensCommonTableExpression(parenthesis, code: code, source: source)
        }
        if leadsCommonTableExpressions(endingAt: before, in: code) {
            return opensCommonTableExpression(parenthesis, code: code, source: source)
        }
        guard let keyword = wordEnding(at: before, in: code), keyword.text == "AS" else { return false }
        return aliasesRelation(before: keyword.start, code: code)
    }

    // `(a, b) AS [[NOT] MATERIALIZED] (`, with nothing but blanks and comments between.
    private static func opensCommonTableExpression(_ parenthesis: Int, code: NSString, source: NSString) -> Bool {
        guard let close = matchingClose(of: parenthesis, in: code),
              let keyword = wordStarting(at: firstUnit(from: close + 1, in: code), in: code), keyword.text == "AS"
        else { return false }
        var cursor = firstUnit(from: keyword.end, in: code)
        if let hint = wordStarting(at: cursor, in: code) {
            let afterNot = hint.text == "NOT" ? wordStarting(at: firstUnit(from: hint.end, in: code), in: code) : hint
            guard let materialized = afterNot, materialized.text == "MATERIALIZED" else { return false }
            cursor = firstUnit(from: materialized.end, in: code)
        }
        return cursor < code.length && code.character(at: cursor) == openParenthesis
            && !holdsQuotedText(from: close + 1, to: cursor, in: source)
    }

    // Every item back to the WITH is a CTE, so a FROM list's `f() AS (a int), g(` is not one.
    private static func endsCommonTableExpression(separator: Int, code: NSString) -> Bool {
        var separator = separator
        while true {
            let close = lastUnit(before: separator, in: code)
            guard close >= 0, code.character(at: close) == closeParenthesis,
                  let body = matchingOpen(of: close, in: code), let keyword = bodyKeyword(before: body, in: code)
            else { return false }
            var nameEnd = lastUnit(before: keyword.start, in: code)
            if nameEnd >= 0, code.character(at: nameEnd) == closeParenthesis {
                guard let columns = matchingOpen(of: nameEnd, in: code) else { return false }
                nameEnd = lastUnit(before: columns, in: code)
            }
            guard let name = wordEnding(at: nameEnd, in: code) else { return false }
            let before = lastUnit(before: name.start, in: code)
            guard before >= 0, code.character(at: before) == comma else {
                return leadsCommonTableExpressions(endingAt: before, in: code)
            }
            separator = before
        }
    }

    private static func leadsCommonTableExpressions(endingAt end: Int, in code: NSString) -> Bool {
        guard let word = wordEnding(at: end, in: code) else { return false }
        guard word.text == "RECURSIVE" else { return word.text == "WITH" }
        return wordEnding(at: lastUnit(before: word.start, in: code), in: code)?.text == "WITH"
    }

    // The AS of `AS [[NOT] MATERIALIZED] (`.
    private static func bodyKeyword(before parenthesis: Int, in code: NSString) -> Word? {
        guard let last = wordEnding(at: lastUnit(before: parenthesis, in: code), in: code) else { return nil }
        guard last.text == "MATERIALIZED" else { return last.text == "AS" ? last : nil }
        guard let previous = wordEnding(at: lastUnit(before: last.start, in: code), in: code) else { return nil }
        guard previous.text == "NOT" else { return previous.text == "AS" ? previous : nil }
        let keyword = wordEnding(at: lastUnit(before: previous.start, in: code), in: code)
        return keyword?.text == "AS" ? keyword : nil
    }

    // Only a FROM or JOIN list holds one: ClickHouse's `CREATE TABLE t AS remote(...)` is a call.
    private static func aliasesRelation(before keyword: Int, code: NSString) -> Bool {
        var cursor = lastUnit(before: keyword, in: code)
        while cursor >= 0 {
            let unit = code.character(at: cursor)
            if unit == closeParenthesis {
                guard let open = matchingOpen(of: cursor, in: code) else { return false }
                cursor = lastUnit(before: open, in: code)
            } else if unit == comma || unit == period {
                cursor = lastUnit(before: cursor, in: code)
            } else if let word = wordEnding(at: cursor, in: code) {
                if word.text == "FROM" || word.text == "JOIN" { return true }
                guard !clausesOutsideTableLists.contains(word.text) else { return false }
                cursor = lastUnit(before: word.start, in: code)
            } else {
                return false
            }
        }
        return false
    }

    private static func holdsQuotedText(from start: Int, to end: Int, in source: NSString) -> Bool {
        guard end > start else { return false }
        let stretch = source.substring(with: NSRange(location: start, length: end - start))
        return stretch.utf16.contains(where: quoteMarks.contains)
    }

    private static func lastUnit(before index: Int, in code: NSString) -> Int {
        var cursor = index - 1
        while cursor >= 0, blankUnits(endingAt: cursor, in: code) > 0 {
            cursor -= blankUnits(endingAt: cursor, in: code)
        }
        return cursor
    }

    private static func firstUnit(from index: Int, in code: NSString) -> Int {
        var cursor = index
        while cursor < code.length, StatementBlank.blankLength(in: code, at: cursor) > 0 {
            cursor += StatementBlank.blankLength(in: code, at: cursor)
        }
        return cursor
    }

    private static func wordEnding(at last: Int, in code: NSString) -> Word? {
        guard last >= 0, last < code.length, isIdentifierUnit(code.character(at: last)) else { return nil }
        var start = last
        while start > 0, isIdentifierUnit(code.character(at: start - 1)),
              blankUnits(endingAt: start - 1, in: code) == 0 {
            start -= 1
        }
        return word(from: start, to: last + 1, in: code)
    }

    private static func wordStarting(at first: Int, in code: NSString) -> Word? {
        var end = first
        while end < code.length, isIdentifierUnit(code.character(at: end)),
              StatementBlank.blankLength(in: code, at: end) == 0 {
            end += 1
        }
        return end > first ? word(from: first, to: end, in: code) : nil
    }

    // A keyword is ASCII, so a word with a letter outside it keeps its spelling and matches none.
    private static func word(from start: Int, to end: Int, in code: NSString) -> Word? {
        guard !digits.contains(code.character(at: start)) else { return nil }
        let text = code.substring(with: NSRange(location: start, length: end - start))
        let isASCII = text.utf16.allSatisfy { $0 < 0x80 }
        return Word(text: isASCII ? text.uppercased() : text, start: start, end: end)
    }

    private static func matchingClose(of open: Int, in code: NSString) -> Int? {
        var depth = 0
        for cursor in open..<code.length {
            let unit = code.character(at: cursor)
            if unit == openParenthesis { depth += 1 }
            if unit == closeParenthesis {
                depth -= 1
                if depth == 0 { return cursor }
            }
        }
        return nil
    }

    private static func matchingOpen(of close: Int, in code: NSString) -> Int? {
        var depth = 0
        for cursor in stride(from: close, through: 0, by: -1) {
            let unit = code.character(at: cursor)
            if unit == closeParenthesis { depth += 1 }
            if unit == openParenthesis {
                depth -= 1
                if depth == 0 { return cursor }
            }
        }
        return nil
    }
}
