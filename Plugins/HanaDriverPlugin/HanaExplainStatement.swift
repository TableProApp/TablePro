import Foundation

enum HanaExplainStatement {
    private static let prefixKeywords = ["EXPLAIN", "PLAN", "FOR"]

    static func explainedStatement(in sql: String) -> String? {
        let scalars = Array(sql.unicodeScalars)
        var index = 0
        for keyword in prefixKeywords {
            index = skipTrivia(scalars, from: index)
            guard let end = matchKeyword(keyword, in: scalars, at: index) else { return nil }
            index = end
        }
        guard index < scalars.count, !isIdentifierScalar(scalars[index]) else { return nil }
        let inner = String(String.UnicodeScalarView(scalars[index...]))
        let statement = trimmedStatement(inner)
        return statement.isEmpty ? nil : statement
    }

    private static func skipTrivia(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start
        while index < scalars.count {
            if scalars[index].properties.isWhitespace {
                index += 1
            } else if startsWith("--", in: scalars, at: index) {
                index = endOfLineComment(scalars, from: index + 2)
            } else if startsWith("/*", in: scalars, at: index) {
                index = endOfBlockComment(scalars, from: index + 2)
            } else {
                return index
            }
        }
        return index
    }

    private static func endOfLineComment(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start
        while index < scalars.count, scalars[index] != "\n", scalars[index] != "\r" {
            index += 1
        }
        return index
    }

    private static func endOfBlockComment(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start
        while index < scalars.count {
            if startsWith("*/", in: scalars, at: index) { return index + 2 }
            index += 1
        }
        return index
    }

    private static func matchKeyword(_ keyword: String, in scalars: [Unicode.Scalar], at start: Int) -> Int? {
        var index = start
        for expected in keyword.unicodeScalars {
            guard index < scalars.count,
                  String(scalars[index]).uppercased() == String(expected) else {
                return nil
            }
            index += 1
        }
        guard index < scalars.count, !isIdentifierScalar(scalars[index]) else {
            return index == scalars.count ? index : nil
        }
        return index
    }

    private static func startsWith(_ marker: String, in scalars: [Unicode.Scalar], at start: Int) -> Bool {
        var index = start
        for expected in marker.unicodeScalars {
            guard index < scalars.count, scalars[index] == expected else { return false }
            index += 1
        }
        return true
    }

    private static func isIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || scalar == "$" || scalar == "#" || scalar.properties.isAlphabetic
            || scalar.properties.numericType != nil || scalar.properties.generalCategory == .nonspacingMark
    }

    private static func trimmedStatement(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        while let last = scalars.last, last == ";" || last.properties.isWhitespace {
            scalars.removeLast()
        }
        while let first = scalars.first, first.properties.isWhitespace {
            scalars.removeFirst()
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
