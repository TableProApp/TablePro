//
//  SQLFunctionCallScanner.swift
//  TablePro
//

import Foundation

enum SQLFunctionCallScanner {
    enum Callee: Equatable {
        case unnamed
        case named(String, start: Int)
    }

    struct Call: Equatable {
        let callee: Callee
        let parenthesis: Int
    }

    static let openParenthesis = UInt16(UnicodeScalar("(").value)

    static func calls(in source: NSString, code: NSString) -> [Call] {
        var calls: [Call] = []
        for index in 0..<code.length where code.character(at: index) == openParenthesis {
            guard let callee = callee(before: index, code: code, source: source) else { continue }
            calls.append(Call(callee: callee, parenthesis: index))
        }
        return calls
    }

    static func isBlank(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D || unit == 0x0C || unit == 0x0B
    }

    static func isIdentifierUnit(_ unit: UInt16) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return true }
        return scalar == "_" || scalar == "$" || CharacterSet.alphanumerics.contains(scalar) || unit > 0x7F
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
        while cursor >= 0, isBlank(code.character(at: cursor)) {
            cursor -= 1
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
        while start > 0, isIdentifierUnit(code.character(at: start - 1)) {
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
}
