import Foundation

enum DamengStatementClassifier {
    private static let resultKeywords: Set<String> = [
        "DESC", "DESCRIBE", "EXPLAIN", "SELECT", "SHOW", "VALUES", "WITH"
    ]

    static func expectsRows(_ query: String) -> Bool {
        guard let keyword = firstKeyword(query) else { return false }
        return resultKeywords.contains(keyword)
    }

    private static func firstKeyword(_ query: String) -> String? {
        var remaining = query[...]
        while true {
            remaining = remaining.drop { $0.isWhitespace || $0 == "(" || $0 == ";" || $0 == "\u{FEFF}" }
            if remaining.hasPrefix("--") {
                guard let newline = remaining.firstIndex(where: \.isNewline) else { return nil }
                remaining = remaining[remaining.index(after: newline)...]
            } else if remaining.hasPrefix("/*") {
                remaining = skippingBlockComment(remaining.dropFirst(2))
            } else {
                let keyword = remaining.prefix { $0.isLetter || $0 == "_" }
                return keyword.isEmpty ? nil : keyword.uppercased()
            }
        }
    }

    private static func skippingBlockComment(_ body: Substring) -> Substring {
        var remaining = body
        var depth = 1
        while let character = remaining.first {
            remaining = remaining.dropFirst()
            if character == "/", remaining.first == "*" {
                remaining = remaining.dropFirst()
                depth += 1
            } else if character == "*", remaining.first == "/" {
                remaining = remaining.dropFirst()
                depth -= 1
                if depth == 0 { return remaining }
            }
        }
        return remaining
    }
}
