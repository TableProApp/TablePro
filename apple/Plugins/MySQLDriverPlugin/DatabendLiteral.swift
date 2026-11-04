//
//  DatabendLiteral.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

internal enum DatabendLiteralError: Error, Equatable {
    case parameterCountMismatch(placeholders: Int, values: Int)
    case placeholdersDependOnServerVersion
    case serverTooOldToBind
}

extension DatabendLiteralError: PluginDriverError {
    var pluginErrorMessage: String {
        switch self {
        case let .parameterCountMismatch(placeholders, values):
            return String(
                format: String(localized: "The statement has %d placeholders but %d values were given."),
                placeholders, values
            )
        case .serverTooOldToBind:
            return String(localized: "Binding parameters needs Databend 1.2.473 or later.")
        case .placeholdersDependOnServerVersion:
            return String(
                localized: "Databend versions end this statement's comments in different places, so its parameters cannot be bound. Rewrite comments such as /**/ or one ending in **/."
            )
        }
    }
}

internal enum DatabendLiteral {
    // QuotedString reads `\0` as an octal escape that takes the octal digits after it, so NUL is `\x00`, as
    // Databend's own writer spells it.
    static func escapeString(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count + 2)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "'": result += "''"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\0": result += "\\x00"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    static func quoted(_ value: String) -> String {
        "'\(escapeString(value))'"
    }

    static func hex(_ data: Data) -> String {
        "X'" + data.map { String(format: "%02X", $0) }.joined() + "'"
    }

    static func literal(for value: PluginCellValue) -> String {
        switch value {
        case .null:
            return "NULL"
        case .text(let text):
            return quoted(text)
        case .bytes(let data):
            return hex(data)
        }
    }

    // 1.2.473 brought today's literal and name decoding, and every tokenizer change since is a reading below. An
    // older release reads `1_`, `$$`, stage names and several operators differently, so a value bound for it could
    // land outside its literal.
    static let oldestBindingRelease = (major: 1, minor: 2, patch: 473)

    // `8.0.90-v1.2.880-nightly-081742daa3(...)`: the MySQL version Databend answers as, then its own.
    static func release(fromServerVersion banner: String) -> (major: Int, minor: Int, patch: Int)? {
        guard let marker = banner.range(of: "-v") else { return nil }
        return MySQLServerVersion.components(from: String(banner[marker.upperBound...]))
    }

    // A value only stays a literal where every release the server could be reads a placeholder in the same place.
    static func inline(_ sql: String, parameters: [PluginCellValue], serverVersion: String? = nil) throws -> String {
        if let banner = serverVersion, let release = release(fromServerVersion: banner), release < oldestBindingRelease {
            throw DatabendLiteralError.serverTooOldToBind
        }
        let scalars = Array(sql.unicodeScalars)
        let placeholders = DatabendPlaceholderScanner(scalars: scalars, rules: .current).placeholders()
        for rules in DatabendTokenizerRules.readings(of: scalars).dropFirst() {
            guard DatabendPlaceholderScanner(scalars: scalars, rules: rules).placeholders() == placeholders else {
                throw DatabendLiteralError.placeholdersDependOnServerVersion
            }
        }
        guard placeholders.count == parameters.count else {
            throw DatabendLiteralError.parameterCountMismatch(placeholders: placeholders.count, values: parameters.count)
        }
        var output = String.UnicodeScalarView()
        var copied = 0
        for (offset, value) in zip(placeholders, parameters) {
            output.append(contentsOf: scalars[copied..<offset])
            output.append(contentsOf: literal(for: value).unicodeScalars)
            copied = offset + 1
        }
        output.append(contentsOf: scalars[copied...])
        return String(output)
    }
}

// The rules of Databend's tokenizer, src/query/ast/src/parser/token.rs, that changed between releases.
struct DatabendTokenizerRules: Hashable {
    // Before 1.2.884 a block comment is `/\*[^\+]([^\*]|(\*[^/]))*\*/`, so `**/` and `/**/` leave it open.
    var pairsStarsInBlockComments: Bool
    // A stage name such as `@s` ran on through a comma until October 2025.
    var commaContinuesStageNames: Bool
    // `!*` was an operator until July 2026, so `!*/*` opened a comment.
    var bangStarIsAnOperator: Bool
    // A hint after MERGE was skipped like one in any other wrong place until April 2026.
    var mergeTakesHints: Bool

    static let current = DatabendTokenizerRules(
        pairsStarsInBlockComments: false, commaContinuesStageNames: false, bangStarIsAnOperator: false,
        mergeTakesHints: true
    )

    // The current rules first, then each older one the text can tell apart.
    static func readings(of scalars: [Unicode.Scalar]) -> [DatabendTokenizerRules] {
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

// Reads tokens as the server does only as far as a `?` needs: a comment, a literal, a stage name, a name or an
// operator holding one hides it, and so does a hint the server skips. Text the server refuses to tokenize ends the
// scan, so no later `?` is bound.
struct DatabendPlaceholderScanner {
    let scalars: [Unicode.Scalar]
    let rules: DatabendTokenizerRules

    private static let operators: [[Unicode.Scalar]] = [
        "!~*", "#>>", "->>", "<+>", "<->", "<=>", "||/",
        "!!", "!=", "!~", "#-", "#>", "*/", "->", "//", "::", ":=", "<<", "<=", "<>", "<@", "=>", "==", ">=", ">>",
        "?&", "?|", "@>", "@?", "@@", "|/", "||", "~*",
    ].map { Array($0.unicodeScalars) }

    private static let operatorStarts = Set(operators.compactMap(\.first))

    private static let hintTakers: Set<String> = ["INSERT", "SELECT", "REPLACE", "UPDATE", "DELETE", "COPY"]

    private enum TokenKind {
        case skipped, hintPrefix, hintSuffix, placeholder, hintTaker, other
    }

    // Tokenizer::next skips a hint unless the token before it is one that takes a hint, and a hint skipped inside
    // another one takes its own `*/`.
    func placeholders() -> [Int] {
        var offsets: [Int] = []
        var index = 0
        var previousTakesHint = false
        var skippedHints = 0
        while index < scalars.count {
            guard let end = tokenEnd(at: index) else { return offsets }
            switch kind(from: index, to: end) {
            case .skipped:
                break
            case .hintPrefix where !previousTakesHint:
                skippedHints += 1
            case .hintSuffix where skippedHints > 0:
                skippedHints -= 1
                previousTakesHint = false
            case .placeholder:
                if skippedHints == 0 { offsets.append(index) }
                previousTakesHint = false
            case .hintTaker:
                previousTakesHint = true
            default:
                previousTakesHint = false
            }
            index = end
        }
        return offsets
    }

    private func kind(from start: Int, to end: Int) -> TokenKind {
        let first = scalars[start]
        let second = peek(start + 1)
        switch first {
        case " ", "\t", "\r", "\n", "\u{0C}":
            return .skipped
        case "-" where second == "-" && end > start + 1:
            return .skipped
        case "/" where second == "*" && end > start + 1:
            return end == start + 3 && scalars[start + 2] == "+" ? .hintPrefix : .skipped
        case "*" where second == "/" && end == start + 2:
            return .hintSuffix
        case "?" where end == start + 1:
            return .placeholder
        default:
            guard Self.startsName(first), first.isASCII else { return .other }
            let word = String(String.UnicodeScalarView(scalars[start..<end])).uppercased()
            return Self.hintTakers.contains(word) || (rules.mergeTakesHints && word == "MERGE") ? .hintTaker : .other
        }
    }

    // Past the token at `index`, or nil when the server stops reading there.
    private func tokenEnd(at index: Int) -> Int? {
        let scalar = scalars[index]
        let next = peek(index + 1)
        switch scalar {
        case "-" where next == "-":
            var end = index + 2
            while end < scalars.count, scalars[end] != "\n", scalars[end] != "\u{0C}" {
                end += 1
            }
            return end
        case "/" where next == "*":
            if peek(index + 2) == "+" { return index + 3 }
            return rules.pairsStarsInBlockComments ? pairedStarCommentEnd(at: index) : firstCloseCommentEnd(at: index)
        case "'", "\"":
            return stringEnd(at: index, quote: scalar)
        case "`":
            return scalars[(index + 1)...].firstIndex(of: "`").map { $0 + 1 }
        case "$":
            return dollarEnd(at: index)
        case "@":
            let end = stageNameEnd(at: index)
            if end > index + 1 { return end }
        case "0"..."9":
            return numberEnd(at: index)
        case "." where next.map(Self.isDigit) == true:
            return numberEnd(at: index)
        default:
            if Self.startsName(scalar) { return nameEnd(from: index + 1) }
        }
        if Self.operatorStarts.contains(scalar), let symbol = Self.operators.first(where: { matches($0, at: index) }) {
            return index + symbol.count
        }
        if rules.bangStarIsAnOperator, matches(["!", "*"], at: index) {
            return index + 2
        }
        return index + 1
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

    private func dollarEnd(at index: Int) -> Int? {
        guard let next = peek(index + 1) else { return index + 1 }
        if next == "$" {
            var cursor = index + 2
            while cursor + 1 < scalars.count {
                if scalars[cursor] == "$", scalars[cursor + 1] == "$" { return cursor + 2 }
                cursor += 1
            }
            return nil
        }
        if Self.isDigit(next) { return digitsEnd(from: index + 1) }
        if Self.startsName(next), next.isASCII { return nameEnd(from: index + 2) }
        return index + 1
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

    // A name runs through `$` and digits. Any non-ASCII scalar is taken as part of one: the server either reads it
    // so or refuses the statement.
    private func nameEnd(from index: Int) -> Int {
        var cursor = index
        while let scalar = peek(cursor), Self.startsName(scalar) || Self.isDigit(scalar) || scalar == "$" {
            cursor += 1
        }
        return cursor
    }

    private static func startsName(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || !scalar.isASCII
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }
}
